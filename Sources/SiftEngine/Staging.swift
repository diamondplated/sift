import DuckDBKit
import Foundation
import SiftCore

// Staging and the staged-data lifecycle. Ported from engine/session.py lines 775-1015:
// `_next_job`, `_maybe_stage_after_dwell`, `stage_now`, `_do_stage`, `cancel`, `_record_staged`,
// `_db_bytes`, `staged_entries`, `staged_total_bytes`, `purge_staged`, plus `unstage`
// (session.py:1116, which belongs to this lifecycle rather than to Task 7's joins).
//
// STAGING IS THE SECOND STEP, NEVER THE FIRST. `openPath` creates a view over the file, which is
// instant at any size; the CTAS that copies it into native storage only fires for a text format
// above 25 MB (`SiftCore.shouldStage`) and only once the user has shown interest — an aggregate
// query or `stageDwellSeconds` of dwell on the open table. A drive-by "let me peek at the header"
// must never pay for a 20 s copy.
//
// CONNECTION STRATEGY: the CTAS runs on its OWN `Connection`, created inside the detached task
// that runs it, and never on `pagingConnection`. That is not a preference — `pagingConnection` is
// safe as a single long-lived non-`Sendable` connection only because no user ever SUSPENDS between
// acquiring it and finishing with it (Session.swift's header, fact 3), and a multi-second CTAS on
// it would both break that proof and freeze every page request behind it.
//
// THREE places in this file DO touch `pagingConnection` — half of its six users, which is why
// fact 3 names them:
//
//   * `applyStaged` — drops the stale materialized-sort TEMP TABLE the swap orphaned;
//   * `unstage` — drops the same thing, going the other way;
//   * `finishStage` — drops the VIEW of a table closed while its job was in flight. **A VIEW, not
//     a TEMP TABLE**, so it is on `pagingConnection` for a different reason from the other two:
//     not visibility, but that it is a synchronous drop already running on the actor with a
//     connection in hand. (An earlier version of this note listed two of the three and described
//     all of them as TEMP-TABLE drops.)
//
// All three run their statement with no suspension point between acquiring the connection and
// finishing with it. `unstage` is `async` and does `await` — but only after, on `computeProfile`,
// which is the exact shape fact 3 now spells out as permitted.

// MARK: - a staging job's cancel half

/// The cancellable half of one staging job: the flag `runStage` polls, and the connection the
/// interrupt has to reach.
///
/// 🔴 **The interrupt must be hammered, not fired once.** MEASURED against libduckdb 1.5.5: a
/// single `duckdb_interrupt` issued *before* execution begins is swallowed — the flag is cleared
/// as execution starts and the query then runs to completion (4.20 s in the probe). Re-asserting
/// it in a loop cancels reliably (5/5 runs, 0.000-0.002 s). Python's `cancel` calls
/// `con.interrupt()` exactly once and therefore does not port; `StagingTests` pins both halves.
///
/// `@unchecked Sendable` around a non-`Sendable` `Connection` is the same documented exception
/// `Tests/DuckDBKitTests/SmokeTests.swift`'s `Interrupter` box makes: `interrupt()` is the one
/// `Connection` call that exists to be made from somewhere other than the task running the query.
/// Everything crossing that boundary goes through `lock`.
final class StageJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var connection: Connection?
    /// `true` until the interruptible query has returned. Closing the window before running the
    /// swap/count/checkpoint statements is what stops a hammer in flight from killing one of
    /// those instead — the interrupt flag is connection-wide, not query-specific.
    private var windowOpen = true
    private var hammering = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    /// Is the hammer thread still running? The observable half of "every exit closes the window" —
    /// a job left hammering is the M4/N1 failure, and it is invisible from the outside otherwise.
    var isHammering: Bool { lock.withLock { hammering } }

    /// Hand the job the connection its CTAS runs on. Called once, before the CTAS starts.
    func attach(_ connection: Connection) {
        lock.withLock { self.connection = connection }
    }

    /// Set the cancel flag and start re-asserting the interrupt until the window closes. Returns
    /// `false` when the job is already past the point a cancel can reach it.
    ///
    /// That return value is the honest half of review M3: once the interruptible query has
    /// returned, `runStage` is committed to publishing — the swap is a fast, transactional rename
    /// that undoing would mean dropping a finished copy and rebuilding a view. Reporting `true`
    /// there told the user a cancel had been accepted and then published the copy anyway.
    ///
    /// A real `Thread`, not a `Task`: this loop is a spin with a 0.2 ms pause, and parking a
    /// cooperative-pool thread on it would starve the very actor the job has to call back into.
    /// Starting even when no connection is attached yet is deliberate — `cancel` can be called
    /// with the job id `stageNow` just returned, microseconds before the detached task has
    /// connected, and the loop simply hammers nothing until it has.
    @discardableResult
    func requestCancel() -> Bool {
        lock.lock()
        guard windowOpen else { lock.unlock(); return false }
        cancelled = true
        let start = !hammering
        if start { hammering = true }
        lock.unlock()
        guard start else { return true }

        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let open = windowOpen
                let target = connection
                lock.unlock()
                guard open else { break }
                target?.interrupt()
                usleep(200)
            }
            lock.withLock { hammering = false }
        }
        return true
    }

    /// Stop hammering, and do not return until the hammer thread has actually stopped — an
    /// interrupt landing after this returns would be picked up by the NEXT statement on the same
    /// connection (the swap, the count, the CHECKPOINT), which is not what was cancelled.
    func closeInterruptWindow() {
        lock.withLock {
            windowOpen = false
            connection = nil
        }
        while lock.withLock({ hammering }) { usleep(200) }
    }
}

