import AppKit
import DuckDBKit
import Foundation
import SiftCore
import SwiftUI
import Testing
import TestSupport
@testable import SiftEngine
@testable import SiftUI

// The five sheets. A SwiftUI `body` cannot be tested, so every decision each sheet makes lives in
// a free function beside it and everything below drives those directly — the same split
// `RootView`'s `gridState` and `GridBridge` already made for the grid.
//
// One test here reads PIXELS rather than properties, and it is deliberately the bad-rows
// highlight: that panel is the product's headline claim, and the grid's own suite already found
// two defects that no property assertion could see (a cell that drew completely blank because
// AppKit refuses to underline a whitespace-only run, and text that elided while
// `intrinsicContentSize` said it fit). `cacheDisplay(in:to:)` on a live `NSView` is the only
// capture that works here — Screen Recording is not granted and the Accessibility API returns zero
// windows.
//
// No `.serialized` anywhere, and nothing here reads or writes a process-global: the two staging
// environment variables are only ever *read*, and the tests that care assert the defaults only
// when the variables are absent.

/// AppKit's appearance system wants an app object before any `NSView` is constructed, even
/// headlessly. Idempotent; every rendering test here calls it first.
@MainActor
private func appKitReady() { _ = NSApplication.shared }

// MARK: - the staging policy the engine is actually enforcing

/// 🔴 The staged-data panel states the numbers that govern the user's own copy of their data. If
/// it restated `defaultBudgetBytes` while `SIFT_STAGE_BUDGET_GB` had moved the real limit, it
/// would be confidently wrong about the one thing it exists to be right about — so the numbers
/// come from the session, and SiftUI never reads those variables itself.
@Test func stagePolicyReportsTheLimitsThisSessionIsEnforcing() throws {
    let session = try Session(home: tempHome())
    let policy = session.stagePolicy()

    let environment = ProcessInfo.processInfo.environment
    if environment["SIFT_STAGE_BUDGET_GB"] == nil {
        #expect(policy.budgetBytes == defaultBudgetBytes)
        #expect(stageBudgetGB(policy) == 20, "20 GB, by exact integer division")
    }
    if environment["SIFT_STAGE_MAX_AGE_DAYS"] == nil {
        #expect(policy.maxAgeDays == defaultMaxAgeDays)
    }
}

// MARK: - bad rows

/// 🔴 The headline claim, end to end against a real dirty file. `bad_columns` is column 0 and it
/// is a `Cell.list`; this asserts the failing column is named and that NO other column is.
///
/// The gz detour is SessionQueriesTests' established trick and it is load-bearing: under
/// `fullSniffMaxBytes` the sniffer scans the WHOLE file and correctly widens `amount` to VARCHAR
/// the moment it sees one non-numeric value, leaving nothing to detect. A compressed CSV samples
/// only the first 20,480 rows however big it is, so a bad row placed past that window reproduces
/// the real scenario — the sniffer keeps `amount` numeric, and the later row does not fit it.
@MainActor
@Test func theBadRowsPanelNamesTheColumnThatFailedAndNoOther() async throws {
    let (state, name) = try await dirtyFixture()
    let panel = try await state.session.badRows(name)

    #expect(panel.rows == 1)
    #expect(panel.cells == 1)
    #expect(panel.data.count == 1)
    #expect(badColumnNames(in: panel.data[0]) == ["amount"])

    // …and every OTHER column of that row is left alone. Without this the test passes for an
    // implementation that paints the whole row red, which is the behaviour this panel replaced.
    let painted = panel.columns.map(\.name).filter { badColumnNames(in: panel.data[0]).contains($0) }
    #expect(painted == ["amount"])
    #expect(panel.columns.map(\.name).contains("region"), "…and there really was another column")
}

/// 🔴 The whole reason `Cell.list` exists. A joined string would have to be re-split downstream,
/// and re-splitting breaks the instant a column name contains the separator — in the one product
/// whose premise is not mangling data. A `.display`-and-split implementation returns
/// `["a", "b", "qty"]` here; this returns two names.
@Test func badColumnNamesReadsTheListAndNeverResplitsAJoinedString() {
    let row: [Cell] = [.list([.text("a,b"), .text("qty")]), .text("x"), .int(3)]
    #expect(badColumnNames(in: row) == ["a,b", "qty"])

    // A row from a table with no castable columns carries no list at all.
    #expect(badColumnNames(in: [.text("not a list"), .int(1)]).isEmpty)
    #expect(badColumnNames(in: []).isEmpty)
}

