import DuckDBKit
import Foundation
import Testing
import TestSupport
@testable import SiftEngine
import SiftCore

// `harden(allowRemote:)` proved end to end, in the only place that can prove it: against a real
// server, with a real `httpfs`. `Tests/DuckDBKitTests/SmokeTests.swift` pins the same branch
// offline (a narrowing SET is refused in one posture and accepted in the other, no network, no
// extension) — that is the mutation-killer the default suite runs. These two are the ones that
// answer "…and does a remote read actually WORK", which no offline test can.
//
// GATED behind SIFT_REMOTE_FACTS=1 for the reason RemoteFactsTests.swift gives: `httpfs` has to be
// present, and `loadExtensions` does LOAD→INSTALL→LOAD, so an unprepared machine reaches for the
// network. The default `swift test` stays offline. The name prefix matters — CI's canary step runs
// `swift test --filter remoteFact`.
//
// Nothing here is `.serialized`: each test owns its own `Database` and its own ephemeral port.

private let remoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

/// The error text DuckDB produced, or `"no error"` when the statement unexpectedly succeeded.
private func failure(_ c: Connection, _ sql: String) -> String {
    do { _ = try c.query(sql).allRows(); return "no error" } catch { return "\(error)" }
}

/// One small parquet file's bytes, and the row count they carry.
private func parquetBytes(rows: Int) throws -> Data {
    let path = (TestTemp.dir("remote-posture") as NSString).appendingPathComponent("a.parquet")
    try Database.inMemory().connect().execute("""
        COPY (SELECT range AS id, 'r' || range AS label FROM range(\(rows)))
        TO '\(path)' (FORMAT parquet)
        """)
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

/// 🔴 **The pair the branch lacked, one test per direction.** `RemoteFactsTests` measures what
/// DuckDB does; this measures Sift's decision. `harden(allowRemote: true)` is the whole point of
/// the Connections work — a session the user chose to make remote — and the only honest proof it
/// works is rows coming back over a socket. The strict half is the same `LOAD`, the same URL,
/// refused. Together they stop "allowRemote does nothing" and "allowRemote is always on" from both
/// looking green: delete the branch either way and exactly one of the two goes red.
///
/// MEASURED (`docs/…/2026-08-16-duckdb-remote-facts.md` §2): the disabled set is per-`Database` and
/// only ever grows, so these are two `Database`s and never a toggle. Both `LOAD httpfs` explicitly —
/// `autoload_known_extensions=false` applies in both postures, and `allowRemote` does not touch it.
@Test(.enabled(if: remoteFacts))
func remoteFactHarden_allowRemoteDecidesWhetherALoadedHttpfsCanRead() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/a.parquet", body: try parquetBytes(rows: 1000))
    let url = "\(server.baseURL)/a.parquet"

    let open = try Database.inMemory()
    open.harden(allowRemote: true)
    open.loadExtensions(["httpfs"])
    try #require(open.loadedExtensions["httpfs"] == .loaded, "the httpfs extension must be installed")
    let permissive = try open.connect()
    // Loopback needs nothing like the default 30 s, and a machine that cannot reach the oracle
    // should say so in seconds — MEASURED on the first CI canary: 244 s to report nothing.
    try permissive.execute("SET GLOBAL http_timeout=5")
    #expect(try permissive.query("SELECT count(*) FROM read_parquet('\(url)')")
        .allRows()[0][0] == .int(1000))
    #expect(!server.requestLog.isEmpty, "the permissive posture never reached the server")

    // The reverse, on the same URL and the same extension: refused before a request is made.
    let locked = try Database.inMemory()
    locked.harden()
    locked.loadExtensions(["httpfs"])
    try #require(locked.loadedExtensions["httpfs"] == .loaded)
    let before = server.requestLog.count
    let text = failure(try locked.connect(), "SELECT count(*) FROM read_parquet('\(url)')")
    #expect(text.contains("Permission Error: File system HTTPFileSystem has been disabled by configuration"),
            "\(text)")
    #expect(server.requestLog.count == before,
            "a refused read must not hit the network: \(server.requestLog.dropFirst(before))")
}

/// 🔴 **The SELECT-only gate does not stop `SELECT * FROM duckdb_secrets()` — that is a read.**
/// Once the Connections work issues a secret it lives on the same `Database` the SQL console runs
/// against (MEASURED §6b: secrets are Database-scoped and visible to every sibling connection), so
/// the only thing between a user's query and the credential is DuckDB's own redaction.
///
/// MEASURED (§6c): redaction is on by default, `duckdb_secrets(redact=false)` is refused, and
/// `SET allow_unredacted_secrets=true` cannot be changed while the database runs — there is no
/// switch here for Sift to get wrong, only an upstream default that this test exists to notice
/// changing. It goes through `wrapUserSQL`, the wrap a console query actually passes, rather than a
/// bare connection: the claim is about the shipped path, not about a DuckDB feature in isolation.
@Test(.enabled(if: remoteFacts))
func remoteFactSecrets_redactionSurvivesTheUserSQLWrap() throws {
    let key = "SUPERSECRETKEY123"
    let keyID = "AKIAEXAMPLEKEYID"

    let database = try Database.inMemory()
    database.harden()
    database.loadExtensions(["httpfs"])   // `TYPE s3` secrets come from httpfs
    try #require(database.loadedExtensions["httpfs"] == .loaded, "the httpfs extension must be installed")
    let con = try database.connect()
    // Bound, never interpolated — MEASURED §6a: every VALUE position of CREATE SECRET binds.
    // Dummy values: nothing here authenticates against anything.
    _ = try con.query("CREATE SECRET leaky (TYPE s3, KEY_ID ?, SECRET ?)", [.text(keyID), .text(key)])

    let (wrapped, params) = wrapUserSQL("SELECT * FROM duckdb_secrets()", limit: 100, offset: 0)
    let cells = try con.query(wrapped, params.map(toDBValue)).allRows().flatMap { $0 }
    try #require(!cells.isEmpty, "the secret was not visible at all — this test proved nothing")

    for cell in cells {
        #expect(!cell.display.contains(key), "a secret value reached the SQL console: \(cell.display)")
    }
    // …and the half that is NOT redacted, which the Connections UI has to respect: `key_id` and
    // `account_name` print in the clear, so anything surfacing duckdb_secrets() leaks identity even
    // though it never leaks the key.
    #expect(cells.contains { $0.display.contains(keyID) },
            "key_id is expected in the clear — if that changed, §6c moved")
}
