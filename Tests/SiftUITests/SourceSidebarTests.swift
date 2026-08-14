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
    filters: [Filter] = [], badRows: Int = 0, counting: Bool = false, staged: Bool = false,
    sheet: String? = nil, sheets: [SheetInfo] = [], remote: RemoteRef? = nil
) -> SiftEngine.Table {
    let spec = SourceSpec(
        key: SourceKey(path: path, mtimeNs: 0, size: size), fmt: fmt, readFn: "read_csv",
        rowEstimate: estimate, sheet: sheet, sheets: sheets, remote: remote)
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

    // A local source has no fetch to report, and must not grow a line saying so.
    #expect(!sourceTooltip(clean).contains("Fetched"))
    #expect(remoteFetchedAt(clean) == nil)
}

// MARK: - a remote source, on screen
//
// The engine has opened URLs since `eefbedc` and refreshed them since `02ceb35`. Until this task
// the sidebar drew a remote table exactly like a local one: the row said nothing about the network,
// nothing about when the bytes arrived, and offered no way to ask for them again.

/// A `RemoteRef` as the engine writes one — `url` is `RemoteURL.sanitized` by contract.
private func remoteRef(
    _ url: String = "https://acct.blob.core.windows.net/c/sales.csv",
    fetchedAtNs: Int = 1_755_180_720_000_000_000, signed: Bool = false
) -> RemoteRef {
    RemoteRef(
        url: url, etag: "\"v1\"", lastModifiedMs: nil, contentLength: 4096,
        fetchedAtNs: fetchedAtNs, cachePath: "/tmp/remote-cache/1a2b3c.csv", signed: signed)
}

/// 🔴 The row's three missing facts, all three of them. `spec.remote` is non-nil for exactly the
/// sources that came from a URL, which is why `offersRefresh` asks it and never a string.
@Test func aRemoteRowSaysItCameOverTheNetworkAndWhenTheBytesArrived() throws {
    let url = "https://acct.blob.core.windows.net/c/sales.csv"
    let remote = fixture(
        name: "sales", path: url, size: fortyOnePointTwoMB, rowCount: 900, remote: remoteRef(url))
    let local = fixture(size: fortyOnePointTwoMB, rowCount: 900)

    #expect(offersRefresh(remote), "no ⟳ on the only kind of table that can be refreshed")
    #expect(!offersRefresh(local), "⟳ on a table the engine reads from disk on every query")

    // The path line is the sanitized URL — what `RemoteRef.url` holds and what `_sift_sources`
    // persists — and the fetch time is its own line rather than a segment of the subtitle, which
    // truncates to the tail in a 220 pt sidebar.
    let fetched = try #require(remoteFetchedAt(remote))
    #expect(
        sourceTooltip(remote)
            == "\(url)\ncsv · 41.2 MB · 900 rows\nFetched from the network \(fetched)")
    #expect(sourceTooltip(remote).contains(url))

    // The subtitle itself is untouched: a remote CSV is still a CSV of that size with that many
    // rows, and the network fact rides the glyph beside it, not the string.
    #expect(sourceSubtitle(remote) == sourceSubtitle(local))
}

/// 🔴 **Nanoseconds since the UNIX epoch, rendered by `stagedTimestamp` and no formatter.**
/// `fetchClockNs()` is `Date().timeIntervalSince1970 * 1e9` — deliberately a wall clock rather than
/// `uptimeNanoseconds`, because the value is compared on a later launch — so it can be rendered at
/// all. Getting the scale wrong is the failure this pins: a `/ 1_000` divisor puts the fetch a
/// million years out and the row states it with total confidence.
@Test func theFetchTimeIsTheEpochInNanosecondsAndIsBuiltWithoutAFormatter() throws {
    let seconds = 1_755_180_720.0
    let t = fixture(remote: remoteRef(fetchedAtNs: Int(seconds * 1_000_000_000)))
    let rendered = try #require(remoteFetchedAt(t))

    #expect(rendered == stagedTimestamp(Date(timeIntervalSince1970: seconds)))
    #expect(rendered != stagedTimestamp(Date(timeIntervalSince1970: seconds * 1_000)),
            "a milliseconds reading of the same field renders a different, equally confident date")

    // `YYYY-MM-DD HH:MM`, zero-padded, whatever time zone this machine is in — the shape is
    // assertable where the value is not.
    let halves = rendered.split(separator: " ")
    #expect(halves.count == 2)
    #expect(halves[0].split(separator: "-").map(\.count) == [4, 2, 2])
    #expect(halves[1].split(separator: ":").map(\.count) == [2, 2])
}

