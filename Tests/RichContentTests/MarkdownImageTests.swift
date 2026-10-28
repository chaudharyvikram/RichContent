import XCTest
@testable import RichContent

@MainActor
final class MarkdownImageTests: XCTestCase {

    // MARK: Splitting

    func testImageLineBecomesImgPart() {
        XCTAssertEqual(RichContent.markdown("# Report\n![Chart](https://x.com/c.png)\nDone.").flattened, [
            .markdown("# Report"),
            .html(#"<img src="https://x.com/c.png" alt="Chart">"#),
            .markdown("Done.")
        ])
    }

    func testInlineImageSplitsSurroundingText() {
        XCTAssertEqual(MixedContentSegmenter.splittingImages("See **this** ![chart](https://x.com/c.png) below"), [
            .markdown("See **this** "),
            .html(#"<img src="https://x.com/c.png" alt="chart">"#),
            .markdown(" below")
        ])
    }

    func testAdjacentImagesShareOnePart() {
        let parts = MixedContentSegmenter.splittingImages("![a](https://x.com/1.png) ![b](https://x.com/2.png)\n![c](https://x.com/3.png)")
        XCTAssertEqual(parts, [.html(
            #"<img src="https://x.com/1.png" alt="a"> <img src="https://x.com/2.png" alt="b"> <img src="https://x.com/3.png" alt="c">"#
        )])
    }

    func testLinkedImageKeepsLink() {
        XCTAssertEqual(MixedContentSegmenter.splittingImages("[![Logo](https://x.com/l.png)](https://x.com)"), [
            .html(#"<a href="https://x.com"><img src="https://x.com/l.png" alt="Logo"></a>"#)
        ])
    }

    func testTitleAngleBracketsAndEscaping() {
        XCTAssertEqual(MixedContentSegmenter.splittingImages(#"![A "quoted" <alt>](<https://x.com/a.png?a=1&b=2> "Title")"#), [
            .html(#"<img src="https://x.com/a.png?a=1&amp;b=2" alt="A &quot;quoted&quot; &lt;alt&gt;">"#)
        ])
    }

    func testImagesInCodeAreLeftAlone() {
        let markdown = "Use `![x](https://x.com/a.png)` syntax\n```\n![y](https://x.com/b.png)\n```"
        XCTAssertEqual(MixedContentSegmenter.splittingImages(markdown), [.markdown(markdown)])
    }

    func testEscapedImageAndPlainLinkAreLeftAlone() {
        let markdown = #"\![not](https://x.com/a.png) and [link](https://x.com)"#
        XCTAssertEqual(MixedContentSegmenter.splittingImages(markdown), [.markdown(markdown)])
    }

    func testAutoDetectsImageOnlyMarkdown() {
        XCTAssertEqual(RichContent.auto("![](https://x.com/a.png)").flattened, [
            .html(#"<img src="https://x.com/a.png" alt="">"#)
        ])
    }

    // MARK: Rendering

    func testImageRendersInWebViewByDefault() {
        let blocks = RichContentRenderer.render(.markdown("Hi\n\n![Chart](https://x.com/c.png)"), style: .standard)
        XCTAssertEqual(blocks.count, 2)
        guard case .text(let text) = blocks.first, case .web(let html) = blocks.last else {
            return XCTFail("expected text then web, got \(blocks)")
        }
        XCTAssertEqual(text.string, "Hi")
        XCTAssertTrue(html.contains(#"<img src="https://x.com/c.png""#))
    }

    func testNativeModeShowsAltText() {
        var style = RichContentStyle.standard
        style.htmlRendering = .native
        let text = RichContentRenderer.attributedString(for: .markdown("![Quarterly chart](https://x.com/c.png)"), style: style)
        XCTAssertEqual(text.string, "Quarterly chart")
    }
}
