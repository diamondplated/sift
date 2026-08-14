import DuckDBKit
import Foundation
import SiftCore

// Opening a URL: the connection-needing half of `SiftCore/Remote.swift`, and the sibling of
// `SourceProbe.swift`. Identity comes from an HTTP HEAD, the format decision comes from the
// extension (there are no magic bytes to read without downloading), the download goes through
// DuckDB so it can use DuckDB's own credentials, and three shapes are refused before the wire.
//
// Every fact this file leans on was MEASURED against the vendored libduckdb 1.5.5 — the ten in
// `docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md`, plus five taken here against the
// loopback oracle and cited at the line that depends on them.
//
// THE RULING THIS FILE IMPLEMENTS. A remote text format is downloaded ONCE, to a local cache, and
// everything after that — sniff, stage, bad rows — runs against the local copy. That is not a
// convenience: MEASURED (spike §7), `sniff_csv(url, sample_size=20)` fetches 100 % of the object
// and a bare `read_csv(url)` fetches 200 % of it, so reading in place re-downloads the whole file
// on every statement. Parquet is the exception and reads in place for real: a `count(*)` on a
// 28.6 MB file cost 64 KB.

// MARK: - what a URL is on the wire

/// The URL as it must go to DuckDB or `URLSession`: `sanitized` with the query put back.
///
/// 🔴 The only place the two halves are rejoined, and the result is **transient by contract** — it
/// goes into one call and is never stored, never rendered, never persisted. An Azure SAS token
/// lives in that query. `RemoteURL` exists to keep it out of window titles, log lines, the staging
/// catalog and saved config; a `wireURL` kept in a struct puts it back into all four.
func wireURL(_ url: RemoteURL) -> String {
    guard let query = url.query else { return url.sanitized }
    return url.sanitized + "?" + query
}

/// Everything from the authority's first `/` onward, or `""` when the URL names only a host.
/// The query and the fragment are already gone (`RemoteURL.sanitized`), so a `*` or a `_delta_log`
/// found here really is in the path.
func remotePath(_ url: RemoteURL) -> String {
    guard let sep = url.sanitized.range(of: "://") else { return "" }
    let rest = url.sanitized[sep.upperBound...]
    guard let slash = rest.firstIndex(of: "/") else { return "" }
    return String(rest[slash...])
}

/// DuckDB puts the URL it was handed into its own error text — SAS token included. Every message
/// from a statement that carried a `wireURL` goes through this before it can reach a user.
func redactQuery(_ message: String, _ url: RemoteURL) -> String {
    guard let query = url.query else { return message }
    return message.replacingOccurrences(of: "?" + query, with: "?\u{2026}")
}

/// A byte count for a sentence. Deliberately integer-only and unit-free of decimals: no
/// `NumberFormatter` anywhere near a user-visible string (AGENTS.md, four shipped locale bugs), and
/// a cap message needs the magnitude, not the digits.
func byteCount(_ n: Int) -> String {
    let mb = 1024 * 1024
    return n >= mb ? "\(n / mb) MB" : "\(n) bytes"
}

// MARK: - identity

/// What a HEAD told us, or `nil` where auth or scheme makes a HEAD impossible.
///
/// Feeds two things and nothing else: the `SourceKey` a remote source is identified by, and
/// `remoteStagingToken`, which decides whether a cached copy may be adopted. Both treat a missing
/// field as "no identity", which is the safe direction — a copy that can never be adopted costs a
/// download; a copy wrongly adopted shows the wrong file's data.
public struct RemoteIdentity: Sendable, Equatable {
    public let etag: String?
    public let lastModifiedMs: Int?
    public let contentLength: Int?
    public let acceptsRanges: Bool

    public init(
        etag: String? = nil, lastModifiedMs: Int? = nil, contentLength: Int? = nil,
        acceptsRanges: Bool = false
    ) {
        self.etag = etag
        self.lastModifiedMs = lastModifiedMs
        self.contentLength = contentLength
        self.acceptsRanges = acceptsRanges
    }
}

