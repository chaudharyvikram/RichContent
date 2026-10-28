import UIKit

/// Content of a table block: rows of cells, each cell a small document that
/// holds any blocks (paragraphs, lists, quotes …) with every inline format.
/// The first row is a header row when `hasHeaderRow`.
struct EditorTable {
    var rows: [[[EditorBlock]]]
    var hasHeaderRow: Bool

    init(rows: [[[EditorBlock]]], hasHeaderRow: Bool = true) {
        self.rows = rows
        self.hasHeaderRow = hasHeaderRow
        normalize()
    }

    /// An empty table (default 3 × 3 with a header row).
    static func empty(rows: Int = 3, columns: Int = 3, hasHeaderRow: Bool = true) -> EditorTable {
        EditorTable(rows: Array(repeating: Array(repeating: [], count: max(columns, 1)), count: max(rows, 1)),
                    hasHeaderRow: hasHeaderRow)
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// Every row has `columnCount` cells; there is at least one cell.
    mutating func normalize() {
        let columns = max(columnCount, 1)
        if rows.isEmpty { rows = [Array(repeating: [], count: columns)] }
        for i in rows.indices where rows[i].count < columns {
            rows[i] += Array(repeating: [], count: columns - rows[i].count)
        }
    }

    // MARK: Structure

    mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: [], count: max(columnCount, 1)), at: min(max(index, 0), rows.count))
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index), rows.count > 1 else { return }
        rows.remove(at: index)
    }

    mutating func insertColumn(at index: Int) {
        for i in rows.indices { rows[i].insert([], at: min(max(index, 0), rows[i].count)) }
    }

    mutating func removeColumn(at index: Int) {
        guard columnCount > 1 else { return }
        for i in rows.indices where rows[i].indices.contains(index) { rows[i].remove(at: index) }
    }
}

/// Table block. Lays the table out (equal columns, at least
/// `minimumColumnWidth` wide; rows as tall as their tallest cell), draws its
/// grid and, unless cell editors cover it, the cells.
public final class RichTableAttachment: EditorBlockAttachment {

    static let cellPadding = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    static let minimumColumnWidth: CGFloat = 96

    struct Layout: Equatable {
        var columnWidth: CGFloat
        var columns: Int
        var rowHeights: [CGFloat]
        var width: CGFloat { columnWidth * CGFloat(columns) }
        var height: CGFloat { rowHeights.reduce(0, +) }

        func cellRect(row: Int, column: Int) -> CGRect {
            let y = rowHeights.prefix(row).reduce(0, +)
            return CGRect(x: CGFloat(column) * columnWidth, y: y, width: columnWidth, height: rowHeights[row])
        }
    }

    private(set) var table: EditorTable
    private(set) var style: RichContentStyle
    /// Cells as rendered (header row bold), rebuilt with the table or style.
    private var display: [[NSAttributedString]] = []
    /// Heights of cell contents measured by live cell editors ([row][column]).
    private var measuredHeights: [[CGFloat?]] = []
    private var cachedLayout: (available: CGFloat, layout: Layout)?
    /// Off while cell editors are shown on top of the table.
    var drawsCellContent = true {
        didSet { if drawsCellContent != oldValue { invalidate() } }
    }

