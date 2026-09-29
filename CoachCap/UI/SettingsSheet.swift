import SwiftUI
import AppKit

/// Settings — opened from the ⚙ button in the top bar. Lives in a SHEET (its own window),
/// so nothing here can affect the main window's content size (see the windowResizability
/// foot-gun: conditional fixed-width UI in the main window resizes the whole window).
struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var branding = BrandingStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Brand.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    backupSection
                    brandingSection
                }
                .padding(22)
            }
            Divider().overlay(Brand.border)
            HStack {
                Spacer()
                Button("done") { isPresented = false }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(14)
        }
        .frame(width: 520, height: 560)
        .onAppear { Analytics.track("settings_opened") }
        .background(Brand.bg)
        .brandTheme()
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.accentBorder, lineWidth: 1))
                    .frame(width: 44, height: 44)
                Image(systemName: "gearshape").font(.system(size: 19)).foregroundStyle(Brand.accent2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("settings").font(Brand.font(19, .bold)).foregroundStyle(Brand.text)
                Text("backups & your branding").font(Brand.font(12)).foregroundStyle(Brand.muted)
            }
            Spacer()
        }
        .padding(18)
    }

    // MARK: Backup

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "externaldrive.badge.icloud", title: "back up recordings")
            Text("every finished recording is also copied to this folder. point it at **iCloud Drive** (nothing to install), or a **Google Drive / Dropbox** folder, and your check-ins upload themselves — your storage, kept as long as you need.")
                .font(Brand.body(12.5)).foregroundStyle(Brand.text.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: branding.backupFolderPath.isEmpty ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(branding.backupFolderPath.isEmpty ? Brand.muted : Brand.accent)
                Text(branding.backupFolderPath.isEmpty
                     ? "backups off"
                     : (branding.backupFolderPath as NSString).abbreviatingWithTildeInPath)
                    .font(Brand.font(12)).foregroundStyle(Brand.text.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("choose folder…") { chooseBackupFolder() }.buttonStyle(OutlineButtonStyle())
                if !branding.backupFolderPath.isEmpty {
                    Button("turn off") { branding.backupFolderPath = "" }.buttonStyle(LinkButtonStyle())
                }
            }
            Text("using dropbox? turn on *selective sync* in its settings so it doesn't download your whole account to this Mac.")
                .font(Brand.font(11)).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    // MARK: Branding

    private var brandingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "paintpalette", title: "your branding")
            Text("your logo and colours appear on what **clients** see — the logo on recordings, and logo + colours on exported before/after photos.")
                .font(Brand.body(12.5)).foregroundStyle(Brand.text.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            // Logo row
            HStack(spacing: 12) {
                Group {
                    if let logo = branding.logoImage {
                        Image(nsImage: logo).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20)).foregroundStyle(Brand.muted)
                    }
                }
                .frame(width: 72, height: 48)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.control))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Brand.controlBorder, lineWidth: 1))

                Button(branding.logoImage == nil ? "upload logo…" : "replace logo…") { chooseLogo() }
                    .buttonStyle(OutlineButtonStyle())
                if branding.logoImage != nil {
                    Button("remove") { branding.removeLogo() }.buttonStyle(LinkButtonStyle())
                }
                Spacer()
            }
            Text("tip: a PNG with a transparent background looks best on video.")
                .font(Brand.font(11)).foregroundStyle(Brand.muted)

            Toggle(isOn: $branding.showLogoOnRecordings) {
                Text("show my logo on recordings").font(Brand.font(13))
            }
            .toggleStyle(.checkbox)
            .disabled(branding.logoImage == nil)

            Divider().overlay(Brand.border)

            // Colours
            HStack(spacing: 18) {
                colorRow(label: "primary colour", hex: $branding.primaryHex)
                colorRow(label: "secondary colour", hex: $branding.secondaryHex)
                colorRow(label: "float cam ring", hex: $branding.ringHex)
                Spacer()
            }
            Text("primary tints the float cam & photo dividers, secondary is the header band behind the client's name on exports. the float cam's ring follows primary unless you give it its own colour.")
                .font(Brand.font(11)).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func colorRow(label: String, hex: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hexString: hex.wrappedValue) ?? .gray) },
                set: { hex.wrappedValue = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(Brand.font(12)).foregroundStyle(Brand.text.opacity(0.85))
                if NSColor(hexString: hex.wrappedValue) != nil {
                    Button("clear") { hex.wrappedValue = "" }.buttonStyle(LinkButtonStyle())
                } else {
                    Text("not set").font(Brand.font(11)).foregroundStyle(Brand.muted)
                }
            }
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Brand.accent2).frame(width: 20)
            Text(title).font(Brand.font(15, .bold)).foregroundStyle(Brand.text)
        }
    }

    // MARK: Panels

    private func chooseBackupFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Use this folder"
        p.message = "Recordings will also be copied here (e.g. a folder in iCloud Drive, Google Drive or Dropbox)."
        if p.runModal() == .OK, let url = p.url {
            branding.backupFolderPath = url.path
        }
    }

    private func chooseLogo() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        p.message = "Choose your business logo (PNG with transparency looks best)."
        if p.runModal() == .OK, let url = p.url {
            branding.setLogo(from: url)
        }
    }
}
