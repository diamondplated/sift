import AppKit
import Foundation
import SiftCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
import TestSupport
@testable import SiftEngine
@testable import SiftUI

// The sources sidebar: the four sentences, the chip, the armed close, and one look at the pixels.
//
// Everything here is over synthetic `Table`s except the last two, which need a real `Session`
// because `AppState.tables` is fed by the engine and by nothing else.

// MARK: - synthetic tables

/// A `Table` with exactly the fields the sidebar reads. Every initializer it touches is public, so
/// this needs no engine and no file on disk.
private func fixture(
    name: String = "orders", fmt: Fmt = .csv, path: String = "/data/orders.csv", size: Int = 0,
    rowCount: Int? = nil, estimate: RowEstimate? = nil, filteredCount: Int? = nil,
    filters: [Filter] = [], badRows: Int = 0, counting: Bool = false, staged: Bool = false
) -> SiftEngine.Table {
    let spec = SourceSpec(
        key: SourceKey(path: path, mtimeNs: 0, size: size), fmt: fmt, readFn: "read_csv",
        rowEstimate: estimate)
    var t = SiftEngine.Table(
        name: name, spec: spec, qspec: QuerySpec(relation: name, filters: filters), openedAt: 1)
    t.rowCount = rowCount
    t.filteredCount = filteredCount
    t.badRows = badRows
    t.counting = counting
    t.staged = staged
    return t
}

/// 41.2 MB through `humanBytes`, so the expected subtitle below is the shipping string and not a
/// number chosen to match whatever the code happens to print.
private let fortyOnePointTwoMB = 43_201_331

// MARK: - sourceSubtitle

@Test func aStagedCSVReadsAsFormatSizeRowsAndStaged() {
    let t = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338, staged: true)
    #expect(sourceSubtitle(t) == "csv · 41.2 MB · 2,412,338 rows · staged")
}

@Test func anUnstagedSourceDropsTheStagedSegmentAndNothingElse() {
    let t = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338)
    #expect(sourceSubtitle(t) == "csv · 41.2 MB · 2,412,338 rows")
}

/// 🔴 A folder of parquet is a FOLDER, and `glob_parquet` said in the sidebar is engine vocabulary
/// leaking into the window. `web/index.html:967` replaces the prefix with `▤ `.
@Test func aFolderSourceReadsAsTheFolderGlyphAndNotGlobParquet() {
    let t = fixture(
        name: "sales", fmt: .globParquet, path: "/data/sales", size: 12 * 1024 * 1024,
        rowCount: 900)
    #expect(sourceSubtitle(t) == "▤ parquet · 12.0 MB · 900 rows")
    #expect(!sourceSubtitle(t).contains("glob_"))

    let csv = fixture(fmt: .globCsv, rowCount: 4)
    #expect(sourceSubtitle(csv) == "▤ csv · 4 rows")
}

/// A merge view is a view over two open tables: `merge`'s `SourceKey` is `("merge://a+b", 0, 0)`,
/// and a size segment reading `0 B` would be a claim about a file that does not exist.
@Test func aMergeViewReadsAsMergedAndCarriesNoSize() {
    let t = fixture(
        name: "a_b", fmt: .merge, path: "merge://a+b", size: 0, rowCount: 1_204)
    #expect(sourceSubtitle(t) == "merged · 1,204 rows")
}

/// The count comes from `displayRows`, so a big CSV says how big it is from the moment it opens
/// rather than after the background count lands.
@Test func aTableWithOnlyAnEstimateStillCarriesItsRowsSegment() {
    let estimate = RowEstimate(rows: 2_400_000, confidence: .low, basis: "3x256KiB sample")
    let t = fixture(size: fortyOnePointTwoMB, estimate: estimate)
    #expect(sourceSubtitle(t) == "csv · 41.2 MB · 2,400,000 rows")

    // …and a table with neither has no rows segment at all, rather than a zero.
    #expect(sourceSubtitle(fixture(size: fortyOnePointTwoMB)) == "csv · 41.2 MB")
}

// MARK: - rowText

@Test func aCountingTableSaysSo() {
    #expect(rowText(fixture(rowCount: 2_412_338, counting: true)) == "counting…")
    // …and so does one with nothing to say yet: no exact count and no estimate.
    #expect(rowText(fixture()) == "counting…")
}

