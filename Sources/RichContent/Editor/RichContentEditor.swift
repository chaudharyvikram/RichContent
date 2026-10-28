import SwiftUI
import UIKit

/// Notion-style block editor that pairs with `RichContentView`: same fonts
/// and style (`.richContentStyle(...)`), exports HTML / Markdown / plain text.
///
/// ```swift
/// @StateObject private var editor = RichEditorController()
///
/// RichContentEditor(controller: editor, placeholder: "Write something…")
///     .richEditorToolbar(editor)          // format bar above the keyboard
///     .richContentStyle(.email)
/// ```
/// Pass `isScrollEnabled: false` to put the editor inside your own
/// `ScrollView`; it then grows with its content.
public struct RichContentEditor: View {
    @ObservedObject private var controller: RichEditorController
    private let placeholder: String
    private let isScrollEnabled: Bool
    @Environment(\.richContentStyle) private var style

    public init(controller: RichEditorController, placeholder: String = "", isScrollEnabled: Bool = true) {
        self.controller = controller
        self.placeholder = placeholder
        self.isScrollEnabled = isScrollEnabled
    }

    public var body: some View {
        RichEditorRepresentable(controller: controller, style: style,
                                placeholder: placeholder, isScrollEnabled: isScrollEnabled)
    }
}

private struct RichEditorRepresentable: UIViewRepresentable {
    let controller: RichEditorController
    let style: RichContentStyle
    let placeholder: String
    let isScrollEnabled: Bool

    func makeUIView(context: Context) -> RichEditorTextView {
        let textView = RichEditorTextView()
        textView.isScrollEnabled = isScrollEnabled
        textView.placeholder = placeholder
        controller.attach(textView, style: style)
        return textView
    }

    func updateUIView(_ textView: RichEditorTextView, context: Context) {
        controller.updateStyle(style)
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        if textView.isScrollEnabled != isScrollEnabled { textView.isScrollEnabled = isScrollEnabled }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichEditorTextView, context: Context) -> CGSize? {
        guard !isScrollEnabled, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(ceil(height), uiView.minimumHeight))
    }
}

// MARK: - Toolbar

public extension View {
    /// Shows the format bar above the keyboard while the editor is focused
    /// (or always, with `alwaysVisible`).
    func richEditorToolbar(_ controller: RichEditorController, alwaysVisible: Bool = false) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            RichEditorToolbarHost(controller: controller, alwaysVisible: alwaysVisible)
        }
    }
}

private struct RichEditorToolbarHost: View {
    @ObservedObject var controller: RichEditorController
    let alwaysVisible: Bool

    var body: some View {
        ZStack {
            if alwaysVisible || controller.isFocused {
                RichEditorToolbar(controller: controller)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controller.isFocused)
    }
}

/// Format bar (Liquid Glass on iOS 26). Usable on its own, e.g. in a custom
/// keyboard accessory.
public struct RichEditorToolbar: View {
    @ObservedObject private var controller: RichEditorController
    @Environment(\.richContentStyle) private var style

    public init(controller: RichEditorController) {
        self.controller = controller
    }

    private var allowed: Set<RichBlockType> { controller.configuration.allowedBlocks }

    public var body: some View {
        HStack(spacing: 0) {
            tools
            if controller.isFocused {
                // Pinned outside the scrolling tools, always one tap away.
                divider
                icon("keyboard.chevron.compact.down", "Hide keyboard") { controller.resignFocus() }
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 50)
        .richGlassCapsule()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if controller.configuration.slashCommands {
                    icon("plus", "Add block") { controller.showCommandMenu() }
                }
                turnIntoMenu
                divider
                ForEach([RichInlineFormat.bold, .italic, .underline, .strikethrough, .code], id: \.self) { format in
                    icon(format.symbolName, format.title, isActive: controller.activeFormats.contains(format)) {
                        controller.toggle(format)
                    }
                }
                icon("link", "Link", isActive: controller.activeFormats.contains(.link)) { controller.beginLinkEditing() }
                colorMenu
                divider
                ForEach([RichBlockType.todo, .bulletList, .numberedList, .toggle].filter { allowed.contains($0) }, id: \.self) { type in
                    icon(type.symbolName, type.title, isActive: controller.blockType == type) { controller.toggleBlock(type) }
                }
                icon("decrease.indent", "Outdent", enabled: controller.canOutdent) { controller.outdent() }
                icon("increase.indent", "Indent", enabled: controller.canIndent) { controller.indent() }
                if allowed.contains(.image) {
                    divider
                    icon("photo", "Image") { controller.textView?.presentImagePicker() }
                }
                divider
                icon("arrow.uturn.backward", "Undo", enabled: controller.canUndo) { controller.undo() }
                icon("arrow.uturn.forward", "Redo", enabled: controller.canRedo) { controller.redo() }
            }
            .padding(.horizontal, 6)
        }
        .clipShape(Capsule())
    }

    // MARK: Pieces

    private var accent: Color { Color(uiColor: style.linkColor) }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    private var turnIntoMenu: some View {
        Menu {
            ForEach(RichBlockType.textBlocks.filter { allowed.contains($0) }, id: \.self) { type in
                Button {
                    controller.setBlock(type)
                } label: {
                    if controller.blockType == type {
                        Label(type.title, systemImage: "checkmark")
                    } else {
                        Label(type.title, systemImage: type.symbolName)
                    }
                }
            }
            if allowed.contains(.divider) {
                Divider()
                Button { controller.insertDivider() } label: { Label("Divider", systemImage: RichBlockType.divider.symbolName) }
            }
        } label: {
            ToolbarIcon(systemName: "textformat", isActive: controller.blockType != .paragraph, accent: accent)
        }
        .accessibilityLabel("Turn into, \(controller.blockType.title)")
    }

    /// Text colors and Background colors, both expanded: color picker, the
    /// app's asset colors, then the built-in palette.
    private var colorMenu: some View {
        let colors = controller.configuration.assetColors + RichColor.allCases
        return Menu {
            Section("Text colors") {
                Button { controller.presentColorPicker(background: false) } label: {
                    Label("Choose from color picker…", systemImage: "eyedropper")
                }
                textButtons(colors)
            }
            Section("Background colors") {
                Button { controller.presentColorPicker(background: true) } label: {
                    Label("Choose from color picker…", systemImage: "eyedropper")
                }
                ForEach(colors, id: \.self) { color in
                    Button { controller.setHighlight(color) } label: {
                        Label { Text(color == .default ? "Default background" : "\(color.title) background") }
                            icon: { Image(uiImage: EditorMenus.swatch(color, background: true)) }
                    }
                }
            }
        } label: {
            ToolbarIcon(systemName: "paintpalette", isActive: controller.textColor != .default || controller.highlight != .default,
                        accent: accent)
        }
        .accessibilityLabel("Color")
    }

    private func textButtons(_ colors: [RichColor]) -> some View {
        ForEach(colors, id: \.self) { color in
            Button { controller.setTextColor(color) } label: {
                Label { Text(color.title) } icon: { Image(uiImage: EditorMenus.swatch(color, background: false)) }
            }
        }
    }

    private func icon(_ symbol: String, _ label: String, isActive: Bool = false, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarIcon(systemName: symbol, isActive: isActive, accent: accent)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct ToolbarIcon: View {
    let systemName: String
    let isActive: Bool
    let accent: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 42, height: 40)
            .foregroundStyle(isActive ? accent : Color.primary)
            .background(isActive ? accent.opacity(0.15) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func richGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}
