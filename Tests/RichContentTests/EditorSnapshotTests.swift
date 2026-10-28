import XCTest
import SwiftUI
@testable import RichContent

/// Renders the editor to PNGs for eyeballing (not compared). Set
/// RICH_SNAPSHOT_DIR to choose where they go.
@MainActor
final class EditorSnapshotTests: XCTestCase {

    private func render(_ view: UIView, name: String, dark: Bool = false) throws {
        let window = UIWindow(frame: view.frame)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            UIColor.systemBackground.resolvedColor(with: view.traitCollection).setFill()
            context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
        let directory = ProcessInfo.processInfo.environment["RICH_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("\(name).png")
        try image.pngData()?.write(to: url)
        print("SNAPSHOT \(url.path)")
        window.isHidden = true
    }

    func testRenderNotes() throws {
        for dark in [false, true] {
            let editor = RichEditorController(content: .html(RichEditorSamples.notesHTML))
            let textView = RichEditorTextView()
            textView.frame = CGRect(x: 0, y: 0, width: 393, height: 1100)
            textView.isScrollEnabled = false
            editor.attach(textView, style: .standard)
            textView.layoutIfNeeded()
            try render(textView, name: dark ? "editor-notes-dark" : "editor-notes", dark: dark)
        }
    }
}
