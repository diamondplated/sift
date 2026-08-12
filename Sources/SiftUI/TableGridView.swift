import AppKit
import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

// The grid. An `NSTableView` in an `NSViewRepresentable`, and every decision it makes pulled out
// into `GridBridge` below it.
//
// WHY `NSTableView` AND NOT SwiftUI's `Table` (design spec §9). `Table` wants a
// `RandomAccessCollection` of every row; this grid's rows arrive 500 at a time out of a bounded
// cache and there may be 2.5 million of them. `NSTableView` asks its data source only for the rows
// that are on screen, which is also what removes the web build's scroll-height workaround —
// browsers clamp element height around 17.8M px, and the row↔pixel mapping broke *silently* past
// ~800k rows.
//
// WHY THE SPLIT. `NSViewRepresentable` cannot be rendered by `ImageRenderer` (measured on this
// branch: SwiftUI returns its prohibited-symbol placeholder), so anything inside `makeNSView` /
// `updateNSView` has no automated check at all and is verified by hand, once, by a human looking at
// a window. `GridBridge` is a plain `NSObject` that can be built in a test without one, so every
// decision lives there and the representable is left holding only wiring. If something here starts
// wanting a test, it is in the wrong type.

/// Matches the shell's `--row-h: 27px` (`web/index.html:112`). The scroll↔row mapping is computed
/// from this, so it and the table view's `rowHeight` are the same number by construction.
public let gridRowHeight: CGFloat = 27

/// The row-number gutter's floor — `.rownum { width: 62px }` (`web/index.html:192`). A floor rather
/// than the width, because 62 is not enough past ~100k rows; see `GridBridge.gutterWidth()`.
private let minimumGutterWidth: CGFloat = 62

/// `.rownum { font-size: 10.5px; font-family: ui-monospace }`. Shared, because the gutter's width is
/// measured from the same font the gutter draws with — two copies is how it stops fitting.
///
/// Computed rather than a stored global: an `NSFont` is not `Sendable`, so a global `let` is a hard
/// error in Swift 6 mode. AppKit caches the lookup, so this costs nothing per call.
@MainActor
var gutterFont: NSFont { .monospacedSystemFont(ofSize: 10.5, weight: .regular) }

/// Identifier of the gutter column. Data columns are identified by ordinal (`c0`, `c1`, …) rather
/// than by name: DuckDB will happily return two columns called `id`, and a name-keyed identifier
/// would hand both of them the same cells.
private let gutterID = NSUserInterfaceItemIdentifier("__rownum__")

// MARK: - which of the four things the pane is showing

/// The web's `renderGrid` fan-out (`web/index.html:660-666`), as a value.
///
/// Lives here rather than inside `RootView`'s body because it is a decision with edges and a body
/// cannot be tested. The fourth state — nothing open at all — is not in here: it is decided by
/// there being no table to have a view model for, which `RootView` already branches on.
public enum GridState: Equatable {
    case noColumns
    case noRows
    case rows
}

/// Takes the three numbers rather than the model, so every branch is reachable in a test. A table
/// with zero columns cannot be produced from a real file, and a branch a test cannot reach is a
/// branch nobody has ever run.
///
/// 🔴 `rowCountKnown` is why this is not just `scrollExtent == 0`. A multi-GB CSV mid-count has no
/// row number *yet* and its extent reads 0 — telling that user "no rows match the current filters"
/// would be the grid inventing a fact about a file it has not finished reading. Pass
/// `table.displayRows != nil`.
public func gridState(columnCount: Int, scrollExtent: Int, rowCountKnown: Bool) -> GridState {
    if columnCount == 0 { return .noColumns }
    if scrollExtent == 0, rowCountKnown { return .noRows }
    return .rows
}

// MARK: - the representable

/// The virtualized grid for one open table.
///
/// Give it an `.id(model.name)` at the call site. `NSViewRepresentable` reuses its coordinator for
/// the lifetime of one view identity, and the coordinator holds the model.
public struct TableGridView: NSViewRepresentable {
    private let model: TableViewModel
    private let onColumnSelected: ((String) -> Void)?
    private let onError: ((String) -> Void)?