/// One HEAD, through `URLSession`, for `http`/`https` only.
///
/// **`nil` for `s3`/`az`/`abfss`, deliberately.** `URLSession` has no idea how to sign an Azure or
/// S3 request — the credential lives in a DuckDB secret (spike §6), which is inside the engine and
/// not reachable from here. A HEAD sent anyway would be an unauthenticated request that returns 403
/// and an *identity built from an error page*. `nil` is not a failure: it is "this URL has no
/// cheap identity", and `remoteStagingToken` already has a form for exactly that (`fetched=`), so a
/// v1 Azure source simply never adopts a cached copy.
///
/// `nil` is also the answer for every failure — a timeout, a refused connection, a 404, a 500. The
/// caller is about to try the real read, which produces the error a user can act on; a second
/// error from the identity probe would only race it.
///
/// The cache policy is not decoration: a HEAD answered from `URLSession`'s own cache is an identity
/// for whatever the object USED to be, which is the one thing this function must never return.
public func remoteIdentity(_ url: RemoteURL, timeout: TimeInterval = 5) async -> RemoteIdentity? {
    // The scheme test is a CLARITY guard, not a correctness one, and it has a SURVIVING MUTANT
    // recorded rather than hidden: deleting it leaves `remoteIdentityIsNilForEveryUrlUrlSession…`
    // green, because `URLSession` refuses `az://`/`s3://` itself with `NSURLErrorUnsupportedURL`
    // and the `nil` comes out of the same door. It stays because the reason those schemes have no
    // identity is a design fact (the credential is in a DuckDB secret), not a Foundation
    // limitation — if URLSession ever learned a scheme, the request must still not be sent.
    guard url.scheme == .http || url.scheme == .https,
        let target = URL(string: wireURL(url))
    else { return nil }

    // Both knobs, on a session of our own — `URLSession.shared`'s configuration is fixed, so
    // `timeoutIntervalForResource` cannot be set on it at all. They are belt; `withDeadline` below
    // is the enforcement. See its comment for the measurement that made that necessary.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }

    let request: URLRequest = {
        var head = URLRequest(
            url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        head.httpMethod = "HEAD"
        return head
    }()

    return await withDeadline(timeout) {
        guard let (_, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }

        // `value(forHTTPHeaderField:)` is case-insensitive (macOS 13+), which matters: the loopback
        // oracle sends `ETag` and Foundation reports it back as `Etag`.
        let etag = http.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespaces)
        let ranges = http.value(forHTTPHeaderField: "Accept-Ranges")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return RemoteIdentity(
            etag: (etag?.isEmpty ?? true) ? nil : etag,
            lastModifiedMs: http.value(forHTTPHeaderField: "Last-Modified").flatMap(httpDateMs),
            contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) },
            acceptsRanges: ranges == "bytes"
        )
    }
}

/// Run `work`, giving up and answering `nil` after `timeout` — **Sift's clock, not the host's.**
///
/// 🔴 MEASURED, and it is the reason this exists rather than a bare `timeoutInterval`. On the
/// macos-15 CI runner a HEAD against a held-open socket, asked to give up after 1 s, took **31 s** —
/// the OS default — so neither `URLRequest.timeoutInterval` nor
/// `URLSessionConfiguration.timeoutIntervalForRequest` bounded it there. On this Mac the same knob
/// is honoured to the millisecond (10 ms asked, 20 ms taken; 0.25/1/3 s each within 10 ms). That is
/// the SDK skew AGENTS.md warns about in its sharpest form: the local machine makes an unbounded
/// call look bounded, so the documented 5 s contract was really "whatever the host felt like".
///
/// A `TaskGroup` rather than a detached task and a continuation: the loser is cancelled by the group
/// and the whole thing stays structured, so nothing outlives the call. `Task.sleep` and
/// `URLSession.data(for:)` both honour cancellation, so the group exits as soon as the winner is in.
///
/// ponytail: generic and one call site, which is normally a smell. It is a separate function for
/// one reason — `theDeadlineIsSiftsOwnClockAndNotTheHostOperatingSystems` can then test the
/// mechanism directly, and on a machine where the OS knob happens to work (this one) that is the
/// ONLY test that can tell a raced probe from an unraced one.
func withDeadline<T: Sendable>(
    _ timeout: TimeInterval, _ work: @Sendable @escaping () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private let httpMonths = [
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
]

/// `Wed, 21 Oct 2026 07:28:00 GMT` → epoch milliseconds, or `nil` for anything else.
///
/// **IMF-fixdate only.** RFC 9110 §5.6.7 requires every server to *generate* that form and only
/// asks recipients to tolerate the two obsolete ones; an unparsed date falls through to the
/// `fetched=` token form, which merely means the copy is never re-adopted — the safe direction.
///
/// Hand-parsed, and the pieces go through `DateComponents` rather than a formatter. AGENTS.md bans
/// the `DateFormatter` family from anything user-visible after four shipped locale bugs, and the
/// reason applies with more force here: `Locale.current` decides how a formatter reads a month
/// name, so a cache identity would be a function of the user's region. Nothing below reads a
/// locale — an explicit Gregorian calendar pinned to UTC, and `Int()` for the digits.
func httpDateMs(_ text: String) -> Int? {
    // "Wed," "21" "Oct" "2026" "07:28:00" "GMT"
    let fields = text.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 5, fields[0].hasSuffix(","),
        let day = Int(fields[1]), let month = httpMonths[fields[2].lowercased()],
        let year = Int(fields[3])
    else { return nil }
    let clock = fields[4].split(separator: ":", omittingEmptySubsequences: false)
    guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]),
        let second = Int(clock[2])
    else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
    calendar.timeZone = utc
    let parts = DateComponents(
        timeZone: utc, year: year, month: month, day: day,
        hour: hour, minute: minute, second: second
    )
    guard let date = calendar.date(from: parts) else { return nil }
    return Int(date.timeIntervalSince1970 * 1000)
}

