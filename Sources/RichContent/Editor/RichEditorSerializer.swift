import UIKit

/// Exports the editor's document as HTML (lossless, email-safe), Markdown or
/// plain text. Hidden children of collapsed toggles are always included.
@MainActor
public enum RichEditorSerializer {

    /// A block and the blocks nested under it.
    struct Node {
        var block: EditorBlock
        var children: [Node]
    }

    static func tree(_ blocks: [EditorBlock]) -> [Node] {
        var index = 0
        func build(minLevel: Int) -> [Node] {
            var nodes: [Node] = []
            while index < blocks.count, blocks[index].info.level >= minLevel {
                let block = blocks[index]
                index += 1
                var children = build(minLevel: block.info.level + 1)
                if let hidden = block.hiddenChildren { children = tree(hidden) + children }
                nodes.append(Node(block: block, children: children))
            }
            return nodes
        }
        var roots: [Node] = []
        while index < blocks.count { roots += build(minLevel: blocks[index].info.level) }
        return roots
    }

    // MARK: - HTML

    public static func html(from s: NSAttributedString) -> String {
        html(blocks: EditorDocument.blocks(from: s))
    }

    static func html(blocks: [EditorBlock]) -> String {
        html(tree(blocks))
    }

    private static func html(_ nodes: [Node]) -> String {
        var out = ""
        var i = 0
        while i < nodes.count {
            let type = nodes[i].block.info.type
            // Siblings of one kind share a container.
            var j = i
            while j < nodes.count, nodes[j].block.info.type == type { j += 1 }
            let group = Array(nodes[i..<j])
            switch type {
            case .bulletList, .numberedList:
                let tag = type == .bulletList ? "ul" : "ol"
                out += "<\(tag)>" + group.map { "<li>\(inlineHTML($0.block))\(html($0.children))</li>" }.joined() + "</\(tag)>"
            case .todo:
                out += "<ul data-type=\"todo\" style=\"list-style:none;padding-left:0\">"
                for node in group {
                    let checked = node.block.info.checked
                    let textStyle = checked ? " style=\"text-decoration:line-through;color:#9B9A97\"" : ""
                    out += "<li data-checked=\"\(checked)\"><span data-type=\"todo-box\">\(checked ? "☑" : "☐")</span>&nbsp;"
                        + "<span data-type=\"todo-text\"\(textStyle)>\(inlineHTML(node.block))</span>"
                        + html(node.children) + "</li>"
                }
                out += "</ul>"
            case .quote:
                out += "<blockquote style=\"margin:4px 0;padding-left:14px;border-left:3px solid currentColor\">"
                for node in group {
                    out += paragraphDiv(node.block) + indented(node.children)
                }
                out += "</blockquote>"
            default:
                for node in group { out += blockHTML(node) }
            }
            i = j
        }
        return out
    }

    private static func blockHTML(_ node: Node) -> String {
        let block = node.block
        switch block.info.type {
        case .heading1, .heading2, .heading3:
            let n = block.info.type.headingLevel ?? 2
            return "<h\(n)>\(inlineHTML(block))</h\(n)>" + indented(node.children)
        case .toggle:
            let open = block.hiddenChildren == nil ? " open" : ""
            return "<details data-type=\"toggle\"\(open)><summary>\(inlineHTML(block))</summary>\(html(node.children))</details>"
        case .callout:
            let emoji = block.info.emoji ?? "💡"
            let color = block.info.color ?? .gray
            return "<div data-type=\"callout\" data-emoji=\"\(escapeHTML(emoji, attribute: true))\" data-color=\"\(color.rawValue)\" "
                + "style=\"background:\(color.backgroundHex);border-radius:6px;padding:12px 16px;margin:4px 0\">"
                + "<span data-type=\"callout-emoji\">\(escapeHTML(emoji))</span>&nbsp;\(inlineHTML(block))</div>"
                + indented(node.children)
        case .codeBlock:
            let code = escapeHTML(block.text.replacingOccurrences(of: EditorStyling.lineBreak, with: "\n"))
            let language = block.info.language.map { escapeHTML($0, attribute: true) }
            let preAttr = language.map { " data-language=\"\($0)\"" } ?? ""
            let codeAttr = language.map { " class=\"language-\($0)\"" } ?? ""
            return "<pre\(preAttr)><code\(codeAttr)>\(code)</code></pre>" + indented(node.children)
        case .divider:
            return "<hr>" + indented(node.children)
        case .image:
            guard let image = block.image, !image.source.isEmpty else { return indented(node.children) }
            var attrs = "src=\"\(escapeHTML(image.source, attribute: true))\" alt=\"\(escapeHTML(image.alt, attribute: true))\""
            if let size = image.size, size.width > 0 { attrs += " width=\"\(Int(size.width))\" height=\"\(Int(size.height))\"" }
            return "<div data-type=\"image\"><img \(attrs) style=\"max-width:100%;height:auto\"></div>" + indented(node.children)
        case .table:
            guard let table = block.table else { return indented(node.children) }
            return tableHTML(table) + indented(node.children)
        default:
            return paragraphDiv(block) + indented(node.children)
        }
    }

