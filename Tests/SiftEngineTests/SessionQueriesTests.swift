import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// The read side of the session: SQL mode, profiling, and the three panels. session.py has no
// direct engine/tests/test_session.py counterpart to port assertion-for-assertion here either
// (same situation SessionTests.swift's own header describes) — these are the Task 5 brief's
// required scenarios: faceting both ways, compute_profile reusing the cached bad-cell scan
// instead of rescanning, bad_rows decoding the LIST of failing column names against a genuinely
// dirty fixture, set_spec's validation and cache invalidation, and run_sql's guard/wrap pair —
// plus one smoke test per remaining ported function so every name in the brief's port list has
// at least one assertion behind it.
//
// Each test gets its OWN `~/.sift`-equivalent temp directory, matching SessionTests.swift's own
// rationale: Swift Testing runs in parallel, and two tests sharing a home directory would race on
// DuckDB's exclusive file lock.

private let sharedData = try! corpus()

private func newSessionHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-session-queries-tests-\(UUID().uuidString)").path
}

private func newSession() throws -> Session {
    try Session(home: newSessionHome())
}

/// `_after_open`'s background pipeline (count -> bad-row detection -> staging decision) runs
/// detached. Polling for `stageDecision` — its last step — is the same "background work for this
/// open has finished" signal SessionTests.swift uses.
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

/// Gzips an existing file via a blocking, file-redirected `/usr/bin/gzip -c` — not a `Pipe`, per
/// Fixtures.swift's `makeGzipCSV` comment on the GCD-thread-starvation deadlock that form avoids.
/// SessionTests.swift keeps its own file-scoped copy of this exact helper; this is a second one
/// for the identical documented reason (SQLGenPanelsTests.swift: "one temp-dir helper is not
/// worth sharing across files").
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

/// `order_id` is column 0 in every row `SELECT * FROM <clean.csv view>` returns.
private func orderID(_ row: [Cell]) -> Int {
    guard case .int(let v) = row[0] else {
        Issue.record("order_id was not an int: \(row[0])")
        return -1
    }
    return Int(v)
}

