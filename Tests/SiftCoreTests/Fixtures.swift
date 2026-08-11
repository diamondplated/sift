import Testing
import DuckDBKit
import Foundation
import TestSupport
@testable import SiftCore

// Fixture builders, ported from engine/tests/fixtures.py and engine/tests/conftest.py.
//
// Almost everything is generated rather than committed: the pathological cases are easier to
// read as code than as bytes, and a generated corpus keeps the repo clean and the suite fast.
// The two xlsx workbooks are the deliberate exception — see Fixtures/README.md.
//
// Every knob on `makeCSV` maps to a failure mode Sift exists to survive: a value that will not
// cast, a quoted field containing a newline (which breaks byte-sample row estimation), a BOM,
// junk preamble lines above the header, ragged rows, and the three flavours of missing (NULL,
// a quoted empty string, and a "nullish" sentinel like "N/A"). Later tasks depend on each.

/// A stable timestamp, matching fixtures.py's `FIXED_MS`. `Date()`-style nondeterminism in
/// fixtures makes failures unreproducible.
let FIXED_MS = 1_770_000_000_000

private func join(_ dir: String, _ name: String) -> String {
    URL(fileURLWithPath: dir).appendingPathComponent(name).path
}

/// Still `throws` so the ~20 `try tempDir()` call sites below stay untouched — `TestTemp.dir`
/// treats a temp directory it cannot create as fatal, not as one test's failure.
private func tempDir() throws -> String { TestTemp.dir("fixtures") }

/// Opens a throwaway in-memory database and tries to load `name`, tolerating failure exactly
/// like conftest.py's session `con` fixture: a machine without network access on first run
/// cannot INSTALL a missing extension, and that must not look like a code defect. Cheap enough
/// to call directly from a `.enabled(if:)` trait.
func extensionIsAvailable(_ name: String) -> Bool {
    guard let db = try? Database.inMemory() else { return false }
    db.loadExtensions([name])
    return db.loadedExtensions[name] == true
}

// MARK: - CSV

