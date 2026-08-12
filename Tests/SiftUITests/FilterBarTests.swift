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

@MainActor
private func renderBar(_ view: some View, _ width: CGFloat, _ height: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(
        content: view.frame(width: width, height: height, alignment: .topLeading))
    return try #require(renderer.cgImage, "ImageRenderer produced no image at all")
}

/// Pixels that lean blue, and pixels that lean amber — the filter chip's accent tint and the SQL
/// chip's warning tint. By the RATIO between two channels rather than by an absolute level, so a
/// pale 12%-opacity fill still counts and a different renderer's gamma does not decide the answer.
///
/// 🔴 **This exists because a pixel digest cannot be used on this view at all.** MEASURED here:
/// rendering the *same* `FilterBar` three times in a row produced digests `A, A, B` — an
/// `ImageRenderer` bitmap containing an AppKit-backed `Button` is not byte-stable between renders.
/// A `digest(x) != digest(y)` assertion therefore passes for two renders of *identical* content,
/// which is a vacuous test that looks like a strong one: written that way first, this file's
/// SQL-mode check passed with the SQL-mode branch deleted. These counts, over the same four
/// renders, were identical every time.
private func tintedPixels(_ image: CGImage) -> (blue: Int, amber: Int) {
    let rep = NSBitmapImageRep(cgImage: image)
    var blue = 0
    var amber = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.2
            else { continue }
            let lean = colour.blueComponent - colour.redComponent
            if lean > 0.08 { blue += 1 }
            if -lean > 0.08 { amber += 1 }
        }
    }
    return (blue, amber)
}

@discardableResult
private func writeBarPNG(_ image: CGImage, _ name: String) throws -> String {
    let data = try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let path = ProcessInfo.processInfo.environment["SIFT_RENDER_OUT"]
        .map { ($0 as NSString).appendingPathComponent("\(name).png") }
        ?? TestTemp.path("p4t10-\(name)", ".png")
    try data.write(to: URL(fileURLWithPath: path))
    return path
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

/// Four states of the same bar, compared to each other. Every claim is a *relationship* between two
/// renders — never an absolute pixel count, which is a number tuned on whichever machine wrote the
/// test and a CI failure on any other.
@MainActor
@Test func theFilterBarDrawsItsFiltersAndNotJustItsChrome() async throws {
    let (state, model) = try await openedFixture(rows: 12)
    var showSQL = false
    let binding = Binding(get: { showSQL }, set: { showSQL = $0 })
    func bar() -> FilterBar { FilterBar(model: model, showSQL: binding) { _ in } }

    let empty = try renderBar(bar(), 620, 34)
    try writeBarPNG(empty, "filter-bar-empty")

    try await model.setFilters([Filter(col: "label", op: .inList, values: [.text("row1")])])
    #expect(model.table.qspec.filters.count == 1)
    let one = try renderBar(bar(), 620, 34)
    try writeBarPNG(one, "filter-bar-one")
    #expect(
        tintedPixels(one).blue > tintedPixels(empty).blue,
        "a filter drew no chip — the bar is showing the no-filters hint either way")

    // Two filters on ONE column. `applyDistinctClick` replaces per (column, op), so a column can
    // carry several at once, and each has to be its own chip with its own ×.
    try await model.setFilters([
        Filter(col: "label", op: .inList, values: [.text("row1")]),
        Filter(col: "label", op: .notNull),
    ])
    let two = try renderBar(bar(), 620, 34)
    try writeBarPNG(two, "filter-bar-two-on-one-column")
    #expect(
        tintedPixels(two).blue > tintedPixels(one).blue,
        "a column's second filter drew nothing of its own")

    // SQL mode REPLACES the chips rather than hiding them: the filters are still in the catalog and
    // still describe nothing on screen. Both halves are asserted, because "the amber chip is there"
    // alone would pass for a bar that drew the frozen filters beside it.
    model.typeSQL(try await state.session.renderedSQL(model.name))
    try await model.runSQL()
    #expect(model.table.sqlMode)
    #expect(!model.table.qspec.filters.isEmpty, "the filters are frozen, not cleared")
    let sql = try renderBar(bar(), 620, 34)
    let path = try writeBarPNG(sql, "filter-bar-sql-mode")
    #expect(
        tintedPixels(sql).amber > tintedPixels(two).amber,
        "no frozen-filters chip in SQL mode — see \(path)")
    #expect(
        tintedPixels(sql).blue < tintedPixels(two).blue,
        "SQL mode drew the frozen filters as well — see \(path)")
}
