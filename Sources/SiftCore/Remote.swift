import Foundation

// Remote sources, decided: what a pasted URL *is*, what a saved connection *is*, the SQL that
// issues a connection's credential, and what a cached remote copy is a copy OF.
//
// Pure, like the rest of SiftCore — Foundation only, no connection, no clock, no filesystem, no
// network. Every function here is total and deterministic; `fetchedAtNs` is a parameter precisely
// so that the one value that has to come from a clock comes from the caller's.
//
// The facts this file is built on were MEASURED against the vendored libduckdb 1.5.5 and written
// up in docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md; each is cited where it bites.

// MARK: - URL classification

/// A URL scheme Sift treats as remote. Raw values are the canonical scheme text.
public enum RemoteScheme: String, Sendable, Equatable {
    case http, https, s3, az, abfss
}

/// Every scheme *spelling* that reaches DuckDB, mapped to the case that decides policy.
///
/// `azure://` and `abfs://` are aliases of `az://` and `abfss://`, not new cases. MEASURED twice:
/// the facts spike (§1) found the azure extension registers exactly two filesystems,
/// `AzureBlobStorageFileSystem` serving `az://`+`azure://` and `AzureDfsStorageFileSystem` serving
/// `abfss://`+`abfs://`; and an azure secret created on a bare 1.5.5 reports its own scope as
/// `azure://,az://,abfss://,abfs://` — all four spellings, from DuckDB's own mouth.
///
/// 🔴 Leaving an alias out would not make it "unsupported". `classifyRemote` returning `nil` means
/// **local path**, so `azure://c/f.parquet` would be handed to the local-file flow and fail as a
/// missing file. A scheme this table does not know is a scheme Sift silently mis-routes.
private let remoteSchemes: [String: RemoteScheme] = [
    "http": .http, "https": .https, "s3": .s3,
    "az": .az, "azure": .az,
    "abfss": .abfss, "abfs": .abfss,
]

/// A URL split into the part that may be shown and the part that must not be.
///
/// The split exists because of one shape: an Azure blob URL with a SAS token
/// (`https://acct.blob.core.windows.net/c/f.parquet?sv=…&sig=…`). The `sig` is a bearer credential.
/// It has to reach DuckDB, and it must never reach a window title, a log line, the staging catalog,
/// or a saved config. Keeping the two in one `String` and remembering to strip it at each of those
/// four sites is how one of them ends up not stripping it.
public struct RemoteURL: Sendable, Equatable {
    public let scheme: RemoteScheme

    /// The URL with the query string, the fragment and any `user:password@` removed. **The ONLY
    /// form that may be displayed or persisted.**
    ///
    /// Three things are dropped, not one:
    /// * **the query** — it is where a SAS token lives, and it is why this type exists;
    /// * **the fragment** — client-side by definition (no HTTP client ever sends one), so keeping
    ///   it would only feed `#anchor` to `pathSuffix` and blank out a perfectly good `.csv`;
    /// * **`user:password@`** — a password in the authority is exactly the leak the query strip
    ///   exists to prevent, and it is not carried anywhere else either. Sift does not do
    ///   credentials-in-a-URL: credentials live in a `ConnectionSpec` and the Keychain, so a URL
    ///   that carries its own will authenticate as anonymous and get a clean 401 rather than have
    ///   its password persisted into `_sift_sources`.
    ///
    /// The scheme is lowercased (case-insensitive per RFC 3986); nothing after `://` is touched —
    /// an S3 bucket and an object key are both case-sensitive, so "normalising" them corrupts them.
    public let sanitized: String

    /// The query string (a SAS token, when present), with no leading `?`. Memory-only: never
    /// rendered, never stored. `nil` when there was no query, and also when there was a bare `?`
    /// with nothing after it — an empty query carries nothing to re-attach.
    public let query: String?

    /// The authority with userinfo and port removed. For `s3://` this is the bucket.
    public let host: String

    /// The percent-decoded last path component — what a human calls the file.
    public let displayName: String

