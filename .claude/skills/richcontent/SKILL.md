---
name: richcontent
description: Implement the RichContent Swift package in an iOS app (SwiftUI or UIKit) — showing email / meeting / note bodies (HTML, Markdown, plain text, attributed strings or a mix) with RichContentView / RichContentTextView, and editing them with RichContentEditor / RichEditorTextView (format bar, colors, images and uploads, reply with quoted original, HTML / Markdown export). Use when adding, configuring or debugging RichContent views or the editor, or when the user mentions RichContent, RichContentView, RichEditorController or rendering / editing rich email bodies.
---

# RichContent

One Swift package (iOS 16+, no dependencies) for **reading** and **editing**
rich bodies. `import RichContent`.

- Read the API reference only as needed: [references/api.md](references/api.md)
- Ready-to-adapt code: [references/recipes.md](references/recipes.md)

## Pick the component

| Need | SwiftUI | UIKit |
|---|---|---|
| Show content, read-only | `RichContentView(.auto(body))` | `RichContentTextView` (native text only) or host `RichContentView` in `UIHostingController` (any content, incl. designed emails) |
| Edit content | `RichContentEditor(controller:)` + `.richEditorToolbar(controller)` | `RichEditorTextView` + `controller.attach(to:)` |
| Just an attributed string | `RichContentRenderer.attributedString(for:style:)` | same |

`RichEditorController` is the editor's model in both worlds: create it once
(`@StateObject` in SwiftUI, a stored property in UIKit), load content into it,
read `html` / `markdown` / `plainText` / `replyHTML()` out of it.

## Rules that prevent most bugs

1. **Pass server content as-is with `.auto(string)`.** It detects HTML,
   Markdown, plain text, mixes of them in one string, and JSON-escaped HTML
   (`\"`, `\r\n`, ` `). Don't pre-sniff, strip or unescape. Use `.html` /
   `.markdown` / `.plain` only when the format is known.
2. **`RichContentView` sizes to its width, not its height** — put it in a
   `ScrollView` (or a `List` row). Designed emails (layout tables, images)
   render in a sandboxed web view that reports its own height.
3. **Style through `.richContentStyle(...)`** (environment) in SwiftUI,
   `richStyle` / `init(style:)` in UIKit. Start from `.email` or `.standard`
   and change fields; don't hard-code fonts/colors in views.
4. **Remote content loads by default** (`allowsRemoteContent = true`). For
   untrusted mail, set it to `false` to block tracking pixels / remote CSS.
   Page JavaScript is always off.
5. **Links**: SwiftUI → `.environment(\.openURL, OpenURLAction { … })`;
   UIKit / editor → `onOpenURL`. Otherwise the system opens them.
6. **The editor is not a pixel-exact email viewer.** Loading a designed email
   into `RichEditorController` converts it to editable blocks (headings,
   lists, links, images, colors); layout CSS is dropped. Show originals with
   `RichContentView`; for replies use `quotedOriginal` (rendered exactly,
   read-only, inside the editor).
7. **Gate sending on images**: with an `imageUploader`, disable Send while
   `!editor.allImagesUploaded` (uploading or failed). Without one, images are
   embedded as `data:` URLs (large; many mail clients won't show them).
8. **Persist `editor.html`** (lossless: to-dos, toggles, callouts, colors,
   nesting). Markdown/plain text drop information.
9. Configure the editor with `RichEditorConfiguration` (`.email` for mail:
   no toggles/callouts). Changing `controller.configuration` at runtime is
   supported.

## Typical tasks

- **Email/message detail screen** → recipe "Viewer" (SwiftUI or UIKit).
- **Notes-style editor** → recipe "Editor"; save `editor.html` in `onChange`.
- **Reply / forward** → recipe "Reply": `quotedOriginal` + `replyHTML()`.
- **Fewer toolbar buttons** → `configuration.toolbarTools = [.bold, .italic, …]`
  or `.basic`; per bar: `.richEditorToolbar(editor, tools:)`.
- **Brand colors in color menus** → `configuration.assetColors = [.asset("Brand")]`.
- **Image upload to your backend** → recipe "Image uploads".

## Checklist before finishing

- Content passed through `.auto` unless the format is guaranteed.
- Viewer inside a scroll container; editor gets a bounded height or is the
  screen's scroll view.
- `allowsRemoteContent` decided for the content's trust level.
- Link handling wired (`openURL` / `onOpenURL`) if the app routes links.
- Editor: content saved from `html`; Send disabled on
  `editor.isEmpty || !editor.allImagesUploaded` when uploads are used.
- Builds for iOS 16+; `RichContent` added to the app target
  (`.product(name: "RichContent", package: "RichContent")`).
