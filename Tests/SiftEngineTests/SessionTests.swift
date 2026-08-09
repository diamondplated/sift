import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Session: catalog, open, background post-open work, paging. session.py has no direct
// engine/tests/test_session.py counterpart to port assertion-for-assertion — Python exercised
// this through FastAPI's app.py over HTTP. These are the Task 4 brief's own required scenarios:
// open -> page contiguity, sorted-page stability across offsets (the reason `_sorted_relation`
// exists), the bad-row accounting `_after_open` produces, filtered vs unfiltered `visibleRows`,
// `~/.sift`'s 0700 enforcement, a table-name collision, and `_sweep_private_stores`.
//
// Each test gets its OWN `~/.sift`-equivalent temp directory (`newSession()`), never the real
// one — Session.init honors an explicit `home:` override for exactly this reason. Swift Testing
// runs tests in parallel, so two tests sharing a home directory would race on DuckDB's exclusive
// file lock; only `sweepPrivateStoresKeepsALiveOwnersStoreAndRemovesADeadOnes` shares one on
// purpose, and only after the owning process (a real `/bin/sleep`, not this test) is reaped.

private let sharedData = try! corpus()

private func newSessionHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-session-tests-\(UUID().uuidString)").path
}

private func newSession() throws -> Session {
    try Session(home: newSessionHome())
}

/// `_after_open`'s background pipeline (count -> bad-row detection -> staging decision) runs
/// detached. Within Task 4's scope, the staging decision is always its last step, so polling for
/// it is a reliable "the background work for this open has finished" signal for a test.
private func waitForBackgroundWork(
    _ session: Session, _ name: String, timeout: TimeInterval = 10
) async throws -> Table {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let t = try await session.table(name)
        if t.stageDecision != nil { return t }
        if Date() > deadline {
            Issue.record("background work for \(name) did not finish within \(timeout)s")
            return t
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// `order_id` is column 0 in every row `SELECT * FROM <clean.csv view>` returns — the file's own
/// first header column, and BIGINT once sniffed (values are bare digit strings "0".."999").
private func orderID(_ row: [Cell]) -> Int {
    guard case .int(let v) = row[0] else {
        Issue.record("order_id was not an int: \(row[0])")
        return -1
    }
    return Int(v)
}

// MARK: - open -> page contiguity

@Test func openThenPageCoversEveryRowExactlyOnce() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    #expect(t.name == "clean")

    var seen = Set<Int>()
    var offset = 0
    let limit = 137   // not a divisor of 1000, so the final page is deliberately ragged
    while true {
        let page = try await session.page(t.name, offset: offset, limit: limit)
        if page.rows.isEmpty { break }
        for row in page.rows { seen.insert(orderID(row)) }
        offset += limit
    }
    #expect(seen == Set(0..<1000))
}

// MARK: - sorted-page stability (the reason `_sorted_relation` exists)

@Test func sortedPagesNeverDuplicateOrDropARowAcrossOffsets() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    // "region" is deliberately non-unique (4 values over 1000 rows): a fresh ORDER BY per page
    // would let ties land on either side of a LIMIT/OFFSET boundary unpredictably, which is
    // exactly the failure `_sorted_relation`'s one-time materialization exists to close.
    await session.replaceQuerySpec(
        t.name, with: QuerySpec(relation: t.name, sort: [.init(column: "region", direction: .asc)])
    )

    var seen: [Int: Int] = [:]   // order_id -> times seen
    var offset = 0
    let limit = 251   // not a divisor of 1000 or of any region's 250-row block
    while true {
        let page = try await session.page(t.name, offset: offset, limit: limit)
        if page.rows.isEmpty { break }
        for row in page.rows { seen[orderID(row), default: 0] += 1 }
        offset += limit
    }
    #expect(seen.count == 1000, "every row should appear — none dropped")
    #expect(seen.values.allSatisfy { $0 == 1 }, "no row should appear on two pages")
}

// MARK: - bad-row accounting

