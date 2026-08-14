import DuckDBKit
import Foundation
import SiftCore

// The headless verification surface — everything `sift --verify` and `sift <path>` do, minus the
// printing. This is the role `pv-pipeline` plays in latent, and it is the reason killing browser
// mode was safe: without a window, this is the only thing that drives `Session` end to end over
// real files on disk.
//
// 🔴 IT ALL LIVES HERE, NOT IN THE EXECUTABLE, and that is structural rather than stylistic: a
// SwiftPM test target cannot import an `executableTarget`, so anything written in
// `Sources/sift/main.swift` is untestable forever. `main.swift` therefore parses nothing itself
// (`parseArguments` below), formats nothing itself (`renderCheckResult`/`renderSummary`/
// `renderOverview` below), and decides nothing itself (`VerificationReport.exitCode`). It calls
// four functions and prints their strings. If a change wants to add logic there, it belongs here.
//
// THREE RULES THE CHECKS BELOW HOLD:
//
//  1. **Each check gets its own `~/.sift` and its own scratch directory, and both are deleted
//     afterwards** (`withWorkspace`). `--verify` is therefore idempotent, leaves nothing in the
//     user's real `~/.sift`, and never sees another check's staged copies.
//  2. **Exactly one `Session` per home, ever.** Design spec §13a, measured twice: two
//     `DuckDBKit.Database` handles on one file *in one process* are two independent DuckDB
//     instances that cannot see each other's catalog, and the second flush wins. The `sharedStore`
//     lock fallback does not fire in-process, so nothing warns you. Every check below constructs
//     one `Session` from `Workspace.session()` and reuses it.
//  3. **A check that cannot run is not a check that passed.** A missing `delta` or `excel`
//     extension throws `VerifySkipped`, which reports as `skip` and does not fail the run —
//     distinct from `VerifyFailure`, which does. Collapsing the two would turn "the binary can't
//     read Delta here" into either a false green or a false red.
//
// FIXTURES ARE GENERATED HERE, not read from a test bundle: this ships inside a binary that runs
// on a machine with no checkout. CSV/JSON/NDJSON are written as bytes by hand (the parser must be
// fed a file this process wrote, not one DuckDB round-tripped); parquet, xlsx and the Delta table's
// data files come from a throwaway in-memory `Database`, since there is no sane way to hand-write
// those.

// MARK: - what one check reports

/// The three outcomes, kept apart on purpose. See rule 3 in this file's header.
public enum CheckOutcome: Sendable, Equatable {
    case passed
    /// The check ran and the engine did the wrong thing. This is a bug.
    case failed(String)
    /// The check could not run at all — a missing DuckDB extension, say. Neither a pass nor a
    /// failure, and reporting it as either loses the one fact the reader needs.
    case skipped(String)
}

public struct CheckResult: Sendable, Equatable {
    public let name: String
    public let outcome: CheckOutcome
    public let milliseconds: Double

    public init(name: String, outcome: CheckOutcome, milliseconds: Double) {
        self.name = name
        self.outcome = outcome
        self.milliseconds = milliseconds
    }

    public var failed: Bool {
        if case .failed = outcome { return true }
        return false
    }

    public var wasSkipped: Bool {
        if case .skipped = outcome { return true }
        return false
    }

    /// The sentence explaining a failure or a skip; `nil` for a pass.
    public var detail: String? {
        switch outcome {
        case .passed: return nil
        case .failed(let message), .skipped(let message): return message
        }
    }
}

public struct VerificationReport: Sendable, Equatable {
    public let results: [CheckResult]

    public init(results: [CheckResult]) { self.results = results }

    public var failures: [CheckResult] { results.filter(\.failed) }
    public var skips: [CheckResult] { results.filter(\.wasSkipped) }
    public var passes: [CheckResult] { results.filter { $0.outcome == .passed } }
    public var ok: Bool { failures.isEmpty }

    /// The process exit status. Lives here rather than in `main.swift` so it is covered by a test:
    /// a skipped check must not fail the run, and a failed one must.
    public var exitCode: Int32 { ok ? 0 : 1 }
}

// MARK: - how a check says what went wrong

/// The engine did the wrong thing. Reports as `.failed`.
struct VerifyFailure: SiftError, Equatable {
    let message: String
    var description: String { message }
}

/// The check could not run here. Reports as `.skipped`.
struct VerifySkipped: SiftError, Equatable {
    let message: String
    var description: String { message }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw VerifyFailure(message: message()) }
}

func requireEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
    if actual != expected {
        throw VerifyFailure(message: "\(what): expected \(expected), got \(actual)")
    }
}

// MARK: - one check's workspace

/// A private `~/.sift` plus a scratch directory for this check's fixtures. Both are inside one
/// temp root that `withWorkspace` removes afterwards.
struct Workspace: Sendable {
    let home: String
    let scratch: String

    /// THE one `Session` for this home — see rule 2 in this file's header. Never call it twice.
    func session() throws -> Session { try Session(home: home) }

    func path(_ name: String) -> String { (scratch as NSString).appendingPathComponent(name) }
}

func withWorkspace(_ body: (Workspace) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sift-verify-\(UUID().uuidString)")
    let workspace = Workspace(
        home: root.appendingPathComponent("home").path,
        scratch: root.appendingPathComponent("data").path
    )
    try FileManager.default.createDirectory(
        atPath: workspace.scratch, withIntermediateDirectories: true
    )
    // Runs on the throwing path too, which is the whole point: a failed check must not leave a
    // staged copy behind for the next run to adopt. `Session.init` creates `home` itself.
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(workspace)
}

// MARK: - the runner

struct VerificationCheck: Sendable {
    let name: String
    let run: @Sendable (Workspace) async throws -> Void
}

/// Run every check, in order, each in a fresh workspace. **Never stops at the first failure** —
/// the whole point of a structured report is that one run tells you everything that is broken.
///
/// `onResult` fires as each check finishes so a CLI can stream progress rather than sitting mute.
public func runVerification(
    onResult: (@Sendable (CheckResult) -> Void)? = nil
) async -> VerificationReport {
    await runChecks(verificationChecks, onResult: onResult)
}

/// The runner proper, over an injectable check list — which is how the classification below (a
/// thrown `VerifySkipped` is a skip, anything else is a failure) and the never-stop-early rule are
/// covered by a test without needing a broken engine to point it at.
func runChecks(
    _ checks: [VerificationCheck], onResult: (@Sendable (CheckResult) -> Void)? = nil
) async -> VerificationReport {
    var results: [CheckResult] = []
    for check in checks {
        let started = DispatchTime.now()
        let outcome: CheckOutcome
        do {
            try await withWorkspace(check.run)
            outcome = .passed
        } catch let skipped as VerifySkipped {
            outcome = .skipped(skipped.message)
        } catch let failure as VerifyFailure {
            outcome = .failed(failure.message)
        } catch {
            // An error the check did not expect at all — a `SessionError`, a `DuckDBError`, an
            // unreadable fixture. That is a failure, never a skip: only a check that deliberately
            // stood down gets to be a skip.
            outcome = .failed("\(error)")
        }
        let result = CheckResult(
            name: check.name, outcome: outcome, milliseconds: millisecondsSince(started)
        )
        results.append(result)
        onResult?(result)
    }
    return VerificationReport(results: results)
}

// MARK: - rendering the run

/// One result as a line (plus an indented sentence when there is one to give).
public func renderCheckResult(_ result: CheckResult, nameWidth: Int = 26) -> String {
    let status: String
    switch result.outcome {
    case .passed: status = "ok  "
    case .failed: status = "FAIL"
    case .skipped: status = "skip"
    }
    var line = "\(status)  \(padRight(result.name, nameWidth))  "
        + "\(String(format: "%.1f", result.milliseconds)) ms"
    if let detail = result.detail {
        line += "\n        " + detail
    }
    return line
}

public func renderSummary(_ report: VerificationReport) -> String {
    var lines = [
        "\(report.results.count) checks: \(report.passes.count) passed, "
            + "\(report.failures.count) failed, \(report.skips.count) skipped"
    ]
    // Restated at the end on purpose: in a CI log the individual lines are thousands of rows up.
    for failure in report.failures {
        lines.append("  FAILED  \(failure.name): \(failure.detail ?? "")")
    }
    for skip in report.skips {
        lines.append("  skipped \(skip.name): \(skip.detail ?? "")")
    }
    return lines.joined(separator: "\n")
}

// MARK: - the checks

let verificationChecks: [VerificationCheck] = [
    VerificationCheck(name: "open csv", run: checkOpenCSV),
    VerificationCheck(name: "open parquet", run: checkOpenParquet),
    VerificationCheck(name: "open json", run: checkOpenJSON),
    VerificationCheck(name: "open ndjson", run: checkOpenNDJSON),
    VerificationCheck(name: "open xlsx", run: checkOpenXLSX),
    VerificationCheck(name: "open delta", run: checkOpenDelta),
    VerificationCheck(name: "open folder", run: checkOpenFolder),
    VerificationCheck(name: "malformed file", run: checkMalformedFile),
    VerificationCheck(name: "profile", run: checkProfile),
    VerificationCheck(name: "distinct panel", run: checkDistinctPanel),
    VerificationCheck(name: "histogram panel", run: checkHistogramPanel),
    VerificationCheck(name: "sample and length panels", run: checkSmallPanels),
    VerificationCheck(name: "dropped rows", run: checkDroppedRows),
    VerificationCheck(name: "ragged csv", run: checkRaggedCollapse),
    VerificationCheck(name: "skipped preamble", run: checkPreambleAteTheFile),
    VerificationCheck(name: "snippet and rendered SQL", run: checkSnippetAndRenderedSQL),
    VerificationCheck(name: "SELECT-only gate", run: checkSelectOnlyGate),
    VerificationCheck(name: "remote connection", run: checkRemoteConnection),
    VerificationCheck(name: "staging and unstaging", run: checkStagingRoundTrip),
    VerificationCheck(name: "merge", run: checkMerge),
    VerificationCheck(name: "export", run: checkExport),
]

