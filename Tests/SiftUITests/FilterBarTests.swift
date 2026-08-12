import AppKit
import Foundation
import SiftCore
import SiftEngine
import SwiftUI
import Testing
import TestSupport
@testable import SiftUI

// The filter bar, the banner sentences, and the block failure that used to have nowhere to go.
//
// The sentences are tested as functions rather than through a render because a `View`'s body cannot
// be tested and every one of these strings carries a number or a plural. The renders below are
// smoke checks — they catch a bar that lays out blank or ignores its filters, not one that is ugly.

// MARK: - helpers
//
// A third private copy of `render`/`digest` (`InspectorRenderTests`, `HistogramRenderTests`), for
// the same reason those two are separate: both are file-private, and a test target cannot export to
// itself without a shared file every render task would then contend on. Kept byte-identical in
// behaviour to `HistogramRenderTests`', deliberately — a render helper that differs subtly between
// files is how one of them ends up with the padding bug again.

/// Draw a view through AppKit and hand back its pixels.
///
/// 🔴 **`cacheDisplay` on an `NSHostingView`, NOT `ImageRenderer`, and that is a correctness
/// requirement here rather than a preference.** MEASURED on this view, 20 renders of identical
/// content each way: `ImageRenderer` produced **two** distinct bitmaps, `cacheDisplay` produced
/// **one**. (Not row padding, which was my first guess — both routes report `bytesPerRow` exactly
/// equal to the row's real width. `ImageRenderer` also rasterizes at 1x where `cacheDisplay` uses
/// the 2x backing scale.) An unstable capture makes every "these two renders differ" assertion
/// vacuous, which is exactly how this file's SQL-mode check once passed with the SQL-mode branch
/// deleted.
///
/// 🔴 **Pinned to Aqua.** Without it the render follows whatever appearance the machine happens to
/// be in, so every comparison below means something different on a laptop in dark mode than on the
/// runner.
@MainActor
private func renderBar(_ view: some View, _ tag: String, _ width: CGFloat = 620) throws
    -> NSBitmapImageRep
{
    _ = NSApplication.shared   // AppKit wants an app object before any NSView exists, even headless
    let host = NSHostingView(
        rootView: view.frame(width: width, height: 34, alignment: .topLeading))
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 34)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["SIFT_RENDER_DUMP"],
        let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag).png"))
    }
    return rep
}

/// Every pixel byte, walked by hand, row padding excluded.
///
/// 🔴 Walked by hand because `Hasher.combine(someData)` — the obvious spelling — hashes the count
/// and **at most the first 80 bytes**, which on a 620-point strip is blank left margin, and reports
/// two visibly different pictures as identical. That trap has now bitten this branch three times.
///
/// 🔴 Padding excluded because `bytesPerRow` may exceed the row's real width and the slack is never
/// initialized, so a digest over the whole backing store can differ from itself. It happens not to
/// bite at this size (measured: no padding either way) — it is excluded so that it cannot start to
/// at a different width, which is precisely the kind of thing that only shows up on the runner.
private func digest(_ rep: NSBitmapImageRep) -> UInt64 {
    guard let data = rep.bitmapData else { return 0 }
    let perRow = rep.pixelsWide * rep.samplesPerPixel
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for y in 0..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for i in 0..<perRow { hash = (hash ^ UInt64(row[i])) &* 0x0100_0000_01b3 }
    }
    return hash
}

// MARK: - the chip labels

/// A verbatim port of `opLabel` (`web/index.html:929-941`). Every branch, because each one is a
/// different sentence a user reads off a chip and none of them is reachable from a render.
@Test func theChipLabelsMatchTheShippingWebBuildsOpLabel() {
    #expect(filterChipLabel(Filter(col: "a", op: .isNull)) == "is null")
    #expect(filterChipLabel(Filter(col: "a", op: .notNull)) == "is not null")
    #expect(filterChipLabel(Filter(col: "a", op: .isEmpty)) == "is empty")

    // Two values still read as a list; three stop being readable and become a count.
    #expect(filterChipLabel(Filter(col: "a", op: .inList, values: [.text("x")])) == "= x")
    #expect(
        filterChipLabel(Filter(col: "a", op: .inList, values: [.text("x"), .text("y")]))
            == "= x, y")
    #expect(
        filterChipLabel(
            Filter(col: "a", op: .inList, values: [.text("x"), .text("y"), .text("z")]))
            == "in 3 values")

    #expect(filterChipLabel(Filter(col: "a", op: .notIn, values: [.text("x")])) == "≠ x")
    #expect(filterChipLabel(Filter(col: "a", op: .contains, values: [.text("x")])) == "contains “x”")
    #expect(filterChipLabel(Filter(col: "a", op: .between, values: [.int(1), .int(9)])) == "1 … 9")

    // The default branch: the wire spelling of the op is already what the user would write.
    #expect(filterChipLabel(Filter(col: "a", op: .gt, values: [.int(3)])) == "> 3")
    #expect(filterChipLabel(Filter(col: "a", op: .ne, values: [.text("x")])) == "!= x")
}