/// 🔴 The outcome is RENDERED, never inferred. `.unchanged` and `.refetched` leave the same grid,
/// the same row count and the same everything — which is why `refreshRemote` returns the case at
/// all, and why a UI that read a side effect would be right half the time and confident always.
@Test func aRefreshSaysWhichOfTheTwoOutcomesTheEngineMeasured() {
    let unchanged = refreshOutcomeText(table: "sales", .unchanged(since: "14:32"))
    let refetched = refreshOutcomeText(table: "sales", .refetched)

    #expect(unchanged == "sales: unchanged since 14:32.")
    #expect(refetched == "sales: re-fetched from the source.")
    #expect(unchanged != refetched, "one sentence for both outcomes says nothing")
    // `since` is the engine's already-rendered `HH:MM` (`clockHHMM`, built from `Calendar`
    // components), passed through rather than re-derived — this codebase has no way to format a
    // `Date` in the UI, which is the point.
    #expect(unchanged.contains("14:32"))
}

/// 🔴 **A signed source cannot be RE-OPENED from `RemoteRef.url` either, and now Sift knows which
/// ones those are.** T10 shipped `refreshSignedURLNote` — a conditional sentence appended to every
/// refresh failure — because `RemoteRef` carried no marker and inventing one at the view layer would
/// have been guessing. `RemoteRef.signed` is that marker, so the guess is gone and this is a fact
/// being read: `nil` for a local table, `nil` for an unsigned remote one, a sentence for a signed
/// one.
///
/// The pair is the point. A refusal that fires on every remote source would pass an "it refuses a
/// signed one" assertion just as happily, and would break the ordinary pasted-URL workbook — which
/// is the common case this whole phase was designed around.
@Test func onlyASignedSourceIsRefusedAReopenFromTheUrlSiftKept() throws {
    let url = "https://acct.blob.core.windows.net/c/sales.csv"
    let signed = fixture(name: "sales", path: url, remote: remoteRef(url, signed: true))
    let unsigned = fixture(name: "sales", path: url, remote: remoteRef(url))
    let local = fixture(name: "sales")

    #expect(signedReopenRefusal(unsigned) == nil, "an ordinary pasted URL re-opens fine")
    #expect(signedReopenRefusal(local) == nil, "a file on disk has no signature to have lost")

    let text = try #require(
        signedReopenRefusal(signed), "the one source that cannot be re-opened was offered the try")
    #expect(text.hasPrefix("sales "), "the sentence must name the table it is about: \(text)")
    #expect(text.contains("never saved the signature"), "\(text)")
    #expect(text.contains("paste the whole URL"), "a cause with no fix is a shrug: \(text)")
}

/// 🔴 `Image(systemName:)` handed a name macOS does not know draws **nothing** and reports nothing —
/// a hover button that is present, enabled, hit-testable and invisible. The same failure
/// `theToolbarsSymbolsAllResolve` exists for, one view over: this Mac carries a newer SDK than the
/// macos-15 runner, and the macOS 14 deployment floor is lower than both.
@MainActor
@Test func theSidebarsSymbolsAllResolve() {
    for name in SidebarSymbol.all {
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "the sidebar draws \(name), which this system does not have")
    }
    #expect(SidebarSymbol.all.count == 4, "a glyph was added or removed without its name")
    // …and the check is not vacuous.
    #expect(NSImage(systemSymbolName: "sift.not.a.symbol", accessibilityDescription: nil) == nil)
}

/// Which rows offer the other sheets of their workbook, and — the part that matters — what decides
/// it. `spec.sheets` was read off the real OOXML by the engine; `NSString.pathExtension` was not.
@Test func onlyAMultiSheetWorkbookOffersItsOtherSheets() {
    let two = [SheetInfo(name: "Q1", rows: 40, cols: 3), SheetInfo(name: "Q2", rows: 9, cols: 3)]
    #expect(offersSheetChoice(fixture(fmt: .xlsx, path: "/data/book.xlsx", sheets: two)))
    #expect(!offersSheetChoice(fixture(fmt: .xlsx, path: "/data/book.xlsx", sheets: [two[0]])),
            "a one-sheet workbook has no choice to offer")
    #expect(!offersSheetChoice(fixture(fmt: .csv, sheets: two)), "a CSV has no sheets")
    // A remote workbook is the case with no other route at all — the pre-open picker shells
    // `/usr/bin/unzip` at a path, and a URL is not one.
    let url = "https://h/c/book.xlsx"
    #expect(offersSheetChoice(
        fixture(fmt: .xlsx, path: url, sheets: two, remote: remoteRef(url))))
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

