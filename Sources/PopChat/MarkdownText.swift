import AppKit
import SwiftUI
import Splash
import SwiftMath

/// Native markdown rendering with real text selection. SwiftUI's `.textSelection`
/// is per-Text-view (selection can't cross paragraphs), so assistant messages are
/// rendered as NSTextField labels — one per prose section — where selection behaves
/// like a normal document. Code fences, blockquotes, tables and display math are
/// split into their own styled blocks.
enum MarkdownRenderer {
    enum Segment {
        case prose(String)
        case code(language: String?, content: String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case math(String)
        /// Reusable content the model marked with <pasteable> tags (per the
        /// default system prompt) — rendered as a dedicated copyable card.
        case pasteable(title: String?, content: String)

        var isProse: Bool {
            if case .prose = self { return true }
            return false
        }
    }

    /// Splits fences (an unclosed fence mid-stream renders as code), `$$` display
    /// math, `>` blockquotes and pipe tables out of the prose flow.
    static func segments(_ markdown: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [String] = []

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.prose(text)) }
            prose = []
        }

        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushProse()
                let hint = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                result.append(.code(language: hint.isEmpty ? nil : hint, content: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Content is captured verbatim until the closing tag, so pasteable
            // blocks may safely contain code fences (and fences may contain
            // literal <pasteable> text — the fence branch above consumes it).
            if trimmed.hasPrefix("<pasteable"), trimmed.hasSuffix(">") {
                flushProse()
                var title: String?
                if let match = trimmed.range(of: #"title\s*=\s*"([^"]*)""#, options: .regularExpression) {
                    let attribute = String(trimmed[match])
                    if let open = attribute.firstIndex(of: "\""), let close = attribute.lastIndex(of: "\""), open < close {
                        let value = String(attribute[attribute.index(after: open)..<close])
                        title = value.isEmpty ? nil : value
                    }
                }
                var content: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "</pasteable>" {
                    content.append(lines[i])
                    i += 1
                }
                result.append(.pasteable(
                    title: title,
                    content: content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                i += 1
                continue
            }

            if trimmed == "$$" || (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4) {
                flushProse()
                if trimmed.count > 4 {
                    result.append(.math(String(trimmed.dropFirst(2).dropLast(2))))
                    i += 1
                    continue
                }
                var math: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    math.append(lines[i])
                    i += 1
                }
                result.append(.math(math.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushProse()
                var quote: [String] = []
                while i < lines.count {
                    let quoteLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quote.append(String(quoteLine.dropFirst().drop(while: { $0 == " " })))
                    i += 1
                }
                result.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushProse()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowLine.hasPrefix("|") else { break }
                    rows.append(tableCells(rowLine))
                    i += 1
                }
                result.append(.table(header: header, rows: rows))
                continue
            }

            prose.append(line)
            i += 1
        }
        flushProse()
        return result
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    // MARK: - Search

    /// The strings ⌘F searches, in the exact order their views render: prose and
    /// quotes with markdown syntax already stripped (so a hit lands where the
    /// user sees the text, not where the source has it), code/pasteable content
    /// verbatim, table cells header-first then row by row. Display math is a
    /// rendered bitmap and has no searchable text.
    ///
    /// `FindCursor` walks this same order when handing out highlight contexts —
    /// if one side changes, the other must change with it.
    static func searchableStrings(_ segment: Segment) -> [String] {
        switch segment {
        case .prose(let prose): return [attributedProse(prose).string]
        case .quote(let quote): return [attributedProse(quote).string]
        case .code(_, let content): return [content]
        case .pasteable(_, let content): return [content]
        case .table(let header, let rows): return header.map { tableCell($0).string } + rows.flatMap { $0.map { tableCell($0).string } }
        case .math: return []
        }
    }

    /// A table cell's rendered text (inline markdown only). Lives here so search
    /// and rendering measure the same string.
    static func tableCell(_ text: String, bold: Bool = false) -> NSAttributedString {
        let font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        result.addAttributes([.font: font, .foregroundColor: NSColor.labelColor],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    static func searchableStrings(for message: ChatMessage) -> [String] {
        switch message.role {
        case .assistant: return segments(message.text).flatMap(searchableStrings)
        case .user, .activity, .error: return [message.text]
        }
    }

    // MARK: - Prose → NSAttributedString

    // Bounded: streaming produces a new string per tick, so uncapped caches would
    // fill with thousands of one-off intermediate entries.
    private static let proseCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        return cache
    }()

    /// The current appearance is part of every render-cache key: label colors are
    /// dynamic and resolve at draw time, but math images are BITMAPS with the
    /// color baked in — an Auto/Light/Dark flip (4f) must not serve stale ones.
    private static var appearanceKey: String {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? "l" : "d"
    }

    static func attributedProse(_ markdown: String, caret: NSColor? = nil) -> NSAttributedString {
        let base: NSAttributedString
        let cacheKey = "\(appearanceKey)|\(markdown)" as NSString
        if let cached = proseCache.object(forKey: cacheKey) {
            base = cached
        } else {
            base = buildProse(markdown)
            proseCache.setObject(base, forKey: cacheKey)
        }
        guard let caret else { return base }
        let withCaret = NSMutableAttributedString(attributedString: base)
        withCaret.append(NSAttributedString(string: "▍", attributes: [
            .foregroundColor: caret,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]))
        return withCaret
    }

    private static func buildProse(_ markdown: String) -> NSAttributedString {
        // Inline math is swapped for placeholder tokens before markdown parsing
        // (so the parser can't mangle it), then replaced with rendered attachments.
        var mathParts: [String] = []
        var source = markdown
        if markdown.contains("$") {
            (source, mathParts) = extractInlineMath(markdown)
        }

        let baseSize = NSFont.systemFontSize
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return plain(markdown)
        }

        let result = NSMutableAttributedString()
        var previousBlockID: Int?
        var previousListItemID: Int?

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }

            var headerLevel = 0
            var isCodeBlock = false
            var isQuote = false
            var listDepth = 0
            var isOrdered = false
            var listOrdinal: Int?
            var listItemID: Int?
            var blockID: Int?

            if let intent = run.presentationIntent {
                blockID = intent.components.first?.identity
                for component in intent.components {
                    switch component.kind {
                    case .header(let level): headerLevel = level
                    case .codeBlock: isCodeBlock = true
                    case .blockQuote: isQuote = true
                    case .orderedList: isOrdered = true; listDepth += 1
                    case .unorderedList: listDepth += 1
                    case .listItem(let ordinal):
                        listOrdinal = ordinal
                        listItemID = component.identity
                    case .thematicBreak: text = "———"
                    default: break
                    }
                }
            }

            // Font: header size/bold, then code/emphasis traits on top.
            var font: NSFont
            let headerScales: [Int: CGFloat] = [1: 1.35, 2: 1.2, 3: 1.1]
            if headerLevel > 0 {
                let size = baseSize * (headerScales[headerLevel] ?? 1.05)
                font = NSFont.boldSystemFont(ofSize: size)
            } else {
                font = NSFont.systemFont(ofSize: baseSize)
            }
            let inline = run.inlinePresentationIntent ?? []
            let isInlineCode = inline.contains(.code)
            if isCodeBlock || isInlineCode {
                font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = headerLevel > 0 ? 8 : 6
            paragraph.lineSpacing = 4
            if listDepth > 0 {
                let indent = CGFloat(listDepth - 1) * 16
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 16
            }
            if isQuote {
                paragraph.firstLineHeadIndent += 10
                paragraph.headIndent += 10
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isQuote ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if isInlineCode || isCodeBlock {
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08)
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            // Separate blocks with a newline; bullet/number prefix on new list items.
            if let blockID, blockID != previousBlockID {
                if previousBlockID != nil {
                    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph, .font: font]))
                }
                if let listItemID, listItemID != previousListItemID {
                    let prefix = isOrdered ? "\(listOrdinal ?? 1). " : "•  "
                    var prefixAttributes = attributes
                    prefixAttributes[.font] = NSFont.systemFont(ofSize: baseSize)
                    prefixAttributes.removeValue(forKey: .backgroundColor)
                    result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
                    previousListItemID = listItemID
                }
                previousBlockID = blockID
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        substituteInlineMath(in: result, parts: mathParts)
        return result.length > 0 ? result : plain(markdown)
    }

    static func plain(_ text: String, monospaced: Bool = false, color: NSColor = .labelColor, size: CGFloat? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = monospaced ? 4 : 3
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size ?? 11.5, weight: .regular)
            : NSFont.systemFont(ofSize: size ?? NSFont.systemFontSize)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Syntax highlighting (Splash — Xcode dark/light palettes, 4f)

    private static let splashDarkTheme = Splash.Theme(
        font: Splash.Font(size: 11.5),
        plainTextColor: Theme.nsColor("#DFDFE6"),
        tokenColors: [
            .keyword: Theme.nsColor("#FC5FA3"),
            .type: Theme.nsColor("#5DD8FF"),
            .call: Theme.nsColor("#67B7A4"),
            .property: Theme.nsColor("#67B7A4"),
            .dotAccess: Theme.nsColor("#67B7A4"),
            .number: Theme.nsColor("#D0BF69"),
            .comment: Theme.nsColor("#6C7986"),
            .string: Theme.nsColor("#FC6A5D"),
            .preprocessing: Theme.nsColor("#FD8F3F"),
        ],
        backgroundColor: .clear
    )
    private static let splashLightTheme = Splash.Theme(
        font: Splash.Font(size: 11.5),
        plainTextColor: Theme.nsColor("#262629"),
        tokenColors: [
            .keyword: Theme.nsColor("#AD3DA4"),
            .type: Theme.nsColor("#0B4F79"),
            .call: Theme.nsColor("#326D74"),
            .property: Theme.nsColor("#326D74"),
            .dotAccess: Theme.nsColor("#326D74"),
            .number: Theme.nsColor("#1C00CF"),
            .comment: Theme.nsColor("#5D6C79"),
            .string: Theme.nsColor("#D12F1B"),
            .preprocessing: Theme.nsColor("#78492A"),
        ],
        backgroundColor: .clear
    )
    private static let darkHighlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: splashDarkTheme))
    private static let lightHighlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: splashLightTheme))
    private static let codeCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 64
        return cache
    }()

    static func highlightedCode(_ code: String, dark: Bool = true) -> NSAttributedString {
        let key = "\(dark ? "d" : "l")|\(code)" as NSString
        if let cached = codeCache.object(forKey: key) { return cached }
        let highlighter = dark ? darkHighlighter : lightHighlighter
        let highlighted = NSMutableAttributedString(attributedString: highlighter.highlight(code))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        highlighted.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: highlighted.length))
        codeCache.setObject(highlighted, forKey: key)
        return highlighted
    }

    // MARK: - Math (SwiftMath)

    private static let mathCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func mathImage(_ latex: String, fontSize: CGFloat, display: Bool) -> NSImage? {
        let key = "\(appearanceKey)|\(display ? "d" : "t")|\(fontSize)|\(latex)" as NSString
        if let cached = mathCache.object(forKey: key) { return cached }
        let renderer = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: .labelColor,
            labelMode: display ? .display : .text
        )
        let (error, image) = renderer.asImage()
        guard error == nil, let image, image.size.width > 0 else { return nil }
        mathCache.setObject(image, forKey: key)
        return image
    }

    /// Matches `$…$` spans that plausibly contain math (no surrounding spaces, and
    /// either math syntax characters or no whitespace at all) and swaps them for
    /// placeholder tokens the markdown parser passes through untouched.
    private static func extractInlineMath(_ markdown: String) -> (String, [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\$([^\s$](?:[^$\n]*[^\s$])?)\$"#) else {
            return (markdown, [])
        }
        let text = markdown as NSString
        var parts: [String] = []
        var result = markdown
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            let content = text.substring(with: match.range(at: 1))
            let mathy = content.rangeOfCharacter(from: CharacterSet(charactersIn: "\\^_{}=")) != nil
                || !content.contains(" ")
            guard mathy else { continue }
            parts.insert(content, at: 0)
            let start = result.index(result.startIndex, offsetBy: match.range.location)
            let end = result.index(start, offsetBy: match.range.length)
            result.replaceSubrange(start..<end, with: "⟦M\(match.range.location)⟧")
        }
        // Re-key tokens by order of appearance so substitution can find them.
        var ordered = result
        var index = 0
        while let tokenRange = ordered.range(of: #"⟦M\d+⟧"#, options: .regularExpression) {
            ordered.replaceSubrange(tokenRange, with: "⟦MATH\(index)⟧")
            index += 1
        }
        return (ordered, parts)
    }

    private static func substituteInlineMath(in result: NSMutableAttributedString, parts: [String]) {
        for (index, latex) in parts.enumerated() {
            let token = "⟦MATH\(index)⟧"
            let range = (result.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            if let image = mathImage(latex, fontSize: NSFont.systemFontSize, display: false) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.capHeight - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                )
                result.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
            } else {
                result.replaceCharacters(in: range, with: "$\(latex)$")
            }
        }
    }
}

