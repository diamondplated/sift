import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// The measurement harness behind `computeProfile`'s detach, kept as its own file and OFF by
// default (`SIFT_PROFILE_BENCH=1` to run it). It builds a 200-column × 200,000-row fixture and
// prints timings; it is not a unit test and must never join the ~30 s parallel suite.
//
// Reference numbers on this code: `computeProfile` alone 6.4-7.4 s, worst `table()` while
// profiling 0.1 ms, worst `page()` 181-266 ms. Before the detach, worst `table()` was 7228 ms —
// which is the whole point, and the number to re-measure before touching the detach.

private func benchHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-bench-\(UUID().uuidString)").path
}

/// Written once and cached in the temp dir across runs — building it takes longer than the
/// measurement does.
private func wideFixture(cols: Int, rows: Int) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-bench-\(cols)x\(rows).parquet").path
    if FileManager.default.fileExists(atPath: path) { return path }

    var exprs: [String] = []
    for i in 0..<cols {
        switch i % 3 {
        case 0: exprs.append("((i * \(i + 7)) % 100000)::BIGINT AS c\(i)")
        case 1: exprs.append("((i % \(i + 13)) / 7.0)::DOUBLE AS c\(i)")
        default: exprs.append("('v' || ((i * \(i + 3)) % 977)) AS c\(i)")
        }
    }
    let con = try Database.inMemory().connect()
    try con.execute(
        "COPY (SELECT \(exprs.joined(separator: ", ")) FROM range(\(rows)) t(i)) "
            + "TO \(qlit(path)) (FORMAT PARQUET)"
    )
    return path
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SIFT_PROFILE_BENCH"] == "1"))
func benchActorHoldDuringAProfile() async throws {
    let cols = Int(ProcessInfo.processInfo.environment["SIFT_BENCH_COLS"] ?? "200") ?? 200
    let rows = Int(ProcessInfo.processInfo.environment["SIFT_BENCH_ROWS"] ?? "200000") ?? 200_000
    let path = try wideFixture(cols: cols, rows: rows)

    let session = try Session(home: benchHome())
    let wide = try await session.openPath(path, name: "wide")
    _ = try await session.openPath(path, name: "probe")

    // What the two queries cost on their own, off any actor — the work itself, so the hold numbers
    // below can be read against it.
    let raw = try Database.inMemory().connect()
    let s0 = DispatchTime.now()
    _ = try raw.query("SUMMARIZE SELECT * FROM read_parquet(\(qlit(path)))").allRows()
    let summarizeMs = millisecondsSince(s0)
    let s1 = DispatchTime.now()
    _ = try raw.query(
        profileExtraSQL("read_parquet(\(qlit(path)))", wide.spec.columns)
    ).allRows()
    let extraMs = millisecondsSince(s1)

    // Idle cost of the two probes, so a hold can be told from the probe's own price.
    var idlePage = 0.0
    var idleTable = 0.0
    for _ in 0..<5 {
        let a = DispatchTime.now()
        _ = try await session.table("wide")
        idleTable = max(idleTable, millisecondsSince(a))
        let b = DispatchTime.now()
        _ = try await session.page("wide", offset: 0, limit: 500)
        idlePage = max(idlePage, millisecondsSince(b))
    }

    // End-to-end profile latency with nothing else running, on a SECOND open of the same file so
    // "wide" still has no cached profile for the contended run below.
    let s2 = DispatchTime.now()
    let soloColumns = try await session.computeProfile("probe")
    let soloMs = millisecondsSince(s2)

    // The measurement: how long a trivial actor call, and a real page, wait while "wide" profiles.
    let kicked = DispatchTime.now()
    let job = Task { try await session.computeProfile("wide") }
    var worstTable = 0.0
    var worstPage = 0.0
    var probes = 0
    while true {
        let a = DispatchTime.now()
        let snapshot = try await session.table("wide")
        worstTable = max(worstTable, millisecondsSince(a))
        let b = DispatchTime.now()
        _ = try await session.page("wide", offset: 0, limit: 500)
        worstPage = max(worstPage, millisecondsSince(b))
        probes += 1
        if snapshot.profile != nil { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let columns = try await job.value
    let wallMs = millisecondsSince(kicked)

    print("""

        ================ BENCH \(cols) cols x \(rows) rows ================
          raw SUMMARIZE               \(summarizeMs) ms
          raw profileExtraSQL         \(extraMs) ms
          idle table()                \(idleTable) ms
          idle page()                 \(idlePage) ms
          computeProfile alone        \(soloMs) ms      (\(soloColumns.count) columns)
          --- while a profile is in flight ---
          WORST table() (actor hold)  \(worstTable) ms
          WORST page()                \(worstPage) ms
          probe rounds                \(probes)
          profile wall clock          \(wallMs) ms      (\(columns.count) columns)
        ==========================================================

        """)
    #expect(columns.count == cols)
}
