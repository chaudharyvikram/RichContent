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
///
/// With `controller.quotedOriginal` set, the editor grows with its text and
/// the quoted original is stacked below it in one scroll view (Mail-style):
/// typing and focusing only scroll as far as the caret.
public struct RichContentEditor: View {
    @ObservedObject private var controller: RichEditorController
    private let placeholder: String
    private let isScrollEnabled: Bool
    @Environment(\.richContentStyle) private var style
    @Environment(\.openURL) private var openURL
    @State private var editorHeight: CGFloat = 0

    public init(controller: RichEditorController, placeholder: String = "", isScrollEnabled: Bool = true) {
        self.controller = controller
        self.placeholder = placeholder
        self.isScrollEnabled = isScrollEnabled
    }

    public var body: some View {
        if let quoted = controller.quotedOriginal {
            if isScrollEnabled {
                ScrollView { editorWithQuote(quoted) }
                    .scrollDismissesKeyboard(.interactively)
            } else {
                editorWithQuote(quoted)
            }
        } else {
            editor(scrolls: isScrollEnabled)
        }
    }

    private func editor(scrolls: Bool) -> some View {
        RichEditorRepresentable(controller: controller, style: style, placeholder: placeholder,
                                isScrollEnabled: scrolls, onContentHeightChange: { editorHeight = $0 })
            .frame(height: scrolls ? nil : max(editorHeight, 120))
    }

    private func editorWithQuote(_ quoted: QuotedOriginal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editor(scrolls: false)
                .zIndex(1)   // its "/" menu / selection toolbar draw over the quote
            EditorQuotedOriginalView(
                quoted: quoted, style: style,
                openURL: { url in
                    if let open = controller.onOpenURL { open(url) } else { openURL(url) }
                },
                onHeightChange: { _ in })
                .padding(.horizontal, RichEditorTextView.sideInset(
                    for: style, showsHandles: controller.configuration.showsBlockHandles))
                .padding(.bottom, 24)
        }
    }
}

private struct RichEditorRepresentable: UIViewRepresentable {
    let controller: RichEditorController
    let style: RichContentStyle
    let placeholder: String
    let isScrollEnabled: Bool
    let onContentHeightChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> RichEditorTextView {
        let textView = RichEditorTextView()
        textView.isScrollEnabled = isScrollEnabled
        textView.placeholder = placeholder
        // RichContentEditor shows the quoted original itself, below the editor.
        textView.showsQuotedOriginal = false
        textView.onContentHeightChange = onContentHeightChange
        controller.attach(textView, style: style)
        return textView
    }

    func updateUIView(_ textView: RichEditorTextView, context: Context) {
        controller.updateStyle(style)
        textView.onContentHeightChange = onContentHeightChange
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        if textView.isScrollEnabled != isScrollEnabled { textView.isScrollEnabled = isScrollEnabled }
    }

    static func dismantleUIView(_ textView: RichEditorTextView, coordinator: ()) {
        textView.editorController?.detach(textView)
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
    /// `tools` overrides `configuration.toolbarTools` for this bar.
    func richEditorToolbar(_ controller: RichEditorController, tools: [RichEditorTool]? = nil,
                           alwaysVisible: Bool = false) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            RichEditorToolbarHost(controller: controller, tools: tools, alwaysVisible: alwaysVisible)
        }
    }
}

private struct RichEditorToolbarHost: View {
    @ObservedObject var controller: RichEditorController
    let tools: [RichEditorTool]?
    let alwaysVisible: Bool

    var body: some View {
        ZStack {
            if alwaysVisible || controller.isFocused {
                RichEditorToolbar(controller: controller, tools: tools)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controller.isFocused)
    }
}

/// Format bar (Liquid Glass on iOS 26). Usable on its own, e.g. in a custom
/// keyboard accessory. Shows `configuration.toolbarTools` (all by default),
/// or `tools` when given, in that order. While a table cell is being edited
/// the tools act on that cell (`controller.focusedEditor`).
public struct RichEditorToolbar: View {
    @ObservedObject private var controller: RichEditorController
    private let customTools: [RichEditorTool]?

    public init(controller: RichEditorController, tools: [RichEditorTool]? = nil) {
        self.controller = controller
        self.customTools = tools
    }