    @MainActor
    init(table: EditorTable, style: RichContentStyle) {
        self.table = table
        self.style = style
        super.init(data: nil, ofType: nil)
        rebuildDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Updating

    @MainActor
    func update(table: EditorTable) {
        self.table = table
        rebuildDisplay()
        invalidate()
    }

    @MainActor
    func update(style: RichContentStyle) {
        guard style != self.style else { return }
        self.style = style
        rebuildDisplay()
        invalidate()
    }

    /// A live cell editor's content height; relayouts when it changes.
    func setMeasuredHeight(_ height: CGFloat, row: Int, column: Int) {
        guard measuredHeights.indices.contains(row), measuredHeights[row].indices.contains(column),
              measuredHeights[row][column].map({ abs($0 - height) > 0.5 }) ?? true else { return }
        measuredHeights[row][column] = height
        cachedLayout = nil
        invalidate()
    }

    /// The style cells are rendered and edited with.
    static func cellStyle(_ style: RichContentStyle, header: Bool) -> RichContentStyle {
        var cell = style
        cell.horizontalPadding = 0
        cell.verticalPadding = 0
        cell.editorHorizontalPadding = 0
        cell.paragraphSpacing = min(style.paragraphSpacing, 6)
        if header { cell.font = style.font.adding(.traitBold) }
        return cell
    }

    @MainActor
    private func rebuildDisplay() {
        display = table.rows.enumerated().map { r, row in
            let cellStyle = Self.cellStyle(style, header: table.hasHeaderRow && r == 0)
            return row.map { EditorDocument.attributedString(from: $0, style: cellStyle) }
        }
        measuredHeights = table.rows.map { $0.map { _ in nil } }
        cachedLayout = nil
    }

    // MARK: Layout

    func layout(forWidth available: CGFloat) -> Layout {
        if let cached = cachedLayout, abs(cached.available - available) < 0.5 { return cached.layout }
        let pad = Self.cellPadding
        let columns = max(table.columnCount, 1)
        let columnWidth = max(floor(available / CGFloat(columns)), Self.minimumColumnWidth)
        let textWidth = max(columnWidth - pad.left - pad.right, 1)
        let minimumLine = ceil(style.font.lineHeight)
        var heights: [CGFloat] = []
        for (r, row) in display.enumerated() {
            var tallest = minimumLine
            for (c, cell) in row.enumerated() {
                let measured = measuredHeights[r][c] ?? ceil(cell.boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
                tallest = max(tallest, measured)
            }
            heights.append(tallest + pad.top + pad.bottom)
        }
        let layout = Layout(columnWidth: columnWidth, columns: columns, rowHeights: heights)
        cachedLayout = (available, layout)
        return layout
    }

    override public func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                          glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let available = availableWidth(textContainer, characterIndex: charIndex, fallback: lineFrag.width)
        let layout = layout(forWidth: available)
        // Wider tables scroll sideways inside this width (cell editors).
        return CGRect(x: 0, y: 0, width: min(layout.width, available), height: layout.height)
    }

    override public func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?,
                               characterIndex charIndex: Int) -> UIImage? {
        let available = availableWidth(textContainer, characterIndex: charIndex, fallback: imageBounds.width)
        let layout = layout(forWidth: available)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: imageBounds.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: imageBounds.size)
            context.cgContext.clip(to: bounds)
            Self.drawGrid(layout, hasHeaderRow: table.hasHeaderRow, in: bounds)
            guard drawsCellContent else { return }
            let pad = Self.cellPadding
            for (r, row) in display.enumerated() {
                for (c, cell) in row.enumerated() where cell.length > 0 {
                    let rect = layout.cellRect(row: r, column: c).inset(by: pad)
                    cell.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
            }
        }
    }

    /// Header tint, cell borders and the outer frame.
    static func drawGrid(_ layout: Layout, hasHeaderRow: Bool, in bounds: CGRect) {
        let outer = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        if hasHeaderRow, let first = layout.rowHeights.first {
            UIColor.secondarySystemFill.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: layout.width, height: first))
        }
        let line = 1 / max(UITraitCollection.current.displayScale, 1)
        UIColor.separator.setFill()
        var y: CGFloat = 0
        for height in layout.rowHeights.dropLast() {
            y += height
            UIRectFill(CGRect(x: 0, y: y - line / 2, width: layout.width, height: line))
        }
        for column in 1..<max(layout.columns, 1) {
            let x = CGFloat(column) * layout.columnWidth
            UIRectFill(CGRect(x: x - line / 2, y: 0, width: line, height: layout.height))
        }
        let frame = UIBezierPath(rect: outer.insetBy(dx: line / 2, dy: line / 2))
        frame.lineWidth = line
        UIColor.separator.setStroke()
        frame.stroke()
    }
}
