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

    // MARK: - Prose → NSAttributedString

    // Bounded: streaming produces a new string per tick, so uncapped caches would
    // fill with thousands of one-off intermediate entries.
    private static let proseCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        return cache
    }()

    static func attributedProse(_ markdown: String, caret: NSColor? = nil) -> NSAttributedString {
        let base: NSAttributedString
        if let cached = proseCache.object(forKey: markdown as NSString) {
            base = cached
        } else {
            base = buildProse(markdown)
            proseCache.setObject(base, forKey: markdown as NSString)
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

    static func plain(_ text: String, monospaced: Bool = false, color: NSColor = .labelColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = monospaced ? 4 : 3
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Syntax highlighting (Splash, Xcode-dark palette)

    private static let splashTheme = Splash.Theme(
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
    private static let highlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: splashTheme))
    private static let codeCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 64
        return cache
    }()

    static func highlightedCode(_ code: String) -> NSAttributedString {
        if let cached = codeCache.object(forKey: code as NSString) { return cached }
        let highlighted = NSMutableAttributedString(attributedString: highlighter.highlight(code))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        highlighted.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: highlighted.length))
        codeCache.setObject(highlighted, forKey: code as NSString)
        return highlighted
    }

    // MARK: - Math (SwiftMath)

    private static let mathCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func mathImage(_ latex: String, fontSize: CGFloat, display: Bool) -> NSImage? {
        let key = "\(display ? "d" : "t")|\(fontSize)|\(latex)" as NSString
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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributed)
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
        if field.attributedStringValue != attributed {
            field.attributedStringValue = attributed
        }
    }

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

    @AppStorage("accentColor") private var accentHex = Theme.defaultAccentHex

    var body: some View {
        let segments = MarkdownRenderer.segments(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .prose(let prose):
                    // While streaming, the last prose segment carries a steady
                    // (non-blinking) inline caret — a timer-driven blink here would
                    // re-evaluate and re-layout the transcript on every tick.
                    SelectableText(attributed: MarkdownRenderer.attributedProse(
                        prose,
                        caret: showCaret && index == segments.count - 1 ? Theme.nsColor(accentHex) : nil
                    ))
                case .code(let language, let content):
                    CodeBlockView(language: language, content: content)
                case .quote(let quote):
                    QuoteBlockView(text: quote)
                case .table(let header, let rows):
                    TableBlockView(header: header, rows: rows)
                case .math(let latex):
                    MathBlockView(latex: latex)
                }
            }
            if showCaret, !(segments.last?.isProse ?? false) {
                BlinkingCaret(color: Theme.color(accentHex))
            }
        }
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

    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: Theme.nsColor("#DFDFE6")).opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(nsColor: Theme.nsColor("#DFDFE6")).opacity(0.5))
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(attributed: MarkdownRenderer.highlightedCode(content), wraps: false)
                    .padding(10)
            }
        }
        // The Xcode-dark palette needs a dark backdrop in both appearances.
        .background(Color.black.opacity(scheme == .dark ? 0.35 : 0.78))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .padding(.vertical, 2)
    }
}

struct QuoteBlockView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.3))
                .frame(width: 2)
            SelectableText(attributed: MarkdownRenderer.attributedProse(text))
                .opacity(0.65)
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    cellView(cell, header: true)
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.2))
                .frame(height: 1)
                .gridCellColumns(max(header.count, 1))
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, header: false)
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

    private func cellView(_ text: String, header: Bool) -> some View {
        SelectableText(attributed: inlineAttributed(text, bold: header))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func inlineAttributed(_ text: String, bold: Bool) -> NSAttributedString {
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
