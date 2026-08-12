import AppKit
import DuckDBKit
import Foundation
import SiftCore
import Testing
@testable import SiftEngine
@testable import SiftUI

// The grid's automated coverage, in full.
//
// `TableGridView` is an `NSViewRepresentable`; `ImageRenderer` refuses to render one (measured on
// this branch: SwiftUI hands back its prohibited-symbol placeholder), so there is no visual check of
// it at any layer and its correctness was verified by a human looking at a window, once. What CAN be
// tested is `GridBridge`, a plain `NSObject` that needs no window — so every decision the grid makes
// lives there, and everything below drives it directly.
//
// Nothing here asserts on a `Task` immediately after spawning it: a `Task {}` created on the
// MainActor cannot start before the next suspension point, so "the work is in flight" is not
// observable by construction. Every background assertion drains the pump or polls for a real signal.

/// AppKit's appearance system wants an app object to exist before any `NSView` is constructed, even
/// headlessly. Idempotent, and every test here calls it first.
@MainActor
private func appKitReady() { _ = NSApplication.shared }

// MARK: - the extent

@MainActor
@Test func theGridAsksForTheCappedExtentAndNotTheRawRowCount() async throws {
    appKitReady()
    let view = NSTableView(frame: .zero)
    let (_, model) = try await openedFixture(rows: 1_200)
    let bridge = GridBridge(model: model)
    #expect(bridge.numberOfRows(in: view) == 1_200)
    #expect(bridge.syncExtent(view), "the first build")
    #expect(!bridge.syncExtent(view), "…and no reload while the extent stands still")

    // Not a restatement of `scrollExtent`: this is the assertion that would have caught the grid
    // promising 100M rows for a sorted table. Force the capped case through the same path.
    model.overrideScrollExtentForTest(sortMaterializeMax)
    #expect(bridge.numberOfRows(in: view) == sortMaterializeMax)
    // An exact count landing behind a byte-sample estimate moves the extent and nothing else, so
    // this is a separate trigger from the column rebuild rather than a second name for it.
    #expect(bridge.syncExtent(view), "an extent that moved is a reload")
}

// MARK: - the three states, and the fourth thing that is none of them

@MainActor
@Test func aPendingRowIsDistinctFromARowOfNullsAndBecomesLoadedWhenItsBlockArrives() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 1_200)

    // Block 0 is already in from `openedFixture`, so `.loaded` is genuinely reachable — a test that
    // only asserted `.pending` would pass if `rowSlot` always returned `.pending`.
    #expect(model.rowSlot(at: 0) != .pending)
    #expect(model.rowSlot(at: 1_100) == .pending)

    model.ensureVisible(firstRow: 1_090, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.rowSlot(at: 1_100) != .pending)

    // The fixture's `note` column carries a real NULL (row 0, a bare empty field), a real '' (row 1,
    // a quoted empty field — `allow_quoted_nulls=false` keeps them apart) and a literal N/A (row 2).
    // All three are loaded rows, and none of them may look like `.pending`.
    func note(_ r: Int) throws -> CellGlyph {
        guard case .loaded(let row) = model.rowSlot(at: r) else {
            Issue.record("row \(r) not loaded"); throw CancellationError()
        }
        return glyph(for: row[2], kind: .text)
    }
    #expect(try note(0) == .null)
    #expect(try note(1) == .empty)
    #expect(try note(2) == .text("N/A"))
}

