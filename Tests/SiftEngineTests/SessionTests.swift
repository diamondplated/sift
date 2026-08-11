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
    var t = Table(name: "x", spec: spec, qspec: QuerySpec(relation: "x"), openedAt: 1)
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

    // Overwrite the cache with an impossible sentinel. This is the part that actually proves
    // caching: without it, deleting the `t.filteredCount == nil` guard in page() still passes
    // both assertions above (the data never changes, so a recount also returns 250). If page()
    // recomputed the count, the real value (250) would come back and clobber the sentinel; if it
    // truly reads the cache, the sentinel survives untouched.
    await session.setFilteredCountForTest(t.name, 999_999)
    let page2 = try await session.page(t.name, offset: 0, limit: 500)
    #expect(page2.total.value == 999_999)
    let after = try await session.table(t.name)
    #expect(after.filteredCount == 999_999)
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

// MARK: - the two escape hatches are alternatives, and the engine says so

/// Deleting `openPath`'s two-hatch guard left all 461 tests green. The only test of the pair is
/// the CLI parser's, and its own comment says "Session.openPath throws on the same pair" — a
/// confident comment over a guard no test reached, the same shape as a finding earlier in this
/// plan.
///
/// The refusal is not pedantry: MEASURED, pinning `skip` is exactly what defeats `null_padding`
/// (an explicit `skip=0` is the sniffer's own answer handed back, and restores the collapse), so
/// asking for both silently gets neither — a user following a note that told them how to recover
/// their columns would get the same broken read back with no indication why.
@Test func openPathRefusesBothEscapeHatchesAtOnceRatherThanHonouringNeither() async throws {
    let session = try newSession()
    do {
        _ = try await session.openPath(sharedData.cleanCSV, nullPadding: true, skipPreamble: false)
        Issue.record("openPath accepted both escape hatches and would have honoured neither")
    } catch let error as SessionError {
        #expect(error.message.contains("cannot be combined"), "got: \(error.message)")
        #expect(error.message.contains("Pick one."), "the sentence must say what to do: \(error.message)")
    }
    #expect(await session.state().tables.isEmpty, "a refused open must leave nothing behind")

    // Either hatch ALONE is honoured — otherwise this would pass against an `openPath` that
    // refused every use of them.
    #expect(try await session.openPath(sharedData.cleanCSV, nullPadding: true).rowCount == 1000)
    #expect(try await session.openPath(sharedData.cleanCSV, skipPreamble: false).name == "clean_2")
}

// MARK: - the engine hardens its own database (§11 frozen contract)

/// 🔴 `db.harden()` could be deleted from `Session.init` and all 461 tests stayed green. The only
/// hardening tests live in `DuckDBKitTests/SmokeTests.swift` and call `harden()` THEMSELVES — they
/// prove the method works, and nothing proved the engine calls it. Spec §11 lists the four
/// settings as a frozen contract, so a silent regression here is the whole security posture of a
/// tool that runs arbitrary user SQL against arbitrary local files.
///
/// Asserted on the SETTINGS and on a real refusal, not on the `hardened` flag alone, because §11
/// specifically warns that a test here must assert on the message: `hardened` is a dictionary this
/// engine writes about itself, and a test that only reads it would survive DuckDB renaming a
/// setting out from under the whole layer.
@Test func aSessionHardensTheDatabaseItHandsEveryQuery() async throws {
    let session = try newSession()

    // 1. Every setting `harden()` names actually applied. A `false` here means DuckDB renamed one
    //    and a security layer is silently gone — the exact signal `hardened` exists to carry.
    #expect(session.database.hardened == ["disabled_filesystems": true,
                                          "autoinstall_known_extensions": true,
                                          "autoload_known_extensions": true,
                                          "allow_community_extensions": true])

    // 2. The three readable ones, read back from DuckDB itself on a connection opened AFTER init —
    //    which is every connection the engine makes. `disabled_filesystems` is deliberately absent:
    //    MEASURED, it reads back empty even on the connection that set it, so behaviour below is
    //    the only honest assertion for that one.
    let con = try session.database.connect()
    for setting in ["autoinstall_known_extensions", "autoload_known_extensions",
                    "allow_community_extensions"] {
        let value = try con.query("SELECT current_setting('\(setting)')").allRows()[0][0]
        #expect(value == .bool(false), "\(setting) is not off in a live Session")
    }

    // 3. And the behaviour, through the engine's own SQL box rather than a hand-built connection:
    //    a network read is refused by the extension guard before anything reaches the network.
    //    With `harden()` deleted the URL simply 404s instead — also an error, and a completely
    //    different one, which is why the message is what is asserted.
    let t = try await session.openPath(sharedData.cleanCSV)
    var message = ""
    do {
        _ = try await session.runSQL(
            t.name, sql: "SELECT * FROM read_csv_auto('https://example.com/x.csv')",
            offset: 0, limit: 1
        )
        Issue.record("a network read succeeded through a hardened Session")
    } catch let error as SessionError {
        message = error.message
    }
    #expect(message.contains("requires the extension httpfs"),
            "expected the extension guard to refuse the read; got: \(message)")
}

// MARK: - state() is in OPEN order, not Dictionary order