/// 🔴 **The branch Task 5a made reachable.** `Table.displayRows` falls back to the byte-sample
/// estimate; delete that fallback and `displayRows` is `nil` in exactly this case, this table takes
/// the `counting…` branch instead, and this expectation goes red. That is the whole reason this case
/// is written out separately from the exact one.
///
/// `KeyNavTests` asserts the same branch through `rowSummaryText`. That is not a duplicate — since
/// `rowSummaryText` now calls `rowText`, it is the seam check that keeps the toolbar and the sidebar
/// saying the same thing about the same table.
@Test func theSidebarsRowPhraseMarksAnEstimateAsApproximate() {
    let estimate = RowEstimate(rows: 2_400_000, confidence: .low, basis: "3x256KiB sample")
    let t = fixture(estimate: estimate)
    #expect(t.displayRows == 2_400_000, "the estimate fallback is what makes the ≈ branch reachable")
    #expect(!t.rowsAreExact)
    #expect(rowText(t) == "≈ 2,400,000 rows")
}

@Test func anExactCountCarriesNoApproximationMark() {
    let t = fixture(rowCount: 2_412_338)
    #expect(rowText(t) == "2,412,338 rows")
    #expect(!rowText(t).contains("≈"))
}

@Test func aFilteredTableSaysBothNumbers() {
    let t = fixture(
        rowCount: 2_412_338, filteredCount: 1_204,
        filters: [Filter(col: "region", op: .eq, values: [.text("West")])])
    #expect(rowText(t) == "1,204 of 2,412,338 rows")
}

/// Dropped rows come off the denominator, because they are rows the grid cannot reach — the same
/// `gridRows` the scroll extent is sized from.
@Test func droppedRowsComeOffTheUnfilteredTotal() {
    let t = fixture(
        rowCount: 1_000, filteredCount: 10, filters: [Filter(col: "c", op: .notNull)], badRows: 4)
    #expect(rowText(t) == "10 of 996 rows")
}

// MARK: - the chip

@Test func everyFormatGetsItsOwnChip() {
    #expect(formatBadge(.parquet) == ("square.stack.3d.up.fill", .purple))
    #expect(formatBadge(.globParquet) == ("square.stack.3d.up.fill", .purple))
    #expect(formatBadge(.delta) == ("clock.arrow.circlepath", .orange))
    #expect(formatBadge(.xlsx) == ("tablecells.fill", .teal))
    #expect(formatBadge(.json) == ("curlybraces", .blue))
    #expect(formatBadge(.ndjson) == ("curlybraces", .blue))
    #expect(formatBadge(.globCsv) == ("doc.text.fill", .indigo))
    #expect(formatBadge(.csv) == ("doc.text.fill", .green))
    #expect(formatBadge(.merge) == ("arrow.triangle.merge", .pink))

    // A folder of CSV and a single CSV share a symbol and are told apart by tint alone, which is
    // the pair a "same icon for everything" regression would hide behind.
    #expect(formatBadge(.globCsv).symbol == formatBadge(.csv).symbol)
    #expect(formatBadge(.globCsv).tint != formatBadge(.csv).tint)
}

/// The menu item's applicability, not the engine's decision — `Session.stageNow` still owns whether
/// a copy actually happens. Parquet, a parquet folder and Delta are never staged; a merge view has
/// no file to copy.
@Test func stagingIsOfferedForExactlyTheFormatsTheShellOfferedIt() {
    #expect(stageableFormat(.csv))
    #expect(stageableFormat(.globCsv))
    #expect(stageableFormat(.xlsx))
    #expect(stageableFormat(.json))
    #expect(stageableFormat(.ndjson))
    #expect(!stageableFormat(.parquet))
    #expect(!stageableFormat(.globParquet))
    #expect(!stageableFormat(.delta))
    #expect(!stageableFormat(.merge))
}

// MARK: - the tooltip

@Test func theTooltipCarriesThePathTheSubtitleAndTheDroppedRows() {
    let clean = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338)
    #expect(sourceTooltip(clean) == "/data/orders.csv\ncsv · 41.2 MB · 2,412,338 rows")

    let dirty = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338, badRows: 12_004)
    #expect(
        dirty.spec.key.path == "/data/orders.csv"
            && sourceTooltip(dirty).hasSuffix("\n12,004 rows dropped"),
        "a file that lost rows must say so somewhere the user can find it")
}

// MARK: - the path box