/// 🔴 Design spec §9, at the last layer before a person sees it. The one above proves the *model*
/// keeps the three apart; this proves the cell the grid actually hands `NSTableView` does too. Both
/// are needed — a `CellGlyph` router that is perfect and a cell view that renders `.null` and
/// `.empty` identically collapses them just as thoroughly, and only this test would notice.
@MainActor
@Test func nullAnEmptyStringAndTheLiteralTextNAAreThreeDifferentCells() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    view.dataSource = bridge
    view.delegate = bridge
    bridge.sync(view)

    // gutter, id, label, note.
    #expect(view.tableColumns.count == 4)
    let note = view.tableColumns[3]
    func cell(_ row: Int) throws -> GridCellView {
        try #require(bridge.tableView(view, viewFor: note, row: row) as? GridCellView)
    }

    let isNull = try cell(0)
    let isEmpty = try cell(1)
    let isNA = try cell(2)

    #expect(isNull.textField?.stringValue == SiftEngine.nullGlyph)
    #expect(isNA.textField?.stringValue == "N/A")

    // 🔴 The empty string carries no text at all — its whole rendering is a 22-pt dotted rule the
    // cell DRAWS, because AppKit refuses to draw an underline under a run of spaces (measured; the
    // first version of this shipped as an attributed string and rendered a blank cell). So the
    // assertion is on the marker, not on a string, and `showsEmptyMarker` is the only thing telling
    // an empty string apart from a cell whose value simply failed to appear.
    #expect(isEmpty.textField?.stringValue == "")
    #expect(isEmpty.showsEmptyMarker, "'' is a dotted rule, which is what makes it not a null")
    #expect(!isNull.showsEmptyMarker)
    #expect(!isNA.showsEmptyMarker)

    // Read out of the attributed string, not out of `NSTextField.font` — that property keeps
    // whatever was assigned to it and does not follow an attributed value, so asserting on it would
    // have been a test of the wrong object. (It was, for one run.)
    #expect(isItalic(isNull.textField), "null is italic")
    #expect(!isItalic(isNA.textField))

    // And the tooltip says the state in words, because a text cell whose contents are literally
    // `null` renders the same as the state of the same name.
    #expect(isNull.toolTip == "null")
    #expect(isEmpty.toolTip == "empty string")
    #expect(isNA.toolTip == "N/A")
}

/// 🔴 **Rendered, not inspected.** Every other assertion in this file reads a property; this one
/// reads pixels, and it is the only kind that could have caught what actually happened: the first
/// version of the empty-string cell set an underlined attributed string, every property on the
/// object said "dotted rule", and AppKit silently declined to draw an underline under a run of
/// spaces. On screen it was a blank cell — indistinguishable from a value that had failed to render,
/// in the one place design spec §9 calls non-negotiable. Found by looking at a PNG, so the guard
/// against it looks at one too.
@MainActor
@Test func theEmptyStringCellDrawsAnActualDottedRuleAndNotAnEmptyCell() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    bridge.sync(view)
    let note = view.tableColumns[3]

    func ink(_ row: Int) throws -> [Int] {
        let cell = try #require(bridge.tableView(view, viewFor: note, row: row) as? GridCellView)
        cell.frame = NSRect(x: 0, y: 0, width: note.width, height: gridRowHeight)
        cell.layoutSubtreeIfNeeded()
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        // Columns that got any paint at all. The cell has no background, so anything opaque is
        // something this code drew.
        return (0..<rep.pixelsWide).filter { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
        }
    }

    let empty = try ink(1)
    #expect(!empty.isEmpty, "an empty string that draws nothing is a cell that failed to render")

    // Dotted, not solid: between the first and last painted column there has to be a gap. A solid
    // rule paints every column in between and reads as a filled-in value.
    let gaps = zip(empty, empty.dropFirst()).filter { $1 - $0 > 1 }
    #expect(!gaps.isEmpty, "…and it is dotted, which is what stops it reading as a solid value")

    // And the rule is a rule: it occupies a couple of rows of pixels, not the whole cell.
    let cell = try #require(bridge.tableView(view, viewFor: note, row: 1) as? GridCellView)
    cell.frame = NSRect(x: 0, y: 0, width: note.width, height: gridRowHeight)
    cell.layoutSubtreeIfNeeded()
    let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: rep)
    let paintedRows = (0..<rep.pixelsHigh).filter { y in
        (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
    }
    #expect(paintedRows.count <= 3, "a rule, not a filled box")
}

/// 🔴 `NSTableView` recycles cell views, so every branch of `show` has to undo every other one. A
/// null followed by an ordinary value in the same reused cell is the case that bites: the italic
/// font and the empty-string rule both persist unless something clears them, and the second value
/// then renders wearing the first one's styling.
@MainActor
@Test func aRecycledCellDoesNotKeepThePreviousRowsStyling() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    bridge.sync(view)
    let cell = try #require(
        bridge.tableView(view, viewFor: view.tableColumns[3], row: 0) as? GridCellView)
    #expect(isItalic(cell.textField), "row 0's note is a null")

    cell.show(.empty, kind: .text)
    #expect(cell.showsEmptyMarker)
    cell.show(.text("N/A"), kind: .text)
    #expect(!cell.showsEmptyMarker, "the rule from the previous row must not survive")
    #expect(!isItalic(cell.textField), "…nor the italic from the row before that")
    #expect(cell.textField?.stringValue == "N/A")

    // 🔴 Back to `.empty` FIRST. The obvious ordering — go straight from the `N/A` above to a
    // skeleton — asserts nothing at all, because that `show` had already cleared the marker; the
    // mutation that deletes `showsEmptyMarker = false` from `showSkeleton` survived it. The only
    // arrangement that tests the skeleton's own clear is one where the marker is set going in.
    cell.show(.empty, kind: .text)
    #expect(cell.showsEmptyMarker)
    cell.showSkeleton(kind: .text)
    #expect(cell.textField?.isHidden == true)
    #expect(!cell.showsEmptyMarker, "a skeleton clears the rule too, or it draws over the bar")
}