    /// The extension of the PATH component, lowercased and dot-prefixed (`".csv"`, or `""` when
    /// there is none), so it can be tested against `csvExt` / `parquetExt` / `xlsxExt` directly.
    ///
    /// 🔴 **This field is the entire reason this type exists.** Two shipped sites derive a format
    /// from `(path as NSString).pathExtension` — `SourceProbe.isCompressedPath` and
    /// `AppState.needsSheetPicker` — and `NSString.pathExtension` has no idea what a URL is. On
    /// `https://h/get?id=5&fmt=csv` it answers `csv`, so a JSON API endpoint is opened as a CSV,
    /// and on `https://h/f.csv?sv=…&sig=…` it answers the tail of the SAS signature, so a real CSV
    /// is opened as nothing at all. The query is removed *before* the extension is taken, and the
    /// extension is taken from `displayName`, which is derived from the path alone.
    public let effectiveExt: String

    /// **This URL arrived carrying something `sanitized` threw away** — the ONE spelling of that
    /// fact in the product, and the source of `RemoteRef.signed`.
    ///
    /// It is `query != nil` and nothing cleverer, because nothing cleverer is available: Sift cannot
    /// tell a SAS signature from `?id=5` without parsing somebody's private auth scheme, and it does
    /// not need to. The consequence is the same either way — the query is not persisted, so any
    /// request re-derived from `sanitized` is a *different* request from the one that worked, and
    /// for the shape this whole path was built around (`?sv=…&sig=…`) that difference is anonymous
    /// versus authorised. "Signed" is the product's own word for it (`sasParquetNote`,
    /// `ConnectionsSheet.sasNote`), so it is the word here.
    ///
    /// 🔴 A boolean, and it stays one. It must never grow into a length, a prefix, a hash or a
    /// "which parameters were present" — every one of those is a fact about a bearer credential, and
    /// this value's whole purpose is to be safe to carry into a `RemoteRef` that outlives the query.
    public var signed: Bool { query != nil }
}

/// Classify a pasted string. `nil` = not remote → the existing local flow, untouched.
///
/// Structural only: it answers "is this a URL Sift can reach, and what are its parts", never "is
/// this a good idea". A `*` in the path (globs are refused before the wire — spike §4), a
/// `_delta_log/` directory (remote Delta cannot work at all — spike §3) and an unreachable host are
/// all somebody else's clean sentence; classifying them here would put three refusal messages in
/// the one function whose `nil` already means something else.
public func classifyRemote(_ s: String) -> RemoteURL? {
    let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sep = text.range(of: "://") else { return nil }
    let rawScheme = String(text[..<sep.lowerBound]).lowercased()
    guard let scheme = remoteSchemes[rawScheme] else { return nil }

    // Fragment before query: RFC 3986 orders them `?query#fragment`, so splitting the other way
    // round leaves `#frag` glued to the end of the query.
    var rest = String(text[sep.upperBound...])
    if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }

    var query: String?
    if let mark = rest.firstIndex(of: "?") {
        let q = String(rest[rest.index(after: mark)...])
        query = q.isEmpty ? nil : q
        rest = String(rest[..<mark])
    }

    // The authority ends at the first `/`; everything from that `/` on is the path. Looking for
    // `@` only inside the authority matters — `https://h/a@b/f.csv` is a legal object key.
    let slash = rest.firstIndex(of: "/")
    var authority = slash.map { String(rest[..<$0]) } ?? rest
    let path = slash.map { String(rest[$0...]) } ?? ""
    if let at = authority.lastIndex(of: "@") {
        authority = String(authority[authority.index(after: at)...])
    }
    guard !authority.isEmpty else { return nil }

    // `rawScheme` rather than `scheme.rawValue`: an alias must go back to DuckDB spelled the way
    // it arrived. `azure://` and `az://` are the same filesystem but not the same string, and this
    // one is about to be persisted.
    let sanitized = "\(rawScheme)://\(authority)\(path)"
    let raw = pathName(sanitized)
    let displayName = raw.removingPercentEncoding ?? raw
    return RemoteURL(
        scheme: scheme,
        sanitized: sanitized,
        query: query,
        host: hostOf(authority),
        displayName: displayName,
        effectiveExt: pathSuffix(displayName).lowercased()
    )
}

/// The authority minus its port. An IPv6 literal is bracketed (`[::1]:8080`), so the brackets are
/// the delimiter there; elsewhere a trailing `:digits` is a port and anything else is part of the
/// name.
private func hostOf(_ authority: String) -> String {
    if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
        return String(authority[...close])
    }
    if let colon = authority.lastIndex(of: ":"),
        authority[authority.index(after: colon)...].allSatisfy(isASCIIDigit) {
        return String(authority[..<colon])
    }
    return authority
}

// MARK: - Saved connections

