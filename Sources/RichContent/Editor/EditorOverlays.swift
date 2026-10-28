import UIKit

// MARK: - Shared menus

@MainActor
enum EditorMenus {

    static func turnInto(_ controller: RichEditorController) -> UIMenu {
        let current = controller.blockType
        let actions = RichBlockType.textBlocks.filter { controller.configuration.allowedBlocks.contains($0) }.map { type in
            UIAction(title: type.title, image: UIImage(systemName: type.symbolName), state: type == current ? .on : .off) { _ in
                controller.setBlock(type)
            }
        }
        return UIMenu(title: "Turn into", image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: actions)
    }

    /// Two expanded sections, Text colors and Background colors, each with
    /// "Choose from color picker…", then the built-in palette.
    static func color(_ controller: RichEditorController, wholeBlock: Bool) -> UIMenu {
        func text(_ color: RichColor) -> UIAction {
            UIAction(title: color.title, image: swatch(color, background: false),
                     state: !wholeBlock && controller.textColor == color ? .on : .off) { _ in
                if wholeBlock { controller.setBlockColor(color) } else { controller.setTextColor(color) }
            }
        }
        func background(_ color: RichColor) -> UIAction {
            UIAction(title: color == .default ? "Default background" : "\(color.title) background",
                     image: swatch(color, background: true),
                     state: !wholeBlock && controller.highlight == color ? .on : .off) { _ in
                if wholeBlock { controller.setBlockColor(color, background: true) } else { controller.setHighlight(color) }
            }
        }
        func picker(background: Bool) -> UIAction {
            UIAction(title: "Choose from color picker…", image: UIImage(systemName: "eyedropper")) { _ in
                controller.presentColorPicker(background: background, wholeBlock: wholeBlock)
            }
        }
        // Flat inline groups, separated: the titled picker group heads each
        // section, then the built-in palette. (Nested inline menus would drop
        // the section titles.)
        func section(_ title: String, background isBackground: Bool, _ item: (RichColor) -> UIAction) -> [UIMenu] {
            [UIMenu(title: title, options: .displayInline, children: [picker(background: isBackground)]),
             UIMenu(options: .displayInline, children: RichColor.allCases.map(item))]
        }
        return UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"),
                      children: section("Text colors", background: false, text)
                        + section("Background colors", background: true, background))
    }

    /// "A" in the color, or a filled square for backgrounds.
    static func swatch(_ color: RichColor, background: Bool) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
            if background {
                (color == .default ? UIColor.systemBackground : color.backgroundColor).setFill()
                path.fill()
                UIColor.separator.setStroke()
                path.stroke()
            } else {
                UIColor.separator.setStroke()
                path.stroke()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                    .foregroundColor: color == .default ? UIColor.label : color.textColor
                ]
                let a = "A" as NSString
                let s = a.size(withAttributes: attrs)
                a.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2), withAttributes: attrs)
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    static let codeLanguages = ["Plain text", "Swift", "Kotlin", "JavaScript", "TypeScript", "Python", "Java", "Go", "Rust",
                                "Ruby", "PHP", "C", "C++", "C#", "Objective-C", "SQL", "Shell", "JSON", "YAML", "HTML",
                                "CSS", "Markdown", "XML", "GraphQL"]

    /// Block handle menu: turn into, color, block-specific actions, move, delete.
    static func block(_ controller: RichEditorController, info: BlockInfo) -> UIMenu {
        var sections: [UIMenuElement] = []
        if !info.type.isAttachment {
            sections.append(UIMenu(options: .displayInline, children: [turnInto(controller), color(controller, wholeBlock: true)]))
        }
        var specific: [UIMenuElement] = []
        switch info.type {
        case .todo:
            specific.append(UIAction(title: info.checked ? "Uncheck" : "Check",
                                     image: UIImage(systemName: info.checked ? "square" : "checkmark.square")) { _ in controller.toggleChecked() })
        case .toggle:
            specific.append(UIAction(title: info.collapsed == nil ? "Collapse" : "Expand",
                                     image: UIImage(systemName: info.collapsed == nil ? "chevron.up" : "chevron.down")) { _ in controller.toggleCollapsed() })
        case .callout:
            let emojis = EditorEmojiPicker.emojis.prefix(24).map { emoji in
                UIAction(title: emoji, state: info.emoji == emoji ? .on : .off) { _ in controller.setCalloutEmoji(emoji) }
            }
            specific.append(UIMenu(title: "Icon", image: UIImage(systemName: "face.smiling"), children: emojis))
        case .codeBlock:
            let languages = codeLanguages.map { name in
                let value: String? = name == "Plain text" ? nil : name.lowercased()
                return UIAction(title: name, state: info.language == value ? .on : .off) { _ in controller.setCodeLanguage(value) }
            }
            specific.append(UIMenu(title: "Language", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), children: languages))
        default:
            break
        }
        var nesting: [UIMenuElement] = []
        if controller.canIndent {
            nesting.append(UIAction(title: "Indent", image: UIImage(systemName: "increase.indent")) { _ in controller.indent() })
        }
        if controller.canOutdent {
            nesting.append(UIAction(title: "Outdent", image: UIImage(systemName: "decrease.indent")) { _ in controller.outdent() })
        }
        if !specific.isEmpty || !nesting.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: specific + nesting))
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Move up", image: UIImage(systemName: "arrow.up")) { _ in controller.moveBlockUp() },
            UIAction(title: "Move down", image: UIImage(systemName: "arrow.down")) { _ in controller.moveBlockDown() },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in controller.duplicateBlock() }
        ]))
        sections.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            controller.deleteBlock()
        })
        return UIMenu(title: info.type.title, children: sections)
    }
}