/// A single-column CSV of `count` distinct integers, one each, 0..<count — the identical shape
/// `DuckDB155FactsTests.fact8_approxCountDistinctIsAnEstimate` measured `approx_count_distinct`
/// overshooting for (340 reported for 300 real distinct values).
private func makeUniqueIntCSV(dir: String, count: Int) throws -> String {
    let path = (dir as NSString).appendingPathComponent("unique.csv")
    var out = "v\n"
    for i in 0..<count { out += "\(i)\n" }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - faceting (brief gotcha #1) — both halves in one test

@Test func distinctFacetingIgnoresItsOwnColumnsFilterButRespectsOtherColumns() async throws {
    // clean.csv: 1000 rows, region cycles West/Midwest/South/Northeast every 4 rows (250 each) —
    // the same fixture and the same fact SessionTests.swift's own filtering test relies on.
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    _ = try await session.setSpec(
        t.name, filters: [Filter(col: "region", op: .eq, values: [.text("West")])], sort: []
    )

    // Half 1: the region panel's OWN filter must be dropped from its own query, so clicking
    // "West" does not collapse the panel down to only West. If `distinct` used the unfaceted
    // `t.qspec.filters` for its own query, `regionPanel.nRows` would come back 250, not 1000.
    let regionPanel = try await session.distinct(t.name, col: "region", limit: 10)
    #expect(regionPanel.nRows == 1000)
    #expect(regionPanel.values.count == 4)
    for v in regionPanel.values {
        #expect(v.n == 250, "every region has 250 rows regardless of the West filter")
        #expect(v.selected == (v.label == "West"), "only the actually-selected value highlights")
    }

    // Half 2: a filter on a DIFFERENT column must still narrow the panel. If `distinct` dropped
    // ALL filters unconditionally (not just the panel's own column), `amountPanel.nRows` would
    // come back 1000, not 250.
    let amountPanel = try await session.distinct(t.name, col: "amount", limit: 5)
    #expect(amountPanel.nRows == 250)
}

@Test func distinctThrowsForAnUnknownColumn() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    do {
        _ = try await session.distinct(t.name, col: "nope")
        Issue.record("expected SessionError")
    } catch let e as SessionError {
        #expect(e.message.contains("nope"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

// MARK: - distinct clamps an approx count that overshoots the real row count (brief gotcha #3)

@Test func distinctClampsAnApproxCountThatOvershootsTheRealRowCount() async throws {
    // `wantsExactDistinct` only lets `distinct()` reach the approximate/clamp branch when the
    // CACHED profile's own `approxDistinct` is already >= 100,000 — a real table would need that
    // many actual distinct values to get there, which is not a size worth paying for in a unit
    // test. So the cached profile is overridden directly (the same sentinel-trick shape as
    // `setUncastableForTest`) while the REAL `distinctStatsSQL` query underneath still runs
    // against the real table below and can still genuinely overshoot.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = try makeUniqueIntCSV(dir: dir, count: 300)

    let session = try newSession()
    let t = try await session.openPath(path)

    // Prove the overshoot is real on THIS data, independent of `distinct()` entirely — the same
    // method fact8 uses, rather than trusting a hardcoded "340" to still hold on a CSV-sniffed
    // BIGINT column (as opposed to fact8's raw `range(300)`).
    let probe = try Database.inMemory().connect()
    let rawApproxCell = try probe.query(
        "SELECT approx_count_distinct(v) FROM read_csv(\(qlit(path)))"
    ).allRows()[0][0]
    guard case .int(let rawApproxRaw) = rawApproxCell else {
        Issue.record("expected an integer: \(rawApproxCell)"); return
    }
    let rawApprox = Int(rawApproxRaw)
    #expect(rawApprox > 300, "the whole point of this fixture is a HyperLogLog overshoot to clamp")

    var profile = try await session.computeProfile(t.name)
    guard let i = profile.firstIndex(where: { $0.name == "v" }) else {
        Issue.record("no 'v' column in the profile"); return
    }
    let original = profile[i]
    profile[i] = ColumnProfile(
        name: original.name, type: original.type, kind: original.kind, n: original.n,
        nNull: original.nNull, nEmpty: original.nEmpty, nNullish: original.nNullish,
        approxDistinct: 999_999, exactDistinct: original.exactDistinct,
        minS: original.minS, maxS: original.maxS, avg: original.avg, std: original.std,
        q25: original.q25, q50: original.q50, q75: original.q75, maxLen: original.maxLen,
        nUncastable: original.nUncastable, view: original.view
    )
    await session.setProfileForTest(t.name, profile)

    let panel = try await session.distinct(t.name, col: "v", limit: 5)
    #expect(panel.nDistinct.exact == false, "the exact branch must not have been taken")
    #expect(panel.nRows == 300)
    #expect(panel.nDistinct.value == 300, "clampDistinct caps the overshoot at the real row count")
    #expect(panel.nDistinct.value < rawApprox, "the clamp must have actually reduced the raw estimate")
}

// MARK: - the speculative profile pays the cost gate; a direct ask does not

/// 🔴 The gate on `session.py:454` — `size <= PROFILE_EAGER_MAX_BYTES or staged or columnar` —
/// was the one step of `_after_open` the port never carried, and `PROFILE_EAGER_MAX_BYTES` did not
/// exist in Swift at all. With the kick left to the UI and the policy left nowhere, the UI plan's
/// Task 5c kicks a profile after the first page with no gate, so the native app would `SUMMARIZE`
/// a 30 GB CSV that Python deliberately skips.
///
/// The table below is a real 1,000-row CSV wearing a 30 GB spec, which is what makes the refusal
/// visible: the profile is perfectly computable, so if the gate goes the job runs and
/// `nextProfileJobID` moves. A fixture that genuinely could not be profiled would prove nothing.
@Test func aSpeculativeProfileRefusesASourceTooBigToProfileUnasked() async throws {
    let session = try newSession()

    // Cheap: a 12 KB CSV. The speculative kick takes it.
    let small = try await session.openPath(sharedData.cleanCSV)
    #expect(try await session.profileIfCheap(small.name) == true)
    #expect(await session.nextProfileJobID == 1, "the cheap case must actually profile")
    #expect(try await session.table(small.name).profile != nil)

    // The same file again, wearing a spec that claims 30 GB of CSV.
    let huge = try await session.openPath(sharedData.cleanCSV)
    await session.setSourceSpecForTest(huge.name, hugeCSVSpec(like: huge.spec))
    #expect(try await session.profileIfCheap(huge.name) == false)
    #expect(await session.nextProfileJobID == 1, "no SUMMARIZE may have been started")
    #expect(try await session.table(huge.name).profile == nil, "nothing may have been cached")

    // ...and a DIRECT ask is still answered, which is the other half of the contract and the
    // reason the gate is not inside `computeProfile`. Python does not gate `profile_of` either:
    // a user clicking a column on a 30 GB file is asking.
    let asked = try await session.profileOf(huge.name, col: "order_id")
    #expect(asked.n == 1000)
    #expect(await session.nextProfileJobID == 2, "the direct ask must have run its own job")
}

/// The same source spec with a 30 GB size. Every other field is carried over verbatim so the
/// relation underneath still reads the real file.
private func hugeCSVSpec(like spec: SourceSpec) -> SourceSpec {
    SourceSpec(
        key: SourceKey(path: spec.key.path, mtimeNs: spec.key.mtimeNs, size: 30 * 1024 * 1024 * 1024),
        fmt: spec.fmt, readFn: spec.readFn, readArgs: spec.readArgs, columns: spec.columns,
        rowCount: spec.rowCount, rowEstimate: spec.rowEstimate, compressed: spec.compressed,
        sheet: spec.sheet, sheets: spec.sheets, deltaVersion: spec.deltaVersion,
        sniffPrompt: spec.sniffPrompt, glob: spec.glob, raggedColumns: spec.raggedColumns
    )
}

// MARK: - compute_profile reuses the cached bad-cell scan (brief gotcha #2)

@Test func computeProfileReusesTheCachedUncastableScanInsteadOfRescanning() async throws {
    // clean.csv's order_id column is always a valid integer ("0".."999"), so a REAL uncastable
    // scan reports 0 bad cells for it. Waiting for background work first means the real scan has
    // already run and will not run again — only then is it safe to plant an impossible sentinel
    // and prove `computeProfile` reads it rather than recomputing it: if the "reuse the cache"
    // code path regressed to calling `detectBadRows` again, this sentinel would be overwritten by
    // the real (zero) count and the assertion below would fail. This is Task 4's
    // `setFilteredCountForTest` sentinel trick applied to the read side.
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    _ = try await waitForBackgroundWork(session, t.name)

    await session.setUncastableForTest(t.name, ["c0__bad": 424_242, "n": 1000])
    let profile = try await session.computeProfile(t.name)

    #expect(profile[0].name == "order_id", "index 0 must line up with spec.columns' own order")
    #expect(profile[0].nUncastable == 424_242, "a real rescan of order_id would report 0, not the sentinel")
}

@Test func profileOfThrowsForAnUnknownColumn() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    do {
        _ = try await session.profileOf(t.name, col: "nope")
        Issue.record("expected SessionError")
    } catch is SessionError {
        // expected
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

// MARK: - the Excel-serial-date note is column-scoped, not table-wide (brief gotcha #8)

@Test func computeProfileNotesAnExcelSerialDateLookingColumnOnlyForXlsx() async throws {
    // excel_serial.xlsx: "serial" holds five values inside looksLikeExcelSerialDates' 25,000-
    // 50,000 window (2 distinct is already > 1), "id" is an ordinary small integer. Both columns
    // together pin that the note fires per-column, not once the source format is merely xlsx —
    // `&& t.spec.fmt == .xlsx` is new code unique to this task, so SiftCoreTests' coverage of the
    // pure predicate alone (which knows nothing about `spec.fmt`) cannot exercise this gate; only
    // going through `Session.computeProfile` can.
    let session = try newSession()
    let t = try await session.openPath(siftCoreTestsFixture("excel_serial.xlsx"))
    #expect(t.spec.fmt == .xlsx)

    _ = try await session.computeProfile(t.name)
    let after = try await session.table(t.name)
    #expect(
        after.notes.contains { $0.contains("serial") && $0.contains("Excel serial dates") },
        "expected an Excel-serial-date note naming the 'serial' column; got: \(after.notes)"
    )
    #expect(
        !after.notes.contains { $0.contains("\u{201C}id\u{201D}") },
        "the ordinary 'id' column must not also get the note"
    )
}

// MARK: - bad_rows decodes the LIST of failing column names (brief gotcha #4)

@Test func badRowsDecodesBadColumnsAsTheListOfFailingColumnNames() async throws {
    // Reuses SessionTests.swift's own established trick for producing a genuinely dirty table:
    // under fullSniffMaxBytes the sniffer scans the WHOLE file and would correctly widen "amount"
    // to VARCHAR the moment it saw one non-numeric value, leaving nothing to detect. A
    // *compressed* CSV samples only the first 20,480 rows regardless of size, so a bad row placed
    // well past that window reproduces the real scenario: the sniffer keeps "amount" numeric from
    // the sample, and the later row does not fit it.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let plain = try makeCSV(dir: dir, name: "dirty.csv", rows: 25_000, badIntRow: 21_000)
    let gz = (dir as NSString).appendingPathComponent("dirty.csv.gz")
    try gzip(plain, to: gz)

    let session = try newSession()
    let t = try await session.openPath(gz)
    let settled = try await waitForBackgroundWork(session, t.name)
    #expect(settled.badCells == 1)
    #expect(settled.badRows == 1)

    let panel = try await session.badRows(t.name)
    #expect(panel.cells == 1)
    #expect(panel.rows == 1)
    #expect(panel.data.count == 1)
    // Column 0 is `bad_columns`, the LIST SQLGenPanels.badRowsSQL prepends — Task 1 made it
    // decodable as `.list`. If that decoded as text instead (or joined into a string), this
    // exact equality would fail: `.list([.text("amount")])` is not equal to any `Cell.text`.
    #expect(panel.data[0][0] == .list([.text("amount")]))
}

@Test func badRowsReturnsTheEmptyShapeWhenThereAreNoBadCells() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    _ = try await waitForBackgroundWork(session, t.name)

    let panel = try await session.badRows(t.name)
    #expect(panel.cells == 0)
    #expect(panel.rows == 0)
    #expect(panel.columns.isEmpty)
    #expect(panel.data.isEmpty)
}

// MARK: - set_spec: validation and cache invalidation (brief gotchas #6, #7)

@Test func setSpecRejectsAnUnknownFilterColumn() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    do {
        _ = try await session.setSpec(
            t.name, filters: [Filter(col: "nope", op: .eq, values: [.text("x")])], sort: []
        )
        Issue.record("expected SessionError")
    } catch let e as SessionError {
        #expect(e.message.contains("nope"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func setSpecRejectsAnUnknownSortColumn() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    do {
        _ = try await session.setSpec(
            t.name, filters: [], sort: [QuerySpec.SortTerm(column: "nope", direction: .asc)]
        )
        Issue.record("expected SessionError")
    } catch let e as SessionError {
        #expect(e.message.contains("nope"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func setSpecClearsTheCachedFilteredCount() async throws {
    // The other half of Task 4's caching test, which guards that `filteredCount` STAYS cached
    // across pages of the same spec: this is what makes it re-derive once the spec actually
    // changes. Planting an impossible sentinel first proves `setSpec` itself clears it — a page()
    // call afterward that happened to recompute the same real value would pass even if the reset
    // line were deleted, exactly the vacuous-assertion trap SessionTests.swift's own version of
    // this test calls out.
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    await session.setFilteredCountForTest(t.name, 999_999)
    let before = try await session.table(t.name)
    #expect(before.filteredCount == 999_999)

    _ = try await session.setSpec(t.name, filters: [], sort: [])
    let after = try await session.table(t.name)
    #expect(after.filteredCount == nil)
}

// MARK: - run_sql: the guard runs first, then the wrap (brief gotcha #5)

@Test func runSQLAcceptsALegitimateSelectAndEntersSqlMode() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    let sql = "SELECT * FROM \(q(t.name)) ORDER BY order_id"

    let page = try await session.runSQL(t.name, sql: sql, offset: 0, limit: 10)
    #expect(page.rows.count == 10)
    #expect(orderID(page.rows[0]) == 0)
    #expect(page.total.value == nil)
    #expect(page.total.exact == false)

    let after = try await session.table(t.name)
    #expect(after.sqlMode == true)
    #expect(after.sqlText == sql)
}

