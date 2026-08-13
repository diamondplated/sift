import AppKit
import DuckDBKit
import Foundation
import SiftCore
import SwiftUI
import Testing
@testable import SiftEngine
@testable import SiftUI

// SQL mode: the console, the one-way door, and the extent that has to grow because nothing counted
// the result.
//
// Every test here drives a REAL `Session` over a REAL file — `TablePage` has no public initializer,
// so a page cannot be faked, and none may be added to the engine to make a test easier.
//
// 🔴 **The gate assertions below assert on the MESSAGE, never merely that something threw.** With
// the guard deleted from `Session.runSQL`, `DROP TABLE x` still throws — from `wrapUserSQL`'s
// subquery wrap, as a DuckDB parse error — so a bare `#expect(throws:)` passes on an engine with no
// gate at all. Pinning the sentence is what makes these tests notice.

/// AppKit's appearance system wants an app object to exist before any `NSView` is constructed, even
/// headlessly (`GridBridgeTests` says the same, one file over).
@MainActor
private func appKitReady() { _ = NSApplication.shared }

// MARK: - running a query

@MainActor
@Test func runningASelectPagesItsOwnColumnsAndRowsAndNotTheTables() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    #expect(model.columns.map(\.name) == ["id", "label", "note"])

    model.typeSQL("SELECT 1 AS n")
    try await model.runSQL()

    #expect(model.columns.map(\.name) == ["n"], "the result's columns, not the file's")
    guard case .loaded(let row) = model.rowSlot(at: 0) else {
        Issue.record("the SQL result's first row never landed"); return
    }
    #expect(row == [.int(1)])
    #expect(model.scrollExtent == 1, "one row, and the grid may reach exactly one row")
    #expect(model.rowSlot(at: 1) == .pending, "…and nothing past the end is loaded")
}

// MARK: - the gate, which is the engine's

/// 🔴 The one that proves the guard is consulted at all. Delete `try assertSelectOnly(sql)` from
/// `Session.runSQL` and the wrap still refuses this — with `Parser Error: syntax error at or near
/// "DROP"`, which is exactly the parser dump the guard exists to replace. So the assertion is the
/// sentence, character for character.
@MainActor
@Test func aNonSelectComesBackAsTheGuardsOwnSentence() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    model.typeSQL("DROP TABLE t")

    await #expect(throws: SQLRejected.self) { try await model.runSQL() }
    do {
        try await model.runSQL()
        Issue.record("a DROP reached the database")
    } catch {
        #expect(
            error.localizedDescription
                == "Sift only runs SELECT queries, and this starts with DROP. "
                    + "Sources are opened read-only; use the Export button to write a file.")
    }

    // …and a refusal is not a state change. The table the user was looking at is still theirs.
    #expect(model.table.sqlMode == false)
    #expect(model.table.sqlText == nil)
    #expect(model.columns.map(\.name) == ["id", "label", "note"])
    #expect(model.rowSlot(at: 0) != .pending, "the rows on screen survived the refusal")
    #expect(model.scrollExtent == 12)
}

/// The two rejections a leading-keyword check cannot make on its own: a second statement after a
/// semicolon, and a second statement hidden behind a comment. Both are counted by DuckDB's own
/// parser inside `assertSingleSelectStatement`, and both must still arrive as a sentence.
@MainActor
@Test func aSecondStatementIsRefusedEvenWhenACommentHidesIt() async throws {
    let (_, model) = try await openedFixture(rows: 12)

    func message(_ sql: String) async -> String {
        model.typeSQL(sql)
        do {
            try await model.runSQL()
            return "(it ran)"
        } catch {
            return error.localizedDescription
        }
    }

    let expected = "Sift runs one statement at a time — it found 2. "
        + "Remove the semicolon and everything after it."
    #expect(await message("SELECT 1; DROP TABLE t") == expected)
    #expect(await message("SELECT 1 --hidden\n; DROP TABLE t") == expected)
    #expect(await message("SELECT 1 /* hidden */; DROP TABLE t") == expected)

    // A semicolon INSIDE a literal is one statement and a perfectly good query — the case the
    // engine's header calls out, and the reason none of this is done by scanning for `;`.
    model.typeSQL("SELECT '; DROP TABLE t' AS s")
    try await model.runSQL()
    guard case .loaded(let row) = model.rowSlot(at: 0) else {
        Issue.record("a legitimate query with a semicolon in a literal was refused"); return
    }
    #expect(row == [.text("; DROP TABLE t")])
}

