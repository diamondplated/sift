import Testing
import Foundation
import TestSupport
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

private func newSessionHome() -> String { TestTemp.path("profile-generation-tests") }

/// The fixtures here are the widest in the suite: left behind they were measured at 1.7 GB across
/// 28 runs, which is why this file grew a per-test `defer` before anything else did. That defer is
/// gone — `TestTemp` removes the whole per-process root at exit, so the 28-run number is now
/// structurally impossible rather than one file's discipline.
private func tempDir() throws -> String { TestTemp.dir("profile-gen") }

/// A small parquet table. Parquet rather than CSV because it costs almost nothing to open — the
/// schema and row count come out of the footer, so there is no `sniff_csv` per column and the
/// post-open pipeline has neither an exact count nor an all-varchar bad-row scan to run.
///
/// **It used to be 200 columns x 500 rows, and that was load-bearing for the wrong reason.** These
/// tests have to act while a profile is in flight, and width was how they bought the time to: the
/// profiling cost is per-COLUMN, so 200 of them took ~700 ms against a ~10 ms close-and-reopen.
/// That margin was a property of the machine, not the code, and it inverted on CI. `ProfileGate`
/// holds the job instead, so the margin is not needed — VERIFIED by running these tests at both
/// extremes: a 3-second stall injected at the moment the race used to be lost (4x longer than the
/// job itself takes), and a fixture this narrow, where the job's DuckDB work is under a
/// millisecond. Both pass. Nothing here depends on the profile being slow any more, and leaving
/// 200 columns in place would tell the next reader it still does.
private func smallFixture(dir: String, name: String, cols: Int, rows: Int) throws -> String {
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
func waitForProfileJob(_ session: Session, _ name: String) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while try await session.table(name).profiling == false {
        if Date() > deadline { return false }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// A one-shot gate a profile job is held at, installed as `Session.profileBarrierForTest`.
///
/// **This replaces a retry loop that replaced a hope, and the progression is the point.** These
/// tests have to deliver a result while a real job is registered, and the first version got there
/// by simply being faster than the job. That passed here and failed 6 times out of 6 on the
/// macos-15 runner: the job runs on DuckDB's own threads while the close-and-reopen queues on the
/// cooperative pool, so a 70x margin measured solo inverts on a slower, more contended machine.
/// Retrying the premise made that honest — a lost race went red instead of quietly proving nothing
/// — but it was still a bet on the environment, and CI is a slower environment than either
/// developer Mac. Holding the job removes the machine from the question entirely: the job is in
/// flight because the test is holding it, not because the test won a race.
///
/// Suspends the job rather than blocking its thread — `withCheckedContinuation`, not a semaphore.
/// A blocking barrier would hold a cooperative-pool thread for the length of the test, which is a
/// new environment dependence (thread availability on a 2-core runner) in the middle of a fix for
/// an environment dependence. `open()` is synchronous so a `defer` can guarantee it even when an
/// assertion fails partway through; it is one-shot, so jobs started afterwards — including the
/// ones `computeProfile`'s own retry starts — pass straight through instead of deadlocking.
///
/// `@unchecked Sendable` around an `NSLock` is the same documented exception `StageJob` makes.
// Not `private`: RemoteOpenTests reuses both of these to hold a profile job across a Refresh —
// the same window, the same reason, and a second copy of a synchronisation primitive is a second
// place for it to be subtly wrong.
final class ProfileGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Called on the profile job's own task, before it touches DuckDB.
    func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiting.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiting
        waiting = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

// MARK: - guard 2: the table under this name moved on

@Test func aProfileFinishedForAClosedAndReopenedTableIsRejected() async throws {
    // Kills the `tables[name]?.openedAt == openedAt` guard, and only that guard: the delivery
    // below carries the live claim's own job ID, so guard 1 is proven to wave it through first.
    let dir = try tempDir()
    let firstPath = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)
    // Same column names as the first file: after the gate opens, the held job runs its second
    // query against whatever "x" now means, and a file that lacked those columns would fail it —
    // a different path than the one under test.
    let reopenedPath = try smallFixture(dir: dir, name: "reopened.parquet", cols: 8, rows: 3)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    await session.setProfileBarrierForTest { await gate.hold() }

    let first = try await session.openPath(firstPath, name: "x")
    // Speculative kick, exactly as the UI does after its first page: started, never awaited.
    Task { _ = try? await session.computeProfile("x") }
    try #require(await waitForProfileJob(session, "x"), "the profile job never registered")

    try await session.closeTable("x")
    let second = try await session.openPath(reopenedPath, name: "x")
    #expect(first.openedAt != second.openedAt, "reopening must bump the generation")

    // Delivering under the LIVE claim's own id is what forces guard 1 to wave this through, so
    // guard 2 is the only thing left that can reject it. The gate is what makes that claim
    // certainly still there rather than probably: the job cannot retire it while it is held.
    let claim = try #require(await session.profileJobs["x"], "the held job's claim was gone")
    #expect(
        claim.openedAt == first.openedAt,
        "the claim must belong to the FIRST open, or guard 1 does the rejecting"
    )

    // The wide file's profile under the wide file's generation — exactly what the held job will
    // itself deliver when it is released.
    let stale = (0..<8).map {
        ColumnProfile(name: "c\($0)", type: "BIGINT", kind: .number, n: 4_000)
    }
    await session.applyProfile("x", stale, jobID: claim.id, openedAt: first.openedAt)

    let after = try await session.table("x")
    #expect(
        after.profile?.contains { $0.n == 4_000 } != true,
        "the previous file's 500-row profile must not be served as this 3-row file's"
    )
}