@Test func theBadRowsHeadlineAndParagraphCountRowsAndCellsSeparately() {
    #expect(badRowsHeadline(rows: 2_120) == "2,120 rows dropped")
    #expect(badRowsHeadline(rows: 1) == "1 row dropped")
    #expect(badRowsHeadline(rows: 0) == "0 rows dropped")

    #expect(
        badRowsExplanation(cells: 2_120) == """
            2,120 cells could not be cast to the detected type, so DuckDB skipped the whole row. \
            These are not in the grid or in any aggregate. Reading the column as text instead \
            keeps them.
            """)
    #expect(badRowsExplanation(cells: 1).hasPrefix("1 cell could not"))
}

/// A sample cell is the shared engine glyph, capped at the web's 60 characters — never
/// `Cell.display`, which renders NULL and `''` identically.
@Test func aSampleCellIsTheEngineGlyphAndIsCappedAtSixtyCharacters() {
    #expect(badCellText(.null, kind: .text) == SiftEngine.nullGlyph)
    #expect(badCellText(.text(""), kind: .text) == SiftEngine.emptyStringGlyph)
    #expect(badCellText(.int(1_234_567), kind: .number) == "1,234,567")
    #expect(badCellText(.text(String(repeating: "x", count: 200)), kind: .text).count == 60)
}

/// 🔴 **Rendered, not inspected.** Every other assertion in this file reads a property; this one
/// reads pixels, because "the offending cell is red" is a claim about paint. A `BadCell` that
/// carried the right flag and drew the same colour either way would satisfy every property
/// assertion above and be exactly as useless as no highlight at all.
@MainActor
@Test func theOffendingCellIsPaintedRedAndItsNeighbourIsNot() throws {
    appKitReady()
    let bad = try ink(BadCell(text: "N/A", bad: true))
    let plain = try ink(BadCell(text: "N/A", bad: false))

    #expect(!bad.isEmpty, "a cell that draws nothing is a cell that failed to render")
    #expect(!plain.isEmpty)
    #expect(redFraction(bad) > 0.5, "the failing cell is red")
    #expect(redFraction(plain) < 0.1, "…and the one beside it is not")
}

// MARK: - staged data

/// The web's `human` (web/index.html:464-470), not `ByteCountFormatter` (locale- and
/// unit-convention dependent) and not `SiftCore.human` (which groups its byte branch, so 1023
/// reads `1,023 B` there).
@Test func humanBytesIsTheWebsLadderExactly() {
    #expect(humanBytes(0) == "0 B")
    #expect(humanBytes(1023) == "1023 B")
    #expect(humanBytes(1024) == "1.0 KB")
    #expect(humanBytes(1_572_864) == "1.5 MB")
    #expect(humanBytes(1_099_511_627_776) == "1.0 TB")
    #expect(humanBytes(1024 * 1_099_511_627_776) == "1024.0 TB", "the ladder stops at TB")
}

/// 🔴 `20 GB`, not `20.0 GB`. The budget is always a whole number of GiB by construction, and
/// running it through `humanBytes` would drift from the web's `${d.budget_gb} GB`.
@Test func theStagePolicySentenceStatesWholeGigabytes() {
    let policy = StagePolicy(budgetBytes: 20 * 1_073_741_824, maxAgeDays: 14)
    #expect(stageBudgetGB(policy) == 20)
    #expect(
        stagePolicySentence(home: "/Users/x/.sift", policy: policy) == """
            Native copies kept in /Users/x/.sift so reopening a large file is instant. This is a \
            real copy of your data on this machine: anything untouched for 14 days is purged \
            automatically, and the total is capped at 20 GB.
            """)
    #expect(stagedTotalSentence(totalBytes: 1_572_864, policy: policy) == "1.5 MB total of 20 GB.")

    // An override the engine is really enforcing shows up as itself, in both sentences.
    let raised = StagePolicy(budgetBytes: 3 * 1_073_741_824, maxAgeDays: 2)
    #expect(stagePolicySentence(home: "/h", policy: raised).contains("untouched for 2 days"))
    #expect(stagePolicySentence(home: "/h", policy: raised).hasSuffix("capped at 3 GB."))
}

