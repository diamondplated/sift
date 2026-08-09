import Foundation

// SQL generation for the panels: top-N, distinct stats, histogram, the extra profiling scan,
// and the uncastable/bad-row queries. Pure — every function returns (sql, params) or a plain
// string; nothing here touches a connection. Ported from engine/core/sqlgen.py lines 134-306.
// Lines 1-131 and 308-369 are Task 3's, in SQLGen.swift.
//
// Invariant (pinned by SQLGenPanelsTests, ported from engine/tests/test_sqlgen.py): identifiers
// are quoted via q(), values are ALWAYS bound as `?` parameters — except safeType's DuckDB type
// name, the one deliberate exception (see its doc comment).

/// Non-NULL values that look like missing data. Compared against lower(trim(...)), so lowercase
/// only. "" catches whitespace-only; c{i}__empty/c{i}__nullish below keep true-empty disjoint
/// from it. Mirrors Python's module-level `NULLISH` tuple, verbatim order and contents.
private let nullish: [String] = [
    "", "na", "n/a", "null", "none", "nil", "-", "--", "—", "?", "#n/a", "#na",
    "nan", "not available", "unknown", ".",
]

// MARK: - Column lookup
//
// `col`/`asText` (the quoted-identifier and CAST-to-VARCHAR helpers) live in SQLGen.swift and
// are reused from there — no local copy. `lookupColumn` below is NOT a duplicate of those: it
// returns the whole `Column`, which histogramSQL needs for `.kind` (temporal vs. not), where
// `col` only ever returns the quoted name string. One adjacent existence check, not two copies
// of the same one.

private func lookupColumn(_ name: String, _ cols: [String: Column]) throws -> Column {
    guard let c = cols[name] else { throw UnknownColumn(column: name) }
    return c
}

// MARK: - Top-N

/// Top-N distinct values with counts and share-of-rows in a single pass —
/// `sum(count(*)) OVER ()` supplies the (filtered) percentage denominator in the same scan.
///
/// Pass `filters` already stripped of this column's own predicates (`QuerySpec.withoutColumn`)
/// so the panel keeps showing every value with the selected ones highlighted.
public func topNSQL(
    _ rel: String, _ colName: String, cols: [String: Column],
    filters: [Filter] = [], limit: Int = 200, search: String? = nil
) throws -> (String, [SQLValue]) {
    let c = try col(colName, cols)
    let txt = try asText(colName, cols)
    var (w, params) = try whereClause(filters, cols)
    var clauses = w.isEmpty ? [] : [w]
    if let search, !search.isEmpty {
        clauses.append("\(txt) ILIKE '%' || ? || '%'")
        params.append(.text(search))
    }
    let where_ = clauses.isEmpty ? "" : "\nWHERE " + clauses.joined(separator: " AND ")

    let sql = "SELECT\n"
        + "  CASE WHEN \(c) IS NULL THEN '␀ NULL'\n"
        + "       WHEN \(txt) = '' THEN '␀ EMPTY'\n"
        + "       ELSE \(txt) END AS label,\n"
        + "  \(c) AS value,\n"
        + "  count(*) AS n,\n"
        + "  count(*) * 1.0 / sum(count(*)) OVER () AS frac\n"
        + "FROM \(rel)\(where_)\n"
        + "GROUP BY ALL\n"
        + "ORDER BY n DESC, label\n"
        + "LIMIT ?"
    return (sql, params + [.int(Int64(limit))])
}

// MARK: - Distinct stats

/// Row/non-null/distinct counts for the panel footer. approx_count_distinct is HyperLogLog and
/// can exceed the true row count (measured: 340 for 300 distinct), so callers clamp to n. Exact
/// is opt-in: count(DISTINCT) on a high-cardinality column is expensive.
public func distinctStatsSQL(
    _ rel: String, _ colName: String, cols: [String: Column],
    filters: [Filter] = [], exact: Bool = false
) throws -> (String, [SQLValue]) {
    let c = try col(colName, cols)
    let (frag, params) = try whereClause(filters, cols)
    let w = frag.isEmpty ? "" : "\nWHERE \(frag)"
    let extra = exact ? ",\n  count(DISTINCT \(c)) AS n_distinct_exact" : ""
    let sql = "SELECT\n  count(*) AS n_rows,\n  count(\(c)) AS n_nonnull,"
        + "\n  approx_count_distinct(\(c)) AS n_distinct_approx\(extra)\nFROM \(rel)\(w)"
    return (sql, params)
}

