import AppKit
import DuckDBKit
import Foundation
import SiftCore
import SwiftUI
import Testing
import TestSupport
@testable import SiftEngine
@testable import SiftUI

// The histogram, the high-cardinality panel and the Source tab — the three inspector surfaces that
// are almost entirely drawing.
//
// 🔴 **Why half of this file reads pixels.** Two defects in the grid were caught only by rendering:
// an empty-string cell whose every property said "dotted rule" and which AppKit drew as a blank
// cell, and a row gutter that elided `119,974` while `intrinsicContentSize` insisted it fit. Bars,
// bins and byte sizes are the same shape of risk — arithmetic that is right and a rectangle that is
// invisible, or a label that is right and a layout that cuts it in half. Neither is observable from
// a property.
//
// Every render assertion below compares TWO GENUINELY DIFFERENT INPUTS and requires the pixels to
// differ. "More than one distinct colour appears" is satisfied by any non-uniform background and
// proves nothing.
//
// `cacheDisplay(in:to:)` on a live `NSHostingView` is the capture route: it needs no permission
// (Screen Recording is not granted here) and it reads the real AppKit/SwiftUI drawing rather than a
// re-derivation of it. It cannot capture an `NSVisualEffectView` — the window server composites
// those — which is why these render the pane and never a window.

/// AppKit wants an app object before any `NSView` exists, even headlessly. Idempotent.
@MainActor
private func appKitReady() { _ = NSApplication.shared }

// MARK: - humanBytes

/// A port of `web/index.html:464-470`, pinned at every unit boundary.
///
/// 🔴 `ByteCountFormatter` would pass none of this reliably: it follows `Locale.current` for the
/// decimal separator and switches between SI and binary units by region, so `1_572_864` reads
/// `1.5 MB` here and `1.65 MB` on a machine set up slightly differently.
@Test func humanBytesIsTheWebsUnitLadderAndNotTheSystemFormatters() {
    #expect(humanBytes(0) == "0 B")
    #expect(humanBytes(1) == "1 B")
    #expect(humanBytes(1023) == "1023 B", "no decimal and no grouping below a kilobyte")
    #expect(humanBytes(1024) == "1.0 KB", "…and exactly one decimal from there up")
    #expect(humanBytes(1536) == "1.5 KB")
    #expect(humanBytes(1_048_576) == "1.0 MB")
    #expect(humanBytes(1_572_864) == "1.5 MB")
    #expect(humanBytes(1_073_741_824) == "1.0 GB")
    #expect(humanBytes(1_099_511_627_776) == "1.0 TB")
    // The ladder stops at TB rather than rolling over into a unit nobody has a feel for.
    #expect(humanBytes(1_099_511_627_776 * 2048) == "2048.0 TB")
}

// MARK: - the bars

/// 🔴 The defect this exists for: `histogramSQL`'s `GROUP BY b` emits NO ROW for an empty bucket, so
/// drawing `panel.buckets` in array order puts bucket 5 in slot 2 and shifts everything after it —
/// a plausible, entirely wrong distribution, in the panel whose only job is showing the shape of the
/// data.
@Test func anAbsentBucketDrawsZeroHeightInItsOwnSlotRatherThanShiftingItsNeighbours() {
    let bars = HistogramView.bars(panelOf(bins: 6, buckets: [(0, 100), (1, 50), (5, 25)]))

    #expect(bars.count == 6, "one bar per bin, present or not")
    #expect(bars.map(\.fraction) == [1.0, 0.5, 0, 0, 0, 0.25])
    #expect(bars[2].tooltip == "0 rows")
    #expect(bars[5].tooltip.hasPrefix("25 rows"), "the last bucket stayed last")
}

/// A single row among a million still has to be visible, or the panel says "empty" about data that
/// is there — `Math.max(n ? 2 : 0, …)` in the web.
@Test func aBucketWithRowsInItNeverDrawsShorterThanTwoPercentAndAnEmptyOneDrawsNothing() {
    let bars = HistogramView.bars(panelOf(bins: 3, buckets: [(0, 1_000_000), (1, 1)]))
    #expect(bars[0].fraction == 1.0)
    #expect(bars[1].fraction == 0.02, "one row in a million is still a bar")
    #expect(bars[2].fraction == 0, "…and a bucket with nothing in it is still nothing")
}

