import Foundation
import Testing
import TestSupport
@testable import DuckDBKit

// Executable pins for the ten remote-connection measurements in
// docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md. A failure here is not a test bug —
// it means libduckdb's remote behavior moved and the Connections design must move with it.
//
// GATED behind SIFT_REMOTE_FACTS=1 and excluded from the default suite on purpose: every test
// needs `httpfs`/`azure`/`delta` present, and `loadExtensions` does LOAD→INSTALL→LOAD, so a
// machine without them reaches for the network. The default `swift test` must stay offline.
//
//     SIFT_REMOTE_FACTS=1 swift test --filter remoteFact
//
// Nothing here is `.serialized`: every test owns its own `Database` and its own loopback server.

private let remoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

/// A `Database` with the named extensions loaded and `harden()` deliberately NOT called — these
/// tests measure what the engine does when the network filesystems are reachable.
private func db(_ extensions: [String]) throws -> Database {
    let d = try Database.inMemory()
    d.loadExtensions(extensions)
    for name in extensions {
        try #require(d.loadedExtensions[name] == true, "the \(name) extension must be installed")
    }
    return d
}

/// The error text DuckDB produced, or `"no error"` when the statement unexpectedly succeeded.
private func failure(_ c: Connection, _ sql: String) -> String {
    do { _ = try c.query(sql).allRows(); return "no error" } catch { return "\(error)" }
}

// MARK: - 1. Azure registers TWO filesystems, and `harden()` blocks neither

@Test(.enabled(if: remoteFacts))
func remoteFact1_azureRegistersTwoFilesystemsAndHardenBlocksNeither() throws {
    // `SET disabled_filesystems` accepts any string — an unknown name is silently ignored — so the
    // registered names can only be read off the ERROR CLASS: a name that is registered turns the
    // read into a Permission Error that names it, and a name that is not leaves the read to fail
    // further down the stack. No Azure account is involved; the credential error IS the negative.
    func read(disabling name: String, _ url: String) throws -> String {
        let c = try db(["azure"]).connect()
        try c.execute("SET disabled_filesystems='\(name)'")
        return failure(c, "SELECT * FROM read_parquet('\(url)')")
    }

    #expect(try read(disabling: "AzureBlobStorageFileSystem", "az://c/x.parquet")
        .contains("Permission Error: File system AzureBlobStorageFileSystem has been disabled"))
    #expect(try read(disabling: "AzureBlobStorageFileSystem", "azure://c/x.parquet")
        .contains("Permission Error: File system AzureBlobStorageFileSystem has been disabled"))
    #expect(try read(disabling: "AzureDfsStorageFileSystem", "abfss://c@a.dfs.core.windows.net/x.parquet")
        .contains("Permission Error: File system AzureDfsStorageFileSystem has been disabled"))

    // `AzureStorageFileSystem` appears in the extension's own error TEXT but is the C++ base class,
    // not a registered filesystem: disabling it blocks nothing, and az:// runs on to credentials.
    #expect(try read(disabling: "AzureStorageFileSystem", "az://c/x.parquet")
        .contains("No valid Azure credentials found"))

    // The consequence, pinned: `harden()`'s frozen four disable HTTPFileSystem and S3FileSystem
    // only, so the moment `azure` is loaded, az:// egress is wide open. Adding azure as a core
    // extension REQUIRES adding both names above to that list.
    let hardened = try Database.inMemory()
    hardened.harden()
    hardened.loadExtensions(["azure"])
    try #require(hardened.loadedExtensions["azure"] == true)
    let text = failure(try hardened.connect(), "SELECT * FROM read_parquet('az://c/x.parquet')")
    #expect(!text.contains("Permission Error"), "harden() must not be assumed to cover Azure")
    #expect(text.contains("No valid Azure credentials found"))
}

// MARK: - 2. `disabled_filesystems` only ever grows, and it is per-Database

