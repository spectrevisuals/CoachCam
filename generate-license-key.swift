#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("Usage: swift generate-license-key.swift <coach-name> [count]")
    print("Example: swift generate-license-key.swift \"John Smith\"")
    print("         swift generate-license-key.swift \"John Smith\" 5  (generate 5 keys)")
    exit(1)
}

let coachName = CommandLine.arguments[1]
let count = CommandLine.arguments.count >= 3 ? Int(CommandLine.arguments[2]) ?? 1 : 1

func generateKey() -> String {
    let random = (0..<12).map { _ in String("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!) }.joined()
    return "COACH-\(random)"
}

print("\n✓ License key(s) generated for: \(coachName)")
print("📋 License Key\(count > 1 ? "s" : ""):")
for _ in 1...count {
    print(generateKey())
}
print("\nShare these key\(count > 1 ? "s" : "") with \(coachName) to unlock CoachCam.\n")
