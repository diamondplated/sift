import Foundation

// Staging policy and the staged-data lifecycle.
//
// Pure: decisions only. SiftEngine owns the thread that carries them out. The first step is
// always a view over the file (instant at any size); staging is the second, and only where it
// pays. Ported from engine/core/stage.py.

/// Internal (not public): only this file and StageTests.swift (via `@testable import`) need
/// them, mirroring how engine/tests/test_stage_policy.py imports `GB`/`MB` straight from
/// core.stage rather than restating the byte math.
let MB = 1024 * 1024
let GB = 1024 * MB

/// Below: a full re-parse is under ~100 ms, a view is imperceptible. `@usableFromInline` (not
/// `public`): it is `shouldStage`'s default `threshold`, and a default argument value must be
/// at least as accessible as the function it defaults for — but nothing in engine/ ever
/// referenced `STAGE_MIN_BYTES` outside stage.py, so this stays out of SiftCore's public API.
@usableFromInline let stageMinBytes = 25 * MB
/// Above: a CTAS is minutes and many GB of disk, so ask first.
let stageConfirmBytes = 20 * GB
/// Measured CSV parse rate on an M-series Mac; only the "~20 s" hint.
let parseBytesPerSec = 250 * MB

/// Never worth staging: parquet/glob are already columnar and compressed with footer statistics
/// and row-group skipping; a flat copy of delta additionally freezes the table at one version.
let neverStage: Set<Fmt> = [.parquet, .globParquet, .delta]

let stageSuffix = "__stage"

/// Decide whether this source earns a native DuckDB copy.
///
/// The payoff is not just aggregate speed: `LIMIT/OFFSET` on a CSV view is O(offset), while a
/// native table seeks by row group. Staging and smooth scrolling are the same feature.
public func shouldStage(
    fmt: Fmt, sizeBytes: Int, freeBytes: Int, threshold: Int = stageMinBytes
) -> StageDecision {
    if neverStage.contains(fmt) {
        return StageDecision(
            stage: false,
            reason: "already columnar with per-file statistics — a copy would only duplicate it"
                + (fmt == .delta ? " and pin the table to one version" : "")
        )
    }
    if sizeBytes < threshold {
        return StageDecision(
            stage: false,
            reason: "only \(human(Double(sizeBytes))) — re-reading it is faster than copying it"
        )
    }
    if freeBytes < sizeBytes {
        // Conservative: DuckDB usually compresses CSV below 1x, but running the disk to zero on
        // someone's laptop is not a risk worth taking for a speed-up.
        return StageDecision(
            stage: false,
            reason: "only \(human(Double(freeBytes))) free on disk for a \(human(Double(sizeBytes))) source"
        )
    }
    let est = Double(sizeBytes) / Double(parseBytesPerSec)
    if sizeBytes > stageConfirmBytes {
        return StageDecision(
            stage: true,
            reason: "\(human(Double(sizeBytes))) — this will take a while and use real disk",
            estSeconds: est, needsConfirm: true
        )
    }
    return StageDecision(
        stage: true,
        reason: "\(human(Double(sizeBytes))) of text — a native copy makes scrolling and grouping instant",
        estSeconds: est
    )
}

/// Locale-independent replica of Python's `_human`: `f"{n:,.0f} B"` for bytes, `f"{n:,.1f}
/// <unit>"` for KB/MB/GB/TB. Deliberately NOT NumberFormatter — without an explicit `.locale` it
/// follows `Locale.current`, and a blob-size string that changes shape with the user's region
/// already shipped twice on this branch. `grouped(_:decimals:)` below hand-rolls the formatting.
private func human(_ nInput: Double) -> String {
    var n = nInput
    for unit in ["B", "KB", "MB", "GB"] {
        if abs(n) < 1024 {
            return unit == "B" ? "\(grouped(n, decimals: 0)) B" : "\(grouped(n, decimals: 1)) \(unit)"
        }
        n /= 1024.0
    }
    return "\(grouped(n, decimals: 1)) TB"
}

