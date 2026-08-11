import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Everything that keeps a detached profile honest: the two guards on `applyProfile`, the
// generation check on the value `computeProfile` hands back, and the coalescing and `profiling`
// flag that only exist because the work is detached at all. Nothing else in the suite reaches any
// of it.
//
//   guard profileJobs[name]?.id == jobID      <- revocation: staging/unstaging drops the claim
//   guard tables[name]?.openedAt == openedAt  <- reopen: the table under this name moved on
//
// The two are genuinely independent, and each has its own test below.
//
//   * The REOPEN case is reachable because `closeTable` does NOT clear `profileJobs`. A profile
//     started before a close is still the claim holder afterwards, so the first guard waves its
//     result through and only the second rejects it. That is the profile-shaped form of the
//     regression that once reported 3,000,000 rows for a 10-row file.
//   * The REVOCATION case is reachable because `applyStaged`/`unstage` drop the claim WITHOUT
//     reopening the table, so the replacement they kick registers under the SAME `openedAt`. That
//     is why the first guard compares job IDs and not generations: comparing generations accepted
//     the revoked job's result AND deleted the replacement's claim, so the correct profile that
//     arrived moments later was itself dropped and the stale one stayed cached for the life of
//     the table.

private func newSessionHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-generation-tests-\(UUID().uuidString)").path
}

/// Removed by each test's own `defer`. The fixtures here are the widest in the suite, and left
/// behind they were measured at 1.7 GB across 28 runs — ~55x the suite's usual per-invocation temp
/// cost, which is a different thing from the suite's general habit of leaking small dirs.
private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-gen-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Wide, not long, and PARQUET — all three matter, and all three are measured.
///
/// * Wide: profiling cost is per-COLUMN. 200 columns profile in ~700 ms; 500 rows versus 5,000
///   moved that by ~100 ms, so rows buy nothing here.
/// * Parquet, not CSV: a CSV view re-parses the file for each of the two profiling queries
///   (MEASURED: this same 200 x 500 shape takes ~5.2 s as CSV), and `openPath` on a 200-column CSV
///   pays a `sniff_csv` per column. Parquet carries its schema and row count in its footer, so the
///   close-and-reopen the tests below race against costs ~10 ms instead of ~70 ms, and the
///   post-open pipeline has neither an exact count nor an all-varchar bad-row scan to run.
///
/// ~460 KB, versus the 67 MB this file used to write per run and never clean up.
private func wideFixture(dir: String, name: String, cols: Int, rows: Int) throws -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    let exprs = (0..<cols).map { "((i * \($0 + 7)) % 100000)::BIGINT AS c\($0)" }
    let con = try Database.inMemory().connect()
    try con.execute(
        "COPY (SELECT \(exprs.joined(separator: ", ")) FROM range(\(rows)) t(i)) "
            + "TO \(qlit(path)) (FORMAT PARQUET)"
    )
    return path
}