// MARK: formats

@Sendable func checkOpenCSV(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    try requireEqual(t.name, "sales", "table name")
    try requireEqual(t.spec.fmt, Fmt.csv, "detected format")
    try requireEqual(
        t.spec.columns.map(\.name), ["order_id", "region", "amount", "note"], "sniffed columns"
    )
    try requireEqual(t.rowCount, 500, "exact row count at open")

    let page = try await session.page(t.name, offset: 0, limit: 10)
    try requireEqual(page.rows.count, 10, "rows on the first page")
    try requireEqual(page.columns.count, 4, "columns on the first page")
    try requireEqual(page.total.value, 500, "reported total")
    try require(page.total.exact, "the total should be exact for a 500-row CSV")
    // Contiguity, not just arity: the first page must be rows 0..9 in file order.
    try requireEqual(page.rows.map { $0[0].display }, (0..<10).map(String.init), "first page order_ids")

    let second = try await session.page(t.name, offset: 495, limit: 10)
    try requireEqual(second.rows.count, 5, "rows on the ragged final page")
}

@Sendable func checkOpenParquet(_ ws: Workspace) async throws {
    let path = try writeParquet(ws.path("t.parquet"), rows: 400)
    let session = try ws.session()
    let t = try await session.openPath(path)

    try requireEqual(t.spec.fmt, Fmt.parquet, "detected format")
    // The footer carries the count, so it is exact before any scan runs.
    try requireEqual(t.rowCount, 400, "row count from the parquet footer")

    let page = try await session.page(t.name, offset: 0, limit: 4)
    try requireEqual(page.columns.map(\.name), ["order_id", "region", "amount"], "columns")
    // DECIMAL(12,2) must keep its declared scale all the way to the glyph — `Decimal` drops the
    // trailing zero the instant anything asks it for its own description, which is why `Cell`
    // carries the scale alongside the value. 1 * 1.5 = 1.50, not 1.5.
    try requireEqual(page.rows[1][2].display, "1.50", "DECIMAL(12,2) display at row 1")
    try requireEqual(page.rows[0][2].display, "0.00", "DECIMAL(12,2) display at row 0")
}

@Sendable func checkOpenJSON(_ ws: Workspace) async throws {
    let path = try writeJSONArray(ws.path("events.json"), rows: 120)
    let session = try ws.session()
    let t = try await session.openPath(path)

    try requireEqual(t.spec.fmt, Fmt.json, "detected format")
    try requireEqual(t.spec.readFn, "read_json_auto", "read function")
    try requireEqual(t.rowCount, 120, "exact row count at open")

    let page = try await session.page(t.name, offset: 0, limit: 120)
    try requireEqual(page.rows.count, 120, "rows read back")
    try requireEqual(page.columns.map(\.name), ["id", "region"], "columns")
}

@Sendable func checkOpenNDJSON(_ ws: Workspace) async throws {
    let path = try writeNDJSON(ws.path("events.ndjson"), rows: 120)
    let session = try ws.session()
    let t = try await session.openPath(path)

    try requireEqual(t.spec.fmt, Fmt.ndjson, "detected format")
    try requireEqual(t.rowCount, 120, "exact row count at open")

    let page = try await session.page(t.name, offset: 0, limit: 120)
    try requireEqual(page.rows.count, 120, "rows read back")
    // A nested object must classify as `.nested`, not text — the grid and the panel picker both
    // branch on it.
    let nested = page.columns.first { $0.name == "nested" }
    try require(nested != nil, "the nested column is missing from the page")
    try requireEqual(nested?.kind, Kind.nested, "kind of the nested column")
}

@Sendable func checkOpenXLSX(_ ws: Workspace) async throws {
    let db = try scratchDatabase(loading: ["excel"])
    guard db.loadedExtensions["excel"] == .loaded else {
        throw VerifySkipped(
            message: "the DuckDB excel extension is not installed, so no .xlsx can be written or read"
        )
    }
    let path = try writeXLSX(db, ws.path("book.xlsx"), rows: 60)

    let session = try ws.session()
    let t = try await session.openPath(path)
    try requireEqual(t.spec.fmt, Fmt.xlsx, "detected format")
    try require(t.spec.sheet != nil, "no sheet was selected for the workbook")
    try require(!t.spec.sheets.isEmpty, "the sheet list is empty")
    try require(
        t.notes.contains { $0.hasPrefix("Sheet ") },
        "the open should note which sheet it picked; notes were \(t.notes)"
    )

    let page = try await session.page(t.name, offset: 0, limit: 100)
    try requireEqual(page.rows.count, 60, "rows read back from the sheet")
    try requireEqual(page.columns.map(\.name), ["id", "label"], "columns")
}

@Sendable func checkOpenDelta(_ ws: Workspace) async throws {
    let session = try ws.session()
    guard session.engineInfo().extensions["delta"] == .loaded else {
        throw VerifySkipped(
            message: "the DuckDB delta extension is not installed, so Delta tables cannot be read"
        )
    }
    let root = try writeDeltaTable(ws.path("dtable"), kept: 100, tombstoned: 50)

    let t = try await session.openPath(root)
    try requireEqual(t.spec.fmt, Fmt.delta, "detected format")
    try requireEqual(t.spec.readFn, "delta_scan", "read function")
    try require(
        t.notes.contains { $0.hasPrefix("Delta table at version") },
        "the open should note the Delta version; notes were \(t.notes)"
    )

    // THE contract: version 1 tombstones part-1, whose parquet file is still physically present.
    // A raw glob over the directory returns 150 rows and resurrects deleted data; `delta_scan`
    // returns 100. Measured on this exact fixture shape in Plan 2.
    let page = try await session.page(t.name, offset: 0, limit: 500)
    try requireEqual(page.rows.count, 100, "rows visible at the current Delta version")
    try require(
        !page.rows.contains { $0[1].display == "tombstoned" },
        "a tombstoned row came back — the parquet files were globbed instead of read through delta_scan"
    )
}

@Sendable func checkOpenFolder(_ ws: Workspace) async throws {
    let dir = ws.path("daily")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    _ = try writeSmallCSV((dir as NSString).appendingPathComponent("2026-08-01.csv"), rows: 15, from: 0)
    _ = try writeSmallCSV((dir as NSString).appendingPathComponent("2026-08-02.csv"), rows: 15, from: 15)

    let session = try ws.session()
    let t = try await session.openPath(dir)
    try requireEqual(t.spec.fmt, Fmt.globCsv, "detected format")
    try require(
        t.notes.contains { $0.hasPrefix("Folder read as one table") },
        "the open should note the folder union; notes were \(t.notes)"
    )

    let page = try await session.page(t.name, offset: 0, limit: 200)
    try requireEqual(page.rows.count, 30, "rows unioned across both files")
    // The provenance column is what makes a folder read auditable — which file did this row
    // come from — and it is appended last.
    try requireEqual(page.columns.map(\.name), ["id", "region", "filename"], "columns")
}

// MARK: the file that is not what its name says

/// 🔴 **The nineteen checks above this one never opened a file that could not be read**, and that
/// is why 461 tests and a green `--verify` sat on top of the single most common user error in the
/// product rendering as `The operation couldn't be completed. (DuckDBKit.DuckDBError error 1.)`.
/// Every check here is a *successful* open of a *valid* fixture; a verifier made only of those
/// proves the happy path and nothing about the sentence a user actually reads first.
///
/// So this one opens four files that are genuinely broken and asserts on the MESSAGE, not merely
/// that something was thrown: DuckDB's own first line has to survive to `localizedDescription`,
/// which is what `main.swift` prints and what the app's banner will show.
@Sendable func checkMalformedFile(_ ws: Workspace) async throws {
    let session = try ws.session()
    let broken: [(String, String, String)] = [
        // (what, filename, bytes)
        ("a corrupt parquet", "corrupt.parquet", "this is not a parquet file"),
        ("an empty parquet", "empty.parquet", ""),
        ("a truncated json", "corrupt.json", "{\"a\": "),
        ("a half-written ndjson", "corrupt.ndjson", "{\"a\": 1}\n{not json at all\n"),
    ]

    for (what, name, bytes) in broken {
        let path = ws.path(name)
        try bytes.write(toFile: path, atomically: true, encoding: .utf8)

        var reported: String?
        do {
            _ = try await session.openPath(path)
        } catch let error as SessionError {
            // BOTH string paths, because they are different code paths in Swift and only one of
            // them was ever wrong: `"\(error)"` was always the sentence, `localizedDescription`
            // was the Foundation dump.
            try requireEqual(error.localizedDescription, error.message, "\(what): the two string paths")
            reported = error.message
        } catch {
            throw VerifyFailure(
                message: "opening \(what) threw \(type(of: error)) instead of SessionError: "
                    + "\(error.localizedDescription)"
            )
        }
        guard let message = reported else {
            throw VerifyFailure(message: "opening \(what) did not fail at all")
        }
        try require(
            !message.contains("The operation couldn"),
            "opening \(what) reported a Foundation dump instead of DuckDB's message: \(message)"
        )
        try require(
            message.count > 12 && !message.hasPrefix("Query failed."),
            "opening \(what) reported nothing a user can act on: \(message)"
        )
    }

    // ...and the engine is still usable afterwards: a refused open must leave no half-built table
    // in the catalog and must not have poisoned the session.
    try requireEqual(await session.state().tables.count, 0, "tables left behind by four failed opens")
    let good = try await session.openPath(try writeSalesCSV(ws.path("sales.csv"), rows: 20))
    try requireEqual(try await session.page(good.name, offset: 0, limit: 50).rows.count, 20, "rows after the failures")
}

