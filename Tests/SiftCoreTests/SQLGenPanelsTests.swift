import Testing
@testable import SiftCore

// SQL generation for the panels: top-N, distinct stats, histogram, the extra profiling scan,
// and the uncastable/bad-row queries. Ported from the ten tests in engine/tests/test_sqlgen.py
// that Task 3 did not take (grepped: none of the ten carry @pytest.mark.parametrize, so each
// becomes exactly one @Test func here — no cases hiding behind a function count).
//
// The invariant under test throughout: identifiers are quoted, values are bound as parameters,
// except safeType's DuckDB type name — the one deliberate interpolation site, whitelisted.

private let colsList: [Column] = [
    Column(name: "region", type: "VARCHAR"),
    Column(name: "amount", type: "DECIMAL(12,2)"),
    Column(name: "id", type: "BIGINT"),
    Column(name: "ts", type: "TIMESTAMP"),
    Column(name: "ok", type: "BOOLEAN"),
]

private let cols: [String: Column] = Dictionary(uniqueKeysWithValues: colsList.map { ($0.name, $0) })

// MARK: - topn_sql

// Faceting. Without it, clicking "West" makes the region panel show only West.
@Test func topNExcludesItsOwnColumnFilters() throws {
    let spec = QuerySpec(
        relation: "t",
        filters: [
            Filter(col: "region", op: .inList, values: [.text("W")]),
            Filter(col: "amount", op: .gt, values: [.int(5)]),
        ]
    )
    let facet = spec.withoutColumn("region").filters
    #expect(facet.map(\.col) == ["amount"])

    let (sql, params) = try topNSQL(q("t"), "region", cols: cols, filters: facet, limit: 10)
    #expect(params == [.int(5), .int(10)])
    #expect(sql.contains("␀ NULL") && sql.contains("␀ EMPTY"))
    // The percentage denominator comes from the same pass — no companion count query.
    #expect(sql.contains("sum(count(*)) OVER ()"))
}

@Test func topNSearchAddsOneBoundParam() throws {
    let (sql, params) = try topNSQL(
        q("t"), "region", cols: cols, filters: [], limit: 5, search: "wes"
    )
    #expect(params == [.text("wes"), .int(5)])
    #expect(sql.contains("ILIKE"))
}

// MARK: - distinct_stats_sql

@Test func distinctStatsExactIsOptIn() throws {
    let (sql, _) = try distinctStatsSQL(q("t"), "region", cols: cols, filters: [], exact: false)
    #expect(!sql.contains("count(DISTINCT"))
    let (sql2, _) = try distinctStatsSQL(q("t"), "region", cols: cols, filters: [], exact: true)
    #expect(sql2.contains("count(DISTINCT \"region\")"))
}

// MARK: - histogram_sql

@Test func histogramReusesProfileBoundsSoItIsOnePass() throws {
    let (sql, params) = try histogramSQL(q("t"), "amount", cols: cols, 0.0, 10.0, 5)
    #expect(Array(params.prefix(3)) == [.int(5), .double(0.0), .double(10.0)])
    #expect(sql.contains("min(") && sql.contains("max("))  // true per-bucket range for the tooltip
    #expect(!sql.contains("width_bucket"))                 // avoided deliberately for version stability
}

@Test func histogramUsesEpochMsForTemporal() throws {
    let (sql, _) = try histogramSQL(q("t"), "ts", cols: cols, 0.0, 10.0, 5)
    #expect(sql.contains("epoch_ms(\"ts\")"))
}

// MARK: - profile_extra_sql

// Two columns whose names sanitize identically must not collide in the result shape.
@Test func profileExtraUsesIndexAliasesNotNames() {
    let localCols = [Column(name: "a b", type: "VARCHAR"), Column(name: "a-b", type: "VARCHAR")]
    let sql = profileExtraSQL(q("t"), localCols)
    #expect(sql.contains("c0__empty") && sql.contains("c1__empty"))
    #expect(!sql.contains("a b__empty"))
}

@Test func profileExtraKeepsNullEmptyAndNullishDisjoint() {
    let sql = profileExtraSQL(q("t"), colsList)
    #expect(sql.contains("IS NULL) AS c0__null"))
    #expect(sql.contains("= '') AS c0__empty"))
    // nullish excludes both real NULL and true empty, so whitespace-only lands in exactly one bucket
    #expect(sql.contains("IS NOT NULL AND CAST(\"region\" AS VARCHAR) <> ''"))
}

// MARK: - uncastable_sql / bad_row_count_sql

@Test func uncastableSkipsTextColumnsButKeepsTheShape() throws {
    let sql = try uncastableSQL(q("t"), colsList)
    #expect(sql.contains("0 AS c0__bad"))  // region is VARCHAR: nothing to fail
    #expect(sql.contains("TRY_CAST"))      // amount/id/ts are checked
}

@Test func badRowCountIsRowsNotCells() throws {
    let sql = try badRowCountSQL(q("t"), colsList)
    #expect(sql.hasPrefix("SELECT count(*)"))
    #expect(sql.contains(" OR "))          // any bad cell makes the row bad
}

@Test func uncastableRefusesASuspiciousTypeName() throws {
    #expect(throws: UnsafeTypeName.self) {
        _ = try safeType("BIGINT); DROP TABLE x; --")
    }
    #expect(try safeType("DECIMAL(12,2)") == "DECIMAL(12,2)")
    #expect(try safeType("TIMESTAMP WITH TIME ZONE") == "TIMESTAMP WITH TIME ZONE")
}