    /// Both closures default to `nil` so the existing call site keeps compiling. `onColumnSelected`
    /// is where a plain header click lands once there is an inspector to select a column *in* (Task
    /// 8); `onError` is where a failed sort goes, and leaving it unwired means a shift-click that
    /// fails does nothing visible.
    public init(
        model: TableViewModel,
        onColumnSelected: ((String) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.onColumnSelected = onColumnSelected
        self.onError = onError
    }

    public func makeCoordinator() -> GridBridge {
        let bridge = GridBridge(model: model)
        bridge.onColumnSelected = onColumnSelected
        bridge.onError = onError
        return bridge
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let bridge = context.coordinator

        let table = NSTableView(frame: .zero)
        table.rowHeight = gridRowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.headerView = NSTableHeaderView()
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = bridge
        table.delegate = bridge

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // A scroll turns into a page request. `postsBoundsChangedNotifications` is already true by
        // default on a clip view, but it is set here anyway because everything below it depends on
        // it and a default is not a contract.
        //
        // Target/selector rather than the block form on purpose, twice over: the block form's
        // observer token has to be stored and removed by hand, while this registration is
        // zeroing-weak (10.11 and later); and the block is `@Sendable`, which would mean reaching
        // this `@MainActor` bridge through `MainActor.assumeIsolated` — trading a compile-time
        // guarantee for a crash if the assumption is ever wrong.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            bridge, selector: #selector(GridBridge.clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        // 🔴 The three callbacks, installed together. `TableViewModel`'s own header caps them at
        // three for exactly this reason: a fourth installation site is where one starts getting
        // forgotten. Weak on both sides — the model outlives this view, and it is holding these
        // closures, so a strong capture of either the bridge or the table view is a cycle that
        // keeps a dead window's view tree alive.
        model.onProfileArrived = { [weak bridge, weak table] in
            guard let bridge, let table else { return }
            // Widths come from `max_len`, which only exists once the profile lands — seconds after
            // the first paint. Without this trigger every column sits on the 120-pt fallback
            // forever even though the numbers to do better arrived long ago.
            bridge.sync(table)
        }
        model.onBlockDelivered = { [weak bridge, weak table] block in
            guard let bridge, let table else { return }
            bridge.blockArrived(block, in: table)
        }
        model.onViewportReset = { [weak bridge, weak table, weak scroll] in
            guard let bridge, let table, let scroll else { return }
            // A spec change is `resetGrid()` (`web/index.html:585-592`), not a re-request of
            // wherever the thumb happened to be: a filter that cuts 1,000,000 rows to 12 leaves it
            // parked past the end of the data.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            bridge.sync(table)
        }

        bridge.sync(table)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        // Idempotent, and guarded by the stamp inside: columns are rebuilt only when they actually
        // changed identity or a profile arrived, because rebuilding them unconditionally throws
        // away the scroll position on every SwiftUI update.
        context.coordinator.sync(table)
    }
}

// MARK: - every decision the representable delegates

/// The data source and delegate, and the only testable half of this file.
@MainActor
public final class GridBridge: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// What a rebuild is keyed on. Two triggers, not one: the columns themselves changing (a SQL
    /// query returning a different shape, a staged swap), and a profile landing — because widths
    /// are derived from `max_len` and there is no profile at first paint.
    struct ColumnStamp: Equatable {
        let columns: [String]
        let profiled: Bool
    }

    public let model: TableViewModel

    /// A plain click on a header. The web set `state.col` and switched the inspector to its Column
    /// tab; there is no inspector on this branch yet, so this is the seam it lands on when Task 8
    /// builds one — passed in from `TableGridView.init`, and `nil` until then.
    public var onColumnSelected: ((String) -> Void)?
    /// Where a failed sort goes. `setSort` runs in a detached `Task`, so there is no caller left to
    /// throw back to; without this the user's shift-click would simply do nothing, which is the
    /// silent failure this app exists to be the opposite of.
    public var onError: ((String) -> Void)?

    private var stamp: ColumnStamp?
    private var builtExtent = -1

    public init(model: TableViewModel) {
        self.model = model
        super.init()
    }

    // MARK: - data source

    public func numberOfRows(in tableView: NSTableView) -> Int { model.scrollExtent }

    // MARK: - columns

    var columnStamp: ColumnStamp {
        ColumnStamp(
            columns: model.columns.map { "\($0.name)\u{1}\($0.type)" },
            profiled: !model.profile.isEmpty
        )
    }

    /// Column widths, in model-column order. The arithmetic is `ColumnLayout.columnWidths`, which is
    /// where every decision this header makes lives; this is the model-shaped call of it.
    func columnWidths() -> [CGFloat] {
        SiftUI.columnWidths(model.columns, profile: model.profile).map { CGFloat($0) }
    }

    /// The profile for one column, by name. `nil` before a profile has landed — which is a different
    /// thing from "all zero", and `headerDecoration` treats it as such.
    func profile(for name: String) -> ColumnProfile? {
        model.profile.first { $0.name == name }
    }