// MARK: - Block handle

/// ⋮⋮ beside the current block. Tap: block menu. Drag: move the block.
final class EditorBlockHandle: UIButton {
    weak var textView: RichEditorTextView?
    private var configuredInfo: BlockInfo?
    private var configuredState: (Bool, Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(Self.gripImage, for: .normal)
        tintColor = .secondaryLabel
        showsMenuAsPrimaryAction = true
        accessibilityLabel = "Block actions"
        accessibilityHint = "Shows actions for this block. Drag to move it."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(for controller: RichEditorController, info: BlockInfo) {
        let state = (controller.canIndent, controller.canOutdent)
        guard configuredInfo != info || configuredState.map({ $0 != state }) ?? true else { return }
        configuredInfo = info
        configuredState = state
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak controller] completion in
            guard let controller else { completion([]); return }
            let current = controller.info(ofParagraphAt: controller.selectedRange.location)
            completion(EditorMenus.block(controller, info: current).children)
        }])
    }

    /// ⋮⋮ (two columns of three dots), drawn so it doesn't depend on a symbol name.
    static let gripImage: UIImage = {
        let size = CGSize(width: 10, height: 16)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setFill()
            for column in 0..<2 {
                for row in 0..<3 {
                    let dot = CGRect(x: CGFloat(column) * 6, y: 1 + CGFloat(row) * 6, width: 3.4, height: 3.4)
                    UIBezierPath(ovalIn: dot).fill()
                }
            }
        }.withRenderingMode(.alwaysTemplate)
    }()

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -6).contains(point)
    }
}

// MARK: - Selection toolbar

