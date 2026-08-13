import Testing
import Foundation
import TestSupport
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Tests for the `sift` verifier itself — the thing `swift run sift --verify` and `sift <path>`
// are thin wrappers over. Three groups, and the split is the point:
//
//  1. **The runner** (`runChecks`): that a skip is not a failure, that an unexpected error IS a
//     failure, that it never stops at the first failure, and that every check's workspace is
//     private and really is deleted. Driven with injected checks, so none of it depends on the
//     engine being correct.
//  2. **The pure surface**: argument parsing, and the rendering `sift <path>` produces —
//     including `DECIMAL(10,2)` keeping its trailing zero, which is the one display contract the
//     spec calls out by name.
//  3. **The checks themselves**, each invoked DIRECTLY rather than through `runVerification`.
//     Asserting "the verifier reported success" would be a test of the reporting; running the
//     check is a test of the engine, which is what these are for. The fixture builders are
//     covered separately below — a fixture that stops carrying the property it was built for
//     (the Delta table with no tombstone, the parquet with no DECIMAL) silently turns its check
//     into a no-op, and nothing else would notice.

// MARK: - helpers

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CheckResult] = []
    func add(_ result: CheckResult) { lock.withLock { items.append(result) } }
    var all: [CheckResult] { lock.withLock { items } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ value: T) { lock.withLock { storage.append(value) } }
    var all: [T] { lock.withLock { storage } }
}

private func passing(_ name: String) -> VerificationCheck {
    VerificationCheck(name: name, run: { _ in })
}

private func failing(_ name: String, _ message: String) -> VerificationCheck {
    VerificationCheck(name: name, run: { _ in throw VerifyFailure(message: message) })
}

private func skipping(_ name: String, _ message: String) -> VerificationCheck {
    VerificationCheck(name: name, run: { _ in throw VerifySkipped(message: message) })
}

private func column(_ name: String, _ type: String) -> TablePage.ColumnInfo {
    TablePage.ColumnInfo(name: name, type: type, kind: kind(of: type))
}

private func newHome() -> String { TestTemp.path("verification-tests") }

// MARK: - 1. the runner

@Test func runChecksReportsEveryFailureNotJustTheFirst() async throws {
    let report = await runChecks([
        failing("first", "one broke"),
        passing("middle"),
        failing("last", "two broke"),
    ])

    #expect(report.results.map(\.name) == ["first", "middle", "last"])
    #expect(report.failures.map(\.name) == ["first", "last"])
    #expect(report.failures.map(\.detail) == ["one broke", "two broke"])
    #expect(report.passes.map(\.name) == ["middle"])
    #expect(!report.ok)
    #expect(report.exitCode == 1)
}

@Test func aSkippedCheckIsNeitherAPassNorAFailureAndLeavesTheRunGreen() async throws {
    let report = await runChecks([
        passing("ran"),
        skipping("needs delta", "the DuckDB delta extension is not installed"),
    ])

    #expect(report.skips.map(\.name) == ["needs delta"])
    #expect(report.skips.first?.detail == "the DuckDB delta extension is not installed")
    #expect(report.passes.map(\.name) == ["ran"])
    #expect(report.failures.isEmpty)
    #expect(report.ok)
    #expect(report.exitCode == 0)
}

@Test func anErrorTheCheckDidNotExpectIsAFailureNotASkip() async throws {
    let report = await runChecks([
        VerificationCheck(name: "engine threw", run: { _ in throw SessionError("no such table 'x'") })
    ])

    #expect(report.failures.map(\.name) == ["engine threw"])
    #expect(report.failures.first?.detail?.contains("no such table 'x'") == true)
    #expect(report.skips.isEmpty)
    #expect(report.exitCode == 1)
}

@Test func onResultFiresOncePerCheckInOrder() async throws {
    let collector = Collector()
    let report = await runChecks(
        [passing("a"), failing("b", "nope"), skipping("c", "not here")],
        onResult: { collector.add($0) }
    )

    #expect(collector.all.map(\.name) == ["a", "b", "c"])
    #expect(collector.all.map(\.outcome) == report.results.map(\.outcome))
}

