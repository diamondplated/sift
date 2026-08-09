import Testing
@testable import SiftCore

// MARK: - kind(of:)

@Test func nestedTypesAreDetected() {
    #expect(kind(of: "JSON") == .nested)
    #expect(kind(of: "STRUCT(a INTEGER, b VARCHAR)") == .nested)
    #expect(kind(of: "MAP(VARCHAR, INTEGER)") == .nested)
    #expect(kind(of: "UNION(a INTEGER, b VARCHAR)") == .nested)
    #expect(kind(of: "LIST") == .nested)
    #expect(kind(of: "ARRAY") == .nested)
    // Array-suffix form, e.g. INTEGER[] or INTEGER[3].
    #expect(kind(of: "INTEGER[]") == .nested)
    #expect(kind(of: "INTEGER[3]") == .nested)
}

// The load-bearing ordering trap: STRUCT(a INTEGER) contains the word INTEGER, so nesting
// must be checked before the numeric branch or this collapses to .number.
@Test func structContainingIntegerIsStillNestedNotNumber() {
    #expect(kind(of: "STRUCT(a INTEGER)") == .nested)
}

@Test func blobTypesAreDetected() {
    for t in ["BLOB", "BYTEA", "BINARY", "VARBINARY", "BIT"] {
        #expect(kind(of: t) == .blob)
    }
}

@Test func booleanIsDetected() {
    #expect(kind(of: "BOOLEAN") == .bool)
}

@Test func temporalTypesAreDetected() {
    #expect(kind(of: "TIMESTAMP") == .temporal)
    #expect(kind(of: "TIMESTAMP WITH TIME ZONE") == .temporal)
    #expect(kind(of: "DATE") == .temporal)
    #expect(kind(of: "TIME") == .temporal)
    #expect(kind(of: "INTERVAL") == .temporal)
}

@Test func numberTypesAreDetected() {
    #expect(kind(of: "DECIMAL(10,2)") == .number)
    #expect(kind(of: "NUMERIC") == .number)
    for t in [
        "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "REAL", "DOUBLE",
    ] {
        #expect(kind(of: t) == .number)
    }
}

@Test func textTypesAreDetected() {
    for t in ["VARCHAR", "CHAR", "TEXT", "STRING", "UUID"] {
        #expect(kind(of: t) == .text)
    }
    #expect(kind(of: "ENUM('a', 'b')") == .text)
}

@Test func unrecognizedTypeFallsBackToOther() {
    #expect(kind(of: "SOME_FUTURE_TYPE") == .other)
}

@Test func kindOfIsCaseAndWhitespaceInsensitive() {
    #expect(kind(of: "  varchar  ") == .text)
    #expect(kind(of: "integer") == .number)
}

// Python's str.strip() trims newlines too, not just spaces — .whitespaces alone would leave a
// trailing "\n" on the type string and miss this match. Guards against that regression.
@Test func kindOfTrimsNewlinesNotJustSpaces() {
    #expect(kind(of: "VARCHAR\n") == .text)
}

// MARK: - Column

@Test func columnComputesItsOwnKindFromItsType() {
    let c = Column(name: "amount", type: "DECIMAL(10,2)")
    #expect(c.kind == .number)
    #expect(c.name == "amount")
    #expect(c.type == "DECIMAL(10,2)")
}

@Test func columnOfStructTypeIsNestedNotNumber() {
    // Same ordering trap as kind(of:), exercised through the type Sift actually constructs.
    let c = Column(name: "payload", type: "STRUCT(a INTEGER)")
    #expect(c.kind == .nested)
}

// MARK: - SheetInfo.empty

@Test func sheetAtOneByOneIsEmpty() {
    #expect(SheetInfo(name: "Sheet1", rows: 1, cols: 1).empty)
}

@Test func sheetJustPastOneByOneIsNotEmpty() {
    #expect(!SheetInfo(name: "Sheet1", rows: 2, cols: 1).empty)
}

@Test func sheetWithZeroColumnsIsEmptyRegardlessOfRows() {
    #expect(SheetInfo(name: "Sheet1", rows: 50, cols: 0).empty)
}

@Test func sheetWithZeroRowsIsEmpty() {
    #expect(SheetInfo(name: "Sheet1", rows: 0, cols: 2).empty)
}

// MARK: - QuerySpec.withoutColumn

@Test func withoutColumnDropsOnlyThatColumnsFiltersAndKeepsOrder() {
    let spec = QuerySpec(
        relation: "t",
        filters: [
            Filter(col: "region", op: .eq, values: [.text("West")]),
            Filter(col: "status", op: .eq, values: [.text("open")]),
            Filter(col: "region", op: .notNull),
        ]
    )
    let result = spec.withoutColumn("region")
    #expect(result.filters == [Filter(col: "status", op: .eq, values: [.text("open")])])
    #expect(result.relation == "t")
}

@Test func withoutColumnOnAbsentColumnLeavesFiltersUnchanged() {
    let spec = QuerySpec(relation: "t", filters: [Filter(col: "status", op: .eq, values: [.text("open")])])
    #expect(spec.withoutColumn("region").filters == spec.filters)
}

// MARK: - SourceSpec.target

@Test func targetPrefersGlobOverPath() {
    let spec = SourceSpec(
        key: SourceKey(path: "/data/sales.csv", mtimeNs: 0, size: 0),
        fmt: .globCsv, readFn: "read_csv", glob: "/data/**/*.csv"
    )
    #expect(spec.target == "/data/**/*.csv")
}

@Test func targetFallsBackToPathWhenNoGlob() {
    let spec = SourceSpec(
        key: SourceKey(path: "/data/sales.csv", mtimeNs: 0, size: 0),
        fmt: .csv, readFn: "read_csv"
    )
    #expect(spec.target == "/data/sales.csv")
}

// MARK: - Op.nullary

@Test func nullaryOpsAreExactlyTheThreeValuelessOps() {
    let expected: Set<Op> = [.isNull, .notNull, .isEmpty]
    #expect(Op.nullary == expected)
}

// MARK: - Raw-value fidelity
//
// Not because web/index.html reads them — that file is deleted in Plan 5, and Types.swift's own
// comment was corrected to say so while this one was missed. The two live reasons: sqlgen
// interpolates `f.op` straight into SQL text, so `Op.rawValue` IS the SQL operator; and
// stage.py's CATALOG_DDL persists `fmt VARCHAR` into ~/.sift/stage.duckdb, which both engines
// open during the Plan 5 transition, so a changed string breaks an on-disk contract. A case
// without an explicit raw value silently breaks both — `.globCsv` would encode as "globCsv".

@Test func fmtRawValuesRoundTripThroughTheStagingCatalog() {
    #expect(Fmt.globParquet.rawValue == "glob_parquet")
    #expect(Fmt.globCsv.rawValue == "glob_csv")
}

@Test func opRawValuesMatchSqlOperatorSymbolsAndPythonLiterals() {
    #expect(Op.eq.rawValue == "=")
    #expect(Op.ne.rawValue == "!=")
    #expect(Op.inList.rawValue == "in")
    #expect(Op.notIn.rawValue == "not_in")
    #expect(Op.isNull.rawValue == "is_null")
    #expect(Op.notNull.rawValue == "not_null")
    #expect(Op.isEmpty.rawValue == "is_empty")
}
