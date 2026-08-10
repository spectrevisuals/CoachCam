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
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let vTrack = videoTracks.first else { return inputURL }  // nothing we can improve

            // Mix only the audio tracks that actually carry content. A dropped external mic can
            // leave a zero-length track that would break the mixer or add a dead silent track —
            // we skip those, but KEEP both voice and system audio whenever both have samples.
            var validAudio: [AVAssetTrack] = []
            for t in audioTracks {
                if let range = try? await t.load(.timeRange), CMTimeGetSeconds(range.duration) > 0.05 {
                    validAudio.append(t)
                }
            }
            // Nothing to merge or strip (≤1 audio track and none of them empty) — leave as-is.
            if audioTracks.count <= 1 && validAudio.count == audioTracks.count { return inputURL }

            let outURL = inputURL.deletingPathExtension().appendingPathExtension("flat.mp4")
            try? FileManager.default.removeItem(at: outURL)

            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

            // Video: passthrough (nil settings = copy compressed samples, no re-encode).
            let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            vOut.alwaysCopiesSampleData = false
            if reader.canAdd(vOut) { reader.add(vOut) }
            let hint = try await vTrack.load(.formatDescriptions).first
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            vIn.expectsMediaDataInRealTime = false
            if writer.canAdd(vIn) { writer.add(vIn) }

            // Audio: mix the tracks that have content into one AAC track (only if any exist —
            // otherwise we produce video-only rather than fail, but that's the last resort).
            var audioPair: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
            if !validAudio.isEmpty {
                // Preserve the recorded audio rate rather than forcing 44100 — the recorder now
                // writes at the mic's native rate (commonly 48000), so re-encoding at 44100 here
                // would add a needless resample. Fall back to 44100 if the rate can't be read.
                var flatHz: Double = 44100
                if let fmt = try? await validAudio[0].load(.formatDescriptions).first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                    let hz = asbd.pointee.mSampleRate
                    if hz >= 8000, hz <= 192000 { flatHz = hz }
                }
                let pcm: [String: Any] = [
                    AVFormatIDKey:             kAudioFormatLinearPCM,
                    AVSampleRateKey:           flatHz,
                    AVNumberOfChannelsKey:     2,
                    AVLinearPCMBitDepthKey:    16,
                    AVLinearPCMIsFloatKey:     false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let mixOut = AVAssetReaderAudioMixOutput(audioTracks: validAudio, audioSettings: pcm)
                mixOut.alwaysCopiesSampleData = false
                if reader.canAdd(mixOut) { reader.add(mixOut) }
                let aac: [String: Any] = [
                    AVFormatIDKey:         kAudioFormatMPEG4AAC,
                    AVSampleRateKey:       flatHz,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey:   128_000,   // matches RecordingConfig.audioBitrate
                ]
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) { writer.add(aIn) }
                audioPair = (mixOut, aIn)
            }

            guard reader.startReading(), writer.startWriting() else {
                throw reader.error ?? writer.error ?? ExportError.sessionCreationFailed
            }
            writer.startSession(atSourceTime: .zero)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump(vOut, into: vIn, label: "flat.video") }
                if let (mixOut, aIn) = audioPair {
                    group.addTask { await pump(mixOut, into: aIn, label: "flat.audio") }
                }
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
            NSLog("DEBUG: flatten merged \(validAudio.count) audio track(s) of \(audioTracks.count) → \(inputURL.lastPathComponent)")
            return inputURL
        } catch {
            // On ANY failure, keep the original file — it still has video + both audio tracks
            // (just not merged), so we never lose the recording.
            NSLog("ERROR: audio flatten failed (\(inputURL.lastPathComponent)) — keeping original: \(String(describing: error))")
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
