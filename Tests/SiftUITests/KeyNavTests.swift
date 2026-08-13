import AppKit
import Foundation
import SiftCore
import SiftEngine
import Testing

@testable import SiftUI

// The keyboard's arithmetic, the toolbar's phrase, and the two routing decisions the menus make.
//
// Everything the menu bar and the key monitor *do* is in `SiftApp`, which no test target can
// import; everything they *decide* is here. That split is the reason this file exists, so every
// assertion below is one a mutation to `KeyNav.swift` or `AppState.swift` can kill — the failing
// mutants are recorded in the task report.

// MARK: - down and up

@Test func downAndUpMoveExactlyOneRow() {
    #expect(rowTarget(for: .down, firstRow: 5, rowsOnScreen: 10, total: 1000) == 6)
    #expect(rowTarget(for: .up, firstRow: 5, rowsOnScreen: 10, total: 1000) == 4)
}

/// The bottom of the scroll is `total - rowsOnScreen`, NOT `total - 1`: the last screenful is the
/// last position, and stopping at the last *row* would scroll a full window past the end of the
/// data.
@Test func downStopsWithTheLastScreenfulShowing() {
    // 1000 rows, 10 on screen -> row 990 puts rows 990…999 on screen and there is nowhere further.
    #expect(rowTarget(for: .down, firstRow: 989, rowsOnScreen: 10, total: 1000) == 990)
    #expect(rowTarget(for: .down, firstRow: 990, rowsOnScreen: 10, total: 1000) == nil)
}

@Test func upStopsAtZero() {
    #expect(rowTarget(for: .up, firstRow: 1, rowsOnScreen: 10, total: 1000) == 0)
    #expect(rowTarget(for: .up, firstRow: 0, rowsOnScreen: 10, total: 1000) == nil)
}

/// `nil` is "already there", and it is what stops a held-down arrow at the end of a 40M-row file
/// from issuing a scroll, a bounds notification and a block request per key repeat.
@Test func aJumpThatWouldNotMoveTheViewportIsNil() {
    #expect(rowTarget(for: .top, firstRow: 0, rowsOnScreen: 10, total: 1000) == nil)
    #expect(rowTarget(for: .bottom, firstRow: 990, rowsOnScreen: 10, total: 1000) == nil)
    #expect(rowTarget(for: .pageUp, firstRow: 0, rowsOnScreen: 10, total: 1000) == nil)
    #expect(rowTarget(for: .pageDown, firstRow: 990, rowsOnScreen: 10, total: 1000) == nil)
}

// MARK: - pages

/// `Math.max(1, visibleRows() - 1)` — a page keeps one row of context so the eye has something to
/// land on. A page of exactly `rowsOnScreen` would leave nothing shared between the two screens.
@Test func aPageIsOneScreenLessOneRowOfContext() {
    #expect(rowTarget(for: .pageDown, firstRow: 0, rowsOnScreen: 20, total: 10_000) == 19)
    #expect(rowTarget(for: .pageUp, firstRow: 100, rowsOnScreen: 20, total: 10_000) == 81)
}

/// The `max(1, …)`: on a viewport one row tall a page must still move, or PageDown does nothing at
/// all on a very short window.
@Test func aPageOnAOneRowViewportStillMovesOneRow() {
    #expect(rowTarget(for: .pageDown, firstRow: 4, rowsOnScreen: 1, total: 1000) == 5)
    #expect(rowTarget(for: .pageUp, firstRow: 4, rowsOnScreen: 1, total: 1000) == 3)
}

@Test func pagesClampRatherThanOvershoot() {
    // 995 + 19 = 1014, well past the last first row of 990.
    #expect(rowTarget(for: .pageDown, firstRow: 995, rowsOnScreen: 10, total: 1000) == 990)
    #expect(rowTarget(for: .pageUp, firstRow: 3, rowsOnScreen: 10, total: 1000) == 0)
}

// MARK: - top and bottom

@Test func topAndBottomGoAllTheWay() {
    #expect(rowTarget(for: .top, firstRow: 500, rowsOnScreen: 10, total: 1000) == 0)
    #expect(rowTarget(for: .bottom, firstRow: 0, rowsOnScreen: 10, total: 1000) == 990)
}

