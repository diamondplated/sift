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
//   3. `page`, `sortedRelation` and `closeTable` share ONE long-lived `Connection`
//      (`pagingConnection`), for as long as the `Session` exists, instead of opening a fresh one
//      per call. This is not a stylistic choice — MEASURED (see `sortedRelation`'s doc comment):
//      a `CREATE TEMP TABLE` created on one `duckdb_connect()` connection is invisible to a
//      `SELECT` on a different one, even against the same file, so a materialized sort must be
//      read back through the SAME connection that created it across however many `page()` calls
//      follow. Safe to share despite `Connection` not being `Sendable`: none of `page`,
//      `sortedRelation` or `closeTable` ever awaits anything (verified by reading them — every
//      DuckDB call inside is synchronous), so the actor's serial executor guarantees exactly one
//      of them runs at a time and `pagingConnection` never sees two callers at once. `openPath`'s
//      initial half and `_after_open`'s background pipeline still open a fresh `Connection` each
//      time (fact 2) — they never touch a materialized sort, so they have no reason to share one.
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
/// consequence: a sort over more rows than this silently truncates the materialized copy, so
/// pages past row `sortMaterializeMax` come back empty and `visibleRows` still reports the full
/// (untruncated) count. Not fixed here — inherited as-is; see task-4-report.md's Minor-review
/// notes for the call on whether it needs its own fix.
let sortMaterializeMax = 5_000_000

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
    public nonisolated let siftHome: String
    public nonisolated let dbPath: String
    /// `false` once a second engine has been found holding the shared store's lock — see `init`.
    public nonisolated let sharedStore: Bool
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
    /// Per-table mutex a later task's staging swap-retry loop will lock from its own background
    /// `Task`, mirroring Python's `with self._tlock(name):` called from a worker thread. Only this
    /// dictionary's get-or-create needs actor isolation; the returned `NSLock` itself is meant to
    /// be locked/unlocked from the caller's own (non-actor) context.
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

    public init(home: String? = nil) throws {
        let resolvedHome = Self.resolveHome(home)
        try Self.ensureHomeDirectory(resolvedHome)
        Self.sweepPrivateStores(in: resolvedHome)

        // DuckDB takes an exclusive lock on the database file, so only one engine can own the
        // shared staged-data store — usually right, it is one user's cache. Browser mode (the
        // reason a second engine used to show up routinely) is gone, but `open -n` can still
        // start a second instance, and that must not turn into an opaque lock error at launch:
        // fall back to a private, per-PID store this instance deletes on exit (`dropPrivateStore`).
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
            // permission refusal. This is the very first thing the CLI and the app call, and the
            // app's `presentFatal` puts `localizedDescription` straight into an alert body.
            throw SessionError(error.firstLine)
        }

        self.siftHome = resolvedHome
        self.dbPath = path
        self.sharedStore = shared
        self.database = db

        db.harden()
        db.loadExtensions(sessionExtensions)

        let con: Connection
        do {
            con = try db.connect()
            try con.execute(catalogDDL)
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
        // Before anything reads the catalog: a store written by an older build has a differently
        // keyed catalog holding tokens this build cannot interpret. See `migrateCatalog`.
        Self.migrateCatalog(con)
        // Python's `self.purge_staged(reason="startup")`. Nothing is open yet, so the "never yank
        // a table out from under an open tab" rule is trivially satisfied — this is where a copy
        // that aged out, blew the budget, or no longer matches its source gets collected.
        // `try?`: a store that cannot be purged must not stop the engine from starting.
        _ = try? Self.purgeStagedTables(con, open: [], tables: nil, all: false)
        self.pagingConnection = con
    }

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
        t.staging = StagingProgress(jobID: "stage-test", state: "running", pct: 0, estSeconds: 0)
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
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let resolved = realPath(expanded)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SessionError("No such file or folder: \(resolved)")
        }

        if isDeltaDir(resolved), database.loadedExtensions["delta"] != true {
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

        let taken = Set(tables.keys)
        let base: String
        if let name, !name.isEmpty {
            base = name
        } else {
            let raw = spec.fmt == .xlsx
                ? (spec.sheet ?? (resolved as NSString).lastPathComponent)
                : (resolved as NSString).lastPathComponent
            base = try sanitizeTableName(raw)
        }
        let tname = taken.contains(base) ? try sanitizeTableName(base, taken: taken) : base

        nextOpenGeneration += 1
        var t = Table(name: tname, spec: spec, qspec: QuerySpec(relation: tname), openedAt: nextOpenGeneration)
        if let rowCount = spec.rowCount { t.rowCount = rowCount }

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
        let decision = shouldStage(fmt: spec.fmt, sizeBytes: spec.key.size, freeBytes: free)
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
        defer { tables.removeValue(forKey: name) }

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

    public func shutdown() {
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
    public let extensions: [String: Bool]
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
