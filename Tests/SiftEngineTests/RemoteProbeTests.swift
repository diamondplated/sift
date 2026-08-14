import Darwin
import DuckDBKit
import Foundation
import Testing
import TestSupport
@testable import SiftEngine
import SiftCore

// `RemoteProbe.swift`, against the loopback oracle.
//
// Almost everything here runs in the DEFAULT suite. Only the tests that need DuckDB to have
// `httpfs` — the DESCRIBE probes, `read_blob`, the parquet-in-place spec — are gated behind
// `SIFT_REMOTE_FACTS=1`, because `loadExtensions` does LOAD→INSTALL→LOAD and would put
// `extensions.duckdb.org` on the critical path of `swift test`. The HEAD identity tests need no
// extension at all (they are `URLSession` talking to a socket), and neither do the refusals, which
// is the point of refusing before the wire.
//
// Gated names carry the `remoteFact` prefix so CI's canary step (`swift test --filter remoteFact`)
// picks them up, matching `RemotePostureTests`.
//
// Nothing here is `.serialized`: every test owns its own server, its own ephemeral port and its own
// `Database`.

private let remoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

/// A `RemoteURL` or a failed test — every one of these strings is a literal in this file.
private func remote(_ text: String) throws -> RemoteURL {
    try #require(classifyRemote(text), "\(text) did not classify as remote")
}

/// A connection that can parse a remote read but can never make one: `harden()`'s deny list means
/// the DESCRIBE probes fail locally and instantly, so a refusal test never touches the network.
private func offlineConnection() throws -> Connection {
    let database = try Database.inMemory()
    database.harden()
    return try database.connect()
}

/// Non-compressible bytes — a pattern a proxy cannot silently re-encode into something shorter.
private func noise(_ count: Int) -> Data {
    var out = Data(capacity: count)
    for i in 0..<count { out.append(UInt8((i &* 31 &+ 7) % 256)) }
    return out
}

private func parquetBytes(rows: Int) throws -> Data {
    let path = (TestTemp.dir("remote-probe") as NSString).appendingPathComponent("a.parquet")
    try Database.inMemory().connect().execute("""
        COPY (SELECT range AS id, 'r' || range AS label FROM range(\(rows)))
        TO '\(path)' (FORMAT parquet)
        """)
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

/// A permissive `Database` with `httpfs` loaded and a loopback-sized timeout.
private func remoteConnection() throws -> Connection {
    let database = try Database.inMemory()
    database.harden(allowRemote: true)
    database.loadExtensions(["httpfs"])
    try #require(database.loadedExtensions["httpfs"] == .loaded, "httpfs must be installed")
    let con = try database.connect()
    // GLOBAL, not a bare SET (spike §8 — a bare SET configures one connection and no queries), and
    // 5 s rather than the default 30: a machine that cannot reach the oracle should say so in
    // seconds. MEASURED on the first CI canary: 244 s to report nothing.
    try con.execute("SET GLOBAL http_timeout=5")
    return con
}

// MARK: - identity

@Test
func remoteIdentityReadsEtagDateLengthAndRangeSupportOffOneHead() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let body = Data("id,name\n1,a\n".utf8)
    server.register(
        path: "/a.csv", body: body,
        headers: ["ETag": "\"v1\"", "Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"]
    )

    let identity = try #require(await remoteIdentity(try remote("\(server.baseURL)/a.csv")))
    #expect(identity.etag == "\"v1\"")
    #expect(identity.contentLength == body.count)
    #expect(identity.acceptsRanges)
    // 2026-10-21T07:28:00Z. Spelled as the arithmetic rather than as a magic number so the
    // assertion says what it means; a formatter would put the machine's locale in the answer.
    #expect(identity.lastModifiedMs == 1_792_567_680_000)

    let log = server.requestLog
    #expect(log.map(\.method) == ["HEAD"], "an identity probe is one HEAD and nothing else: \(log)")
    #expect(log.allSatisfy { $0.bytesSent == 0 }, "a HEAD must not move the object: \(log)")
}

@Test
func aServerWithNoEtagStillYieldsALastModifiedAndALength() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(
        path: "/a.csv", body: Data("id\n1\n".utf8),
        headers: ["Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"]
    )

    let identity = try #require(await remoteIdentity(try remote("\(server.baseURL)/a.csv")))
    #expect(identity.etag == nil)
    #expect(identity.lastModifiedMs == 784_111_777_000)
    #expect(identity.contentLength == 5)
    // …and that is a REAL identity: `lm` + `len` together are the HTTP twin of (mtime, size).
    #expect(remoteStagingToken(
        sanitizedURL: "u", etag: identity.etag, lastModifiedMs: identity.lastModifiedMs,
        contentLength: identity.contentLength, fetchedAtNs: 7
    ) == "v3|remote|u|lm=784111777000|len=5")
}