// MARK: - guard 1: the claim was revoked

@Test func aRevokedProfileJobsLateResultCannotStealTheReplacementsClaim() async throws {
    // Kills the `profileJobs[name]?.id == jobID` guard. Comparing `openedAt` there instead — which
    // is what shipped — passes this delivery, because the replacement registered under the same
    // generation: the stale profile is cached, the replacement's claim is deleted, and the
    // replacement's own correct result is then rejected and lost.
    let dir = try tempDir()
    let path = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    let t = try await session.openPath(path, name: "x")

    // Job A, run to completion BEFORE the gate is installed — so its id is a real issued id and
    // nothing is being held yet.
    _ = try await session.computeProfile("x")
    let revoked = await session.nextProfileJobID
    #expect(revoked == 1, "the first profile of a table is job 1")
    await session.setProfileBarrierForTest { await gate.hold() }

    // The revocation, at its real site: `applyStaged` publishes a copy, drops the profile, and
    // drops the claim. It does NOT reopen the table, which is the entire defect.
    _ = await session.applyStaged(
        "x", physicalRows: 500, openedAt: t.openedAt, jobID: "no-such-job"
    )
    #expect(try await session.table("x").profile == nil, "a published copy drops the profile")

    // The replacement, exactly as `runStage` kicks it immediately afterwards — held at the gate,
    // so it is genuinely registered and genuinely unfinished when job A's result arrives.
    Task { _ = try? await session.computeProfile("x") }
    try #require(await waitForProfileJob(session, "x"), "the replacement never registered")
    let replacement = try #require(await session.profileJobs["x"])
    #expect(
        replacement.openedAt == t.openedAt,
        "the replacement registers under the SAME generation — that is why this is a bug"
    )
    #expect(replacement.id != revoked, "and it is a different job")

    // Job A's result, arriving late. It describes the view the copy replaced, and it must land
    // nowhere — neither in the cache, nor by evicting the live claim. Both halves are asserted
    // while the gate is still shut, so neither depends on what the replacement does next.
    let stale = [ColumnProfile(name: "STALE_MARKER", type: "BIGINT", kind: .number, n: 1)]
    await session.applyProfile("x", stale, jobID: revoked, openedAt: t.openedAt)
    let stillClaimed = await session.profileJobs["x"]
    #expect(stillClaimed?.id == replacement.id, "it must not evict the live claim")
    #expect(try await session.table("x").profile == nil, "and it must not be cached")

    // Released: the replacement's own, correct result must still be the one that lands.
    gate.open()
    let deadline = Date().addingTimeInterval(30)
    while try await session.table("x").profile == nil {
        if Date() > deadline { Issue.record("the replacement profile never landed"); return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let landed = try #require(try await session.table("x").profile)
    #expect(landed.count == 8, "got \(landed.map(\.name).prefix(3))")
    #expect(!landed.contains { $0.name == "STALE_MARKER" })
}

// MARK: - the value the caller is handed, not just the value the catalog keeps

@Test func anAwaitedProfileDescribesTheTableThatIsOpenNowNotTheOneItWasLaunchedFor() async throws {
    // The hole detaching the work opened, which the `openedAt` guard did not close: `rel` is a
    // bare quoted NAME, so the job's `SUMMARIZE "x"` binds when it RUNS. REPRODUCED before the fix
    // — the awaiting `profileOf` returned the reopened file's numbers while the cache correctly
    // refused them, so `histogram` would draw one file's bin bounds over another file's data and
    // `distinct` would seed its exact/approximate decision from them.
    let dir = try tempDir()
    let firstPath = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)
    let reopenedPath = try smallFixture(dir: dir, name: "reopened.parquet", cols: 8, rows: 30)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    await session.setProfileBarrierForTest { await gate.hold() }

    let first = try await session.openPath(firstPath, name: "x")
    let panel = Task { try await session.profileOf("x", col: "c0") }
    try #require(await waitForProfileJob(session, "x"), "the profile job never registered")

    try await session.closeTable("x")
    let second = try await session.openPath(reopenedPath, name: "x")
    #expect(first.openedAt != second.openedAt, "reopening must bump the generation")
    let awaited = try #require(await session.profileJobs["x"], "the held job's claim was gone")
    #expect(
        awaited.openedAt == first.openedAt,
        "the awaited job must still be the one launched for the file that is now gone"
    )

    // Released only now, so its `SUMMARIZE "x"` binds a name that has meant a different file since
    // before it ran a single query.
    gate.open()
    let returned = try await panel.value
    // The catalog is the authority on which results belong to this table, and the value handed to
    // the caller has to agree with it. Before the fix the catalog held nothing at all here, while
    // the caller was handed a full profile of a file it had not asked about.
    let cached = try #require(try await session.table("x").profile, "nothing was ever cached")
    let live = try #require(cached.first { $0.name == "c0" })
    #expect(returned == live, "the awaited profile must be the one the catalog accepted")
    #expect(returned.n == 30, "it must describe the file open under this name NOW")
}