/// Poll until the job registers. `profiling` is published in the same non-`async` step of
/// `profileJob(for:)` that registers the job, so it cannot be observed apart from it — which makes
/// it the exact signal wanted here.
private func waitForProfileJob(_ session: Session, _ name: String) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while try await session.table(name).profiling == false {
        if Date() > deadline { return false }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// Run `attempt` until it reports that its premise held — that the profile job it needs was still
/// in flight when it acted — and fail the test if that never happens.
///
/// **This is the shape the version of this file that shipped got wrong, and the reason it is worth
/// six lines.** Three of the tests below have to act while a real profile is running, and that is
/// a race the test can lose: the job runs on DuckDB's own threads while the close-and-reopen
/// queues on the cooperative pool, so under a saturated parallel suite the job can finish first
/// even against a 70x margin measured solo (OBSERVED: 1 run in 8). An attempt that lost that race
/// proves nothing — and, crucially, must not be allowed to prove the code RIGHT, which is exactly
/// what the shipped test did: with the reopen guard deleted and the job finishing early, it passed.
/// So the premise is retried, never assumed, and never quietly skipped: a run that cannot win the
/// race in six attempts is red.
private func withAProfileStillInFlight(
    _ what: String, _ attempt: () async throws -> Bool
) async throws {
    for _ in 0..<6 {
        if try await attempt() { return }
    }
    Issue.record("\(what): no attempt kept a profile in flight long enough to test anything")
}

// MARK: - guard 2: the table under this name moved on

@Test func aProfileFinishedForAClosedAndReopenedTableIsRejected() async throws {
    // Kills the `tables[name]?.openedAt == openedAt` guard, and only that guard: the delivery
    // below carries the live claim's own job ID, so guard 1 is proven to wave it through first.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let widePath = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)
    // Same column names as the wide file on purpose: the in-flight job's second query names all
    // 200 of them, and a reopened file that lacked them would fail that query and make the job
    // retire its own claim — losing the race for a reason that has nothing to do with the guard.
    let shortPath = try wideFixture(dir: dir, name: "short.parquet", cols: 200, rows: 3)

    try await withAProfileStillInFlight("the reopen guard") {
        let session = try Session(home: newSessionHome())
        let first = try await session.openPath(widePath, name: "x")
        // Speculative kick, exactly as the UI does after its first page: started, never awaited.
        Task { _ = try? await session.computeProfile("x") }
        guard try await waitForProfileJob(session, "x") else {
            Issue.record("the profile job never registered"); return true
        }

        try await session.closeTable("x")
        let second = try await session.openPath(shortPath, name: "x")
        #expect(first.openedAt != second.openedAt, "reopening must bump the generation")

        // THE PREMISE. Delivering under the LIVE claim's own id is what forces guard 1 to wave
        // this through, so that guard 2 is the only thing left that can reject it. If the job has
        // already retired its claim there is nothing to deliver under, and this attempt is thrown
        // away rather than counted as a pass.
        guard let claim = await session.profileJobs["x"] else { return false }
        #expect(
            claim.openedAt == first.openedAt,
            "the claim must belong to the FIRST open, or guard 1 does the rejecting"
        )

        // The wide file's profile under the wide file's generation — exactly what the in-flight
        // job will itself deliver when it finishes.
        let stale = (0..<200).map {
            ColumnProfile(name: "c\($0)", type: "BIGINT", kind: .number, n: 4_000)
        }
        await session.applyProfile("x", stale, jobID: claim.id, openedAt: first.openedAt)

        let after = try await session.table("x")
        #expect(
            after.profile?.contains { $0.n == 4_000 } != true,
            "the previous file's 500-row profile must not be served as this 3-row file's"
        )
        return true
    }
}

// MARK: - guard 1: the claim was revoked

