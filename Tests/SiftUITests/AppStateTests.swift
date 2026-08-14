import DuckDBKit
import Foundation
import SiftCore
import SiftEngine
import Testing
@testable import SiftUI

// The catalog mirror, the per-table view models, the error banner and the poll loop. Every test
// here drives a REAL `Session` over a REAL file: `TablePage` and its `ColumnInfo` declare `public
// let` fields and no `public init`, so there is no way to fake a page, and no `public init` may be
// added to the engine to make a test easier (plan, "Landmines").

@MainActor
/// The staging banner's Cancel routes through `AppState.cancelStaging` so the engine's `false` —
/// "that cancel cannot land" — reaches the user as a sentence. The whole-UI review (I2) found the
/// button discarding it: the one answer the engine deliberately made observable, dropped on the
/// floor. A job id that is not running is exactly what an already-finished job looks like, so it
/// is the honest way to produce the `false` without racing a real CTAS.
@Test func aCancelThatCannotLandTellsTheUserInsteadOfPretending() async throws {
    let (state, _) = try await openedFixture(rows: 12)
    #expect(state.banner == nil)

    await state.cancelStaging("stage-no-such-job")
    #expect(state.banner == "That copy had already finished — nothing left to cancel.")
}

@MainActor
@Test func openingACSVPutsItInTheCatalogAndReadsItsFirstPage() async throws {
    let (state, model) = try await openedFixture(rows: 12)

    #expect(state.banner == nil)
    #expect(state.tables.count == 1)
    #expect(state.activeName == state.tables[0].name)
    #expect(state.active?.name == state.tables[0].name)

    #expect(model.columns.map(\.name) == ["id", "label", "note"])
    #expect(model.scrollExtent == 12)
    #expect(model.rowSlot(at: 0) != .pending)
}

/// `Session.state()` sorts by `openedAt` (it used to return `Array(tables.values)`, i.e. Swift
/// `Dictionary` order — measured different on every launch, so the tab bar shuffled). This pins
/// that the mirror keeps that order rather than re-keying it through a dictionary of its own.
@MainActor
@Test func tablesFollowTheOrderTheUserOpenedThem() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))

    var opened: [String] = []
    for name in ["alpha.csv", "bravo.csv", "charlie.csv", "delta_x.csv", "echo.csv"] {
        let path = try makeCSV(in: dir, name: name, rows: 3)
        await state.open(path: path)
        opened.append(try #require(state.activeName))
    }

    #expect(opened.count == 5)
    #expect(state.tables.map(\.name) == opened)
}

@MainActor
@Test func closingATableDropsItAndMovesTheSelection() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "first.csv", rows: 3))
    let first = try #require(state.activeName)
    await state.open(path: try makeCSV(in: dir, name: "second.csv", rows: 3))
    let second = try #require(state.activeName)
    #expect(state.tables.count == 2)

    await state.close(second)

    #expect(state.banner == nil)
    #expect(state.tables.map(\.name) == [first])
    // The selection followed the close rather than pointing at a table that no longer exists.
    #expect(state.activeName == first)
    #expect(state.active?.name == first)

    await state.close(first)
    #expect(state.tables.isEmpty)
    #expect(state.activeName == nil)
    #expect(state.active == nil)
}

/// Python emitted `{"type": "error"}` over SSE; there is no SSE, so the banner IS the
/// notification. A failed open that left `banner` nil would be a silent failure — the user clicks
/// Open, picks a file, and nothing at all happens.
@MainActor
@Test func openingAMissingFileBannersInsteadOfFailingSilently() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: tempDir().appendingPathComponent("not-here.csv").path)

    let banner = try #require(state.banner)
    #expect(banner.contains("No such file"))
    #expect(state.tables.isEmpty)
    #expect(state.activeName == nil)
}

