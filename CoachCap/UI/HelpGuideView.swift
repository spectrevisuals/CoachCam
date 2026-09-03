import SwiftUI
import AppKit

/// The in-app "how it works" guide. One scrollable, brand-styled sheet reachable from the
/// "?" button in the top bar, and shown automatically the very first launch (see the
/// `hasSeenGuide` flag in ContentView). Deliberately a single panel — not a multi-step tour —
/// to fit CoachCam's one-window, big-button feel. Covers only the spots people actually get
/// stuck on: the smart-match keys, and the two permissions (Screen Recording + Full Disk
/// Access) that cause "it's not working" support moments.
struct HelpGuideView: View {
    @Binding var isPresented: Bool
    /// true when the sheet is auto-shown on first launch — changes the footer button wording.
    var firstRun: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Brand.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        icon: "record.circle",
                        title: "record a coaching clip",
                        lines: [
                            "the **record** tab captures your screen and face-cam together in one video.",
                            "got more than one monitor? CoachCam records **the screen its window is on** — move the window and it follows. want a different one? pick it from the **display menu** and your choice sticks.",
                            "**drag the small face-cam** in the preview to move it wherever it fits best.",
                            "while recording, hit **draw** to sketch red lines over anything on screen — switch between **pen** and **straight line**, and the **eraser** clears them. perfect for showing where a movement should go.",
                            "**custom area** — record just part of the screen (loom-style): click *custom area*, drag a box, and an orange outline shows exactly what's captured and stays on screen as you record. click again to clear it.",
                            "**pause / resume** any time — the paused bits are skipped, no editing needed.",
                            "webcam-only? switch off the screen source for a plain talking-head clip."
                        ]
                    )

                    section(
                        icon: "pip",
                        title: "float cam — record over any window",
                        lines: [
                            "click **float cam** to pop your camera out into its own little window that **floats on top of everything** — even across other spaces and full-screen apps. this is how most coaches are used to working.",
                            "drag it anywhere; **resize** from the top-left grip. it stays pinned where you put it and never slides off screen.",
                            "**record, stop, and even draw on screen** right from that floating window — you never have to come back to the main app. click **dock cam** to put it back."
                        ]
                    )

                    section(
                        icon: "macwindow",
                        title: "auto-hide the app",
                        lines: [
                            "turn on **auto-hide** and the CoachCam window gets out of the way the moment recording starts — perfect for talking over a client's google sheet, photos, or plan.",
                            "**pair it with float cam** so you've still got a stop button (and your face) on screen while the main window is tucked away."
                        ]
                    )

                    section(
                        icon: "photo.on.rectangle.angled",
                        title: "before / after photos",
                        lines: [
                            "**smart match** lines up a client's progress photos side by side. pick the client and two dates, then hit **AI match** to auto-pair the poses.",
                            "**← / →** step through the matched poses.",
                            "AI got a pairing wrong? hit **ai match wrong?**, line up the correct *after* photo with **← / →**, then **save match** to lock it (a ✎ shows on ones you've fixed).",
                            "prefer to browse by hand? hit **manual scroll** — **W A S D** flick the before photo, **← / →** flick the after, each side on its own.",
                            "client sent before **and** after in one batch (missed a week), maybe mixed with sleep or food pics? hit **sort before / after** — tag each photo as *before* or *after* and leave the rest untagged, then **compare** shows only the ones you picked.",
                            "**paste** mode lets you build a before/after deck by hand — paste from the clipboard or pull from whatsapp, then **clear all** to start the next check-in."
                        ]
                    )

                    section(
                        icon: "bubble.left.and.bubble.right",
                        title: "pull photos from whatsapp",
                        lines: [
                            "CoachCam can read the photos your clients send you in whatsapp, so you don't have to save each one.",
                            "this needs **full disk access** (whatsapp keeps its photos in a protected folder). if the client list or photos are empty, that permission is almost always why — see below."
                        ]
                    )

                    section(
                        icon: "square.and.arrow.up",
                        title: "where clips go & sending them",
                        lines: [
                            "every clip is saved on your mac at **~/Movies/CoachCam/**, named by client and date. nothing is uploaded — recording and saving work **fully offline**, so you never need internet to make a clip.",
                            "when you're ready, hit **send to whatsapp**: CoachCam opens the client's chat (if it knows their number) and pops the video up in finder so you **drag it straight in**. it's already small enough — no compressing, no uploading.",
                            "no internet right now? the clip is already saved — just send it later from that folder."
                        ]
                    )

                    permissionsSection
                }
                .padding(24)
            }
            Divider().overlay(Brand.border)
            footer
        }
        .frame(width: 560, height: 640)
        .background(Brand.bg)
        .brandTheme()
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.accentBorder, lineWidth: 1))
                    .frame(width: 44, height: 44)
                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(Brand.accent2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("how coachcam works").font(Brand.font(19, .bold)).foregroundStyle(Brand.text)
                Text("a quick tour — you can reopen this any time from the ? button").font(Brand.font(12)).foregroundStyle(Brand.muted)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(firstRun ? "got it" : "close") { isPresented = false }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
    }

    // MARK: permissions (with actionable buttons)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "gearshape", title: "if recording or photos won't work")
            Text("macOS guards the screen and whatsapp's photos. CoachCam has to be ticked in two places — this is a one-time setup.")
                .font(Brand.body(13)).foregroundStyle(Brand.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)

            permissionRow(
                title: "screen recording",
                detail: "needed to record your screen. tick CoachCam, then quit and reopen the app.",
                button: "open screen recording settings",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            permissionRow(
                title: "full disk access",
                detail: "needed to pull photos from whatsapp. tick CoachCam, then quit and reopen.",
                button: "open full disk access settings",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            )

            Text("camera and microphone ask with a normal popup the first time you record — just click allow.")
                .font(Brand.font(12)).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }

    private func permissionRow(title: String, detail: String, button: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Brand.font(14, .semibold)).foregroundStyle(Brand.text)
            Text(detail).font(Brand.body(13)).foregroundStyle(Brand.text.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            Button(button) {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
            .buttonStyle(OutlineButtonStyle())
        }
        .padding(.top, 4)
    }

    // MARK: section builders

    private func section(icon: String, title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(icon: icon, title: title)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(Brand.accent).frame(width: 5, height: 5).padding(.top, 7)
                        Text(.init(line))          // markdown for the **bold** key terms
                            .font(Brand.body(13))
                            .foregroundStyle(Brand.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Brand.accent2).frame(width: 20)
            Text(title).font(Brand.font(16, .bold)).foregroundStyle(Brand.text)
        }
    }
}
