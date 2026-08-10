import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Staging and the staged-data lifecycle. session.py has no `engine/tests/test_staging.py` to port
// assertion-for-assertion — none of this was ever covered in Python — so these are the Task 6
// brief's own required scenarios: the cancel hammer (and the single-shot interrupt it replaces),
// staging as the SECOND step (dwell and aggregate), the row-count-plus-bad-rows rule, byte
// accounting measured as store growth, the purge policy including the open-tab rule, and unstage.
//
// Each test gets its own `~/.sift`-equivalent temp directory, never the real one, for the reason
// SessionTests.swift states: Swift Testing runs in parallel and DuckDB takes an exclusive lock on
// the store file. Nothing here is `.serialized`.

private func newSession() throws -> Session {
    try Session(
        home: FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-staging-tests-\(UUID().uuidString)").path
    )
}

private func newTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-staging-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - fixtures

/// A CSV comfortably over `stageMinBytes` (25 MB), so the real policy — not `force:` — is what
/// decides to stage it. Built once for the whole suite: ~30 MB written per test would dominate
/// the run, and every test that reads it only reads.
private let bigCSVRows = 300_000
// `try!`, matching SessionTests' `try! corpus()`: a fixture that cannot even be written is not a
// per-test failure this suite can report meaningfully.
private let bigCSV: String = try! makeBigCSV()

