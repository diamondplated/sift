import AppKit
import Foundation
import SiftCore
import SwiftUI
import Testing
import TestSupport
@testable import SiftEngine
@testable import SiftUI

// The inspector's visual checks, and the number formatting underneath them.
//
// **These are smoke checks, not golden images.** They catch a view that fails to lay out, renders
// blank, or ignores the column it was handed; they do NOT catch a view that renders wrongly.
// Appearance and layout were verified by a human looking at the PNGs these write. Run with
// `SIFT_KEEP_TEST_TEMP=1` to keep them — the path is printed at the top of the run.
//
// `ImageRenderer` is what makes this possible at all: no window, no permissions, no `NSApplication`
// — and it works only because nothing on this page is an `NSViewRepresentable` (the grid is, and
// `ImageRenderer` hands back a prohibited-symbol placeholder for it, which is why Task 6 had to go
// through `cacheDisplay` instead). Keep it that way.
//
// Two known blind spots in these PNGs, neither of them a defect in the views:
//   * The lens `Picker` and the search `TextField` are AppKit-backed, so they come out as the same
//     prohibited-symbol placeholder — a yellow bar. They draw normally in the app (checked through
//     an `NSHostingView` + `cacheDisplay`, which renders those two controls and, being the mirror
//     image of this limitation, drops most of the SwiftUI-drawn text instead).
//   * `ImageRenderer` lays out no `ScrollView`, which is why the pane owns the only one.

// MARK: - helpers

@MainActor
private func render(_ view: some View, _ width: CGFloat, _ height: CGFloat) throws -> CGImage {
    // `.topLeading`, so a short panel sits where the pane would put it rather than floating in the
    // middle of the bitmap — these PNGs get looked at.
    let renderer = ImageRenderer(
        content: view.frame(width: width, height: height, alignment: .topLeading))
    return try #require(renderer.cgImage, "ImageRenderer produced no image at all")
}

/// A hash of the image's raw pixels. Two renders that differ here drew different things — which is
/// the only claim about drawing that a bitmap can support without a reference image.
///
/// 🔴 `hasher.combine(bytes:)`, NOT `hasher.combine(data)`. Foundation's `Data.hash(into:)` mixes
/// in the count and **at most the first 80 bytes**, which on a 340pt-wide render is the top-left
/// corner — blank margin in every panel this suite draws. MEASURED: written that way, this
/// function reported two visibly different `ColumnPanel`s as identical, and the test built to catch
/// a panel that ignores its column would instead have passed for a panel that drew nothing at all.
///
/// `skippingTop` crops a band off the top before hashing, for the panels whose *header* alone
/// echoes the thing under test — see `theColumnPanelDrawsTheColumnItWasHandedAndNotJustChrome`.
private func pixelDigest(_ image: CGImage, skippingTop: Int = 0) throws -> Int {
    let cropped = skippingTop == 0 ? image : try #require(image.cropping(
        to: CGRect(x: 0, y: skippingTop, width: image.width, height: image.height - skippingTop)))
    let data = try #require(cropped.dataProvider?.data) as Data
    var hasher = Hasher()
    data.withUnsafeBytes { hasher.combine(bytes: $0) }
    return hasher.finalize()
}

/// Under `SIFT_RENDER_OUT` when it is set, and under the suite's temp root otherwise. The override
/// is what makes "look at the picture" repeatable: the temp root is swept by the *next* test
/// process, so even `SIFT_KEEP_TEST_TEMP=1` does not reliably leave a PNG behind long enough to
/// open (measured — twice).
@discardableResult
private func writePNG(_ image: CGImage, _ name: String) throws -> String {
    let data = try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let path = ProcessInfo.processInfo.environment["SIFT_RENDER_OUT"]
        .map { ($0 as NSString).appendingPathComponent("\(name).png") }
        ?? TestTemp.path("p4t8-\(name)", ".png")
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

/// Pixels whose hue is unmistakably one channel's, by RATIO rather than by absolute level: a
/// partially covered pixel keeps its hue but loses its brightness, and premultiplied alpha loses
/// more of it, so `red > 0.6` would answer "nothing was drawn" for a bar that is plainly there.
private func inkCount(_ image: CGImage, _ hue: (CGFloat, CGFloat, CGFloat) -> Bool) throws -> Int {
    let rep = NSBitmapImageRep(cgImage: image)
    var count = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.2
            else { continue }
            if hue(colour.redComponent, colour.greenComponent, colour.blueComponent) { count += 1 }
        }
    }
    return count
}

