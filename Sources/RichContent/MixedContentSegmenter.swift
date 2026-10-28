import Foundation

/// Splits one string that mixes formats (an HTML document, then Markdown
/// notes, then a plain-text reply, …) into parts that can each be rendered
/// with the right renderer.
///
/// Rules, applied line by line:
/// - A line starting with a block-level tag (`<div`, `<table`, `<!DOCTYPE`, …)
///   opens an HTML section. A line starting with an inline tag (`<b>`, `<a>`,
///   `<span>` …) only does when it leaves tags open or holds a block tag, so
///   `<b>Note:</b> text` inside Markdown stays Markdown.
/// - The section stays open while tags are unbalanced, and continues across
///   following lines that also start with a tag. An unclosed `<p>`, `<li>`,
///   `<td>` … keeps it open until the next blank line.
/// - A blank line, or a non-tag line once everything is closed, closes it.
/// - Lines inside ``` code fences are never treated as HTML.
/// - Everything else is text, classified as Markdown or plain.
enum MixedContentSegmenter {

    static func segments(of string: String) -> [RichContent] {
        let lines = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var parts: [RichContent] = []
        var text: [String] = []
        var html: [String] = []
        var inHTML = false
        var inFence = false
        var depth = 0
        var softDepth = 0
        /// Start of a tag that continues on the next line (`<img src=` ⏎ `"…" >`).
        var openTag = ""

        func flushText() {
            defer { text.removeAll() }
            for chunk in splitOnBlankRuns(text) {
                guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                parts.append(classifyText(chunk))
            }
        }

        func flushHTML() {
            let chunk = html.joined(separator: "\n")
            html.removeAll()
            inHTML = false
            depth = 0
            softDepth = 0
            openTag = ""
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parts.append(.html(chunk))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inHTML, !inFence, opensHTML(trimmed) {
                flushText()
                inHTML = true
            }

            if inHTML {
                let closed = depth == 0 && (softDepth == 0 || trimmed.isEmpty) && openTag.isEmpty
                if closed, !html.isEmpty, !matches(tagLineStart, trimmed) {
                    flushHTML()           // falls through: this line is text
                } else {
                    html.append(line)
                    // A tag split across lines counts once, when it's complete.
                    let (complete, unfinished) = splitUnfinishedTag(openTag + "\n" + line)
                    openTag = unfinished.count > 20_000 ? "" : unfinished   // never swallow everything
                    let delta = tagDepthDelta(complete)
                    depth = max(0, depth + delta.hard)
                    softDepth = max(0, softDepth + delta.soft)
                    continue
                }
            }

            if trimmed.hasPrefix("```") { inFence.toggle() }
            text.append(line)
        }

        flushHTML()
        flushText()
        return parts
    }