private func makeBigCSV() throws -> String {
    let path = (try newTempDir() as NSString).appendingPathComponent("big.csv")
    let regions = ["West", "Midwest", "South", "Northeast"]
    let padding = String(repeating: "x", count: 64)   // ~100 B/row: 300k rows ≈ 30 MB
    var text = "order_id,region,amount,note\n"
    text.reserveCapacity(32 * 1024 * 1024)
    for i in 0..<bigCSVRows {
        text += "\(i),\(regions[i % 4]),\(i).50,note \(i) \(padding)\n"
    }
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// A small CSV in its own directory, so a test can modify or delete it without disturbing others.
private func makeSmallCSV(rows: Int = 200) throws -> String {
    try makeCSV(dir: try newTempDir(), name: "small.csv", rows: rows)
}

// MARK: - waiting

/// Polls the catalog for a condition instead of sleeping a fixed interval — the background work
/// here is a real CTAS whose duration depends on the machine.
@discardableResult
private func waitFor(
    _ session: Session, _ name: String, timeout: TimeInterval = 120,
    _ label: String, until done: @Sendable (Table) -> Bool
) async throws -> Table {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let t = try await session.table(name)
        if done(t) { return t }
        if Date() > deadline {
            let state = "staged=\(t.staged) staging=\(String(describing: t.staging)) "
                + "error=\(String(describing: t.stagingError))"
            Issue.record("timed out after \(timeout)s waiting for \(label) on \(name): \(state)")
            return t
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@discardableResult
private func waitForStaged(_ session: Session, _ name: String) async throws -> Table {
    try await waitFor(session, name, "the copy to be published") { $0.staged && $0.staging == nil }
}

@discardableResult
private func waitForCatalog(_ session: Session, count: Int) async throws -> [StagedSource] {
    let deadline = Date().addingTimeInterval(120)
    while true {
        let entries = try await session.stagedEntries()
        if entries.count == count { return entries }
        if Date() > deadline {
            Issue.record("timed out waiting for \(count) catalog row(s); saw \(entries.count)")
            return entries
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Ask the session's own store a question through the public SQL path — the only way to see the
/// DuckDB catalog from outside the actor, since the store file is exclusively locked by it.
/// `exitSQLMode` afterwards leaves the table exactly as it was found.
private func introspect(_ session: Session, table: String, _ sql: String) async throws -> [[Cell]] {
    let page = try await session.runSQL(table, sql: sql, offset: 0, limit: 1000)
    _ = try await session.exitSQLMode(table)
    return page.rows
}

/// 1 if `name` is a real table in the store, 0 if it is a view (or absent) — the difference
/// staging exists to make.
private func isNativeTable(_ session: Session, _ probe: String, _ name: String) async throws -> Int {
    let rows = try await introspect(
        session, table: probe,
        "SELECT count(*) FROM duckdb_tables() WHERE table_name = '\(name)'"
    )
    guard case .int(let n) = rows[0][0] else { Issue.record("expected an integer"); return -1 }
    return Int(n)
}

// MARK: - 🔴 the cancel hammer

@Test func aSingleInterruptIsSwallowedButAStageJobsHammeringIsNot() throws {
    // The landmine, both halves, against the real library. MEASURED (Plan 1, re-confirmed here):
    // `duckdb_interrupt` issued BEFORE execution begins is swallowed — the flag is cleared as
    // execution starts — so Python's single `con.interrupt()` in `cancel` does not port. This is
    // the test that fails if `StageJob.requestCancel` is ever simplified back to one shot.
    let con = try Database.inMemory().connect()
    // ~1 s unimpeded (MEASURED: 0.19 s per 1e8 rows), three orders of magnitude wider than the
    // 0.000-0.002 s the hammer needs, and short enough not to dominate the suite.
    let slow = "SELECT count(*) FROM range(500000000) t(i) WHERE i % 7 = 3"

    con.interrupt()                          // single shot, fired before the query starts
    let survived = try con.query(slow).allRows()
    #expect(survived.count == 1, "a single pre-execution interrupt must be shown insufficient")

    // Same connection, same query, cancelled the way a staging job is cancelled.
    let job = StageJob()
    job.attach(con)
    job.requestCancel()
    #expect(job.isCancelled)

    var message = ""
    do {
        _ = try con.query(slow).allRows()
        Issue.record("the query ran to completion despite the hammered interrupt")
    } catch let error as DuckDBError {
        message = error.message
    }
    #expect(message.contains("INTERRUPT"), "expected an interrupt error; got: \(message)")

    // The window closes, and after it does the connection is usable again — which is what stops a
    // hammer in flight from killing the swap, the count and the CHECKPOINT that follow a real
    // CTAS. Re-running the SLOW query, not a `SELECT 1`: a fast query slips between two hammers
    // often enough that it passes even when the window never closes at all (MEASURED — that was
    // this assertion's first form, and making `closeInterruptWindow` a no-op left it green).
    job.closeInterruptWindow()
    let recovered = try con.query(slow).allRows()
    #expect(recovered.count == 1, "the hammer must stop when the window closes, not keep firing")
}

@Test func cancellingAStagingJobLeavesNoCopyAndNoCatalogRow() async throws {
    let session = try newSession()
    await session.setStageDwellForTest(3600)     // only the explicit job below may run
    let t = try await session.openPath(bigCSV)

    let jobID = try await session.stageNow(t.name)
    #expect(jobID != nil, "a 30 MB CSV is over the threshold, so no force should be needed")
    #expect(await session.cancel(jobID!) == true)

    let after = try await waitFor(session, t.name, "the job to clear") { $0.staging == nil }
    #expect(after.staged == false)
    #expect(after.stagingError == nil, "a cancel is not a failure — the user asked for it")
    #expect(try await session.stagedEntries().isEmpty)
    #expect(try await isNativeTable(session, t.name, t.name) == 0, "the view must still be a view")
    #expect(try await isNativeTable(session, t.name, stagingName(t.name)) == 0,
            "the half-built copy must be dropped, not left behind")
}

@Test func cancelIsFalseForAJobThatIsNotRunning() async throws {
    let session = try newSession()
    #expect(await session.cancel("stage-999") == false)
}

// MARK: - staging is the SECOND step, never the first

@Test func theDwellAloneStagesAndRecordsWhatTheCopyCost() async throws {
    let session = try newSession()
    await session.setStageDwellForTest(0.05)
    let t = try await session.openPath(bigCSV)

    let staged = try await waitForStaged(session, t.name)
    #expect(staged.stageDecision?.stage == true)
    #expect(staged.rowCount == bigCSVRows)
    #expect(staged.stagingError == nil)
    #expect(try await isNativeTable(session, t.name, t.name) == 1, "the view must now be a table")
    #expect(try await isNativeTable(session, t.name, stagingName(t.name)) == 0,
            "the staging name must not survive the swap")

    let entries = try await waitForCatalog(session, count: 1)
    #expect(entries[0].table == t.name)
    // `realPath`, because `openPath` resolves symlinks before it builds the key — on macOS the
    // temp directory is one (/var -> /private/var), so the catalog records the resolved form.
    #expect(entries[0].path == realPath(bigCSV))
    #expect(entries[0].fmt == "csv")
    #expect(entries[0].rows == bigCSVRows)
    #expect(entries[0].sourceMissing == false)
    #expect(entries[0].sourceChanged == false)
    // Bytes are the store's growth across the CTAS, not `duckdb_tables.estimated_size` — which is
    // estimated ROWS (DuckDB155FactsTests' fact9) and would report a number close to 300,000 here.
    // A real native copy of a 30 MB CSV is megabytes.
    #expect(entries[0].bytes > 2_000_000, "measured \(entries[0].bytes) B — that is a row count, not bytes")
    #expect(session.stagedTotalBytes() >= entries[0].bytes)
    // Paging still works, off the copy this time.
    let page = try await session.page(t.name, offset: 0, limit: 10)
    #expect(page.rows.count == 10)
}

@Test func aDriveByPeekDoesNotPayForTheCopyUntilAnAggregate() async throws {
    let session = try newSession()
    await session.setStageDwellForTest(3600)   // the dwell will not fire during this test
    let t = try await session.openPath(bigCSV)

    // The staging DECISION lands almost immediately; the copy must not.
    let decided = try await waitFor(session, t.name, "the staging decision") { $0.stageDecision != nil }
    #expect(decided.stageDecision?.stage == true)
    try await Task.sleep(nanoseconds: 400_000_000)
    let peeked = try await session.table(t.name)
    #expect(peeked.staged == false)
    #expect(peeked.staging == nil, "a header peek must not start a 20 s copy")

    // An aggregate is the signal that the user is actually working with this table, and it
    // short-circuits the (here: hour-long) dwell.
    _ = try await session.setSpec(t.name, filters: [], sort: [])
    let staged = try await waitForStaged(session, t.name)
    #expect(staged.rowCount == bigCSVRows)
}

@Test func stageNowRefusesASmallSourceUnlessForced() async throws {
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())

    #expect(try await session.stageNow(t.name) == nil, "well under 25 MB — re-reading beats copying")
    let refused = try await session.table(t.name)
    #expect(refused.stageDecision?.stage == false)
    #expect(refused.staging == nil)

    #expect(try await session.stageNow(t.name, force: true) != nil)
    let staged = try await waitForStaged(session, t.name)
    #expect(staged.rowCount == 200)
    #expect(try await isNativeTable(session, t.name, t.name) == 1)
}

// MARK: - row counts after the swap

@Test func stagedRowCountAddsBackTheRowsTheParserDropped() async throws {
    // A compressed CSV always samples only the first 20,480 rows, so a bad value past that window
    // is invisible to the sniffer and `ignore_errors` silently drops the row — the same fixture
    // shape SessionTests uses for `gridRowsExcludesBadRowsOnACompressedDirtyCSV`. The materialized
    // copy therefore holds ONE FEWER row than the file, which is exactly why the staged row count
    // is the table's own count plus `bad_rows`.
    let dir = try newTempDir()
    let plain = try makeCSV(dir: dir, name: "dirty.csv", rows: 25_000, badIntRow: 21_000)
    let gz = (dir as NSString).appendingPathComponent("dirty.csv.gz")
    FileManager.default.createFile(atPath: gz, contents: nil)
    let gzip = Process()
    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzip.arguments = ["-c"]
    gzip.standardInput = FileHandle(forReadingAtPath: plain)
    gzip.standardOutput = FileHandle(forWritingAtPath: gz)
    try gzip.run()
    gzip.waitUntilExit()

    let session = try newSession()
    let t = try await session.openPath(gz)
    let scanned = try await waitFor(session, t.name, "the bad-row scan") { $0.badRows > 0 }
    #expect(scanned.badRows == 1)
    #expect(scanned.rowCount == 25_000)

    _ = try await session.stageNow(t.name, force: true)
    let staged = try await waitForStaged(session, t.name)

    let physical = try await introspect(session, table: t.name, "SELECT count(*) FROM \(q(t.name))")
    #expect(physical[0][0] == .int(24_999), "the copy really is a row short")
    #expect(staged.rowCount == 25_000, "and the reported count adds the dropped row back")
    #expect(staged.gridRows == 24_999)
}

// MARK: - failure reporting

@Test func aStagingFailureIsReportedOnTheTable() async throws {
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    _ = try await waitFor(session, t.name, "the staging decision") { $0.stageDecision != nil }

    // The file disappears out from under the copy — the CTAS cannot read it.
    try FileManager.default.removeItem(atPath: path)
    _ = try await session.stageNow(t.name, force: true)

    let failed = try await waitFor(session, t.name, "the failure") { $0.staging == nil && $0.staged == false }
    #expect(failed.stagingError?.hasPrefix("staging failed:") == true,
            "a background copy that dies must say so; got \(String(describing: failed.stagingError))")
    #expect(try await session.stagedEntries().isEmpty, "a failed copy must not be recorded")
}

@Test func aCopyFinishedForAClosedAndReopenedTableIsRejected() async throws {
    // The staging half of SessionTests' `closeAndReopenRejectsAStaleBackgroundResult`, and the
    // reason `runStage` repairs the catalog on `.stale`: the copy is published by RENAMING it over
    // the table's name, so a job that finishes after its table was closed and a DIFFERENT file
    // reopened under the same name would leave that name serving the OLD file's rows — the
    // relation-level shape of "3,000,000 rows for a 10-row file". Exercised directly with a stale
    // `openedAt`, the way that test does, since racing a real CTAS is not reproducible at unit
    // speed.
    let session = try newSession()
    let firstPath = try makeSmallCSV(rows: 200)
    let secondPath = try makeSmallCSV(rows: 10)
    let first = try await session.openPath(firstPath, name: "x")
    try await session.closeTable("x")
    let second = try await session.openPath(secondPath, name: "x")
    #expect(first.openedAt != second.openedAt)

    let result = await session.applyStaged(
        "x", physicalRows: 3_000_000, openedAt: first.openedAt, jobID: "stage-1"
    )
    guard case .stale(let replacement) = result else {
        Issue.record("a finished copy for a closed table must be rejected, not published")
        return
    }
    #expect(replacement?.key.path == realPath(secondPath), "the repair must rebuild the NEW view")

    let after = try await session.table("x")
    #expect(after.staged == false)
    #expect(after.rowCount != 3_000_000)
}

// MARK: - the catalog

@Test func lastUsedRoundTripsThroughTheCatalogInTheSameClockFrame() async throws {
    // `now()` is a TIMESTAMPTZ stored into a naive TIMESTAMP column, so it lands in the session's
    // LOCAL time; reading it back with a bare `epoch_ms` yields an instant off by the machine's
    // UTC offset (MEASURED: 5 h on this machine, America/Chicago). Everything downstream compares
    // it against Swift's `Date()` — the purge cutoff, and any "last used" the UI shows — so the
    // `::TIMESTAMPTZ` cast in `stagedEntries`/`purgeStagedTables` is load-bearing, not decoration.
    // (On a machine whose zone IS UTC this test cannot distinguish the two; it is written for the
    // developer machine and CI, one of which has an offset.)
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)

    let entries = try await waitForCatalog(session, count: 1)
    #expect(abs(entries[0].lastUsed.timeIntervalSinceNow) < 300,
            "last_used came back as \(entries[0].lastUsed), which is not 'a moment ago'")
    #expect(abs(entries[0].stagedAt.timeIntervalSinceNow) < 300)
}