/// 🔴 No `DateFormatter`. Built from `Calendar.current` components and zero-padded by hand, which
/// is the `YYYY-MM-DD HH:MM` the web produced by slicing an ISO string to 16 characters.
@Test func aStagedTimestampIsYearMonthDayHourMinuteWithNoFormatter() throws {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 9
    components.hour = 4
    components.minute = 7
    let date = try #require(Calendar.current.date(from: components))
    #expect(stagedTimestamp(date) == "2026-08-09 04:07")

    // Two digits either side of the pad boundary, so a missing pad shows up as `2026-8-9 4:7`.
    components.month = 11
    components.day = 30
    components.hour = 23
    components.minute = 59
    #expect(stagedTimestamp(try #require(Calendar.current.date(from: components)))
        == "2026-11-30 23:59")
}

@Test func aMissingOrChangedSourceIsMarkedAndAHealthyOneIsNot() {
    func entry(missing: Bool, changed: Bool) -> StagedSource {
        StagedSource(
            table: "sales", path: "/data/archive/sales.csv", fmt: "csv", stagedAt: Date(),
            lastUsed: Date(), rows: 10, bytes: 1024, sourceMissing: missing,
            sourceChanged: changed)
    }
    #expect(stagedSourceName("/data/archive/sales.csv") == "sales.csv")
    #expect(stagedSourceMarker(entry(missing: false, changed: false)) == nil)
    #expect(stagedSourceMarker(entry(missing: false, changed: true)) == " (source changed)")
    #expect(stagedSourceMarker(entry(missing: true, changed: false)) == " (source gone)")
    // Missing wins, so a copy of a file that is simply gone never reads as merely stale.
    #expect(stagedSourceMarker(entry(missing: true, changed: true)) == " (source gone)")
}

// MARK: - export

/// 🔴 `SiftEngine.exportFormats` is the authority on the keys, the order and the extensions, and
/// SiftUI adds only the labels. This is what keeps a seventh format from reaching a menu as a raw
/// lowercase key — `exportLabel`'s `default` branch is unreachable exactly while this passes.
@Test func everyFormatTheEngineOffersHasALabelAndTheOrderIsTheEngines() {
    #expect(exportFormats.map(\.key) == ["parquet", "csv", "tsv", "json", "ndjson", "xlsx"])
    #expect(
        exportFormats.map { exportLabel(forKey: $0.key) }
            == ["Parquet (zstd)", "CSV", "TSV", "JSON (array)", "NDJSON (lines)", "Excel"])
    for format in exportFormats {
        #expect(exportLabel(forKey: format.key) != format.key, "\(format.key) has no label")
    }
}

@Test func theDefaultDestinationSitsBesideTheSourceAsAParquet() {
    #expect(
        defaultExportDestination(sourcePath: "/data/2026/orders.csv", table: "orders")
            == "/data/2026/orders_export.parquet")
}

/// Choosing a format rewrites the destination's extension — the web's
/// `replace(/\.[a-z0-9]+$/i, "." + ext)`, including its refusal to append one where there is none.
@Test func theDestinationFollowsTheChosenFormatsExtension() {
    #expect(retargetExtension("/d/orders_export.parquet", to: "csv") == "/d/orders_export.csv")
    #expect(retargetExtension("/d/orders_export.CSV", to: "ndjson") == "/d/orders_export.ndjson")
    #expect(retargetExtension("/d/v1.2/orders_export.json", to: "tsv") == "/d/v1.2/orders_export.tsv")
    // No trailing extension: left exactly as typed, rather than silently renaming the user's file.
    #expect(retargetExtension("/d/orders_export", to: "csv") == "/d/orders_export")
    #expect(retargetExtension("/d.v2/orders", to: "csv") == "/d.v2/orders")
    #expect(retargetExtension("", to: "csv") == "")
}

