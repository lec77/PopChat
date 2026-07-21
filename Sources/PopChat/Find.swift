import AppKit
import SwiftUI

/// What ONE text view needs to know about the live ⌘F query: the needle, and
/// which occurrence *inside that view's own text* is the active hit (nil = the
/// active hit lives in another view; its matches still get the passive tint).
///
/// Occurrences are counted over DISPLAYED text — markdown syntax already
/// stripped — so "7 of 12" points at exactly the range the user can see.
struct TextFind: Equatable {
    var query: String
    var active: Int?
}

/// Match-finding and highlight painting. Colors resolve from the accent +
/// current appearance here (same trick as MarkdownRenderer.appearanceKey)
/// rather than being threaded through every view.
enum FindHighlight {
    static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let found = haystack.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: start, length: haystack.length - start)
            )
            guard found.location != NSNotFound else { break }
            result.append(found)
            start = found.location + max(found.length, 1)
        }
        return result
    }

    static func count(in text: String, query: String) -> Int {
        ranges(in: text, query: query).count
    }

    static func fill(active: Bool) -> NSColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let hex = UserDefaults.standard.string(forKey: "accentColor") ?? Theme.defaultAccentHex
        let accent = Theme.nsColor(hex)
        if active {
            return accent.withAlphaComponent(dark ? 0.55 : 0.42)
        }
        return accent.withAlphaComponent(dark ? 0.24 : 0.18)
    }

    /// Highlights only add `.backgroundColor`, which cannot change metrics —
    /// that is what lets SelectableText keep measuring against the unpainted
    /// original (see its `measurementIdentity`).
    static func paint(_ attributed: NSAttributedString, find: TextFind) -> NSAttributedString {
        let matches = ranges(in: attributed.string, query: find.query)
        guard !matches.isEmpty else { return attributed }
        let painted = NSMutableAttributedString(attributedString: attributed)
        for (index, range) in matches.enumerated() {
            painted.addAttribute(.backgroundColor, value: fill(active: index == find.active), range: range)
        }
        return painted
    }

    /// SwiftUI-side equivalent for rows rendered as Labels (activity/error).
    static func paint(_ text: String, find: TextFind?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let find, !find.query.isEmpty else { return attributed }
        for (index, range) in ranges(in: text, query: find.query).enumerated() {
            guard let bounds = Range(range, in: text),
                  let lower = AttributedString.Index(bounds.lowerBound, within: attributed),
                  let upper = AttributedString.Index(bounds.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = Color(nsColor: fill(active: index == find.active))
        }
        return attributed
    }
}

/// Hands out per-view `TextFind`s while walking a message's text views in
/// render order, so occurrence N of the message maps onto exactly one painted
/// range. Views with no matches get nil — their attributed strings stay
/// identical and the render/measurement caches keep hitting.
struct FindCursor {
    private let query: String
    /// Occurrence index within this message, or nil when the active hit is in
    /// another message.
    private let active: Int?
    private var consumed = 0

    init?(_ find: MessageFind?) {
        guard let find, !find.query.isEmpty else { return nil }
        query = find.query
        active = find.activeOccurrence
    }

    mutating func next(_ text: String) -> TextFind? {
        let count = FindHighlight.count(in: text, query: query)
        defer { consumed += count }
        guard count > 0 else { return nil }
        let local = active.map { $0 - consumed }
        return TextFind(query: query, active: local.flatMap { (0..<count).contains($0) ? $0 : nil })
    }

    /// Contexts for a run of strings (table cells), in render order.
    mutating func next(all texts: [String]) -> [TextFind?] {
        texts.map { next($0) }
    }
}

/// One search result: which message, and which occurrence within that message's
/// displayed text. The find bar's "n of m" indexes this list.
struct FindHit: Equatable {
    let messageID: UUID
    let occurrence: Int
}

/// A message's slice of the search: the needle plus which of ITS occurrences is
/// the active hit. Only messages that actually match get one, so every other
/// row stays Equatable-gated while the user types.
struct MessageFind: Equatable {
    var query: String
    var activeOccurrence: Int?
}
