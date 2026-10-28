# RichContent

One iOS component for email / meeting bodies: **HTML, Markdown, plain text,
`AttributedString`, `NSAttributedString`, or any mix**. iOS 16+, SwiftUI and UIKit.

**Demo app:** `Demo/RichContentDemo.xcodeproj`: a notes app, an email
composer and a viewer gallery built on this package (see `Demo/README.md`).

## Installation

Swift Package Manager, iOS 16+, no dependencies.

**Xcode:** File → Add Package Dependencies…, enter
`https://github.com/chaudharyvikram/RichContent.git`, pick **Up to Next Major
Version** from `1.0.0`, and add the **RichContent** library to your app target.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/chaudharyvikram/RichContent.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "RichContent", package: "RichContent")
    ])
]
```

If the repository is private, add a GitHub account with access in Xcode →
Settings → Accounts (and give CI a token or SSH key) so the package can be fetched.

## Use

```swift
import RichContent

// SwiftUI
ScrollView {
    RichContentView(.auto(email.body))          // sniffs html / markdown / plain
        .richContentStyle(.email)
        .padding(.horizontal, 16)
}

RichContentView(.mixed([
    .attributed(header),
    .html(bodyHTML),
    .markdown(aiSummary),
    .plain(signature)
]))

// Intercept links
.environment(\.openURL, OpenURLAction { url in handle(url); return .handled })

// UIKit
let textView = RichContentTextView(style: .email)
textView.setContent(.html(bodyHTML))
textView.onOpenURL = { url in … }

// Just the attributed string (previews, search snippets, share)
let attributed = RichContentRenderer.attributedString(for: .markdown(notes))
```

## How each format renders

| Input | Renderer | Notes |
|---|---|---|
| `.plain` | `PlainTextRenderer` | `>` / `>>` email quoting → quote bars; blank lines kept short; links detected |
| `.markdown` | `MarkdownRenderer` | Real block layout from `presentationIntent`: headings, nested lists, quotes, code blocks, tables (tab-aligned), inline bold/italic/code/strike/links; `![alt](url)` images become `<img>` blocks rendered like HTML images |
| `.attributed` | as-is, or Markdown layout | If it came from `AttributedString(markdown:)` its blocks are laid out; UIKit fonts/colors kept, missing ones filled from the style |
| `.nsAttributed` | as-is | Missing font / color / paragraph style filled from the style |
| `.html` (simple) | `HTMLRenderer` → native text | `<blockquote>` → same quote bars; fonts mapped to the app font, near-black → `label` (dark mode), compact spacing, no network |
| `.html` (tables, images, media) | `RichWebContentView` | Sandboxed `WKWebView`: JS off, remote content loads unless `allowsRemoteContent` is off (then blocked by CSP), auto-height, links routed to `openURL`, light/dark CSS from the style |
| `.mixed` | all of the above | Consecutive native parts merge into **one** selectable text view; web parts sit between them |

`htmlRendering` = `.automatic` (default), `.native` or `.web` overrides the routing.

### One string, several formats

`.auto(string)` splits a single string into sections before rendering:
HTML blocks (lines starting with a block tag, kept together while tags are
unbalanced), and text sections separated by 2+ blank lines, each classified
as Markdown or plain. Inline `<b>`, `<i>`, `<a href>`, `<br>`, `<code>` inside
Markdown are converted to Markdown. When you already know the parts, prefer
`.mixed([...])`, which skips detection.

Wide email HTML (600px newsletters) is scaled down to fit the view width.

## Style

```swift
var style = RichContentStyle.email
style.linkColor = UIColor(named: "Accent")!
style.quoteBarColor = .systemPurple.withAlphaComponent(0.35)
style.allowsRemoteContent = user.loadsRemoteImages   // on by default; off blocks tracking pixels
RichContentView(content).richContentStyle(style)
```

Fonts default to Dynamic Type; colors are dynamic system colors.

### Custom base font

```swift
var style = RichContentStyle.email
style.setFont(UIFont(name: "Inter-Regular", size: 16)!)          // scales with Dynamic Type
style.setCodeFont(UIFont(name: "JetBrainsMono-Regular", size: 14)!)
style.forcesBaseFontInWebContent = false   // true = newsletters use your font too
```

The font drives plain text, Markdown (headings are the same family, larger
and bold), native HTML (sender fonts are mapped onto it, keeping bold/italic
and relative size) and the web view. WKWebView can't see app-registered
fonts, so the font files (regular, bold, italic, bold-italic, when the family
has them) are embedded as `@font-face` data URLs. Register the font in
Info.plist (`UIAppFonts`) as usual; `.ttc` collections fall back to the
family name.

### Padding

```swift
style.horizontalPadding = 16   // .email default
style.verticalPadding = 8
style.webPadding = .automatic  // .always / .never
```

The editor uses the same padding on both sides, widened to fit the block
handle (⋮⋮) when it is shown. To set it exactly:

```swift
style.editorHorizontalPadding = 24   // editor only; nil = automatic
```

With less than ~30pt the handle overlaps the screen edge; turn it off with
`RichEditorConfiguration.showsBlockHandles = false` for tight layouts.

Native text always gets the horizontal padding. `.automatic` web padding
pads simple HTML but lets designed emails (layout tables, body backgrounds)
run edge to edge with their own margins, like Mail.

Tweak the inherited style inline:

```swift
RichContentView(content)
    .richContentStyle { $0.horizontalPadding = 20 }
    .richContentStyle(.email)      // outer: base style