@Test func theExportToastSpellsBytesDestinationAndMilliseconds() {
    let result = ExportResult(
        dest: "/data/orders_export.parquet", format: "parquet", bytes: 1_572_864,
        milliseconds: 12.34)
    #expect(exportToast(result) == "Wrote 1.5 MB to /data/orders_export.parquet in 12.3 ms")
}

// MARK: - merge

/// 🔴 The one number that prevents more bad analyses than anything else in the app, against a real
/// probe over two real tables. Also the test that pins `joinProbe`'s argument labels — both table
/// arguments are `_`, and a wrong label reads at the call site as a missing method.
@Test func theOverlapSentenceIsTheOneNumberThatStopsABadJoin() async throws {
    let (session, _, _) = try await joinFixture()
    let probe = try await session.joinProbe("orders", "returns", on: ["order_id"])

    #expect(
        overlapSentence(probe)
            == "7 of 10 distinct order_id in orders match returns → 70.0%")
    #expect(unmatchedSentence(probe) == "3 unmatched (kept only by a left/full join)")

    // Two keys read as one compound key, joined the way the web joined them.
    let compound = JoinProbe(
        left: "a", right: "b", on: ["k1", "k2"], leftDistinct: 1_318, matched: 1_204,
        unmatched: 114, pct: 1_204.0 / 1_318.0)
    #expect(
        overlapSentence(compound)
            == "1,204 of 1,318 distinct k1 + k2 in a match b → 91.4%")
}

/// A real-but-tiny overlap keeps two decimals so it cannot round to a flat `0.0%` and read as "no
/// match at all" — the web's `f < 0.01 && f > 0` branch.
@Test func aTinyRealOverlapKeepsTwoDecimalsAndAZeroKeepsOne() {
    #expect(joinPercent(0.914) == "91.4%")
    #expect(joinPercent(1.0) == "100.0%")
    #expect(joinPercent(0.005) == "0.50%")
    #expect(joinPercent(0.0001) == "0.01%")
    #expect(joinPercent(0.0) == "0.0%", "genuinely nothing matched, and it says so plainly")
    #expect(joinPercent(0.01) == "1.0%", "the boundary is exclusive")
}

@Test func aPerfectJoinHasNoUnmatchedLine() {
    let probe = JoinProbe(
        left: "a", right: "b", on: ["k"], leftDistinct: 9, matched: 9, unmatched: 0, pct: 1.0)
    #expect(unmatchedSentence(probe) == nil)
}

@Test func theKeyPromptSaysWhichOfTheThreeSituationsThisIs() {
    let candidate = JoinCandidate(
        col: "order_id", leftType: "BIGINT", rightType: "BIGINT", compatible: true)
    #expect(mergeKeyPrompt(left: "a", right: "a", candidates: [candidate]) == .sameTable)
    #expect(mergeKeyPrompt(left: "a", right: "b", candidates: []) == .noSharedColumns)
    #expect(mergeKeyPrompt(left: "a", right: "b", candidates: [candidate]) == .pick)

    #expect(MergeKeyPrompt.sameTable.text == "Pick two different tables.")
    #expect(
        MergeKeyPrompt.noSharedColumns.text
            == "These two share no column names — nothing to join on.")
    #expect(MergeKeyPrompt.pick.text == "Join on — tick one or more keys:")
}

/// The candidate list carries both types and the compatibility flag the row is disabled on — from
/// the engine, in the file's own column order.
@Test func theCandidateKeysComeBackWithBothTypesAndTheirCompatibility() async throws {
    let (session, _, _) = try await joinFixture()
    let candidates = try await session.joinCandidates("orders", "returns")
    #expect(candidates.map(\.col) == ["order_id"])
    #expect(candidates[0].compatible)
    #expect(candidates[0].leftType == candidates[0].rightType)
}

@Test func mergeToastCountsTheRowsTheNewViewActuallyHas() async throws {
    let (session, _, _) = try await joinFixture()
    let merged = try await session.merge("orders", "returns", on: ["order_id"])
    #expect(merged.name == "orders_returns")
    #expect(mergeToast(merged) == "Merged into orders_returns — 7 rows")
}

