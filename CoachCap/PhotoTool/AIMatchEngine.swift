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

/// On-device pose matching (Vision, no API key / network).
///
/// Accuracy comes from matching *body shape*, not pixels:
///  • The body is located via `VNDetectHumanBodyPoseRequest` and the image is cropped to it,
///    so background, framing and zoom stop dominating the comparison.
///  • A translation/scale-normalised pose descriptor (joint positions relative to the torso)
///    is the primary signal — the same pose pairs even if the person stands elsewhere in frame.
///  • Orientation (front / back / side) gates matches so a front shot won't pair with a side.
///  • A lighting-tolerant cosine distance over a cropped greyscale fingerprint is a secondary
///    tie-breaker for when pose data is weak.
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
        var fingerprint: [Float]      // cropped, mean-subtracted greyscale (cosine-compared)
        var pose:        [Float]      // normalised joint coords, NaN where the joint is missing
        var poseJoints:  Int          // how many joints were confidently detected
        var orientation: String       // Front / Back / Side / Photo
        static let empty = ImageData(fingerprint: [], pose: [], poseJoints: 0, orientation: "Photo")
    }

    /// Joints used for the normalised pose descriptor (order is fixed so vectors line up).
    private static let descriptorJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle
    ]

    private static func analyse(_ url: URL) -> ImageData {
        guard let cg = loadThumbnail(url) else { return .empty }

        // 1) Detect the body pose.
        let poseReq = VNDetectHumanBodyPoseRequest()
        let faceReq = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([poseReq, faceReq])
        let obs = poseReq.results?.first

        // 2) Collect confident joint locations (Vision coords: normalised, bottom-left origin).
        var raw: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        if let obs {
            for j in descriptorJoints {
                if let p = try? obs.recognizedPoint(j), p.confidence > 0.15 {
                    raw[j] = p.location
                }
            }
        }

        let (poseVec, jointCount) = normalisedPose(raw)
        let orientation = orientationLabel(raw, hasFace: faceReq.results?.isEmpty == false)

        // 3) Crop to the body (with padding) so the fingerprint isn't all background, then
        //    reduce to a normalised greyscale vector.
        let cropped = cropToBody(cg, joints: raw) ?? cg
        let fp = fingerprint(cropped)

        return ImageData(fingerprint: fp, pose: poseVec, poseJoints: jointCount, orientation: orientation)
    }

    /// Centre joints on the torso and scale by torso size → translation/scale invariant.
    /// Returns a vector of length `2 * descriptorJoints.count`; missing joints are `NaN`.
    private static func normalisedPose(_ raw: [VNHumanBodyPoseObservation.JointName: CGPoint])
        -> (vector: [Float], jointCount: Int) {

        func mid(_ a: VNHumanBodyPoseObservation.JointName,
                 _ b: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = raw[a], let q = raw[b] else { return nil }
            return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        }

        let shoulderMid = mid(.leftShoulder, .rightShoulder)
        let hipMid      = mid(.leftHip, .rightHip)

        // Centre: hip-mid preferred, else shoulder-mid, else centroid of everything.
        let center: CGPoint
        if let h = hipMid { center = h }
        else if let s = shoulderMid { center = s }
        else if !raw.isEmpty {
            let sx = raw.values.reduce(0) { $0 + $1.x }, sy = raw.values.reduce(0) { $0 + $1.y }
            center = CGPoint(x: sx / CGFloat(raw.count), y: sy / CGFloat(raw.count))
        } else {
            return (Array(repeating: Float.nan, count: descriptorJoints.count * 2), 0)
        }

        // Scale: torso length (shoulder→hip) preferred, else shoulder width, else a fallback.
        var scale: CGFloat = 0
        if let s = shoulderMid, let h = hipMid { scale = hypot(s.x - h.x, s.y - h.y) }
        if scale < 0.02, let l = raw[.leftShoulder], let r = raw[.rightShoulder] {
            scale = hypot(l.x - r.x, l.y - r.y)
        }
        if scale < 0.02 { scale = 0.25 }

        var vec = [Float](); vec.reserveCapacity(descriptorJoints.count * 2)
        var count = 0
        for j in descriptorJoints {
            if let p = raw[j] {
                vec.append(Float((p.x - center.x) / scale))
                vec.append(Float((p.y - center.y) / scale))
                count += 1
            } else {
                vec.append(.nan); vec.append(.nan)
            }
        }
        return (vec, count)
    }

    /// Front / Back / Side from shoulder spread + face presence.
    private static func orientationLabel(_ raw: [VNHumanBodyPoseObservation.JointName: CGPoint],
                                         hasFace: Bool) -> String {
        if let ls = raw[.leftShoulder], let rs = raw[.rightShoulder] {
            return abs(rs.x - ls.x) > 0.08 ? (hasFace ? "Front" : "Back") : "Side"
        }
        return hasFace ? "Front" : "Photo"
    }

    /// Crop the image to the bounding box of the detected joints (15% padding). Vision joints
    /// are normalised with a bottom-left origin; CGImage cropping is top-left, hence the flip.
    private static func cropToBody(_ cg: CGImage,
                                   joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGImage? {
        guard joints.count >= 3 else { return nil }
        let xs = joints.values.map { $0.x }, ys = joints.values.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let padX = (maxX - minX) * 0.18 + 0.04
        let padY = (maxY - minY) * 0.18 + 0.04
        let x0 = max(0, minX - padX), x1 = min(1, maxX + padX)
        let y0 = max(0, minY - padY), y1 = min(1, maxY + padY)

        // Flip Y for top-left CGImage space.
        let rect = CGRect(x: x0 * w,
                          y: (1 - y1) * h,
                          width:  (x1 - x0) * w,
                          height: (y1 - y0) * h).integral
        guard rect.width > 8, rect.height > 8 else { return nil }
        return cg.cropping(to: rect)
    }

    /// 48×48 greyscale, mean-subtracted so cosine distance ignores overall brightness.
    private static func fingerprint(_ src: CGImage) -> [Float] {
        let size = 48
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))

        var out = [Float](); out.reserveCapacity(size * size)
        stride(from: 0, to: pixels.count, by: 4).forEach { i in
            // Rec. 601 luma
            let g = 0.299 * Float(pixels[i]) + 0.587 * Float(pixels[i + 1]) + 0.114 * Float(pixels[i + 2])
            out.append(g)
        }
        // Mean-subtract (cosine distance handles the rest).
        let mean = out.reduce(0, +) / Float(out.count)
        for i in out.indices { out[i] -= mean }
        return out
    }

    // MARK: - Matching

    private static func greedyMatch(left: [ImageData], right: [ImageData]) -> [PoseMatch] {
        var usedRight = Set<Int>()
        var matches:  [PoseMatch] = []

        for (li, ld) in left.enumerated() {
            var bestCost = Float.infinity
            var bestRI   = -1

            for (ri, rd) in right.enumerated() where !usedRight.contains(ri) {
                let cost = pairCost(ld, rd)
                if cost < bestCost { bestCost = cost; bestRI = ri }
            }

            if bestRI >= 0 {
                let label = ld.orientation != "Photo" ? ld.orientation : right[bestRI].orientation
                matches.append(PoseMatch(leftIndex: li, rightIndex: bestRI, pose: label))
                usedRight.insert(bestRI)
            }
        }
        return matches
    }

    /// Lower = more similar. Pose-led, with a visual tie-breaker and an orientation penalty.
    private static func pairCost(_ a: ImageData, _ b: ImageData) -> Float {
        let pose = poseDistance(a.pose, b.pose)          // normalised torso units, or NaN
        let vis  = cosineDistance(a.fingerprint, b.fingerprint)  // 0…2

        var cost: Float
        if let pose, a.poseJoints >= 4, b.poseJoints >= 4 {
            cost = pose * 0.7 + vis * 0.3                // trust the body shape
        } else {
            cost = vis + 0.3                             // weak/absent pose → visual only, slight penalty
        }

        // Don't pair across orientations (front vs side vs back) when both are confident.
        if a.orientation != "Photo", b.orientation != "Photo", a.orientation != b.orientation {
            cost += 0.6
        }
        return cost
    }

    /// Mean joint displacement over joints present in *both* poses. `nil` if too little overlap.
    private static func poseDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0, n = 0
        var i = 0
        while i < a.count {
            let ax = a[i], ay = a[i + 1], bx = b[i], by = b[i + 1]
            if ax.isFinite, ay.isFinite, bx.isFinite, by.isFinite {
                sum += sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
                n += 1
            }
            i += 2
        }
        guard n >= 4 else { return nil }
        return sum / Float(n)
    }

    /// 1 − cosine similarity (0 = identical direction, 2 = opposite). Brightness-invariant.
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (sqrt(na) * sqrt(nb))
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
