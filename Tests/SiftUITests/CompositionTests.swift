import AppKit
import Foundation
import SiftCore
import SwiftUI
import Testing
import TestSupport

@testable import SiftEngine
@testable import SiftUI

// The three files nothing tested: `RootView`, `InspectorView`, `AppDelegate`.
//
// 🔴 **This suite exists because per-file discipline cannot see composition.** `SourceTab` shipped
// as 243 finished, documented, tested lines that no user could reach: `InspectorView`'s `.source`
// case rendered a placeholder naming an internal task number, and every test that touched the panel
// rendered `SourceTab(...)` DIRECTLY, so the suite was green with the panel unmounted. The same
// blind spot hid a blank, undismissable sheet — `RootView`'s `.sheet` content is `if let t =
// state.active` with no else, and nothing cleared `modalSheet` when that table closed.
//
// So the rule for anything added here: **drive the composing view, never the piece it composes.**
// A test that constructs `SourceTab` is a `SourceTab` test and belongs in `HistogramRenderTests`.
//
// The wiring assertion is "render this view against two different tables and require the bitmaps to
// differ", the shape `theColumnPanelDrawsTheColumnItWasHandedAndNotJustChrome` already uses. It is
// the one claim a bitmap can support without a reference image, and it is exactly the claim a
// placeholder fails: a `Note` renders the same sentence whatever table is open.

// MARK: - helpers

/// Draw a view through AppKit and hand back its pixels.
///
/// `cacheDisplay(in:to:)` on a live `NSHostingView` and never `ImageRenderer` — `ImageRenderer`
/// lays out no `ScrollView` at all, and `InspectorView` owns the pane's only one, so it would
/// render this whole suite's subject as a blank bitmap. Pinned to Aqua on both the window and the
/// view, for the reason `AppearanceTests` measured: unpinned, a render follows whatever appearance
/// the machine is in.
///
/// A fifth private copy of this helper rather than a shared one, matching the four that already
/// exist in this target — a test target cannot export to itself.
@MainActor
private func render(_ view: some View, _ width: CGFloat, _ height: CGFloat) throws
    -> NSBitmapImageRep
{
    _ = NSApplication.shared   // AppKit wants an app object before any NSView exists, even headless
    let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    host.appearance = NSAppearance(named: .aqua)
    window.contentView?.addSubview(host)
    host.layoutSubtreeIfNeeded()

    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// Every pixel byte, walked by hand with the row padding excluded — the digest the other four
/// render suites use, and for their reasons: `Hasher.combine(someData)` mixes in at most the first
/// 80 bytes (blank margin in every panel drawn here), and `bytesPerRow` slack is never initialized.
///
/// `skippingTopFraction` crops the tab strip off before hashing, for the one assertion that is
/// about the panel *under* it: the segmented picker draws its own selection, so three renders of
/// the same empty state differ at the top by construction. A fraction rather than a pixel count
/// because `pixelsHigh` is backing-store pixels and the frame is points.
private func digest(_ rep: NSBitmapImageRep, skippingTopFraction: Double = 0) -> UInt64 {
    guard let data = rep.bitmapData else { return 0 }
    let perRow = rep.pixelsWide * rep.samplesPerPixel
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for y in Int(Double(rep.pixelsHigh) * skippingTopFraction)..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for i in 0..<perRow { hash = (hash ^ UInt64(row[i])) &* 0x0100_0000_01b3 }
    }
    return hash
}

/// How many pixels this view actually paints. Relative, never an absolute count: the assertion
/// every empty state has to survive is "something was drawn at all".
private func inkCount(_ rep: NSBitmapImageRep) -> Int {
    var painted = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5 { painted += 1 }
        }
    }
    return painted
}

/// Two open tables that differ in every field the inspector draws: different filenames, different
/// column names, different column counts, different row counts. Anything mounting a real panel
/// renders them differently; a placeholder renders them identically.
@MainActor
private func twoUnlikeTables() async throws -> (AppState, String, String) {
    let dir = tempDir("composition")
    let state = AppState(session: try Session(home: tempHome()))

    let one = try makeCSV(in: dir, name: "one.csv", rows: 12)
    var other = "alpha,beta\n"
    for i in 0..<40 { other += "\(i),value\(i)\n" }
    let two = dir.appendingPathComponent("two.csv").path
    try other.write(toFile: two, atomically: true, encoding: .utf8)

    await state.open(path: one)
    let first = try #require(state.activeName)
    await state.open(path: two)
    let second = try #require(state.activeName)
    #expect(first != second)
    return (state, first, second)
}