// MARK: - the format decision

/// What Sift will read this URL as — extension first, a DESCRIBE probe when there is no extension,
/// and three refusals that never reach the network.
///
/// **There are no magic bytes here, and there cannot be.** `detectFormat` reads the first eight
/// bytes of a local file because that costs nothing; the same eight bytes over http cost a request,
/// and for CSV and JSON they cost the whole object (spike §7). So the path component's extension
/// decides, and `RemoteURL.effectiveExt` is what makes that safe — MEASURED as the shipped defect
/// it exists for: `NSString.pathExtension` on `https://h/get?id=5&fmt=csv` answers `csv`, and on a
/// SAS'd `.csv` it answers the tail of the signature.
public func remoteFormat(_ url: RemoteURL, con: Connection) throws -> Fmt {
    let path = remotePath(url)

    // 🔴 MEASURED (spike §4, re-measured here): DuckDB refuses `read_parquet('http://…/*.parquet')`
    // at PLAN time — `Invalid Input Error: Globs (`*`) for generic HTTP file is are not supported.`
    // — and the server logs zero requests. Refusing here rather than passing it through is about
    // the sentence, not the round trip: DuckDB's names a setting (`allow_asterisks_in_http_paths`)
    // that only converts a clear error into a 404 on a literal `*`.
    guard !path.contains("*") else {
        throw UnsupportedSource("Remote folder globs are not supported — open a single object.")
    }

    // 🔴 MEASURED (spike §3): `delta_scan` over http fails INSIDE delta-kernel-rs, before a single
    // request leaves the machine — it carries its own object_store and never routes through
    // httpfs, so no setting, secret or retry can reach it. The refusal matters more than the
    // failure: reading the same files as a parquet list WORKS and returns the tombstoned rows as
    // live data (150 where delta_scan returns 100). A silent downgrade would show deleted rows as
    // real ones, which is the worst thing this product could do.
    guard !path.hasSuffix("/"), !path.contains("_delta_log") else {
        throw UnsupportedSource(
            "\(url.displayName) is a remote folder or Delta table, and neither can be read over a "
                + "URL \u{2014} DuckDB's Delta reader never reaches the server and an HTTP folder "
                + "cannot be listed \u{2014} so download it and open the folder locally."
        )
    }

    if let fmt = try formatFromExtension(url) { return fmt }
    return try describedFormat(url, con: con)
}

/// The extension table, reading the same per-format sets `detectFormat` reads so the two cannot
/// drift, and seeing through one compression suffix the way `_ext_chain` does locally.
private func formatFromExtension(_ url: RemoteURL) throws -> Fmt? {
    let ext = dataExtension(url)
    if parquetExt.contains(ext) { return .parquet }
    if ndjsonExt.contains(ext) { return .ndjson }
    if jsonExt.contains(ext) { return .json }
    if xlsxExt.contains(ext) { return .xlsx }
    if xlsExt.contains(ext) {
        // The same refusal a local `.xls` gets, for the same reason (no Swift xlrd), and reached
        // the same way — one sentence naming the way out rather than a download that then fails.
        throw LegacyXls(
            "\(url.displayName) is a legacy .xls file. Open it and re-save as .xlsx \u{2014} "
                + "Sift reads the modern format only."
        )
    }
    if csvExt.contains(ext) { return .csv }
    return nil
}