@Test func stagedEntriesFlagsAChangedOrMissingSource() async throws {
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    let fresh = try await waitForCatalog(session, count: 1)
    #expect(fresh[0].sourceChanged == false)
    #expect(fresh[0].sourceMissing == false)

    try "order_id,region,amount,note\n1,West,1.50,note 1\n".write(
        toFile: path, atomically: true, encoding: .utf8)
    let changed = try await session.stagedEntries()
    #expect(changed[0].sourceChanged == true, "a copy of a file that has since changed is wrong")
    #expect(changed[0].sourceMissing == false)

    try FileManager.default.removeItem(atPath: path)
    let missing = try await session.stagedEntries()
    #expect(missing[0].sourceMissing == true)
    #expect(missing[0].sourceChanged == false, "a vanished file has no mtime to disagree with")
}

// MARK: - purge

@Test func purgeNeverYanksATableOutFromUnderAnOpenTab() async throws {
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await waitForCatalog(session, count: 1)

    // `all: true` selects everything there is — and still must not touch an open tab.
    let held = try await session.purgeStaged(all: true)
    #expect(held.dropped.isEmpty, "the live catalog wins over the on-disk one")
    #expect(try await session.stagedEntries().count == 1)
    #expect(try await isNativeTable(session, t.name, t.name) == 1, "the copy must still be there")

    try await session.closeTable(t.name)
    let purged = try await session.purgeStaged(all: true)
    #expect(purged.dropped == [t.name])
    #expect(try await session.stagedEntries().isEmpty)
}

@Test func purgeDropsACopyWhoseSourceChangedOnDisk() async throws {
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await waitForCatalog(session, count: 1)
    try await session.closeTable(t.name)

    // Fresh and tiny: neither the age cutoff nor the size budget can select this row. Only the
    // staleness sweep can — a copy of a file that has since changed is simply wrong.
    let untouched = try await session.purgeStaged()
    #expect(untouched.dropped.isEmpty)

    try "order_id,region,amount,note\n1,West,1.50,note 1\n".write(
        toFile: path, atomically: true, encoding: .utf8)
    let purged = try await session.purgeStaged()
    #expect(purged.dropped == [t.name])
    #expect(try await session.stagedEntries().isEmpty)
}

@Test func purgeSelectsAgedOutThenOverBudgetAndSkipsWhatIsOpen() throws {
    // The policy itself, against a bare store: `Session.purgeStagedTables` is `static` precisely
    // so this needs no live session, no 20 GB of real disk, and no clock manipulation.
    let db = try Database.inMemory()
    let con = try db.connect()
    try con.execute(catalogDDL)

    func insert(_ name: String, bytes: Int, ageDays: Int) throws {
        _ = try con.query(
            "INSERT INTO _sift_sources VALUES (?, ?, 0, 0, ?, 'csv', now(), "
                + "now() - INTERVAL (?) DAY, 0, ?)",
            // Current-format token: without the version prefix the format sweep collects these
            // rows before the age/budget policy is ever consulted, which silently stops this test
            // from testing anything (review round 3).
            [.text("\(stagingTokenVersion)|token-\(name)"), .text("/nonexistent/\(name).csv"),
             .text(name), .int(Int64(ageDays)), .int(Int64(bytes))]
        )
    }
    // `defaultMaxAgeDays` is 14 and `defaultBudgetBytes` is 20 GB.
    try insert("aged", bytes: 1, ageDays: 30)
    try insert("older_big", bytes: 15 * 1024 * 1024 * 1024, ageDays: 2)
    try insert("newer_big", bytes: 15 * 1024 * 1024 * 1024, ageDays: 1)

    // Nothing open: the aged row goes on the clock, and the surviving 30 GB is over the 20 GB
    // budget, so the least-recently-used of the two survivors is evicted until it fits.
    let dropped = try Session.purgeStagedTables(con, open: ["newer_big"], tables: nil, all: false)
    #expect(Set(dropped) == ["aged", "older_big"])
    #expect(dropped.first == "aged", "age-out is decided before the size check")

    let left = try con.query("SELECT table_name FROM _sift_sources").allRows()
    #expect(left.count == 1)
    #expect(left[0][0] == .text("newer_big"))

    // An explicit list is taken as given — no policy, but the open-tab rule still applies.
    #expect(try Session.purgeStagedTables(
        con, open: ["newer_big"], tables: ["newer_big"], all: false).isEmpty)
    #expect(try Session.purgeStagedTables(
        con, open: [], tables: ["newer_big"], all: false) == ["newer_big"])
}

// MARK: - unstage

@Test func unstageGoesBackToReadingTheFileInPlace() async throws {
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await waitForCatalog(session, count: 1)

    let back = try await session.unstage(t.name)
    #expect(back.staged == false)
    #expect(try await session.stagedEntries().isEmpty, "the catalog row goes with the copy")
    #expect(try await isNativeTable(session, t.name, t.name) == 0, "a view again, not a table")

    let page = try await session.page(t.name, offset: 0, limit: 10)
    #expect(page.rows.count == 10, "and the file still reads")

    // Unstaging something that was never staged is a no-op, not an error.
    let again = try await session.unstage(t.name)
    #expect(again.staged == false)
}

@Test func reopeningAStagedFileReusesTheCopyItAlreadyPaidFor() async throws {
    // Staging leaves a real TABLE in a persistent store, so the copy outlives the tab — which is
    // what the `_sift_sources` catalog is for. Python never reads that catalog back on open: its
    // `open_path` runs `CREATE OR REPLACE VIEW` unconditionally, and MEASURED against DuckDB
    // 1.5.5 that fails outright over an existing table ("Existing object small is of type Table,
    // trying to replace with type View"). Reopening a file you staged — this session or tomorrow
    // — is therefore broken in the shipping Python. Reproduced here before it was fixed.
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await session.closeTable(t.name)      // staged: the copy and its catalog row stay behind

    let again = try await session.openPath(path)
    #expect(again.name == t.name)
    #expect(again.staged == true, "the copy the user already waited for must be reused, not rebuilt")
    #expect(again.rowCount == 200)
    #expect(try await isNativeTable(session, again.name, again.name) == 1)
    let page = try await session.page(again.name, offset: 0, limit: 10)
    #expect(page.rows.count == 10)
    #expect(try await session.stagedEntries().count == 1, "still exactly one copy, not a second")
}

@Test func reopeningAChangedFileThrowsAwayTheStaleCopy() async throws {
    // The other half of adoption: a copy is only the file if the source token still matches.
    // Serving a stale copy would be the "confidently wrong numbers" failure this tool exists to
    // avoid, so the copy is dropped and the file is read in place again.
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await session.closeTable(t.name)

    try "order_id,region,amount,note\n1,West,1.50,note 1\n".write(
        toFile: path, atomically: true, encoding: .utf8)
    let again = try await session.openPath(path)
    #expect(again.staged == false, "a copy of the OLD file is not this file")
    #expect(try await isNativeTable(session, again.name, again.name) == 0, "a view again")
    #expect(try await session.stagedEntries().isEmpty, "and its catalog row goes with it")

    let page = try await session.page(again.name, offset: 0, limit: 10)
    #expect(page.rows.count == 1, "the new contents, not the stale copy's 200 rows")
}