@Test(.enabled(if: remoteFacts))
func remoteFact2_disabledFilesystemsCanOnlyEverBeBroadened() throws {
    let database = try db(["httpfs"])
    let a = try database.connect()
    let b = try database.connect()

    try a.execute("SET disabled_filesystems='HTTPFileSystem'")
    try a.execute("SET disabled_filesystems='HTTPFileSystem,S3FileSystem'")   // broadening is fine

    // Narrowing, clearing and RESET are all refused — the set is monotonic for the life of the
    // Database. This is why "enable remote for this window" cannot be a live toggle.
    for narrowing in ["SET disabled_filesystems='HTTPFileSystem'", "SET disabled_filesystems=''"] {
        let text = failure(a, narrowing)
        #expect(text.contains("has been disabled previously, it cannot be re-enabled"), "\(text)")
    }
    #expect(failure(a, "RESET disabled_filesystems")
        .contains("has been disabled previously, it cannot be re-enabled"))

    // Database-wide, not connection-local: the sibling that never issued the SET is blocked, and
    // so is a connection opened afterwards.
    let c = try database.connect()
    for connection in [b, c] {
        #expect(failure(connection, "SELECT * FROM read_csv('http://127.0.0.1:9/nope.csv')")
            .contains("Permission Error: File system HTTPFileSystem has been disabled"))
    }

    // A NEW Database in the same process is clean — the reset is a Database restart, not an app
    // restart. Port 9 is discard/closed, so this fails at connect, never on the network.
    let second = try db(["httpfs"])
    let fresh = failure(try second.connect(), "SELECT * FROM read_csv('http://127.0.0.1:9/nope.csv')")
    #expect(!fresh.contains("Permission Error"), "\(fresh)")
    #expect(fresh.contains("Could not connect to server"))
}

// MARK: - 3. `delta_scan` over http:// never reaches the server

@Test(.enabled(if: remoteFacts))
func remoteFact3_deltaScanOverHttpFailsInsideTheKernel() throws {
    let dir = TestTemp.dir("remote-delta")
    let root = try makeDeltaFixture(try Database.inMemory().connect(), dir)

    var files: [String: Data] = [:]
    for rel in try FileManager.default.subpathsOfDirectory(atPath: root) {
        let full = (root as NSString).appendingPathComponent(rel)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
        if !isDir.boolValue { files["/dtable/" + rel] = try Data(contentsOf: URL(fileURLWithPath: full)) }
    }
    let server = try LoopbackServer(files: files)
    defer { server.stop() }

    // Local control: the fixture is a valid two-version table and the tombstone is honored.
    let local = try db(["delta"]).connect()
    #expect(try local.query("SELECT count(*) FROM delta_scan('\(root)')").allRows()[0][0] == .int(100))

    // Over http it fails inside delta-kernel-rs's own object_store — which is NOT httpfs, so
    // loading httpfs does not help — while looking for `_delta_log/_last_checkpoint`.
    let remote = try db(["delta", "httpfs"]).connect()
    server.clearLog()
    let text = failure(remote, "SELECT count(*) FROM delta_scan('\(server.base)/dtable')")
    #expect(text.contains("ObjectStoreError"), "\(text)")
    #expect(text.contains("_delta_log/_last_checkpoint"), "\(text)")
    #expect(server.log.isEmpty, "not one request reached the server: \(server.log)")

    // …and the fallback the frozen contract forbids does work over http, which is exactly why it
    // is forbidden: a raw parquet read sees the 150 rows including the tombstoned file.
    let glob = try remote.query(
        "SELECT count(*) FROM read_parquet(['\(server.base)/dtable/part-0.parquet',"
            + "'\(server.base)/dtable/part-1.parquet'])").allRows()[0][0]
    #expect(glob == .int(150))
}

// MARK: - 4. Remote globs are refused, and the escape hatch does not glob