@Test func aRevokedProfileJobsLateResultCannotStealTheReplacementsClaim() async throws {
    // Kills the `profileJobs[name]?.id == jobID` guard. Comparing `openedAt` there instead — which
    // is what shipped — passes this delivery, because the replacement registered under the same
    // generation: the stale profile is cached, the replacement's claim is deleted, and the
    // replacement's own correct result is then rejected and lost.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)

    try await withAProfileStillInFlight("the claim guard") {
        let session = try Session(home: newSessionHome())
        let t = try await session.openPath(path, name: "x")
        // Job A, run to completion so its id is known without racing anything.
        _ = try await session.computeProfile("x")
        let revoked = await session.nextProfileJobID
        #expect(revoked == 1, "the first profile of a table is job 1")

        // The revocation, at its real site: `applyStaged` publishes a copy, drops the profile, and
        // drops the claim. It does NOT reopen the table, which is the entire defect.
        _ = await session.applyStaged(
            "x", physicalRows: 500, openedAt: t.openedAt, jobID: "no-such-job"
        )
        #expect(try await session.table("x").profile == nil, "a published copy drops the profile")

        // The replacement, exactly as `runStage` kicks it immediately afterwards.
        Task { _ = try? await session.computeProfile("x") }
        guard try await waitForProfileJob(session, "x") else {
            Issue.record("the replacement profile job never registered"); return true
        }
        guard let replacement = await session.profileJobs["x"] else { return false }
        #expect(
            replacement.openedAt == t.openedAt,
            "the replacement registers under the SAME generation — that is why this is a bug"
        )
        #expect(replacement.id != revoked, "and it is a different job")

        // Job A's result, arriving late. It describes the view the copy replaced, and it must land
        // nowhere — neither in the cache, nor by evicting the live claim.
        let stale = [ColumnProfile(name: "STALE_MARKER", type: "BIGINT", kind: .number, n: 1)]
        await session.applyProfile("x", stale, jobID: revoked, openedAt: t.openedAt)
        let stillClaimed = await session.profileJobs["x"]
        #expect(stillClaimed?.id == replacement.id, "it must not evict the live claim")

        // And the replacement's own, correct result must still be the one that lands.
        let deadline = Date().addingTimeInterval(30)
        while try await session.table("x").profile == nil {
            if Date() > deadline { Issue.record("the replacement profile never landed"); return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let landed = try #require(try await session.table("x").profile)
        #expect(landed.count == 200, "got \(landed.map(\.name).prefix(3))")
        #expect(!landed.contains { $0.name == "STALE_MARKER" })
        return true
    }
}

// MARK: - the value the caller is handed, not just the value the catalog keeps

@Test func anAwaitedProfileDescribesTheTableThatIsOpenNowNotTheOneItWasLaunchedFor() async throws {
    // The hole detaching the work opened, which the `openedAt` guard did not close: `rel` is a
    // bare quoted NAME, so the job's `SUMMARIZE "x"` binds when it RUNS. REPRODUCED before the fix
    // — the awaiting `profileOf` returned the reopened file's numbers while the cache correctly
    // refused them, so `histogram` would draw one file's bin bounds over another file's data and
    // `distinct` would seed its exact/approximate decision from them.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let widePath = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)
    let shortPath = try wideFixture(dir: dir, name: "short.parquet", cols: 200, rows: 30)

    try await withAProfileStillInFlight("the awaited-result guard") {
        let session = try Session(home: newSessionHome())
        let first = try await session.openPath(widePath, name: "x")
        let panel = Task { try await session.profileOf("x", col: "c0") }
        guard try await waitForProfileJob(session, "x") else {
            Issue.record("the profile job never registered"); return true
        }

        try await session.closeTable("x")
        let second = try await session.openPath(shortPath, name: "x")
        #expect(first.openedAt != second.openedAt, "reopening must bump the generation")
        // PREMISE: the awaited job must still be the one launched for the file that is now gone.
        // If it already landed, this caller was answered while its own table was still open —
        // correct behavior, and nothing stale was ever awaited.
        let awaited = await session.profileJobs["x"]
        guard awaited?.openedAt == first.openedAt else {
            _ = try? await panel.value
            return false
        }

        let returned = try await panel.value
        // The catalog is the authority on which results belong to this table, and the value handed
        // to the caller has to agree with it. Before the fix the catalog held nothing at all here,
        // while the caller was handed a full profile of a file it had not asked about.
        let cached = try #require(try await session.table("x").profile, "nothing was ever cached")
        let live = try #require(cached.first { $0.name == "c0" })
        #expect(returned == live, "the awaited profile must be the one the catalog accepted")
        #expect(returned.n == 30, "it must describe the file open under this name NOW")
        return true
    }
}

@Test func closingATableWhileItsPanelLoadsGivesThePanelASentenceNotACatalogDump() async throws {
    // The other half of the same hole: a job bound by NAME does not merely return the wrong answer
    // when the name moves, it can FAIL — `closeTable` drops the view underneath it, so its second
    // query dies with `Catalog Error: Table with name x does not exist!`. Handing that to the panel
    // is a DuckDB dump for an ordinary "the user closed the tab", and it is a lie about whose
    // failure it was. A job's error is never the caller's unless the table it was launched for is
    // still the one open.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let widePath = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)

    try await withAProfileStillInFlight("the closed-mid-panel error") {
        let session = try Session(home: newSessionHome())
        _ = try await session.openPath(widePath, name: "x")
        let panel = Task { try await session.profileOf("x", col: "c0") }
        guard try await waitForProfileJob(session, "x") else {
            Issue.record("the profile job never registered"); return true
        }
        try await session.closeTable("x")

        do {
            _ = try await panel.value
            // The job beat the close and answered for the table that was still open. Correct, and
            // not what this test is about.
            return false
        } catch let error as SessionError {
            #expect(error.message == "No open table named 'x'.", "got: \(error.message)")
            return true
        }
    }
}

@Test func closingATableWhileTheDistinctPanelLoadsGivesItASentenceNotACatalogDump() async throws {
    // The same close, one panel over. `histogram` lets `profileOf` propagate and reports
    //     No open table named 'x'.
    // `distinct` wrapped the identical call in `try?`, threw that sentence away, and then ran its
    // stats query against a relation `closeTable` had just dropped — so the user closing a tab got
    //     Catalog Error: Table with name x does not exist!
    // This is the fourth instance of the "one clean sentence, never a parser dump" contract
    // breaking in this plan, and it reopens one `ced8df7` fixed a level up (its own comment says
    // "that used to surface as a raw 'Catalog Error…' when a user closed a tab mid-panel"). It is
    // in the panel the UI calls on EVERY column click.
    //
    // The `try?` was there for a real reason — Python's own bare `except Exception: pass`, so a
    // table whose profile fails still renders the panel. That reason does not survive contact with
    // this case: the profile did not fail, the TABLE went away, and the very next query is going
    // to fail for the same reason with a worse message.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let widePath = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)

    try await withAProfileStillInFlight("the closed-mid-distinct error") {
        let session = try Session(home: newSessionHome())
        _ = try await session.openPath(widePath, name: "x")
        let panel = Task { try await session.distinct("x", col: "c0") }
        guard try await waitForProfileJob(session, "x") else {
            Issue.record("the profile job never registered"); return true
        }
        // `profiling == true` means `distinct` is already suspended inside `profileOf`: its top-N
        // query has run, and the stats query has not. That is exactly the window.
        try await session.closeTable("x")

        do {
            _ = try await panel.value
            // The profile beat the close and the panel was built for the table that was still
            // open. Correct, and not what this test is about.
            return false
        } catch let error as SessionError {
            #expect(error.message == "No open table named 'x'.", "got: \(error.message)")
            return true
        }
    }
}

// MARK: - what the registry is actually for

@Test func concurrentProfileCallsShareOneJobAndPublishTheProfilingFlag() async throws {
    // Coalescing is the entire reason `profileJobs` exists — the UI kicks a profile speculatively
    // after the first page and every panel asks for one on click — and nothing pinned it, so a
    // regression to one `SUMMARIZE` per caller would have been silent and seconds wide.
    // `nextProfileJobID` counts REGISTRATIONS, so it is the coalescing count directly.
    let session = try Session(home: newSessionHome())
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try wideFixture(dir: dir, name: "wide.parquet", cols: 200, rows: 500)

    _ = try await session.openPath(path, name: "x")
    #expect(await session.nextProfileJobID == 0, "opening a file does not profile it")

    let callers = (0..<12).map { _ in Task { try await session.computeProfile("x") } }

    // `Table.profiling` is newly reachable — while `computeProfile` ran on the actor it was set
    // and cleared without ever suspending, so `true` was unobservable by construction. It is the
    // flag a spinner renders from, and it appeared in this suite only as a polling gate, never as
    // an assertion. Unlike the races above this one needs no retry: `waitForProfileJob` starts
    // polling before any caller can finish, and a job that has already landed would leave a
    // cached profile rather than an unobservable flag.
    let sawProfiling = try await waitForProfileJob(session, "x")
    #expect(sawProfiling, "Table.profiling must be observably true while a profile is in flight")

    var counts: Set<Int> = []
    for caller in callers { counts.insert(try await caller.value.count) }
    #expect(counts == [200], "every caller gets the same complete profile")
    #expect(await session.nextProfileJobID == 1, "12 concurrent callers must share ONE SUMMARIZE")
    #expect(try await session.table("x").profiling == false, "the flag must clear when the job lands")
    let retired = await session.profileJobs["x"]
    #expect(retired == nil, "a landed job retires its own claim")
}