```

## Performance

- Plain / Markdown / attributed render synchronously (cheap) and are cached.
- Native HTML import (UIKit's importer is main-thread only) runs after the
  first frame with a skeleton placeholder, then is cached (64 entries).

## Editor

A Notion-style block editor that shares the viewer's style. Native
`UITextView` (TextKit 1): system keyboard, dictation, autocorrect, selection
across blocks, undo for every command. No web view.

```swift
@StateObject private var editor = RichEditorController()           // or (content: .html(saved))

RichContentEditor(controller: editor, placeholder: "Untitled")
    .richEditorToolbar(editor)              // format bar above the keyboard
    .richContentStyle(.standard)

editor.html          // lossless, email-safe HTML: load it back to keep editing
editor.markdown      // GitHub Markdown
editor.plainText     // "• ", "1. ", "☐ ", "> " prefixes
editor.load(.markdown(notes))               // any RichContent: HTML, Markdown, plain, attributed
editor.onChange = { autosave($0.html) }
editor.imageUploader = { image in try await upload(image) }   // else images are embedded as data: URLs
```

UIKit: `let tv = RichEditorTextView(); editor.attach(to: tv)`.

### Blocks

Text, Heading 1–3, Bulleted list, Numbered list (1. → a. → i. by level),
To-do (tap the checkbox), Toggle (tap the arrow; hidden content is kept and
exported), Quote, Callout (tap the icon to change it; color), Code (language),
Divider, Image (photo library, paste, or link; remote images load
asynchronously). Any block can be nested under another (Tab / Shift-Tab, or
the indent buttons); children move with their parent.

Inline: bold, italic, underline, strikethrough, inline code, link, and
Notion's 10 text colors and 10 highlight colors (dark-mode aware).

### Ways to edit

| | |
|---|---|
| `/` menu | Type `/` at the start of a word: blocks, media, colors, duplicate / move / delete. Type to filter; arrows + Return on a hardware keyboard. The toolbar's `+` opens it too. |
| Markdown shortcuts | At the start of a block: `- ` `* ` `+ ` bullets, `1. ` numbers, `[] ` / `[x] ` to-dos, `# ` `## ` `### ` headings, `> ` toggle, `" ` quote, ```` ``` ```` code, `---` divider. Inline: `**bold**`, `*italic*`, `_italic_`, `~strike~`, `` `code` `` (on the closing marker). Undo restores what you typed. |
| Selection toolbar | Appears under selected text: Turn into, B I U S, code, link, color. |
| Block handle ⋮⋮ | Beside the current block. Tap: Turn into, Color, Check / Expand, Icon, Language, Indent / Outdent, Move up / down, Duplicate, Delete. Drag: move the block (with its children) anywhere; it takes the level where it lands. |
| Keyboard toolbar | `+`, Turn into, B I U S, code, link, color, to-do, bullets, numbers, toggle, outdent / indent, image, undo / redo, hide keyboard. |
| Hardware keyboard | ⌘B ⌘I ⌘U, ⇧⌘S strike, ⌘E code, ⌘K link, Tab / ⇧Tab, ⇧↩ line break, ⌘↩ check / expand, ⌘D duplicate, ⇧⌘↑ / ↓ move, ⌥⌘0–8 turn into. |
| VoiceOver | Rotor actions on the current block: check, expand, indent, outdent, move, duplicate, delete. |

Return continues lists and to-dos (unchecked), leaves an empty item (outdents
first), starts text after a heading or quote, adds a line inside code and
callouts (Return on an empty last line leaves them), and goes inside an open
toggle. Backspace at the start of a block turns it into text, then outdents,
then joins it with the block above; on an image or divider it removes it.

Copy / paste keeps everything inside the editor (HTML on the pasteboard) and
maps HTML from Safari, Mail, Notes, Google Docs and Notion onto the same
blocks. A URL pasted over selected text links it; pasted images become image
blocks; multi-line plain text becomes blocks ("- ", "1. ", "[ ] " understood).