/// 🔴 **The gesture this whole phase was designed around: copy a blob URL, paste it into Sift.**
/// Before this the box typed the URL into a field and did nothing at all.
///
/// The authority is `SiftCore.classifyRemote`, and the two assertions that say so are the ones a
/// hand-rolled string test would fail: `gs://` and `ftp://` **contain `://`** and are not schemes
/// Sift can reach, while `azure://` and `abfs://` do not appear in any obvious prefix list and are
/// two of the four spellings DuckDB's own azure secret scopes to. `classifyRemote`'s `nil` means
/// *local path* — so a scheme decided wrong here is not "unsupported", it is a URL handed silently
/// to the local-file flow to come back as a missing file.
@Test func aPastedURLOpensAndClassifyRemoteIsWhatDecidesWhichOnesDo() {
    // Every spelling that reaches DuckDB, pasted whole.
    for url in [
        "https://acct.blob.core.windows.net/c/sales.csv",
        "http://h/sales.csv",
        "s3://bucket/key/sales.parquet",
        "az://container/sales.csv",
        "azure://container/sales.csv",
        "abfss://fs@acct.dfs.core.windows.net/sales.csv",
        "abfs://fs@acct.dfs.core.windows.net/sales.csv",
    ] {
        #expect(autoOpenPath(from: "", to: url) == url, "\(url) did not open")
        #expect(classifyRemote(url) != nil, "\(url) is not remote to the engine either")
    }

    // 🔴 Not remote to `classifyRemote`, so not remote here. A `contains("://")` test opens both.
    #expect(autoOpenPath(from: "", to: "gs://bucket/sales.csv") == nil)
    #expect(autoOpenPath(from: "", to: "ftp://h/sales.csv") == nil)
    #expect(autoOpenPath(from: "", to: "https://") == nil, "a scheme with no authority is not a URL")

    // The growth rule is unchanged by any of it: `https://h/f.csv` is fifteen keystrokes and none
    // of them may open anything.
    var typed = ""
    for character in "https://h/f.csv" {
        let next = typed + String(character)
        #expect(autoOpenPath(from: typed, to: next) == nil, "typing fired the paste handler at \(next)")
        typed = next
    }

    // Finder's trailing newline is trimmed here too; two URLs in one paste is still not one URL.
    #expect(autoOpenPath(from: "", to: "  https://h/f.csv \n") == "https://h/f.csv")
    #expect(autoOpenPath(from: "", to: "https://h/a.csv\nhttps://h/b.csv") == nil)
}