/// One view model per open table, created lazily and *kept* — the web build cleared its blocks on
/// every tab switch and re-fetched (`resetGrid`). A fresh instance per call would silently restore
/// that behaviour once Task 5 puts a page cache inside.
@MainActor
@Test func theSameTableKeepsTheSameViewModel() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "a.csv", rows: 3))
    let a = try #require(state.activeName)
    await state.open(path: try makeCSV(in: dir, name: "b.csv", rows: 3))
    let b = try #require(state.activeName)

    let first = try #require(state.model(for: a))
    _ = try #require(state.model(for: b))          // switch away
    #expect(state.model(for: a) === first)          // and back

    #expect(state.model(for: "no-such-table") == nil)
}

/// …and a closed table's model goes with it. A table closed and reopened under the same name is a
/// DIFFERENT table (the engine says so — that is what `Table.openedAt` exists for), so serving it
/// the old model would hand the user a cache of the previous file's rows under the new file's name.
@MainActor
@Test func closingATableThrowsAwayItsViewModel() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    let path = try makeCSV(in: dir, name: "reopen.csv", rows: 3)
    await state.open(path: path)
    let name = try #require(state.activeName)
    let before = try #require(state.model(for: name))

    await state.close(name)
    await state.open(path: path)
    #expect(state.activeName == name)   // same name, second open

    let after = try #require(state.model(for: name))
    #expect(after !== before)
}

/// `refresh()` pushes the freshly-read catalog into every live view model. Proven with a planted
/// sentinel rather than by waiting for the background exact count to land: a 12-row CSV is counted
/// in milliseconds, so a test that merely waited for `rowCount == 12` would pass even if `apply`
/// were never called — the model would have been *constructed* with the finished table. The
/// sentinel is a value no real code path could produce, so only `apply` can clear it.
@MainActor
@Test func refreshPushesTheCatalogIntoEveryLiveViewModel() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, rows: 12))
    let name = try #require(state.activeName)
    let model = try #require(state.model(for: name))

    var planted = model.table
    planted.rowCount = 999_999
    model.apply(planted)
    #expect(model.table.rowCount == 999_999)

    await state.refresh()

    #expect(model.table.rowCount != 999_999)
}

/// Spec §9's non-negotiable: a real NULL, a real empty string and a cell whose text is literally
/// `N/A` are three different answers and must reach the grid as three different answers. The
/// fixture writes one of each in its `note` column, and `Cell.display` deliberately collapses the
/// first two — so this pins both halves: the page keeps the cases apart, and `SiftEngine.glyph`
/// (the ONE renderer, shared with the CLI) turns them into three distinct strings.
@MainActor
@Test func nullEmptyAndNAStayThreeDifferentThings() async throws {
    let (_, model) = try await openedFixture(rows: 12)

    let note = try #require(model.columns.firstIndex(where: { $0.name == "note" }))
    let rows: [[Cell]] = try (0..<3).map { row in
        guard case .loaded(let cells) = model.rowSlot(at: row) else {
            throw SessionError("row \(row) never loaded")
        }
        return cells
    }
    #expect(rows[0][note] == .null)
    #expect(rows[1][note] == .text(""))
    #expect(rows[2][note] == .text("N/A"))

    let kind = model.columns[note].kind
    // Module-qualified since Task 3: `SiftUI.glyph(for:kind:)` has the same argument labels and
    // returns a `CellGlyph`, so a bare call here is ambiguous. This one wants the ENGINE's strings —
    // the point of the assertion is that the shared renderer, the one the CLI also calls, keeps the
    // three states apart. `CellGlyphTests` covers the UI-side routing separately.
    let glyphs = (0..<3).map { SiftEngine.glyph(for: rows[$0][note], kind: kind) }
    #expect(glyphs == [nullGlyph, emptyStringGlyph, "N/A"])
    #expect(Set(glyphs).count == 3)
}

