import DuckDBKit
import Foundation
import SiftCore
import Testing
@testable import SiftEngine
@testable import SiftUI

// The view model over a REAL `Session` and a REAL file, like every other test in this target:
// `TablePage` has no public initializer, so a page cannot be faked, and none may be added to the
// engine to make a test easier.
//
// Nothing here asserts on a `Task` immediately after spawning it. A `Task {}` created on the
// MainActor cannot start before the next suspension point, so "the work is in flight" is not
// observable by construction — every background assertion below either drains the pump or polls
// for a signal that can only come from the work having finished.

// MARK: - the extent

@MainActor
@Test func theScrollExtentIsTheRowCountAndRowsArriveWhereTheyAreAskedFor() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)

    #expect(model.scrollExtent == 1_200)
    #expect(model.rowSlot(at: 0) != .pending, "the first page is loaded")
    #expect(model.rowSlot(at: 1_100) == .pending, "…and nothing beyond it is, until asked for")

    model.ensureVisible(firstRow: 1_090, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.rowSlot(at: 1_100) != .pending)
    if case .loaded(let cells) = model.rowSlot(at: 1_100) {
        #expect(cells[0] == .int(1_100), "the row at 1,100 is row 1,100, not block 2's first row")
    }
}

/// 🔴 **5a, the defect this task exists for.** `visibleRows` is nil until the detached background
/// count lands, and `buildSource` leaves `spec.rowCount` nil for every CSV over 64 MB — so an
/// extent taken from `visibleRows` alone is **0**, i.e. an empty grid on open, for exactly the
/// large text files the product is sold on opening instantly. `Table.displayRows` falls back to the
/// byte-sample estimate (Python's `summary()` did; the port dropped it).
///
/// Planted rather than generated: a real 64 MB fixture proves the same thing in
/// `RowExtentTests.aCSVOverTheExactCountThresholdOpensWithAnEstimateAndNoCount`, and repeating it
/// here would put 73 MB and a second and a half into a UI test to re-learn what the engine's own
/// suite already pins.
@MainActor
@Test func aTableStillCountingSizesItsGridFromTheEstimateInsteadOfShowingNothing() async throws {
    let (_, model) = try await openedFixture(rows: 12)

    let spec = SourceSpec(
        key: SourceKey(path: "/tmp/huge.csv", mtimeNs: 0, size: 3_000_000_000),
        fmt: .csv, readFn: "read_csv", columns: model.table.spec.columns,
        rowEstimate: RowEstimate(rows: 2_400_000, confidence: .low, basis: "3x256KiB sample")
    )
    // Same name, same generation, same staged-ness: this is the SAME open table mid-count, not a
    // different one — so `apply` must not treat it as a swap.
    let counting = SiftEngine.Table(
        name: model.name, spec: spec, qspec: QuerySpec(relation: model.name),
        openedAt: model.table.openedAt
    )
    #expect(counting.rowCount == nil && counting.visibleRows == nil)

    model.apply(counting)

    #expect(model.scrollExtent == 2_400_000, "an empty grid here is the whole defect")
    #expect(model.table.rowsAreExact == false)
    #expect(rowsBasisText(model.table.rowsBasis) == "3x256KiB sample")
}

/// Task 6's grid geometry needs a 100M-row extent without 100M rows, and there is no fixture for
/// that. The override is that seam, and `nil` must put the real table back in charge.
@MainActor
@Test func theExtentCanBeOverriddenForAGridWithNoFileBehindIt() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    model.overrideScrollExtentForTest(100_000_000)
    #expect(model.scrollExtent == 100_000_000)
    model.overrideScrollExtentForTest(nil)
    #expect(model.scrollExtent == 12)
}

@MainActor
@Test func theThreeRowBasisSentencesAreTheOnesPythonPrinted() {
    #expect(rowsBasisText(.counted) == "counted exactly")
    #expect(rowsBasisText(.estimated("3x256KiB sample, no quotes seen")) == "3x256KiB sample, no quotes seen")
    #expect(rowsBasisText(.pending) == "counting…")
}