/// A selectable, wrapping (or horizontally scrolling, for code) text label with
/// document-style selection and clickable links.
struct SelectableText: NSViewRepresentable {
    let attributed: NSAttributedString
    var wraps = true
    /// Live ⌘F state for THIS view's text. Highlights add only
    /// `.backgroundColor`, which cannot change metrics — so `sizeThatFits` keeps
    /// keying on the UNPAINTED `attributed` and typing in the find field never
    /// re-measures the transcript.
    var find: TextFind?
    /// Delta 4 streaming fade for THIS view's text. Like `find`, it only
    /// multiplies alpha into `.foregroundColor` — metrics-neutral, so
    /// `sizeThatFits` keeps keying on the UNPAINTED `attributed` and a fade tick
    /// never re-measures the transcript.
    var reveal: TextReveal?

    /// Number of actual CoreText measurements performed (cache misses).
    /// Read by the --smoke-typing harness; main-thread only.
    nonisolated(unsafe) static var measurementCount = 0

    /// Per-view measurement cache. Keyed by attributed-string IDENTITY (cheap;
    /// finalized rows get the same cached instance from MarkdownRenderer, the
    /// streaming row gets a fresh instance per tick and correctly misses) and
    /// measured width. Layout probes each pass with a few proposals, so a small
    /// per-width map is kept rather than a single last-value slot.
    final class Coordinator {
        var cachedAttributed: NSAttributedString?
        var cachedWraps: Bool?
        var sizes: [CGFloat: CGSize] = [:]
        /// Last hit this view scrolled to — re-renders must not yank the
        /// transcript back to a match the user has already stepped past.
        var lastRevealed: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var displayed: NSAttributedString {
        var result = attributed
        if let find { result = FindHighlight.paint(result, find: find) }
        if let reveal { result = RevealFade.paint(result, reveal: reveal) }
        return result
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: displayed)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true // required for clickable links
        field.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = wraps
        field.cell?.isScrollable = !wraps
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let display = displayed
        if field.attributedStringValue != display {
            field.attributedStringValue = display
        }
        revealActiveMatch(in: field, coordinator: context.coordinator)
    }