/// Write a CSV and return its path.
///
/// The knobs map to the failure modes this tool exists to survive: a value that won't cast, a
/// quoted field containing a newline, a BOM, junk preamble lines above the header, and ragged
/// rows. Ported line-for-line from fixtures.py's `make_csv`, including the order in which
/// `nullsEvery` / `emptiesEvery` / `nullishEvery` can overwrite one another on the same row.
func makeCSV(
    dir: String, name: String = "sales.csv", rows: Int = 1000, delim: String = ",",
    crlf: Bool = false, bom: Bool = false, preamble: Int = 0, header: Bool = true,
    ragged: Bool = false, badIntRow: Int? = nil, quoteNotes: Bool = false,
    quotedNewlineRow: Int? = nil, nullsEvery: Int? = nil, emptiesEvery: Int? = nil,
    nullishEvery: Int? = nil
) throws -> String {
    let path = join(dir, name)
    let eol = crlf ? "\r\n" : "\n"
    let regions = ["West", "Midwest", "South", "Northeast"]

    var out = ""
    if bom { out += "\u{FEFF}" }
    for i in 0..<preamble {
        out += "# generated file, junk line \(i)\(eol)"
    }
    if header {
        out += ["order_id", "region", "amount", "note"].joined(separator: delim) + eol
    }
    for i in 0..<rows {
        var region = regions[i % regions.count]
        // `ne != 0` guards match Python's `n and i % n == 0`, which short-circuits on a falsy
        // (zero) `n` and treats 0 as "disabled" rather than computing `i % 0`. Unreachable via
        // any fixture built by this file today, but `i % 0` traps in Swift where Python's `%`
        // would too were it ever reached — the guard is what makes 0 behave as documented
        // ("disabled") instead of as a crash for the next caller who passes it.
        if let ne = nullsEvery, ne != 0, i % ne == 0 { region = "" }   // unquoted empty reads as NULL
        var amount = "\(i).50"
        if let bir = badIntRow, i == bir { amount = "N/A" }
        var note = "note \(i)"
        if let ee = emptiesEvery, ee != 0, i % ee == 0 { note = "\"\"" }   // quoted empty, distinct from NULL
        if let nie = nullishEvery, nie != 0, i % nie == 0 { note = "N/A" }
        if quoteNotes { note = "\"\(note)\"" }
        if let qnr = quotedNewlineRow, i == qnr { note = "\"line one\(eol)line two\"" }
        var fields = [String(i), region, amount, note]
        if ragged && i % 97 == 0 { fields = Array(fields.prefix(2)) }
        out += fields.joined(separator: delim) + eol
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - Parquet / hive / delta (written by DuckDB itself)

func makeParquet(con: Connection, dir: String, name: String = "t.parquet", rows: Int = 1000) throws -> String {
    let path = join(dir, name)
    try con.execute(
        "COPY (SELECT range AS order_id, "
            + "['West','Midwest','South','Northeast'][(range % 4) + 1] AS region, "
            + "(range * 1.5)::DECIMAL(12,2) AS amount, "
            + "CASE WHEN range % 50 = 0 THEN NULL ELSE 'note ' || range END AS note "
            + "FROM range(\(rows))) TO \(qlit(path)) (FORMAT parquet)"
    )
    return path
}

/// A hive-partitioned dataset: dt=.../region=.../part-0.parquet.
func makeHiveParquet(con: Connection, dir: String, name: String = "events", rows: Int = 400) throws -> String {
    let root = join(dir, name)
    let combos = [("2026-08-01", "West"), ("2026-08-01", "South"),
                  ("2026-08-02", "West"), ("2026-08-02", "South")]
    for (d, region) in combos {
        let part = URL(fileURLWithPath: root)
            .appendingPathComponent("dt=\(d)")
            .appendingPathComponent("region=\(region)")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        let partFile = part.appendingPathComponent("part-0.parquet").path
        try con.execute(
            "COPY (SELECT range AS id, (range * 2)::BIGINT AS qty FROM range(\(rows / 4))) "
                + "TO \(qlit(partFile)) (FORMAT parquet)"
        )
    }
    return root
}

private func jsonString(_ obj: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? ""
}

private func jsonLine(_ obj: [String: Any]) throws -> String {
    try jsonString(obj) + "\n"
}

/// A minimal but real Delta table whose version 1 tombstones a still-present file.
///
/// This is the fixture that makes the Delta test meaningful: a raw parquet glob returns
/// kept+tombstoned rows, while delta_scan must return only `kept`. If those two numbers are
/// ever equal, the fixture is broken and the test proves nothing — see
/// `deltaGlobVsScanRowCountsDiffer` below.
func makeDelta(con: Connection, dir: String, name: String = "dtable",
                kept: Int = 100, tombstoned: Int = 50) throws -> String {
    let root = join(dir, name)
    let logDir = join(root, "_delta_log")
    try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

    let part0 = "part-0.parquet"
    let part1 = "part-1.parquet"
    try con.execute(
        "COPY (SELECT range AS id, 'a' AS g FROM range(\(kept))) TO \(qlit(join(root, part0))) (FORMAT parquet)")
    try con.execute(
        "COPY (SELECT range AS id, 'b' AS g FROM range(\(kept), \(kept + tombstoned))) "
            + "TO \(qlit(join(root, part1))) (FORMAT parquet)")

    let schema: [String: Any] = [
        "type": "struct",
        "fields": [
            ["name": "id", "type": "long", "nullable": true, "metadata": [String: Any]()],
            ["name": "g", "type": "string", "nullable": true, "metadata": [String: Any]()],
        ],
    ]
    let schemaString = try jsonString(schema)

    func size(_ filename: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: join(root, filename))
        return (attrs[.size] as? Int) ?? 0
    }

    var log0 = try jsonLine(["protocol": ["minReaderVersion": 1, "minWriterVersion": 2]])
    log0 += try jsonLine(["metaData": [
        "id": UUID().uuidString.lowercased(),
        "format": ["provider": "parquet", "options": [String: Any]()],
        "schemaString": schemaString,
        "partitionColumns": [String](),
        "configuration": [String: Any](),
        "createdTime": FIXED_MS,
    ]])
    for p in [part0, part1] {
        log0 += try jsonLine(["add": [
            "path": p, "partitionValues": [String: Any](), "size": try size(p),
            "modificationTime": FIXED_MS, "dataChange": true,
        ]])
    }
    try log0.write(toFile: join(logDir, "00000000000000000000.json"), atomically: true, encoding: .utf8)

    let log1 = try jsonLine(["remove": [
        "path": part1, "deletionTimestamp": FIXED_MS + 1000,
        "dataChange": true, "partitionValues": [String: Any](),
        "size": try size(part1),
    ]])
    try log1.write(toFile: join(logDir, "00000000000000000001.json"), atomically: true, encoding: .utf8)

    return root
}

// MARK: - NDJSON

func makeNDJSON(dir: String, name: String = "events.ndjson", rows: Int = 200) throws -> String {
    let path = join(dir, name)
    var out = ""
    for i in 0..<rows {
        let region = i % 2 == 0 ? "West" : "South"
        out += "{\"id\": \(i), \"region\": \"\(region)\", \"nested\": {\"a\": \(i)}}\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - Gzip CSV

/// Foundation has no gzip writer, so this shells out to `/usr/bin/gzip -c`. Both ends are real
/// files, not pipes — no `DispatchQueue.global()` writer/reader needed, and so no dependency on
/// a GCD worker thread being free to run one. That dependency was real: the previous
/// Pipe-plus-background-queue version deadlocked the test suite when enough parallel tests each
/// built a corpus at once and starved the global concurrent queue of the thread the writer block
/// needed — MEASURED, not hypothetical; see task-9-report.md's review-fix section. Redirecting
/// stdin/stdout to files sidesteps the whole class of failure: the kernel drains both ends, no
/// GCD thread required.
func makeGzipCSV(dir: String, name: String = "sales.csv.gz", rows: Int = 500) throws -> String {
    let path = join(dir, name)
    var text = "id,region\n"
    for i in 0..<rows {
        text += "\(i),\(i % 2 == 0 ? "South" : "West")\n"
    }
    let inputPath = join(dir, ".\(UUID().uuidString).csv")
    try text.write(toFile: inputPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: inputPath) }
    FileManager.default.createFile(atPath: path, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = FileHandle(forReadingAtPath: inputPath)
    process.standardOutput = FileHandle(forWritingAtPath: path)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DuckDBError("gzip exited \(process.terminationStatus)")
    }
    return path
}

// MARK: - Fake legacy .xls

/// OLE2 magic bytes plus padding — enough to exercise the legacy-.xls refusal path. Not a real
/// spreadsheet, and must not become one.
func makeFakeXLS(dir: String, name: String = "legacy.xls") throws -> String {
    let path = join(dir, name)
    var data = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
    data.append(Data(repeating: 0, count: 512))
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

// MARK: - The whole corpus, built once

/// Everything the corpus needs, generated once per call. Mirrors conftest.py's session-scoped
/// `data` fixture; `xlsx` points at the committed golden file (Fixtures/README.md) rather than
/// generating one. `deltaAvailable` / `excelAvailable` say whether this DuckDB build could
/// actually load those extensions — building the corpus itself never depends on them, since
/// `makeDelta` writes its own `_delta_log` JSON by hand.
struct FixtureCorpus: Sendable {
    let dir: String
    let cleanCSV: String
    let dirtyCSV: String
    let nullsCSV: String
    let weirdCSV: String
    let semiCSV: String
    let quotedNLCSV: String
    let gzCSV: String
    let parquet: String
    let ndjson: String
    let xlsx: String
    let fakeXLS: String
    let delta: String
    let hive: String
    let empty: String
    let deltaAvailable: Bool
    let excelAvailable: Bool
}

/// The committed golden workbook's path — see Fixtures/README.md for why it's not generated.
func bundledXLSXPath(_ name: String = "book") -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures") else {
        fatalError("missing committed fixture \(name).xlsx — see Tests/SiftCoreTests/Fixtures/README.md")
    }
    return url.path
}

func corpus() throws -> FixtureCorpus {
    let dir = try tempDir()
    let db = try Database.inMemory()
    // Tolerated exactly like conftest.py's `con` fixture: LOAD, then INSTALL+LOAD, then give up.
    db.loadExtensions(["delta", "excel"])
    let con = try db.connect()

    let empty = join(dir, "empty.csv")
    FileManager.default.createFile(atPath: empty, contents: Data())

    return FixtureCorpus(
        dir: dir,
        cleanCSV: try makeCSV(dir: dir, name: "clean.csv", rows: 1000),
        dirtyCSV: try makeCSV(dir: dir, name: "dirty.csv", rows: 1000, badIntRow: 500),
        nullsCSV: try makeCSV(dir: dir, name: "nulls.csv", rows: 600,
                               nullsEvery: 7, emptiesEvery: 11, nullishEvery: 13),
        weirdCSV: try makeCSV(dir: dir, name: "weird.csv", rows: 300,
                               crlf: true, bom: true, preamble: 3),
        semiCSV: try makeCSV(dir: dir, name: "semi.csv", rows: 200, delim: ";"),
        quotedNLCSV: try makeCSV(dir: dir, name: "qnl.csv", rows: 400, quotedNewlineRow: 100),
        gzCSV: try makeGzipCSV(dir: dir),
        parquet: try makeParquet(con: con, dir: dir, rows: 1000),
        ndjson: try makeNDJSON(dir: dir),
        xlsx: bundledXLSXPath("book"),
        fakeXLS: try makeFakeXLS(dir: dir),
        delta: try makeDelta(con: con, dir: dir),
        hive: try makeHiveParquet(con: con, dir: dir),
        empty: empty,
        deltaAvailable: db.loadedExtensions["delta"] == true,
        excelAvailable: db.loadedExtensions["excel"] == true
    )
}

// MARK: - Self-checks: makeCSV

@Test func makeCSVWritesTheClaimedHeaderAndRowCount() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, rows: 50)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.first == "order_id,region,amount,note")
    // 1 header + 50 rows + trailing empty split element from the final "\n".
    #expect(lines.count == 52)
}

