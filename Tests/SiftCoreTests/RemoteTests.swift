import Foundation
import Testing
import DuckDBKit
@testable import SiftCore

// Remote URLs, saved connections, secret SQL and remote staging tokens.
//
// The invariants under test, in the order Remote.swift states them:
//   1. a query string never reaches anything renderable, persistable, or extension-shaped;
//   2. every credential rides as a bound `?` parameter and never appears in SQL text;
//   3. a token without a server-supplied identity is different on every fetch, by construction.
//
// Three tests reach a real in-memory DuckDB. MEASURED: `CREATE SECRET` with `TYPE s3` and
// `TYPE azure` parses, binds and registers on a bare 1.5.5 with **no extension loaded and no
// network** — the extensions are needed to *use* a secret, not to create one. That keeps the
// strongest available assertion (the engine accepted this SQL and the value landed verbatim) in the
// default offline suite.

// MARK: - classification

/// One row of the classification table. `query` is `nil` where there is none.
private struct Case {
    let input: String
    let scheme: RemoteScheme
    let sanitized: String
    let query: String?
    let host: String
    let displayName: String
    let ext: String
}

private let table: [Case] = [
    Case(input: "az://c/f.parquet", scheme: .az, sanitized: "az://c/f.parquet", query: nil,
         host: "c", displayName: "f.parquet", ext: ".parquet"),
    Case(input: "abfss://c@acct.dfs.core.windows.net/dir/f.parquet", scheme: .abfss,
         sanitized: "abfss://acct.dfs.core.windows.net/dir/f.parquet", query: nil,
         host: "acct.dfs.core.windows.net", displayName: "f.parquet", ext: ".parquet"),
    Case(input: "s3://b/k.csv", scheme: .s3, sanitized: "s3://b/k.csv", query: nil,
         host: "b", displayName: "k.csv", ext: ".csv"),
    Case(input: "https://h/p/f.csv?sv=2022-11-02&sig=ABC%2Fdef", scheme: .https,
         sanitized: "https://h/p/f.csv", query: "sv=2022-11-02&sig=ABC%2Fdef",
         host: "h", displayName: "f.csv", ext: ".csv"),
    Case(input: "http://127.0.0.1:8080/x.parquet", scheme: .http,
         sanitized: "http://127.0.0.1:8080/x.parquet", query: nil,
         host: "127.0.0.1", displayName: "x.parquet", ext: ".parquet"),
    // The query-string monster: `NSString.pathExtension` answers "csv" for this, which is how a
    // JSON endpoint gets opened as a CSV.
    Case(input: "https://h/get?id=5&fmt=csv", scheme: .https, sanitized: "https://h/get",
         query: "id=5&fmt=csv", host: "h", displayName: "get", ext: ""),
    Case(input: "https://h/2026%20Sales%20(final).csv", scheme: .https,
         sanitized: "https://h/2026%20Sales%20(final).csv", query: nil, host: "h",
         displayName: "2026 Sales (final).csv", ext: ".csv"),
    Case(input: "HTTPS://H/P/F.CSV", scheme: .https, sanitized: "https://H/P/F.CSV", query: nil,
         host: "H", displayName: "F.CSV", ext: ".csv"),
    Case(input: "  s3://b/k.parquet\n", scheme: .s3, sanitized: "s3://b/k.parquet", query: nil,
         host: "b", displayName: "k.parquet", ext: ".parquet"),
    // Aliases: DuckDB's own azure secret scopes itself to all four spellings.
    Case(input: "azure://c/f.csv", scheme: .az, sanitized: "azure://c/f.csv", query: nil,
         host: "c", displayName: "f.csv", ext: ".csv"),
    Case(input: "abfs://c@a.dfs.core.windows.net/f.csv", scheme: .abfss,
         sanitized: "abfs://a.dfs.core.windows.net/f.csv", query: nil,
         host: "a.dfs.core.windows.net", displayName: "f.csv", ext: ".csv"),
    // A fragment is client-side and never sent; leaving it on would blank out a real extension.
    Case(input: "https://h/p/f.csv#row=10", scheme: .https, sanitized: "https://h/p/f.csv",
         query: nil, host: "h", displayName: "f.csv", ext: ".csv"),
    Case(input: "https://h/p/f.csv?sv=SAS#frag", scheme: .https, sanitized: "https://h/p/f.csv",
         query: "sv=SAS", host: "h", displayName: "f.csv", ext: ".csv"),
    Case(input: "http://[::1]:9/x.csv", scheme: .http, sanitized: "http://[::1]:9/x.csv",
         query: nil, host: "[::1]", displayName: "x.csv", ext: ".csv"),
    // A trailing slash is a container/folder, not a file.
    Case(input: "az://container/folder/", scheme: .az, sanitized: "az://container/folder/",
         query: nil, host: "container", displayName: "folder", ext: ""),
    // `@` in a path is a legal object key, not userinfo.
    Case(input: "https://h/a@b/f.csv", scheme: .https, sanitized: "https://h/a@b/f.csv",
         query: nil, host: "h", displayName: "f.csv", ext: ".csv"),
]

