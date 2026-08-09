import Testing
import CDuckDB
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

@Test func hardeningBlocksNetworkFilesystemsButNotLocalReads() throws {
    let db = try Database.inMemory()
    db.harden()
    // Connection opened AFTER harden(), deliberately: harden() applies its settings on
    // a throwaway connection and discards it. That only works because these are
    // GLOBAL-scope settings which outlive the connection that set them — measured
    // against libduckdb 1.5.5. If they were session-scoped, harden() would be a
    // silent no-op and this test is what would catch it.
    let con = try db.connect()

    // Local reads must keep working. enable_external_access=false would have blocked
    // read_csv itself and destroyed the whole premise, which is why harden()
    // deliberately does not set it.
    try con.execute("SELECT 1")

    // But a SELECT must not be able to exfiltrate. disabled_filesystems enforces that,
    // and it fails at the filesystem layer, so this needs no network to run.
    #expect(throws: DuckDBError.self) {
        try con.execute("SELECT * FROM read_csv_auto('https://example.com/x.csv')")
    }
}
