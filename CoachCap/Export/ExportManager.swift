import Foundation
import AVFoundation
import AppKit

/// Post-recording compression. Downscales to 720p/1080p and re-encodes
/// so clips reliably fit WhatsApp's ~16 MB upload limit.
struct ExportManager {

    struct Options {
        /// Target long dimension (e.g. 1280 for 720p, 1920 for 1080p)
        var maxDimension: Int = 1280
        var videoBitrate: Int = 2_500_000
        var audioBitrate: Int = 128_000
    }

    /// Compresses `inputURL` into a new file next to it, suffix `_compressed`.
    /// Returns the URL of the compressed file.
    static func compress(inputURL: URL, options: Options = Options()) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)

        let outURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("_compressed.mp4")
        try? FileManager.default.removeItem(at: outURL)

        // Choose preset based on target dimension
        let preset = options.maxDimension >= 1920
            ? AVAssetExportPreset1920x1080
            : AVAssetExportPreset1280x720

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.sessionCreationFailed
        }

        session.outputURL      = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        if let err = session.error { throw err }
        return outURL
    }

    /// Opens the file in Finder.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Flattens a recording's system-audio + mic tracks into a SINGLE audio track, in place.
    ///
    /// The recorder writes system audio and microphone as two separate AVAssetWriter tracks.
    /// QuickTime / iOS mix every audio track on playback, but WhatsApp (and some other
    /// players) only play the FIRST track — so the coach's voice or the system sound goes
    /// missing once it's sent. This reads both tracks through AVAssetReaderAudioMixOutput
    /// (which sums them into one PCM stream), re-encodes that to one AAC track, copies the
    /// video through untouched (no re-encode), and replaces the original file.
    ///
    /// No-ops (returns the input URL unchanged) when there's only one audio track. On any
    /// failure it logs and returns the original two-track file, which still plays everywhere
    /// except the WhatsApp edge case — better than losing the recording.
    static func flattenAudioTracks(inputURL: URL) async -> URL {
        let asset = AVURLAsset(url: inputURL)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard audioTracks.count > 1 else { return inputURL }   // nothing to merge
            let videoTracks = try await asset.loadTracks(withMediaType: .video)

            let outURL = inputURL.deletingPathExtension()
                .appendingPathExtension("flat.mp4")
            try? FileManager.default.removeItem(at: outURL)

            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

            // Video: passthrough (nil settings = copy compressed samples, no re-encode).
            var videoPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
            if let vTrack = videoTracks.first {
                let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
                vOut.alwaysCopiesSampleData = false
                if reader.canAdd(vOut) { reader.add(vOut) }
                let hint = try await vTrack.load(.formatDescriptions).first
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
                vIn.expectsMediaDataInRealTime = false
                if writer.canAdd(vIn) { writer.add(vIn) }
                videoPair = (vOut, vIn)
            }

            // Audio: mix all tracks down to one PCM stream, then re-encode to a single AAC track.
            let pcm: [String: Any] = [
                AVFormatIDKey:             kAudioFormatLinearPCM,
                AVSampleRateKey:           44100,
                AVNumberOfChannelsKey:     2,
                AVLinearPCMBitDepthKey:    16,
                AVLinearPCMIsFloatKey:     false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let mixOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            mixOut.alwaysCopiesSampleData = false
            if reader.canAdd(mixOut) { reader.add(mixOut) }

            let aac: [String: Any] = [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey:   128_000,   // matches RecordingConfig.audioBitrate
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) { writer.add(aIn) }

            guard reader.startReading(), writer.startWriting() else {
                throw reader.error ?? writer.error ?? ExportError.sessionCreationFailed
            }
            writer.startSession(atSourceTime: .zero)

            await withTaskGroup(of: Void.self) { group in
                if let (vOut, vIn) = videoPair {
                    group.addTask { await pump(vOut, into: vIn, label: "flat.video") }
                }
                group.addTask { await pump(mixOut, into: aIn, label: "flat.audio") }
            }

            guard reader.status == .completed else {
                throw reader.error ?? ExportError.sessionCreationFailed
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? ExportError.sessionCreationFailed
            }

            // Atomically swap the flattened file in for the original (same name/URL). Using
            // replaceItemAt avoids a window where the original is deleted but the new file
            // isn't in place yet — so a failure here can't lose the recording.
            _ = try FileManager.default.replaceItemAt(inputURL, withItemAt: outURL)
            return inputURL
        } catch {
            NSLog("ERROR: audio flatten failed (%@) — keeping original two-track file: %@",
                  inputURL.lastPathComponent, String(describing: error))
            return inputURL
        }
    }

    /// Drains one reader output into one writer input on a dedicated queue.
    private static func pump(_ output: AVAssetReaderOutput,
                             into input: AVAssetWriterInput,
                             label: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "com.coachcap.\(label)")
            var resumed = false
            func finish() {
                input.markAsFinished()
                if !resumed { resumed = true; cont.resume() }
            }
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else { finish(); return }
                    if !input.append(sb) { finish(); return }   // writer failed; stop feeding it
                }
            }
        }
    }
}

enum ExportError: LocalizedError {
    case sessionCreationFailed
    var errorDescription: String? { "Could not create export session." }
}
