import XCTest
@testable import RichContent

@MainActor
final class HTMLRendererTests: XCTestCase {

    private func prepared(_ html: String) -> String {
        HTMLRenderer.prepare(html, style: .standard)
    }

    // MARK: Native import never loads remote resources

    func testStripsStylesheetsImportsAndRefresh() {
        let out = prepared("""
        <link rel="stylesheet" href="https://t.co/a.css">
        <meta http-equiv="refresh" content="0;url=https://x">
        <style>@import url("https://f.com/x.css"); @import "https://f.com/y.css";</style>
        <div>Body</div>
        """)
        XCTAssertFalse(out.contains("http"), out)
        XCTAssertTrue(out.contains("<div>Body</div>"))
    }

    func testReplacesRemoteCSSURLsButKeepsDataURLs() {
        let out = prepared("""
        <style>.h{background:url('https://t.co/p.gif') no-repeat} .d{background:url(data:image/png;base64,AAA)}</style>
        <td style="background-image: url(&quot;https://t.co/q.png&quot;)">x</td>
        """)
        XCTAssertFalse(out.contains("t.co"), out)
        XCTAssertTrue(out.contains("background:none no-repeat"))
        XCTAssertTrue(out.contains("url(data:image/png;base64,AAA)"))
    }

    func testStripsBackgroundAttributesAndMedia() {
        let out = prepared("""
        <table background="https://t.co/bg.jpg" width=600><tr><td>cell</td></tr></table>
        <video poster="https://t.co/p.jpg"><source src="https://t.co/v.mp4"></video>
        <svg><image href="https://t.co/s.png"/></svg>
        <frameset><frame src="https://t.co/f"></frameset>
        <input type="image" src="https://t.co/i.png">
        """)
        XCTAssertFalse(out.contains("t.co"), out)
        XCTAssertTrue(out.contains("<table width=600>"))
    }

    func testKeepsImageAltText() {
        let out = prepared(#"<p><img src="https://t.co/logo.png" alt="Company logo"></p>"#)
        XCTAssertFalse(out.contains("t.co"), out)
        XCTAssertTrue(out.contains("Company logo"))
    }

    // MARK: Links and body text survive

    func testKeepsLinks() {
        let out = prepared(#"<p>See <a href="https://example.com/agenda?id=1">the agenda</a> or https://example.com</p>"#)
        XCTAssertTrue(out.contains(#"<a href="https://example.com/agenda?id=1">the agenda</a>"#), out)
        XCTAssertTrue(out.contains("or https://example.com"))
    }

    func testKeepsBodyTextThatLooksLikeAttributes() {
        let out = prepared("<p>Hi, the background = blue here, see url(notes)</p>")
        XCTAssertTrue(out.contains("the background = blue here"), out)
    }

    func testRenderedLinksAreClickable() {
        let rendered = HTMLRenderer.render(#"<p>Open <a href="https://example.com/x">this</a></p>"#, style: .standard)
        let range = (rendered.string as NSString).range(of: "this")
        XCTAssertNotEqual(range.location, NSNotFound)
        let link = rendered.attribute(.link, at: range.location, effectiveRange: nil)
        XCTAssertEqual((link as? URL)?.absoluteString ?? (link as? String), "https://example.com/x")
    }

    // MARK: Remote images go to the web view

    func testRemoteContentLoadsByDefault() {
        XCTAssertTrue(RichContentStyle().allowsRemoteContent)
        XCTAssertTrue(RichContentStyle.email.allowsRemoteContent)
    }

    func testImagesPreferWebView() {
        XCTAssertTrue(HTMLRenderer.prefersWebView(#"<p><img src="https://t.co/photo.jpg"></p>"#))
    }

    func testTrackingPixelStaysNative() {
        XCTAssertFalse(HTMLRenderer.prefersWebView(#"<p>Hi</p><img src="https://t.co/p.gif" width="1" height="1">"#))
    }

    func testCSSBackgroundImagesPreferWebView() {
        XCTAssertTrue(HTMLRenderer.prefersWebView(#"<div style="background:url(https://t.co/hero.jpg)">Hi</div>"#))
        XCTAssertTrue(HTMLRenderer.prefersWebView(#"<body background="https://t.co/bg.jpg"><div>Hi</div></body>"#))
    }

    func testSimpleHTMLStaysNative() {
        XCTAssertFalse(HTMLRenderer.prefersWebView(#"<div>Hi <a href="https://example.com">link</a></div>"#))
    }
}
