# RichContent API reference

Public API only, grouped by task. Source of truth: `Sources/RichContent/`.

## Content

```swift
public indirect enum RichContent: Hashable, ExpressibleByStringLiteral {
    case plain(String)
    case markdown(String)
    case html(String)
    case attributed(AttributedString)
    case nsAttributed(NSAttributedString)
    case auto(String)              // detects; also splits mixed strings, unescapes JSON-escaped HTML
    case mixed([RichContent])      // parts in order; adjacent native parts merge into one text view
}
let c: RichContent = "**Hi**"     // string literal = .auto
```

Helpers: `RichContentDetector.detect(_:) -> RichContentFormat` (`.plain/.markdown/.html`),
`containsHTMLTags(_:)`, `looksLikeMarkdown(_:)`;
`JSONEscapedHTML.isEscaped(_:)`, `unescapeIfNeeded(_:)`.

## Viewing

### SwiftUI
```swift
RichContentView(_ content: RichContent)
    .richContentStyle(.email)                        // or a RichContentStyle value
    .richContentStyle { $0.horizontalPadding = 20 }  // adjust the inherited style
    .environment(\.openURL, OpenURLAction { url in …; return .handled })
```
Sizes to the proposed width; place in a `ScrollView`. Simple content renders
synchronously; HTML that needs import renders asynchronously (cached) with a
placeholder. Tables / images / media go to a sandboxed `WKWebView` block.

### UIKit
```swift
let textView = RichContentTextView(style: .email)   // UITextView: not editable, selectable, no scrolling (self-sizing)
textView.setContent(.html(body))                    // native rendering only (no web view)
textView.richStyle = style
textView.onOpenURL = { url in … }

let web = RichWebContentView(frame: .zero)          // sandboxed WKWebView, no scrolling
web.load(html: html, style: style)
web.onHeightChange = { height in heightConstraint.constant = height }
web.onOpenURL = { url in … }
```
For arbitrary / mixed / designed content in UIKit, host the SwiftUI view:
`UIHostingController(rootView: RichContentView(.auto(body)).richContentStyle(.email))`.

### Without a view
```swift
RichContentRenderer.attributedString(for: content, style: .standard) -> NSAttributedString
RichContentRenderer.render(content, style:) -> [RenderedBlock]          // .text(NSAttributedString) / .web(html: String)
await RichContentRenderer.renderAsync(content, style:) -> [RenderedBlock]
RichContentRenderer.immediateBlocks(for:style:) -> [RenderedBlock]?     // nil when an async import is needed
```

## RichContentStyle (value type, `Hashable`)

Presets: `.standard`, `.email` (16 pt body, padding 16×8, compact spacing).
Helpers: `style.padding(horizontal:vertical:)`, `style.font(_:relativeTo:)` (Dynamic Type scaled).

| Group | Fields |
|---|---|
| Text | `font`, `textColor`, `secondaryTextColor`, `linkColor`, `codeFont`, `codeBackgroundColor` |
| Spacing | `lineSpacing`, `paragraphSpacing`, `listIndent` |
| Quotes | `quoteBarColor`, `quoteBarWidth`, `quoteIndent`, `dimsQuotedText` |
| Padding | `horizontalPadding`, `verticalPadding`, `webPadding: WebPadding` (`.automatic/.always/.never`), `editorHorizontalPadding` |
| Behaviour | `htmlRendering: HTMLRendering` (`.automatic/.native/.web`), `allowsRemoteContent` (default `true`), `forcesBaseFontInWebContent`, `normalizesHTMLFonts`, `detectsLinks`, `preservesMarkdownLineBreaks` |

## Editing

### SwiftUI
```swift
@StateObject private var editor = RichEditorController(style: .email, content: .auto(saved),
                                                       configuration: .email)
RichContentEditor(controller: editor, placeholder: "Write…", isScrollEnabled: true)
    .richEditorToolbar(editor)                          // format bar above the keyboard
    .richEditorToolbar(editor, tools: .basic, alwaysVisible: false)
RichEditorToolbar(controller: editor, tools: nil)     // the bar on its own
```
`isScrollEnabled: false` makes the editor grow with its content (put it in your own `ScrollView`).

### UIKit
```swift
let editor = RichEditorController(style: .email, configuration: .email)
let textView = RichEditorTextView()        // UITextView subclass; scrolls by default
textView.placeholder = "Write…"
textView.minimumHeight = 120               // when isScrollEnabled = false
editor.attach(to: textView)                // sets the delegate: don't replace textView.delegate
```
The SwiftUI `RichEditorToolbar` can be hosted with `UIHostingController`
(e.g. as an input accessory); otherwise call the controller methods from your own buttons.

### RichEditorController
Init: `init(style: RichContentStyle = .standard, content: RichContent? = nil, configuration: RichEditorConfiguration = .standard)`