@Test func everyCheckGetsItsOwnWorkspaceAndItIsDeletedAfterwards() async throws {
    let seen = Box<Workspace>()
    func recording(_ name: String) -> VerificationCheck {
        VerificationCheck(name: name, run: { ws in
            seen.add(ws)
            // Both directories must be usable while the check runs...
            #expect(FileManager.default.fileExists(atPath: ws.scratch))
            try "x".write(toFile: ws.path("marker"), atomically: true, encoding: .utf8)
            _ = try ws.session()
            #expect(FileManager.default.fileExists(atPath: ws.home))
        })
    }

    let report = await runChecks([recording("one"), recording("two")])
    #expect(report.ok, "the recording checks themselves failed: \(report.failures)")

    let workspaces = seen.all
    #expect(workspaces.count == 2)
    #expect(workspaces[0].home != workspaces[1].home)
    #expect(workspaces[0].scratch != workspaces[1].scratch)
    // ...and gone afterwards, fixtures, staged store and all.
    for ws in workspaces {
        #expect(!FileManager.default.fileExists(atPath: ws.home))
        #expect(!FileManager.default.fileExists(atPath: ws.scratch))
        #expect(!FileManager.default.fileExists(atPath: ws.path("marker")))
    }
}

@Test func theWorkspaceIsRemovedEvenWhenTheCheckThrows() async throws {
    let seen = Box<Workspace>()
    let report = await runChecks([
        VerificationCheck(name: "throws", run: { ws in
            seen.add(ws)
            try "x".write(toFile: ws.path("marker"), atomically: true, encoding: .utf8)
            throw VerifyFailure(message: "deliberate")
        })
    ])

    #expect(report.failures.count == 1)
    let ws = try #require(seen.all.first)
    #expect(!FileManager.default.fileExists(atPath: ws.scratch))
    #expect(!FileManager.default.fileExists(atPath: ws.home))
}

@Test func theCheckListStillCoversEverySurfaceTheBriefNames() {
    let names = Set(verificationChecks.map(\.name))
    for required in [
        "open csv", "open parquet", "open json", "open ndjson", "open xlsx", "open delta",
        "open folder", "malformed file", "profile", "distinct panel", "histogram panel",
        "sample and length panels", "dropped rows", "ragged csv", "skipped preamble",
        "snippet and rendered SQL",
        "SELECT-only gate", "staging and unstaging", "merge", "export",
    ] {
        #expect(names.contains(required), "the \u{201C}\(required)\u{201D} check has gone missing")
    }
    #expect(verificationChecks.count == names.count, "two checks share a name")
}

// MARK: - 2a. rendering a run

@Test func renderCheckResultLabelsEachOutcomeAndIndentsItsSentence() {
    let ok = renderCheckResult(CheckResult(name: "merge", outcome: .passed, milliseconds: 12.34))
    #expect(ok.hasPrefix("ok    merge"))
    #expect(ok.contains("12.3 ms"))
    #expect(!ok.contains("\n"), "a passing check needs no second line")

    let bad = renderCheckResult(
        CheckResult(name: "merge", outcome: .failed("rows: expected 50, got 0"), milliseconds: 1.0)
    )
    #expect(bad.hasPrefix("FAIL  merge"))
    #expect(bad.contains("\n        rows: expected 50, got 0"))

    let skipped = renderCheckResult(
        CheckResult(name: "open delta", outcome: .skipped("no delta extension"), milliseconds: 1.0)
    )
    #expect(skipped.hasPrefix("skip  open delta"))
    #expect(skipped.contains("\n        no delta extension"))
}