/// A table shorter than the window cannot scroll at all, and every key has to agree about that —
/// `maxFirstRow` going negative is how the grid ends up scrolled past a three-row file.
@Test func aTableShorterThanTheWindowCannotScroll() {
    #expect(maxFirstRow(total: 5, rowsOnScreen: 40) == 0)
    for key in [NavKey.down, .up, .pageDown, .pageUp, .top, .bottom] {
        #expect(rowTarget(for: key, firstRow: 0, rowsOnScreen: 40, total: 5) == nil)
    }
}

/// A viewport reported as zero rows tall — a window mid-resize, a grid that has not laid out — must
/// not make the last row the last first row.
@Test func aZeroHeightViewportIsTreatedAsOneRow() {
    #expect(maxFirstRow(total: 1000, rowsOnScreen: 0) == 999)
    #expect(rowTarget(for: .bottom, firstRow: 0, rowsOnScreen: 0, total: 1000) == 999)
}

/// A viewport parked past the end (a filter that just cut the table) is pulled back rather than
/// left where it was.
@Test func aFirstRowAlreadyPastTheEndIsPulledBack() {
    #expect(rowTarget(for: .down, firstRow: 5000, rowsOnScreen: 10, total: 1000) == 990)
    #expect(rowTarget(for: .up, firstRow: 5000, rowsOnScreen: 10, total: 1000) == 990)
}

// MARK: - ⌘G

@Test func goToRowIsOneBasedOnScreenAndZeroBasedInside() {
    #expect(gotoRowTarget("1", rowsOnScreen: 10, total: 1000) == 0)
    #expect(gotoRowTarget("500", rowsOnScreen: 10, total: 1000) == 499)
}

/// The gutter and the toolbar both show grouped digits, so a grouped number is what gets pasted
/// back in. `gotoRow`'s `replace(/[^0-9]/g, "")`.
@Test func goToRowAcceptsAGroupedNumber() {
    #expect(gotoRowTarget("1,048,576", rowsOnScreen: 10, total: 2_000_000) == 1_048_575)
    #expect(gotoRowTarget(" row 42 ", rowsOnScreen: 10, total: 1000) == 41)
}

@Test func goToRowWithoutADigitIsRefusedRatherThanTreatedAsZero() {
    #expect(gotoRowTarget("", rowsOnScreen: 10, total: 1000) == nil)
    #expect(gotoRowTarget("   ", rowsOnScreen: 10, total: 1000) == nil)
    #expect(gotoRowTarget("last", rowsOnScreen: 10, total: 1000) == nil)
    // Not `Character.isNumber`: `Int("٣")` is nil, so stripping to it and then failing to parse
    // would silently mean "the end of the table".
    #expect(gotoRowTarget("٣", rowsOnScreen: 10, total: 1000) == nil)
}

@Test func goToRowClampsAtBothEnds() {
    #expect(gotoRowTarget("0", rowsOnScreen: 10, total: 1000) == 0)
    #expect(gotoRowTarget("999999", rowsOnScreen: 10, total: 1000) == 990)
    // Bigger than an Int: `parseInt` produced a float and `Math.min` clamped it, so this means
    // "the end" rather than a refusal.
    #expect(gotoRowTarget("999999999999999999999999", rowsOnScreen: 10, total: 1000) == 990)
}

// MARK: - which key is which

@Test func arrowsScrollAndCommandArrowsJumpToTheEnds() {
    let up = Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
    let down = Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
    #expect(navKey(for: up, command: false) == .up)
    #expect(navKey(for: down, command: false) == .down)
    #expect(navKey(for: up, command: true) == .top)
    #expect(navKey(for: down, command: true) == .bottom)
}

@Test func pageKeysNeedNoModifierAndHomeEndNeedCommand() {
    let pageUp = Character(UnicodeScalar(UInt32(NSPageUpFunctionKey))!)
    let pageDown = Character(UnicodeScalar(UInt32(NSPageDownFunctionKey))!)
    let home = Character(UnicodeScalar(UInt32(NSHomeFunctionKey))!)
    let end = Character(UnicodeScalar(UInt32(NSEndFunctionKey))!)
    #expect(navKey(for: pageUp, command: false) == .pageUp)
    #expect(navKey(for: pageDown, command: false) == .pageDown)
    #expect(navKey(for: home, command: true) == .top)
    #expect(navKey(for: end, command: true) == .bottom)
    // Bare Home/End are left to AppKit, which already scrolls to the ends of the document.
    #expect(navKey(for: home, command: false) == nil)
    #expect(navKey(for: end, command: false) == nil)
}

