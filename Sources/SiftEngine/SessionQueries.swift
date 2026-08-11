import DuckDBKit
import Foundation
import SiftCore

// The read side of the session: SQL mode, profiling, and the three panels (top-N/distinct,
// histogram, bad-rows), plus the small state-only operations around them. Ported from
// engine/session.py lines 542-780: `run_sql`, `exit_sql_mode`, `compute_profile`, `profile_of`,
// `distinct`, `histogram`, `sample_values`, `length_histogram`, `bad_rows`, `set_spec`,
// `rendered_sql`, `snippet`.
//
// Every SQL string and every piece of profiling math already exists in SiftCore — `topNSQL`,
// `distinctStatsSQL`, `histogramSQL`, `profileExtraSQL`, `uncastableSQL`, `badRowsSQL`,
// `renderSQL`, `wrapUserSQL`, `parseSummarize`, `clampDistinct`, `chooseView`,
// `wantsExactDistinct`, `buildProfile`, `histogramParams`, `numericBounds`,
// `looksLikeExcelSerialDates`, `snippet` — so this file is orchestration only: fetch a `Table`,
// build its relation, open a `Connection`, run the SQL SiftCore already generated, decode the
// `Cell`s the way the paging path already does, and persist whatever changed back into
// `Session.tables`.
//
// CONNECTION STRATEGY: unlike `page`/`sortedRelation`/`closeTable` (Session.swift's header, fact
// 3), nothing here touches the shared, actor-owned `pagingConnection` — every function opens its
// own throwaway `Connection` per call, exactly like `openPath`'s initial half and
// `runAfterOpen`'s background pipeline. There is no materialized-sort state here for a second
// connection to fail to see, so there is no reason to share one — and no need for the "never
// awaits inside" proof that makes sharing `pagingConnection` safe. Profiling goes one step
// further: its `Connection` is opened inside a detached `Task` (`runProfile`), because it is the
// one query pair here slow enough that running it on the actor froze paging — see
// `computeProfile`.
//
// DECLARATION STYLE: functions that open a `Connection` and run SQL are declared `async throws`,
// matching `page`'s own precedent (synchronous inside, `async` anyway for API consistency — see
// its doc comment). Functions that only read/write `Table` state, with no `Connection`, are
// declared plain `throws`, matching `table(_:)`. Either way every call from outside the actor
// needs `await` regardless of the callee's own `async` keyword — `table(_:)` is proof of that
// (SessionTests.swift calls it `try await session.table(name)`), so this split is a documentation
// choice, not a functional one.

extension Session {

    // MARK: - SQL mode