@Test func renderSummaryCountsEachOutcomeAndRestatesEveryFailure() {
    let summary = renderSummary(VerificationReport(results: [
        CheckResult(name: "a", outcome: .passed, milliseconds: 1),
        CheckResult(name: "b", outcome: .failed("b broke"), milliseconds: 1),
        CheckResult(name: "c", outcome: .failed("c broke"), milliseconds: 1),
        CheckResult(name: "d", outcome: .skipped("no extension"), milliseconds: 1),
    ]))

    #expect(summary.contains("4 checks: 1 passed, 2 failed, 1 skipped"))
    #expect(summary.contains("FAILED  b: b broke"))
    #expect(summary.contains("FAILED  c: c broke"))
    #expect(summary.contains("skipped d: no extension"))
}

// MARK: - 2b. rendering a file

@Test func renderGridKeepsADecimalsDeclaredScaleAndRightAlignsNumbers() {
    let lines = renderGrid(
        columns: [column("amount", "DECIMAL(10,2)"), column("region", "VARCHAR")],
        rows: [
            [.decimal(Decimal(string: "10.5")!, scale: 2), .text("West")],
            [.decimal(Decimal(string: "3")!, scale: 2), .text("South")],
        ],
        width: 100
    )

    // `Decimal` canonicalizes the trailing zero away the moment anything asks it for its own
    // description; the scale riding alongside is what puts it back. 10.50, never 10.5.
    #expect(lines[1].contains("10.50"))
    #expect(lines[2].contains("3.00"))
    // Right-aligned, so the decimal points line up: "amount" is 6 wide, "10.50" is 5.
    #expect(lines[1].hasPrefix("   10.50"))
    #expect(lines[2].hasPrefix("    3.00"))
    // Text is left-aligned.
    #expect(lines[1].hasSuffix("West"))
}

@Test func renderGridKeepsNullAndTheEmptyStringApartTheWayTheWebGridDoes() {
    let lines = renderGrid(
        columns: [column("id", "BIGINT"), column("note", "VARCHAR")],
        rows: [[.int(1), .null], [.int(2), .text("")]],
        width: 100
    )
    // `Cell.display` renders both as "" — which is why this renderer goes through
    // `glyph(for:kind:)` instead. ("  " margin, then the id right-aligned under the
    // two-character header "id".)
    #expect(lines[1] == "   1  null")
    #expect(lines[2] == "   2  ''")
}

@Test func renderGridClipsLongCellsAndDropsColumnsThatDoNotFitTheWidth() {
    let long = String(repeating: "x", count: 80)
    let columns = (0..<4).map { column("c\($0)", "VARCHAR") }
    let lines = renderGrid(columns: columns, rows: [[.text(long), .text(long), .text(long), .text(long)]], width: 60)

    // Each cell is capped at 24 characters, the last of which becomes an ellipsis.
    #expect(lines[1].contains(String(repeating: "x", count: 23) + "\u{2026}"))
    #expect(!lines[1].contains(String(repeating: "x", count: 25)))
    // 2 margin + 24 + 2 + 24 = 52 fits in 60; a third column would take it to 78.
    #expect(lines[1].count <= 60)
    #expect(lines.last == "  \u{2026} and 2 more column(s)")
}

@Test func renderGridKeepsAtLeastOneColumnHoweverNarrowTheTerminal() {
    let lines = renderGrid(
        columns: [column("a_rather_long_column_name", "VARCHAR"), column("b", "VARCHAR")],
        rows: [[.text("value"), .text("other")]],
        width: 20
    )
    #expect(lines[0].contains("a_rather_long_column"))
    #expect(lines.last == "  \u{2026} and 1 more column(s)")
}

@Test func renderGridFlattensAQuotedNewlineSoItCannotTearTheGridApart() {
    let lines = renderGrid(
        columns: [column("id", "BIGINT"), column("note", "VARCHAR")],
        rows: [[.int(1), .text("line one\nline two")], [.int(2), .text("after")]],
        width: 100
    )
    #expect(lines.count == 3, "an embedded newline added a row: \(lines)")
    #expect(lines[1].contains("line one line two"))
}