    /// Rebuild the table's columns if — and only if — they changed identity or a profile arrived.
    /// Returns whether it did anything, which is the whole assertion `GridBridgeTests` makes about
    /// the second trigger.
    @discardableResult
    func syncColumns(_ tableView: NSTableView) -> Bool {
        let next = columnStamp
        guard stamp != next else { return false }
        stamp = next

        // 🔴 MEASURED: `style = .plain` leaves `intercellSpacing.width` at SEVENTEEN points. Every
        // column then occupies 17 pt more than the width `columnWidths` computed for it; the cell
        // views are centred in that slot while the header cell is handed the whole of it, so the
        // header name sat 8.5 pt to the left of its own column's values and a full-width missing bar
        // ran a quarter of the way into the next column. The web grid's cells are flush
        // (`.gcell { flex:none; padding:2px 7px }`, no margin) and these widths are ported from it,
        // so the gap is zero and a column is exactly as wide as it was measured to be.
        //
        // Set here rather than in `makeNSView` for the usual reason: `makeNSView` cannot be tested,
        // and a header that lines up only in the shipping app is a header nothing checks.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        let gutter = NSTableColumn(identifier: gutterID)
        // A `SiftHeaderCell` with nothing in it, rather than the stock `NSTableHeaderCell`: the
        // custom cell paints its own background and hairlines, so a stock neighbour over the gutter
        // would be the one square of the header wearing the system's chrome instead.
        gutter.headerCell = SiftHeaderCell(textCell: "")
        gutter.title = ""
        gutter.width = gutterWidth()
        gutter.minWidth = minimumGutterWidth
        gutter.maxWidth = 200
        tableView.addTableColumn(gutter)

        let widths = columnWidths()
        for (i, column) in model.columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            let header = SiftHeaderCell(textCell: column.name)
            header.typeText = column.type
            col.headerCell = header
            col.title = column.name
            col.width = widths[i]
            col.minWidth = 40
            col.maxWidth = 2000
            tableView.addTableColumn(col)
        }
        syncHeaders(tableView)
        return true
    }

    /// Push the caret, the distinct count and the missing bar onto the header cells, and say whether
    /// any of them moved.
    ///
    /// Separate from `syncColumns` and called on every `sync`, because the three of them change on
    /// triggers the column stamp deliberately does not carry. A sort click changes nothing about the
    /// columns' identity — same names, same types — so a caret that only appeared on a rebuild would
    /// never appear at all. Rebuilding the columns instead would work and would also throw away
    /// every column's user-dragged width on every sort.
    ///
    /// `Equatable` on `HeaderDecoration` is what makes this cheap enough to run unconditionally: a
    /// scroll tick reaches here and finds nothing changed.
    @discardableResult
    func syncHeaders(_ tableView: NSTableView) -> Bool {
        let sort = model.table.qspec.sort
        var changed = false
        for (i, column) in model.columns.enumerated() {
            let at = i + 1  // the gutter is column 0
            guard at < tableView.tableColumns.count,
                let header = tableView.tableColumns[at].headerCell as? SiftHeaderCell
            else { continue }
            let profile = profile(for: column.name)
            let next = headerDecoration(column, profile: profile, sort: sort)
            if header.decoration != next {
                header.decoration = next
                changed = true
            }
            // Not part of `changed`: a tooltip is not drawn, so it can never be the reason to
            // repaint. It is refreshed here anyway because the counts in it come from the same
            // profile the decoration does.
            tableView.tableColumns[at].headerToolTip = headerTooltip(column, profile: profile)
        }
        return changed
    }

    /// Reload when the number of rows the scroll bar may reach changed. Separate from the column
    /// rebuild because the two move independently — an exact count landing changes the extent and
    /// nothing else.
    @discardableResult
    func syncExtent(_ tableView: NSTableView) -> Bool {
        guard builtExtent != model.scrollExtent else { return false }
        builtExtent = model.scrollExtent
        return true
    }

    /// Wide enough for the largest ordinal this table will ever draw, floored at the web's 62.
    ///
    /// 🔴 MEASURED, and the reason this is not just the constant: at 120,000 rows a flat 62 pt
    /// truncated `119,974` to `119,9…`. A row number that is wrong on screen, in the one column
    /// whose entire job is being right about which row you are looking at. (The web has the same
    /// 62 px and clips mid-glyph instead of eliding, which is not better.)
    func gutterWidth() -> CGFloat {
        let widest = groupDigits(String(max(1, model.scrollExtent))) as NSString
        let measured = widest.size(withAttributes: [.font: gutterFont]).width
        // 14 for the cell's own 7-pt padding either side, and 4 more for `NSTextFieldCell`'s
        // internal inset — MEASURED, because the text width alone is not the threshold: `119,974`
        // measures 45.4 pt and elides inside a 48-pt label. `theGutterIsWideEnoughFor…` asserts on
        // AppKit's own `expansionFrame`, so an allowance that is one point short goes red rather
        // than shipping a truncated row number again.
        return max(minimumGutterWidth, (measured + 18).rounded(.up))
    }

    func sync(_ tableView: NSTableView) {
        let columnsChanged = syncColumns(tableView)
        // After the rebuild, and unconditionally: a sort click leaves the columns identical and is
        // the one thing that must still repaint a caret.
        if syncHeaders(tableView) || columnsChanged {
            tableView.headerView?.needsDisplay = true
        }
        let extentChanged = syncExtent(tableView)
        // The extent is what the gutter is measured from, and it moves on its own — an exact count
        // landing behind a byte-sample estimate can add a digit without touching the columns.
        if extentChanged, let gutter = tableView.tableColumns.first,
            gutter.identifier == gutterID {
            gutter.width = gutterWidth()
        }
        if columnsChanged || extentChanged { tableView.reloadData() }
    }

    // MARK: - blocks

    /// The rows one delivered block covers, clamped to the extent. Clamped rather than trusted:
    /// the last block of a 1,200-row table holds 200 rows, and handing `reloadData` a range past
    /// the end is an out-of-bounds exception, not a no-op.
    func rows(inBlock block: Int) -> IndexSet {
        let lower = max(0, block * pageRows)
        let upper = min(lower + pageRows, model.scrollExtent)
        guard upper > lower else { return IndexSet() }
        return IndexSet(integersIn: lower..<upper)
    }

    func blockArrived(_ block: Int, in tableView: NSTableView) {
        // `deliver` sets `columns` from the page immediately before firing this, so a SQL query
        // that changed shape is picked up here rather than waiting for SwiftUI to notice.
        sync(tableView)
        let rows = rows(inBlock: block)
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: - the viewport

    /// Which rows a visible rectangle covers. The web's `firstRow = scrollTop / ROW_H` and
    /// `visibleRows = ceil(clientHeight / ROW_H)` (`web/index.html:593`).
    ///
    /// 🔴 This is the reason the grid is an `NSTableView`: the model is asked for *this* window plus
    /// its overscan, and never for the whole table. A version of this that returned the full extent
    /// would still draw correctly and would pull 2.5M rows through a 500-row cache to do it.
    static func viewport(_ rect: CGRect, rowHeight: CGFloat) -> (firstRow: Int, rowsOnScreen: Int) {
        guard rowHeight > 0 else { return (0, 1) }
        return (
            max(0, Int((rect.minY / rowHeight).rounded(.down))),
            max(1, Int((rect.height / rowHeight).rounded(.up)))
        )
    }

    func scrolled(to rect: CGRect) {
        let window = Self.viewport(rect, rowHeight: gridRowHeight)
        model.ensureVisible(firstRow: window.firstRow, rowsOnScreen: window.rowsOnScreen)
    }

    @objc func clipViewBoundsChanged(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        scrolled(to: clip.documentVisibleRect)
    }

    // MARK: - delegate: one cell

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let cell = reuse(tableColumn.identifier, in: tableView)

        if tableColumn.identifier == gutterID {
            // 🔴 The ENGINE's grouping, not a loop here. `SiftCore.groupDigits` takes a string and
            // never parses it, which is why a row ordinal and a BIGINT cell agree; this branch is
            // the third place on this rewrite that wanted its own copy and the third that does not
            // get one. (And it is not `NumberFormatter`: without an explicit locale the same
            // ordinal renders four ways.)
            cell.showOrdinal(groupDigits(String(row + 1)))
            return cell
        }
        guard let index = dataColumnIndex(tableColumn, in: tableView),
            index < model.columns.count
        else { return cell }

        let column = model.columns[index]
        guard case .loaded(let cells) = model.rowSlot(at: row), index < cells.count else {
            // Not "empty" and not "null" — a bar that reads as *coming*. The web's shimmer keyframes
            // are dropped: a static bar says the same thing, costs nothing, and needs no
            // `prefers-reduced-motion` special case (which the web version did have to write).
            cell.showSkeleton(kind: column.kind)
            return cell
        }
        // 🔴 `glyph(for:kind:)`, never `Cell.display`. `display` renders `.null` and `.text("")`
        // identically, collapsing two of the three states design spec §9 calls non-negotiable. The
        // case is what picks the styling; the string is the engine's, shared with the `sift` CLI.
        cell.show(glyph(for: cells[index], kind: column.kind), kind: column.kind)
        cell.toolTip = tooltip(for: cells[index])
        return cell
    }

    private func reuse(_ id: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> GridCellView
    {
        if let existing = tableView.makeView(withIdentifier: id, owner: self) as? GridCellView {
            return existing
        }
        let fresh = GridCellView(frame: .zero)
        fresh.identifier = id
        return fresh
    }

    /// Position, not name: two columns may share a name, and `identifier` is only unique because it
    /// was built from the ordinal in the first place.
    private func dataColumnIndex(_ column: NSTableColumn, in tableView: NSTableView) -> Int? {
        guard let at = tableView.tableColumns.firstIndex(where: { $0 === column }), at > 0 else {
            return nil
        }
        return at - 1
    }

    // MARK: - delegate: a click on a header

    /// 🔴 The modifier flags are read HERE and nowhere below, because this is the only place they
    /// exist. `tableView(_:mouseDownInHeaderOf:)` hands over the column and not the event, so the
    /// shift key has to come off `NSApp.currentEvent` — and `NSApp` is exactly the kind of ambient
    /// global that makes a decision untestable. So this method reads the one bit and hands it to
    /// `headerClicked`, which is where the decision is and which the suite drives directly.
    public func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        guard let index = dataColumnIndex(tableColumn, in: tableView),
            index < model.columns.count
        else { return }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        headerClicked(model.columns[index].name, shift: shift)
    }

    /// Plain click opens the column; shift-click sorts. The web build's binding, and the reason its
    /// header tooltip ends `click: values · shift-click: sort` (`web/index.html:617`) — nobody
    /// guesses this one.
    ///
    /// It is this way round rather than the more obvious click-to-sort because a sort on a file this
    /// app is built for is not free: `Table.scrollableRows` caps a sorted table at what the engine
    /// materialized, so an accidental sort of a 40M-row Parquet is a visible, expensive thing to
    /// have done by brushing the header on the way to the scrollbar.
    func headerClicked(_ column: String, shift: Bool) {
        guard shift else {
            onColumnSelected?(column)
            return
        }
        let next = nextSort(for: column, current: model.table.qspec.sort)
        Task { [weak self] in
            guard let self else { return }
            do { try await model.setSort(next) } catch { onError?(error.localizedDescription) }
        }
    }
}