/// 🔴 **A prepare failure is not a guard rejection.** `SELECT * FROM nonexistent` cannot be
/// prepared, but it is legitimate SQL against a table the user has not opened — the landmine
/// `GuardStatements.swift` exists to close. The engine lets it through and reports the catalog
/// error; the console must not turn that into a refusal, and must not swallow it either.
@MainActor
@Test func aPrepareFailureReportsTheEnginesErrorAndNotARefusal() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    model.typeSQL("SELECT * FROM definitely_not_a_table")

    do {
        try await model.runSQL()
        Issue.record("a query against a missing table appeared to succeed")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("definitely_not_a_table"), "the engine's own sentence: \(message)")
        #expect(!message.contains("Sift only runs SELECT"), "this is not a refusal")
        #expect(!(error is SQLRejected))
    }

    // The engine flipped into SQL mode before running the query (`Session.runSQL` sets the flags
    // first), so the grid is emptied rather than left showing the previous table's rows under a
    // query that never produced any.
    #expect(model.table.sqlMode, "the engine moved, and the model read it back rather than guessing")
    #expect(model.scrollExtent == 0)
    #expect(model.rowSlot(at: 0) == .pending)
}

// MARK: - the one-way door

@MainActor
@Test func takingOverTheBoxIsAOneWayDoorAndResetIsTheOnlyExit() async throws {
    let (state, model) = try await openedFixture(rows: 12)
    let session = state.session
    try await model.mirrorRenderedSQL()
    #expect(model.sqlText == "SELECT *\nFROM \"t\"", "the box mirrors the filters to begin with")
    #expect(model.sqlOwned == false)

    model.typeSQL("SELECT id FROM t WHERE id > 8")
    #expect(model.sqlOwned, "typing claims the box")
    try await model.runSQL()

    #expect(model.table.sqlMode)
    #expect(model.table.sqlText == "SELECT id FROM t WHERE id > 8")
    #expect(try await session.renderedSQL("t") == "SELECT id FROM t WHERE id > 8")
    #expect(model.scrollExtent == 3, "ids 9, 10, 11")

    // 🔴 And re-mirroring while in SQL mode hands back the USER's text and leaves the box claimed —
    // re-selecting a tab must not tell them their query mirrors filters it has nothing to do with.
    try await model.mirrorRenderedSQL()
    #expect(model.sqlText == "SELECT id FROM t WHERE id > 8")
    #expect(model.sqlOwned)

    try await model.exitSQLMode()

    #expect(model.table.sqlMode == false)
    #expect(model.table.sqlText == nil)
    #expect(model.sqlOwned == false, "the status line goes back to saying the box is a mirror")
    #expect(model.sqlText == "SELECT *\nFROM \"t\"", "re-mirrored, not cleared")
    #expect(try await session.renderedSQL("t") == "SELECT *\nFROM \"t\"")

    // The whole table is back: its own columns, its own rows, its own extent.
    #expect(model.columns.map(\.name) == ["id", "label", "note"])
    #expect(model.scrollExtent == 12, "the SQL result's extent does not outlive SQL mode")
    guard case .loaded(let row) = model.rowSlot(at: 0) else {
        Issue.record("the table's first page never came back"); return
    }
    #expect(row[0] == .int(0))
}

/// The status line is the one-way-door warning, and it says one of exactly two things
/// (`web/index.html:1762, 1770`).
@MainActor
@Test func theStatusLineSaysWhichOfTheTwoThingsTheBoxIs() async throws {
    #expect(sqlStatusText(owned: false) == "mirrors the filters above")
    #expect(sqlStatusText(owned: true) == "your SQL — filters and header controls are frozen")

    // 🔴 The mirror must not claim the box. The web told a user edit from a programmatic write
    // apart with the `input` event; SwiftUI cannot, so `typeSQL` is the only thing that claims.
    let (_, model) = try await openedFixture(rows: 12)
    try await model.mirrorRenderedSQL()
    #expect(model.sqlText.hasPrefix("SELECT *"), "the mirror wrote to the box…")
    #expect(sqlStatusText(owned: model.sqlOwned) == "mirrors the filters above", "…without claiming it")

    // Nor does a no-op write from the editor re-binding to the same string.
    model.typeSQL(model.sqlText)
    #expect(model.sqlOwned == false)

    model.typeSQL("SELECT 1")
    #expect(sqlStatusText(owned: model.sqlOwned) == "your SQL — filters and header controls are frozen")
}

// MARK: - the extent, which grows

