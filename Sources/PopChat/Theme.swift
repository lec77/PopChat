import AppKit
import SwiftUI

// Design tokens for the "Glass" redesign (design/README.md). Chat Style choices
// persist via @AppStorage; everything reads them through these helpers so the
// panel and the Settings preview stay in sync.

/// Removed 2026-07-22: `quietGray`. With a free accent picker it was just
/// "accent fill with a gray accent", and a stored "quietGray" decodes through
/// the `?? .accentTint` fallback every call site already had — that IS the
/// migration.
enum BubbleStyle: String, CaseIterable, Identifiable {
    case accentTint
    case accentFill

    var id: String { rawValue }
    var label: String {
        switch self {
        case .accentTint: "Accent tint"
        case .accentFill: "Accent fill"
        }
    }
}

enum StreamingMode: String, CaseIterable, Identifiable {
    case perCharacter
    /// Delta 4 renamed "By chunk" → "Per-sentence" (mirroring raw snapshots
    /// mid-word read as the same stutter as per-character did). The RAW VALUE
    /// deliberately stays "byChunk" so saved prefs migrate silently — this is
    /// the whole migration; there is no other decode path.
    case perSentence = "byChunk"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .perCharacter: "Per-character"
        case .perSentence: "Per-sentence"
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
    /// The four preset accent choices; Settings adds a color well beside them
    /// for a custom hex (stored separately under "customAccentColor" so the
    /// swatch survives switching to a preset and back).
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
        let (red, green, blue) = components(hex)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Parsed sRGB components, 0…1. Anything that isn't exactly six hex digits
    /// falls back to the default accent rather than to black — a stored value
    /// this can't read is a bug to be visible in Settings, not a black panel.
    static func components(_ hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        func parse(_ text: String) -> (CGFloat, CGFloat, CGFloat)? {
            let cleaned = text.hasPrefix("#") ? String(text.dropFirst()) : text
            guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
            return (
                CGFloat((value >> 16) & 0xFF) / 255,
                CGFloat((value >> 8) & 0xFF) / 255,
                CGFloat(value & 0xFF) / 255
            )
        }
        return parse(hex) ?? parse(defaultAccentHex) ?? (0, 0, 0)
    }

    // sRGB HSB ⇄ hex. The custom-accent picker works in HSB and stores hex, so
    // both directions live here and are exact inverses at 8-bit precision.
    // Deliberately hand-rolled rather than going through NSColor/Color: the
    // system color panel hands back EXTENDED-range (HDR) colors whose
    // components exceed 1, and packing those into a hex saturates every
    // channel — that was the "my custom accent turns white" bug (2026-07-22).
    // Nothing here can leave 0…1.

    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let (red, green, blue) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static func hsb(_ hex: String) -> (hue: Double, saturation: Double, brightness: Double) {
        let (red, green, blue) = components(hex)
        let high = max(red, green, blue), low = min(red, green, blue)
        let delta = high - low
        var hue: CGFloat = 0
        if delta > 0 {
            switch high {
            case red: hue = (green - blue) / delta + (green < blue ? 6 : 0)
            case green: hue = (blue - red) / delta + 2
            default: hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        return (Double(hue), Double(high > 0 ? delta / high : 0), Double(high))
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let wrapped = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let saturation = min(max(saturation, 0), 1)
        let value = min(max(brightness, 0), 1)
        let sector = floor(wrapped)
        let fraction = wrapped - sector
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch Int(sector) % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    private static func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Black or white text for a fill of this color. A free accent picker means
    /// an "Accent fill" bubble can now be pale yellow, where fixed white text
    /// was unreadable.
    ///
    /// The split is CIE L* (perceptual lightness) at 60, NOT "whichever wins the
    /// WCAG contrast ratio": maximizing the ratio puts BLACK text on system blue
    /// (#0A84FF scores 5.7 against black vs 3.7 against white), which no design
    /// system — Apple's included — actually does. L* ≥ 60 is the light/dark
    /// split that matches how a filled bubble reads.
    static func contrastingNSColor(on hex: String) -> NSColor {
        let (red, green, blue) = components(hex)
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let lightness = luminance <= 0.008856 ? 903.3 * luminance : 116 * pow(luminance, 1.0 / 3) - 16
        return lightness >= 60 ? .black : .white
    }

    static func contrastingForeground(on hex: String) -> Color {
        Color(nsColor: contrastingNSColor(on: hex))
    }

    // Bubble styles — tint = accent at 19% (dark) / 15% (light), fill = accent.
    static func bubbleFill(style: BubbleStyle, accentHex: String, dark: Bool) -> Color {
        let accent = color(accentHex)
        switch style {
        case .accentTint: return accent.opacity(dark ? 0.19 : 0.15)
        case .accentFill: return accent
        }
    }

    /// Tinted bubbles are mostly panel, so text stays `.primary`; a filled
    /// bubble takes whichever of black/white the accent can carry.
    static func bubbleForeground(style: BubbleStyle, accentHex: String) -> Color {
        style == .accentFill ? contrastingForeground(on: accentHex) : .primary
    }

    static func bubbleForegroundNSColor(style: BubbleStyle, accentHex: String) -> NSColor {
        style == .accentFill ? contrastingNSColor(on: accentHex) : .labelColor
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
    // of the slider was never actually clear. Ceiling 0.95: "Tinted" reads as
    // near-solid (the old 0.80/0.85 still looked quite transparent) while
    // keeping a whisper of glass; fully solid remains the Liquid glass toggle.
    private func tintFill(_ t: Double) -> Color {
        scheme == .dark
            ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.95 * t)
            : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.95 * t)
    }
}

/// Header chrome pills: capsule, hairline stroke, brighter on hover, brighter
/// still while the control it opens is showing (7c's pressed state).
struct PillBackground: ViewModifier {
    var hovered = false
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill: Color = scheme == .dark
            ? Color.white.opacity(pressed ? 0.18 : hovered ? 0.12 : 0.08)
            : Color.white.opacity(pressed ? 0.85 : hovered ? 0.7 : 0.55)
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
    func pillBackground(hovered: Bool = false, pressed: Bool = false) -> some View {
        modifier(PillBackground(hovered: hovered, pressed: pressed))
    }

    func glassCard<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassCard(shape: shape))
    }
}
