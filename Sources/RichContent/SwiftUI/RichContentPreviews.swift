import SwiftUI

#if DEBUG
enum RichContentSamples {

    static let plainReply = """
    Test attachments.

    On February 24, 2026 at 1:51 PM, Gunavant Patel (gp@rings.ai) wrote:
    > test email body
    >
    > On February 24, 2026 at 1:29 PM, Gunavant Patel (gp@rings.ai) wrote:
    >> Test Reply All
    >>
    >> On February 24, 2026 at 12:35 PM, Gunavant Patel (gp@rings.ai) wrote:
    >>> Test from iOS
    """

    static let htmlReply = """
    <div>Test attachments.</div><br>
    <div>On February 24, 2026 at 1:51 PM, Gunavant Patel &lt;gp@rings.ai&gt; wrote:</div>
    <blockquote type="cite">
      <div>test email body</div><br>
      <div>On February 24, 2026 at 1:29 PM, Gunavant Patel &lt;gp@rings.ai&gt; wrote:</div>
      <blockquote type="cite"><div><b>Test</b> Reply <a href="https://rings.ai">All</a></div></blockquote>
    </blockquote>
    """

    static let newsletterHTML = """
    <table width="100%"><tr><td style="padding:12px;background:#F2F4F9;border-radius:12px">
      <h2 style="margin:0 0 6px 0">Weekly sync</h2>
      <p>Agenda attached. <a href="https://example.com">Open in browser</a></p>
    </td></tr></table>
    """

    static let markdownNotes = """
    ## Meeting notes
    **Attendees:** Gunavant, Vikram

    1. Ship the *email detail* redesign
    2. Review `RichContentView`
       - native text first
       - web view fallback

    > Decision: keep quoted replies compact.

    ```swift
    RichContentView(.auto(body))
    ```
    """

    static var attributedSignature: AttributedString {
        var s = AttributedString("— Sent from Rings")
        s.foregroundColor = .secondaryLabel
        s.font = .preferredFont(forTextStyle: .footnote)
        return s
    }
}

#Preview("Email – plain quotes") {
    ScrollView { RichContentView(.plain(RichContentSamples.plainReply)).padding(16) }
        .richContentStyle(.email)
}

#Preview("Email – HTML quotes") {
    ScrollView { RichContentView(.html(RichContentSamples.htmlReply)).padding(16) }
        .richContentStyle(.email)
}

#Preview("Markdown") {
    ScrollView { RichContentView(.markdown(RichContentSamples.markdownNotes)).padding(16) }
}

#Preview("Mixed") {
    ScrollView {
        RichContentView(.mixed([
            .markdown(RichContentSamples.markdownNotes),
            .html(RichContentSamples.newsletterHTML),     // tables → web view
            .auto(RichContentSamples.htmlReply),           // sniffed as HTML
            .attributed(RichContentSamples.attributedSignature)
        ]))
        .padding(16)
    }
    .richContentStyle(.email)
}
#endif
