import Testing
import CDuckDB
import Foundation
@testable import DuckDBKit

// Forces an actual link against libduckdb (module autolink only fires on import)
// and pins that the loaded library is genuinely the 1.5.5 build we checksummed.
@Test func linkedLibraryIsThePinnedDuckDBVersion() {
    #expect(String(cString: duckdb_library_version()) == "v1.5.5")
}

@Test func errorKeepsOnlyTheFirstLine() {
    let e = DuckDBError("Binder Error: no such column\nLINE 1: SELECT nope\n        ^")
    #expect(e.firstLine == "Binder Error: no such column")
}

@Test func emptyErrorGetsAFallbackMessage() {
    #expect(DuckDBError("").firstLine == "Query failed.")
}

@Test func longErrorIsCappedAt400Characters() {
    let e = DuckDBError(String(repeating: "x", count: 900))
    #expect(e.firstLine.count == 400)
}

@Test func opensAnInMemoryDatabaseAndConnects() throws {
    let db = try Database.inMemory()
    let con = try db.connect()
    try con.execute("CREATE TABLE t (a INTEGER)")
    try con.execute("INSERT INTO t VALUES (1), (2)")
}

@Test func aBadStatementThrowsWithDuckDBsMessage() throws {
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        try con.execute("SELECT * FROM no_such_table")
    }
}

@Test func hardeningRefusesNetworkReadsAndKeepsLocalOnesWorking() throws {
    let db = try Database.inMemory()
    db.harden()
    // Connection opened after harden(): the settings are GLOBAL scope, so they outlive
    // the throwaway connection harden() uses. Measured against libduckdb 1.5.5.
    let con = try db.connect()

    // Local file reads must keep working — the entire product is local file reading.
    // enable_external_access=false would have blocked read_csv itself, which is exactly
    // why harden() deliberately does not set it. `SELECT 1` would NOT test this: it
    // touches no filesystem at all.
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-harden-\(UUID().uuidString).csv")
    try "a,b\n1,2\n".write(to: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: path) }
    try con.execute("SELECT * FROM read_csv('\(path.path)', header=true)")

    // A network read must be refused, and we assert WHICH mechanism refuses it.
    // MEASURED: what actually blocks this path is the extension guard
    // (autoload_known_extensions=false) — httpfs never loads, so disabled_filesystems
    // is never consulted. It is a second layer that only engages once something has
    // loaded httpfs. Asserting only `throws: DuckDBError.self` is worthless here: with
    // harden() deleted entirely the URL simply 404s, which is also a DuckDBError.
    var message = ""
    do {
        try con.execute("SELECT * FROM read_csv_auto('https://example.com/x.csv')")
        Issue.record("a network read succeeded despite hardening")
    } catch let error as DuckDBError {
        message = error.message
    }
    #expect(message.contains("httpfs") || message.contains("HTTPFileSystem"),
            "expected hardening to refuse the read; got: \(message)")
}

@Test func blobDisplayMatchesThePythonEngineFormat() {
    // The grid renders this string, so the format is a contract, not a detail — and it
    // must not vary with the machine's region. See Cell.grouped for the measurements.
    #expect(Cell.blob(0).display == "<blob 0 B>")
    #expect(Cell.blob(3).display == "<blob 3 B>")
    #expect(Cell.blob(999).display == "<blob 999 B>")
    #expect(Cell.blob(1000).display == "<blob 1,000 B>")
    #expect(Cell.blob(1234).display == "<blob 1,234 B>")
    #expect(Cell.blob(999999).display == "<blob 999,999 B>")
    #expect(Cell.blob(1000000).display == "<blob 1,000,000 B>")
    #expect(Cell.blob(1234567890).display == "<blob 1,234,567,890 B>")
}

@Test func nullDisplaysAsEmptyAndKnowsItIsNull() {
    #expect(Cell.null.isNull)
    #expect(Cell.null.display == "")
    #expect(!Cell.int(0).isNull)
}