@Test func aPastedAbsolutePathOpensByItselfAndATypedOneDoesNot() {
    // A paste: many characters arrive in one change.
    #expect(autoOpenPath(from: "", to: "/Users/a/data/orders.csv") == "/Users/a/data/orders.csv")
    #expect(autoOpenPath(from: "/Users", to: "/Users/a/data/orders.csv") != nil)
    // Finder's ⌥⌘C hands over a trailing newline often enough to matter.
    #expect(autoOpenPath(from: "", to: "  /data/orders.csv \n") == "/data/orders.csv")

    // 🔴 Typing. One character at a time can never trip this, which is the entire reason the rule is
    // "more than one character arrived" and not "the text starts with a slash".
    #expect(autoOpenPath(from: "", to: "/") == nil)
    #expect(autoOpenPath(from: "/d", to: "/da") == nil)
    // Not a path, however it arrived.
    #expect(autoOpenPath(from: "", to: "orders.csv") == nil)
    #expect(autoOpenPath(from: "", to: "/a/b.csv\n/c/d.csv") == nil, "two paths is not one path")
    // A deletion is not a paste.
    #expect(autoOpenPath(from: "/data/orders.csv", to: "/data") == nil)
}

// MARK: - the armed close

@Test func theCloseNeedsTwoPressesAndForgetsTheFirstAfterTwoAndAHalfSeconds() {
    let now = Date()
    #expect(!closeConfirmed(armedAt: nil, now: now), "a first press must never close a table")
    #expect(closeConfirmed(armedAt: now.addingTimeInterval(-1), now: now))
    #expect(closeConfirmed(armedAt: now.addingTimeInterval(-(armedCloseSeconds - 0.01)), now: now))
    #expect(!closeConfirmed(armedAt: now.addingTimeInterval(-(armedCloseSeconds + 0.01)), now: now))
    #expect(armedCloseSeconds == 2.5)
}

// MARK: - the drop
//
// The window's drop target decides exactly one thing — which real filesystem paths a drag was
// carrying. What happens to them afterwards is `AppState.open(paths:)`, which Task 13 owns and
// tests: the sheet-picker routing lives there and is deliberately NOT restated here, because two
// copies of "is this a workbook" is how `.xlsm` ends up handled in one of them.

/// A `.fileURL` provider carries the URL as its `dataRepresentation`, which is the one part of a
/// drag that can be built without a drag.
private func fileProvider(_ path: String) -> NSItemProvider {
    NSItemProvider(
        item: URL(fileURLWithPath: path).dataRepresentation as NSData,
        typeIdentifier: UTType.fileURL.identifier)
}

@MainActor
@Test func aDropResolvesEveryFileURLItWasHandedInTheOrderItArrived() async {
    let paths = await droppedPaths(from: [fileProvider("/data/a.csv"), fileProvider("/data/b.parquet")])
    #expect(paths == ["/data/a.csv", "/data/b.parquet"])
}

/// 🔴 A provider carrying something that is not a file URL must not become a path. Before this,
/// `URL(dataRepresentation:)` was handed whatever bytes arrived — and a drag of plain text would
/// have gone to the engine as a path, which comes back as "No such file or folder: <the text>".
@MainActor
@Test func aDropOfSomethingThatIsNotAFileResolvesToNothing() async {
    let text = NSItemProvider(
        item: "just some text" as NSString, typeIdentifier: UTType.plainText.identifier)
    #expect(await droppedPaths(from: [text]).isEmpty)
    #expect(await droppedPaths(from: []).isEmpty)

    // 🔴 The one that bites. A provider that *claims* `public.file-url` and hands over bytes that
    // are not a URL gets through `loadItem`, and `URL(dataRepresentation:)` answers it with a
    // RELATIVE url rather than nil — so without `isFileURL` this becomes a path, and the user gets
    // "No such file or folder: just some text" for a drag they never made.
    let liar = NSItemProvider(
        item: Data("just some text".utf8) as NSData, typeIdentifier: UTType.fileURL.identifier)
    #expect(await droppedPaths(from: [liar]).isEmpty)

    // …and one bad provider does not take the good ones with it.
    #expect(await droppedPaths(from: [text, liar, fileProvider("/data/a.csv")]) == ["/data/a.csv"])
}

// MARK: - the pixels