@Test func theNullBarIsScaledAgainstWhicheverIsTallerAndIsAbsentWhenNothingIsNull() {
    #expect(HistogramView.nullBar(panelOf(bins: 4, buckets: [(0, 10)], nNull: 0)) == nil)

    let some = HistogramView.nullBar(panelOf(bins: 4, buckets: [(0, 100)], nNull: 25))
    #expect(some?.fraction == 0.25)
    #expect(some?.tooltip == "25 null (excluded from the buckets)")

    // 🔴 A mostly-null column: scaling against the buckets alone gives 10.0 and a bar ten plot
    // heights tall, which draws as a solid block over the whole panel.
    let mostly = HistogramView.nullBar(panelOf(bins: 4, buckets: [(0, 100)], nNull: 1_000))
    #expect(mostly?.fraction == 1.0)
    #expect(mostly?.tooltip == "1,000 null (excluded from the buckets)", "grouped, by groupDigits")
}

@Test func theCaptionCountsBucketsAndOnlyMentionsNullsWhenThereAreSome() {
    #expect(HistogramView.caption(panelOf(bins: 40, buckets: [(0, 1)])) == "40 buckets")
    #expect(
        HistogramView.caption(panelOf(bins: 40, buckets: [(0, 1)], nNull: 12_500))
            == "40 buckets · 12,500 null shown separately in amber")
}

@Test func aDegenerateColumnSaysWhyInsteadOfPlottingAFlatLine() {
    let flat = HistogramPanel(
        col: "x", kind: nil, lo: nil, step: nil, bins: nil, nNull: 0, buckets: [],
        degenerate: true, reason: "every value is the same, or the range is empty", milliseconds: nil)
    #expect(
        HistogramView.degenerateText(flat)
            == "No spread to plot — every value is the same, or the range is empty.")
    #expect(HistogramView.bars(flat).isEmpty, "no bins means no slots to draw")
}

/// The axis takes the profile's own extremes when there is one, and the buckets' otherwise — it
/// never invents a number.
@Test func theAxisPrefersTheProfilesExtremesAndFallsBackToTheBucketsOwn() {
    let panel = panelOf(bins: 4, buckets: [(0, 10), (3, 4)], low: .double(1.5), high: .double(88.25))
    #expect(HistogramView.axis(panel, profile: nil).min == "1.5")
    #expect(HistogramView.axis(panel, profile: nil).max == "88.25")

    let profile = ColumnProfile(name: "x", type: "DOUBLE", kind: .number, minS: "0", maxS: "99")
    #expect(HistogramView.axis(panel, profile: profile) == ("0", "99"))

    #expect(HistogramView.axis(panelOf(bins: 4, buckets: []), profile: nil) == ("", ""))
}

// MARK: - high cardinality

@Test func theHighCardSentenceNamesTheRatioAndSaysWhyThereIsNoRankedList() {
    let profile = ColumnProfile(
        name: "order_id", type: "VARCHAR", kind: .text, n: 1_200_000, approxDistinct: 1_199_988,
        view: .highcard)
    #expect(
        HighCardView.headline(profile) == "1,199,988 distinct of 1,200,000 rows (100.0%) — this "
            + "looks like an identifier, so a ranked list would tell you nothing.")

    // A column that is high-cardinality by count but not by ratio still gets a real percentage —
    // and one under 1 % gets the second decimal, so it does not read as `0.0%`.
    let sparse = ColumnProfile(name: "u", type: "VARCHAR", kind: .text, n: 1_000, approxDistinct: 4)
    #expect(HighCardView.headline(sparse).hasPrefix("4 distinct of 1,000 rows (0.40%)"))

    // And a table with no rows cannot divide by zero.
    let none = ColumnProfile(name: "u", type: "VARCHAR", kind: .text, n: 0, approxDistinct: 0)
    #expect(HighCardView.headline(none).contains("(0.0%)"))
}