private func amber(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    r > 0.2 && r > b * 2.5 && g > b && g < r
}

private func azure(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    b > 0.2 && b > r * 2.5
}

// MARK: - the Column tab

/// `ImageRenderer` returning a non-nil image is not evidence that anything was drawn, and "more
/// than one colour on screen" is satisfied by any background. Rendering a SECOND column and
/// requiring the two bitmaps to differ is the assertion with teeth: it can only hold if the panel
/// is drawing *this* column's data.
@MainActor
@Test func theColumnPanelDrawsTheColumnItWasHandedAndNotJustChrome() async throws {
    let (state, model) = try await openedFixture(rows: 400)
    // The panel draws the view model's profile synchronously — `ImageRenderer` never runs a
    // `.task`, so its own `profileOf` fetch is unreachable here, and this is what fills the
    // stats grid. `drainForTest` is what makes that deterministic rather than a race.
    await model.drainForTest()
    #expect(!model.profile.isEmpty, "no profile means the panel has nothing to draw but chrome")

    let label = try render(
        ColumnPanel(session: state.session, model: model, column: "label"), 340, 520)
    let id = try render(ColumnPanel(session: state.session, model: model, column: "id"), 340, 520)
    #expect(label.width > 0 && label.height > 0)
    // 🔴 Below the header, and that is the whole assertion. The header draws the column's own name
    // and type, so a full-bitmap comparison differs even when everything under it is another
    // column's numbers — MEASURED by mutation: `model.profile.first` in place of
    // `first { $0.name == column }` (every panel showing the FIRST column's stats, in the app whose
    // premise is not lying about data) passed the uncropped version of this test.
    #expect(try pixelDigest(label, skippingTop: 48) != pixelDigest(id, skippingTop: 48),
        "two different columns must not render identically below their headers")

    try writePNG(label, "column-panel-label")
    try writePNG(id, "column-panel-id")
}

/// The value list is the densest thing the inspector draws and the only place NULL and `''` appear
/// as their own rows. It is a separate view precisely so this check can reach it: the loaded state
/// lives behind a `.task`, and `ImageRenderer` does not run one.
@MainActor
@Test func theValueListDrawsTheTwoSentinelRowsInTheirOwnColour() async throws {
    let (state, model) = try await openedFixture(rows: 12)
    let panel = try await state.session.distinct(model.name, col: "note")
    #expect(panel.values.contains { $0.label == "␀ NULL" }, "the fixture's three states")
    #expect(panel.values.contains { $0.label == "␀ EMPTY" })

    let image = try render(DistinctList(panel: panel) { _, _ in }, 320, 220)
    let path = try writePNG(image, "value-list-note")
    // The sentinels are drawn amber and everything else is not; a panel that rendered its rows in
    // one undifferentiated colour — which is what happens when the `sentinel` branch is dropped —
    // has no amber in it at all.
    #expect(try inkCount(image, amber) > 0, "no sentinel styling in \(path)")

    let other = try render(
        DistinctList(panel: try await state.session.distinct(model.name, col: "label")) { _, _ in },
        320, 220)
    #expect(try pixelDigest(image) != pixelDigest(other), "two value lists rendered identically")
}

// MARK: - the Schema tab

