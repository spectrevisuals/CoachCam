import SwiftUI

struct LicenseView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var keyInput = ""

    var body: some View {
        VStack(spacing: 12) {
            if licenseManager.isUnlocked {
                activeBox
            } else {
                trialBox
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Active

    private var activeBox: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(licenseManager.onGrace ? "License Active (offline)" : "License Active")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await licenseManager.deactivateDevice() }
                } label: {
                    if licenseManager.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Deactivate this device")
                    }
                }
                .font(.caption)
                .disabled(licenseManager.isWorking)
                .help("Free this Mac's activation so the key can be used on another Mac.")
            }
            if licenseManager.onGrace {
                Text("Running offline. Connect to the internet occasionally to keep your license verified.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !licenseManager.statusMessage.isEmpty {
                Text(licenseManager.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.green.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: Trial / activation

    private var trialBox: some View {
        VStack(spacing: 8) {
            Text("Free Trial: 120 seconds per recording")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                TextField("License key", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(licenseManager.isWorking)
                    .onSubmit(activate)
                Button {
                    activate()
                } label: {
                    if licenseManager.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Activate")
                    }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || licenseManager.isWorking)
            }
            if !licenseManager.statusMessage.isEmpty {
                Text(licenseManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private func activate() {
        let key = keyInput
        Task {
            await licenseManager.activate(key: key)
            if licenseManager.isUnlocked { keyInput = "" }
        }
    }
}
