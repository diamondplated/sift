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

// MARK: - supplementary: the ragged-CSV collapse
//
// The real-sniffer half of the fix. SiftCoreTests/SourceTests.swift pins the pure rule against
// hand-built inputs; these feed DuckDB's actual sniffer the actual bytes, which is the only way to
// know that the collapse shape is what it produces and — much more importantly — that none of the
// legitimate one-column files trip it. A detector that fires on a healthy file is worse than no
// detector, because it teaches the reader to skip past notes.

/// A CSV written into its own temp directory. These fixtures are deliberately NOT in the shared
/// corpus: each one exists to be handed to the sniffer whole, and they are six lines apiece.
private func writeCSVFixture(_ name: String, _ text: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-ragged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private let raggedCSVText = """
    order_id,region,amount
    1,Midwest,10
    2,West,20
    3,South,30,EXTRA,FIELDS
    4,East,40
    5,North,50,BOOM
    6,West,60

    """

@Test func buildSourceNoticesWhenARaggedFileCollapsedIntoOneColumn() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: try writeCSVFixture("ragged.csv", raggedCSVText))

    // Still exactly what the sniffer said — the file is NOT quietly re-read behind the user's back.
    #expect(spec.columns.map(\.name) == ["order_id,region,amount"])
    #expect(spec.rowCount == 6)
    // ...but the collapse is now recorded, with the number null padding really gets back. Five,
    // not the header's three: row 3 carries two fields the header has no name for.
    #expect(spec.raggedColumns == 5)
    #expect(raggedCollapseNote(spec)?.contains("to see all 5") == true)
}

@Test func buildSourceNoticesTheCollapseWhateverTheRealDelimiterWas() throws {
    let con = try newConnection()
    // Semicolon, tab and pipe files all sniff as `,` when ragged (measured) — the opposite
    // fallback from the comma case above, and the reason the rule looks at what is left inside the
    // name rather than hard-coding which delimiter the sniffer runs away to.
    for (name, delim) in [("semi.csv", ";"), ("tab.csv", "\t"), ("pipe.csv", "|")] {
        let text = ["a", "b", "c"].joined(separator: delim) + "\n"
            + "1\(delim)2\(delim)3\n4\(delim)5\(delim)6\(delim)7\(delim)8\n9\(delim)10\(delim)11\n"
        let spec = try buildSource(con, path: try writeCSVFixture(name, text))
        #expect(spec.columns.count == 1, "\(name) did not collapse, so it tests nothing")
        #expect(spec.raggedColumns == 5, "\(name): recovered \(String(describing: spec.raggedColumns))")
    }
}

@Test func buildSourceStaysQuietOnEveryLegitimateSingleColumnFile() throws {
    let con = try newConnection()
    let healthy: [(String, String)] = [
        // Prose full of commas, quoted the way any real writer emits it.
        ("prose.csv", "note\n\"Hello, world\"\n\"Once upon a time, there was a file.\"\n"
            + "\"Commas, everywhere, really\"\n\"and, again, more\"\n\"yes, indeed\"\n"),
        // URLs carrying commas in their paths.
        ("urls.csv", "url\n\"https://example.com/a,b\"\n\"https://example.com/c,d\"\n"
            + "\"https://example.com/e,f\"\n\"https://example.com/g,h\"\n\"https://example.com/i,j\"\n"),
        // Quoted strings, nothing but.
        ("quoted.csv", "label\n\"alpha\"\n\"bravo\"\n\"charlie\"\n\"delta\"\n\"echo\"\n"),
        // A JSON document per row — commas, colons and braces inside one VARCHAR column.
        ("json.csv", "payload\n\"{\"\"a\"\": 1, \"\"b\"\": 2}\"\n\"{\"\"a\"\": 3, \"\"b\"\": 4}\"\n"
            + "\"{\"\"a\"\": 5, \"\"b\"\": 6}\"\n"),
        // 🔴 The one that decides the rule's shape: the HEADER itself contains a comma. DuckDB
        // sniffs `,` here, so the comma in the column name is the chosen delimiter — and a rule
        // that only asked "is there a delimiter in the name" would fire on a perfectly good file.
        ("names.csv", "\"Last, First\"\n\"Smith, John\"\n\"Doe, Jane\"\n\"Roe, Rich\"\n\"Poe, Edgar\"\n"),
        // Plain single column, no delimiter anywhere.
        ("plain.csv", "note\nalpha\nbeta\ngamma\ndelta\nepsilon\n"),
    ]
    for (name, text) in healthy {
        let spec = try buildSource(con, path: try writeCSVFixture(name, text))
        #expect(spec.columns.count == 1, "\(name) is not the one-column file this test needs")
        #expect(
            spec.raggedColumns == nil,
            "\(name) was wrongly reported as collapsed into \(spec.raggedColumns ?? 0) columns"
        )
        #expect(raggedCollapseNote(spec) == nil, "\(name) got a note it should not have")
    }
    // And a perfectly ordinary multi-column CSV, for the same reason.
    #expect(try buildSource(con, path: sharedData.cleanCSV).raggedColumns == nil)
}

