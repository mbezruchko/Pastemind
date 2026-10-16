import AppKit
import SwiftUI

/// What a `ListView` shows: how many rows, how tall, and a cell for each.
protocol ListSource: AnyObject {
    var rowCount: Int { get }
    /// The row's own height, without the gap under it.
    func rowHeight(_ row: Int) -> CGFloat
    func cell(_ row: Int, in list: ListView) -> ListCell
    /// A click on a row (`count` 2 and more: a double click).
    func click(_ row: Int, count: Int)
    /// What dragging the row out takes along (nothing: it doesn't drag).
    func dragWriters(_ row: Int) -> [NSPasteboardWriting]
    func dragBegan(_ row: Int)
    /// The row dragged out was dropped somewhere that took it (`dropped`), or not.
    func dragEnded(_ row: Int, dropped: Bool)
    /// The rows one dragged within the list goes among, to be dropped between (nil: it stays where it is).
    func reorderRange(_ row: Int) -> Range<Int>?
    /// Dropped at `index`, between rows (0: above the first).
    func reorder(_ row: Int, to index: Int)
}

extension ListSource {
    func dragWriters(_ row: Int) -> [NSPasteboardWriting] { [] }
    func dragBegan(_ row: Int) {}
    func dragEnded(_ row: Int, dropped: Bool) {}
    func reorderRange(_ row: Int) -> Range<Int>? { nil }
    func reorder(_ row: Int, to index: Int) {}
}

/// The panels' lists, drawn by AppKit. NSTableView keeps views only for the rows on screen (about ten), reuses them as
/// the list scrolls or changes, and lays out nothing else; each row draws itself in one go. SwiftUI's lazy stack
/// measured and diffed every row on each keystroke: 14–18 ms a keystroke with a long history, 40–60 ms at worst, nearly
/// all of it SwiftUI's own work; this costs about a millisecond (measured 2026-10-14).
///
/// The rows aren't NSTableView's own: they draw the panels' rounded selection and hover, a click acts at once (no
/// double-click delay), and the list never takes the keyboard (the panel's keys move the selection, the field keeps
/// the cursor).
final class ListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSDraggingSource {
    struct Layout {
        /// From the rows to the list's sides.
        var inset: CGFloat
        /// Above the first row and below the last.
        var top: CGFloat
        var bottom: CGFloat
        /// Between rows.
        var gap: CGFloat
    }

    let layout: Layout
    weak var source: ListSource?
    /// Rows dragged within it can be dropped between others (`ListSource.reorderRange`): the rows part to show where.
    var reorderable = false {
        didSet {
            guard reorderable != oldValue else { return }
            table.unregisterDraggedTypes()
            if reorderable { table.registerForDraggedTypes(Self.draggedTypes) }
        }
    }
    /// What a row that drags nothing out (a folder) carries, to be dropped within the list.
    private static let rowType = NSPasteboard.PasteboardType("app.pastemind.row")
    /// Whatever the rows carry (their text, a file promise), so a row dragged within the list is seen as it passes.
    private static let draggedTypes = [rowType, .string, .fileURL]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    /// The selected row, drawn selected.
    private(set) var selected: Int?
    /// The row under the pointer.
    private var hovered: Int?
    private let table = ListTableView()
    private var rows = 0