@Test
func acceptsRangesFollowsTheHeaderRatherThanHope() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    // MEASURED (spike §7b): a server that IGNORES `Range` answers 200 with the whole body and
    // advertises `Accept-Ranges: none`. Believing it supported ranges is how a remote parquet plan
    // turns into a whole-object download per statement.
    server.register(path: "/no.parquet", body: Data("PAR1".utf8), rangeMode: .ignore)
    server.register(path: "/yes.parquet", body: Data("PAR1".utf8), rangeMode: .honor)

    let no = try #require(await remoteIdentity(try remote("\(server.baseURL)/no.parquet")))
    let yes = try #require(await remoteIdentity(try remote("\(server.baseURL)/yes.parquet")))
    #expect(!no.acceptsRanges)
    #expect(yes.acceptsRanges)
}

@Test
func anUnparseableLastModifiedIsNoLastModifiedRatherThanAGuess() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    // RFC 850, which RFC 9110 lists as obsolete and which nothing generates any more. Falling
    // through to `nil` costs a re-download; guessing a date adopts the wrong cached copy.
    server.register(
        path: "/a.csv", body: Data("id\n".utf8),
        headers: ["Last-Modified": "Sunday, 06-Nov-94 08:49:37 GMT"]
    )
    let identity = try #require(await remoteIdentity(try remote("\(server.baseURL)/a.csv")))
    #expect(identity.lastModifiedMs == nil)
    #expect(httpDateMs("not a date at all") == nil)
    #expect(httpDateMs("Wed, 21 Xxx 2026 07:28:00 GMT") == nil)
    #expect(httpDateMs("Wed, 21 Oct 2026 07:28 GMT") == nil)
}

@Test
func aServerThatNeverAnswersTimesOutIntoNilRatherThanHanging() async throws {
    // The one personality `LoopbackHTTPServer` deliberately does not have: a socket that accepts
    // the connection and then says nothing at all, which is what a black-holed host looks like.
    let rude = try RudeServer(manner: .silent)
    defer { rude.stop() }

    let started = Date()
    let identity = await remoteIdentity(try remote("\(rude.baseURL)/a.csv"), timeout: 1)
    let elapsed = Date().timeIntervalSince(started)
    #expect(identity == nil)
    #expect(elapsed < 10, "the identity probe hung for \(elapsed)s instead of timing out")
}

@Test
func remoteIdentityIsNilForEveryUrlUrlSessionCouldNotSign() async throws {
    // Not a gap being papered over: the credential for these lives in a DuckDB secret, inside the
    // engine. A HEAD sent from here would be anonymous, and a 403's headers are an identity for an
    // error page. `nil` routes them to the `fetched=` token form, which never adopts a copy.
    for text in [
        "az://container/data.parquet", "azure://container/data.parquet",
        "abfss://c@acct.dfs.core.windows.net/data.parquet", "s3://bucket/data.parquet",
    ] {
        #expect(await remoteIdentity(try remote(text)) == nil, "\(text)")
    }
}

@Test
func aRefusedHeadIsNoIdentityRatherThanAnEmptyOne() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    // 404: the object is not there, so there is nothing to be the identity OF. Returning an
    // all-nil `RemoteIdentity` would let the caller build a `SourceKey` for a file that does not
    // exist.
    #expect(await remoteIdentity(try remote("\(server.baseURL)/gone.csv")) == nil)
    #expect(server.requestLog.map(\.status) == [404])
}

// MARK: - format: the extension table