// MARK: profiling and panels

@Sendable func checkProfile(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    let profile = try await session.computeProfile(t.name)
    try requireEqual(
        profile.map(\.name), ["order_id", "region", "amount", "note"], "profiled columns, in file order"
    )

    guard let orderID = profile.first(where: { $0.name == "order_id" }),
        let region = profile.first(where: { $0.name == "region" }),
        let note = profile.first(where: { $0.name == "note" })
    else { throw VerifyFailure(message: "a profiled column is missing") }

    try requireEqual(orderID.kind, Kind.number, "kind of order_id")
    try requireEqual(orderID.n, 500, "rows seen by the profile")
    try requireEqual(orderID.nNull, 0, "nulls in order_id")
    try requireEqual(region.kind, Kind.text, "kind of region")
    // Four values, and `approx_count_distinct` is clamped to the row count before display — the
    // HyperLogLog overshoot that reads as a bug on a small table.
    try requireEqual(region.approxDistinct, 4, "distinct regions")
    try requireEqual(region.view, ColumnProfile.View.topn, "panel chosen for region")
    try require(note.maxLen != nil && note.maxLen! >= 6, "maxLen of note: got \(String(describing: note.maxLen))")
    try require(orderID.minS == "0", "min of order_id: got \(String(describing: orderID.minS))")

    // Cached, not recomputed: the second call must return the identical profile.
    let again = try await session.computeProfile(t.name)
    try requireEqual(again, profile, "the profile is cached after the first computation")
}

@Sendable func checkDistinctPanel(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    let panel = try await session.distinct(t.name, col: "region")
    try requireEqual(panel.nRows, 500, "rows behind the panel")
    try requireEqual(panel.nNonnull, 500, "non-null values")
    try requireEqual(panel.values.count, 4, "distinct values shown")
    try requireEqual(panel.nDistinct.value, 4, "distinct count")
    try require(panel.nDistinct.exact, "a 4-value column should get an exact distinct count")
    try requireEqual(panel.otherN, 0, "rows not covered by the shown values")
    try requireEqual(
        Set(panel.values.map(\.label)), ["West", "Midwest", "South", "Northeast"], "value labels"
    )
    try requireEqual(panel.values.reduce(0) { $0 + $1.n }, 500, "counts summed across the panel")
    try require(!panel.values.contains { $0.selected }, "nothing should be selected before a filter")

    // Faceting: this column's own filter is dropped from the panel query, so clicking "West"
    // leaves the other three regions visible with West highlighted. Getting this wrong makes the
    // panel collapse to one row the moment anyone uses it.
    _ = try await session.setSpec(
        t.name, filters: [Filter(col: "region", op: .eq, values: [.text("West")])], sort: []
    )
    let faceted = try await session.distinct(t.name, col: "region")
    try requireEqual(faceted.values.count, 4, "values still shown after filtering on this column")
    try requireEqual(faceted.nRows, 500, "the faceted panel counts unfiltered rows")
    try requireEqual(faceted.values.filter(\.selected).map(\.label), ["West"], "selected values")

    // ...while the grid behind it really is filtered.
    let page = try await session.page(t.name, offset: 0, limit: 500)
    try requireEqual(page.rows.count, 125, "filtered rows in the grid")
    try requireEqual(page.total.value, 125, "filtered total")
}

@Sendable func checkHistogramPanel(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    let h = try await session.histogram(t.name, col: "order_id", bins: 10)
    try require(!h.degenerate, "a 0..499 column read as degenerate: \(h.reason ?? "")")
    try requireEqual(h.bins, 10, "bins")
    try requireEqual(h.nNull, 0, "nulls reported alongside the histogram")
    try requireEqual(h.buckets.reduce(0) { $0 + $1.n }, 500, "rows covered by the buckets")
    try require(
        h.buckets.allSatisfy { (0..<10).contains($0.b) },
        "a bucket index escaped 0..<10: \(h.buckets.map(\.b))"
    )
    // `least(bins - 1, ...)` exists so max(value) lands in the last bucket and not a phantom
    // bucket N. Without it the top row falls off the chart.
    try requireEqual(h.buckets.map(\.b).max(), 9, "highest bucket index")
    // Bucket edges are derived from lo/step, so bucket 0 starts at the bottom of the range.
    try require(h.buckets.first?.lo == h.lo, "the first bucket does not start at lo")

    // A single-valued column has no range to bin, and the panel has to SAY so rather than draw
    // one enormous bar or an empty chart the user reads as "no data".
    let flat = try writeConstantCSV(ws.path("flat.csv"), rows: 50)
    let ft = try await session.openPath(flat)
    let degenerate = try await session.histogram(ft.name, col: "v")
    try require(degenerate.degenerate, "a single-valued column did not report degenerate")
    try require(degenerate.reason != nil, "a degenerate histogram must say why")
    try require(degenerate.buckets.isEmpty, "a degenerate histogram invented \(degenerate.buckets.count) buckets")
}

@Sendable func checkSmallPanels(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    let sample = try await session.sampleValues(t.name, col: "note", limit: 20)
    try requireEqual(sample.count, 20, "sampled values")
    try require(!sample.contains { $0.isNull }, "the sample invented a NULL")
    try require(
        sample.allSatisfy { $0.display.hasPrefix("note ") },
        "a sampled value did not come from the note column: \(sample.map(\.display))"
    )
    // A panel nobody asked for failing is not an error the user must see — Python swallows it and
    // so does this, which is a deliberate contract and therefore worth pinning.
    try requireEqual(try await session.sampleValues(t.name, col: "nope").count, 0, "sample of an unknown column")

    let lengths = try await session.lengthHistogram(t.name, col: "note")
    try requireEqual(lengths.reduce(0) { $0 + $1.n }, 500, "rows covered by the length histogram")
    // "note 0" .. "note 499" is 6, 7 and 8 characters, and the buckets come back in length order.
    try requireEqual(lengths.map(\.len), [6, 7, 8], "note lengths, in order")
    try requireEqual(try await session.lengthHistogram(t.name, col: "nope").count, 0, "lengths of an unknown column")
}

// MARK: the rows your file lost

/// The product's headline claim, end to end: a file whose rows really are being dropped must say
/// so — through the engine's own accounting, through the bad-rows panel, and out of `sift <path>`.
@Sendable func checkDroppedRows(_ ws: Workspace) async throws {
    // 25,000 rows with one uncastable `amount` at row 21,000, gzipped. The compression is
    // load-bearing, not incidental: an UNcompressed CSV under 50 MB is sniffed in full, so DuckDB
    // widens `amount` to VARCHAR the moment it sees "N/A" and nothing is ever dropped. A compressed
    // one always samples only the first 20,480 rows, which is the real scenario — the type is
    // fixed from a sample that never saw the bad value, and `ignore_errors` silently drops the row.
    let path = try writeDirtyGzipCSV(ws.path("dirty.csv.gz"), rows: 25_000, badRow: 21_000)
    let session = try ws.session()
    let t = try await session.openPath(path)

    guard let settled = await waitForOpenScan(session, t.name) else {
        throw VerifyFailure(message: "the background bad-row scan did not finish within 30s")
    }
    try requireEqual(settled.rowCount, 25_000, "physical rows in the file")
    try requireEqual(settled.badRows, 1, "rows that would not cast")
    try requireEqual(settled.badCells, 1, "cells that would not cast")
    try requireEqual(settled.gridRows, 24_999, "rows the grid can actually page")

    let panel = try await session.badRows(t.name)
    try requireEqual(panel.rows, 1, "rows reported by the bad-rows panel")
    try requireEqual(panel.cells, 1, "cells reported by the bad-rows panel")
    try requireEqual(panel.data.count, 1, "bad rows returned")
    // `bad_columns` names the offending column so the UI can highlight the CELL, not just the row.
    try requireEqual(panel.data[0][0], Cell.list([.text("amount")]), "bad_columns")

    // And the CLI says it out loud. A second `Session` on the same home would violate this file's
    // rule 2, so `openAndDescribe` gets its own home inside this workspace's scratch directory —
    // still removed with everything else when the check ends.
    let overview = try await openAndDescribe(path: path, rows: 3, home: ws.path("cli-home"))
    try requireEqual(overview.droppedRows, 1, "dropped rows reported by `sift <path>`")
    try requireEqual(overview.droppedCells, 1, "dropped cells reported by `sift <path>`")
    let rendered = renderOverview(overview)
    try require(
        rendered.contains("1 row dropped"),
        "`sift <path>` did not report the dropped row:\n\(rendered)"
    )

    // The other half of the ruling: a CLEAN file must say "no rows dropped" rather than going
    // quiet, because silence is indistinguishable from never having checked.
    let clean = try writeSalesCSV(ws.path("sales.csv"), rows: 200)
    let cleanOverview = try await openAndDescribe(path: clean, rows: 3, home: ws.path("cli-home-2"))
    try requireEqual(cleanOverview.droppedRows, 0, "dropped rows on a clean file")
    try require(
        renderOverview(cleanOverview).contains("no rows dropped"),
        "a clean file said nothing about dropped rows:\n\(renderOverview(cleanOverview))"
    )
}

