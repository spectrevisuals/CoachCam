import Foundation

struct License {
    let key: String
    let isValid: Bool
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
        let isValid = isValidKeyFormat(key)
        let license = License(key: key, isValid: isValid)
        self.license = license
        self.isUnlocked = isValid
        if isValid {
            defaults.set(key, forKey: licenseKey)
        }
    }

    func removeLicense() {
        defaults.removeObject(forKey: licenseKey)
        license = nil
        isUnlocked = false
    }

    // MARK: License validation

    private func isValidKeyFormat(_ key: String) -> Bool {
        // Simple format: COACH-XXXXXXXXXX (at least 10 chars after COACH-)
        let parts = key.uppercased().split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0] == "COACH" else {
            return false
        }
        let keyPart = String(parts[1])
        return keyPart.count >= 10 && keyPart.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Key generation

    static func generateLicenseKey() -> String {
        let random = (0..<12).map { _ in String("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!) }.joined()
        return "COACH-\(random)"
    }
}