    init(layout: Layout) {
        self.layout = layout
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.draggingDestinationFeedbackStyle = .gap
        table.onClick = { [weak self] point, count in self?.click(at: point, count: count) }
        table.onPointer = { [weak self] point in self?.hover(at: point) }
        table.onDrag = { [weak self] point, event in self?.drag(at: point, with: event) }
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(tintChanged), name: SelectionTint.changed,
                                               object: nil)
    }

    /// The selection's colour changed in Settings: the rows on screen draw again (the others will as they come).
    @objc private func tintChanged() {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            table.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The source's rows again (new results, a new query): the cells on screen are made again, nothing else.
    func reload(selected row: Int?) {
        selected = row
        hovered = nil   // the pointer is somewhere else in the new list: it shows again once it moves
        rows = source?.rowCount ?? 0
        table.reloadData()
    }

    /// Only the selection moved: the two rows redraw.
    func select(_ row: Int?) {
        guard row != selected else { return }
        selected = row
        updateCells()
    }

    func scrollToTop() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    /// As little as it takes for the row to be all on screen.
    /// With room round it: as far from the list's top and bottom as from its sides, and the first and last rows with
    /// all their padding (scrolled to just the row, the selection sat against the edge).
    func scrollToVisible(_ row: Int) {
        guard row >= 0, row < rows else { return }
        var rect = table.rect(ofRow: row + 1)
        rect.size.height -= layout.gap
        rect = rect.insetBy(dx: 0, dy: -layout.inset)
        if row == 0 { rect = rect.union(table.rect(ofRow: 0)) }
        if row == rows - 1 { rect = rect.union(table.rect(ofRow: rows + 1)) }
        table.scrollToVisible(rect)
    }

    /// The source's row `row`, while it's on screen in full (not scrolled out of the list, wholly or in part).
    func visibleCell(_ row: Int) -> ListCell? {
        guard row >= 0, row < rows,
              let cell = table.view(atColumn: 0, row: row + 1, makeIfNecessary: false) as? ListCell,
              convert(bounds, to: nil).insetBy(dx: -1, dy: -1).contains(cell.convert(cell.content, to: nil))
        else { return nil }
        return cell
    }

    /// A cell of `type` to show again, or a new one.
    func reuse<Cell: ListCell>(_ type: Cell.Type) -> Cell {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: type))
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
        let cell = Cell(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    // MARK: Table (a row of padding above the source's rows, and one below)

    func numberOfRows(in tableView: NSTableView) -> Int { rows + 2 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row == 0 { return layout.top }
        if row == rows + 1 { return max(layout.bottom - layout.gap, 1) }
        return (source?.rowHeight(row - 1) ?? 1) + layout.gap
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row > 0, row <= rows, let source else { return nil }
        let cell = source.cell(row - 1, in: self)
        cell.inset = layout.inset
        cell.gap = layout.gap
        cell.selected = row - 1 == selected
        cell.hovered = row - 1 == hovered
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PlainRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Pointer

    /// For the debug hooks, which can't move the pointer: the pointer at `point` in the window, from its top left (nil:
    /// gone), or a click there, through the same hit testing as the real ones.
    func debugPointer(_ point: NSPoint?) {
        hover(at: point.map { table.convert(NSPoint(x: $0.x, y: (window?.frame.height ?? 0) - $0.y), from: nil) })
    }

    func debugClick(_ point: NSPoint, count: Int) {
        click(at: table.convert(NSPoint(x: point.x, y: (window?.frame.height ?? 0) - point.y), from: nil), count: count)
    }

    /// The row whose cell (not the padding beside it or the gap under it) is under `point`, in the table.
    private func row(at point: NSPoint) -> Int? {
        let row = table.row(at: point)
        guard row > 0, row <= rows,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ListCell, cell.interactive,
              cell.content.contains(cell.convert(point, from: table)) else { return nil }
        return row - 1
    }

    private func click(at point: NSPoint, count: Int) {
        guard let row = row(at: point) else { return }
        source?.click(row, count: count)
    }

    // MARK: Dragging out

    private var draggedRow: Int?

    /// The row under `point` (where the button went down), as it's drawn, under the pointer.
    private func drag(at point: NSPoint, with event: NSEvent) {
        guard let row = row(at: point), let source else { return }
        let reorders = reorderable && source.reorderRange(row) != nil
        var writers = source.dragWriters(row)
        if writers.isEmpty, reorders {   // nothing to take out of the panel (a folder): within the list only
            let item = NSPasteboardItem()
            item.setData(Data(), forType: Self.rowType)
            writers = [item]
        }
        guard !writers.isEmpty, let cell = table.view(atColumn: 0, row: row + 1, makeIfNecessary: false) as? ListCell,
              let bitmap = cell.bitmapImageRepForCachingDisplay(in: cell.content) else { return }
        cell.cacheDisplay(in: cell.content, to: bitmap)
        let image = NSImage(size: cell.content.size)
        image.addRepresentation(bitmap)
        let frame = table.convert(cell.content, from: cell)
        let items = writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return item
        }
        draggedRow = row
        source.dragBegan(row)
        table.beginDraggingSession(with: items, event: event, source: self)
        // Out of the list while it's carried, the gap it's dropped into taking its place: the list keeps its length
        // (left where it was, the gap pushed the last row out under the list's foot). Back if it's dropped elsewhere.
        if reorders { table.hideRows(at: IndexSet(integer: row + 1), withAnimation: .slideUp) }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? ClipDrag.operations.union(.move) : ClipDrag.operations
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let row = draggedRow else { return }
        draggedRow = nil
        let moved = droppedHere
        droppedHere = false
        if !table.hiddenRowIndexes.isEmpty {
            table.unhideRows(at: table.hiddenRowIndexes, withAnimation: moved ? [] : .slideDown)
        }
        // Dropped back in the list it moved: not taken by another app.
        source?.dragEnded(row, dropped: operation != [] && !moved)
    }

    // MARK: Dragging within

    /// The row being dragged went in somewhere else in the list (the drag's end is told it wasn't taken out).
    private var droppedHere = false

    /// Only a row of its own, between the rows it goes among; on a row, above or below it, whichever half it's over.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as AnyObject?) === self, let dragged = draggedRow,
              let range = source?.reorderRange(dragged) else { return [] }
        // The table's rows: 0 is the padding above the source's rows, 1…rows theirs, rows + 1 the padding below.
        var index = row - 1
        if operation == .on {
            let point = tableView.convert(info.draggingLocation, from: nil)
            if point.y > tableView.rect(ofRow: row).midY { index += 1 }
        }
        index = min(max(index, range.lowerBound), range.upperBound)
        tableView.setDropRow(index + 1, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard (info.draggingSource as AnyObject?) === self, let dragged = draggedRow, let source else { return false }
        droppedHere = true
        source.reorder(dragged, to: row - 1)
        return true
    }

    private func hover(at point: NSPoint?) {
        let row = point.flatMap(row(at:))
        guard row != hovered else { return }
        hovered = row
        updateCells()
    }

    /// Scrolling moves the rows under a still pointer.
    @objc private func scrolled() {
        guard let window, hovered != nil || table.isMouseInside else { return }
        let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hover(at: table.visibleRect.contains(point) ? point : nil)
    }

    private func updateCells() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? ListCell else { return }
            cell.selected = row - 1 == selected
            cell.hovered = row - 1 == hovered
        }
    }
}

