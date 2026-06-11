import SwiftUI

struct LicenseView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var keyInput = ""
    @State private var showGenerateTestKey = false
    @State private var generatedTestKey = ""

    var body: some View {
        VStack(spacing: 12) {
            if licenseManager.isUnlocked {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(licenseManager.license?.isTestKey == true ? "Test License Active" : "License Active")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Remove") {
                        licenseManager.removeLicense()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                .padding(8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
            } else {
                VStack(spacing: 8) {
                    Text("Free Trial: 120 seconds per recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("License key", text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Activate") {
                            licenseManager.validateLicense(key: keyInput)
                            keyInput = ""
                        }
                        .disabled(keyInput.isEmpty)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            if showGenerateTestKey {
                VStack(spacing: 8) {
                    Text("Generated Test Key:")
                        .font(.caption.weight(.semibold))
                    HStack {
                        Text(generatedTestKey)
                            .font(.system(.caption, design: .monospaced))
                            .selectableText()
                        Button(action: { copyTestKey() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .padding(6)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            // Developer/Testing button (only show if not unlocked)
            if !licenseManager.isUnlocked {
                Button("Generate Test Key") {
                    generatedTestKey = LicenseManager.generateTestKey()
                    showGenerateTestKey = true
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func copyTestKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generatedTestKey, forType: .string)
    }
}

// Helper for selectable text
extension Text {
    func selectableText() -> some View {
        self.textSelection(.enabled)
    }
}