// MARK: - the two escape hatches
//
// 🔴 `Session.openPath(nullPadding:skipPreamble:)` has existed and been tested since the engine was
// written, the `sift` CLI has had both switches, and both notes end by telling the user to
// "re-open with null padding" / "re-open without skipping" — while `AppState.open`, the only way a
// path reaches the engine from the window, could pass NEITHER. The instruction on screen was one no
// Mac user had any way to follow. These drive the whole route: the note the engine attaches, the
// affordance `reopenFix` decides to show beside it, and the re-open recovering the real data.

/// A ragged file. The sniffer can find no consistent field count, settles on a delimiter the file
/// does not contain, and the whole thing reads as ONE column whose name is the header.
/// `SourceProbeTests` pins the engine half of this; these are the window half.
private let raggedCSVText = """
    order_id,region,amount
    1,Midwest,10
    2,West,20
    3,South,30,EXTRA,FIELDS
    4,East,40
    5,North,50,BOOM
    6,West,60

    """

/// Three lines of prose. The sniffer throws the first two away as a preamble and lands on a header
/// that matches no data at all, so the grid is empty and the file is not.
private let preambleCSVText = "notes\nthis is prose, with a comma\nanother line; semicolon too\n"

@discardableResult
private func write(_ text: String, _ name: String, in dir: URL) throws -> String {
    let path = dir.appendingPathComponent(name).path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@MainActor
@Test func theRaggedNotesButtonReallyRecoversTheColumns() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try write(raggedCSVText, "orders.csv", in: tempDir()))

    let collapsed = try #require(state.active)
    #expect(collapsed.spec.columns.map(\.name) == ["order_id,region,amount"], "not collapsed, so this tests nothing")
    let note = try #require(collapsed.notes.first)
    #expect(reopenFix(for: note, spec: collapsed.spec) == .nullPadding)

    await state.reopen(collapsed, with: .nullPadding)

    let fixed = try #require(state.active)
    #expect(state.banner == nil)
    // A REPLACEMENT. Opening without closing first would leave the collapsed `orders` sitting
    // beside a recovered `orders_2` for the user to tidy up.
    #expect(state.tables.count == 1, "the re-open sat beside the broken table instead of replacing it")
    #expect(fixed.name == "orders", "the recovered table lost the name the user already knows")
    #expect(fixed.spec.columns.map(\.name) == ["order_id", "region", "amount", "column3", "column4"])
    #expect(fixed.notes.isEmpty, "the note outlived its own fix")
}

@MainActor
@Test func thePreambleNotesButtonReallyGetsTheRowsBack() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try write(preambleCSVText, "prose.csv", in: tempDir()))

    let eaten = try #require(state.active)
    #expect(eaten.rowCount == 0, "the preamble did not eat the file, so this tests nothing")
    let note = try #require(eaten.notes.first)
    #expect(reopenFix(for: note, spec: eaten.spec) == .keepAllLines)

    await state.reopen(eaten, with: .keepAllLines)

    let fixed = try #require(state.active)
    #expect(state.banner == nil)
    #expect(state.tables.count == 1)
    #expect(fixed.name == "prose")
    #expect(fixed.spec.columns.map(\.name) == ["notes"])
    #expect(fixed.rowCount == 2, "the rows the preamble ate did not come back")
    #expect(fixed.notes.isEmpty)
}

/// The affordance appears beside the note that names it and nowhere else.
///
/// 🔴 The mapping is identity against the function that PRODUCES the note, not a keyword scan.
/// `Table.notes` is a flat `[String]` — sheet, folder, Delta and these two all arrive in one array
/// with nothing to tell them apart — so a `contains("null padding")` would offer a null-padded
/// re-open on a table whose spec never collapsed, and would stop firing silently the day the
/// sentence is reworded.
@MainActor
@Test func onlyTheNoteThatNamesAFixOffersOne() async throws {
    let dir = tempDir()
    let folder = dir.appendingPathComponent("parts")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try write("a,b\n1,2\n3,4\n", "one.csv", in: folder)
    try write("a,b\n5,6\n7,8\n", "two.csv", in: folder)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: folder.path)
    let table = try #require(state.active)
    let note = try #require(table.notes.first)
    #expect(note.contains("Folder read as one table"), "the fixture stopped producing a folder note")
    #expect(reopenFix(for: note, spec: table.spec) == nil, "a folder note offered an escape hatch")

    // A string that says the words is still not the note this table is showing.
    #expect(reopenFix(for: "Not every row has the same number of fields — re-open with null "
        + "padding to see all 5", spec: table.spec) == nil)
    #expect(reopenFix(for: "re-open without skipping to see them", spec: table.spec) == nil)
    #expect(reopenFix(for: "", spec: table.spec) == nil)
}