    private func revealActiveMatch(in field: NSTextField, coordinator: Coordinator) {
        guard let find, let active = find.active else {
            coordinator.lastRevealed = nil
            return
        }
        let key = "\(find.query)#\(active)"
        guard coordinator.lastRevealed != key else { return }
        coordinator.lastRevealed = key
        let matches = FindHighlight.ranges(in: attributed.string, query: find.query)
        guard matches.indices.contains(active) else { return }
        let range = matches[active]
        let text = attributed
        let shouldWrap = wraps
        // After the layout pass that this update belongs to: the field may not
        // have its final width yet, and scrolling mid-layout fights SwiftUI.
        DispatchQueue.main.async { Self.reveal(range: range, of: text, wraps: shouldWrap, in: field) }
    }

    /// Scrolls so the matched CHARACTERS are on screen — not the message, which
    /// can be pages long. The range is laid out at the field's own width, then
    /// padded on top so the hit can't land under the header pills or find bar.
    private static func reveal(range: NSRange, of attributed: NSAttributedString, wraps: Bool, in field: NSTextField) {
        let width = field.bounds.width
        guard width > 1 else { return }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: wraps ? width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        // NSTextField lays text out top-down even though the view isn't flipped.
        let top = field.isFlipped ? bounds.minY : field.bounds.height - bounds.maxY
        let padded = NSRect(
            x: bounds.minX,
            y: top - revealTopInset,
            width: max(bounds.width, 1),
            height: bounds.height + revealTopInset + revealBottomInset
        )
        // Every enclosing scroller, innermost first: a hit inside a code block
        // has to move the block's horizontal scroller AND the transcript.
        var walker: NSView = field
        while let scroll = walker.enclosingScrollView {
            if let document = scroll.documentView {
                document.scrollToVisible(field.convert(padded, to: document))
            }
            walker = scroll
        }
    }