public enum ConnectionKind: String, Codable, Sendable { case azure, s3 }

/// How an Azure connection proves who it is.
///
/// `credentialChain` is the nice one on a Mac: DuckDB asks `az login` and the environment, and
/// Sift holds no credential at all (spike §9).
///
/// 🔴 The raw values are the **persisted** spelling — they land in the config file as
/// `"credentialChain"` / `"connectionString"`. Renaming a case, or giving one a prettier snake_case
/// raw value, silently invalidates every saved connection, and `RemoteConfig`'s version guard would
/// NOT catch it because the version would not have changed. Same rule as `Fmt` in Types.swift.
public enum AzureAuth: String, Codable, Sendable { case credentialChain, connectionString }

/// A connection the user has saved. Deliberately holds **no credential**: the secret value lives in
/// the Keychain and is handed to `createSecretSQL` at open time, so this whole struct is safe to
/// write to disk as plain JSON.
public struct ConnectionSpec: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ConnectionKind
    public var name: String

    /// The non-secret half of the identity, and it means one thing per kind: for `azure` the
    /// storage account name (required by `credentialChain`), for `s3` the access **key id**.
    ///
    /// One field rather than two because they are the same fact wearing two names, and MEASURED
    /// (spike §6c) they are even redacted the same way — `duckdb_secrets()` shows `account_name`
    /// and `key_id` in the clear while redacting `connection_string` and `secret`. The secret half
    /// never appears in this struct at all.
    public var accountName: String?
    public var azureAuth: AzureAuth?
    /// s3.
    public var region: String?
    /// s3; `nil` = AWS.
    public var endpoint: String?

    public init(
        id: UUID = UUID(), kind: ConnectionKind, name: String, accountName: String? = nil,
        azureAuth: AzureAuth? = nil, region: String? = nil, endpoint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.accountName = accountName
        self.azureAuth = azureAuth
        self.region = region
        self.endpoint = endpoint
    }
}

/// A config written in a format this build cannot read. One sentence, per the house contract.
public struct UnsupportedRemoteConfig: SiftError, Equatable {
    public let version: Int
    public var description: String {
        "this remote-connections config is format \(version) and this build of Sift reads format "
            + "\(remoteConfigVersion) — update Sift rather than let it rewrite the file without "
            + "the settings it cannot read"
    }
}

/// The only `RemoteConfig.version` this build understands.
public let remoteConfigVersion = 1

/// Everything the Connections UI persists. Remote is **off** until someone turns it on: Sift's
/// standing promise is that it touches no live system, and a default that quietly allowed egress
/// would break that promise for every user who never opened this screen.
public struct RemoteConfig: Codable, Sendable, Equatable {
    public var version: Int = remoteConfigVersion
    public var allowRemote: Bool = false
    public var connections: [ConnectionSpec] = []

    public init(
        version: Int = remoteConfigVersion, allowRemote: Bool = false,
        connections: [ConnectionSpec] = []
    ) {
        self.version = version
        self.allowRemote = allowRemote
        self.connections = connections
    }

    /// Refuses a version it does not know, loudly, rather than decoding what it recognises and
    /// dropping the rest.
    ///
    /// Silent tolerance is the worse failure here and it is not symmetric with the local staging
    /// precedent, which is why this is spelled out: an unreadable *staging token* is collected —
    /// the copy is disk that can be regenerated. An unreadable *config* is the user's own typing.
    /// A newer Sift writes a field this build cannot see; this build decodes around it, the user
    /// edits one connection, and the whole file is rewritten without it. Refusing means the UI can
    /// say "update Sift" while the file on disk stays intact.
    ///
    /// Missing keys inside a known version are fine and take their defaults — a version bump is
    /// how a format change announces itself, so absence within v1 is just an older or hand-written
    /// file, not an uninterpretable one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? remoteConfigVersion
        guard version == remoteConfigVersion else { throw UnsupportedRemoteConfig(version: version) }
        allowRemote = try c.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? false
        connections = try c.decodeIfPresent([ConnectionSpec].self, forKey: .connections) ?? []
    }
}

// MARK: - Secret SQL

