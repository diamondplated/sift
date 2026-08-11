import Foundation
import Testing
import TestSupport
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
    let path = TestTemp.path("fact", ".csv")
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Test func fact1_theSniffEmptySentinelCannotBeFedBackIntoReadCsv() throws {
    // The measured oddity: sniff_csv reports an ABSENT quote/escape/comment as the
    // literal 7-character string "(empty)", and passing that straight back into
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

/// `Bundle.module` isn't visible from this target (only SiftCoreTests has the `resources:`
/// copy of Tests/SiftCoreTests/Fixtures in Package.swift, and this file may only be appended
/// to, not have Package.swift edited to add a second copy). `#filePath` is this file's own
/// absolute source path at compile time, which `swift test` preserves regardless of process
/// cwd — two `deletingLastPathComponent()` calls walk DuckDBKitTests/ up to Tests/, then back
/// down into the sibling SiftCoreTests/Fixtures/ the golden workbook actually lives in.
private func siftCoreTestsFixture(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SiftCoreTests/Fixtures/\(name)").path
}

/// Mirrors Tests/SiftCoreTests/Fixtures.swift's `extensionIsAvailable` (that one isn't visible
/// from this target either — test targets don't export to one another in SwiftPM).
private func extensionIsAvailable(_ name: String) -> Bool {
    guard let db = try? Database.inMemory() else { return false }
    db.loadExtensions([name])
    return db.loadedExtensions[name] == true
}

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func fact4_readXlsxTakesSheetArrowNotSheetName() throws {
    // MEASURED against libduckdb 1.5.5: read_xlsx's sheet-selection keyword is `sheet`, not
    // pandas' familiar `sheet_name` — core/source.py's build_source sets `read_args["sheet"]`
    // because of exactly this. Using the committed book.xlsx (not a nonexistent path) so this
    // fails for the right reason if the keyword ever changes, not because the file is missing.
    let path = siftCoreTestsFixture("book.xlsx")
    let db = try Database.inMemory()
    db.harden()
    db.loadExtensions(["excel"])
    let c = try db.connect()

    let rows = try c.query("SELECT count(*) FROM read_xlsx('\(path)', sheet => 'By Store')").allRows()
    guard case .int(let n) = rows[0][0] else { Issue.record("expected an integer"); return }
    #expect(n == 50)   // 51 rows minus the header

    #expect(throws: DuckDBError.self) {
        _ = try c.query("SELECT count(*) FROM read_xlsx('\(path)', sheet_name='By Store')")
    }
}

@Test func fact5_timestampWithTimeZoneNeedsNoPytz() throws {
    // In the Python engine this is a hard dependency: without pytz, fetching ANY
    // TIMESTAMP WITH TIME ZONE raises "Required module 'pytz' failed to import".
    // Through the C API there is no Python in the picture at all, so the pinned
    // pytz dependency disappears with the rewrite. This test is what proves it.
    let c = try con()
    try c.execute("SET TimeZone='UTC'")
    let v = try c.query("SELECT TIMESTAMPTZ '2026-08-09 12:00:00+00'").allRows()[0][0]
    #expect(v == .text("2026-08-09T12:00:00+00:00"))
}

private func fact6JSONString(_ obj: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? ""
}

private func fact6JSONLine(_ obj: [String: Any]) throws -> String {
    try fact6JSONString(obj) + "\n"
}

