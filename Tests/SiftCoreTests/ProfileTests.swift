import Testing
import DuckDBKit
import Foundation
@testable import SiftCore

// Profiling: what SUMMARIZE gives, and which panel each column earns. Ported from the 8 test
// functions in engine/tests/test_profile.py. One has @pytest.mark.parametrize (test_choose_view,
// 8 cases) — all 8 are ported below as one @Test(arguments:) case each, so the case count survives
// the port even though the function count would not show it.
//
// The first three Python tests build their fixture through `core.source.build_source` /
// `read_expr` (session-scoped `con`/`data` fixtures in conftest.py) — machinery SiftCore does not
// have yet (source.py is a later task; see the brief). What those three tests actually exercise is
// profile.py's own behavior against a real SUMMARIZE/profileExtraSQL/uncastableSQL result, not
// source.py's CSV sniffing — so here they stand up an equivalent DuckDB view directly (matching
// fixtures.py's `make_csv(rows=600, nulls_every=7, empties_every=11, nullish_every=13)` byte for
// byte, including `allow_quoted_nulls=false`, the option that keeps NULL and '' distinct) rather
// than reimplementing source.py's sniffing layer.

// MARK: - Shared "nulls.csv" fixture (engine/tests/fixtures.py's make_csv, same knobs)

