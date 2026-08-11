import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// engine/tests/test_paging.py, ported.
//
// Nine Python tests. FOUR port straight across and are here. FIVE cover `jsonable`,
// `rows_payload` and `needs_string_transport` — machinery this port deleted outright, because
// there is no JSON wire format anymore: `Session` hands `DuckDBKit.Cell` values to an in-process
// caller. Each of those five is a claim that a value survives the crossing, and here the crossing
// is a Swift enum, so the equivalent claim is "the decoder produced the right Cell" —
// Tests/DuckDBKitTests/DecodeTests.swift. The full mapping, test by test, is in
// .superpowers/sdd/2026-08-09-siftengine/task-9-report.md.
//
// ONE case inside those five had no counterpart anywhere and is written here rather than dropped:
// column KIND classification (`test_nested_and_blob_columns_are_classified`, and the
// `payload["cols"][0]["kind"] == "temporal"` half of `test_timestamptz_survives_serialization`).
// See `nestedBlobAndZonedColumnsAreClassifiedFromDuckDBsOwnTypeNames` for why
// SiftCoreTests/TypesTests.swift does not already cover it.
//
// Level: Python drives `sqlgen` against a live connection over a real fixture, so these do too —
// SQLGenTests.swift pins the SQL strings and would not notice a query that is well-formed and
// wrong. The two tests that need the fix Python never had (`Session.sortedRelation`) go through
// `Session` instead, which is where that fix lives.

private let sharedData = try! corpus()

private func newConnection() throws -> Connection {
    try Database.inMemory().connect()
}

private func newSession() throws -> Session {
    try Session(
        home: FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-paging-tests-\(UUID().uuidString)").path
    )
}

/// `test_paging.py`'s own `_view`: build the source spec, expose it as a view, and hand back the
/// name-keyed columns every `sqlgen` entry point takes.
private func view(
    _ con: Connection, _ path: String, _ name: String
) throws -> (SourceSpec, [String: Column]) {
    let spec = try buildSource(con, path: path)
    try con.execute(createViewSQL(name: name, spec: spec))
    return (spec, Dictionary(spec.columns.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last }))
}

/// `order_id` is column 0 of clean.csv, BIGINT once sniffed.
private func orderID(_ row: [Cell]) -> Int {
    guard case .int(let v) = row[0] else {
        Issue.record("order_id was not an int: \(row[0])")
        return -1
    }
    return Int(v)
}

// MARK: - contiguity

@Test func pagesAreContiguousAndNonOverlapping() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "pg1")

    var seen: [Int] = []
    for off in stride(from: 0, to: 1000, by: 250) {
        let (sql, params) = try pageSQL(
            QuerySpec(relation: "pg1"), cols: cols, rel: q("pg1"), limit: 250, offset: off
        )
        let rows = try con.query(sql, params.map(toDBValue)).allRows()
        #expect(rows.count == 250)
        seen.append(contentsOf: rows.map(orderID))
    }
    // Order preserved, nothing repeated or skipped — an equality on the ARRAY, not on a Set:
    // a Set would still pass if every page came back shuffled.
    #expect(seen == Array(0..<1000))
}

// MARK: - sorted-page stability

@Test func sortedPagesAreStableAcrossOffsets() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "pg2")
    let spec = QuerySpec(relation: "pg2", sort: [.init(column: "order_id", direction: .desc)])

    let (first, p1) = try pageSQL(spec, cols: cols, rel: q("pg2"), limit: 10, offset: 0)
    let (second, p2) = try pageSQL(spec, cols: cols, rel: q("pg2"), limit: 10, offset: 10)
    let a = try con.query(first, p1.map(toDBValue)).allRows().map(orderID)
    let b = try con.query(second, p2.map(toDBValue)).allRows().map(orderID)

    #expect(a == Array((990...999).reversed()))
    #expect(b == Array((980...989).reversed()))
    #expect(Set(a).isDisjoint(with: Set(b)))
}