/// Gzips an existing file via a blocking, file-redirected `/usr/bin/gzip -c` — not a `Pipe`, per
/// Fixtures.swift's `makeGzipCSV` comment on the GCD-thread-starvation deadlock that form avoids.
private func gzip(_ sourcePath: String, to destPath: String) throws {
    FileManager.default.createFile(atPath: destPath, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = FileHandle(forReadingAtPath: sourcePath)
    process.standardOutput = FileHandle(forWritingAtPath: destPath)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DuckDBError("gzip exited \(process.terminationStatus)")
    }
}

@Test func gridRowsExcludesBadRowsOnACompressedDirtyCSV() async throws {
    // The corpus's plain `dirtyCSV` (1000 rows, one bad "amount" cell) cannot demonstrate this
    // end to end: under `fullSniffMaxBytes` (50MB) Sift's sniffer scans the WHOLE file, and
    // correctly widens "amount" to VARCHAR the instant it sees one value that cannot be a
    // number — so nothing gets cast, nothing gets dropped, and there is nothing to detect.
    // MEASURED directly against DuckDB 1.5.5's `sniff_csv` (see task-4-report.md).
    //
    // A *compressed* CSV always samples only the first 20,480 rows, regardless of file size —
    // so placing the bad row well past that window reproduces the real scenario
    // `_detect_bad_rows` exists for: the sniffer keeps "amount" numeric from the sample it saw,
    // and `ignore_errors` silently drops the one later row that does not fit it.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let plain = try makeCSV(dir: dir, name: "dirty.csv", rows: 25_000, badIntRow: 21_000)
    let gz = (dir as NSString).appendingPathComponent("dirty.csv.gz")
    try gzip(plain, to: gz)

    let session = try newSession()
    let t = try await session.openPath(gz)
    let settled = try await waitForBackgroundWork(session, t.name)

    #expect(settled.rowCount == 25_000)
    #expect(settled.badRows == 1)
    #expect(settled.gridRows == 24_999)
}

// MARK: - visibleRows: filtered vs unfiltered

@Test func visibleRowsIsTheFilteredCountOnlyWhileAFilterIsActive() {
    let key = SourceKey(path: "/tmp/x.csv", mtimeNs: 0, size: 1000)
    let spec = SourceSpec(
        key: key, fmt: .csv, readFn: "read_csv", columns: [Column(name: "id", type: "BIGINT")]
    )
    var t = Table(name: "x", spec: spec, qspec: QuerySpec(relation: "x"))
    t.rowCount = 1000
    t.badRows = 10
    #expect(t.gridRows == 990)
    #expect(t.visibleRows == 990)   // no filter: the unfiltered (grid) count

    t.qspec = QuerySpec(relation: "x", filters: [Filter(col: "id", op: .gt, values: [.int(5)])])
    #expect(t.visibleRows == 990)   // filter active but not yet counted: falls back to gridRows
    t.filteredCount = 42
    #expect(t.visibleRows == 42)    // filter active and counted
}

@Test func pageCountsTheFilteredRelationOncePerSpecChangeNotPerPage() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    await session.replaceQuerySpec(
        t.name,
        with: QuerySpec(relation: t.name, filters: [Filter(col: "region", op: .eq, values: [.text("West")])])
    )

    let page1 = try await session.page(t.name, offset: 0, limit: 500)
    #expect(page1.rows.count == 250)
    #expect(page1.total.filtered == true)
    #expect(page1.total.value == 250)
    #expect(page1.total.unfiltered == 1000)

    // Past the filtered count: zero rows, but the SAME cached total — proving the count query ran
    // once for this spec, not once per page.
    let page2 = try await session.page(t.name, offset: 500, limit: 500)
    #expect(page2.rows.isEmpty)
    #expect(page2.total.value == 250)
}

// MARK: - ~/.sift permissions (§11 frozen contract)

@Test func siftHomeEndsUpAt0700EvenIfItAlreadyExistedLooser() throws {
    let home = newSessionHome()
    try FileManager.default.createDirectory(
        atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
    )
    let before = try FileManager.default.attributesOfItem(atPath: home)[.posixPermissions] as? Int
    #expect(before == 0o755)

    _ = try Session(home: home)

    let after = try FileManager.default.attributesOfItem(atPath: home)[.posixPermissions] as? Int
    #expect(after == 0o700)
}

// MARK: - table-name collisions

