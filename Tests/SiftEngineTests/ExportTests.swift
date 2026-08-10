import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Export — the only place Sift writes to the user's disk, and therefore the only trust boundary
// in the engine that produces a file. Roughly half of these are attacks rather than happy paths,
// per the Task 7 brief: a format, a destination and a table name that each try to break out of
// the COPY statement, plus the SELECT-only re-check on stored SQL text. The other half pin the
// two behaviours a data tool cannot get wrong — every format actually round-trips, and an
// existing file is never silently replaced.
//
// Each test gets its own `~/.sift`-equivalent temp directory and its own output directory:
// Swift Testing runs in parallel, two sessions sharing a home would race on DuckDB's exclusive
// file lock, and two tests sharing an output directory would race on filenames.

private let sharedData = try! corpus()

private func newSession() throws -> Session {
    try Session(
        home: FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-export-tests-\(UUID().uuidString)").path
    )
}

private func newOutputDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-export-out-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func out(_ dir: String, _ name: String) -> String {
    (dir as NSString).appendingPathComponent(name)
}

private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

/// Read an exported file back with a fresh in-memory DuckDB — a genuinely independent reader, so
/// "the export worked" cannot be satisfied by a file only this engine's own state can interpret.
private func rowsIn(_ path: String, reader: String) throws -> Int {
    let db = try Database.inMemory()
    db.loadExtensions(["excel"])
    let con = try db.connect()
    let row = try con.query("SELECT count(*) FROM \(reader)(\(qlit(path)))").allRows()[0][0]
    guard case .int(let n) = row else { return -1 }
    return Int(n)
}

/// The compression codecs a parquet file's column chunks actually use, read from its footer.
private func compressionOf(_ path: String) throws -> Set<String> {
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT DISTINCT compression FROM parquet_metadata(\(qlit(path)))"
    ).allRows()
    return Set(rows.map { $0[0].display })
}

/// A three-row CSV, small enough that every assertion below can name exact numbers.
private func makeTinyCSV(dir: String, name: String = "tiny.csv") throws -> String {
    let path = out(dir, name)
    try "id,region\n1,West\n2,South\n3,West\n".write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - the formats round-trip

@Test func everyExportFormatWritesAFileThatReadsBackWithTheSameRowCount() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    // `read_csv` reads the tsv too (it sniffs the delimiter), and `read_json` reads both JSON
    // shapes. The point is a reader that is not this session.
    let readers = [
        "parquet": "read_parquet", "csv": "read_csv", "tsv": "read_csv",
        "json": "read_json", "ndjson": "read_json", "xlsx": "read_xlsx",
    ]
    for format in exportFormats {
        if format.key == "xlsx" && !sharedData.excelAvailable { continue }
        let dest = out(dir, "round-trip.\(format.ext)")
        let result = try await session.export(t.name, dest: dest, format: format.key)

        #expect(result.dest == dest)
        #expect(result.format == format.key)
        #expect(result.bytes > 0, "\(format.key) wrote an empty file")
        #expect(result.milliseconds >= 0)
        #expect(try rowsIn(dest, reader: readers[format.key]!) == 3, "\(format.key) round-trip")
    }

    // Each format's COPY options actually took effect — a round-trip row count alone would not
    // notice, because `read_csv` sniffs the delimiter and `read_json` accepts both JSON shapes.
    func text(_ ext: String) throws -> String {
        try String(contentsOfFile: out(dir, "round-trip.\(ext)"), encoding: .utf8)
    }
    #expect(try text("csv").hasPrefix("id,region"))
    #expect(try text("tsv").hasPrefix("id\tregion"))         // DELIMITER '\t'
    #expect(try text("json").hasPrefix("["))                 // ARRAY true
    #expect(try text("ndjson").hasPrefix("{"))               // one object per line
    #expect(try compressionOf(out(dir, "round-trip.parquet")) == ["ZSTD"])
}

@Test func exportIsNotCappedAtOnePageOfRows() async throws {
    // `pageSQL` always emits `LIMIT ? OFFSET ?`, so "all of it" has to be spelled as a number
    // larger than any table. Getting that wrong would silently truncate every export of a table
    // bigger than one screen — the quietest data-loss bug in the product.
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)   // 1,000 rows, well past `pageRows`
    let dest = out(dir, "big.parquet")
    _ = try await session.export(t.name, dest: dest, format: "parquet")
    #expect(try rowsIn(dest, reader: "read_parquet") == 1000)
}

@Test func exportedFormatKeysAreCaseInsensitiveAndKeepTheirMenuOrder() async throws {
    // Python's dict is insertion-ordered and both UI menus list these six in this order; a
    // dictionary here would have thrown that away silently.
    #expect(exportFormats.map(\.key) == ["parquet", "csv", "tsv", "json", "ndjson", "xlsx"])
    #expect(exportFormat(named: "XLSX")?.ext == "xlsx")
    #expect(exportFormat(named: "Parquet")?.copyOptions == "(FORMAT parquet, COMPRESSION zstd)")
    #expect(exportFormat(named: "parqet") == nil)
}