@Test(.enabled(if: remoteFacts))
func remoteFact4_httpGlobsAreRefusedNotExpanded() throws {
    let server = try LoopbackServer(files: try parquetPair())
    defer { server.stop() }
    let c = try db(["httpfs"]).connect()

    #expect(try c.query("SELECT current_setting('allow_asterisks_in_http_paths')")
        .allRows()[0][0] == .bool(false))

    // The message carries DuckDB's own grammar slip ("file is are not supported") — matched loosely
    // so a typo fix upstream does not fail this, and the *class* is what matters.
    for sql in ["SELECT count(*) FROM read_parquet('\(server.base)/*.parquet')",
                "SELECT count(*) FROM glob('\(server.base)/*.parquet')"] {
        let text = failure(c, sql)
        #expect(text.contains("Invalid Input Error"), "\(text)")
        #expect(text.contains("Globs (`*`) for generic HTTP file"), "\(text)")
    }
    #expect(server.log.isEmpty, "a refused glob must not hit the network: \(server.log)")

    // `allow_asterisks_in_http_paths=true` does not enable globbing — it stops treating `*` as one,
    // so the asterisk is sent as a literal path character and the server 404s.
    try c.execute("SET allow_asterisks_in_http_paths=true")
    server.clearLog()
    #expect(failure(c, "SELECT count(*) FROM read_parquet('\(server.base)/*.parquet')")
        .contains("404"))
    #expect(server.log.map(\.path) == ["/*.parquet"], "\(server.log)")

    // An explicit LIST is the supported multi-file form.
    let listed = try c.query(
        "SELECT count(*) FROM read_parquet(['\(server.base)/a.parquet','\(server.base)/b.parquet'])")
    #expect(try listed.allRows()[0][0] == .int(2000))
}

// MARK: - 5. `read_blob` over http is byte-exact and downloads the whole object

@Test(.enabled(if: remoteFacts))
func remoteFact5_readBlobOverHttpIsByteExactAndUnchunked() throws {
    let dir = TestTemp.dir("remote-blob")
    let path = (dir as NSString).appendingPathComponent("blob.bin")
    var blob = Data(); blob.reserveCapacity(4 << 20)
    var seed: UInt64 = 88_172_645_463_325_252
    for _ in 0..<(4 << 20) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        blob.append(UInt8(seed & 0xFF))
    }
    try blob.write(to: URL(fileURLWithPath: path))

    let server = try LoopbackServer(files: ["/blob.bin": blob])
    defer { server.stop() }
    let c = try db(["httpfs"]).connect()

    let remote = try c.query(
        "SELECT octet_length(content), md5(content) FROM read_blob('\(server.base)/blob.bin')").allRows()[0]
    let onDisk = try c.query(
        "SELECT octet_length(content), md5(content) FROM read_blob('\(path)')").allRows()[0]
    #expect(remote[0] == .int(Int64(blob.count)))
    #expect(remote[1] == onDisk[1], "read_blob over http must be byte-for-byte the local bytes")

    // One HEAD for the size, then ONE GET whose Range spans the entire object: the header is
    // present but this is a whole-object download, not a chunked or partial read. The planned
    // remote-xlsx path therefore pays the full file every time.
    let gets = server.log.filter { $0.method == "GET" }
    #expect(server.log.filter { $0.method == "HEAD" }.count == 1, "\(server.log)")
    #expect(gets.count == 1, "\(server.log)")
    #expect(gets.first?.range == "bytes=0-\(blob.count - 1)", "\(server.log)")
    #expect(gets.first?.sent == blob.count)
}

// MARK: - 6. `CREATE SECRET` — bindable, temporary, Database-scoped, redacted

@Test(.enabled(if: remoteFacts))
func remoteFact6a_createSecretAcceptsBoundValuesButNotABoundName() throws {
    let c = try db(["azure", "httpfs"]).connect()

    // Every VALUE position binds, including the ones that carry credentials. Only the secret's
    // NAME is a parser-level identifier and cannot be bound.
    _ = try c.query("CREATE SECRET s1 (TYPE azure, ACCOUNT_NAME ?)", [.text("bound_account")])
    _ = try c.query("CREATE SECRET s2 (TYPE azure, ACCOUNT_NAME ?, SCOPE ?)",
                    [.text("scoped"), .text("az://only-this-container")])
    _ = try c.query("CREATE SECRET s3 (TYPE s3, KEY_ID ?, SECRET ?)", [.text("AKIA_ID"), .text("SEKRIT")])
    #expect(failure(c, "CREATE SECRET ? (TYPE azure, ACCOUNT_NAME 'x')").contains("Parser Error"))

    // The bound values land verbatim — the bind is real, not a silently-dropped placeholder.
    func secretString(_ name: String) throws -> String {
        guard case .text(let s) = try c.query(
            "SELECT secret_string FROM duckdb_secrets() WHERE name = ?", [.text(name)]
        ).allRows()[0][0] else { Issue.record("expected text"); return "" }
        return s
    }
    #expect(try secretString("s1").contains("account_name=bound_account"))
    #expect(try secretString("s2").contains("scope=az://only-this-container"))
    #expect(try secretString("s3").contains("key_id=AKIA_ID"))
}

