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
@Test func openingACSVPutsItInTheCatalogAndReadsItsFirstPage() async throws {
    let dir = tempDir()
    let path = try makeCSV(in: dir, rows: 12)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: path)

    #expect(state.banner == nil)
    #expect(state.tables.count == 1)
    #expect(state.activeName == state.tables[0].name)
    #expect(state.active?.name == state.tables[0].name)

    let model = try #require(state.model(for: state.tables[0].name))
    try await model.loadFirstPage()
    #expect(model.columns.map(\.name) == ["id", "label", "note"])
    #expect(model.firstPage.count == 12)
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
    let dir = tempDir()
    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: dir, rows: 12))
    let name = try #require(state.activeName)
    let model = try #require(state.model(for: name))
    try await model.loadFirstPage()

    let note = try #require(model.columns.firstIndex(where: { $0.name == "note" }))
    #expect(model.firstPage[0][note] == .null)
    #expect(model.firstPage[1][note] == .text(""))
    #expect(model.firstPage[2][note] == .text("N/A"))

    let kind = model.columns[note].kind
    // Module-qualified since Task 3: `SiftUI.glyph(for:kind:)` has the same argument labels and
    // returns a `CellGlyph`, so a bare call here is ambiguous. This one wants the ENGINE's strings —
    // the point of the assertion is that the shared renderer, the one the CLI also calls, keeps the
    // three states apart. `CellGlyphTests` covers the UI-side routing separately.
    let glyphs = (0..<3).map { SiftEngine.glyph(for: model.firstPage[$0][note], kind: kind) }
    #expect(glyphs == [nullGlyph, emptyStringGlyph, "N/A"])
    #expect(Set(glyphs).count == 3)
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
