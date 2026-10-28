import XCTest
@testable import RichContent

/// Import / export of the editor's document model.
@MainActor
final class EditorFormatTests: XCTestCase {

    /// "type@level[flags]: text" per block, hidden toggle children indented with "  ".
    static func describe(_ blocks: [EditorBlock], indent: String = "") -> [String] {
        blocks.flatMap { b -> [String] in
            var flags: [String] = []
            if b.info.type == .todo, b.info.checked { flags.append("x") }
            if let e = b.info.emoji, b.info.type == .callout { flags.append(e) }
            if let c = b.info.color, b.info.type == .callout { flags.append(c.rawValue) }
            if let l = b.info.language { flags.append(l) }
            if b.hiddenChildren != nil { flags.append("closed") }
            let flagText = flags.isEmpty ? "" : "[" + flags.joined(separator: ",") + "]"
            let text = b.image.map { "img:\($0.source)|\($0.alt)" } ?? b.text.replacingOccurrences(of: "\u{2028}", with: "⏎")
            return ["\(indent)\(b.info.type.rawValue)@\(b.info.level)\(flagText): \(text)"]
                + describe(b.hiddenChildren ?? [], indent: indent + "  ")
        }
    }

    private func html(_ html: String) -> [String] { Self.describe(EditorHTMLParser.blocks(fromHTML: html)) }
    private func markdown(_ md: String) -> [String] { Self.describe(EditorImporter.markdownBlocks(md)) }

    private func inline(_ text: String, _ change: (inout InlineInfo) -> Void) -> NSAttributedString {
        var info = InlineInfo()
        change(&info)
        return NSAttributedString(string: text, attributes: info.attributes)
    }

    /// One of every block, nested, with inline formats and a closed toggle.
    private var sampleDocument: [EditorBlock] {
        var blocks: [EditorBlock] = []
        blocks.append(EditorBlock(.heading1, text: "Plan"))
        let rich = NSMutableAttributedString(string: "Plain ")
        rich.append(inline("bold") { $0.bold = true })
        rich.append(NSAttributedString(string: " "))
        rich.append(inline("red link") { $0.color = .red; $0.link = URL(string: "https://example.com/a?b=1&c=2") })
        rich.append(NSAttributedString(string: " "))
        rich.append(inline("marked") { $0.highlight = .yellow; $0.italic = true })
        rich.append(NSAttributedString(string: " "))
        rich.append(inline("code") { $0.code = true })
        rich.append(NSAttributedString(string: " "))
        rich.append(inline("gone") { $0.strike = true; $0.underline = true })
        blocks.append(EditorBlock(.paragraph, content: rich))
        blocks.append(EditorBlock(.bulletList, text: "One"))
        blocks.append(EditorBlock(.bulletList, level: 2, text: "One.a"))
        blocks.append(EditorBlock(.numberedList, level: 3, text: "Deep"))
        blocks.append(EditorBlock(.bulletList, text: "Two"))
        var done = EditorBlock(.todo, text: "Done")
        done.info.checked = true
        blocks.append(done)
        blocks.append(EditorBlock(.todo, text: "Open"))
        blocks.append(EditorBlock(.paragraph, level: 2, text: "Note under to-do"))
        var toggle = EditorBlock(.toggle, text: "Details")
        toggle.hiddenChildren = [EditorBlock(.paragraph, level: 2, text: "Hidden"), EditorBlock(.bulletList, level: 3, text: "Hidden item")]
        blocks.append(toggle)
        blocks.append(EditorBlock(.toggle, text: "Open toggle"))
        blocks.append(EditorBlock(.paragraph, level: 2, text: "Inside"))
        blocks.append(EditorBlock(.quote, text: "Quoted\u{2028}second line"))
        var callout = EditorBlock(.callout, text: "Heads up")
        callout.info.emoji = "⚠️"
        callout.info.color = .red
        blocks.append(callout)
        var code = EditorBlock(.codeBlock, text: "let a = 1\u{2028}  print(a < 2 && true)")
        code.info.language = "swift"
        blocks.append(code)
        blocks.append(EditorBlock(.divider))
        var image = EditorBlock(.image)
        image.image = EditorImage(source: "https://example.com/p.png", alt: "Chart \"Q3\"", size: CGSize(width: 640, height: 480))
        blocks.append(image)
        blocks.append(EditorBlock(.paragraph))
        blocks.append(EditorBlock(.paragraph, text: "End"))
        return blocks
    }