@Test(.enabled(if: remoteFacts))
func remoteFact6b_secretsAreDatabaseScopedNotConnectionScoped() throws {
    // The highest-stakes fact of the ten: the design issues a secret on the engine's own
    // connection and reads through throwaway connections. That only works because the secret
    // manager hangs off the Database, not the connection.
    let database = try db(["azure"])
    do {
        let maker = try database.connect()
        try maker.execute("CREATE SECRET issued (TYPE azure, ACCOUNT_NAME 'from_a_dead_connection')")
    }   // maker is released here — duckdb_disconnect has run

    let reader = try database.connect()
    let rows = try reader.query(
        "SELECT name, persistent, storage FROM duckdb_secrets()").allRows()
    #expect(rows.count == 1)
    #expect(rows[0][0] == .text("issued"))
    #expect(try reader.query("SELECT name FROM which_secret('az://c/x.parquet', 'azure')")
        .allRows()[0][0] == .text("issued"))

    // …and it stops at the Database boundary: a second Database in the same process sees nothing.
    let other = try db(["azure"])
    #expect(try other.connect().query("SELECT count(*) FROM duckdb_secrets()").allRows()[0][0] == .int(0))
}

@Test(.enabled(if: remoteFacts))
func remoteFact6c_secretsAreTemporaryByDefaultAndRedactedOnRead() throws {
    let dir = TestTemp.dir("remote-secret")
    let store = (dir as NSString).appendingPathComponent("store.duckdb")
    let secretDir = (dir as NSString).appendingPathComponent("secrets")
    let key = "SUPERSECRETKEY123"

    do {
        let database = try Database(path: store)
        database.loadExtensions(["azure"])
        try #require(database.loadedExtensions["azure"] == true)
        let c = try database.connect()
        try c.execute("SET secret_directory='\(secretDir)'")
        try c.execute("""
            CREATE SECRET tmp (TYPE azure, ACCOUNT_NAME 'acct', CONNECTION_STRING \
            'DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=\(key);EndpointSuffix=core.windows.net')
            """)
        let row = try c.query(
            "SELECT persistent, storage, secret_string FROM duckdb_secrets()").allRows()[0]
        #expect(row[0] == .bool(false), "TEMPORARY is the default")
        #expect(row[1] == .text("memory"))

        // Redaction is on by default and covers the sensitive fields only.
        guard case .text(let printed) = row[2] else { Issue.record("expected text"); return }
        #expect(printed.contains("connection_string=redacted"))
        #expect(!printed.contains(key))
        #expect(printed.contains("account_name=acct"))

        // Unredacted display is refused, and the switch that would allow it is start-up only —
        // a running Database can never be talked into printing a credential.
        #expect(try c.query("SELECT current_setting('allow_unredacted_secrets')")
            .allRows()[0][0] == .bool(false))
        #expect(failure(c, "SELECT * FROM duckdb_secrets(redact=false)")
            .contains("Displaying unredacted secrets is disabled"))
        #expect(failure(c, "SET allow_unredacted_secrets=true")
            .contains("Cannot change allow_unredacted_secrets setting while database is running"))

        try c.execute("CHECKPOINT")
    }

    // Nothing touched disk: not the database file, not the secret directory.
    let bytes = try Data(contentsOf: URL(fileURLWithPath: store))
    #expect(bytes.range(of: Data(key.utf8)) == nil, "a temporary secret must never reach the store")
    #expect(!FileManager.default.fileExists(atPath: secretDir),
            "a temporary secret must not create secret_directory")

    // Reopening the same file confirms it: the secret is gone.
    let reopened = try Database(path: store)
    reopened.loadExtensions(["azure"])
    let c = try reopened.connect()
    try c.execute("SET secret_directory='\(secretDir)'")
    #expect(try c.query("SELECT count(*) FROM duckdb_secrets()").allRows()[0][0] == .int(0))
}