/// The web's `pct`: two decimals only where one would round a real value down to `0.0%`.
@Test func smallPercentagesGetASecondDecimalSoTheyAreNotRoundedToNothing() {
    #expect(HighCardView.pct(0) == "0.0%")
    #expect(HighCardView.pct(0.0004) == "0.04%")
    #expect(HighCardView.pct(0.009) == "0.90%")
    #expect(HighCardView.pct(0.01) == "1.0%")
    #expect(HighCardView.pct(1) == "100.0%")
}

/// 🔴 Design spec §9 in the sample list: `Cell.display` renders a NULL and an empty string
/// identically as `""`, so a sample built from it would show two blank rows and imply they are the
/// same value.
@Test func aNullSampleSaysSoAndAnEmptyStringIsStillNotTheSameThing() {
    #expect(HighCardView.sampleLabel(.null, kind: .text) == "␀ NULL")
    #expect(HighCardView.sampleLabel(.text(""), kind: .text) == SiftEngine.emptyStringGlyph)
    #expect(HighCardView.sampleLabel(.text("NULL"), kind: .text) == "NULL", "the literal text")
    #expect(HighCardView.sampleLabel(.int(42), kind: .number) == "42")
    #expect(HighCardView.sampleLabel(.bool(true), kind: .bool) == "true")
}

@Test func aLengthBucketsTooltipNamesTheLengthAndTheGroupedCount() {
    #expect(
        HighCardView.lengthTooltip(LengthBucket(len: 36, n: 1_200_000))
            == "length 36: 1,200,000 rows")
}

// MARK: - the source tab

/// 🔴 Built by hand, not by opening a file. `stats` is a pure map from `Table` to rows, and every
/// opened `Session` in this target is a real `SUMMARIZE` competing with the five-second `waitFor`
/// budgets the rest of the suite runs on — MEASURED: this file's fixtures were enough to time three
/// of those out on a loaded machine. The real-open path is still covered, once, by the Source-tab
/// render below.
@Test func theStatsGridSaysWhatIsKnownLeavesOutWhatIsNotAndTildesAnEstimate() throws {
    var table = fakeTable(fmt: .csv)
    table.spec = SourceSpec(
        key: SourceKey(path: "/tmp/stats.csv", mtimeNs: 0, size: 134), fmt: .csv, readFn: "read_csv",
        columns: [
            Column(name: "id", type: "BIGINT"), Column(name: "label", type: "VARCHAR"),
            Column(name: "note", type: "VARCHAR"),
        ],
        rowEstimate: RowEstimate(
            rows: 4_812_004, confidence: .low, basis: "3x256KiB sample, no quotes seen"))
    table.rowCount = 12

    let stats = SourceTab.stats(table)
    let byLabel = Dictionary(stats.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
    #expect(
        Array(stats.map(\.label).prefix(4)) == ["format", "size", "columns", "rows"],
        "the web's order")
    #expect(byLabel["format"] == "csv")
    #expect(byLabel["columns"] == "3")
    #expect(byLabel["rows"] == "12", "counted exactly, so no ≈ — and NOT the 4.8M estimate")
    #expect(byLabel["size"] == "134 B")
    #expect(byLabel["staged"] == nil, "a `staged: no` row is a claim about a feature not in play")
    #expect(byLabel["sheet"] == nil)
    #expect(byLabel["delta version"] == nil)
    #expect(
        byLabel["physical rows"] == nil,
        "identical to `rows` here — printing both only invites 'which one is right'")

    // The rows that appear only when they have something to say.
    var noisy = table
    noisy.badCells = 4_000
    noisy.staged = true
    #expect(SourceTab.stats(noisy).contains(SourceTab.Stat(label: "bad cells", value: "4,000")))
    #expect(SourceTab.stats(noisy).contains(SourceTab.Stat(label: "staged", value: "yes")))

    // 🔴 The tilde: the entire difference between "this file has 4,812,004 rows" and "we guessed
    // 4,812,004", in the product whose premise is not lying about data.
    #expect(table.rowsAreExact)
    #expect(SourceTab.rowsText(table) == "12")
    #expect(rowsBasisText(table.rowsBasis) == "counted exactly")

    // The same table as a multi-GB CSV arrives: no count yet, so `displayRows` falls back to the
    // byte-sample estimate — and the number on screen has to say which one it is.
    var pending = table
    pending.rowCount = nil
    #expect(SourceTab.rowsText(pending) == "≈4,812,004")
    #expect(rowsBasisText(pending.rowsBasis) == "3x256KiB sample, no quotes seen")

    // And a source with neither says nothing rather than zero — "0 rows" about a file that is still
    // being counted is a wrong answer, not a placeholder.
    var unknown = pending
    unknown.spec = SourceSpec(key: pending.spec.key, fmt: .csv, readFn: "read_csv")
    #expect(unknown.displayRows == nil)
    #expect(SourceTab.rowsText(unknown) == "…")
    #expect(rowsBasisText(unknown.rowsBasis) == "counting…")
}