Content in / out
- `load(_ content: RichContent)`, `setDocument(_ NSAttributedString)`, `clear()`
- `html` (lossless, email-safe), `markdown`, `plainText`, `attributedText`
- `replyHTML()` (with `quotedOriginal`), `replyHTML(quoting:attribution:)`
- `onChange: ((RichEditorController) -> Void)?` after every edit

State (`@Published`, read-only) — drive custom toolbars
- `activeFormats: Set<RichInlineFormat>`, `blockType`, `listLevel`, `isChecked`,
  `textColor`, `highlight`, `isFocused`, `isEmpty`, `hasSelection`,
  `canUndo`, `canRedo`, `canIndent`, `canOutdent`,
  `pendingImageUploads`, `failedImageUploads`
- `selectedRange`, `selectedText`, `selectedLink`, `allImagesUploaded`

Formatting
- `toggle(_ RichInlineFormat)` — `.bold .italic .underline .strikethrough .code .link`
- `setTextColor(_ RichColor)`, `setHighlight(_ RichColor)`, `setBlockColor(_:background:)`
- `setLink(_ url: URL?, title:range:)`, `beginLinkEditing()` (prompt)
- `presentColorPicker(background:wholeBlock:)` (system picker)

Blocks — `RichBlockType`: `paragraph heading1 heading2 heading3 bulletList numberedList todo toggle quote callout codeBlock divider image`
- `setBlock(_:)`, `toggleBlock(_:)`, `indent()`, `outdent()`
- `toggleChecked()`, `toggleCollapsed()`, `setCalloutEmoji(_:)`, `setCodeLanguage(_:)`
- `insertDivider()`, `insertImage(_ UIImage, alt:)`, `insertImage(url:alt:)`
- `duplicateBlock()`, `deleteBlock()`, `moveBlockUp()`, `moveBlockDown()`
- `undo()`, `redo()`, `focus()`, `resignFocus()`, `showCommandMenu()`

Links: `onOpenURL: ((URL) -> Void)?` (edit menu "Open Link" and the quoted original).

Reply: `quotedOriginal: QuotedOriginal?` — `QuotedOriginal(_ content: RichContent, attribution: String = "")`.
Shown read-only below the text, scrolls with it, sent by `replyHTML()`.

Images
- `imageUploader: ((UIImage) async throws -> URL)?` — without it images are embedded `data:` URLs
- `onImageUploadFailure: ((Error) -> Void)?`
- `retryFailedImageUploads()`, `removeFailedImages()`
- Images are scaled to `configuration.maxImagePixelSize` (2048) before embedding/upload.

### RichEditorConfiguration
Presets `.standard`, `.email` (no toggles/callouts, no command hint).

| Field | Default | |
|---|---|---|
| `allowedBlocks: Set<RichBlockType>` | all | limits "/", shortcuts, menus, paste, toolbar |
| `showsBlockHandles` | `true` | ⋮⋮ handle: block menu, drag to move |
| `showsSelectionToolbar` | `true` | floating bar over selections |
| `slashCommands` | `true` | "/" command menu |
| `markdownShortcuts` | `true` | `- `, `1. `, `[] `, `# `, `> `, `**bold**` while typing |
| `loadsRemoteImages` | `true` | `http(s)` images in the document |
| `commandHint` | `"Type '/' for commands"` | empty-line hint |
| `assetColors: [RichColor]` | `[]` | e.g. `[.asset("Brand")]`, listed first in color menus |
| `maxImagePixelSize` | `2048` | long side of picked/pasted images |
| `showsImageUploadFailureAlert` | `true` | Retry / Remove Image alert |
| `toolbarTools: [RichEditorTool]` | `.all` | format-bar buttons, in order |

`RichEditorTool`: `addBlock turnInto bold italic underline strikethrough code link color todo bulletList numberedList toggle outdent indent image undo redo hideKeyboard`;
lists `.all`, `.basic`. Separators are automatic between groups; tools the configuration rules out stay hidden.

### RichColor
Palette `.default .gray .brown .orange .yellow .green .blue .purple .pink .red` (dark-mode aware),
`.asset("Name")` (from `RichColor.assetBundle`, default `.main`), `.custom(UIColor)` (stored as hex).
`title`, `textColor`, `backgroundColor`.

### Serializer (no editor instance needed)
`RichEditorSerializer.html(from:)`, `.markdown(from:)`, `.plainText(from:)`,
`.replyHTML(_:quoting:attribution:style:)` — input is the editor's `attributedText`.

## Not for app code

`RichEditorController` is the `UITextViewDelegate` of its `RichEditorTextView`
(`textViewDidChange` etc. are public only for that conformance), and
`RichWebContentView` is its own `WKNavigationDelegate`. Don't call these
methods or replace the delegates; use `onChange`, `onOpenURL` and the
published state instead. Attachment layout overrides (`attachmentBounds`) are
TextKit hooks. `RichImageAttachment.UploadState` (`.uploading/.failed`) is
read-only state for drawing; use the controller's upload API.