/// A close the engine refuses leaves ONE table, not two.
///
/// `close` reports the refusal on the banner and carries on, which is right — but a `reopen` that
/// then opened anyway would put a second copy of the file on screen under `orders_2` with the
/// engine's sentence sitting above it, which is the app doing something other than what the button
/// said.
@MainActor
@Test func aReopenWhoseCloseIsRefusedDoesNotOpenASecondCopy() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    let path = try write(raggedCSVText, "orders.csv", in: dir)
    await state.open(path: path)
    await state.open(path: path)
    #expect(state.tables.map(\.name) == ["orders", "orders_2"])

    _ = try await state.session.merge("orders", "orders_2", on: ["order_id,region,amount"])
    await state.refresh()
    #expect(state.tables.count == 3)

    let collapsed = try #require(state.tables.first { $0.name == "orders" })
    await state.reopen(collapsed, with: .nullPadding)

    #expect(state.tables.count == 3, "the refused close still let a second copy in")
    #expect(state.tables.first { $0.name == "orders" }?.spec.columns.count == 1)
    let banner = try #require(state.banner, "the refusal was swallowed")
    #expect(banner.contains("is merged into"))
}

/// The engine is polled, not subscribed. This opens a table *behind `AppState`'s back*, so the
/// only thing that can make it appear in the mirror is the poll loop actually running.
///
/// 🔴 Polls for the signal rather than asserting on the next line: a `Task {}` is not guaranteed
/// to have started when `startPolling()` returns, so an immediate assertion would be testing the
/// scheduler, not the loop.
@MainActor
@Test func pollingPicksUpACatalogChangeMadeBehindAppStatesBack() async throws {
    let dir = tempDir()
    let path = try makeCSV(in: dir, rows: 3)
    let session = try Session(home: tempHome())
    let state = AppState(session: session)

    state.startPolling()
    defer { state.stopPolling() }
    _ = try await session.openPath(path)

    #expect(await waitFor { state.tables.count == 1 })
}

/// The other half: a stopped loop stays stopped. The wait is longer than the idle cadence (2 s),
/// so a loop that was still running would have had at least one refresh in the window.
@MainActor
@Test func stopPollingActuallyStops() async throws {
    let dir = tempDir()
    let path = try makeCSV(in: dir, rows: 3)
    let session = try Session(home: tempHome())
    let state = AppState(session: session)

    state.startPolling()
    _ = try await session.openPath(path, name: "seen")
    #expect(await waitFor { state.tables.count == 1 })

    state.stopPolling()
    _ = try await session.openPath(path, name: "unseen")

    #expect(await waitFor(3) { state.tables.count == 2 } == false)
    #expect(state.tables.map(\.name) == ["seen"])
}

// MARK: - a closed table stays closed