// ============================================================================================
// Round-1 review fixes. Each test below exists because a mechanism could be deleted with the
// suite still green, or because a copy of the wrong data was being served.
// ============================================================================================

// MARK: - C1: what a staged copy is a copy OF

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func aCopyOfOneSheetIsNeverServedAsAnother() async throws {
    // REPRODUCED before the fix: every sheet of one workbook shares one path, mtime and size, so
    // `SourceKey.token()` matched across sheets. Staging `Summary` (1 row, metric/value) and then
    // opening `By Store` (50 rows, store/sales) under the same table name adopted Summary's copy —
    // `page()` returned Summary's row under By Store's headers, with no error and nothing in
    // `stagedEntries()` able to tell which sheet the copy was of.
    let session = try newSession()
    let book = siftCoreTestsFixture("book.xlsx")

    let summary = try await session.openPath(book, name: "d", sheet: "Summary")
    _ = try await session.stageNow(summary.name, force: true)
    try await waitForStaged(session, "d")
    try await session.closeTable("d")

    let byStore = try await session.openPath(book, name: "d", sheet: "By Store")
    #expect(byStore.staged == false, "a copy of Summary is not By Store")
    let page = try await session.page("d", offset: 0, limit: 100)
    #expect(page.columns.map(\.name) == ["store", "sales"])
    #expect(page.rows.count == 50, "By Store's own 50 rows, not Summary's 1")

    // And the right sheet's own copy still adopts — the fix must not simply disable adoption.
    _ = try await session.stageNow("d", force: true)
    try await waitForStaged(session, "d")
    try await session.closeTable("d")
    let again = try await session.openPath(book, name: "d", sheet: "By Store")
    #expect(again.staged == true)
    #expect(again.rowCount == 50)
}

@Test func aCopyOfAFolderIsNotServedAfterAMemberIsRewrittenInPlace() async throws {
    // REPRODUCED before the fix, and this was the one with no way back: a directory's mtime and
    // size do not move when a member file is rewritten in place, so the copy was adopted with the
    // pre-edit values AND reported `sourceChanged: false`. The staleness sweep does the same
    // directory `stat`, so it never collected it either — only deleting `~/.sift` fixed it.
    let dir = try newTempDir()
    let header = "order_id,region,amount,note\n"
    try (header + "1,West,100.50,a\n").write(
        toFile: (dir as NSString).appendingPathComponent("a.csv"), atomically: true, encoding: .utf8)
    try (header + "2,South,200.50,b\n").write(
        toFile: (dir as NSString).appendingPathComponent("b.csv"), atomically: true, encoding: .utf8)

    let session = try newSession()
    let t = try await session.openPath(dir)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await session.closeTable(t.name)

    // Rewritten IN PLACE — `atomically: true` would write a temp file and rename it, which is a
    // directory-entry change and does move the directory's mtime. This is the case that hides.
    let before = try statInfo(dir)
    try (header + "1,West,999.50,EDITED\n").write(
        toFile: (dir as NSString).appendingPathComponent("a.csv"), atomically: false, encoding: .utf8)
    let after = try statInfo(dir)
    #expect(before.mtimeNs == after.mtimeNs && before.size == after.size,
            "the premise: a folder's own stat cannot see a member being rewritten")

    let again = try await session.openPath(dir)
    #expect(again.staged == false, "the copy predates the edit and must not be adopted")
    let page = try await session.page(again.name, offset: 0, limit: 10)
    let amounts = page.rows.map { $0[2].display }.sorted()
    #expect(amounts.contains("999.5") || amounts.contains("999.50"),
            "the edited value must be visible; got \(amounts)")

    // And the positive case, in the same test: a folder whose members have NOT moved must still
    // adopt its copy. Without this, "never adopt a folder" passes the assertions above while
    // quietly turning adoption off for every folder source — which is exactly what an earlier
    // version of the column backstop did.
    _ = try await session.stageNow(again.name, force: true)
    try await waitForStaged(session, again.name)
    try await session.closeTable(again.name)
    let third = try await session.openPath(dir)
    #expect(third.staged == true, "an unchanged folder must reuse the copy it already paid for")
}

@Test func theStagingTokenSeparatesSheetsAndFolderContents() throws {
    // The identity itself, unit-level: the same file, two sheets -> two tokens; a folder whose
    // member changed -> a different token. This is what `SourceKey.token()` could not do.
    let key = SourceKey(path: "/tmp/book.xlsx", mtimeNs: 111, size: 222)
    func spec(_ sheet: String?) -> SourceSpec {
        SourceSpec(key: key, fmt: .xlsx, readFn: "read_xlsx",
                   columns: [Column(name: "a", type: "BIGINT")], sheet: sheet)
    }
    #expect(stagingToken(spec("Summary")) != stagingToken(spec("By Store")))
    #expect(stagingToken(spec("Summary")) == stagingToken(spec("Summary")))
    #expect(stagingToken(spec(nil)).hasPrefix(stagingTokenVersion),
            "every token carries its format version, so an older build's can never match")

    let dir = try newTempDir()
    let member = (dir as NSString).appendingPathComponent("a.csv")
    try "x\n1\n".write(toFile: member, atomically: true, encoding: .utf8)
    let dirKey = try statInfo(dir)
    func dirSpec() throws -> SourceSpec {
        SourceSpec(key: SourceKey(path: dir, mtimeNs: dirKey.mtimeNs, size: dirKey.size),
                   fmt: .globCsv, readFn: "read_csv", columns: [Column(name: "x", type: "BIGINT")])
    }
    let firstToken = stagingToken(try dirSpec())
    try "x\n1\n2\n".write(toFile: member, atomically: true, encoding: .utf8)
    #expect(stagingToken(try dirSpec()) != firstToken,
            "a folder's identity comes from its members, not from its own stat")
}

// MARK: - I2: the swap retries through a real write-write conflict

@Test func theSwapRetriesThroughAWriteWriteConflict() throws {
    // The retry, the ROLLBACK and the backoff could all be deleted with the suite green. This
    // forces the conflict the mechanism exists for, with no timing: a second connection holds an
    // open transaction that has written the view being swapped away.
    let path = (try newTempDir() as NSString).appendingPathComponent("swap.duckdb")
    let db = try Database(path: path)
    let worker = try db.connect()
    let blocker = try db.connect()

    try worker.execute("CREATE OR REPLACE VIEW t AS SELECT 1 AS x")
    try worker.execute("CREATE OR REPLACE TABLE \(q(stagingName("t"))) AS SELECT 42 AS x")

    try blocker.execute("BEGIN TRANSACTION")
    try blocker.execute("CREATE OR REPLACE VIEW t AS SELECT 2 AS x")

    // Attempt one must genuinely fail — otherwise this test proves nothing about the retry.
    var firstAttemptFailed = false
    do {
        try worker.execute("BEGIN TRANSACTION")
        try worker.execute("DROP VIEW IF EXISTS t")
        try worker.execute("ALTER TABLE \(q(stagingName("t"))) RENAME TO t")
        try worker.execute("COMMIT")
    } catch let error as DuckDBError {
        firstAttemptFailed = true
        #expect(error.message.contains("conflict"), "expected a write-write conflict; got \(error.message)")
    }
    try? worker.execute("ROLLBACK")
    try blocker.execute("ROLLBACK")
    #expect(firstAttemptFailed, "the conflict this test relies on did not happen")

    // Now the real thing, through the same conflict: the blocker is released 50 ms in, while
    // `swapStaged` is inside its 150 ms backoff, so attempt one hits the conflict and attempt two
    // succeeds. Without the retry (or without the ROLLBACK that clears the failed transaction)
    // this throws.
    try blocker.execute("BEGIN TRANSACTION")
    try blocker.execute("CREATE OR REPLACE VIEW t AS SELECT 3 AS x")
    try worker.execute("CREATE OR REPLACE TABLE \(q(stagingName("t"))) AS SELECT 42 AS x")
    let release = ConnectionBox(blocker)
    Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.05); release.rollback() }
    try swapStaged(worker, name: "t", lock: NSLock())
    let rows = try worker.query("SELECT x FROM t").allRows()
    #expect(rows.count == 1)
    #expect(rows[0][0] == .int(42), "the staged rows must be the ones under the user-facing name")
}

