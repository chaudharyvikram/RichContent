import XCTest
@testable import RichContent

final class MixedContentSegmenterTests: XCTestCase {

    private func segments(_ string: String) -> [RichContent] {
        MixedContentSegmenter.segments(of: string)
    }

    // MARK: Optional-close elements across lines

    func testMultiLineParagraphsStayOneBlock() {
        let html = "<p>Hello\nworld</p>\n<p>Second\nline</p>"
        XCTAssertEqual(segments(html), [.html(html)])
    }

    func testMultiLineListItemStaysInList() {
        XCTAssertEqual(segments("<ul>\n<li>One\ncontinues</li>\n</ul>\nThanks"), [
            .html("<ul>\n<li>One\ncontinues</li>\n</ul>"),
            .plain("Thanks")
        ])
    }

    func testMultiLineTableCellStaysInTable() {
        XCTAssertEqual(segments("<table>\n<tr><td>a\nb</td></tr>\n</table>\nafter text"), [
            .html("<table>\n<tr><td>a\nb</td></tr>\n</table>"),
            .plain("after text")
        ])
    }

    func testUnclosedParagraphEndsAtBlankLine() {
        let parts = segments("<p>Sloppy\n\nPlain reply after blank")
        XCTAssertEqual(parts.first, .html("<p>Sloppy"))
        XCTAssertEqual(parts.count, 2)
        guard case .plain(let reply) = parts.last else { return XCTFail("expected plain reply, got \(parts)") }
        XCTAssertEqual(reply.trimmingCharacters(in: .whitespacesAndNewlines), "Plain reply after blank")
    }

    // MARK: Inline tags at line start

    func testInlineTagLineStaysMarkdown() {
        let markdown = "## Notes\n<b>Note:</b> ship it\n- item"
        XCTAssertEqual(segments(markdown), [.markdown(markdown)])
    }

    func testInlineLinkLineStaysMarkdown() {
        let markdown = "Hi\n<a href=\"https://x.com\">link</a>\n**bold**"
        XCTAssertEqual(segments(markdown), [.markdown(markdown)])
    }

    func testFontWrapperOpensHTML() {
        XCTAssertEqual(segments("<font face=\"Arial\">\n<div>Body</div>\n</font>\n\n\n## After\n- x"), [
            .html("<font face=\"Arial\">\n<div>Body</div>\n</font>"),
            .markdown("## After\n- x")
        ])
    }

    func testInlineLineWithBreakOpensHTML() {
        let html = "<span>Hi</span><br>\n<span>there</span>"
        XCTAssertEqual(segments(html), [.html(html)])
    }

    func testInlineOnlyTextWithoutMarkdownIsHTML() {
        XCTAssertEqual(segments("<b>Hi</b>\nthanks"), [.html("<b>Hi</b>\nthanks")])
    }

    func testMarkdownWithInlineTagIsNotSplit() {
        let content = RichContent.markdown("Intro\n<b>Note:</b> ship it\n- item")
        XCTAssertEqual(content.flattened, [.markdown("Intro\n<b>Note:</b> ship it\n- item")])
    }
}