// MARK: - 7. CSV over http is a whole-object download; ranges are load-bearing

@Test(.enabled(if: remoteFacts))
func remoteFact7a_csvOverHttpDownloadsTheWholeObjectWhateverTheSampleSize() throws {
    let csv = try makeCSV(rows: 400_000)
    let server = try LoopbackServer(files: ["/data.csv": csv])
    defer { server.stop() }

    // sniff_csv reads the whole object. `sample_size` bounds the ROWS INSPECTED, not the bytes
    // fetched — the same 8 MB crosses the wire either way. Staging a remote CSV on open is
    // therefore not a convenience, it is the only way to pay for the download once.
    for sql in ["SELECT Columns::VARCHAR FROM sniff_csv('\(server.base)/data.csv')",
                "SELECT Columns::VARCHAR FROM sniff_csv('\(server.base)/data.csv', sample_size=20)"] {
        let c = try db(["httpfs"]).connect()
        server.clearLog()
        _ = try c.query(sql).allRows()
        let gets = server.log.filter { $0.method == "GET" }
        #expect(gets.count == 1, "\(server.log)")
        #expect(gets.first?.sent == csv.count, "the whole object, every time: \(server.log)")
    }

    // A plain `read_csv … LIMIT 5` fetches the object TWICE — sniff pass, then scan pass.
    let c = try db(["httpfs"]).connect()
    server.clearLog()
    _ = try c.query("SELECT * FROM read_csv('\(server.base)/data.csv') LIMIT 5").allRows()
    #expect(server.log.filter { $0.method == "GET" }.reduce(0) { $0 + $1.sent } == 2 * csv.count,
            "\(server.log)")
}

@Test(.enabled(if: remoteFacts))
func remoteFact7b_aServerThatRefusesRangesFailsButOneThatIgnoresThemWorks() throws {
    let csv = try makeCSV(rows: 2000)

    // 416 is fatal, after the initial GET plus `http_retries` (3) more. The retry wait is turned
    // down so the pin costs milliseconds rather than the default 100/400/1600 ms backoff.
    let rejecting = try LoopbackServer(files: ["/data.csv": csv], mode: .reject)
    defer { rejecting.stop() }
    let strict = try db(["httpfs"]).connect()
    try strict.execute("SET http_retry_wait_ms=1")
    let text = failure(strict, "SELECT count(*) FROM read_csv('\(rejecting.base)/data.csv')")
    #expect(text.contains("416"), "\(text)")
    #expect(rejecting.log.filter { $0.method == "GET" }.count == 4, "1 + http_retries: \(rejecting.log)")

    // A server that IGNORES the Range header and answers 200 with the whole body is handled
    // transparently — no error, right answer. Only an outright refusal breaks the read.
    let lenient = try LoopbackServer(files: ["/data.csv": csv], mode: .ignore)
    defer { lenient.stop() }
    let relaxed = try db(["httpfs"]).connect()
    #expect(try relaxed.query("SELECT count(*) FROM read_csv('\(lenient.base)/data.csv')")
        .allRows()[0][0] == .int(2000))
    #expect(lenient.log.allSatisfy { $0.status == 200 }, "\(lenient.log)")
}

