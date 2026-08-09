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

    // Verbatim, in order, from CATALOG_DDL.
    let expectedColumns = [
        "source_token VARCHAR PRIMARY KEY",
        "path         VARCHAR",
        "mtime_ns     BIGINT",
        "size         BIGINT",
        "table_name   VARCHAR",
        "fmt          VARCHAR",
        "staged_at    TIMESTAMP",
        "last_used    TIMESTAMP",
        "row_count    BIGINT",
        "bytes        BIGINT",
    ]
    #expect(catalogDDL.contains(expectedColumns.joined(separator: ",\n    ")))

    // Exactly one PRIMARY KEY, and (checked above) it is on source_token, not floated elsewhere.
    #expect(catalogDDL.components(separatedBy: "PRIMARY KEY").count == 2)
}
