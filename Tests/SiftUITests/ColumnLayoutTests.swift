import AppKit
import Foundation
import SiftCore
import Testing
@testable import SiftEngine
@testable import SiftUI

// The column headers: the arithmetic they run, and the pixels they end up as.
//
// The file splits the same way the code does. Everything above `MARK: - the header, drawn` is a
// function over values and needs no window, no file and no DuckDB. Everything below it renders a
// real `NSTableHeaderView` through `cacheDisplay(in:to:)` and reads the bitmap back, because Task 6
// found two defects that every property-level assertion had already passed: an empty-string cell
// that drew nothing at all, and a row number that elided. A header that computes `≈1.2M` and paints
// it under the type it is supposed to sit beside is the same defect in a new place, and only a
// bitmap notices.
//
// (`cacheDisplay` is the only capture route that works here: Screen Recording is not granted and
// Accessibility returns zero windows. It also cannot capture an `NSVisualEffectView`, which is why
// this renders the header view alone rather than a window.)

/// AppKit wants an app object before any `NSView` exists, even headlessly. Idempotent.
@MainActor
private func appKitReady() { _ = NSApplication.shared }

private func col(_ name: String, _ type: String = "VARCHAR") -> Column {
    Column(name: name, type: type)
}

private func profile(
    _ name: String, n: Int = 0, nNull: Int = 0, nEmpty: Int = 0, nUncastable: Int = 0,
    approx: Int = 0, exact: Int? = nil, maxLen: Int? = nil
) -> ColumnProfile {
    ColumnProfile(
        name: name, type: "VARCHAR", kind: .text, n: n, nNull: nNull, nEmpty: nEmpty,
        approxDistinct: approx, exactDistinct: exact, maxLen: maxLen, nUncastable: nUncastable)
}

// MARK: - widths

/// `computeWidths` (`web/index.html:576-583`), branch by branch. Every column here lands on a
/// different one of the four answers on purpose — a formula with the wrong multiplier still returns
/// 76 for any short column, so a fixture of short columns would pass on a broken implementation.
@Test func everyBranchOfTheWebsWidthFormulaSurvivesThePort() {
    let cols = [
        col("id"), col("description"), col("a_very_long_column_name_here_x"), col("blob"),
    ]
    #expect(columnWidths(cols, profile: []) == [120, 120, 254, 120], "no profile: the fallback")

    let profiled = [
        profile("id", maxLen: 2),           //  34.8 by data, 41.2 by name → the 76 floor
        profile("description", maxLen: 20),  // 168 by data beats 109.6 by name
        profile("a_very_long_column_name_here_x", maxLen: 1),  // 254 by name beats 27.4 by data
        profile("blob", maxLen: 60),         // capped at 42 chars (330.8), then clamped to 320
    ]
    #expect(columnWidths(cols, profile: profiled) == [76, 168, 254, 320])

    // A profile with no `max_len` at all — the `p.max_len ?` in the original. Not a zero-width
    // column: a column of all-NULLs has no measured length and must keep the fallback.
    #expect(columnWidths([col("id")], profile: [profile("id", maxLen: nil)]) == [120])
    #expect(columnWidths([col("id")], profile: [profile("id", maxLen: 0)]) == [120])

    // …and a profile for some *other* table's column does not silently apply to this one.
    #expect(columnWidths([col("id")], profile: [profile("elsewhere", maxLen: 40)]) == [120])

    // The clamp is what stops a 4 KB JSON blob asking for a 30,000-point column. The 42-character
    // cap beside it is dead arithmetic and is kept only because this is a line-by-line port: 42
    // characters is 330.8 pt, already past the 320 clamp, so no input exists for which the cap
    // changes the answer. Said out loud because an assertion that claimed to test it would be
    // vacuous, and twelve vacuous tests have already been caught on this branch.
    #expect(columnWidths([col("j")], profile: [profile("j", maxLen: 4_000)]) == [320])
    #expect(columnWidths([col("j")], profile: [profile("j", maxLen: 42)]) == [320])
    #expect(columnWidths([col("j")], profile: [profile("j", maxLen: 30)]) == [242])
}

// MARK: - sort

/// `cycleSort` (`web/index.html:870-874`): none → asc → desc → none.
@Test func clickingAColumnCyclesItThroughAscendingDescendingAndOff() {
    let none: [QuerySpec.SortTerm] = []
    let asc = nextSort(for: "price", current: none)
    #expect(asc == [QuerySpec.SortTerm(column: "price", direction: .asc)])

    let desc = nextSort(for: "price", current: asc)
    #expect(desc == [QuerySpec.SortTerm(column: "price", direction: .desc)])

    #expect(nextSort(for: "price", current: desc).isEmpty, "the third click clears it")
}

