import AppKit
import SwiftUI

// The custom accent control in Settings › General › Chat Style.
//
// Deliberately NOT NSColorWell / NSColorPanel (tried 2026-07-22 and removed):
// the system panel hands back colors in EXTENDED (HDR) ranges, and components
// above 1 saturate every channel when packed into a hex — the custom accent
// silently became #FFFFFF as soon as Settings closed. Everything here is HSB in
// sRGB via Theme.hex(hue:saturation:brightness:), so what the swatch shows is
// exactly what gets stored. It also lets the control SAY it is a custom color:
// the stock well was an anonymous colored rectangle next to four colored
// circles, with nothing marking it as the one that opens a picker.

/// Row-level swatch: a rainbow ring (the "custom" signal, present whether or
/// not a color has been chosen) around the chosen color, selectable like a
/// preset, opening the picker popover on click.
struct CustomAccentSwatch: View {
    @Binding var accentHex: String
    @Binding var customHex: String
    @State private var showPicker = false

    private var isSet: Bool { !customHex.isEmpty }
    private var selected: Bool { isSet && accentHex == customHex }

    var body: some View {
        Button {
            if isSet { accentHex = customHex }
            showPicker = true
        } label: {
            ZStack {
                Circle().fill(Self.wheel)
                if isSet {
                    Circle()
                        .fill(Theme.color(customHex))
                        .padding(3)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(
                Circle()
                    .strokeBorder(isSet ? Theme.color(customHex) : Color.secondary, lineWidth: 2)
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isSet ? "Custom accent \(customHex) — click to edit" : "Choose a custom accent color")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            AccentPickerPopover(accentHex: $accentHex, customHex: $customHex)
        }
    }

    /// The universal "any color" mark. Six stops so the seam closes cleanly.
    static let wheel = AngularGradient(
        colors: [
            Theme.color("#FF3B30"), Theme.color("#FF9F0A"), Theme.color("#30D158"),
            Theme.color("#0A84FF"), Theme.color("#BF5AF2"), Theme.color("#FF3B30"),
        ],
        center: .center
    )
}

/// Hue / Saturation / Brightness + a hex field. Applies live — the chat panel
/// sits behind Settings, so dragging a slider is the preview.
/// Internal, not private, so `--shot accent` can render it (a popover never
/// appears in an offscreen snapshot of its host window).
struct AccentPickerPopover: View {
    @Binding var accentHex: String
    @Binding var customHex: String

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var hexDraft = ""

    private var current: Color { Theme.color(hexDraft) }

    // Sliders write through these bindings, NOT through `.onChange(of:)`:
    // seeding the sliders from a hex would then be indistinguishable from a
    // drag and would write the color straight back out — which defeats Reset,
    // and would snap Saturation to 0 the moment a drag took Brightness to black
    // (black has no saturation to read back).
    private var hueBinding: Binding<Double> {
        Binding(get: { hue }, set: { hue = $0; apply() })
    }

    private var saturationBinding: Binding<Double> {
        Binding(get: { saturation }, set: { saturation = $0; apply() })
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { brightness }, set: { brightness = $0; apply() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(current)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Custom accent")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Used everywhere the accent appears")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                labeled("Hue") {
                    GradientSlider(value: hueBinding, track: LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                            Theme.color(Theme.hex(hue: $0, saturation: 1, brightness: 1))
                        },
                        startPoint: .leading, endPoint: .trailing
                    ))
                }
                labeled("Saturation") {
                    GradientSlider(value: saturationBinding, track: LinearGradient(
                        colors: [
                            Theme.color(Theme.hex(hue: hue, saturation: 0, brightness: brightness)),
                            Theme.color(Theme.hex(hue: hue, saturation: 1, brightness: brightness)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                }
                labeled("Brightness") {
                    GradientSlider(value: brightnessBinding, track: LinearGradient(
                        colors: [
                            .black,
                            Theme.color(Theme.hex(hue: hue, saturation: saturation, brightness: 1)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
                }
            }

            HStack(spacing: 8) {
                Text("Hex")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField("#RRGGBB", text: $hexDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 92)
                    .onSubmit { commitHexDraft() }
                Spacer()
                Button("Reset") {
                    customHex = ""
                    accentHex = Theme.defaultAccentHex
                }
                .font(.system(size: 11))
                .help("Forget the custom color and go back to Blue")
            }
        }
        .padding(14)
        .frame(width: 268)
        .onAppear { seed(from: customHex.isEmpty ? accentHex : customHex) }
        // Only an OUTSIDE change re-seeds — after apply() the stored hex is
        // already what the sliders say, so this no-ops on our own writes and
        // fires for Reset (which clears the custom color back to unset).
        .onChange(of: customHex) { _, new in
            guard new != hexDraft else { return }
            seed(from: new.isEmpty ? accentHex : new)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }

    /// Writes the sliders directly (never through their bindings), so seeding
    /// can never be mistaken for a drag.
    private func seed(from hex: String) {
        let (h, s, b) = Theme.hsb(hex)
        // Grays have no hue of their own; keep the slider where it was rather
        // than snapping it to red.
        if s > 0 { hue = h }
        saturation = s
        brightness = b
        hexDraft = Theme.hex(hue: hue, saturation: s, brightness: b)
    }

    private func apply() {
        let hex = Theme.hex(hue: hue, saturation: saturation, brightness: brightness)
        // A drag produces far more ticks than distinct 8-bit colors, and every
        // published change re-renders (and re-measures) filled bubbles in the
        // panel behind Settings. Publish only when the color actually moves.
        guard hex != customHex || accentHex != hex else { return }
        hexDraft = hex
        customHex = hex
        accentHex = hex
    }

    private func commitHexDraft() {
        let trimmed = hexDraft.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6, UInt64(body, radix: 16) != nil else {
            hexDraft = customHex.isEmpty ? accentHex : customHex // reject, don't guess
            return
        }
        seed(from: "#" + body.uppercased())
        apply()
    }
}

/// A slider whose track IS the value it picks — a plain `Slider` can't show the
/// hue ramp, and the ramp is what makes the control readable at this size.
private struct GradientSlider: View {
    @Binding var value: Double
    var track: LinearGradient

    private let thumb: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let span = max(geometry.size.width - thumb, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(height: 9)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: min(max(value, 0), 1) * span)
            }
            .frame(height: thumb, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = min(max((drag.location.x - thumb / 2) / span, 0), 1)
                }
            )
        }
        .frame(height: thumb)
    }
}
