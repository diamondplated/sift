import Foundation
import Testing
@testable import SiftCore

// Staging policy and the purge lifecycle. Pure — no connection, no files. Ported from
// engine/tests/test_stage_policy.py.

private let free = 500 * GB

// MARK: - should_stage

@Test(arguments: [Fmt.parquet, .globParquet, .delta])
func columnarFormatsAreNeverStaged(fmt: Fmt) {
    let d = shouldStage(fmt: fmt, sizeBytes: 100 * GB, freeBytes: free)
    #expect(d.stage == false)
}

@Test func smallTextIsNotWorthCopying() {
    let d = shouldStage(fmt: .csv, sizeBytes: 5 * MB, freeBytes: free)
    #expect(d.stage == false)
    #expect(d.reason.contains("faster"))
}

@Test func midSizeTextStagesInTheBackground() {
    let d = shouldStage(fmt: .csv, sizeBytes: 500 * MB, freeBytes: free)
    #expect(d.stage == true)
    #expect(d.needsConfirm == false)
    #expect(d.estSeconds > 0)
}

@Test func enormousTextAsksFirst() {
    let d = shouldStage(fmt: .csv, sizeBytes: 40 * GB, freeBytes: free)
    #expect(d.stage == true)
    #expect(d.needsConfirm == true)
}

@Test func refusesWhenTheDiskIsTight() {
    let d = shouldStage(fmt: .csv, sizeBytes: 10 * GB, freeBytes: 5 * GB)
    #expect(d.stage == false)
    #expect(d.reason.contains("free"))
}

@Test func thresholdBoundary() {
    #expect(shouldStage(fmt: .csv, sizeBytes: 25 * MB - 1, freeBytes: free).stage == false)
    #expect(shouldStage(fmt: .csv, sizeBytes: 25 * MB, freeBytes: free).stage == true)
}

// MARK: - should_profile_eagerly (session.py:454's gate, ported)

// The profiling path's version of the dwell. A `SUMMARIZE` reads every column of every row, so an
// UNASKED-FOR profile of a 30 GB CSV view is minutes of scan for a panel nobody opened. Python
// gates it three ways and the port had none of them — see `Session.profileIfCheap`.

@Test func aSmallTextSourceIsProfiledEagerly() {
    #expect(shouldProfileEagerly(fmt: .csv, sizeBytes: 5 * MB, staged: false))
}

@Test func aHugeTextSourceIsNotProfiledUntilSomeoneAsks() {
    #expect(!shouldProfileEagerly(fmt: .csv, sizeBytes: 30 * GB, staged: false))
    #expect(!shouldProfileEagerly(fmt: .json, sizeBytes: 30 * GB, staged: false))
    #expect(!shouldProfileEagerly(fmt: .ndjson, sizeBytes: 1 * GB, staged: false))
    #expect(!shouldProfileEagerly(fmt: .xlsx, sizeBytes: 1 * GB, staged: false))
}

@Test func profileEagerThresholdBoundary() {
    #expect(shouldProfileEagerly(fmt: .csv, sizeBytes: 200 * MB, staged: false))
    #expect(!shouldProfileEagerly(fmt: .csv, sizeBytes: 200 * MB + 1, staged: false))
}

/// Once the copy is in the local store the scan is native columnar work, whatever the source
/// weighed — the same reason `stagedRowCount` becomes authoritative at the swap.
@Test func aStagedSourceIsProfiledEagerlyAtAnySize() {
    #expect(shouldProfileEagerly(fmt: .csv, sizeBytes: 30 * GB, staged: true))
}

/// The formats `shouldStage` refuses to copy are exactly the formats that are cheap to profile —
/// per-column statistics and row-group skipping, the same property read twice. Reads
/// `neverStage` itself rather than a second list, so a format joining one set joins both.
@Test(arguments: [Fmt.parquet, .globParquet, .delta])
func columnarFormatsAreProfiledEagerlyAtAnySize(fmt: Fmt) {
    #expect(shouldProfileEagerly(fmt: fmt, sizeBytes: 100 * GB, staged: false))
    #expect(neverStage.contains(fmt), "the two policies must read the same set")
}

/// A glob of CSVs is NOT columnar, and it is the one folder shape that can be arbitrarily large.
@Test func aHugeCsvFolderIsNotProfiledEagerly() {
    #expect(!shouldProfileEagerly(fmt: .globCsv, sizeBytes: 30 * GB, staged: false))
}