/// Floating format bar shown while text is selected.
final class EditorSelectionToolbar: UIView {
    weak var textView: RichEditorTextView?
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let stack = UIStackView()
    private let turnInto = UIButton(type: .system)
    private let colorButton = UIButton(type: .system)
    private var formatButtons: [RichInlineFormat: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        blur.layer.cornerRadius = 12
        blur.clipsToBounds = true
        blur.layer.borderWidth = 0.5
        blur.layer.borderColor = UIColor.separator.cgColor
        addSubview(blur)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        blur.contentView.addSubview(stack)

        var turnConfig = UIButton.Configuration.plain()
        turnConfig.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        turnConfig.imagePlacement = .trailing
        turnConfig.imagePadding = 4
        turnConfig.baseForegroundColor = .label
        turnConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8)
        turnInto.configuration = turnConfig
        turnInto.showsMenuAsPrimaryAction = true
        turnInto.accessibilityLabel = "Turn into"
        stack.addArrangedSubview(turnInto)
        stack.addArrangedSubview(separator())

        for format in RichInlineFormat.allCases {
            let button = iconButton(format.symbolName, format.title) { [weak self] in
                self?.textView?.editorController?.toggle(format)
            }
            formatButtons[format] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        colorButton.setImage(UIImage(systemName: "paintpalette", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal)
        colorButton.tintColor = .label
        colorButton.showsMenuAsPrimaryAction = true
        colorButton.accessibilityLabel = "Color"
        colorButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(colorButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width, height: 40)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        stack.frame = blur.contentView.bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }

    func update(_ controller: RichEditorController) {
        var config = turnInto.configuration
        var title = AttributedString(controller.blockType.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        config?.attributedTitle = title
        turnInto.configuration = config
        turnInto.menu = EditorMenus.turnInto(controller)
        colorButton.menu = EditorMenus.color(controller, wholeBlock: false)
        for (format, button) in formatButtons {
            let on = controller.activeFormats.contains(format)
            button.tintColor = on ? controller.style.linkColor : .label
            button.backgroundColor = on ? controller.style.linkColor.withAlphaComponent(0.14) : .clear
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
        invalidateIntrinsicContentSize()
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        button.accessibilityLabel = label
        button.layer.cornerRadius = 7
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let wrapper = UIStackView(arrangedSubviews: [line])
        wrapper.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        wrapper.isLayoutMarginsRelativeArrangement = true
        wrapper.alignment = .center
        return wrapper
    }
}

// MARK: - Slash menu

/// The "/" command list, anchored under the caret.
final class EditorSlashMenuView: UIView, UITableViewDataSource, UITableViewDelegate {
    weak var textView: RichEditorTextView?
    private let table = UITableView(frame: .zero, style: .plain)
    private var sections: [(String, [RichEditorCommand])] = []
    private var selected: RichEditorCommand?
    private let rowHeight: CGFloat = 52

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)
        table.backgroundColor = .secondarySystemGroupedBackground
        table.layer.cornerRadius = 12
        table.layer.borderWidth = 0.5
        table.layer.borderColor = UIColor.separator.cgColor
        table.separatorStyle = .none
        table.rowHeight = rowHeight
        table.sectionHeaderHeight = 28
        table.sectionHeaderTopPadding = 0
        table.dataSource = self
        table.delegate = self
        table.register(SlashCell.self, forCellReuseIdentifier: "cell")
        addSubview(table)
        accessibilityLabel = "Commands"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        table.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }

    func show(_ state: SlashState, grouped: Bool) {
        if grouped {
            var order: [String] = []
            var map: [String: [RichEditorCommand]] = [:]
            for command in state.results {
                if map[command.section] == nil { order.append(command.section) }
                map[command.section, default: []].append(command)
            }
            sections = order.map { ($0, map[$0]!) }
        } else {
            sections = [("", state.results)]
        }
        selected = state.selection < state.results.count ? state.results[state.selection] : nil
        table.reloadData()
        if let selected, let path = indexPath(of: selected) {
            table.scrollToRow(at: path, at: .none, animated: false)
        }
    }

    func preferredSize(maxHeight: CGFloat) -> CGSize {
        let rows = sections.reduce(0) { $0 + $1.1.count }
        let headers = sections.filter { !$0.0.isEmpty }.count
        let height = CGFloat(rows) * rowHeight + CGFloat(headers) * 28 + 8
        return CGSize(width: 280, height: min(max(height, rowHeight), maxHeight))
    }

    private func indexPath(of command: RichEditorCommand) -> IndexPath? {
        for (s, section) in sections.enumerated() {
            if let r = section.1.firstIndex(of: command) { return IndexPath(row: r, section: s) }
        }
        return nil
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].0.isEmpty ? nil : sections[section].0
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].0.isEmpty ? 4 : 28
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! SlashCell
        let command = sections[indexPath.section].1[indexPath.row]
        cell.configure(command, highlighted: command == selected, accent: textView?.editorController?.style.linkColor ?? .tintColor)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        textView?.editorController?.run(sections[indexPath.section].1[indexPath.row])
    }

    private final class SlashCell: UITableViewCell {
        private let iconBox = UIView()
        private let icon = UIImageView()
        private let title = UILabel()
        private let subtitle = UILabel()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            iconBox.backgroundColor = .systemBackground
            iconBox.layer.cornerRadius = 6
            iconBox.layer.borderWidth = 0.5
            iconBox.layer.borderColor = UIColor.separator.cgColor
            icon.contentMode = .center
            icon.tintColor = .label
            title.font = .systemFont(ofSize: 15, weight: .medium)
            subtitle.font = .systemFont(ofSize: 12)
            subtitle.textColor = .secondaryLabel
            for v in [iconBox, icon, title, subtitle] { v.translatesAutoresizingMaskIntoConstraints = false }
            contentView.addSubview(iconBox)
            iconBox.addSubview(icon)
            contentView.addSubview(title)
            contentView.addSubview(subtitle)
            NSLayoutConstraint.activate([
                iconBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
                iconBox.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                iconBox.widthAnchor.constraint(equalToConstant: 36),
                iconBox.heightAnchor.constraint(equalToConstant: 36),
                icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 10),
                title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
                title.bottomAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 1),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitle.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
                subtitle.topAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func configure(_ command: RichEditorCommand, highlighted: Bool, accent: UIColor) {
            title.text = command.title
            subtitle.text = command.subtitle
            switch command.action {
            case .textColor(let color):
                icon.image = EditorMenus.swatch(color, background: false)
            case .background(let color):
                icon.image = EditorMenus.swatch(color, background: true)
            default:
                icon.image = UIImage(systemName: command.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
            }
            contentView.backgroundColor = highlighted ? accent.withAlphaComponent(0.12) : .clear
            accessibilityLabel = "\(command.title), \(command.subtitle)"
            accessibilityTraits = highlighted ? [.button, .selected] : .button
        }
    }
}