@Test func onlyTheFormatsWorthCopyingOfferTheButtonAndTheRestExplainWhyNot() {
    #expect(SourceTab.stageable == [.csv, .globCsv, .xlsx, .json, .ndjson])
    #expect(!SourceTab.stageable.contains(.parquet), "columnar already — a copy only duplicates it")
    #expect(!SourceTab.stageable.contains(.delta))
    #expect(!SourceTab.stageable.contains(.globParquet))
    #expect(!SourceTab.stageable.contains(.merge), "a view over other tables, not a file")

    #expect(SourceTab.staging(fakeTable(fmt: .csv)) == .stageable)
    #expect(SourceTab.staging(fakeTable(fmt: .parquet)) == .neither)
    #expect(SourceTab.staging(fakeTable(fmt: .csv, staged: true)) == .staged)
    // Staged wins over stageable: a table that already has a copy is offered the way back, not a
    // second copy.
    #expect(SourceTab.staging(fakeTable(fmt: .parquet, staged: true)) == .staged)
}

@Test func theStagingNoteQuotesTheEnginesOwnReasonAndTellsMergeApartFromColumnar() {
    #expect(SourceTab.stagingNote(fakeTable(fmt: .csv, staged: true)).hasPrefix("Staged:"))

    // The engine's `shouldStage` is the authority on the decision, and its reason is appended
    // verbatim — the button and the explanation of why it is being offered cannot drift apart.
    var decided = fakeTable(fmt: .csv)
    decided.stageDecision = StageDecision(stage: false, reason: "only 4 KB — re-reading it is faster")
    #expect(SourceTab.stagingNote(decided).hasSuffix("only 4 KB — re-reading it is faster."))
    #expect(!SourceTab.stagingNote(fakeTable(fmt: .csv)).contains("re-reading"), "no decision yet")

    #expect(
        SourceTab.stagingNote(fakeTable(fmt: .merge))
            == "A merged view — export it if you want a saved copy.")
    #expect(
        SourceTab.stagingNote(fakeTable(fmt: .parquet))
            == "Already columnar with per-file statistics, so staging would not make it faster.")
}

@Test func theDetectedDialectBreaksOneUnreadableLineIntoOneArgumentPerLine() {
    let prompt = "read_csv('/tmp/a.csv', delim=',', header=true, quote='\"')"
    #expect(
        SourceTab.dialectText(prompt) == """
            read_csv('/tmp/a.csv',
              delim=',',
              header=true,
              quote='"')
            """)
    // A prompt with no argument separators is left exactly as it is.
    #expect(
        SourceTab.dialectText("read_parquet('/tmp/a.parquet')") == "read_parquet('/tmp/a.parquet')")
}

@Test func aSheetsRowSaysItsShapeOrThatItIsEmpty() {
    #expect(SourceTab.sheetDetail(SheetInfo(name: "Q1", rows: 12_500, cols: 8)) == "12,500×8")
    #expect(SourceTab.sheetDetail(SheetInfo(name: "blank", rows: 1, cols: 1)) == "empty")
}

// MARK: - rendered

