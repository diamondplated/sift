import Testing
import Foundation
import DuckDBKit
@testable import SiftCore

// Copy-as-code: pandas/polars/duckdb/sql snippets. Ported from engine/tests/test_snippet.py's
// 11 test functions (all 11 present below, one-to-one — none use @pytest.mark.parametrize).
//
// Every Python test builds its context via `_ctx`, which calls `S.build_source(con, path,
// sheet=...)` — connection-dependent and deferred to Plan 3 (see task-9-report.md's deferred
// checklist; the same situation SourceTests.swift/SheetsTests.swift already worked around). The
// function actually under test here, `snippet()`, takes a `SourceSpec`/`QuerySpec` it never
// mutates and never opens a connection itself, so each test below builds the SourceSpec by hand
// instead — via a live DESCRIBE against a freshly-written fixture, which is exactly what
// build_source's own branches do internally (parquet: DESCRIBE read_parquet(...); csv: sniff,
// which DuckDB's own auto-detecting read_csv DESCRIBE reproduces type-for-type; xlsx: DESCRIBE
// read_xlsx(...); delta: DESCRIBE delta_scan(...)). This keeps the assertions identical to
// Python's while sourcing real column types from DuckDB rather than guessing them.
//
// One assertion does NOT survive the port unchanged: test_filenames_with_quotes_are_escaped_
// per_dialect's Python original ends each dialect's loop with `compile(out, "<snippet>",
// "exec")`, using the live Python interpreter as a syntax oracle. Shipping that check here would
// give SiftCore's own test suite a runtime dependency on a Python interpreter being present —
// exactly the dependency this whole plan exists to remove (Plan 5 deletes the Python tree
// entirely; "Done when" in the plan doc requires SiftCore to import Foundation only). The
// f'"{spec.key.path}"' in out assertion (the actual substance of the test: the literal must stay
// intact) is ported verbatim below; the compile() check was instead run out-of-band against this
// exact generated output during development — see task-10-report.md for that transcript, which
// is the real proof no quote broke out of its string.
//
// Each test opens its own Database/Connection (never shared — DuckDBKit.Connection is documented
// non-Sendable and Swift Testing runs in parallel by default), matching every other file in this
// suite; no shared corpus needed since these fixtures are small and cheap to build per test.

private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-snippet-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// Mirrors source.py's `_describe`: `DESCRIBE SELECT * FROM <relation expr>`, decoded into the
/// same `Column` shape `build_source` would have produced.
private func describeColumns(_ con: Connection, _ relationExpr: String) throws -> [Column] {
    try con.query("DESCRIBE SELECT * FROM \(relationExpr)").allRows().map { row in
        guard case .text(let name) = row[0], case .text(let type) = row[1] else {
            preconditionFailure("DESCRIBE returned a non-text name/type cell")
        }
        return Column(name: name, type: type)
    }
}

private func colsDict(_ columns: [Column]) -> [String: Column] {
    Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
}

/// `dataclasses.replace(spec, key=dataclasses.replace(spec.key, size=...))` — SourceSpec has no
/// Swift `with`-mutator, so this rebuilds it field-for-field with only `size` changed.
private func withSize(_ spec: SourceSpec, _ size: Int) -> SourceSpec {
    SourceSpec(
        key: SourceKey(path: spec.key.path, mtimeNs: spec.key.mtimeNs, size: size), fmt: spec.fmt,
        readFn: spec.readFn, readArgs: spec.readArgs, columns: spec.columns, rowCount: spec.rowCount,
        rowEstimate: spec.rowEstimate, compressed: spec.compressed, sheet: spec.sheet,
        sheets: spec.sheets, deltaVersion: spec.deltaVersion, sniffPrompt: spec.sniffPrompt,
        glob: spec.glob
    )
}

private struct Ctx {
    let spec: SourceSpec
    let cols: [String: Column]
    let qs: QuerySpec
}

// MARK: - pyRepr regression table