// MARK: the columns your file lost

/// The other half of the same claim, and the half that shipped broken. `checkDroppedRows` covers a
/// file losing ROWS; this covers one losing its entire COLUMN structure. When a CSV's rows do not
/// all carry the same number of fields, DuckDB's sniffer cannot find a consistent field count for
/// the real delimiter and falls back to one that does not occur in the file at all — so every row
/// survives intact, as a single column literally named `order_id,region,amount`, under an
/// honest-looking "no rows dropped". That is the exact failure this product exists to prevent, and
/// it said nothing at all until this check existed.
@Sendable func checkRaggedCollapse(_ ws: Workspace) async throws {
    let path = try writeRaggedCSV(ws.path("ragged.csv"))
    let session = try ws.session()
    let t = try await session.openPath(path)

    // What Sift SHOWS is deliberately unchanged. It does not quietly re-read the file with
    // different options and hand back different columns — that would trade one silent behaviour
    // for another, and the user would have no way to tell which read they were looking at.
    try requireEqual(t.spec.columns.count, 1, "columns the sniffer produced")
    try requireEqual(t.rowCount, 6, "rows in the file")
    try requireEqual(t.spec.raggedColumns, 5, "columns null padding gets back")
    try require(
        t.notes.contains { $0.contains("read as one column") && $0.contains("null padding") },
        "the open said nothing about the file losing its columns; notes were \(t.notes)"
    )

    // ...and it reaches the CLI, NEXT TO the dropped-rows line rather than instead of it. A file
    // that lost its shape must not be able to print "no rows dropped" and stop there.
    let overview = try await openAndDescribe(path: path, rows: 3, home: ws.path("cli-home"))
    let rendered = renderOverview(overview)
    try require(
        rendered.contains("to see all 5"), "`sift <path>` did not report the collapse:\n\(rendered)"
    )
    try require(rendered.contains("no rows dropped"), "the dropped-rows line went missing:\n\(rendered)")

    // 🔴 The half that makes the note worth printing at all: the way out it names really works.
    // Same build path, one explicit option, and the five real columns come back with every field
    // in place — including the two on row 3 that had nowhere to live in a one-column read.
    let con = try scratchDatabase().connect()
    let padded = try buildSource(con, path: path, nullPadding: true)
    try requireEqual(
        padded.columns.map(\.name), ["order_id", "region", "amount", "column3", "column4"],
        "columns recovered by null padding"
    )
    try requireEqual(padded.raggedColumns, nil, "a null-padded open still reported itself collapsed")
    let rows = try con.query("SELECT * FROM \(readExpr(spec: padded))").allRows()
    try requireEqual(rows.count, 6, "rows read back with null padding")
    try requireEqual(
        rows[2].map(\.display), ["3", "South", "30", "EXTRA", "FIELDS"], "the widest row"
    )

    // The other direction, and the one that decides whether any of this is worth having: a healthy
    // file stays quiet. A note that fires on a legitimate single-column file is worse than no note,
    // because it teaches the reader to skip past the one that was true.
    let clean = try writeSalesCSV(ws.path("sales.csv"), rows: 50)
    try requireEqual(
        try buildSource(con, path: clean).raggedColumns, nil, "a clean file was reported as collapsed"
    )
}

// MARK: the file your preamble ate

/// The third shape of the same product claim, and the one found by hand-checking the ragged fix's
/// own false-positive controls. `checkDroppedRows` covers a file losing ROWS and `checkRaggedCollapse`
/// a file losing its COLUMN STRUCTURE; this covers a file losing everything. Three lines of prose
/// sniffed as `;`, the first two thrown away as a preamble, the third turned into column names, and
/// an empty grid under the words "no rows dropped".
///
/// The two files that must stay SILENT are the point of this check as much as the one that must
/// speak: a header with no rows under it is a legitimate zero-row file, and a real preamble in
/// front of real data is a supported feature.
@Sendable func checkPreambleAteTheFile(_ ws: Workspace) async throws {
    let path = try writeProseCSV(ws.path("prose.csv"))
    let session = try ws.session()
    let t = try await session.openPath(path)

    // What Sift SHOWS is deliberately unchanged — it does not quietly re-read the file with
    // different options. What it must not do is show an empty grid and say nothing about why.
    try requireEqual(t.rowCount, 0, "rows the sniffed dialect found")
    try requireEqual(t.spec.columns.count, 2, "columns the sniffer produced")
    try requireEqual(preambleAteTheFile(t.spec), 2, "lines thrown away as a preamble")
    try require(
        t.notes.contains { $0.contains("skipped as a preamble") && $0.contains("no rows at all") },
        "the open said nothing about the file being thrown away; notes were \(t.notes)"
    )

    let overview = try await openAndDescribe(path: path, rows: 10, home: ws.path("cli-home"))
    let rendered = renderOverview(overview)
    try require(
        rendered.contains("The first 2 lines were skipped as a preamble"),
        "`sift <path>` did not report the discarded preamble:\n\(rendered)"
    )
    try require(rendered.contains("(no rows)"), "the empty grid stopped saying it was empty:\n\(rendered)")

    // 🔴 The way out the note names really works: pinning `skip` to 0 recovers the one column the
    // file actually has and both lines of prose that were thrown away.
    let con = try scratchDatabase().connect()
    let kept = try buildSource(con, path: path, skipPreamble: false)
    try requireEqual(kept.columns.map(\.name), ["notes"], "columns recovered by not skipping")
    try requireEqual(kept.rowCount, 2, "rows recovered by not skipping")
    try requireEqual(preambleAteTheFile(kept), nil, "the recovered spec still reported itself eaten")
    let rows = try con.query("SELECT * FROM \(readExpr(spec: kept))").allRows()
    try requireEqual(
        rows.map { $0[0].display },
        ["this is prose, with a comma", "another line; semicolon too"], "the recovered lines"
    )

    // SILENCE, on both shapes that look like this one and are not it. A note that fires on either
    // teaches the reader to skip past notes, which costs them the one that was true.
    let headerOnly = try buildSource(con, path: writeHeaderOnlyCSV(ws.path("header.csv")))
    try requireEqual(headerOnly.rowCount, 0, "a header-only file should genuinely have no rows")
    try requireEqual(preambleNote(headerOnly), nil, "a header-only file was reported as eaten")

    // `skip` is a feature: 3 junk lines and 200 real rows must pass without a word. The `skip`
    // assertion is fixture integrity — if DuckDB ever classifies those junk lines as comments
    // instead, this file stops being a preamble file and the silence below proves nothing.
    let preamble = try buildSource(con, path: writePreambleCSV(ws.path("preamble.csv"), rows: 200))
    try requireEqual(preamble.readArgs["skip"], .int(3), "lines skipped in front of real data")
    try requireEqual(preamble.rowCount, 200, "rows behind a real preamble")
    try requireEqual(preambleAteTheFile(preamble), nil, "a real preamble was reported as eaten")
}

// MARK: what the user copies out

@Sendable func checkSnippetAndRenderedSQL(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    _ = try await session.setSpec(
        t.name,
        filters: [Filter(col: "region", op: .inList, values: [.text("West"), .text("South")])],
        sort: [.init(column: "order_id", direction: .desc)]
    )

    let sql = try await session.renderedSQL(t.name)
    for fragment in [
        "SELECT *", "FROM \"sales\"", "\"region\" IN ('West', 'South')", "ORDER BY \"order_id\" DESC",
    ] {
        try require(sql.contains(fragment), "rendered SQL is missing \u{201C}\(fragment)\u{201D}:\n\(sql)")
    }

    // Every snippet dialect produces something, and the "sql" one is the rendered SQL itself.
    var snippets: [String: String] = [:]
    for dialect in ["sql", "duckdb", "pandas", "polars"] {
        let text = try await session.snippet(t.name, dialect: dialect)
        try require(!text.isEmpty, "the \(dialect) snippet is empty")
        snippets[dialect] = text
    }
    try requireEqual(snippets["sql"], sql, "the sql snippet and the rendered SQL")
    // Each library snippet must reach the real file, not the in-engine table name — a snippet the
    // user pastes into a notebook has no `sales` view to read from.
    for dialect in ["duckdb", "pandas", "polars"] {
        try require(
            snippets[dialect]?.contains(path) == true,
            "the \(dialect) snippet does not name the source file:\n\(snippets[dialect] ?? "")"
        )
    }
    try require(snippets["pandas"]?.contains("pd.read_csv") == true, "pandas snippet is not a read_csv")
    try require(snippets["polars"]?.contains("pl.scan_csv") == true, "polars snippet is not a scan_csv")

    // An unknown dialect is a sentence, never a half-written snippet.
    var rejected = false
    do {
        _ = try await session.snippet(t.name, dialect: "excel")
    } catch is UnknownDialect {
        rejected = true
    }
    try require(rejected, "snippet accepted an unknown dialect")

    // 🔴 The assertion that makes the rest of this worth having: the rendered SQL is display text,
    // but it must still be SQL that RUNS and returns the same rows the grid is showing. A copy
    // button that hands the user a query DuckDB rejects is worse than no copy button.
    let filtered = try await session.page(t.name, offset: 0, limit: 1000)
    let rerun = try await session.runSQL(t.name, sql: sql, offset: 0, limit: 1000)
    try requireEqual(rerun.rows.count, 250, "rows from the rendered SQL run back through the engine")
    try requireEqual(rerun.rows.count, filtered.rows.count, "rendered SQL vs the grid it describes")
    try requireEqual(
        rerun.rows.map { $0[0].display }, filtered.rows.map { $0[0].display },
        "rendered SQL returned different rows, or a different order, than the grid"
    )
    _ = try await session.exitSQLMode(t.name)
    // In SQL mode the snippet must carry the user's own query verbatim rather than a
    // reconstruction of filters they are no longer looking at.
    _ = try await session.runSQL(t.name, sql: "SELECT 1 AS one", offset: 0, limit: 1)
    try requireEqual(try await session.snippet(t.name, dialect: "sql"), "SELECT 1 AS one", "snippet in SQL mode")
    _ = try await session.exitSQLMode(t.name)
}