@Test func theClassificationTableHolds() throws {
    for c in table {
        let u = try #require(classifyRemote(c.input), "\(c.input) should classify as remote")
        #expect(u.scheme == c.scheme, "\(c.input) scheme")
        #expect(u.sanitized == c.sanitized, "\(c.input) sanitized")
        #expect(u.query == c.query, "\(c.input) query")
        #expect(u.host == c.host, "\(c.input) host")
        #expect(u.displayName == c.displayName, "\(c.input) displayName")
        #expect(u.effectiveExt == c.ext, "\(c.input) effectiveExt")
        // `signed` is the ONE spelling of "this arrived with a query", read by the download decision
        // (`sasParquetNote`) and written into `RemoteRef.signed`, which is what lets refresh and the
        // sheet re-opens refuse instead of firing an anonymous request. Pinned against the `query`
        // column already in this table, so every row above is a case for it too: 20 URLs, both
        // answers, one line.
        #expect(u.signed == (c.query != nil), "\(c.input) signed")
    }
}

@Test func nothingLocalIsEverMistakenForARemoteURL() {
    for s in [
        "/local/path.csv", "~/x.csv", "file:///x", "file:///Users/a/x.csv", "ftp://h/x.csv",
        "", "   ", "not a url at all", "C:\\data\\x.csv", "s3:/b/k.csv", "https:/h/x.csv",
        "https://", "https:///x.csv", "mailto:a@b.com", "sftp://h/x.csv",
        "see http://h/x.csv for details",
    ] {
        #expect(classifyRemote(s) == nil, "\(s) must not classify as remote")
    }
}

@Test func aQueryStringNeverBecomesAnExtension() throws {
    // The defect this field exists to fix, MEASURED on the two sites that still have it
    // (`SourceProbe.isCompressedPath`, `AppState.needsSheetPicker`), in both directions:

    // 1. a query decides the format outright — nothing here is JSON.
    let endpoint = "https://h/get?id=5&fmt=csv&x=a.json"
    #expect((endpoint as NSString).pathExtension == "json", "the defect")
    let u = try #require(classifyRemote(endpoint))
    #expect(u.effectiveExt == "")
    #expect(!jsonExt.contains(u.effectiveExt))

    // 2. a real CSV stops being one, and the SAS ends up *inside the extension string*.
    let sas = "https://h/data.csv?sv=2022&sig=xyz"
    #expect((sas as NSString).pathExtension == "csv?sv=2022&sig=xyz", "the defect")
    let real = try #require(classifyRemote(sas))
    #expect(real.effectiveExt == ".csv")
    #expect(csvExt.contains(real.effectiveExt))
    #expect(!real.effectiveExt.contains("sig"))

    // The plain query monster from the plan: no dot anywhere, so no extension either.
    let bare = try #require(classifyRemote("https://h/get?id=5&fmt=csv"))
    #expect(bare.effectiveExt == "")
}

@Test func theSASTokenReachesNothingThatIsShownOrStored() throws {
    let sig = "ABCdefGHI%2Fjkl%3D"
    let u = try #require(
        classifyRemote("https://acct.blob.core.windows.net/c/f.parquet?sv=2022-11-02&sig=\(sig)"))

    for (field, value) in [
        ("sanitized", u.sanitized), ("displayName", u.displayName), ("effectiveExt", u.effectiveExt),
        ("host", u.host),
    ] {
        #expect(!value.contains(sig), "\(field) leaked the signature")
        #expect(!value.contains("sig="), "\(field) leaked the signature")
        #expect(!value.contains("?"), "\(field) kept the query delimiter")
    }
    #expect(u.query == "sv=2022-11-02&sig=\(sig)", "and it is still available in memory")
    #expect(u.sanitized == "https://acct.blob.core.windows.net/c/f.parquet")
}

