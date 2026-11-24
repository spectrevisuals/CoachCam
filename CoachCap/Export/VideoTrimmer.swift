import AVFoundation
import Foundation

/// Cuts sections OUT of a finished recording and exports the result as a new file.
///
/// Operates purely on the finished MP4 — the recording pipeline is never touched. The export
/// re-encodes via our own AVAssetReader → AVAssetWriter (same pattern as
/// `ExportManager.flattenAudioTracks`) instead of AVAssetExportSession, because the stock
/// presets encode at ~2× our bitrates and would break the "drag straight into WhatsApp"
/// file-size promise. Audio stays AAC 48000/2ch/128k (single track, as flattened).
enum VideoTrimmer {

    enum TrimError: LocalizedError {
        case noVideoTrack, nothingLeft, setupFailed, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack:            return "This file has no video track."
            case .nothingLeft:             return "The cuts remove the whole recording — nothing left to save."
            case .setupFailed:             return "Couldn't start the export. Please try again."
            case .exportFailed(let m):     return "Export failed — \(m)"
            }
        }
    }

    /// Merge overlapping cut ranges and invert them into the KEPT ranges over [0, duration].
    /// Slivers under 0.1 s are dropped (they'd just produce encoder hiccups).
    static func keptRanges(duration: Double, cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        // Clamp BOTH ends into [0, duration] before building ranges — a cut lying entirely
        // outside the video (possible via stale state) must not crash on lower > upper.
        // (Caught by VideoTrimmerTests' randomised invariant sweep.)
        let sorted = cuts
            .map { (lo: min(max(0, $0.lowerBound), duration), hi: min(max(0, $0.upperBound), duration)) }
            .filter { $0.hi > $0.lo }
            .map { $0.lo...$0.hi }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for c in sorted {
            if let last = merged.last, c.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, c.upperBound)
            } else {
                merged.append(c)
            }
        }
        var kept: [ClosedRange<Double>] = []
        var cursor = 0.0
        for c in merged {
            if c.lowerBound - cursor > 0.1 { kept.append(cursor...c.lowerBound) }
            cursor = c.upperBound
        }
        if duration - cursor > 0.1 { kept.append(cursor...duration) }
        return kept
    }

    /// Collision-safe "<base>_edited.mp4" next to the original.
    static func editedOutputURL(for source: URL) -> URL {
        let dir  = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent("\(base)_edited.mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_edited_\(n).mp4")
            n += 1
        }
        return url
    }

    /// Export `source` with `cuts` removed, to `dest`. `progress` is called on an arbitrary
    /// queue with 0…1. Throws TrimError.
    static func export(source: URL, cuts: [ClosedRange<Double>], to dest: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        // Build a composition of the kept ranges, video + (single, flattened) audio in sync.
        let comp = AVMutableComposition()
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw TrimError.noVideoTrack
        }
        // Bound everything by the VIDEO track's end, not the asset's. The mic track can run a
        // few ms past the last video frame (its final buffer lands after capture stops — true
        // of every mic-first/computer-sound-off recording), and inserting a range beyond the
        // video track's end puts an empty video segment in the composition, which the encoder
        // rejects at the tail with a useless -11800/-12905. Found in the field 2026-11-14:
        // every trim that kept the end of such a clip failed with "export failed".
        let videoEnd = try await srcVideo.load(.timeRange).end.seconds
        let duration = min(try await asset.load(.duration).seconds, videoEnd)
        let kept = keptRanges(duration: duration, cuts: cuts)
        guard !kept.isEmpty else { throw TrimError.nothingLeft }
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        guard let compVideo = comp.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw TrimError.setupFailed }
        let compAudio = srcAudio == nil ? nil
            : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertAt = CMTime.zero
        for range in kept {
            let tr = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                 end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            do {
                try compVideo.insertTimeRange(tr, of: srcVideo, at: insertAt)
                if let sa = srcAudio, let ca = compAudio {
                    try ca.insertTimeRange(tr, of: sa, at: insertAt)
                }
            } catch { throw TrimError.setupFailed }
            insertAt = CMTimeAdd(insertAt, tr.duration)
        }
        let totalOut = insertAt.seconds
        let size = try await srcVideo.load(.naturalSize)

        // Reader
        guard let reader = try? AVAssetReader(asset: comp) else { throw TrimError.setupFailed }
        let videoOut = AVAssetReaderTrackOutput(
            track: compVideo,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        var audioOut: AVAssetReaderTrackOutput?
        if let ca = compAudio {
            let out = AVAssetReaderTrackOutput(
                track: ca,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            audioOut = out
        }
        guard reader.canAdd(videoOut) else { throw TrimError.setupFailed }
        reader.add(videoOut)
        if let a = audioOut { guard reader.canAdd(a) else { throw TrimError.setupFailed }; reader.add(a) }

        // Writer — our bitrates, same as fresh recordings.
        try? FileManager.default.removeItem(at: dest)
        guard let writer = try? AVAssetWriter(outputURL: dest, fileType: .mp4) else {
            throw TrimError.setupFailed
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingConfig.videoBitrate(for: size),
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: RecordingConfig.audioBitrate,
            ])
            a.expectsMediaDataInRealTime = false
            audioIn = a
        }
        guard writer.canAdd(videoIn) else { throw TrimError.setupFailed }
        writer.add(videoIn)
        if let a = audioIn { guard writer.canAdd(a) else { throw TrimError.setupFailed }; writer.add(a) }

        guard reader.startReading(), writer.startWriting() else {
            throw TrimError.exportFailed(reader.error?.localizedDescription
                ?? writer.error?.localizedDescription ?? "couldn't start")
        }
        writer.startSession(atSourceTime: .zero)

        // Pump both tracks.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()

            group.enter()
            let vq = DispatchQueue(label: "trim.video")
            videoIn.requestMediaDataWhenReady(on: vq) {
                while videoIn.isReadyForMoreMediaData {
                    if let sample = videoOut.copyNextSampleBuffer() {
                        videoIn.append(sample)
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if totalOut > 0 { progress(min(1, max(0, t / totalOut))) }
                    } else {
                        videoIn.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let aIn = audioIn, let aOut = audioOut {
                group.enter()
                let aq = DispatchQueue(label: "trim.audio")
                aIn.requestMediaDataWhenReady(on: aq) {
                    while aIn.isReadyForMoreMediaData {
                        if let sample = aOut.copyNextSampleBuffer() {
                            aIn.append(sample)
                        } else {
                            aIn.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) { done.resume() }
        }

        // Full NSError detail (domain/code/underlying) in the thrown message — AVFoundation's
        // localizedDescription alone is a useless "The operation could not be completed".
        func detail(_ e: Error?, _ fallback: String) -> String {
            guard let ns = e as NSError? else { return fallback }
            let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " under=\($0.domain)#\($0.code)" } ?? ""
            return "\(ns.localizedDescription) [\(ns.domain)#\(ns.code)\(under)]"
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw TrimError.exportFailed("reading: " + detail(reader.error, "read error"))
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TrimError.exportFailed("writing: " + detail(writer.error, "write error"))
        }
    }
}
