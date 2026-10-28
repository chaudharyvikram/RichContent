# RichContent recipes

Adapt names and storage to the app. All snippets assume `import RichContent`.

## Viewer — SwiftUI

```swift
struct MessageDetailView: View {
    let message: Message                       // body: String, as received from the server
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            RichContentView(.auto(message.body))
                .richContentStyle(style)
        }
        .environment(\.openURL, OpenURLAction { url in
            // Route in-app links, otherwise let the system open them.
            if url.host == "app.example.com" { router.open(url); return .handled }
            return .systemAction
        })
    }

    private var style: RichContentStyle {
        var style = RichContentStyle.email
        style.allowsRemoteContent = message.isFromTrustedSender   // false blocks tracking pixels
        style.linkColor = UIColor(named: "Accent") ?? .tintColor
        return style
    }
}
```

Several parts in one screen (header + body + AI summary + signature):

```swift
RichContentView(.mixed([.attributed(header), .auto(body), .markdown(summary), .plain(signature)]))
```

## Viewer — UIKit

Native-only content (no designed HTML), e.g. a table-view cell:

```swift
let bodyView = RichContentTextView(style: .email)
bodyView.translatesAutoresizingMaskIntoConstraints = false
bodyView.onOpenURL = { [weak self] url in self?.open(url) }
contentView.addSubview(bodyView)   // pin edges; it sizes itself (no scrolling)
bodyView.setContent(.markdown(note.text))
```

Any content, including designed emails (web view parts), via SwiftUI hosting:

```swift
final class MessageViewController: UIViewController {
    var body = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ScrollView { RichContentView(.auto(body)) }.richContentStyle(.email)
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}
```

## Editor — SwiftUI (notes)

```swift
struct NoteEditorView: View {
    @StateObject private var editor: RichEditorController
    let save: (String) -> Void

    init(html: String, save: @escaping (String) -> Void) {
        _editor = StateObject(wrappedValue: RichEditorController(content: .html(html)))
        self.save = save
    }

    var body: some View {
        RichContentEditor(controller: editor, placeholder: "Start writing…")
            .richEditorToolbar(editor)
            .onAppear { editor.onChange = { save($0.html) } }   // html is lossless
    }
}
```

## Editor — UIKit

```swift
final class NoteViewController: UIViewController {
    private let editor = RichEditorController(style: .standard)
    private let textView = RichEditorTextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.placeholder = "Start writing…"
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        editor.attach(to: textView)          // owns textView.delegate
        editor.load(.html(savedHTML))
        editor.onChange = { [weak self] editor in self?.store(editor.html) }

        // Optional: the SwiftUI format bar above the keyboard.
        let bar = UIHostingController(rootView: RichEditorToolbar(controller: editor, tools: .basic))
        bar.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 62)
        bar.view.backgroundColor = .clear
        textView.inputAccessoryView = bar.view
    }
}
```

## Reply with the original quoted inside the editor

```swift
@StateObject private var editor: RichEditorController = {
    let editor = RichEditorController(style: .email, configuration: .email)
    return editor
}()

.onAppear {
    editor.quotedOriginal = QuotedOriginal(.auto(original.body),
                                           attribution: "On \(original.dateText), \(original.sender) wrote:")
}

Button("Send") { mail.send(html: editor.replyHTML()) }
    .disabled(editor.isEmpty || !editor.allImagesUploaded)
```

The original renders exactly (web view for designed emails), is read-only,
and scrolls with the reply. `replyHTML()` = reply + attribution +
`<blockquote type="cite">original</blockquote>`.

## Image uploads

```swift
editor.imageUploader = { image in
    let data = image.jpegData(compressionQuality: 0.85)!
    return try await api.uploadAttachment(data, contentType: "image/jpeg")   // returns the public URL
}
editor.onImageUploadFailure = { error in logger.error("Image upload failed: \(error)") }
// editor.configuration.showsImageUploadFailureAlert = false   // to show your own UI

Button("Send") { send() }
    .disabled(editor.isEmpty || !editor.allImagesUploaded)
```

Behaviour: the picked image appears at once ("Uploading…"); on success its
`src` becomes the returned URL; on failure it is badged "Upload failed" and
an alert offers Retry / Remove Image. `pendingImageUploads`,
`failedImageUploads`, `retryFailedImageUploads()`, `removeFailedImages()`
are available for custom UI.

## Configuration

```swift
var config = RichEditorConfiguration.email
config.toolbarTools = [.bold, .italic, .underline, .link, .color,
                       .bulletList, .numberedList, .image, .undo, .redo, .hideKeyboard]
config.allowedBlocks.remove(.image)        // also hides the image tool, "/image", paste of images
config.showsBlockHandles = false
config.maxImagePixelSize = 1600
let editor = RichEditorController(style: .email, configuration: config)
```

## Custom toolbar (instead of RichEditorToolbar)

Bind to the published state of `editor.focusedEditor` (a table cell's
editor while a cell is edited, otherwise `editor` itself) and send formatting
there; table structure goes to `editor`:

```swift
struct MyBar: View {
    @ObservedObject var editor: RichEditorController          // the document
    var body: some View { MyBarButtons(target: editor.focusedEditor, document: editor) }
}

struct MyBarButtons: View {
    @ObservedObject var target: RichEditorController          // where the caret is
    let document: RichEditorController
    var body: some View {
        HStack {
            Button { target.toggle(.bold) } label: { Image(systemName: "bold") }
                .foregroundStyle(target.activeFormats.contains(.bold) ? Color.accentColor : .primary)
            Button { target.toggleBlock(.bulletList) } label: { Image(systemName: "list.bullet") }
            Button { target.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!target.canUndo)
            if document.isInTable {
                Menu("Table") {
                    Button("Row below") { document.insertTableRow(below: true) }
                    Button("Column right") { document.insertTableColumn(right: true) }
                    Button("Delete table", role: .destructive) { document.deleteTable() }
                }
            } else {
                Button { document.insertTable() } label: { Image(systemName: "tablecells") }
            }
        }
    }
}
```

## Export

```swift
editor.html        // store this (lossless round trip)
editor.markdown    // for Markdown backends (drops colors / toggle state)
editor.plainText   // previews, search
RichContentRenderer.attributedString(for: .html(editor.html))   // render elsewhere
```