@Test func aPasswordInTheAuthorityIsDroppedRatherThanPersisted() throws {
    let u = try #require(classifyRemote("https://alice:hunter2@h:8443/p/f.csv"))
    #expect(u.sanitized == "https://h:8443/p/f.csv")
    #expect(!u.sanitized.contains("hunter2"))
    #expect(!u.sanitized.contains("alice"))
    #expect(u.host == "h", "userinfo and port both leave the host")
    #expect(u.displayName == "f.csv")
}

@Test func percentEncodingIsDecodedForDisplayOnly() throws {
    let u = try #require(classifyRemote("https://h/dir%20one/my%20report%20(v2).csv"))
    #expect(u.displayName == "my report (v2).csv", "a human reads the decoded name")
    #expect(u.sanitized == "https://h/dir%20one/my%20report%20(v2).csv",
            "but the wire form keeps its encoding")
    #expect(u.effectiveExt == ".csv")

    // A malformed escape must not blank the name out.
    let bad = try #require(classifyRemote("https://h/100%off.csv"))
    #expect(bad.displayName == "100%off.csv")
    #expect(bad.effectiveExt == ".csv")
}

@Test func anEmptyQueryIsNoQuery() throws {
    let u = try #require(classifyRemote("https://h/f.csv?"))
    #expect(u.query == nil)
    #expect(u.sanitized == "https://h/f.csv")
    // …and therefore not signed either: a bare `?` carries nothing to have been dropped, so refusing
    // to refresh it would be a refusal with no cause behind it.
    #expect(!u.signed)
}

// MARK: - secret SQL

private let azureID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
private let s3ID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

private func azureSpec(_ auth: AzureAuth?, account: String? = "myacct") -> ConnectionSpec {
    ConnectionSpec(id: azureID, kind: .azure, name: "prod", accountName: account, azureAuth: auth)
}

private func s3Spec(
    key: String? = "AKIAKEY", region: String? = "us-east-1", endpoint: String? = nil
) -> ConnectionSpec {
    ConnectionSpec(
        id: s3ID, kind: .s3, name: "prod", accountName: key, region: region, endpoint: endpoint)
}

@Test func theAzureCredentialChainShapeIsPinned() throws {
    let (sql, params) = try #require(createSecretSQL(azureSpec(.credentialChain), secretValue: nil))
    #expect(sql == "CREATE OR REPLACE TEMPORARY SECRET "
        + "sift_e621e1f8c36c495a93fc0c247a3e6e5f "
        + "(TYPE azure, PROVIDER credential_chain, CHAIN 'cli;env', ACCOUNT_NAME ?)")
    #expect(params == [.text("myacct")])

    // A secret value handed in anyway is ignored: the whole point of the chain is that there is none.
    let (withValue, sameParams) = try #require(
        createSecretSQL(azureSpec(.credentialChain), secretValue: "ignored"))
    #expect(withValue == sql)
    #expect(sameParams == params)
    #expect(!sql.contains("ignored"))
}

@Test func theAzureConnectionStringShapeIsPinned() throws {
    let (sql, params) = try #require(
        createSecretSQL(azureSpec(.connectionString), secretValue: "AccountKey=abc=="))
    #expect(sql == "CREATE OR REPLACE TEMPORARY SECRET "
        + "sift_e621e1f8c36c495a93fc0c247a3e6e5f (TYPE azure, CONNECTION_STRING ?)")
    #expect(params == [.text("AccountKey=abc==")])
}