// Every pair below is CPython-verified (task-10-report.md's differential section has the full
// 47-string sweep this is drawn from) — before this test, `pyRepr` had zero direct coverage
// anywhere in Tests/, only the indirect apostrophe-only and no-quote paths exercised by the
// dialect tests above. `both ' and "` is the load-bearing case: drop the backslash escape on the
// chosen quote character and this emits an UNTERMINATED string literal, not merely a
// wrong-but-valid one — and nothing else in this suite would have caught that.
@Test(arguments: [
    ("hello", "'hello'"),
    ("O'Brien", "\"O'Brien\""),
    ("say \"hi\"", "'say \"hi\"'"),
    ("both ' and \"", "'both \\' and \"'"),
    ("", "''"),
    ("tab\ttab", "'tab\\ttab'"),
    ("back\\slash", "'back\\\\slash'"),
    ("new\nline", "'new\\nline'"),
    ("carriage\rreturn", "'carriage\\rreturn'"),
    ("R&D", "'R&D'"),
    ("it's data.csv", "\"it's data.csv\""),
    ("nul:\u{0}:end", "'nul:\\x00:end'"),
    ("del:\u{7F}:end", "'del:\\x7f:end'"),
    ("nbsp:\u{A0}:end", "'nbsp:\\xa0:end'"),
    ("line-sep:\u{2028}:end", "'line-sep:\\u2028:end'"),
    ("para-sep:\u{2029}:end", "'para-sep:\\u2029:end'"),
    ("emoji: \u{1F600}", "'emoji: \u{1F600}'"),
    ("cjk: \u{6587}\u{5B57}\u{5217}", "'cjk: \u{6587}\u{5B57}\u{5217}'"),
    ("euro: \u{20AC}100", "'euro: \u{20AC}100'"),
] as [(String, String)])
private func pyReprMatchesCPython(input: String, expected: String) {
    #expect(pyRepr(input) == expected)
}

@Test func pyReprOnSQLValuePrimitives() {
    #expect(pyRepr(SQLValue.null) == "None")
    #expect(pyRepr(SQLValue.bool(true)) == "True")
    #expect(pyRepr(SQLValue.bool(false)) == "False")
    #expect(pyRepr(SQLValue.int(42)) == "42")
    #expect(pyRepr(SQLValue.double(1.5)) == "1.5")
    #expect(pyRepr(SQLValue.double(1.0)) == "1.0")
    #expect(pyRepr(SQLValue.text("O'Brien")) == "\"O'Brien\"")
}

/// Stands in for `_ctx(con, path)` on a CSV fixture: the args dict mirrors exactly what
/// `build_source`'s CSV branch always sets (delim/quote/escape/header/skip/ignore_errors/
/// allow_quoted_nulls), and the columns come from a live DESCRIBE of an auto-detecting
/// `read_csv` — the same DuckDB sniffer `sniff_csv` itself calls, so the inferred types match
/// what `build_source` would really have found.
private func csvCtx(_ con: Connection, path: String, delim: String = ",", size: Int = 0) throws -> Ctx {
    let cols = try describeColumns(con, "read_csv(\(qlit(path)), header=true, delim=\(qlit(delim)))")
    // quote/escape empty, not '"': none of these fixtures ever quote a field (makeCSV only
    // quotes with quoteNotes/emptiesEvery, neither used by any Snippet test), and MEASURED
    // against the real sniff_csv on this exact fixture shape — it reports Quote/Escape as
    // "(empty)" (source.py's SNIFF_EMPTY, normalized to "" by _unsniff) whenever no quoted field
    // appears in the sample. Hardcoding '"' here silently added a `quotechar=` pandas never
    // emits for a real clean.csv — caught by the differential check in task-10-report.md.
    let args: [String: ReadArg] = [
        "delim": .text(delim), "quote": .text(""), "escape": .text(""),
        "header": .bool(true), "skip": .int(0),
        "ignore_errors": .bool(true), "allow_quoted_nulls": .bool(false),
    ]
    let spec = SourceSpec(
        key: SourceKey(path: path, mtimeNs: 0, size: size), fmt: .csv, readFn: "read_csv",
        readArgs: args, columns: cols
    )
    return Ctx(spec: spec, cols: colsDict(cols), qs: QuerySpec(relation: "t"))
}

