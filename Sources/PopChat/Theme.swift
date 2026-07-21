import AppKit
import SwiftUI

// Design tokens for the "Glass" redesign (design/README.md). Chat Style choices
// persist via @AppStorage; everything reads them through these helpers so the
// panel and the Settings preview stay in sync.

enum BubbleStyle: String, CaseIterable, Identifiable {
    case accentTint
    case quietGray
    case accentFill

    var id: String { rawValue }
    var label: String {
        switch self {
        case .accentTint: "Accent tint"
        case .quietGray: "Quiet gray"
        case .accentFill: "Accent fill"
        }
    }
}

enum StreamingMode: String, CaseIterable, Identifiable {
    case perCharacter
    case byChunk

    var id: String { rawValue }
    var label: String {
        switch self {
        case .perCharacter: "Per-character"
        case .byChunk: "By chunk"
        }
    }
}

/// App-wide appearance override (Settings › General › Chat Style). Applied via
/// NSApp.appearance so every window flips together — panel, Settings, popovers;
/// .preferredColorScheme alone would not reach the NSPanel chrome. `auto` (nil)
/// tracks the system live, no relaunch.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyCurrent() {
        let raw = UserDefaults.standard.string(forKey: "appearance") ?? AppearanceChoice.auto.rawValue
        NSApp.appearance = (AppearanceChoice(rawValue: raw) ?? .auto).nsAppearance
    }
}

enum Theme {
    /// The four fixed accent choices — no free picker.
    static let accentOptions = ["#0A84FF", "#BF5AF2", "#FF9F0A", "#30D158"]
    static let defaultAccentHex = "#0A84FF"

    static let warningOrange = color("#FF9F0A")
    static let stopRed = color("#FF453A")
    /// Warning text needs a darker tone on light backgrounds to stay readable.
    static let warningTextLight = color("#C93400")

    static var currentAccent: Color {
        color(UserDefaults.standard.string(forKey: "accentColor") ?? defaultAccentHex)
    }

    static func color(_ hex: String) -> Color {
        Color(nsColor: nsColor(hex))
    }

    static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        Scanner(string: cleaned).scanHexInt64(&value)
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // Bubble styles — dark: tint = accent 19%, gray = white 9%, fill = accent.
    // Light: tint = accent 15%, gray = black 6%, fill = accent.
    static func bubbleFill(style: BubbleStyle, accentHex: String, dark: Bool) -> Color {
        let accent = color(accentHex)
        switch style {
        case .accentTint: return accent.opacity(dark ? 0.19 : 0.15)
        case .quietGray: return dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
        case .accentFill: return accent
        }
    }

    static func bubbleForeground(style: BubbleStyle) -> Color {
        style == .accentFill ? .white : .primary
    }

    static func panelBorder(dark: Bool) -> Color {
        Color.white.opacity(dark ? 0.16 : 0.65)
    }

    // Semantic surfaces (delta 2): the transcript uses three depth levels that
    // must keep their relationships in both modes — chat text sits flat on
    // glass, code blocks RECESS, pasteable blocks LIFT.

    /// Lifted surface — pasteable blocks: light fill + hairline, "take this".
    static func liftedFill(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    static func liftedBorder(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    static func liftedDivider(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    /// Recessed surface — code blocks.
    static func recessedFill(dark: Bool) -> Color {
        dark ? Color.black.opacity(0.35) : Color.black.opacity(0.05)
    }

    static func recessedHeader(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    static func recessedBorder(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }

    static func recessedCaption(dark: Bool) -> Color {
        dark ? color("#DFDFE6").opacity(0.5) : color("#3C3C43").opacity(0.6)
    }
}

// MARK: - Glass materials

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The panel's backdrop. Liquid glass (behind-window blur + glassEffect where the
/// OS supports it) with an optional user-tint fill; or a solid opaque fill when
/// the Liquid glass toggle is off — or Reduce Transparency is on, which always
/// wins. `panelTint` of -1 means "follow the system glass appearance"; 0–1 maps
/// to a fill opacity layered behind the blur.
struct PanelGlassBackground: View {
    @AppStorage("liquidGlass") private var liquidGlass = true
    @AppStorage("panelTint") private var panelTint = -1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !liquidGlass || reduceTransparency {
            solidFill
        } else {
            ZStack {
                if #available(macOS 26.0, *) {
                    // glassEffect alone — a second live NSVisualEffectView backdrop
                    // underneath doubled the compositing cost for no visual gain.
                    // If glass ever stops sampling behind the window (blank/clear
                    // panel), re-add VisualEffectBackground() beneath it.
                    // Untouched slider (-1) keeps the system `regular` look; once
                    // set, the `clear` variant + a 0→max tint ramp spans genuinely
                    // transparent → strongly tinted (`regular`'s inherent frosting
                    // put a floor under how clear the panel could get).
                    if panelTint >= 0 {
                        Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                } else {
                    VisualEffectBackground()
                    if panelTint < 0 {
                        // Pre-glass fallback default tint.
                        scheme == .dark
                            ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.55)
                            : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.62)
                    }
                }
                if panelTint >= 0 {
                    tintFill(min(panelTint, 1))
                }
            }
        }
    }

    private var solidFill: Color {
        scheme == .dark ? Theme.color("#232326") : Theme.color("#f5f5f7")
    }

    // Linear from zero — the delta spec's 0.30/0.40 floor meant the "Clear" end
    // of the slider was never actually clear.
    private func tintFill(_ t: Double) -> Color {
        scheme == .dark
            ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.80 * t)
            : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.85 * t)
    }
}

/// Header chrome pills: capsule, hairline stroke, brighter on hover.
struct PillBackground: ViewModifier {
    var hovered = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill: Color = scheme == .dark
            ? Color.white.opacity(hovered ? 0.12 : 0.08)
            : Color.white.opacity(hovered ? 0.7 : 0.55)
        let stroke: Color = scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
        content
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
    }
}

/// Floating glass layer used by the input capsule and the cards above it.
struct GlassCard<S: InsettableShape>: ViewModifier {
    var shape: S
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill: Color = scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.75)
        let stroke: Color = scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 12, y: 8)
    }
}

extension View {
    func pillBackground(hovered: Bool = false) -> some View {
        modifier(PillBackground(hovered: hovered))
    }

    func glassCard<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassCard(shape: shape))
    }
}