/// The four value cases a chip can carry, and the sentinel. `␀ NULL` is the same string the distinct
/// panel's NULL row carries and the same one `applyDistinctClick` dispatches on — a chip spelling it
/// differently would be the app calling one thing two names on two panels.
@Test func aNullFilterValueRendersAsTheSameSentinelTheValueListUses() {
    #expect(filterChipLabel(Filter(col: "a", op: .inList, values: [.null])) == "= ␀ NULL")
    #expect(filterChipLabel(Filter(col: "a", op: .notIn, values: [.null])) == "≠ ␀ NULL")
    #expect(filterChipLabel(Filter(col: "a", op: .inList, values: [.bool(true)])) == "= true")
    #expect(filterChipLabel(Filter(col: "a", op: .inList, values: [.int(-40)])) == "= -40")
    // NOT grouped: a filter value is something the user would type back in, not a count.
    #expect(filterChipLabel(Filter(col: "a", op: .inList, values: [.int(1_000_000)])) == "= 1000000")
}

// MARK: - the banner sentences

@Test func theStagingBannerSaysHowLongOrAdmitsItDoesNotKnow() {
    #expect(
        stagingText(estSeconds: 12.4)
            == "Staging into native storage — the grid may be slower for about 12s.")
    #expect(
        stagingText(estSeconds: 0)
            == "Staging into native storage — the grid may be slower for about ?s.",
        "a job with no estimate yet must not claim zero seconds")
}

@Test func theTruncationBannerNamesBothCountsAndTheWayOut() {
    #expect(
        sortTruncationText(rows: 40_000_000)
            == "Sorted view reaches the first 5,000,000 rows of 40,000,000. "
            + "Clear the sort to page the rest.")
}

@Test func theMissingExtensionBannerIsPluralised_sorted_andCarriesItsFix() throws {
    #expect(missingExtensionsBanner([:]) == nil)
    #expect(missingExtensionsBanner(["excel": true, "delta": true]) == nil)

    let one = try #require(missingExtensionsBanner(["excel": false, "delta": true]))
    #expect(one.message.hasPrefix("DuckDB extension unavailable: excel."))
    #expect(one.message.hasSuffix("Fix with one online run of"))
    #expect(one.fix == "INSTALL excel")

    // 🔴 Five keys, so an unsorted `Dictionary` has one chance in 120 of coming out in this order.
    // Swift seeds its hash per process, so without the `sorted()` the same two extensions name
    // themselves differently on every launch and the sentence reads like a changing situation.
    let many = try #require(
        missingExtensionsBanner(
            ["excel": false, "delta": false, "httpfs": false, "aws": false, "spatial": false]))
    #expect(
        many.message.hasPrefix(
            "DuckDB extensions unavailable: aws, delta, excel, httpfs, spatial."))
    #expect(many.message.contains("refused rather than read incorrectly"))
    #expect(many.fix == "INSTALL aws; INSTALL delta; INSTALL excel; INSTALL httpfs; INSTALL spatial")
}

// MARK: - the block that threw

/// 🔴 `PageLoader` has had an `onFailure` hook since Task 4 and **nothing installed it**, so a block
/// whose fetch threw was dropped in silence: the rows it covered stayed skeletons forever with
/// nothing on screen saying why. In SQL mode, where every block re-runs the user's query, that is a
/// grid of placeholders under a console reporting success.
@MainActor
@Test func aBlockThatThrowsReachesTheBannerInsteadOfVanishing() async throws {
    let (state, model) = try await openedFixture(rows: 12)
    #expect(model.pageError == nil)

    // Pull the table out from under the pump. Every later block now throws the engine's own
    // sentence, which is the one the banner shows — nothing here synthesizes a message.
    try await state.session.closeTable(model.name)
    // Block 0 is already cached, so ask for blocks that are not.
    model.ensureVisible(firstRow: 10 * pageRows, rowsOnScreen: 20)
    await model.drainForTest()

    let failure = try #require(model.pageError, "a block that threw was dropped in silence")
    #expect(failure.contains(model.name), "the banner did not name the table: \(failure)")

    // …and it clears on the next viewport reset, because by then it describes a query nobody is
    // looking at anymore.
    model.resetViewport()
    #expect(model.pageError == nil)
}