/// The table under a list: clicks and the pointer go to the list; it never takes the keyboard, and selects nothing
/// itself.
private final class ListTableView: NSTableView {
    var onClick: (NSPoint, Int) -> Void = { _, _ in }
    var onPointer: (NSPoint?) -> Void = { _ in }
    /// The button went down at the point and the pointer's moved on a few points: a drag.
    var onDrag: (NSPoint, NSEvent) -> Void = { _, _ in }
    private var pressed: NSEvent?
    private(set) var isMouseInside = false
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        onClick(convert(event.locationInWindow, from: nil), event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let from = pressed.locationInWindow, to = event.locationInWindow
        guard hypot(to.x - from.x, to.y - from.y) > 4 else { return }
        self.pressed = nil
        onDrag(convert(from, from: nil), event)
    }

    override func mouseUp(with event: NSEvent) { pressed = nil }

    override func rightMouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Always: the panels never make Pastemind the active app.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        onPointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        onPointer(nil)
    }
}

/// A row that draws nothing of its own: its cell draws the selection.
private final class PlainRowView: NSTableRowView {
    /// Clicks go to the table.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// A row of a list, drawn in one go: the selection or the pointer's faint highlight, then what the row shows.
class ListCell: NSView {
    var selected = false {
        didSet { if selected != oldValue { selectionChanged() } }
    }
    var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    /// From the row to the list's sides, and the gap under it: set by the list.
    var inset: CGFloat = 0
    var gap: CGFloat = 0
    /// The selection's corner radius: concentric with the panel's corners, as far in as the list's side inset (8
    /// points of radius in 8 of inset left the bottom row's corner squeezed against the panel's curve).
    var radius: CGFloat { max(PanelChrome.cornerRadius - inset, 8) }
    /// The selection: the colour chosen in Settings (the system's accent colour unless another is), faint.
    private static var selection: NSColor { Settings.selectionTint.color.opacity(0.26) }
    private static let hover = NSColor.labelColor.opacity(0.05)
    /// Headers aren't clicked or hovered.
    var interactive: Bool { true }