/// 🔴 **Closing a source under a live merge is REFUSED, not cascaded**, and the refusal names the
/// dependents so the fix is one click away. This sheet creates that dependency, so this is the
/// behaviour it is on the hook for surfacing — it must not invent a cascade and must not swallow
/// the sentence.
@Test func closingASourceUnderALiveMergeIsRefusedWithASentenceNamingIt() async throws {
    let (session, _, _) = try await joinFixture()
    _ = try await session.merge("orders", "returns", on: ["order_id"])

    await #expect(throws: SessionError.self) { try await session.closeTable("orders") }
    do {
        try await session.closeTable("orders")
        Issue.record("closing a merged source was allowed")
    } catch {
        #expect(
            "\(error)" == "'orders' is merged into 'orders_returns'. Close 'orders_returns' first.")
    }
    // …and the merge is still there, which is the half a cascade would have destroyed.
    #expect(await session.state().tables.map(\.name).contains("orders_returns"))
}

// MARK: - the workbook sheet picker

// Which paths reach this picker is `needsSheetPicker`, pinned once in
// `KeyNavTests.workbooksRouteThroughTheSheetPickerAndNothingElseDoes`. The six cases used to be
// here too, against a byte-identical `offersSheetPicker` that nothing called — two spellings of one
// rule, either of which could be edited with the suite still green.

/// A single-sheet workbook still gets the picker — parity with `siftOpenPaths`, which routes every
/// workbook through it unconditionally. Shortcutting one sheet straight to open is a visible
/// behaviour change, not an implementation detail.
@Test func aSingleSheetWorkbookStillGetsThePickerAndItsPluralSubtitle() {
    #expect(sheetPickerSubtitle(count: 1) == "1 sheets — pick what to open.")
    #expect(sheetPickerSubtitle(count: 3) == "3 sheets — pick what to open.")
}

@Test func everyNonEmptySheetIsTickedAndAnEmptyOneIsListedButNot() {
    let sheets = [
        SheetInfo(name: "Summary", rows: 2, cols: 2),
        SheetInfo(name: "By Store", rows: 1_204, cols: 7),
        SheetInfo(name: "Empty", rows: 1, cols: 1),
        SheetInfo(name: "NoDimension", rows: 0, cols: 0),
    ]
    #expect(defaultSheetSelection(sheets) == ["Summary", "By Store"])
    #expect(sheetRowLabel(sheets[0]) == "2 × 2")
    #expect(sheetRowLabel(sheets[1]) == "1,204 × 7")
    #expect(sheetRowLabel(sheets[2]) == "empty")
    #expect(sheetRowLabel(sheets[3]) == "empty", "a sheet with no <dimension> is nothing to open")
}

// MARK: - fixtures

/// Two tables that share exactly one column name, with a known overlap: 10 distinct `order_id` on
/// the left, 7 of them on the right.
private func joinFixture() async throws -> (Session, String, String) {
    let dir = tempDir("merge")
    var orders = "order_id,amount\n"
    for i in 1...10 { orders += "\(i),\(i * 5)\n" }
    var returns = "order_id,reason\n"
    for i in 1...7 { returns += "\(i),damaged\n" }
    try orders.write(
        toFile: dir.appendingPathComponent("orders.csv").path, atomically: true, encoding: .utf8)
    try returns.write(
        toFile: dir.appendingPathComponent("returns.csv").path, atomically: true, encoding: .utf8)

    let session = try Session(home: tempHome())
    let left = try await session.openPath(dir.appendingPathComponent("orders.csv").path)
    let right = try await session.openPath(dir.appendingPathComponent("returns.csv").path)
    return (session, left.name, right.name)
}