// MARK: - the bar itself

/// Four states of the same bar, each required to draw differently from the last.
///
/// 🔴 **The control comes first, and it is what makes the rest mean anything.** Every assertion here
/// is "these two renders differ", which is only evidence if the renderer produces the same bytes for
/// the same input — so the first thing this test does is render one model twice and require the two
/// buffers to be identical. Both pictures come out of one rasterizer in one process, so a runner
/// with different fonts, a different backing scale or different antialiasing moves both sides of
/// every comparison the same way and cancels.
///
/// 🔴 **What this replaced, and why it was wrong.** This test used to count pixels "leaning amber"
/// in one render and compare that count against another render *of different content*. It passed
/// here and inverted on the macos-15 runner — `Color.accentColor` resolves to a different hue there,
/// so the chips themselves counted as amber and two blue chips out-ambered the amber one. A count
/// compared across two different contents measures the renderer as much as the code. Nothing below
/// asserts a magnitude, a colour, or a coordinate.
@MainActor
@Test func theFilterBarDrawsItsFiltersAndNotJustItsChrome() async throws {
    let (state, model) = try await openedFixture(rows: 12)
    var showSQL = false
    let binding = Binding(get: { showSQL }, set: { showSQL = $0 })
    func bar(_ tag: String) throws -> UInt64 {
        digest(try renderBar(FilterBar(model: model, showSQL: binding) { _ in }, tag))
    }

    // THE CONTROL: the same model, twice.
    let empty = try bar("filter-bar-empty")
    #expect(
        empty == (try bar("filter-bar-empty-control")),
        "the renderer does not reproduce itself, so no comparison below this line means anything")

    try await model.setFilters([Filter(col: "label", op: .inList, values: [.text("row1")])])
    #expect(model.table.qspec.filters.count == 1)
    let one = try bar("filter-bar-one")
    #expect(one != empty, "a filter drew no chip — the bar shows the no-filters hint either way")

    // 🔴 A chip that draws but ignores what it was handed. Both pairs below differ in exactly one
    // string and are otherwise the same chip in the same place, so a bar that drew empty chips — or
    // the same chip for every filter — renders the two identically. MEASURED by mutation: with
    // `Text(filterChipLabel(filter))` replaced by `Text("")`, everything else in this test stayed
    // green, because a chip of a different WIDTH is still a different picture.
    try await model.setFilters([Filter(col: "label", op: .inList, values: [.text("row2")])])
    let otherValue = try bar("filter-bar-one-other-value")
    #expect(
        otherValue != one,
        "the chip is not drawing filterChipLabel — two different values render identically")

    // Same op, same value, different column: the bold column name has to be on screen too.
    try await model.setFilters([Filter(col: "note", op: .inList, values: [.text("row2")])])
    #expect(
        (try bar("filter-bar-one-other-column")) != otherValue,
        "the chip is not drawing its column name")

    try await model.setFilters([Filter(col: "label", op: .inList, values: [.text("row1")])])

    // Two filters on ONE column. `applyDistinctClick` replaces per (column, op), so a column can
    // carry several at once, and each has to be its own chip with its own ×.
    try await model.setFilters([
        Filter(col: "label", op: .inList, values: [.text("row1")]),
        Filter(col: "label", op: .notNull),
    ])
    let two = try bar("filter-bar-two-on-one-column")
    #expect(two != one, "a column's second filter drew nothing of its own")

    // SQL mode REPLACES the chips rather than hiding them: the filters are still in the catalog and
    // still describe nothing on screen, so drawing them would be the app lying about the grid.
    model.typeSQL(try await state.session.renderedSQL(model.name))
    try await model.runSQL()
    #expect(model.table.sqlMode)
    #expect(!model.table.qspec.filters.isEmpty, "the filters are frozen, not cleared")
    #expect(
        (try bar("filter-bar-sql-mode")) != two,
        "SQL mode drew the frozen filters instead of the frozen-filters chip")
}
