import UIKit

/// Turns any `RichContent` (HTML, Markdown, plain, attributed, mixed) into
/// editor blocks. HTML goes through `EditorHTMLParser`, Markdown through
/// Apple's parser (block structure from `presentationIntent`), plain text is
/// read line by line, and already-rendered attributed text is mapped by its
/// fonts, list markers and quote bars.
@MainActor
enum EditorImporter {

    static func editorModel(from content: RichContent, style: RichContentStyle) -> NSMutableAttributedString {
        EditorDocument.attributedString(from: blocks(from: content), style: style)
    }

    static func blocks(from content: RichContent) -> [EditorBlock] {
        var result: [EditorBlock] = []
        for part in content.flattened {
            switch part {
            case .plain(let text): result += plainBlocks(text)
            case .markdown(let text): result += markdownBlocks(text)
            case .html(let html): result += EditorHTMLParser.blocks(fromHTML: html)
            case .attributed(let attributed):
                if attributed.runs.contains(where: { $0.presentationIntent != nil }) {
                    result += markdownBlocks(parsed: attributed)
                } else {
                    let converted = (try? NSAttributedString(attributed, including: \.uiKit)) ?? NSAttributedString(attributed)
                    result += renderedBlocks(converted)
                }
            case .nsAttributed(let attributed): result += renderedBlocks(attributed)
            case .auto, .mixed: break   // resolved by `flattened`
            }
        }
        return result
    }

    // MARK: - Plain text

    /// One block per line. Understands "> " quotes, "- " / "* " / "• "
    /// bullets, "1. " numbers, "[ ] " to-dos and indentation (2 spaces / tab).
    static func plainBlocks(_ text: String) -> [EditorBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [EditorBlock] = []
        for raw in lines {
            var line = Substring(raw)
            var indent = 0
            while let first = line.first, first == " " || first == "\t" {
                indent += first == "\t" ? 2 : 1
                line = line.dropFirst()
            }
            let level = 1 + indent / 2
            if line.hasPrefix(">") {
                var depthLine = line
                while depthLine.hasPrefix(">") { depthLine = depthLine.dropFirst(); if depthLine.hasPrefix(" ") { depthLine = depthLine.dropFirst() } }
                blocks.append(EditorBlock(.quote, level: level, text: String(depthLine)))
                continue
            }
            if let (type, checked, rest) = listMarker(line) {
                var block = EditorBlock(type, level: level, text: String(rest))
                block.info.checked = checked
                blocks.append(block)
                continue
            }
            blocks.append(EditorBlock(.paragraph, level: indent >= 2 ? level : 1, text: String(line)))
        }
        // Blank lines between paragraphs are spacing, not content.
        var compact: [EditorBlock] = []
        for block in blocks {
            if block.info.type == .paragraph, block.text.trimmingCharacters(in: .whitespaces).isEmpty,
               compact.last.map({ $0.info.type == .paragraph && $0.text.isEmpty }) ?? true { continue }
            compact.append(block)
        }
        while compact.last?.info.type == .paragraph && compact.last?.text.isEmpty == true { compact.removeLast() }
        return compact
    }

    private static func listMarker(_ line: Substring) -> (RichBlockType, Bool, Substring)? {
        for (prefix, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("[ ] ", false), ("[x] ", true),
                                  ("☐ ", false), ("☑ ", true)] where line.hasPrefix(prefix) {
            return (.todo, checked, line.dropFirst(prefix.count))
        }
        for prefix in ["- ", "* ", "• ", "◦ ", "▪ ", "+ "] where line.hasPrefix(prefix) {
            return (.bulletList, false, line.dropFirst(prefix.count))
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           (1...3).contains(line[..<dot].count), line[..<dot].allSatisfy(\.isNumber),
           line[line.index(after: dot)...].hasPrefix(" ") {
            return (.numberedList, false, line[line.index(dot, offsetBy: 2)...])
        }
        return nil
    }

    // MARK: - Markdown

    static func markdownBlocks(_ markdown: String) -> [EditorBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let source = markThematicBreaks(MarkdownRenderer.convertInlineHTML(markdown))
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return plainBlocks(markdown) }
        return markdownBlocks(parsed: parsed)
    }