/// A minimal, real two-version Delta table: version 0 adds two parquet files, version 1
/// tombstones one of them (which stays physically present on disk — that's the whole point).
/// A trimmed, single-target copy of Tests/SiftCoreTests/Fixtures.swift's `makeDelta` (not
/// reusable directly: SwiftPM test targets don't export to one another, and this file may only
/// be appended to, not have Package.swift edited to add a cross-target dependency).
private func makeDeltaFixture(con: Connection, dir: String, kept: Int = 100, tombstoned: Int = 50) throws -> String {
    let root = (dir as NSString).appendingPathComponent("dtable")
    let logDir = (root as NSString).appendingPathComponent("_delta_log")
    try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    func entryPath(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    let part0 = "part-0.parquet"
    let part1 = "part-1.parquet"
    try con.execute(
        "COPY (SELECT range AS id, 'a' AS g FROM range(\(kept))) TO '\(entryPath(part0))' (FORMAT parquet)")
    try con.execute(
        "COPY (SELECT range AS id, 'b' AS g FROM range(\(kept), \(kept + tombstoned))) "
            + "TO '\(entryPath(part1))' (FORMAT parquet)")

    func fileSize(_ name: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: entryPath(name))
        return (attrs[.size] as? Int) ?? 0
    }

    let ms = 1_770_000_000_000
    let schemaString = try fact6JSONString([
        "type": "struct",
        "fields": [
            ["name": "id", "type": "long", "nullable": true, "metadata": [String: Any]()],
            ["name": "g", "type": "string", "nullable": true, "metadata": [String: Any]()],
        ],
    ])

    var log0 = try fact6JSONLine(["protocol": ["minReaderVersion": 1, "minWriterVersion": 2]])
    log0 += try fact6JSONLine(["metaData": [
        "id": UUID().uuidString.lowercased(),
        "format": ["provider": "parquet", "options": [String: Any]()],
        "schemaString": schemaString,
        "partitionColumns": [String](),
        "configuration": [String: Any](),
        "createdTime": ms,
    ]])
    for part in [part0, part1] {
        log0 += try fact6JSONLine(["add": [
            "path": part, "partitionValues": [String: Any](), "size": try fileSize(part),
            "modificationTime": ms, "dataChange": true,
        ]])
    }
    try log0.write(
        toFile: (logDir as NSString).appendingPathComponent("00000000000000000000.json"),
        atomically: true, encoding: .utf8)

    let log1 = try fact6JSONLine(["remove": [
        "path": part1, "deletionTimestamp": ms + 1000,
        "dataChange": true, "partitionValues": [String: Any](),
        "size": try fileSize(part1),
    ]])
    try log1.write(
        toFile: (logDir as NSString).appendingPathComponent("00000000000000000001.json"),
        atomically: true, encoding: .utf8)

    return root
}

@Test(.enabled(if: extensionIsAvailable("delta"), "duckdb delta extension not installed"))
func fact6_deltaTimeTravelUsesVersionArrowNotAtVersion() throws {
    // MEASURED against libduckdb 1.5.5: `delta_scan(path, version => n)` parses and works;
    // `delta_scan(path, AT (VERSION => n))` — the syntax DuckDB's own SQL-standard AT clause
    // uses for other table functions — does not parse against delta_scan. core/source.py's
    // read_expr_at is built around exactly this.
    let dir = TestTemp.dir("fact6")
    let db = try Database.inMemory()
    db.harden()
    db.loadExtensions(["delta"])
    let c = try db.connect()
    let root = try makeDeltaFixture(con: c, dir: dir, kept: 100, tombstoned: 50)

    // version => n works, and honors the tombstone (100 kept, not the 150 a raw glob would see).
    let versioned = try c.query("SELECT count(*) FROM delta_scan('\(root)', version => 1)").allRows()[0][0]
    #expect(versioned == .int(100))

    // version => 0 is the assertion that actually proves time travel SELECTS a different
    // version rather than merely parsing and being ignored: 100 == 100 above is consistent
    // with either. Before the remove in version 1, both parquet files were live, so version 0
    // must see all 150 rows — the tombstoned-but-still-on-disk row count, same number a raw
    // glob would report.
    let atVersionZero = try c.query("SELECT count(*) FROM delta_scan('\(root)', version => 0)").allRows()[0][0]
    #expect(atVersionZero == .int(150), "version => 0 must predate the tombstone and see both files")

    let scanned = try c.query("SELECT count(*) FROM delta_scan('\(root)')").allRows()[0][0]
    #expect(scanned == .int(100), "delta_scan must honor the tombstone, not the raw 150")

    #expect(throws: DuckDBError.self) {
        _ = try c.query("SELECT count(*) FROM delta_scan('\(root)', AT (VERSION => 0))")
    }
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
