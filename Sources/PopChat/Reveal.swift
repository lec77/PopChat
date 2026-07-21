import AppKit

/// Delta 4: motion for the streaming reveal.
///
/// The spec asks for SwiftUI `TextRenderer` (macOS 15+) glyph animation, which
/// cannot be used here: assistant prose renders through `SelectableText` —
/// `NSTextField(labelWithAttributedString:)` — because SwiftUI text selection is
/// per-`Text`-view, which is exactly why MarkdownUI was removed. `TextRenderer`
/// only decorates SwiftUI `Text`, so adopting it would trade cross-block
/// selection and the `sizeThatFits` cache for the fade.
///
/// So the fade is painted instead, riding the precedent already in this file's
/// neighbour: `FindHighlight.paint` builds a painted string for DISPLAY while
/// `sizeThatFits` keys on the unpainted one. Alpha on `.foregroundColor` is
/// metrics-neutral in the same way `.backgroundColor` is, so the transcript
/// never re-measures because of a fade.
///
/// A `TextReveal` is a stack of alpha bands measured BACKWARDS from the end of a
/// text view's string — `stops[0]` covers the last `stops[0].length` characters,
/// `stops[1]` the ones before those, and so on. Both streaming modes reduce to
/// that shape: per-character produces a graded ramp, per-sentence one band per
/// in-flight sentence group.
struct TextReveal: Equatable {
    struct Stop: Equatable {
        var length: Int
        var alpha: Double
    }

    var stops: [Stop]
    /// Characters at the very end to leave alone — the streaming caret glyph,
    /// which must stay solid: it rides the head of the fade, it isn't part of it.
    var trailingSkip = 0

    var isEmpty: Bool { stops.allSatisfy { $0.length <= 0 || $0.alpha >= 1 } }

    /// Ease-out, matching the spec's 0→1 opacity curve.
    static func eased(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped)
    }

    /// 6a — per-character. The spec describes a 220 ms fade per glyph with a
    /// 12 ms stagger; at a constant reveal rate "time since this glyph was
    /// committed" and "distance from the head" are the same quantity, so the ramp
    /// can be a function of POSITION. That is what makes this affordable: it needs
    /// no per-glyph timestamps and no animation timer, it advances on the drain's
    /// own tick, and it adds no repaints beyond the ones the reveal already causes.
    ///
    /// `head` is sized at 6 generations of the drain's step — precisely the
    /// overlap the design credits for reading as smooth rather than as steps.
    /// Quantized into bands because 8 attribute runs and ~40 look identical.
    static func ramp(head: Int, bands: Int = 8) -> TextReveal {
        guard head > 0, bands > 0 else { return TextReveal(stops: []) }
        let width = Double(head) / Double(bands)
        var stops: [Stop] = []
        var placed = 0
        for band in 0..<bands {
            let upTo = Int((Double(band + 1) * width).rounded())
            let length = max(0, upTo - placed)
            guard length > 0 else { continue }
            placed = upTo
            stops.append(Stop(length: length, alpha: eased((Double(band) + 0.5) / Double(bands))))
        }
        return TextReveal(stops: stops)
    }

    /// 6b — per-sentence. Each committed group fades in as ONE unit over 0.35 s.
    /// Groups overlap (commits are ≥140 ms apart, the fade runs 350 ms) and they
    /// are contiguous and ordered, so they map exactly onto consecutive bands.
    /// `groups` must be newest-first.
    static func groups(_ groups: [(length: Int, age: Int)], duration: Int = 350) -> TextReveal {
        TextReveal(stops: groups.compactMap { group in
            guard group.length > 0 else { return nil }
            return Stop(length: group.length, alpha: eased(Double(group.age) / Double(duration)))
        })
    }
}

enum RevealFade {
    /// Multiplies alpha into `.foregroundColor` over the trailing bands. Bands at
    /// full opacity are skipped entirely, so settled text keeps its ORIGINAL
    /// attributes (including dynamic system colors) — only the fading head is
    /// ever rewritten.
    static func paint(_ attributed: NSAttributedString, reveal: TextReveal) -> NSAttributedString {
        guard !reveal.isEmpty, attributed.length > 0 else { return attributed }
        var end = attributed.length - reveal.trailingSkip
        guard end > 0 else { return attributed }

        // Runs are collected before any mutation: enumerating an attribute while
        // rewriting that same attribute is not safe.
        var edits: [(NSRange, NSColor)] = []
        for stop in reveal.stops {
            guard end > 0, stop.length > 0 else { break }
            let start = max(0, end - stop.length)
            let range = NSRange(location: start, length: end - start)
            end = start
            guard stop.alpha < 1 else { continue }
            attributed.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
                let base = (value as? NSColor) ?? .labelColor
                edits.append((sub, base.withAlphaComponent(base.alphaComponent * stop.alpha)))
            }
        }
        guard !edits.isEmpty else { return attributed }
        let painted = NSMutableAttributedString(attributedString: attributed)
        for (range, color) in edits {
            painted.addAttribute(.foregroundColor, value: color, range: range)
        }
        return painted
    }
}
