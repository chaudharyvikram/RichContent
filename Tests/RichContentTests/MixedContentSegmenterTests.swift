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

    func testTagSplitAcrossLinesStaysHTML() {
        // A tracking pixel at the end of an email, its src on the next line.
        let email = "<table><tr><td>Hi</td></tr></table>\r\n<img alt=\"\" src=\r\n\"https://t.example.com/o/ODU1=\" >\r\n"
        let parts = MixedContentSegmenter.segments(of: email)
        XCTAssertEqual(parts.count, 1)
        guard case .html(let html)? = parts.first else { return XCTFail("\(parts)") }
        XCTAssertTrue(html.contains("ODU1="))

        // A multi-line opening tag still counts for nesting.
        let nested = "<div\n class=\"card\">\nInside\n\nStill inside\n</div>\n\nAfter"
        let split = MixedContentSegmenter.segments(of: nested)
        guard case .html(let block)? = split.first else { return XCTFail("\(split)") }
        XCTAssertTrue(block.contains("Still inside"))
        XCTAssertEqual(split.count, 2)
    }

    func testUnfinishedTagSplit() {
        XCTAssertEqual(MixedContentSegmenter.splitUnfinishedTag("<p>ok</p><img src=").unfinished, "<img src=")
        XCTAssertEqual(MixedContentSegmenter.splitUnfinishedTag("<a title=\"a > b\" href=").unfinished, "<a title=\"a > b\" href=")
        XCTAssertEqual(MixedContentSegmenter.splitUnfinishedTag("1 < 2 and <b>x</b>").unfinished, "")
    }
}