    // MARK: HTML

    func testHTMLRoundTripKeepsEveryBlock() {
        let original = sampleDocument
        let exported = RichEditorSerializer.html(blocks: original)
        let parsed = EditorHTMLParser.blocks(fromHTML: exported)
        XCTAssertEqual(Self.describe(parsed), Self.describe(original), exported)
    }

    func testHTMLRoundTripKeepsInlineFormats() {
        let parsed = EditorHTMLParser.blocks(fromHTML: RichEditorSerializer.html(blocks: sampleDocument))
        let rich = parsed[1].content
        func info(_ word: String) -> InlineInfo {
            let r = (rich.string as NSString).range(of: word)
            return InlineInfo(rich.attributes(at: r.location, effectiveRange: nil))
        }
        XCTAssertTrue(info("bold").bold)
        XCTAssertEqual(info("red link").color, .red)
        XCTAssertEqual(info("red link").link?.absoluteString, "https://example.com/a?b=1&c=2")
        XCTAssertEqual(info("marked").highlight, .yellow)
        XCTAssertTrue(info("marked").italic)
        XCTAssertTrue(info("code").code)
        XCTAssertTrue(info("gone").strike)
        XCTAssertTrue(info("gone").underline)
        XCTAssertFalse(info("Plain").bold)
        // A checked to-do's struck-through look is not a format.
        XCTAssertFalse(InlineInfo(parsed[6].content.attributes(at: 0, effectiveRange: nil)).strike)
    }

    func testRoundTripThroughEditorTextStorage() {
        let storage = EditorDocument.attributedString(from: sampleDocument, style: .standard)
        XCTAssertEqual(Self.describe(EditorDocument.blocks(from: storage)), Self.describe(sampleDocument))
    }