    override required init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Clicks go to the table.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the row is: the cell less the inset at the sides and the gap below.
    var content: NSRect {
        NSRect(x: inset, y: 0, width: max(bounds.width - inset * 2, 0), height: max(bounds.height - gap, 0))
    }

    func selectionChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.scale = window?.backingScaleFactor ?? 2
        let rect = content
        if interactive, selected || hovered {
            (selected ? Self.selection : Self.hover).setFill()
            Draw.rounded(rect, radius: radius).fill()
        }
        drawRow(in: rect)
    }

    /// What the row shows, in `rect` (the row's frame in the cell).
    func drawRow(in rect: NSRect) {}

    /// `value` on the display's pixel grid, as SwiftUI places views.
    func pixel(_ value: CGFloat) -> CGFloat { Draw.pixel(value) }
}

/// Drawing the rows as SwiftUI drew them: its continuous corners, its text metrics, its pixel grid.
enum Draw {
    /// The display's pixels per point, for the cell being drawn.
    static var scale: CGFloat = 2

    /// `value` on the pixel grid, as SwiftUI places views (a cell's origin is on it).
    static func pixel(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    static func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
    }

    /// A rounded rectangle's border inside it, as SwiftUI's `strokeBorder`.
    static func border(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: 0.5)
            .path(in: rect).cgPath)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }

    /// A tile with a symbol: the clip's kind, a snippet. `tint` at 16% inside, 18% around, full on the symbol.
    /// A tile's corners, for whatever else shares its place (a picture, a colour).
    static func tileRadius(_ rect: NSRect) -> CGFloat { rect.width * 0.24 }

    static func tile(_ rect: NSRect, symbol: String, tint: NSColor) {
        let radius = tileRadius(rect)
        tint.opacity(0.16).setFill()
        rounded(rect, radius: radius).fill()
        border(rect, radius: radius, color: tint.opacity(0.18))
        Draw.symbol(symbol, size: (rect.width * 0.4).rounded(), weight: .semibold, color: tint, centeredIn: rect)
    }

    private static var symbols: [String: NSImage] = [:]

    /// An SF Symbol at `size` points in `color` (a template tinted as SwiftUI tints one), centered in `rect` as
    /// SwiftUI centers an Image: its left edge.
    @discardableResult
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centeredIn rect: NSRect)
        -> CGFloat {
        guard let image = symbolImage(name, size: size, weight: weight),
              let context = NSGraphicsContext.current?.cgContext else { return rect.midX }
        // Across, SwiftUI centers the symbol's alignment width (a code symbol's is half a point narrower than its
        // image), which puts some half a pixel further right.
        let alignment = image.alignmentRect.width > 0 ? image.alignmentRect : NSRect(origin: .zero, size: image.size)
        let frame = NSRect(x: pixel(rect.midX - alignment.width / 2) - alignment.minX,
                           y: pixel(rect.midY - image.size.height / 2), width: image.size.width, height: image.size.height)
        context.saveGState()
        context.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.set()
        frame.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
        return frame.minX
    }

    static func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)@\(size)/\(weight.rawValue)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        symbols[key] = image
        return image
    }

    /// An image filling `rect` (cropped to it, as SwiftUI's `scaledToFill`), its corners rounded.
    static func fill(_ image: NSImage, in rect: NSRect, radius: CGFloat) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                           width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        rounded(rect, radius: radius).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// One line of text with its top at `top`, cut short to fit `width` as its paragraph style says. On Core Text, as
    /// SwiftUI draws: it fits as many characters before the "…" as there's room for (TextKit's truncation stopped up
    /// to a character short).
    static func line(_ text: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat) {
        guard width > 0, text.length > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let string = coreText(text)
        let line = CTLineCreateWithAttributedString(string)
        var drawn = line
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) {
            let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let middle = paragraph?.lineBreakMode == .byTruncatingMiddle
            let token = CTLineCreateWithAttributedString(NSAttributedString(
                string: "…", attributes: string.attributes(at: middle ? 0 : string.length - 1, effectiveRange: nil)))
            drawn = CTLineCreateTruncatedLine(line, Double(width), middle ? .middle : .end, token) ?? line
        }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: top + baselineOffset(font))
        CTLineDraw(drawn, context)
        context.restoreGState()
    }

    /// The text with its colors resolved for the appearance it's drawn in, and its tracking, as Core Text takes them.
    private static func coreText(_ text: NSAttributedString) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: string.length)
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor else { return }
            string.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor,
                                range: range)
        }
        text.enumerateAttribute(.tracking, in: whole) { value, range, _ in
            guard let tracking = value else { return }
            string.addAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), value: tracking, range: range)
        }
        return string
    }

    private static var baselines: [NSFont: CGFloat] = [:]

    /// Where SwiftUI puts a line's baseline under its top (TextKit's: 13 for 13 points).
    static func baselineOffset(_ font: NSFont) -> CGFloat {
        if let offset = baselines[font] { return offset }
        let offset = NSLayoutManager().defaultBaselineOffset(for: font)
        baselines[font] = offset
        return offset
    }

    private static var heights: [NSFont: CGFloat] = [:]

    /// The height SwiftUI gives a line of `font` (TextKit's: 16 for 13 points).
    static func lineHeight(_ font: NSFont) -> CGFloat {
        if let height = heights[font] { return height }
        let height = NSAttributedString(string: "Hg", attributes: [.font: font])
            .boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).height
        heights[font] = height
        return height
    }

    /// `text` in `font` and `color`, cut short as `truncation` says, with the query's matches (`Excerpt.matches`) in
    /// `bold` and `boldColor`.
    static func text(_ text: String, font: NSFont, color: NSColor, query: String = "", bold: NSFont? = nil,
                     boldColor: NSColor = .labelColor, truncation: NSLineBreakMode = .byTruncatingTail,
                     tracking: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if tracking != 0 { attributes[.tracking] = tracking }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        guard !query.isEmpty, let bold else { return string }
        for range in Excerpt.matches(of: query, in: text) {
            string.addAttributes([.font: bold, .foregroundColor: boldColor], range: NSRange(range, in: text))
        }
        return string
    }

    static func width(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    /// A system font with SwiftUI's rounded design and, for the ⌘ numbers, digits of one width.
    static func roundedFont(size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    private static var faded: [String: NSColor] = [:]

    /// SwiftUI's `opacity`: the color's own alpha times `factor`, in whatever appearance it's drawn. (`withAlphaComponent`
    /// replaces the alpha: the label colors, translucent already, came out brighter than SwiftUI drew them.)
    func opacity(_ factor: CGFloat) -> NSColor {
        let key = "\(self)/\(factor)"
        if let color = Self.faded[key] { return color }
        let base = self
        let color = NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
        Self.faded[key] = color
        return color
    }
}