    /// `<table data-type="table">` with inline styles mail clients keep; cells
    /// hold the cell's blocks as HTML, header cells are `<th>`.
    static func tableHTML(_ table: EditorTable) -> String {
        let cellStyle = "border:1px solid #D9D9D6;padding:6px 8px;vertical-align:top;text-align:left"
        var out = "<table data-type=\"table\" style=\"border-collapse:collapse;width:100%;margin:4px 0\">"
        for (r, row) in table.rows.enumerated() {
            let header = table.hasHeaderRow && r == 0
            let tag = header ? "th" : "td"
            let style = header ? cellStyle + ";background:#F1F1EF;font-weight:600" : cellStyle
            out += "<tr>" + row.map { "<\(tag) style=\"\(style)\">\(html(blocks: $0))</\(tag)>" }.joined() + "</tr>"
        }
        return out + "</table>"
    }

    private static func paragraphDiv(_ block: EditorBlock) -> String {
        let inner = inlineHTML(block)
        return inner.isEmpty ? "<div><br></div>" : "<div>\(inner)</div>"
    }

    private static func indented(_ children: [Node]) -> String {
        children.isEmpty ? "" : "<div data-type=\"indent\" style=\"margin-left:24px\">\(html(children))</div>"
    }

    static func inlineHTML(_ block: EditorBlock) -> String {
        let s = block.content
        guard s.length > 0 else { return "" }
        let ns = s.string as NSString
        var out = ""
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
            let inline = InlineInfo(attrs)
            var text = escapeHTML(ns.substring(with: r)).replacingOccurrences(of: EditorStyling.lineBreak, with: "<br>")
            if inline.code { text = "<code>\(text)</code>" }
            if inline.strike { text = "<s>\(text)</s>" }
            if inline.underline { text = "<u>\(text)</u>" }
            if inline.italic { text = "<em>\(text)</em>" }
            if inline.bold { text = "<strong>\(text)</strong>" }
            if let color = inline.color, color != .default {
                text = "<span data-color=\"\(color.rawValue)\" style=\"color:\(color.textHex)\">\(text)</span>"
            }
            if let highlight = inline.highlight, highlight != .default {
                text = "<span data-highlight=\"\(highlight.rawValue)\" style=\"background-color:\(highlight.backgroundHex)\">\(text)</span>"
            }
            if let link = inline.link {
                text = "<a href=\"\(escapeHTML(link.absoluteString, attribute: true))\">\(text)</a>"
            }
            out += text
        }
        return out
    }

    // MARK: - Markdown

    public static func markdown(from s: NSAttributedString) -> String {
        markdown(blocks: EditorDocument.blocks(from: s))
    }

    static func markdown(blocks: [EditorBlock]) -> String {
        var lines: [String] = []
        markdown(tree(blocks), indent: "", into: &lines)
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func markdown(_ nodes: [Node], indent: String, into lines: inout [String]) {
        var ordinal = 0
        for (i, node) in nodes.enumerated() {
            let block = node.block
            let type = block.info.type
            let listLike = type.hasMarker
            ordinal = type == .numberedList ? ordinal + 1 : 0
            if i > 0, !(nodes[i - 1].block.info.type.hasMarker && listLike), lines.last != "" {
                lines.append("")
            }

            let text = inlineMarkdown(block)
            switch type {
            case .bulletList, .numberedList, .todo, .toggle:
                let marker: String
                switch type {
                case .numberedList: marker = "\(ordinal). "
                case .todo: marker = block.info.checked ? "- [x] " : "- [ ] "
                default: marker = "- "
                }
                let continuation = indent + String(repeating: " ", count: type == .numberedList ? marker.count : 2)
                lines.append(indent + marker + hardBreaks(text, continuation))
                if let first = node.children.first {
                    // Nested lists stay tight; other children need a blank line
                    // or they'd continue the item's paragraph.
                    if !first.block.info.type.hasMarker { lines.append("") }
                    markdown(node.children, indent: continuation, into: &lines)
                }
                continue
            case .heading1, .heading2, .heading3:
                lines.append(indent + String(repeating: "#", count: type.headingLevel ?? 2) + " " + text)
            case .quote:
                lines.append(indent + "> " + hardBreaks(text, indent + "> "))
            case .callout:
                lines.append(indent + "> " + (block.info.emoji ?? "💡") + " " + hardBreaks(text, indent + "> "))
            case .codeBlock:
                let fence = block.text.contains("```") ? "````" : "```"
                lines.append(indent + fence + (block.info.language ?? ""))
                for line in block.text.components(separatedBy: EditorStyling.lineBreak) { lines.append(indent + line) }
                lines.append(indent + fence)
            case .divider:
                lines.append(indent + "---")
            case .image:
                if let image = block.image, !image.source.isEmpty {
                    let src = image.source.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")
                    lines.append(indent + "![\(escapeMarkdown(image.alt))](\(src))")
                }
            case .paragraph:
                if !text.isEmpty { lines.append(indent + escapeLineStart(hardBreaks(text, indent))) }
            case .table:
                if let table = block.table { lines += markdownTable(table).map { indent + $0 } }
            }
            if !node.children.isEmpty {
                lines.append("")
                markdown(node.children, indent: indent, into: &lines)
            }
        }
    }

    /// GitHub-style pipe table. Markdown tables need a header row, so a table
    /// without one gets an empty header. Multi-line cells use `<br>`.
    static func markdownTable(_ table: EditorTable) -> [String] {
        func cell(_ blocks: [EditorBlock]) -> String {
            markdown(blocks: blocks)
                .replacingOccurrences(of: "\n\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "|", with: "\\|")
        }
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let columns = max(table.columnCount, 1)
        let rows = table.rows.map { line($0.map(cell)) }
        let separator = line(Array(repeating: "---", count: columns))
        if table.hasHeaderRow {
            return [rows[0], separator] + rows.dropFirst()
        }
        return [line(Array(repeating: " ", count: columns)), separator] + rows
    }

    private static func hardBreaks(_ text: String, _ continuation: String) -> String {
        text.replacingOccurrences(of: EditorStyling.lineBreak, with: "\\\n" + continuation)
    }

    private static func inlineMarkdown(_ block: EditorBlock) -> String {
        let s = block.content
        guard s.length > 0 else { return "" }
        let ns = s.string as NSString
        var out = ""
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, r, _ in
            let raw = ns.substring(with: r)
            let inline = InlineInfo(attrs)
            var text: String
            if inline.code {
                let fence = raw.contains("`") ? "``" : "`"
                text = fence + raw + fence
            } else {
                text = escapeMarkdown(raw)
                if inline.strike { text = wrap(text, "~~") }
                if inline.italic { text = wrap(text, "*") }
                if inline.bold { text = wrap(text, "**") }
                if inline.underline && inline.link == nil { text = wrap(text, "<u>", "</u>") }
            }
            if let link = inline.link {
                let url = link.absoluteString.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
                text = "[\(text)](\(url))"
            }
            out += text
        }
        return out
    }

    /// Wraps the non-space core so `** bold**` never happens.
    private static func wrap(_ text: String, _ open: String, _ close: String? = nil) -> String {
        let leading = String(text.prefix { $0 == " " })
        let trailing = String(text.reversed().prefix { $0 == " " })
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        return leading + open + core + (close ?? open) + trailing
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\*_`[]<".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Stops body text that happens to start like Markdown syntax ("# ",
    /// "- ", "1. ", "> ") from turning into structure.
    private static func escapeLineStart(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        guard lineStartSyntax.firstMatch(in: line, range: range) != nil else { return line }
        return "\\" + line
    }
    private static let lineStartSyntax = try! NSRegularExpression(pattern: #"^(#{1,6}\s|[-+]\s|\d+[.)]\s|>|-{3,}\s*$)"#)

    // MARK: - Plain text

    public static func plainText(from s: NSAttributedString) -> String {
        plainText(blocks: EditorDocument.blocks(from: s))
    }

    static func plainText(blocks: [EditorBlock]) -> String {
        var lines: [String] = []
        plainText(tree(blocks), depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func plainText(_ nodes: [Node], depth: Int, into lines: inout [String]) {
        var ordinal = 0
        let indent = String(repeating: "  ", count: depth)
        for node in nodes {
            let block = node.block
            ordinal = block.info.type == .numberedList ? ordinal + 1 : 0
            let prefix: String
            switch block.info.type {
            case .bulletList: prefix = "• "
            case .numberedList: prefix = "\(ordinal). "
            case .todo: prefix = block.info.checked ? "☑ " : "☐ "
            case .toggle: prefix = "▸ "
            case .quote: prefix = "> "
            case .callout: prefix = (block.info.emoji ?? "💡") + " "
            default: prefix = ""
            }
            switch block.info.type {
            case .divider: lines.append(indent + "———")
            case .image: lines.append(indent + "[Image" + (block.image?.alt.isEmpty == false ? ": \(block.image!.alt)" : "") + "]")
            case .table:
                // One line per row, cells separated by tabs.
                for row in block.table?.rows ?? [] {
                    let cells = row.map { plainText(blocks: $0).replacingOccurrences(of: "\n", with: " ") }
                    lines.append(indent + cells.joined(separator: "\t"))
                }
            case .codeBlock:
                lines += block.text.components(separatedBy: EditorStyling.lineBreak).map { indent + $0 }
            default:
                let continuation = indent + (block.info.type == .quote ? "> " : String(repeating: " ", count: prefix.count))
                let text = block.text.replacingOccurrences(of: EditorStyling.lineBreak, with: "\n" + continuation)
                lines.append((indent + prefix + text).trimmingTrailingSpaces())
            }
            plainText(node.children, depth: depth + 1, into: &lines)
        }
    }

    // MARK: - Replies

    /// Email reply body: the new text, an attribution line, and the original
    /// message in a `<blockquote type="cite">` (understood by Mail, Gmail, Outlook).
    public static func replyHTML(_ reply: NSAttributedString, quoting original: RichContent,
                                 attribution: String, style: RichContentStyle = .standard) -> String {
        let originalHTML: String
        if case .html(let html) = original {
            originalHTML = bodyContent(of: html)
        } else {
            originalHTML = html(blocks: EditorImporter.blocks(from: original))
        }
        return html(from: reply)
            + "<br><div>\(escapeHTML(attribution))</div>"
            + "<blockquote type=\"cite\" style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">"
            + originalHTML
            + "</blockquote>"
    }

    // MARK: - Helpers

    private static func bodyContent(of html: String) -> String {
        guard let match = bodyRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html)
        else { return html }
        return String(html[r])
    }
    private static let bodyRegex = try! NSRegularExpression(pattern: #"<body\b[^>]*>([\s\S]*)</body\s*>"#, options: [.caseInsensitive])

    static func escapeHTML(_ text: String, attribute: Bool = false) -> String {
        var out = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