/// 🔴 **The two-render rule.** Two columns whose distributions are genuinely different have to draw
/// differently. A blankness check ("some pixel is not the background") passes on a view that draws
/// the same bar for every column, which is exactly the bug a histogram can have.
///
/// 🔴 And the comparison is of the PLOT BAND, not of the whole picture. Two columns with different
/// extremes differ in their axis labels whatever the bars do, so a whole-render digest is green on a
/// histogram drawing one identical bar per bucket — the same vacuity the inspector task hit when a
/// header band alone carried its "two renders differ".
@MainActor
@Test func twoColumnsWithDifferentDistributionsDrawDifferentHistograms() async throws {
    appKitReady()
    let (state, name) = try await histFixture()
    let ramp = try await state.session.histogram(name, col: "ramp", bins: 12)
    let clump = try await state.session.histogram(name, col: "clump", bins: 12)
    #expect(!ramp.degenerate && !clump.degenerate, "both columns have a real spread to plot")

    let rampImage = try render(HistogramView(panel: ramp), "hist-ramp")
    let clumpImage = try render(HistogramView(panel: clump), "hist-clump")
    #expect(ink(rampImage) > 200, "a histogram that draws nothing is not a histogram")
    // A `Comment` has to be a single literal, which is why the longer ones do not wrap.
    #expect(
        digest(rampImage, rows: plotBand(rampImage)) != digest(clumpImage, rows: plotBand(clumpImage)),
        "a uniform ramp and two spikes are not the same picture — if these match, every column draws the same bars")
    #expect(
        digest(rampImage) == digest(rampImage), "the digest has to be stable to mean anything")

    // …and the degenerate branch is a third, different picture: a sentence, not a plot.
    let flat = try await state.session.histogram(name, col: "same", bins: 12)
    #expect(flat.degenerate)
    let flatImage = try render(HistogramView(panel: flat), "hist-flat")
    #expect(ink(flatImage) > 100, "the reason has to actually be on screen")
    #expect(digest(flatImage) != digest(rampImage))

    // The null count comes off the engine's own profile, which is what the amber bar below is fed.
    let gappy = try await state.session.histogram(name, col: "gappy", bins: 12)
    #expect(gappy.nNull > 0 && ramp.nNull == 0, "a real column with nulls, and one without")
}

/// 🔴 The null bar is the one mark on this plot meaning "rows that are in NO bucket". Drawn in the
/// bar colour it reads as the first bucket — a count of nulls presented as a count of values.
///
/// Hand-built panels rather than a second opened file: the two differ ONLY in `nNull`, so the axis,
/// the buckets and the caption are identical and the amber bar is the only thing that can move.
@MainActor
@Test func theNullBarIsAmberAndDrawnInFrontOfTheBucketsRatherThanAsOne() throws {
    appKitReady()
    let buckets = (0..<12).map { ($0, 100 - $0 * 4) }
    let plotted = try render(
        HistogramView(panel: panelOf(bins: 12, buckets: buckets, nNull: 225)), "hist-nulls")
    let plain = try render(
        HistogramView(panel: panelOf(bins: 12, buckets: buckets)), "hist-nonulls")

    // Amber by COLOUR, not by "some extra pixels appeared" — the accent satisfies that too.
    let amber = amberPixels(plotted)
    #expect(amberPixels(plain).isEmpty, "no nulls, no amber")
    #expect(amber.count > 40, "the amber bar has to actually be painted")

    // In front of the buckets, and 9 pt wide — `.hist i.nul { flex: 0 0 9px }`. A null bar that
    // stretched like a bucket would claim a share of the axis it does not have.
    let scale = max(1, plotted.pixelsWide / Int(renderWidth))
    let columns = amber.map(\.x)
    let span = try #require(columns.max()) - (try #require(columns.min())) + 1
    #expect(abs(span / scale - 9) <= 2, "a 9-pt bar, not a bucket-width one")
    #expect(
        try #require(columns.min()) == (try #require(paintedColumns(plotted).min())),
        "the leftmost thing on the plot is the null bar")
    #expect(digest(plotted) != digest(plain))
}

