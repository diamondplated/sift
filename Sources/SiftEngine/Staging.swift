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
// safe as a single long-lived non-`Sendable` connection only because every one of its users runs
// to completion on the actor's serial executor without suspending (Session.swift's header, fact
// 3), and a multi-second CTAS on it would both break that proof and freeze every page request
// behind it. The two places below that DO touch `pagingConnection` (`applyStaged`, `unstage`)
// only drop a materialized-sort TEMP TABLE, which is visible ONLY to the connection that created
// it, and they do it synchronously with no `await` in between.

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

    /// Hand the job the connection its CTAS runs on. Called once, before the CTAS starts.
    func attach(_ connection: Connection) {
        lock.withLock { self.connection = connection }
    }

    /// Set the cancel flag and start re-asserting the interrupt until the window closes.
    ///
    /// A real `Thread`, not a `Task`: this loop is a spin with a 0.2 ms pause, and parking a
    /// cooperative-pool thread on it would starve the very actor the job has to call back into.
    /// Starting even when no connection is attached yet is deliberate — `cancel` can be called
    /// with the job id `stageNow` just returned, microseconds before the detached task has
    /// connected, and the loop simply hammers nothing until it has.
    func requestCancel() {
        lock.lock()
        cancelled = true
        let start = windowOpen && !hammering
        if start { hammering = true }
        lock.unlock()
        guard start else { return }

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
            jobID: jobID, state: "running", pct: 0,
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
        job.requestCancel()
        return true
    }

    // MARK: - running one job

    /// The CTAS, the swap, and the bookkeeping. Ported from Python's `_do_stage`.
    ///
    /// `nonisolated` with its own `Connection`, matching `runAfterOpen`: the copy takes seconds
    /// and must not run on the actor. Every mutation of the catalog goes through a small isolated
    /// `apply*`/`finishStage` call carrying `openedAt`, so a job whose table was closed (or closed
    /// and reopened) mid-copy cannot write onto the table that now holds its name.
    nonisolated func runStage(
        name: String, spec: SourceSpec, jobID: String, job: StageJob, openedAt: Int
    ) async {
        let con: Connection
        do {
            con = try database.connect()
        } catch {
            await finishStage(name, jobID: jobID, openedAt: openedAt, error: "staging failed: \(error)")
            return
        }
        job.attach(con)

        // CHECKPOINT before measuring as well as after: `bytes` is the growth of the store across
        // this CTAS, and an unflushed WAL on either side makes the delta meaningless. (Python only
        // checkpoints at the end.) DuckDB exposes no per-table size — `duckdb_tables.estimated_size`
        // is estimated *rows*, and produced a literal "3,000,048 B" reading for a 3M-row table
        // until it was caught; DuckDB155FactsTests' fact9 pins that.
        try? con.execute("CHECKPOINT")
        let before = dbBytes()

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

        switch await applyStaged(name, physicalRows: physical, openedAt: openedAt, jobID: jobID) {
        case .applied(let rowCount):
            try? con.execute("CHECKPOINT")   // flush the WAL so the size delta is meaningful
            try? recordStaged(
                con, spec: spec, table: name, rowCount: rowCount, bytes: dbBytes() - before
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
            // catalog back the way the live table expects to find it.
            try? con.execute("DROP TABLE IF EXISTS \(q(name))")
            if let replacement {
                try? con.execute(createViewSQL(name: name, spec: replacement))
            }
        }
    }

    /// `BEGIN / DROP VIEW / ALTER TABLE RENAME / COMMIT` under the per-table lock, three attempts
    /// with a `ROLLBACK` between. DuckDB DDL is transactional, so the swap is invisible to
    /// readers and the user's typed SQL keeps working across it.
    ///
    /// Synchronous on purpose: `lock` is an `NSLock`, and unlocking one from a different thread
    /// than locked it is undefined — which is exactly what an `await` inside this scope could
    /// arrange. The 0.15 s backoff is therefore `Thread.sleep`, on a task that has just spent
    /// seconds inside a blocking CTAS on this same thread.
    private nonisolated func swapStaged(_ con: Connection, name: String, lock: NSLock) throws {
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
        guard var t = tables[name], t.openedAt == openedAt else { return }
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
                .text(spec.key.token()), .text(spec.key.path), .int(Int64(spec.key.mtimeNs)),
                .int(Int64(spec.key.size)), .text(table), .text(spec.fmt.rawValue),
                .int(Int64(rowCount)), .int(Int64(max(0, bytes))),
            ]
        )
    }

    // MARK: - the staged-data lifecycle

    /// Every staged copy this store knows about, newest use first. Ported from `staged_entries`.
    public func stagedEntries() throws -> [StagedSource] {
        let con = try database.connect()
        let rows = try con.query(
            "SELECT table_name, path, fmt, epoch_ms(staged_at::TIMESTAMPTZ), "
                + "epoch_ms(last_used::TIMESTAMPTZ), row_count, bytes, mtime_ns, size "
                + "FROM _sift_sources ORDER BY last_used DESC"
        ).allRows()

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

    /// Drop staged tables — explicitly, by age, or under size pressure. Ported from `purge_staged`.
    ///
    /// Python's `reason` argument only ever fed a log line and an SSE event, neither of which
    /// exists here, so it is not ported.
    @discardableResult
    public func purgeStaged(tables names: [String]? = nil, all: Bool = false) throws -> PurgeResult {
        let con = try database.connect()
        let dropped = try Self.purgeStagedTables(
            con, open: Set(tables.keys), tables: names, all: all
        )
        return PurgeResult(dropped: dropped, stagedBytes: dbBytes())
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
            try con.execute("DROP TABLE IF EXISTS \(q(name))")
            _ = try con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(name)])
            dropped.append(name)
        }
        return dropped
    }

    /// Drop a staged table and go back to reading the source in place. Ported from `unstage`.
    @discardableResult
    public func unstage(_ name: String) async throws -> Table {
        var t = try table(name)
        guard t.staged else { return t }

        let con = try database.connect()
        try con.execute("DROP TABLE IF EXISTS \(q(t.name))")
        try con.execute(createViewSQL(name: t.name, spec: t.spec))
        _ = try con.query("DELETE FROM _sift_sources WHERE table_name = ?", [.text(t.name)])

        t.staged = false
        if let key = t.sortKey {
            // Same reasoning as `applyStaged`: dropped, not merely forgotten, and safe on
            // `pagingConnection` because nothing suspends between here and the write below.
            try? pagingConnection.execute("DROP TABLE IF EXISTS \(q(key))")
            t.sortKey = nil
        }
        t.profile = nil
        tables[name] = t

        _ = try await computeProfile(name)
        return tables[name] ?? t
    }
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
private func stageBudgetBytes() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["SIFT_STAGE_BUDGET_GB"],
        let gb = Int(raw)
    else { return defaultBudgetBytes }
    return gb * 1024 * 1024 * 1024
}

/// `SIFT_STAGE_MAX_AGE_DAYS`, ported from session.py:979.
private func stageMaxAgeDays() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["SIFT_STAGE_MAX_AGE_DAYS"],
        let days = Int(raw)
    else { return defaultMaxAgeDays }
    return days
}