@Test func theS3ShapeIsPinnedWithAndWithoutItsOptionalParts() throws {
    let name = "sift_00112233445566778899aabbccddeeff"

    let (plain, plainParams) = try #require(createSecretSQL(s3Spec(), secretValue: "SEKRIT"))
    #expect(plain == "CREATE OR REPLACE TEMPORARY SECRET \(name) "
        + "(TYPE s3, KEY_ID ?, SECRET ?, REGION ?)")
    #expect(plainParams == [.text("AKIAKEY"), .text("SEKRIT"), .text("us-east-1")])

    let (full, fullParams) = try #require(
        createSecretSQL(s3Spec(endpoint: "minio.local:9000"), secretValue: "SEKRIT"))
    #expect(full == "CREATE OR REPLACE TEMPORARY SECRET \(name) "
        + "(TYPE s3, KEY_ID ?, SECRET ?, REGION ?, ENDPOINT ?)")
    #expect(fullParams
        == [.text("AKIAKEY"), .text("SEKRIT"), .text("us-east-1"), .text("minio.local:9000")])

    // No region: the clause goes away rather than binding "", which DuckDB would take as a region.
    let (noRegion, noRegionParams) = try #require(
        createSecretSQL(s3Spec(region: nil), secretValue: "SEKRIT"))
    #expect(noRegion == "CREATE OR REPLACE TEMPORARY SECRET \(name) (TYPE s3, KEY_ID ?, SECRET ?)")
    #expect(noRegionParams == [.text("AKIAKEY"), .text("SEKRIT")])
    #expect(!noRegion.contains("REGION"))

    // Whitespace is not a value either.
    #expect(createSecretSQL(s3Spec(region: "   "), secretValue: "SEKRIT")?.0 == noRegion)
}

@Test func aHostileSecretValueRidesAsAValueAndNeverEntersTheSQL() throws {
    // Every character that would end the statement, comment out the rest of it, or close a literal.
    let hostile = "DefaultEndpointsProtocol=https;AccountKey=a'b''c;--x;/*y*/;DROP SECRET s;"
    let (sql, params) = try #require(
        createSecretSQL(azureSpec(.connectionString), secretValue: hostile))

    #expect(params == [.text(hostile)])
    #expect(sql.filter { $0 == "?" }.count == 1, "exactly one placeholder")
    // Not just "the whole string is absent" — no recognisable *fragment* of it is in the text.
    for fragment in ["AccountKey", "a'b", "DROP SECRET s", "--x", "/*y*/", "https"] {
        #expect(!sql.contains(fragment), "SQL text leaked \(fragment)")
    }
    #expect(!sql.contains("'"), "the only quotes in this shape would be interpolation")

    // The same for the s3 secret, whose key id is not redacted by duckdb_secrets().
    let (s3SQL, s3Params) = try #require(createSecretSQL(s3Spec(key: hostile), secretValue: hostile))
    #expect(s3Params == [.text(hostile), .text(hostile), .text("us-east-1")])
    #expect(!s3SQL.contains("AccountKey"))
}

@Test func aSpecWithNothingToBindIssuesNoSecret() {
    #expect(createSecretSQL(azureSpec(nil), secretValue: "x") == nil, "no auth mode chosen")
    #expect(createSecretSQL(azureSpec(.credentialChain, account: nil), secretValue: nil) == nil)
    #expect(createSecretSQL(azureSpec(.credentialChain, account: ""), secretValue: nil) == nil)
    #expect(createSecretSQL(azureSpec(.connectionString), secretValue: nil) == nil)
    #expect(createSecretSQL(azureSpec(.connectionString), secretValue: "  ") == nil)
    // An anonymous read of a public bucket is a real thing; a half-empty secret would break it.
    #expect(createSecretSQL(s3Spec(), secretValue: nil) == nil)
    #expect(createSecretSQL(s3Spec(key: nil), secretValue: "SEKRIT") == nil)
}

@Test func theSecretNameIsAlwaysAnIdentifierDuckDBCanParse() {
    for spec in [azureSpec(.credentialChain), s3Spec(), ConnectionSpec(kind: .s3, name: "x")] {
        let name = secretName(spec)
        #expect(name.hasPrefix("sift_"))
        #expect(name.count == "sift_".count + 32)
        #expect(name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) },
                "\(name) must match ^[a-z_][a-z0-9_]*$ — the NAME is the one thing that cannot bind")
        #expect(name == name.lowercased())
    }
    // The user's own name for the connection never reaches the identifier.
    let evil = ConnectionSpec(id: s3ID, kind: .s3, name: "\"; DROP TABLE x; --")
    #expect(secretName(evil) == "sift_00112233445566778899aabbccddeeff")
    #expect(dropSecretSQL(evil) == "DROP SECRET IF EXISTS sift_00112233445566778899aabbccddeeff")
}

