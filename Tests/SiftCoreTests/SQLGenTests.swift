import Testing
import DuckDBKit
@testable import SiftCore

// SQL generation: filters, paging, render, and the wrap. Ported from twelve tests in
// engine/tests/test_sqlgen.py (the rest are Task 4's) and the three wrap_* tests near the
// bottom of engine/tests/test_guard.py (the rest of that file is Task 5's).
//
// The invariant under test throughout: identifiers are quoted, values are bound as
// parameters. Nothing user-supplied is ever interpolated into SQL text.

private let cols: [String: Column] = {
    let list = [
        Column(name: "region", type: "VARCHAR"),
        Column(name: "amount", type: "DECIMAL(12,2)"),
        Column(name: "id", type: "BIGINT"),
        Column(name: "ts", type: "TIMESTAMP"),
        Column(name: "ok", type: "BOOLEAN"),
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
}()

private let evilName = "\"; DROP TABLE x; --"
private let evilCols: [String: Column] = [evilName: Column(name: evilName, type: "VARCHAR")]

/// SiftCore declares SQLValue, DuckDBKit declares DBValue — deliberately not the same type
/// (see SQLValue's doc comment). This is the five-line mapping between them, scoped to this
/// test file only, so tests can bind SQLValue params against a real connection.
private func toDBValue(_ v: SQLValue) -> DBValue {
    switch v {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .text(let s): return .text(s)
    }
}

// MARK: - where_clause

@Test func aHostileColumnNameStaysOneQuotedIdentifier() throws {
    let (sql, params) = try whereClause(
        [Filter(col: evilName, op: .eq, values: [.text("v")])], evilCols
    )
    #expect(sql == "\"\"\"; DROP TABLE x; --\" = ?")
    #expect(params == [.text("v")])

    // And it survives a real parser: the identifier binds, the "statement" inside it does not run.
    let con = try Database.inMemory().connect()
    try con.execute("CREATE TABLE t (\(q(evilName)) VARCHAR)")
    try con.execute("INSERT INTO t VALUES ('v')")
    let rows = try con.query("SELECT count(*) FROM t WHERE \(sql)", params.map(toDBValue)).allRows()
    #expect(rows[0][0] == .int(1))
}

@Test func valuesAreNeverInlined() throws {
    let (sql, params) = try whereClause(
        [Filter(col: "region", op: .eq, values: [.text("O'Brien")])], cols
    )
    #expect(!sql.contains("O'Brien"))
    #expect(params == [.text("O'Brien")])
}

@Test func unknownColumnIsRejectedEarly() {
    #expect(throws: UnknownColumn.self) {
        _ = try whereClause([Filter(col: "nope", op: .eq, values: [.int(1)])], cols)
    }
    #expect(throws: UnknownColumn.self) {
        _ = try orderBy([QuerySpec.SortTerm(column: "nope", direction: .asc)], cols)
    }
}

@Test(arguments: [
    (Filter(col: "region", op: .eq, values: [.text("W")]), "\"region\" = ?", [SQLValue.text("W")]),
    (Filter(col: "amount", op: .ge, values: [.int(5)]), "\"amount\" >= ?", [SQLValue.int(5)]),
    (Filter(col: "amount", op: .between, values: [.int(1), .int(9)]),
     "\"amount\" BETWEEN ? AND ?", [SQLValue.int(1), SQLValue.int(9)]),
    (Filter(col: "region", op: .isNull), "\"region\" IS NULL", []),
    (Filter(col: "region", op: .notNull), "\"region\" IS NOT NULL", []),
    (Filter(col: "region", op: .isEmpty), "CAST(\"region\" AS VARCHAR) = ''", []),
    (Filter(col: "region", op: .contains, values: [.text("oo")]),
     "CAST(\"region\" AS VARCHAR) ILIKE '%' || ? || '%'", [SQLValue.text("oo")]),
    (Filter(col: "region", op: .inList, values: [.text("A"), .text("B")]),
     "\"region\" IN (?, ?)", [SQLValue.text("A"), SQLValue.text("B")]),
])
func operatorRendering(f: Filter, wantSQL: String, wantParams: [SQLValue]) throws {
    let (sql, params) = try whereClause([f], cols)
    #expect(sql == wantSQL)
    #expect(params == wantParams)
}

// The distinct panel makes NULL clickable, so multi-select including it is normal use.
// `col IN (NULL)` never matches, so without the split the filter would silently return nothing.
@Test func inWithNullSplitsTheNullOut() throws {
    let (sql, params) = try whereClause(
        [Filter(col: "region", op: .inList, values: [.text("W"), .null])], cols
    )
    #expect(sql == "(\"region\" IN (?) OR \"region\" IS NULL)")
    #expect(params == [.text("W")])
}

@Test func notInKeepsNullRowsUnlessNullIsItselfExcluded() throws {
    // Excluding "West" should not also quietly drop rows where region is NULL.
    let (sql, _) = try whereClause([Filter(col: "region", op: .notIn, values: [.text("W")])], cols)
    #expect(sql == "(\"region\" NOT IN (?) OR \"region\" IS NULL)")
    let (sql2, _) = try whereClause(
        [Filter(col: "region", op: .notIn, values: [.text("W"), .null])], cols
    )
    #expect(sql2 == "(\"region\" NOT IN (?) AND \"region\" IS NOT NULL)")
}