/// The inspector, drawn for whichever table is selected, with one tab forward.
@MainActor
private func inspector(_ state: AppState, _ table: String, _ tab: InspectorTab) throws
    -> NSBitmapImageRep
{
    state.activeName = table
    return try render(InspectorView(state: state, initialTab: tab), 320, 420)
}

// MARK: - the inspector's three tabs

/// 🔴 **The production-wiring test C1 kept evading.** `SourceTab` was finished and unreachable, and
/// the reason nothing caught it is that `HistogramRenderTests` renders `SourceTab` directly — which
/// is green whether or not `InspectorView` ever mounts it. This renders `InspectorView` itself.
///
/// Mutation, all three of them: replace any one panel below with the `Note` placeholder it used to
/// be (or with any other constant) and that tab's assertion goes red, because a constant draws the
/// same pixels for both tables.
@MainActor
@Test func everyInspectorTabMountsItsRealPanelAndNotAPlaceholder() async throws {
    let (state, one, two) = try await twoUnlikeTables()

    // Source — the path, the format, the size, the row count and the basis sentence all differ.
    #expect(
        digest(try inspector(state, one, .source)) != digest(try inspector(state, two, .source)),
        "the Source tab drew the same thing for two different files — it is not mounting SourceTab")

    // Schema — `id,label,note` against `alpha,beta`, and "3 columns" against "2 columns".
    #expect(
        digest(try inspector(state, one, .schema)) != digest(try inspector(state, two, .schema)),
        "the Schema tab drew the same thing for two different tables")

    // Column — the panel is keyed on `state.selectedColumn`, so the two renders are two columns.
    state.selectedColumn = "label"
    let label = try inspector(state, one, .column)
    state.selectedColumn = "alpha"
    let alpha = try inspector(state, two, .column)
    #expect(digest(label) != digest(alpha), "the Column tab drew the same thing for two columns")
}

/// The tab strip is not decoration: picking a segment has to change what is under it. Three
/// different panels for one table, which is the half the test above cannot see (a single panel
/// mounted under all three cases would pass it).
@MainActor
@Test func theThreeInspectorTabsDrawThreeDifferentPanels() async throws {
    let (state, one, _) = try await twoUnlikeTables()
    state.selectedColumn = "label"

    let drawn = try [InspectorTab.schema, .column, .source].map {
        digest(try inspector(state, one, $0))
    }
    #expect(Set(drawn).count == 3, "two of the inspector's three tabs render identically")
}

/// …and with nothing open, all three say so rather than drawing a panel about a table that is not
/// there. The empty state is the one place where "all three tabs are identical" is correct.
@MainActor
@Test func theInspectorSaysNothingOpenOnEveryTabWhenNothingIsOpen() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    // Below the tab strip, which draws its own selected segment and therefore differs three ways
    // whatever is under it.
    let drawn = try [InspectorTab.schema, .column, .source].map {
        digest(
            try render(InspectorView(state: state, initialTab: $0), 320, 420),
            skippingTopFraction: 0.2)
    }
    #expect(Set(drawn).count == 1, "the inspector drew a panel with no table open")
}


// MARK: - a sheet whose table went away

/// 🔴 **C2's belt, measured.** The `.sheet` content was `if let t = state.active` with no else, and
/// that body with a nil subject paints ZERO pixels — a blank window-modal sheet with no button on
/// it, over an app whose menu bar is still live. Force-quit.
///
/// `AppState` is what makes the fallback unreachable in practice (`dismissSheetWithoutASubject`,
/// pinned in `AppStateTests`); this is the assertion that if it IS reached, something is drawn.
/// Delete the `Text` and the `Button` and the ink collapses to the empty render's.
@MainActor
@Test func theSheetFallbackPaintsRatherThanRenderingABlankModal() throws {
    let painted = inkCount(try render(SheetSubjectGone(), 400, 140))
    let blank = inkCount(try render(Color.clear, 400, 140))
    #expect(painted > blank, "the fallback drew nothing — this is the blank sheet, again")
}