    /// Execute the SQL box's text and page the result. Ported from Python's `run_sql`.
    ///
    /// The guard runs FIRST, before `t` is even fetched — a rejected query never touches the
    /// table, matching Python's ordering exactly. `assertSelectOnly` exists only to turn a bad
    /// query into a sentence; the actual enforcement is `wrapUserSQL`'s newline subquery wrap,
    /// where a non-SELECT cannot occupy a subquery position and dies in DuckDB's own parser (see
    /// GuardStatements.swift's header). Do not reorder these two calls.
    public func runSQL(_ name: String, sql: String, offset: Int, limit: Int) async throws -> TablePage {
        try assertSelectOnly(sql)
        var t = try table(name)
        t.sqlMode = true
        t.sqlText = sql
        tables[name] = t

        let (wrapped, params) = wrapUserSQL(sql, limit: limit, offset: offset)
        do {
            let con = try database.connect()
            let started = DispatchTime.now()
            let rs = try con.query(wrapped, params.map(toDBValue))
            let fetched = try rs.allRows()
            let columns = rs.columns.map {
                TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
            }
            return TablePage(
                columns: columns, rows: fetched, offset: offset, limit: limit,
                milliseconds: millisecondsSince(started),
                // No filtered/unfiltered concept in raw SQL mode — Python's own payload omits
                // both keys here (`total={"value": None, "exact": False}`); `nil`/`false` are the
                // nearest Swift equivalents in a struct that must give every field a value.
                total: TablePage.Total(value: nil, exact: false, unfiltered: nil, filtered: false)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Ported from Python's `exit_sql_mode`.
    public func exitSQLMode(_ name: String) throws -> Table {
        var t = try table(name)
        t.sqlMode = false
        t.sqlText = nil
        tables[name] = t
        return t
    }

    // MARK: - profiling

    /// Compute (and cache) this table's per-column profile. Ported from Python's
    /// `compute_profile`.
    ///
    /// Reuses `Table.uncastable` — the full per-column result Task 4's `detectBadRows` cached at
    /// open — instead of re-running the all-varchar scan `uncastableSQL` represents. That scan
    /// reads every cell of every text column; running it twice per open is exactly the cost this
    /// cache exists to avoid.
    ///
    /// **The two queries run OFF the actor**, in a detached `Task` with its own `Connection`, the
    /// same shape as `runAfterOpen`/`runStage` — and this method then awaits that task, so the
    /// contract every caller already relies on is unchanged: it returns the profile, or throws.
    /// What changed is that awaiting suspends, which releases the actor: paging, a second open,
    /// and every `apply*` callback now run *during* a profile instead of behind it.
    ///
    /// MEASURED (`ProfileBenchTests.benchActorHoldDuringAProfile`, `SIFT_PROFILE_BENCH=1`), and the
    /// whole reason for the detour: run on the actor, the two queries below hold it for **6.4-7.4 s
    /// on a 200-column × 200,000-row table**, because nothing in them suspends — so the worst
    /// `table()` call during a profile measured **7228 ms**. Detached, the same probe measures
    /// 0.1 ms for `table()` and 181-266 ms for a real `page()`. (An earlier version of this comment
    /// claimed ~1.29 s: that number came from the DuckDB CLI and excluded chunk decoding, which is
    /// most of the cost. The bench is the number.) The UI kicks a profile as soon as the first page
    /// has rendered, so on a wide file that was the user's first scroll stalling for seconds — spec
    /// §13a's page-latency cliff in a second location.
    ///
    /// A caller that does NOT want to wait (the UI's speculative kick after the first page) wraps
    /// this in its own `Task` and never awaits it; the coalescing in `profileJob(for:)` means that
    /// kick and a panel's `profileOf` moments later share one `SUMMARIZE` rather than paying twice.
    ///
    /// **The loop is the awaited half of the generation guard, and it is not decoration.** `rel`
    /// (below, in `profileJob`) is a bare quoted NAME for a plain table — so the job's SQL is
    /// `SUMMARIZE "x"`, resolved when the query RUNS, not when it was launched. Detaching the work
    /// made a `closeTable` able to interleave, so a job launched for one file can execute against
    /// whatever was reopened under that name. `applyProfile` refuses such a result for the CACHE;
    /// nothing refused it for the RETURN VALUE, and REPRODUCED before this loop existed: a
    /// `profileOf` awaiting a 120 × 40,000 file's profile returned the 30-row file reopened under
    /// the same name (`n=30`), while the cache correctly held nothing. So the task's return value
    /// is never used here — `applyProfile` is the single authority on whether a result belongs to
    /// the table now open under this name, and this reads back only what it accepted. A caller
    /// whose table moved therefore gets the CURRENT table's profile (the panels ask by name; the
    /// name is the identity the whole engine uses), or a clean "no open table" error if it is gone.
    ///
    /// Bounded rather than `while true`: a normal profile costs two passes (compute, then read the
    /// cache), and every extra pass means a claim was revoked or the generation moved underneath
    /// this call — each of which has exactly one producer per event (`applyStaged`/`unstage`
    /// re-profile once, `openPath` bumps the generation once). Five is far past any real sequence
    /// of those, and an error beats spinning for a table someone is churning.
    public func computeProfile(_ name: String) async throws -> [ColumnProfile] {
        for _ in 0..<5 {
            let t = try table(name)
            if let profile = t.profile { return profile }
            do {
                _ = try await profileJob(for: t).value
            } catch {
                // A job that failed BECAUSE the table changed underneath it — its
                // `profileExtraSQL` names columns the relation no longer has — must not become the
                // caller's error: the table under this name is perfectly profilable, this job just
                // was not about it. Only a failure for the table still open is the caller's.
                guard tables[name]?.openedAt != t.openedAt else { throw error }
            }
        }
        throw SessionError("'\(name)' kept changing while its profile was being computed.")
    }

    /// The SPECULATIVE profile: compute one only if it is cheap enough to be worth doing unasked.
    /// Returns `false`, having done nothing, when it is not.
    ///
    /// 🔴 **This is the eager trigger from Python's `_after_open` (session.py:454), and it is the
    /// one step of that pipeline the port never carried over.** `runAfterOpen` stops at the
    /// staging decision, so nothing in the engine profiles on open — which left the kick, and with
    /// it the COST DECISION, to whoever called next. The UI plan's Task 5c kicks a profile after
    /// the first page **with no gate at all**, so the native app would `SUMMARIZE` a 30 GB CSV
    /// that Python deliberately skips: minutes of scan for a panel nobody has opened, on the same
    /// "a drive-by peek must not pay for the copy" principle `shouldStage`'s dwell enforces.
    ///
    /// **Why this is a public entry point rather than a line in `runAfterOpen`.** The engine has
    /// two consumers now, and Python had one. `sift <path>` never renders a profile — it prints a
    /// schema and a preview and shuts the session down — so an engine-side kick would make every
    /// CLI open pay for a `SUMMARIZE` whose result is discarded milliseconds later. And unlike the
    /// exact count and the bad-row scan, an eager profile is not a correctness step: it is latency
    /// work done on behalf of a UI that is about to ask. So the KICK stays with the caller that
    /// benefits, and the GATE comes here, where both consumers read the same policy
    /// (`SiftCore.shouldProfileEagerly`) instead of re-deriving it.
    ///
    /// **And a caller cannot get the gate wrong by forgetting it**, which is the part that
    /// mattered: the speculative path IS the gated one. A UI kick is
    /// `Task { try? await session.profileIfCheap(name) }` — there is no ungated speculative call
    /// to reach for. `computeProfile`/`profileOf` stay ungated on purpose, exactly as Python
    /// leaves `profile_of`: a user clicking a column on a 30 GB file is asking.
    @discardableResult
    public func profileIfCheap(_ name: String) async throws -> Bool {
        let t = try table(name)
        guard shouldProfileEagerly(fmt: t.spec.fmt, sizeBytes: t.spec.key.size, staged: t.staged)
        else { return false }
        _ = try await computeProfile(name)
        return true
    }

    /// The in-flight profile for this exact open of this table, started if there isn't one.
    ///
    /// Synchronous and actor-isolated on purpose: it publishes `profiling = true` and registers the
    /// job in one uninterrupted step, so by the time `computeProfile` suspends on the task, the
    /// flag is already visible to every other caller and a second caller can only ever find the
    /// job — never a window where neither is true.
    private func profileJob(for snapshot: Table) -> Task<[ColumnProfile], Error> {
        if let existing = profileJobs[snapshot.name], existing.openedAt == snapshot.openedAt {
            return existing.task
        }

        var t = snapshot
        // Published BEFORE the work starts, which is what finally makes `Table.profiling` a flag
        // anything can observe: while `computeProfile` ran on the actor it set the flag and cleared
        // it in a `defer` without ever suspending, so no other actor call could run in between and
        // `true` was unreachable by construction.
        t.profiling = true
        tables[t.name] = t

        let name = t.name
        let openedAt = t.openedAt
        let spec = t.spec
        let rel = relation(t)
        let uncastable = t.uncastable ?? [:]
        // This job's identity, and the only thing `applyProfile` accepts a result on. Issued here,
        // before the task exists, so the claim it registers below cannot be confused with a
        // replacement registered under the same `openedAt` after a revocation.
        nextProfileJobID += 1
        let jobID = nextProfileJobID
        // Everything the work needs is copied out here, as `Sendable` values. `Connection` is not
        // `Sendable` and is created inside the task, never handed to it — and emphatically not
        // `pagingConnection`, whose safety rests on every one of its users running to completion on
        // the actor without suspending (Session.swift's header, fact 3).
        let task = Task.detached { [self] in
            do {
                let profile = try runProfile(spec: spec, rel: rel, uncastable: uncastable)
                await applyProfile(name, profile, jobID: jobID, openedAt: openedAt)
                return profile
            } catch {
                await applyProfile(name, nil, jobID: jobID, openedAt: openedAt)
                throw error
            }
        }
        profileJobs[name] = (jobID, openedAt, task)
        return task
    }

    /// The two profiling queries, off the actor on their own `Connection`. Ported verbatim from the
    /// body `computeProfile` used to run inline; `nonisolated` and taking only `Sendable` values so
    /// the detached task can run it without an actor hop, matching `runAfterOpen`'s helpers.
    nonisolated func runProfile(
        spec: SourceSpec, rel: String, uncastable: [String: Int]
    ) throws -> [ColumnProfile] {
        do {
            let con = try database.connect()

            let summRS = try con.query("SUMMARIZE \(rel)")
            let summRows = try summRS.allRows()
            let summ = parseSummarize(
                columnNames: summRS.columns.map(\.name),
                // Profile.swift's own signature note: `cell.isNull ? nil : cell.display`
                // round-trips a SUMMARIZE cell exactly, since SUMMARIZE returns min/max/quantiles
                // as VARCHAR precisely so heterogeneous columns share one result shape.
                rows: summRows.map { row in row.map { $0.isNull ? nil : $0.display } }
            )

            let extraRS = try con.query(profileExtraSQL(rel, spec.columns))
            let extraRow = try extraRS.allRows()[0]
            var extra: [String: Int] = [:]
            for (i, meta) in extraRS.columns.enumerated() { extra[meta.name] = cellInt(extraRow[i]) }

            return buildProfile(
                cols: spec.columns, summ: summ, extra: extra, uncastable: uncastable,
                nRows: extra["n"]
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Land a finished profile on the open table — or, with `profile: nil`, record that the job
    /// ended without one. The `applyCount`/`applyBadRows`/`applyStaged` shape, `Int?`-optional
    /// argument included, for the same reason they have it: a background result is applied by a
    /// small, fast, actor-isolated method, never by the background task itself.
    ///
    /// **Two independent guards, and they reject different things — see `Session.profileJobs`.**
    ///
    /// 1. `profileJobs[name]?.id == jobID` — *this* job still holds the claim. `applyStaged` and
    ///    `unstage` revoke a job by dropping the entry, because the copy they just published means
    ///    a profile computed against what the name USED to point at is no longer about this table.
    ///    Compared on the job's ID, never on its generation: revocation does not reopen the table,
    ///    so the replacement registers under the same `openedAt` and a generation comparison
    ///    accepted the revoked result AND deleted the replacement's claim, permanently caching the
    ///    stale profile it was supposed to reject.
    /// 2. `t.openedAt == openedAt` — the table has not been closed and reopened under this name.
    ///    Reachable independently of (1) precisely because `closeTable` does NOT clear
    ///    `profileJobs`: the old job is still the claim holder afterwards, so (1) waves it through
    ///    and only this rejects it. This is the profile-shaped form of a bug this branch has
    ///    already shipped once — a background row count applied by table NAME reported 3,000,000
    ///    rows for a 10-row file.
    ///
    /// `profiling` stays `true` on a dropped result on purpose: every caller of `computeProfile`
    /// retries against the current table when its result was dropped, so the flag reads as "a
    /// profile is still owed", and the replacement job clears it.
    func applyProfile(_ name: String, _ profile: [ColumnProfile]?, jobID: Int, openedAt: Int) {
        guard profileJobs[name]?.id == jobID else { return }
        profileJobs.removeValue(forKey: name)
        guard var t = tables[name], t.openedAt == openedAt else { return }

        t.profiling = false
        if let profile {
            t.profile = profile
            for p in profile where looksLikeExcelSerialDates(p) && t.spec.fmt == .xlsx {
                t.notes.append(
                    "\u{201C}\(p.name)\u{201D} looks like Excel serial dates read as numbers "
                        + "(\(p.minS ?? "")\u{2013}\(p.maxS ?? ""))"
                )
            }
        }
        tables[name] = t
    }

    /// Ported from Python's `profile_of`.
    ///
    /// Awaits the profile — it does not kick one and return a partial answer. That is the only
    /// coherent contract for its three callers: `distinct` seeds `wantsExactDistinct` from
    /// `approxDistinct` and would silently take the approximate branch for a table it was about to
    /// learn is small; `histogram` derives its bin bounds from `numericBounds(p)` and has no
    /// histogram at all without them; and the Column panel exists to display these numbers. A
    /// "come back later" result would mean every one of them re-asking on a timer. What the detach
    /// buys them is that the wait is now a suspension rather than a held actor, so the grid keeps
    /// paging while a panel is loading.
    public func profileOf(_ name: String, col: String) async throws -> ColumnProfile {
        let profile = try await computeProfile(name)
        guard let match = profile.first(where: { $0.name == col }) else {
            throw SessionError("No column '\(col)' in \(name).")
        }
        return match
    }

    // MARK: - distinct panel

    /// Ported from Python's `distinct`.
    ///
    /// The `profileOf` call in the middle of this method is now a real suspension point (see
    /// `computeProfile`), so `cols`, `rel` and `facet` — all read before it — are a snapshot: a
    /// `setSpec` landing during the wait produces a panel built against the spec that was current
    /// when the user clicked. That is the same staleness Python had by construction (its panels ran
    /// in a threadpool while the filters could change underneath), and the UI re-requests panels
    /// after a spec change anyway. Worth knowing rather than worth fixing.
    public func distinct(
        _ name: String, col: String, limit: Int = 200, search: String? = nil
    ) async throws -> DistinctPanel {
        // Set unconditionally, even if `col` turns out not to exist below — matches Python, which
        // mutates the live `Table` before the column check ever runs.
        var t = try table(name)
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t

        let cols = t.cols
        guard let column = cols[col] else { throw SessionError("No column '\(col)' in \(name).") }

        // Faceting: this column's own filters are dropped so every value stays visible with the
        // selected ones highlighted — clicking "West" must not make the region panel show only
        // West. `selectedValues` below, by contrast, reads the UNFACETED filters on purpose: a
        // selected value must still highlight even though its own filter was just dropped from
        // the query that fetches the row list.
        let facet = t.qspec.withoutColumn(col).filters
        let rel = relation(t)
        do {
            let con = try database.connect()
            let started = DispatchTime.now()
            let (sql, params) = try topNSQL(rel, col, cols: cols, filters: facet, limit: limit, search: search)
            let rows = try con.query(sql, params.map(toDBValue)).allRows()

            // 🔴 NOT `try?`, and that is a fix rather than a divergence. Python's bare
            // `except Exception: pass` here means "a table whose profile fails still renders the
            // panel" — a fine intention that produced the worst message in the engine. Closing a
            // tab while this panel loads makes `profileOf` throw the clean
            // `No open table named 'x'.`; swallowing it left the very next statement querying a
            // relation `closeTable` had just dropped, so the user got
            // `Catalog Error: Table with name x does not exist!` for closing a tab. `histogram`
            // lets the identical call propagate (see its own note) and reports the sentence; this
            // now matches it. Nothing is lost: the case Python's `except` was protecting — a
            // profile that fails while the table is still open — is precisely the case where the
            // stats query below is about to fail too, and `computeProfile` already refuses to hand
            // a caller an error that belonged to a different open of this name.
            let p = try await profileOf(name, col: col)
            let approx = p.approxDistinct
            let (statsSQL, statsParams) = try distinctStatsSQL(
                rel, col, cols: cols, filters: facet, exact: wantsExactDistinct(approx)
            )
            let statsRS = try con.query(statsSQL, statsParams.map(toDBValue))
            let statsRow = try statsRS.allRows()[0]
            var stats: [String: Cell] = [:]
            for (i, meta) in statsRS.columns.enumerated() { stats[meta.name] = statsRow[i] }

            let selectedValues: [SQLValue] = t.qspec.filters
                .filter { $0.col == col && ($0.op == .eq || $0.op == .inList) }
                .flatMap(\.values)

            let values: [DistinctPanel.Value] = rows.map { row in
                let value = row[1]
                return DistinctPanel.Value(
                    label: panelLabel(row[0]), value: value, n: cellInt(row[2]), frac: cellDouble(row[3]),
                    selected: selectedValues.contains { cellEquals(value, $0) }
                )
            }
            let nRows = cellInt(stats["n_rows"] ?? .int(0))
            let shown = values.reduce(0) { $0 + $1.n }
            let nDistinct: Int
            let exact: Bool
            if let exactCell = stats["n_distinct_exact"] {
                exact = true
                nDistinct = cellInt(exactCell)
            } else {
                exact = false
                nDistinct = clampDistinct(cellInt(stats["n_distinct_approx"] ?? .int(0)), nRows)
            }

            return DistinctPanel(
                mode: p.view, col: col, type: column.type, kind: column.kind,
                nRows: nRows, nNonnull: cellInt(stats["n_nonnull"] ?? .int(0)),
                nDistinct: .init(value: nDistinct, exact: exact),
                values: values, otherN: max(0, nRows - shown), shown: values.count,
                milliseconds: millisecondsSince(started)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - histogram panel

    /// Ported from Python's `histogram`.
    public func histogram(_ name: String, col: String, bins: Int = 40) async throws -> HistogramPanel {
        var t = try table(name)
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t

        let cols = t.cols
        guard let column = cols[col] else { throw SessionError("No column '\(col)' in \(name).") }
        // NOT swallowed, unlike `distinct`'s own `profileOf` call above — Python leaves this one
        // to propagate; it runs before the `try`/`except duckdb.Error` block even starts. Same
        // snapshot caveat as `distinct`: this awaits a profile that now runs off the actor, and
        // `t`/`cols` were read before it.
        let p = try await profileOf(name, col: col)
        let rel = relation(t)

        do {
            let con = try database.connect()
            let bounds: (lo: Double, hi: Double)?
            if column.kind == .temporal {
                let row = try con.query(
                    "SELECT min(epoch_ms(\(q(col))))::DOUBLE, max(epoch_ms(\(q(col))))::DOUBLE FROM \(rel)"
                ).allRows()[0]
                bounds = row[0].isNull ? nil : (cellDouble(row[0]), cellDouble(row[1]))
            } else {
                bounds = numericBounds(p)
            }
            guard let params = histogramParams(lo: bounds?.lo, hi: bounds?.hi, bins: bins) else {
                return HistogramPanel(
                    col: col, kind: nil, lo: nil, step: nil, bins: nil, nNull: p.nNull, buckets: [],
                    degenerate: true, reason: "every value is the same, or the range is empty",
                    milliseconds: nil
                )
            }

            let facet = t.qspec.withoutColumn(col).filters
            let (sql, sqlParams) = try histogramSQL(
                rel, col, cols: cols, lo: params.lo, step: params.step, bins: params.bins, filters: facet
            )
            let started = DispatchTime.now()
            let rows = try con.query(sql, sqlParams.map(toDBValue)).allRows()
            let buckets = rows.map { row -> HistogramPanel.Bucket in
                let b = cellInt(row[0])
                return HistogramPanel.Bucket(
                    b: b, lo: params.lo + params.step * Double(b), hi: params.lo + params.step * Double(b + 1),
                    n: cellInt(row[1]), bMin: row[2], bMax: row[3]
                )
            }
            return HistogramPanel(
                col: col, kind: column.kind, lo: params.lo, step: params.step, bins: params.bins,
                nNull: p.nNull, buckets: buckets, degenerate: false, reason: nil,
                milliseconds: millisecondsSince(started)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - the smaller panels

    /// A random-ish sample, for the high-cardinality panel where top-N says nothing. Ported from
    /// Python's `sample_values`. Query failures are swallowed — the same `try/except
    /// duckdb.Error: return []` as Python, since this is a nice-to-have panel, not a correctness
    /// path — but a missing table still throws, since Python's own `t = self.table(name)` runs
    /// outside that try.
    public func sampleValues(_ name: String, col: String, limit: Int = 20) async throws -> [Cell] {
        let t = try table(name)
        let rel = relation(t)
        guard let con = try? database.connect(),
            let rows = try? con.query("SELECT \(q(col)) FROM \(rel) USING SAMPLE \(limit) ROWS"),
            let fetched = try? rows.allRows()
        else { return [] }
        return fetched.map { $0[0] }
    }

    /// Ported from Python's `length_histogram`. Same error-swallowing contract as `sampleValues`.
    public func lengthHistogram(_ name: String, col: String, bins: Int = 24) async throws -> [LengthBucket] {
        let t = try table(name)
        let rel = relation(t)
        let sql = "SELECT length(CAST(\(q(col)) AS VARCHAR)) AS len, count(*) AS n "
            + "FROM \(rel) WHERE \(q(col)) IS NOT NULL GROUP BY len ORDER BY len LIMIT \(bins)"
        guard let con = try? database.connect(), let rows = try? con.query(sql),
            let fetched = try? rows.allRows()
        else { return [] }
        return fetched.map { LengthBucket(len: cellInt($0[0]), n: cellInt($0[1])) }
    }

    /// The rows containing uncastable cells, for the "rows your file lost" panel. Ported from
    /// Python's `bad_rows`. `bad_columns` (`data[i][0]`) decodes as `Cell.list` — Task 1 closed
    /// the DuckDBKit gap that made this possible, and consuming it here (rather than a joined
    /// string) is the entire reason that gap was closed: the UI highlights individual cells, not
    /// just the row.
    ///
    /// **Reversed in the whole-plan review, and the reversal is the interesting part.** An earlier
    /// comment here said query failures were deliberately NOT converted to `SessionError`, because
    /// Python's `bad_rows` has no `try/except duckdb.Error` either — "a behavioral port, not a
    /// correctness upgrade Python itself never made". That reasoning loses: this panel reads the
    /// file through its all-varchar expression rather than through the view, so a source deleted
    /// while its tab is open (anyone with `rm`, or a synced folder) fails right here, and the user
    /// got `IO Error: No files found that match the pattern …` with a Foundation dump around it.
    /// The "one clean sentence" contract is a product rule, not a Python behavior to preserve, and
    /// every other public method in this file already holds it. `UnsafeTypeName`/`UnknownColumn`
    /// from `badRowsSQL` still propagate as themselves — they are already `SiftError`s.
    public func badRows(_ name: String, limit: Int = 200) async throws -> BadRowsPanel {
        let t = try table(name)
        guard let raw = rawRelation(t), t.badCells > 0 else {
            return BadRowsPanel(cells: t.badCells, rows: t.badRows, columns: [], data: [])
        }
        let (sql, params) = try badRowsSQL(raw, t.spec.columns, limit: limit)
        do {
            let con = try database.connect()
            let rs = try con.query(sql, params.map(toDBValue))
            let fetched = try rs.allRows()
            let columns = rs.columns.map {
                TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
            }
            return BadRowsPanel(cells: t.badCells, rows: t.badRows, columns: columns, data: fetched)
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - filters / sort

    /// Replace the table's query spec, after validating every filter/sort column actually exists
    /// — a typo becomes a clean `SessionError`, not a binder dump. Ported from Python's
    /// `set_spec`.
    ///
    /// Resets `filteredCount` to `nil` so the next `page()` recounts — the invalidation half of
    /// Task 4's `pageCountsTheFilteredRelationOncePerSpecChangeNotPerPage`, which guards that the
    /// count STAYS cached across pages of the same spec; this is what makes it re-derive once the
    /// spec actually changes.
    public func setSpec(_ name: String, filters: [Filter], sort: [QuerySpec.SortTerm]) throws -> Table {
        var t = try table(name)
        let cols = t.cols
        for f in filters {
            guard cols[f.col] != nil else { throw SessionError("No column '\(f.col)' in \(name).") }
        }
        for s in sort {
            guard cols[s.column] != nil else { throw SessionError("No column '\(s.column)' in \(name).") }
        }
        t.qspec = QuerySpec(relation: t.name, filters: filters, sort: sort)
        t.filteredCount = nil
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t
        return t
    }

    /// Ported from Python's `rendered_sql`.
    public func renderedSQL(_ name: String) throws -> String {
        let t = try table(name)
        if t.sqlMode, let text = t.sqlText { return text }
        return renderSQL(t.qspec, cols: t.cols)
    }

    /// Ported from Python's `snippet`. Calls through `SiftCore.snippet` (module-qualified): an
    /// unqualified call from inside a method of the same name would recurse into itself instead
    /// of reaching SiftCore's free function.
    public func snippet(_ name: String, dialect: String) throws -> String {
        let t = try table(name)
        return try SiftCore.snippet(
            dialect: dialect, source: t.spec, spec: t.qspec, cols: t.cols,
            sqlOverride: t.sqlMode ? t.sqlText : nil
        )
    }
}

// MARK: - panel result types
//
// No JSON wire format exists anymore (Table.swift's header makes the same call for `summary()`),
// so these carry `Cell`/`SQLValue` directly rather than Python's `jsonable`-flattened `dict`.

public struct DistinctPanel: Sendable {
    public struct Value: Sendable {
        public let label: String
        public let value: Cell
        public let n: Int
        public let frac: Double
        public let selected: Bool
    }
    public struct DistinctCount: Sendable {
        public let value: Int
        public let exact: Bool
    }

    public let mode: ColumnProfile.View
    public let col: String
    public let type: String
    public let kind: Kind
    public let nRows: Int
    public let nNonnull: Int
    public let nDistinct: DistinctCount
    public let values: [Value]
    public let otherN: Int
    public let shown: Int
    public let milliseconds: Double
}

public struct HistogramPanel: Sendable {
    public struct Bucket: Sendable {
        public let b: Int
        public let lo: Double
        public let hi: Double
        public let n: Int
        public let bMin: Cell
        public let bMax: Cell
    }

    public let col: String
    /// `nil` only in the degenerate case, matching Python's dict, which simply omits the key.
    public let kind: Kind?
    public let lo: Double?
    public let step: Double?
    public let bins: Int?
    public let nNull: Int
    public let buckets: [Bucket]
    public let degenerate: Bool
    public let reason: String?
    public let milliseconds: Double?
}

public struct LengthBucket: Sendable, Equatable {
    public let len: Int
    public let n: Int
}

public struct BadRowsPanel: Sendable {
    public let cells: Int
    public let rows: Int
    public let columns: [TablePage.ColumnInfo]
    public let data: [[Cell]]
}

// MARK: - small Cell helpers local to this file
//
// `toDBValue`/`cellInt` (the SQLValue<->DBValue mapping, and Cell->Int for every count(*)-shaped
// result above) already exist in Session.swift, widened from `private` to internal so every file
// in this module shares one copy of each rather than a second copy that could silently drift —
// this branch has already ruled against exactly that duplication twice (Plan 2 Task 4's `col`/
// `asText`, Plan 2 Task 10's `grouped`), and both of these are decoders: drift changes a parsed
// value, not a format. `cellText`/`cellDouble`/`cellEquals` below have no equivalent elsewhere
// yet — same "swallow instead of throw" contract as SiftCore.Profile's looseInt/looseFloat: a
// shape a query should never actually produce degrades rather than throws.

/// The distinct panel's row label. Named `panelLabel`, not `cellText`, only because SourceProbe's
/// deliberately different `cellText` (strict: anything not `.text` reads as `""`) had to widen to
/// internal for Staging.swift, and two same-named top-level functions in one module collide even
/// when one is `private`. The pair stays two functions — Task 5's review looked at them and ruled
/// them genuinely different, unlike `cellInt`'s four copies: this one falls back to `display`
/// because a top-N label is a glyph, while the other one's result decides whether a file is
/// purged.
private func panelLabel(_ cell: Cell) -> String {
    if case .text(let s) = cell { return s }
    return cell.display
}

private func cellDouble(_ cell: Cell) -> Double {
    switch cell {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return 0
    }
}

/// Python's `r[1] in selected` compares two values of the SAME dynamic type (both raw DB values).
/// Swift keeps them as two different types — `Cell`, decoded from the topN query, and `SQLValue`,
/// bound into a filter — so this is the equality between them. The int/double cross-case matches
/// Python's own numeric equality (`5 == 5.0` is `True` there too).
private func cellEquals(_ cell: Cell, _ value: SQLValue) -> Bool {
    switch (cell, value) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.text(let a), .text(let b)): return a == b
    case (.int(let a), .double(let b)): return Double(a) == b
    case (.double(let a), .int(let b)): return a == Double(b)
    default: return false
    }
}

/// Elapsed milliseconds since `started`, rounded to one decimal place — matches every `round(...,
/// 1)` call in Python's own `time.perf_counter()` timings.
///
/// Not `private`: Export.swift times its COPY the same way and shares this rather than keeping a
/// second copy of the same rounding, on the same grounds as `cellInt`/`toDBValue` above.
func millisecondsSince(_ started: DispatchTime) -> Double {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    return (elapsed * 10).rounded() / 10
}
