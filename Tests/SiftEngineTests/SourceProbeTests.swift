import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// The connection-needing half of engine/tests/test_source.py and test_sheets.py: the 13 + 3
// tests Plan 2 deferred (named in Tests/SiftCoreTests/SourceTests.swift:10-18 and
// SheetsTests.swift:7-10), because `sniff_csv`, `build_source`, `_describe` and `exact_count`
// all need a live DuckDB connection. Everything else in those two Python files already ported in
// Plan 2 — this file only closes the gap.
//
// Each test opens its own Connection (Connection is deliberately not Sendable, and Swift Testing
// runs tests in parallel), but the fixture corpus is built once and shared read-only.

private let sharedData = try! corpus()

private func newConnection(extensions: [String] = []) throws -> Connection {
    let db = try Database.inMemory()
    db.loadExtensions(extensions)
    return try db.connect()
}

// MARK: - sniff_csv

@Test func sniffNormalizesTheEmptySentinel() throws {
    // sniff_csv reports an absent quote/escape as the literal string "(empty)". Feeding that
    // back into read_csv fails with "cannot exceed a size of 1 byte", so it must be normalized
    // to "" — the bug that would otherwise break every unquoted CSV.
    let con = try newConnection()
    let sn = try sniffCSV(con, path: sharedData.cleanCSV)
    #expect(sn.quote != "(empty)")
    #expect(sn.escape != "(empty)")
    #expect(sn.comment != "(empty)")
    #expect(sn.delim == ",")
    #expect(sn.header == true)
}

@Test func sniffFindsASemicolonDelimiter() throws {
    let con = try newConnection()
    #expect(try sniffCSV(con, path: sharedData.semiCSV).delim == ";")
}

@Test func sniffSkipsAJunkPreamble() throws {
    let con = try newConnection()
    let sn = try sniffCSV(con, path: sharedData.weirdCSV)
    #expect(sn.skip == 3)
    #expect(sn.columns.prefix(2).map(\.name) == ["order_id", "region"])
}

// MARK: - build_source: CSV

@Test func buildSourceCSVBakesExplicitOptions() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.cleanCSV)
    #expect(spec.fmt == .csv)
    #expect(spec.readFn == "read_csv")
    // Stands in for Python's `"columns" in spec.read_args`: readArgs structurally cannot carry a
    // "columns" key (see Types.swift's ReadArg LANDMINE) — the ordered spec.columns array is the
    // Swift equivalent, and readExpr renders `columns={...}` from it directly.
    #expect(!spec.columns.isEmpty)   // types pinned, so later queries never re-sniff
    #expect(spec.readArgs["ignore_errors"] == .bool(true))
    let expr = readExpr(spec: spec)
    #expect(expr.hasPrefix("read_csv("))
    let n = try con.query("SELECT count(*) FROM \(expr)").allRows()[0][0]
    #expect(n == .int(1000))
}

@Test func buildSourceGivesSmallCSVsAnExactCount() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.cleanCSV)
    #expect(spec.rowCount == 1000)
    #expect(spec.rowEstimate == nil)   // no need to guess at this size
}

@Test func quotedNewlinesDoNotInflateTheCount() throws {
    // Line counting overshoots when a quoted field contains a newline; an exact count must not.
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.quotedNLCSV)
    #expect(spec.rowCount == 400)
}

@Test func compressedCSVGetsNeitherCountNorEstimate() throws {
    // Compressed bytes say nothing about row count, so the UI shows "counting…" rather than a
    // fabricated number.
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.gzCSV)
    #expect(spec.compressed == true)
    #expect(spec.rowEstimate == nil)
    #expect(spec.rowCount == nil)
    let n = try con.query("SELECT count(*) FROM \(readExpr(spec: spec))").allRows()[0][0]
    #expect(n == .int(500))
}

@Test func allVarcharRelationDropsTheColumnTypes() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.dirtyCSV)
    let raw = readExpr(spec: spec, allVarchar: true)
    #expect(raw.contains("all_varchar=true"))
    #expect(!raw.contains("columns="))
    let types = try con.query("DESCRIBE SELECT * FROM \(raw)").allRows().compactMap { row -> String? in
        guard case .text(let t) = row[1] else { return nil }
        return t
    }
    #expect(Set(types) == ["VARCHAR"])
}

