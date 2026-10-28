import SwiftUI

@main
struct RichContentDemoApp: App {
    @StateObject private var store = NotesStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                NotesView()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                ComposeView()
                    .tabItem { Label("Compose", systemImage: "square.and.pencil") }
                ViewerView()
                    .tabItem { Label("Viewer", systemImage: "doc.richtext") }
            }
            .environmentObject(store)
        }
    }
}
