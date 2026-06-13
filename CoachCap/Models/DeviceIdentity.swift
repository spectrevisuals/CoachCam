import Foundation
import IOKit

/// Stable, unique-per-Mac identifier used as the Lemon Squeezy `instance_name`.
///
/// The anti-sharing guarantee depends on this being the machine's hardware ID:
/// it must be identical across launches and reinstalls on the same Mac, and
/// different on every other Mac. We read `IOPlatformUUID` from
/// `IOPlatformExpertDevice`, which satisfies all three.
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
