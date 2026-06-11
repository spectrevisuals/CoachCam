import Foundation

struct License {
    let key: String
    let isValid: Bool
    let expiresAt: Date?
    let isTestKey: Bool
}

@MainActor
final class LicenseManager: ObservableObject {
    @Published var license: License?
    @Published var isUnlocked: Bool = false

    private let defaults = UserDefaults.standard
    private let licenseKey = "coachcam.license.key"

    init() {
        loadLicense()
    }

    func loadLicense() {
        if let savedKey = defaults.string(forKey: licenseKey) {
            validateLicense(key: savedKey)
        }
    }

    func validateLicense(key: String) {
        let license = checkLicenseValidity(key)
        self.license = license
        self.isUnlocked = license.isValid
        if license.isValid {
            defaults.set(key, forKey: licenseKey)
        }
    }

    func removeLicense() {
        defaults.removeObject(forKey: licenseKey)
        license = nil
        isUnlocked = false
    }

    // MARK: License validation

    private func checkLicenseValidity(_ key: String) -> License {
        // Test keys: start with "TEST-"
        if key.uppercased().hasPrefix("TEST-") {
            return License(key: key, isValid: true, expiresAt: nil, isTestKey: true)
        }

        // Real keys: format "COACHCAM-XXXXXXXX-XXXXXXXX"
        // For now, validate format. Later: verify against Stripe/backend
        let parts = key.uppercased().split(separator: "-")
        if parts.count == 3 && parts[0] == "COACHCAM" {
            // Placeholder validation — will check Stripe later
            return License(key: key, isValid: true, expiresAt: nil, isTestKey: false)
        }

        return License(key: key, isValid: false, expiresAt: nil, isTestKey: false)
    }

    // MARK: Test key generation (for you to give to testers)

    static func generateTestKey() -> String {
        let uuid = UUID().uuidString.prefix(8).uppercased()
        return "TEST-\(uuid)"
    }
}