/// `fetchBlock`'s three-way (`web/index.html:846-855`) as a function, at every edge. A SQL result
/// has no exact count, so a FULL block can only promise one more row and a SHORT one is the end.
@Test func theSQLExtentGrowsOnAFullBlockAndIsPinnedByAShortOne() {
    #expect(sqlModeExtent(0, block: 0, rows: 3) == 3, "a short first block IS the whole result")
    #expect(sqlModeExtent(0, block: 0, rows: 0) == 0, "…and an empty one is an empty grid")
    #expect(sqlModeExtent(0, block: 0, rows: pageRows) == pageRows + 1, "full: at least one more row")
    #expect(sqlModeExtent(pageRows + 1, block: 1, rows: pageRows) == 2 * pageRows + 1)
    #expect(sqlModeExtent(2 * pageRows + 1, block: 2, rows: 7) == 2 * pageRows + 7, "the end, exactly")

    // 🔴 `max` on the growing branch and NOWHERE ELSE, both halves. Blocks arrive
    // nearest-the-viewport-first, so the two out-of-order cases pull in opposite directions:
    //   - a FULL block landing after the short one that found the end must not re-grow past it…
    #expect(sqlModeExtent(2 * pageRows + 7, block: 1, rows: pageRows) == 2 * pageRows + 7)
    //   - …and a SHORT block must SHRINK an extent a speculative full block had grown, because it
    //     is the end of the result and the grown one was only ever a guess. `max` here would leave
    //     the scroll bar reaching 501 rows into a three-row answer.
    #expect(sqlModeExtent(pageRows + 1, block: 0, rows: 3) == 3)
    // A full block never shrinks anything, though.
    #expect(sqlModeExtent(9_999, block: 0, rows: pageRows) == 9_999)
}

/// The same rule against a real query, through the real block pump: in SQL mode the grid pages the
/// user's own text at an offset, and the extent it can reach grows to meet each block.
@MainActor
@Test func sqlModeBlocksArePagedFromTheUsersQueryAndTheExtentGrowsToMeetThem() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)
    model.typeSQL("SELECT id FROM t ORDER BY id")
    try await model.runSQL()

    #expect(model.scrollExtent == pageRows + 1, "block 0 came back full: 501, not 1,200")
    #expect(model.rowSlot(at: 499) != .pending)
    #expect(model.rowSlot(at: 500) == .pending)

    model.ensureVisible(firstRow: 480, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.scrollExtent == 2 * pageRows + 1, "block 1 was full too")
    guard case .loaded(let row) = model.rowSlot(at: 700) else {
        Issue.record("block 1 was never paged out of the user's query"); return
    }
    #expect(row == [.int(700)], "…and it is the query's row 700, one column wide")

    model.ensureVisible(firstRow: 980, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.scrollExtent == 1_200, "block 2 was short — that is the end of the result")
    #expect(model.rowSlot(at: 1_199) != .pending)
}

/// 🔴 **The gate is on every block, not just the first.** A SQL-mode table is paged by re-running
/// the stored text at an offset, and `Session.page` would do that too — it has its own
/// `wrapUserSQL` branch — but without re-asserting the SQL first. So this plants text in
/// `Table.sqlText` that never passed the gate (which is what any route other than `runSQL` writing
/// that field looks like) and asks for a block: the refusal has to be the guard's, in its own
/// words. Under `Session.page` the same text still fails — as a DuckDB parse error out of the wrap,
/// which is a `SessionError` and a parser dump, and is why this asserts the type AND the sentence.
@MainActor
@Test func everyBlockInSQLModeGoesBackThroughTheGate() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)
    var forged = model.table
    forged.sqlMode = true
    forged.sqlText = "DROP TABLE t"
    model.apply(forged)

    await #expect(throws: SQLRejected.self) { _ = try await model.fetchBlock(1) }
    do {
        _ = try await model.fetchBlock(1)
        Issue.record("a block fetch ran a DROP")
    } catch {
        #expect(
            error.localizedDescription
                == "Sift only runs SELECT queries, and this starts with DROP. "
                    + "Sources are opened read-only; use the Export button to write a file.")
    }

    // And the ordinary path is unaffected: with no SQL mode, a block is the table's own rows.
    let (_, plain) = try await openedFixture(rows: 1_200, name: "plain.csv")
    let block = try await plain.fetchBlock(1)
    #expect(block.rows.first?.first == .int(500))
}

