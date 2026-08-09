import Foundation
import Testing
@testable import DuckDBKit

/// Re-verification of the nine DuckDB 1.5.5 behaviors AGENTS.md pins, measured against
/// libduckdb rather than the Python wheel. A failure here is not a test bug — it means
/// the engine changed and the design must change with it.
private func con() throws -> Connection {
    let db = try Database.inMemory()
    db.harden()
    return try db.connect()
}

private func tempCSV(_ contents: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-fact-\(UUID().uuidString).csv")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

@Test func fact1_theSniffEmptySentinelCannotBeFedBackIntoReadCsv() throws {
    // The measured oddity: sniff_csv reports an ABSENT quote/escape/comment as the
    // literal 8-character string "(empty)", and passing that straight back into
    // read_csv fails with "the quote option cannot exceed a size of 1 byte".
    // core/source.py's SNIFF_EMPTY normalization exists solely because of this.
    //
    // Asserting the failure is the deterministic half of the fact. Asserting what
    // sniff_csv *returns* is not: for a file with no quote characters the sniffer may
    // still report its default quote, so that direction would be a coin flip dressed
    // up as a test.
    let path = try tempCSV("a,b\n1,2\n")
    let c = try con()

    #expect(throws: DuckDBError.self) {
        _ = try c.query("SELECT * FROM read_csv('\(path)', header=true, quote='(empty)')")
    }
    // The normalized form — what core/source.py actually sends — must work.
    _ = try c.query("SELECT * FROM read_csv('\(path)', header=true, quote='')").allRows()
}

@Test func fact2_rejectScansAndRejectErrorsDoNotExist() throws {
    let c = try con()
    #expect(throws: DuckDBError.self) { _ = try c.query("SELECT * FROM reject_scans()") }
    #expect(throws: DuckDBError.self) { _ = try c.query("SELECT * FROM reject_errors()") }
}

@Test func fact3_countStarOnACsvViewDisagreesWithSelectStar() throws {
    // With an uncastable value present, count(*) is answered by projection pushdown
    // without parsing any column, so it reports the PHYSICAL count while SELECT *
    // returns fewer rows. This is why exact counts run against the all-varchar relation.
    let path = try tempCSV("n\n1\n2\nnot_a_number\n4\n")
    let c = try con()
    let read = "read_csv('\(path)', columns={'n': 'INTEGER'}, header=true, ignore_errors=true)"
    let counted = try c.query("SELECT count(*) FROM \(read)").allRows()[0][0]
    let selected = try c.query("SELECT * FROM \(read)").allRows().count
    #expect(counted == .int(4))
    #expect(selected == 3)
}

// fact4 (read_xlsx takes `sheet =>`, not `sheet_name`) and fact6 (Delta time travel is
// `version => n`; `AT (VERSION => n)` does not parse) are NOT tested here. Both need a
// real .xlsx and a real Delta table, and this plan has no such fixtures — a version
// pointed at a nonexistent path throws for the missing file, so the test would pass
// whether or not the behavior still holds. A test that passes for the wrong reason is
// worse than no test. Both land in Plan 2, where the fixtures exist.

@Test func fact5_timestampWithTimeZoneRoundTrips() throws {
    // In Python this needs pytz or it raises. Through the C API there is no Python
    // dependency at all, so this must simply work — the pytz pin disappears with it.
    let c = try con()
    try c.execute("SET TimeZone='UTC'")
    let v = try c.query("SELECT TIMESTAMPTZ '2026-08-09 12:00:00+00'").allRows()[0][0]
    #expect(v != .null)
}

@Test func fact7_allowQuotedNullsFalseKeepsEmptyStringDistinctFromNull() throws {
    // The distinction the whole tool exists to show:
    //   ,,   -> NULL   (nothing there)
    //   ,"", -> ''     (an empty string, written deliberately)
    let path = try tempCSV("a,b,c\n1,,2\n3,\"\",4\n")
    let rows = try con().query(
        "SELECT b FROM read_csv('\(path)', header=true, allow_quoted_nulls=false, all_varchar=true)"
    ).allRows()
    #expect(rows[0][0] == .null)
    #expect(rows[1][0] == .text(""))
}

@Test func fact8_approxCountDistinctIsAnEstimate() throws {
    // MEASURED against libduckdb 1.5.5 via the C API: approx_count_distinct(range(300))
    // reports 340 for 300 distinct values — the same overshoot as the Python-wheel
    // measurement AGENTS.md pins. HyperLogLog is an estimate and can overshoot the true
    // count, which is why core/profile.py clamps it to the exact count — this test pins
    // that the overshoot (and therefore the need for the clamp) still holds.
    let rows = try con().query(
        "SELECT approx_count_distinct(i), count(*) FROM range(300) AS t(i)"
    ).allRows()
    guard case .int(let approx) = rows[0][0], case .int(let exact) = rows[0][1] else {
        Issue.record("expected two integers"); return
    }
    #expect(exact == 300)
    #expect(approx == 340)
}

@Test func fact9_duckdbTablesEstimatedSizeIsRowsNotBytes() throws {
    // It produced a "3,000,048 B" reading for a 3M-row table until this was caught,
    // which is why staged bytes are measured as growth of stage.duckdb instead.
    let c = try con()
    try c.execute("CREATE TABLE big AS SELECT i FROM range(100000) AS t(i)")
    let v = try c.query(
        "SELECT estimated_size FROM duckdb_tables() WHERE table_name = 'big'"
    ).allRows()[0][0]
    guard case .int(let n) = v else { Issue.record("expected an integer"); return }
    // Rows, not bytes: 100k rows of BIGINT would be ~800 KB if it were bytes.
    #expect(n < 200_000)
}

@Test func theSelectOnlyWrapRejectsNonSelectsAtParseTime() throws {
    // Not one of the nine, but the security property that depends on the same parser.
    // The NEWLINES are load-bearing: the flat form rejects a legitimate trailing comment.
    let c = try con()
    func wrapped(_ sql: String) -> String { "SELECT * FROM (\n\(sql)\n) AS _q\nLIMIT 10 OFFSET 0" }

    _ = try c.query(wrapped("select 1 -- a trailing comment"))   // must succeed

    for dangerous in ["DROP TABLE t", "ATTACH 'x.db'", "PRAGMA version",
                      "SET memory_limit='1GB'", "SELECT 1; DROP TABLE t"] {
        #expect(throws: DuckDBError.self) { _ = try c.query(wrapped(dangerous)) }
    }
}