// MARK: - one cell's view

/// One grid cell: a label, or a skeleton bar while its block is in flight.
///
/// Frames rather than constraints, and one view class rather than two: this is built and rebuilt for
/// every visible cell on every scroll tick, and a per-cell Auto Layout pass is the thing that makes
/// an `NSTableView` feel like a web grid.
final class GridCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    /// `NSBox`, not a layer-backed `NSView`: a `CGColor` baked from a dynamic `NSColor` does not
    /// follow a light↔dark switch, and `NSBox.fillColor` does.
    private let bar = NSBox(frame: .zero)
    private var barFraction: CGFloat = 0.70
    private var barTrailing = false
    /// Whether this cell is drawing the empty-string rule. Read by the suite; see `draw(_:)`.
    private(set) var showsEmptyMarker = false
    private var emptyMarkerAlignment: NSTextAlignment = .left

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        addSubview(label)

        bar.boxType = .custom
        bar.titlePosition = .noTitle
        bar.borderWidth = 0
        bar.cornerRadius = 4
        bar.fillColor = .quaternaryLabelColor
        bar.isHidden = true
        addSubview(bar)

        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GridCellView is never unarchived") }

    override func layout() {
        super.layout()
        // `.gcell { padding: 2px 7px }` (`web/index.html:180`).
        let inset: CGFloat = 7
        let width = max(0, bounds.width - inset * 2)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: inset, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        let barWidth = (width * barFraction).rounded()
        bar.frame = NSRect(
            x: barTrailing ? bounds.width - inset - barWidth : inset,
            y: ((bounds.height - 8) / 2).rounded(), width: barWidth, height: 8)
    }

    /// `.empt { min-width: 22px }` — wide enough to read as a value that is deliberately nothing.
    private let emptyMarkerWidth: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsEmptyMarker else { return }
        let inset: CGFloat = 7
        let x: CGFloat
        switch emptyMarkerAlignment {
        case .right: x = bounds.width - inset - emptyMarkerWidth
        case .center: x = ((bounds.width - emptyMarkerWidth) / 2).rounded()
        default: x = inset
        }
        // Under where the text baseline would be, so it lines up with the values above and below
        // rather than floating in the middle of the row.
        let y = (bounds.height / 2 - 5).rounded() + 0.5
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: x, y: y))
        rule.line(to: NSPoint(x: x + emptyMarkerWidth, y: y))
        rule.lineWidth = 1
        rule.setLineDash([1, 2], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        rule.stroke()
    }

    func showOrdinal(_ text: String) {
        bar.isHidden = true
        label.isHidden = false
        showsEmptyMarker = false
        needsDisplay = true
        label.alignment = .right
        label.font = gutterFont
        label.textColor = .tertiaryLabelColor
        label.stringValue = text
        toolTip = nil
        needsLayout = true
    }

    func showSkeleton(kind: Kind) {
        label.isHidden = true
        label.stringValue = ""
        showsEmptyMarker = false
        needsDisplay = true
        bar.isHidden = false
        // `.gcell.skel i { width: 70% }`, and `.skel.n i { margin-left:auto; width:52% }` — a number
        // column's placeholder sits where its digits will (`web/index.html:219-221`).
        barFraction = kind == .number ? 0.52 : 0.70
        barTrailing = kind == .number
        toolTip = nil
        needsLayout = true
    }

    func show(_ glyph: CellGlyph, kind: Kind) {
        bar.isHidden = true
        label.isHidden = false
        showsEmptyMarker = false
        needsDisplay = true
        label.alignment = alignment(for: kind)
        let font = self.font(for: kind)
        label.font = font
        label.textColor = .labelColor

        switch glyph {
        case .null:
            // `.gcell .nul { font-style: italic; color: var(--ink-3) }` (`web/index.html:188`).
            label.attributedStringValue = NSAttributedString(
                string: SiftEngine.nullGlyph,
                attributes: [.font: italic(font), .foregroundColor: NSColor.tertiaryLabelColor])
        case .empty:
            // 🔴 `.gcell .empt { min-width: 22px; border-bottom: 1px dotted }` — and the comment
            // above it in the stylesheet: "NULL and empty string MUST look different — that
            // distinction is why people open this tool." The rule is DRAWN (see `draw(_:)`) rather
            // than spelled as an underlined run of spaces, because AppKit will not draw an
            // underline under a whitespace-only run. MEASURED, all four ways round: ordinary spaces
            // and non-breaking spaces, `usesSingleLineMode` on and off, `allowsEditingTextAttributes`
            // on, dotted pattern and plain single — every one of them renders an empty cell, while
            // the identical attributes over the letters `xxx` underline correctly. The first version
            // of this shipped as the attributed string and looked, on screen, exactly like a cell
            // that had failed to render.
            label.stringValue = ""
            showsEmptyMarker = true
            emptyMarkerAlignment = label.alignment
        case .bool(let value):
            label.stringValue = value ? "true" : "false"
            // `.tru`/`.fal` — a false reads as absence, a true as a fact.
            label.textColor = value ? .systemGreen : .tertiaryLabelColor
        case .text(let value):
            label.stringValue = value
        case .number(let value):
            label.stringValue = value
        }
        needsLayout = true
    }

    /// `cellClass` (`web/index.html:513`): alignment comes from the COLUMN's kind, never from
    /// whether this particular value parsed — so an `N/A` in a number column still lines up under
    /// the digits above it.
    private func alignment(for kind: Kind) -> NSTextAlignment {
        switch kind {
        case .number, .temporal: return .right
        case .bool: return .center
        default: return .left
        }
    }

    private func font(for kind: Kind) -> NSFont {
        switch kind {
        case .number: return .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .temporal, .bool: return .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .nested, .blob: return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .text, .other: return .systemFont(ofSize: 12)
        }
    }

    private func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