// MARK: - duckdb dialect

@Test func duckdbSnippetCarriesTheSniffedDialect() throws {
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "semi.csv", rows: 20, delim: ";")
    let ctx = try csvCtx(con, path: path, delim: ";")
    let out = try snippet(dialect: "duckdb", source: ctx.spec, spec: ctx.qs, cols: ctx.cols)
    #expect(out.contains("import duckdb"))
    #expect(out.contains("read_csv("))
    #expect(out.contains("delim=';'"), "a semicolon file must not be reproduced as comma-delimited")
    #expect(out.contains(path))
}

@Test func duckdbSnippetIsRunnableAsWritten() throws {
    // The strongest check available: execute the generated SQL and compare row counts.
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "clean.csv", rows: 1000)
    let ctx = try csvCtx(con, path: path)
    let qs = QuerySpec(relation: "t", filters: [Filter(col: "region", op: .inList, values: [.text("West")])])
    let out = try snippet(dialect: "duckdb", source: ctx.spec, spec: qs, cols: ctx.cols)
    let sql = out.components(separatedBy: "\"\"\"")[1]
    let n = try con.query("SELECT count(*) FROM (\(sql))").allRows()[0][0]
    let expected = try con.query(
        "SELECT count(*) FROM \(readExpr(spec: ctx.spec)) WHERE region = 'West'"
    ).allRows()[0][0]
    #expect(n == expected)
}

// MARK: - pandas dialect

@Test func pandasSnippetCarriesDtypesAndFilters() throws {
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "clean.csv", rows: 1000)
    let ctx = try csvCtx(con, path: path)
    let qs = QuerySpec(
        relation: "t",
        filters: [Filter(col: "region", op: .inList, values: [.text("West"), .text("South")])],
        sort: [QuerySpec.SortTerm(column: "order_id", direction: .desc)]
    )
    let out = try snippet(dialect: "pandas", source: ctx.spec, spec: qs, cols: ctx.cols)
    #expect(out.contains("import pandas as pd"))
    // Full string, not just "dtype=" presence — file-column order (order_id, region, amount,
    // note, matching clean.csv's real header), CPython-verified via task-10-report.md's
    // differential. A `.sorted(by:)` creeping back into pandasDtypes would still pass a
    // substring-only check; this is the regression guard for that.
    #expect(out.contains("dtype={'order_id': 'Int64', 'region': 'string', 'amount': 'float64', 'note': 'string'}"))
    #expect(out.contains(".isin(['West', 'South'])"))
    #expect(out.contains("sort_values('order_id', ascending=False)"))
}

@Test func pandasSnippetOrdersDtypesAndParseDatesByFileColumnOrderNotAlphabetically() throws {
    // No committed fixture has two+ temporal columns, so parse_dates ordering was untested on
    // both sides of the port (see task-10-report.md's review-fix section) — built by hand here.
    // Deliberately out-of-alphabetical-order names (zulu_when < mike_when < alpha_when would sort
    // the other way) so a `.sorted(by:)` regression in pandasDtypes fails this immediately.
    let fileCols = [
        Column(name: "zulu_when", type: "TIMESTAMP"),
        Column(name: "id", type: "BIGINT"),
        Column(name: "mike_when", type: "TIMESTAMP"),
        Column(name: "region", type: "VARCHAR"),
        Column(name: "alpha_when", type: "TIMESTAMP"),
    ]
    let spec = SourceSpec(
        key: SourceKey(path: "/tmp/three-temporal.csv", mtimeNs: 0, size: 0), fmt: .csv, readFn: "read_csv",
        columns: fileCols)
    let out = try snippet(dialect: "pandas", source: spec, spec: QuerySpec(relation: "t"), cols: colsDict(fileCols))
    #expect(out.contains("dtype={'id': 'Int64', 'region': 'string'}"))
    #expect(out.contains("parse_dates=['zulu_when', 'mike_when', 'alpha_when']"))
}