@Test func reopeningTheSameFileGetsA_2Suffix() async throws {
    let session = try newSession()
    let first = try await session.openPath(sharedData.cleanCSV)
    let second = try await session.openPath(sharedData.cleanCSV)
    #expect(first.name == "clean")
    #expect(second.name == "clean_2")

    let state = await session.state()
    #expect(Set(state.tables.map(\.name)) == ["clean", "clean_2"])
}

// MARK: - a fresh session's engine info

@Test func aFreshSessionOwnsTheSharedStore() throws {
    let session = try newSession()
    let info = session.engineInfo()
    #expect(info.sharedStore == true)
    #expect(info.dbPath.hasSuffix("stage.duckdb"))
    #expect(info.extensions.isEmpty == false)   // "delta" and "excel" were at least attempted
}

// MARK: - _sweep_private_stores: telling a dead owner from a live one
//
// The fallback itself (Session.init falling back to `stage-<pid>.duckdb` when the shared store's
// lock is held) has no test here: DuckDB's file lock did not conflict between two `Database`
// instances opened from the SAME process in manual verification — POSIX advisory locks are
// commonly scoped per-process, not per-open-file-description, so a second in-process open cannot
// reproduce the cross-process case the fallback exists for. Python's own test suite has no
// coverage of this path either (no `test_session.py`, and nothing in `engine/tests/**` opens two
// sessions), for what is almost certainly the identical reason. `sweepPrivateStores` — the part
// that does not need a second real process — is fully covered below.

@Test func sweepPrivateStoresKeepsALiveOwnersStoreAndRemovesADeadOnes() throws {
    let home = newSessionHome()
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

    // A real process, so its pid is genuinely live until reaped below — no guessing at a pid
    // that merely looks unused.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    let ownerPID = sleeper.processIdentifier

    let store = (home as NSString).appendingPathComponent("stage-\(ownerPID).duckdb")
    let wal = store + ".wal"
    // Never matches `stage-(\d+)\.duckdb` — no PID digits — so it must survive regardless of
    // anyone's liveness. This is also the shared store's own filename.
    let unrelated = (home as NSString).appendingPathComponent("stage.duckdb")
    for path in [store, wal, unrelated] {
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    }

    Session.sweepPrivateStores(in: home)
    #expect(FileManager.default.fileExists(atPath: store), "a live owner's store must survive")
    #expect(FileManager.default.fileExists(atPath: wal))
    #expect(FileManager.default.fileExists(atPath: unrelated))

    sleeper.terminate()
    sleeper.waitUntilExit()

    Session.sweepPrivateStores(in: home)
    #expect(!FileManager.default.fileExists(atPath: store), "a dead owner's store must be removed")
    #expect(!FileManager.default.fileExists(atPath: wal), "its .wal companion must go too")
    #expect(FileManager.default.fileExists(atPath: unrelated), "a non-matching filename is never touched")
}

// MARK: - sortedRelation survives across page()'s per-call Connection
//
// A regression test for the MEASURED discovery in Session.swift's header: a `TEMP TABLE` created
// on one `Connection` is invisible to a different `Connection` on the same database file, so a
// naive port of `_sorted_relation` (which materializes via `TEMP TABLE`) would work on the FIRST
// sorted page and throw "Catalog Error: ... does not exist" on the second, since `page()` opens a
// fresh `Connection` every call. `sortedPagesNeverDuplicateOrDropARowAcrossOffsets` above already
// pages a sorted table more than once and would fail exactly that way if this regressed; this
// test isolates the mechanism (three page() calls, the smallest number that proves "more than
// once") rather than relying on that test's stability assertion to catch it as a side effect.
@Test func sortedRelationSurvivesMultiplePageCallsEachWithItsOwnConnection() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    await session.replaceQuerySpec(
        t.name, with: QuerySpec(relation: t.name, sort: [.init(column: "region", direction: .asc)])
    )

    _ = try await session.page(t.name, offset: 0, limit: 10)
    _ = try await session.page(t.name, offset: 10, limit: 10)   // would throw if the sort didn't survive
    let third = try await session.page(t.name, offset: 20, limit: 10)
    #expect(third.rows.count == 10)
}