@Test func closingATableWhileItsPanelLoadsGivesThePanelASentenceNotACatalogDump() async throws {
    // The other half of the same hole: a job bound by NAME does not merely return the wrong answer
    // when the name moves, it can FAIL — `closeTable` drops the view underneath it, so its query
    // dies with `Catalog Error: Table with name x does not exist!`. Handing that to the panel is a
    // DuckDB dump for an ordinary "the user closed the tab", and it is a lie about whose failure
    // it was. A job's error is never the caller's unless the table it was launched for is still
    // the one open.
    let dir = try tempDir()
    let firstPath = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    await session.setProfileBarrierForTest { await gate.hold() }

    _ = try await session.openPath(firstPath, name: "x")
    let panel = Task { try await session.profileOf("x", col: "c0") }
    try #require(await waitForProfileJob(session, "x"), "the profile job never registered")
    // Held, so the close is guaranteed to land BEFORE the job's first query rather than merely
    // likely to: the view is already gone when it is released.
    try await session.closeTable("x")
    gate.open()

    do {
        _ = try await panel.value
        Issue.record("expected the panel to fail once its table was closed")
    } catch let error as SessionError {
        #expect(error.message == "No open table named 'x'.", "got: \(error.message)")
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
    let firstPath = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    await session.setProfileBarrierForTest { await gate.hold() }

    _ = try await session.openPath(firstPath, name: "x")
    let panel = Task { try await session.distinct("x", col: "c0") }
    // `profiling == true` means `distinct` is already suspended inside `profileOf`: its top-N
    // query has run, and the stats query has not. That is exactly the window, and the gate holds
    // it open rather than hoping to catch it.
    try #require(await waitForProfileJob(session, "x"), "the profile job never registered")
    try await session.closeTable("x")
    gate.open()

    do {
        _ = try await panel.value
        Issue.record("expected the panel to fail once its table was closed")
    } catch let error as SessionError {
        #expect(error.message == "No open table named 'x'.", "got: \(error.message)")
    }
}

// MARK: - what the registry is actually for

@Test func concurrentProfileCallsShareOneJobAndPublishTheProfilingFlag() async throws {
    // Coalescing is the entire reason `profileJobs` exists — the UI kicks a profile speculatively
    // after the first page and every panel asks for one on click — and nothing pinned it, so a
    // regression to one `SUMMARIZE` per caller would have been silent and seconds wide.
    // `nextProfileJobID` counts REGISTRATIONS, so it is the coalescing count directly.
    let dir = try tempDir()
    let path = try smallFixture(dir: dir, name: "first.parquet", cols: 8, rows: 500)

    let gate = ProfileGate()
    defer { gate.open() }
    let session = try Session(home: newSessionHome())
    await session.setProfileBarrierForTest { await gate.hold() }

    _ = try await session.openPath(path, name: "x")
    #expect(await session.nextProfileJobID == 0, "opening a file does not profile it")

    let callers = (0..<12).map { _ in Task { try await session.computeProfile("x") } }

    // `Table.profiling` is newly reachable — while `computeProfile` ran on the actor it was set
    // and cleared without ever suspending, so `true` was unobservable by construction. It is the
    // flag a spinner renders from, and it appeared in this suite only as a polling gate, never as
    // an assertion. With the job held, "observably true" is a fact rather than a window.
    try #require(
        await waitForProfileJob(session, "x"),
        "Table.profiling must be observably true while a profile is in flight"
    )
    gate.open()

    var counts: Set<Int> = []
    for caller in callers { counts.insert(try await caller.value.count) }
    #expect(counts == [8], "every caller gets the same complete profile")
    #expect(await session.nextProfileJobID == 1, "12 concurrent callers must share ONE SUMMARIZE")
    #expect(try await session.table("x").profiling == false, "the flag must clear when the job lands")
    let retired = await session.profileJobs["x"]
    #expect(retired == nil, "a landed job retires its own claim")
}