@Test func exportCarriesTheTablesFiltersAndSortIntoTheFile() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    _ = try await session.setSpec(
        t.name,
        filters: [Filter(col: "region", op: .eq, values: [.text("West")])],
        sort: [QuerySpec.SortTerm(column: "id", direction: .desc)]
    )

    let dest = out(dir, "filtered.csv")
    _ = try await session.export(t.name, dest: dest, format: "csv")
    // The filter is a BOUND parameter inside the COPY — proving it survives is proving DuckDB
    // accepts a prepared COPY at all, which the whole non-SQL-mode path depends on.
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "id,region\n3,West\n1,West\n")
}

@Test func exportOfASQLModeTableWritesTheQueryResultNotTheWholeTable() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    _ = try await session.runSQL(
        t.name, sql: "SELECT id FROM \(q(t.name)) WHERE region = 'South'", offset: 0, limit: 100
    )

    let dest = out(dir, "sqlmode.csv")
    _ = try await session.export(t.name, dest: dest, format: "csv")
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "id\n2\n")
}

@Test func exportMaterializesAMergeView() async throws {
    // The brief's reason `merge` is allowed to stay a view: exporting it is how you get a copy.
    let dir = try newOutputDir()
    let session = try newSession()
    let a = out(dir, "a.csv")
    try "k,v\n1,x\n2,y\n".write(toFile: a, atomically: true, encoding: .utf8)
    let b = out(dir, "b.csv")
    try "k,w\n1,p\n2,q\n".write(toFile: b, atomically: true, encoding: .utf8)
    _ = try await session.openPath(a)
    _ = try await session.openPath(b)
    let merged = try await session.merge("a", "b", on: ["k"])

    let dest = out(dir, "merged.parquet")
    let result = try await session.export(merged.name, dest: dest, format: "parquet")
    #expect(result.bytes > 0)
    #expect(try rowsIn(dest, reader: "read_parquet") == 2)
}

@Test func exportCreatesMissingParentDirectories() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    let dest = out(dir, "deep/deeper/deepest.csv")
    _ = try await session.export(t.name, dest: dest, format: "csv")
    #expect(exists(dest))
}

@Test func exportResolvesTildeDotSegmentsAndRelativePaths() async throws {
    // `os.path.abspath(os.path.expanduser(...))`. The relative case is the one that separates
    // this from `NSString.standardizingPath`, which would leave it relative — and a relative
    // `dest` names no particular file once it has been handed back to the caller.
    #expect(Session.absolutePath("/a/b/../c/./d") == "/a/c/d")
    #expect(Session.absolutePath("~/x").hasPrefix(NSHomeDirectory()))
    #expect(
        Session.absolutePath("some/where/x.csv")
            == out(FileManager.default.currentDirectoryPath, "some/where/x.csv")
    )

    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    let result = try await session.export(t.name, dest: out(dir, "sub/../plain.csv"), format: "csv")
    #expect(result.dest == out(dir, "plain.csv"))
    #expect(exists(result.dest))
}

// MARK: - overwrite refusal

@Test func exportRefusesToReplaceAnExistingFileAndLeavesItByteForByteIntact() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    let dest = out(dir, "guarded.csv")

    _ = try await session.export(t.name, dest: dest, format: "csv")
    let original = try Data(contentsOf: URL(fileURLWithPath: dest))

    // A filter, so a successful overwrite would visibly shrink the file — "unchanged" has to
    // mean the bytes, not merely "a file is still there".
    _ = try await session.setSpec(
        t.name, filters: [Filter(col: "region", op: .eq, values: [.text("South")])], sort: []
    )
    await #expect(throws: SessionError("\(dest) already exists. Tick overwrite to replace it.")) {
        try await session.export(t.name, dest: dest, format: "csv")
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: dest)) == original)

    // ...and says yes when actually told to.
    let replaced = try await session.export(t.name, dest: dest, format: "csv", overwrite: true)
    #expect(replaced.bytes < original.count)
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "id,region\n2,South\n")
}

@Test func exportRefusesWhenTheDestinationIsAnExistingDirectory() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    let dest = out(dir, "occupied")
    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

    await #expect(throws: SessionError("\(dest) already exists. Tick overwrite to replace it.")) {
        try await session.export(t.name, dest: dest, format: "csv")
    }
}

