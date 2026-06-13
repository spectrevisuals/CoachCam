import Foundation
import CryptoKit

struct License {
    let key: String
    let isValid: Bool
    let coachName: String
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
        let hardwareID = getHardwareID()

        // Format: COACH-[coachname]-[hwid-signature]
        let parts = key.uppercased().split(separator: "-", maxSplits: 2)

        guard parts.count == 3, parts[0] == "COACH" else {
            return License(key: key, isValid: false, coachName: "", isTestKey: false)
        }

        let coachName = String(parts[1])
        let signature = String(parts[2])

        // Verify signature matches this Mac's hardware ID
        let expectedSig = LicenseManager.generateSignature(coachName: coachName, hardwareID: hardwareID)

        if signature == expectedSig {
            return License(key: key, isValid: true, coachName: coachName, isTestKey: false)
        }

        return License(key: key, isValid: false, coachName: "", isTestKey: false)
    }

    // MARK: Hardware ID

    private func getHardwareID() -> String {
        // Use Mac serial number (unique per machine)
        if let serial = getMacSerialNumber() {
            return serial
        }
        // Fallback to MAC address
        return getMacAddress()
    }

    private func getMacSerialNumber() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hardware = json["SPHardwareDataType"] as? [[String: Any]],
           let serial = hardware.first?["serial_number"] as? String {
            return serial
        }
        return nil
    }

    private func getMacAddress() -> String {
        // Fallback: use a combination of hostname + model
        let model = ProcessInfo.processInfo.hostName
        return model.lowercased()
    }

    // MARK: Key generation (for you to create beta keys)

    static func generateLicenseKey(coachName: String, hardwareID: String) -> String {
        let signature = generateSignature(coachName: coachName, hardwareID: hardwareID)
        return "COACH-\(coachName.uppercased())-\(signature)"
    }

    private static func generateSignature(coachName: String, hardwareID: String) -> String {
        let input = "\(coachName)-\(hardwareID)-coachcam-v1"
        let hash = SHA256.hash(data: input.data(using: .utf8) ?? Data())
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined().uppercased()
    }

    static func generateTestKey() -> String {
        let uuid = UUID().uuidString.prefix(8).uppercased()
        return "TEST-\(uuid)"
    }
}