@Test
func theRemoteExtensionTableHolds() throws {
    let con = try offlineConnection()
    let table: [(String, Fmt)] = [
        ("https://h/a.parquet", .parquet), ("https://h/a.parq", .parquet), ("https://h/a.pq", .parquet),
        ("https://h/a.csv", .csv), ("https://h/a.tsv", .csv), ("https://h/a.txt", .csv),
        ("https://h/a.psv", .csv), ("https://h/a.tab", .csv),
        ("https://h/a.json", .json), ("https://h/a.ndjson", .ndjson), ("https://h/a.jsonl", .ndjson),
        ("https://h/a.xlsx", .xlsx), ("https://h/a.xlsm", .xlsx),
        // Case and percent-encoding are the file's, not ours; the query is not the file's at all.
        ("https://h/A.PARQUET", .parquet),
        ("https://h/deep/path/My%20Report.csv", .csv),
        ("https://acct.blob.core.windows.net/c/a.csv?sv=2024&sig=SECRET", .csv),
        ("s3://bucket/key/a.parquet", .parquet),
        ("az://container/a.xlsx", .xlsx),
        // One compression suffix is seen through, the way `_ext_chain` does locally.
        ("https://h/a.csv.gz", .csv), ("https://h/a.json.zst", .json),
        ("https://h/a.parquet.bz2", .parquet),
    ]
    for (text, expected) in table {
        #expect(try remoteFormat(try remote(text), con: con) == expected, "\(text)")
    }
}

@Test
func aQueryStringNeverDecidesTheFormat() throws {
    let con = try offlineConnection()
    // 🔴 The shipped defect `RemoteURL.effectiveExt` exists for: `NSString.pathExtension` answers
    // "csv" here, so a JSON endpoint would be opened as a CSV. There is no extension in the PATH,
    // so this is an extension-less URL and gets the DESCRIBE probes (which, on this hardened
    // connection, all fail locally).
    let error = #expect(throws: UnsupportedSource.self) {
        try remoteFormat(try remote("https://h/get?id=5&fmt=csv"), con: con)
    }
    #expect(error?.message.contains("no file extension") == true, "\(error?.message ?? "")")
}

@Test
func aRemoteXlsIsRefusedTheWayALocalOneIs() throws {
    let con = try offlineConnection()
    let error = #expect(throws: LegacyXls.self) {
        try remoteFormat(try remote("https://h/books.xls"), con: con)
    }
    #expect(error?.message.contains("re-save as .xlsx") == true, "\(error?.message ?? "")")
}

// MARK: - format: the refusals

@Test
func aRemoteGlobIsRefusedWithoutTouchingTheNetwork() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let con = try offlineConnection()
    for text in [
        "\(server.baseURL)/*.parquet", "\(server.baseURL)/data/*/part.parquet",
        "s3://bucket/2026-*/data.parquet",
    ] {
        let error = #expect(throws: UnsupportedSource.self) {
            try remoteFormat(try remote(text), con: con)
        }
        #expect(error?.message == "Remote folder globs are not supported — open a single object.",
                "\(text): \(error?.message ?? "")")
    }
    #expect(server.requestLog.isEmpty, "a glob refusal must be local: \(server.requestLog)")
}

@Test
func aRemoteDeltaTableIsRefusedWithASentenceThatSaysToDownloadIt() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let con = try offlineConnection()
    // 🔴 MEASURED (spike §3): reading these files as a plain parquet list WORKS and returns 150
    // rows where `delta_scan` returns 100 — the tombstoned rows come back as live data. This
    // refusal is the only thing between a Delta URL and that answer.
    for text in [
        "\(server.baseURL)/dtable/", "\(server.baseURL)/dtable/_delta_log/00000.json",
        "az://c/warehouse/orders/_delta_log", "https://h/lake/orders/",
    ] {
        let error = #expect(throws: UnsupportedSource.self) {
            try remoteFormat(try remote(text), con: con)
        }
        let message = error?.message ?? ""
        #expect(message.contains("Delta"), "\(text): \(message)")
        #expect(message.contains("download it and open the folder locally"), "\(text): \(message)")
    }
    #expect(server.requestLog.isEmpty, "a Delta refusal must be local: \(server.requestLog)")
}