/// The case the test above cannot see. `order_id` is UNIQUE, which is the one shape where ties
/// cannot occur — so a paging implementation that re-sorts per page passes it and still duplicates
/// and drops rows on any real column. MEASURED on the Python engine with a non-unique sort column:
/// 4 duplicated and 4 missing rows per 1000, and 68,402 / 68,989 per 500,000.
///
/// `SessionTests.sortedPagesNeverDuplicateOrDropARowAcrossOffsets` (Task 4) already walks a
/// tie-bearing sort and asserts every row appears exactly once, so that half is not repeated here.
/// What it does NOT assert, and what "stable across offsets" actually claims, is the two properties
/// below: that the walk really came back IN sort order rather than merely complete, and that asking
/// for the SAME offset a second time returns the same rows. The second one is the property Python
/// could not have at all — its `_sorted_relation` materializes into a connection-scoped
/// `CREATE OR REPLACE TEMP TABLE` while every request takes a fresh cursor, so page 2 throws
/// `Catalog Error: Table with name _sift_rs_... does not exist!`.
@Test func aTieBearingSortIsStableWhenTheSameOffsetIsAskedTwice() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    // 4 values over 1000 rows. `limit` divides neither 1000 nor a region's 250-row block, so page
    // boundaries land inside ties rather than politely between them.
    await session.replaceQuerySpec(
        t.name, with: QuerySpec(relation: t.name, sort: [.init(column: "region", direction: .asc)])
    )
    let limit = 251

    var pages: [[Int]] = []
    var regions: [String] = []
    var offset = 0
    while true {
        let page = try await session.page(t.name, offset: offset, limit: limit)
        if page.rows.isEmpty { break }
        pages.append(page.rows.map(orderID))
        regions.append(contentsOf: page.rows.map { $0[1].display })
        offset += limit
    }

    let flat = pages.flatMap { $0 }
    #expect(flat.count == 1000)
    #expect(Set(flat) == Set(0..<1000), "every row appears, and none twice")
    // The sort was genuinely applied. Without this, a build that ignored `sort` entirely would
    // still walk all 1000 rows exactly once and pass everything above.
    #expect(
        zip(regions, regions.dropFirst()).allSatisfy { $0 <= $1 },
        "the walk is not in region order"
    )
    #expect(Set(regions).count == 4)

    // Stability proper: the same offset, asked again, gives back the same rows.
    for (i, expected) in pages.enumerated() {
        let again = try await session.page(t.name, offset: i * limit, limit: limit)
        #expect(again.rows.map(orderID) == expected, "page at offset \(i * limit) changed under us")
    }
}

// MARK: - filtered counts

@Test func filteredCountMatchesTheFilteredRows() throws {
    let con = try newConnection()
    let (_, cols) = try view(con, sharedData.cleanCSV, "pg3")
    let spec = QuerySpec(
        relation: "pg3", filters: [Filter(col: "region", op: .inList, values: [.text("West")])]
    )

    let (csql, cparams) = try countSQL(spec, cols: cols, rel: q("pg3"))
    let n = cellInt(try con.query(csql, cparams.map(toDBValue)).allRows()[0][0])
    let (psql, pparams) = try pageSQL(spec, cols: cols, rel: q("pg3"), limit: 10_000, offset: 0)
    let rows = try con.query(psql, pparams.map(toDBValue)).allRows()

    #expect(rows.count == n)
    // Python asserts only that the two agree, which a filter matching NOTHING also satisfies —
    // 0 == 0 is a green test over a broken WHERE clause. clean.csv cycles four regions over 1000
    // rows, so the number is knowable and is pinned.
    #expect(n == 250)
    #expect(rows.allSatisfy { $0[1] == .text("West") })
}

// MARK: - SQL mode

