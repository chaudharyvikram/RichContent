import SwiftUI
import RichContent

/// The read-only renderer on real-world content.
struct ViewerView: View {
    var body: some View {
        NavigationStack {
            List(DemoSamples.viewerSamples) { sample in
                NavigationLink(value: sample) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.title).font(.headline)
                        Text(sample.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Viewer")
            .navigationDestination(for: DemoSamples.ViewerSample.self) { sample in
                ScrollView {
                    RichContentView(sample.content)
                        .richContentStyle(style)
                }
                .navigationTitle(sample.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Remote images load by default; turn off to block them like Mail (no tracking pixels).
                    Toggle(isOn: $loadsRemoteImages) {
                        Label("Load remote images", systemImage: "photo")
                    }
                    .toggleStyle(.button)
                }
                .environment(\.openURL, OpenURLAction { url in
                    print("Link tapped: \(url)")
                    return .systemAction
                })
            }
        }
    }

    @State private var loadsRemoteImages = true

    private var style: RichContentStyle {
        var style = RichContentStyle.email
        style.allowsRemoteContent = loadsRemoteImages
        return style
    }
}