@Test func runSQLRejectsAMultiStatementQueryWithoutMutatingTheTable() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    do {
        _ = try await session.runSQL(t.name, sql: "SELECT 1; DROP TABLE x", offset: 0, limit: 10)
        Issue.record("expected SQLRejected")
    } catch is SQLRejected {
        // expected — and the table must be untouched: the guard runs BEFORE `t` is even
        // fetched/mutated, matching Python's ordering. If a future change reordered these two
        // calls, `sqlMode` could end up `true` here even though the query was rejected.
        let after = try await session.table(t.name)
        #expect(after.sqlMode == false)
        #expect(after.sqlText == nil)
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func exitSqlModeClearsSqlModeAndText() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    _ = try await session.runSQL(t.name, sql: "SELECT * FROM \(q(t.name))", offset: 0, limit: 5)
    let inSqlMode = try await session.table(t.name)
    #expect(inSqlMode.sqlMode == true)

    let after = try await session.exitSQLMode(t.name)
    #expect(after.sqlMode == false)
    #expect(after.sqlText == nil)
}

// MARK: - histogram: a real numeric column produces real, non-degenerate buckets

@Test func histogramBucketsCoverEveryNonNullValue() async throws {
    // amount = "{i}.50" for i in 0..<1000 — a real, non-degenerate numeric range.
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)

    let panel = try await session.histogram(t.name, col: "amount", bins: 40)
    #expect(panel.degenerate == false)
    #expect(panel.nNull == 0)
    #expect(panel.buckets.reduce(0) { $0 + $1.n } == 1000, "every non-null value lands in some bucket")
}