@Test(.enabled(if: remoteFacts))
func remoteFact7c_parquetOverHttpReallyDoesRangeRead() throws {
    // The other half of fact 7, and the one the whole "read remote parquet in place" plan rests
    // on: parquet fetches the footer and only the row groups a query needs.
    let dir = TestTemp.dir("remote-parquet")
    let path = (dir as NSString).appendingPathComponent("big.parquet")
    let maker = try Database.inMemory().connect()
    try maker.execute("""
        COPY (SELECT range AS id, 'name-' || range AS name, range % 97 AS m FROM range(2000000))
        TO '\(path)' (FORMAT parquet)
        """)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let server = try LoopbackServer(files: ["/big.parquet": bytes])
    defer { server.stop() }

    let c = try db(["httpfs"]).connect()
    #expect(try c.query("SELECT count(*) FROM read_parquet('\(server.base)/big.parquet')")
        .allRows()[0][0] == .int(2_000_000))
    let transferred = server.log.reduce(0) { $0 + $1.sent }
    #expect(transferred < bytes.count / 20,
            "count(*) must be answered from the footer alone: \(transferred) of \(bytes.count) B")
    #expect(server.log.filter { $0.method == "GET" }.allSatisfy { $0.status == 206 }, "\(server.log)")
}

// MARK: - 8. The httpfs knobs, and what `scope` in duckdb_settings() does NOT mean