@Test func makeCSVBOMCRLFAndPreambleAreExactlyWhatTheyClaim() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, name: "weird.csv", rows: 10, crlf: true, bom: true, preamble: 3)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF], "expected a UTF-8 BOM")
    let text = String(data: data.dropFirst(3), encoding: .utf8)!
    #expect(!text.contains("\n\n"), "no bare LF should appear (CRLF only)")
    #expect(text.contains("\r\n"), "expected CRLF line endings")
    let lines = text.components(separatedBy: "\r\n")
    #expect(lines[0] == "# generated file, junk line 0")
    #expect(lines[1] == "# generated file, junk line 1")
    #expect(lines[2] == "# generated file, junk line 2")
    #expect(lines[3] == "order_id,region,amount,note")
}

@Test func makeCSVRaggedRowsDropTrailingFields() throws {
    let dir = try tempDir()
    // ragged truncates every 97th data row (0-based) to 2 fields; rows=98 hits i=0 and i=97.
    let path = try makeCSV(dir: dir, rows: 98, ragged: true)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let dataLines = text.split(separator: "\n").dropFirst()   // drop header
    let raggedRows = dataLines.filter { $0.split(separator: ",").count == 2 }
    #expect(raggedRows.count == 2, "expected rows 0 and 97 to be truncated to 2 fields")
}

