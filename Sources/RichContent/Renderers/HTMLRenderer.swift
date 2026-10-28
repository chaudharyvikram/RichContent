import UIKit

/// HTML → NSAttributedString using UIKit's importer, then normalised so the
/// result matches the app: system fonts, dynamic colours, compact spacing and
/// the same quote bars as plain-text / Markdown quotes.
///
/// UIKit's HTML importer must run on the main thread and is slow-ish
/// (it boots WebKit), so callers should prefer `RichContentView`, which
/// renders HTML asynchronously and caches it.
@MainActor
enum HTMLRenderer {

    // Private-use markers that survive the importer and tell us where each
    // <blockquote> starts and ends.
    private static let quoteOpen: Character = "\u{E000}"
    private static let quoteClose: Character = "\u{E001}"

    /// `.automatic` mode: HTML that needs a real browser (layout tables,
    /// images, CSS background images, media) goes to the web view, where
    /// `allowsRemoteContent` decides whether remote resources load.
    static func prefersWebView(_ html: String) -> Bool {
        let range = NSRange(html.startIndex..., in: html)
        if heavyTags.firstMatch(in: html, range: range) != nil { return true }
        if cssURL.firstMatch(in: html, range: range) != nil
            || backgroundAttribute.firstMatch(in: html, range: range) != nil { return true }
        // Images other than 0/1-px tracking pixels.
        for match in imgTag.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            if trackingPixel.firstMatch(in: String(html[r]), range: NSRange(location: 0, length: match.range.length)) == nil {
                return true
            }
        }
        return false
    }

    /// A "designed" email (layout tables, full-width backgrounds) brings its
    /// own margins, so `.automatic` web padding lets it run edge to edge.
    static func isDesignedLayout(_ html: String) -> Bool {
        let range = NSRange(html.startIndex..., in: html)
        return designedLayout.firstMatch(in: html, range: range) != nil
    }

    private static let designedLayout = try! NSRegularExpression(
        pattern: #"<table\b[^>]*(\bwidth\s*=\s*["']?(100%|[4-9]\d\d\b)|\b(max-)?width\s*:\s*(100%|[4-9]\d\dpx))|<body\b[^>]*(\bbgcolor\b|\bbackground)"#,
        options: [.caseInsensitive])

    static func render(_ html: String, style: RichContentStyle) -> NSAttributedString {
        let prepared = prepare(html, style: style)
        guard let data = prepared.data(using: .utf8),
              let imported = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil)
        else {
            return fallback(html, style: style, reason: "importer threw")
        }

        // The importer can return an empty string instead of throwing
        // (Xcode Previews, some run-loop modes, background launches).
        let hasImportedText = !imported.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSourceText = !decodedText(of: html).isEmpty
        if !hasImportedText && hasSourceText {
            return fallback(html, style: style, reason: "importer returned empty text")
        }

        removeTrailingLineBreaks(imported)
        convertTextLists(imported, style: style)
        normalize(imported, style: style)
        applyQuoteMarkers(imported, style: style)
        TextKitHelpers.tidyWhitespace(imported)
        return imported
    }

    /// Renders without UIKit's importer: HTML → Markdown → native text.
    static func fallback(_ html: String, style: RichContentStyle, reason: String) -> NSAttributedString {
        #if DEBUG
        print("[RichContent] Native HTML import failed (\(reason)); using built-in HTML converter.")
        #endif
        let markdown = SimpleHTMLConverter.markdown(from: html)
        return MarkdownRenderer.render(markdown: markdown, style: style)
    }

    private static func decodedText(of html: String) -> String {
        SimpleHTMLConverter.decodeEntities(stripTags(html))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Preparation

    static func prepare(_ html: String, style: RichContentStyle) -> String {
        var s = html
        s = replace(scriptLike, in: s, with: "")
        // The importer would fetch remote images synchronously on the main
        // thread; native mode keeps the alt text instead.
        s = replace(imgWithAlt, in: s, with: "$1")
        s = replace(imgTag, in: s, with: "")
        // Same for anything else that points at a remote resource:
        // stylesheets, CSS images / imports, background attributes, media.
        s = replace(remoteTags, in: s, with: "")
        s = replace(cssImport, in: s, with: "")
        s = replace(cssURL, in: s, with: "none")
        s = replace(backgroundAttribute, in: s, with: "")
        s = replace(blockquoteOpen, in: s, with: "$0&#xE000;")
        s = replace(blockquoteClose, in: s, with: "&#xE001;$0")

        let css = """
        <meta charset="utf-8">
        <style>
        blockquote { margin: 0 !important; padding: 0 !important; border: 0 !important; }
        p { margin: 0 0 \(Int(style.paragraphSpacing))px 0; }
        </style>
        """
        return css + s
    }

    // MARK: - Normalisation

    private static func normalize(_ s: NSMutableAttributedString, style: RichContentStyle) {
        let full = NSRange(location: 0, length: s.length)

        if style.normalizesHTMLFonts {
            s.enumerateAttribute(.font, in: full) { value, range, _ in
                let old = value as? UIFont
                // The importer's default size is 12pt; keep relative sizes
                // (headings, <small>) but map them onto the app's font.
                var factor = old.map { max(0.8, min(2.2, $0.pointSize / 12)) } ?? 1
                if abs(factor - 1) < 0.12 { factor = 1 }
                let oldTraits = old?.fontDescriptor.symbolicTraits ?? []
                let font: UIFont = oldTraits.contains(.traitMonoSpace)
                    ? style.codeFont.withSize(style.codeFont.pointSize * factor)
                    : style.font.withSize(style.font.pointSize * factor)
                s.addAttribute(.font, value: font.adding(oldTraits.intersection([.traitBold, .traitItalic])), range: range)
            }
            s.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
                if let color = value as? UIColor, !color.isNearBlack { return }
                s.addAttribute(.foregroundColor, value: style.textColor, range: range)
            }
            s.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
                if (value as? UIColor)?.isNearWhite == true {
                    s.removeAttribute(.backgroundColor, range: range)
                }
            }
        }

        s.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let p = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? TextKitHelpers.paragraphStyle(style)
            p.lineSpacing = style.lineSpacing
            p.paragraphSpacing = min(p.paragraphSpacing, style.paragraphSpacing)
            p.paragraphSpacingBefore = 0
            s.addAttribute(.paragraphStyle, value: p, range: range)
        }
    }

    /// `<li>Item<br></li>` and `<p>Text<br></p>` leave a line break right
    /// before the paragraph end, which shows as an empty line.
    private static func removeTrailingLineBreaks(_ s: NSMutableAttributedString) {
        let matches = trailingBreak.matches(in: s.string, range: NSRange(location: 0, length: s.length))
        for match in matches.reversed() {
            s.deleteCharacters(in: match.range)
        }
    }
    private static let trailingBreak = try! NSRegularExpression(pattern: "[\\u2028 \\t]*\\u2028[ \\t]*(?=\\n|\\u2029|$)")

    // MARK: - Lists

    /// The HTML importer describes <ul>/<ol> with `NSParagraphStyle.textLists`.
    /// On recent iOS it no longer writes the bullet / number into the text and
    /// relies on TextKit 2 to draw it, so in this (TextKit 1) view lists show
    /// no markers. This writes them as text ("•\t", "2.\t") with a hanging
    /// indent, exactly like Markdown lists, replacing any marker the importer
    /// did insert, and clears `textLists` so TextKit 2 hosts don't draw twice.
    private static func convertTextLists(_ s: NSMutableAttributedString, style: RichContentStyle) {
        guard s.length > 0 else { return }
        let snapshot = NSString(string: s.string)

        struct Item { let content: NSRange; let level: Int; let marker: String }
        var items: [Item] = []
        var stack: [(list: NSTextList, number: Int)] = []

        snapshot.enumerateSubstrings(in: NSRange(location: 0, length: snapshot.length),
                                     options: [.byParagraphs, .substringNotRequired]) { _, content, enclosing, _ in
            guard enclosing.length > 0,
                  let paragraph = s.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil) as? NSParagraphStyle,
                  !paragraph.textLists.isEmpty
            else {
                stack.removeAll()   // a non-list paragraph ends numbering
                return
            }
            let lists = paragraph.textLists
            let depth = lists.count

            if stack.count > depth { stack.removeLast(stack.count - depth) }
            if let mismatch = (0..<stack.count).first(where: { !sameList(stack[$0].list, lists[$0]) }) {
                stack.removeLast(stack.count - mismatch)
            }
            if stack.count == depth {
                stack[depth - 1].number += 1
            } else {
                while stack.count < depth {
                    let list = lists[stack.count]
                    stack.append((list, list.startingItemNumber))
                }
            }
            items.append(Item(content: content, level: depth,
                              marker: markerText(for: lists[depth - 1], number: stack[depth - 1].number, level: depth)))
        }

        // Back to front, so earlier ranges stay valid.
        for item in items.reversed() {
            let text = snapshot.substring(with: item.content)
            if let existing = importedListMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                s.deleteCharacters(in: NSRange(location: item.content.location, length: existing.range.length))
            }
            let location = item.content.location
            guard location <= s.length else { continue }

            let probe = min(location, s.length - 1)
            var markerAttributes = s.attributes(at: probe, effectiveRange: nil)
            markerAttributes[.foregroundColor] = style.secondaryTextColor
            markerAttributes[.link] = nil
            markerAttributes[.underlineStyle] = nil
            markerAttributes[.strikethroughStyle] = nil
            s.insert(NSAttributedString(string: item.marker + "\t", attributes: markerAttributes), at: location)

            let paragraphRange = (s.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
            let base = CGFloat(item.level - 1) * style.listIndent
            s.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, range, _ in
                let p = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                    ?? TextKitHelpers.paragraphStyle(style)
                p.textLists = []
                p.firstLineHeadIndent = base
                p.headIndent = base + style.listIndent
                p.tabStops = [NSTextTab(textAlignment: .natural, location: base + style.listIndent)]
                p.defaultTabInterval = style.listIndent
                p.paragraphSpacing = style.paragraphSpacing / 2
                s.addAttribute(.paragraphStyle, value: p, range: range)
            }
        }
    }

    private static func sameList(_ a: NSTextList, _ b: NSTextList) -> Bool {
        // The importer may share one NSTextList per list or create one per
        // item; adjacent items with the same format continue the list.
        a === b || a.isEqual(b) || a.markerFormat == b.markerFormat
    }

    private static func markerText(for list: NSTextList, number: Int, level: Int) -> String {
        let format = list.markerFormat.rawValue.lowercased()
        let isUpper = format.contains("upper")
        if format.contains("roman") {
            let roman = romanNumeral(number)
            return (isUpper ? roman.uppercased() : roman) + "."
        }
        if format.contains("alpha") || format.contains("latin") {
            let letter = alphabetic(number)
            return (isUpper ? letter.uppercased() : letter) + "."
        }
        if format.contains("decimal") || format.contains("octal") {
            return "\(number)."
        }
        return ["•", "◦", "▪︎"][(max(level, 1) - 1) % 3]
    }

    private static func alphabetic(_ number: Int) -> String {
        var n = max(number, 1)
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(UInt8(97 + n % 26))) + result
            n /= 26
        }
        return result
    }

    private static func romanNumeral(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = max(number, 1)
        var result = ""
        for (value, symbol) in table {
            while n >= value { result += symbol; n -= value }
        }
        return result
    }

    /// A marker the importer wrote into the text itself ("\t•\t", "\t3.\t").
    private static let importedListMarker = try! NSRegularExpression(
        pattern: #"^\t*(?:[•◦▪▫■□●○‣⁃∙·–\-*]\x{FE0E}?|\d+[.)]?|[A-Za-z][.)]|[IVXLCDMivxlcdm]+[.)])\t"#)

    /// Converts the private-use markers into quote depth per paragraph and
    /// removes them.
    private static func applyQuoteMarkers(_ s: NSMutableAttributedString, style: RichContentStyle) {
        let open = quoteOpen.utf16.first!
        let close = quoteClose.utf16.first!
        let units = Array(s.string.utf16)
        guard units.contains(open) else { return }

        var depthAt: [Int] = []
        depthAt.reserveCapacity(units.count)
        var markerIndexes: [Int] = []
        var depth = 0
        for (i, unit) in units.enumerated() {
            if unit == open { depth += 1; markerIndexes.append(i) }
            else if unit == close { depth = max(0, depth - 1); markerIndexes.append(i) }
            depthAt.append(depth)
        }
        for i in markerIndexes.reversed() {
            s.deleteCharacters(in: NSRange(location: i, length: 1))
            depthAt.remove(at: i)
        }

        let ns = s.string as NSString
        var paragraphs: [(NSRange, Int)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, substring, enclosing, _ in
            let probe = substring.length > 0 ? substring.location : enclosing.location
            let d = probe < depthAt.count ? depthAt[probe] : 0
            if d > 0 { paragraphs.append((enclosing, d)) }
        }
        for (range, d) in paragraphs {
            TextKitHelpers.applyQuote(s, range: range, depth: d, style: style)
        }
    }

    // MARK: - Regex helpers

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }

    static func stripTags(_ html: String) -> String {
        replace(anyTag, in: replace(scriptLike, in: html, with: ""), with: "")
    }

    private static let scriptLike = try! NSRegularExpression(
        pattern: #"<(script|iframe|object|embed|svg|video|audio|frameset)\b[\s\S]*?(</\1\s*>|$)"#, options: [.caseInsensitive])
    private static let remoteTags = try! NSRegularExpression(
        pattern: #"<(link|source|track|input|frame|base)\b[^>]*>|<meta\b[^>]*\bhttp-equiv\s*=\s*["']?refresh[^>]*>"#,
        options: [.caseInsensitive])
    private static let cssImport = try! NSRegularExpression(pattern: #"@import\b[^;]*;?"#, options: [.caseInsensitive])
    /// `url(...)` in `<style>` and `style=""`, except `data:` URLs. Quotes may be
    /// raw or entity-encoded inside attributes.
    private static let cssURL = try! NSRegularExpression(
        pattern: #"url\(\s*(?!['"]?data:|&quot;data:|&#0?39;data:)[^)]*\)"#, options: [.caseInsensitive])
    private static let backgroundAttribute = try! NSRegularExpression(
        pattern: #"\s(background|poster|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)(?=[^<>]*>)"#, options: [.caseInsensitive])
    private static let imgTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    private static let imgWithAlt = try! NSRegularExpression(
        pattern: #"<img\b[^>]*\balt\s*=\s*["']([^"']+)["'][^>]*>"#, options: [.caseInsensitive])
    private static let trackingPixel = try! NSRegularExpression(
        pattern: #"\b(width|height)\s*=\s*["']?[01](px)?["'\s>/]"#, options: [.caseInsensitive])
    private static let heavyTags = try! NSRegularExpression(
        pattern: #"<(table|video|audio|svg|canvas|picture|iframe)\b"#, options: [.caseInsensitive])
    private static let blockquoteOpen = try! NSRegularExpression(pattern: #"<blockquote\b[^>]*>"#, options: [.caseInsensitive])
    private static let blockquoteClose = try! NSRegularExpression(pattern: #"</blockquote\s*>"#, options: [.caseInsensitive])
    private static let anyTag = try! NSRegularExpression(pattern: #"<[^>]+>"#)
}