// MARK: - the block pump

/// `OVERSCAN` is 8 rows either side (`web/index.html:423`), and it is what makes a scroll of one
/// row not show a placeholder. Both directions: the viewport here sits wholly inside one block, and
/// only the overscan reaches the neighbours.
@MainActor
@Test func ensureVisibleFetchesTheOverscanEitherSideOfTheViewport() async throws {
    let (_, model) = try await openedFixture(rows: 1_500)

    // Rows 1,000-1,019 are all in block 2. Without the leading overscan, block 1 is not needed.
    model.ensureVisible(firstRow: 1_000, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.rowSlot(at: 999) != .pending, "8 rows of leading overscan reach back into block 1")

    let (_, trailing) = try await openedFixture(rows: 1_500, name: "trailing.csv")
    // Rows 475-494 are all in block 0. Without the trailing overscan, block 1 is not needed.
    trailing.ensureVisible(firstRow: 475, rowsOnScreen: 20)
    await trailing.drainForTest()
    #expect(trailing.rowSlot(at: 500) != .pending, "…and 8 forward reach into block 1")
    #expect(trailing.rowSlot(at: 1_000) == .pending, "but no further than that")
}

// MARK: - spec changes

@MainActor
@Test func aFilterDropsTheCachedRowsAndSendsTheViewportBackToRowZero() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)
    model.ensureVisible(firstRow: 1_090, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.rowSlot(at: 1_100) != .pending)

    var reset = 0
    model.onViewportReset = { reset += 1 }
    try await model.setFilters([Filter(col: "id", op: .lt, values: [.int(12)])])
    await model.drainForTest()

    #expect(reset == 1, "a spec change is `resetGrid()`, not a re-request of where the thumb was")
    #expect(model.scrollExtent == 12, "…which is why: 1,200 rows just became 12")
    #expect(model.rowSlot(at: 0) != .pending, "row 0 was re-requested from the new spec")
    // Block 2 held rows 1,000-1,199 of the unfiltered table. Those rows do not exist under this
    // filter, so a cache that survived the change would still be handing them out.
    #expect(model.rowSlot(at: 1_100) == .pending)
}

@MainActor
@Test func aSortRebuildsTheRowsRatherThanKeepingTheOldOrder() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)
    guard case .loaded(let before) = model.rowSlot(at: 0) else {
        Issue.record("the first page never loaded"); return
    }
    #expect(before[0] == .int(0))

    try await model.setSort([QuerySpec.SortTerm(column: "id", direction: .desc)])
    await model.drainForTest()

    guard case .loaded(let after) = model.rowSlot(at: 0) else {
        Issue.record("the re-request after a sort never landed"); return
    }
    #expect(after[0] == .int(1_199), "descending, so row 0 is the last id — not the cached first one")
    #expect(model.scrollExtent == 1_200)
}

// MARK: - profiling

/// 🔴 **5c: nothing in the app ever computed a profile.** `runAfterOpen` deliberately does not, and
/// `merge` was the only caller of `computeProfile` in the tree — so column widths sat on their
/// fallback forever and the Schema tab rendered empty rows. Delete `kickProfile()`'s call in
/// `loadFirstPage` and this goes red.
@MainActor
@Test func theFirstPageKicksAProfileAndTheColumnsGetTheirStats() async throws {
    let (_, model) = try await openedFixture(rows: 300)
    #expect(await waitFor { !model.profile.isEmpty })

    #expect(model.profile.count == model.columns.count)
    #expect(model.profile.map(\.name) == model.columns.map(\.name))
    let id = try #require(model.profile.first { $0.name == "id" })
    #expect(id.n == 300)
}