// `ImageRenderer`, not `cacheDisplay`: `cacheDisplay` cannot capture an `NSVisualEffectView`, and
// the real sidebar sits on one — a full-window render comes out with a blank panel exactly where
// this work is.
//
// 🔴 **`ImageRenderer` cannot draw a `List`.** It is an `NSTableView` underneath, so the rows come
// back as one prohibited-symbol placeholder (verified: the first version of this file rendered
// `SourceSidebar` with two real sources open and found neither chip, under a yellow square with a
// no-entry sign on it). `SourceRow` is therefore rendered directly, which is also what lets these
// run over synthetic tables instead of a real engine. The path box's `TextField` is the same kind
// of placeholder inside `SourceSidebar`, and the export `Menu` inside a row is too — neither is
// under test here. Swapping `List` for a hand-rolled `LazyVStack` would render, and is deliberately
// not done: the inset selection pill, the sidebar metrics and keyboard navigation are the reason
// `SidebarViewController` used `.sourceList` in the first place, and a test is not worth losing them.
//
// These are smoke checks, not golden images. Nothing below asserts a pixel COUNT: a different
// renderer draws a different number of them, and a threshold calibrated on one Mac is a test that
// is red on CI for no reason. Every assertion is a relationship between two renders of the same
// view on the same machine.

@MainActor
private func render(_ view: some View, _ width: CGFloat, _ height: CGFloat) throws -> CGImage {
    // 🔴 Pinned light. `ImageRenderer` has no `appearance`, so the appearance comes from the
    // environment — and unset, that is whatever the machine is in. Every render check on this branch
    // had always run in dark, which is how two light-mode defects survived eight suites
    // (`AppearanceTests`).
    let renderer = ImageRenderer(
        content: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.colorScheme, .light))
    return try #require(renderer.cgImage, "ImageRenderer produced no image at all")
}

/// Pixels whose hue is unmistakably one colour's, by RATIO — a chip drawn at 18% alpha keeps its
/// hue and loses its brightness, so an absolute threshold would answer "nothing was drawn".
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

private func violet(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    b > 0.25 && r > g * 1.4 && b > g * 1.4
}

private func verdant(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    g > 0.25 && g > r * 1.6 && g > b * 1.6
}

private func amber(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    r > 0.2 && r > b * 2.5 && g > b && g < r
}

/// The raw pixels, for "these two renders drew different things" — the only claim about drawing a
/// bitmap can support without a reference image.
///
/// 🔴 `combine(bytes:)`, never `Hasher.combine(Data)`: Foundation's `Data.hash(into:)` mixes in at
/// most the first 80 bytes, which here is the blank margin above the chip. Written that way it
/// reports every row in this file as identical.
private func pixelDigest(_ image: CGImage) throws -> Int {
    let data = try #require(image.dataProvider?.data) as Data
    var hasher = Hasher()
    data.withUnsafeBytes { hasher.combine(bytes: $0) }
    return hasher.finalize()
}

@discardableResult
private func writePNG(_ image: CGImage, _ name: String) throws -> String {
    let data = try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let path = ProcessInfo.processInfo.environment["SIFT_RENDER_OUT"]
        .map { ($0 as NSString).appendingPathComponent("\(name).png") }
        ?? TestTemp.path("p4t14-\(name)", ".png")
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

/// 🔴 "It rendered" and "more than one colour is on screen" are both satisfied by a blank row with a
/// divider in it. The assertion with teeth is that the chip's TINT reaches the pixels: the parquet
/// row has violet in it and no green, the CSV row has green and no violet. A row that draws no chip
/// fails both halves; a row that draws every chip in one colour fails one of them whichever colour
/// it picked.
@MainActor
@Test func aSourceRowDrawsItsOwnFormatsChipAndNotJustChrome() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let csv = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338)
    let parquet = fixture(
        name: "sales", fmt: .parquet, path: "/data/sales.parquet", size: 9_000_000, rowCount: 41)
    let merge = fixture(name: "a_b", fmt: .merge, path: "merge://a+b", rowCount: 12)

    let csvImage = try render(SourceRow(table: csv, state: state), 260, 44)
    let parquetImage = try render(SourceRow(table: parquet, state: state), 260, 44)
    let mergeImage = try render(SourceRow(table: merge, state: state), 260, 44)
    let csvPath = try writePNG(csvImage, "row-csv")
    let parquetPath = try writePNG(parquetImage, "row-parquet")
    try writePNG(mergeImage, "row-merge")

    #expect(try inkCount(csvImage, verdant) > 0, "no green CSV chip in \(csvPath)")
    #expect(try inkCount(csvImage, violet) == 0, "violet in a CSV row — see \(csvPath)")
    #expect(try inkCount(parquetImage, violet) > 0, "no violet parquet chip in \(parquetPath)")
    #expect(try inkCount(parquetImage, verdant) == 0, "green in a parquet row — see \(parquetPath)")

    // Three formats, three different rows — the pink merge chip has no hue predicate of its own, so
    // this is what says it is not drawn as one of the other two.
    let digests = try [csvImage, parquetImage, mergeImage].map(pixelDigest)
    #expect(Set(digests).count == 3, "two of the three formats rendered identically")

    await state.session.shutdown()
}