/// 🔴 The second column REPLACES the first rather than adding to it — the web's `cycleSort` builds a
/// single-element list, and a sorted table is capped at what the engine materialized, so every extra
/// key is another full pass over the file.
@Test func sortingASecondColumnReplacesTheFirstRatherThanAddingToIt() {
    let byPrice = [QuerySpec.SortTerm(column: "price", direction: .desc)]
    let byName = nextSort(for: "name", current: byPrice)
    #expect(byName == [QuerySpec.SortTerm(column: "name", direction: .asc)])
    #expect(byName.count == 1)

    // And the cycle for the newly clicked column starts at the beginning, rather than inheriting
    // the direction the previous column happened to be sorted in.
    #expect(byName.first?.direction == .asc)
}

// MARK: - counts

/// The web's `compact` (`web/index.html:630-633`).
@Test func distinctCountsAreShortenedTheWayTheWebGridShortenedThem() {
    #expect(compactCount(0) == "0")
    #expect(compactCount(999) == "999")
    #expect(compactCount(1_000) == "1.0k")
    #expect(compactCount(1_500) == "1.5k")
    #expect(compactCount(9_999) == "10.0k", "one decimal right up to the 10k boundary")
    #expect(compactCount(10_000) == "10k", "…and none above it, because there is no room for one")
    #expect(compactCount(42_400) == "42k")
    #expect(compactCount(999_999) == "1000k")
    #expect(compactCount(1_000_000) == "1.0M")
    #expect(compactCount(1_240_000) == "1.2M")
    #expect(compactCount(45_000_000) == "45.0M")

    // 🔴 The rounding is JavaScript's `toFixed`, which rounds an exact tie AWAY from zero — not
    // `printf("%.0f")`, which rounds it to even. `10500` is `11k` in the shipping web build and
    // would be `10k` through a `String(format:)` port, on a value a real column reaches.
    #expect(compactCount(10_500) == "11k")
    #expect(compactCount(11_500) == "12k")
    #expect(compactCount(1_050) == "1.1k")

    // Not a `Double` anywhere on the path: a count past 2^53 still renders, rather than rounding to
    // whatever the nearest representable double was.
    #expect(compactCount(9_007_199_254_740_993) == "9007199254.7M")
}

// MARK: - the three decorations

@Test func theCaretIsTheColumnsOwnSortDirectionAndNothingWhenItIsNotSorted() {
    let price = col("price", "DOUBLE")
    let asc = [QuerySpec.SortTerm(column: "price", direction: .asc)]
    let desc = [QuerySpec.SortTerm(column: "price", direction: .desc)]

    #expect(headerDecoration(price, profile: nil, sort: []).caret == nil)
    #expect(headerDecoration(price, profile: nil, sort: asc).caret == "▲")
    #expect(headerDecoration(price, profile: nil, sort: desc).caret == "▼")
    // Some *other* column being sorted is not this column being sorted.
    #expect(headerDecoration(col("name"), profile: nil, sort: asc).caret == nil)
}

/// 🔴 The `≈`. `approx_distinct` is HyperLogLog and it is genuinely wrong — on a 40 M-row column it
/// can be several percent out, and `SiftUITests`' own twelve-row `label` fixture already comes back
/// one short. A header that spelled an estimate as a fact would be this tool lying in the one place
/// it exists to be trusted, so the prefix is not decoration.
@Test func anEstimatedDistinctCountIsMarkedAndAnExactOneIsNot() {
    let c = col("region")
    let estimated = headerDecoration(
        c, profile: profile("region", n: 100, approx: 4_200), sort: [])
    #expect(estimated.distinctLabel == "≈4.2k")

    let exact = headerDecoration(
        c, profile: profile("region", n: 100, approx: 4_200, exact: 4_180), sort: [])
    #expect(exact.distinctLabel == "4.2k", "the exact count, and no ≈")

    // The exact count is what is SHOWN once it exists, not just what removes the prefix.
    let disagreeing = headerDecoration(
        c, profile: profile("region", n: 100, approx: 4_200, exact: 999), sort: [])
    #expect(disagreeing.distinctLabel == "999")

    // No profile is "not known yet", which is a different thing from zero. A header must not
    // invent a count it does not have.
    #expect(headerDecoration(c, profile: nil, sort: []).distinctLabel == "")
}