@MainActor
private func isItalic(_ field: NSTextField?) -> Bool {
    guard let field else { return false }
    let text = field.attributedStringValue
    guard text.length > 0,
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    else { return false }
    return font.fontDescriptor.symbolicTraits.contains(.italic)
}

/// A row whose block has not arrived is neither of the three: it is a bar that reads as *coming*.
@MainActor
@Test func aRowWhoseBlockIsStillInFlightDrawsASkeletonAndNotAValue() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 1_200)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    bridge.sync(view)
    let note = view.tableColumns[3]

    let pending = try #require(bridge.tableView(view, viewFor: note, row: 1_100) as? NSTableCellView)
    let field = try #require(pending.textField)
    #expect(field.isHidden, "a placeholder that spelled a value would be the grid making one up")
    #expect(field.stringValue.isEmpty)
    #expect(pending.toolTip == nil)

    // …and the same cell, reused, must come back once its block lands. A skeleton that is never
    // cleared is the same defect as one that never appears.
    model.ensureVisible(firstRow: 1_090, rowsOnScreen: 20)
    await model.drainForTest()
    let arrived = try #require(bridge.tableView(view, viewFor: note, row: 1_100) as? NSTableCellView)
    #expect(arrived.textField?.isHidden == false)
}

// MARK: - columns and widths

/// 🔴 The second rebuild trigger, and the reason it is not optional. Widths come from the profile's
/// `max_len`, the profile lands seconds AFTER the first paint (Task 5's `kickProfile`), and a
/// rebuild keyed only on the columns changing identity never fires again — so every column sits on
/// the 120-pt fallback forever with the numbers to do better sitting right there in the model.
@MainActor
@Test func aProfileArrivingRebuildsTheColumnsAndTakesTheWidthsOffTheFallback() async throws {
    appKitReady()
    let (_, model) = try await gridWidthFixture()
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)

    #expect(bridge.syncColumns(view), "the first build")
    #expect(!bridge.syncColumns(view), "…and nothing after it, or every scroll loses its place")
    #expect(view.tableColumns.count == 5, "the row-number gutter, plus one per column")
    #expect(view.tableColumns.dropFirst().map(\.title)
        == ["id", "description", "a_very_long_column_name_here_x", "blob"])
    #expect(bridge.columnWidths() == [120, 120, 254, 120], "no profile: the fallback, everywhere")

    #expect(await waitFor { !model.profile.isEmpty })
    #expect(bridge.syncColumns(view), "a profile is a rebuild")
    #expect(!bridge.syncColumns(view))

    // Every branch of `computeWidths` (web/index.html:576-583), and all four answers different:
    //  id     2-char values  -> 34.8 by data, 41.2 by name, floored at 76
    //  descr. 20-char values -> 168 by data, which beats its 109.6 by name
    //  30-char name          -> 254 by name, which beats its 27.4 by data
    //  blob   60-char values -> capped at 42 chars (330.8) and then clamped at 320
    #expect(bridge.columnWidths() == [76, 168, 254, 320])
    #expect(view.tableColumns.dropFirst().map(\.width) == [76, 168, 254, 320])
    #expect(view.tableColumns[0].width == 62, "the gutter is fixed — `.rownum { width: 62px }`")
}

