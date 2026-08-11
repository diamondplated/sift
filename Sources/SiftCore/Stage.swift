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

/// Python's `PROFILE_EAGER_MAX_BYTES` (session.py:54), and it lives here rather than in SiftEngine
/// for the same reason `defaultBudgetBytes` does: it is cost policy, and cost policy that only one
/// consumer can see is cost policy the other consumer re-derives — or, as the UI plan's Task 5c
/// did, forgets entirely.
public let profileEagerMaxBytes = 200 * MB

/// Is a profile nobody asked for cheap enough to run on this source? Ported from the gate on
/// `session.py:454`: `size <= PROFILE_EAGER_MAX_BYTES or staged or fmt in NEVER_STAGE`.
///
/// 🔴 **This is the profiling path's version of `shouldStage`'s dwell, and it was the one piece of
/// `_after_open` that never got ported.** A `SUMMARIZE` reads every column of every row; over a
/// 30 GB CSV view that is minutes of work for a panel the user has not opened. Staging.swift's
/// header states the principle for the copy — "a drive-by 'let me peek at the header' must never
/// pay for a 20 s copy" — and it is exactly as true of an unasked-for profile.
///
/// The three ways through are not arbitrary:
/// * **under the threshold** — a full scan of 200 MB is sub-second, and the panels want it;
/// * **staged** — the copy is already native columnar storage in the local store;
/// * **`neverStage`** — parquet, a parquet glob, and Delta carry per-column statistics and support
///   row-group skipping, so profiling is cheap at any size. (Which is also why they are never
///   staged: the same property, read twice.)
///
/// Deliberately NOT applied inside `computeProfile`/`profileOf`. Python does not gate those either,
/// and it would be wrong to: a user clicking a column on a 30 GB file is asking, and answering
/// "no" to a direct request is a different product. This gates the SPECULATIVE kick only — see
/// `Session.profileIfCheap`, which is the entry point a speculative caller is meant to use.
public func shouldProfileEagerly(fmt: Fmt, sizeBytes: Int, staged: Bool) -> Bool {
    sizeBytes <= profileEagerMaxBytes || staged || neverStage.contains(fmt)
}

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
///
/// Not `private`, for the same reason `grouped` below isn't: StageTests pins its output at the
/// unit boundaries directly. Every string it produces is read by a user (every
/// `StageDecision.reason`), and before that test existed, changing the group separator from ","
/// to " " left all 195 tests green.
func human(_ nInput: Double) -> String {
    var n = nInput
    for unit in ["B", "KB", "MB", "GB"] {
        if abs(n) < 1024 {
            return unit == "B" ? "\(grouped(n, decimals: 0)) B" : "\(grouped(n, decimals: 1)) \(unit)"
        }
        n /= 1024.0
    }
    return "\(grouped(n, decimals: 1)) TB"
}

/// Insert thousands separators into an already-correct digit string.
///
/// 🔴 It takes a STRING and never parses it, which is the entire point: a BIGINT, a HUGEINT and a
/// DECIMAL all reach the grid with exact digits, and routing any of them through a `Double` on the
/// way to a comma would round the value — `9007199254740993` becomes `...992`, silently, in an
/// order-id column. Same reason the web's own `groupDigits` works on the string.
///
/// Anything that is not a plain digit run passes through untouched, so `inf`, `nan`, `1e+16` from
/// some future producer, or a text value that only looks numeric cannot be mangled here.
///
/// Lives in SiftCore, the lowest layer both consumers can import, and is `public` because
/// SiftEngine's cell renderer (`CellDisplay.glyph`) and the `sift` CLI's row counts call it
/// directly. It used to exist here AND in SiftEngine as two loops; `grouped(_:decimals:)` below is
/// now a wrapper over it. One copy remains elsewhere — `DuckDBKit.Cell.grouped(Int)`, for blob
/// sizes — and it stays there because DuckDBKit sits BELOW SiftCore in the module graph and cannot
/// import it. Two loops separated by the dependency graph, rather than three separated by nobody
/// having looked.
///
/// 🔴 NOT NumberFormatter, here or anywhere else on this branch. Without an explicit `.locale` it
/// follows `Locale.current` and the same value renders four ways (MEASURED: en_US "1,234",
/// de_DE "1.234", fr_FR "1 234", en_US_POSIX "1234").
public func groupDigits(_ text: String) -> String {
    let negative = text.hasPrefix("-")
    let body = negative ? String(text.dropFirst()) : text
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let whole = String(parts[0])
    guard !whole.isEmpty, whole.allSatisfy(isASCIIDigit) else { return text }

    var out = ""
    for (i, digit) in whole.enumerated() {
        if i > 0 && (whole.count - i) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    let fraction = parts.count > 1 ? "." + parts[1] : ""
    return (negative ? "-" : "") + out + fraction
}

/// ASCII `0`-`9` only. `Character.isNumber` is true for Devanagari and Arabic-Indic digits too,
/// which `\d` in the ported regex is not, and which `String(format:)` never produces.
public func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c >= "0" && c <= "9" }