// MARK: - Histogram

/// Fixed-width histogram in one pass, reusing lo/step from the cached profile. Per-bucket true
/// min/max feed the tooltip. Deliberately avoids width_bucket() (cross-version signature drift).
/// Empty buckets are simply absent; the client fills them.
public func histogramSQL(
    _ rel: String, _ colName: String, cols: [String: Column],
    _ lo: Double, _ step: Double, _ bins: Int, filters: [Filter] = []
) throws -> (String, [SQLValue]) {
    let c = try col(colName, cols)
    let column = try lookupColumn(colName, cols)
    let b = column.kind == .temporal ? "epoch_ms(\(c))::DOUBLE" : "\(c)::DOUBLE"
    let (w, params) = try whereClause(filters, cols)
    var clauses = ["\(c) IS NOT NULL"]
    if !w.isEmpty { clauses.append(w) }
    let where_ = "\nWHERE " + clauses.joined(separator: " AND ")
    let sql = "SELECT\n"
        + "  least(? - 1, greatest(0, floor((\(b) - ?) / ?)::INT)) AS b,\n"
        + "  count(*) AS n,\n"
        + "  min(\(c)) AS b_min,\n"
        + "  max(\(c)) AS b_max\n"
        + "FROM \(rel)\(where_)\n"
        + "GROUP BY b\n"
        + "ORDER BY b"
    return (sql, [.int(Int64(bins)), .double(lo), .double(step)] + params)
}

// MARK: - Profiling extras

/// One scan covering every column, for what SUMMARIZE misses: empty strings and null-like
/// sentinels ('NA', '-', '?'). Aliases are index-based (`c0__empty`), not name-based, so two
/// columns whose names sanitize identically cannot collide. n_null / n_empty / n_nullish are kept
/// disjoint: whitespace-only lands in nullish, true '' in empty.
public func profileExtraSQL(_ rel: String, _ cols: [Column]) -> String {
    let sentinels = nullish
        .map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        .joined(separator: ", ")
    var parts = ["count(*) AS n"]
    for (i, column) in cols.enumerated() {
        let c = q(column.name)
        let txt = "CAST(\(c) AS VARCHAR)"
        parts.append("count(*) FILTER (WHERE \(c) IS NULL) AS c\(i)__null")
        parts.append("count(*) FILTER (WHERE \(txt) = '') AS c\(i)__empty")
        parts.append(
            "count(*) FILTER (WHERE \(c) IS NOT NULL AND \(txt) <> ''"
                + " AND lower(trim(\(txt))) IN (\(sentinels))) AS c\(i)__nullish"
        )
        parts.append("max(length(\(txt))) AS c\(i)__maxlen")
    }
    return "SELECT\n  " + parts.joined(separator: ",\n  ") + "\nFROM \(rel)"
}

// MARK: - safeType and uncastable/bad-row queries

/// A DuckDB type name (from sniff_csv / DESCRIBE) — the one thing here interpolated rather than
/// bound, so whitelisted even though the values are engine-generated. Mirrors Python's
/// `_TYPE_RE = re.compile(r"^[A-Za-z0-9_ ()\[\],]+$")`: ASCII letters/digits, underscore, space,
/// parens, brackets, comma — nothing else, and at least one character.
///
/// `public`, unlike `safeType` itself: this is the only error thrown by the public
/// `uncastableSQL`/`badRowCountSQL`/`badRowsSQL`, so SiftEngine cannot `catch let e as
/// UnsafeTypeName` — or tell it apart from an UnknownColumn — while it is internal.
public struct UnsafeTypeName: SiftError, Equatable {
    public let type: String
    public var description: String { "refusing to interpolate suspicious type name '\(type)'" }
}