/// The FIRST trigger, and the half of it a names-only stamp would miss: two relations whose columns
/// have identical names and different types. Alignment, font and the whole cell renderer are driven
/// by `Kind`, which comes from the type — so a grid that skipped the rebuild would go on
/// right-aligning a column that is now text, and reading its numbers through the wrong branch.
@MainActor
@Test func theColumnStampCarriesTypesAndNotJustNames() async throws {
    appKitReady()
    let state = AppState(session: try Session(home: tempHome()))
    let dir = tempDir("grid-stamp")
    try "id,label\n1,a\n2,b\n".write(
        toFile: dir.appendingPathComponent("numeric.csv").path, atomically: true, encoding: .utf8)
    try "id,label\nx,a\ny,b\n".write(
        toFile: dir.appendingPathComponent("textual.csv").path, atomically: true, encoding: .utf8)
    await state.open(path: dir.appendingPathComponent("numeric.csv").path)
    await state.open(path: dir.appendingPathComponent("textual.csv").path)

    let numeric = try #require(state.model(for: "numeric"))
    let textual = try #require(state.model(for: "textual"))
    try await numeric.loadFirstPage()
    try await textual.loadFirstPage()

    #expect(numeric.columns.map(\.name) == textual.columns.map(\.name), "same names…")
    #expect(numeric.columns[0].kind == .number && textual.columns[0].kind == .text, "…other types")
    #expect(GridBridge(model: numeric).columnStamp != GridBridge(model: textual).columnStamp)
}

// MARK: - the gutter

@MainActor
@Test func theRowNumberGutterIsGroupedByTheEnginesOwnFunction() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    bridge.sync(view)
    let gutter = view.tableColumns[0]

    func ordinal(_ row: Int) throws -> String {
        let cell = bridge.tableView(view, viewFor: gutter, row: row) as? NSTableCellView
        return try #require(cell?.textField).stringValue
    }
    // One-based, like the web's `r + 1` — row 0 of the data is row 1 to a person.
    #expect(try ordinal(0) == "1")

    // Grouped, and grouped by `SiftCore.groupDigits` rather than a fourth local loop or (worse) a
    // `NumberFormatter`, which without an explicit locale renders this four different ways.
    model.overrideScrollExtentForTest(2_500_000)
    #expect(try ordinal(999_999) == "1,000,000")
    #expect(try ordinal(2_499_999) == "2,500,000")
}

/// 🔴 A row number the gutter is too narrow to draw is a row number that is WRONG on screen, in the
/// one column whose only job is being right. MEASURED at 120,000 rows against the flat 62 pt this
/// shipped with for an hour: `119,974` rendered `119,9…`.
@MainActor
@Test func theGutterIsWideEnoughForTheLargestRowNumberItWillDraw() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    let view = NSTableView(frame: .zero)
    let bridge = GridBridge(model: model)
    bridge.sync(view)
    #expect(bridge.gutterWidth() == 62, "small tables keep the web's 62 px exactly")

    model.overrideScrollExtentForTest(120_000)
    bridge.sync(view)
    #expect(view.tableColumns[0].width > 62, "…and a six-digit table does not")

    // Not "the number is bigger" — "the text fits". Lay the real cell out at the real width and ask
    // AppKit whether it had to elide: `expansionFrame` is non-empty exactly when a cell truncated,
    // which is the same machinery that draws the "…". Comparing `intrinsicContentSize` against the
    // frame is NOT this assertion and was tried first: `119,974` measures 45.4 pt, elides inside a
    // 48-pt label, and the comparison passes anyway.
    let cell = try #require(
        bridge.tableView(view, viewFor: view.tableColumns[0], row: 119_999) as? GridCellView)
    cell.frame = NSRect(x: 0, y: 0, width: view.tableColumns[0].width, height: gridRowHeight)
    cell.layoutSubtreeIfNeeded()
    let label = try #require(cell.textField)
    #expect(label.stringValue == "120,000")
    #expect(truncated(label) == false, "…without eliding it")
}

/// AppKit's own answer to "did this cell have to draw an ellipsis": the expansion frame is the
/// tooltip-style overlay it would show on hover, and it is empty when nothing was cut.
@MainActor
private func truncated(_ field: NSTextField) -> Bool {
    guard let cell = field.cell else { return false }
    return !cell.expansionFrame(withFrame: field.bounds, in: field).isEmpty
}

// MARK: - only what is on screen

/// 🔴 The whole reason this grid is an `NSTableView`. A `List` — or an `ensureVisible` handed the
/// full extent — would pull every row of a 2.5M-row table through a 500-row cache to draw twenty of
/// them.
@MainActor
@Test func onlyTheRowsInTheVisibleRectangleAreAskedFor() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 3_000)
    let bridge = GridBridge(model: model)

    bridge.scrolled(
        to: CGRect(x: 0, y: 1_000 * gridRowHeight, width: 900, height: 20 * gridRowHeight))
    await model.drainForTest()

    #expect(model.rowSlot(at: 1_010) != .pending, "what is on screen arrives")
    #expect(model.rowSlot(at: 2_500) == .pending, "and nothing else does")
    #expect(model.rowSlot(at: 2_999) == .pending)
}