/// Reproduces fixtures.py's `make_csv(directory, "nulls.csv", rows=600, nulls_every=7,
/// empties_every=11, nullish_every=13)` verbatim: an unquoted empty `region` reads as NULL, a
/// quoted `""` `note` is an explicit empty string (distinct from NULL), and `note` is sometimes
/// the literal sentinel "N/A" (neither null nor empty).
private func writeNullsCSV() -> String {
    let regions = ["West", "Midwest", "South", "Northeast"]
    var lines = ["order_id,region,amount,note"]
    for i in 0..<600 {
        var region = regions[i % regions.count]
        if i % 7 == 0 { region = "" }
        let amount = "\(i).50"
        var note = "note \(i)"
        if i % 11 == 0 { note = "\"\"" }
        if i % 13 == 0 { note = "N/A" }
        lines.append("\(i),\(region),\(amount),\(note)")
    }
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-profile-nulls-\(UUID().uuidString).csv").path
    try! (lines.joined(separator: "\n") + "\n").write(
        toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// A fresh in-memory connection with `viewName` pointed at a freshly-written nulls.csv, plus the
/// [Column] list (name-order matches the view's column order, which is what profileExtraSQL's
/// index-based `c{i}__*` aliases rely on).
private func openNullsView(_ viewName: String) throws -> (con: Connection, cols: [Column]) {
    let con = try Database.inMemory().connect()
    let path = writeNullsCSV()
    try con.execute(
        "CREATE OR REPLACE VIEW \(viewName) AS SELECT * FROM "
            + "read_csv(\(qlit(path)), header=true, allow_quoted_nulls=false)"
    )
    let cols = [
        Column(name: "order_id", type: "BIGINT"),
        Column(name: "region", type: "VARCHAR"),
        Column(name: "amount", type: "DOUBLE"),
        Column(name: "note", type: "VARCHAR"),
    ]
    return (con, cols)
}

private func summarize(_ con: Connection, _ viewName: String) throws -> [String: SummarizeRow] {
    let rs = try con.query("SUMMARIZE \(viewName)")
    let names = rs.columns.map(\.name)
    let rows = try rs.allRows().map { $0.map { $0.isNull ? nil : $0.display } }
    return parseSummarize(columnNames: names, rows: rows)
}

// MARK: - parse_summarize

@Test func summarizeReturnsTheColumnsWeDependOn() throws {
    let (con, _) = try openNullsView("p")
    let rs = try con.query("SUMMARIZE p")
    let names = rs.columns.map(\.name)
    for want in summarizeColumns {
        #expect(names.contains(want), "SUMMARIZE no longer returns \(want)")
    }
    let rows = try rs.allRows().map { $0.map { $0.isNull ? nil : $0.display } }
    let parsed = parseSummarize(columnNames: names, rows: rows)
    #expect(parsed["region"] != nil)
    #expect(parsed["region"]?.count == 600)
}

@Test func nullPercentageArrivesCoercedToADouble() throws {
    // Python's test also asserts `isinstance(v, float)`, guarding against a raw Decimal breaking
    // JSON encoding downstream — moot here, since SummarizeRow.nullPercentage is statically
    // Double?, so that half of the check collapses into the type system. The value check remains.
    let (con, _) = try openNullsView("p2")
    let parsed = try summarize(con, "p2")
    let v = try #require(parsed["region"]?.nullPercentage)
    #expect(v > 0)
}

@Test func profileKeepsNullEmptyAndNullishSeparate() throws {
    // The distinction the whole tool exists for: NULL, '' and 'N/A' are three different problems.
    let (con, cols) = try openNullsView("p3")
    let summ = try summarize(con, "p3")

    let extraSQL = profileExtraSQL("p3", cols)
    let extraRS = try con.query(extraSQL)
    let extraRow = try extraRS.allRows()[0]
    var extra: [String: Int] = [:]
    for (name, c) in zip(extraRS.columns.map(\.name), extraRow) {
        if case .int(let v) = c { extra[name] = Int(v) }
    }

    let profiles = buildProfile(cols: cols, summ: summ, extra: extra, nRows: extra["n"])
    let region = try #require(profiles.first { $0.name == "region" })
    let note = try #require(profiles.first { $0.name == "note" })
    #expect(region.nNull > 0, "unquoted empty fields read as NULL")
    #expect(note.nEmpty > 0, "explicitly quoted empty strings are NOT null")
    #expect(note.nNullish > 0, "'N/A' is neither null nor empty")
    // Disjoint, so each number on screen means exactly one thing.
    #expect(note.nEmpty + note.nNullish <= note.n)
}

// MARK: - clamp_distinct

@Test func approxDistinctIsClampedToTheRowCount() {
    // HyperLogLog can overshoot — measured 340 for 300 distinct values. "340 distinct" above a
    // 300-row table reads as a bug, so it is clamped before display.
    #expect(clampDistinct(340, 300) == 300)
    #expect(clampDistinct(5, 300) == 5)
    #expect(clampDistinct(-1, 300) == 0)
    #expect(clampDistinct(10, 0) == 10)   // unknown n: pass it through
}

// MARK: - choose_view
//
// Python's parametrize also carries a `kind` argument passed straight into `Column(kind=kind)`,
// bypassing derivation from `type_`. Swift's Column always derives kind from type (see
// Types.swift's `kind(of:)`); dropped here because all 8 (kind, type_) pairs already agree with
// what derivation produces, so building `Column(name:type:)` from `type_` alone reproduces every
// case exactly. Verified by inspection against Types.swift's classifier.

@Test(arguments: [
    ("BOOLEAN", 2, 1000, ColumnProfile.View.topn),
    ("INTEGER", 12, 100_000, ColumnProfile.View.topn),         // store_id: categorical in practice
    ("DOUBLE", 100_000, 1_000_000, ColumnProfile.View.hist),
    ("TIMESTAMP", 90_000, 1_000_000, ColumnProfile.View.hist),
    ("DATE", 12, 1_000_000, ColumnProfile.View.topn),          // a month column is a list, not a chart
    ("VARCHAR", 4, 1_000_000, ColumnProfile.View.topn),
    ("VARCHAR", 999_000, 1_000_000, ColumnProfile.View.highcard),
    ("STRUCT(a INTEGER)", 500, 1000, ColumnProfile.View.topn),
])
func chooseViewPicksThePanel(type: String, approx: Int, n: Int, want: ColumnProfile.View) {
    let col = Column(name: "c", type: type)
    #expect(chooseView(col: col, approxDistinct: approx, n: n) == want)
}

// MARK: - wants_exact_distinct

@Test func exactDistinctIsOnlyWorthItBelowACeiling() {
    #expect(wantsExactDistinct(50) == true)
    #expect(wantsExactDistinct(4_000_000) == false)
}

// MARK: - histogram_params

@Test func histogramParamsRefusesDegenerateRanges() throws {
    #expect(histogramParams(lo: nil, hi: 5.0) == nil)
    #expect(histogramParams(lo: 5.0, hi: 5.0) == nil)     // single value: one bar is not a histogram
    #expect(histogramParams(lo: 9.0, hi: 1.0) == nil)     // inverted
    let params = try #require(histogramParams(lo: 0.0, hi: 100.0, bins: 10))
    #expect(params.lo == 0.0 && params.step == 10.0 && params.bins == 10)
}

// MARK: - looks_like_excel_serial_dates

@Test func excelSerialDateDetection() {
    // A date column that lost its formatting reads as ~45000. The most common Excel surprise.
    let dates = ColumnProfile(
        name: "d", type: "DOUBLE", kind: .number,
        approxDistinct: 300, minS: "45000.0", maxS: "45300.0")
    let money = ColumnProfile(
        name: "m", type: "DOUBLE", kind: .number,
        approxDistinct: 5000, minS: "0.0", maxS: "98211.44")
    let text = ColumnProfile(
        name: "t", type: "VARCHAR", kind: .text,
        approxDistinct: 300, minS: "45000", maxS: "45300")
    #expect(looksLikeExcelSerialDates(dates) == true)
    #expect(looksLikeExcelSerialDates(money) == false)
    #expect(looksLikeExcelSerialDates(text) == false)
}
