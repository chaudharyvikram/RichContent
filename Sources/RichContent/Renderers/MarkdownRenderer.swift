import UIKit

/// Markdown → NSAttributedString with real block layout.
///
/// `AttributedString(markdown:)` parses block structure into
/// `presentationIntent`, but UIKit / SwiftUI text ignore it, so headings,
/// lists, quotes, code blocks and tables would otherwise collapse into one
/// line. This walks the runs and turns each block into styled paragraphs.
enum MarkdownRenderer {

    static func render(markdown: String, style: RichContentStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let source = convertInlineHTML(markdown)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return PlainTextRenderer.render(markdown, style: style)
        }
        return render(parsed: parsed, style: style)
    }

    /// Also used for `AttributedString`s that were built from Markdown.
    static func render(parsed: AttributedString, style: RichContentStyle) -> NSAttributedString {
        var paragraphs: [Paragraph] = []

        for run in parsed.runs {
            let intent = run.presentationIntent
            let key = paragraphKey(intent)
            let cell = tableCellID(intent)

            if paragraphs.isEmpty || paragraphs[paragraphs.count - 1].key != key {
                paragraphs.append(Paragraph(intent: intent, key: key, cellID: cell))
            } else if cell != nil, paragraphs[paragraphs.count - 1].cellID != cell {
                paragraphs[paragraphs.count - 1].text.append(NSAttributedString(string: "\t"))
                paragraphs[paragraphs.count - 1].cellID = cell
            }

            var text = String(parsed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.softBreak) {
                text = style.preservesMarkdownLineBreaks ? "\u{2028}" : " "
            } else if inline.contains(.lineBreak) {
                text = "\u{2028}"
            }

            let block = MarkdownBlockInfo(intent)
            var font = block.headerLevel.map { headerFont(level: $0, style: style) } ?? style.font
            if let uiFont = run[AttributeScopes.UIKitAttributes.FontAttribute.self] { font = uiFont }

            var traits: UIFontDescriptor.SymbolicTraits = []
            if inline.contains(.stronglyEmphasized) || block.isTableHeader { traits.insert(.traitBold) }
            if inline.contains(.emphasized) { traits.insert(.traitItalic) }

            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: run[AttributeScopes.UIKitAttributes.ForegroundColorAttribute.self] ?? style.textColor
            ]
            if inline.contains(.code) || block.isCode {
                font = style.codeFont.withSize(font.pointSize * 0.92)
                attrs[.backgroundColor] = style.codeBackgroundColor
            }
            attrs[.font] = font.adding(traits)
            if inline.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link { attrs[.link] = link }

            paragraphs[paragraphs.count - 1].text.append(NSAttributedString(string: text, attributes: attrs))
        }

        return assemble(paragraphs, style: style)
    }

    // MARK: - Inline HTML inside Markdown

    /// Apple's parser shows inline HTML as literal text, so common inline tags
    /// are rewritten as Markdown first. Code spans and fenced code are left
    /// alone, and autolinks like `<https://…>` are kept.
    static func convertInlineHTML(_ markdown: String) -> String {
        guard markdown.contains("<") else { return markdown }
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return line
            }
            guard !inFence, line.contains("<") else { return line }
            return line.components(separatedBy: "`").enumerated().map { index, part in
                index % 2 == 0 ? rewriteInlineTags(part) : part
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }

    private static func rewriteInlineTags(_ text: String) -> String {
        var s = text
        for (regex, template) in inlineTagRewrites {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    private static let inlineTagRewrites: [(NSRegularExpression, String)] = [
        (#"<br\s*/?>"#, "\u{2028}"),
        (#"<(b|strong)\b[^>]*>(.*?)</\1\s*>"#, "**$2**"),
        (#"<(i|em)\b[^>]*>(.*?)</\1\s*>"#, "*$2*"),
        (#"<(s|strike|del)\b[^>]*>(.*?)</\1\s*>"#, "~~$2~~"),
        (#"<code\b[^>]*>(.*?)</code\s*>"#, "`$1`"),
        (#"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#, "[$2]($1)"),
        (#"</?(span|font|u|small|mark|sup|sub)\b[^>]*>"#, "")
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    // MARK: - Paragraph assembly

    private struct Paragraph {
        var text = NSMutableAttributedString()
        var intent: PresentationIntent?
        var key: Int?
        var cellID: Int?

        init(intent: PresentationIntent?, key: Int?, cellID: Int?) {
            self.intent = intent
            self.key = key
            self.cellID = cellID
        }
    }

    private static func assemble(_ paragraphs: [Paragraph], style: RichContentStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var lastListItemID: Int?

        for paragraph in paragraphs {
            let piece = paragraph.text
            let block = MarkdownBlockInfo(paragraph.intent)

            // Trailing newlines inside a block (code blocks end with one).
            while piece.string.hasSuffix("\n") {
                piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1))
            }
            guard piece.length > 0 else { continue }

            // List marker on the first paragraph of each item.
            if let item = block.listItem, item.id != lastListItemID {
                let marker = block.ordered
                    ? "\(item.ordinal).\t"
                    : ["•", "◦", "▪︎"][max(block.listDepth - 1, 0) % 3] + "\t"
                piece.insert(NSAttributedString(string: marker, attributes: [
                    .font: style.font,
                    .foregroundColor: style.secondaryTextColor
                ]), at: 0)
            }
            lastListItemID = block.listItem?.id

            let full = NSRange(location: 0, length: piece.length)
            let p = TextKitHelpers.paragraphStyle(
                style,
                spacing: block.listItem != nil ? style.paragraphSpacing / 2 : style.paragraphSpacing
            )
            if block.headerLevel != nil {
                p.paragraphSpacingBefore = style.paragraphSpacing / 2
            }
            if block.listDepth > 0 {
                let base = CGFloat(block.listDepth - 1) * style.listIndent
                p.firstLineHeadIndent = base
                p.headIndent = base + style.listIndent
                p.tabStops = [NSTextTab(textAlignment: .natural, location: base + style.listIndent)]
                p.defaultTabInterval = style.listIndent
            } else if block.isTable {
                p.tabStops = []
                p.defaultTabInterval = 110
            }
            piece.addAttribute(.paragraphStyle, value: p, range: full)

            TextKitHelpers.applyQuote(piece, range: full, depth: block.quoteDepth, style: style)
            TextKitHelpers.appendParagraph(piece, to: result)
        }
        return result
    }

    private static func headerFont(level: Int, style: RichContentStyle) -> UIFont {
        let scale: [CGFloat] = [1.45, 1.3, 1.18, 1.08, 1.0, 0.95]
        let factor = scale[max(0, min(scale.count - 1, level - 1))]
        return style.font.withSize(style.font.pointSize * factor).adding(.traitBold)
    }

    /// Paragraph identity: the table row for table content (cells join with
    /// tabs), otherwise the innermost block.
    private static func paragraphKey(_ intent: PresentationIntent?) -> Int? {
        guard let intent else { return nil }
        for component in intent.components {
            switch component.kind {
            case .tableRow, .tableHeaderRow: return component.identity
            default: continue
            }
        }
        return intent.components.first?.identity
    }

    private static func tableCellID(_ intent: PresentationIntent?) -> Int? {
        intent?.components.first { component in
            if case .tableCell = component.kind { return true }
            return false
        }?.identity
    }
}

/// Flattened description of a run's block nesting.
private struct MarkdownBlockInfo {
    var headerLevel: Int?
    var quoteDepth = 0
    var listDepth = 0
    var ordered = false
    var isCode = false
    var isTable = false
    var isTableHeader = false
    var listItem: (id: Int, ordinal: Int)?

    init(_ intent: PresentationIntent?) {
        guard let components = intent?.components else { return }
        var resolvedListKind = false
        // `components` runs from innermost to outermost.
        for component in components {
            switch component.kind {
            case .header(let level):
                headerLevel = level
            case .blockQuote:
                quoteDepth += 1
            case .listItem(let ordinal):
                if listItem == nil { listItem = (component.identity, ordinal) }
            case .orderedList:
                listDepth += 1
                if listItem != nil && !resolvedListKind { ordered = true; resolvedListKind = true }
            case .unorderedList:
                listDepth += 1
                if listItem != nil && !resolvedListKind { resolvedListKind = true }
            case .codeBlock:
                isCode = true
            case .tableHeaderRow:
                isTable = true
                isTableHeader = true
            case .table, .tableRow, .tableCell:
                isTable = true
            default:
                break
            }
        }
    }
}