// MARK: - sample_values and length_histogram: decode, and swallow rather than throw

@Test func sampleValuesDecodesUpToLimitRowsForAKnownColumn() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)

    let sample = try await session.sampleValues(t.name, col: "region", limit: 20)
    #expect(sample.count == 20, "USING SAMPLE n ROWS returns exactly n rows on a table this size")
    let known: Set<String> = ["West", "Midwest", "South", "Northeast"]
    for cell in sample {
        guard case .text(let s) = cell else {
            Issue.record("region sample cell was not text: \(cell)")
            continue
        }
        #expect(known.contains(s))
    }
}

@Test func sampleValuesSwallowsAnUnknownColumnAndReturnsEmpty() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    // Deliberately no existence check inside `sampleValues` (brief gotcha #9) — a bad column name
    // is a DuckDB binder error, caught and swallowed, same as any other query failure here.
    let sample = try await session.sampleValues(t.name, col: "nope", limit: 20)
    #expect(sample.isEmpty)
}

@Test func lengthHistogramBucketsSumToTheNonNullRowCount() async throws {
    // note = "note {i}" for every row — never null, so the buckets must account for all 1000.
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)

    let buckets = try await session.lengthHistogram(t.name, col: "note", bins: 24)
    #expect(!buckets.isEmpty)
    #expect(buckets.reduce(0) { $0 + $1.n } == 1000)
}

// MARK: - rendered_sql / snippet: reflect SQL-mode vs. spec-mode (thin wiring over SiftCore)

@Test func renderedSqlAndSnippetReflectSqlModeVersusSpecMode() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)

    // Spec mode: both read through to SiftCore.renderSQL of the current QuerySpec.
    let specRendered = try await session.renderedSQL(t.name)
    #expect(specRendered.contains("SELECT"))
    #expect(try await session.snippet(t.name, dialect: "sql") == specRendered)

    // SQL mode: both must return the user's own text verbatim, not a re-render of the spec —
    // this is the actual thing Task 5 adds (the `sqlOverride` wiring), not SiftCore.snippet's own
    // already-tested internals.
    let sql = "SELECT * FROM \(q(t.name)) WHERE order_id < 5"
    _ = try await session.runSQL(t.name, sql: sql, offset: 0, limit: 5)
    #expect(try await session.renderedSQL(t.name) == sql)
    #expect(try await session.snippet(t.name, dialect: "sql") == sql)
}