// MARK: - human() — the locale trap
//
// `human()` is the module's only number formatter and its output is read by a user in every
// `StageDecision.reason`, all three of `estimateRows`' `basis` strings, and both of
// `ramWarning`'s numbers. Not one of those strings was asserted in either language: changing
// `grouped`'s separator from "," to " " left all 195 tests green. Python's `f"{n:,.1f}"` is
// always a comma group separator and a period decimal point regardless of locale, so these are
// the values, verbatim.

@Test(arguments: [
    (1023.0, "1,023 B"),                 // last byte before the KB step, and grouped
    (1024.0, "1.0 KB"),                  // first KB
    (1_048_576.0, "1.0 MB"),             // first MB
    (1_073_741_823.0, "1,024.0 MB"),     // 1 GB - 1 B: rounds to a grouped "1,024.0 MB", not "1.0 GB"
    (5_629_499_534_213_120.0, "5,120.0 TB"),   // 5 PiB — past the last named unit, still grouped
])
func humanUsesACommaGroupSeparatorAndAPeriodDecimalAtEveryUnitBoundary(n: Double, want: String) {
    #expect(human(n) == want)
}

// One reason string end to end, so the format is pinned where the user actually meets it.
@Test func stageReasonQuotesTheSizeThroughHuman() {
    #expect(
        shouldStage(fmt: .csv, sizeBytes: 500 * MB, freeBytes: free).reason
            == "500.0 MB of text — a native copy makes scrolling and grouping instant"
    )
}

// MARK: - transport
//
// 🔴 The finding is that `transport` changes NO threshold and NO branch, which is why it is asserted
// that way round below: a remote text source has already been downloaded once by the time this is
// asked (MEASURED — spike §7: reading one in place re-fetches 200 % of the object per statement),
// so it is a local file and every local rule applies to it unchanged. Inventing a different size
// for remote text would be a policy no measurement supports.

@Test func transportChangesNoThresholdAndNoVerdict() {
    for size in [5 * MB, 25 * MB - 1, 25 * MB, 500 * MB, 40 * GB] {
        let local = shouldStage(fmt: .csv, sizeBytes: size, freeBytes: free)
        let remote = shouldStage(fmt: .csv, sizeBytes: size, freeBytes: free, transport: .remote)
        #expect(local.stage == remote.stage, "\(size)")
        #expect(local.needsConfirm == remote.needsConfirm, "\(size)")
        // `estSeconds` is a PARSE estimate and the download already finished, so it needs no
        // adjustment either — the number that looks like it should move is the one that must not.
        #expect(local.estSeconds == remote.estSeconds, "\(size)")
    }
    // …and an in-place remote parquet is `neverStage` for exactly the local reason.
    #expect(shouldStage(fmt: .parquet, sizeBytes: 100 * GB, freeBytes: free, transport: .remote).stage == false)
}

/// What it DOES change: the sentence. "re-reading it is faster than copying it" describes
/// re-reading the source, which for a remote source would mean the network — and is not what
/// happens, because the bytes are already on disk.
@Test func aRemoteReasonNamesTheDownloadedCopyRatherThanTheSource() {
    #expect(
        shouldStage(fmt: .csv, sizeBytes: 5 * MB, freeBytes: free, transport: .remote).reason
            == "only 5.0 MB — re-reading the downloaded copy is faster than copying it"
    )
    #expect(
        shouldStage(fmt: .csv, sizeBytes: 500 * MB, freeBytes: free, transport: .remote).reason
            == "500.0 MB of downloaded text — a native copy makes scrolling and grouping instant"
    )
}

// MARK: - ctas_sql / swap_sql

// Turning off preserve_insertion_order makes the swap VISIBLE as the grid reshuffling.
@Test func ctasDoesNotDisableInsertionOrder() {
    let sql = ctasSQL(table: "sales", readExpr: "read_csv('/x.csv')")
    #expect(!sql.contains("preserve_insertion_order"))
    #expect(sql.contains(stagingName("sales")))
}