    public var body: some View {
        RichEditorToolbarContent(controller: controller.focusedEditor, root: controller, customTools: customTools)
    }
}

/// The bar's buttons: actions and state from `controller` (the focused
/// editor), configuration from `root` (the document's editor).
private struct RichEditorToolbarContent: View {
    @ObservedObject var controller: RichEditorController
    @ObservedObject var root: RichEditorController
    @Environment(\.richContentStyle) private var style
    let customTools: [RichEditorTool]?

    private var allowed: Set<RichBlockType> { root.configuration.allowedBlocks }

    /// Requested tools, in order, without duplicates or ones the
    /// configuration rules out (e.g. Image when images aren't allowed).
    private var requested: [RichEditorTool] {
        var seen = Set<RichEditorTool>()
        return (customTools ?? root.configuration.toolbarTools).filter { seen.insert($0).inserted && isAvailable($0) }
    }

    private func isAvailable(_ tool: RichEditorTool) -> Bool {
        switch tool {
        case .addBlock: return root.configuration.slashCommands
        case .todo: return allowed.contains(.todo)
        case .bulletList: return allowed.contains(.bulletList)
        case .numberedList: return allowed.contains(.numberedList)
        case .toggle: return allowed.contains(.toggle)
        case .image: return allowed.contains(.image)
        case .table: return allowed.contains(.table)
        default: return true
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            tools
            if root.isFocused, requested.contains(.hideKeyboard) {
                // Pinned outside the scrolling tools, always one tap away.
                divider
                icon(.hideKeyboard) { controller.resignFocus() }
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 50)
        .richGlassCapsule()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tools: some View {
        // Hide Keyboard is pinned outside the scrolling tools (see `body`).
        let shown = requested.filter { $0 != .hideKeyboard }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, tool in
                    // A separator wherever the group changes.
                    if index > 0, shown[index - 1].group != tool.group { divider }
                    button(for: tool)
                }
            }
            .padding(.horizontal, 6)
        }
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func button(for tool: RichEditorTool) -> some View {
        switch tool {
        case .addBlock:
            icon(tool) { controller.showCommandMenu() }
        case .turnInto:
            turnIntoMenu
        case .bold, .italic, .underline, .strikethrough, .code:
            let format = tool.inlineFormat!
            icon(tool, isActive: controller.activeFormats.contains(format)) { controller.toggle(format) }
        case .link:
            icon(tool, isActive: controller.activeFormats.contains(.link)) { controller.beginLinkEditing() }
        case .color:
            colorMenu
        case .todo, .bulletList, .numberedList, .toggle:
            let type = tool.blockType!
            icon(tool, isActive: controller.blockType == type) { controller.toggleBlock(type) }
        case .outdent:
            icon(tool, enabled: controller.canOutdent) { controller.outdent() }
        case .indent:
            icon(tool, enabled: controller.canIndent) { controller.indent() }
        case .image:
            icon(tool) { controller.textView?.presentImagePicker() }
        case .table:
            if root.activeCellEditor != nil { tableMenu } else { icon(tool) { root.insertTable() } }
        case .undo:
            icon(tool, enabled: controller.canUndo) { controller.undo() }
        case .redo:
            icon(tool, enabled: controller.canRedo) { controller.redo() }
        case .hideKeyboard:
            EmptyView()
        }
    }

    // MARK: Pieces

    private var accent: Color { Color(uiColor: style.linkColor) }

    private func iconOf(_ tool: RichEditorTool) -> RichEditorToolIcon {
        root.configuration.toolbarIcons[tool] ?? tool.defaultIcon
    }