/// What `applyStaged` found when it went to publish a finished copy.
enum StageApplyResult: Sendable {
    case applied(rowCount: Int)
    /// The table this job was launched for is no longer open under this `openedAt`. Carries the
    /// spec of whatever table now holds the name, if any, so the caller can put the catalog back.
    case stale(replacement: SourceSpec?)
}

// MARK: - Session

extension Session {

    // MARK: - starting a job

    /// Stage this table now, if the policy (or `force`) says so. Ported from Python's `stage_now`;
    /// returns the job id, or `nil` when nothing was started.
    @discardableResult
    public func stageNow(_ name: String, force: Bool = false) throws -> String? {
        var t = try table(name)
        if t.staged || t.staging != nil { return nil }

        let decision = shouldStage(
            fmt: t.spec.fmt, sizeBytes: t.spec.key.size, freeBytes: freeDiskBytes(at: siftHome)
        )
        t.stageDecision = decision
        guard decision.stage || force else {
            tables[name] = t          // Python's emit({"type": "state"}) — the state change IS it.
            return nil
        }

        stageJobSeq += 1
        let jobID = "stage-\(stageJobSeq)"
        let job = StageJob()
        stageJobs[jobID] = job
        t.staging = StagingProgress(
            jobID: jobID, state: "running",
            estSeconds: (decision.estSeconds * 10).rounded() / 10   // Python's round(..., 1)
        )
        t.stagingError = nil
        tables[name] = t

        let spec = t.spec
        let openedAt = t.openedAt
        Task.detached { [self] in
            await runStage(name: name, spec: spec, jobID: jobID, job: job, openedAt: openedAt)
        }
        return jobID
    }