/// The data extension of the URL's PATH, with one compression suffix stripped — `".csv"` for
/// `…/a.csv.gz`, `""` for a URL with no extension at all.
///
/// `RemoteURL.effectiveExt` is the final suffix, so a `.csv.gz` reads as `.gz` and would fall
/// through to the DESCRIBE probes below — three round trips to rediscover something the URL says
/// out loud. `NSString.pathExtension` is safe on `displayName` specifically: it is derived from the
/// path alone, with the query already gone.
func dataExtension(_ url: RemoteURL) -> String {
    guard compressionExt.contains(url.effectiveExt) else { return url.effectiveExt }
    let stem = (url.displayName as NSString).deletingPathExtension
    let inner = (stem as NSString).pathExtension.lowercased()
    return inner.isEmpty ? "" : "." + inner
}

/// A URL with no usable extension: ask DuckDB to bind a relation over it and see which reader
/// takes it.
///
/// **The order is a correctness argument, not a preference.** MEASURED against the loopback oracle:
///
///  * `read_parquet` is the only probe that does not download the object — a DESCRIBE over a
///    1.73 MB parquet moved 32 KB in three ranged requests. It goes first because it is nearly
///    free.
///  * `read_json_auto` before `read_csv`, because **`read_csv` accepts JSON**: `DESCRIBE SELECT *
///    FROM read_csv(<a JSON array>)` succeeds and reports two VARCHAR columns named
///    `[{"a":1}` and `{"a":2}]`. CSV last is the difference between reading a JSON document
///    correctly and reading it as a two-column table of nonsense.
///
/// Each of the two text probes costs one whole-object download that is then thrown away (spike §7),
/// which is why this path exists only for a URL that offers no extension.
private func describedFormat(_ url: RemoteURL, con: Connection) throws -> Fmt {
    let wire = wireURL(url)
    let probes: [(Fmt, String)] = [
        (.parquet, "read_parquet(?)"), (.json, "read_json_auto(?)"), (.csv, "read_csv(?)"),
    ]
    for (fmt, expr) in probes {
        if (try? con.query("DESCRIBE SELECT * FROM \(expr)", [.text(wire)]).allRows()) != nil {
            return fmt
        }
    }
    throw UnsupportedSource(
        "\(url.displayName) has no file extension in its URL and Sift could not read it as "
            + "parquet, JSON or CSV \u{2014} put the extension in the URL, or download the file "
            + "and open it locally."
    )
}

// MARK: - downloading

/// The most Sift will pull down from a URL before refusing.
///
/// It is a **refusal** threshold and not a warning, because `read_blob` gives nothing to warn with:
/// MEASURED (spike §5), it is one atomic GET with no progress, no chunking and no cancel — a
/// `duckdb_interrupt` issued before execution begins is swallowed. A 3 GB workbook is therefore an
/// un-cancellable spinner, and the only place to stop it is before it starts.
public let remoteDownloadCapBytes = 500 * 1024 * 1024

/// The TEMP table one download lands in. Connection-scoped (a TEMP table is visible only to the
/// connection that created it), and `downloadRemoteObject` owns its whole lifetime.
private let downloadTable = "_sift_remote_download"