@MainActor
@Test func theVisibleRectangleMapsToRowsTheWayTheWebGridDid() {
    // `firstRow = scrollTop / ROW_H` and `visibleRows = ceil(clientHeight / ROW_H)`.
    let exact = GridBridge.viewport(
        CGRect(x: 0, y: 1_000 * gridRowHeight, width: 900, height: 20 * gridRowHeight),
        rowHeight: gridRowHeight)
    #expect(exact.firstRow == 1_000)
    #expect(exact.rowsOnScreen == 20)

    // Part-way through row 3, and a viewport 3.7 rows tall: the first row is the one the top edge is
    // inside, and a partly-visible last row still has to be fetched or it draws as a placeholder.
    let ragged = GridBridge.viewport(
        CGRect(x: 0, y: gridRowHeight * 3 + 13, width: 900, height: 100), rowHeight: gridRowHeight)
    #expect(ragged.firstRow == 3)
    #expect(ragged.rowsOnScreen == 4)

    let empty = GridBridge.viewport(CGRect(x: 0, y: 0, width: 900, height: 0), rowHeight: gridRowHeight)
    #expect(empty.firstRow == 0)
    #expect(empty.rowsOnScreen == 1, "never zero — the model treats it as a request for nothing")
}

// MARK: - a delivered block

/// `reloadData(forRowIndexes:)` past the end of the table is an exception, not a no-op, and the last
/// block of any table that is not an exact multiple of 500 goes past it.
@MainActor
@Test func aDeliveredBlockReloadsItsOwnRowsAndStopsAtTheEndOfTheTable() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 1_200)
    let bridge = GridBridge(model: model)

    #expect(bridge.rows(inBlock: 0) == IndexSet(integersIn: 0..<500))
    #expect(bridge.rows(inBlock: 1) == IndexSet(integersIn: 500..<1_000))
    #expect(bridge.rows(inBlock: 2) == IndexSet(integersIn: 1_000..<1_200), "200 rows, not 500")
    #expect(bridge.rows(inBlock: 3).isEmpty)
}

// MARK: - which of the empty states

@MainActor
@Test func theEmptyStatesAreTheOnesTheWebGridChoseBetween() async throws {
    // `renderGrid`'s fan-out (web/index.html:660-666).
    #expect(gridState(columnCount: 0, scrollExtent: 0, rowCountKnown: true) == .noColumns)
    #expect(gridState(columnCount: 3, scrollExtent: 0, rowCountKnown: true) == .noRows)
    #expect(gridState(columnCount: 3, scrollExtent: 12, rowCountKnown: true) == .rows)

    // 🔴 A multi-GB CSV between open and the end of its background count has no row number yet and
    // an extent of 0. "No rows match the current filters" would be the grid inventing a fact.
    #expect(gridState(columnCount: 3, scrollExtent: 0, rowCountKnown: false) == .rows)

    // And the real thing, so the arguments `RootView` passes are not the only untested part: a
    // filter that matches nothing is the state's whole reason to exist.
    let (_, model) = try await openedFixture(rows: 12)
    try await model.setFilters([Filter(col: "id", op: .lt, values: [.int(0)])])
    await model.drainForTest()
    #expect(
        gridState(
            columnCount: model.columns.count, scrollExtent: model.scrollExtent,
            rowCountKnown: model.table.displayRows != nil) == .noRows)
}

// MARK: - fixture

/// A table whose four columns land on four different answers from `computeWidths` — the pre-profile
/// fallback, the by-data branch, the by-name branch, and the 42-character cap followed by the 320
/// clamp.
///
/// Worth its own file rather than reusing `openedFixture`: every column of that one is short enough
/// to bottom out at the 76-pt floor, so a width formula with the wrong multiplier in it would still
/// produce 76 and the assertion would pass on a broken implementation.
@MainActor
private func gridWidthFixture() async throws -> (AppState, TableViewModel) {
    let path = tempDir("grid-widths").appendingPathComponent("widths.csv").path
    var out = "id,description,a_very_long_column_name_here_x,blob\n"
    for i in 0..<12 {
        out += "\(i),\(String(repeating: "d", count: 20)),y,\(String(repeating: "b", count: 60))\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: path)
    let opened = try #require(state.activeName)
    await waitForCatalog(state, "\(opened)'s exact row count") {
        state.tables.first { $0.name == opened }?.rowsAreExact == true
    }
    let model = try #require(state.model(for: opened))
    try await model.loadFirstPage()
    return (state, model)
}
