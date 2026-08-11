import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// engine/tests/test_distinct.py, ported — all nine tests, one for one.
//
// The distinct-values panel against a live connection. Tests/SiftCoreTests/SQLGenPanelsTests.swift
// already pins the SQL these build, but only as STRINGS: it would not notice a query that is
// well-formed, parameterized, correctly quoted and returns the wrong numbers. These execute it
// against a real fixture, which is the level Python tests it at and the reason none of the nine is
// redundant.
//
// Each test opens its own in-memory `Connection` (Connection is deliberately not Sendable and the
// suite runs in parallel), so the d1..d9 view names are per-connection and cannot collide. The
// names are kept from the Python file so each test says which one it came from.

private let sharedData = try! corpus()

private func newConnection() throws -> Connection {
    try Database.inMemory().connect()
}

/// `test_distinct.py`'s own `_view`.
private func view(
    _ con: Connection, _ path: String, _ name: String
) throws -> (SourceSpec, [String: Column]) {
    let spec = try buildSource(con, path: path)
    try con.execute(createViewSQL(name: name, spec: spec))
    return (spec, Dictionary(spec.columns.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last }))
}

/// One `distinct_stats_sql` row as a name-keyed dictionary — Python's
/// `dict(zip([d[0] for d in cur.description], cur.fetchone()))`.
private func statsRow(_ con: Connection, _ sql: String, _ params: [SQLValue]) throws -> [String: Cell] {
    let rs = try con.query(sql, params.map(toDBValue))
    let row = try rs.allRows()[0]
    return Dictionary(uniqueKeysWithValues: rs.columns.enumerated().map { ($1.name, row[$0]) })
}

/// topNSQL's `frac` column is a DOUBLE. Local rather than shared: SessionQueries' own `cellDouble`
/// is file-private there, and this is a test-side decoder, not a second copy of a production rule.
private func frac(_ cell: Cell) -> Double {
    switch cell {
    case .double(let d): return d
    case .int(let i): return Double(i)
    case .decimal(let d, _): return NSDecimalNumber(decimal: d).doubleValue
    default:
        Issue.record("frac was not numeric: \(cell)")
        return .nan
    }
}

private func label(_ cell: Cell) -> String {
    if case .text(let s) = cell { return s }
    return cell.display
}

// MARK: - NULL vs empty: the headline distinction

@Test func nullAndEmptyAreSeparateRows() throws {
    // Merging them, or dropping either, would hide the actual problem — design spec §9.
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.nullsCSV, "d1")

    let (sql, params) = try topNSQL(q("d1"), "note", cols: cols, limit: 50)
    let labels = try con.query(sql, params.map(toDBValue)).allRows().map { label($0[0]) }
    #expect(labels.contains("\u{2400} EMPTY"), "quoted empty strings must surface as their own row")

    let (sql2, params2) = try topNSQL(q("d1"), "region", cols: cols, limit: 50)
    let labels2 = try con.query(sql2, params2.map(toDBValue)).allRows().map { label($0[0]) }
    #expect(labels2.contains("\u{2400} NULL"))

    // Not in Python, and the assertion that makes the two above mean something: the two labels are
    // produced by two DIFFERENT branches of the same CASE, over two different columns, and a build
    // that emitted one label for both states would still satisfy `contains` on each column
    // separately. `note` carries BOTH an empty string and the nullish sentinel "N/A" (and no
    // NULLs); `region` carries NULLs and no empties. So neither label may appear on the other side.
    #expect(!labels.contains("\u{2400} NULL"), "note has no NULLs — an empty string was labelled one")
    #expect(!labels2.contains("\u{2400} EMPTY"), "region has no empty strings — a NULL was labelled one")
    #expect(labels.contains("N/A"), "a nullish sentinel is a real value and keeps its own text")
}

// MARK: - counts and fractions come from one pass

@Test func fractionsSumToOneAndComeFromTheSamePass() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d2")

    let (sql, params) = try topNSQL(q("d2"), "region", cols: cols, limit: 100)
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(abs(rows.reduce(0) { $0 + frac($1[3]) } - 1.0) < 1e-9)
    #expect(rows.reduce(0) { $0 + cellInt($1[2]) } == 1000)
    #expect(rows.count == 4)
}

@Test func aFilterOnAnotherColumnNarrowsTheDenominator() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d3")
    let filters = [Filter(col: "order_id", op: .lt, values: [.int(500)])]

    let (sql, params) = try topNSQL(q("d3"), "region", cols: cols, filters: filters, limit: 100)
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(rows.reduce(0) { $0 + cellInt($1[2]) } == 500)
    // The fractions still sum to 1: the denominator narrowed with the numerator, in the same pass.
    #expect(abs(rows.reduce(0) { $0 + frac($1[3]) } - 1.0) < 1e-9)
}

// MARK: - search