    /// Stage only once the user has shown interest — an aggregate query, or `stageDwellSeconds`
    /// of dwell on the open table. Ported from Python's `_maybe_stage_after_dwell`.
    ///
    /// Called from `runAfterOpen` (which is already detached), rather than dispatched onto a
    /// second background worker the way Python submits it to its pool: awaiting it there costs
    /// nothing, since the staging decision it follows is the last thing that pipeline does.
    /// Suspending on the actor is safe and is the point — every 0.1 s wake re-reads the catalog,
    /// and other actor work (paging, a second open) runs in between.
    func maybeStageAfterDwell(_ name: String, openedAt: Int) async {
        let deadline = Date().addingTimeInterval(stageDwellSeconds)
        while Date() < deadline {
            // `openedAt`, not just presence: a table closed and reopened under the same name
            // during the dwell is a different table, and this job is not about it (Session.swift's
            // `runAfterOpen` doc comment has the measurement behind that guard).
            guard let t = tables[name], t.openedAt == openedAt else { return }
            if t.firstAggregateAt != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let t = tables[name], t.openedAt == openedAt, !t.staged else { return }
        _ = try? stageNow(name)
    }

    /// Ask a running job to stop. Returns `false` for a job id that is not running — which is
    /// also what a job that has already finished looks like. Ported from Python's `cancel`.
    ///
    /// Returns immediately (Python's contract): the hammering happens on `StageJob`'s own thread,
    /// because spinning here would hold the actor and deadlock against the very callback the job
    /// needs to make to report that it stopped.
    @discardableResult
    public func cancel(_ jobID: String) -> Bool {
        guard let job = stageJobs[jobID] else { return false }
        // `false` is also the answer for a job whose copy is already built and being published —
        // see `StageJob.requestCancel`. A cancel that cannot land must not report that it did.
        return job.requestCancel()
    }

    // MARK: - running one job

    /// The CTAS, the swap, and the bookkeeping. Ported from Python's `_do_stage`.
    ///
    /// `nonisolated` with its own `Connection`, matching `runAfterOpen`: the copy takes seconds
    /// and must not run on the actor. Every mutation of the catalog goes through a small isolated
    /// `apply*`/`finishStage` call carrying `openedAt`, so a job whose table was closed (or closed
    /// and reopened) mid-copy cannot write onto the table that now holds its name.
    /// `connect` exists only so a test can reach the connection-failure path below, which is
    /// otherwise unreachable — `database.connect()` does not fail on demand. Production passes
    /// nothing. It is a parameter rather than a mutable flag on the actor so the seam is visible
    /// in the signature and carries no state between jobs.
    nonisolated func runStage(
        name: String, spec: SourceSpec, jobID: String, job: StageJob, openedAt: Int,
        connect: (() throws -> Connection)? = nil
    ) async {
        // FIRST STATEMENT IN THE FUNCTION, above the `do`/`catch` below, and that placement is the
        // whole point: Swift registers a `defer` when control REACHES it, so one written below an
        // early `return` never runs on that path. This guard spent round 1 sitting under the
        // `catch` it was written for, with a comment claiming it covered it (review N1) — the
        // cancel hammer really did keep spinning at ~5 kHz for the life of the process when
        // `database.connect()` failed. Idempotent, so the explicit early close still does the real
        // work of shutting the window before the swap.
        defer { job.closeInterruptWindow() }

        let con: Connection
        do {
            con = try (connect ?? database.connect)()
        } catch {
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: "staging failed: \(error)")
            return
        }
        job.attach(con)

        var failure: String?
        do {
            try con.execute(ctasSQL(table: name, readExpr: readExpr(spec: spec)))
        } catch let error as DuckDBError {
            failure = error.firstLine
        } catch {
            failure = "\(error)"
        }
        job.closeInterruptWindow()

        // Cancel wins over the CTAS's own outcome, and deliberately so: a cancelled job's CTAS
        // FAILS (with "INTERRUPT Error: Interrupted!") rather than completing, so Python — which
        // only checks its cancel flag on the success path — reports a user-requested cancel to
        // the user as `staging failed: INTERRUPT Error...`. That is a defect, not a behavior; see
        // task-6-report.md. Here a cancelled job is cancelled, whichever way the CTAS ended.
        if job.isCancelled {
            try? con.execute(dropStagingSQL(name))
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: nil)
            return
        }
        if let failure {
            try? con.execute(dropStagingSQL(name))
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: "staging failed: \(failure)")
            return
        }

        // The last cheap check before the rename makes the name mean something new. It does not
        // close the window — `applyStaged` below is still the authority and still repairs — but it
        // narrows it from "however long the CTAS took" to "the swap itself" (review M5).
        guard await isStillOpen(name, openedAt: openedAt) else {
            try? con.execute(dropStagingSQL(name))
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: nil)
            return
        }

        do {
            try swapStaged(con, name: name, lock: await tlock(name))
        } catch {
            try? con.execute(dropStagingSQL(name))
            let message = (error as? DuckDBError)?.firstLine ?? "\(error)"
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: "staging failed: \(message)")
            return
        }

        let physical = (try? con.query("SELECT count(*) FROM \(q(name))").allRows().first)
            .flatMap { $0.first }.map(cellInt) ?? 0
        let bytes = stagedBytes(con, table: name)

        // Recorded BEFORE the copy is published, not after (review M2): a process that dies in
        // between must leave a catalog row with no table — which the next purge collects — rather
        // than a table with no row, which nothing can ever reach.
        try? recordStaged(con, spec: spec, table: name, rowCount: physical, bytes: bytes)

        switch await applyStaged(name, physicalRows: physical, openedAt: openedAt, jobID: jobID) {
        case .applied(let rowCount):
            // `row_count` is corrected here rather than at INSERT time: the authoritative number
            // is the copy's own count plus the bad rows the parser dropped, and `badRows` lives on
            // the actor, which the write above deliberately runs ahead of.
            _ = try? con.query(
                "UPDATE _sift_sources SET row_count = ? WHERE table_name = ?",
                [.int(Int64(rowCount)), .text(name)]
            )
            // Re-profile against the native table. `try?`, unlike Python's bare call inside its
            // one big `except`: the copy is already live and recorded, so a profile failure here
            // is not "staging failed" — and every reader of `profile` recomputes it on demand.
            _ = try? await computeProfile(name)
        case .stale(let replacement):
            // The table was closed (and possibly reopened under the same name) between the last
            // `openedAt` check and the rename, so the name now points at a copy of a file the
            // open table is not. Left alone, a reopened table would silently serve the OLD file's
            // rows — the relation-level shape of the bug `openedAt` exists to stop. Put the
            // catalog back the way the live table expects to find it, row included.
            _ = try? con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(name)])
            Self.dropStagedObject(con, name)
            if let replacement {
                try? con.execute(createViewSQL(name: name, spec: replacement))
            }
        }
    }

    /// Is this exact open of `name` still in the catalog? The pre-swap half of the `openedAt`
    /// guard — see `runStage`.
    func isStillOpen(_ name: String, openedAt: Int) -> Bool {
        tables[name]?.openedAt == openedAt
    }

    /// Publish a finished copy onto the open table. Actor-isolated and synchronous.
    func applyStaged(
        _ name: String, physicalRows: Int, openedAt: Int, jobID: String
    ) -> StageApplyResult {
        stageJobs.removeValue(forKey: jobID)
        guard var t = tables[name], t.openedAt == openedAt else {
            return .stale(replacement: tables[name]?.spec)
        }

        t.staged = true
        t.staging = nil
        t.stagingError = nil
        if let key = t.sortKey {
            // The materialized sort was built over the view; the staged table's `sortRelationName`
            // differs (it hashes `staged`), so this copy is unreachable from here on. Dropped
            // rather than merely forgotten (Python forgets it): it can hold up to
            // `sortMaterializeMax` rows — 51.9 MB in Task 4's measurement — for the life of the
            // session. Safe on `pagingConnection` despite Session.swift's fact 3: a TEMP TABLE is
            // visible only to its creating connection, this runs synchronously on the actor, and
            // there is no suspension point anywhere in this method.
            try? pagingConnection.execute("DROP TABLE IF EXISTS \(q(key))")
            t.sortKey = nil
        }
        t.profile = nil                  // re-profile against the native table
        // And revoke any profile already in flight: it is reading the VIEW this rename just
        // replaced, so its answer is about what the name used to point at. Dropping the entry
        // drops the claim, and `applyProfile` accepts a result only from the job whose ID is still
        // registered — which is why that guard compares IDs and not `openedAt`: this revocation
        // does not reopen the table, so the replacement `runStage` kicks immediately below
        // registers under the very same generation.
        profileJobs.removeValue(forKey: name)
        // After staging the table is materialized, so its own count is now authoritative and
        // already excludes the rows `ignore_errors` dropped at parse time.
        let rowCount = physicalRows + t.badRows
        t.rowCount = rowCount
        tables[name] = t
        return .applied(rowCount: rowCount)
    }

    /// Clear a job that ended without publishing anything — cancelled (`error: nil`) or failed.
    /// Python emits `{"type": "error", ...}`; in-process that event is `Table.stagingError`.
    func finishStage(_ name: String, jobID: String, openedAt: Int, error: String?) {
        stageJobs.removeValue(forKey: jobID)
        guard var t = tables[name], t.openedAt == openedAt else {
            // The tab was closed while this job was in flight, and `closeTable` deliberately left
            // the name alone because a staging job may have already turned it into a TABLE
            // mid-swap. Every path that lands here — cancel, CTAS failure, and the pre-swap
            // `isStillOpen` bail that made "close a tab mid-copy" the COMMON case — is pre-swap,
            // so the name is still the view `openPath` created, and this is the last place that
            // can collect it. Without this the views pile up in a persistent store where no purge
            // can see them (review N2).
            //
            // Only when the name is unclaimed: if a DIFFERENT open now holds it (generation
            // mismatch), that table's own view is not this job's to drop. Safe on
            // `pagingConnection` for the reason `applyStaged` states — no suspension point here.
            if tables[name] == nil {
                try? pagingConnection.execute("DROP VIEW IF EXISTS \(q(name))")
            }
            return
        }
        t.staging = nil
        t.stagingError = error
        tables[name] = t
    }

    /// Record a staged table, with the disk it actually cost. Ported from `_record_staged`.
    nonisolated func recordStaged(
        _ con: Connection, spec: SourceSpec, table: String, rowCount: Int, bytes: Int
    ) throws {
        _ = try con.query(
            "INSERT OR REPLACE INTO _sift_sources "
                + "(source_token, path, mtime_ns, size, table_name, fmt, staged_at, last_used, "
                + " row_count, bytes) VALUES (?,?,?,?,?,?,now(),now(),?,?)",
            [
                .text(stagingToken(spec)), .text(spec.key.path), .int(Int64(spec.key.mtimeNs)),
                .int(Int64(spec.key.size)), .text(table), .text(spec.fmt.rawValue),
                .int(Int64(rowCount)), .int(Int64(bytes)),
            ]
        )
    }

    /// What one staged copy actually occupies, from DuckDB's own block allocation.
    ///
    /// **Not the store's growth across the CTAS**, which is what the brief specified and what the
    /// first version of this did. That number is not per-copy: `dbBytes()` is the whole store, so
    /// two jobs in flight interleave their checkpoints and charge each other. MEASURED (review
    /// I4): the same 3-row CSV recorded 262,144 B alone and 413 B beside a 30 MB copy, and two
    /// equal files staging together recorded 524,288 and 900,839. `selectForPurge` sums these
    /// against a 20 GB budget and subtracts them while evicting, so under-charging lets the store
    /// grow past the budget with the purge convinced it holds nothing.
    ///
    /// `pragma_storage_info` reports the blocks this table's segments actually live in, so a
    /// concurrent job cannot move the number — MEASURED: a table read 32 blocks before and after
    /// an unrelated 21-block table was written beside it, and 32 + 21 matched the store's own
    /// `used_blocks` of 54 and its growth on disk. This is emphatically NOT
    /// `duckdb_tables.estimated_size`, which is estimated ROWS (DuckDB155FactsTests' fact9) and
    /// still banned.
    ///
    /// ponytail: block granularity (256 KiB), so a small copy rounds up to one block. That is the
    /// allocation unit — it over-states rather than under-states, which is the safe direction for
    /// a disk budget. Per-segment byte counts would need summing `count`×type width by hand.
    nonisolated func stagedBytes(_ con: Connection, table: String) -> Int {
        // A segment that has not been written to a block yet reports `block_id = -1`, so the
        // CHECKPOINT comes first — and it is RETRIED, because a checkpoint fails outright while
        // another connection has a write transaction open ("Cannot CHECKPOINT: there are other
        // write transactions active"), which is exactly the concurrent-staging case this number
        // has to be honest about. MEASURED: without the retry a copy staged beside another
        // recorded 0 B.
        let sql = "SELECT (SELECT count(DISTINCT block_id) FROM pragma_storage_info(\(qlit(table))) "
            + "WHERE block_id >= 0) * (SELECT block_size FROM pragma_database_size())"
        for attempt in 0..<10 {
            // A successful CHECKPOINT means every segment now has a block, so whatever the count
            // says is the answer — including 0 for a copy with no rows. Only a FAILED checkpoint
            // is worth waiting on.
            let checkpointed = (try? con.execute("CHECKPOINT")) != nil
            if let row = try? con.query(sql).allRows().first, checkpointed || cellInt(row[0]) > 0 {
                return cellInt(row[0])
            }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return 0
    }

    /// Drop whatever object holds this name. A staged copy is a TABLE, but a leftover VIEW can
    /// hold the same name, and `DROP TABLE` on a view is a hard `Catalog Error` — which, inside
    /// `purgeStagedTables`' loop, used to abort the whole purge and leave every later target
    /// uncollected (review M1). Returns `false` only if the name survived both attempts.
    @discardableResult
    static func dropStagedObject(_ con: Connection, _ name: String) -> Bool {
        if (try? con.execute("DROP TABLE IF EXISTS \(q(name))")) != nil { return true }
        return (try? con.execute("DROP VIEW IF EXISTS \(q(name))")) != nil
    }

    // MARK: - reopening a file that already has a copy

    /// Reuse the staged copy an earlier open of this exact file left in the store, if there is
    /// one. Returns its recorded row count when the copy was adopted, `nil` when the caller should
    /// create the usual view.
    ///
    /// **This is not in Python, and it has to be here.** A staged copy is a real table in a
    /// file-backed store, so it outlives the tab that made it and the process that made it (that
    /// is the entire point of the `_sift_sources` catalog) — but Python's `open_path`
    /// unconditionally runs `CREATE OR REPLACE VIEW`, and MEASURED against DuckDB 1.5.5 that is
    /// `Catalog Error: Existing object small is of type Table, trying to replace with type View`.
    /// So in the Python engine, staging a file and then reopening it — same session, close the tab
    /// and open it again; or tomorrow morning — fails outright. Nothing in `engine/tests/**`
    /// covers it, which is presumably why it shipped. Task 6 is what makes that state reachable in
    /// this port, so Task 6 closes it.
    ///
    /// Adoption is gated on `stagingToken` — the source's real identity, sheet and folder members
    /// included, NOT `SourceKey.token()`; see `stagingToken` for the two ways that served the
    /// wrong file's data. A copy that does not match is dropped along with its catalog row, and
    /// the caller falls back to reading the source in place.
    nonisolated func adoptStagedCopy(_ con: Connection, name: String, spec: SourceSpec) -> Int? {
        // `duckdb_tables()` lists tables only — a leftover VIEW of the same name is this port's
        // own doing and `CREATE OR REPLACE VIEW` handles it, which is why only tables land here.
        let tableExists = (try? con.query(
            "SELECT count(*) FROM duckdb_tables() WHERE table_name = ?", [.text(name)]
        ).allRows().first).map { cellInt($0[0]) } ?? 0
        guard tableExists > 0 else {
            // No table, but possibly a catalog row still pointing at one. Left behind, that row
            // makes every later purge throw on `DROP TABLE` once anything creates a VIEW under the
            // name — which `openPath` is about to do (review M1).
            _ = try? con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(name)])
            return nil
        }

        let matched = try? con.query(
            "SELECT row_count FROM _sift_sources WHERE table_name = ? AND source_token = ?",
            [.text(name), .text(stagingToken(spec))]
        ).allRows().first
        guard let row = matched ?? nil, columnsMatch(con, table: name, spec: spec) else {
            // A copy of a different file, an older version of this one, or one written by a build
            // whose token format we can no longer interpret. Either way it is wrong AND it is
            // holding the name.
            Self.dropStagedObject(con, name)
            _ = try? con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(name)])
            return nil
        }
        _ = try? con.query(
            "UPDATE _sift_sources SET last_used = now() WHERE table_name = ?", [.text(name)]
        )
        return cellInt(row[0])
    }

    /// Backstop for the one hole the token cannot close: a file replaced by a different file of
    /// the same size with the same mtime (a restore that preserves timestamps). Cheap — the
    /// `LIMIT 0` reads no rows — and it catches the case where that different file also has a
    /// different shape. It is a backstop, not the fix; the fix is `stagingToken`.
    private nonisolated func columnsMatch(_ con: Connection, table: String, spec: SourceSpec) -> Bool {
        guard let result = try? con.query("SELECT * FROM \(q(table)) LIMIT 0") else { return false }
        // Exact, against the shape this source actually produces. A folder read appends ONE
        // `filename` provenance column that `spec.columns` does not list (SourceProbe sets
        // `filename: true` for globs), which is why a bare `== spec.columns` rejected every folder
        // copy and silently disabled adoption for the whole class. `starts(with:)` fixed that but
        // admitted any number of extra trailing columns for any source kind (review N3); naming
        // the one column that is actually expected keeps the fix without the slack.
        let provenance = (spec.fmt == .globCsv || spec.fmt == .globParquet) ? ["filename"] : []
        return result.columns.map(\.name) == spec.columns.map(\.name) + provenance
    }

    // MARK: - the staged-data lifecycle

    /// Every staged copy this store knows about, newest use first. Ported from `staged_entries`.
    public func stagedEntries() throws -> [StagedSource] {
        let rows: [[Cell]]
        do {
            let con = try database.connect()
            rows = try con.query(
                "SELECT table_name, path, fmt, epoch_ms(staged_at::TIMESTAMPTZ), "
                    + "epoch_ms(last_used::TIMESTAMPTZ), row_count, bytes, mtime_ns, size "
                    + "FROM _sift_sources ORDER BY last_used DESC"
            ).allRows()
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }

        return rows.map { row in
            let path = cellText(row[1])
            let stat = try? statInfo(path)
            return StagedSource(
                table: cellText(row[0]), path: path, fmt: cellText(row[2]),
                stagedAt: dateFromEpochMs(row[3]), lastUsed: dateFromEpochMs(row[4]),
                rows: cellInt(row[5]), bytes: cellInt(row[6]),
                sourceMissing: stat == nil,
                sourceChanged: stat.map { $0.mtimeNs != cellInt(row[7]) || $0.size != cellInt(row[8]) } ?? false
            )
        }
    }

    /// Real bytes on disk, not the sum of per-table estimates — the file the user could go and
    /// delete, which is the number that answers "what is this tool holding on to".
    public nonisolated func stagedTotalBytes() -> Int { dbBytes() }

    /// The age-out and size limits this session is actually enforcing, so the staged-data
    /// manager can state them rather than restating a default that `SIFT_STAGE_BUDGET_GB` may
    /// have overridden. `nonisolated`: both read only the environment.
    public nonisolated func stagePolicy() -> StagePolicy {
        StagePolicy(budgetBytes: stageBudgetBytes(), maxAgeDays: stageMaxAgeDays())
    }

    /// Drop staged tables — explicitly, by age, or under size pressure. Ported from `purge_staged`.
    ///
    /// Python's `reason` argument only ever fed a log line and an SSE event, neither of which
    /// exists here, so it is not ported.
    @discardableResult
    public func purgeStaged(tables names: [String]? = nil, all: Bool = false) throws -> PurgeResult {
        do {
            let con = try database.connect()
            let dropped = try Self.purgeStagedTables(
                con, open: Set(tables.keys), tables: names, all: all
            )
            return PurgeResult(dropped: dropped, stagedBytes: dbBytes())
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// The purge itself, against a bare connection.
    ///
    /// `static`, so `Session.init` can run the startup purge (Python's
    /// `self.purge_staged(reason="startup")`) before the actor exists, and so a test can drive the
    /// age/budget/staleness policy without standing up a whole session. `open` is the set of table
    /// names currently in the catalog: a staged copy whose table is still open is skipped even
    /// when the policy selects it — the live catalog wins, and a purge never yanks a table out
    /// from under an open tab.
    static func purgeStagedTables(
        _ con: Connection, open: Set<String>, tables names: [String]?, all: Bool
    ) throws -> [String] {
        let rows = try con.query(
            "SELECT table_name, path, bytes, epoch_ms(last_used::TIMESTAMPTZ), source_token, "
                + "mtime_ns, size FROM _sift_sources"
        ).allRows()

        var targets: [String]
        if all {
            targets = rows.map { cellText($0[0]) }
        } else if let names {
            targets = names
        } else {
            let entries = rows.map {
                StagedEntry(
                    tableName: cellText($0[0]), path: cellText($0[1]), bytes: cellInt($0[2]),
                    lastUsed: dateFromEpochMs($0[3]), sourceToken: cellText($0[4])
                )
            }
            // `Date()` and `epoch_ms(<stored>::TIMESTAMPTZ)` are the same clock frame: the cast
            // reads the naive stored value back in the session time zone `now()` wrote it in.
            // Without it the two are off by the machine's UTC offset (MEASURED: 5 h here);
            // StagingTests pins the round trip.
            let (aged, over) = selectForPurge(
                entries: entries, now: Date(), budgetBytes: stageBudgetBytes(),
                maxAgeDays: stageMaxAgeDays()
            )
            targets = aged + over
            // A copy whose token this build can no longer interpret can never be adopted again, so
            // leaving it is disk nothing will ever reach. `migrateCatalog` handles the older store
            // whose KEY also changed; this is the lighter case — a store whose schema is current
            // but whose tokens predate a format bump (v2 -> v3 when ctime joined the identity).
            for row in rows where !cellText(row[4]).hasPrefix("\(stagingTokenVersion)|") {
                let name = cellText(row[0])
                if !targets.contains(name) { targets.append(name) }
            }
            // A staged copy of a file that has since changed on disk is simply wrong. A source
            // that has *vanished* is not swept here, matching Python — the copy may be the only
            // thing left of it, and `stagedEntries` surfaces it as `sourceMissing` instead.
            for row in rows {
                let name = cellText(row[0])
                guard let stat = try? statInfo(cellText(row[1])) else { continue }
                if stat.mtimeNs != cellInt(row[5]) || stat.size != cellInt(row[6]),
                    !targets.contains(name) {
                    targets.append(name)
                }
            }
        }

        var dropped: [String] = []
        for name in targets where !open.contains(name) {
            // `dropStagedObject` rather than a bare `DROP TABLE`, and one target's failure never
            // aborts the rest: a single row whose name belongs to a VIEW used to throw here and
            // leave every later target uncollected — age and budget enforcement silently dead
            // (review M1).
            guard Self.dropStagedObject(con, name) else { continue }
            _ = try? con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(name)])
            dropped.append(name)
        }
        return dropped
    }

    /// Bring an existing store's catalog to the shape this build expects, before anything reads it.
    ///
    /// Two things changed under it: the PRIMARY KEY moved from `source_token` to `table_name`
    /// (review I5 — the old key made two tabs of one file collapse into one row, stranding a full
    /// copy that no purge could reach), and `stagingToken`'s format changed (C1). Neither can be
    /// patched in place: DuckDB cannot re-key a table, and a v1 token cannot be re-derived from
    /// what the row stores.
    ///
    /// So a legacy store is **reset**: every copy the old catalog lists is dropped and the catalog
    /// is recreated empty. That is the "collected, not stranded" half — those copies could never be
    /// adopted again (their tokens can no longer match), so leaving them would be pure disk that
    /// nothing reaches. A staged copy is a cache; the next open rebuilds it.
    ///
    /// Fail-safe on its own detection: if the constraint query itself fails, nothing is touched.
    static func migrateCatalog(_ con: Connection) {
        guard let row = try? con.query(
            "SELECT count(*) FROM duckdb_constraints() WHERE table_name = '_sift_sources' "
                + "AND constraint_type = 'PRIMARY KEY' "
                + "AND list_contains(constraint_column_names, 'table_name')"
        ).allRows().first else { return }
        guard cellInt(row[0]) == 0 else { return }

        let stale = (try? con.query("SELECT table_name FROM _sift_sources").allRows()) ?? []
        for row in stale { dropStagedObject(con, cellText(row[0])) }
        try? con.execute("DROP TABLE IF EXISTS _sift_sources")
        try? con.execute(catalogDDL)
    }

    /// Drop a staged table and go back to reading the source in place. Ported from `unstage`.
    @discardableResult
    public func unstage(_ name: String) async throws -> Table {
        var t = try table(name)
        guard t.staged else { return t }

        do {
            let con = try database.connect()
            try con.execute("DROP TABLE IF EXISTS \(q(t.name))")
            try con.execute(createViewSQL(name: t.name, spec: t.spec))
            _ = try con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(t.name)])
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }

        t.staged = false
        if let key = t.sortKey {
            // Same reasoning as `applyStaged`: dropped, not merely forgotten, and safe on
            // `pagingConnection` because nothing suspends between here and the write below.
            try? pagingConnection.execute("DROP TABLE IF EXISTS \(q(key))")
            t.sortKey = nil
        }
        t.profile = nil
        profileJobs.removeValue(forKey: name)   // same revocation as `applyStaged`, other direction
        tables[name] = t

        _ = try await computeProfile(name)
        return tables[name] ?? t
    }
}