/// 🔴 **The display half of T8's grep rule.** T8 pins the persisted and snippet surfaces from
/// inside the engine (`RemoteOpenTests.remoteFactOpen_aSasSignedParquetIsDownloadedAndTheSignature\
/// ReachesNothingPersisted`, which greps `spec.target`, `key.path`, `duckdb_views()`,
/// `_sift_sources` and all four snippet dialects). It cannot reach these functions — `SiftEngineTests`
/// does not depend on `SiftUI`, and pointing an engine test target at the view layer would invert
/// the module graph — so this is the same grep over the strings the window draws, and the two are
/// cross-referenced rather than merged.
///
/// The teeth are the last pair: `lastPathComponent` of a signed URL **is** the signature, and the
/// pre-open picker titles itself with exactly that. Delete `needsSheetPicker`'s `classifyRemote`
/// guard and a SAS token is drawn 15 pt tall at the top of a modal sheet.
@Test func nothingTheSidebarDrawsCanCarryASASSignature() throws {
    let sig = "SUPERSECRETSIGNATURE"
    let signed = "https://acct.blob.core.windows.net/c/sales.xlsx?sv=2024-11-04&sig=\(sig)"
    let u = try #require(classifyRemote(signed))

    // The box hands the WHOLE string on — DuckDB needs the token, and `wireURL` is the one place it
    // is re-attached. An `autoOpenPath` that sanitized here would 403 every signed blob in the
    // product.
    #expect(autoOpenPath(from: "", to: signed) == signed)
    #expect(u.query == "sv=2024-11-04&sig=\(sig)", "the token has to survive as far as the engine")

    // …and everything the window draws afterwards is built from the sanitized form, which is what
    // `RemoteRef.url` holds by contract.
    let sheets = [SheetInfo(name: "Q1", rows: 40, cols: 3), SheetInfo(name: "Q2", rows: 9, cols: 3)]
    // 🔴 `signed: true` — the marker is on for this whole sweep, so every string below is drawn for
    // a source that really did arrive with a signature. A marker that leaked would leak here.
    let t = fixture(
        name: "sales", fmt: .xlsx, path: u.sanitized, size: 4096, rowCount: 40, sheet: "Q1",
        sheets: sheets, remote: remoteRef(u.sanitized, signed: true))

    var shown = [
        t.name, t.spec.key.path, t.spec.target, sourceSubtitle(t), sourceTooltip(t),
        try #require(remoteFetchedAt(t)),
        refreshOutcomeText(table: t.name, .refetched),
        refreshOutcomeText(table: t.name, .unchanged(since: "14:32")),
        // The refusal the marker now produces. It joins the sweep rather than needing the exemption
        // `refreshSignedURLNote` used to need: that note SPELLED `?sv=…&sig=…` to help the user
        // recognise their URL and had to be checked separately, and every separately-checked string
        // is one the next person can forget. This one names the shape without quoting it.
        try #require(signedReopenRefusal(t)),
    ]
    shown += t.spec.sheets.map(\.name)
    shown += t.spec.sheets.map(sheetRowLabel)

    for text in shown {
        #expect(!text.contains(sig), "the SAS signature reached a display surface: \(text)")
        #expect(!text.contains("sig="), "a query string reached a display surface: \(text)")
        #expect(!text.contains("?"), "the query delimiter survived into: \(text)")
    }
    // …and the refusal names the TABLE, never the URL — the tooltip is where a path belongs, and a
    // banner that quotes a URL is one keystroke of a future edit away from quoting the wire form.
    let refusal = try #require(signedReopenRefusal(t))
    #expect(!refusal.contains(u.sanitized), "\(refusal)")
    #expect(refusal.contains(t.name))

    // 🔴 **The route that would have drawn a query string 15 pt tall at the top of a modal sheet.**
    // The pre-open picker titles itself `(path as NSString).lastPathComponent`, and `needsSheetPicker`
    // is what sends a path to it. On an endpoint shape — the same one
    // `SiftCoreTests.aQueryStringNeverBecomesAnExtension` pins — `pathExtension` answers `xlsx` for
    // a thing that is not a workbook, and the component it would then draw is the whole signed
    // query. Delete `needsSheetPicker`'s `classifyRemote` guard and the last line goes red.
    let endpoint = "https://acct.blob.core.windows.net/c/get?sv=2024-11-04&sig=\(sig)&as=report.xlsx"
    #expect((endpoint as NSString).pathExtension == "xlsx", "the defect")
    #expect((endpoint as NSString).lastPathComponent.contains(sig), "the defect")
    #expect(!needsSheetPicker(endpoint),
            "a signed URL routed into the picker, whose title is its own path component")
    #expect(!needsSheetPicker(signed), "and neither does the ordinary signed-workbook shape")
    // The sheets ARE still choosable — through the route that reads them off the open table.
    #expect(offersSheetChoice(t))
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

/// 🔴 The glyph has to reach the PIXELS, not merely the code path. `SourceRow`'s
/// `if offersRefresh(table)` lives in a `body`, which no test can call — the failure this catches is
/// a row that carries the right flag and draws the same thing either way, which is exactly what
/// `theOffendingCellIsPaintedRedAndItsNeighbourIsNot` exists for one sheet over.
///
/// The two rows are identical in every string: same name, same size, same count, and
/// `aRemoteRowSaysItCameOverTheNetworkAndWhenTheBytesArrived` pins that their subtitles are equal.
/// So the difference in the bitmap can only be the network glyph.
@MainActor
@Test func aRemoteRowDrawsSomethingALocalRowDoesNot() async throws {
    let state = AppState(session: try Session(home: tempHome()))
    let url = "https://acct.blob.core.windows.net/c/sales.csv"
    let local = fixture(
        name: "sales", path: "/data/sales.csv", size: fortyOnePointTwoMB, rowCount: 900)
    let remote = fixture(
        name: "sales", path: url, size: fortyOnePointTwoMB, rowCount: 900, remote: remoteRef(url))
    #expect(sourceSubtitle(local) == sourceSubtitle(remote), "the rows must differ only in the glyph")

    let localImage = try render(SourceRow(table: local, state: state), 360, 44)
    let remoteImage = try render(SourceRow(table: remote, state: state), 360, 44)
    let path = try writePNG(remoteImage, "row-remote")

    #expect(try pixelDigest(localImage) != pixelDigest(remoteImage),
        "a table opened from a URL draws exactly like one opened from disk — see \(path)")

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