@Test func theMissingBarCoversNullsEmptiesAndUncastablesTogether() {
    let c = col("note")
    func fraction(_ p: ColumnProfile?) -> Double {
        headerDecoration(c, profile: p, sort: []).missingFraction
    }
    #expect(fraction(profile("note", n: 100, nNull: 10)) == 0.10)
    #expect(fraction(profile("note", n: 100, nNull: 10, nEmpty: 20)) == 0.30)
    #expect(fraction(profile("note", n: 100, nNull: 10, nEmpty: 20, nUncastable: 5)) == 0.35)
    #expect(fraction(profile("note", n: 100)) == 0)

    // 🔴 `n == 0` is a profile of nothing, not a division by zero — and `nil` is no profile at all,
    // which must not draw a bar claiming the column is 0% missing.
    #expect(fraction(profile("note", n: 0, nNull: 0)) == 0)
    #expect(fraction(nil) == 0)

    // Clamped, because the three counts are NOT disjoint: an empty string in a number column is
    // both `n_empty` and `n_uncastable`, so their sum can exceed `n` and an unclamped bar would run
    // past the end of its own column and into the next one.
    #expect(fraction(profile("note", n: 100, nNull: 60, nEmpty: 60)) == 1)
}

/// 🔴 The last line of the tooltip is the only place the app says how to sort. Plain click opens the
/// column and SHIFT-click sorts (`web/index.html:617`), which nobody guesses.
@Test func theHeaderTooltipCarriesTheCountsAndTheShiftClickAffordance() {
    let c = col("note", "VARCHAR")
    #expect(headerTooltip(c, profile: nil) == "note — VARCHAR\nclick: values · shift-click: sort")

    let full = headerTooltip(
        c, profile: profile("note", n: 2_000_000, nNull: 1_204_318, nEmpty: 12, approx: 42_400))
    #expect(full == """
        note — VARCHAR
        1,204,318 null, 12 empty, ≈42k distinct
        click: values · shift-click: sort
        """)
    // Grouped by `SiftCore.groupDigits` — the engine's function on the string, never a
    // `NumberFormatter`, which without an explicit locale renders that count four different ways.
    #expect(full.contains("1,204,318"))
}

// MARK: - the header, drawn
/// A CSV whose three columns land on three different header widths, one of which is two-thirds
/// empty — so the missing bar has a length worth measuring rather than 0 or the whole column.
@MainActor
private func headerFixture() async throws -> (AppState, TableViewModel) {
    let path = tempDir("p4t7-header").appendingPathComponent("hdr.csv").path
    var out = "id,description,mostly_missing\n"
    for i in 0..<12 {
        out += "\(i),\(String(repeating: "d", count: 20)),\(i % 3 == 2 ? "x" : "\"\"")\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: path)
    let opened = try #require(state.activeName)
    await waitForCatalog(state, "\(opened)'s exact row count") {
        state.tables.first { $0.name == opened }?.rowsAreExact == true
    }
    let model = try #require(state.model(for: opened))
    return (state, model)
}

/// The fixture with its first page and its profile already in — everything the header draws.
@MainActor
private func profiledHeaderFixture() async throws -> (AppState, TableViewModel) {
    let (state, model) = try await headerFixture()
    try await model.loadFirstPage()
    #expect(await waitFor { !model.profile.isEmpty }, "the header is built from the profile")
    return (state, model)
}

/// A real header view, built by `GridBridge.syncColumns` and rendered through
/// `cacheDisplay(in:to:)` — the only capture route available here (Screen Recording is not granted
/// and Accessibility returns zero windows for every app), and the one that reads AppKit's actual
/// drawing rather than what the code meant to draw.
@MainActor
private final class HeaderHarness {
    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 200))
    let view: NSTableHeaderView

    init(_ bridge: GridBridge) throws {
        table.rowHeight = gridRowHeight
        table.style = .plain
        table.headerView = NSTableHeaderView()
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = bridge
        table.delegate = bridge
        bridge.sync(table)
        view = try #require(table.headerView)
        table.tile()
        view.frame = NSRect(
            x: 0, y: 0, width: table.tableColumns.reduce(0) { $0 + $1.width },
            height: view.frame.height)
        view.layoutSubtreeIfNeeded()
    }

    /// Re-lay the header after a column's width changed — what a drag-to-resize does.
    func retile() {
        table.tile()
        view.frame = NSRect(
            x: 0, y: 0, width: table.tableColumns.reduce(0) { $0 + $1.width },
            height: view.frame.height)
        view.layoutSubtreeIfNeeded()
    }

    var height: Int { Int(view.bounds.height) }
    func rect(ofColumn i: Int) -> NSRect { view.headerRect(ofColumn: i) }
    func cell(_ i: Int) throws -> SiftHeaderCell {
        try #require(table.tableColumns[i].headerCell as? SiftHeaderCell)
    }

    /// Draw, and hand back the bitmap. Called more than once per harness on purpose: the tests that
    /// prove a decoration is *painted* change one and re-render the same cell.
    func shot() throws -> Shot {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return Shot(rep: rep, scale: rep.pixelsWide / Int(view.bounds.width))
    }

    struct Shot {
        let rep: NSBitmapImageRep
        let scale: Int

        /// Points, within `x`, that differ from the header's background — anything this code drew.
        /// Measured against the background colour rather than against alpha, because unlike a grid
        /// cell the header paints an opaque fill of its own first.
        func ink(x: Range<Int>, fromTop: Range<Int>) -> [Int] {
            pixels(x: x, fromTop: fromTop) { c, background in
                abs(c.redComponent - background.redComponent)
                    + abs(c.greenComponent - background.greenComponent)
                    + abs(c.blueComponent - background.blueComponent) > 0.08
            }
        }

        /// Points painted in a saturated colour — the accent caret, told apart from the grey name
        /// and type beside it by the spread between its channels rather than by where it is.
        func coloured(x: Range<Int>, fromTop: Range<Int>) -> [Int] {
            pixels(x: x, fromTop: fromTop) { c, _ in
                max(c.redComponent, c.greenComponent, c.blueComponent)
                    - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.15
            }
        }

        /// Points painted in the missing bar's amber. Told apart from the grey column divider by
        /// hue and not by position — the divider runs the height of the cell and would otherwise be
        /// measured as a full-width bar on every column.
        func amber(x: Range<Int>, fromTop: Range<Int>) -> [Int] {
            pixels(x: x, fromTop: fromTop) { c, _ in c.redComponent > c.blueComponent + 0.15 }
        }

        /// Rows of pixels within a column that have any ink at all — how the two text lines are
        /// proved not to be running into each other.
        func inkedRows(x: Range<Int>) -> Set<Int> {
            let background = rep.colorAt(x: 3, y: 3)
            var out: Set<Int> = []
            for py in 0..<rep.pixelsHigh {
                let hit = (x.lowerBound * scale..<x.upperBound * scale).contains { px in
                    guard let c = rep.colorAt(x: px, y: py), let background else { return false }
                    return abs(c.redComponent - background.redComponent)
                        + abs(c.greenComponent - background.greenComponent)
                        + abs(c.blueComponent - background.blueComponent) > 0.08
                }
                if hit { out.insert(py / scale) }
            }
            return out
        }

        private func pixels(
            x: Range<Int>, fromTop: Range<Int>, _ match: (NSColor, NSColor) -> Bool
        ) -> [Int] {
            guard let background = rep.colorAt(x: 3, y: 3) else { return [] }
            return (x.lowerBound * scale..<x.upperBound * scale).filter { px in
                (fromTop.lowerBound * scale..<fromTop.upperBound * scale).contains { py in
                    guard let c = rep.colorAt(x: px, y: py) else { return false }
                    return match(c, background)
                }
            }.map { $0 / scale }
        }
    }
}

/// 🔴 RENDERED, not inspected. Every assertion above this line reads a value; this one reads the
/// bitmap, and it is the only kind that catches a header whose numbers are all correct and whose
/// second line is drawn on top of its first.
@MainActor
@Test func theHeaderPaintsBothOfItsLinesAndNothingInTheGutter() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let harness = try HeaderHarness(GridBridge(model: model))
    let shot = try harness.shot()

    // 🔴 The header rect IS the column. `style = .plain` leaves `intercellSpacing.width` at 17 pt,
    // which made every header 17 pt wider than the column it names — the name drew over the gap and
    // a full missing bar ran a quarter of the way into the neighbouring column.
    let widths = harness.table.tableColumns.map { Int($0.width) }
    #expect(widths == [62, 76, 168, 132], "gutter, id, description, mostly_missing")
    for i in harness.table.tableColumns.indices {
        #expect(Int(harness.rect(ofColumn: i).width) == widths[i])
    }

    for i in 1..<4 {
        let r = harness.rect(ofColumn: i)
        // The interior, short of the 1-point divider down the right edge.
        let x = Int(r.minX)..<Int(r.maxX) - 2
        let rows = shot.inkedRows(x: x)

        // Both lines drew something. A header that draws only its name is what a two-line layout
        // collapses to when the second line lands off the bottom edge, and on screen it reads as
        // perfectly fine.
        //
        // 🔴 The lower band STOPS at `height - 3`, above the missing bar and the bottom hairline.
        // It did not, for one run, and the assertion was vacuous: the hairline runs the width of
        // every cell, so `contains { $0 >= height / 2 }` was satisfied by the chrome alone and
        // deleting the entire type line kept the test green. Caught by mutation, which is exactly
        // what mutation is for.
        #expect(rows.contains { $0 < harness.height / 2 }, "column \(i) drew no name")
        #expect(
            rows.contains { $0 >= harness.height / 2 && $0 < harness.height - 3 },
            "column \(i) drew no type line")

        // …and they are two lines rather than one smear: a completely unpainted row of pixels
        // between them. This is what goes red if the header is ever made shorter, or either font
        // bigger, than the layout can hold.
        #expect(
            (10..<harness.height / 2 + 4).contains { !rows.contains($0) },
            "column \(i)'s two lines run into each other: painted rows \(rows.sorted())")
    }

    // The gutter's header is blank — it has no name and no type, and the only thing it may draw is
    // its own chrome. (`.rownum` has no header content in the web build either.)
    let gutter = harness.rect(ofColumn: 0)
    #expect(shot.ink(x: 2..<Int(gutter.maxX) - 2, fromTop: 0..<harness.height - 2).isEmpty)
}

/// The bar is the one part of the header carrying a *quantity*, so its length is the assertion.
@MainActor
@Test func theMissingBarIsAsLongAsTheFractionItReports() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let bridge = GridBridge(model: model)
    let harness = try HeaderHarness(bridge)
    let shot = try harness.shot()
    let band = harness.height - 3..<harness.height - 1

    // Two thirds of `mostly_missing` is the empty string, and none of `description` is anything.
    let missing = try #require(bridge.profile(for: "mostly_missing"))
    #expect(missing.nEmpty == 8 && missing.n == 12, "8 of 12 rows are ''")
    let fraction = headerDecoration(model.columns[2], profile: missing, sort: []).missingFraction

    let column = harness.rect(ofColumn: 3)
    let painted = shot.amber(x: Int(column.minX)..<Int(column.maxX), fromTop: band)
    let drawn = (painted.max() ?? -1) - (painted.min() ?? 0) + 1
    #expect(painted.min() == Int(column.minX), "the bar starts at the column's left edge")
    #expect(drawn == Int((column.width * fraction).rounded()), "\(drawn) pt for \(fraction)")
    #expect(drawn > 80 && drawn < Int(column.width), "…two thirds of 132, not all of it")

    // A column with nothing missing gets no bar at all, rather than a full-width one — which is
    // what a bar drawn before the fraction is applied to it looks like.
    let clean = harness.rect(ofColumn: 2)
    #expect(shot.amber(x: Int(clean.minX)..<Int(clean.maxX) - 2, fromTop: band).isEmpty)
}

/// 🔴 The caret and the distinct count are the two things this task adds that a person has to
/// *read*, and both are drawn into a context rather than set on a control — so nothing but a bitmap
/// can say whether they arrived. Renders of the same cell, each adding one decoration, each of
/// which has to add ink where that decoration lives.
@MainActor
@Test func theCaretAndTheDistinctCountAreActuallyPaintedAndNotJustComputed() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let harness = try HeaderHarness(GridBridge(model: model))
    let r = harness.rect(ofColumn: 2)
    // The right-hand third of `description`'s type line, where the count lives and where its own
    // seven-character type does not reach.
    let countRegion = Int(r.maxX) - Int(r.width) / 3..<Int(r.maxX) - 2
    let typeLine = harness.height / 2..<harness.height - 3
    // …and the name line to the right of where `description` ends, which is where the caret goes.
    let cell = try harness.cell(2)
    let nameEnds = Int(r.minX) + 7 + Int(cell.measure("description", font: .systemFont(ofSize: 11.5, weight: .bold)))
    let caretRegion = nameEnds..<Int(r.maxX) - 2
    let nameLine = 0..<harness.height / 2

    func shot(_ decoration: HeaderDecoration) throws -> HeaderHarness.Shot {
        cell.decoration = decoration
        return try harness.shot()
    }

    let bare = try shot(HeaderDecoration(caret: nil, distinctLabel: "", missingFraction: 0))
    #expect(bare.ink(x: countRegion, fromTop: typeLine).isEmpty,
        "`VARCHAR` in a 168 pt column does not reach the right third")
    #expect(bare.ink(x: caretRegion, fromTop: nameLine).isEmpty, "nothing past the name yet")

    let counted = try shot(HeaderDecoration(caret: nil, distinctLabel: "≈42k", missingFraction: 0))
    let countInk = counted.ink(x: countRegion, fromTop: typeLine)
    #expect(!countInk.isEmpty, "a distinct count that draws nothing is a count nobody can read")
    #expect(counted.ink(x: caretRegion, fromTop: nameLine).isEmpty,
        "…and an unsorted column still has no caret")

    let sorted = try shot(HeaderDecoration(caret: "▼", distinctLabel: "≈42k", missingFraction: 0))
    // 🔴 The caret is on the NAME line, immediately after the name — the web's `.hn` flex row. It
    // used to be down beside the count, and that cost the type line 12 pt it did not have.
    let caretInk = sorted.ink(x: caretRegion, fromTop: nameLine)
    #expect(!caretInk.isEmpty, "a caret that draws nothing is a sort nobody can see")
    #expect(caretInk.min() ?? 999 < nameEnds + 8, "…and it sits beside the name, not at the edge")
    // The count is untouched by the move, and the type line gained nothing.
    #expect(sorted.ink(x: countRegion, fromTop: typeLine) == countInk)
}

/// 🔴 The reason the caret is on the name line, and the property that keeps it there: the caret
/// must take NO space from the type line. It used to sit beside the distinct count, and MEASURED,
/// that cost the type 12 pt it did not have — a sorted `BIGINT` column at the 76-pt width floor
/// rendered `BIG…` where the shipping web build renders `BIGINT`. The native app is not allowed to
/// be the worse one.
@MainActor
@Test func theSortCaretTakesNoSpaceFromTheTypeLine() throws {
    appKitReady()
    let cell = SiftHeaderCell(textCell: "id")
    cell.typeText = "BIGINT"
    let frame = NSRect(x: 0, y: 0, width: 76, height: 28)

    func typeWidth(caret: String?, count: String) -> CGFloat {
        cell.decoration = HeaderDecoration(caret: caret, distinctLabel: count, missingFraction: 0)
        return cell.typeRect(in: cell.layout(frame, flipped: true).meta).width
    }
    #expect(typeWidth(caret: "▲", count: "1.2k") == typeWidth(caret: nil, count: "1.2k"),
        "sorting a column must not shrink the room its type has")
    #expect(typeWidth(caret: "▼", count: "1.2k") == typeWidth(caret: nil, count: "1.2k"))

    // …and at the 76-pt floor there is now room for the whole type. `NSString.draw(in:)` puts in an
    // ellipsis exactly when the measured text is wider than the rect it is given, so this is the
    // elision question asked directly of the real layout.
    let metaFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    let needed = cell.measure("BIGINT", font: metaFont, kern: 0.54)
    #expect(needed <= typeWidth(caret: "▲", count: "1.2k"),
        "BIGINT needs \(needed) pt of \(typeWidth(caret: "▲", count: "1.2k"))")
    #expect(needed <= typeWidth(caret: "▲", count: "999"))

    // MEASURED, and the honest edge of this: a FIVE-character count (`≈1.2k`, `≈1.0M`) takes 28 of
    // the 62 points a 76-pt column has, leaving 34 for a type that wants 37, and `BIGINT` renders
    // `BIGI…`. The web build is in the same place — `.hcell { padding:3px 7px }` gives it the same
    // 62 px box and `ui-monospace` at 9 px is the same SF Mono this measures — so it is parity
    // rather than a regression. Not asserted, because an assertion that something does NOT fit goes
    // red the day someone improves it.

    // The floor is the floor: this is the width `columnWidths` actually hands a two-character
    // BIGINT column, not a number picked to make the arithmetic work.
    #expect(columnWidths([col("id", "BIGINT")], profile: [profile("id", maxLen: 4)]) == [76])
}

/// 🔴 A name too long for its column must lose its own tail rather than its caret. The width
/// formula sizes for the name, so this only bites once a column is narrower than computed — the 320
/// clamp on a very long name, or a user dragging one in — and in both cases a caret drawn past the
/// right edge is simply gone, and the column silently stops looking sorted.
@MainActor
@Test func aNameTooLongForItsColumnIsTruncatedBeforeItsCaretIs() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let harness = try HeaderHarness(GridBridge(model: model))
    try harness.cell(2).decoration = HeaderDecoration(
        caret: "▼", distinctLabel: "", missingFraction: 0)

    // `description` needs about 74 pt for its name; give it 60 and it cannot have all of it.
    harness.table.tableColumns[2].width = 60
    harness.retile()
    let r = harness.rect(ofColumn: 2)
    #expect(Int(r.width) == 60)

    let shot = try harness.shot()
    let painted = shot.coloured(x: Int(r.minX)..<Int(r.maxX) - 1, fromTop: 0..<harness.height / 2)
    #expect(!painted.isEmpty, "the caret was pushed off the edge by a name that would not fit")

    // 🔴 The WHOLE caret, not "some accent-coloured pixels". Without the reservation the caret is
    // drawn starting past the column's right edge and four of its six points still land inside —
    // enough for a `!isEmpty` assertion to pass on a caret that is visibly cut in half. Measured,
    // and the reason this compares against the glyph's own width.
    let width = try harness.cell(2).measure("▼", font: .monospacedSystemFont(ofSize: 9, weight: .regular))
    let drawn = painted.max()! - painted.min()! + 1
    #expect(drawn >= Int(width) - 1, "\(drawn) of the caret's \(width) pt made it inside")
    #expect(painted.max()! < Int(r.maxX) - 1, "…and it is inside its own column")
}

/// The name line has to hold the name AND the caret it takes on when sorted.
@MainActor
@Test func theNameLineHoldsBothTheNameAndItsCaret() throws {
    appKitReady()
    let cell = SiftHeaderCell(textCell: "")
    let caret = cell.measure("▲", font: .monospacedSystemFont(ofSize: 9, weight: .regular))
    for name in ["id", "description", "a_very_long_column_name_here_x", "created_at_utc"] {
        let width = try #require(columnWidths([col(name)], profile: []).first)
        cell.stringValue = name
        let box = cell.layout(NSRect(x: 0, y: 0, width: width, height: 28), flipped: true)
        let needed = cell.measure(name, font: .systemFont(ofSize: 11.5, weight: .bold)) + 3 + caret
        #expect(needed <= box.name.width, "\(name) plus a caret needs \(needed) of \(box.name.width)")
    }
}

/// A header whose name is elided is a column whose identity is a guess. `columnWidths` is measured
/// from the name, so this is the cross-check that the multiplier it uses agrees with the font the
/// header actually draws with.
@MainActor
@Test func everyColumnIsWideEnoughForItsOwnNameAndBothOfItsLines() async throws {
    appKitReady()
    let names = [
        "id", "description", "a_very_long_column_name_here_x", "ORDER_ID", "amount_usd",
        "created_at_utc", "Ω_unicode_name",
    ]
    let widths = columnWidths(names.map { col($0) }, profile: [])
    let cell = SiftHeaderCell(textCell: "")

    for (name, width) in zip(names, widths) {
        // The same 7-point inset the cell draws with, either side. `NSString.draw(in:)` puts in an
        // ellipsis exactly when the measured width exceeds the rect it is given, so this is the
        // question `expansionFrame` answers for an `NSCell` that draws its own text — which this one
        // deliberately does not, because the two-line layout is drawn by hand.
        let measured = cell.measure(name, font: .systemFont(ofSize: 11.5, weight: .bold))
        #expect(measured <= width - 14, "\(name) needs \(measured) pt of \(width - 14)")
    }

    // …and the two lines plus the bar fit the height AppKit gives an `NSTableHeaderView` — 28 pt,
    // measured, and the number `RootView`'s "no rows match" overlay is inset by. A layout that
    // needed more would have to move that constant too.
    let table = NSTableView(frame: .zero)
    table.style = .plain
    table.headerView = NSTableHeaderView()
    let height = try #require(table.headerView).frame.height
    let lines = cell.lineHeight(.systemFont(ofSize: 11.5, weight: .bold))
        + cell.lineHeight(.monospacedSystemFont(ofSize: 9, weight: .regular))
    #expect(lines + 3 <= height, "\(lines) pt of text, a 2 pt bar and a hairline, in \(height)")
}

// MARK: - a click on the header

/// 🔴 Shift-click sorts and a plain click does not — the web build's binding
/// (`web/index.html:624-628`). It is this way round because a sort of a 40 M-row file is expensive,
/// and brushing a header on the way to the scrollbar must not start one.
@MainActor
@Test func aPlainHeaderClickSelectsTheColumnAndDoesNotSortIt() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let bridge = GridBridge(model: model)
    var selected: [String] = []
    bridge.onColumnSelected = { selected.append($0) }

    bridge.headerClicked("description", shift: false)
    #expect(selected == ["description"])
    #expect(model.table.qspec.sort.isEmpty, "a plain click must not have sorted anything")

    bridge.headerClicked("description", shift: true)
    #expect(await waitFor { !model.table.qspec.sort.isEmpty })
    #expect(selected == ["description"], "…and a shift-click must not select")
}

/// The whole cycle, through the real engine, ending on the real header cell — which is what
/// `syncHeaders` exists for and which the column stamp deliberately cannot see.
@MainActor
@Test func shiftClickingAHeaderCyclesTheSortAndMovesItsCaret() async throws {
    appKitReady()
    let (_, model) = try await profiledHeaderFixture()
    let bridge = GridBridge(model: model)
    let table = NSTableView(frame: .zero)
    table.dataSource = bridge
    table.delegate = bridge
    bridge.sync(table)

    // 🔴 Through `sync`, not `syncHeaders` — `sync` is what the app calls (via `onViewportReset`,
    // which every spec change ends in) and the only place the header can be refreshed from. Calling
    // `syncHeaders` directly here made this test pass with the call REMOVED from `sync`, which is a
    // caret that never moves in the shipping app. Caught by mutation.
    func caret() throws -> String? {
        bridge.sync(table)
        return try #require(table.tableColumns[2].headerCell as? SiftHeaderCell).decoration.caret
    }
    #expect(try caret() == nil)

    bridge.headerClicked("description", shift: true)
    #expect(await waitFor { model.table.qspec.sort.first?.direction == .asc })
    #expect(try caret() == "▲")

    bridge.headerClicked("description", shift: true)
    #expect(await waitFor { model.table.qspec.sort.first?.direction == .desc })
    #expect(try caret() == "▼")

    bridge.headerClicked("description", shift: true)
    #expect(await waitFor { model.table.qspec.sort.isEmpty })
    #expect(try caret() == nil, "the third click takes the caret away again")

    // 🔴 The columns did not change identity through any of that — same names, same types — so a
    // header repainted only on a column rebuild would never have moved at all. This is the
    // assertion that `syncHeaders` is a second trigger and not another name for `syncColumns`.
    #expect(!bridge.syncColumns(table), "a sort is not a column rebuild")
}

/// The header is built before there is a profile and has to pick the numbers up when one lands —
/// the same second trigger the widths need, and the reason `syncHeaders` runs on every `sync`.
@MainActor
@Test func theDistinctCountAndMissingBarAppearWhenTheProfileLands() async throws {
    appKitReady()
    // Deliberately NOT `profiledHeaderFixture`: this is the ordering the app actually has, where
    // the grid draws a header seconds before `kickProfile`'s answer arrives.
    let (_, model) = try await headerFixture()
    let bridge = GridBridge(model: model)
    let table = NSTableView(frame: .zero)
    bridge.sync(table)

    #expect(model.profile.isEmpty, "no profile yet — the first paint happens without one")
    let header = try #require(table.tableColumns[3].headerCell as? SiftHeaderCell)
    #expect(header.decoration.distinctLabel == "", "a header must not invent a count")
    #expect(header.decoration.missingFraction == 0)
    #expect(!bridge.syncHeaders(table), "…and nothing to repaint while that stays true")

    try await model.loadFirstPage()
    #expect(await waitFor { !model.profile.isEmpty })
    #expect(bridge.syncHeaders(table), "a profile landing is a repaint")

    // 🔴 `≈`, because this is `approx_distinct` — HyperLogLog, exact only by luck at twelve rows.
    // `exact_distinct` is `nil` until a panel asks for it, and until then the header says so.
    #expect(header.decoration.distinctLabel.hasPrefix("≈"))
    #expect(header.decoration.missingFraction > 0.6, "8 of its 12 rows are the empty string")
    #expect(bridge.profile(for: "mostly_missing")?.exactDistinct == nil)
    #expect(bridge.profile(for: "id")?.approxDistinct == 12)

    // The tooltip picks the counts up in the same pass — it is the only place the app spells out
    // that sorting is behind the shift key.
    let tip = try #require(table.tableColumns[3].headerToolTip)
    #expect(tip.contains("8 empty"))
    #expect(tip.hasSuffix("click: values · shift-click: sort"))
}