@Test func makeCSVBadIntRowProducesAValueThatWillNotCast() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, rows: 20, badIntRow: 5)
    let con = try Database.inMemory().connect()
    let read = "read_csv(\(qlit(path)), columns={'order_id':'BIGINT','region':'VARCHAR'," +
        "'amount':'DOUBLE','note':'VARCHAR'}, header=true, ignore_errors=true)"
    // count(*) is answered by projection pushdown (fact3 in DuckDB155FactsTests) and sees the
    // physical row count; SELECT * drops the row whose amount ("N/A") fails TRY_CAST to DOUBLE.
    let counted = try con.query("SELECT count(*) FROM \(read)").allRows()[0][0]
    let selected = try con.query("SELECT * FROM \(read)").allRows().count
    #expect(counted == .int(20))
    #expect(selected == 19, "the uncastable amount at row 5 should be dropped, not silently coerced")
}

@Test func makeCSVQuoteNotesWrapsEveryNoteField() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, rows: 5, quoteNotes: true)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for i in 0..<5 {
        #expect(text.contains("\"note \(i)\""))
    }
}

@Test func makeCSVQuotedNewlineFieldParsesAsOneRowNotTwo() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, name: "qnl.csv", rows: 20, quotedNewlineRow: 5)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("\"line one\nline two\""), "expected a literal embedded newline inside quotes")

    let con = try Database.inMemory().connect()
    // A byte-sample line count would see 21 header+data lines' worth of "\n" plus one extra
    // from the embedded newline — exactly the estimator failure mode this fixture exists for.
    let n = try con.query("SELECT count(*) FROM read_csv(\(qlit(path)), header=true)").allRows()[0][0]
    #expect(n == .int(20), "DuckDB's real CSV parser must still see exactly 20 data rows")
}