    private func labelOf(_ tool: RichEditorTool) -> String {
        root.configuration.toolbarLabels[tool] ?? tool.defaultLabel
    }

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
            if allowed.contains(.table), root.activeCellEditor == nil {
                Button { root.insertTable() } label: { Label("Table", systemImage: RichBlockType.table.symbolName) }
            }
        } label: {
            ToolbarIcon(icon: iconOf(.turnInto), isActive: controller.blockType != .paragraph, accent: accent)
        }
        .accessibilityLabel("\(labelOf(.turnInto)), \(controller.blockType.title)")
        .help(labelOf(.turnInto))
    }

    /// Rows, columns and the header row of the table being edited.
    private var tableMenu: some View {
        Menu {
            Section {
                Button { root.insertTableRow(below: false) } label: { Label("Insert row above", systemImage: "arrow.up") }
                Button { root.insertTableRow(below: true) } label: { Label("Insert row below", systemImage: "arrow.down") }
                Button { root.insertTableColumn(right: false) } label: { Label("Insert column left", systemImage: "arrow.left") }
                Button { root.insertTableColumn(right: true) } label: { Label("Insert column right", systemImage: "arrow.right") }
            }
            Section {
                Button { root.toggleTableHeaderRow() } label: {
                    Label("Header row", systemImage: root.tableHasHeaderRow ? "checkmark" : "rectangle.topthird.inset.filled")
                }
            }
            Section {
                Button(role: .destructive) { root.deleteTableRow() } label: { Label("Delete row", systemImage: "trash") }
                Button(role: .destructive) { root.deleteTableColumn() } label: { Label("Delete column", systemImage: "trash") }
                Button(role: .destructive) { root.deleteTable() } label: { Label("Delete table", systemImage: "tablecells.badge.ellipsis") }
            }
        } label: {
            ToolbarIcon(icon: iconOf(.table), isActive: true, accent: accent)
        }
        .accessibilityLabel(labelOf(.table))
        .help(labelOf(.table))
    }

    /// Text colors and Background colors, both expanded: color picker, then
    /// the built-in palette.
    private var colorMenu: some View {
        Menu {
            // Sections are separated; the titled one heads each group.
            Section("Text colors") {
                Button { controller.presentColorPicker(background: false) } label: {
                    Label("Choose from color picker…", systemImage: "eyedropper")
                }
            }
            Section { textButtons(RichColor.allCases) }
            Section("Background colors") {
                Button { controller.presentColorPicker(background: true) } label: {
                    Label("Choose from color picker…", systemImage: "eyedropper")
                }
            }
            Section { backgroundButtons(RichColor.allCases) }
        } label: {
            ToolbarIcon(icon: iconOf(.color), isActive: controller.textColor != .default || controller.highlight != .default,
                        accent: accent)
        }
        .accessibilityLabel(labelOf(.color))
        .help(labelOf(.color))
    }

    private func textButtons(_ colors: [RichColor]) -> some View {
        ForEach(colors, id: \.self) { color in
            Button { controller.setTextColor(color) } label: {
                Label { Text(color.title) } icon: { Image(uiImage: EditorMenus.swatch(color, background: false)) }
            }
        }
    }

    private func backgroundButtons(_ colors: [RichColor]) -> some View {
        ForEach(colors, id: \.self) { color in
            Button { controller.setHighlight(color) } label: {
                Label { Text(color == .default ? "Default background" : "\(color.title) background") }
                    icon: { Image(uiImage: EditorMenus.swatch(color, background: true)) }
            }
        }
    }

    private func icon(_ tool: RichEditorTool, isActive: Bool = false, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarIcon(icon: iconOf(tool), isActive: isActive, isEnabled: enabled, accent: accent)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(labelOf(tool))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(labelOf(tool))
    }
}

private struct ToolbarIcon: View {
    let icon: RichEditorToolIcon
    let isActive: Bool
    var isEnabled = true
    let accent: Color

    /// Disabled is a color, not opacity: the glass bar re-renders its content
    /// while pressed, which made opacity-dimmed icons look enabled.
    private var color: Color {
        if !isEnabled { return Color(uiColor: .tertiaryLabel) }
        return isActive ? accent : Color.primary
    }

    @ViewBuilder
    private var image: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name).font(.system(size: 17, weight: .medium))
        case .asset(let name, let bundle):
            Image(name, bundle: bundle).renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
        case .image(let image):
            Image(uiImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
        }
    }

    var body: some View {
        image
            .frame(width: 42, height: 40)
            .foregroundStyle(color)
            .background(isActive ? accent.opacity(0.15) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
    }
}

extension View {
    @ViewBuilder
    func richGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            // Not `.interactive()`: the buttons give their own feedback, and the
            // bar-wide press effect also brightened disabled icons.
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}
