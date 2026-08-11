import Testing
import Foundation
@testable import SiftCore
@testable import SiftEngine

// The open-generation guards on `applyProfile`, which detaching `computeProfile` made necessary
// and which nothing else in the suite reaches.
//
// Both guards were unpinned when this file was written: deleting EITHER one on its own left all
// 412 tests green.
//
//   guard profileJobs[name]?.openedAt == openedAt   <- revocation: staging removes the job
//   guard tables[name]?.openedAt == openedAt        <- reopen: the table moved on
//
// Only the second is pinned here. The first turned out not to guarantee what its own comment
// claims — see the note at the bottom of this file, which is a finding, not a gap in the test.
//
// The reopen case is reachable specifically because `closeTable` does NOT clear `profileJobs`.
// A profile started before a close is still registered under the same name afterwards, so when
// its result lands the FIRST guard matches and waves it through — only the second rejects it.
// That is the profile-shaped form of the regression that once reported 3,000,000 rows for a
// 10-row file, and it is why both guards stay.

private func newSessionHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-generation-tests-\(UUID().uuidString)").path
}

private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-gen-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// Wide enough that `computeProfile` is still in flight while a close-and-reopen of a 3-row file
/// completes. The bench in `ProfileBenchTests` measures 200 columns x 200k rows at ~6.6 s; this is
/// deliberately far smaller but still hundreds of milliseconds, against a reopen that is single
/// -digit. The assertion does not depend on the timing — a profile that finishes early is simply
/// applied to its own table and the reopened table still has none.
private func makeWideCSV(dir: String, cols: Int, rows: Int) throws -> String {
    let path = (dir as NSString).appendingPathComponent("wide.csv")
    var out = (0..<cols).map { "c\($0)" }.joined(separator: ",") + "\n"
    for r in 0..<rows {
        out += (0..<cols).map { String(r &* 31 &+ $0) }.joined(separator: ",") + "\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func makeNarrowCSV(dir: String) throws -> String {
    let path = (dir as NSString).appendingPathComponent("narrow.csv")
    try "only_column\nalpha\nbeta\ngamma\n".write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Test func aProfileFinishedForAClosedAndReopenedTableIsRejected() async throws {
    // Kills the `tables[name]?.openedAt == openedAt` guard. The first guard cannot catch this:
    // `closeTable` leaves `profileJobs["x"]` registered under the OLD generation, so a result
    // carrying that same generation matches it exactly.
    let session = try Session(home: newSessionHome())
    let dir = try tempDir()
    let widePath = try makeWideCSV(dir: dir, cols: 200, rows: 60_000)
    let narrowPath = try makeNarrowCSV(dir: dir)

    let first = try await session.openPath(widePath, name: "x")
    // Speculative kick, exactly as the UI does after its first page: started, never awaited.
    Task { _ = try? await session.computeProfile("x") }

    // Wait for the job to actually REGISTER before closing. A `Task {}` is not guaranteed to have
    // started at the next line, so without this the job is never registered, `profileJobs["x"]` is
    // nil, and the FIRST guard rejects — which made the earlier draft of this test pass with the
    // second guard deleted. `profiling` is published synchronously inside `profileJob(for:)`, in
    // the same actor step that registers the job, so it is the exact signal wanted here.
    let registered = Date().addingTimeInterval(10)
    while try await session.table("x").profiling == false {
        if Date() > registered { Issue.record("the profile job never registered"); return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }

    try await session.closeTable("x")
    let second = try await session.openPath(narrowPath, name: "x")
    #expect(first.openedAt != second.openedAt, "reopening must bump the generation")

    // Deliver the wide file's profile under the wide file's generation, which is what the
    // in-flight job will itself do when it finishes.
    let stale = (0..<200).map {
        ColumnProfile(name: "c\($0)", type: "BIGINT", kind: .number, n: 4_000)
    }
    await session.applyProfile("x", stale, openedAt: first.openedAt)

    let after = try await session.table("x")
    #expect(
        after.profile?.contains { $0.name.hasPrefix("c") } != true,
        "the previous file's 200 columns must not be served as this file's profile"
    )
    if let landed = after.profile {
        #expect(landed.count == 1 && landed[0].name == "only_column")
    }
}

// NOT WRITTEN: a test for the `profileJobs[name]?.openedAt == openedAt` guard.
//
// An attempt is recorded in the ledger and was deleted rather than shipped, because it asserted
// something the code does not actually guarantee. Staging revokes the in-flight job
// (`Staging.swift:343`) and then re-profiles immediately — and staging does NOT reopen the table,
// so the replacement job registers under the SAME `openedAt`. A result computed against the
// pre-staging view therefore matches the new job's generation and is accepted, unless it happens
// to land in the window after the revocation and before the replacement registers. The test
// passed in isolation and failed in the full parallel suite for exactly that reason.
//
// So the guard's own doc comment overstates it: revocation is not sufficient to reject a profile
// computed against the old relation. The consequence is small — a staged copy holds the same rows
// as the view it replaced — but the guard should either be strengthened to carry a job identity
// that changes on revocation, or its comment corrected to say what it really does. Left for the
// review this salvaged work still owes.