@Test func makeCSVCustomDelimiterIsHonored() throws {
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, name: "semi.csv", rows: 20, delim: ";")
    let con = try Database.inMemory().connect()
    let n = try con.query("SELECT count(*) FROM read_csv(\(qlit(path)), header=true, delim=';')")
        .allRows()[0][0]
    #expect(n == .int(20))
}

@Test func makeCSVKeepsNullEmptyAndNullishDistinctThroughDuckDB() throws {
    // The distinction the whole tool exists for, and gotcha #8's exact quoting requirement:
    // nullsEvery writes a bare empty field (NULL under allow_quoted_nulls=false); emptiesEvery
    // writes a QUOTED "" (a real empty string); nullishEvery overwrites with the literal "N/A".
    let dir = try tempDir()
    let path = try makeCSV(dir: dir, name: "nulls.csv", rows: 600,
                            nullsEvery: 7, emptiesEvery: 11, nullishEvery: 13)
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT region, note FROM read_csv(\(qlit(path)), header=true, allow_quoted_nulls=false)"
    ).allRows()

    let nNullRegion = rows.filter { $0[0].isNull }.count
    let nEmptyNote = rows.filter { $0[1] == .text("") }.count
    let nNullishNote = rows.filter { $0[1] == .text("N/A") }.count
    let nNullNote = rows.filter { $0[1].isNull }.count

    #expect(nNullRegion > 0, "unquoted empty region fields must read as NULL")
    #expect(nEmptyNote > 0, "quoted \"\" notes must read as an empty string, not NULL")
    #expect(nNullishNote > 0, "the N/A sentinel must survive as literal text, not NULL")
    #expect(nNullNote == 0, "note is never unquoted-empty in this fixture, so it must never be NULL")
}

// MARK: - Self-checks: makeParquet

@Test func makeParquetHasTheClaimedShape() throws {
    let dir = try tempDir()
    let con = try Database.inMemory().connect()
    let path = try makeParquet(con: con, dir: dir, rows: 250)
    let cols = try con.query("SELECT * FROM read_parquet(\(qlit(path))) LIMIT 0").columns.map(\.name)
    #expect(cols == ["order_id", "region", "amount", "note"])
    let counts = try con.query(
        "SELECT count(*), count(DISTINCT region), count(*) FILTER (note IS NULL) FROM read_parquet(\(qlit(path)))"
    ).allRows()[0]
    #expect(counts[0] == .int(250))
    #expect(counts[1] == .int(4))
    #expect(counts[2] != .int(0), "every 50th note is NULL by construction")
}

// MARK: - Self-checks: makeHiveParquet

@Test func makeHiveParquetProducesTheDtRegionDirectoryLayout() throws {
    let dir = try tempDir()
    let con = try Database.inMemory().connect()
    let root = try makeHiveParquet(con: con, dir: dir, rows: 400)
    for (d, region) in [("2026-08-01", "West"), ("2026-08-01", "South"),
                         ("2026-08-02", "West"), ("2026-08-02", "South")] {
        let part = URL(fileURLWithPath: root)
            .appendingPathComponent("dt=\(d)").appendingPathComponent("region=\(region)")
            .appendingPathComponent("part-0.parquet")
        #expect(FileManager.default.fileExists(atPath: part.path), "missing \(part.path)")
    }
    let glob = join(root, "**/*.parquet")
    let cols = try con.query(
        "SELECT * FROM read_parquet(\(qlit(glob)), hive_partitioning=true) LIMIT 0"
    ).columns.map(\.name)
    #expect(cols.contains("dt") && cols.contains("region"), "hive partitioning must surface dt/region columns")
    let n = try con.query(
        "SELECT count(*) FROM read_parquet(\(qlit(glob)), hive_partitioning=true)"
    ).allRows()[0][0]
    #expect(n == .int(400))
}

// MARK: - Self-checks: makeDelta