/// The DuckDB secret name for a connection: `sift_` + the id's 32 hex digits.
///
/// MEASURED (spike §6a): every *value* in a `CREATE SECRET` binds as a parameter, but the secret's
/// **name** is a parser identifier — `CREATE SECRET ? (…)` is a `Parser Error`. So the one token
/// that must be interpolated into this SQL is the one token no user can influence. Hex digits after
/// a `sift_` prefix always satisfy DuckDB's unquoted identifier rule (`^[a-z_][a-z0-9_]*$`), and a
/// UUID means two connections cannot collide even when the user names them both "prod".
func secretName(_ spec: ConnectionSpec) -> String {
    "sift_" + spec.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// Trim to `nil`: an empty string is a missing value everywhere in this file, never a real one.
/// Binding `REGION ''` is not the same as not setting a region, and it is worse.
private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
}

/// Session-scoped secret for one connection; `nil` when the spec has nothing to bind.
///
/// 🔴 **Every credential rides as a bound `?` parameter**, which is why this returns the same
/// `(String, [SQLValue])` pair every generator in SQLGen.swift returns rather than a string built
/// with `qlit`. The task this came from assumed secrets were the one place Sift would have to
/// interpolate; the spike measured otherwise (§6a — `CONNECTION_STRING`, `SECRET`, `ACCOUNT_NAME`,
/// `KEY_ID`, `REGION` and `ENDPOINT` all bind, and a bound value lands verbatim). The package
/// invariant — *nothing in Sift interpolates a user value into SQL text* — therefore survives
/// contact with credentials. Do not "simplify" this back into an interpolated string.
///
/// The literal `'cli;env'` is the exception that proves it: it is Sift's own configuration
/// (spike §9 — ask the Azure CLI, then the environment), a constant chosen by this file, not data
/// from anyone. A constant belongs in the SQL text; a value does not.
///
/// `TEMPORARY` is spelled even though MEASURED (spike §6c) it is already the default, because it is
/// the property that keeps a credential off the disk: a temporary secret writes nothing to the
/// `.duckdb` file and dies with the `Database`. Spelling it means a future change of DuckDB's
/// default cannot silently start persisting credentials.
///
/// `nil` cases, all of them "there is nothing to say to DuckDB":
/// * azure + `credentialChain` with no account name — the whole point of the chain is that there is
///   no secret, so `secretValue` is ignored here; the account name is the only thing to bind.
/// * azure + `connectionString` with no connection string, and azure with no `azureAuth` at all.
/// * s3 without both a key id and a secret — an anonymous read of a public bucket is a real thing,
///   and issuing a half-empty secret would break it.
public func createSecretSQL(_ spec: ConnectionSpec, secretValue: String?) -> (String, [SQLValue])? {
    var clauses: [String]
    var params: [SQLValue] = []

    switch spec.kind {
    case .azure:
        switch spec.azureAuth {
        case .credentialChain:
            guard let account = nonEmpty(spec.accountName) else { return nil }
            clauses = ["TYPE azure", "PROVIDER credential_chain", "CHAIN 'cli;env'", "ACCOUNT_NAME ?"]
            params.append(.text(account))
        case .connectionString:
            guard let connection = nonEmpty(secretValue) else { return nil }
            clauses = ["TYPE azure", "CONNECTION_STRING ?"]
            params.append(.text(connection))
        case nil:
            return nil
        }

    case .s3:
        guard let keyID = nonEmpty(spec.accountName), let secret = nonEmpty(secretValue) else {
            return nil
        }
        clauses = ["TYPE s3", "KEY_ID ?", "SECRET ?"]
        params.append(.text(keyID))
        params.append(.text(secret))
        if let region = nonEmpty(spec.region) {
            clauses.append("REGION ?")
            params.append(.text(region))
        }
        if let endpoint = nonEmpty(spec.endpoint) {
            clauses.append("ENDPOINT ?")
            params.append(.text(endpoint))
        }
    }

    let sql = "CREATE OR REPLACE TEMPORARY SECRET \(secretName(spec)) "
        + "(\(clauses.joined(separator: ", ")))"
    return (sql, params)
}

/// Drop a connection's secret. Unconditional and `IF EXISTS`, so it is safe to call for a spec
/// whose `createSecretSQL` returned `nil` — turning a connection off must not depend on remembering
/// whether it ever managed to turn on.
public func dropSecretSQL(_ spec: ConnectionSpec) -> String {
    "DROP SECRET IF EXISTS \(secretName(spec))"
}

// MARK: - Remote staging tokens