// MARK: the gate

@Sendable func checkSelectOnlyGate(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)

    let denied = [
        "DROP TABLE \(t.name)",
        "DELETE FROM \(t.name)",
        // DuckDB classifies PRAGMA as StatementType.SELECT, so the keyword list is what stops it.
        "PRAGMA database_list",
        "COPY (SELECT 1) TO 'pwned.csv'",
        "ATTACH 'evil.db'",
        // Two statements: the second one is the payload.
        "SELECT 1; DROP TABLE \(t.name)",
        "-- nothing but a comment",
        "",
    ]
    for sql in denied {
        var rejected = false
        do {
            _ = try await session.runSQL(t.name, sql: sql, offset: 0, limit: 10)
        } catch is SQLRejected {
            rejected = true
        } catch {
            throw VerifyFailure(
                message: "the gate refused \u{201C}\(sql)\u{201D} with the wrong error type: \(error)"
            )
        }
        let shown = sql.isEmpty ? "an empty query" : "\u{201C}\(sql)\u{201D}"
        try require(rejected, "the SELECT-only gate accepted \(shown)")
    }

    // Nothing above ran, so the table is untouched.
    let page = try await session.page(t.name, offset: 0, limit: 500)
    try requireEqual(page.rows.count, 500, "rows still readable after the refused statements")

    // A semicolon INSIDE a string literal is not a second statement — rejecting it would be the
    // obvious wrong way to count statements, so this is pinned as an allow case.
    let literal = try await session.runSQL(
        t.name, sql: "SELECT '; DROP TABLE \(t.name)' AS s", offset: 0, limit: 10
    )
    try requireEqual(literal.rows.count, 1, "rows from the literal-semicolon query")
    try requireEqual(literal.rows[0][0].display, "; DROP TABLE \(t.name)", "the literal's value")

    let counted = try await session.runSQL(
        t.name, sql: "SELECT count(*) AS n FROM \(q(t.name))", offset: 0, limit: 10
    )
    try requireEqual(counted.rows[0][0].display, "500", "count(*) through the SQL box")

    _ = try await session.exitSQLMode(t.name)
    let back = try await session.page(t.name, offset: 0, limit: 500)
    try requireEqual(back.rows.count, 500, "rows after leaving SQL mode")
}

// MARK: the connections config decides the posture

/// 🔴 The other half of the hardening claim, and the half nothing else in `--verify` can make.
/// Every check above this one runs on a default home, where there is no `connections.json` and the
/// engine is airtight — that is the strict half, and `checkSelectOnlyGate` plus the posture tests in
/// the suite already pin it. This one plants `allowRemote: true` in a workspace's own home and
/// proves the whole chain end to end: the file is read BEFORE the `Database` opens, `harden()` skips
/// the deny list because of what it said, `httpfs` is loaded because of what it said, and a real
/// `read_parquet` over a real socket comes back with rows through the shipped SQL path.
///
/// GATED behind `SIFT_REMOTE_FACTS=1`, matching `RemoteFactsTests`/`RemotePostureTests`: `httpfs`
/// has to be present, and `loadExtensions` does LOAD→INSTALL→LOAD, so an unprepared machine would
/// reach for the network in the middle of a command a user runs to check their own install. A skip
/// is not a pass (rule 3 in this file's header) — it says which switch to flip.
@Sendable func checkRemoteConnection(_ ws: Workspace) async throws {
    guard ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1" else {
        throw VerifySkipped(
            message: "set SIFT_REMOTE_FACTS=1 to check a remote read — it needs the httpfs "
                + "extension, which may have to be installed over the network"
        )
    }

    // Written before the Session exists, which is the point: `Session.init` reads it before it
    // opens the store, and the posture is frozen from that moment.
    try Session.ensureHomeDirectory(ws.home)
    try Session.writeRemoteConfig(
        RemoteConfig(allowRemote: true), to: Session.connectionsPath(in: ws.home)
    )

    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let parquet = try writeParquet(ws.path("remote.parquet"), rows: 1000)
    server.register(path: "/remote.parquet", body: try Data(contentsOf: URL(fileURLWithPath: parquet)))

    let session = try ws.session()
    try requireEqual(await session.connections().allowRemote, true, "the config the session read back")
    try requireEqual(session.allowRemoteAtLaunch, true, "the posture the Database opened with")
    // MEASURED (remote facts §2): the permissive posture never issues the SET at all, so the key is
    // ABSENT rather than false — absent is "Sift deliberately never asked", false is "DuckDB
    // refused", and collapsing them would hide a renamed setting.
    try require(
        session.database.hardened["disabled_filesystems"] == nil,
        "a permissive session still disabled the network filesystems"
    )
    guard session.engineInfo().extensions["httpfs"] == .loaded else {
        throw VerifySkipped(
            message: "the DuckDB httpfs extension is not installed, so no remote read can be checked"
        )
    }

    // Loopback needs nothing like the default 30 s, and a machine that cannot reach its own socket
    // should say so in seconds — MEASURED on the first CI canary: 244 s to report nothing.
    try session.database.connect().execute("SET GLOBAL http_timeout=5")

    // Through the shipped path — the SELECT-only gate and `wrapUserSQL` — not a hand-built
    // connection. The claim is about what a user's query does, not about a DuckDB feature.
    let local = try await session.openPath(try writeSalesCSV(ws.path("sales.csv"), rows: 20))
    let page = try await session.runSQL(
        local.name,
        sql: "SELECT count(*) AS n FROM read_parquet('\(server.baseURL)/remote.parquet')",
        offset: 0, limit: 10
    )
    try requireEqual(page.rows.count, 1, "rows from the remote count")
    try requireEqual(page.rows[0][0].display, "1000", "rows read over http through a permissive Session")
    try require(!server.requestLog.isEmpty, "the read returned an answer without reaching the server")
}

// MARK: staging

@Sendable func checkStagingRoundTrip(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)
    let first = try await session.page(t.name, offset: 0, limit: 3)

    // `force`, because the policy correctly refuses to copy a 12 KB file — the point here is the
    // CTAS/swap/catalog machinery, not the size threshold (which StageTests already pins).
    let jobID = try await session.stageNow(t.name, force: true)
    try require(jobID != nil, "stageNow(force: true) started no job")

    let staged = try await waitForStaging(session, t.name)
    try require(staged.stagingError == nil, "staging failed: \(staged.stagingError ?? "")")
    try require(staged.staged, "the table is not marked staged after the job finished")
    try requireEqual(staged.rowCount, 500, "row count after staging")

    let entries = try await session.stagedEntries()
    try requireEqual(entries.map(\.table), [t.name], "catalogued staged copies")
    try requireEqual(entries[0].rows, 500, "rows recorded in the staging catalog")
    try require(entries[0].bytes > 0, "the staged copy recorded 0 bytes on disk")
    try require(!entries[0].sourceChanged, "the source was reported as changed immediately after copying it")
    try require(!entries[0].sourceMissing, "the source was reported as missing immediately after copying it")

    // The swap must be invisible: same rows, same order, off the native copy now.
    let afterStage = try await session.page(t.name, offset: 0, limit: 3)
    try requireEqual(afterStage.rows.map { $0[0].display }, first.rows.map { $0[0].display }, "rows across the swap")
    try requireEqual(afterStage.total.value, 500, "total after staging")

    let unstaged = try await session.unstage(t.name)
    try require(!unstaged.staged, "the table is still marked staged after unstage")
    try requireEqual(try await session.stagedEntries().count, 0, "catalog rows after unstage")

    let afterUnstage = try await session.page(t.name, offset: 0, limit: 3)
    try requireEqual(
        afterUnstage.rows.map { $0[0].display }, first.rows.map { $0[0].display },
        "rows after falling back to reading the file in place"
    )
}

// MARK: joins