/// 🔴 The gutter defect, one panel over: a min/max label the layout cuts is a number that is WRONG
/// on screen. `expansionFrame` is AppKit's own answer to "did this cell elide", but SwiftUI draws
/// `Text` itself and puts no `NSTextField` in the hierarchy to ask — so the equivalent proof is
/// rendering two labels that differ only in their LAST characters. If either end is being trimmed,
/// the two pictures come out identical.
@MainActor
@Test func theAxisDrawsTheWholeOfALongTimestampRatherThanElidingItsTail() throws {
    appKitReady()
    let panel = panelOf(bins: 12, buckets: [(0, 10), (11, 4)])
    func axis(_ maxLabel: String, _ tag: String) throws -> NSBitmapImageRep {
        let profile = ColumnProfile(
            name: "t", type: "TIMESTAMP", kind: .temporal, minS: "2026-08-09 14:03:01",
            maxS: maxLabel)
        return try render(HistogramView(panel: panel, profile: profile), tag)
    }
    // Two 19-character maxima differing ONLY in their final character: the web's own
    // `.slice(0, 18)`, ported literally, renders these two identically.
    #expect(
        digest(try axis("2026-08-09 23:59:01", "axis-01"))
            != digest(try axis("2026-08-09 23:59:02", "axis-02")),
        "the last character is being cut off the axis — different maxima, identical pictures")
}

/// The high-card panel's three parts all have to reach the screen: two length distributions that
/// differ have to draw differently, and the sample list has to draw at all.
@MainActor
@Test func theHighCardPanelDrawsItsLengthsAndItsSampleAndNotJustItsSentence() throws {
    appKitReady()
    let profile = ColumnProfile(
        name: "id", type: "VARCHAR", kind: .text, n: 900, approxDistinct: 899, view: .highcard)
    let even = (6...11).map { LengthBucket(len: $0, n: 150) }
    let skewed = (6...11).map { LengthBucket(len: $0, n: $0 == 8 ? 800 : 20) }
    let sample: [Cell] = [.text("a4c1"), .null, .text(""), .text("9f20")]

    let flatImage = try render(
        HighCardView(profile: profile, lengths: even, sample: sample), "highcard-even", height: 260)
    let skewImage = try render(
        HighCardView(profile: profile, lengths: skewed, sample: sample), "highcard-skew",
        height: 260)
    let noSample = try render(
        HighCardView(profile: profile, lengths: even, sample: []), "highcard-nosample", height: 260)

    #expect(ink(flatImage) > 500, "an unrendered panel is not a panel")
    #expect(digest(flatImage) != digest(skewImage), "every length bucket is drawing the same bar")
    #expect(digest(flatImage) != digest(noSample), "the sample list never drew")
}

