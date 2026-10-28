import Foundation
import RichContent

/// Content the demo starts with. The notes are stored as the editor's HTML,
/// exactly what an app would save.
enum DemoSamples {

    // MARK: Notes

    static let welcome = """
    <h1>Welcome 👋</h1>
    <div>This is a native, Notion-style editor. Everything below is editable: try it.</div>
    <div data-type="callout" data-emoji="💡" data-color="blue"><span data-type="callout-emoji">💡</span>&nbsp;Tap a line, then the <strong>⋮⋮</strong> handle on its left for block actions. Drag the handle to move the block.</div>
    <h2>Try these</h2>
    <ul data-type="todo">
    <li data-checked="true">Open this note</li>
    <li data-checked="false">Tap a checkbox to tick it</li>
    <li data-checked="false">Type <code>/</code> on an empty line and pick a block</li>
    <li data-checked="false">Start a line with <code>- </code>, <code>1. </code>, <code>[] </code>, <code>## </code> or <code>&gt; </code></li>
    <li data-checked="false">Wrap a word in <code>**stars**</code> or <code>`backticks`</code></li>
    <li data-checked="false">Select text to see the format bar: bold, color, links…</li>
    <li data-checked="false">Press Return on an empty list item to leave the list</li>
    <li data-checked="false">Undo anything with the ↶ button</li>
    </ul>
    <details><summary>Keyboard shortcuts (tap the arrow)</summary>
    <ul><li><strong>⌘B / ⌘I / ⌘U</strong> bold, italic, underline</li><li><strong>⌘E</strong> inline code, <strong>⌘K</strong> link</li>
    <li><strong>Tab / ⇧Tab</strong> nest / un-nest</li><li><strong>⌘Return</strong> tick a to-do or open a toggle</li>
    <li><strong>⌥⌘1–8</strong> turn into heading, to-do, list, toggle, code</li><li><strong>⇧⌘↑ / ↓</strong> move block</li></ul>
    </details>
    <h2>Every block</h2>
    <div>Plain text with <strong>bold</strong>, <em>italic</em>, <u>underline</u>, <s>strike</s>, <code>code</code>, <a href="https://www.notion.so">a link</a>, <span data-color="red" style="color:#D44C47">red</span>, <span data-color="purple" style="color:#9065B0">purple</span> and <span data-highlight="yellow" style="background-color:#FBF3DB">highlighted</span> text.</div>
    <h3>Lists nest</h3>
    <ul><li>Bulleted list<ul><li>Nested with Tab<ul><li>And again</li></ul></li></ul></li></ul>
    <ol><li>Numbered list<ol><li>Second level letters</li><li>Keeps counting</li></ol></li><li>Back to numbers</li></ol>
    <blockquote><div>A quote. “Simple things should be simple, complex things should be possible.”</div></blockquote>
    <div data-type="callout" data-emoji="⚠️" data-color="orange"><span data-type="callout-emoji">⚠️</span>&nbsp;Callouts: tap the icon to change it. Return adds a line; Return on an empty line leaves.</div>
    <pre data-language="swift"><code class="language-swift">let editor = RichEditorController()
    editor.load(.markdown(notes))
    save(editor.html)   // lossless</code></pre>
    <hr>
    <div data-type="image"><img src="https://picsum.photos/id/1018/1200/700" alt="Mountains" width="1200" height="700"></div>
    <div>Images come from Photos (toolbar 📷 or <code>/image</code>), paste, or a link.</div>
    """

    static let meeting = """
    <h1>Weekly sync</h1>
    <div><span data-color="gray" style="color:#787774">Oct 28 · Design, iOS, Web</span></div>
    <h2>Agenda</h2>
    <ol><li>Editor launch status</li><li>Feedback from beta</li><li>Next sprint</li></ol>
    <h2>Notes</h2>
    <ul><li>Beta testers love the <strong>slash menu</strong><ul><li>Asked for tables next</li></ul></li><li>Paste from Google Docs keeps formatting</li></ul>
    <details><summary>Raw feedback</summary><blockquote><div>“Feels like Notion, but it's native and fast.”</div></blockquote><blockquote><div>“Dark mode looks great.”</div></blockquote></details>
    <h2>Action items</h2>
    <ul data-type="todo"><li data-checked="true">Ship TestFlight build</li><li data-checked="false">Write release notes</li><li data-checked="false">Plan tables <span data-highlight="yellow" style="background-color:#FBF3DB">(research)</span></li></ul>
    """

    static let markdownNote = """
    # Imported from Markdown

    This note was loaded with `editor.load(.markdown(…))`.

    - [x] Headings, lists and **inline** *formats*
    - [ ] Tasks become to-dos
      - Nested items keep their level

    > Quotes stay quotes.

    ---

    ```json
    { "format": "markdown", "roundTrips": true }
    ```
    """

    // MARK: Email

    static let originalEmail = """
    <div>Hi team,</div><div><br></div>
    <div>Here's the plan for the launch:</div>
    <ul><li>Finish the <b>editor</b></li><li>Record the demo</li></ul>
    <div>Let me know what you think.</div><div><br></div>
    <div>On Oct 27, 2026 at 4:12 PM, Alex Kim &lt;alex@example.com&gt; wrote:</div>
    <blockquote type="cite"><div>Can we demo the editor on Thursday?</div></blockquote>
    """

    // MARK: Viewer

    struct ViewerSample: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let content: RichContent

        static func == (a: ViewerSample, b: ViewerSample) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// The built-in samples, plus your local `htmlcontent.html` when present.
    static var viewerSamples: [ViewerSample] {
        builtInViewerSamples + (htmlContent.map {
            [ViewerSample(id: "htmlcontent", title: "HTML", subtitle: "Your htmlcontent.html, as one plain string", content: .auto($0))]
        } ?? [])
    }

    private static let builtInViewerSamples: [ViewerSample] = [
        ViewerSample(id: "plain", title: "Plain-text reply", subtitle: "\"> \" quoting becomes quote bars", content: .plain("""
        Sounds good, see you Thursday.

        On Oct 27, 2026 at 4:12 PM, Alex Kim wrote:
        > Can we demo the editor on Thursday?
        >
        > On Oct 26, 2026 at 9:03 AM, Sam Lee wrote:
        >> Editor is feature complete.
        """)),
        ViewerSample(id: "html", title: "HTML email", subtitle: "Native text, dark-mode colors", content: .html(originalEmail)),
        ViewerSample(id: "newsletter", title: "Newsletter", subtitle: "Layout tables go to a sandboxed web view", content: .html("""
        <table width="100%" style="background:#F2F4F9"><tr><td style="padding:16px">
        <h2 style="margin:0 0 8px 0;color:#1a1a2e">This week in RichContent</h2>
        <p style="color:#333333">A native block editor, a faster HTML importer and better dark mode.</p>
        <table><tr><td style="background:#337EA9;border-radius:6px;padding:10px 16px"><a href="https://example.com" style="color:white">Read more</a></td></tr></table>
        </td></tr></table>
        """)),
        ViewerSample(id: "markdown", title: "Markdown notes", subtitle: "Headings, nested lists, code", content: .markdown(markdownNote)),
        ViewerSample(id: "editor", title: "Editor output", subtitle: "The welcome note's HTML, read-only", content: .html(welcome)),
        ViewerSample(id: "mixed", title: "Mixed formats", subtitle: "One string: HTML, then Markdown, then plain", content: .auto("""
        <div><b>From the API</b> as HTML.</div>


        ## Then Markdown
        - with a list


        And a plain-text signature.
        """))
    ]
}