private func isSafeTypeScalar(_ scalar: Unicode.Scalar) -> Bool {
    let v = scalar.value
    if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) { return true }
    switch scalar {
    case "_", " ", "(", ")", "[", "]", ",": return true
    default: return false
    }
}

/// Exposed `internal` (not `public`) rather than kept file-private, so `@testable import
/// SiftCore` can reach it — mirroring engine/tests/test_sqlgen.py's deliberate `from
/// core.sqlgen import _safe_type`, importing a private symbol to test the whitelist directly.
func safeType(_ t: String) throws -> String {
    guard !t.isEmpty, t.unicodeScalars.allSatisfy(isSafeTypeScalar) else {
        throw UnsafeTypeName(type: t)
    }
    return t
}

/// Whether a TRY_CAST check is meaningful — text and nested columns can't fail to be text.
private func castable(_ col: Column) -> Bool {
    ![Kind.text, .other, .nested, .blob].contains(col.kind)
}

/// Predicate for "this varchar cell would not survive casting to the sniffed type".
private func badCell(_ col: Column) throws -> String {
    let c = q(col.name)
    return "(\(c) IS NOT NULL AND trim(\(c)) <> ''"
        + " AND TRY_CAST(\(c) AS \(try safeType(col.type))) IS NULL)"
}

/// Count cells that would fail to cast, scanning the all-varchar relation. Verified: DuckDB
/// 1.5.5 has no reject_scans()/reject_errors — store_rejects is accepted but produces no
/// queryable table. TRY_CAST names the column and can show the offending value anyway.
public func uncastableSQL(_ relVarchar: String, _ cols: [Column]) throws -> String {
    var parts = ["count(*) AS n"]
    for (i, column) in cols.enumerated() {
        if !castable(column) {
            parts.append("0 AS c\(i)__bad")  // nothing to fail; keeps the result shape uniform
            continue
        }
        parts.append("count(*) FILTER (WHERE \(try badCell(column))) AS c\(i)__bad")
    }
    return "SELECT\n  " + parts.joined(separator: ",\n  ") + "\nFROM \(relVarchar)"
}

/// Count ROWS with at least one uncastable cell (uncastableSQL counts cells). This is the number
/// that reconciles the grid: the typed relation is read with ignore_errors, so it returns
/// physical - bad_rows. Counting the typed relation directly can't produce it — projection
/// pushdown answers count(*) without parsing — hence the all-varchar relation.
public func badRowCountSQL(_ relVarchar: String, _ cols: [Column]) throws -> String {
    let conds = try cols.filter { castable($0) }.map { try badCell($0) }
    if conds.isEmpty {
        return "SELECT 0 AS n FROM \(relVarchar) LIMIT 1"
    }
    return "SELECT count(*) AS n\nFROM \(relVarchar)\nWHERE \(conds.joined(separator: " OR "))"
}

/// The rows containing uncastable cells; `bad_columns` is a list so the UI can highlight the
/// offending cells rather than just flagging the row.
public func badRowsSQL(
    _ relVarchar: String, _ cols: [Column], limit: Int = 200
) throws -> (String, [SQLValue]) {
    let checkable = cols.filter { castable($0) }
    guard !checkable.isEmpty else {
        return ("SELECT * FROM \(relVarchar) LIMIT 0", [])
    }
    var conds: [String] = []
    var labels: [String] = []
    for column in checkable {
        let cond = try badCell(column)
        conds.append(cond)
        labels.append("CASE WHEN \(cond) THEN \(qlit(column.name)) END")
    }
    let sql = "SELECT list_filter([\(labels.joined(separator: ", "))], x -> x IS NOT NULL) AS bad_columns, *\n"
        + "FROM \(relVarchar)\nWHERE \(conds.joined(separator: " OR "))\nLIMIT ?"
    return (sql, [.int(Int64(limit))])
}