@Test func renderOverviewMarksAnEstimateAsApproximateAndSaysWhy() {
    let columns = [column("id", "BIGINT")]
    let exact = renderOverview(FileOverview(
        path: "/tmp/a.csv", table: "a", format: "csv", rows: 1200, rowsExact: true,
        rowsBasis: nil, droppedRows: 0, droppedCells: 0, notes: [], columns: columns,
        preview: [[.int(1)]], milliseconds: 1
    ))
    // Thousands-grouped through the same public rule the cells go through — the third consumer
    // of a rule that used to exist privately twice.
    #expect(exact.contains("a \u{2014} csv \u{2014} 1,200 rows"))
    #expect(!exact.contains("estimate:"))
    #expect(exact.contains("showing 1 of 1,200 rows"))

    let estimated = renderOverview(FileOverview(
        path: "/tmp/a.csv", table: "a", format: "csv", rows: 1200, rowsExact: false,
        rowsBasis: "3x256KiB sample, no quote characters seen", droppedRows: 0, droppedCells: 0,
        notes: ["a note"], columns: columns, preview: [[.int(1)]], milliseconds: 1
    ))
    #expect(estimated.contains("~1,200 rows"))
    #expect(estimated.contains("estimate: 3x256KiB sample, no quote characters seen"))
    #expect(estimated.contains("note: a note"))

    let counting = renderOverview(FileOverview(
        path: "/tmp/a.csv", table: "a", format: "csv", rows: nil, rowsExact: false,
        rowsBasis: nil, droppedRows: 0, droppedCells: 0, notes: [], columns: columns,
        preview: [], milliseconds: 1
    ))
    #expect(counting.contains("counting rows\u{2026}"))
    #expect(counting.contains("(no rows)"))
}

/// The dropped-row line is printed on EVERY open, including the clean case, and a scan that did
/// not finish must not be reported as a clean one. Before this, a file that lost 12 rows showed
/// the survivors and said nothing — the product's headline claim going silent.
@Test func everyOverviewSaysWhetherRowsWereDropped() {
    func overview(_ dropped: Int?, _ cells: Int) -> String {
        renderOverview(FileOverview(
            path: "/tmp/a.csv", table: "a", format: "csv", rows: 1200, rowsExact: true,
            rowsBasis: nil, droppedRows: dropped, droppedCells: cells, notes: [],
            columns: [column("id", "BIGINT")], preview: [[.int(1)]], milliseconds: 1
        ))
    }
    #expect(overview(0, 0).contains("no rows dropped"))
    #expect(overview(1, 1).contains("1 row dropped \u{2014} 1 cell would not cast"))
    #expect(overview(12, 30).contains("12 rows dropped \u{2014} 30 cells would not cast"))
    // Thousands-grouped through the same rule as everything else, and never through a Double.
    #expect(overview(1_234_567, 2_000).contains("1,234,567 rows dropped \u{2014} 2,000 cells"))
    // The third state, and the one that must never be spelled as either of the other two.
    let unknown = overview(nil, 0)
    #expect(unknown.contains("dropped rows: not known"))
    #expect(!unknown.contains("no rows dropped"))
}

@Test func renderSchemaListsNameTypeAndKindPerColumn() {
    let lines = renderSchema([column("id", "BIGINT"), column("payload", "JSON")])
    #expect(lines == ["  id       BIGINT  number", "  payload  JSON    nested"])
}

// MARK: - 2c. argument parsing