// MARK: - the swap

/// `BEGIN / DROP VIEW / ALTER TABLE RENAME / COMMIT` under the per-table lock, three attempts with
/// a `ROLLBACK` between. DuckDB DDL is transactional, so the swap is invisible to readers and the
/// user's typed SQL keeps working across it.
///
/// The retry is not decoration. MEASURED: with a second connection holding an open
/// `BEGIN; CREATE OR REPLACE VIEW t AS …`, an attempt fails immediately with
/// `TransactionContext Error: Catalog write-write conflict on alter with "…View…"`; the `ROLLBACK`
/// clears the failed transaction and the next attempt, once that transaction is gone, puts the
/// copy in place.
///
/// A free function rather than a `Session` method because it touches no session state — which also
/// makes the conflict above reproducible in a test without a live session, the thing review I2
/// showed was missing.
///
/// Synchronous on purpose: `lock` is an `NSLock`, and unlocking one from a different thread than
/// locked it is undefined — exactly what an `await` inside this scope could arrange. The 0.15 s
/// backoff is therefore `Thread.sleep`, on a task that has just spent seconds inside a blocking
/// CTAS on this same thread.
func swapStaged(_ con: Connection, name: String, lock: NSLock) throws {
    lock.lock()
    defer { lock.unlock() }

    var lastError: Error?
    for attempt in 0..<3 {
        do {
            for statement in swapSQL(table: name) { try con.execute(statement) }
            return
        } catch {
            lastError = error
            try? con.execute("ROLLBACK")
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
    }
    throw lastError ?? DuckDBError("could not swap \(stagingName(name)) into place")
}

// MARK: - what a staged copy is a copy OF

/// Bumped whenever `stagingToken`'s format changes, and the first field of every token, so a token
/// written by an older build can never compare equal to one written by this build. A copy whose
/// identity we can no longer interpret must never be adopted.
// The version constant moved to SiftCore (`Remote.swift`) the day remote tokens started sharing
// the prefix — one spelling, so the purge sweep and both token formats cannot drift apart.
// (`stagingTokenVersion` here now resolves to SiftCore's, via the module import.)

/// The identity a staged copy is matched on: the exact bytes it was made from.
///
/// **`SourceKey.token()` is not enough, and that was a Critical.** It is `path:mtimeNs:size` from a
/// single `stat()` of the path, which identifies neither of the two source shapes Sift supports:
///
/// - **A workbook sheet.** Every sheet of one `.xlsx` shares one path, mtime and size. REPRODUCED:
///   stage `Summary` (1 row, `metric`/`value`) as table `d`, close it, open `By Store` (50 rows,
///   `store`/`sales`) — the copy of Summary was adopted, and `page()` returned Summary's row under
///   By Store's headers. No explicit name is needed for the collision: `sanitizeTableName`
///   lowercases and collapses non-alphanumeric runs, so `Q1 2024` and `Q1-2024` derive the same
///   name on their own, and `openPath` tells the user to "use the sheet picker to open others".
/// - **A folder.** A directory's mtime and size change when an entry is added or removed and
///   **never** when a member file is rewritten in place. MEASURED: identical `stat` before and
///   after rewriting a member. REPRODUCED: the copy was adopted with the pre-edit values, and
///   `stagedEntries()` reported `sourceChanged: false` — the staleness sweep does the same
///   directory `stat`, so nothing collected it either. There was no path back to correct data
///   short of deleting `~/.sift`.
///
/// So the sheet joins the identity, and a directory's identity comes from its members' stats
/// rather than its own. What remains open is a file rewritten with an identical mtime AND size
/// (a restore that preserves timestamps): `adoptStagedCopy`'s column check is the backstop there,
/// and closing it completely would mean hashing the contents of a file that may be 30 GB.
///
/// ponytail: stats every member on every open of a folder source. The open itself reads those
/// files, so it is noise next to the parse — if a folder ever gets big enough for the walk to show
/// up, cache it against the directory's own mtime.
func stagingToken(_ spec: SourceSpec) -> String {
    var parts = [stagingTokenVersion, spec.key.path, String(spec.key.mtimeNs), String(spec.key.size)]
    if let ctime = try? statInfo(spec.key.path).ctimeNs { parts.append("ctime=\(ctime)") }
    if let sheet = spec.sheet, !sheet.isEmpty { parts.append("sheet=\(sheet)") }
    if let members = directoryDigest(spec.key.path) { parts.append("members=\(members)") }
    return parts.joined(separator: "|")
}

/// A digest of every file under `path`, or `nil` when `path` is not a directory.
private func directoryDigest(_ path: String) -> String? {
    var info = stat()
    guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
    guard let walker = FileManager.default.enumerator(atPath: path) else { return "unreadable" }

    var lines: [String] = []
    for case let entry as String in walker {
        guard let member = try? statInfo((path as NSString).appendingPathComponent(entry)) else {
            continue
        }
        lines.append("\(entry):\(member.mtimeNs):\(member.size):\(member.ctimeNs)")
    }
    return fnv1a(lines.sorted().joined(separator: "\n"))
}

/// FNV-1a, 64-bit. Not `Hasher`: this value is written to disk and compared on a later launch, and
/// `Hasher` is seeded per process, so it would never match itself twice. Not a cryptographic digest
/// either — nothing here is adversarial, the question is only "did these files change".
/// `String(_:radix:)` is locale-independent, unlike anything from `NumberFormatter`.
private func fnv1a(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}

// MARK: - results

/// One row of the `_sift_sources` catalog as the UI sees it. Named for what it is rather than
/// reusing `SiftCore.StagedEntry`, which is the smaller shape `selectForPurge` decides on.
public struct StagedSource: Sendable, Equatable {
    public let table: String
    public let path: String
    public let fmt: String
    public let stagedAt: Date
    public let lastUsed: Date
    public let rows: Int
    public let bytes: Int
    /// The source file is gone. The copy is kept — it may be all that is left of it.
    public let sourceMissing: Bool
    /// The source file's mtime or size no longer matches what was copied, so this copy is wrong.
    public let sourceChanged: Bool
}

public struct PurgeResult: Sendable, Equatable {
    public let dropped: [String]
    public let stagedBytes: Int
}

/// The two limits the purge is enforcing on this store right now — read from the environment
/// through `stageBudgetBytes()`/`stageMaxAgeDays()` below, so a `SIFT_STAGE_BUDGET_GB` override is
/// reflected rather than shadowed by a restated default.
///
/// `budgetBytes` rather than a `budgetGB`, even though the only consumer divides it back down:
/// bytes is what `selectForPurge` actually compares against, and a second unit in the type is a
/// second place for the conversion to drift. The UI does the division (exactly — the value is
/// always a whole number of GiB).
public struct StagePolicy: Sendable, Equatable {
    public let budgetBytes: Int
    public let maxAgeDays: Int

    public init(budgetBytes: Int, maxAgeDays: Int) {
        self.budgetBytes = budgetBytes
        self.maxAgeDays = maxAgeDays
    }
}

// MARK: - free helpers

/// `epoch_ms(...)` comes back as a BIGINT of milliseconds; `.null` (a catalog row written before
/// the column existed) reads as 1970, which sorts as "oldest" and is the safe direction for a
/// purge decision.
private func dateFromEpochMs(_ cell: Cell) -> Date {
    Date(timeIntervalSince1970: Double(cellInt(cell)) / 1000)
}

/// `SIFT_STAGE_BUDGET_GB`, ported from session.py:978. Unparseable input falls back to the
/// default rather than raising the way Python's bare `int()` would — an env var typo must not
/// stop the engine from starting.
///
/// Internal rather than `private` so `Session.stagePolicy()` can report it: the staged-data panel
/// has to state the numbers its own copy is governed by, and it must not read the environment a
/// second time to find them. One authority.
func stageBudgetBytes() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["SIFT_STAGE_BUDGET_GB"],
        let gb = Int(raw)
    else { return defaultBudgetBytes }
    return gb * 1024 * 1024 * 1024
}

/// `SIFT_STAGE_MAX_AGE_DAYS`, ported from session.py:979. Internal for the same reason as
/// `stageBudgetBytes` above.
func stageMaxAgeDays() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["SIFT_STAGE_MAX_AGE_DAYS"],
        let days = Int(raw)
    else { return defaultMaxAgeDays }
    return days
}
