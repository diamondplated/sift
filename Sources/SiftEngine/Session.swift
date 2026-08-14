import CDuckDB
import Darwin
import DuckDBKit
import Foundation
import SiftCore

// The one stateful object: the catalog of open sources, opening a path, background post-open
// work, and paging. Ported from engine/session.py's `Session.__init__`, `open_path`,
// `_after_open`, `_detect_bad_rows`, `page`, `_sorted_relation`, `table`, `_tlock`, `relation`,
// `raw_relation`, `engine_info`, `state`, `close_table`, `shutdown`, `drop_private_store`, and
// `_sweep_private_stores`. The rest of session.py lives beside it, per the design spec's port
// map: run_sql and profiling in SessionQueries.swift, the staging lifecycle in Staging.swift,
// joins and merge in Joins.swift, and export in Export.swift.
//
// Concurrency, in three facts (replacing Python's own docstring, which described a single
// DuckDBPyConnection guarded by cursors and a thread pool):
//   1. One `DuckDBKit.Database` is opened at launch, against `~/.sift/stage.duckdb`.
//   2. `openPath`'s initial work (build the spec, create the view), `_after_open`'s background
//      pipeline, and `runProfile` each take their own throwaway `Connection` — the direct analogue
//      of Python's `con.cursor()` for one-shot work. `Connection` is deliberately not `Sendable`
//      and never crosses a task boundary: profiling's is created *inside* its detached task.
//
//      `openPath`'s REMOTE half is the exception that proves the "initial work runs on the actor"
//      half of this: `buildRemoteOpen` is a detached `Task` whose `Connection` is created inside
//      it, because a hung endpoint is a real and ordinary thing and it must suspend the open
//      rather than freeze the actor for the OS's idea of a timeout (MEASURED, RemoteProbe.swift:
//      31 s on the macos-15 runner for a HEAD asked to give up after 1). It touches NO actor state
//      and in particular never `pagingConnection` — the six users below are still six.
//   3. SIX methods share ONE long-lived `Connection` (`pagingConnection`), for as long as the
//      `Session` exists, instead of opening a fresh one per call. In this file: `page`,
//      `sortedRelation`, `closeTable`. In Staging.swift: `applyStaged` (drops a stale
//      materialized-sort TEMP TABLE), `finishStage` (drops the VIEW of a table closed mid-job),
//      and `unstage` (drops a materialized-sort TEMP TABLE).
//
//      Sharing is not a stylistic choice — MEASURED (see `sortedRelation`'s doc comment): a
//      `CREATE TEMP TABLE` created on one `duckdb_connect()` connection is invisible to a `SELECT`
//      on a different one, even against the same file. So a materialized sort must be read back
//      through the SAME connection that created it across however many `page()` calls follow, and
//      a DROP of one must go through that connection too — which is why the three in Staging.swift
//      are on this list at all.
//
//      🔴 **THE INVARIANT IS PER-USE, NOT PER-METHOD, AND ONE OF THE SIX IS `async`.** `Connection`
//      is not `Sendable`; what makes sharing safe is that no user ever SUSPENDS between acquiring
//      the connection and finishing with it, so the actor's serial executor guarantees exactly one
//      caller is inside at a time. All six were re-checked line by line and all six hold. But
//      `unstage` IS `async` and DOES `await` — `computeProfile`, immediately after it is done with
//      the connection — so "none of these methods awaits anything" (what an earlier version of
//      this fact said, about three methods it thought were all of them) is simply false, and a
//      reader who believed it would not know what they were preserving. **The rule to preserve:
//      you may `await` in one of these methods, but never between `pagingConnection.…` and the
//      last statement that depends on it.** A new user of `pagingConnection` must be added to this
//      list and checked against that rule.
//
//      `openPath`'s initial half and `_after_open`'s background pipeline still open a fresh
//      `Connection` each time (fact 2) — they never touch a materialized sort, so they have no
//      reason to share one.
//
// `Session` is an `actor`; it owns the catalog. `openPath`'s initial work and `page` run directly
// on the actor — both are meant to be interactive-latency, matching Python running them in the
// request-handling thread rather than the background pool. The genuinely slow work — `_after_open`'s
// pipeline (exact count, bad-row detection, staging decision), the staging CTAS, and profiling —
// runs instead as a detached `Task` that creates its own `Connection` off the actor and calls back
// with small, fast, actor-isolated "apply" methods: `applyCount`, `applyBadRows`,
// `applyStageDecision`, `applyStaged`, `applyProfile`. Every one of them is checked against the
// `Table.openedAt` it was launched for (see `runAfterOpen`'s doc comment), so a result from a
// closed-and-reopened table's stale background work can never land on the new table sharing its
// name. Profiling is the newest of these and the one with a public caller waiting on it: see
// `SessionQueries.computeProfile`, which detaches the work and then awaits it, so the actor is free
// for the duration while the caller still gets its profile. That waiting caller is why profiling
// needs one guard the others do not: the `apply*` check protects the CATALOG, and a caller holding
// the result in its hand is a second way for a dead generation's answer to reach the user — so
// `computeProfile` returns only what `applyProfile` accepted, never the task's own return value.
//
// SSE (`attach_loop`/`subscribe`/`unsubscribe`/`emit`) is deleted, per the design spec: in-process,
// a property change on an actor a SwiftUI-facing observer wraps IS the notification. Every call
// site below that would have been `self.emit(...)` in Python is simply the state mutation itself,
// with a comment where useful.

/// Default page size for `Session.page`.
public let pageRows = 500

/// The materialized copy `sortedRelation` builds is capped at this many rows — ported verbatim
/// from Python's identical `LIMIT` in `_sorted_relation`, which has the same cap and the same
/// consequence: a sort over more rows than this truncates the materialized copy, so pages past row
/// `sortMaterializeMax` come back empty.
///
/// **No longer silent (spec §13a, CLOSED Plan 4 Task 5).** `Table.scrollableRows` caps the scroll
/// extent at this number whenever a sort is active, so everything the thumb can reach returns rows,
/// and `Table.sortTruncated` is what the UI puts a banner on — a named missing tail, with "clear
/// the sort" as the way to reach it. The other §13a option — re-materializing a window per scroll —
/// was rejected: `sortedRelation`'s own measurement shows tie order is not reproducible across
/// separate materializations, so two windows duplicate or drop rows at their seam.
///
/// `public` for the same reason: the UI needs the number to say how many rows the sort can reach.
/// Deliberately not raised — it is Python's number, and 5M rows of materialized copy is already the
/// memory ceiling the engine chose.
public let sortMaterializeMax = 5_000_000

/// Extensions Sift loads at startup. Mirrors Python's module-level `_EXTENSIONS`.
private let sessionExtensions = ["delta", "excel"]

/// A user-facing session failure. Mirrors Python's `class SiftError(RuntimeError)` — a message
/// meant to reach the user with nothing else attached (app.py used to turn it into an HTTP 400
/// with the message intact; there is no HTTP layer anymore, but the "one clean sentence" contract
/// is the same one SiftUI will surface in a banner). Named `SessionError`, not `SiftError`: this
/// module imports `SiftCore`, whose `SiftError` is the protocol every concrete error here
/// conforms to (see `SQLRejected`, `UnsupportedSource`) — reusing the name would shadow it.
public struct SessionError: SiftError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Session

