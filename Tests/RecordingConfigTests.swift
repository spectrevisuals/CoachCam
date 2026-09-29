import XCTest

/// Bitrate tiers are the WhatsApp-file-size promise (~30 MB/min ceiling). If these drift,
/// clips stop fitting in chats.
final class RecordingConfigTests: XCTestCase {
    func testBitrateTiers() {
        XCTAssertEqual(RecordingConfig.videoBitrate(for: CGSize(width: 1920, height: 1080)), 4_000_000)
        XCTAssertEqual(RecordingConfig.videoBitrate(for: CGSize(width: 2560, height: 1440)), 4_000_000)
        XCTAssertEqual(RecordingConfig.videoBitrate(for: CGSize(width: 1280, height: 720)), 2_500_000)
        XCTAssertEqual(RecordingConfig.videoBitrate(for: CGSize(width: 640, height: 480)), 1_500_000)
    }

    func testAudioBitrateIsWhatsAppFriendly() {
        XCTAssertEqual(RecordingConfig.audioBitrate, 128_000)
    }
}