// MARK: - Emoji picker

/// Small emoji grid for callout icons.
final class EditorEmojiPicker: UIViewController, UIPopoverPresentationControllerDelegate,
                               UICollectionViewDataSource, UICollectionViewDelegate {

    static let emojis = ["💡", "📌", "⚠️", "❗", "✅", "❌", "ℹ️", "❓", "🔥", "⭐", "📝", "📎", "📅", "⏰", "🚀", "🎯",
                         "💬", "📣", "🔒", "🔑", "💰", "📈", "🐛", "🛠️", "🧪", "🎉", "👍", "👀", "❤️", "🙏", "🤔", "😀",
                         "📚", "🗂️", "🧭", "🌱", "☕", "🏁", "🔔", "✏️"]

    private let onPick: (String) -> Void

    init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 296, height: 196)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 36, height: 36)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        let grid = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(grid)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { Self.emojis.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        let label = (cell.contentView.viewWithTag(1) as? UILabel) ?? {
            let l = UILabel(frame: cell.contentView.bounds)
            l.tag = 1
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 24)
            l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cell.contentView.addSubview(l)
            return l
        }()
        label.text = Self.emojis[indexPath.item]
        cell.accessibilityLabel = Self.emojis[indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let emoji = Self.emojis[indexPath.item]
        dismiss(animated: true) { self.onPick(emoji) }
    }
}