/// 🔴 **I4.** `close(_:)` used to be `await closeTable` → `models[name] = nil` → `await refresh()`,
/// so `tables` still named the table across two suspension points. Nothing here is hypothetical:
/// the poll loop writes `tables` unconditionally every 250 ms–2 s, which invalidates every
/// `@Observable` reader whether or not the value moved, and both `RootView.body` and
/// `BannerStack.tableBanners` call `model(for:)` — which guards on the mirror and on nothing else.
/// A model rebuilt in that window throws `No open table named 'x'.` out of `loadFirstPage()`, onto
/// the banner, immediately after a close the user asked for.
///
/// This is the review's probe: put the mirror in exactly that state and show that the resurrection
/// is real, then show that a close the user asked for does not end in one.
///
/// 🔴 Stated so nobody trusts it for more than it is worth: the FIRST half is a standing statement
/// about a stale mirror — it survives any ordering, and it is what Phase 1 turns from a race into a
/// routine event, since a dropped remote connection is a table leaving the catalog with no user
/// action behind it. The ordering itself is pinned by
/// `closeDropsTheTableFromTheMirrorBeforeItAwaitsTheEngine` below, which is the mutation-sensitive
/// one.
@MainActor
@Test func aTableTheEngineHasClosedIsNotHandedBackAsAViewModel() async throws {
    let (state, _) = try await openedFixture(rows: 12)
    let name = try #require(state.activeName)

    // The window, reproduced: the engine has closed the table and the mirror has not caught up.
    try await state.session.closeTable(name)
    let resurrected = try #require(
        state.model(for: name), "precondition: a stale mirror is what makes this possible at all")
    await #expect(throws: (any Error).self, "the sentence that used to reach the banner") {
        try await resurrected.loadFirstPage()
    }

    // …and the same state reached the way a user reaches it — through `close(_:)` — leaves nothing
    // to resurrect.
    let (other, _) = try await openedFixture(rows: 12, name: "other.csv")
    let closing = try #require(other.activeName)
    await other.close(closing)
    #expect(other.model(for: closing) == nil)
    #expect(!other.tables.contains { $0.name == closing })
}

/// The half a completed `close(_:)` cannot show: the mirror has to be right *at the suspension
/// point*, not only afterwards. `Task.yield()` hands the actor to the enqueued close, which runs
/// until it awaits the engine — everything it has done by then is the fix.
///
/// Mutation: move `tables.removeAll` back below the `await` and this goes red.
@MainActor
@Test func closeDropsTheTableFromTheMirrorBeforeItAwaitsTheEngine() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "going.csv", rows: 3))
    await state.open(path: try makeCSV(in: dir, name: "staying.csv", rows: 3))
    let going = try #require(state.tables.first?.name)
    let staying = try #require(state.tables.last?.name)
    state.activeName = going

    state.presentExport()
    let closing = Task { await state.close(going) }
    await Task.yield()

    #expect(state.model(for: going) == nil, "the mirror still offered a model for a closing table")
    // …and the selection moved with it, so the detail pane never flashes its no-file-open state on
    // the way to the table that is still there.
    #expect(state.activeName == staying)
    // …and so did the sheet. `refresh()` reconciles it too, so this is the half of C2's first leg
    // that only the window can show: without the dismissal in `close(_:)` the sheet spends the
    // engine call with a subject that is not in the catalog, and `RootView` flashes its fallback.
    #expect(state.modalSheet == nil)
    await closing.value
    #expect(state.tables.map(\.name) == [staying])
}

/// A refused close changes NOTHING. `assertNoLiveMerge` throws while a merge reads the table, and
/// the optimistic mirror drop above must not survive that — the row comes back through `refresh()`
/// and the selection is put back in the `catch`.
@MainActor
@Test func aRefusedCloseLeavesTheCatalogAndTheSelectionExactlyWhereTheyWere() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    var orders = "order_id,amount\n"
    for i in 1...6 { orders += "\(i),\(i * 5)\n" }
    var returns = "order_id,reason\n"
    for i in 1...3 { returns += "\(i),damaged\n" }
    try orders.write(
        toFile: dir.appendingPathComponent("orders.csv").path, atomically: true, encoding: .utf8)
    try returns.write(
        toFile: dir.appendingPathComponent("returns.csv").path, atomically: true, encoding: .utf8)
    await state.open(path: dir.appendingPathComponent("orders.csv").path)
    await state.open(path: dir.appendingPathComponent("returns.csv").path)
    _ = try await state.session.merge("orders", "returns", on: ["order_id"], how: .inner)
    await state.refresh()
    state.activeName = "orders"

    await state.close("orders")

    let banner = try #require(state.banner, "a refusal the user cannot see is a silent failure")
    #expect(banner.contains("Close 'orders_returns' first."))
    #expect(state.tables.contains { $0.name == "orders" })
    #expect(state.activeName == "orders", "a close that did not happen must not move the selection")
    #expect(state.model(for: "orders") != nil)
}