@Test func nullPaddingIsTheWayOutAndItReallyRecoversTheColumns() throws {
    let con = try newConnection()
    let path = try writeCSVFixture("ragged.csv", raggedCSVText)
    let spec = try buildSource(con, path: path, nullPadding: true)

    #expect(spec.raggedColumns == nil, "a null-padded open reported itself collapsed")
    #expect(spec.columns.map(\.name) == ["order_id", "region", "amount", "column3", "column4"])
    // Baked into the spec, so every later query — the grid, the profile, the bad-cell scan —
    // reads the same five columns rather than re-deriving them.
    #expect(spec.readArgs["null_padding"] == .bool(true))
    // 🔴 MEASURED, DuckDB 1.5.5: an explicit `skip=0` DEFEATS null_padding — the sniffer returns to
    // the absent-delimiter fallback and the file collapses again. It reads as a no-op (it is the
    // sniffer's own answer handed back), which is exactly why it needs a test rather than a
    // comment: delete the `if !nullPadding` guard in buildSource and this line goes red.
    #expect(spec.readArgs["skip"] == nil)

    let rows = try con.query("SELECT * FROM \(readExpr(spec: spec))").allRows()
    try #require(rows.count == 6)
    // `#require`, not `#expect`, before indexing into a row: everything below reads columns 3 and
    // 4, and on a regression that puts the file back to one column those subscripts TRAP — which
    // in a parallel suite takes the whole runner down instead of failing one test. Measured while
    // mutation-testing this file, not theorised.
    try #require(rows.allSatisfy { $0.count == 5 })
    #expect(rows[2].map(\.display) == ["3", "South", "30", "EXTRA", "FIELDS"])
    // The two fields that had nowhere to live in the one-column read are NULL on the rows that
    // never had them — not empty strings, and not a dropped row.
    #expect(rows[0][3].isNull && rows[0][4].isNull)
    #expect(!rows[4][3].isNull && rows[4][4].isNull)

    // The all-varchar relation the bad-row scan reads has to survive the same option set —
    // it drops `columns=` and adds `all_varchar`, and null padding has to still apply.
    let raw = readExpr(spec: spec, allVarchar: true)
    #expect(try con.query("SELECT count(*) FROM \(raw)").allRows()[0][0] == .int(6))
    #expect(try describe(con, relationExpr: raw).count == 5)
}

@Test func nullPaddingLeavesAHealthyFileExactlyAsItWas() throws {
    // The option is an escape hatch, not a mode: asking for it on a file that never needed it must
    // not quietly reshape the file either.
    let con = try newConnection()
    let plain = try buildSource(con, path: sharedData.cleanCSV)
    let padded = try buildSource(con, path: sharedData.cleanCSV, nullPadding: true)
    #expect(padded.columns.map(\.name) == plain.columns.map(\.name))
    #expect(padded.columns.map(\.type) == plain.columns.map(\.type))
    #expect(padded.rowCount == plain.rowCount)
}

@Test func aFolderOfRaggedCSVsIsCaughtTheSameWayASingleOneIs() throws {
    // The sibling path, found by pointing the shipped CLI at a folder: `glob_csv` never sniffs at
    // all (it DESCRIBEs one member), so the single-file detection could not see it — and a folder
    // of daily exports where one day came out ragged is exactly how this reaches a real user.
    let con = try newConnection()
    let first = try writeCSVFixture(
        "a.csv", "order_id,region,amount\n1,Midwest,10\n2,West,20,EXTRA,FIELDS\n3,South,30\n"
    )
    let folder = (first as NSString).deletingLastPathComponent
    try "order_id,region,amount\n4,East,40\n5,North,50,BOOM\n6,West,60\n".write(
        toFile: (folder as NSString).appendingPathComponent("b.csv"), atomically: true, encoding: .utf8
    )

    let spec = try buildSource(con, path: folder)
    #expect(spec.fmt == .globCsv)
    #expect(spec.columns.map(\.name) == ["order_id,region,amount"])
    #expect(spec.raggedColumns == 5)
    // Worded for what actually happened: a folder collapses one file at a time.
    #expect(raggedCollapseNote(spec)?.contains("every file in the folder") == true)

    // And the same way out, on the same argument.
    let padded = try buildSource(con, path: folder, nullPadding: true)
    #expect(padded.raggedColumns == nil)
    #expect(padded.columns.map(\.name) == ["order_id", "region", "amount", "column3", "column4"])
    let rows = try con.query("SELECT * FROM \(readExpr(spec: padded))").allRows()
    try #require(rows.count == 6)
    // Five real columns plus the `filename` provenance column the folder read always appends —
    // which is why the note counts the FILES' columns and not the relation's.
    try #require(rows.allSatisfy { $0.count == 6 })
    #expect(rows[1].prefix(5).map(\.display) == ["2", "West", "20", "EXTRA", "FIELDS"])
    #expect(rows[4].prefix(5).map(\.display) == ["5", "North", "50", "BOOM", ""])
}

@Test func aHealthyFolderIsNotReportedAsCollapsed() throws {
    // The folder fixtures the rest of the suite uses are multi-column, so this builds the harder
    // case on purpose: a folder of legitimate ONE-column CSVs, which is the shape the new
    // single-column pre-filter waves through to the delimiter check.
    let con = try newConnection()
    let first = try writeCSVFixture("a.csv", "note\n\"Hello, world\"\n\"and, again\"\n")
    let folder = (first as NSString).deletingLastPathComponent
    try "note\n\"third, line\"\n\"fourth, line\"\n".write(
        toFile: (folder as NSString).appendingPathComponent("b.csv"), atomically: true, encoding: .utf8
    )
    let spec = try buildSource(con, path: folder)
    #expect(spec.columns.count == 1)
    #expect(spec.raggedColumns == nil)
    #expect(raggedCollapseNote(spec) == nil)
    // ...and the ordinary multi-column folder in the shared corpus stays quiet too.
    #expect(try buildSource(con, path: sharedData.hive).raggedColumns == nil)
}