// MARK: - one column header

/// One column header: the name on the first line, the type with its sort caret and distinct count on
/// the second, and a bar along the bottom edge for how much of the column is missing.
///
/// **Why a cell subclass and not a custom `NSTableHeaderView`.** Replacing the header view means
/// re-implementing column hit-testing, drag-to-resize and the divider tracking areas — all of which
/// AppKit already does correctly and none of which this design changes. An `NSTableHeaderCell` per
/// column gets the two-line layout for the price of one `draw(withFrame:in:)`.
///
/// 🔴 It decides NOTHING. Every value it draws is computed by `ColumnLayout` and handed over as a
/// `HeaderDecoration`, because an `NSCell` draws into a context and has no state afterwards to
/// assert on. What is left here is geometry, and the suite checks that by rendering it.
final class SiftHeaderCell: NSTableHeaderCell {
    /// The column's SQL type, drawn under the name. Not `stringValue` — that stays the name, because
    /// `NSTableColumn.title` is a proxy for it and the rest of the app reads titles.
    var typeText = ""
    var decoration = HeaderDecoration(caret: nil, distinctLabel: "", missingFraction: 0)

    /// `.hcell .hn { font-weight:700; font-size:11.5px }`.
    private var nameFont: NSFont { .systemFont(ofSize: 11.5, weight: .bold) }
    /// `.hcell .ht`/`.dcount { font-size:9px; font-family:ui-monospace }`. Monospaced so the distinct
    /// counts down a wide table line up with each other instead of wandering.
    private var metaFont: NSFont { .monospacedSystemFont(ofSize: 9, weight: .regular) }
    /// `letter-spacing:.06em` on a 9 pt uppercase run — without it `VARCHAR` sets as a grey smudge.
    private var metaKern: CGFloat { 0.54 }
    /// `.hcell { padding: 3px 7px }`, and the same 7 the cells below use, so a header sits over its
    /// own column's values rather than 2 pt off them.
    private let inset: CGFloat = 7
    /// `.hcell .hbar { height:2px }`.
    private let barHeight: CGFloat = 2

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // NOT `super.draw`: the superclass paints the system header chrome *and* `stringValue`, and
        // the name would then be drawn twice — once by AppKit, vertically centred, and once here.
        let flipped = controlView.isFlipped
        NSColor.windowBackgroundColor.setFill()
        cellFrame.fill()
        NSColor.separatorColor.setFill()
        // `.ghead { border-bottom: 1px solid var(--line) }`, plus the divider between columns. The
        // divider is what makes a 0-width missing bar readable as "nothing missing" rather than as
        // the neighbouring column's bar running long.
        band(cellFrame, fromTop: cellFrame.height - 1, height: 1, flipped: flipped).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()