// MARK: - I3: the two unpinned openedAt guards

@Test func aFailedJobForAClosedAndReopenedTableIsNotReportedOnTheNewOne() async throws {
    // Without `finishStage`'s guard, a job that dies for table `x` after `x` was closed and a
    // different file reopened under that name writes "staging failed: …" onto the innocent new
    // table and clears its own in-flight progress. Same shape as the regression this branch
    // already shipped once.
    let session = try newSession()
    let first = try await session.openPath(try makeSmallCSV(), name: "x")
    try await session.closeTable("x")
    let second = try await session.openPath(try makeSmallCSV(rows: 10), name: "x")
    #expect(first.openedAt != second.openedAt)

    let inFlight = StagingProgress(jobID: "stage-live", state: "running", pct: 0, estSeconds: 1)
    await session.setStagingForTest("x", inFlight)
    await session.finishStage("x", jobID: "stage-1", openedAt: first.openedAt, error: "staging failed: boom")

    let after = try await session.table("x")
    #expect(after.stagingError == nil, "the new table never had a failure")
    #expect(after.staging == inFlight, "and its own job must not be cleared by a stranger")
}

@Test func theDwellDropsAStaleGenerationImmediatelyInsteadOfWaiting() async throws {
    // `maybeStageAfterDwell`'s two guards. With them removed this call sits in the dwell loop for
    // the full (here: hour-long) deadline instead of returning at once, and then stages a table
    // its job was never about — so the assertion is that it comes back promptly AND stages nothing.
    let session = try newSession()
    await session.setStageDwellForTest(3600)
    let first = try await session.openPath(bigCSV, name: "x")
    try await session.closeTable("x")
    let second = try await session.openPath(bigCSV, name: "x")
    #expect(first.openedAt != second.openedAt)

    let returned = DoneFlag()
    Task { await session.maybeStageAfterDwell("x", openedAt: first.openedAt); returned.set() }
    let deadline = Date().addingTimeInterval(5)
    while !returned.isSet, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(returned.isSet, "a stale generation must be dropped, not waited on")

    let after = try await session.table("x")
    #expect(after.staged == false)
    #expect(after.staging == nil, "and no copy may be started for a table this job was not about")
}

// MARK: - I4: two copies in flight must not charge each other

@Test func twoCopiesStagingAtOnceEachGetTheirOwnHonestByteCount() async throws {
    // A whole-store delta cross-charges: MEASURED in review, two equal files staging together
    // recorded 524,288 and 900,839 B, and a 3-row CSV recorded 413 B beside a 30 MB copy. Two
    // byte-identical files must cost exactly the same, whatever else is happening in the store.
    let dir = try newTempDir()
    let a = try makeCSV(dir: dir, name: "twin_a.csv", rows: 20_000)
    let b = try makeCSV(dir: dir, name: "twin_b.csv", rows: 20_000)
    #expect(try statInfo(a).size == statInfo(b).size, "the premise: identical content")

    let session = try newSession()
    let ta = try await session.openPath(a)
    let tb = try await session.openPath(b)
    _ = try await session.stageNow(ta.name, force: true)
    _ = try await session.stageNow(tb.name, force: true)
    try await waitForStaged(session, ta.name)
    try await waitForStaged(session, tb.name)

    let entries = try await waitForCatalog(session, count: 2)
    let bytes = Dictionary(uniqueKeysWithValues: entries.map { ($0.table, $0.bytes) })
    #expect(bytes[ta.name] == bytes[tb.name],
            "identical copies must cost identically; got \(bytes)")
    #expect((bytes[ta.name] ?? 0) > 0)
}

// MARK: - I5: one row per staged table, not per source token

@Test func twoTabsOfOneFileEachKeepTheirOwnCatalogRow() async throws {
    // The old PRIMARY KEY was `source_token`, which both tabs of one file share, so the second
    // INSERT OR REPLACE replaced the first tab's row. REPRODUCED: catalog `["small_2"]` against
    // real tables `["small", "small_2"]`, and `purgeStaged(all: true)` then dropped only
    // `small_2` — leaving a copy in the store that no purge could reach.
    let session = try newSession()
    let path = try makeSmallCSV()
    let first = try await session.openPath(path)
    let second = try await session.openPath(path)
    #expect(second.name == "small_2")

    for name in [first.name, second.name] {
        _ = try await session.stageNow(name, force: true)
        try await waitForStaged(session, name)
    }
    let entries = try await waitForCatalog(session, count: 2)
    #expect(Set(entries.map(\.table)) == ["small", "small_2"])

    let probe = try await session.openPath(try makeSmallCSV(rows: 5))
    for name in [first.name, second.name] {
        #expect(try await isNativeTable(session, probe.name, name) == 1)
        try await session.closeTable(name)
    }
    let purged = try await session.purgeStaged(all: true)
    #expect(Set(purged.dropped) == ["small", "small_2"], "both copies, not just the surviving row")
    for name in [first.name, second.name] {
        #expect(try await isNativeTable(session, probe.name, name) == 0,
                "\(name) must not survive the user's reclaim-everything button")
    }
}

// MARK: - I6: closing a tab while its copy is being swapped in

@Test func closingATabMidSwapDoesNotThrow() async throws {
    // Between `swapStaged`'s rename and `applyStaged`'s publish the name is a real TABLE while the
    // flags still say "not staged" — and `DROP VIEW` on a table is a hard Catalog Error, so
    // closing the tab in that window failed while the `defer` removed it from the catalog anyway.
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)

    // Exactly the mid-swap store state: the copy is in place under the name, the flags are not.
    await session.setMidSwapStateForTest(t.name)
    try await session.closeTable(t.name)          // threw `Existing object … is of type Table`

    await #expect(throws: SessionError.self) { try await session.table(t.name) }
}

// MARK: - M1: one bad row must not disable the purge forever

@Test func aCatalogRowWhoseObjectIsAViewIsCollectedInsteadOfAbortingThePurge() throws {
    // `DROP TABLE` on a view throws, and inside the purge loop that throw aborted every later
    // target — age and budget enforcement silently dead from then on. The path in is real: a
    // catalog row outliving its table, then `openPath` creating a view under the same name.
    let db = try Database.inMemory()
    let con = try db.connect()
    try con.execute(catalogDDL)
    try con.execute("CREATE VIEW ghost AS SELECT 1 AS x")
    try con.execute("CREATE TABLE later AS SELECT 2 AS x")
    for name in ["ghost", "later"] {
        _ = try con.query(
            "INSERT INTO _sift_sources VALUES (?, '/nonexistent/x.csv', 0, 0, ?, 'csv', now(), "
                + "now() - INTERVAL 30 DAY, 0, 1)",
            [.text("\(stagingTokenVersion)|token-\(name)"), .text(name)]
        )
    }

    let dropped = try Session.purgeStagedTables(con, open: [], tables: nil, all: false)
    #expect(Set(dropped) == ["ghost", "later"], "the view is collected AND the later target too")
    #expect(try con.query("SELECT count(*) FROM _sift_sources").allRows()[0][0] == .int(0))
}

// MARK: - M3 / M4: the cancel job's own edges