@Sendable func checkMerge(_ ws: Workspace) async throws {
    // 100 keys on the left, 100 on the right, overlapping on 50 — so the probe has a number worth
    // reading rather than 0% or 100%.
    let left = try writeKeyedCSV(ws.path("orders.csv"), column: "amount", keys: 0..<100)
    let right = try writeKeyedCSV(ws.path("customers.csv"), column: "credit", keys: 50..<150)

    let session = try ws.session()
    let lt = try await session.openPath(left)
    let rt = try await session.openPath(right)

    let probe = try await session.joinProbe(lt.name, rt.name, on: ["k"])
    try requireEqual(probe.leftDistinct, 100, "distinct left keys")
    try requireEqual(probe.matched, 50, "matched keys")
    try requireEqual(probe.unmatched, 50, "unmatched keys")
    try require(abs(probe.pct - 0.5) < 1e-9, "match fraction: got \(probe.pct)")

    let unmatched = try await session.unmatchedKeys(lt.name, rt.name, on: ["k"])
    try requireEqual(unmatched.rows.count, 50, "unmatched key rows")

    let merged = try await session.merge(lt.name, rt.name, on: ["k"], how: .inner)
    try requireEqual(merged.spec.fmt, Fmt.merge, "merged source format")
    try requireEqual(merged.rowCount, 50, "rows in the inner join")
    // USING keeps one copy of the key and both sides' other columns.
    try requireEqual(merged.spec.columns.map(\.name), ["k", "amount", "credit"], "merged columns")
    try require(merged.profile != nil, "a merged table should be profiled eagerly")

    let page = try await session.page(merged.name, offset: 0, limit: 100)
    try requireEqual(page.rows.count, 50, "rows paged from the merged view")

    let outer = try await session.merge(lt.name, rt.name, on: ["k"], how: .left, name: "left_outer")
    try requireEqual(outer.rowCount, 100, "rows in the left join")
}

// MARK: export

@Sendable func checkExport(_ ws: Workspace) async throws {
    let path = try writeSalesCSV(ws.path("sales.csv"), rows: 500)
    let session = try ws.session()
    let t = try await session.openPath(path)
    let excelAvailable = session.engineInfo().extensions["excel"] == .loaded

    var wrote: [String] = []
    for format in exportFormats {
        if format.key == "xlsx", !excelAvailable { continue }
        let dest = ws.path("out.\(format.ext)")
        let result = try await session.export(t.name, dest: dest, format: format.key)
        try requireEqual(result.format, format.key, "reported format")
        try requireEqual(result.dest, dest, "reported destination")
        try require(result.bytes > 0, "\(format.key) export wrote 0 bytes")
        try require(
            FileManager.default.fileExists(atPath: dest), "\(format.key) export left no file at \(dest)"
        )
        wrote.append(format.key)
    }
    try require(wrote.contains("parquet") && wrote.contains("csv"), "exported formats: \(wrote)")

    let parquetDest = ws.path("out.parquet")

    // A file is never silently replaced. The destination is CLAIMED with an exclusive create, so
    // there is no check-then-write window for a second writer to slip through.
    var refused = false
    do {
        _ = try await session.export(t.name, dest: parquetDest, format: "parquet")
    } catch let error as SessionError {
        refused = error.message.contains("already exists")
        try require(refused, "the overwrite refusal said something else: \(error.message)")
    }
    try require(refused, "export silently replaced an existing file")
    _ = try await session.export(t.name, dest: parquetDest, format: "parquet", overwrite: true)

    // An unknown format is a sentence, never an interpolation into the COPY statement.
    var rejected = false
    do {
        _ = try await session.export(t.name, dest: ws.path("out.bogus"), format: "parqet")
    } catch let error as SessionError {
        rejected = error.message.contains("Unsupported export format")
    }
    try require(rejected, "export accepted an unknown format")

    // Round trip: what came out reads back as what went in.
    let reopened = try await session.openPath(parquetDest)
    try requireEqual(reopened.rowCount, 500, "rows in the exported parquet")
    try requireEqual(
        reopened.spec.columns.map(\.name), t.spec.columns.map(\.name), "columns in the exported parquet"
    )
}

// MARK: - waiting

