# Editor behaviour, document model and limits

Read this when the task touches how the editor behaves for users, the
document model (`attributedText`), or something the package may not support.

## What users can do (no app code needed)

Blocks: Text, Heading 1–3, Bulleted list, Numbered list (1. → a. → i. by
level), To-do, Toggle (hidden children are kept and exported), Quote,
Callout (emoji icon, background color), Code (language), Divider, Image,
Table. Any block nests under another (Tab / Shift-Tab, indent buttons); children
move with their parent. Inline: bold, italic, underline, strikethrough, code,
link, 10 text colors + 10 highlights (dark-mode aware), and custom colors
from the system picker.

| Way | Behaviour | Controlled by |
|---|---|---|
| `/` menu | Blocks, media, colors, duplicate / move / delete; type to filter; arrows + Return on hardware keyboards. Format-bar `+` opens it. | `slashCommands`, `allowedBlocks` |
| Markdown shortcuts | At block start: `- ` `* ` `+ ` bullets, `1. ` numbers, `[] ` / `[x] ` to-dos, `#`–`###` headings, `> ` toggle, `" ` quote, ```` ``` ```` code, `---` divider. Inline on the closing marker: `**bold**`, `*italic*` / `_italic_`, `~strike~`, `` `code` ``. Undo restores the typed text. | `markdownShortcuts`, `allowedBlocks` |
| Selection toolbar | Under selected text: Turn into, B I U S, code, link, color. | `showsSelectionToolbar` |
| Block handle ⋮⋮ | Tap: Turn into, Color, Check / Expand, Icon, Language, Indent / Outdent, Move, Duplicate, Delete. Drag: move the block with its children. | `showsBlockHandles` |
| Format bar | Buttons from `toolbarTools`. | `toolbarTools`, `.richEditorToolbar(_:tools:)` |
| Hardware keyboard | ⌘B ⌘I ⌘U, ⇧⌘S strike, ⌘E code, ⌘K link, Tab / ⇧Tab, ⇧↩ line break, ⌘↩ check / expand, ⌘D duplicate, ⇧⌘↑ / ↓ move, ⌥⌘0–8 turn into. | always on |
| VoiceOver | Rotor actions on the current block: check, expand, indent, outdent, move, duplicate, delete. | always on |

Return continues lists / to-dos (unchecked); on an empty item it outdents,
then leaves the list; after a heading or quote it starts text; inside code
and callouts it adds a line (Return on an empty last line leaves); in an open
toggle it goes inside. Backspace at block start: turn into text → outdent →
join with the block above; on an image / divider it removes it.

Tables: inserted from the format bar's Table tool, `/table` or Turn into
(3 × 3, header row). Each cell is a full nested `RichEditorController`, so
every tool works in cells (no nested tables, no ⋮⋮ handles in cells). While a
cell is edited the document's controller has `activeCellEditor` /
`focusedEditor` = the cell's editor and `isInTable == true`; `isFocused` stays
`true`; `onChange` fires on the document's controller for cell edits. The
Table tool becomes a menu in a table: rows above / below, columns left /
right, header row, delete row / column / table (same as
`insertTableRow(below:)`, `insertTableColumn(right:)`, `toggleTableHeaderRow()`,
`deleteTableRow()`, `deleteTableColumn()`, `deleteTable()`). Tab / ⇧Tab move
between cells; Tab in the last cell adds a row. Equal-width columns (≥ 96 pt);
wide tables scroll sideways. Import: data tables (`<th>`, borders,
`data-type="table"`) and Markdown pipe tables become table blocks; layout
tables are flattened. Export: `<table data-type="table">` with `<th>` header,
Markdown pipe table, tab-separated plain text.

Paste: HTML from Safari, Mail, Notes, Google Docs and Notion maps onto the
same blocks; a URL pasted over a selection links it; images become image
blocks; multi-line plain text becomes blocks (`- `, `1. `, `[ ] ` understood).
Copy inside the editor keeps everything (HTML on the pasteboard).

Taps: checkbox toggles a to-do, arrow expands a toggle, callout icon changes
the emoji, a failed-upload image offers Retry / Remove. The quoted original
(`quotedOriginal`) never takes the caret.

## Slash commands

`RichEditorCommand` (`id`, `title`, `subtitle`, `symbolName`, `section`,
`keywords`, `action`: `.block(_)`, `.imageFromURL`, `.textColor(_)`,
`.background(_)`, `.duplicate`, `.delete`, `.moveUp`, `.moveDown`) and
`editor.run(_:)` are public, but the command catalogue and initializer are
not: apps can't add custom commands or list them. Shape the menu with
`allowedBlocks` and `slashCommands`; open it with
`showCommandMenu()`.

## Document model (`editor.attributedText`)

Prefer `html` / `markdown` / `plainText` and the controller's methods. Work
on the attributed string only for custom rendering or analysis.

- One paragraph per block; every character carries its block's attributes.
- Block attributes (`NSAttributedString.Key`):
  `.richBlock` (`RichBlockType.rawValue`), `.richListLevel` (Int ≥ 1),
  `.richChecked` (Bool), `.richToggleChildren` (`RichToggleChildren`, present
  while a toggle is collapsed; opaque), `.richCalloutEmoji` (String),
  `.richBlockColor` (`RichColor.rawValue`, callout background),
  `.richCodeLanguage` (String).
- Inline attributes: `.richBold`, `.richItalic`, `.richUnderline`,
  `.richStrike`, `.richCode` (Bool), `.richTextColor`, `.richHighlight`
  (`RichColor.rawValue`), plus `.link`.
- Viewer quotes: `.richQuoteDepth` (Int) on rendered text.
- Images and dividers are one attachment character:
  `RichImageAttachment` (`source` URL / `data:` string, `alt`, `naturalSize`,
  `state` `.loading/.loaded/.failed`, `loadedImage`, `uploadState`
  `.uploading/.failed` or `nil`) and a divider attachment; both subclass
  `EditorBlockAttachment`.
- `setDocument(_:)` accepts such a string (missing attributes are filled in).

Type helpers: `RichBlockType.title`, `.symbolName`, `.isList`, `.isHeading`,
`.hasMarker`, `.isAttachment`, `RichBlockType.textBlocks` (turn-into targets);
`RichInlineFormat.title`, `.symbolName`.

## Persisting colors

`RichColor` is `RawRepresentable`: store `color.rawValue` (`"red"`,
`"hex:#7F3FBF"`) and restore with `RichColor(rawValue:)`.
`RichColor.allCases` is the built-in palette; `customColor` is non-nil for
picked colors. (App asset colors were removed; old `data-color="asset:…"`
HTML imports as the exported hex color.) In HTML, colors export as
`data-color` / `data-highlight` with a light-mode inline style.

## Performance

- Plain / Markdown / attributed content renders synchronously and is cached.
- Native HTML import (UIKit's importer, main thread only) runs after the first
  frame behind a skeleton placeholder, then is cached (64 entries).
- Editor HTML import uses its own parser (no WebKit): fast, works off-screen
  and in previews.
- Embedded `data:` images inflate `html` (≈1.3× the JPEG size each). Use an
  `imageUploader` or a lower `maxImagePixelSize` for synced / sent content,
  and avoid re-reading `html` on every keystroke in large documents
  (debounce saves in `onChange`).

## Not supported (don't promise these)

- Editor: merged table cells (colspan / rowspan) and column widths, mentions / dates, synced blocks, columns, page links,
  toggle headings, image captions / resizing, code syntax highlighting.
- Pixel-exact editing of designed emails (layout CSS is dropped on import).
- Reference-style Markdown images (`![alt][ref]`) show their alt text only.
- `cid:` inline attachment images: map them to `data:` URLs (or real URLs)
  before passing the HTML.
- Text selection across a native block and a web block in the viewer.
- Custom `/` commands or custom format-bar buttons (use your own toolbar with
  the controller's methods instead).