/// Anything else has to fall through, or the monitor swallows ordinary typing.
@Test func anOrdinaryCharacterIsNotANavigationKey() {
    #expect(navKey(for: "j", command: false) == nil)
    #expect(navKey(for: "g", command: true) == nil)
    #expect(navKey(for: " ", command: false) == nil)
}

@Test func commandOneThroughNineSelectTheNthTable() {
    #expect(tableIndex(forCommandKey: "1") == 0)
    #expect(tableIndex(forCommandKey: "9") == 8)
    // ⌘0 is not the tenth table — there is no ⌘0 tab anywhere on the platform.
    #expect(tableIndex(forCommandKey: "0") == nil)
    #expect(tableIndex(forCommandKey: "a") == nil)
}

// MARK: - the routing the open panel and the drops go through

@Test func workbooksRouteThroughTheSheetPickerAndNothingElseDoes() {
    #expect(needsSheetPicker("/data/books.xlsx"))
    #expect(needsSheetPicker("/data/BOOKS.XLSX"))
    #expect(needsSheetPicker("/data/macro.xlsm"))
    #expect(!needsSheetPicker("/data/books.csv"))
    #expect(!needsSheetPicker("/data/books.parquet"))
    // A legacy .xls is refused by the engine with a sentence explaining why; a picker that failed
    // to unzip it would replace that sentence with a worse one.
    #expect(!needsSheetPicker("/data/ancient.xls"))
    #expect(!needsSheetPicker("/data/xlsx"))
}

@MainActor
@Test func openingABatchOpensTheOrdinaryFilesAndQueuesOneWorkbook() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    let csv = try makeCSV(in: dir, name: "plain.csv", rows: 3)
    let book = dir.appendingPathComponent("book.xlsx").path
    let other = dir.appendingPathComponent("other.xlsx").path

    await state.open(paths: [csv, book, other])

    // The CSV is open; neither workbook was opened behind the picker's back.
    #expect(state.tables.count == 1)
    #expect(state.modalSheet == .workbook(path: book))
    // …and the one that could not be shown is said out loud rather than dropped.
    let banner = try #require(state.banner)
    #expect(banner.contains("book.xlsx"))
}

// MARK: - the menu actions

@MainActor
@Test func commandNumberSelectsByPositionAndIgnoresAnIndexThatIsNotThere() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    for name in ["a.csv", "b.csv", "c.csv"] {
        await state.open(path: try makeCSV(in: dir, name: name, rows: 3))
    }
    let names = state.tables.map(\.name)
    #expect(names.count == 3)

    state.selectTable(atIndex: 0)
    #expect(state.activeName == names[0])
    state.selectTable(atIndex: 2)
    #expect(state.activeName == names[2])

    // ⌘7 with three tables open leaves the selection alone rather than clearing or trapping.
    state.selectTable(atIndex: 6)
    #expect(state.activeName == names[2])
    state.selectTable(atIndex: -1)
    #expect(state.activeName == names[2])
}

@MainActor
@Test func toggleSidebarAndInspectorGoBothWays() {
    let state = AppState(session: try! Session(home: tempHome()))
    #expect(state.sidebarVisibility == .all)
    state.toggleSidebar()
    #expect(state.sidebarVisibility == .detailOnly)
    state.toggleSidebar()
    #expect(state.sidebarVisibility == .all)

    #expect(state.inspectorVisible)
    state.toggleInspector()
    #expect(!state.inspectorVisible)
    state.toggleInspector()
    #expect(state.inspectorVisible)
}

/// Export is about the open table, so with nothing open it must not put up a sheet with no subject.
/// The File menu greys the item for the same reason; this is the half that is checkable.
@MainActor
@Test func exportAndBadRowsRefuseWhenThereIsNothingToActOn() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    state.presentExport()
    #expect(state.modalSheet == nil)
    state.presentBadRows()
    #expect(state.modalSheet == nil)

    await state.open(path: try makeCSV(in: tempDir(), rows: 3))
    state.presentExport()
    #expect(state.modalSheet == .export)
    // A clean CSV drops no rows, so there is still nothing for the bad-rows sheet to show.
    state.modalSheet = nil
    state.presentBadRows()
    #expect(state.modalSheet == nil)
}

@MainActor
@Test func mergeAndStagedAreAlwaysReachable() {
    let state = AppState(session: try! Session(home: tempHome()))
    state.presentMerge()
    #expect(state.modalSheet == .merge)
    state.presentStaged()
    #expect(state.modalSheet == .staged)
}

