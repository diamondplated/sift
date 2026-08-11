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

// 🔴 `firstLine` reaches `localizedDescription`, not just `"\(error)"`.
//
// Without `LocalizedError`, Foundation bridges this to `NSError` and synthesizes "The operation
// couldn't be completed. (DuckDBKit.DuckDBError error 1.)" — MEASURED, and shipped: `sift
// bad.parquet` printed exactly that, throwing away
// `Invalid Input Error: No magic bytes found at end of file '…'`. The conformance is what covers
// the throw sites nobody has enumerated; SiftEngine additionally wraps its own public methods.
@Test func aDuckDBErrorReadsAsItsFirstLineThroughEveryStringPath() {
    let e = DuckDBError("Invalid Input Error: No magic bytes found at end of file 'bad.parquet'\nstack: …")
    #expect(e.localizedDescription == "Invalid Input Error: No magic bytes found at end of file 'bad.parquet'")
    #expect((e as NSError).localizedDescription == e.firstLine)
    #expect(!e.localizedDescription.contains("The operation couldn"))
    // The parser dump below the first line stays out of every user-facing path.
    #expect(!e.localizedDescription.contains("stack:"))
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
    // Pinned to the extension guard's exact message, not to "httpfs OR HTTPFileSystem":
    // the loose form passes in three of the four states, including extension-guard-only,
    // which would let the disabled_filesystems layer rot away unnoticed.
    #expect(message.contains("requires the extension httpfs"),
            "expected the extension guard to refuse the read; got: \(message)")
}

@Test func disabledFilesystemsReachesConnectionsOpenedAfterIt() throws {
    // Layer 2 of the pair, and the property the whole design rests on: the setting is
    // GLOBAL, so it binds connections opened later — including every per-unit-of-work
    // connection the engine will make. Needs no network and no extension, so it tests the
    // half the httpfs test above can never reach (httpfs never loads, so
    // disabled_filesystems is never consulted on that path). Design spec §11: the two are
    // complementary layers, not belt and braces.
    //
    // A throwaway Database, because disabling the local filesystem is not something the
    // real harden() does — LocalFileSystem is the entire product.
    let db = try Database.inMemory()
    try db.connect().execute("SET disabled_filesystems='LocalFileSystem'")

    var message = ""
    do {
        _ = try db.connect().query("SELECT * FROM read_csv_auto('/etc/hosts')").allRows()
        Issue.record("a local read succeeded on a connection opened after the setting")
    } catch let error as DuckDBError {
        message = error.message
    }
    // MEASURED: current_setting('disabled_filesystems') reads back EMPTY even on the
    // connection that set it, so behavior is the only honest assertion here.
    #expect(message.contains("has been disabled by configuration"),
            "expected the filesystem guard to refuse the read; got: \(message)")
}

@Test func hardenRecordsWhatItActuallyApplied() throws {
    // harden() is non-fatal by design, which used to mean it was also unobservable: four
    // `try?` calls and no caller could tell whether any of them landed. A DuckDB rename
    // would have silently removed a security layer. MEASURED: a typo'd setting throws
    // `Catalog Error: unrecognized configuration parameter`, so the signal was there to
    // be kept.
    let db = try Database.inMemory()
    db.harden()
    #expect(db.hardened == ["disabled_filesystems": true,
                            "autoinstall_known_extensions": true,
                            "autoload_known_extensions": true,
                            "allow_community_extensions": true])
}

@Test func loadExtensionsRejectsANameThatCarriesSQL() throws {
    // LOAD takes no bound parameters, so the name is interpolated. MEASURED before the
    // guard: this exact call created evil.db, attached it, and recorded the whole string
    // as successfully loaded.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-load-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let evil = dir.appendingPathComponent("evil.db")

    let db = try Database.inMemory()
    let injected = "httpfs; ATTACH '\(evil.path)'"
    db.loadExtensions([injected])

    #expect(db.loadedExtensions[injected] == false)
    #expect(!FileManager.default.fileExists(atPath: evil.path),
            "loadExtensions executed the injected ATTACH")
    #expect(Database.isExtensionName("httpfs"))
    #expect(Database.isExtensionName("_x9"))
    #expect(!Database.isExtensionName(""))
    #expect(!Database.isExtensionName("HTTPFS"))
    #expect(!Database.isExtensionName("9lives"))
    #expect(!Database.isExtensionName("http fs"))
    #expect(!Database.isExtensionName("httpfs\n"))
}

@Test func loadExtensionsRecordsAMissingExtensionAsFailed() throws {
    // The dictionary this writes is what spec §11 turns into a policy decision: a missing
    // `delta` extension must refuse the open rather than degrade to a parquet glob. It was
    // entirely untested, LOAD→INSTALL→LOAD fallback included.
    let db = try Database.inMemory()
    db.harden()
    db.loadExtensions(["not_a_real_extension"])
    #expect(db.loadedExtensions["not_a_real_extension"] == false)
}

/// `Connection` is deliberately not Sendable — one unit of work, one connection. `interrupt()`
/// is the documented exception: it is the cancel path, and it exists to be called from
/// somewhere other than the task running the query. This box says that out loud rather than
/// papering over it at the call site.
private struct Interrupter: @unchecked Sendable {
    let con: Connection
    func fire() { con.interrupt() }
}