@Test func swapIsTransactionalAndKeepsTheUserFacingName() {
    let stmts = swapSQL(table: "sales")
    #expect(stmts.first == "BEGIN TRANSACTION")
    #expect(stmts.last == "COMMIT")
    #expect(stmts.contains { $0.contains("DROP VIEW IF EXISTS \"sales\"") })
    #expect(stmts.contains { $0.contains("RENAME TO \"sales\"") })
}

// MARK: - purge

// Only relative offsets from NOW are ever asserted on, so an arbitrary fixed instant (rather
// than reconstructing 2026-08-07 12:00:00 via Calendar) is enough to match Python's NOW.
private let NOW = Date(timeIntervalSinceReferenceDate: 0)

private func entry(_ name: String, _ daysAgo: Int, _ gb: Double) -> StagedEntry {
    StagedEntry(
        tableName: name, path: "/data/\(name).csv", bytes: Int(gb * Double(GB)),
        lastUsed: NOW.addingTimeInterval(-Double(daysAgo) * 86400)
    )
}

@Test func ageOutSelectsOnlyStaleEntries() {
    let entries = [entry("fresh", 1, 1), entry("old", 20, 1), entry("edge", 13, 1)]
    let (aged, over) = selectForPurge(entries: entries, now: NOW, budgetBytes: 100 * GB)
    #expect(aged == ["old"])
    #expect(over == [])
}

@Test func sizePressureEvictsLeastRecentlyUsedFirst() {
    let entries = [entry("a", 1, 8), entry("b", 2, 8), entry("c", 3, 8)]
    let (aged, over) = selectForPurge(entries: entries, now: NOW, budgetBytes: 20 * GB)
    #expect(aged == [])
    #expect(over == ["c"])   // 24 GB total, drop the oldest-used until it fits
}

@Test func nothingIsReportedInBothLists() {
    let entries = [entry("stale_big", 30, 30), entry("fresh_big", 1, 30)]
    let (aged, over) = selectForPurge(entries: entries, now: NOW, budgetBytes: 20 * GB)
    #expect(Set(aged).isDisjoint(with: over))
    #expect(aged == ["stale_big"])
    // After the age-out only fresh_big remains at 30 GB, still over a 20 GB budget.
    #expect(over == ["fresh_big"])
}

@Test func recentlyUsedSurvivesWhenTheBudgetAlreadyFits() {
    let entries = [entry("a", 0, 1), entry("b", 0, 1)]
    let (aged, over) = selectForPurge(entries: entries, now: NOW, budgetBytes: 20 * GB)
    #expect(aged == [] && over == [])
}

@Test func defaultAgeIsTwoWeeks() {
    #expect(defaultMaxAgeDays == 14)
}

// MARK: - catalog schema (review round 1, I2)

// ~/.sift/stage.duckdb is a persisted, on-disk store both the Python and Swift engines can open
// during the Plan 5 transition. Pinned against engine/core/stage.py's CATALOG_DDL directly (not
// against Stage.swift's own catalogDDL), so a reordered column, changed type, or dropped
// PRIMARY KEY fails here even though it would pass every test that exists in either language.
@Test func catalogDDLPinsTheSharedSchemaColumnByColumn() {
    #expect(catalogDDL.contains("CREATE TABLE IF NOT EXISTS _sift_sources"))

    // In order, from CATALOG_DDL. One deliberate divergence from Python: the PRIMARY KEY is
    // `table_name`, not `source_token`. Two tabs of ONE file share a source token — `openPath`
    // derives `x_2` precisely so that flow works — so the old key made the second tab's row
    // REPLACE the first's, stranding a full copy in the store that no purge could reach while
    // `stagedTotalBytes()` kept counting it. Every other statement that touches this table already
    // keys on `table_name`. See SiftEngine's `migrateCatalog` for what an older store does.
    let expectedColumns = [
        "source_token VARCHAR",
        "path         VARCHAR",
        "mtime_ns     BIGINT",
        "size         BIGINT",
        "table_name   VARCHAR PRIMARY KEY",
        "fmt          VARCHAR",
        "staged_at    TIMESTAMP",
        "last_used    TIMESTAMP",
        "row_count    BIGINT",
        "bytes        BIGINT",
    ]
    #expect(catalogDDL.contains(expectedColumns.joined(separator: ",\n    ")))

    // Exactly one PRIMARY KEY, and (checked above) it is on table_name, not floated elsewhere.
    #expect(catalogDDL.components(separatedBy: "PRIMARY KEY").count == 2)
}
