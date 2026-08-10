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
    VerificationCheck(name: "profile", run: checkProfile),
    VerificationCheck(name: "distinct panel", run: checkDistinctPanel),
    VerificationCheck(name: "SELECT-only gate", run: checkSelectOnlyGate),
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
    guard db.loadedExtensions["excel"] == true else {
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
    guard session.engineInfo().extensions["delta"] == true else {
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
    let excelAvailable = session.engineInfo().extensions["excel"] == true

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
    path: String, sheet: String? = nil, rows: Int = 10, home: String? = nil
) async throws -> FileOverview {
    let started = DispatchTime.now()
    let session = try Session(home: home)
    let t = try await session.openPath(path, sheet: sheet)
    let page = try await session.page(t.name, offset: 0, limit: max(0, rows))
    await session.shutdown()

    return FileOverview(
        path: t.spec.key.path,
        table: t.name,
        format: t.spec.fmt.rawValue,
        rows: t.rowCount ?? t.spec.rowEstimate?.rows,
        rowsExact: t.rowCount != nil,
        rowsBasis: t.rowCount == nil ? t.spec.rowEstimate?.basis : nil,
        notes: t.notes,
        columns: page.columns,
        preview: page.rows,
        milliseconds: millisecondsSince(started)
    )
}

/// The whole `sift <path>` output: a headline, the schema, and the first rows as a grid.
///
/// Row counts print ungrouped ("120000", not "120,000"). Both grouping helpers that exist here
/// (`DuckDBKit.Cell.grouped`, `SiftCore.grouped`) are module-internal and unreachable from this
/// module, and this branch has twice ruled against a third copy of that loop — a bare integer is
/// locale-independent and honest, which is the property that actually matters.
public func renderOverview(_ overview: FileOverview, width: Int = 100) -> String {
    var lines: [String] = []

    let count: String
    if let rows = overview.rows {
        count = overview.rowsExact ? "\(rows) rows" : "~\(rows) rows"
    } else {
        count = "counting rows\u{2026}"
    }
    lines.append("\(overview.table) \u{2014} \(overview.format) \u{2014} \(count)")
    lines.append(overview.path)
    if let basis = overview.rowsBasis { lines.append("estimate: \(basis)") }
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
            lines.append("  showing \(overview.preview.count) of \(total) rows")
        }
    }
    return lines.joined(separator: "\n")
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
/// readable at all. Every cell's glyph comes from `Cell.display` — the engine's own display logic,
/// which is where `DECIMAL(10,2)` learns to stay `10.50` — and newlines are flattened to spaces,
/// since a quoted newline in a CSV cell would otherwise tear the grid in half.
func renderGrid(
    columns: [TablePage.ColumnInfo], rows: [[Cell]], width: Int, cellMax: Int = overviewCellMax
) -> [String] {
    guard !columns.isEmpty else { return [] }

    let texts: [[String]] = columns.indices.map { i in
        rows.map { row in i < row.count ? flatten(row[i].display) : "" }
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
    case open(path: String, sheet: String?, rows: Int, width: Int)
    /// The arguments made no sense. Carries the sentence to print before the usage text.
    case usageError(String)
}

public let siftUsage = """
    sift \u{2014} look at a data file, or verify the engine end to end.

    Usage:
      sift <path> [--sheet NAME] [--rows N] [--width N]
      sift --verify
      sift --help

      --sheet NAME   which sheet of a workbook to open (default: the first non-empty one)
      --rows N       rows to preview (default: 10)
      --width N      terminal width to lay the grid out for (default: 100)
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
        default:
            if name.hasPrefix("-") { return .usageError("unknown option \(name)") }
            guard path == nil else { return .usageError("sift opens one file at a time") }
            path = arg
        }
        i += 1
    }

    guard let path else { return .usageError("no file to open") }
    return .open(path: path, sheet: sheet, rows: rows, width: width)
}