/// The Source tab's path line WRAPS rather than eliding, and this is what proves it: two files at
/// the same depth whose directories differ only near the end of a long path. A line that truncated
/// would draw both identically — and the question that line exists to answer is precisely *which*
/// of the four `data.csv`s this is.
@MainActor
@Test func theSourceTabDrawsTheWholePathAndTheRowsThatOnlyAppearWhenTheyMatter() async throws {
    appKitReady()

    // One `Session` for both files, with the first CLOSED before the second opens — two sessions
    // would be two `SUMMARIZE`s, and closing is also what lets both tables be called `data`, which
    // is the whole point: the path has to be the only thing that differs.
    let state = AppState(session: try Session(home: tempHome()))
    func openUnder(_ suffix: String) async throws -> SiftEngine.Table {
        let root = tempDir("p4t9-source")
            .appendingPathComponent("analytics_exports_2026_quarterly_run_\(suffix)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try makeCSV(in: root, name: "data.csv", rows: 12)
        await state.open(path: root.appendingPathComponent("data.csv").path)
        return try #require(state.active)
    }

    // 🔴 The path pair is compared with the "Detected dialect" block OFF, because that block quotes
    // the whole path back. MEASURED: with it on, this test stayed GREEN under a `.lineLimit(1)`
    // mutation on the path line — the dialect text moved the pixels all by itself, and the
    // assertion was proving nothing about the line it names.
    func withoutDialect(_ table: SiftEngine.Table) -> SiftEngine.Table {
        var out = table
        out.spec = SourceSpec(
            key: table.spec.key, fmt: table.spec.fmt, readFn: table.spec.readFn,
            columns: table.spec.columns, rowEstimate: table.spec.rowEstimate)
        return out
    }

    let alpha = try await openUnder("alpha")
    await state.close(alpha.name)
    let omega = try await openUnder("omega")
    #expect(alpha.name == omega.name, "same table name — the PATH is the only thing that differs")
    #expect(alpha.spec.key.size == omega.spec.key.size, "…and the same size, so is the stats grid")

    let alphaPath = try render(
        SourceTab(state: state, table: withoutDialect(alpha)), "source-alpha-path",
        width: 300, height: 320)
    let omegaPath = try render(
        SourceTab(state: state, table: withoutDialect(omega)), "source-omega-path",
        width: 300, height: 320)
    #expect(
        digest(alphaPath) != digest(omegaPath),
        "the path is being cut before the part that tells these two files apart")

    // One full-height render, so the dialect block is actually drawn once rather than only reasoned
    // about — and it is the only tall one, because a 760-pt hosting view is the most main-actor time
    // anything here spends.
    let alphaImage = try render(
        SourceTab(state: state, table: alpha), "source-alpha", width: 300, height: 760)
    #expect(ink(alphaImage) > 500, "an empty Source tab is a Source tab that failed to render")

    // And a stats row that exists only when it has something to say has to actually reach the
    // screen — `stats` returning it and the grid dropping it look identical from a property.
    var damaged = withoutDialect(alpha)
    damaged.badCells = 4_000
    let damagedImage = try render(
        SourceTab(state: state, table: damaged), "source-badcells", width: 300, height: 320)
    #expect(digest(damagedImage) != digest(alphaPath), "the bad-cells row never drew")
}

// MARK: - rendering

private let renderWidth: CGFloat = 280
private let renderHeight: CGFloat = 160

/// Draw a view through AppKit and hand back its pixels.
///
/// `NSHostingView` + `cacheDisplay(in:to:)`: no window, no permission, and the drawing is the real
/// thing rather than a re-derivation. Set `SIFT_RENDER_DUMP=/some/dir` to keep the PNGs.
@MainActor
private func render<V: View>(
    _ view: V, _ tag: String, width: CGFloat = renderWidth, height: CGFloat = renderHeight
) throws -> NSBitmapImageRep {
    appKitReady()
    let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading))
    // 🔴 Pinned to Aqua. Without it the render follows whatever appearance the machine running
    // the suite happens to be in, and every pixel assertion below means something different on a
    // laptop in dark mode than it does on the CI runner.
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["SIFT_RENDER_DUMP"],
        let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag).png"))
    }
    return rep
}

/// Every pixel byte, row padding excluded — `bytesPerRow` can exceed the row's real width and the
/// slack is not initialized, which would make the digest differ from itself.
///
/// 🔴 Every byte, walked explicitly. `Hasher.combine(someData)` — the obvious spelling — hashes at
/// most the first 80 bytes, which on a rendered panel is blank margin, and calls two visibly
/// different pictures identical. `rows:` narrows it to a band when the rest of the picture differs
/// for reasons that are not the thing under test.
private func digest(_ rep: NSBitmapImageRep, rows: Range<Int>? = nil) -> UInt64 {
    guard let data = rep.bitmapData else { return 0 }
    let perRow = rep.pixelsWide * rep.samplesPerPixel
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for y in rows ?? 0..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for i in 0..<perRow { hash = (hash ^ UInt64(row[i])) &* 0x0100_0000_01b3 }
    }
    return hash
}

/// Pixels this code actually painted. The host view has no background, so anything with alpha is
/// ink — and the threshold is deliberately low: the bars are drawn at 0.75 opacity and `.secondary`
/// text at about half, so "opaque" would count neither and a blank panel would pass.
private func ink(_ rep: NSBitmapImageRep) -> Int {
    guard rep.samplesPerPixel == 4, let data = rep.bitmapData else { return 0 }
    var count = 0
    for y in 0..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for x in 0..<rep.pixelsWide where row[x * 4 + 3] > 40 { count += 1 }
    }
    return count
}