/// ⌘W closes the open TABLE, not the window — closing the window quits the app
/// (`applicationShouldTerminateAfterLastWindowClosed`).
@MainActor
@Test func closeActiveClosesTheOpenTableAndIsANoOpWithNothingOpen() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "one.csv", rows: 3))
    let first = try #require(state.activeName)
    await state.open(path: try makeCSV(in: dir, name: "two.csv", rows: 3))
    #expect(state.tables.count == 2)

    await state.closeActive()
    #expect(state.tables.map(\.name) == [first])
    await state.closeActive()
    #expect(state.tables.isEmpty)

    await state.closeActive()
    #expect(state.tables.isEmpty)
    #expect(state.banner == nil)
}

// MARK: - the toolbar's phrase

/// Planted tables rather than opened files: "counting…" and a dropped-row count cannot be produced
/// on demand from a fixture small enough for a test to wait on, and a branch a test cannot reach is
/// a branch nobody has ever run.
private func plantedTable(
    columns: Int = 3, rowCount: Int? = 1_048_576, estimate: Int? = nil, badRows: Int = 0,
    counting: Bool = false, filters: [Filter] = [], filteredCount: Int? = nil
) -> SiftEngine.Table {
    let spec = SourceSpec(
        key: SourceKey(path: "/data/t.csv", mtimeNs: 0, size: 0),
        fmt: .csv,
        readFn: "read_csv",
        columns: (0..<columns).map { Column(name: "c\($0)", type: "VARCHAR") },
        rowEstimate: estimate.map { RowEstimate(rows: $0, confidence: .low, basis: "sample") }
    )
    var table = SiftEngine.Table(
        name: "t", spec: spec, qspec: QuerySpec(relation: "t", filters: filters), openedAt: 0)
    table.rowCount = rowCount
    table.badRows = badRows
    table.counting = counting
    table.filteredCount = filteredCount
    return table
}

@Test func theRowPhraseGroupsItsDigitsAndNamesTheColumns() {
    #expect(rowSummaryText(plantedTable()) == "1,048,576 rows · 3 cols")
}

/// The estimate is marked. A byte-sample guess presented as a count is this app failing at the one
/// thing it claims to be for.
@Test func anEstimatedCountIsMarkedApproximate() {
    let table = plantedTable(rowCount: nil, estimate: 4_200_000)
    #expect(rowSummaryText(table) == "≈ 4,200,000 rows · 3 cols")
}

/// An exact count already in flight makes the estimate a number about to be replaced.
@Test func aCountInFlightSaysSoRatherThanShowingTheEstimate() {
    #expect(rowSummaryText(plantedTable(counting: true)) == "counting… · 3 cols")
    #expect(
        rowSummaryText(plantedTable(rowCount: nil, estimate: 900, counting: true))
            == "counting… · 3 cols")
    // Nothing known at all reads the same way.
    #expect(rowSummaryText(plantedTable(rowCount: nil)) == "counting… · 3 cols")
}

@Test func aFilteredCountIsShownAgainstTheUnfilteredOne() {
    let table = plantedTable(
        rowCount: 1_048_576, filters: [Filter(col: "c0", op: .eq, values: [.text("x")])],
        filteredCount: 12)
    #expect(rowSummaryText(table) == "12 of 1,048,576 rows · 3 cols")
}

/// The headline claim of the product, in the toolbar. It only appears when rows were actually
/// dropped — "0 dropped" on every clean file would train the eye to stop reading it.
@Test func droppedRowsAreCountedOnlyWhenThereAreSome() {
    // The count shown is what the grid can page through — physical rows MINUS the dropped ones, so
    // the two numbers in the phrase never add up to a third number that is nowhere on screen.
    #expect(
        rowSummaryText(plantedTable(badRows: 12_345))
            == "1,036,231 rows · 3 cols · 12,345 dropped")
    #expect(!rowSummaryText(plantedTable(badRows: 0)).contains("dropped"))
}

@MainActor
@Test func theToolbarIsEmptyWithNothingOpenAndFollowsTheActiveTable() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    #expect(state.rowSummary == "")

    await state.open(path: try makeCSV(in: tempDir(), rows: 12))
    await waitForCatalog(state, "the exact row count") { state.tables.first?.rowsAreExact == true }
    #expect(state.rowSummary == "12 rows · 3 cols")
}

// MARK: - what LaunchServices hands over