@Test func sqlModeWrappingPages() throws {
    let con = try newConnection()
    _ = try view(con, sharedData.cleanCSV, "pg4")

    let (sql, params) = wrapUserSQL("SELECT order_id FROM pg4 ORDER BY order_id", limit: 10, offset: 20)
    let rows = try con.query(sql, params.map(toDBValue)).allRows()
    #expect(rows.map(orderID) == Array(20..<30))
}

// MARK: - the case with no counterpart: column kind classification
//
// Python's `rows_payload` attached a `kind` to every result column, and two of its tests asserted
// that classification end to end (`test_nested_and_blob_columns_are_classified`, and the `cols`
// half of `test_timestamptz_survives_serialization`). `rows_payload` is deleted; the surviving
// equivalent is `TablePage.ColumnInfo.kind`, computed in `page`/`runSQL` as
// `kind(of: columnMeta.typeName)`.
//
// 🔴 The two halves of this are each already covered; the JOIN between them is not, and that is
// the whole assertion. SiftCoreTests/TypesTests.swift pins `kind(of:)` over hand-written strings.
// DuckDBKitTests/SmokeTests.swift pins `ResultSet.typeName` over real queries
// (`nestedTypeNamesReportTheirShapeRatherThanOTHER`, `scalarTypeNamesMatchDuckDBsOwnTypeof`).
// Neither one runs a query and looks at the `kind` in the payload — which is what Python asserted
// (`payload["cols"]`, never `kind_of` in isolation), and which is the value the grid branches on.
// Wiring `page`/`runSQL` to `kind(of: $0.type)` instead of `kind(of: $0.typeName)`, or dropping the
// call, leaves every test in both of those files green.
//
// MEASURED while writing this: `typeName` for a LIST column is the bare string "LIST", NOT
// DuckDB's own `typeof()` rendering `INTEGER[]` — `ResultSet.typeName` synthesizes it from the
// type id, because duckdb 1.5.5's C header has no `logical_type_to_string`. Pinned below, since
// `kind(of:)`'s `hasPrefix("LIST")` / `hasSuffix("]")` branches only both exist because of it.

@Test func nestedBlobAndZonedColumnsAreClassifiedFromDuckDBsOwnTypeNames() async throws {
    let session = try newSession()
    let t = try await session.openPath(sharedData.cleanCSV)
    let page = try await session.runSQL(
        t.name,
        sql: "SELECT [1,2] AS l, {'a':1} AS s, 'x'::BLOB AS b, "
            + "TIMESTAMPTZ '2026-01-04 09:11:02+00' AS tz",
        offset: 0, limit: 1
    )

    let types = Dictionary(uniqueKeysWithValues: page.columns.map { ($0.name, $0.type) })
    let kinds = Dictionary(uniqueKeysWithValues: page.columns.map { ($0.name, $0.kind) })

    // The type names this decoder actually produces — the input the classification is derived
    // from. A rename here silently reclassifies every nested column as `.other`.
    #expect(types["l"] == "LIST")
    #expect(types["s"] == "STRUCT")
    #expect(types["b"] == "BLOB")
    #expect(types["tz"] == "TIMESTAMP WITH TIME ZONE")

    #expect(kinds["l"] == .nested)
    #expect(kinds["s"] == .nested)
    #expect(kinds["b"] == .blob)
    #expect(kinds["tz"] == .temporal)

    // `test_timestamptz_survives_serialization`'s value half: in Python this raised inside DuckDB
    // without pytz installed, which is why it was a hard requirement there. Here it is just a
    // value, and it keeps its offset rather than being silently rendered as naive local time.
    #expect(page.rows[0][3] == .text("2026-01-04T09:11:02+00:00"))
    // ...and the nested/blob values are not silently blank either, which is the failure mode the
    // classification exists to keep visible.
    #expect(page.rows[0][0] == .list([.int(1), .int(2)]))
    #expect(page.rows[0][2] == .blob(1))
}
