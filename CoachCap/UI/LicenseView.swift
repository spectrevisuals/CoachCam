import SwiftUI

struct LicenseView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var keyInput = ""

    var body: some View {
        if licenseManager.isUnlocked {
            activeBar
        } else {
            trialBox
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: Active — subtle thin indicator

    private var activeBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0x28C840)).frame(width: 7, height: 7)
            Text(licenseManager.onGrace ? "licensed · offline" : "licensed")
                .font(Brand.font(12))
                .foregroundStyle(Brand.muted)
            Spacer()
            if !licenseManager.statusMessage.isEmpty {
                Text(licenseManager.statusMessage.lowercased())
                    .font(Brand.font(11))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
            }
            Button {
                Task { await licenseManager.deactivateDevice() }
            } label: {
                if licenseManager.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("deactivate this device")
                        .font(Brand.font(11))
                        .foregroundStyle(Brand.muted)
                }
            }
            .buttonStyle(.plain)
            .disabled(licenseManager.isWorking)
            .help("Free this Mac's activation so the key can be used on another Mac.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Brand.bg)
    }

    // MARK: Trial / activation

    private var trialBox: some View {
        VStack(spacing: 8) {
            Text("free plan · \(RecordingQuota.remaining()) of \(FreeTier.maxRecordingsPerMonth) recordings left this month · 2-min limit · watermark")
                .font(Brand.font(12))
                .foregroundStyle(Brand.muted)
            HStack(spacing: 10) {
                TextField("license key", text: $keyInput)
                    .textFieldStyle(.plain)
                    .font(Brand.font(13))
                    .foregroundStyle(Brand.text)
                    .brandPill()
                    .disabled(licenseManager.isWorking)
                    .onSubmit(activate)
                Button {
                    activate()
                } label: {
                    if licenseManager.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("activate")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || licenseManager.isWorking)
            }
            if !licenseManager.statusMessage.isEmpty {
                Text(licenseManager.statusMessage)
                    .font(Brand.font(12))
                    .foregroundStyle(Brand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func activate() {
        let key = keyInput
        Task {
            await licenseManager.activate(key: key)
            if licenseManager.isUnlocked { keyInput = "" }
        }
    }
}
