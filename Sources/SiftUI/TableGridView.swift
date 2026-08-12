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

    public init(model: TableViewModel) {
        self.model = model
    }

    public func makeCoordinator() -> GridBridge { GridBridge(model: model) }

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

    /// Column widths, in model-column order — `computeWidths` (`web/index.html:576-583`), rule for
    /// rule. The `120` is the pre-profile fallback and the reason a profile has to force a rebuild:
    /// every column sits on it until `max_len` exists.
    func columnWidths() -> [CGFloat] {
        var maxLens: [String: Int] = [:]
        for column in model.profile where (column.maxLen ?? 0) > 0 {
            maxLens[column.name] = column.maxLen
        }
        return model.columns.map { column in
            let byName = Double(column.name.count) * 7.6 + 26
            let byData = maxLens[column.name].map { Double(min($0, 42)) * 7.4 + 20 } ?? 120
            return CGFloat(max(76, min(320, max(byName, byData))).rounded())
        }
    }

    /// Rebuild the table's columns if — and only if — they changed identity or a profile arrived.
    /// Returns whether it did anything, which is the whole assertion `GridBridgeTests` makes about
    /// the second trigger.
    @discardableResult
    func syncColumns(_ tableView: NSTableView) -> Bool {
        let next = columnStamp
        guard stamp != next else { return false }
        stamp = next

        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        let gutter = NSTableColumn(identifier: gutterID)
        gutter.title = ""
        gutter.width = gutterWidth()
        gutter.minWidth = minimumGutterWidth
        gutter.maxWidth = 200
        tableView.addTableColumn(gutter)

        let widths = columnWidths()
        for (i, column) in model.columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            col.title = column.name
            col.width = widths[i]
            col.minWidth = 40
            col.maxWidth = 2000
            col.headerToolTip = "\(column.name) — \(column.type)"
            tableView.addTableColumn(col)
        }
        return true
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