/// Poll until this table's staging job has ended. A staging job is a detached `Task`; there is no
/// completion handle to await, and the flag it clears IS the notification (SSE is gone).
func waitForStaging(_ session: Session, _ name: String, timeout: TimeInterval = 60) async throws -> Table {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let t = try await session.table(name)
        if t.staging == nil { return t }
        if Date() > deadline {
            throw VerifyFailure(message: "the staging job for \(name) did not finish within \(Int(timeout))s")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - fixtures

/// A throwaway in-memory DuckDB, used only to WRITE fixture files no sane amount of Swift could
/// hand-assemble (parquet, xlsx, a Delta table's data files). Hardened like the real one, so a
/// fixture cannot reach the network either.
func scratchDatabase(loading extensions: [String] = []) throws -> Database {
    let db = try Database.inMemory()
    db.harden()
    if !extensions.isEmpty { db.loadExtensions(extensions) }
    return db
}

/// The workhorse fixture: 4 columns, `region` cycling through 4 values (so the distinct panel has
/// something to count), `amount` decimal-looking text (so the sniffer has a type to infer).
/// Written as bytes by this process on purpose — the CSV path must be fed a real file, not one
/// DuckDB round-tripped through its own writer.
@discardableResult
func writeSalesCSV(_ path: String, rows: Int = 500) throws -> String {
    let regions = ["West", "Midwest", "South", "Northeast"]
    var out = "order_id,region,amount,note\n"
    for i in 0..<rows {
        out += "\(i),\(regions[i % regions.count]),\(i).50,note \(i)\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// A CSV whose rows do not all carry the same number of fields — the shape that makes DuckDB's
/// sniffer give up on the real delimiter and collapse the whole file into one column.
///
/// Deliberately ragged by two different amounts: the header carries three fields, row 3 carries
/// five and row 5 carries four. That is what makes 5 — not the header's 3, and not row 5's 4 — the
/// number null padding recovers, and it is the whole reason `raggedColumns` is MEASURED rather than
/// counted off the header. A fixture whose widest row matched its header would let a header count
/// pass for the right answer and quietly turn the check into a tautology.
@discardableResult
func writeRaggedCSV(_ path: String) throws -> String {
    try """
        order_id,region,amount
        1,Midwest,10
        2,West,20
        3,South,30,EXTRA,FIELDS
        4,East,40
        5,North,50,BOOM
        6,West,60

        """.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Three lines of one-column prose — the shape that makes DuckDB's sniffer throw the data away as
/// a preamble.
///
/// MEASURED on the vendored 1.5.5: it picks `;` (from line 3), decides the first TWO lines are
/// junk, and uses line 3 as the header. Two thirds of the file discarded, the remaining third
/// turned into column names, and not one row left. The commas and the semicolon are the whole
/// fixture — they are what give the sniffer a delimiter worth preferring over "this is one column
/// of text".
@discardableResult
func writeProseCSV(_ path: String) throws -> String {
    try """
        notes
        this is prose, with a comma
        another line; semicolon too

        """.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// A header and nothing else. Genuinely zero rows, and the detector above must stay silent on it —
/// this is the one file that looks exactly like the defect from the row count alone.
@discardableResult
func writeHeaderOnlyCSV(_ path: String) throws -> String {
    try "order_id,region,amount\n".write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Junk preamble lines followed by real data. `skip` is a FEATURE — this is the file it exists for,
/// and it has to stay silent too.
@discardableResult
func writePreambleCSV(_ path: String, rows: Int, preamble: Int = 3) throws -> String {
    var out = ""
    for i in 0..<preamble { out += "# generated file, junk line \(i)\n" }
    out += "order_id,region,amount\n"
    for i in 0..<rows { out += "\(i),West,\(i).50\n" }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// One column, one value, repeated — the degenerate histogram case.
@discardableResult
func writeConstantCSV(_ path: String, rows: Int) throws -> String {
    try ("v\n" + String(repeating: "7\n", count: rows)).write(
        toFile: path, atomically: true, encoding: .utf8
    )
    return path
}

/// A GZIPPED sales CSV with exactly one uncastable `amount`, placed past the 20,480-row window a
/// compressed CSV is sniffed from. See `checkDroppedRows` for why the compression is the whole
/// trick.
///
/// Written by DuckDB's own CSV writer rather than by hand: 25,000 rows of Swift string
/// concatenation plus a gzip is a fixture that costs more than the check, and shelling out to
/// `/usr/bin/gzip` would put a PATH dependency inside a shipped binary. `amount` is built as
/// VARCHAR so the one bad row is genuinely text in the file, exactly as a real dirty export has it.
@discardableResult
func writeDirtyGzipCSV(_ path: String, rows: Int, badRow: Int) throws -> String {
    let con = try scratchDatabase().connect()
    try con.execute(
        "COPY (SELECT range AS order_id, "
            + "['West','Midwest','South','Northeast'][(range % 4) + 1] AS region, "
            + "CASE WHEN range = \(badRow) THEN 'N/A' ELSE range || '.50' END AS amount, "
            + "'note ' || range AS note "
            + "FROM range(\(rows))) TO \(qlit(path)) (FORMAT csv, HEADER true, COMPRESSION gzip)"
    )
    return path
}

/// Two columns, ids starting at `from` — one member of a folder read.
@discardableResult
func writeSmallCSV(_ path: String, rows: Int, from: Int) throws -> String {
    var out = "id,region\n"
    for i in from..<(from + rows) {
        out += "\(i),\(i % 2 == 0 ? "West" : "South")\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// A key column plus one named payload column, for the join checks.
@discardableResult
func writeKeyedCSV(_ path: String, column: String, keys: Range<Int>) throws -> String {
    var out = "k,\(column)\n"
    for k in keys {
        out += "\(k),\(k * 2)\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@discardableResult
func writeJSONArray(_ path: String, rows: Int) throws -> String {
    let items = (0..<rows).map { "{\"id\": \($0), \"region\": \"\($0 % 2 == 0 ? "West" : "South")\"}" }
    try ("[\n" + items.joined(separator: ",\n") + "\n]\n").write(
        toFile: path, atomically: true, encoding: .utf8
    )
    return path
}

@discardableResult
func writeNDJSON(_ path: String, rows: Int) throws -> String {
    var out = ""
    for i in 0..<rows {
        out += "{\"id\": \(i), \"region\": \"\(i % 2 == 0 ? "West" : "South")\", \"nested\": {\"a\": \(i)}}\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Includes a `DECIMAL(12,2)` column, which is the only fixture in this file that can catch a
/// regression in `Cell`'s scale handling end to end.
@discardableResult
func writeParquet(_ path: String, rows: Int) throws -> String {
    let con = try scratchDatabase().connect()
    try con.execute(
        "COPY (SELECT range AS order_id, "
            + "['West','Midwest','South','Northeast'][(range % 4) + 1] AS region, "
            + "(range * 1.5)::DECIMAL(12,2) AS amount "
            + "FROM range(\(rows))) TO \(qlit(path)) (FORMAT parquet)"
    )
    return path
}

/// Needs the excel extension — the caller checks for it and skips.
@discardableResult
func writeXLSX(_ db: Database, _ path: String, rows: Int) throws -> String {
    let con = try db.connect()
    try con.execute(
        "COPY (SELECT range AS id, 'r' || range AS label FROM range(\(rows))) "
            + "TO \(qlit(path)) (FORMAT xlsx, HEADER true)"
    )
    return path
}

/// A minimal but genuine Delta table whose version 1 tombstones a parquet file that is still
/// sitting on disk. That gap — 100 rows through `delta_scan`, 150 through a raw glob — is the
/// whole reason `isDeltaDir` exists, and it is invisible to any fixture without a `remove` action.
@discardableResult
func writeDeltaTable(_ root: String, kept: Int, tombstoned: Int) throws -> String {
    let logDir = (root as NSString).appendingPathComponent("_delta_log")
    try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

    func member(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
    let part0 = "part-0.parquet"
    let part1 = "part-1.parquet"
    let con = try scratchDatabase().connect()
    try con.execute(
        "COPY (SELECT range AS id, 'kept' AS g FROM range(\(kept))) "
            + "TO \(qlit(member(part0))) (FORMAT parquet)"
    )
    try con.execute(
        "COPY (SELECT range AS id, 'tombstoned' AS g FROM range(\(kept), \(kept + tombstoned))) "
            + "TO \(qlit(member(part1))) (FORMAT parquet)"
    )

    func line(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
    func size(_ name: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: member(name)))?[.size] as? Int) ?? 0
    }

    let schema: [String: Any] = [
        "type": "struct",
        "fields": [
            ["name": "id", "type": "long", "nullable": true, "metadata": [String: Any]()],
            ["name": "g", "type": "string", "nullable": true, "metadata": [String: Any]()],
        ],
    ]
    let schemaString = String(
        data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
        encoding: .utf8
    ) ?? ""

    // A fixed timestamp, not `Date()`: nothing reads it, and a wall clock in a fixture is how a
    // timezone bug gets in.
    let fixedMs = 1_770_000_000_000
    var log0 = try line(["protocol": ["minReaderVersion": 1, "minWriterVersion": 2]])
    log0 += try line(["metaData": [
        "id": UUID().uuidString.lowercased(),
        "format": ["provider": "parquet", "options": [String: Any]()],
        "schemaString": schemaString,
        "partitionColumns": [String](),
        "configuration": [String: Any](),
        "createdTime": fixedMs,
    ]])
    for part in [part0, part1] {
        log0 += try line(["add": [
            "path": part, "partitionValues": [String: Any](), "size": size(part),
            "modificationTime": fixedMs, "dataChange": true,
        ]])
    }
    try log0.write(
        toFile: (logDir as NSString).appendingPathComponent("00000000000000000000.json"),
        atomically: true, encoding: .utf8
    )

    let log1 = try line(["remove": [
        "path": part1, "deletionTimestamp": fixedMs + 1000, "dataChange": true,
        "partitionValues": [String: Any](), "size": size(part1),
    ]])
    try log1.write(
        toFile: (logDir as NSString).appendingPathComponent("00000000000000000001.json"),
        atomically: true, encoding: .utf8
    )
    return root
}

// MARK: - `sift <path>`: open one file and look at it

/// What `sift <path>` learned about a file. Values only — the rendering is `renderOverview`.
///
/// Not `Equatable`: `TablePage.ColumnInfo` is not, and making it so would be a public API change
/// to Task 4's type for one convenience in this file's tests.
public struct FileOverview: Sendable {
    public let path: String
    public let table: String
    public let format: String
    /// Rows, when a number is actually known. `nil` means the background count is still running,
    /// which is the honest answer for a large compressed CSV.
    public let rows: Int?
    /// `false` when `rows` came from `estimateRows`' byte sampling rather than a real count.
    public let rowsExact: Bool
    /// How an inexact count was arrived at ("3x256KiB sample, no quote characters seen").
    public let rowsBasis: String?
    /// Rows the file lost because a cell would not cast to its sniffed type. `0` means the scan
    /// ran and found nothing; **`nil` means the scan did not finish in time and nothing is known**
    /// — the two must never be collapsed, which is the whole reason this is optional.
    public let droppedRows: Int?
    /// Cells behind `droppedRows`. One bad row can carry several.
    public let droppedCells: Int
    public let notes: [String]
    public let columns: [TablePage.ColumnInfo]
    public let preview: [[Cell]]
    public let milliseconds: Double
}

/// Open a file the way the app will and report its schema plus the first rows.
///
/// `home` defaults to the real `~/.sift` (or `$SIFT_HOME`), because this is a user-facing command
/// and a staged copy it adopts or leaves behind is a feature. Tests pass an explicit one.
public func openAndDescribe(
    path: String, sheet: String? = nil, rows: Int = 10, home: String? = nil,
    nullPadding: Bool = false, skipPreamble: Bool = true
) async throws -> FileOverview {
    let started = DispatchTime.now()
    let session = try Session(home: home)
    let t = try await session.openPath(
        path, sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
    )
    let page = try await session.page(t.name, offset: 0, limit: max(0, rows))
    // 🔴 THE WAIT IS THE POINT. "Your file lost 12 rows" is this product's headline claim, and it
    // is produced by a detached background scan that had not run yet when `openPath` returned —
    // so before this, `sift <path>` printed the surviving rows and said nothing at all about the
    // missing ones. See `waitForOpenScan` for why it polls rather than reading the flag once.
    let settled = await waitForOpenScan(session, t.name)
    await session.shutdown()

    // A short page at offset 0 IS the end of the table, so the count is exact even though the
    // background scan may have produced nothing. That matters here: `openPath` returns no count at
    // all for a folder or a Delta table, and printing "counting rows…" above a preview that already
    // shows the whole file is the kind of thing that reads as broken.
    var rowCount = settled?.rowCount ?? t.rowCount
    var exact = rowCount != nil
    if rowCount == nil, rows > 0, page.rows.count < rows {
        rowCount = page.rows.count
        exact = true
    }

    return FileOverview(
        path: t.spec.key.path,
        table: t.name,
        format: t.spec.fmt.rawValue,
        rows: rowCount ?? t.spec.rowEstimate?.rows,
        rowsExact: exact,
        rowsBasis: exact ? nil : t.spec.rowEstimate?.basis,
        droppedRows: settled.map(\.badRows),
        droppedCells: settled?.badCells ?? 0,
        notes: settled?.notes ?? t.notes,
        columns: page.columns,
        preview: page.rows,
        milliseconds: millisecondsSince(started)
    )
}

/// Poll until this open's background pipeline has landed, and hand back the settled `Table`.
/// `nil` means it did not finish inside `timeout` — which the caller must report as "not known",
/// never as "nothing was dropped".
///
/// `runAfterOpen` runs exact count -> bad-row detection -> staging decision, in that order, and the
/// staging decision is always its last step, so `stageDecision != nil` is the observable "it has
/// landed" signal. There is no completion handle to await: the pipeline is a detached `Task` and
/// the state change IS the notification (SSE is gone) — the same shape, and the same reason, as
/// `waitForStaging` above.
///
/// 🔴 POLLED, not read once. A `Task {}` is not guaranteed to have STARTED by the time the next
/// line runs, so a single read of `badRows` right after `openPath` returns 0 on every file,
/// including the ones that really did lose rows — a green, silent, entirely wrong answer.
func waitForOpenScan(_ session: Session, _ name: String, timeout: TimeInterval = 30) async -> Table? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        guard let t = try? await session.table(name) else { return nil }
        if t.stageDecision != nil { return t }
        if Date() > deadline { return nil }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// The whole `sift <path>` output: a headline, the schema, and the first rows as a grid.
///
/// Row counts are thousands-grouped through `SiftCore.groupDigits` (`SiftCore/Stage.swift`; an
/// earlier version of this comment said `CellDisplay.groupDigits`, which is not where it lives and
/// not the module that owns it) — the same public rule the
/// grid's cells go through, and the same one SiftUI will use. (An earlier version of this comment
/// explained why they printed ungrouped: the two grouping helpers that already existed,
/// `DuckDBKit.Cell.grouped` and `SiftCore.grouped(_:decimals:)`, are module-internal and cannot be
/// reached from here. That was true and it was the wrong conclusion — a rule that exists privately
/// twice is a rule the third consumer goes without, which is exactly what happened. It is public
/// once now, in the layer both consumers import.)
public func renderOverview(_ overview: FileOverview, width: Int = 100) -> String {
    var lines: [String] = []

    let count: String
    if let rows = overview.rows {
        count = (overview.rowsExact ? "" : "~") + groupDigits(String(rows)) + " rows"
    } else {
        count = "counting rows\u{2026}"
    }
    lines.append("\(overview.table) \u{2014} \(overview.format) \u{2014} \(count)")
    lines.append(overview.path)
    if let basis = overview.rowsBasis { lines.append("estimate: \(basis)") }
    lines.append(renderDropped(rows: overview.droppedRows, cells: overview.droppedCells))
    for note in overview.notes { lines.append("note: \(note)") }

    lines.append("")
    lines.append(contentsOf: renderSchema(overview.columns))

    lines.append("")
    if overview.preview.isEmpty {
        lines.append("  (no rows)")
    } else {
        lines.append(contentsOf: renderGrid(columns: overview.columns, rows: overview.preview, width: width))
        if let total = overview.rows, total > overview.preview.count {
            lines.append("")
            lines.append(
                "  showing \(groupDigits(String(overview.preview.count))) of "
                    + "\(groupDigits(String(total))) rows"
            )
        }
    }
    return lines.joined(separator: "\n")
}

/// The dropped-row line, printed on EVERY open.
///
/// "no rows dropped" is information. Silence is indistinguishable from never having looked, and
/// this tool's entire pitch is that it does not quietly hand you the rows that survived. The
/// unknown case gets its own sentence for the same reason: reporting a timed-out scan as zero
/// would be the exact failure this line exists to prevent, with a reassuring face on it.
func renderDropped(rows: Int?, cells: Int) -> String {
    guard let rows else {
        return "dropped rows: not known \u{2014} the background scan did not finish in time"
    }
    guard rows > 0 else { return "no rows dropped" }
    return "\(groupDigits(String(rows))) row\(rows == 1 ? "" : "s") dropped \u{2014} "
        + "\(groupDigits(String(cells))) cell\(cells == 1 ? "" : "s") would not cast to the "
        + "sniffed column type"
}

/// name / type / kind, one column per line.
func renderSchema(_ columns: [TablePage.ColumnInfo]) -> [String] {
    let nameWidth = columns.map(\.name.count).max() ?? 0
    let typeWidth = columns.map(\.type.count).max() ?? 0
    return columns.map {
        trimTrailing("  \(padRight($0.name, nameWidth))  \(padRight($0.type, typeWidth))  \($0.kind.rawValue)")
    }
}

/// The most a single cell may occupy before it is clipped.
let overviewCellMax = 24

/// Lay rows out as a fixed-width grid, dropping trailing columns that do not fit `width`.
///
/// Numbers are right-aligned, which is the one alignment rule that makes a column of figures
/// readable at all. Every cell's glyph comes from `CellDisplay.glyph(for:kind:)` — the SHARED
/// presentation layer the SwiftUI grid uses too, never `Cell.display`, which collapses NULL and
/// `''` into the same blank. Newlines are flattened to spaces, since a quoted newline in a CSV
/// cell would otherwise tear the grid in half.
func renderGrid(
    columns: [TablePage.ColumnInfo], rows: [[Cell]], width: Int, cellMax: Int = overviewCellMax
) -> [String] {
    guard !columns.isEmpty else { return [] }

    let texts: [[String]] = columns.indices.map { i in
        rows.map { row in i < row.count ? flatten(glyph(for: row[i], kind: columns[i].kind)) : "" }
    }
    let widths: [Int] = columns.indices.map { i in
        min(cellMax, max(columns[i].name.count, texts[i].map(\.count).max() ?? 0))
    }

    // Keep columns while they fit; always keep the first, however wide it is.
    var shown = 0
    var used = 2   // the two-space left margin
    for i in columns.indices {
        let cost = widths[i] + (shown == 0 ? 0 : 2)
        if shown > 0 && used + cost > width { break }
        used += cost
        shown += 1
    }

    func line(_ cells: [String], rightAlign: Bool) -> String {
        var out = "  "
        for i in 0..<shown {
            if i > 0 { out += "  " }
            let text = clip(cells[i], widths[i])
            out += rightAlign && columns[i].kind == .number
                ? padLeft(text, widths[i]) : padRight(text, widths[i])
        }
        return trimTrailing(out)
    }

    var lines = [line(columns.map(\.name), rightAlign: false)]
    for r in rows.indices {
        lines.append(line(columns.indices.map { texts[$0][r] }, rightAlign: true))
    }
    if shown < columns.count {
        lines.append("  \u{2026} and \(columns.count - shown) more column(s)")
    }
    return lines
}

// MARK: - small string helpers
//
// Hand-rolled rather than `String(format: "%-*s")`: `%s` takes a C string, and padding a Swift
// `String` through it mis-measures anything outside ASCII. These count Characters.

func padRight(_ s: String, _ width: Int) -> String {
    s + String(repeating: " ", count: max(0, width - s.count))
}

func padLeft(_ s: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - s.count)) + s
}

func clip(_ s: String, _ width: Int) -> String {
    guard s.count > width else { return s }
    guard width > 1 else { return String(s.prefix(width)) }
    return String(s.prefix(width - 1)) + "\u{2026}"
}

/// Newlines, carriage returns and tabs become spaces. A CSV cell really can contain one (a quoted
/// newline is a first-class fixture shape here), and one would otherwise tear the grid apart.
func flatten(_ s: String) -> String {
    String(s.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })
}

func trimTrailing(_ s: String) -> String {
    var out = s
    while out.hasSuffix(" ") { out.removeLast() }
    return out
}

// MARK: - argument parsing
//
// Hand-rolled: zero third-party dependencies is a project constraint, so there is no
// swift-argument-parser. Here rather than in `main.swift` for the reason this file's header gives
// — an `executableTarget` cannot be imported by a test target, and "which flag won" is exactly the
// kind of thing that quietly regresses.

public enum SiftCommand: Sendable, Equatable {
    case help
    case verify
    case open(
        path: String, sheet: String?, rows: Int, width: Int,
        nullPadding: Bool, skipPreamble: Bool
    )
    /// The arguments made no sense. Carries the sentence to print before the usage text.
    case usageError(String)
}

public let siftUsage = """
    sift \u{2014} look at a data file, or verify the engine end to end.

    Usage:
      sift <path> [--sheet NAME] [--rows N] [--width N]
                  [--null-padding | --no-skip-preamble]
      sift --verify
      sift --help

      --sheet NAME   which sheet of a workbook to open (default: the first non-empty one)
      --rows N       rows to preview (default: 10)
      --width N      terminal width to lay the grid out for (default: 100)

    When a note says the file lost its shape, these are the two ways back. They
    cannot be combined \u{2014} pinning the skip is what defeats null padding:

      --null-padding      read rows with more fields than the header, instead of
                          collapsing the whole file into one column
      --no-skip-preamble  keep the leading lines the sniffer wanted to discard,
                          when discarding them left no rows at all
    """

public func parseArguments(_ args: [String]) -> SiftCommand {
    if args.isEmpty { return .usageError("no arguments") }
    if args.contains("--help") || args.contains("-h") { return .help }
    if args.contains("--verify") {
        guard args.count == 1 else {
            return .usageError("--verify takes no other arguments")
        }
        return .verify
    }

    var path: String?
    var sheet: String?
    var rows = 10
    var width = 100
    var nullPadding = false
    var skipPreamble = true

    var i = 0
    while i < args.count {
        let arg = args[i]
        // `--rows=5` and `--rows 5` both, because both are what people type.
        let (name, inlineValue): (String, String?)
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            (name, inlineValue) = (String(arg[arg.startIndex..<eq]), String(arg[arg.index(after: eq)...]))
        } else {
            (name, inlineValue) = (arg, nil)
        }

        func value() -> String? {
            if let inlineValue { return inlineValue }
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }

        switch name {
        case "--sheet":
            guard let v = value() else { return .usageError("--sheet needs a sheet name") }
            sheet = v
        case "--rows":
            guard let v = value(), let n = Int(v), n >= 0 else {
                return .usageError("--rows needs a non-negative whole number")
            }
            rows = n
        case "--width":
            guard let v = value(), let n = Int(v), n >= 20 else {
                return .usageError("--width needs a whole number of at least 20")
            }
            width = n
        case "--null-padding":
            nullPadding = true
        case "--no-skip-preamble":
            skipPreamble = false
        default:
            if name.hasPrefix("-") { return .usageError("unknown option \(name)") }
            guard path == nil else { return .usageError("sift opens one file at a time") }
            path = arg
        }
        i += 1
    }

    guard let path else { return .usageError("no file to open") }
    // Rejected here rather than at the engine, so the user gets the usage text with it. The
    // engine refuses the same pair too (Session.openPath): pinning `skip` is exactly what
    // defeats `null_padding`, so accepting both would silently do neither.
    guard !(nullPadding && !skipPreamble) else {
        return .usageError("--null-padding and --no-skip-preamble cannot be combined")
    }
    return .open(
        path: path, sheet: sheet, rows: rows, width: width,
        nullPadding: nullPadding, skipPreamble: skipPreamble
    )
}