    private static let revealTopInset: CGFloat = 96 // header pills + find bar
    private static let revealBottomInset: CGFloat = 48

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        // Deterministic for every proposal (nil/zero/infinite all measure as a
        // single line) — a mixed nil/measured response can make container layouts
        // oscillate and never converge.
        let maxWidth: CGFloat
        if wraps, let width = proposal.width, width > 0, width.isFinite {
            maxWidth = width
        } else {
            maxWidth = .greatestFiniteMagnitude
        }
        let coordinator = context.coordinator
        if coordinator.cachedAttributed !== attributed || coordinator.cachedWraps != wraps {
            coordinator.cachedAttributed = attributed
            coordinator.cachedWraps = wraps
            coordinator.sizes.removeAll()
        }
        if let cached = coordinator.sizes[maxWidth] {
            return cached
        }
        Self.measurementCount += 1
        let bounds = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = min(ceil(bounds.width) + 2, maxWidth)
        let size = CGSize(width: width, height: ceil(bounds.height) + 2)
        coordinator.sizes[maxWidth] = size
        return size
    }
}

/// Assistant message body: prose sections with document-style selection, plus
/// styled blocks for code, quotes, tables and display math. While streaming, a
/// blinking caret rides the end of the text.
struct AssistantMessageView: View {
    let text: String
    var showCaret = false
    var find: MessageFind?
    /// Delta 4: the fade over just-revealed text. It lands on the LAST segment —
    /// the only one the drain can be appending to.
    var reveal: TextReveal?

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex

