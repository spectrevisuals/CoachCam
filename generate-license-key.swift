#!/usr/bin/env swift

import Foundation
import CryptoKit

// Usage: swift generate-license-key.swift "Coach Name" "SERIALNUMBER123ABC"
// or:    swift generate-license-key.swift "Coach Name" (will auto-detect your Mac's serial)

guard CommandLine.arguments.count >= 2 else {
    print("Usage: swift generate-license-key.swift <coach-name> [hardware-id]")
    print("Example: swift generate-license-key.swift \"John Smith\" \"SERIALNUMBER123\"")
    print("         swift generate-license-key.swift \"Jane Coach\" (auto-detects your Mac)")
    exit(1)
}

let coachName = CommandLine.arguments[1]
let hardwareID: String

if CommandLine.arguments.count >= 3 {
    hardwareID = CommandLine.arguments[2]
} else {
    // Auto-detect Mac serial number
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
        hardwareID = serial
        print("Auto-detected hardware ID: \(serial)")
    } else {
        print("Error: Could not auto-detect hardware ID. Please provide it manually.")
        exit(1)
    }
}

func generateSignature(coachName: String, hardwareID: String) -> String {
    let input = "\(coachName)-\(hardwareID)-coachcam-v1"
    let hash = SHA256.hash(data: input.data(using: .utf8) ?? Data())
    return hash.prefix(12).map { String(format: "%02x", $0) }.joined().uppercased()
}

let signature = generateSignature(coachName: coachName, hardwareID: hardwareID)
let licenseKey = "COACH-\(coachName.uppercased())-\(signature)"

print("\n✓ License key generated for: \(coachName)")
print("Hardware ID: \(hardwareID)")
print("\n📋 License Key:")
print(licenseKey)
print("\nShare this key with \(coachName) to unlock CoachCam.\n")