/// The subtitle is the row's whole payload — the format, the size, the count and whether a copy is
/// on disk. Two rows that differ only there must not render the same.
@MainActor
@Test func aSourceRowDrawsItsSubtitleAndTurnsItOrangeWhenRowsWereDropped() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let plain = fixture(size: fortyOnePointTwoMB, rowCount: 2_412_338)
    var staged = plain
    staged.staged = true
    var dropped = plain
    dropped.badRows = 12_004

    let plainImage = try render(SourceRow(table: plain, state: state), 360, 44)
    let stagedImage = try render(SourceRow(table: staged, state: state), 360, 44)
    let droppedImage = try render(SourceRow(table: dropped, state: state), 360, 44)
    let plainPath = try writePNG(plainImage, "row-plain")
    try writePNG(stagedImage, "row-staged")
    let droppedPath = try writePNG(droppedImage, "row-dropped")

    #expect(try pixelDigest(plainImage) != pixelDigest(stagedImage),
        "`staged` never reached the subtitle — see \(plainPath)")
    // 🔴 The chip is green in all three, and `verdant` and `amber` are disjoint by construction
    // (`g > r * 1.6` against `r > b * 2.5 && g < r`), so the orange can only be coming from the
    // subtitle. Nothing else in an unselected row is warm.
    #expect(try inkCount(plainImage, amber) == 0, "orange in a row that dropped nothing")
    #expect(try inkCount(droppedImage, amber) > 0,
        "a row that dropped 12,004 rows says nothing about it — see \(droppedPath)")

    await state.session.shutdown()
}

/// The empty rail is its own state and its own sentence, not a zero-row list.
@MainActor
@Test func anEmptySidebarStillDrawsTheDropzoneAndItsNote() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let cold = try render(
        SourceSidebar(state: state).environment(\.sourceDragHot, false), 260, 420)
    let path = try writePNG(cold, "sidebar-empty")

    // 🔴 The comparison is against the SAME view with the drag hint on: the dropzone's hot state is
    // the only thing that differs, so this can only pass if `\.sourceDragHot` reaches the pixels —
    // which is the feedback whose absence reads as "drops are not supported here".
    let hot = try render(
        SourceSidebar(state: state).environment(\.sourceDragHot, true), 260, 420)
    try writePNG(hot, "sidebar-empty-drag")
    let coldBytes = try #require(cold.dataProvider?.data) as Data
    let hotBytes = try #require(hot.dataProvider?.data) as Data
    #expect(coldBytes != hotBytes, "a drag over the window gives no feedback — see \(path)")

    await state.session.shutdown()
}

// MARK: - the engine, in the window

/// 🔴 The web build showed engine and version in-window; the native port showed it only in About
/// Sift. "Which DuckDB is this" is the first question of every report about a file that read wrong,
/// and a version behind a modal is a version nobody quotes.
///
/// Pinned against a REAL session, so the line carries the version this build is actually linked
/// against rather than one anybody typed. Mutating the function to drop the version, or to name a
/// different engine, goes red here.
@Test func theSidebarFootNamesTheEngineThisSessionIsActuallyUsing() throws {
    let engine = try Session(home: tempHome()).engineInfo()
    let line = engineFooterText(engine)

    #expect(engine.duckdbVersion.count > 1, "the session reported no version at all")
    #expect(line.hasPrefix("DuckDB "), "the line stopped naming the engine")
    #expect(line.contains(engine.duckdbVersion), "the line stopped carrying the live version")
    // About Sift prints the same field the same way, and DuckDB supplies its own leading `v` — so
    // this must not add a second one.
    #expect(!line.contains("vv"))
    #expect(line == "DuckDB \(engine.duckdbVersion)")
}