    var body: some View {
        let segments = MarkdownRenderer.segments(text)
        let finds = segmentFinds(segments)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let segmentFind = finds[index].first ?? nil
                let last = index == segments.count - 1
                switch segment {
                case .prose(let prose):
                    // While streaming, the last prose segment carries a steady
                    // (non-blinking) inline caret — a timer-driven blink here would
                    // re-evaluate and re-layout the transcript on every tick.
                    let caret = showCaret && last
                    SelectableText(
                        attributed: MarkdownRenderer.attributedProse(
                            prose,
                            caret: caret ? Theme.nsColor(accentHex) : nil
                        ),
                        find: segmentFind,
                        // The caret glyph rides the HEAD of the fade rather than
                        // being part of it, so it stays solid.
                        reveal: last ? reveal.map { fade(over: prose, $0, caret: caret ? 1 : 0) } : nil
                    )
                case .code(let language, let content):
                    CodeBlockView(
                        language: language, content: content, find: segmentFind,
                        reveal: last ? reveal.map { fade(over: content, $0, caret: 0) } : nil
                    )
                case .quote(let quote):
                    QuoteBlockView(text: quote, find: segmentFind)
                case .table(let header, let rows):
                    TableBlockView(header: header, rows: rows, cellFinds: finds[index])
                case .math(let latex):
                    MathBlockView(latex: latex)
                case .pasteable(let title, let content):
                    PasteableBlockView(title: title, content: content, find: segmentFind)
                }
            }
            if showCaret, !(segments.last?.isProse ?? false) {
                BlinkingCaret(color: Theme.color(accentHex))
            }
        }
    }

    /// Fits the drain's fade onto one segment. The stop lengths are counted in
    /// SOURCE characters while the painted string is RENDERED text (markdown
    /// syntax stripped, inline math swapped for attachments), so the head can sit
    /// a few characters off — invisible in a soft tail gradient. Clamping is not
    /// optional though: a head longer than this segment would otherwise bleed the
    /// ramp back across text that settled long ago.
    private func fade(over source: String, _ reveal: TextReveal, caret: Int) -> TextReveal {
        var budget = source.count
        var stops: [TextReveal.Stop] = []
        for stop in reveal.stops {
            guard budget > 0 else { break }
            let length = min(stop.length, budget)
            stops.append(TextReveal.Stop(length: length, alpha: stop.alpha))
            budget -= length
        }
        return TextReveal(stops: stops, trailingSkip: caret)
    }

    /// One highlight context per text view, walked in the same order
    /// `MarkdownRenderer.searchableStrings` counts occurrences — that shared
    /// order is what keeps "7 of 12" pointing at the range actually painted.
    /// Segments with no match yield nil, so their attributed strings stay
    /// identical and the render/measurement caches keep hitting.
    private func segmentFinds(_ segments: [MarkdownRenderer.Segment]) -> [[TextFind?]] {
        guard var cursor = FindCursor(find) else { return segments.map { _ in [nil] } }
        return segments.map { cursor.next(all: MarkdownRenderer.searchableStrings($0)) }
    }
}