    private static let breakSentinel = "\u{E010}"

    /// Apple's parser drops thematic breaks (they have no text), so `---`
    /// lines become a sentinel paragraph first. A `---` right under text is a
    /// setext heading and is left alone.
    private static func markThematicBreaks(_ markdown: String) -> String {
        var inFence = false
        var previousBlank = true
        return markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            defer { previousBlank = trimmed.isEmpty }
            guard !inFence, previousBlank, thematicBreak.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            else { return line }
            return breakSentinel + "\n"
        }.joined(separator: "\n")
    }
    private static let thematicBreak = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    static func markdownBlocks(parsed: AttributedString) -> [EditorBlock] {
        var blocks: [EditorBlock] = []
        var currentKey: Int?
        var current: EditorBlock?
        var text = NSMutableAttributedString()
        var seenListItems = Set<Int>()
        var lastCell: Int?

        func flush() {
            guard var block = current else { return }
            current = nil
            if block.info.type == .codeBlock {
                while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
                text.mutableString.replaceOccurrences(of: "\n", with: EditorStyling.lineBreak, options: [],
                                                      range: NSRange(location: 0, length: text.length))
            }
            if text.string == breakSentinel {
                blocks.append(EditorBlock(.divider, level: block.info.level))
            } else if text.length > 0 || block.info.type != .paragraph {
                block.content = text
                blocks.append(block)
            }
            text = NSMutableAttributedString()
        }

        for run in parsed.runs {
            let intent = run.presentationIntent
            let key = paragraphKey(intent)
            if key != currentKey || current == nil {
                flush()
                currentKey = key
                current = block(for: intent, seenListItems: &seenListItems)
                lastCell = nil
            }
            if let cell = tableCell(intent), cell != lastCell {
                if lastCell != nil { text.append(NSAttributedString(string: "\t")) }
                lastCell = cell
            }

            var inline = InlineInfo()
            let intents = run.inlinePresentationIntent ?? []
            inline.bold = intents.contains(.stronglyEmphasized) || isTableHeader(intent)
            inline.italic = intents.contains(.emphasized)
            inline.code = intents.contains(.code) && current?.info.type != .codeBlock
            inline.strike = intents.contains(.strikethrough)
            inline.link = run.link

            if let imageURL = run.imageURL {
                // Images are blocks: end the paragraph, add the image, continue.
                let level = current?.info.level ?? 1
                let alt = String(parsed[run.range].characters)
                let resume = current
                flush()
                var image = EditorBlock(.image, level: level)
                image.image = EditorImage(source: imageURL.absoluteString, alt: alt)
                blocks.append(image)
                if var resumed = resume {
                    if resumed.info.type.hasMarker { resumed.info.type = .paragraph; resumed.info.level += 1 }
                    current = resumed
                }
                continue
            }

            var string = String(parsed[run.range].characters)
            if intents.contains(.softBreak) || intents.contains(.lineBreak) { string = EditorStyling.lineBreak }
            text.append(NSAttributedString(string: string, attributes: inline.attributes))
        }
        flush()
        return EditorHTMLParser.postProcess(blocks)
    }

    private static func block(for intent: PresentationIntent?, seenListItems: inout Set<Int>) -> EditorBlock {
        guard let components = intent?.components else { return EditorBlock(.paragraph) }
        var heading: Int?
        var listDepth = 0
        var listItem: Int?
        var innermostList: RichBlockType?
        var quote = false
        var code = false
        var language: String?

        for component in components {   // innermost → outermost
            switch component.kind {
            case .header(let level): heading = level
            case .listItem: if listItem == nil { listItem = component.identity }
            case .orderedList:
                listDepth += 1
                if innermostList == nil { innermostList = .numberedList }
            case .unorderedList:
                listDepth += 1
                if innermostList == nil { innermostList = .bulletList }
            case .blockQuote: quote = true
            case .codeBlock(let hint): code = true; language = hint
            default: break
            }
        }

        let level = max(listDepth, 1)
        if code {
            var block = EditorBlock(.codeBlock, level: level)
            block.info.language = language
            return block
        }
        if let heading {
            return EditorBlock(heading == 1 ? .heading1 : heading == 2 ? .heading2 : .heading3, level: level)
        }
        if let item = listItem, let list = innermostList {
            // The first paragraph of an item is the item; later ones are children.
            if seenListItems.insert(item).inserted { return EditorBlock(list, level: level) }
            return EditorBlock(.paragraph, level: level + 1)
        }
        return EditorBlock(quote ? .quote : .paragraph, level: level)
    }

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

    private static func tableCell(_ intent: PresentationIntent?) -> Int? {
        intent?.components.first { if case .tableCell = $0.kind { return true }; return false }?.identity
    }

    private static func isTableHeader(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains { if case .tableHeaderRow = $0.kind { return true }; return false } ?? false
    }

    // MARK: - Rendered attributed text

    /// Text that was already laid out (viewer output, `NSAttributedString`
    /// from elsewhere): list marker text ("•\t", "1.\t") becomes a list
    /// block, quote depth a quote, big bold paragraphs headings, all-monospace
    /// paragraphs code blocks; bold / italic come from font traits.
    static func renderedBlocks(_ s: NSAttributedString) -> [EditorBlock] {
        let ns = s.string as NSString
        let baseSize = mostCommonFontSize(s)
        var blocks: [EditorBlock] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byParagraphs, .substringNotRequired]) { _, content, _, _ in
            var range = content
            let text = ns.substring(with: range)
            var block = EditorBlock(.paragraph)

            if let m = renderedListMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let marker = (text as NSString).substring(with: m.range(at: 2))
                block.info.type = marker.first?.isNumber == true || marker.first?.isLetter == true ? .numberedList : .bulletList
                if let p = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle, p.headIndent > 0 {
                    block.info.level = min(max(Int((p.headIndent / 20).rounded()), 1), EditorStyling.maxLevel)
                }
                range = NSRange(location: range.location + m.range.length, length: range.length - m.range.length)
            } else if range.length > 0, (s.attribute(.richQuoteDepth, at: range.location, effectiveRange: nil) as? Int ?? 0) > 0 {
                block.info.type = .quote
            } else if range.length > 0, isAllMonospaced(s, range) {
                block.info.type = .codeBlock
            } else if range.length > 0, let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont {
                let ratio = font.pointSize / baseSize
                if ratio >= 1.38 { block.info.type = .heading1 }
                else if ratio >= 1.2 { block.info.type = .heading2 }
                else if ratio >= 1.08 && font.isBold { block.info.type = .heading3 }
            }

            let out = NSMutableAttributedString()
            if range.length > 0 {
                s.enumerateAttributes(in: range) { attrs, r, _ in
                    var inline = InlineInfo(attrs)
                    if let font = attrs[.font] as? UIFont {
                        inline.bold = font.isBold && !block.info.type.isHeading
                        inline.italic = font.isItalic
                        inline.code = font.isMonospaced && block.info.type != .codeBlock
                    }
                    inline.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0 && inline.link == nil
                    inline.strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
                    out.append(NSAttributedString(string: ns.substring(with: r), attributes: inline.attributes))
                }
            }
            block.content = out
            blocks.append(block)
        }
        return EditorHTMLParser.postProcess(blocks)
    }

    private static let renderedListMarker = try! NSRegularExpression(
        pattern: #"^([\t ]*)(•|◦|▪︎|▪|‣|-|\d+[.)]|[a-z][.)]|[ivxlc]+[.)])\t"#)

    private static func isAllMonospaced(_ s: NSAttributedString, _ range: NSRange) -> Bool {
        var all = true
        s.enumerateAttribute(.font, in: range) { value, _, stop in
            if (value as? UIFont)?.isMonospaced != true { all = false; stop.pointee = true }
        }
        return all
    }

    private static func mostCommonFontSize(_ s: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, r, _ in
            if let font = value as? UIFont { counts[font.pointSize, default: 0] += r.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? UIFont.preferredFont(forTextStyle: .body).pointSize
    }
}
