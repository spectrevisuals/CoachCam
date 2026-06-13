import AppKit
import CoreGraphics

/// A connected monitor the user can choose to record.
struct DisplayOption: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let pixelSize: CGSize        // native pixels

    /// Capture/output size: native aspect ratio, capped to 1920 wide so clips
    /// stay WhatsApp-friendly, with even dimensions (required by H.264).
    var recommendedOutputSize: CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let maxWidth: CGFloat = 1920
        let width = min(pixelSize.width, maxWidth)
        let height = width * pixelSize.height / pixelSize.width
        func even(_ v: CGFloat) -> CGFloat {
            let i = Int(v.rounded())
            return CGFloat(i - (i % 2))
        }
        return CGSize(width: even(width), height: even(height))
    }

    var label: String {
        "\(name)  (\(Int(pixelSize.width))×\(Int(pixelSize.height)))"
    }
}

enum DisplayList {
    /// Connected monitors, primary first. Uses NSScreen so it's synchronous and
    /// gives friendly names; matched to ScreenCaptureKit later via `CGDirectDisplayID`.
    static func available() -> [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let scale = screen.backingScaleFactor
            let px = CGSize(width: screen.frame.width * scale,
                            height: screen.frame.height * scale)
            let name = screen.localizedName.isEmpty ? "Display" : screen.localizedName
            return DisplayOption(id: id, name: name, pixelSize: px)
        }
    }

    /// The chosen display, or the primary if the id is nil/unknown.
    static func option(for id: CGDirectDisplayID?) -> DisplayOption? {
        let all = available()
        if let id, let match = all.first(where: { $0.id == id }) { return match }
        return all.first
    }
}