/// `n` formatted to `decimals` places with a thousands-grouped integer part — Python's
/// `f"{n:,.{decimals}f}"`. Rounding comes from `String(format:)`, which — like Python's float
/// formatting — round-trips the double's exact binary value and rounds half-to-even on an exact
/// tie (verified against CPython; see task-6-report.md). Grouping loop mirrors DuckDBKit's
/// `Cell.grouped`, extended to carry a fractional part and a sign.
private func grouped(_ n: Double, decimals: Int) -> String {
    let formatted = String(format: "%.\(decimals)f", n)
    let negative = formatted.hasPrefix("-")
    let unsigned = negative ? String(formatted.dropFirst()) : formatted
    let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let intDigits = String(parts[0])
    let frac = parts.count > 1 ? ".\(parts[1])" : ""

    var out = ""
    for (i, c) in intDigits.enumerated() {
        if i > 0 && (intDigits.count - i) % 3 == 0 { out.append(",") }
        out.append(c)
    }
    return (negative ? "-" : "") + out + frac
}

public func stagingName(_ table: String) -> String {
    "\(table)\(stageSuffix)"
}

/// Materialize the source into native storage under a temporary name.
///
/// Deliberately does NOT set `preserve_insertion_order = false`: rows would land out of order,
/// making the swap *visible* as the grid silently reshuffling under the user mid-scroll.
public func ctasSQL(table: String, readExpr: String) -> String {
    "CREATE OR REPLACE TABLE \(q(stagingName(table))) AS SELECT * FROM \(readExpr)"
}

/// Replace the view with the staged table under the same user-facing name. DuckDB DDL is
/// transactional, so the rename is invisible to readers and the user's typed SQL keeps working.
/// SiftEngine holds a per-table lock across these and retries on conflict.
public func swapSQL(table: String) -> [String] {
    [
        "BEGIN TRANSACTION",
        "DROP VIEW IF EXISTS \(q(table))",
        "ALTER TABLE \(q(stagingName(table))) RENAME TO \(q(table))",
        "COMMIT",
    ]
}

public func dropStagingSQL(_ table: String) -> String {
    "DROP TABLE IF EXISTS \(q(stagingName(table)))"
}

// ------------------------------------------------------- staged-data lifecycle

/// `@usableFromInline` for the same reason as `stageMinBytes`: `DEFAULT_BUDGET_BYTES` was never
/// referenced outside stage.py either.
@usableFromInline let defaultBudgetBytes = 20 * GB
/// Public, unlike its two siblings above: `DEFAULT_MAX_AGE_DAYS` IS cross-module in Python
/// (session.py:980), so SiftEngine will need this one too.
public let defaultMaxAgeDays = 14

/// A row of the `_sift_sources` catalog, as far as purge decisions are concerned.
public struct StagedEntry: Sendable, Equatable {
    public let tableName: String
    public let path: String
    public let bytes: Int
    public let lastUsed: Date
    public let sourceToken: String

    public init(tableName: String, path: String, bytes: Int, lastUsed: Date, sourceToken: String = "") {
        self.tableName = tableName
        self.path = path
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.sourceToken = sourceToken
    }
}

/// Pick staged tables to evict. Returns (aged_out, over_budget) table names.
///
/// Staged data is *client* data on a laptop, so it ages out on a clock as well as under size
/// pressure — an LRU alone would keep a large feed around indefinitely while the total stayed
/// small. Age-out runs first, the size check applies to what survives, so nothing is ever
/// reported in both lists.
public func selectForPurge(
    entries: [StagedEntry], now: Date, budgetBytes: Int = defaultBudgetBytes,
    maxAgeDays: Int = defaultMaxAgeDays
) -> (aged: [String], over: [String]) {
    let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86400)
    let aged = entries.filter { $0.lastUsed < cutoff }.map(\.tableName)
    let agedSet = Set(aged)
    let survivors = entries.filter { !agedSet.contains($0.tableName) }

    // Evict least-recently-used first until the total fits.
    var total = survivors.reduce(0) { $0 + $1.bytes }
    var over: [String] = []
    for e in survivors.sorted(by: { $0.lastUsed < $1.lastUsed }) {
        if total <= budgetBytes { break }
        over.append(e.tableName)
        total -= e.bytes
    }
    return (aged, over)
}

/// DDL for the staged-table catalog. Ported verbatim from `CATALOG_DDL`.
public let catalogDDL = """
    CREATE TABLE IF NOT EXISTS _sift_sources (
        source_token VARCHAR PRIMARY KEY,
        path         VARCHAR,
        mtime_ns     BIGINT,
        size         BIGINT,
        table_name   VARCHAR,
        fmt          VARCHAR,
        staged_at    TIMESTAMP,
        last_used    TIMESTAMP,
        row_count    BIGINT,
        bytes        BIGINT
    )
    """