@Test func dropNamesTheSameSecretCreateIssued() throws {
    let spec = azureSpec(.credentialChain)
    let (sql, _) = try #require(createSecretSQL(spec, secretValue: nil))
    #expect(sql.contains(secretName(spec)))
    #expect(dropSecretSQL(spec) == "DROP SECRET IF EXISTS \(secretName(spec))")
    // Callable for a spec that never produced a CREATE — turning a connection off must not depend
    // on whether it ever managed to turn on.
    #expect(createSecretSQL(azureSpec(nil), secretValue: nil) == nil)
    #expect(dropSecretSQL(azureSpec(nil)).hasPrefix("DROP SECRET IF EXISTS sift_"))
}

// MARK: - secret SQL, against the real parser

/// SiftCore declares SQLValue, DuckDBKit declares DBValue — deliberately not the same type. Same
/// five-line mapping SQLGenTests keeps, scoped to this file.
private func toDBValue(_ v: SQLValue) -> DBValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .text(let s): return .text(s)
    }
}

@Test func everySecretShapeParsesAndBindsOnARealEngine() throws {
    let con = try Database.inMemory().connect()
    let shapes: [(ConnectionSpec, String?)] = [
        (azureSpec(.credentialChain), nil),
        (azureSpec(.connectionString), "DefaultEndpointsProtocol=https;AccountKey=abc=="),
        (s3Spec(), "SEKRIT"),
        (s3Spec(endpoint: "minio.local:9000"), "SEKRIT"),
        (s3Spec(region: nil), "SEKRIT"),
    ]
    for (spec, value) in shapes {
        let (sql, params) = try #require(createSecretSQL(spec, secretValue: value))
        // Throws on a parser error, a wrong placeholder count, or an unknown option name.
        _ = try con.query(sql, params.map(toDBValue))
        try con.execute(dropSecretSQL(spec))
    }
    #expect(try con.query("SELECT count(*) FROM duckdb_secrets()").allRows()[0][0] == .int(0))
}

@Test func aBoundCredentialLandsVerbatimAndStaysOffDisk() throws {
    let con = try Database.inMemory().connect()
    // A value that would end the statement three times over if it were ever interpolated.
    let hostile = "acct'name;DROP TABLE x;--"
    let spec = azureSpec(.credentialChain, account: hostile)
    let (sql, params) = try #require(createSecretSQL(spec, secretValue: nil))
    _ = try con.query(sql, params.map(toDBValue))

    let rows = try con.query(
        "SELECT persistent, storage, secret_string FROM duckdb_secrets() WHERE name = ?",
        [.text(secretName(spec))]).allRows()
    #expect(rows.count == 1)
    #expect(rows[0][0] == .bool(false), "TEMPORARY: nothing about this reaches disk")
    #expect(rows[0][1] == .text("memory"))
    guard case .text(let described) = rows[0][2] else {
        Issue.record("secret_string is not text")
        return
    }
    #expect(described.contains("account_name=\(hostile)"), "the bound value landed verbatim")
    #expect(described.contains("chain=cli;env"), "the constant Sift chose, not user data")
}

@Test func aBoundConnectionStringIsRedactedWhenReadBack() throws {
    let con = try Database.inMemory().connect()
    let secret = "AccountKey=SUPERSECRETVALUE=="
    let spec = azureSpec(.connectionString)
    let (sql, params) = try #require(createSecretSQL(spec, secretValue: secret))
    _ = try con.query(sql, params.map(toDBValue))

    let rows = try con.query("SELECT secret_string FROM duckdb_secrets()").allRows()
    guard case .text(let described) = rows[0][0] else {
        Issue.record("secret_string is not text")
        return
    }
    // MEASURED (spike §6c): redaction is field-aware and on by default, and the SQL console reads
    // through this same view.
    #expect(described.contains("connection_string=redacted"))
    #expect(!described.contains("SUPERSECRETVALUE"))
}

// MARK: - remote staging tokens

@Test func everyRemoteTokenIsAV3RemoteToken() {
    let tokens = [
        remoteStagingToken(sanitizedURL: "https://h/f.csv", etag: "\"abc\"", lastModifiedMs: nil,
                           contentLength: nil, fetchedAtNs: 1),
        remoteStagingToken(sanitizedURL: "https://h/f.csv", etag: nil, lastModifiedMs: 1_700_000,
                           contentLength: 42, fetchedAtNs: 1),
        remoteStagingToken(sanitizedURL: "https://h/f.csv", etag: nil, lastModifiedMs: nil,
                           contentLength: nil, fetchedAtNs: 1),
    ]
    for token in tokens {
        // The literal, not the constant: reading `tokenVersion` back would pin nothing. This must
        // stay equal to SiftEngine's `stagingTokenVersion` or purgeStaged's format sweep deletes
        // every remote cache on sight.
        #expect(token.hasPrefix("v3|remote|"), "\(token)")
    }
    #expect(Set(tokens).count == 3, "the three forms are three different tokens")
}

