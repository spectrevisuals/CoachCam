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
}

enum ExportError: LocalizedError {
    case sessionCreationFailed
    var errorDescription: String? { "Could not create export session." }
}