/// 🔴 The three-segment missing bar is exactly the thing that computes correctly and draws wrong:
/// three sibling `Rectangle`s whose widths are fractions, inside a fixed 34pt track. A zero-width
/// segment, a NaN width, or a `clipShape` that swallows the lot all look identical from a property
/// assertion, so this one reads the pixels.
@MainActor
@Test func theSchemaListDrawsTheMissingBarsSegmentsAndNotJustTheirText() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    await model.drainForTest()
    let note = try #require(model.profile.first { $0.name == "note" })
    // The fixture's `note` column is a third NULL and a third empty string on purpose (see
    // `makeCSV`), so both segments are wide enough to be unmissable — if they draw at all.
    #expect(note.nNull > 0 && note.nEmpty > 0, "the fixture stopped carrying both states")

    // 🔴 `selected: nil`. With a row selected, its accent-tinted background is itself blue, and it
    // answered for the empty segment — MEASURED by mutation: deleting the empty segment entirely
    // left this test green. Nothing else in an unselected list is blue.
    let image = try render(SchemaList(model: model, selected: nil) { _ in }, 320, 200)
    let path = try writePNG(image, "schema-list")
    #expect(try inkCount(image, amber) > 20, "the null segment did not draw — see \(path)")
    #expect(try inkCount(image, azure) > 20, "the empty segment did not draw — see \(path)")

    // KNOWN GAP, stated rather than implied: the third segment (uncastable, red) is not guarded —
    // deleting it leaves this test green, because no column in this fixture has an uncastable cell
    // and nothing red is drawn either way. Producing one needs the engine suite's gzipped
    // 25,000-row trick (`SessionQueriesTests.badRowsDecodesBadColumnsAsTheListOfFailingColumnNames`),
    // which is a multi-second fixture to prove that a third call to the same one-line `segment`
    // helper draws. What is unguarded is the wiring of `nUncastable` into it, not the drawing.

    // …and the selection, which is the only thing that says which column the Column tab is about.
    let selected = try render(SchemaList(model: model, selected: "note") { _ in }, 320, 200)
    #expect(try pixelDigest(image) != pixelDigest(selected), "the selected row is not marked")
    try writePNG(selected, "schema-list-selected")
}

// MARK: - the numbers

@Test func theInspectorsNumbersMatchTheShippingWebBuildsFormatting() {
    // `compact` (`web/index.html:632`) — one decimal below 10k, none above, then M.
    #expect(compactCount(0) == "0")
    #expect(compactCount(999) == "999")
    #expect(compactCount(1_000) == "1.0k")
    #expect(compactCount(9_999) == "10.0k")
    #expect(compactCount(10_000) == "10k")
    #expect(compactCount(999_999) == "1000k")
    #expect(compactCount(1_500_000) == "1.5M")

    // `pct` (`:471`) — two decimals below 1%, so a rare value never reads as absent.
    #expect(percentText(0.5) == "50.0%")
    #expect(percentText(0) == "0.0%")
    #expect(percentText(0.005) == "0.50%")
    #expect(percentText(0.0001) == "0.01%")
    #expect(percentText(1) == "100.0%")

    // `shortType` (`:1079`).
    #expect(shortType("TIMESTAMP WITH TIME ZONE") == "TSTZ")
    #expect(shortType("DECIMAL(10,2)") == "DEC(10,2)")
    #expect(shortType("VARCHAR") == "STR")
    #expect(shortType("BOOLEAN") == "BOOL")
    #expect(shortType("BIGINT") == "BIGINT")
    #expect(shortType("STRUCT(a VARCHAR, b VARCHAR)") == "STRUCT(a STR, b STR)")

    // Counts are grouped through the one loop the grid and the CLI already share, and a mean keeps
    // up to three decimals with the trailing zeros dropped.
    #expect(countText(1_234_567) == "1,234,567")
    #expect(meanText(1_234.5) == "1,234.5")
    #expect(meanText(2) == "2")
    #expect(meanText(0.12345) == "0.123")
}
