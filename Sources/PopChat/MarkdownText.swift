import AppKit
import SwiftUI

/// Native markdown rendering with real text selection. SwiftUI's `.textSelection`
/// is per-Text-view (selection can't cross paragraphs), so assistant messages are
/// rendered as NSTextField labels — one per prose section — where selection behaves
/// like a normal document. Code fences are split out and get their own styled block
/// with a copy button.
enum MarkdownRenderer {
    enum Segment {
        case prose(String)
        case code(language: String?, content: String)
    }

    /// Splits on ``` fences. An unclosed fence (mid-stream) renders as code.
    static func segments(_ markdown: String) -> [Segment] {
        var result: [Segment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.prose(text)) }
            proseLines = []
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: language, content: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushProse()
                    let hint = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = hint.isEmpty ? nil : hint
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        if inCode {
            result.append(.code(language: language, content: codeLines.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return result
    }

    // MARK: - Prose → NSAttributedString

    static func attributedProse(_ markdown: String) -> NSAttributedString {
        let baseSize = NSFont.systemFontSize
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
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
                font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = headerLevel > 0 ? 8 : 6
            paragraph.lineSpacing = 1.5
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
                attributes[.backgroundColor] = NSColor.gray.withAlphaComponent(0.15)
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

        return result.length > 0 ? result : plain(markdown)
    }

    static func plain(_ text: String, monospaced: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize * 0.9, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }
}

/// A selectable, wrapping (or horizontally scrolling, for code) text label with
/// document-style selection and clickable links.
struct SelectableText: NSViewRepresentable {
    let attributed: NSAttributedString
    var wraps = true

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
        let maxWidth: CGFloat
        if wraps {
            guard let width = proposal.width, width > 0, width.isFinite else { return nil }
            maxWidth = width
        } else {
            maxWidth = .greatestFiniteMagnitude
        }
        let bounds = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = wraps ? min(ceil(bounds.width) + 2, maxWidth) : ceil(bounds.width) + 2
        return CGSize(width: width, height: ceil(bounds.height) + 2)
    }
}

/// Assistant message body: prose sections with document-style selection,
/// code fences as styled blocks with a copy button.
struct AssistantMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownRenderer.segments(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    SelectableText(attributed: MarkdownRenderer.attributedProse(prose))
                case .code(let language, let content):
                    CodeBlockView(language: language, content: content)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let content: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(attributed: MarkdownRenderer.plain(content, monospaced: true), wraps: false)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(.vertical, 2)
    }
}