@Test func valueTakingOpWithNoValuesFiltersNothing() throws {
    let (sql, params) = try whereClause([Filter(col: "region", op: .inList, values: [])], cols)
    #expect(sql == "" && params == [])
}

// MARK: - order_by

@Test func orderByIsExplicitAboutNulls() throws {
    #expect(try orderBy([QuerySpec.SortTerm(column: "amount", direction: .desc)], cols) == "\nORDER BY \"amount\" DESC NULLS LAST")
    #expect(try orderBy([], cols) == "")
}

// MARK: - page_sql / count_sql

@Test func pageSQLBindsLimitAndOffsetLast() throws {
    let spec = QuerySpec(
        relation: "t",
        filters: [Filter(col: "region", op: .eq, values: [.text("W")])],
        sort: [QuerySpec.SortTerm(column: "amount", direction: .desc)]
    )
    let (sql, params) = try pageSQL(spec, cols: cols, rel: q("t"), limit: 500, offset: 1000)
    #expect(params == [.text("W"), .int(500), .int(1000)])
    #expect(sql.contains("LIMIT ? OFFSET ?"))
    #expect(sql.contains("ORDER BY \"amount\" DESC"))
}

@Test func countSQLCarriesTheFilters() throws {
    let spec = QuerySpec(
        relation: "t",
        filters: [Filter(col: "region", op: .inList, values: [.text("W"), .text("E")])]
    )
    let (sql, params) = try countSQL(spec, cols: cols, rel: q("t"))
    #expect(params == [.text("W"), .text("E")])
    #expect(sql.hasPrefix("SELECT count(*)"))
}

// MARK: - render_sql

@Test func renderSQLIsReadableAndQuoted() {
    let spec = QuerySpec(
        relation: "sales",
        filters: [
            Filter(col: "region", op: .inList, values: [.text("West"), .text("Midwest")]),
            Filter(col: "amount", op: .ge, values: [.int(100)]),
        ],
        sort: [QuerySpec.SortTerm(column: "amount", direction: .desc)]
    )
    let out = renderSQL(spec, cols: cols)
    #expect(out.hasPrefix("SELECT *\n"))
    #expect(out.contains("FROM \"sales\""))
    #expect(out.contains("'West', 'Midwest'"))
    #expect(out.contains("ORDER BY \"amount\" DESC"))
}

@Test func renderSQLEscapesQuotesInDisplayedLiterals() {
    let spec = QuerySpec(
        relation: "t", filters: [Filter(col: "region", op: .eq, values: [.text("O'Brien")])]
    )
    #expect(renderSQL(spec, cols: cols).contains("'O''Brien'"))
}

// MARK: - wrap_user_sql (engine/tests/test_guard.py, the wrap_* tests only)

// The layer that actually enforces things. A non-SELECT cannot occupy a subquery position, so
// DuckDB's parser rejects it — a grammar-level guarantee rather than a keyword blocklist.
@Test(arguments: [
    "DROP TABLE x", "SELECT 1; DROP TABLE x", "COPY (SELECT 1) TO '/tmp/x.csv'",
    "ATTACH 'x.db' AS y", "INSTALL httpfs", "PRAGMA database_list", "SET threads=1",
    "CREATE TABLE z AS SELECT 1", "EXPORT DATABASE '/tmp/d'", "INSERT INTO x VALUES (1)",
])
func wrapEnforcementRejectsAtParseTime(sql: String) throws {
    let con = try Database.inMemory().connect()
    let (wrapped, params) = wrapUserSQL(sql, limit: 5, offset: 0)
    #expect(throws: DuckDBError.self) {
        _ = try con.query(wrapped, params.map(toDBValue)).allRows()
    }
}

@Test(arguments: [
    "SELECT 1", "WITH a AS (SELECT 1) SELECT * FROM a", "VALUES (1),(2)",
    "select 1 -- trailing comment", "SELECT 1 /* block */",
])
func wrapStillRunsLegitimateSelects(sql: String) throws {
    let con = try Database.inMemory().connect()
    let (wrapped, params) = wrapUserSQL(sql, limit: 5, offset: 0)
    #expect(try !con.query(wrapped, params.map(toDBValue)).allRows().isEmpty)
}

@Test func wrapPutsTheClosingParenOnItsOwnLine() throws {
    // The newline is load-bearing, not cosmetic. With the flat form
    // `SELECT * FROM ( <sql> ) AS _q`, a trailing `-- comment` swallows the closing paren and a
    // perfectly good query is rejected. Measured on DuckDB 1.5.5.
    let con = try Database.inMemory().connect()
    let sql = "select 1 -- x"
    let flat = "SELECT * FROM ( \(sql) ) AS _q LIMIT 5"
    #expect(throws: DuckDBError.self) {
        _ = try con.query(flat).allRows()
    }
    let (wrapped, params) = wrapUserSQL(sql, limit: 5, offset: 0)
    #expect(wrapped.contains("\n) AS _q"))
    let rows = try con.query(wrapped, params.map(toDBValue)).allRows()
    #expect(rows == [[.int(1)]])
}
