import XCTest
import CoreImage
import CoreMedia
import CoreVideo

/// What ends up in a recorded frame, for each mode. The "screen" is solid red and the "camera"
/// is solid green, so every sampled pixel says which source it came from.
final class FrameCompositorTests: XCTestCase {

    private let size = CGSize(width: 640, height: 360)
    private let defaultPiP = CGRect(x: 0.72, y: 0.04, width: 0.24, height: 0.24)

    // MARK: Webcam-only

    func testWebcamOnlyFillsTheWholeFrameWithTheCamera() throws {
        let compositor = FrameCompositor()
        compositor.webcamOnly = true
        let out = try XCTUnwrap(compositor.composite(screenSample: redScreen(),
                                                     cameraBuffer: greenCamera(),
                                                     pipRect: defaultPiP,
                                                     outputSize: size))
        assertCamera(out, x: 320, y: 180, "centre")
        // Square corners: the camera reaches every corner of the frame (no black wedges).
        assertCamera(out, x: 2, y: 2, "top-left corner")
        assertCamera(out, x: 637, y: 2, "top-right corner")
        assertCamera(out, x: 2, y: 357, "bottom-left corner")
        assertCamera(out, x: 637, y: 357, "bottom-right corner")
    }

    func testWebcamOnlyFillsTheFrameWithAFourByThreeCamera() throws {
        let compositor = FrameCompositor()
        compositor.webcamOnly = true
        let out = try XCTUnwrap(compositor.composite(screenSample: redScreen(),
                                                     cameraBuffer: greenCamera(width: 640, height: 480),
                                                     pipRect: defaultPiP,
                                                     outputSize: size))
        for (x, y) in [(320, 180), (2, 2), (637, 2), (2, 357), (637, 357)] {
            assertCamera(out, x: x, y: y, "(\(x), \(y))")
        }
    }

    /// The screen frame is only the clock in this mode: with no camera frame to draw the result
    /// is black, never the desktop. (So the recorder must always hand the camera over here.)
    func testWebcamOnlyNeverShowsTheScreen() throws {
        let compositor = FrameCompositor()
        compositor.webcamOnly = true
        let out = try XCTUnwrap(compositor.composite(screenSample: redScreen(),
                                                     cameraBuffer: nil,
                                                     pipRect: defaultPiP,
                                                     outputSize: size))
        for (x, y) in [(320, 180), (2, 2), (537, 57)] {
            let p = pixel(out, x: x, y: y)
            XCTAssertTrue(p.r < 40 && p.g < 40 && p.b < 40, "(\(x), \(y)) should be black, got \(p)")
        }
    }

    // MARK: Screen recording

    func testScreenModeShowsTheScreenWithARoundedCameraBubble() throws {
        let compositor = FrameCompositor()
        let out = try XCTUnwrap(compositor.composite(screenSample: redScreen(),
                                                     cameraBuffer: greenCamera(),
                                                     pipRect: defaultPiP,
                                                     outputSize: size))
        assertScreen(out, x: 320, y: 180, "centre")
        assertScreen(out, x: 2, y: 2, "top-left corner")
        // The bubble covers x 460.8…614.4, y 14.4…100.8 (top-left origin).
        assertCamera(out, x: 537, y: 57, "middle of the camera bubble")
        // Just inside the bubble's own corner: cut away by the rounding, so the screen shows.
        assertScreen(out, x: 462, y: 16, "rounded-off corner of the bubble")
    }

    /// The float cam case in a screen recording: the recorder withholds the camera (the float
    /// cam window is itself on screen), so the frame is the screen and nothing else.
    func testScreenModeWithoutACameraFrameIsJustTheScreen() throws {
        let compositor = FrameCompositor()
        let out = try XCTUnwrap(compositor.composite(screenSample: redScreen(),
                                                     cameraBuffer: nil,
                                                     pipRect: defaultPiP,
                                                     outputSize: size))
        assertScreen(out, x: 320, y: 180, "centre")
        assertScreen(out, x: 537, y: 57, "where the camera bubble would be")
    }

    // MARK: Helpers

    private func redScreen() -> CMSampleBuffer {
        sampleBuffer(from: solidBuffer(width: 640, height: 360, r: 255, g: 0, b: 0))
    }

    private func greenCamera(width: Int = 1280, height: Int = 720) -> CVPixelBuffer {
        solidBuffer(width: width, height: height, r: 0, g: 255, b: 0)
    }

    private func assertCamera(_ buffer: CVPixelBuffer, x: Int, y: Int, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let p = pixel(buffer, x: x, y: y)
        XCTAssertTrue(p.g > 150 && p.r < 100, "\(what) should be the camera (green), got \(p)",
                      file: file, line: line)
    }

    private func assertScreen(_ buffer: CVPixelBuffer, x: Int, y: Int, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let p = pixel(buffer, x: x, y: y)
        XCTAssertTrue(p.r > 150 && p.g < 100, "\(what) should be the screen (red), got \(p)",
                      file: file, line: line)
    }

    private func solidBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                row[x * 4] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func sampleBuffer(from buffer: CVPixelBuffer) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// One pixel of a 32BGRA buffer; (0, 0) is the top-left of the picture.
    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }
}