@Test func parseArgumentsReadsAPathAndItsOptionsInBothSpellings() {
    #expect(parseArguments(["data.csv"]) == .open(path: "data.csv", sheet: nil, rows: 10, width: 100, nullPadding: false, skipPreamble: true))
    #expect(
        parseArguments(["--rows", "3", "data.csv", "--sheet", "Q1 2024", "--width", "60"])
            == .open(path: "data.csv", sheet: "Q1 2024", rows: 3, width: 60, nullPadding: false, skipPreamble: true)
    )
    #expect(
        parseArguments(["--rows=3", "--width=60", "--sheet=Q1", "data.csv"])
            == .open(path: "data.csv", sheet: "Q1", rows: 3, width: 60, nullPadding: false, skipPreamble: true)
    )
    // A path that starts with a dash is not a thing here, but one containing "=" is fine.
    #expect(
        parseArguments(["/tmp/a=b/data.csv"])
            == .open(path: "/tmp/a=b/data.csv", sheet: nil, rows: 10, width: 100, nullPadding: false, skipPreamble: true)
    )
}

/// The two escape hatches the sniffer notes tell the user to reach for. Each note names one, so
/// a flag that parsed and did nothing would be the same defect the note exists to report.
@Test func parseArgumentsCarriesTheTwoWaysBackFromABadSniff() {
    #expect(
        parseArguments(["ragged.csv", "--null-padding"])
            == .open(
                path: "ragged.csv", sheet: nil, rows: 10, width: 100,
                nullPadding: true, skipPreamble: true
            )
    )
    #expect(
        parseArguments(["prose.csv", "--no-skip-preamble"])
            == .open(
                path: "prose.csv", sheet: nil, rows: 10, width: 100,
                nullPadding: false, skipPreamble: false
            )
    )
    // Refused here rather than at the engine so the usage text comes with it — and refused at
    // all because pinning the skip is exactly what defeats null padding, so honouring both
    // would silently honour neither. Session.openPath throws on the same pair.
    if case .usageError(let message) = parseArguments(
        ["f.csv", "--null-padding", "--no-skip-preamble"]
    ) {
        #expect(message.contains("cannot be combined"))
    } else {
        Issue.record("the two escape hatches must not be combinable")
    }
}

@Test func parseArgumentsRecognisesHelpAndVerify() {
    #expect(parseArguments(["--help"]) == .help)
    #expect(parseArguments(["-h"]) == .help)
    #expect(parseArguments(["data.csv", "--help"]) == .help)
    #expect(parseArguments(["--verify"]) == .verify)
}

@Test func parseArgumentsRefusesWhatItCannotHonour() {
    func isUsageError(_ args: [String]) -> Bool {
        if case .usageError = parseArguments(args) { return true }
        return false
    }
    #expect(isUsageError([]))
    #expect(isUsageError(["--nope", "data.csv"]))
    #expect(isUsageError(["a.csv", "b.csv"]))
    // --verify runs against its own generated fixtures; combining it with a path is a
    // misunderstanding, not a request.
    #expect(isUsageError(["--verify", "data.csv"]))
    #expect(isUsageError(["--rows"]))
    #expect(isUsageError(["--rows", "many", "data.csv"]))
    #expect(isUsageError(["--rows", "-1", "data.csv"]))
    #expect(isUsageError(["--width", "4", "data.csv"]))
    #expect(isUsageError(["--sheet"]))
    #expect(isUsageError(["--rows", "5"]))   // options but no file
}

// MARK: - 2d. the fixtures the checks lean on
//
// A fixture that quietly stops carrying the property it was built for turns its check into a
// no-op that still reports `ok`. These are the guards against that.

@Test func writeSalesCSVWritesTheHeaderAndExactlyTheRowsAsked() throws {
    let home = newHome()
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let path = (home as NSString).appendingPathComponent("sales.csv")

    try writeSalesCSV(path, rows: 7)
    let lines = try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.first == "order_id,region,amount,note")
    #expect(lines.count == 8)
    #expect(lines[1] == "0,West,0.50,note 0")
    // The distinct panel check counts on exactly four regions cycling.
    let regions = Set(lines.dropFirst().map { $0.split(separator: ",")[1] })
    #expect(regions == ["West", "Midwest", "South", "Northeast"])
}