@Test func pandasWarnsAboutRAMOnABigTextSource() throws {
    let con = try Database.inMemory().connect()
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, name: "clean.csv", rows: 1000)
    let ctx = try csvCtx(con, path: path)
    // Pretend the file is large; the warning is driven by size, not by reading it.
    let big = withSize(ctx.spec, 4 * 1024 * 1024 * 1024)
    let out = try snippet(dialect: "pandas", source: big, spec: ctx.qs, cols: ctx.cols)
    #expect(out.contains("GB source") && out.contains("RAM"))
    #expect(out.contains("duckdb snippet streams"))

    // Parquet is memory-mapped and columnar, so no warning there.
    let ppath = try makeParquet(con: con, dir: dir, rows: 250)
    let pcols = try describeColumns(con, "read_parquet(\(qlit(ppath)))")
    let pspec = SourceSpec(
        key: SourceKey(path: ppath, mtimeNs: 0, size: 0), fmt: .parquet, readFn: "read_parquet",
        columns: pcols
    )
    let pOut = try snippet(dialect: "pandas", source: pspec, spec: QuerySpec(relation: "t"), cols: colsDict(pcols))
    #expect(!pOut.contains("RAM"))
}

// MARK: - polars dialect

@Test func polarsUsesALazyScanAndCollects() throws {
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "clean.csv", rows: 1000)
    let ctx = try csvCtx(con, path: path)
    let qs = QuerySpec(relation: "t", filters: [Filter(col: "amount", op: .ge, values: [.int(100)])])
    let out = try snippet(dialect: "polars", source: ctx.spec, spec: qs, cols: ctx.cols)
    #expect(out.contains("pl.scan_csv("))
    #expect(out.contains(".collect()"))
    #expect(out.contains("pl.col('amount') >= 100"))
}

@Test func polarsParquetUsesScanParquet() throws {
    let con = try Database.inMemory().connect()
    let dir = try tempDir()
    let path = try makeParquet(con: con, dir: dir, rows: 250)
    let cols = try describeColumns(con, "read_parquet(\(qlit(path)))")
    let spec = SourceSpec(
        key: SourceKey(path: path, mtimeNs: 0, size: 0), fmt: .parquet, readFn: "read_parquet", columns: cols
    )
    let out = try snippet(dialect: "polars", source: spec, spec: QuerySpec(relation: "t"), cols: colsDict(cols))
    #expect(out.contains("pl.scan_parquet("))
}

// MARK: - delta

@Test(.enabled(if: extensionIsAvailable("delta"), "delta extension not installed on this machine"))
func deltaSnippetsLoadTheExtension() throws {
    let db = try Database.inMemory()
    db.loadExtensions(["delta"])
    let con = try db.connect()
    let root = try makeDelta(con: con, dir: try tempDir(), kept: 100, tombstoned: 50)
    let cols = try describeColumns(con, "delta_scan(\(qlit(root)))")
    let spec = SourceSpec(
        key: SourceKey(path: root, mtimeNs: 0, size: 0), fmt: .delta, readFn: "delta_scan",
        columns: cols, deltaVersion: deltaVersion(root)
    )
    let qs = QuerySpec(relation: "t")
    let cd = colsDict(cols)

    let duck = try snippet(dialect: "duckdb", source: spec, spec: qs, cols: cd)
    #expect(duck.contains("INSTALL delta") && duck.contains("delta_scan("))

    // pandas has no Delta reader without an extra package, so say so rather than emit broken code.
    let pdOut = try snippet(dialect: "pandas", source: spec, spec: qs, cols: cd)
    #expect(pdOut.contains("deltalake"))
}

// MARK: - xlsx