// MARK: - format: the DESCRIBE fallback

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_anExtensionlessParquetIsFoundByRangingNotByDownloading() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let body = try parquetBytes(rows: 200_000)
    server.register(path: "/noext", body: body)
    let con = try remoteConnection()

    #expect(try remoteFormat(try remote("\(server.baseURL)/noext"), con: con) == .parquet)
    let moved = server.requestLog.reduce(0) { $0 + $1.bytesSent }
    #expect(moved > 0, "the probe never reached the server")
    #expect(moved < body.count / 10,
            "the parquet probe downloaded \(moved) of \(body.count) B — it must range-read")
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_jsonIsProbedBeforeCsvBecauseReadCsvAcceptsJson() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/noext", body: Data("[{\"a\":1},{\"a\":2}]".utf8))
    let con = try remoteConnection()

    // 🔴 MEASURED: `DESCRIBE SELECT * FROM read_csv(<that JSON>)` SUCCEEDS, reporting two VARCHAR
    // columns named `[{"a":1}` and `{"a":2}]`. Probing CSV first would open every extension-less
    // JSON document as a table of nonsense, and nothing downstream would notice.
    #expect(try remoteFormat(try remote("\(server.baseURL)/noext"), con: con) == .json)
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_anExtensionlessUrlThatIsNothingSiftReadsGetsOneSentence() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/noext", body: Data(repeating: 0xFF, count: 4096))
    let con = try remoteConnection()

    let error = #expect(throws: UnsupportedSource.self) {
        try remoteFormat(try remote("\(server.baseURL)/noext"), con: con)
    }
    let message = error?.message ?? ""
    #expect(message.contains("noext"), "\(message)")
    #expect(message.contains("parquet, JSON or CSV"), "\(message)")
    #expect(!message.contains("Binder Error") && !message.contains("\n"),
            "a refusal is one sentence, not a parser dump: \(message)")
}

// MARK: - downloading

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_theDownloadIsByteExactWrittenAt0600AndFetchedExactlyOnce() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let body = noise(1024 * 1024)
    server.register(path: "/blob.bin", body: body)
    let con = try remoteConnection()
    let path = TestTemp.path("remote-cache", ".bin")
    // A stale cache file, world-readable, already sitting on the path — the case a fresh-file test
    // would never reach. MEASURED here: `createFile`'s attributes really are applied over an
    // existing file, which is what lets the download be one call rather than a create and a chmod.
    #expect(FileManager.default.createFile(
        atPath: path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644]))

    let count = try downloadRemoteObject(
        con: con, url: try remote("\(server.baseURL)/blob.bin"), to: path
    )

    #expect(count == body.count)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == body, "the cached copy is not the object")
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o600, "a copy of someone's real data must be 0600, was \(mode)")

    // Downloaded ONCE and FULLY: the size probe is a HEAD (spike §5 — `read_blob` is HEAD + one
    // GET whose range spans the object), and the object's bytes cross the wire exactly once.
    let gets = server.requestLog.filter { $0.method == "GET" }
    #expect(gets.count == 1, "\(server.requestLog)")
    #expect(server.requestLog.reduce(0) { $0 + $1.bytesSent } == body.count, "\(server.requestLog)")
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_theCapRefusesBeforeAnyBodyByteWhenTheServerSaysTooBig() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let body = noise(1024 * 1024)
    server.register(path: "/big.bin", body: body)
    let con = try remoteConnection()
    let path = TestTemp.path("remote-cache", ".bin")

    let error = #expect(throws: UnsupportedSource.self) {
        try downloadRemoteObject(
            con: con, url: try remote("\(server.baseURL)/big.bin"), to: path, capBytes: 4096)
    }
    let message = error?.message ?? ""
    #expect(message.contains("1 MB") && message.contains("4096 bytes"), "\(message)")
    #expect(message.contains("open the file locally"), "\(message)")

    // The point of the check: nothing was downloaded, so it protects the machine and not just the
    // disk. MEASURED here: `SELECT size FROM read_blob(url)` issues one HEAD and no GET.
    #expect(!server.requestLog.contains { $0.method == "GET" }, "\(server.requestLog)")
    #expect(server.requestLog.reduce(0) { $0 + $1.bytesSent } == 0, "\(server.requestLog)")
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_theCapStillRefusesWhenTheServerLiedAboutTheLength() throws {
    // The claim and the download are two separate HTTP transactions, so the object can change (or
    // the server can simply be wrong) in between. This server tells one lie — its FIRST HEAD says
    // 12 bytes — and is honest afterwards, which is exactly what a re-uploaded object looks like
    // from here.
    let body = noise(2 * 1024 * 1024)
    let rude = try RudeServer(manner: .firstHeadLies(claim: 12), body: body)
    defer { rude.stop() }
    let con = try remoteConnection()
    let path = TestTemp.path("remote-cache", ".bin")

    let error = #expect(throws: UnsupportedSource.self) {
        try downloadRemoteObject(
            con: con, url: try remote("\(rude.baseURL)/x.bin"), to: path, capBytes: 100_000)
    }
    let message = error?.message ?? ""
    #expect(message.contains("turned out to be"), "\(message)")
    #expect(message.contains("2 MB") && message.contains("100000 bytes"), "\(message)")
    #expect(message.contains("nothing was cached"), "\(message)")
    #expect(!FileManager.default.fileExists(atPath: path), "a refused download must leave no file")
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_aFailedDownloadLeavesNoFileAndNoSasToken() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let con = try remoteConnection()
    let path = TestTemp.path("remote-cache", ".bin")

    // 🔴 DuckDB puts the URL it was handed into its own error text. The SAS signature rides in the
    // query, so an unredacted message is a bearer credential in a banner.
    let error = #expect(throws: DuckDBError.self) {
        try downloadRemoteObject(
            con: con, url: try remote("\(server.baseURL)/gone.bin?sv=2024&sig=SUPERSECRETSIG"),
            to: path)
    }
    let message = error?.message ?? ""
    #expect(message.contains("404"), "\(message)")
    #expect(!message.contains("SUPERSECRETSIG"), "the SAS token reached an error message: \(message)")
    #expect(!FileManager.default.fileExists(atPath: path))
}