@Test func searchNarrowsTheValues() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d4")

    let (sql, params) = try topNSQL(q("d4"), "region", cols: cols, limit: 100, search: "wes")
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    // Substring and case-insensitive — so "Midwest" matches "wes" too. That is the intent:
    // searching values is for finding them, not for prefix-matching.
    #expect(rows.map { label($0[0]) }.sorted() == ["Midwest", "West"])

    let (sql2, params2) = try topNSQL(q("d4"), "region", cols: cols, limit: 100, search: "nope")
    #expect(try con.query(sql2, params2.map(toDBValue)).allRows().isEmpty)
}

// MARK: - the tail

@Test func otherNAccountsForTheTail() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d5")

    let (sql, params) = try topNSQL(q("d5"), "note", cols: cols, limit: 5)
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    let shown = rows.reduce(0) { $0 + cellInt($1[2]) }
    #expect(rows.count == 5)

    let (csql, cparams) = try distinctStatsSQL(q("d5"), "note", cols: cols)
    let stats = try statsRow(con, csql, cparams)
    #expect(cellInt(stats["n_rows"] ?? .null) == 1000)
    #expect(cellInt(stats["n_rows"] ?? .null) - shown > 0, "a top-5 of 1000 distinct notes must leave a tail")
}

@Test func exactDistinctMatchesReality() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d6")

    let (sql, params) = try distinctStatsSQL(q("d6"), "region", cols: cols, exact: true)
    let stats = try statsRow(con, sql, params)
    #expect(cellInt(stats["n_distinct_exact"] ?? .null) == 4)   // the four regions in the fixture

    // Not in Python: `exact` is opt-in, and the key must be ABSENT when it is not asked for —
    // `distinct` branches on its presence to decide whether to clamp the HyperLogLog estimate.
    let (approxOnly, approxParams) = try distinctStatsSQL(q("d6"), "region", cols: cols)
    #expect(try statsRow(con, approxOnly, approxParams)["n_distinct_exact"] == nil)
}

// MARK: - histograms

@Test func histogramBucketsCoverEveryRow() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d7")
    let (lo, hi) = (0.0, 1000.0)

    let (sql, params) = try histogramSQL(
        q("d7"), "order_id", cols: cols, lo: lo, step: (hi - lo) / 10, bins: 10
    )
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(rows.reduce(0) { $0 + cellInt($1[1]) } == 1000)
    #expect(rows.allSatisfy { (0..<10).contains(cellInt($0[0])) }, "bucket index must stay in range")
}

@Test func histogramClampsTheTopValueIntoTheLastBucket() throws {
    // `least(bins - 1, ...)` exists so max(value) does not land in a phantom bucket N.
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "d8")

    let (sql, params) = try histogramSQL(q("d8"), "order_id", cols: cols, lo: 0.0, step: 100.0, bins: 10)
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(rows.map { cellInt($0[0]) }.max() == 9)

    // Not in Python, and the case that actually exercises the clamp: with `hi` itself as the top
    // of the range, `floor((hi - lo) / step)` is exactly `bins`, one past the last bucket. Python's
    // fixture never reaches it (999 / 100 floors to 9 on its own), so its assertion above passes
    // with `least()` deleted. This one does not.
    let (edge, edgeParams) = try histogramSQL(
        q("d8"), "order_id", cols: cols, lo: 0.0, step: 999.0 / 10.0, bins: 10
    )
    let edgeRows = try con.query(edge, edgeParams.map(toDBValue)).allRows()
    #expect(edgeRows.map { cellInt($0[0]) }.max() == 9, "the maximum value landed in a phantom bucket")
    #expect(edgeRows.reduce(0) { $0 + cellInt($1[1]) } == 1000)
}

@Test func temporalHistogramRuns() throws {
    let con = try newConnection()
    try con.execute(
        "CREATE OR REPLACE VIEW d9 AS SELECT TIMESTAMP '2026-01-01' "
            + "+ INTERVAL (range) HOUR AS ts FROM range(500)"
    )
    let cols = ["ts": Column(name: "ts", type: "TIMESTAMP")]
    #expect(cols["ts"]?.kind == .temporal)   // the branch histogramSQL keys `epoch_ms(...)` off

    let bounds = try con.query(
        "SELECT min(epoch_ms(ts))::DOUBLE, max(epoch_ms(ts))::DOUBLE FROM d9"
    ).allRows()[0]
    guard case .double(let lo) = bounds[0], case .double(let hi) = bounds[1] else {
        Issue.record("temporal bounds did not decode as doubles: \(bounds)")
        return
    }

    let (sql, params) = try histogramSQL(
        q("d9"), "ts", cols: cols, lo: lo, step: (hi - lo) / 12, bins: 12
    )
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(rows.reduce(0) { $0 + cellInt($1[1]) } == 500)
}