/// The gate, from the UI's side. `kickProfile` calls `profileIfCheap`, never `computeProfile`, so a
/// source too big to profile unasked simply gets no profile — Python skips this too
/// (`session.py:454`). Point the table at a 30 GB spec and the kick must come back empty, on a
/// table whose profile is otherwise perfectly computable.
@MainActor
@Test func aSourceTooBigToProfileUnaskedIsLeftAlone() async throws {
    let (state, model) = try await openedFixture(rows: 300, name: "huge.csv")
    #expect(await waitFor { !model.profile.isEmpty }, "small: profiled")

    // A second table, same file, wearing a 30 GB spec.
    let session = state.session
    let big = try await session.openPath(
        try makeCSV(in: tempDir(), name: "also-huge.csv", rows: 300), name: "big")
    let inflated = SourceSpec(
        key: SourceKey(path: big.spec.key.path, mtimeNs: big.spec.key.mtimeNs, size: 30_000_000_000),
        fmt: .csv, readFn: big.spec.readFn, readArgs: big.spec.readArgs, columns: big.spec.columns
    )
    await session.setSourceSpecForTest("big", inflated)
    await state.refresh()

    let bigModel = try #require(state.model(for: "big"))
    try await bigModel.loadFirstPage()
    await bigModel.drainForTest()

    #expect(bigModel.profile.isEmpty, "30 GB: a SUMMARIZE nobody asked for is minutes of scan")
    #expect(bigModel.rowSlot(at: 0) != .pending, "…and the grid works regardless")
    // The gate refused; it is not that the profile is impossible. A panel the user opens still gets
    // one, exactly as Python leaves `profile_of` ungated.
    let asked = try await session.computeProfile("big")
    #expect(asked.count == 3)
}

/// The `profileTask` guard, and the only claim this task makes about profiling's timing. Two kicks
/// with no suspension between them — which is the whole point, since a suspension would let the
/// first finish and the second would be turned away by `profile.isEmpty` instead.
@MainActor
@Test func twoKicksInARowProduceOneProfile() async throws {
    let (_, model) = try await openedFixture(rows: 300)
    var arrived = 0
    model.onProfileArrived = { arrived += 1 }

    model.kickProfile()
    model.kickProfile()

    #expect(await waitFor { arrived == 1 })
    #expect(await waitFor(2) { arrived > 1 } == false, "the second kick must not run its own job")
    #expect(!model.profile.isEmpty)

    // And once it has one, a later kick does not re-run it either — the other half of the guard.
    model.kickProfile()
    #expect(await waitFor(2) { arrived > 1 } == false)
}

// MARK: - staging

/// The relation is swapped view→native table under the name, so every cached row describes
/// something that no longer exists. The web cleared its blocks on the `staged` event
/// (`web/index.html:1838-1843`); with polling instead of SSE, `apply` is the only place that can
/// see the edge.
@MainActor
@Test func aStagedSwapDropsTheCachedRowsAndReRequestsThem() async throws {
    let (state, model) = try await openedFixture(rows: 1_200, name: "stageme.csv")
    model.ensureVisible(firstRow: 1_090, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.rowSlot(at: 1_100) != .pending)
    #expect(model.table.staged == false)

    var delivered: [Int] = []
    model.onBlockDelivered = { delivered.append($0) }
    // Well under the staging threshold, so `force` — the copy itself is what this is about.
    _ = try await state.session.stageNow(model.name, force: true)
    await waitForCatalog(state, "the staged swap") { model.table.staged }

    // Block 2 was already cached and the viewport has not moved, so the ONLY way it can be
    // delivered again is the swap having dropped the cache and re-asked for it. Both halves die
    // if either `cache.removeAll()` or `requestCurrentViewport()` is deleted from `apply`.
    #expect(await waitFor { delivered.contains(2) })
    await model.drainForTest()
    guard case .loaded(let rows) = model.rowSlot(at: 1_100) else {
        Issue.record("the re-request against the staged copy never landed"); return
    }
    #expect(rows[0] == .int(1_100), "…and it is the same row 1,100, read out of the copy")
    #expect(model.scrollExtent == 1_200)
}