        let box = layout(cellFrame, flipped: flipped)
        guard box.name.width > 0 else { return }
        drawNameLine(in: box.name)
        drawMetaLine(in: box.meta)

        if decoration.missingFraction > 0 {
            // `.hbar.nul { background: var(--stale); opacity:.55 }` — the amber the whole app uses
            // for "stale/incomplete", and a system colour rather than the web's literal #b07d1e so
            // it follows a light↔dark switch.
            NSColor.systemOrange.withAlphaComponent(0.55).setFill()
            var bar = box.bar
            bar.size.width = (cellFrame.width * decoration.missingFraction).rounded()
            bar.fill()
        }
    }

    /// The name, then its sort caret immediately after it.
    ///
    /// 🔴 The caret is on THIS line, beside the name, and not down on the type line. `.hn` is a flex
    /// row with `gap: 3px` (`web/index.html:618-620`), so the caret follows the text rather than
    /// sitting against the right edge — and, measured, putting it on the second line cost about
    /// 12 pt there and truncated a sorted `BIGINT` column at the 76-pt width floor to `BIG…`. The
    /// name line has the room (the width formula sizes for the name and then floors at 76) and the
    /// type line does not.
    private func drawNameLine(in rect: NSRect) {
        guard let caret = decoration.caret else {
            draw(stringValue, font: nameFont, color: .labelColor, in: rect)
            return
        }
        let caretWidth = measure(caret, font: metaFont)
        let forName = NSRect(
            x: rect.minX, y: rect.minY, width: max(0, rect.width - caretWidth - 3),
            height: rect.height)
        draw(stringValue, font: nameFont, color: .labelColor, in: forName)
        // `align-items: center` — but aligned on the BASELINE rather than the box, because a 9 pt
        // triangle centred in a 14 pt line box floats visibly above the name's own baseline.
        let drop = (nameFont.ascender - metaFont.ascender).rounded()
        // Immediately after the text, not at the far edge: a caret parked against the right edge of
        // a 320 pt column reads as belonging to whatever is under it.
        let x = forName.minX + min(measure(stringValue, font: nameFont), forName.width) + 3
        // `.hcell .caret { color: var(--accent) }` — the one accent-coloured thing in the header,
        // because it is the only part of it that reflects something the user did.
        draw(caret, font: metaFont, color: .controlAccentColor,
             in: NSRect(x: x, y: rect.minY + drop, width: caretWidth, height: rect.height - drop))
    }

    /// Type on the left, distinct count against the right edge.
    ///
    /// Two draws rather than one right-aligned paragraph because they are different colours — and
    /// because the type's truncation width is whatever the count leaves behind. A type that ran
    /// under the count would put `VARC…` and `≈4.2k` on top of each other.
    private func drawMetaLine(in rect: NSRect) {
        if !decoration.distinctLabel.isEmpty {
            let width = measure(decoration.distinctLabel, font: metaFont)
            draw(decoration.distinctLabel, font: metaFont, color: .tertiaryLabelColor,
                 in: NSRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
        }
        let forType = typeRect(in: rect)
        guard forType.width > 0 else { return }
        // `text-transform: uppercase`. `uppercased()` and not `uppercased(with:)` — the locale-aware
        // one turns a Turkish `i` into `İ`, and these are DuckDB type names.
        draw(typeText.uppercased(), font: metaFont, color: .tertiaryLabelColor, in: forType,
             kern: metaKern)
    }

    // MARK: - geometry

    /// The three bands of the header, with the text ones already inset.
    ///
    /// Anchored from the BOTTOM — the type line sits on the bar, the name takes what is left — so
    /// the layout fits whatever height AppKit gives the header (28 pt, measured) rather than
    /// assuming one. The bar's two points are reserved whether or not there is a bar, so a profile
    /// landing does not shunt every type line up by two points at once. `max(0,)` because a header
    /// shorter than its own two lines must overlap rather than draw the name off the top edge;
    /// `theHeaderPaintsBothOfItsLines…` is what stops that from being something anyone sees.
    ///
    /// Returned rather than computed inside `draw` so the suite can ask where a line will land
    /// without a bitmap — `theTypeSurvivesAtTheWidthFloorOfASortedColumn` measures against these.
    func layout(_ cellFrame: NSRect, flipped: Bool) -> (name: NSRect, meta: NSRect, bar: NSRect) {
        let nameHeight = lineHeight(nameFont)
        let metaHeight = lineHeight(metaFont)
        let metaTop = cellFrame.height - 1 - barHeight - metaHeight
        let nameTop = max(0, (metaTop - nameHeight) / 2).rounded()
        return (
            band(cellFrame, fromTop: nameTop, height: nameHeight, flipped: flipped)
                .insetBy(dx: inset, dy: 0),
            band(cellFrame, fromTop: metaTop, height: metaHeight, flipped: flipped)
                .insetBy(dx: inset, dy: 0),
            band(cellFrame, fromTop: cellFrame.height - 1 - barHeight, height: barHeight,
                 flipped: flipped)
        )
    }

    /// The type's share of the second line: everything the distinct count did not take.
    ///
    /// No gap between the two. There was a 4 pt one, invented here — the web floats the count right
    /// *inside* the type's own element (`.dcount { float:right }`), so the type runs up to it and
    /// `.ht`'s `text-overflow: ellipsis` does the rest. Those 4 points are the difference between
    /// `BIGINT` and `BIG…` in a 76 pt column, which is a bad trade for whitespace nobody asked for.
    ///
    /// Not `private`, because "does `BIGINT` still fit here" is the assertion that moved the caret
    /// off this line in the first place.
    func typeRect(in rect: NSRect) -> NSRect {
        guard !decoration.distinctLabel.isEmpty else { return rect }
        let taken = measure(decoration.distinctLabel, font: metaFont)
        return NSRect(
            x: rect.minX, y: rect.minY, width: rect.width - taken, height: rect.height)
    }

    /// A band `fromTop` points down from the top edge. Everything above is expressed this way so the
    /// layout reads top-to-bottom the way it looks; `NSTableHeaderView` is flipped, and the
    /// `flipped` argument is what keeps this honest if it is ever drawn into a context that is not.
    private func band(_ f: NSRect, fromTop: CGFloat, height: CGFloat, flipped: Bool) -> NSRect {
        NSRect(
            x: f.minX, y: flipped ? f.minY + fromTop : f.maxY - fromTop - height,
            width: f.width, height: height)
    }

    func lineHeight(_ font: NSFont) -> CGFloat { (font.ascender - font.descender + font.leading).rounded(.up) }

    func measure(_ text: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width.rounded(.up)
    }

    private func draw(
        _ text: String, font: NSFont, color: NSColor, in rect: NSRect, kern: CGFloat = 0
    ) {
        let style = NSMutableParagraphStyle()
        // A header too narrow for its own name elides it rather than spilling into the next column.
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern,
            ])
    }
}