@Test func theIdentityFormsArePinnedAndStableAcrossCalls() {
    let url = "https://h/p/f.csv"
    let etag = remoteStagingToken(sanitizedURL: url, etag: "W/\"abc123\"", lastModifiedMs: 999,
                                  contentLength: 7, fetchedAtNs: 1)
    #expect(etag == "v3|remote|https://h/p/f.csv|etag=W/\"abc123\"")
    #expect(etag == remoteStagingToken(sanitizedURL: url, etag: "W/\"abc123\"",
                                       lastModifiedMs: 12345, contentLength: 99, fetchedAtNs: 2),
            "an ETag is the server's own identity — a moved date cannot invalidate it")

    let lm = remoteStagingToken(sanitizedURL: url, etag: nil, lastModifiedMs: 1_700_000_000_000,
                                contentLength: 8_536_550, fetchedAtNs: 1)
    #expect(lm == "v3|remote|https://h/p/f.csv|lm=1700000000000|len=8536550")
    #expect(lm == remoteStagingToken(sanitizedURL: url, etag: nil,
                                     lastModifiedMs: 1_700_000_000_000, contentLength: 8_536_550,
                                     fetchedAtNs: 99), "stable across calls, whatever the clock says")
    #expect(lm != remoteStagingToken(sanitizedURL: url, etag: nil,
                                     lastModifiedMs: 1_700_000_000_000, contentLength: 8_536_551,
                                     fetchedAtNs: 1), "one byte of difference is a different file")
    #expect(etag != lm)
}

@Test func halfAnIdentityIsNoIdentity() {
    let url = "https://h/f.csv"
    // Last-Modified has one-second granularity: alone it would adopt a copy of a file rewritten
    // inside the same second, so it only counts alongside a length.
    let lmOnly = remoteStagingToken(sanitizedURL: url, etag: nil, lastModifiedMs: 1_700_000,
                                    contentLength: nil, fetchedAtNs: 5)
    let lenOnly = remoteStagingToken(sanitizedURL: url, etag: nil, lastModifiedMs: nil,
                                     contentLength: 42, fetchedAtNs: 5)
    #expect(lmOnly == "v3|remote|https://h/f.csv|fetched=5")
    #expect(lenOnly == lmOnly)
    // An empty ETag header is not an ETag.
    #expect(remoteStagingToken(sanitizedURL: url, etag: "", lastModifiedMs: nil,
                               contentLength: nil, fetchedAtNs: 5) == lmOnly)
}

@Test func theFetchedFormIsDifferentOnEveryFetch() {
    let url = "https://h/f.csv"
    func fetch(_ ns: Int) -> String {
        remoteStagingToken(sanitizedURL: url, etag: nil, lastModifiedMs: nil, contentLength: nil,
                           fetchedAtNs: ns)
    }
    // The caller owns the clock; the format owns "distinct input, distinct token".
    let first = fetch(1_000_000_000)
    let second = fetch(1_000_000_001)
    #expect(first != second, "an identity-less copy can never be adopted — by construction")
    #expect(first.hasSuffix("|fetched=1000000000"))
    #expect(Set((0..<500).map { fetch(1_000_000_000 + $0) }).count == 500)

    // And it can never collide with an identity token for the same URL.
    let identity = remoteStagingToken(sanitizedURL: url, etag: "\"x\"", lastModifiedMs: nil,
                                      contentLength: nil, fetchedAtNs: 1_000_000_000)
    #expect(identity != first)
}