/// Download a remote object through DuckDB — and therefore through DuckDB's own credentials —
/// to `path`, returning the byte count.
///
/// `read_blob` rather than `URLSession` for one reason: an `az://` or `s3://` object is reachable
/// only with the secret the engine issued (spike §6), which `URLSession` cannot sign. MEASURED
/// (spike §5): `read_blob` over httpfs is byte-exact, so there is no checksum step to add on top.
///
/// **The cap is enforced twice, and the two checks are different questions.**
///
///  1. *What does the server claim?* MEASURED here: `SELECT size FROM read_blob(url)` issues **one
///     HEAD and no GET** — `read_blob` returns `filename, content, size, last_modified`, and
///     projecting only `size` never asks for the body. So an object that is too big is refused
///     with nothing downloaded, which is the check that actually protects anyone.
///  2. *What actually arrived?* The claim and the download are two separate HTTP transactions, so
///     the object can change between them — and a server can simply be wrong. This one costs the
///     bytes; it is what stops them being written to disk and opened.
///
/// 🔴 **`path` must keep the object's file extension.** `detectFormat` reads magic bytes first but
/// still consults the extension for a zip container, so a cache file named without `.xlsx` is
/// refused as "looks like a zip archive, not a data file" — see `RemoteRef.cachePath`.
///
/// ponytail: the object crosses into Swift as one base64 string, so the peak is roughly 2.3× the
/// object at the 500 MB cap. `substring()` has no BLOB overload on 1.5.5 (MEASURED —
/// `Binder Error: No function matches … 'substring(BLOB, BIGINT, BIGINT)'`), so chunking has to go
/// the other way: `COPY (SELECT to_base64(content) …) TO <tmp>` and a chunked decode on the way
/// back. Worth doing if the cap ever rises.
@discardableResult
public func downloadRemoteObject(
    con: Connection, url: RemoteURL, to path: String, capBytes: Int = remoteDownloadCapBytes
) throws -> Int {
    let wire = wireURL(url)

    // (1) The claim. One HEAD, no body.
    if let claimed = try blobSize(con, wire, url), claimed > capBytes {
        throw UnsupportedSource(
            "\(url.displayName) is \(byteCount(claimed)) and Sift downloads at most "
                + "\(byteCount(capBytes)) from a URL \u{2014} download it yourself and open the "
                + "file locally."
        )
    }

    // (2) The download. Into a TEMP table rather than straight into a projection, so the size it
    // really turned out to be can be checked BEFORE the object is encoded for the trip into Swift:
    // base64-ing 3 GB in order to refuse it is a swap storm, not a refusal.
    defer { try? con.execute("DROP TABLE IF EXISTS \(q(downloadTable))") }
    do {
        _ = try con.query(
            "CREATE OR REPLACE TEMP TABLE \(q(downloadTable)) AS "
                + "SELECT content FROM read_blob(?)", [.text(wire)]
        )
    } catch let error as DuckDBError {
        throw DuckDBError(redactQuery(error.message, url))
    }

    let rows = try con.query("SELECT octet_length(content) FROM \(q(downloadTable))").allRows()
    guard let sizeRow = rows.first else {
        throw UnsupportedSource("\(url.displayName) returned nothing at all.")
    }
    let received = cellInt(sizeRow[0])
    guard received <= capBytes else {
        throw UnsupportedSource(
            "\(url.displayName) turned out to be \(byteCount(received)), over the "
                + "\(byteCount(capBytes)) Sift downloads from a URL \u{2014} the size the server "
                + "reported was wrong, and nothing was cached."
        )
    }

    // MEASURED: `to_base64`/`Data(base64Encoded:)` round-trips 1 MiB of non-compressible bytes
    // byte-for-byte. Base64 rather than `hex` because Foundation decodes it in one call — a
    // hand-written hex decoder in the path that produces the file everything else is read from is
    // a decoder to get wrong — and because it is 1.33× rather than 2×.
    let encoded = try con.query("SELECT to_base64(content) FROM \(q(downloadTable))").allRows()
    guard let text = encoded.first.map({ cellText($0[0]) }),
        let bytes = Data(base64Encoded: text), bytes.count == received
    else {
        throw UnsupportedSource("\(url.displayName) could not be read back after downloading it.")
    }

    // 0600 for the same reason `~/.sift` is 0700 (spec §11 frozen contract): this file is a copy of
    // someone's real data sitting on a laptop. One call, not `createFile` + a chmod behind it —
    // MEASURED here, unlike `createDirectory`'s attributes, `createFile`'s ARE applied to a path
    // that already exists (a stale 0644 cache file comes back 0600), so the second line would be a
    // mutant nothing could kill.
    let manager = FileManager.default
    guard manager.createFile(
        atPath: path, contents: bytes, attributes: [.posixPermissions: 0o600]
    ) else {
        // No half-written cache file left behind for the next open to adopt as a whole one.
        // `createFile` is not documented as atomic, so a failure mid-write can leave one. This is a
        // RECORDED SURVIVING MUTANT — deleting it leaves the suite green, because it is reachable
        // only through a filesystem that fails part-way and no test can arrange that. The property
        // it backs up is structural and IS tested: every other failure path here throws before a
        // byte is written, so there is nothing to clean up (see the three `!fileExists` assertions).
        try? manager.removeItem(atPath: path)
        throw UnsupportedSource("Could not write the downloaded copy of \(url.displayName).")
    }
    return received
}