/// 🔴 **Entering SQL mode ABANDONS the filters — it does not compose with them**, which is the half
/// of the one-way door a status line cannot prove on its own. Every block goes through
/// `Session.runSQL`, whose only addition to the user's text is `wrapUserSQL`'s LIMIT/OFFSET.
///
/// The mutation this exists for: paging SQL mode through `Session.page` instead. That looks
/// harmless — `Session.relation` already puts `sqlText` in a subquery position — and on an
/// unfiltered table it is indistinguishable. With a filter set it silently ANDs the abandoned
/// `WHERE` back onto the user's query, and the guard stops being re-run per block into the bargain.
@MainActor
@Test func enteringSQLModeAbandonsTheFiltersRatherThanComposingWithThem() async throws {
    let (_, model) = try await openedFixture(rows: 1_200)
    try await model.setFilters([Filter(col: "id", op: .lt, values: [.int(12)])])
    await model.drainForTest()
    #expect(model.scrollExtent == 12, "the filter is live going in")

    model.typeSQL("SELECT * FROM t")
    try await model.runSQL()
    #expect(model.scrollExtent == pageRows + 1, "the query sees all 1,200 rows, not the filtered 12")

    // Block 1 is the assertion: under the filter it does not exist at all, so a page that still
    // carried the `WHERE` would hand back nothing and pin the extent at 500.
    model.ensureVisible(firstRow: 480, rowsOnScreen: 20)
    await model.drainForTest()
    #expect(model.scrollExtent == 2 * pageRows + 1)
    guard case .loaded(let row) = model.rowSlot(at: 700) else {
        Issue.record("row 700 does not survive a filter that was supposed to be abandoned"); return
    }
    #expect(row[0] == .int(700))

    // …and `Reset to filters` puts them back. That is what makes the door one-way rather than shut.
    try await model.exitSQLMode()
    #expect(model.scrollExtent == 12)
}

// MARK: - the pane, drawn
//
// 🔴 **Nothing below measures a pixel COUNT, a COORDINATE, or a `* scale` term, and that is not
// style — it is the fix for a real CI failure.** The first version of the status-line check asserted
// that the claimed sentence's ink reached at least 40 pt further right than the mirrored one's. It
// passed here and failed on the macos-15 runner with both renders ending at the same column, because
// a headless runner's backing scale, font rasterization and available typefaces are all different
// from this Mac's — so the number being compared described the environment as much as the code.
// Widening the margin only moves the point at which it lies. Every assertion here is now a
// RELATIONSHIP (these two renders differ / these two are identical) or a PROPORTION of the pane
// (most of it is dark), neither of which has a value to calibrate.
//
// The two renderers each do the half the other cannot, and `InspectorRenderTests`'s header documents
// the same split from the other side:
//   * `ImageRenderer` draws SwiftUI text faithfully and hands back a prohibited-symbol placeholder
//     for anything AppKit-backed — here, the `TextEditor`. Fine for the status line, since the
//     placeholder is identical in both renders being compared.
//   * `NSHostingView` + `cacheDisplay` draws the AppKit-backed control and the pane's own
//     background, and drops much of the SwiftUI-drawn text. Fine for "is it dark", which is what it
//     is used for and all it is used for.

/// 🔴 The status line actually REDRAWS when the box is claimed — a claim no property read can make,
/// and the same class of defect as the empty-string cell that reported a dotted rule from every
/// property while AppKit quietly declined to draw an underline under whitespace.
///
/// The two renders being compared differ in `sqlOwned` and in **nothing else**: `typeSQL` is bounced
/// off an intermediate string and back to the mirrored text, so `sqlText` is byte-identical going
/// into both. The only things that can move a pixel are the sentence, its weight and its colour.
///
/// It does not distinguish WHICH of those three moved, and does not try to — MEASURED by mutation:
/// pinning `sqlStatusText` to one string leaves this green, because the weight and colour still
/// change. The copy is pinned by `theStatusLineSaysWhichOfTheTwoThingsTheBoxIs`, which compares the
/// strings directly; what this adds is that the line is drawn at all and is redrawn on the flip
/// (replace the `Text` with an empty one and this is the only test that goes red).
///
/// **Why this survives a different renderer.** The assertions are "these two images are equal" and
/// "these two are not". Both are decided entirely inside one process, by one rasterizer, on two
/// images it produced itself — a different backing scale, a different font, or different subpixel
/// antialiasing changes both images the same way and cancels out. The control render is what makes
/// the inequality mean something: it proves this renderer is deterministic here, so a difference can
/// only have come from the state that changed. A renderer too unstable for that fails the CONTROL,
/// loudly, instead of making the real assertion flaky.
@MainActor
@Test func theStatusLineRedrawsWhenTheBoxIsClaimed() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    try await model.mirrorRenderedSQL()
    let mirroredText = model.sqlText

    func pixels() throws -> Data {
        let renderer = ImageRenderer(
            content: SQLConsole(model: model, onError: { _ in })
                .frame(width: 900, height: 130, alignment: .topLeading))
        let image = try #require(renderer.cgImage, "ImageRenderer produced no image at all")
        // The raw buffer, compared byte for byte. Deliberately NOT hashed: `Data.hash(into:)` mixes
        // in at most the first 80 bytes, which on a 900-pt render is blank margin — the trap
        // `InspectorRenderTests.pixelDigest` documents, and `==` simply does not have it.
        return try #require(image.dataProvider?.data) as Data
    }

    let unclaimed = try pixels()
    let control = try pixels()
    #expect(control == unclaimed, "rendering is not deterministic here — nothing below means anything")

    model.typeSQL("")
    model.typeSQL(mirroredText)
    #expect(model.sqlText == mirroredText, "the same text going in…")
    #expect(model.sqlOwned, "…and the only difference is that the box is now claimed")

    #expect(try pixels() != unclaimed, "the status line did not redraw when the box was claimed")
}