@Test func aPipeInsideAFieldCannotForgeAFieldBoundary() {
    // `a|b` and the already-encoded `a%7Cb` are different objects. Escaping `|` alone would send
    // both to the same token, and two sources sharing one token is a copy adopted for the wrong
    // file.
    let bar = remoteStagingToken(sanitizedURL: "https://h/a|b.csv", etag: nil, lastModifiedMs: 1,
                                 contentLength: 2, fetchedAtNs: 0)
    let encoded = remoteStagingToken(sanitizedURL: "https://h/a%7Cb.csv", etag: nil,
                                     lastModifiedMs: 1, contentLength: 2, fetchedAtNs: 0)
    #expect(bar != encoded)
    #expect(bar == "v3|remote|https://h/a%7Cb.csv|lm=1|len=2")
    #expect(encoded == "v3|remote|https://h/a%257Cb.csv|lm=1|len=2")

    // Field count is what a parser would split on, and it survives both.
    for token in [bar, encoded] {
        #expect(token.split(separator: "|", omittingEmptySubsequences: false).count == 5, "\(token)")
    }

    // A URL cannot forge a whole trailing field either.
    let forged = remoteStagingToken(sanitizedURL: "https://h/f.csv|etag=\"stolen\"", etag: nil,
                                    lastModifiedMs: nil, contentLength: nil, fetchedAtNs: 7)
    #expect(forged == "v3|remote|https://h/f.csv%7Cetag=\"stolen\"|fetched=7")
    #expect(forged.split(separator: "|", omittingEmptySubsequences: false).count == 4)

    // An ETag is a quoted string and may hold anything, including the delimiter.
    let etag = remoteStagingToken(sanitizedURL: "https://h/f.csv", etag: "\"a|b\"",
                                 lastModifiedMs: nil, contentLength: nil, fetchedAtNs: 0)
    #expect(etag == "v3|remote|https://h/f.csv|etag=\"a%7Cb\"")
}

@Test func aTokenIsBuiltFromTheSanitizedURLSoNoSASEverReachesTheCatalog() throws {
    let u = try #require(classifyRemote("https://h/f.parquet?sv=2022&sig=SECRETSIG"))
    let token = remoteStagingToken(sanitizedURL: u.sanitized, etag: "\"e\"", lastModifiedMs: nil,
                                   contentLength: nil, fetchedAtNs: 0)
    #expect(!token.contains("SECRETSIG"))
    #expect(token == "v3|remote|https://h/f.parquet|etag=\"e\"")
}

// MARK: - config

@Test func theConfigRoundTrips() throws {
    let config = RemoteConfig(
        allowRemote: true,
        connections: [
            ConnectionSpec(id: azureID, kind: .azure, name: "Contoso prod",
                           accountName: "contoso", azureAuth: .credentialChain),
            ConnectionSpec(id: s3ID, kind: .s3, name: "minio", accountName: "AKIAKEY",
                           region: "us-east-1", endpoint: "minio.local:9000"),
        ])
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(RemoteConfig.self, from: data) == config)

    // Nothing secret is in the file — that is what makes plain JSON on disk acceptable.
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"version\":1"))
    #expect(json.contains("credentialChain"), "the persisted spelling of the enum case")
    #expect(!json.lowercased().contains("secret"))
    #expect(!json.lowercased().contains("password"))
}

@Test func aFreshConfigAllowsNothing() {
    let config = RemoteConfig()
    #expect(config.allowRemote == false, "Sift touches no live system until someone says so")
    #expect(config.connections.isEmpty)
    #expect(config.version == 1)
}

@Test func aConfigFromAnUnknownFormatIsRefusedLoudly() throws {
    for version in [2, 7, 0, -1] {
        let json = Data("""
            {"version":\(version),"allowRemote":true,"connections":[],"futureField":"kept"}
            """.utf8)
        #expect(throws: UnsupportedRemoteConfig(version: version)) {
            try JSONDecoder().decode(RemoteConfig.self, from: json)
        }
    }
    // And the sentence is a sentence, on both `\(error)` and `.localizedDescription`.
    let error = UnsupportedRemoteConfig(version: 2)
    #expect("\(error)".contains("format 2"))
    #expect(error.localizedDescription == error.description)
    #expect(!error.localizedDescription.contains("couldn't be completed"))
}

@Test func missingKeysInsideAKnownVersionTakeTheirDefaults() throws {
    // A version bump is how a format change announces itself, so absence within v1 is an older or
    // hand-written file, not an uninterpretable one.
    let bare = try JSONDecoder().decode(RemoteConfig.self, from: Data("{}".utf8))
    #expect(bare == RemoteConfig())
    #expect(bare.allowRemote == false, "and it never defaults to allowing egress")

    let partial = try JSONDecoder().decode(
        RemoteConfig.self, from: Data(#"{"version":1,"allowRemote":true}"#.utf8))
    #expect(partial.allowRemote)
    #expect(partial.connections.isEmpty)
}