@Test(.enabled(if: extensionIsAvailable("delta"), "delta extension not installed on this machine"))
func deltaGlobVsScanRowCountsDiffer() throws {
    let dir = try tempDir()
    let db = try Database.inMemory()
    db.loadExtensions(["delta"])
    let con = try db.connect()
    let root = try makeDelta(con: con, dir: dir, kept: 100, tombstoned: 50)

    let globCount = try con.query(
        "SELECT count(*) FROM read_parquet(\(qlit(join(root, "*.parquet"))))"
    ).allRows()[0][0]
    let scanCount = try con.query("SELECT count(*) FROM delta_scan(\(qlit(root)))").allRows()[0][0]

    #expect(globCount == .int(150), "raw glob must see both the kept and tombstoned rows")
    #expect(scanCount == .int(100), "delta_scan must see only the kept rows")
    #expect(globCount != scanCount,
            "if these are ever equal the fixture is broken and the test proves nothing")
}

@Test func makeDeltaWritesATwoEntryLogWithARemoveTombstone() throws {
    // Independent of the delta extension: this only checks the hand-written log's shape, which
    // is what a machine without the extension still needs to be right.
    let dir = try tempDir()
    let con = try Database.inMemory().connect()
    let root = try makeDelta(con: con, dir: dir, kept: 30, tombstoned: 10)
    let log0 = try String(
        contentsOfFile: join(join(root, "_delta_log"), "00000000000000000000.json"), encoding: .utf8)
    let log1 = try String(
        contentsOfFile: join(join(root, "_delta_log"), "00000000000000000001.json"), encoding: .utf8)
    #expect(log0.contains("\"protocol\""))
    #expect(log0.contains("\"metaData\""))
    #expect(log0.contains("part-0.parquet") && log0.contains("part-1.parquet"))
    #expect(log1.contains("\"remove\""))
    #expect(log1.contains("part-1.parquet"), "version 1 must tombstone the still-present part-1 file")
    #expect(FileManager.default.fileExists(atPath: join(root, "part-1.parquet")),
            "the tombstoned file must remain physically present — that's the whole point")
}

// MARK: - Self-checks: makeNDJSON

@Test func makeNDJSONWritesOneObjectPerLineWithNestedFields() throws {
    let dir = try tempDir()
    let path = try makeNDJSON(dir: dir, rows: 50)
    let lines = try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 50)
    let con = try Database.inMemory().connect()
    let n = try con.query("SELECT count(*) FROM read_ndjson_auto(\(qlit(path)))").allRows()[0][0]
    #expect(n == .int(50))
    let first = try con.query(
        "SELECT region, nested.a FROM read_ndjson_auto(\(qlit(path))) ORDER BY id LIMIT 1"
    ).allRows()[0]
    #expect(first[0] == .text("West"))
    #expect(first[1] == .int(0))
}

// MARK: - Self-checks: makeGzipCSV

@Test func makeGzipCSVProducesRealGzipBytesDuckDBCanRead() throws {
    let dir = try tempDir()
    let path = try makeGzipCSV(dir: dir, rows: 30)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B, "expected the gzip magic bytes")
    let con = try Database.inMemory().connect()
    let n = try con.query("SELECT count(*) FROM read_csv(\(qlit(path)), header=true)").allRows()[0][0]
    #expect(n == .int(30))
}

// MARK: - Self-checks: makeFakeXLS

@Test func makeFakeXLSStartsWithTheOLE2MagicBytes() throws {
    let dir = try tempDir()
    let path = try makeFakeXLS(dir: dir)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(Array(data.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    #expect(data.count == 8 + 512)
}

// MARK: - Self-checks: corpus

@Test func corpusBuildsEveryFixtureAndReportsExtensionAvailability() throws {
    let c = try corpus()
    let paths = [c.cleanCSV, c.dirtyCSV, c.nullsCSV, c.weirdCSV, c.semiCSV, c.quotedNLCSV,
                 c.gzCSV, c.parquet, c.ndjson, c.xlsx, c.fakeXLS, c.delta, c.hive, c.empty]
    for p in paths {
        #expect(FileManager.default.fileExists(atPath: p), "missing \(p)")
    }
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: c.dir, isDirectory: &isDir) && isDir.boolValue)
    #expect(FileManager.default.fileExists(atPath: c.hive, isDirectory: &isDir) && isDir.boolValue)
    #expect(FileManager.default.fileExists(atPath: c.delta, isDirectory: &isDir) && isDir.boolValue)
    // Genuinely empty, matching Python's `open(out["empty"], "w").close()`.
    #expect((try Data(contentsOf: URL(fileURLWithPath: c.empty))).isEmpty)
    // Never a crash either way — the flags say plainly what this machine could load.
    _ = c.deltaAvailable
    _ = c.excelAvailable
}