// MARK: - a sheet whose table went away

/// 🔴 **C2, and it is a force-quit on two keystrokes.** ⌘W is a live main-menu key equivalent while
/// a SwiftUI sheet is up (a sheet is window-modal, not app-modal, so the menu bar stays live —
/// unlike `runModal`), and `validateMenuItem` answers "yes" because the table is still open at the
/// moment it is asked. Open Export, press ⌘W: the sheet's `if let t = state.active` body had no
/// else, painted zero pixels, and carried no `.cancelAction`, so Escape did nothing either.
///
/// The review's probe, verbatim: present, close, and the sheet must be gone.
///
/// Mutation: drop `dismissSheetWithoutASubject()` from `close(_:)` and the first assertion goes red.
@MainActor
@Test func closingTheTableUnderASheetTakesTheSheetWithIt() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "one.csv", rows: 3))
    let one = try #require(state.activeName)

    state.presentExport()
    #expect(state.modalSheet == .export(table: one))
    await state.closeActive()
    #expect(state.modalSheet == nil, "a sheet with no subject is a blank modal with no way out")

    // …and the same for the bad-rows sheet, which is raised by a single click on a title-bar label
    // and is therefore the one an accident puts up.
    await state.open(path: try makeCSV(in: dir, name: "two.csv", rows: 3))
    let two = try #require(state.activeName)
    state.modalSheet = .badRows(table: two)
    await state.close(two)
    #expect(state.modalSheet == nil)
}

/// Subject-aware, not blanket — which is the whole reason `ModalSheet` names its table.
///
/// Mutation: replace `dismissSheetWithoutASubject`'s body with `modalSheet = nil` and both halves
/// go red; make it compare against `activeName` instead of the catalog and the first half goes red.
@MainActor
@Test func aSheetAboutAnotherTableAndASheetAboutNoTableBothSurviveAClose() async throws {
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, name: "keep.csv", rows: 3))
    let keep = try #require(state.activeName)
    await state.open(path: try makeCSV(in: dir, name: "drop.csv", rows: 3))
    let drop = try #require(state.activeName)

    // Raised from the sidebar's ⤓ on a row that is not the selected one.
    state.presentExport(table: keep)
    #expect(state.modalSheet == .export(table: keep))
    await state.close(drop)
    #expect(state.modalSheet == .export(table: keep), "the wrong sheet was dismissed")

    // `.staged` is about the store on disk and has no table at all. A blanket dismissal would
    // close the one panel that tells the user where their copied data lives, mid-read.
    state.presentStaged()
    await state.close(keep)
    #expect(state.modalSheet == .staged)
}

/// The other half of the reconciliation: a table can leave the catalog without going through
/// `close(_:)` — `purgeStaged` skips open tables today, and Phase 1's dropped connection is a table
/// vanishing with no user action behind it at all. `refresh()` is the poll loop's own entry point,
/// so this is the leg that catches those.
///
/// Mutation: drop `dismissSheetWithoutASubject()` from `refresh()` and this goes red.
@MainActor
@Test func refreshAlsoDismissesASheetWhoseTableLeftTheCatalog() async throws {
    let (state, _) = try await openedFixture(rows: 12)
    let name = try #require(state.activeName)
    state.presentExport()
    #expect(state.modalSheet != nil)

    // Behind `AppState`'s back, the way a connection drops.
    try await state.session.closeTable(name)
    await state.refresh()

    #expect(state.modalSheet == nil)
}