/// `n` formatted to `decimals` places with a thousands-grouped integer part — Python's
/// `f"{n:,.{decimals}f}"`. Rounding comes from `String(format:)`, which — like Python's float
/// formatting — round-trips the double's exact binary value and rounds half-to-even on an exact
/// tie (verified against CPython; see task-6-report.md).
///
/// Formats, then defers to `groupDigits` for the separators. It carried its own copy of that loop
/// until Task 9. Behaviour is unchanged, including the non-finite cases: `%.Nf` of an infinity
/// spells "inf"/"-inf"/"nan", which the old loop passed through untouched (no digit ever satisfies
/// `(count - i) % 3 == 0` for a 3-character run) and which `groupDigits` also passes through
/// untouched, via its explicit all-digits guard.
///
/// Not `private`: Source.swift's `estimateRows` reuses this for its `basis` strings (Python's
/// `f"{n:,}"`), on the same "no NumberFormatter, no locale sensitivity" grounds — see task-9
/// gotcha #5. Still module-internal, not `public`; nothing outside SiftCore needs it.
func grouped(_ n: Double, decimals: Int) -> String {
    groupDigits(String(format: "%.\(decimals)f", n))
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

/// Public, like `defaultMaxAgeDays` below and unlike `stageMinBytes` above: session.py:978 spells
/// this budget out a second time as a bare `20` (the default of its `SIFT_STAGE_BUDGET_GB`
/// override), so it IS cross-module in Python — just duplicated rather than imported. SiftEngine
/// reads this one instead of restating the number.
public let defaultBudgetBytes = 20 * GB
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

/// DDL for the staged-table catalog. Ported from `CATALOG_DDL` with one deliberate change: the
/// PRIMARY KEY is `table_name`, where Python keys on `source_token`.
///
/// Python's key is wrong, and the flow that breaks it is first-class — `openPath` explicitly
/// derives `x_2` so one file can be open in two tabs. Both tabs share a source token, so the
/// second `INSERT OR REPLACE` REPLACED the first tab's row. REPRODUCED (review I5):
/// `catalog rows=["small_2"], real tables=["small", "small_2"]`, after which
/// `purgeStaged(all: true)` dropped only `small_2` — leaving a full copy in the store that no
/// purge could ever reach while `stagedTotalBytes()` kept counting it. Every other statement that
/// touches this table already keys on `table_name`, which is also the name the copy actually
/// occupies in the DuckDB catalog; the key now agrees with them. `SiftEngine.migrateCatalog`
/// handles a store created by an older build.
public let catalogDDL = """
    CREATE TABLE IF NOT EXISTS _sift_sources (
        source_token VARCHAR,
        path         VARCHAR,
        mtime_ns     BIGINT,
        size         BIGINT,
        table_name   VARCHAR PRIMARY KEY,
        fmt          VARCHAR,
        staged_at    TIMESTAMP,
        last_used    TIMESTAMP,
        row_count    BIGINT,
        bytes        BIGINT
    )
    """
