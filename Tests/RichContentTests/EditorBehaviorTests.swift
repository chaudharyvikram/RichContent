import XCTest
@testable import RichContent

/// Editing behaviour, driven through the controller like a user typing.
@MainActor
final class EditorBehaviorTests: XCTestCase {

    private var editor: RichEditorController!
    private var textView: RichEditorTextView!

    override func setUp() async throws {
        editor = RichEditorController()
        textView = RichEditorTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 375, height: 700)
        editor.attach(to: textView)
    }

    private func load(_ html: String) {
        editor.load(.html(html))
    }

    private var blocks: [String] { EditorFormatTests.describe(EditorDocument.blocks(from: textView.textStorage)) }

    private func caret(_ location: Int) { textView.selectedRange = NSRange(location: location, length: 0) }
    private func caretAtEnd() { caret(textView.textStorage.length) }

    /// Types like the keyboard: asks the delegate, inserts with typing attributes.
    private func type(_ string: String) {
        for character in string {
            let text = String(character)
            let range = textView.selectedRange
            guard editor.textView(textView, shouldChangeTextIn: range, replacementText: text) else { continue }
            textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
            textView.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
            editor.textViewDidChange(textView)
        }
    }

    private func backspace() {
        guard !editor.handleDeleteBackward() else { return }
        let range = textView.selectedRange
        let target = range.length > 0 ? range : NSRange(location: max(range.location - 1, 0), length: range.location > 0 ? 1 : 0)
        guard target.length > 0, editor.textView(textView, shouldChangeTextIn: target, replacementText: "") else { return }
        textView.textStorage.replaceCharacters(in: target, with: "")
        textView.selectedRange = NSRange(location: target.location, length: 0)
        editor.textViewDidChange(textView)
    }

    // MARK: Markdown shortcuts

    func testBlockShortcuts() {
        let cases: [(String, String)] = [
            ("- ", "bulletList@1: x"), ("* ", "bulletList@1: x"), ("1. ", "numberedList@1: x"), ("[] ", "todo@1: x"),
            ("[x] ", "todo@1[x]: x"), ("# ", "heading1@1: x"), ("## ", "heading2@1: x"), ("### ", "heading3@1: x"),
            ("> ", "toggle@1[closed]: x"), ("\" ", "quote@1: x"), ("```", "codeBlock@1: x")
        ]
        for (shortcut, expected) in cases {
            editor.clear()
            type(shortcut + "x")
            XCTAssertEqual(blocks, [expected], shortcut)
        }
    }

    func testDividerShortcut() {
        type("---")
        XCTAssertEqual(blocks, ["divider@1: "])
        XCTAssertEqual(editor.blockType, .paragraph, "the caret is on a new line below")
        type("after")
        XCTAssertEqual(blocks, ["divider@1: ", "paragraph@1: after"])
    }

    func testInlineShortcuts() {
        type("a **bold** and *it* and `c` and ~s~ x")
        XCTAssertEqual(blocks, ["paragraph@1: a bold and it and c and s x"])
        let s = textView.textStorage
        func at(_ word: String) -> InlineInfo { InlineInfo(s.attributes(at: (s.string as NSString).range(of: word).location, effectiveRange: nil)) }
        XCTAssertTrue(at("bold").bold)
        XCTAssertTrue(at("it").italic)
        XCTAssertTrue(at("c ").code)
        XCTAssertTrue(at("s x").strike)
        XCTAssertFalse(at("x").strike, "typing after the closing marker is unformatted")
        XCTAssertFalse(at("and").bold)
    }

    func testShortcutsDontFireMidText() {
        type("a - b")
        XCTAssertEqual(blocks, ["paragraph@1: a - b"])
        type(" snake_case_name")
        XCTAssertEqual(blocks, ["paragraph@1: a - b snake_case_name"])
    }

    // MARK: Return

    func testReturnContinuesAndLeavesLists() {
        type("- one\ntwo\n")
        XCTAssertEqual(blocks, ["bulletList@1: one", "bulletList@1: two"])
        XCTAssertEqual(editor.blockType, .bulletList, "the new empty line is still a list item")
        type("\n")
        XCTAssertEqual(editor.blockType, .paragraph, "Return on an empty item leaves the list")
        type("after")
        XCTAssertEqual(blocks, ["bulletList@1: one", "bulletList@1: two", "paragraph@1: after"])
    }

    func testReturnOnEmptyNestedItemOutdents() {
        load("<ul><li>a<ul><li>b</li></ul></li></ul>")
        caretAtEnd()
        type("\n")
        XCTAssertEqual(editor.listLevel, 2)
        type("\n")
        XCTAssertEqual(editor.listLevel, 1)
        XCTAssertEqual(editor.blockType, .bulletList)
    }

    func testReturnInTodoStartsUnchecked() {
        load(#"<ul data-type="todo"><li data-checked="true">done</li></ul>"#)
        caretAtEnd()
        type("\nnext")
        XCTAssertEqual(blocks, ["todo@1[x]: done", "todo@1: next"])
    }

    func testReturnAfterHeadingIsText() {
        type("# Title\nbody")
        XCTAssertEqual(blocks, ["heading1@1: Title", "paragraph@1: body"])
    }

    func testReturnSplitsMidText() {
        load("<ul><li>abcd</li></ul>")
        caret(2)
        type("\n")
        XCTAssertEqual(blocks, ["bulletList@1: ab", "bulletList@1: cd"])
        XCTAssertEqual(textView.selectedRange.location, 3)
    }

    func testCodeBlockReturn() {
        type("```let a\n  b\n\nafter")
        XCTAssertEqual(blocks, ["codeBlock@1: let a⏎  b", "paragraph@1: after"])
    }

    func testOpenToggleReturnCreatesChild() {
        type("> Title")
        XCTAssertEqual(blocks, ["toggle@1[closed]: Title"])
        type("\nsibling")
        XCTAssertEqual(blocks, ["toggle@1[closed]: Title", "toggle@1[closed]: sibling"])
        caret(3)
        editor.toggleCollapsed()
        caret(5)
        type("\nchild")
        XCTAssertEqual(blocks, ["toggle@1: Title", "paragraph@2: child", "toggle@1[closed]: sibling"])
    }

    // MARK: Backspace

    func testBackspaceAtStartRemovesFormatThenOutdentsThenJoins() {
        load("<div>top</div><ul><li>a<ul><li>b</li></ul></li></ul>")
        let b = (textView.textStorage.string as NSString).range(of: "b").location
        caret(b)
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: top", "bulletList@1: a", "paragraph@2: b"])
        caret(b)
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: top", "bulletList@1: a", "paragraph@1: b"])
        caret(b)
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: top", "bulletList@1: ab"])
        XCTAssertEqual(textView.selectedRange.location, b - 1)
    }

    func testBackspaceRemovesDividerAbove() {
        load("<div>a</div><hr><div>b</div>")
        caret((textView.textStorage.string as NSString).range(of: "b").location)
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: a", "paragraph@1: b"])
    }

    func testBackspaceRemovesEmptyBlockAbove() {
        load("<div>x</div><div><br></div><ul><li>item</li></ul>")
        caret(3)
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: x", "paragraph@1: ", "paragraph@1: item"], "a list item turns into text first")
        backspace()
        XCTAssertEqual(blocks, ["paragraph@1: x", "paragraph@1: item"], "then the empty block above goes")
        XCTAssertEqual(textView.textStorage.string, "x\nitem")
    }

    // MARK: Nesting

    func testIndentRules() {
        load("<ul><li>a</li><li>b</li><li>c</li></ul>")
        caret(0)
        editor.indent()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@1: b", "bulletList@1: c"], "the first block can't be indented")
        caret(2)
        editor.indent()
        editor.indent()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: b", "bulletList@1: c"], "at most one deeper than the block above")
        caret(0)
        editor.indent()
        XCTAssertEqual(blocks[0], "bulletList@1: a")
        caret(4)
        editor.indent()
        editor.indent()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: b", "bulletList@3: c"])
        caret(2)
        editor.outdent()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@1: b", "bulletList@2: c"], "children move with their parent")
    }

    func testIndentUnderClosedToggleMovesInside() {
        load(#"<details><summary>T</summary><p>hidden</p></details><div>x</div>"#)
        caretAtEnd()
        editor.indent()
        XCTAssertEqual(blocks, ["toggle@1[closed]: T", "  paragraph@2: hidden", "  paragraph@2: x"])
    }

    // MARK: To-dos and toggles

    func testCheckAndCollapse() {
        load(#"<ul data-type="todo"><li data-checked="false">task</li></ul><details open><summary>T</summary><p>child</p><ul><li>deep</li></ul></details><div>after</div>"#)
        caret(1)
        editor.toggleChecked()
        XCTAssertEqual(blocks.first, "todo@1[x]: task")
        let toggle = (textView.textStorage.string as NSString).range(of: "T").location
        caret(toggle)
        editor.toggleCollapsed()
        XCTAssertEqual(blocks, ["todo@1[x]: task", "toggle@1[closed]: T", "  paragraph@2: child", "  bulletList@2: deep", "paragraph@1: after"])
        XCTAssertFalse(textView.textStorage.string.contains("child"), "hidden children are not in the text")
        XCTAssertTrue(editor.html.contains("child"), "export includes hidden children")
        editor.toggleCollapsed()
        XCTAssertEqual(blocks, ["todo@1[x]: task", "toggle@1: T", "paragraph@2: child", "bulletList@2: deep", "paragraph@1: after"])
    }

    func testCollapseLastToggleKeepsDocumentShape() {
        load(#"<details open><summary>T</summary><p>child</p></details>"#)
        caret(0)
        editor.toggleCollapsed()
        XCTAssertEqual(textView.textStorage.string, "T")
        editor.toggleCollapsed()
        XCTAssertEqual(textView.textStorage.string, "T\nchild")
    }

    func testTurnIntoKeepsInlineFormatsAndRevealsToggleChildren() {
        load(#"<details><summary><b>Bold</b> title</summary><p>kid</p></details>"#)
        caret(1)
        editor.setBlock(.bulletList)
        XCTAssertEqual(blocks, ["bulletList@1: Bold title", "paragraph@2: kid"])
        XCTAssertTrue(InlineInfo(textView.textStorage.attributes(at: 0, effectiveRange: nil)).bold)
        editor.setBlock(.toggle)
        XCTAssertEqual(blocks, ["toggle@1: Bold title", "paragraph@2: kid"], "a toggle with children starts open")
    }

    // MARK: Block actions

    func testMoveDuplicateDelete() {
        load("<ul><li>a<ul><li>a1</li></ul></li><li>b</li></ul><div>c</div>")
        caret(0)
        editor.moveBlockDown()
        XCTAssertEqual(blocks, ["bulletList@1: b", "bulletList@1: a", "bulletList@2: a1", "paragraph@1: c"])
        editor.moveBlockUp()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: a1", "bulletList@1: b", "paragraph@1: c"])
        caret(0)
        editor.duplicateBlock()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: a1", "bulletList@1: a", "bulletList@2: a1", "bulletList@1: b", "paragraph@1: c"])
        editor.deleteBlock()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: a1", "bulletList@1: b", "paragraph@1: c"])
        caretAtEnd()
        editor.deleteBlock()
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: a1", "bulletList@1: b"])
        XCTAssertEqual(textView.textStorage.string, "a\na1\nb")
    }

    func testDragMove() {
        load("<div>a</div><ul><li>b<ul><li>b1</li></ul></li></ul><div>c</div>")
        editor.moveBlock(at: 1, toBefore: 4)
        XCTAssertEqual(blocks, ["paragraph@1: a", "paragraph@1: c", "bulletList@1: b", "bulletList@2: b1"])
        editor.moveBlock(at: 2, toBefore: 0)
        XCTAssertEqual(blocks, ["bulletList@1: b", "bulletList@2: b1", "paragraph@1: a", "paragraph@1: c"])
        editor.moveBlock(at: 3, toBefore: 1)
        XCTAssertEqual(blocks, ["bulletList@1: b", "paragraph@2: c", "bulletList@2: b1", "paragraph@1: a"], "dropped blocks take the level where they land")
    }

    // MARK: Slash menu

    func testSlashCommand() {
        type("hello\n/tod")
        XCTAssertEqual(editor.slash?.results.first?.title, "To-do list")
        type("\n")
        XCTAssertNil(editor.slash)
        type("task")
        XCTAssertEqual(blocks, ["paragraph@1: hello", "todo@1: task"])
    }

    func testSlashMenuClosesWithoutMatches() {
        type("/zzzzz")
        XCTAssertNil(editor.slash)
        type("\n")
        XCTAssertEqual(blocks, ["paragraph@1: /zzzzz"], "the text stays as typed")
    }

    func testSlashOnlyAtWordStart() {
        type("a/b")
        XCTAssertNil(editor.slash)
        type(" /")
        XCTAssertNotNil(editor.slash)
    }

    func testColorMenuHasPickerThenPaletteInTwoSections() {
        let menu = EditorMenus.color(editor, wholeBlock: false)
        let groups = menu.children.compactMap { $0 as? UIMenu }
        XCTAssertEqual(groups.map(\.title), ["Text colors", "", "Background colors", ""])
        XCTAssertTrue(groups.allSatisfy { $0.options.contains(.displayInline) }, "all groups are expanded")
        XCTAssertEqual(groups[0].children.map(\.title), ["Choose from color picker…"])
        XCTAssertEqual(groups[1].children.map(\.title), RichColor.allCases.map(\.title))
        XCTAssertEqual(groups[2].children.map(\.title), ["Choose from color picker…"])
        XCTAssertEqual(groups[3].children.first?.title, "Default background")
    }

    func testSlashFilterRanking() {
        let all = RichEditorCommand.catalog(.standard)
        XCTAssertEqual(RichEditorCommand.filter(all, query: "h2").first?.title, "Heading 2")
        XCTAssertEqual(RichEditorCommand.filter(all, query: "bul").first?.title, "Bulleted list")
        XCTAssertEqual(RichEditorCommand.filter(all, query: "red").first?.title, "Red")
        XCTAssertFalse(RichEditorCommand.catalog(.email).contains { $0.action == .block(.toggle) })
    }

    // MARK: Paste

    func testPasteBlocksSplitsAtCaret() {
        load("<div>start end</div>")
        caret(6)
        editor.insertBlocks(EditorHTMLParser.blocks(fromHTML: "<p>mid</p><ul><li>x</li><li>y</li></ul>"))
        XCTAssertEqual(blocks, ["paragraph@1: start mid", "bulletList@1: x", "bulletList@1: y", "paragraph@1: end"])
        XCTAssertEqual(textView.selectedRange.location, (textView.textStorage.string as NSString).range(of: "y").location + 1)
    }

    func testPasteSingleBlockIsInline() {
        load("<h2>ab</h2>")
        caret(1)
        editor.insertBlocks(EditorHTMLParser.blocks(fromHTML: "<p><b>X</b></p>"))
        XCTAssertEqual(blocks, ["heading2@1: aXb"])
        XCTAssertTrue(InlineInfo(textView.textStorage.attributes(at: 1, effectiveRange: nil)).bold)
    }

    func testPasteIntoNestedBlockKeepsRelativeLevels() {
        load("<ul><li>a<ul><li><br></li></ul></li></ul>")
        caretAtEnd()
        editor.insertBlocks(EditorHTMLParser.blocks(fromHTML: "<ul><li>p<ul><li>q</li></ul></li></ul>"))
        XCTAssertEqual(blocks, ["bulletList@1: a", "bulletList@2: p", "bulletList@3: q"])
    }

    // MARK: Formats

    func testInlineFormatsOnSelectionAndCaret() {
        type("hello world")
        textView.selectedRange = NSRange(location: 0, length: 5)
        editor.toggle(.bold)
        XCTAssertTrue(editor.activeFormats.contains(.bold))
        editor.setTextColor(.blue)
        editor.setHighlight(.yellow)
        let a = InlineInfo(textView.textStorage.attributes(at: 0, effectiveRange: nil))
        XCTAssertTrue(a.bold)
        XCTAssertEqual(a.color, .blue)
        XCTAssertEqual(a.highlight, .yellow)
        XCTAssertFalse(InlineInfo(textView.textStorage.attributes(at: 6, effectiveRange: nil)).bold)

        caretAtEnd()
        editor.toggle(.italic)
        type("!")
        XCTAssertTrue(InlineInfo(textView.textStorage.attributes(at: textView.textStorage.length - 1, effectiveRange: nil)).italic)
    }

    // MARK: Image uploads

    private struct UploadError: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    private var photo: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testFailedImageUploadBlocksSendingUntilRetried() async throws {
        var fails = true
        var reported = 0
        editor.configuration.showsImageUploadFailureAlert = false
        editor.onImageUploadFailure = { _ in reported += 1 }
        editor.imageUploader = { _ in
            if fails { throw UploadError() }
            return URL(string: "https://cdn.example.com/photo.jpg")!
        }

        editor.insertImage(photo)
        XCTAssertEqual(editor.pendingImageUploads, 1)
        XCTAssertFalse(editor.allImagesUploaded)

        try await waitUntil { editor.failedImageUploads == 1 }
        XCTAssertEqual(editor.pendingImageUploads, 0)
        XCTAssertFalse(editor.allImagesUploaded)
        XCTAssertEqual(reported, 1)
        let attachment = textView.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? RichImageAttachment
        XCTAssertEqual(attachment?.uploadState, .failed)

        fails = false
        editor.retryFailedImageUploads()
        XCTAssertEqual(editor.pendingImageUploads, 1)
        try await waitUntil { editor.allImagesUploaded }
        XCTAssertTrue(editor.html.contains("https://cdn.example.com/photo.jpg"))
        XCTAssertFalse(editor.html.contains("data:image"))
    }

    func testFailedImageCanBeRemoved() async throws {
        editor.configuration.showsImageUploadFailureAlert = false
        editor.imageUploader = { _ in throw UploadError() }
        type("Hello")
        editor.insertImage(photo)
        try await waitUntil { editor.failedImageUploads == 1 }

        editor.removeFailedImages()
        XCTAssertTrue(editor.allImagesUploaded)
        XCTAssertFalse(editor.html.contains("<img"))
        XCTAssertTrue(blocks.contains("paragraph@1: Hello"))
    }

    func testDeletingAnUploadingImageUnblocksSending() async throws {
        editor.imageUploader = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return URL(string: "https://cdn.example.com/slow.jpg")!
        }
        editor.insertImage(photo)
        XCTAssertFalse(editor.allImagesUploaded)
        textView.selectedRange = NSRange(location: 0, length: 0)
        editor.deleteBlock()
        XCTAssertTrue(editor.allImagesUploaded)
    }

    func testQuotedOriginalIsShownButNotEditableAndIsSent() {
        type("Sounds good")
        XCTAssertEqual(editor.replyHTML(), editor.html)
        XCTAssertNil(textView.quotedHost)

        let original = RichContent.html("<p>Can we demo on Thursday?</p>")
        editor.quotedOriginal = QuotedOriginal(original, attribution: "On Oct 28, Alex wrote:")
        XCTAssertNotNil(textView.quotedHost)
        XCTAssertTrue(textView.quotedHost?.view.superview === textView)
        // Not part of the editable document…
        XCTAssertFalse(editor.html.contains("Can we demo"))
        XCTAssertEqual(blocks, ["paragraph@1: Sounds good"])
        // …but sent with the reply.
        XCTAssertEqual(editor.replyHTML(), editor.replyHTML(quoting: original, attribution: "On Oct 28, Alex wrote:"))
        XCTAssertTrue(editor.replyHTML().contains("Can we demo on Thursday?"))

        editor.quotedOriginal = nil
        XCTAssertNil(textView.quotedHost)
        XCTAssertEqual(editor.replyHTML(), editor.html)
    }

    func testPickedColorAppliesToSelectionFromWhenPickerOpened() {
        type("hello world")
        let purple = UIColor(red: 0.6, green: 0.2, blue: 0.9, alpha: 1)
        // The picker moved the caret away; the color still goes to "hello".
        caretAtEnd()
        editor.applyPickedColor(purple, background: false, wholeBlock: false, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(InlineInfo(textView.textStorage.attributes(at: 0, effectiveRange: nil)).color, .custom(purple))
        XCTAssertNil(InlineInfo(textView.textStorage.attributes(at: 6, effectiveRange: nil)).color)

        editor.applyPickedColor(purple, background: true, wholeBlock: false, range: NSRange(location: 6, length: 5))
        XCTAssertEqual(InlineInfo(textView.textStorage.attributes(at: 6, effectiveRange: nil)).highlight, .custom(purple))
    }

    func testColorPickerAppliesOnceAndOnlyWhenChanged() {
        var applied: [UIColor] = []
        let done = expectation(description: "applied")
        let coordinator = ColorPickerCoordinator(initial: .black) { applied.append($0); done.fulfill() }
        coordinator.finish(with: .purple)
        coordinator.finish(with: .red)   // ✕ and swipe-dismiss both reporting
        wait(for: [done], timeout: 1)
        XCTAssertEqual(applied.map { RichColor.custom($0) }, [.custom(.purple)])

        var unchanged = false
        let closedUntouched = ColorPickerCoordinator(initial: .black) { _ in unchanged = true }
        closedUntouched.finish(with: .black)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(unchanged)
    }

    func testHeadingBoldIsNotAFormat() {
        type("# Title")
        XCTAssertFalse(editor.activeFormats.contains(.bold))
        XCTAssertTrue(editor.html.contains("<h1>Title</h1>"))
    }

    func testCodeTextInCodeBlockHasNoMarkdownShortcuts() {
        type("```a **b** - c")
        XCTAssertEqual(blocks, ["codeBlock@1: a **b** - c"])
    }

    // MARK: Undo

    func testUndoRestoresBlock() throws {
        let undo = try XCTUnwrap(textView.undoManager, "UITextView provides an undo manager")
        type("abc")
        undo.removeAllActions()
        editor.setBlock(.heading1)
        XCTAssertEqual(blocks, ["heading1@1: abc"])
        editor.undo()
        XCTAssertEqual(blocks, ["paragraph@1: abc"])
        editor.redo()
        XCTAssertEqual(blocks, ["heading1@1: abc"])
    }

    // MARK: Loading

    func testLoadsEveryFormat() {
        editor.load(.markdown("# T\n- [ ] a"))
        XCTAssertEqual(blocks, ["heading1@1: T", "todo@1: a"])
        editor.load(.plain("x\n> y"))
        XCTAssertEqual(blocks, ["paragraph@1: x", "quote@1: y"])
        editor.load(.auto("<p>html</p>\n\n\n## md"))
        XCTAssertEqual(blocks, ["paragraph@1: html", "heading2@1: md"])
        XCTAssertEqual(editor.markdown, "html\n\n## md")
    }
}