/// 🔴 The tab bar's order, the sources list's order, and which table is selected on launch all
/// come straight off `state().tables` — `web/index.html` renders it into the tab bar (:945) and
/// the sources list (:974), and picks `tables[0]` as the default selection (:526, :993). Python
/// iterates an insertion-ordered dict (`session.py:1187`), so that is the file's own open order,
/// every time.
///
/// `Array(tables.values)` is not. MEASURED across three processes opening the same eight files in
/// the same order: `delta_x bravo golf alpha echo…`, then `foxtrot alpha charlie delta_x…`, then
/// `bravo golf foxtrot echo…` — never open order, and different every launch. This engine already
/// carries LANDMINE comments about exactly this hazard for `joinCandidates` (Joins.swift) and
/// `exportFormats` (Export.swift); `state()` is the call site nobody checked.
///
/// `openedAt` is the fix and it already existed: a monotonic per-open counter, never reused, that
/// `merge` also stamps. Eight tables, a close, and two more opens — so a sort that merely happened
/// to agree with insertion order cannot pass, and neither can one keyed on the name.
@Test func stateListsTablesInTheOrderTheyWereOpened() async throws {
    let session = try newSession()
    let names = ["alpha", "bravo", "charlie", "delta_x", "echo", "foxtrot", "golf", "hotel"]
    for name in names { _ = try await session.openPath(sharedData.cleanCSV, name: name) }

    // A close plus two later opens: `india` and `juliet` must land AFTER `hotel`, and the reopened
    // `charlie` must move to the end rather than back to its original slot — which is what makes
    // this a test of `openedAt` rather than of "some stable order".
    try await session.closeTable("charlie")
    _ = try await session.openPath(sharedData.cleanCSV, name: "india")
    _ = try await session.openPath(sharedData.cleanCSV, name: "charlie")
    _ = try await session.openPath(sharedData.cleanCSV, name: "juliet")

    let listed = await session.state().tables
    #expect(
        listed.map(\.name) == [
            "alpha", "bravo", "delta_x", "echo", "foxtrot", "golf", "hotel",
            "india", "charlie", "juliet",
        ],
        "got \(listed.map(\.name))"
    )
    // The property behind the order, stated directly: whatever the names are, the generations rise.
    #expect(
        zip(listed, listed.dropFirst()).allSatisfy { $0.openedAt < $1.openedAt },
        "openedAt must increase down the list: \(listed.map(\.openedAt))"
    )
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

// MARK: - sortedRelation's TEMP TABLE survives across separate page() calls
//
// A regression test for the fact `page`/`sortedRelation`/`closeTable` sharing one long-lived
// `pagingConnection` (Session.swift's header, fact 3) exists to guarantee: a `TEMP TABLE` is
// visible only to the connection that created it, so if `page()` ever went back to opening a
// fresh `Connection` per call, this would throw "Catalog Error: ... does not exist" on the
// SECOND sorted page. `sortedPagesNeverDuplicateOrDropARowAcrossOffsets` above already pages a
// sorted table more than once and would fail the same way if this regressed; this test isolates
// the mechanism (three page() calls, the smallest number that proves "more than once") rather
// than relying on that test's stability assertion to catch it as a side effect.
@Test func sortedRelationSurvivesAcrossMultiplePageCalls() async throws {
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

// MARK: - preserve_insertion_order (Minor 1): sortedRelation's correctness rests on this default

@Test func preserveInsertionOrderDefaultsOn() throws {
    // sortedRelation's whole correctness rests on a materialized table's physical scan order
    // matching its `CREATE TABLE AS SELECT ... ORDER BY` order. MEASURED with the setting
    // explicitly forced off, at a scale where ties are common enough to matter (500k rows,
    // the same page() sequence sortedPagesNeverDuplicateOrDropARowAcrossOffsets runs): 123,608
    // duplicated rows and 170,820 missing. At that test's actual scale (1000 rows) the collapse
    // would likely go unnoticed, so if this setting were ever flipped off — a future `harden()`
    // change, say — the product would silently duplicate and drop rows with no test catching it.
    //
    // MUST call `harden()` first: it's the same one-time configure step `Session.init` runs
    // before handing out any connection, and its four `SET`s are GLOBAL scope (Database.swift),
    // so a connection opened before `harden()` runs can silently read the DuckDB factory default
    // instead of Sift's actual effective setting — which is exactly the regression this test
    // exists to catch, and exactly what a version without this call fails to catch (caught in
    // review: a `harden()` mutation that flipped this setting off left this test green).
    let db = try Database.inMemory()
    db.harden()
    let con = try db.connect()
    let value = try con.query("SELECT current_setting('preserve_insertion_order')").allRows()[0][0]
    #expect(value == .bool(true))
}

// MARK: - a closed-and-reopened table must not inherit a stale background result (review C1)

@Test func closeAndReopenRejectsAStaleBackgroundResult() async throws {
    // Reproduces the scenario from review: open a table, close it, reopen a DIFFERENT table
    // under the SAME name, then simulate the closed table's background scan finishing late and
    // trying to write its result. `runAfterOpen`'s `apply*` calls are keyed by name only, so
    // without the `openedAt` guard this silently overwrites the reopened table's real values —
    // MEASURED against the pre-fix build with a real 3,000,000-row/10-row pair: the 10-row table
    // reported `rowCount: 3000000`. This test exercises the guard directly rather than racing a
    // real background scan, which is not reliably reproducible at unit-test speed.
    let session = try newSession()
    let first = try await session.openPath(sharedData.cleanCSV, name: "clean")
    try await session.closeTable("clean")
    let second = try await session.openPath(sharedData.cleanCSV, name: "clean")
    #expect(first.openedAt != second.openedAt)

    await session.applyCount("clean", 3_000_000, openedAt: first.openedAt)

    let after = try await session.table("clean")
    #expect(after.rowCount == second.rowCount)
    #expect(after.rowCount != 3_000_000)
}