@Test(.enabled(if: extensionIsAvailable("excel"), "excel extension not installed on this machine"))
func xlsxSnippetNamesTheSheet() throws {
    let db = try Database.inMemory()
    db.loadExtensions(["excel"])
    let con = try db.connect()
    let path = bundledXLSXPath("book")
    let sheet = "By Store"
    let cols = try describeColumns(con, "read_xlsx(\(qlit(path)), sheet=\(qlit(sheet)))")
    let sheets = try listSheets(path: path)
    let spec = SourceSpec(
        key: SourceKey(path: path, mtimeNs: 0, size: 0), fmt: .xlsx, readFn: "read_xlsx",
        readArgs: ["sheet": .text(sheet)], columns: cols, sheet: sheet, sheets: sheets
    )
    let qs = QuerySpec(relation: "t")
    let cd = colsDict(cols)

    let duck = try snippet(dialect: "duckdb", source: spec, spec: qs, cols: cd)
    #expect(duck.contains("read_xlsx(") && duck.contains("By Store"))

    let pdOut = try snippet(dialect: "pandas", source: spec, spec: qs, cols: cd)
    #expect(pdOut.contains("sheet_name='By Store'"))
}

// MARK: - sql dialect

@Test func sqlDialectIsTheRenderedSQL() throws {
    // The sql dialect only ever touches spec/cols — source is unused, so a minimal stand-in
    // (no file, no connection) exercises exactly what render_sql does.
    let key = SourceKey(path: "/dev/null", mtimeNs: 0, size: 0)
    let spec = SourceSpec(key: key, fmt: .csv, readFn: "read_csv")
    let qs = QuerySpec(relation: "sales", filters: [Filter(col: "region", op: .eq, values: [.text("West")])])
    let out = try snippet(dialect: "sql", source: spec, spec: qs, cols: [:])
    #expect(out.hasPrefix("SELECT *"))
    #expect(out.contains("\"sales\""))
}

@Test func sqlOverrideWinsAndIsFlagged() throws {
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "clean.csv", rows: 1000)
    let ctx = try csvCtx(con, path: path)
    let override = "SELECT region, count(*) FROM sales GROUP BY 1"

    #expect(try snippet(dialect: "sql", source: ctx.spec, spec: ctx.qs, cols: ctx.cols, sqlOverride: override) == override)
    #expect(try snippet(dialect: "duckdb", source: ctx.spec, spec: ctx.qs, cols: ctx.cols, sqlOverride: override)
        .contains(override))
    // pandas cannot express arbitrary SQL, so it must say so instead of lying.
    #expect(try snippet(dialect: "pandas", source: ctx.spec, spec: ctx.qs, cols: ctx.cols, sqlOverride: override)
        .contains("cannot express arbitrary SQL"))
}

// MARK: - quoted filenames

@Test func filenamesWithQuotesAreEscapedPerDialect() throws {
    // An apostrophe in a filename must not break out of the generated string literal.
    let con = try Database.inMemory().connect()
    let path = try makeCSV(dir: try tempDir(), name: "it's data.csv", rows: 10)
    let ctx = try csvCtx(con, path: path)

    // SQL doubles the quote, and the result must still parse and read the file.
    let duck = try snippet(dialect: "duckdb", source: ctx.spec, spec: ctx.qs, cols: ctx.cols)
    #expect(duck.contains("it''s data.csv"))
    let sql = duck.components(separatedBy: "\"\"\"")[1]
    let n = try con.query("SELECT count(*) FROM (\(sql))").allRows()[0][0]
    #expect(n == .int(10))

    // Python's repr switches to double quotes for a string containing an apostrophe, so the
    // whole path lands inside one intact literal. (Python's original also calls compile(out,
    // "<snippet>", "exec") here as a live syntax check — see this file's header comment for why
    // that's verified out-of-band instead of shipped as a test-time Python dependency.)
    for dialect in ["pandas", "polars"] {
        let out = try snippet(dialect: dialect, source: ctx.spec, spec: ctx.qs, cols: ctx.cols)
        #expect(out.contains("\"\(ctx.spec.key.path)\""), "\(out)")
    }
}
