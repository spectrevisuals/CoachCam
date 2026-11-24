import Foundation
import IOKit

/// Stable, unique-per-Mac identifier.
///
/// Its only use today is crash and error reporting: `Telemetry.start()` sends the FIRST
/// 8 CHARACTERS as the anonymous user id on every Sentry event, so reports from one Mac can
/// be told apart from another's. Events carry no other identity: no name, e-mail address or
/// licence key, and the hardware-derived `device_app_hash` that the SDK adds by itself is
/// removed before an event is sent. The full value never leaves the Mac.
///
/// One thing is outside that rule. The SDK's release-health session updates (they count
/// launches and crashes; they are not events) carry a random per-install id that the SDK
/// makes up and keeps in its cache folder. It is not derived from this value or from any
/// hardware, and it cannot be changed from the app.
///
/// It is no longer part of licensing. It was introduced as the Lemon Squeezy
/// `instance_name` (one activation per Mac); licensing has since moved to Polar, which
/// labels an activation with the computer's name instead (`LicenseManager.activate`), and
/// nothing calls the Lemon Squeezy activate endpoint any more.
///
/// The value must be identical across launches and reinstalls on the same Mac, and
/// different on every other Mac. We read `IOPlatformUUID` from `IOPlatformExpertDevice`,
/// which satisfies all three.
enum DeviceIdentity {

    /// Cached for the process lifetime. `IOPlatformUUID` is itself stable, so
    /// recomputing would return the same value — this just avoids the IOKit
    /// round-trip on repeated reads.
    static let hardwareUUID: String = {
        if let uuid = platformUUID() {
            return uuid
        }
        // IOKit should always succeed on real hardware. As an absolute last
        // resort, persist a UUID in the Keychain (survives app reinstall) so
        // the value is still stable on this machine — never random per launch.
        return persistedFallback()
    }()

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String,
        !cf.isEmpty else {
            return nil
        }
        return cf
    }

    private static func persistedFallback() -> String {
        let account = "device_fallback_id"
        if let existing = Keychain.get(account) {
            return existing
        }
        let generated = UUID().uuidString
        Keychain.set(generated, for: account)
        return generated
    }
}
