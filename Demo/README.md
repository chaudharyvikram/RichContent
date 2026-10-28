# RichContent Demo

An iPhone / iPad app that shows the package working end to end. It uses the
package from `..` (local Swift package), so edits to the library show up on
the next run.

## Run

Open `RichContentDemo.xcodeproj` in Xcode and run the **RichContentDemo**
scheme on any iOS 17+ simulator or device.

From the terminal:

```bash
xcodebuild -project Demo/RichContentDemo.xcodeproj -scheme RichContentDemo -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
```

## What's in it

| Tab | Shows |
|---|---|
| **Notes** | A small notes app. Notes are saved as the editor's HTML (in Documents/notes.json) as you type, and reopen exactly as you left them. The **Welcome** note is a guided tour; **Notion Block** is a real marketing email (layout tables, hidden preheader, remote images) imported from HTML; **Weekly sync** is a realistic meeting note; the last was imported from Markdown. ⚙︎ toggles editor options and allowed blocks live; Export shows the HTML / Markdown / plain text and a rendered preview. "…" → Restore Sample Notes resets everything. |
| **Compose** | An email reply using `RichEditorConfiguration.email` (no toggles / callouts). Send shows the reply built with `replyHTML(quoting:attribution:)`, rendered and as HTML source. |
| **Viewer** | `RichContentView` on plain-text quoting, an HTML email, a table newsletter (web view), Markdown, the editor's own output, one string mixing HTML, Markdown and plain text, and the Notion Block email (`NotionNewsletter.html`, loaded as a plain string). |

## Things to try in the editor

- Type `/` on an empty line, then a few letters (`/todo`, `/call`, `/red`) and Return.
- Start a line with `- `, `1. `, `[] `, `## `, `> ` (toggle) or `" ` (quote); type `---` or ```` ``` ````.
- Wrap text in `**…**`, `*…*`, `~…~` or `` `…` ``.
- Tap a checkbox, a toggle arrow, or a callout's icon.
- Select text for the floating format bar (Turn into, B / I / U / S, code, link, color).
- Tap the ⋮⋮ handle beside the current block for its menu; drag it to move the block.
- Paste from Safari, Notes or Google Docs; paste a URL over selected text.
- Use the 📷 button or `/image` for photos, `/image from link` for a URL.