/// A file with exactly one cell that will not cast, past the sniffer's sample window. Returns the
/// state once the background scan has actually landed — `badCells` is 0 for a moment after open,
/// so a test that read it immediately would pass for the wrong reason.
@MainActor
private func dirtyFixture() async throws -> (AppState, String) {
    let dir = tempDir("dirty")
    var text = "order_id,region,amount\n"
    for i in 0..<25_000 {
        text += "\(i),West,\(i == 21_000 ? "N/A" : "\(i).50")\n"
    }
    let plain = dir.appendingPathComponent("dirty.csv").path
    try text.write(toFile: plain, atomically: true, encoding: .utf8)
    let gz = dir.appendingPathComponent("dirty.csv.gz").path
    try gzip(plain, to: gz)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: gz)
    let name = try #require(state.activeName, "open failed: \(state.banner ?? "no banner")")
    await waitForCatalog(state, "\(name)'s bad-cell scan") {
        state.tables.first { $0.name == name }?.badCells ?? 0 > 0
    }
    return (state, name)
}

/// Blocking file-redirected `/usr/bin/gzip -c`, not a `Pipe` — a third copy of
/// SiftEngineTests' helper, because SwiftPM test targets cannot import one another (the same
/// trade-off Fixtures.swift's header records for the corpus itself).
private func gzip(_ sourcePath: String, to destPath: String) throws {
    FileManager.default.createFile(atPath: destPath, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = FileHandle(forReadingAtPath: sourcePath)
    process.standardOutput = FileHandle(forWritingAtPath: destPath)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DuckDBError("gzip exited \(process.terminationStatus)")
    }
}

// MARK: - pixels

/// Every opaque pixel a SwiftUI view actually paints, through `NSHostingView`.
///
/// `cacheDisplay(in:to:)` on a live `NSView`, and a plain `NSWindow` behind it so SwiftUI has a
/// backing store to draw into. NOT `ImageRenderer` (it hands back a prohibited-symbol placeholder
/// for anything with an `NSViewRepresentable` in it, and this file should not care which kind of
/// view it is handed) and never an `NSVisualEffectView`, which `cacheDisplay` cannot capture.
@MainActor
private func ink<V: View>(_ view: V, width: CGFloat = 120, height: CGFloat = 20) throws -> [NSColor]
{
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    // 🔴 Pinned to Aqua, on the window as well as the view — a hosting view inherits its window's
    // appearance for anything AppKit draws. Without it this render follows whatever appearance the
    // machine is in, and every render check on this branch had always run in dark, which is how two
    // light-mode defects survived eight suites (see `AppearanceTests`).
    window.appearance = NSAppearance(named: .aqua)
    host.appearance = NSAppearance(named: .aqua)
    window.contentView?.addSubview(host)
    host.layoutSubtreeIfNeeded()

    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    var painted: [NSColor] = []
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
            painted.append(colour)
        }
    }
    return painted
}

/// How much of the ink is red, rather than whether ANY of it is: antialiased glyph edges carry
/// colour fringes either way, so a "contains one red pixel" test would be noise.
private func redFraction(_ colours: [NSColor]) -> Double {
    guard !colours.isEmpty else { return 0 }
    let reds = colours.filter { colour in
        guard let rgb = colour.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.4
            && rgb.redComponent > rgb.greenComponent + 0.2
            && rgb.redComponent > rgb.blueComponent + 0.2
    }
    return Double(reds.count) / Double(colours.count)
}

/// 🔴 The toolbar's row phrase is the only way into the bad-rows panel, and `canShowBadRows` is what
/// decides whether that phrase is drawn as a click target at all. `KeyNavTests` pins the negative
/// half (nothing open, and a clean file); this is the half that needs a file which really dropped a
/// row, which only `dirtyFixture` produces.
@MainActor
@Test func theRowPhraseIsAWayIntoTheBadRowsPanelOnlyWhenRowsWereDropped() async throws {
    let (state, _) = try await dirtyFixture()
    #expect((state.active?.badRows ?? 0) > 0, "the fixture stopped dropping a row")
    #expect(state.canShowBadRows)
    #expect(state.rowSummary.contains("dropped"))
    state.presentBadRows()
    #expect(state.modalSheet == .badRows(table: try #require(state.activeName)))

    // …and it stops being one the moment the selection moves to a clean table.
    state.modalSheet = nil
    await state.open(path: try makeCSV(in: tempDir(), rows: 3))
    #expect(state.canShowBadRows == false)
    #expect(state.rowSummary.contains("dropped") == false)
    state.presentBadRows()
    #expect(state.modalSheet == nil)
}