// MARK: - the spec

@Test
func aCachedRemoteSourceIsKeyedByItsUrlAndReadFromItsLocalCopy() throws {
    let con = try offlineConnection()
    let cache = TestTemp.path("remote-cache", ".csv")
    try Data("id,region\n1,west\n2,east\n".utf8).write(to: URL(fileURLWithPath: cache))
    let url = try remote("https://acct.blob.core.windows.net/c/sales.csv?sv=2024&sig=SECRET")
    let identity = RemoteIdentity(
        etag: "\"abc\"", lastModifiedMs: 1_792_567_680_000, contentLength: 31, acceptsRanges: true)

    let spec = try buildRemoteSource(
        con: con, url: url, identity: identity, cachePath: cache, fetchedAtNs: 12345)

    // The identity the user sees is the URL — sanitized, so the SAS is nowhere in it.
    #expect(spec.key.path == "https://acct.blob.core.windows.net/c/sales.csv")
    #expect(!spec.key.path.contains("SECRET"))
    #expect(spec.key.mtimeNs == 1_792_567_680_000 * 1_000_000)
    #expect(spec.key.size == 31)
    // …and the bytes are read from the local copy, once, instead of the object being re-downloaded
    // per statement (spike §7: a bare `read_csv(url)` costs 200 % of the object).
    #expect(spec.target == cache)
    #expect(spec.fmt == .csv)
    #expect(spec.columns.map(\.name) == ["id", "region"])
    #expect(spec.rowCount == 2)
    #expect(readExpr(spec: spec).contains(qlit(cache)))
    #expect(!readExpr(spec: spec).contains("SECRET"))
    #expect(spec.remote?.stagingToken
        == "v3|remote|https://acct.blob.core.windows.net/c/sales.csv|etag=\"abc\"")
}

@Test
func withoutAnIdentityTheKeyFallsBackToTheFetchClockAndTheCopyIsNeverAdoptedAgain() throws {
    let con = try offlineConnection()
    let cache = TestTemp.path("remote-cache", ".csv")
    try Data("id\n1\n".utf8).write(to: URL(fileURLWithPath: cache))
    let url = try remote("https://h/data/a.csv")

    let first = try buildRemoteSource(
        con: con, url: url, identity: nil, cachePath: cache, fetchedAtNs: 1_000)
    let second = try buildRemoteSource(
        con: con, url: url, identity: nil, cachePath: cache, fetchedAtNs: 2_000)

    #expect(first.key.mtimeNs == 1_000)
    #expect(first.key.size == 0)
    #expect(first.remote?.stagingToken == "v3|remote|https://h/data/a.csv|fetched=1000")
    #expect(first.remote?.stagingToken != second.remote?.stagingToken,
            "a source with no server identity must never match a copy of itself")
}

@Test
func theCachedBytesDecideTheFormat_notTheUrlsExtension() throws {
    let con = try offlineConnection()
    // A parquet file behind a `.csv` URL — the "a .csv that is really something else" case that
    // makes `detectFormat` read magic bytes at all. Over http there are no magic bytes to read
    // without downloading; once the object is cached there are, and they win.
    let cache = TestTemp.path("remote-cache", ".csv")
    try parquetBytes(rows: 25).write(to: URL(fileURLWithPath: cache))

    let spec = try buildRemoteSource(
        con: con, url: try remote("https://h/a.csv"), identity: nil, cachePath: cache,
        fetchedAtNs: 1)
    #expect(spec.fmt == .parquet)
    #expect(spec.readFn == "read_parquet")
    #expect(spec.rowCount == 25)
}