@Test func aCancelThatCannotLandReportsFalse() throws {
    // Once the interruptible query has returned, the job is committed to publishing. Saying "yes,
    // cancelled" there and then publishing the copy anyway is the lie this closes.
    let con = try Database.inMemory().connect()
    let job = StageJob()
    job.attach(con)
    #expect(job.requestCancel() == true, "an in-flight job can be cancelled")
    job.closeInterruptWindow()
    #expect(job.requestCancel() == false, "a job past the interrupt window cannot")
}

@Test func aCancelBeforeTheConnectionExistsStillStopsItsThread() throws {
    // `cancel` can arrive with the job id `stageNow` just returned, before `runStage` has
    // connected. The hammer starts anyway (so it catches the CTAS the moment it begins), and it
    // must still stop — otherwise it spins at ~5 kHz on a nil target for the life of the process.
    let job = StageJob()
    #expect(job.requestCancel() == true)
    job.closeInterruptWindow()          // hangs if the thread cannot see the window close
    #expect(job.isCancelled)
}

/// Did an `async` call come back? A plain `Bool` cannot cross the task boundary and
/// `DispatchSemaphore.wait` is unavailable in an async context, so this is the smallest thing
/// that answers "did it return, or is it still sitting in a loop".
private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// `Connection` is deliberately not `Sendable`; this is the same narrowly-scoped box
/// `Tests/DuckDBKitTests/SmokeTests.swift` uses for `interrupt()`, here so a test can end a
/// blocking transaction from another thread while the swap under test is in its backoff.
private struct ConnectionBox: @unchecked Sendable {
    let con: Connection
    init(_ con: Connection) { self.con = con }
    func rollback() { try? con.execute("ROLLBACK") }
}

// MARK: - M6: the timestamp round trip, pinned rather than left to the host's zone

@Test func theCatalogsTimestampsAreReadBackInTheFrameTheyWereWrittenIn() throws {
    // The end-to-end version of this ("last_used is close to now") is VACUOUS on a UTC host: with
    // the `::TIMESTAMPTZ` cast removed it still passes under `TZ=UTC`. This one pins the session
    // zone itself, so it is the same test on every machine: `now()` is a TIMESTAMPTZ landing in a
    // naive TIMESTAMP column, so it stores LOCAL time, and reading it back without the cast is off
    // by the zone's offset from UTC.
    let con = try Database.inMemory().connect()
    try con.execute("SET TimeZone='America/Chicago'")
    #expect(try con.query("SELECT current_setting('TimeZone')").allRows()[0][0] == .text("America/Chicago"),
            "the premise: this test needs a non-UTC session zone to say anything")
    try con.execute(catalogDDL)
    _ = try con.query(
        "INSERT INTO _sift_sources VALUES ('t', '/x.csv', 0, 0, 'x', 'csv', now(), now(), 0, 0)")

    let row = try con.query(
        "SELECT epoch_ms(last_used::TIMESTAMPTZ), epoch_ms(last_used) FROM _sift_sources"
    ).allRows()[0]
    let cast = Date(timeIntervalSince1970: Double(cellInt(row[0])) / 1000)
    let bare = Date(timeIntervalSince1970: Double(cellInt(row[1])) / 1000)

    #expect(abs(cast.timeIntervalSinceNow) < 300, "the cast reads the instant that was written")
    #expect(abs(bare.timeIntervalSinceNow) > 3600,
            "and without it the value is off by the zone offset — 5 h for Chicago")
}

// MARK: - M8: the size half of "mtime or size"

@Test func theStalenessSweepFiresOnSizeAloneAsWellAsMtimeAlone() throws {
    // Every end-to-end test rewrites a file, which moves BOTH fields, so either half of this
    // condition could be deleted with the suite green. Here the stored values are planted so that
    // exactly one field disagrees with the file on disk.
    let dir = try newTempDir()
    let file = (dir as NSString).appendingPathComponent("src.csv")
    try "x\n1\n".write(toFile: file, atomically: true, encoding: .utf8)
    let real = try statInfo(file)

    let con = try Database.inMemory().connect()
    try con.execute(catalogDDL)
    func plant(_ name: String, mtimeNs: Int, size: Int) throws {
        try con.execute("CREATE TABLE \(q(name)) AS SELECT 1 AS x")
        _ = try con.query(
            "INSERT INTO _sift_sources VALUES (?, ?, ?, ?, ?, 'csv', now(), now(), 0, 1)",
            [.text("\(stagingTokenVersion)|token-\(name)"), .text(file), .int(Int64(mtimeNs)), .int(Int64(size)), .text(name)]
        )
    }
    try plant("size_moved", mtimeNs: real.mtimeNs, size: real.size + 1)
    try plant("mtime_moved", mtimeNs: real.mtimeNs + 1, size: real.size)
    try plant("unchanged", mtimeNs: real.mtimeNs, size: real.size)

    let dropped = try Session.purgeStagedTables(con, open: [], tables: nil, all: false)
    #expect(Set(dropped) == ["size_moved", "mtime_moved"])
    #expect(!dropped.contains("unchanged"), "a copy that still matches its source is left alone")
}

// MARK: - the startup purge, and a second Session in the same process

@Test func aFreshSessionCollectsWhatTheLastOneLeftStale() async throws {
    // My round-0 report claimed this test was impossible because "a second Session on the same
    // home cannot be opened in-process". That was FALSE — DuckDB's file lock is cross-process
    // only. (What two live in-process Sessions actually are is worse than sharing and is written
    // up in the report; this test deliberately does NOT rely on it. The first session is released
    // before the second opens, which is the real "next launch" this is about.)
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-staging-startup-\(UUID().uuidString)").path
    let path = try makeSmallCSV()

    do {
        let first = try Session(home: home)
        let t = try await first.openPath(path)
        _ = try await first.stageNow(t.name, force: true)
        try await waitForStaged(first, t.name)
        try await waitForCatalog(first, count: 1)
        try await first.closeTable(t.name)
    }   // released: the store is now just a file on disk, as it would be after a quit

    try "order_id,region,amount,note\n1,West,1.50,note 1\n".write(
        toFile: path, atomically: true, encoding: .utf8)

    let second = try Session(home: home)
    #expect(second.engineInfo().sharedStore == true, "it really does open the same store")
    #expect(try await second.stagedEntries().isEmpty,
            "a copy of a file that has since changed must not survive a restart")
}

// MARK: - a store written by an older build

@Test func aStoreFromAnOlderBuildIsResetRatherThanMisread() async throws {
    // The catalog's key moved (I5) and the token format changed (C1). Neither can be patched in
    // place, so a legacy store is reset: its copies are DROPPED — not left stranded where nothing
    // can reach them — and the catalog is recreated with the current schema.
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-staging-legacy-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let store = (home as NSString).appendingPathComponent("stage.duckdb")
    let path = try makeSmallCSV()

    do {   // exactly what an older build left behind: old key, v1 token, a real copy
        let legacy = try Database(path: store)
        let con = try legacy.connect()
        try con.execute("""
            CREATE TABLE _sift_sources (
                source_token VARCHAR PRIMARY KEY, path VARCHAR, mtime_ns BIGINT, size BIGINT,
                table_name VARCHAR, fmt VARCHAR, staged_at TIMESTAMP, last_used TIMESTAMP,
                row_count BIGINT, bytes BIGINT)
            """)
        try con.execute("CREATE TABLE small AS SELECT 1 AS order_id")
        let stat = try statInfo(path)
        _ = try con.query(
            "INSERT INTO _sift_sources VALUES (?, ?, ?, ?, 'small', 'csv', now(), now(), 1, 262144)",
            [.text("\(path):\(stat.mtimeNs):\(stat.size)"),   // v1 format: no version, no members
             .text(path), .int(Int64(stat.mtimeNs)), .int(Int64(stat.size))]
        )
    }

    let session = try Session(home: home)
    #expect(try await session.stagedEntries().isEmpty, "the legacy catalog is emptied")

    // The copy it named is gone too, and the file opens fresh rather than adopting anything.
    let reopened = try await session.openPath(path)
    #expect(reopened.name == "small")
    #expect(reopened.staged == false, "a v1 token must never resurrect a copy")
    #expect(try await isNativeTable(session, "small", "small") == 0)
    let page = try await session.page("small", offset: 0, limit: 5)
    #expect(page.columns.map(\.name) == ["order_id", "region", "amount", "note"],
            "the real file's shape, not the legacy copy's single column")

    // And the catalog this build writes from here on is keyed the new way.
    _ = try await session.stageNow("small", force: true)
    try await waitForStaged(session, "small")
    #expect(try await session.stagedEntries().count == 1)
}

