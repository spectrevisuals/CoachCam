import SwiftUI

/// Single source of truth for all colours, fonts and radii — mirrors the CoachCam
/// landing page (coachcam.vercel.app). Nothing visual should be hardcoded in views.
enum Brand {
    // MARK: Palette — exact values from the landing page CSS (:root)
    static let accent       = Color(hex: 0xFD5601)              // --accent  (CoachCam orange)
    static let accent2      = Color(hex: 0xFF8A3D)              // --accent-2 (hover/highlight)
    static let accentSoft   = Color(hex: 0xFD5601, alpha: 0.12) // --accent-soft
    static let accentBorder = Color(hex: 0xFD5601, alpha: 0.30) // --accent-border
    static let danger       = Color(hex: 0xFF3B30)              // record / stop (universal red)

    // Surfaces — near-black, not pure black (pure black looks flat)
    static let bg       = Color(hex: 0x111014)
    static let bgElev   = Color(hex: 0x16151A)
    static let bgCard   = Color(hex: 0x1A181E)
    static let text     = Color.white
    static let muted    = Color.white.opacity(0.5)
    static let border   = Color.white.opacity(0.10)

    // Translucent control surface (inputs / pills)
    static let control       = Color.white.opacity(0.05)
    static let controlBorder = Color.white.opacity(0.12)

    // MARK: Radius scale — one scale everywhere
    static let rControl: CGFloat = 11   // buttons, inputs, pills
    static let rPanel:   CGFloat = 14   // panels / cards
    static let rWindow:  CGFloat = 18   // window-level container
    static var radius: CGFloat { rControl }   // back-compat default

    static let controlHeight: CGFloat = 40

    // MARK: Type — Quicksand (bundled variable font, family "Quicksand")
    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        Font.custom("Quicksand", size: size).weight(weight)
    }
    static func title(_ size: CGFloat = 22) -> Font { font(size, .bold) }
    static func body(_ size: CGFloat = 14)  -> Font { font(size, .medium) }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension View {
    /// Applies the brand defaults (dark, orange tint, Quicksand, lowercase) to a subtree.
    func brandTheme() -> some View {
        self
            .environment(\.font, Brand.font(14))
            .textCase(.lowercase)
            .tint(Brand.accent)
            .foregroundStyle(Brand.text)
            .preferredColorScheme(.dark)
    }

    /// Translucent rounded "pill" surface used for inputs and dropdowns.
    func brandPill(height: CGFloat = Brand.controlHeight) -> some View {
        self
            .frame(height: height)
            .padding(.horizontal, 13)
            .background(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous).fill(Brand.control))
            .overlay(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous)
                .stroke(Brand.controlBorder, lineWidth: 1))
    }

    func brandCard() -> some View { modifier(BrandCard()) }
}

// MARK: - Shared button styles (build once, use everywhere)

/// Primary action — brand orange, white text. The one style for save jpeg, add pose, etc.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Brand.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(14, .semibold))
            .textCase(.lowercase)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.white)
            .frame(height: Brand.controlHeight)
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous)
                .fill(color.opacity(configuration.isPressed ? 0.82 : 1)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Outline / ghost button — used for secondary actions (float cam). Highlights orange when active.
struct OutlineButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(13, .medium))
            .textCase(.lowercase)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Brand.accent : Brand.text.opacity(0.85))
            .frame(height: Brand.controlHeight)
            .padding(.horizontal, 17)
            .background(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous)
                .fill(active ? Brand.accentSoft : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous)
                .stroke(active ? Brand.accentBorder : Brand.controlBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Plain orange text link (e.g. "paste").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(12, .medium))
            .foregroundStyle(Brand.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct BrandCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous).fill(Brand.bgCard))
            .overlay(RoundedRectangle(cornerRadius: Brand.rPanel, style: .continuous).stroke(Brand.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

// MARK: - Shared empty state (icon-in-soft-box + title + subtitle)

/// The consistent empty-state treatment used across the app (record screen, photo drop
/// zones, compare/browse). A soft orange-tinted rounded icon box over title + subtitle.
struct BrandEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconSize: CGFloat = 24
    var boxSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Brand.accentBorder, lineWidth: 1))
                    .frame(width: boxSize, height: boxSize)
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundStyle(Brand.accent2)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(Brand.font(15, .semibold))
                    .foregroundStyle(Brand.text.opacity(0.85))
                Text(subtitle)
                    .font(Brand.font(12))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Shared segmented control (one component for ALL segmented controls)

/// A brand segmented control. Active segment = orange fill with a subtle inner highlight.
/// An optional `recommended` value is highlighted (orange tint + ✨) even when unselected,
/// to steer users toward the best option.
struct BrandSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(label: String, value: T)]
    var compact: Bool = false
    var recommended: T? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { opt in
                let active = selection == opt.value
                let isRec = recommended == opt.value
                Button {
                    selection = opt.value
                } label: {
                    HStack(spacing: 4) {
                        if isRec {
                            Image(systemName: "sparkles").font(.system(size: compact ? 10 : 11))
                        }
                        Text(opt.label)
                    }
                        .font(Brand.font(compact ? 12 : 13, (active || isRec) ? .semibold : .medium))
                        .textCase(.lowercase)
                        .foregroundStyle(active ? Color.white : (isRec ? Brand.accent : Brand.muted))
                        .padding(.horizontal, compact ? 11 : 14)
                        .padding(.vertical, compact ? 6 : 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Brand.accent : (isRec ? Brand.accentSoft : Color.clear))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(active ? Color.white.opacity(0.18)
                                                       : (isRec ? Brand.accentBorder : Color.clear),
                                                lineWidth: active ? 0.5 : 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous).fill(Brand.control))
        .overlay(RoundedRectangle(cornerRadius: Brand.rControl, style: .continuous).stroke(Brand.controlBorder, lineWidth: 1))
    }
}