@Test
func aLocalSourceIsCompletelyUnchangedByTheRemoteFieldExisting() throws {
    let con = try offlineConnection()
    let path = TestTemp.path("local", ".csv")
    try Data("id,name\n1,a\n".utf8).write(to: URL(fileURLWithPath: path))

    let spec = try buildSource(con, path: path)
    #expect(spec.remote == nil)
    #expect(spec.target == spec.key.path, "`target` must be untouched for every local source")
}

@Test(.enabled(if: remoteFacts))
func remoteFactProbe_remoteParquetIsSpecdToReadInPlace() throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    let body = try parquetBytes(rows: 100_000)
    server.register(path: "/a.parquet", body: body)
    let con = try remoteConnection()
    let url = try remote("\(server.baseURL)/a.parquet")

    let spec = try buildRemoteSource(
        con: con, url: url, identity: nil, cachePath: nil, fetchedAtNs: 99)

    #expect(spec.fmt == .parquet)
    #expect(spec.rowCount == 100_000)
    #expect(spec.target == url.sanitized, "an in-place parquet reads from the URL itself")
    #expect(spec.columns.map(\.name) == ["id", "label"])
    // The whole reason parquet is not downloaded (spike §7): the footer answers the row count.
    let moved = server.requestLog.reduce(0) { $0 + $1.bytesSent }
    #expect(moved < body.count / 10, "read \(moved) of \(body.count) B just to build the spec")
}

// MARK: - the two server personalities LoopbackHTTPServer does not have

/// A deliberately badly-behaved origin, for the two shapes the oracle in `SiftEngine` has no
/// business growing: one that accepts a connection and never answers, and one that reports a wrong
/// `Content-Length` on its first HEAD.
///
/// Same two hard-won rules as `LoopbackHTTPServer` (its doc comment has the measurements): Darwin
/// sockets rather than `NWListener`, which cannot bind on this Mac at all, and real `Thread`s
/// rather than the global queue, which starved thirteen parallel tests into empty-log timeouts on
/// CI. It is smaller because it answers one canned response and does not pretend otherwise — no
/// ranges, no 404s, no keep-alive bookkeeping.
private final class RudeServer: @unchecked Sendable {
    enum Manner {
        /// Accept, then say nothing, and hold the connection open. A black-holed host.
        case silent
        /// The first HEAD under-reports the length; every later request tells the truth.
        case firstHeadLies(claim: Int)
    }

    let port: UInt16
    private let fd: Int32
    private let manner: Manner
    private let body: Data
    private let lock = NSLock()
    private var heads = 0
    private var stopped = false
    private var clients: Set<Int32> = []

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(manner: Manner, body: Data = Data()) throws {
        self.manner = manner
        self.body = body
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SessionError("could not create a socket (errno \(errno))") }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port: 0)
        let bound = Self.withAddress(&addr) { bind(sock, $0, $1) }
        guard bound == 0, listen(sock, 16) == 0 else {
            let failure = errno
            close(sock)
            throw SessionError("could not bind a loopback port (errno \(failure))")
        }
        var me = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        fd = sock
        port = UInt16(bigEndian: me.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if lock.withLock({ stopped }) { if client >= 0 { close(client) }; break }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                break
            }
            lock.withLock { _ = clients.insert(client) }
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(fd)
    }

    private func serve(_ client: Int32) {
        defer {
            lock.withLock { _ = clients.remove(client) }
            close(client)
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            guard case .firstHeadLies(let claim) = manner else {
                continue   // .silent: read the request and never answer it
            }
            let isHead = String(decoding: buffer[0..<min(n, 8)], as: UTF8.self).hasPrefix("HEAD")
            let firstHead = isHead && lock.withLock { () -> Bool in heads += 1; return heads == 1 }
            let length = firstHead ? claim : body.count
            var out = Data(
                "HTTP/1.1 200 OK\r\nAccept-Ranges: none\r\nContent-Length: \(length)\r\n\r\n".utf8)
            if !isHead { out.append(body) }
            guard sendAll(client, out) else { return }
        }
    }

    private func sendAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    func stop() {
        let victims: [Int32]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { clients.removeAll() }
            return Array(clients)
        }
        guard let victims else { return }
        for client in victims { shutdown(client, SHUT_RDWR) }
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        if probe >= 0 {
            var addr = Self.loopback(port: port)
            _ = Self.withAddress(&addr) { connect(probe, $0, $1) }
            close(probe)
        }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return addr
    }

    private static func withAddress<T>(
        _ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