/// The size the server claims, from the HEAD `read_blob` does anyway. `nil` when the server offers
/// no length — nothing to check against, so the download proceeds and check (2) catches it.
private func blobSize(_ con: Connection, _ wire: String, _ url: RemoteURL) throws -> Int? {
    do {
        guard let row = try con.query("SELECT size FROM read_blob(?)", [.text(wire)])
            .allRows().first, !row[0].isNull
        else { return nil }
        return cellInt(row[0])
    } catch let error as DuckDBError {
        throw DuckDBError(redactQuery(error.message, url))
    }
}

// MARK: - the spec

/// The `SourceSpec` for a remote object — the glue `Session.openPath`'s remote half consumes.
///
/// `cachePath` decides the shape, and there are only two:
///
///  * **given** — the object has already been downloaded, so every format question is answered
///    against the local copy by `buildSource`, magic bytes included. The sniffing, the ragged-CSV
///    recovery, the sheet picking, the exact counts and the row estimates all come for free and
///    stay in ONE place; this function only re-keys the result and attaches the remote facts.
///  * **`nil`** — parquet, read in place. MEASURED (spike §7): a `count(*)` over http costs 0.2 %
///    of the file and a filtered scan 0.7 %, so downloading it would be strictly worse.
///
/// The key is the plan's: `path` is the **sanitized** URL (the identity the user sees, and the only
/// form that may be persisted), `mtimeNs` is `Last-Modified` promoted to nanoseconds or the fetch
/// clock when the server offered none, `size` is the `Content-Length` or 0.
///
/// 🔴 **`fetchedAtNs` is the caller's clock, on purpose.** `remoteStagingToken`'s `fetched=` form is
/// what makes a copy with no server identity un-adoptable, and it only works if distinct fetches
/// produce distinct values. Passing a constant is a caller defeating its own cache.
///
/// KNOWN GAP, for whoever wires the open path: `spec.target` for the in-place parquet case is the
/// sanitized URL, so a SAS token in the pasted URL does NOT survive into later reads. That is
/// deliberate — the alternative writes a bearer credential into the `CREATE VIEW` text DuckDB
/// stores on disk — and the designed answer is a DuckDB secret (`createSecretSQL`), which resolves
/// by scope and needs nothing in the URL.
public func buildRemoteSource(
    con: Connection, url: RemoteURL, identity: RemoteIdentity?, cachePath: String?,
    fetchedAtNs: Int, sheet: String? = nil, nullPadding: Bool = false, skipPreamble: Bool = true
) throws -> SourceSpec {
    let key = SourceKey(
        path: url.sanitized,
        mtimeNs: identity?.lastModifiedMs.map { $0 * 1_000_000 } ?? fetchedAtNs,
        size: identity?.contentLength ?? 0
    )
    let ref = RemoteRef(
        url: url.sanitized, etag: identity?.etag, lastModifiedMs: identity?.lastModifiedMs,
        contentLength: identity?.contentLength, fetchedAtNs: fetchedAtNs, cachePath: cachePath
    )

    guard let cachePath else {
        let wire = wireURL(url)
        do {
            let meta = try parquetFooter(con, target: wire)
            let cols = try describe(con, relationExpr: "read_parquet(\(qlit(wire)))")
            return SourceSpec(
                key: key, fmt: .parquet, readFn: "read_parquet", columns: cols,
                rowCount: meta.numRows, remote: ref
            )
        } catch let error as DuckDBError {
            throw DuckDBError(redactQuery(error.message, url))
        }
    }

    // `local.fmt`, never a format decided from the URL: the bytes are here now, so `detectFormat`'s
    // magic-byte check is authoritative and a `.csv` that is really a workbook is caught exactly
    // the way it is for a local file.
    let local = try buildSource(
        con, path: cachePath, sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
    )
    return SourceSpec(
        key: key, fmt: local.fmt, readFn: local.readFn, readArgs: local.readArgs,
        columns: local.columns, rowCount: local.rowCount, rowEstimate: local.rowEstimate,
        compressed: local.compressed, sheet: local.sheet, sheets: local.sheets,
        deltaVersion: local.deltaVersion, sniffPrompt: local.sniffPrompt, glob: local.glob,
        raggedColumns: local.raggedColumns, remote: ref
    )
}