@Test func exactCountUsesThePhysicalRelation() throws {
    // count(*) on the typed relation is answered by projection pushdown without parsing
    // anything. With an uncastable value present that makes it disagree with what SELECT *
    // returns, so exact_count must go through the all-varchar relation.
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.dirtyCSV)
    #expect(try exactCount(con, spec: spec) == 1000)
}

// MARK: - build_source: parquet

@Test func parquetRowCountIsFreeAndExact() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.parquet)
    #expect(spec.rowCount == 1000)
    #expect(spec.fmt == .parquet)
}

@Test func supportsAllVarcharOnlyForTextFormats() throws {
    let con = try newConnection()
    #expect(supportsAllVarchar(try buildSource(con, path: sharedData.cleanCSV)))
    // Parquet carries real types, so there is no sniffing to get wrong and no reject count to
    // compute.
    #expect(!supportsAllVarchar(try buildSource(con, path: sharedData.parquet)))
}

// MARK: - build_source: hive glob

@Test func buildSourceHiveSetsPartitioningAndProvenance() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.hive)
    #expect(spec.fmt == .globParquet)
    #expect(spec.readArgs["hive_partitioning"] == .bool(true))
    #expect(spec.readArgs["union_by_name"] == .bool(true))
    #expect(spec.readArgs["filename"] == .bool(true))   // answers "which file has the bad row"
    let names = try describe(con, relationExpr: readExpr(spec: spec)).map(\.name)
    #expect(names.contains("dt") && names.contains("region") && names.contains("filename"))
}

// MARK: - header_byte_offset

@Test func headerByteOffsetCountsPreambleAndHeader() throws {
    let con = try newConnection()
    let sn = try sniffCSV(con, path: sharedData.weirdCSV)
    let off = try headerByteOffset(path: sharedData.weirdCSV, sniff: SniffHints(skip: sn.skip, header: sn.header))
    #expect(off > 0)
    let head = try Data(contentsOf: URL(fileURLWithPath: sharedData.weirdCSV)).prefix(off)
    #expect(head.filter { $0 == 0x0A }.count == 4)   // 3 junk lines + the header
}

// MARK: - build_source: xlsx (test_sheets.py)

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func defaultSheetIsTheFirstNonEmpty() throws {
    let con = try newConnection(extensions: ["excel"])
    let spec = try buildSource(con, path: siftCoreTestsFixture("book.xlsx"))
    #expect(spec.sheet == "Summary")
    #expect(spec.fmt == .xlsx)
    #expect(spec.sheets.count == 3)
}

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func aNamedSheetCanBeOpened() throws {
    let con = try newConnection(extensions: ["excel"])
    let spec = try buildSource(con, path: siftCoreTestsFixture("book.xlsx"), sheet: "By Store")
    #expect(spec.sheet == "By Store")
    #expect(spec.readArgs["sheet"] == .text("By Store"))   // `sheet`, not `sheet_name`
    let n = try con.query("SELECT count(*) FROM \(readExpr(spec: spec))").allRows()[0][0]
    #expect(n == .int(50))   // 51 rows minus the header
}

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func sheetNamesWithQuotesDoNotBreakTheExpression() throws {
    // Python's original generates a workbook on the fly with openpyxl (unavailable here); the
    // committed odd.xlsx fixture is exactly that shape — one sheet named `it's a sheet`, 2 rows
    // by 1 col — see Tests/SiftCoreTests/Fixtures/README.md.
    let con = try newConnection(extensions: ["excel"])
    let spec = try buildSource(con, path: siftCoreTestsFixture("odd.xlsx"), sheet: "it's a sheet")
    let n = try con.query("SELECT count(*) FROM \(readExpr(spec: spec))").allRows()[0][0]
    #expect(n == .int(1))
}

// MARK: - supplementary: build_source: ndjson
//
// Not a port — no test in engine/tests/** exercises build_source's json/ndjson branch through a
// live connection (test_source.py's ndjson coverage stops at detect_format). Added per the
// "leave one runnable check" rule: the branch is real code with a real cast/count path.

@Test func buildSourceNdjsonGetsAnExactCount() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.ndjson)
    #expect(spec.fmt == .ndjson)
    #expect(spec.readFn == "read_json_auto")
    #expect(spec.compressed == false)
    #expect(spec.rowCount == 200)
    let n = try con.query("SELECT count(*) FROM \(readExpr(spec: spec))").allRows()[0][0]
    #expect(n == .int(200))
}