/// 🔴 `application(_:open:)` did `urls.map(\.path)`, which is right for a `file:` URL and wrong for
/// every other scheme: `URL.path` is the path COMPONENT, so the scheme, host, query and fragment are
/// discarded and what is left is a plausible-looking local path. The refusal then names a file the
/// user never mentioned — or, on a machine where the stripped path happens to exist, Sift opens the
/// wrong file and says nothing.
@Test func aFileURLOpensByPathAndEverythingElseKeepsItsWholeURL() {
    #expect(openArguments([URL(fileURLWithPath: "/data/orders.csv")]) == ["/data/orders.csv"])

    // A custom scheme. `.path` leaves `/open/Users/andrew/orders.csv` — a real-looking path.
    #expect(
        openArguments([URL(string: "sift://open/Users/andrew/orders.csv")!])
            == ["sift://open/Users/andrew/orders.csv"])
    // …and https leaves `/data.csv`, which on plenty of machines exists.
    #expect(
        openArguments([URL(string: "https://example.com/data.csv")!])
            == ["https://example.com/data.csv"])
    // The query is part of what was handed over and part of what a refusal has to quote back.
    #expect(
        openArguments([URL(string: "s3://bucket/key.parquet?versionId=7")!])
            == ["s3://bucket/key.parquet?versionId=7"])

    // Order is the order they arrived in, and a mixed batch keeps both rules.
    #expect(
        openArguments([
            URL(string: "https://example.com/a.csv")!, URL(fileURLWithPath: "/data/b.csv"),
        ]) == ["https://example.com/a.csv", "/data/b.csv"])
    #expect(openArguments([]).isEmpty)

    // A file URL with a space is decoded, which is exactly why `.path` is right for this one case:
    // the engine wants bytes on disk, not percent-encoding.
    #expect(openArguments([URL(fileURLWithPath: "/data/my file.csv")]) == ["/data/my file.csv"])
}

/// Open Recent is the OS's documents list — drawn with a file icon, resolved against the
/// filesystem, persisted across launches. A non-file URL in it is an entry that can never re-open
/// anything.
@Test func onlyFileURLsAreRecordedAsRecentDocuments() {
    let file = URL(fileURLWithPath: "/data/orders.csv")
    let web = URL(string: "https://example.com/data.csv")!
    let custom = URL(string: "sift://open/x.csv")!

    #expect(recentDocuments([file, web, custom]) == [file])
    #expect(recentDocuments([web, custom]).isEmpty)
    #expect(recentDocuments([]).isEmpty)
}

// MARK: - the toolbar

/// 🔴 The menu item and the toolbar button read the SAME property, which is the whole reason these
/// two exist. The rule used to be written twice — once in `AppDelegate.validateMenuItem`, in a
/// target no test can import, and once as a guard inside `presentExport` — and two spellings of one
/// sentence is how a greyed menu item ends up beside a live toolbar button.
@MainActor
@Test func exportAndMergeSayTheSameThingToTheMenuAndToTheToolbar() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    #expect(state.canExport == false)
    #expect(state.canMerge == false)
    #expect(state.canShowBadRows == false)

    await state.open(path: try makeCSV(in: dir, name: "one.csv", rows: 3))
    #expect(state.canExport)
    #expect(state.canMerge == false, "one table is not two")

    await state.open(path: try makeCSV(in: dir, name: "two.csv", rows: 3))
    #expect(state.canExport)
    #expect(state.canMerge)

    // …and back down again as the tables close, so the toolbar greys on the way out too.
    await state.closeActive()
    #expect(state.canMerge == false)
    await state.closeActive()
    #expect(state.canExport == false)
}

/// 🔴 `Label(_, systemImage:)` handed a symbol name macOS does not know draws NOTHING and reports
/// nothing: a toolbar button that is present, enabled, hit-testable and invisible — a worse bug than
/// the title-bar accessory this toolbar replaced. `NSImage(systemSymbolName:)` answers for the
/// system the test is actually running on, which matters here more than usual: this Mac has only the
/// macOS 26 SDK while CI runs macos-15, so "it looked right here" has already twice been no evidence
/// at all about the floor.
@MainActor
@Test func theToolbarsSymbolsAllResolve() {
    for name in ToolbarSymbol.all {
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "the toolbar draws \(name), which this system does not have")
    }
    #expect(ToolbarSymbol.all.count == 4, "a button was added or removed without its symbol")
    // …and the check is not vacuous: a name macOS does not know really does come back nil.
    #expect(NSImage(systemSymbolName: "sift.not.a.symbol", accessibilityDescription: nil) == nil)
}