    /// Two or more blank lines (outside code fences) separate independently
    /// classified text sections, e.g. Markdown notes followed by a plain reply.
    private static func splitOnBlankRuns(_ lines: [String]) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var blankRun = 0
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty && !inFence {
                blankRun += 1
                if blankRun == 2, !current.isEmpty {
                    chunks.append(current.joined(separator: "\n"))
                    current.removeAll()
                }
                if blankRun < 2 { current.append(line) }
                continue
            }
            blankRun = 0
            current.append(line)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks.map { dedent($0) }
    }

    /// Removes indentation shared by every non-blank line. Swift multi-line
    /// literals and server templates often indent the whole body, and 4+
    /// spaces would otherwise turn Markdown into a code block.
    static func dedent(_ chunk: String) -> String {
        let lines = chunk.components(separatedBy: "\n")
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        guard let common = indents.min(), common > 0 else { return chunk }
        return lines.map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(line.dropFirst(common))
        }.joined(separator: "\n")
    }

    // MARK: - Markdown images

    /// Pulls `![alt](url)` and linked `[![alt](url)](href)` images out of
    /// Markdown as `<img>` HTML parts, so they render like HTML images (web
    /// view, `allowsRemoteContent` decides loading; alt text in native mode).
    /// Text around an image stays Markdown; adjacent images share one part.
    /// Images in code spans and fences are left alone.
    static func splittingImages(_ markdown: String) -> [RichContent] {
        guard markdown.contains("![") else { return [.markdown(markdown)] }

        var parts: [RichContent] = []
        var text: [String] = []
        var images: [String] = []
        var inFence = false

        func flushText() {
            let chunk = text.joined(separator: "\n")
            text.removeAll()
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            parts.append(.markdown(chunk))
        }
        func flushImages() {
            guard !images.isEmpty else { return }
            parts.append(.html(images.joined(separator: " ")))
            images.removeAll()
        }
        func addText(_ piece: String) {
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            flushImages()
            text.append(piece)
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            let ns = line as NSString
            let codeSpans = inFence ? [] : codeSpanRanges(in: line)
            let matches = inFence ? [] : markdownImage
                .matches(in: line, range: NSRange(location: 0, length: ns.length))
                .filter { match in !codeSpans.contains { NSIntersectionRange($0, match.range).length > 0 } }

            guard !matches.isEmpty else {
                flushImages()
                text.append(line)
                continue
            }

            var cursor = 0
            for match in matches {
                addText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                flushText()
                images.append(imageHTML(match, in: ns))
                cursor = NSMaxRange(match.range)
            }
            addText(ns.substring(from: cursor))
        }
        flushImages()
        flushText()
        return parts
    }

    private static func imageHTML(_ match: NSTextCheckingResult, in line: NSString) -> String {
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : line.substring(with: r)
        }
        // Groups 1–3: linked image (alt, src, href); 4–5: plain image (alt, src).
        let alt = group(1) ?? group(4) ?? ""
        let src = group(2) ?? group(5) ?? ""
        let img = "<img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\">"
        guard let href = group(3) else { return img }
        return "<a href=\"\(escapeAttribute(href))\">\(img)</a>"
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Ranges of `` `code` `` spans (matching backtick runs) on one line.
    private static func codeSpanRanges(in line: String) -> [NSRange] {
        codeSpan.matches(in: line, range: NSRange(line.startIndex..., in: line)).map(\.range)
    }

    private static let markdownImage: NSRegularExpression = {
        let image = #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*"|\s+'[^']*')?\s*\)"#
        let target = #"\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*"|\s+'[^']*')?\s*\)"#
        let linked = "\\[" + image + "\\]" + target
        return try! NSRegularExpression(pattern: #"(?<!\\)(?:"# + linked + "|" + image + ")")
    }()
    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)[^`]+?\1"#)

    private static func classifyText(_ chunk: String) -> RichContent {
        if RichContentDetector.looksLikeMarkdown(chunk) { return .markdown(chunk) }
        if RichContentDetector.containsHTMLTags(chunk) { return .html(chunk) }
        return .plain(chunk)
    }

    private static func opensHTML(_ trimmed: String) -> Bool {
        if matches(blockStart, trimmed) { return true }
        guard matches(inlineStart, trimmed) else { return false }
        // `<font face=…>` wrapping the body, or `<span>Hi</span><br>`.
        let delta = tagDepthDelta(trimmed)
        return delta.hard != 0 || delta.soft != 0 || matches(blockTagAnywhere, trimmed)
    }

    // MARK: - Tag balance

    /// Splits off a trailing tag that hasn't reached its `>` yet (quotes in
    /// attribute values respected), so it can be completed by the next line.
    static func splitUnfinishedTag(_ text: String) -> (complete: String, unfinished: String) {
        var tagStart: String.Index?
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index)
            if tagStart != nil {
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    tagStart = nil
                }
            } else if c == "<", next < text.endIndex,
                      text[next].isLetter || text[next] == "/" || text[next] == "!" {
                tagStart = index
            }
            index = next
        }
        guard let start = tagStart else { return (text, "") }
        return (String(text[..<start]), String(text[start...]))
    }

    /// +1 per opening tag, −1 per closing tag; void and self-closing elements
    /// are ignored. Optional-close elements (`<p>`, `<li>`, `<td>` …) are
    /// counted separately (`soft`): they keep a section open across lines, but
    /// a blank line still ends it, so sloppy HTML can't swallow the rest of
    /// the string.
    private static func tagDepthDelta(_ line: String) -> (hard: Int, soft: Int) {
        let cleaned = comment.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        var hard = 0, soft = 0
        for match in tag.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
            guard let nameRange = Range(match.range(at: 2), in: cleaned) else { continue }
            let name = cleaned[nameRange].lowercased()
            if voidElements.contains(name) { continue }
            let isClosing = match.range(at: 1).length > 0
            let isSelfClosing = match.range(at: 3).length > 0
            if isSelfClosing { continue }
            let step = isClosing ? -1 : 1
            if optionalCloseElements.contains(name) { soft += step } else { hard += step }
        }
        return (hard, soft)
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"
    ]
    private static let optionalCloseElements: Set<String> = [
        "p", "li", "dt", "dd", "tr", "td", "th", "thead", "tbody", "tfoot", "option"
    ]

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static let blockStart = try! NSRegularExpression(
        pattern: #"^<(?:!doctype\b|!--|(?:html|head|body|style|meta|div|table|p|blockquote|ul|ol|h[1-6]|hr|br|section|article|header|footer|center|img|pre)\b)"#,
        options: [.caseInsensitive])
    private static let inlineStart = try! NSRegularExpression(
        pattern: #"^<(?:font|span|a|b|i|u|s|strong|em|small)\b"#, options: [.caseInsensitive])
    private static let blockTagAnywhere = try! NSRegularExpression(
        pattern: #"<(?:div|p|br|table|blockquote|ul|ol|li|h[1-6]|hr|pre|img)\b"#, options: [.caseInsensitive])
    private static let tagLineStart = try! NSRegularExpression(pattern: #"^<[!/a-zA-Z]"#)
    private static let tag = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(/?)>"#)
    private static let comment = try! NSRegularExpression(pattern: #"<!--.*?-->"#)
}