/// 🔴 The console is a CONSOLE — a light box of monospaced text is the defect, and `.background`
/// silently not applying is exactly the kind of thing every property on the view denies.
///
/// **Why this survives a different renderer.** It asks what fraction of the pane is dark, not what
/// colour sits at one coordinate. The background covers essentially all of a 900 × 130 pane in any
/// layout a renderer could produce; text ink and two small buttons cannot approach a fifth of it. So
/// the 80% floor has enormous headroom in both directions and no calibration in it. The opacity
/// check is there because "dark" is also what a bitmap that was never drawn into looks like — that
/// is the vacuous pass this would otherwise have.
@MainActor
@Test func theConsoleDrawsOnADarkSurfaceAndNotADocumentOne() async throws {
    appKitReady()
    let (_, model) = try await openedFixture(rows: 12)
    try await model.mirrorRenderedSQL()

    let host = NSHostingView(rootView: SQLConsole(model: model, onError: { _ in }))
    // 🔴 Pinned to Aqua — and for this view that is more than hygiene: the console is deliberately
    // dark in BOTH appearances, so an unpinned render here would have been passing in dark while
    // the same pane in light appearance drew invisible buttons (`AppearanceTests`).
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 130)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)

    // Every 3rd pixel each way — a sample of the whole pane rather than a point on it, so the answer
    // does not depend on where anything landed.
    var opaque = 0
    var dark = 0
    var total = 0
    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            total += 1
            if colour.alphaComponent > 0.9 { opaque += 1 }
            if colour.alphaComponent > 0.9 && colour.brightnessComponent < 0.3 { dark += 1 }
        }
    }

    #expect(total > 0)
    #expect(Double(opaque) / Double(total) > 0.95, "the pane never drew — everything below is vacuous")
    #expect(Double(dark) / Double(total) > 0.8, "a console, not a document surface")
}

/// 🔴 The one-way-door sentence is the warning; a truncated warning is not one. AppKit's own answer
/// to "did this have to draw an ellipsis" is `expansionFrame` — non-empty exactly when a cell
/// elided, the same machinery that draws the "…". Comparing `intrinsicContentSize` against a frame
/// is NOT this assertion (`GridBridgeTests` measured it eliding inside a frame it "fit" in).
///
/// The budget is the space the bar leaves the status line beside its two buttons in a narrow
/// window; a copy change that overruns it goes red here rather than on someone's screen.
///
/// **Why this survives a different renderer**, unlike the pixel comparison this file used to carry:
/// it measures a STRING in a FONT, not a rendered layout. MEASURED at 274.1 pt against a 300 pt
/// budget — 9% headroom, where SF Pro's metrics move by fractions of a percent between macOS
/// versions and a fallback to Helvetica moves them by about 5%. What can consume 9% is a longer
/// sentence, which is exactly what this is here to catch.
@MainActor
@Test func theOneWayDoorSentenceFitsTheBarWithoutEliding() {
    appKitReady()
    let field = NSTextField(labelWithString: sqlStatusText(owned: true))
    field.font = .systemFont(ofSize: 11, weight: .bold)
    field.lineBreakMode = .byTruncatingTail
    field.frame = NSRect(x: 0, y: 0, width: sqlBarStatusBudget, height: 16)
    field.layoutSubtreeIfNeeded()

    let cell = field.cell
    #expect(cell?.expansionFrame(withFrame: field.bounds, in: field).isEmpty == true)
    #expect(field.attributedStringValue.size().width <= sqlBarStatusBudget)
}

/// Points the bar has for its status line once the two buttons and the 10-pt padding are out of a
/// 520-pt pane — the narrowest the centre column is worth using.
private let sqlBarStatusBudget: CGFloat = 300