private struct Painted: Hashable {
    let x: Int
    let y: Int
}

/// The plot band only — the axis and caption below it are ink too, and they start at x = 0.
private func plotBand(_ rep: NSBitmapImageRep) -> Range<Int> {
    let scale = max(1, rep.pixelsHigh / Int(renderHeight))
    return 0..<min(rep.pixelsHigh, Int(HistogramView.plotHeight) * scale)
}

/// Pixels within a whisker of the web's `--stale` amber (`#b07d1e`). A tolerance rather than an
/// exact match because the capture lands in `NSCalibratedRGB` and shifts the value (MEASURED:
/// `#b07d1e` arrives as 159,106,24) — wide enough for that, nowhere near the accent colour.
private func amberPixels(_ rep: NSBitmapImageRep) -> [Painted] {
    guard rep.samplesPerPixel == 4, let data = rep.bitmapData else { return [] }
    var out: [Painted] = []
    for y in plotBand(rep) {
        let row = data + y * rep.bytesPerRow
        for x in 0..<rep.pixelsWide {
            let p = row + x * 4
            guard p[3] > 200 else { continue }
            if abs(Int(p[0]) - 176) < 32, abs(Int(p[1]) - 125) < 32, abs(Int(p[2]) - 30) < 32 {
                out.append(Painted(x: x, y: y))
            }
        }
    }
    return out
}

/// Every column of the plot band carrying ink.
private func paintedColumns(_ rep: NSBitmapImageRep) -> [Int] {
    guard rep.samplesPerPixel == 4, let data = rep.bitmapData else { return [] }
    var out: Set<Int> = []
    for y in plotBand(rep) {
        let row = data + y * rep.bytesPerRow
        for x in 0..<rep.pixelsWide where row[x * 4 + 3] > 40 { out.insert(x) }
    }
    return out.sorted()
}

// MARK: - fixtures

/// A panel built by hand, for the arithmetic tests — the engine's own panels cannot be made to have
/// a hole in exactly bin 2.
private func panelOf(
    bins: Int, buckets: [(Int, Int)], nNull: Int = 0, low: Cell = .double(0), high: Cell = .double(1)
) -> HistogramPanel {
    HistogramPanel(
        col: "x", kind: .number, lo: 0, step: 1, bins: bins, nNull: nNull,
        buckets: buckets.map {
            HistogramPanel.Bucket(
                b: $0.0, lo: Double($0.0), hi: Double($0.0 + 1), n: $0.1,
                bMin: $0.0 == buckets.first?.0 ? low : .double(Double($0.0)),
                bMax: $0.0 == buckets.last?.0 ? high : .double(Double($0.0 + 1)))
        },
        degenerate: false, reason: nil, milliseconds: 1)
}

private func fakeTable(fmt: Fmt, staged: Bool = false) -> SiftEngine.Table {
    var t = SiftEngine.Table(
        name: "t",
        spec: SourceSpec(
            key: SourceKey(path: "/tmp/t", mtimeNs: 0, size: 4_096), fmt: fmt, readFn: "read_csv"),
        qspec: QuerySpec(relation: "t"), openedAt: 0)
    t.staged = staged
    return t
}

/// Four columns with deliberately different shapes: a uniform ramp, two spikes with empty bins
/// between them, a column that is a quarter values and three-quarters NULL, and one constant value
/// so the degenerate branch is reachable from real data rather than a hand-built panel.
@MainActor
private func histFixture() async throws -> (AppState, String) {
    let path = tempDir("p4t9-hist").appendingPathComponent("dist.csv").path
    var out = "ramp,clump,gappy,same\n"
    for i in 0..<300 {
        out += "\(i),\(i < 250 ? 5 : 95),\(i % 4 == 0 ? String(i) : ""),7\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: path)
    return (state, try #require(state.activeName))
}