@Test func theParquetFixtureReallyCarriesADecimalColumn() throws {
    let home = newHome()
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let path = (home as NSString).appendingPathComponent("t.parquet")

    try writeParquet(path, rows: 10)
    let con = try scratchDatabase().connect()
    let described = try con.query("DESCRIBE SELECT * FROM read_parquet(\(qlit(path)))").allRows()
    let types = Dictionary(uniqueKeysWithValues: described.map { ($0[0].display, $0[1].display) })
    // Without this the "open parquet" check's 10.50-vs-10.5 assertion proves nothing.
    #expect(types["amount"] == "DECIMAL(12,2)")
    #expect(types["order_id"] == "BIGINT")
}

@Test func theDeltaFixtureTombstonesAFileThatIsStillPhysicallyPresent() throws {
    let home = newHome()
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let root = (home as NSString).appendingPathComponent("dtable")

    try writeDeltaTable(root, kept: 10, tombstoned: 5)
    let removed = (root as NSString).appendingPathComponent("part-1.parquet")
    // The gap only exists if the tombstoned file is still on disk — otherwise a raw glob would
    // give the same answer as delta_scan and the check would pass for the wrong reason.
    #expect(FileManager.default.fileExists(atPath: removed))

    let logPath = (root as NSString)
        .appendingPathComponent("_delta_log/00000000000000000001.json")
    let log = try String(contentsOfFile: logPath, encoding: .utf8)
    let action = try #require(
        try JSONSerialization.jsonObject(with: Data(log.utf8)) as? [String: Any]
    )
    let remove = try #require(action["remove"] as? [String: Any])
    #expect(remove["path"] as? String == "part-1.parquet")

    // And the rows really do differ: 15 physically, 10 through the log.
    let con = try scratchDatabase().connect()
    let glob = try con.query(
        "SELECT count(*) FROM read_parquet(\(qlit(root + "/*.parquet")))"
    ).allRows()[0][0]
    #expect(glob.display == "15")
}

// MARK: - 2e. `sift <path>`

@Test func openAndDescribeReportsTheSchemaAndTheFirstRows() async throws {
    let home = newHome()
    let scratch = newHome()
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let path = try writeSalesCSV((scratch as NSString).appendingPathComponent("sales.csv"), rows: 40)

    let overview = try await openAndDescribe(path: path, rows: 4, home: home)
    #expect(overview.table == "sales")
    #expect(overview.format == "csv")
    #expect(overview.rows == 40)
    #expect(overview.rowsExact)
    #expect(overview.rowsBasis == nil)
    #expect(overview.columns.map(\.name) == ["order_id", "region", "amount", "note"])
    #expect(overview.preview.count == 4)
    #expect(overview.preview.map { $0[0].display } == ["0", "1", "2", "3"])

    // The dropped-row accounting is waited for, not skipped: 0 here, and printed as a sentence
    // rather than left as silence a reader cannot distinguish from "never checked".
    #expect(overview.droppedRows == 0)
    #expect(overview.droppedCells == 0)

    let rendered = renderOverview(overview)
    #expect(rendered.contains("sales \u{2014} csv \u{2014} 40 rows"))
    #expect(rendered.contains("no rows dropped"))
    #expect(rendered.contains("showing 4 of 40 rows"))
}

/// 🔴 THE REGRESSION TEST FOR THE DEFECT THIS WHOLE FEATURE EXISTS FOR. Inherited from the Python
/// original, found by running the shipped CLI over a real file: a CSV whose rows do not all carry
/// the same number of fields printed one column literally named `order_id,region,amount`, an
/// honest-looking `no rows dropped`, and nothing else. Every row was intact; the entire column
/// structure was gone, and the one line on screen that talks about loss said there wasn't any.
///
/// Written to FAIL before the fix and kept as the end-to-end guard afterwards: it goes through
/// `openAndDescribe` and `renderOverview`, i.e. the exact bytes `sift <path>` puts on a terminal.
/// 🔴 THE REGRESSION TEST FOR THE SECOND INSTANCE OF THE SAME CLASS, found by hand-checking one of
/// the ragged fix's own false-positive controls. A three-line file of prose printed `0 rows`, two
/// columns the user never wrote (`another line`, `semicolon too`), `no rows dropped`, and `(no
/// rows)`. The sniffer picked `;` off line 3, threw the first two lines away as a preamble, and
/// used what was left as the header — two thirds of the file discarded in silence.
///
/// Written to FAIL before the fix. Goes through `openAndDescribe` and `renderOverview`, i.e. the
/// exact bytes `sift <path>` puts on a terminal.
@Test func aFileWhosePreambleAteItSaysSo() async throws {
    let home = newHome()
    let scratch = newHome()
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let path = try writeProseCSV((scratch as NSString).appendingPathComponent("prose.csv"))

    let overview = try await openAndDescribe(path: path, rows: 10, home: home)
    // Unchanged on purpose: Sift does not quietly re-read the file with different options. What it
    // must not do is show an empty grid and say nothing about why.
    #expect(overview.rows == 0)
    #expect(overview.columns.count == 2)

    let rendered = renderOverview(overview)
    #expect(
        rendered.contains("skipped as a preamble"),
        "`sift <path>` threw two thirds of the file away and said nothing:\n\(rendered)"
    )
    #expect(rendered.contains("The first 2 lines were"), "the note does not say how much was lost")
    #expect(rendered.contains("(no rows)"))
}

@Test func aRaggedFileSaysOutLoudThatItCollapsedIntoOneColumn() async throws {
    let home = newHome()
    let scratch = newHome()
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let path = try writeRaggedCSV((scratch as NSString).appendingPathComponent("ragged.csv"))

    let overview = try await openAndDescribe(path: path, rows: 10, home: home)
    // Unchanged on purpose: Sift does not quietly re-read the file with different options and
    // show different columns. That would trade one silent behaviour for another.
    #expect(overview.columns.count == 1)
    #expect(overview.droppedRows == 0)

    let rendered = renderOverview(overview)
    #expect(
        rendered.contains("read as one column"),
        "`sift <path>` lost the file's column structure and said nothing:\n\(rendered)"
    )
    #expect(rendered.contains("to see all 5"), "the note does not say how many columns are there")
    // The dropped-rows line is still printed and still true — the point is that it is no longer
    // the ONLY thing said about a file that lost its shape.
    #expect(rendered.contains("no rows dropped"))
}

@Test func openAndDescribeCountsAShortFileExactlyEvenBeforeTheBackgroundScanLands() async throws {
    let home = newHome()
    let scratch = newHome()
    let folder = (scratch as NSString).appendingPathComponent("daily")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try writeSmallCSV((folder as NSString).appendingPathComponent("a.csv"), rows: 6, from: 0)
    try writeSmallCSV((folder as NSString).appendingPathComponent("b.csv"), rows: 4, from: 6)

    // A folder source has NO row count when `openPath` returns — `buildSource` has nothing free to
    // read (unlike a parquet footer) and the exact count runs in the detached background pipeline.
    // Since Task 9 `openAndDescribe` WAITS for that pipeline (it has to, to report dropped rows),
    // so the count normally arrives from it. The short-page fallback this test is named for is now
    // the backstop for the two cases where it does not: the scan times out, or `exactCount` itself
    // throws and `applyCount` lands a `nil`. Either way a page that came back short of the 50 rows
    // asked for IS the whole file, and printing "counting rows…" over a preview that already shows
    // every row reads as broken. Both paths produce the same answer here, which is the point.
    let overview = try await openAndDescribe(path: folder, rows: 50, home: home)
    #expect(overview.format == "glob_csv")
    #expect(overview.preview.count == 10)
    // The page came back short of the 50 asked for, so the file ended — 10 rows, exactly, and
    // not "counting rows…" printed over a preview that already shows all of them.
    #expect(overview.rows == 10)
    #expect(overview.rowsExact)
    #expect(renderOverview(overview).contains("\u{2014} 10 rows"))
}

// MARK: - 2f. waiting

@Test func waitForStagingGivesUpRatherThanHangingOnAJobThatNeverEnds() async throws {
    let home = newHome()
    let scratch = newHome()
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let path = try writeSalesCSV((scratch as NSString).appendingPathComponent("sales.csv"), rows: 5)

    let session = try Session(home: home)
    let t = try await session.openPath(path)
    // A job that will never clear itself — the shape a wedged CTAS would leave behind. Without the
    // deadline this call is an infinite loop, which in CI is a 20-minute timeout with no message.
    await session.setStagingForTest(
        t.name, StagingProgress(jobID: "stuck", state: "running", estSeconds: 0)
    )

    await #expect(throws: VerifyFailure.self) {
        _ = try await waitForStaging(session, t.name, timeout: 0.3)
    }
}

// MARK: - 3. the checks, run directly
//
// Not through `runVerification`: a green report proves the reporting works, and these have to
// prove the ENGINE works. `withWorkspace` gives each one the same private home and scratch
// directory the CLI would.

@Test func csvOpensAndPagesContiguously() async throws { try await withWorkspace(checkOpenCSV) }
@Test func parquetOpensWithItsFooterCountAndDecimalScale() async throws {
    try await withWorkspace(checkOpenParquet)
}
@Test func jsonOpens() async throws { try await withWorkspace(checkOpenJSON) }
@Test func ndjsonOpensAndClassifiesNestedColumns() async throws {
    try await withWorkspace(checkOpenNDJSON)
}
@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func xlsxOpensThroughTheSheetPicker() async throws { try await withWorkspace(checkOpenXLSX) }
@Test(.enabled(if: extensionIsAvailable("delta"), "duckdb delta extension not installed"))
func deltaOpensAndHonoursTombstones() async throws { try await withWorkspace(checkOpenDelta) }
@Test func aFolderOpensAsOneTableWithFilenameProvenance() async throws {
    try await withWorkspace(checkOpenFolder)
}
@Test func aFileThatIsNotWhatItsNameSaysGetsASentence() async throws {
    try await withWorkspace(checkMalformedFile)
}
@Test func profilingProducesOneProfilePerColumnInFileOrder() async throws {
    try await withWorkspace(checkProfile)
}
@Test func theDistinctPanelCountsAndFacets() async throws {
    try await withWorkspace(checkDistinctPanel)
}
@Test func theHistogramPanelCoversEveryRowAndNamesTheDegenerateCase() async throws {
    try await withWorkspace(checkHistogramPanel)
}
@Test func theSampleAndLengthPanelsReportRealValues() async throws {
    try await withWorkspace(checkSmallPanels)
}
@Test func droppedRowsAreCountedAndSaidOutLoud() async throws {
    try await withWorkspace(checkDroppedRows)
}
@Test func aCollapsedRaggedFileSaysSoAndNullPaddingGetsTheColumnsBack() async throws {
    try await withWorkspace(checkRaggedCollapse)
}
@Test func aFileEatenByItsPreambleSaysSoAndKeepingItGetsTheRowsBack() async throws {
    try await withWorkspace(checkPreambleAteTheFile)
}
@Test func theRenderedSQLAndEverySnippetDialectAreProduced() async throws {
    try await withWorkspace(checkSnippetAndRenderedSQL)
}
@Test func theSelectOnlyGateRefusesEverythingItShould() async throws {
    try await withWorkspace(checkSelectOnlyGate)
}
@Test func stagingAndUnstagingRoundTripsWithoutChangingTheRows() async throws {
    try await withWorkspace(checkStagingRoundTrip)
}
@Test func joinProbeAndMergeAgreeOnTheOverlap() async throws { try await withWorkspace(checkMerge) }
@Test func everyExportFormatWritesAFileThatReadsBack() async throws {
    try await withWorkspace(checkExport)
}