@Test func aFailedExportLeavesNoPlaceholderBehind() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))
    // A perfectly well-formed SELECT against a table that does not exist: it passes the
    // SELECT-only gate (which deliberately lets an unpreparable statement through — see
    // GuardStatements.swift's landmine) and fails when the COPY binds.
    await session.setSQLTextForTest(t.name, "SELECT * FROM no_such_table_here")

    let dest = out(dir, "doomed.parquet")
    await #expect(throws: (any Error).self) {
        try await session.export(t.name, dest: dest, format: "parquet")
    }
    // The claim-the-name step creates a zero-byte file BEFORE the COPY runs. Leaving it there
    // would mean a failed export permanently blocks its own retry with "already exists".
    #expect(!exists(dest), "a failed export must leave the destination exactly as it found it")

    // And the retry really does work once the query is fixed.
    await session.setSQLTextForTest(t.name, nil)
    _ = try await session.export(t.name, dest: dest, format: "parquet")
    #expect(try rowsIn(dest, reader: "read_parquet") == 3)
}

// MARK: - the trust boundary

@Test func exportRejectsAnUnknownFormatCleanlyAndBeforeTouchingTheDisk() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    let dest = out(dir, "never/made/here.csv")
    await #expect(throws: SessionError("Unsupported export format 'parqet'.")) {
        try await session.export(t.name, dest: dest, format: "parqet")
    }
    // DIVERGENCE from Python, which looks the format up AFTER `os.makedirs` and so leaves a
    // directory tree behind for a call that was never going to write anything.
    #expect(!exists(out(dir, "never")))
}

@Test func aFormatThatTriesToCloseTheCopyStatementIsJustAnUnknownFormat() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    let attack = "csv) TO '\(out(dir, "pwned-by-format.csv"))' --"
    await #expect(throws: SessionError("Unsupported export format '\(attack)'.")) {
        try await session.export(t.name, dest: out(dir, "ok.csv"), format: attack)
    }
    #expect(!exists(out(dir, "pwned-by-format.csv")))
    #expect(!exists(out(dir, "ok.csv")))
}

@Test func aDestinationThatTriesToStartASecondStatementBecomesOneLiteralFilename() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    // No slash anywhere in the injected half, so if the quoting failed the second COPY would
    // succeed and drop `pwned.csv` in the process working directory — which is what the last
    // assertion looks for. With the quoting intact this is one filename with punctuation in it.
    let dest = out(dir, "od'); COPY (SELECT 42) TO 'pwned.csv")
    let result = try await session.export(t.name, dest: dest, format: "csv")

    #expect(result.dest == dest)
    #expect(exists(dest))
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "id,region\n1,West\n2,South\n3,West\n")
    #expect(!exists(out(dir, "pwned.csv")))
    #expect(!exists(out(FileManager.default.currentDirectoryPath, "pwned.csv")))
}

@Test func exportSurvivesATableNameCarryingADoubleQuote() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    // `openPath(_:name:)` takes a caller-supplied name verbatim — it does NOT sanitize one that
    // was given explicitly — so this is a reachable shape, not a contrived one.
    let hostile = "ev\"il\"; DROP TABLE x; --"
    let t = try await session.openPath(try makeTinyCSV(dir: dir), name: hostile)
    #expect(t.name == hostile)

    let dest = out(dir, "hostile-name.csv")
    _ = try await session.export(t.name, dest: dest, format: "csv")
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "id,region\n1,West\n2,South\n3,West\n")
}

@Test func exportReRunsTheSelectOnlyGateOnStoredSQLTextBeforeWrappingIt() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    let t = try await session.openPath(try makeTinyCSV(dir: dir))

    // `runSQL` would never store this — which is the point. `export` re-checks rather than
    // trusting the flag, so the day a second writer of `sqlText` appears (a session restore, a
    // saved view) this is the call that stops the statement being assembled at all.
    await session.setSQLTextForTest(t.name, "DROP TABLE \(q(t.name))")
    let dest = out(dir, "guarded-sql.csv")
    await #expect(throws: SQLRejected.self) {
        try await session.export(t.name, dest: dest, format: "csv")
    }
    #expect(!exists(dest))
    // The table is still there, i.e. nothing ran. (Leaving SQL mode first, because paging a
    // table whose stored text is `DROP TABLE` would fail at the wrap, not at the drop.)
    await session.setSQLTextForTest(t.name, nil)
    #expect(try await session.page(t.name, offset: 0, limit: 10).rows.count == 3)

    // Two statements: rejected by the statement-count half of the same gate.
    await session.setSQLTextForTest(t.name, "SELECT 1; SELECT 2")
    await #expect(throws: SQLRejected.self) {
        try await session.export(t.name, dest: out(dir, "two.csv"), format: "csv")
    }
    #expect(!exists(out(dir, "two.csv")))
}

@Test func exportRefusesATableThatIsNotOpen() async throws {
    let dir = try newOutputDir()
    let session = try newSession()
    await #expect(throws: SessionError("No open table named 'nope'.")) {
        try await session.export("nope", dest: out(dir, "x.csv"), format: "csv")
    }
    #expect(!exists(out(dir, "x.csv")))
}