/// 🔴 **Must equal `SiftEngine.stagingTokenVersion`, and the compiler cannot check it**: SiftCore
/// sits below SiftEngine in the module graph, so the constant cannot be shared from where it lives
/// today. If these two ever disagree, `purgeStaged`'s format sweep — `!token.hasPrefix("v3|")` —
/// deletes every remote cache on every purge, silently, and nothing goes red. The fix is to hoist
/// `stagingTokenVersion` out of Staging.swift into this file and delete the copy there; that file
/// was out of scope for the task that added this one. Until then, a test pins the literal at both
/// ends.
/// The staging-token format version — ONE spelling, shared by the local tokens in
/// `SiftEngine/Staging.swift` and the remote tokens below. Two independent "v3" strings were the
/// hazard: if they drifted, the purge's format sweep (`!token.hasPrefix("v3|")`) would silently
/// delete every remote staged copy on every purge, with the whole suite green.
public let stagingTokenVersion = "v3"
private let tokenVersion = stagingTokenVersion

/// The identity a cached remote copy is matched on.
///
/// Same `v3|` prefix as a local staging token, so the purge's format sweep keeps them, with
/// `remote` as the second field so the two families can never be confused for one another.
///
///     with identity:     v3|remote|<sanitized-url>|etag=<e>
///                        v3|remote|<sanitized-url>|lm=<ms>|len=<n>
///     without identity:  v3|remote|<sanitized-url>|fetched=<ns>
///
/// **Why three forms, in this order.** An `ETag` is the server's own statement about its content,
/// so it is used alone — adding `Last-Modified` on top of it can only invalidate a copy that was
/// actually fine (a re-upload of identical bytes moves the date and not the tag). Failing that,
/// `Last-Modified` **and** `Content-Length` together are the HTTP twin of the local
/// `(mtime, size)` that `SourceKey` already trusts, and they are required *together*: a
/// `Last-Modified` alone has one-second granularity and would adopt a copy of a file rewritten
/// within the same second, so half an identity is no identity.
///
/// **The `fetched=` form is the point.** When a server offers neither, there is nothing to compare,
/// and the only safe answer is that the copy is never adopted again. That is spelled as a field
/// which is *different on every call given a distinct `fetchedAtNs`* rather than as an
/// `if token.hasPrefix("…|fetched=") { return false }` branch in the adoption code — a branch can
/// be deleted by someone tidying up, and the deletion looks harmless. As a property of the format
/// it cannot be removed without the tokens visibly changing shape.
///
/// **Who owns the uniqueness.** The caller owns the clock — this function reads none, which is what
/// keeps it pure and testable in microseconds. The *format* owns the guarantee that distinct
/// `fetchedAtNs` values produce distinct tokens, and that no `fetched=` token can ever equal an
/// identity token. Pass a monotonic clock reading; passing a constant is the caller defeating its
/// own cache, not this function forging an identity.
///
/// Field values are escaped (see `escapeTokenField`) so a `|` inside a URL or an ETag cannot forge
/// a field boundary.
public func remoteStagingToken(
    sanitizedURL: String, etag: String?, lastModifiedMs: Int?, contentLength: Int?,
    fetchedAtNs: Int
) -> String {
    var parts = [tokenVersion, "remote", escapeTokenField(sanitizedURL)]
    if let etag = nonEmpty(etag) {
        parts.append("etag=\(escapeTokenField(etag))")
    } else if let lastModifiedMs, let contentLength {
        parts.append("lm=\(lastModifiedMs)")
        parts.append("len=\(contentLength)")
    } else {
        parts.append("fetched=\(fetchedAtNs)")
    }
    return parts.joined(separator: "|")
}

/// Percent-escape the two characters that could otherwise forge a field boundary in a `|`-delimited
/// token. `|` is the delimiter; `%` has to go first and it is not optional.
///
/// 🔴 Escaping `|` alone is **not** injective: `a|b` and the already-encoded `a%7Cb` are different
/// URLs that would both render as `a%7Cb`, and two different sources sharing one token is a staged
/// copy adopted for the wrong file — the plausible-wrong-value failure this whole product exists to
/// avoid. Escaping `%` first sends them to `a%7Cb` and `a%257Cb`, which is reversible and therefore
/// collision-free.
///
/// Refusal was the alternative and it does not fit: this function returns a non-optional `String`,
/// a `|` in a path is legal (merely unencoded), and "Sift cannot open this file" is a worse answer
/// than four extra characters in a token nobody reads.
private func escapeTokenField(_ value: String) -> String {
    value
        .replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "|", with: "%7C")
}
