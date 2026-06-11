import AppKit
import Vision
import CoreGraphics

// MARK: - Types

struct PoseMatch {
    let leftIndex:  Int
    let rightIndex: Int
    let pose:       String
}

enum AIMatchError: LocalizedError {
    case tooFewPhotos
    var errorDescription: String? { "Load at least one photo on each side first." }
}

// MARK: - Engine

/// On-device pose matching using visual similarity.
///
/// Each image is reduced to a 32×32 greyscale fingerprint (1024 floats).
/// Greedy nearest-neighbour pairing finds the most visually similar match
/// across both sets — front naturally pairs with front, side with side, etc.
/// No API key, no network, no model download required.
final class AIMatchEngine {
    static let shared = AIMatchEngine()

    private static let queue = DispatchQueue(
        label: "coachcap.ai.match",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Public

    func matchPoses(leftURLs: [URL], rightURLs: [URL]) async throws -> [PoseMatch] {
        guard !leftURLs.isEmpty, !rightURLs.isEmpty else { throw AIMatchError.tooFewPhotos }

        return await withCheckedContinuation { continuation in
            Self.queue.async {
                var leftData  = Array(repeating: ImageData.empty, count: leftURLs.count)
                var rightData = Array(repeating: ImageData.empty, count: rightURLs.count)

                let dg   = DispatchGroup()
                let lock = NSLock()

                for (i, url) in leftURLs.enumerated() {
                    dg.enter()
                    Self.queue.async {
                        let d = Self.analyse(url)
                        lock.lock(); leftData[i] = d; lock.unlock()
                        dg.leave()
                    }
                }
                for (i, url) in rightURLs.enumerated() {
                    dg.enter()
                    Self.queue.async {
                        let d = Self.analyse(url)
                        lock.lock(); rightData[i] = d; lock.unlock()
                        dg.leave()
                    }
                }
                dg.wait()

                continuation.resume(returning: Self.greedyMatch(left: leftData, right: rightData))
            }
        }
    }

    // MARK: - Per-image analysis

    private struct ImageData {
        var fingerprint: [Float]   // 32×32 greyscale pixel vector
        var poseLabel:   String
        static let empty = ImageData(fingerprint: [], poseLabel: "Photo")
    }

    private static func analyse(_ url: URL) -> ImageData {
        guard let cg = loadThumbnail(url) else { return .empty }

        let fp    = fingerprint(cg)
        let label = poseLabel(cg)
        return ImageData(fingerprint: fp, poseLabel: label)
    }

    /// Shrink to 128×128 RGBA and return R+G+B channels as floats (3×16384 values).
    /// Colour gives 3× the signal vs greyscale for distinguishing poses.
    private static func fingerprint(_ src: CGImage) -> [Float] {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4) // RGBA
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))
        // Interleaved RGBA → extract R, G, B (skip A)
        var out = [Float](); out.reserveCapacity(size * size * 3)
        stride(from: 0, to: pixels.count, by: 4).forEach { i in
            out.append(Float(pixels[i]))     // R
            out.append(Float(pixels[i + 1])) // G
            out.append(Float(pixels[i + 2])) // B
        }
        return out
    }

    /// Best-effort pose label for the toolbar badge (Front / Back / Side).
    private static func poseLabel(_ cg: CGImage) -> String {
        let faceReq = VNDetectFaceRectanglesRequest()
        let poseReq = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([faceReq, poseReq])

        let hasFace = faceReq.results?.isEmpty == false

        if let obs = poseReq.results?.first {
            func pt(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let p = try? obs.recognizedPoint(j), p.confidence > 0.2 else { return nil }
                return p.location
            }
            if let ls = pt(.leftShoulder), let rs = pt(.rightShoulder) {
                return abs(rs.x - ls.x) > 0.08 ? (hasFace ? "Front" : "Back") : "Side"
            }
        }
        return hasFace ? "Front" : "Photo"
    }

    // MARK: - Greedy nearest-neighbour matching

    private static func greedyMatch(left: [ImageData], right: [ImageData]) -> [PoseMatch] {
        var usedRight = Set<Int>()
        var matches:  [PoseMatch] = []

        for (li, ld) in left.enumerated() {
            var bestDist = Float.infinity
            var bestRI   = -1

            for (ri, rd) in right.enumerated() {
                guard !usedRight.contains(ri) else { continue }

                if !ld.fingerprint.isEmpty && !rd.fingerprint.isEmpty {
                    let dist = l2(ld.fingerprint, rd.fingerprint)
                    if dist < bestDist { bestDist = dist; bestRI = ri }
                } else if bestRI == -1 {
                    bestRI = ri // no fingerprint — fallback to first available
                }
            }

            if bestRI >= 0 {
                let label = ld.poseLabel != "Photo" ? ld.poseLabel : right[bestRI].poseLabel
                matches.append(PoseMatch(leftIndex: li, rightIndex: bestRI, pose: label))
                usedRight.insert(bestRI)
            }
        }

        return matches
    }

    private static func l2(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(Float(0)) { acc, p in let d = p.0 - p.1; return acc + d * d }
    }

    // MARK: - Image loading

    private static func loadThumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
