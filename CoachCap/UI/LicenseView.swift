import SwiftUI

struct LicenseView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var keyInput = ""
    @State private var validationError = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            if licenseManager.isUnlocked {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("License Active")
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
                            if licenseManager.isUnlocked {
                                keyInput = ""
                                alertMessage = "License activated!"
                                showAlert = true
                            } else {
                                alertMessage = "Invalid license key"
                                showAlert = true
                            }
                        }
                        .disabled(keyInput.isEmpty)
                    }
                    if !validationError.isEmpty {
                        Text(validationError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert("License", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
}

// Helper for selectable text
extension Text {
    func selectableText() -> some View {
        self.textSelection(.enabled)
    }
}