    func testAssetColorsRoundTrip() {
        let brand = RichColor.asset("BrandIndigo")
        XCTAssertEqual(brand.title, "Brand Indigo")
        XCTAssertEqual(RichColor.asset("brand_accent").title, "brand accent")
        XCTAssertEqual(RichColor(rawValue: "asset:BrandIndigo"), brand)
        XCTAssertNil(RichColor(rawValue: "notacolor"))
        XCTAssertEqual(RichColor(rawValue: "red"), .red)

        let text = NSMutableAttributedString(string: "plain ")
        text.append(inline("brand") { $0.color = brand; $0.highlight = .asset("Coral") })
        let exported = RichEditorSerializer.html(blocks: [EditorBlock(.paragraph, content: text)])
        XCTAssertTrue(exported.contains(#"data-color="asset:BrandIndigo""#), exported)
        let parsed = EditorHTMLParser.blocks(fromHTML: exported)[0].content
        let info = InlineInfo(parsed.attributes(at: parsed.length - 1, effectiveRange: nil))
        XCTAssertEqual(info.color, brand)
        XCTAssertEqual(info.highlight, .asset("Coral"))
    }

    func testHiddenEmailPartsAreNotImported() {
        XCTAssertEqual(html("""
        <body><div style="display: none">Preheader \u{2007}\u{034F} \u{2007}\u{034F}<div>nested</div></div>
        <div style="display:none; max-height:0; overflow:hidden;">Preheader again</div>
        <p style="margin: 0;">Hi there</p><span hidden>secret</span>
        <img src="https://t.example/o.gif" style="width: 1px !important; display: none !important;" alt="">
        <p style="color:#000;display:block">Bye</p></body>
        """), ["paragraph@1: Hi there", "paragraph@1: Bye"])
    }

    func testCustomColorsRoundTrip() {
        let custom = RichColor.custom(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        XCTAssertEqual(custom.rawValue, "hex:#FF8000")
        XCTAssertEqual(RichColor(rawValue: "hex:#FF8000"), custom)
        XCTAssertNil(RichColor(rawValue: "hex:#nothex"))
        let translucent = RichColor.custom(UIColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        XCTAssertEqual(translucent.rawValue, "hex:#0000FF80")

        let text = NSMutableAttributedString(string: "x ")
        text.append(inline("picked") { $0.color = custom; $0.highlight = translucent })
        let exported = RichEditorSerializer.html(blocks: [EditorBlock(.paragraph, content: text)])
        XCTAssertTrue(exported.contains("color:#FF8000"), exported)
        let parsed = EditorHTMLParser.blocks(fromHTML: exported)[0].content
        let info = InlineInfo(parsed.attributes(at: parsed.length - 1, effectiveRange: nil))
        XCTAssertEqual(info.color, custom)
        XCTAssertEqual(info.highlight, translucent)
    }

    func testEverydayEmailHTML() {
        XCTAssertEqual(html("""
        <div dir="ltr">Hi team,<div><br></div><div>Agenda:</div>
        <ul><li>Intro</li><li><div>Demo</div><ul><li>iOS &amp; web</li></ul></li></ul>
        <ol><li>First</li><li>Second</li></ol>
        <blockquote type="cite"><div>Earlier message</div></blockquote>
        <div>Thanks,<br>Sam</div></div>
        """), [
            "paragraph@1: Hi team,",
            "paragraph@1: ",
            "paragraph@1: Agenda:",
            "bulletList@1: Intro",
            "bulletList@1: Demo",
            "bulletList@2: iOS & web",
            "numberedList@1: First",
            "numberedList@1: Second",
            "quote@1: Earlier message",
            "paragraph@1: Thanks,⏎Sam"
        ])
    }

    func testGoogleDocsAndWebHTML() {
        let blocks = EditorHTMLParser.blocks(fromHTML: """
        <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1">
        <p><span style="font-weight:700">Bold</span><span> plain </span><span style="font-style:italic">it</span></p>
        <h2>Title</h2><p>Line <a href="javascript:alert(1)">bad</a> <a href="https://ok.com">ok</a></p></b>
        <pre>
        let x = 1
          x += 1</pre>
        <ul><li><input type="checkbox" checked> Shipped</li><li><input type="checkbox"> Pending</li></ul>
        <details><summary>More</summary><p>Inside</p></details>
        <hr><img src="https://t.co/pixel.gif" width="1" height="1"><img src="https://x.com/a.png" alt="A">
        <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Pen</td><td>2</td></tr></table>
        <script>alert(1)</script><style>p{}</style>
        """)
        XCTAssertEqual(Self.describe(blocks), [
            "paragraph@1: Bold plain it",
            "heading2@1: Title",
            "paragraph@1: Line bad ok",
            "codeBlock@1: let x = 1⏎  x += 1",
            "todo@1[x]: Shipped",
            "todo@1: Pending",
            "toggle@1[closed]: More",
            "  paragraph@2: Inside",
            "divider@1: ",
            "image@1: img:https://x.com/a.png|A",
            "paragraph@1: Name\tQty",
            "paragraph@1: Pen\t2"
        ])
        let first = blocks[0].content
        XCTAssertTrue(InlineInfo(first.attributes(at: 0, effectiveRange: nil)).bold)
        XCTAssertFalse(InlineInfo(first.attributes(at: 6, effectiveRange: nil)).bold, "font-weight:normal on <b> cancels bold")
        XCTAssertTrue(InlineInfo(first.attributes(at: first.length - 1, effectiveRange: nil)).italic)
        let line = blocks[2].content
        XCTAssertNil(InlineInfo(line.attributes(at: 5, effectiveRange: nil)).link, "javascript: links are dropped")
        XCTAssertEqual(InlineInfo(line.attributes(at: line.length - 1, effectiveRange: nil)).link?.host, "ok.com")
    }

    func testTextMarkersBecomeTodos() {
        XCTAssertEqual(html("<ul><li>[x] Done</li><li>☐ Open</li></ul>"), ["todo@1[x]: Done", "todo@1: Open"])
    }

    func testJSONEscapedHTML() {
        XCTAssertEqual(html(#"<ul><li>One<\/li><li><a href=\"https:\/\/x.com\">Two<\/a><\/li><\/ul>"#),
                       ["bulletList@1: One", "bulletList@1: Two"])
    }

    // MARK: Markdown

    func testMarkdownImport() {
        XCTAssertEqual(markdown("""
        # Title
        Some **bold** text
        with a soft break.

        - one
          - nested
        - [ ] task
        - [x] done

        1. first
        2. second

        > quoted

        ---

        ```swift
        let a = 1
        ```

        ![Logo](https://x.com/l.png)
        """), [
            "heading1@1: Title",
            "paragraph@1: Some bold text⏎with a soft break.",
            "bulletList@1: one",
            "bulletList@2: nested",
            "todo@1: task",
            "todo@1[x]: done",
            "numberedList@1: first",
            "numberedList@1: second",
            "quote@1: quoted",
            "divider@1: ",
            "codeBlock@1[swift]: let a = 1",
            "image@1: img:https://x.com/l.png|Logo"
        ])
    }

    func testSetextHeadingIsNotADivider() {
        XCTAssertEqual(markdown("Title\n---\nBody"), ["heading2@1: Title", "paragraph@1: Body"])
    }

    func testMarkdownExport() {
        var blocks = [EditorBlock(.heading2, text: "Notes")]
        let rich = NSMutableAttributedString(string: "See ")
        rich.append(inline("docs") { $0.link = URL(string: "https://x.com"); $0.bold = true })
        blocks.append(EditorBlock(.paragraph, content: rich))
        blocks.append(EditorBlock(.bulletList, text: "a"))
        blocks.append(EditorBlock(.numberedList, level: 2, text: "b"))
        blocks.append(EditorBlock(.numberedList, level: 2, text: "c"))
        var todo = EditorBlock(.todo, text: "ship")
        todo.info.checked = true
        blocks.append(todo)
        blocks.append(EditorBlock(.paragraph, text: "- not a list"))
        blocks.append(EditorBlock(.divider))
        var code = EditorBlock(.codeBlock, text: "x\u{2028}y")
        code.info.language = "js"
        blocks.append(code)
        XCTAssertEqual(RichEditorSerializer.markdown(blocks: blocks), """
        ## Notes

        See [**docs**](https://x.com)

        - a
          1. b
          2. c
        - [x] ship

        \\- not a list

        ---

        ```js
        x
        y
        ```
        """)
    }

    func testMarkdownRoundTrip() {
        let blocks = [EditorBlock(.heading1, text: "T"), EditorBlock(.bulletList, text: "a"),
                      EditorBlock(.bulletList, level: 2, text: "b"), EditorBlock(.todo, text: "c"),
                      EditorBlock(.quote, text: "q"), EditorBlock(.divider), EditorBlock(.paragraph, text: "end")]
        XCTAssertEqual(markdown(RichEditorSerializer.markdown(blocks: blocks)), Self.describe(blocks))
    }

    // MARK: Plain text

    func testPlainTextExportAndImport() {
        let blocks = sampleDocument
        let plain = RichEditorSerializer.plainText(from: EditorDocument.attributedString(from: blocks, style: .standard))
        XCTAssertTrue(plain.contains("• One\n  • One.a\n    1. Deep\n• Two\n☑ Done\n☐ Open"), plain)
        XCTAssertTrue(plain.contains("▸ Details\n  Hidden\n    • Hidden item"), plain)
        XCTAssertTrue(plain.contains("⚠️ Heads up"), plain)

        XCTAssertEqual(Self.describe(EditorImporter.plainBlocks("Hello\n\n- a\n  - b\n1. c\n[ ] d\n> e")), [
            "paragraph@1: Hello", "paragraph@1: ", "bulletList@1: a", "bulletList@2: b",
            "numberedList@1: c", "todo@1: d", "quote@1: e"
        ])
    }
}