public actor Session {
    /// Every `SIFT_HOME` a live `Session` in this process is holding. See `OpenHomes` for what two
    /// of them on one home actually do to each other, and `init`'s refusal below.
    static let openHomes = OpenHomes()
    /// This session's identity in `openHomes`. `nonisolated let` so `deinit` can read it.
    nonisolated let claimToken = UUID()

    public nonisolated let siftHome: String
    public nonisolated let dbPath: String
    /// `false` once a second engine has been found holding the shared store's lock — see `init`.
    public nonisolated let sharedStore: Bool
    /// `<siftHome>/connections.json` — the remote-connections config this session read at launch
    /// and rewrites on every change. Public because a Connections screen that refuses to start has
    /// to be able to say which file to fix.
    public nonisolated let connectionsPath: String
    /// The posture the `Database` was actually opened with, frozen for the life of this session.
    ///
    /// 🔴 Not the same thing as `connections().allowRemote`, and conflating them is the bug this
    /// property exists to prevent. MEASURED (remote facts §2): `disabled_filesystems` only ever
    /// grows inside one `duckdb_database`, so the switch in the config can be flipped at any time
    /// and the ENGINE keeps whatever it started with. Everything in Connections.swift that reports
    /// `ConnectionOutcome` compares the two.
    public nonisolated let allowRemoteAtLaunch: Bool
    /// The Keychain service this session files credentials under.
    ///
    /// Production is always `Keychain.service`. The seam exists so ConnectionsTests can point a
    /// real `Session` at `dev.sift.connections.<something>` and do genuine add/read/delete round
    /// trips without ever touching an item a user actually saved — the same namespace split
    /// `KeychainTests` makes, applied one layer up. There is no public way to set it.
    nonisolated let keychainService: String
    /// `@unchecked Sendable` (Database.swift) and immutable after `init`, so `nonisolated` lets
    /// the detached background pipeline in `runAfterOpen` reach it without an actor hop — the
    /// whole point of that path being detached in the first place.
    nonisolated let database: Database
    /// The one `Connection` shared by `page`, `sortedRelation` and `closeTable` — see this file's
    /// header (fact 3) for why it must be a single long-lived connection rather than one per call,
    /// and why sharing it is safe despite `Connection` not being `Sendable`. Actor-isolated, not
    /// `nonisolated`: unlike `database`, `Connection` isn't `Sendable`, so it must never be reached
    /// from outside the actor (in particular, never from `runAfterOpen`'s detached pipeline).
    let pagingConnection: Connection

    var tables: [String: Table] = [:]
    /// Per-table mutex, mirroring Python's `with self._tlock(name):`. Only this dictionary's
    /// get-or-create needs actor isolation; the returned `NSLock` is locked/unlocked from the
    /// caller's own (non-actor) context.
    ///
    /// 🔴 **RULED VESTIGIAL, 2026-08-11 (whole-plan review). The retry is the real mechanism.**
    /// `tlock` has exactly ONE acquisition site — `swapStaged` — in Swift *and* in Python, and
    /// `stageNow` refuses to start a second job for a table that already has one in flight
    /// (`t.staged || t.staging != nil`). So nothing can ever contend for one of these locks: to
    /// contend, two staging jobs would have to be swapping the same table name at the same
    /// instant, and the catalog makes that unconstructible. Spec §11 lists the lock as a frozen
    /// contract, so it stays — but a reader must not mistake it for the thing that makes the swap
    /// safe.
    ///
    /// What ACTUALLY handles the write-write conflict is `swapStaged`'s three-attempt retry with a
    /// `ROLLBACK` between, and that IS pinned: MEASURED, with a second CONNECTION (not a second
    /// job) holding an open `BEGIN; CREATE OR REPLACE VIEW t AS …`, the swap fails immediately
    /// with `TransactionContext Error: Catalog write-write conflict on alter`, and the retry is
    /// what puts the copy in place. A lock cannot help there — the conflicting writer is a
    /// different connection, not a different `Session` method.
    private var tableLocks: [String: NSLock] = [:]
    /// Source of `Table.openedAt` — see its doc comment. Incremented once per table this session
    /// puts into the catalog, never reused. Two writers: `openPath` and Joins.swift's `merge`,
    /// which produces a `Table` that is not backed by a file but still needs an identity no later
    /// open can collide with.
    var nextOpenGeneration = 0

    /// The in-flight profile per table name — the job's own id, the `openedAt` it was launched
    /// for, and the task (SessionQueries.swift owns every method that touches it; it lives here
    /// because Swift extensions cannot add stored properties).
    ///
    /// Two jobs: it coalesces concurrent callers onto one `SUMMARIZE` — the UI kicks a profile
    /// speculatively after the first page and the panels ask for one the moment a column is
    /// clicked, and on a wide table each of those is seconds of DuckDB work — and it is the claim
    /// token `applyProfile` checks, so a result whose claim was dropped (`applyStaged`/`unstage`
    /// revoking the job mid-flight) lands nowhere.
    ///
    /// **`id` is what `applyProfile` compares, not `openedAt`, and that is a fix rather than a
    /// detail.** Revocation does not reopen the table, so the replacement job registers under the
    /// SAME `openedAt` — a generation comparison therefore matched the *replacement's*
    /// registration, accepted the revoked job's result, and deleted the replacement's claim, so the
    /// correct profile that arrived moments later was itself thrown away and the stale one stayed
    /// cached for the life of the table. `openedAt` stays in the tuple because it is what decides
    /// COALESCING: a table closed and reopened under the same name is a different table, and a
    /// caller for the new one must never be joined onto the old one's job.
    var profileJobs: [String: (id: Int, openedAt: Int, task: Task<[ColumnProfile], Error>)] = [:]
    /// Source of `profileJobs`' `id`. Monotonic, never reused — the `stageJobSeq` shape, for the
    /// same reason: an identity that a later job cannot accidentally wear.
    var nextProfileJobID = 0

    // Staging job state (Staging.swift owns every method that touches these; they live here
    // because Swift extensions cannot add stored properties).
    //
    /// Live staging jobs by id, Python's `self.jobs`. A job is registered by `stageNow` and
    /// removed by whichever of `applyStaged`/`finishStage` ends it, so "not in this dictionary"
    /// means "not running" — which is exactly what `cancel` reports as `false`.
    var stageJobs: [String: StageJob] = [:]
    /// Python's `_job_seq`. Monotonic, never reused.
    var stageJobSeq = 0
    /// Python's `STAGE_DWELL_SECONDS`: how long `maybeStageAfterDwell` waits for a sign the user
    /// is actually working with a table before paying for the copy. A `var` rather than a
    /// constant purely so tests can shorten or lengthen it (`setStageDwellForTest`) — three real
    /// seconds of `sleep` in a parallel suite is a flake generator, not a test.
    var stageDwellSeconds: Double = 3.0

    // Remote connections (Connections.swift owns every method that touches these; they live here
    // because Swift extensions cannot add stored properties).
    //
    /// The config as it stands on disk, read before the `Database` opened and rewritten by every
    /// `addConnection`/`removeConnection`/`setAllowRemote`.
    var remoteConfig: RemoteConfig
    /// Why a saved connection's credential is not live on this engine, by connection id. Filled in
    /// at launch by `issueSecrets` and per-connection by `addConnection`. **Recorded, never
    /// thrown**: one bad credential must not stop the app opening local files.
    var secretIssues: [UUID: String] = [:]

    /// The shipping entry point. Delegates so the Keychain namespace stays out of the public API —
    /// see `keychainService`.
    public init(home: String? = nil) throws {
        try self.init(home: home, keychainService: Keychain.service)
    }

    init(home: String?, keychainService: String) throws {
        let resolvedHome = Self.resolveHome(home)
        // Read once into a local: the failure path below needs it while `self` is still only
        // partly initialized, and it must be the SAME value `deinit` will release with.
        let token = claimToken
        // 🔴 Spec §13a. Two `Database` handles on one file in this process are two independent
        // DuckDB instances with no shared catalog, and the second one's flush overwrites the
        // first one's — silently, with no lock error anywhere (which is why `sharedStore` below
        // reports `true` for both and protects nothing). Refusing is the only thing that stops it.
        guard Self.openHomes.claim(resolvedHome, token: token) else {
            throw SessionError(
                "Another Sift session in this process is already using \(resolvedHome). Two "
                    + "engines on one home are two independent DuckDB instances that cannot see "
                    + "each other's catalog, so the second one's writes would silently overwrite "
                    + "the first one's — refusing rather than corrupting the staged-data store."
            )
        }
        // A throwing initializer runs no `deinit` — nothing here is fully initialized when it
        // throws — so every failure path past the claim has to hand the home back explicitly.
        do {
            try Self.ensureHomeDirectory(resolvedHome)

            // 🔴 BEFORE the `Database` opens, and that ordering is the whole security posture.
            // `harden(allowRemote:)` is applied once, to a `Database` that is already open, and
            // MEASURED (remote facts §2) the disabled-filesystem set only ever grows afterwards —
            // there is no second chance. Reading the config later would mean either opening the
            // engine in the wrong posture or opening it twice. It also means a config Sift refuses
            // costs no store file: nothing on disk is touched before this line. See
            // `Connections.swift` for why a corrupt or future-version file refuses the session
            // rather than defaulting.
            let connectionsPath = Self.connectionsPath(in: resolvedHome)
            let config = try Self.loadRemoteConfig(connectionsPath)

            Self.sweepPrivateStores(in: resolvedHome)

            // DuckDB takes an exclusive lock on the database file, so only one engine can own the
            // shared staged-data store — usually right, it is one user's cache. Browser mode (the
            // reason a second engine used to show up routinely) is gone, but `open -n` can still
            // start a second instance, and that must not turn into an opaque lock error at launch:
            // fall back to a private, per-PID store this instance deletes on exit
            // (`dropPrivateStore`). Cross-process only: the in-process case never reaches here,
            // because the claim above already refused it.
            let sharedPath = (resolvedHome as NSString).appendingPathComponent("stage.duckdb")
            var path = sharedPath
            var shared = true
            let db: Database
            do {
                db = try Database(path: sharedPath)
            } catch let error as DuckDBError where error.message.lowercased().contains("lock") {
                let pid = ProcessInfo.processInfo.processIdentifier
                path = (resolvedHome as NSString).appendingPathComponent("stage-\(pid).duckdb")
                shared = false
                do {
                    db = try Database(path: path)
                } catch let error as DuckDBError {
                    throw SessionError(error.firstLine)
                }
                FileHandle.standardError.write(Data((
                    "sift: another Sift engine holds \(sharedPath), so this one is using a private "
                        + "store at \(path) (staged data will not persist)\n"
                ).utf8))
            } catch let error as DuckDBError {
                // Anything that is NOT the lock — a store that is a directory, a corrupt file, a
                // permission refusal. This is the very first thing the CLI and the app call, and
                // the app's `presentFatal` puts `localizedDescription` straight into an alert body.
                throw SessionError(error.firstLine)
            }

            self.siftHome = resolvedHome
            self.dbPath = path
            self.sharedStore = shared
            self.database = db
            self.connectionsPath = connectionsPath
            self.remoteConfig = config
            self.allowRemoteAtLaunch = config.allowRemote
            self.keychainService = keychainService

            db.harden(allowRemote: config.allowRemote)
            db.loadExtensions(sessionExtensions + remoteExtensions(for: config))

            let con: Connection
            do {
                con = try db.connect()
                try con.execute(catalogDDL)
            } catch let error as DuckDBError {
                throw SessionError(error.firstLine)
            }
            // Before anything reads the catalog: a store written by an older build has a
            // differently keyed catalog holding tokens this build cannot interpret. See
            // `migrateCatalog`.
            Self.migrateCatalog(con)
            // Python's `self.purge_staged(reason="startup")`. Nothing is open yet, so the "never
            // yank a table out from under an open tab" rule is trivially satisfied — this is where
            // a copy that aged out, blew the budget, or no longer matches its source gets
            // collected. `try?`: a store that cannot be purged must not stop the engine starting.
            _ = try? Self.purgeStagedTables(con, open: [], tables: nil, all: false)

            // Credentials last, and only in the permissive posture. A secret on a strict engine is
            // inert — every network filesystem is denied, so nothing could resolve it — and issuing
            // one would mean reading the Keychain (a prompt, on a locked one) on behalf of a session
            // the user has told to stay local. Best effort per connection: `issueSecrets` RECORDS
            // failures rather than throwing, so a deleted Keychain item costs one row in the
            // Connections screen and not the whole app.
            if config.allowRemote {
                self.secretIssues = Self.issueSecrets(con, config: config, service: keychainService)
            }
            self.pagingConnection = con
        } catch {
            Self.openHomes.release(resolvedHome, token: token)
            throw error
        }
    }

    /// The other half of `init`'s claim. Runs whether or not `shutdown()` was called, and is a
    /// no-op if it was — `release` compares the token, so a session that already handed its home
    /// over cannot take it back off whoever holds it now.
    deinit { Self.openHomes.release(siftHome, token: claimToken) }

    // MARK: - setup helpers

    /// `SIFT_HOME`, matching Python's `os.environ.get("SIFT_HOME", os.path.expanduser("~/.sift"))`
    /// — `home` (a caller-supplied override, used by tests to avoid touching a real `~/.sift`)
    /// takes precedence over the environment variable, which takes precedence over the default.
    static func resolveHome(_ home: String?) -> String {
        home ?? ProcessInfo.processInfo.environment["SIFT_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".sift")
    }

    /// `~/.sift` created and enforced at `0700`, even if it already existed — §11 frozen contract:
    /// staged data is a copy of someone's real data sitting on a laptop. `createDirectory`'s own
    /// `attributes` are subject to umask and are not retroactively applied to a directory that
    /// already existed, so the explicit `setAttributes` below runs unconditionally afterward.
    static func ensureHomeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Delete private stores left behind by engines that are no longer running. `kill(pid, 0)`
    /// sends no signal; it only asks whether `pid` exists, which is how a dead owner is told from
    /// a live one (`ESRCH` vs success/`EPERM`).
    static func sweepPrivateStores(in home: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for name in names {
            guard let pid = privateStorePID(in: name), pid != myPID else { continue }
            if kill(pid, 0) == 0 { continue }   // still alive: leave it alone
            if errno == ESRCH {
                try? FileManager.default.removeItem(atPath: (home as NSString).appendingPathComponent(name))
            }
            // EPERM: alive but owned by someone else — leave it alone, same as Python.
        }
    }

    /// Matches `stage-(\d+)\.duckdb(\.wal)?` as a full-string match (Python's `re.fullmatch`).
    private static func privateStorePID(in filename: String) -> Int32? {
        guard filename.hasPrefix("stage-") else { return nil }
        var rest = filename.dropFirst("stage-".count)
        if rest.hasSuffix(".duckdb.wal") {
            rest = rest.dropLast(".duckdb.wal".count)
        } else if rest.hasSuffix(".duckdb") {
            rest = rest.dropLast(".duckdb".count)
        } else {
            return nil
        }
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int32(rest)
    }

    // MARK: - engine / catalog snapshot

    /// DuckDB version, `SIFT_HOME`, which extensions loaded, staged bytes, and whether the store
    /// is shared. `nonisolated`: every value it reads (`database.loadedExtensions`, `siftHome`,
    /// `sharedStore`, `dbPath`) is itself immutable/nonisolated, so this needs no actor hop.
    public nonisolated func engineInfo() -> EngineInfo {
        EngineInfo(
            duckdbVersion: String(cString: duckdb_library_version()),
            siftHome: siftHome,
            extensions: database.loadedExtensions,
            stagedBytes: dbBytes(),
            sharedStore: sharedStore,
            dbPath: dbPath
        )
    }

    /// 🔴 **LANDMINE, sorted rather than `Array(tables.values)`.** This list IS the tab bar's
    /// order, the sources list's order, and the default selection: `web/index.html` renders it
    /// into the tabs (:945) and the sources list (:974), and picks `tables[0]` (:526, :993).
    /// Python iterates an insertion-ordered dict (`session.py:1187-1189`), so that order is the
    /// order the user opened the files in, every launch.
    ///
    /// A Swift `Dictionary` has no iteration order at all. MEASURED across three processes opening
    /// the same eight files in the same order: `delta_x bravo golf alpha echo…`, then
    /// `foxtrot alpha charlie delta_x…`, then `bravo golf foxtrot echo…` — never open order, and
    /// different every launch. This is the same silent order loss `joinCandidates` (Joins.swift)
    /// and `exportFormats` (Export.swift) already carry LANDMINE comments about; this was the call
    /// site nobody checked.
    ///
    /// `openedAt` is exactly the right key and it already existed: monotonic, never reused, and
    /// stamped by both writers of the catalog (`openPath` and `merge`). A closed-and-reopened
    /// table therefore sorts to the END, which is where the user just put it.
    public func state() -> SessionState {
        SessionState(tables: tables.values.sorted { $0.openedAt < $1.openedAt }, engine: engineInfo())
    }

    /// Not `private`: Export.swift reports the bytes it just wrote with this, rather than a
    /// second copy of the same `attributesOfItem` dance.
    nonisolated func fileSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int
        else { return 0 }
        return size
    }

    /// Real bytes on disk (the store file plus its WAL), not a sum of per-table estimates — the
    /// number that answers "what is this tool holding on to", i.e. the file the user could delete.
    ///
    /// Not `private`: Staging.swift measures a staged copy's cost as this number's growth across
    /// the CTAS, and reads `dbPath` — the store this session actually opened, which is the
    /// per-PID fallback whenever the shared one was locked — rather than re-deriving the path.
    nonisolated func dbBytes() -> Int {
        fileSize(dbPath) + fileSize(dbPath + ".wal")
    }

    /// The byte count a staging decision is about — `SourceKey.size` for a local source, the CACHE
    /// FILE's real size for a downloaded remote one.
    ///
    /// 🔴 The substitution is not cosmetic. For a remote source `key.size` is the server's
    /// `Content-Length`, and that is the wrong number twice over: it is **0** when the server sent
    /// no length at all (`buildRemoteSource`'s documented fallback), which reads as "only 0 B —
    /// re-reading it is faster than copying it" and silently disables staging for the whole source;
    /// and for a `.csv.gz` it is the COMPRESSED length, so a 30 MB download that expands to 900 MB
    /// of text is judged as 30. What `shouldStage` is actually asking is "how much text does DuckDB
    /// have to re-parse on every page", and once the object is on disk the file itself answers that
    /// exactly.
    ///
    /// An in-place remote parquet has no cache file and keeps `key.size` — `neverStage` refuses it
    /// whatever the number says, so there is nothing here for it to get wrong.
    ///
    /// Not `private`: `stageNow` re-runs the same decision at the moment the copy would start
    /// (Python's ordering too), and it has to ask the same question with the same number or the two
    /// disagree about a source the banner has already offered to stage.
    nonisolated func stagingSizeBytes(_ spec: SourceSpec) -> Int {
        guard let cache = spec.remote?.cachePath else { return spec.key.size }
        return fileSize(cache)
    }

    /// Where this source's bytes came from, for `shouldStage`'s wording. Shared by `runAfterOpen`
    /// and `stageNow` for the reason above: one question, one answer.
    nonisolated func transport(of spec: SourceSpec) -> Transport {
        spec.remote == nil ? .local : .remote
    }

    // MARK: - relations

    public func table(_ name: String) throws -> Table {
        guard var t = tables[name] else {
            throw SessionError("No open table named '\(name)'.")
        }
        t.lastUsed = Date()
        tables[name] = t
        return t
    }

    func tlock(_ name: String) -> NSLock {
        if let existing = tableLocks[name] { return existing }
        let lock = NSLock()
        tableLocks[name] = lock
        return lock
    }

    /// Test/debug support: replace an open table's query spec directly, bypassing the validation
    /// and cache-reset bookkeeping a later task's real `set_spec` will add (the spec comes from a
    /// trusted caller here, never a user-typed column name). Exists because Task 4's required
    /// tests — sorted-page stability, filtered `visibleRows` — need a way to put an open table
    /// into a filtered/sorted state, and `set_spec` itself is not ported until a later task.
    func replaceQuerySpec(_ name: String, with qspec: QuerySpec) {
        guard var t = tables[name] else { return }
        t.qspec = qspec
        t.filteredCount = nil
        tables[name] = t
    }

    /// Test support: overwrite an open table's cached filtered count directly, without touching
    /// its query spec — lets a test prove `page()` reads the cache instead of recomputing it, by
    /// planting a value `page()` could not possibly have computed itself.
    func setFilteredCountForTest(_ name: String, _ value: Int?) {
        guard var t = tables[name] else { return }
        t.filteredCount = value
        tables[name] = t
    }

    /// Test support: overwrite an open table's cached uncastable-scan result directly, bypassing
    /// `detectBadRows`'s real all-varchar scan — lets SessionQueriesTests prove `computeProfile`
    /// reads this cache instead of re-running that scan, by planting a value the real scan could
    /// not possibly have produced (the same sentinel trick as `setFilteredCountForTest` above,
    /// applied to Task 5's read side).
    func setUncastableForTest(_ name: String, _ value: [String: Int]) {
        guard var t = tables[name] else { return }
        t.uncastable = value
        tables[name] = t
    }

    /// Test support: overwrite an open table's cached profile directly. Lets a test drive
    /// `distinct` down its approximate/clamp branch without a genuinely 100,000-plus-distinct
    /// fixture — plant a `ColumnProfile` whose `approxDistinct` already clears
    /// `wantsExactDistinct`'s threshold, while the real `distinctStatsSQL` query underneath still
    /// runs against the real (small) table and can still genuinely overshoot.
    func setProfileForTest(_ name: String, _ profile: [ColumnProfile]) {
        guard var t = tables[name] else { return }
        t.profile = profile
        tables[name] = t
    }

    /// Test support: a hook every profile job awaits before it does any work. `nil` in production,
    /// where `await barrier?()` on a `nil` optional is not even a suspension.
    ///
    /// **This is the seam that turns "a profile is still in flight" from a race into a fact.** The
    /// guards on `applyProfile` can only be tested by delivering a result while a real job is
    /// registered, and the tests that do so used to get there by being faster than the job: kick a
    /// profile, poll until it registers, then close and reopen before it finishes. That is not a
    /// property of the code, it is a property of the machine. The job runs on DuckDB's own threads
    /// while the close-and-reopen queues on the cooperative pool, so a 70x margin measured on a
    /// developer Mac inverted completely on a CI runner — 6 failures in 6, against 1 in 8 locally.
    /// Holding the job here instead makes the window the test's to open, and removes the machine
    /// from the question. Same reasoning as `setStageDwellForTest`: a test that waits on a real
    /// clock to prove a timer is a flake generator, not a test.
    ///
    /// Captured by `profileJob(for:)` per job, alongside `spec`/`rel`, so a barrier installed after
    /// a job started does not reach back and hold it — and a gate the test has already opened lets
    /// every later job through, including the ones `computeProfile`'s own retry starts.
    var profileBarrierForTest: (@Sendable () async -> Void)?
    func setProfileBarrierForTest(_ hook: (@Sendable () async -> Void)?) {
        profileBarrierForTest = hook
    }

    /// Test support: override whether `openPath` believes the `delta` extension loaded. `nil`
    /// (the default) means "ask the database", which is what production always does — this exists
    /// only so DeltaTests can reach `openPath`'s refusal, which on every machine this code runs on
    /// is otherwise unreachable because `delta` always loads. See the refusal itself for why a
    /// branch that prevents resurrecting deleted rows must not be pinned by luck.
    var deltaLoadedForTest: Bool?
    func setDeltaLoadedForTest(_ loaded: Bool?) { deltaLoadedForTest = loaded }

    /// Test support: swap an open table's `SourceSpec` — the size, format and sheet the cost
    /// policies read — without touching the relation underneath it. The only way to point a test
    /// at a 30 GB source without writing 30 GB: `profileIfCheap`'s gate reads `spec.key.size` and
    /// `spec.fmt`, so a real 12 KB CSV wearing a 30 GB spec exercises the refusal exactly, while
    /// still being a table the profile COULD be computed for if the gate were deleted — which is
    /// what makes the deletion visible. Same internal-seam trick as `setFilteredCountForTest`.
    func setSourceSpecForTest(_ name: String, _ spec: SourceSpec) {
        guard var t = tables[name] else { return }
        t.spec = spec
        tables[name] = t
    }

    /// Test support: shorten (or lengthen) the staging dwell. The same internal-seam trick as
    /// `setFilteredCountForTest`/`setProfileForTest` above, applied to a clock: a test that
    /// really slept `stageDwellSeconds` would add three seconds to a parallel suite to prove a
    /// timer it could prove in 200 ms, and a test that waited on the real deadline would be a
    /// flake the moment the machine is busy. Both directions matter — one test shortens it to
    /// watch the dwell fire, another lengthens it to prove an aggregate short-circuits it.
    func setStageDwellForTest(_ seconds: Double) { stageDwellSeconds = seconds }

    /// Test support: put a table into the state that exists for a few seconds inside every real
    /// staging job — the copy has been renamed over the name, so the store holds a TABLE, but the
    /// job has not published it yet, so the flags still say "not staged, job in flight". That
    /// window is only reachable by racing a live CTAS, which is not reproducible at unit speed;
    /// this reconstructs it exactly, which is how `closeTable` proves it no longer throws in it.
    func setMidSwapStateForTest(_ name: String) {
        guard var t = tables[name] else { return }
        t.staged = false
        t.staging = StagingProgress(jobID: "stage-test", state: "running", estSeconds: 0)
        tables[name] = t
    }

    /// Test support: put a table into SQL mode with arbitrary stored text, bypassing `runSQL`'s
    /// SELECT-only gate. The seam that makes Export.swift's re-check testable at all: `runSQL` is
    /// currently the only writer of `sqlText` and it guards on the way in, so no production path
    /// can currently store a non-SELECT — which is precisely why `export` re-checks rather than
    /// trusting the flag, and why proving it re-checks needs a way in that `runSQL` will not give.
    /// Same internal-seam trick as `setFilteredCountForTest`/`setProfileForTest` above.
    func setSQLTextForTest(_ name: String, _ text: String?) {
        guard var t = tables[name] else { return }
        t.sqlMode = text != nil
        t.sqlText = text
        tables[name] = t
    }

    /// Test support: plant an in-flight staging progress so a stale-generation callback has
    /// something to (wrongly) clear. See `finishStage`'s guard.
    func setStagingForTest(_ name: String, _ progress: StagingProgress?) {
        guard var t = tables[name] else { return }
        t.staging = progress
        tables[name] = t
    }

    /// Safe relation SQL for this table — a quoted name, or the user's wrapped query.
    public nonisolated func relation(_ t: Table) -> String {
        if t.sqlMode, let text = t.sqlText {
            return "(\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n) AS _q"
        }
        return q(t.name)
    }

    /// The all-varchar file expression, or `nil` when the format cannot mis-cast — parquet and
    /// Delta carry real types, so there is nothing to sniff wrong and no reject count to compute.
    public nonisolated func rawRelation(_ t: Table) -> String? {
        rawRelationExpr(t.spec)
    }

    // MARK: - open

    /// `nullPadding` and `skipPreamble` are the two escape hatches from a sniff that went wrong,
    /// and each exists because a note tells the user to reach for it: `nullPadding` recovers the
    /// columns of a file whose rows have inconsistent field counts, `skipPreamble: false` recovers
    /// the rows of a file whose preamble ate it.
    ///
    /// They are ALTERNATIVES, not combinable, and asking for both silently gets neither: pinning
    /// `skip` is exactly what defeats `null_padding` (measured — an explicit `skip=0` looks like a
    /// no-op, because it is the sniffer's own answer handed back, and restores the collapse). The
    /// combination throws rather than quietly doing half of what was asked.
    public func openPath(
        _ path: String, name: String? = nil, sheet: String? = nil,
        nullPadding: Bool = false, skipPreamble: Bool = true
    ) async throws -> Table {
        guard !(nullPadding && !skipPreamble) else {
            throw SessionError(
                "Null padding and skipping no preamble cannot be combined — pinning the skip is "
                    + "what defeats null padding. Pick one."
            )
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // 🔴 BEFORE the `fileExists` guard, and the order is the whole branch. A URL is not a path:
        // `realPath` leaves it alone, `stat` fails, and every remote source in the product would
        // come back as `No such file or folder: https://…` — Sift refusing, in its own voice, to
        // open something it can open. `classifyRemote` returning `nil` means "not a URL Sift
        // reaches", which is the local flow below, untouched.
        if let remote = classifyRemote(trimmed) {
            return try await openRemote(
                remote, name: name, sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
            )
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = realPath(expanded)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SessionError("No such file or folder: \(resolved)")
        }

        // 🔴 The single most consequential refusal in the product, and until 2026-08-11 it was
        // held up by an environmental accident: `delta` always loads on every machine this runs
        // on, so the branch was unreachable and deleting it left 461 tests green. What it guards
        // is reading a Delta table as a raw parquet glob, which RESURRECTS DELETED ROWS — the
        // worst thing a tool whose entire premise is not lying about data could do. It deserves a
        // seam, not luck: `deltaLoadedForTest` is that seam and its only purpose.
        if isDeltaDir(resolved), !(deltaLoadedForTest ?? (database.loadedExtensions["delta"] == .loaded)) {
            throw SessionError(
                "\((resolved as NSString).lastPathComponent) is a Delta table, but the DuckDB "
                    + "delta extension is not available, so Sift cannot read it correctly. Reading "
                    + "the parquet files directly would resurrect deleted rows — refusing rather "
                    + "than showing you wrong numbers. Fix: run INSTALL delta once with network "
                    + "access."
            )
        }

        let spec: SourceSpec
        do {
            let con = try database.connect()
            spec = try buildSource(
                con, path: resolved, sheet: sheet,
                nullPadding: nullPadding, skipPreamble: skipPreamble
            )
        } catch let error as UnsupportedSource {
            throw SessionError(error.message)
        } catch let error as LegacyXls {
            throw SessionError(error.message)
        } catch let error as DuckDBError {
            // 🔴 THE most common user error in the product, and it shipped as a Foundation dump.
            // A corrupt/empty parquet, a truncated JSON, a half-written NDJSON — DuckDB says
            // `Invalid Input Error: No magic bytes found at end of file '…'` and that sentence is
            // the entire answer. Every other public method here has had this wrap since it was
            // written; this one, the one a user hits first, did not.
            throw SessionError(error.firstLine)
        }

        return try finishOpen(
            spec: spec, requestedName: name,
            displayName: (resolved as NSString).lastPathComponent
        )
    }

    /// The half of an open both branches share: derive a free table name, put the source into the
    /// catalog under a fresh generation, reuse a staged copy if one matches, and kick the
    /// background pipeline.
    ///
    /// Factored out when the remote branch arrived rather than copied into it, and that is not
    /// tidiness: every line below is a rule with a measurement or a review behind it — the sorted
    /// `state()` order that `openedAt` carries, `adoptStagedCopy`'s `CREATE OR REPLACE VIEW`-over-a-
    /// TABLE catalog error, the `openedAt` snapshot the whole background pipeline is checked
    /// against. A second copy is a second place for one of them to be dropped, and the copy that
    /// drops one still looks right.
    ///
    /// `displayName` is the source's own name — the last path component locally,
    /// `RemoteURL.displayName` for a URL. `extraNotes` is what the branch learned on the way in
    /// that the spec cannot say for itself; today that is exactly one thing, the SAS'd parquet that
    /// had to be downloaded.
    private func finishOpen(
        spec: SourceSpec, requestedName: String?, displayName: String, extraNotes: [String] = []
    ) throws -> Table {
        let taken = Set(tables.keys)
        let base: String
        if let requestedName, !requestedName.isEmpty {
            base = requestedName
        } else {
            let raw = spec.fmt == .xlsx ? (spec.sheet ?? displayName) : displayName
            base = try sanitizeTableName(raw)
        }
        let tname = taken.contains(base) ? try sanitizeTableName(base, taken: taken) : base

        nextOpenGeneration += 1
        var t = Table(name: tname, spec: spec, qspec: QuerySpec(relation: tname), openedAt: nextOpenGeneration)
        if let rowCount = spec.rowCount { t.rowCount = rowCount }
        t.notes.append(contentsOf: extraNotes)

        if spec.fmt == .xlsx, !spec.sheets.isEmpty {
            t.notes.append(
                "Sheet \u{201C}\(spec.sheet ?? "")\u{201D} of \(spec.sheets.count)"
                    + (spec.sheets.count > 1 ? " — use the sheet picker to open others" : "")
            )
        }
        if spec.fmt == .globParquet || spec.fmt == .globCsv {
            t.notes.append("Folder read as one table (union by name, with filename provenance)")
        }
        if spec.fmt == .delta {
            // Python renders a missing delta_version via its f-string as the literal "None";
            // "unknown" says the same thing without leaking a Python-ism into a native app, for a
            // branch that's effectively unreachable (isDeltaDir already confirmed a real log).
            let version = spec.deltaVersion.map(String.init) ?? "unknown"
            t.notes.append("Delta table at version \(version) — tombstones honored")
        }

        // A staged copy of this exact file, left in the store by an earlier open, is reused rather
        // than rebuilt — and a copy of a file that has since changed is dropped. Both matter for
        // correctness, not just speed: a staged copy is a real table in a persistent store, and
        // `CREATE OR REPLACE VIEW` over one is a hard `Catalog Error`. See `adoptStagedCopy`.
        do {
            let viewCon = try database.connect()
            if let adoptedRows = adoptStagedCopy(viewCon, name: tname, spec: spec) {
                t.staged = true
                t.rowCount = adoptedRows
            } else {
                try viewCon.execute(createViewSQL(name: tname, spec: spec))
            }
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }

        tables[tname] = t

        let snapshot = t
        Task.detached { [self] in
            await runAfterOpen(
                name: tname, spec: snapshot.spec, initialRowCount: snapshot.rowCount,
                openedAt: snapshot.openedAt
            )
        }

        return t
    }

    // MARK: - open: the remote branch

    /// Open a URL. Four gates that never touch the network, then one detached build that does.
    ///
    /// The gates are in this order because each one's sentence is only correct once the ones above
    /// it have passed: there is no point naming an extension to a session that may not reach the
    /// network at all, and no point naming a missing Azure connection to a session whose azure
    /// extension is not installed. Each of them is a local decision from state this actor already
    /// holds, so the whole prefix costs nothing and refuses in microseconds — the same
    /// "refuse before the wire" rule `remoteFormat`'s glob and Delta refusals follow one layer down.
    func openRemote(
        _ url: RemoteURL, name: String?, sheet: String?, nullPadding: Bool, skipPreamble: Bool
    ) async throws -> Table {
        try checkRemotePosture(url)
        try checkRemoteExtension(url)
        try checkRemoteConnection(url)

        let opened = try await remoteOpen(
            url, sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
        )
        return try finishOpen(
            spec: opened.spec, requestedName: name, displayName: url.displayName,
            extraNotes: opened.notes
        )
    }

    /// May this session reach the network at all? MEASURED (remote facts §2, and `Connections.swift`
    /// is built on it): the posture is frozen when the `Database` opens and can never be narrowed or
    /// widened inside it, so this is `allowRemoteAtLaunch` and never `connections().allowRemote`.
    ///
    /// The two sentences are different because the FIXES are different, which is the whole reason
    /// `ConnectionOutcome` exists as a return value in T6: a user who has already flipped the switch
    /// has nothing left to do in Connections and must be told to relaunch, not sent back to a screen
    /// that already says yes. Telling them to "turn it on" there is how a correct setting gets
    /// toggled twice by someone hunting for the thing they missed.
    private func checkRemotePosture(_ url: RemoteURL) throws {
        guard !allowRemoteAtLaunch else { return }
        guard !remoteConfig.allowRemote else {
            throw SessionError(
                "Remote sources are switched on in Data \u{2192} Connections…, but this Sift "
                    + "session started with them off \u{2014} relaunch Sift to open "
                    + "\(url.displayName)."
            )
        }
        throw SessionError(
            "Sift is not allowed to reach the network in this session, so it cannot open "
                + "\(url.displayName) \u{2014} switch remote sources on in Data \u{2192} "
                + "Connections…, then relaunch Sift."
        )
    }

    /// Is the DuckDB extension this scheme reads through actually here?
    ///
    /// Asked through `installExtension`, which is idempotent and free when the extension is already
    /// loaded (the common call — a permissive session asks for `httpfs` at launch). Going through it
    /// rather than reading `loadedExtensions` directly is what makes the tri-state exhaustive: an
    /// `az://` URL on a permissive session with no saved Azure connection has no `azure` entry at
    /// all, because `remoteExtensions(for:)` only asks for it when a connection needs it, and
    /// "absent" is not a state with a sentence — `installExtension` turns it into `.loaded` (this is
    /// a session the user has authorised to reach the network, so a first INSTALL here is exactly
    /// what they asked for) or into one of the two below.
    ///
    /// `.unavailable` carries DuckDB's own first line, which is what separates "there is no such
    /// extension" from "this machine has no network" — two different problems and two different
    /// fixes, which is why T1 made the state carry the reason at all.
    private func checkRemoteExtension(_ url: RemoteURL) throws {
        let name = remoteExtensionName(url.scheme)
        switch installExtension(name) {
        case .loaded:
            return
        case .unavailable(let why):
            throw SessionError(
                "Sift reads \(url.scheme.rawValue):// sources through the DuckDB \(name) extension, "
                    + "and it is not available here: \(why). Install it from Data \u{2192} "
                    + "Connections…, once, on a machine with network access."
            )
        case .rejectedName:
            throw SessionError(
                "Sift asked DuckDB for an extension name it cannot use (\(name)) \u{2014} this is a "
                    + "bug in Sift, not something you can fix."
            )
        }
    }

    /// Does a saved Azure connection cover this URL? Azure only.
    ///
    /// **Nothing is looked up FROM the match** — the secret was issued at launch and DuckDB resolves
    /// it by scope, so this changes no SQL and passes nothing on. It exists purely so an Azure URL
    /// with no credential behind it gets Sift's sentence instead of DuckDB's
    /// `Invalid Input Error: No valid Azure credentials found!` (MEASURED — spike §1, the error every
    /// unauthenticated `az://` read produces), which names nothing the user can act on.
    ///
    /// The account is the host's first label, and it is only really there for `abfss://`:
    /// `abfss://c@acct.dfs.core.windows.net/f` carries the account (the `c@` is already stripped by
    /// `classifyRemote`), while `az://container/blob` names only the container and leaves the account
    /// to the secret. That asymmetry is why a lone saved azure connection is accepted whatever the
    /// host says — with one connection there is nothing to choose between, and refusing would make
    /// `az://` unopenable for the ordinary single-account user.
    ///
    /// s3 needs nothing: an anonymous read of a public bucket is a real and supported thing
    /// (`createSecretSQL` returns `nil` for a half-empty s3 spec for the same reason). http(s) needs
    /// nothing either — a pasted URL is the most common remote source there is.
    ///
    /// Internal rather than `private` so its sentences can be tested without an Azure account or an
    /// installed `azure` extension: reaching this through `openRemote` means passing
    /// `checkRemoteExtension` first, which for an `az://` URL is an INSTALL, and a sentence about a
    /// missing connection should not need a network to prove.
    func checkRemoteConnection(_ url: RemoteURL) throws {
        guard url.scheme == .az || url.scheme == .abfss else { return }
        let azure = remoteConfig.connections.filter { $0.kind == .azure }
        let account = String(url.host.prefix { $0 != "." })
        if azure.contains(where: {
            $0.accountName?.caseInsensitiveCompare(account) == .orderedSame
        }) { return }
        if azure.count == 1 { return }

        guard !azure.isEmpty else {
            throw SessionError(
                "\(url.displayName) is an Azure source and no Azure connection is saved, so Sift "
                    + "has no credential to read it with \u{2014} add one in Data \u{2192} "
                    + "Connections…."
            )
        }
        throw SessionError(
            "\(url.displayName) is an Azure source and none of the \(azure.count) saved "
                + "connections is for \(url.host) \u{2014} add the right one in Data \u{2192} "
                + "Connections…, or use the abfss:// form, which names the storage account."
        )
    }

    /// The detached half: HEAD, format, download, spec. Off the actor, with its own `Connection`.
    ///
    /// 🔴 **Detached because a hung endpoint must suspend the OPEN, never the actor.** Everything
    /// inside is a network round trip in the bad case, and two of the three are synchronous DuckDB
    /// calls that no `Task.cancel` can reach. Run on the actor, one unreachable host would block
    /// paging on every other open table, `state()`, and every `apply*` callback from every other
    /// table's background pipeline — the `page` cliff this file's header documents, except caused by
    /// somebody else's server rather than by a big sort.
    ///
    /// The errors are unwrapped here rather than inside, so the three refusal types RemoteProbe
    /// raises (`UnsupportedSource` for a glob, a remote Delta table, an over-cap object;
    /// `LegacyXls`; `DuckDBError` for anything the engine said) reach the user as the one clean
    /// sentence they already are — the identical wrap `openPath`'s local half puts around
    /// `buildSource`.
    private func remoteOpen(
        _ url: RemoteURL, sheet: String?, nullPadding: Bool, skipPreamble: Bool
    ) async throws -> RemoteOpen {
        let database = self.database
        let home = self.siftHome
        let fetchedAtNs = fetchClockNs()
        do {
            return try await Task.detached {
                try await buildRemoteOpen(
                    database: database, home: home, url: url, fetchedAtNs: fetchedAtNs,
                    sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
                )
            }.value
        } catch let error as UnsupportedSource {
            throw SessionError(error.message)
        } catch let error as LegacyXls {
            throw SessionError(error.message)
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - post-open background work

    /// Background work: exact count, bad-row detection, staging decision — in that order. Runs
    /// off the actor with its own `Connection` so a slow scan on one table's file never blocks
    /// paging on another table or a second `openPath` in flight; each stage calls back with a
    /// small, fast, actor-isolated "apply" method rather than mutating shared state directly.
    ///
    /// **`compute_profile`'s eager trigger is deliberately NOT here, and its cost gate now is —
    /// see `SessionQueries.profileIfCheap`.** Python calls `self.compute_profile(name)` at this
    /// point in `_after_open`, behind `size <= PROFILE_EAGER_MAX_BYTES or staged or columnar`
    /// (session.py:454). The port carried neither, which left the kick to whoever called next and
    /// the COST POLICY nowhere at all — so the UI plan's speculative kick had no gate to consult
    /// and would have `SUMMARIZE`d a 30 GB CSV that Python skips.
    ///
    /// The gate is now `SiftCore.shouldProfileEagerly`, sitting beside `shouldStage` where both
    /// consumers read it, and `profileIfCheap` is the gated entry point a speculative caller uses.
    /// The kick stays with the caller because the engine has two consumers and Python had one:
    /// `sift <path>` never renders a profile, so a kick here would make every CLI open pay for a
    /// `SUMMARIZE` it discards. Unlike the exact count and the bad-row scan below, an eager profile
    /// is not a correctness step — it is latency work for a UI that is about to ask.
    ///
    /// Background staging (`_maybe_stage_after_dwell`) IS wired, below the staging decision, where
    /// Python has it — that one IS the engine's, because the dwell it enforces is a cost decision
    /// with no caller to make it.
    ///
    /// `openedAt` is the opened table's identity, carried through to every `apply*` call below so
    /// each one can confirm it is still writing to the SAME open table it was launched for. Python
    /// is immune to this by construction — `_after_open` binds `t = self.tables.get(name)` once
    /// and mutates that live object directly, so once `close_table` pops it from the dict the
    /// object is simply garbage, and any Python-cursor callback still touching it lands nowhere.
    /// This port instead re-looks-up `tables[name]` on every `apply*` call (`Table` is a struct
    /// there is no live reference to hold onto) — which means a background scan for a CLOSED table
    /// would silently write onto a DIFFERENT, later-opened table of the same name, if nothing
    /// stopped it. `openedAt` is that stop: `Table.init` sets it once, fresh, per open, so a stale
    /// callback's `openedAt` can never match a reopened table's.
    nonisolated private func runAfterOpen(
        name: String, spec: SourceSpec, initialRowCount: Int?, openedAt: Int
    ) async {
        guard let connection = try? database.connect() else { return }

        // 🔴 **The remote adaptation is that there is none, and that is the design working rather
        // than a gap.** A remote text source has already been downloaded once (`buildRemoteOpen`),
        // so `spec.target` is a local cache file and both steps below are the ordinary LOCAL
        // pipeline reading an ordinary local file: the exact count is a `count(*)` over the cache,
        // the bad-row scan is the same all-varchar pass, and neither touches the network. An
        // in-place remote parquet skips both for the same reasons a local parquet does — its
        // `rowCount` came free from the footer, so the count never runs, and `rawRelationExpr` is
        // `nil` for a format that carries real types, so the scan never runs either. The whole point
        // of downloading once (MEASURED — spike §7: a bare `read_csv(url)` fetches 200 % of the
        // object) is that nothing after the download has to know it was ever remote.
        var rowCount = initialRowCount
        if rowCount == nil {
            await applyCounting(name, true, openedAt: openedAt)
            rowCount = try? exactCount(connection, spec: spec)
            await applyCount(name, rowCount, openedAt: openedAt)
        }

        if let raw = rawRelationExpr(spec), let scan = try? detectBadRows(connection, spec: spec, raw: raw) {
            await applyBadRows(name, scan, openedAt: openedAt)
        }

        let free = freeDiskBytes(at: siftHome)
        let decision = shouldStage(
            fmt: spec.fmt, sizeBytes: stagingSizeBytes(spec), freeBytes: free,
            transport: transport(of: spec)
        )
        await applyStageDecision(name, decision, openedAt: openedAt)

        // `needsConfirm` (a source over 20 GB) is the user's call, not a background job's.
        if decision.stage, !decision.needsConfirm {
            await maybeStageAfterDwell(name, openedAt: openedAt)
        }
    }

    /// `guard ... t.openedAt == openedAt` below is the fix for a real bug caught in review: a
    /// closed-and-reopened table sharing the OLD table's name would otherwise silently inherit a
    /// still-in-flight background result meant for the table that used to have that name (a huge
    /// file's row count landing on a freshly-opened tiny one). Not `private`: exercised directly
    /// (with a deliberately stale `openedAt`) by SessionTests' regression test for exactly this.
    func applyCounting(_ name: String, _ counting: Bool, openedAt: Int) {
        guard var t = tables[name], t.openedAt == openedAt else { return }
        t.counting = counting
        tables[name] = t
    }

    func applyCount(_ name: String, _ rowCount: Int?, openedAt: Int) {
        guard var t = tables[name], t.openedAt == openedAt else { return }
        if let rowCount { t.rowCount = rowCount }
        t.counting = false
        tables[name] = t
    }

    func applyBadRows(_ name: String, _ scan: BadRowScan, openedAt: Int) {
        guard var t = tables[name], t.openedAt == openedAt else { return }
        t.uncastable = scan.uncastable
        t.badCells = scan.badCells
        t.badRows = scan.badRows
        tables[name] = t
    }

    func applyStageDecision(_ name: String, _ decision: StageDecision, openedAt: Int) {
        guard var t = tables[name], t.openedAt == openedAt else { return }
        t.stageDecision = decision
        tables[name] = t
    }

    // MARK: - paging

    /// **Known responsiveness cliff (review I6), left as-is on purpose.** This entire method runs
    /// synchronously on the actor — it never suspends — so a first sorted page over a large table
    /// (the `sortedRelation` materialization, up to `sortMaterializeMax` rows) blocks every other
    /// actor call for however long that takes: `table`, `state`, a second `openPath`, and every
    /// `apply*` callback from an in-flight `runAfterOpen`. Python ran `page` in a threadpool, where
    /// only the calling request stalled.
    ///
    /// Not fixed here because fact 3 (this file's header) forecloses the obvious fix: detaching
    /// this work would mean using `pagingConnection` from a detached `Task`, and `pagingConnection`
    /// is safe to hold as a single, long-lived, non-`Sendable` `Connection` ONLY because every
    /// caller — `page`, `sortedRelation`, `closeTable` — is guaranteed by the actor's serial
    /// executor to run to completion before the next one starts. A detached caller would break
    /// that guarantee, which is the one thing standing between "shared Connection" and a data race.
    /// Given the choice between reintroducing that risk and leaving this cliff documented, this
    /// keeps the simpler, provably-safe design and accepts the cliff.
    public func page(_ name: String, offset: Int, limit: Int = pageRows) async throws -> TablePage {
        var t = try table(name)
        // Persists whatever `t` ends up mutated to (filteredCount, sortKey) on every exit path —
        // success or a thrown error — matching Python, where `t` IS the dictionary's own object,
        // so those mutations are visible immediately regardless of what happens afterward.
        defer { tables[name] = t }

        let cols = t.cols
        let con = pagingConnection
        do {
            let sql: String
            let params: [SQLValue]
            if t.sqlMode, let text = t.sqlText {
                (sql, params) = wrapUserSQL(text, limit: limit, offset: offset)
            } else {
                // A filtered view has a different row count, and the grid's scroll extent is built
                // from it — so count once per spec change and cache it, not once per page.
                if !t.qspec.filters.isEmpty, t.filteredCount == nil {
                    let (countSql, countParams) = try countSQL(t.qspec, cols: cols, rel: q(t.name))
                    let row = try con.query(countSql, countParams.map(toDBValue)).allRows()[0]
                    t.filteredCount = cellInt(row[0])
                }
                let rel = try sortedRelation(con, &t)
                // `rel` already carries the sort — either it's the plain table (t.qspec.sort was
                // empty, nothing to order) or `sortedRelation` just materialized it in that exact
                // order. Re-appending `ORDER BY` here would re-sort it, and MEASURED (DuckDB
                // 1.5.5, the vendored dylib this target actually links — an earlier CLI-based
                // repro used 1.5.2, re-confirmed here against what ships): re-sorting the same
                // static, tie-bearing table at different LIMIT/OFFSET pairs does NOT reliably
                // reproduce the same tie order every time — 4 rows out of 1000 landed on two pages
                // and 4 others on none. Reading the materialized copy's own physical order via a
                // bare LIMIT/OFFSET (no ORDER BY) does not have that problem — DuckDB's default
                // `preserve_insertion_order` is exactly what `sortedRelation`'s materializing
                // CREATE TABLE relies on (SessionTests pins this at scale, and directly asserts
                // the setting itself, in case it is ever flipped off in `harden()`). Filters stay:
                // they were already baked into the materialized copy, so re-applying the same
                // predicate is redundant but harmless, unlike sort.
                let readSpec = QuerySpec(relation: t.qspec.relation, filters: t.qspec.filters)
                (sql, params) = try pageSQL(readSpec, cols: cols, rel: rel, limit: limit, offset: offset)
            }

            let started = DispatchTime.now()
            let rows = try con.query(sql, params.map(toDBValue))
            let fetched = try rows.allRows()
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

            let columns = rows.columns.map {
                TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
            }
            return TablePage(
                columns: columns, rows: fetched, offset: offset, limit: limit,
                milliseconds: (elapsedMs * 10).rounded() / 10,
                total: TablePage.Total(
                    value: t.visibleRows, exact: t.rowCount != nil,
                    unfiltered: t.gridRows, filtered: !t.qspec.filters.isEmpty
                )
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Materializes a sorted result set once per (name, qspec, staged) combination, then pages off
    /// the copy. Two reasons, both real: a fresh `ORDER BY` per page is a full sort per page, and
    /// ties on a non-unique sort column are ordered arbitrarily, so the same row could appear on
    /// two pages or none.
    ///
    /// `TEMP TABLE`, matching Python — but not for the reason an earlier version of this comment
    /// claimed. That version said Python's `con.cursor()` shares its parent connection's session,
    /// so the materialized copy survives across the cursors `page()` opens. MEASURED, and false:
    /// a `TEMP TABLE` created on one Python cursor is NOT visible on a second cursor OR the parent
    /// connection (`Catalog Error: Table with name ... does not exist` on both) — and end to end,
    /// paging a sorted table a second time against the real `engine/session.py` throws the
    /// identical error today. Python was never a faithful reference for this call to diverge
    /// from; it is currently broken here too, just untested (no `test_session.py` pages a sorted
    /// table more than once). What actually makes `TEMP TABLE` work in THIS file is `page`,
    /// `sortedRelation` and `closeTable` sharing one `pagingConnection` (this file's header, fact
    /// 3) — a `TEMP TABLE` is visible for as long as the connection that created it stays open,
    /// and that connection is now the `Session`'s, not a fresh one per call. Dropped explicitly
    /// below and in `closeTable` on every orderly exit; needs no startup sweep for the unclean
    /// case, unlike a plain table — DuckDB drops a connection's temp tables itself when it closes,
    /// which happens automatically at process exit regardless of how the process ended.
    private func sortedRelation(_ con: Connection, _ t: inout Table) throws -> String {
        guard !t.qspec.sort.isEmpty else {
            if let key = t.sortKey {
                try con.execute("DROP TABLE IF EXISTS \(q(key))")
                t.sortKey = nil
            }
            return q(t.name)
        }

        let key = sortRelationName(for: t)
        if t.sortKey == key { return q(key) }
        if let old = t.sortKey {
            try con.execute("DROP TABLE IF EXISTS \(q(old))")
        }
        let (inner, params) = try pageSQL(t.qspec, cols: t.cols, rel: q(t.name), limit: sortMaterializeMax, offset: 0)
        _ = try con.query("CREATE OR REPLACE TEMP TABLE \(q(key)) AS \(inner)", params.map(toDBValue))
        t.sortKey = key
        return q(key)
    }

    // MARK: - close / shutdown

    /// **Does not cancel an in-flight profile, on purpose (and it is waste, not incorrectness).**
    /// Closing a tab on a wide file leaves its `SUMMARIZE` burning a connection and a thread for a
    /// table nobody can see — seconds of it. Not fixed, because there is no cheap version: the job
    /// is a synchronous `duckdb_query` inside a detached task, so `Task.cancel()` cannot touch it;
    /// stopping it for real means `StageJob`'s interrupt hammer (a real `Thread` re-asserting
    /// `duckdb_interrupt` at ~5 kHz around a non-`Sendable` `Connection`, plus a window that must
    /// be closed on every exit path — review N1's bug) for a job with nothing to publish. Clearing
    /// `profileJobs[name]` here without actually stopping the work would be worse than useless: it
    /// would retire the claim `applyProfile`'s reopen guard exists to be checked against, so the
    /// one thing standing between a stale profile and a reopened table would stop being reachable
    /// — and stop being testable — while the SUMMARIZE kept running anyway.
    public func closeTable(_ name: String) async throws {
        let t = try table(name)
        // Before the `defer` below registers, so a refused close removes nothing: a merge view is
        // built over this table's NAME, and dropping the view underneath one leaves it in the
        // catalog looking healthy and throwing a raw catalog dump on every read. See
        // Joins.swift's `assertNoLiveMerge` for why this refuses rather than cascading.
        try assertNoLiveMerge(on: name)
        defer {
            tables.removeValue(forKey: name)
            // The lock goes with the table. It is vestigial (see `tableLocks`), but a dictionary
            // that only ever grows is a leak whether or not anyone locks what is in it — a session
            // that opens and closes a thousand tabs kept a thousand `NSLock`s alive. Safe here for
            // the same reason the retire is: nothing can be holding it, since `stageNow` refuses a
            // second job and a running job's `swapStaged` has the OBJECT, not the dictionary slot.
            tableLocks.removeValue(forKey: name)
        }

        let con = pagingConnection
        do {
            if let key = t.sortKey {
                try con.execute("DROP TABLE IF EXISTS \(q(key))")
            }
            if t.staged {
                _ = try con.query("UPDATE _sift_sources SET last_used = now() WHERE table_name = ?", [.text(name)])
            } else if t.staging == nil {
                try con.execute("DROP VIEW IF EXISTS \(q(name))")
            }
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
        // `t.staging != nil` falls through both branches on purpose. A staging job turns this name
        // into a real TABLE at the swap, seconds before `applyStaged` sets `staged = true`, and
        // `DROP VIEW` on a table is a hard `Catalog Error` — closing a tab in that window failed
        // with a catalog dump while the `defer` above removed it from `tables` anyway, so the user
        // got an error for an operation that half-happened (review I6). Nothing is leaked by
        // waiting: the job's own `.stale` repair drops whatever it finds under the name.
    }

    /// Hands the home back before anything else: after this call another `Session` may legitimately
    /// open it, and this one's later `deinit` must not take it away again (`release` compares the
    /// token, so it cannot).
    public func shutdown() {
        Self.openHomes.release(siftHome, token: claimToken)
        dropPrivateStore()
    }

    /// Removes a private fallback store's files. `nonisolated` and safe to call redundantly (e.g.
    /// from a future parent-death watcher) — it touches only the immutable `dbPath`/`sharedStore`,
    /// never the actor's mutable catalog, so it never needs to wait for a hop.
    ///
    /// Python explicitly closes its one connection first; there is no equivalent step here because
    /// `DuckDBKit.Database` exposes no public `close()` (Task 4 must not touch
    /// Sources/DuckDBKit/**). ARC drops the handle once every reference to `database` is released,
    /// which for a private store happens at process exit regardless — and the files removed here
    /// were never meant to outlive that anyway ("staged data will not persist").
    public nonisolated func dropPrivateStore() {
        guard !sharedStore else { return }
        for path in [dbPath, dbPath + ".wal"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - snapshots returned to callers

public struct EngineInfo: Sendable {
    public let duckdbVersion: String
    public let siftHome: String
    public let extensions: [String: ExtensionState]
    public let stagedBytes: Int
    public let sharedStore: Bool
    public let dbPath: String
}

public struct SessionState: Sendable {
    public let tables: [Table]
    public let engine: EngineInfo
}

public struct TablePage: Sendable {
    public struct ColumnInfo: Sendable {
        public let name: String
        public let type: String
        public let kind: Kind
    }
    public struct Total: Sendable {
        public let value: Int?
        public let exact: Bool
        public let unfiltered: Int?
        public let filtered: Bool
    }

    public let columns: [ColumnInfo]
    public let rows: [[Cell]]
    public let offset: Int
    public let limit: Int
    public let milliseconds: Double
    public let total: Total
}

// MARK: - free helpers: the remote open (no actor state; runs in a detached task)

/// What a remote open produced: the spec, plus anything the branch learned that the spec has no
/// field for. `Sendable` because it crosses back out of the detached task.
struct RemoteOpen: Sendable {
    let spec: SourceSpec
    let notes: [String]
}

/// Where downloaded remote objects live, under `SIFT_HOME`.
let remoteCacheDirName = "remote-cache"

/// The note a SAS-signed parquet gets, and the shape of the ruling behind it.
///
/// 🔴 A `?sv=…&sig=…` query is a **bearer credential**. `RemoteRef` deliberately carries none
/// (Types.swift states it as a rule), because a `SourceSpec` is rendered into the `CREATE VIEW`
/// text DuckDB writes into the on-disk store and its `key.path` is written into `_sift_sources` —
/// an in-place read would put the signature in both. So a SAS'd parquet is DOWNLOADED, like a text
/// format, and that is the ruling rather than a refusal: refusing would mean the shape most people
/// are handed a private blob in simply does not open, to protect an optimisation. The cost is real
/// and is what this note is for — range reads are the whole reason parquet is normally read in
/// place (MEASURED, spike §7: `count(*)` over 28.6 MB costs 64 KB), and a downloaded copy pays for
/// the object once instead. Plain `https://` parquet and `az://`-through-a-connection parquet still
/// read in place: their credential is a Database-scoped secret, not a string in the URL.
let sasParquetNote =
    "SAS-signed parquet cannot be read in place without persisting the token, so Sift downloaded "
    + "a local copy instead"

/// The connection-needing half of a remote open. Called only from `Session.remoteOpen`'s detached
/// task, and touches no actor state — `database` is `@unchecked Sendable` and immutable, `home` is
/// a string.
///
/// The order is the cheap-and-local-first order every remote path in this codebase uses:
///
///  1. **The format**, from the URL's own extension — which is also where the glob and Delta
///     refusals live, and why this goes FIRST rather than after the HEAD it reads more naturally
///     after. Both refusals are decided from the URL text alone (MEASURED, spike §3 and §4: DuckDB
///     refuses a remote glob at plan time, and `delta_scan` over http dies inside delta-kernel-rs
///     without one request leaving the machine), so putting a HEAD in front of them would send a
///     request on behalf of a source Sift has already decided it will not open — and for the Delta
///     case that refusal is the only thing standing between a URL and tombstoned rows served as
///     live data.
///  2. **The HEAD**, for identity. `nil` for `az`/`s3` by design (no `URLSession` can sign one) and
///     `nil` for every failure — the read below produces the error a user can act on, and a second
///     one from here would only race it.
///  3. **The download decision.** Everything that is not parquet is a text format, and MEASURED
///     (spike §7) reading one in place re-downloads the whole object per statement — so it is
///     downloaded once and the LOCAL pipeline takes it from there. Parquet reads in place, except
///     when a SAS is in the URL (see `sasParquetNote`).
///  4. **The spec**, `buildRemoteSource`, which re-sniffs the cache file from its magic bytes.
///
/// **T7's extension-less-CSV concern dies here, with no new `Fmt` case.** The worry was that a URL
/// with no extension costs three fetches to identify. It does not, in this shape: `remoteFormat`'s
/// DESCRIBE probes go parquet first, which ranges rather than downloads, and anything that falls
/// past it is a text format that step 3 was going to download anyway. The wasted work is the ONE
/// probe download that identified it, and buying a `Fmt` case to save that would mean a second
/// format decision living outside `remoteFormat` — two places to disagree about what a URL is, to
/// save one fetch on the rarest shape of URL there is.
func buildRemoteOpen(
    database: Database, home: String, url: RemoteURL, fetchedAtNs: Int,
    sheet: String?, nullPadding: Bool, skipPreamble: Bool
) async throws -> RemoteOpen {
    let con = try database.connect()
    let fmt = try remoteFormat(url, con: con)
    let identity = await remoteIdentity(url)

    var notes: [String] = []
    let sasParquet = fmt == .parquet && url.query != nil
    if sasParquet { notes.append(sasParquetNote) }

    var cachePath: String?
    if fmt != .parquet || sasParquet {
        let path = try remoteCachePath(home: home, url: url)
        try downloadRemoteObject(con: con, url: url, to: path)
        cachePath = path
    }

    let spec = try buildRemoteSource(
        con: con, url: url, identity: identity, cachePath: cachePath, fetchedAtNs: fetchedAtNs,
        sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble
    )
    return RemoteOpen(spec: spec, notes: notes)
}

/// `<SIFT_HOME>/remote-cache/<fnv1a(sanitized URL)><suffix>`.
///
/// The URL is HASHED rather than sanitized into a filename, and that is the lazy answer to a real
/// problem: an object key can contain `/`, a percent-decoded `displayName` can contain `..`, and
/// both are path traversal out of the cache directory. A 16-hex-digit digest of the *sanitized* URL
/// cannot leave the directory, is stable across launches (FNV-1a, not `Hasher` — see `fnv1a`), and
/// keys on exactly the identity `RemoteRef` persists. Sanitized, not `wireURL`: two SAS'd fetches of
/// one blob are the same object, and hashing the signature in would make the cache miss every time
/// the token was re-issued.
///
/// The directory is created at **0700**, through the same call that enforces it on `~/.sift`
/// itself: these files are copies of someone's real data sitting on a laptop (spec §11), and
/// `downloadRemoteObject` writes each one 0600 inside it.
func remoteCachePath(home: String, url: RemoteURL) throws -> String {
    let dir = (home as NSString).appendingPathComponent(remoteCacheDirName)
    // Named for `~/.sift`, but it is exactly "create this directory and hold it at 0700, whether or
    // not it already existed" — which is the contract this needs, unchanged.
    try Session.ensureHomeDirectory(dir)
    return (dir as NSString).appendingPathComponent(fnv1a(url.sanitized) + cacheSuffix(url))
}

/// The extension a cache file must keep, including a compression suffix.
///
/// 🔴 **The suffix is load-bearing twice.** `detectFormat` reads magic bytes first but still
/// consults the extension for a zip container, so a cache file with no `.xlsx` is refused as "looks
/// like a zip archive, not a data file" (`RemoteRef.cachePath` states this). And a compressed file
/// keeps BOTH halves — `a.csv.gz` caches as `<hash>.csv.gz`, never `<hash>.gz`: DuckDB decides to
/// decompress from the outer suffix and `_ext_chain` reads the format from the inner one, so
/// dropping the inner half makes every `.json.gz` in the world open as a CSV (its magic bytes are
/// gzip's, so the sniffer's fallback guess is what would decide).
///
/// Built from `RemoteURL.effectiveExt`/`dataExtension`, both of which read the PATH only — never
/// from `displayName` directly, which is percent-DECODED and can therefore contain a `/`.
func cacheSuffix(_ url: RemoteURL) -> String {
    guard compressionExt.contains(url.effectiveExt) else { return url.effectiveExt }
    return dataExtension(url) + url.effectiveExt
}

/// The DuckDB extension a scheme is read through. `s3` rides on httpfs, like its secret does.
func remoteExtensionName(_ scheme: RemoteScheme) -> String {
    switch scheme {
    case .az, .abfss: return "azure"
    case .http, .https, .s3: return "httpfs"
    }
}

/// Wall-clock nanoseconds, for `RemoteRef.fetchedAtNs`.
///
/// 🔴 Wall clock and NOT `DispatchTime.now().uptimeNanoseconds`, which is the reflex here and is
/// wrong for this one job: `fetchedAtNs` is written into a staging token that is compared on a
/// LATER LAUNCH, and uptime restarts at zero every boot — two fetches on either side of a restart
/// could produce the same token, which is precisely the collision the `fetched=` form exists to
/// make impossible. It doubles as `SourceKey.mtimeNs` when the server offered no `Last-Modified`,
/// which is an epoch slot, so the epoch is also the value that belongs there.
///
/// `Date()`'s ~1 µs granularity (MEASURED, `Table.openedAt`) is not a risk at this scale: two
/// distinct fetches are a HEAD and a download apart, milliseconds at the very best.
func fetchClockNs() -> Int {
    Int(Date().timeIntervalSince1970 * 1_000_000_000)
}

// MARK: - free helpers (no actor state; safe to call from the detached background pipeline)

/// Only text-ish sources can produce cast failures — parquet and Delta carry real types, so there
/// is nothing to sniff wrong. Shared by `Session.rawRelation(_:)` (a live `Table`) and
/// `runAfterOpen` (a `SourceSpec` snapshot, before a `Table` even exists in the catalog).
private func rawRelationExpr(_ spec: SourceSpec) -> String? {
    guard supportsAllVarchar(spec) else { return nil }
    return readExpr(spec: spec, allVarchar: true)
}

/// Result of one all-varchar bad-row scan. Mirrors what Python's `_detect_bad_rows` stashes on
/// `t._uncastable` plus the two counts it derives from it.
struct BadRowScan: Sendable {
    let uncastable: [String: Int]
    let badCells: Int
    let badRows: Int
}

/// Count cells and rows that would not survive casting to the sniffed types. Reads the
/// all-varchar relation, so it sees the file as it really is. Keeps the whole per-column result
/// (not just the totals) — a future profiling task needs it for `n_uncastable` and would
/// otherwise have to re-run this same full varchar scan.
private func detectBadRows(_ con: Connection, spec: SourceSpec, raw: String) throws -> BadRowScan {
    let sql = try uncastableSQL(raw, spec.columns)
    let rs = try con.query(sql)
    let rows = try rs.allRows()
    guard let row = rows.first else {
        return BadRowScan(uncastable: [:], badCells: 0, badRows: 0)
    }

    var uncastable: [String: Int] = [:]
    for (i, meta) in rs.columns.enumerated() {
        uncastable[meta.name] = cellInt(row[i])
    }
    let badCells = uncastable.filter { $0.key.hasSuffix("__bad") }.values.reduce(0, +)

    var badRows = 0
    if badCells > 0 {
        let badSQL = try badRowCountSQL(raw, spec.columns)
        badRows = cellInt(try con.query(badSQL).allRows()[0][0])
    }
    return BadRowScan(uncastable: uncastable, badCells: badCells, badRows: badRows)
}

/// Not `private`: SourceProbe.swift and SessionQueries.swift decode plenty of `count(*)`-shaped
/// `Cell`s of their own and share this exact coercion rather than a second (or third) copy that
/// could silently drift from it — decoders drift into a wrong parsed value, not just a wrong
/// format, which is why this branch has twice ruled against the same move for `col`/`asText`
/// (Plan 2 Task 4) and `grouped` (Plan 2 Task 10).
func cellInt(_ cell: Cell) -> Int {
    if case .int(let v) = cell { return Int(v) }
    return 0
}

/// `shutil.disk_usage(path).free` — free bytes available to a non-superuser, via `statfs(2)`
/// directly (matching SourceProbe.swift's preference for the raw syscall over a Foundation
/// abstraction). Returns 0 on failure rather than throwing: this feeds a staging decision, not a
/// user-facing operation, and "call it zero free space" fails safe (never stages).
///
/// Not `private`: `stageNow` re-runs the same decision against the free space at the moment the
/// copy would actually start, which is Python's ordering too (`_after_open` and `stage_now` both
/// call `shutil.disk_usage` themselves).
func freeDiskBytes(at path: String) -> Int {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return 0 }
    return Int(s.f_bavail) * Int(s.f_bsize)
}

/// SiftCore declares `SQLValue`, DuckDBKit declares `DBValue` — deliberately not the same type
/// (see `SQLValue`'s doc comment: SiftCore cannot import DuckDBKit). This is the five-line
/// mapping between them, the real (non-test-scoped) copy of SQLGenTests.swift's `toDBValue`.
///
/// Not `private`: SessionQueries.swift binds `[SQLValue]` into every query it runs and shares
/// this exact mapping rather than a second copy.
func toDBValue(_ v: SQLValue) -> DBValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .text(let s): return .text(s)
    }
}

/// A stable-within-this-run token for `sortedRelation`'s materialized-sort table name, standing
/// in for Python's `abs(hash((t.name, t.qspec, t.staged)))`. `QuerySpec`/`SQLValue` are
/// `Equatable` but not `Hashable` in SiftCore (Task 4 must not touch Sources/SiftCore/**), so
/// this hashes a manually-built string instead of the values directly — same "good enough to key
/// a same-run cache, not a cross-run identity" contract Python's own `hash()` (salted per
/// process) accepts.
private func sortRelationName(for t: Table) -> String {
    var parts = [t.name, t.staged ? "1" : "0"]
    for f in t.qspec.filters {
        parts.append(f.col)
        parts.append(f.op.rawValue)
        parts.append(contentsOf: f.values.map(sqlValueToken))
    }
    for s in t.qspec.sort {
        parts.append(s.column)
        parts.append(s.direction.rawValue)
    }
    let token = parts.joined(separator: "\u{1}")
    // Masks the sign bit instead of `abs()`: `abs(Int.min)` traps, and a hash landing exactly on
    // Int.min is the one input that would turn a temp-table name into a crash.
    let magnitude = token.hashValue & Int.max
    return "_sift_rs_\(magnitude)"
}

private func sqlValueToken(_ v: SQLValue) -> String {
    switch v {
    case .null: return "\u{2}n"
    case .bool(let b): return "\u{2}b\(b)"
    case .int(let i): return "\u{2}i\(i)"
    case .double(let d): return "\u{2}d\(d)"
    case .text(let s): return "\u{2}t\(s)"
    }
}