@Test func aCopyWhoseShapeDisagreesWithTheFileIsNotAdoptedEvenWhenTheTokenMatches() async throws {
    // The backstop for the one hole the token cannot close (review C1(c)): a file replaced by a
    // different file of the same size with the same mtime — a restore that preserves timestamps —
    // produces a MATCHING token for content that is not the same. Constructed directly, because
    // faking an identical mtime through the filesystem is the same test with more moving parts.
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    let con = try session.database.connect()

    // A copy under this table's name whose columns are not this file's columns, and a catalog row
    // whose token matches the live spec exactly.
    try con.execute("DROP VIEW IF EXISTS \(q(t.name))")
    try con.execute("CREATE TABLE \(q(t.name)) AS SELECT 1 AS wrong_column")
    _ = try con.query(
        "INSERT INTO _sift_sources VALUES (?, ?, 0, 0, ?, 'csv', now(), now(), 1, 1)",
        [.text(stagingToken(t.spec)), .text(path), .text(t.name)]
    )
    #expect(session.adoptStagedCopy(con, name: t.name, spec: t.spec) == nil,
            "a copy shaped differently from the file is not a copy of the file")
    // …and it was cleared away rather than left holding the name.
    _ = try await session.openPath(path)
    #expect(try await session.stagedEntries().isEmpty)
}

// ============================================================================================
// Round-2 review fixes.
// ============================================================================================

// MARK: - N1: the hammer stops on EVERY exit from runStage, including a failed connect

@Test func aJobThatCannotEvenConnectStillStopsItsHammer() async throws {
    // The M4 `defer` spent round 1 sitting BELOW the `catch { … return }` it was written for, with
    // a comment claiming it covered that case. Swift registers a `defer` when control reaches it,
    // so it never ran on that path and the hammer thread spun at ~5 kHz for the life of the
    // process. `database.connect()` cannot be made to fail on demand, hence `runStage`'s `connect`
    // seam — the same reason `setStageDwellForTest` exists.
    let session = try newSession()
    let t = try await session.openPath(try makeSmallCSV())

    let job = StageJob()
    #expect(job.requestCancel() == true)      // a cancel racing the connection, before `attach`
    #expect(job.isHammering, "the premise: a cancelled job hammers until its window closes")

    await session.runStage(
        name: t.name, spec: t.spec, jobID: "stage-unconnectable", job: job, openedAt: t.openedAt,
        connect: { throw DuckDBError("could not open a DuckDB connection") }
    )
    #expect(!job.isHammering, "every exit from runStage must close the interrupt window")

    let after = try await session.table(t.name)
    #expect(after.stagingError?.hasPrefix("staging failed:") == true)
}

// MARK: - N2: closing a tab mid-copy must not leak the view

@Test func closingATabMidCopyLeavesNoViewBehind() async throws {
    // `closeTable` leaves the name alone while a job is in flight, because a copy may already have
    // renamed a TABLE over it. Every pre-swap exit then lands in `finishStage`, which used to find
    // no table and simply return — so nobody dropped the view. `~/.sift` is persistent and no
    // purge can see an object with no catalog row, so they accumulate without bound. The new
    // pre-swap `isStillOpen` check made this the COMMON path, not a rare race.
    let session = try newSession()
    await session.setStageDwellForTest(3600)
    let probe = try await session.openPath(try makeSmallCSV(rows: 5))
    let t = try await session.openPath(bigCSV)

    _ = try await session.stageNow(t.name)     // 30 MB: the copy takes long enough to close under
    try await session.closeTable(t.name)       // ← the tab goes while the CTAS is still running

    // The job finishes, finds its table gone, and must collect the view it left behind.
    let deadline = Date().addingTimeInterval(60)
    var views = -1
    while Date() < deadline {
        let rows = try await introspect(
            session, table: probe.name,
            "SELECT count(*) FROM duckdb_views() WHERE view_name = '\(t.name)'")
        views = cellInt(rows[0][0])
        if views == 0 { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(views == 0, "a cancelled/abandoned copy must not leave an orphan view in the store")
    #expect(try await session.stagedEntries().isEmpty)
}

// MARK: - N3: the column check admits exactly one provenance column, not any number

@Test func aCopyWithAnUnexpectedExtraColumnIsNotAdopted() async throws {
    // `starts(with:)` fixed the folder case but admitted ANY number of extra trailing columns for
    // ANY source kind. A plain CSV's copy must match its spec exactly.
    let session = try newSession()
    let path = try makeSmallCSV()
    let t = try await session.openPath(path)
    let con = try session.database.connect()

    let columns = t.spec.columns.map { "NULL::\($0.type) AS \(q($0.name))" }.joined(separator: ", ")
    try con.execute("DROP VIEW IF EXISTS \(q(t.name))")
    try con.execute("CREATE TABLE \(q(t.name)) AS SELECT \(columns), 'extra' AS surprise")
    _ = try con.query(
        "INSERT INTO _sift_sources VALUES (?, ?, 0, 0, ?, 'csv', now(), now(), 1, 1)",
        [.text(stagingToken(t.spec)), .text(path), .text(t.name)]
    )
    #expect(session.adoptStagedCopy(con, name: t.name, spec: t.spec) == nil,
            "a copy carrying a column the source does not produce is not this source's copy")
}

// MARK: - N4: a rewrite that forges the mtime cannot forge the ctime

@Test func aCopyIsNotAdoptedWhenTheFileWasRewrittenWithItsTimestampRestored() async throws {
    // The realistic route is not an exotic restore: any toolchain that stamps a constant mtime on
    // its outputs (SOURCE_DATE_EPOCH, Nix/Bazel, unzip of a fixed-timestamp archive) plus a
    // fixed-width export gives an identical mtime AND size for different content — and identical
    // columns, so the shape backstop cannot fire either. `utimensat` sets atime and mtime; ctime
    // is maintained by the kernel and cannot be set from userspace at all, which is what makes it
    // the field a forgery cannot reach.
    let dir = try newTempDir()
    let path = (dir as NSString).appendingPathComponent("fixed.csv")
    try "order_id,amount\n1,00100\n2,00200\n".write(toFile: path, atomically: false, encoding: .utf8)
    let original = try statInfo(path)

    let session = try newSession()
    let t = try await session.openPath(path)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await session.closeTable(t.name)

    // Same length, different values, and the exact original mtime put back to the nanosecond.
    try "order_id,amount\n1,99100\n2,99200\n".write(toFile: path, atomically: false, encoding: .utf8)
    var times = [
        timespec(tv_sec: original.mtimeNs / 1_000_000_000, tv_nsec: original.mtimeNs % 1_000_000_000),
        timespec(tv_sec: original.mtimeNs / 1_000_000_000, tv_nsec: original.mtimeNs % 1_000_000_000),
    ]
    #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
    let forged = try statInfo(path)
    #expect(forged.mtimeNs == original.mtimeNs && forged.size == original.size,
            "the premise: mtime and size are indistinguishable from the staged file's")

    let again = try await session.openPath(path)
    #expect(again.staged == false, "ctime moved, so this is not the file that was copied")
    let page = try await session.page(again.name, offset: 0, limit: 10)
    #expect(page.rows.map { $0[1].display } == ["99100", "99200"],
            "the disk's contents, not the copy's")
}