@Test(.enabled(if: remoteFacts))
func remoteFact8_httpTimeoutAndRetryKnobsAndTheirRealScope() throws {
    let database = try db(["httpfs"])
    let a = try database.connect()
    let b = try database.connect()

    // Defaults, as shipped. These are the numbers any timeout UI has to start from.
    for (name, value) in [("http_timeout", Cell.int(30)), ("http_retries", .int(3)),
                          ("http_retry_wait_ms", .int(100)), ("http_retry_backoff", .int(4)),
                          ("http_keep_alive", .bool(true)), ("enable_http_metadata_cache", .bool(false)),
                          ("allow_asterisks_in_http_paths", .bool(false))] {
        #expect(try a.query("SELECT current_setting('\(name)')").allRows()[0][0] == value, "\(name)")
        #expect(try a.query("SELECT scope FROM duckdb_settings() WHERE name = ?", [.text(name)])
            .allRows()[0][0] == .text("GLOBAL"), "\(name)")
    }

    // …and the trap. `scope` says GLOBAL, but a bare SET is SESSION-local: the sibling connection
    // and every connection opened afterwards keep the default. Sift hands work to throwaway
    // connections, so a bare `SET http_timeout` would silently do nothing.
    try a.execute("SET http_timeout=3000")
    #expect(try a.query("SELECT current_setting('http_timeout')").allRows()[0][0] == .int(3000))
    #expect(try b.query("SELECT current_setting('http_timeout')").allRows()[0][0] == .int(30))

    try a.execute("SET GLOBAL http_timeout=10000")
    #expect(try b.query("SELECT current_setting('http_timeout')").allRows()[0][0] == .int(10000))
    #expect(try database.connect().query("SELECT current_setting('http_timeout')")
        .allRows()[0][0] == .int(10000))
    // A session override still wins over the global on the connection that set it.
    #expect(try a.query("SELECT current_setting('http_timeout')").allRows()[0][0] == .int(3000))

    // Before `httpfs` is loaded these knobs are not in duckdb_settings() at all — and yet SET
    // accepts them, silently, while refusing a name no extension owns. So a pre-LOAD `SET` is
    // neither an error nor an effect: the value sticks to that one connection, and every
    // connection opened after the LOAD still gets the default.
    let pre = try Database.inMemory()
    let before = try pre.connect()
    #expect(try before.query("""
        SELECT count(*) FROM duckdb_settings()
        WHERE name IN ('http_timeout', 'http_retries', 'http_retry_wait_ms', 'http_retry_backoff')
        """).allRows()[0][0] == .int(0))
    try before.execute("SET http_retries=7")
    #expect(throws: DuckDBError.self) { try before.execute("SET totally_made_up_setting=1") }
    pre.loadExtensions(["httpfs"])
    try #require(pre.loadedExtensions["httpfs"] == true)
    #expect(try before.query("SELECT current_setting('http_retries')").allRows()[0][0] == .int(7))
    #expect(try pre.connect().query("SELECT current_setting('http_retries')").allRows()[0][0] == .int(3))
}

// MARK: - 9. The azure transport option exists on 1.5.5

@Test(.enabled(if: remoteFacts))
func remoteFact9_azureTransportOptionTypeExists() throws {
    let c = try db(["azure"]).connect()
    let row = try c.query("""
        SELECT value, description, scope FROM duckdb_settings()
        WHERE name = 'azure_transport_option_type'
        """).allRows()
    #expect(row.count == 1, "azure_transport_option_type must exist on 1.5.5")
    #expect(row[0][0] == .text("default"))
    guard case .text(let description) = row[0][1] else { Issue.record("expected text"); return }
    #expect(description.contains("default, curl"), "the two accepted values")
    try c.execute("SET azure_transport_option_type='curl'")
    #expect(try c.query("SELECT current_setting('azure_transport_option_type')")
        .allRows()[0][0] == .text("curl"))
}

// MARK: - Fixtures

private func parquetPair() throws -> [String: Data] {
    let dir = TestTemp.dir("remote-pair")
    let c = try Database.inMemory().connect()
    var files: [String: Data] = [:]
    for (name, from) in [("a", 0), ("b", 1000)] {
        let path = (dir as NSString).appendingPathComponent("\(name).parquet")
        try c.execute("""
            COPY (SELECT range AS id, '\(name)' || range AS label FROM range(\(from), \(from + 1000)))
            TO '\(path)' (FORMAT parquet)
            """)
        files["/\(name).parquet"] = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    return files
}

private func makeCSV(rows: Int) throws -> Data {
    let path = (TestTemp.dir("remote-csv") as NSString).appendingPathComponent("data.csv")
    try Database.inMemory().connect().execute("""
        COPY (SELECT range AS id, 'name-' || range AS name, range % 97 AS m FROM range(\(rows)))
        TO '\(path)' (FORMAT csv, HEADER)
        """)
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

/// A minimal real two-version Delta table: version 0 adds two parquet files, version 1 tombstones
/// the second, which stays physically on disk. A trimmed copy of the builder in
/// `DuckDB155FactsTests.swift` — SwiftPM test targets cannot import one another, so the third copy
/// is the cost of not editing `Package.swift`.
private func makeDeltaFixture(_ c: Connection, _ dir: String) throws -> String {
    let root = (dir as NSString).appendingPathComponent("dtable")
    let logDir = (root as NSString).appendingPathComponent("_delta_log")
    try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    func entry(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
    func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               as: UTF8.self) + "\n"
    }
    func size(_ name: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: entry(name))[.size] as? Int) ?? 0
    }

    try c.execute("COPY (SELECT range AS id, 'a' AS g FROM range(100)) "
        + "TO '\(entry("part-0.parquet"))' (FORMAT parquet)")
    try c.execute("COPY (SELECT range AS id, 'b' AS g FROM range(100, 150)) "
        + "TO '\(entry("part-1.parquet"))' (FORMAT parquet)")

    let ms = 1_770_000_000_000
    let schema = try line([
        "type": "struct",
        "fields": [["name": "id", "type": "long", "nullable": true, "metadata": [String: Any]()],
                   ["name": "g", "type": "string", "nullable": true, "metadata": [String: Any]()]],
    ]).trimmingCharacters(in: .newlines)

    var v0 = try line(["protocol": ["minReaderVersion": 1, "minWriterVersion": 2]])
    v0 += try line(["metaData": ["id": UUID().uuidString.lowercased(),
                                 "format": ["provider": "parquet", "options": [String: Any]()],
                                 "schemaString": schema, "partitionColumns": [String](),
                                 "configuration": [String: Any](), "createdTime": ms]])
    for part in ["part-0.parquet", "part-1.parquet"] {
        v0 += try line(["add": ["path": part, "partitionValues": [String: Any](),
                                "size": try size(part), "modificationTime": ms, "dataChange": true]])
    }
    try v0.write(toFile: (logDir as NSString).appendingPathComponent("00000000000000000000.json"),
                 atomically: true, encoding: .utf8)
    try line(["remove": ["path": "part-1.parquet", "deletionTimestamp": ms + 1000,
                         "dataChange": true, "partitionValues": [String: Any](),
                         "size": try size("part-1.parquet")]])
        .write(toFile: (logDir as NSString).appendingPathComponent("00000000000000000001.json"),
               atomically: true, encoding: .utf8)
    return root
}

// MARK: - The test oracle

/// A small HTTP/1.1 origin server on 127.0.0.1: a fixed in-memory file map, a log of every request
/// line, and a switch for how it treats `Range`.
///
/// MEASURED 2026-08-13 (macOS 26 / Darwin 25.3, Swift 6.3): every `NWListener` configuration —
/// `on: .any`, an explicit port, with or without `requiredLocalEndpoint` — fails with
/// `POSIXErrorCode(22): Invalid argument`, compiled and interpreted alike, while a plain BSD
/// `bind()` on the same port succeeds. Hence Darwin sockets rather than the Network framework.
/// ponytail: a test oracle, not a web server — no routing, no MIME table, no chunked encoding.
final class LoopbackServer: @unchecked Sendable {
    enum RangeMode { case honor, ignore, reject }

    struct Hit: CustomStringConvertible, Sendable {
        let method: String, path: String, range: String?, status: Int, sent: Int
        var description: String { "\(method) \(path) range=\(range ?? "-") -> \(status) (\(sent)B)" }
    }

    private let fd: Int32
    private let files: [String: Data]
    private let mode: RangeMode
    private let lock = NSLock()
    private var hits: [Hit] = []
    private var stopped = false
    let port: UInt16

    var log: [Hit] { lock.lock(); defer { lock.unlock() }; return hits }
    var base: String { "http://127.0.0.1:\(port)" }
    func clearLog() { lock.lock(); hits = []; lock.unlock() }

    init(files: [String: Data], mode: RangeMode = .honor) throws {
        self.files = files
        self.mode = mode

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                 // an ephemeral port
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian  // 127.0.0.1 and nothing else
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else { close(sock); throw POSIXError(.EADDRINUSE) }

        var me = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        fd = sock
        port = UInt16(bigEndian: me.sin_port)

        DispatchQueue.global().async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                lock.lock(); let done = stopped; lock.unlock()
                if done || client < 0 { if client >= 0 { close(client) }; return }
                DispatchQueue.global().async { [self] in handle(client) }
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        close(fd)
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                if !sendAll(client, respond(to: head)) { return }
            }
            let n = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func sendAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func respond(to head: String) -> Data {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = request.first ?? "?"
        let path = request.count > 1 ? String(request[1].prefix { $0 != "?" }) : "/"
        let range = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        func reply(_ status: Int, _ reason: String, _ extra: [String], _ body: Data) -> Data {
            lock.lock()
            hits.append(Hit(method: method, path: path, range: range, status: status,
                            sent: method == "HEAD" ? 0 : body.count))
            lock.unlock()
            var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
            for line in extra { header += line + "\r\n" }
            return Data((header + "\r\n").utf8) + (method == "HEAD" ? Data() : body)
        }

        guard let body = files[path] else { return reply(404, "Not Found", [], Data()) }
        let acceptRanges = ["Accept-Ranges: " + (mode == .honor ? "bytes" : "none")]

        // "bytes=start-end", end optional. Anything else falls through to a 200.
        if let range, mode != .ignore,
           let spec = range.split(separator: "=").last?
               .split(separator: "-", omittingEmptySubsequences: false),
           let start = Int(spec.first ?? "") {
            if mode == .reject { return reply(416, "Range Not Satisfiable", acceptRanges, Data()) }
            let end = min(Int(spec.count > 1 ? spec[1] : "") ?? (body.count - 1), body.count - 1)
            guard start <= end else { return reply(416, "Range Not Satisfiable", acceptRanges, Data()) }
            return reply(206, "Partial Content",
                         acceptRanges + ["Content-Range: bytes \(start)-\(end)/\(body.count)"],
                         Data(body[start...end]))
        }
        return reply(200, "OK", acceptRanges, body)
    }
}