@Test func interruptCancelsAQueryAlreadyInFlight() throws {
    // Spec §6 keeps both halves of today's cancel mechanism, and this is the half that
    // reaches a query already running. It could have been a no-op, or bound to the wrong
    // handle, and all 41 tests stayed green.
    let con = try Database.inMemory().connect()
    let box = Interrupter(con: con)
    let done = DispatchSemaphore(value: 0)
    // Fires in a loop rather than once: the interrupt flag is cleared when a query begins,
    // so a single call racing ahead of execution is swallowed. No sleeps — the semaphore is
    // the stop signal, and the count below runs ~4 s unimpeded (MEASURED: 0.19 s per 1e8
    // rows), a window four orders of magnitude wider than the interrupt needs.
    let spinner = Thread { while done.wait(timeout: .now()) == .timedOut { box.fire() } }
    spinner.start()
    defer { done.signal() }

    var message = ""
    do {
        _ = try con.query("SELECT count(*) FROM range(2000000000) t(i) WHERE i % 7 = 3").allRows()
        Issue.record("the query ran to completion despite interrupt()")
    } catch let error as DuckDBError {
        message = error.message
    }
    #expect(message.contains("INTERRUPT"), "expected an interrupt error; got: \(message)")
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

@Test func reportsColumnNamesInOrder() throws {
    let con = try Database.inMemory().connect()
    let rs = try con.query("SELECT 1 AS alpha, 2 AS beta")
    #expect(rs.columns.map(\.name) == ["alpha", "beta"])
}

@Test func reportsDecimalScaleAndWidth() throws {
    let con = try Database.inMemory().connect()
    let rs = try con.query("SELECT 1.23::DECIMAL(9,3) AS d")
    #expect(rs.columns[0].typeName == "DECIMAL(9,3)")
    #expect(rs.columns[0].decimalScale == 3)
    #expect(rs.columns[0].decimalWidth == 9)
}

@Test func scalarTypeNamesMatchDuckDBsOwnTypeof() throws {
    // typeName is not cosmetic: downstream classification branches on its PREFIX to pick
    // column alignment, histogram-vs-top-N and cell rendering. Every type below reported
    // the single string "OTHER" until the switch caught up with the decoder, which would
    // have classified every temporal type as `other`. DuckDB's own typeof() is the oracle.
    let con = try Database.inMemory().connect()
    for expr in ["TIMESTAMP_S '2026-01-01'", "TIMESTAMP_MS '2026-01-01'",
                 "TIMESTAMP_NS '2026-01-01'", "TIMETZ '12:00:00+02'",
                 "TIMESTAMPTZ '2026-01-01'", "INTERVAL '1 day'", "'1010'::BIT",
                 "1.23::DECIMAL(9,3)", "1.23::DECIMAL(38,10)", "42::HUGEINT",
                 "'x'::VARCHAR", "'abc'::BLOB", "DATE '2026-01-01'", "TIME '12:00:00'"] {
        let ours = try con.query("SELECT \(expr) AS v").columns[0].typeName
        let theirs = try con.query("SELECT typeof(\(expr)) AS t").allRows()[0][0].display
        #expect(ours == theirs, "typeName disagrees with typeof for \(expr)")
    }
}

@Test func nestedTypeNamesReportTheirShapeRatherThanOTHER() throws {
    // DuckDB's typeof() fully parameterizes these (`INTEGER[]`, `STRUCT(a INTEGER)`,
    // `MAP(INTEGER, INTEGER)`, `INTEGER[3]`, `UNION(a INTEGER)` — all MEASURED), which
    // needs a recursive walk of the logical type. The bare shape is enough: classification
    // reads the prefix, and "OTHER" was the thing that was wrong.
    let con = try Database.inMemory().connect()
    let expected = [
        "[1,2,3]": "LIST",
        "{'a': 1}": "STRUCT",
        "MAP([1],[2])": "MAP",
        "[1,2,3]::INTEGER[3]": "ARRAY",
        "union_value(a := 1)": "UNION",
    ]
    for (expr, name) in expected {
        #expect(try con.query("SELECT \(expr) AS v").columns[0].typeName == name)
    }
    // ENUM reports its own declared type name through typeof(), so it cannot be compared
    // for equality — but "ENUM" is the prefix that classifies it as text.
    try con.execute("CREATE TYPE mood AS ENUM ('ok', 'sad')")
    #expect(try con.query("SELECT 'ok'::mood AS v").columns[0].typeName == "ENUM")
}

@Test func aPrepareFailureThrows() throws {
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        _ = try con.query("SELECT * FROM nope WHERE x = ?", [.int(1)])
    }
}

@Test func bindingAcceptsEveryValueKindWithoutThrowing() throws {
    // Values are read back in Task 5, once chunk decoding exists. This asserts the
    // bind path itself accepts all five cases and executes.
    let con = try Database.inMemory().connect()
    let rs = try con.query(
        "SELECT ?::BOOLEAN AS b, ?::BIGINT AS i, ?::DOUBLE AS d, ?::VARCHAR AS s, ?::VARCHAR AS n",
        [.bool(true), .int(42), .double(1.5), .text("hi"), .null]
    )
    #expect(rs.columns.map(\.name) == ["b", "i", "d", "s", "n"])
}