### Options

```swift
var config = RichEditorConfiguration()          // or .email: no toggles / callouts
config.allowedBlocks.remove(.image)              // limits /, shortcuts, menus, paste
config.showsBlockHandles = false
config.showsSelectionToolbar = true
config.markdownShortcuts = true
config.slashCommands = true
config.loadsRemoteImages = true
config.commandHint = "Type '/' for commands"
config.assetColors = [.asset("Brand"), .asset("Accent")]   // your Assets.xcassets colors
let editor = RichEditorController(style: .email, configuration: config)
```

**App colors.** `assetColors` lists named colors from your asset catalog
(`RichColor.assetBundle`, default `.main`). They appear first and expanded in
every Color menu (block handle, selection toolbar, keyboard toolbar) and in
the `/` menu; the built-in palette sits in collapsed "Text colors" /
"Background colors" sections. Asset colors keep their light / dark variants;
as highlights they're used as a light tint. iOS can't list an asset catalog
at runtime, so name the colors you want offered. They export as
`data-color="asset:Brand"` with the light-mode hex as the inline style.

### Formats

HTML is the lossless format: to-dos are `<ul data-type="todo">` with
`data-checked`, toggles `<details>`, callouts `<div data-type="callout">`,
colors `<span data-color>` / `data-highlight` with inline styles, nesting
inside `<li>` or `<div data-type="indent">`. It renders sensibly in mail
clients and in `RichContentView`. Markdown keeps structure but not colors,
callout styling or toggle state (toggles become list items).
`replyHTML(quoting:attribution:)` builds an email reply around the original.

### Replying with the original below

Like Mail and Gmail, the editor can show the message being replied to under
the reply: rendered like `RichContentView` (designed emails in the web view),
behind a quote bar, scrolling with the text, and read-only (the caret never
enters it). `replyHTML()` sends the reply with it quoted.

```swift
editor.quotedOriginal = QuotedOriginal(.auto(email.body),
                                       attribution: "On Oct 28, 2026 at 9:41 AM, Alex Kim wrote:")
send(editor.replyHTML())   // reply + attribution + <blockquote type="cite">original</blockquote>
editor.quotedOriginal = nil   // remove it
```

The editor's HTML import is its own parser (no WebKit), so loading is fast
and works off-screen and in previews.

### Format bar

`.richEditorToolbar(editor)` shows every tool by default. To show only some,
list them (in the order to show them) from the `RichEditorTool` presets;
separators are added between groups:

```swift
config.toolbarTools = [.bold, .italic, .underline, .link, .color,
                       .bulletList, .numberedList, .image, .undo, .redo, .hideKeyboard]
// or per bar:
.richEditorToolbar(editor, tools: RichEditorTool.basic)
```

Tools: `addBlock`, `turnInto`, `bold`, `italic`, `underline`, `strikethrough`,
`code`, `link`, `color`, `todo`, `bulletList`, `numberedList`, `toggle`,
`outdent`, `indent`, `image`, `undo`, `redo`, `hideKeyboard`. Tools the
configuration rules out (Image without `.image` in `allowedBlocks`, `addBlock`
without `slashCommands`) stay hidden.

### Image uploads

Picked and pasted images are scaled to `maxImagePixelSize` and shown at once.
Without an `imageUploader` they stay embedded as `data:` URLs. With one, the
image shows "Uploading…" until your closure returns its URL, which replaces
the embedded data in `html` / `replyHTML()`.

If an upload fails, the image is badged "Upload failed" and an alert offers
**Retry** and **Remove Image** (tapping the badge later asks again). Gate
sending on `allImagesUploaded`, which is `false` while any image in the
document is uploading or failed:

```swift
editor.imageUploader = { image in try await api.upload(image) }
editor.onImageUploadFailure = { error in log(error) }    // optional
// editor.configuration.showsImageUploadFailureAlert = false   // to show your own UI

Button("Send") { send(editor.replyHTML()) }
    .disabled(editor.isEmpty || !editor.allImagesUploaded)

editor.pendingImageUploads        // uploading now
editor.failedImageUploads         // waiting for Retry / Remove
editor.retryFailedImageUploads()
editor.removeFailedImages()
```

Deleting an uploading or failed image unblocks sending.

## Not covered yet

- Reference-style Markdown images (`![alt][ref]`) show their alt text only.
- Editor: tables, mentions / dates, synced blocks, columns, page links,
  toggle headings, image captions / resizing, and code syntax highlighting.
- `cid:` inline attachment images: map them to `data:` URLs before passing the HTML.
- Text selection across a native block and a web block.