// MARK: - M6: the purge cutoff read in the wrong timezone deletes the user's data

@Test func thePurgeCutoffIsImmuneToTheSessionTimezone() throws {
    // `stagedEntries` merely mislabels a string if the cast is dropped; THIS site deletes cached
    // data. A row 13 h 21 m short of the 14-day cutoff is read 5 h older without the cast on a
    // Chicago-zoned connection — over the line, and gone. The zone is pinned inside the test, so
    // it says the same thing under TZ=UTC as it does here.
    let con = try Database.inMemory().connect()
    try con.execute("SET TimeZone='America/Chicago'")
    try con.execute(catalogDDL)
    try con.execute("CREATE TABLE nearly_aged AS SELECT 1 AS x")
    _ = try con.query(
        "INSERT INTO _sift_sources VALUES (?, '/nonexistent/x.csv', 0, 0, 'nearly_aged', 'csv', "
            + "now(), now() - INTERVAL 14 DAY + INTERVAL 3 HOUR, 0, 1)",
        [.text("\(stagingTokenVersion)|nearly-aged")])

    let dropped = try Session.purgeStagedTables(con, open: [], tables: nil, all: false)
    #expect(dropped.isEmpty,
            "13 d 21 h is inside the 14-day window; only a timezone misread makes it 14 d 2 h")
    #expect(try con.query("SELECT count(*) FROM _sift_sources").allRows()[0][0] == .int(1))
}

// MARK: - N5: two sheets of one workbook that only the identity can tell apart

@Test(.enabled(if: extensionIsAvailable("excel"), "duckdb excel extension not installed"))
func aCopyOfOneMonthsSheetIsNeverServedAsAnother() async throws {
    // `book.xlsx`'s two sheets have different columns, so the shape backstop rejects the wrong
    // copy even when the identity itself is broken — which left the sheet component with no
    // end-to-end guard. `monthly.xlsx` is the real-world case: identically-shaped monthly sheets,
    // same columns, different numbers, so ONLY the token can tell them apart.
    let session = try newSession()
    let book = siftCoreTestsFixture("monthly.xlsx")

    let jan = try await session.openPath(book, name: "m", sheet: "Jan")
    _ = try await session.stageNow(jan.name, force: true)
    try await waitForStaged(session, "m")
    try await session.closeTable("m")

    let feb = try await session.openPath(book, name: "m", sheet: "Feb")
    #expect(feb.staged == false, "January's copy is not February")
    let page = try await session.page("m", offset: 0, limit: 10)
    #expect(page.columns.map(\.name) == ["store", "sales"])
    #expect(page.rows.map { $0[1].display } == ["901.0", "902.0", "903.0", "904.0", "905.0"],
            "February's numbers, not January's")

    // The right sheet still adopts its own copy.
    _ = try await session.stageNow("m", force: true)
    try await waitForStaged(session, "m")
    try await session.closeTable("m")
    let again = try await session.openPath(book, name: "m", sheet: "Feb")
    #expect(again.staged == true)
}

@Test func aCopyWhoseTokenFormatPredatesThisBuildIsCollected() throws {
    // `migrateCatalog` resets a store whose catalog KEY is also old. This is the lighter case: the
    // schema is current but the token format bumped (v2 -> v3, when ctime joined the identity).
    // Such a row can never be adopted again, so leaving it is disk nothing will ever reach.
    let con = try Database.inMemory().connect()
    try con.execute(catalogDDL)
    try con.execute("CREATE TABLE old_format AS SELECT 1 AS x")
    try con.execute("CREATE TABLE current AS SELECT 1 AS x")
    let dir = try newTempDir()
    let file = (dir as NSString).appendingPathComponent("src.csv")
    try "x\n1\n".write(toFile: file, atomically: true, encoding: .utf8)
    let real = try statInfo(file)

    func plant(_ name: String, token: String) throws {
        _ = try con.query(
            "INSERT INTO _sift_sources VALUES (?, ?, ?, ?, ?, 'csv', now(), now(), 0, 1)",
            [.text(token), .text(file), .int(Int64(real.mtimeNs)), .int(Int64(real.size)), .text(name)]
        )
    }
    try plant("old_format", token: "v2|\(file)|\(real.mtimeNs)|\(real.size)")
    try plant("current", token: "\(stagingTokenVersion)|whatever")

    let dropped = try Session.purgeStagedTables(con, open: [], tables: nil, all: false)
    #expect(dropped == ["old_format"])
    #expect(try con.query("SELECT count(*) FROM _sift_sources").allRows()[0][0] == .int(1),
            "the current-format row is left alone")
}

// MARK: - N4 (folder half): a member rewritten with its timestamp restored

@Test func aCopyIsNotAdoptedWhenAFolderMemberWasRewrittenWithItsTimestampRestored() async throws {
    // The file half of this is `aCopyIsNotAdopted…TimestampRestored`; this is the per-member half,
    // which was unpinned — removing ctime from the digest left all 320 green. Written by the
    // round-2 reviewer, delivered as-is apart from naming and these comments.
    //
    // The premises are what make it load-bearing: the member's mtime and size are restored to the
    // nanosecond, AND the directory's own stat — ctime included — never moves, because rewriting a
    // member in place is not a directory-entry change. So nothing about this folder looks different
    // except the member's ctime, which the kernel maintains and userspace cannot set.
    let dir = try newTempDir()
    let header = "order_id,region,amount,note\n"
    let a = (dir as NSString).appendingPathComponent("a.csv")
    try (header + "1,West,100.50,a\n").write(toFile: a, atomically: true, encoding: .utf8)
    try (header + "2,South,200.50,b\n").write(
        toFile: (dir as NSString).appendingPathComponent("b.csv"), atomically: true, encoding: .utf8)

    let session = try newSession()
    let t = try await session.openPath(dir)
    _ = try await session.stageNow(t.name, force: true)
    try await waitForStaged(session, t.name)
    try await session.closeTable(t.name)

    let originalDir = try statInfo(dir)
    let originalMember = try statInfo(a)
    try (header + "1,West,999.50,z\n").write(toFile: a, atomically: false, encoding: .utf8)
    var times = [
        timespec(tv_sec: originalMember.mtimeNs / 1_000_000_000,
                 tv_nsec: originalMember.mtimeNs % 1_000_000_000),
        timespec(tv_sec: originalMember.mtimeNs / 1_000_000_000,
                 tv_nsec: originalMember.mtimeNs % 1_000_000_000),
    ]
    #expect(utimensat(AT_FDCWD, a, &times, 0) == 0)
    let forgedMember = try statInfo(a)
    let afterDir = try statInfo(dir)
    #expect(forgedMember.mtimeNs == originalMember.mtimeNs && forgedMember.size == originalMember.size,
            "premise: the member's mtime and size are indistinguishable from the staged folder's")
    #expect(afterDir.mtimeNs == originalDir.mtimeNs && afterDir.ctimeNs == originalDir.ctimeNs,
            "premise: the directory's own stat, ctime included, did not move")

    let again = try await session.openPath(dir)
    #expect(again.staged == false, "a member's ctime moved, so this is not the folder that was copied")
    let page = try await session.page(again.name, offset: 0, limit: 10)
    let amounts = page.rows.map { $0[2].display }.sorted()
    #expect(amounts.contains("999.5") || amounts.contains("999.50"),
            "the disk's contents, not the copy's; got \(amounts)")
}
