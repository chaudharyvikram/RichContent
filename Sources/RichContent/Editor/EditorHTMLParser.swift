import Foundation

/// HTML → editor blocks, without WebKit (fast, works off-screen, in previews
/// and on background launches). Reads the editor's own export losslessly
/// (to-dos, toggles, callouts, colors, nesting) and maps everyday HTML from
/// Mail, Gmail, Notes, Google Docs, Notion and web pages onto the same blocks.
enum EditorHTMLParser {

    // MARK: - Tree

    final class Node {
        let name: String              // lowercased tag, or "#text"
        var attributes: [String: String]
        var text: String
        var children: [Node] = []
        weak var parent: Node?

        init(name: String, attributes: [String: String] = [:], text: String = "") {
            self.name = name
            self.attributes = attributes
            self.text = text
        }

        subscript(_ attribute: String) -> String? { attributes[attribute] }
    }

    static func parseTree(_ html: String) -> Node {
        let root = Node(name: "#root")
        var stack: [Node] = [root]
        let ns = html as NSString
        var index = 0

        func current() -> Node { stack[stack.count - 1] }
        func append(_ node: Node) {
            node.parent = current()
            current().children.append(node)
        }
        func close(_ name: String, stoppingAt boundaries: Set<String> = []) {
            guard let i = stack.lastIndex(where: { $0.name == name || boundaries.contains($0.name) }),
                  i > 0, stack[i].name == name else { return }
            stack.removeSubrange(i...)
        }

        while index < ns.length {
            guard let match = token.firstMatch(in: html, range: NSRange(location: index, length: ns.length - index)) else { break }
            index = NSMaxRange(match.range)

            if match.range(at: 5).location != NSNotFound {           // text
                let text = ns.substring(with: match.range)
                append(Node(name: "#text", text: SimpleHTMLConverter.decodeEntities(text)))
                continue
            }
            guard match.range(at: 2).location != NSNotFound else { continue }   // comment / doctype / stray "<"
            let isClosing = match.range(at: 1).length > 0
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let selfClosing = match.range(at: 4).length > 0

            if isClosing {
                close(name, stoppingAt: closeBoundaries[name] ?? [])
                continue
            }

            if skippedWithContent.contains(name) {
                // Skip everything up to the matching close tag.
                let rest = NSRange(location: index, length: ns.length - index)
                let end = ns.range(of: "</\(name)", options: [.caseInsensitive], range: rest)
                if end.location == NSNotFound { index = ns.length } else {
                    let gt = ns.range(of: ">", options: [], range: NSRange(location: end.location, length: ns.length - end.location))
                    index = gt.location == NSNotFound ? ns.length : NSMaxRange(gt)
                }
                continue
            }

            // Implicitly closed elements.
            if let closes = implicitCloses[name] {
                for closed in closes where stack.contains(where: { $0.name == closed }) {
                    close(closed, stoppingAt: listContainers)
                }
            }

            let attrs = parseAttributes(match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3)))
            let node = Node(name: name, attributes: attrs)
            // Hidden elements (email preheaders, tracking pixels) stay out of
            // the tree; their content still parses, into the detached node.
            if !isHidden(attrs) { append(node) }
            if !voidElements.contains(name) && !selfClosing { stack.append(node) }
        }
        return root
    }

    private static func isHidden(_ attributes: [String: String]) -> Bool {
        if attributes["hidden"] != nil { return true }
        guard let style = attributes["style"] else { return false }
        return hiddenStyle.firstMatch(in: style, range: NSRange(location: 0, length: (style as NSString).length)) != nil
    }

    private static let hiddenStyle = try! NSRegularExpression(
        pattern: #"(?:^|;)\s*(?:display\s*:\s*none|mso-hide\s*:\s*all)\b"#, options: [.caseInsensitive])

    private static func parseAttributes(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = source as NSString
        for m in attribute.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                value = ns.substring(with: m.range(at: g))
            }
            result[name] = SimpleHTMLConverter.decodeEntities(value)
        }
        return result
    }

    private static let token = try! NSRegularExpression(pattern:
        #"<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\?[^>]*>|<(/?)([a-zA-Z][a-zA-Z0-9:-]*)((?:\s+[^\s=/>]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?)*)\s*(/?)>|([^<]+|<)"#)
    private static let attribute = try! NSRegularExpression(pattern:
        #"([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#)

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"
    ]
    private static let skippedWithContent: Set<String> = [
        "head", "script", "style", "title", "template", "noscript", "svg", "video", "audio", "iframe", "object",
        "canvas", "select", "textarea", "button", "xml"
    ]
    private static let blockElements = [
        "p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "hr", "details",
        "section", "article", "header", "footer", "figure", "dl"
    ]
    private static let implicitCloses: [String: [String]] = {
        var map: [String: [String]] = ["li": ["li"], "dt": ["dt", "dd"], "dd": ["dt", "dd"],
                                       "tr": ["tr", "td", "th"], "td": ["td", "th"], "th": ["td", "th"]]
        for block in blockElements { map[block, default: []].append("p") }
        return map
    }()
    private static let listContainers: Set<String> = ["ul", "ol", "table"]
    private static let closeBoundaries: [String: Set<String>] = ["li": ["ul", "ol"], "td": ["tr", "table"], "th": ["tr", "table"]]

    // MARK: - Blocks

    static func blocks(fromHTML html: String) -> [EditorBlock] {
        var builder = Builder()
        builder.visitChildren(of: parseTree(JSONEscapedHTML.unescapeIfNeeded(html)), Context())
        builder.flush()
        return postProcess(builder.blocks)
    }

    struct Context {
        var level = 1
        var listType: RichBlockType?
        var quote = false
        var pre = false
        var callout = false
        var todoLike = false
        var inline = InlineInfo()
    }

    struct Builder {
        var blocks: [EditorBlock] = []
        private var current: EditorBlock?
        private var text = NSMutableAttributedString()
        /// Content of the next block element flows into the current block
        /// while it is still empty (`<li><div>Item</div></li>`).
        private var absorbing = false
        private var keepEmpty = false

        // MARK: Block bookkeeping

        mutating func start(_ type: RichBlockType, level: Int, absorbing: Bool = false, keepEmpty: Bool = false) {
            flush()
            current = EditorBlock(type, level: level)
            self.absorbing = absorbing
            self.keepEmpty = keepEmpty
        }

        mutating func flush() {
            guard var block = current else { return }
            current = nil
            trim(text, keepsLeading: block.info.type == .codeBlock)
            let isEmpty = text.length == 0
            if !isEmpty || keepEmpty {
                text.mutableString.replaceOccurrences(of: "\n", with: EditorStyling.lineBreak, options: [],
                                                      range: NSRange(location: 0, length: text.length))
                block.content = text
                blocks.append(block)
            }
            text = NSMutableAttributedString()
            absorbing = false
            keepEmpty = false
        }

        /// Called by block elements: keeps an empty absorbing block open.
        mutating func boundary() {
            if current != nil, absorbing, text.length == 0 { return }
            flush()
        }

        var currentType: RichBlockType? { current?.info.type }
        var currentIsEmpty: Bool { text.length == 0 }

        mutating func setCurrent(_ change: (inout EditorBlock) -> Void) {
            guard current != nil else { return }
            change(&current!)
        }

        mutating func ensureBlock(_ ctx: Context) {
            guard current == nil else { return }
            start(ctx.quote ? .quote : .paragraph, level: ctx.level)
        }

        mutating func appendText(_ raw: String, _ ctx: Context) {
            var s = raw
            if !ctx.pre {
                s = s.replacingOccurrences(of: #"[ \t\n\r\f]+"#, with: " ", options: .regularExpression)
                if s == " ", current == nil { return }
                let last = text.string.last
                if text.length == 0 || last == " " || last == "\u{2028}" {
                    s = String(s.drop { $0 == " " })
                }
                guard !s.isEmpty else { return }
            } else {
                s = s.replacingOccurrences(of: "\r\n", with: "\n")
                // A newline right after <pre> is not content.
                if text.length == 0, s.hasPrefix("\n") { s.removeFirst() }
                guard !s.isEmpty else { return }
            }
            ensureBlock(ctx)
            text.append(NSAttributedString(string: s, attributes: ctx.inline.attributes))
        }

        mutating func lineBreak(_ ctx: Context) {
            if current == nil {
                start(ctx.quote ? .quote : .paragraph, level: ctx.level, keepEmpty: true)
                return
            }
            if text.length == 0 { keepEmpty = true; return }
            while text.string.hasSuffix(" ") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
            text.append(NSAttributedString(string: ctx.pre ? "\n" : EditorStyling.lineBreak, attributes: ctx.inline.attributes))
        }

        mutating func appendAttachment(_ block: EditorBlock) {
            flush()
            blocks.append(block)
        }

        private func trim(_ s: NSMutableAttributedString, keepsLeading: Bool) {
            let ws = CharacterSet(charactersIn: " \u{2028}\n")
            while let last = s.string.unicodeScalars.last, ws.contains(last) {
                s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1))
            }
            while !keepsLeading, let first = s.string.unicodeScalars.first, ws.contains(first) {
                s.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
        }

        // MARK: Visiting

        mutating func visitChildren(of node: Node, _ ctx: Context) {
            for child in node.children { visit(child, ctx) }
        }

        mutating func visit(_ node: Node, _ parentContext: Context) {
            var ctx = parentContext
            if node.name == "#text" {
                appendText(node.text, ctx)
                return
            }
            applyInlineStyle(node, &ctx)
            let dataType = node["data-type"]?.lowercased()

            switch node.name {
            case "br":
                lineBreak(ctx)

            case "hr":
                appendAttachment(EditorBlock(.divider, level: ctx.level))

            case "img":
                guard let src = node["src"], !src.isEmpty, !isTrackingPixel(node) else { return }
                var block = EditorBlock(.image, level: ctx.level)
                block.image = EditorImage(source: src, alt: node["alt"] ?? "", size: size(of: node))
                appendAttachment(block)

            case "input":
                if node["type"]?.lowercased() == "checkbox", let type = currentType, type.isList || type == .paragraph, currentIsEmpty {
                    let checked = node["checked"] != nil
                    setCurrent { $0.info.type = .todo; $0.info.checked = checked }
                }

            case "h1", "h2", "h3", "h4", "h5", "h6":
                if ctx.callout { lineBreak(ctx); visitChildren(of: node, ctx); lineBreak(ctx); return }
                let type: RichBlockType = node.name == "h1" ? .heading1 : node.name == "h2" ? .heading2 : .heading3
                if absorbing, current != nil, currentIsEmpty {
                    setCurrent { if $0.info.type == .paragraph { $0.info.type = type } }
                } else {
                    start(type, level: ctx.level, keepEmpty: false)
                }
                var inner = ctx
                inner.inline.bold = false
                visitChildren(of: node, inner)
                flush()

            case "ul", "ol":
                boundary()
                var inner = ctx
                let isTodo = dataType == "todo" || dataType == "tasklist"
                    || (node["class"]?.lowercased().contains("todo") ?? false)
                    || (node["class"]?.lowercased().contains("checklist") ?? false)
                inner.listType = node.name == "ol" ? .numberedList : (isTodo ? .todo : .bulletList)
                inner.todoLike = isTodo
                visitChildren(of: node, inner)
                flush()

            case "li":
                var type = ctx.listType ?? .bulletList
                let checkedAttr = node["data-checked"]?.lowercased() ?? node["aria-checked"]?.lowercased()
                let classes = node["class"]?.lowercased() ?? ""
                if checkedAttr != nil || classes.contains("checked") || classes.contains("task") { type = .todo }
                start(type, level: ctx.level, absorbing: true, keepEmpty: true)
                if type == .todo {
                    let checked = checkedAttr == "true" || (checkedAttr == nil && classes.contains("checked") && !classes.contains("unchecked"))
                    setCurrent { $0.info.checked = checked }
                }
                var inner = ctx
                inner.level = ctx.level + 1
                inner.listType = nil
                inner.quote = false
                visitChildren(of: node, inner)
                flush()

            case "blockquote":
                boundary()
                var inner = ctx
                inner.quote = true
                visitChildren(of: node, inner)
                flush()

            case "pre":
                start(.codeBlock, level: ctx.level, keepEmpty: true)
                let language = node["data-language"] ?? languageClass(node.children.first { $0.name == "code" })
                setCurrent { $0.info.language = language }
                var inner = ctx
                inner.pre = true
                inner.inline = InlineInfo()
                visitChildren(of: node, inner)
                flush()

            case "code", "kbd", "samp", "tt":
                if !ctx.pre { ctx.inline.code = true }
                visitChildren(of: node, ctx)

            case "details":
                let isOpen = node["open"] != nil
                start(.toggle, level: ctx.level, absorbing: true, keepEmpty: true)
                if !isOpen { setCurrent { $0.hiddenChildren = [] } }
                var inner = ctx
                inner.listType = nil
                inner.quote = false
                if let summary = node.children.first(where: { $0.name == "summary" }) {
                    visitChildren(of: summary, inner)
                }
                flush()
                inner.level = ctx.level + 1
                for child in node.children where child.name != "summary" { visit(child, inner) }
                flush()

            case "summary":
                start(.paragraph, level: ctx.level)
                visitChildren(of: node, ctx)
                flush()

            case "table":
                boundary()
                visitChildren(of: node, ctx)
                flush()

            case "tr":
                start(ctx.quote ? .quote : .paragraph, level: ctx.level)
                visitChildren(of: node, ctx)
                flush()

            case "td", "th":
                if !currentIsEmpty { appendText("\t", Context(pre: true)) }
                var inner = ctx
                if node.name == "th" { inner.inline.bold = true }
                visitChildren(of: node, inner)

            case "span" where node["data-type"] == "todo-box" || node["data-type"] == "callout-emoji":
                return

            default:
                if dataType == "callout" {
                    start(.callout, level: ctx.level, keepEmpty: true)
                    let emoji = node["data-emoji"]
                    let color = node["data-color"].flatMap(RichColor.init(rawValue:))
                    setCurrent {
                        $0.info.emoji = emoji ?? "💡"
                        $0.info.color = color
                    }
                    var inner = ctx
                    inner.callout = true
                    visitChildren(of: node, inner)
                    flush()
                    return
                }
                guard isBlock(node.name) else {
                    visitChildren(of: node, ctx)
                    return
                }
                var inner = ctx
                if dataType == "indent" || (dataType == nil && indentsChildren(node)) {
                    boundary()
                    inner.level = ctx.level + 1
                    visitChildren(of: node, inner)
                    flush()
                    return
                }
                if ctx.callout {
                    if !currentIsEmpty { lineBreak(ctx) }
                    visitChildren(of: node, ctx)
                    return
                }
                boundary()
                visitChildren(of: node, inner)
                if !(absorbing && currentIsEmpty) { flush() }
            }
        }

        private func isBlock(_ name: String) -> Bool {
            ["p", "div", "section", "article", "header", "footer", "main", "center", "figure", "figcaption",
             "address", "dl", "dt", "dd", "aside", "nav", "form", "fieldset", "body", "html"].contains(name)
        }

        private func indentsChildren(_ node: Node) -> Bool {
            guard let style = node["style"]?.lowercased(), node.name == "div" else { return false }
            for property in ["margin-left", "padding-left"] {
                if let value = cssValue(property, in: style), let px = Double(value.filter { $0.isNumber || $0 == "." }),
                   px >= 20, !value.contains("%") {
                    return true
                }
            }
            return false
        }

        private func isTrackingPixel(_ node: Node) -> Bool {
            let small = { (v: String?) in v.flatMap { Double($0.filter { $0.isNumber || $0 == "." }) }.map { $0 <= 2 } ?? false }
            return small(node["width"]) && small(node["height"])
        }

        private func size(of node: Node) -> CGSize? {
            guard let w = node["width"].flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) }),
                  let h = node["height"].flatMap({ Double($0.filter { $0.isNumber || $0 == "." }) }),
                  w > 0, h > 0, !(node["width"]?.contains("%") ?? false) else { return nil }
            return CGSize(width: w, height: h)
        }

        private func languageClass(_ node: Node?) -> String? {
            guard let classes = node?["class"] else { return nil }
            return classes.split(separator: " ").first { $0.hasPrefix("language-") }.map { String($0.dropFirst(9)) }
        }

        // MARK: Inline styles

        private func applyInlineStyle(_ node: Node, _ ctx: inout Context) {
            // The struck-through look of a checked to-do is not a format.
            if node["data-type"] == "todo-text" { return }
            switch node.name {
            case "b", "strong": ctx.inline.bold = true
            case "i", "em", "cite", "dfn", "var": ctx.inline.italic = true
            case "u", "ins": ctx.inline.underline = true
            case "s", "strike", "del": ctx.inline.strike = true
            case "mark": ctx.inline.highlight = .yellow
            case "a":
                if let href = node["href"]?.trimmingCharacters(in: .whitespaces), !href.isEmpty,
                   !href.lowercased().hasPrefix("javascript:"), !href.hasPrefix("#"), let url = URL(string: href) {
                    ctx.inline.link = url
                }
            case "font":
                if let color = node["color"].flatMap(EditorHTMLParser.paletteColor(css:)) { ctx.inline.color = color }
            default: break
            }
            if let color = node["data-color"].flatMap(RichColor.init(rawValue:)), node["data-type"] != "callout" {
                ctx.inline.color = color
            }
            if let highlight = node["data-highlight"].flatMap(RichColor.init(rawValue:)) { ctx.inline.highlight = highlight }
            guard let style = node["style"]?.lowercased(), node["data-type"] != "callout" else { return }

            if let weight = cssValue("font-weight", in: style) {
                if weight.contains("bold") || (Int(weight).map { $0 >= 600 } ?? false) { ctx.inline.bold = true }
                if weight == "normal" || (Int(weight).map { $0 < 600 } ?? false) { ctx.inline.bold = false }
            }
            if let fontStyle = cssValue("font-style", in: style) { ctx.inline.italic = fontStyle.contains("italic") }
            if let decoration = cssValue("text-decoration", in: style) ?? cssValue("text-decoration-line", in: style) {
                if decoration.contains("underline") { ctx.inline.underline = true }
                if decoration.contains("line-through") { ctx.inline.strike = true }
            }
            if node["data-color"] == nil, let color = cssValue("color", in: style).flatMap(EditorHTMLParser.paletteColor(css:)) {
                ctx.inline.color = color
            }
            if node["data-highlight"] == nil,
               let bg = (cssValue("background-color", in: style) ?? cssValue("background", in: style)).flatMap(EditorHTMLParser.paletteHighlight(css:)) {
                ctx.inline.highlight = bg
            }
            if let family = cssValue("font-family", in: style), family.contains("mono") || family.contains("courier") || family.contains("menlo") {
                if !ctx.pre { ctx.inline.code = true }
            }
        }

        private func cssValue(_ property: String, in style: String) -> String? {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == property else { continue }
                return parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    // MARK: - Colors

    private static let namedText: [String: RichColor] = [
        "red": .red, "darkred": .red, "crimson": .red, "blue": .blue, "navy": .blue, "royalblue": .blue,
        "green": .green, "darkgreen": .green, "orange": .orange, "darkorange": .orange, "purple": .purple,
        "violet": .purple, "gray": .gray, "grey": .gray, "brown": .brown, "pink": .pink, "hotpink": .pink,
        "#ff0000": .red, "#f00": .red, "#0000ff": .blue, "#00f": .blue, "#008000": .green, "#ffa500": .orange,
        "#800080": .purple, "#808080": .gray, "#a52a2a": .brown, "#ffc0cb": .pink, "#cb912f": .yellow
    ]
    private static let namedHighlight: [String: RichColor] = [
        "yellow": .yellow, "#ffff00": .yellow, "#ff0": .yellow, "#fff2cc": .yellow, "#fef3c7": .yellow,
        "lightgreen": .green, "lightblue": .blue, "pink": .pink, "#ffc0cb": .pink
    ]

    static func paletteColor(css: String) -> RichColor? {
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedText[value] { return named }
        if value.hasPrefix("#"), let match = RichColor.matching(textHex: expandHex(value)) { return match }
        return nil
    }

    static func paletteHighlight(css: String) -> RichColor? {
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedHighlight[value] { return named }
        if value.hasPrefix("#"), let match = RichColor.matching(backgroundHex: expandHex(value)) { return match }
        return nil
    }

    private static func expandHex(_ hex: String) -> String {
        let digits = hex.dropFirst()
        guard digits.count == 3 else { return String(digits) }
        return digits.map { "\($0)\($0)" }.joined()
    }

    // MARK: - Post-processing

    /// To-do markers written as text, toggles collapsed, edges trimmed.
    static func postProcess(_ input: [EditorBlock]) -> [EditorBlock] {
        var blocks = input.map(detectTodoMarker)

        // Collapse toggles back to front, so nested ones are handled first.
        var i = blocks.count - 1
        while i >= 0 {
            if blocks[i].info.type == .toggle, blocks[i].hiddenChildren != nil {
                let level = blocks[i].info.level
                var end = i + 1
                while end < blocks.count, blocks[end].info.level > level { end += 1 }
                blocks[i].hiddenChildren = Array(blocks[(i + 1)..<end])
                blocks.removeSubrange((i + 1)..<end)
            }
            i -= 1
        }

        while let first = blocks.first, first.info.type == .paragraph, first.content.length == 0 { blocks.removeFirst() }
        while let last = blocks.last, last.info.type == .paragraph, last.content.length == 0 { blocks.removeLast() }
        return blocks
    }

    private static func detectTodoMarker(_ block: EditorBlock) -> EditorBlock {
        guard block.info.type.isList || block.info.type == .todo || block.info.type == .paragraph else { return block }
        let text = block.content.string
        let markers: [(String, Bool)] = [("☐ ", false), ("☑ ", true), ("☒ ", true), ("[ ] ", false), ("[x] ", true), ("[X] ", true),
                                         ("☐\u{00A0}", false), ("☑\u{00A0}", true)]
        guard let (marker, checked) = markers.first(where: { text.hasPrefix($0.0) }),
              block.info.type != .paragraph || marker.first == "☐" || marker.first == "☑" else { return block }
        var b = block
        b.info.type = .todo
        b.info.checked = checked
        let length = (marker as NSString).length
        b.content = block.content.attributedSubstring(from: NSRange(location: length, length: block.content.length - length))
        return b
    }
}