/// Blink is a repeat-forever opacity animation — rendered by Core Animation, so
/// it never re-evaluates SwiftUI bodies or triggers layout.
private struct BlinkingCaret: View {
    let color: SwiftUI.Color
    @State private var dimmed = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1.5, height: 14)
            .opacity(dimmed ? 0.1 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

struct CodeBlockView: View {
    let language: String?
    let content: String
    var find: TextFind?
    var reveal: TextReveal?

    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Recessed surface (4f): dark = black 35% with the Xcode-dark palette,
        // light = black 5% with the Xcode-light palette — the block recesses in
        // both modes instead of staying a dark slab on a light panel.
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.recessedCaption(dark: dark))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.recessedCaption(dark: dark))
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.recessedHeader(dark: dark))
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(
                    attributed: MarkdownRenderer.highlightedCode(content, dark: dark),
                    wraps: false, find: find, reveal: reveal
                )
                .padding(10)
            }
        }
        .background(Theme.recessedFill(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.recessedBorder(dark: dark), lineWidth: 0.5))
        .padding(.vertical, 2)
    }
}

struct QuoteBlockView: View {
    let text: String
    var find: TextFind?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.3))
                .frame(width: 2)
            SelectableText(attributed: MarkdownRenderer.attributedProse(text), find: find)
                .opacity(0.65)
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]
    /// One entry per cell, in `MarkdownRenderer.searchableStrings` order.
    var cellFinds: [TextFind?] = []

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    cellView(cell, header: true, find: cellFind(row: nil, column: column))
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.2))
                .frame(height: 1)
                .gridCellColumns(max(header.count, 1))
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, header: false, find: cellFind(row: rowIndex, column: column))
                    }
                }
                if rowIndex < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 0.5)
                        .gridCellColumns(max(header.count, 1))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func cellView(_ text: String, header: Bool, find: TextFind?) -> some View {
        SelectableText(attributed: MarkdownRenderer.tableCell(text, bold: header), find: find)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    /// Cells are numbered header-first, then row by row — the order
    /// `MarkdownRenderer.searchableStrings` emits them in.
    private func cellFind(row: Int?, column: Int) -> TextFind? {
        var index = column
        if let row {
            index += header.count + rows.prefix(row).reduce(0) { $0 + $1.count }
        }
        return cellFinds.indices.contains(index) ? cellFinds[index] : nil
    }
}

/// Reusable content marked by the model for one-click copying. Shown verbatim
/// (no markdown parsing) — what you see is exactly what the Copy button copies.
///
/// Lifted neutral surface (4c): chat text sits flat on glass, code recesses,
/// pasteables lift — light fill + hairline, clipboard glyph leading: "take
/// this". Accent marks only the action: the Copy capsule.
struct PasteableBlockView: View {
    let title: String?
    let content: String
    var find: TextFind?

    @State private var copied = false
    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex
    @Environment(\.colorScheme) private var scheme

    private var accent: SwiftUI.Color { Theme.color(accentHex) }

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(title ?? "Pasteable")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(copied ? .white : accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(copied ? accent : accent.opacity(0.16), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Copy this block")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
                .overlay(Theme.liftedDivider(dark: dark))
            SelectableText(attributed: MarkdownRenderer.plain(content, size: 12.5), find: find)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(Theme.liftedFill(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.liftedBorder(dark: dark), lineWidth: 0.5)
        )
        .padding(.vertical, 2)
    }
}

struct MathBlockView: View {
    let latex: String

    var body: some View {
        if let image = MarkdownRenderer.mathImage(latex, fontSize: 17, display: true) {
            Image(nsImage: image)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            // Explicit fallback: show the raw TeX rather than silently dropping it.
            SelectableText(attributed: MarkdownRenderer.plain("$$\(latex)$$", monospaced: true))
        }
    }
}
