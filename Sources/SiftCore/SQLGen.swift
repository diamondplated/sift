import Foundation

// SQL generation: filters, paging, render, and the SELECT-only wrap. Pure — every function
// returns (sql, params) or a plain string; nothing here touches a connection. Ported from
// engine/core/sqlgen.py lines 1-131 and 308-369. Lines 134-306 (topn_sql, distinct_stats_sql,
// histogram_sql, profile_extra_sql, uncastable_sql, bad_row_count_sql, bad_rows_sql) are Task 4's
// and are not ported here.
//
// Invariant (pinned by SQLGenTests, ported from engine/tests/test_sqlgen.py): identifiers are
// quoted via q(), values are ALWAYS bound as `?` parameters. `rel` throughout is already-safe
// relation SQL — `q(tablename)` or a wrapped user subquery — callers decide which; sqlgen never
// builds it from user input.

/// A filter or sort referenced a column that isn't in the relation — a typo becomes a clean
/// error here, not a binder dump. Mirrors Python's `class UnknownColumn(KeyError)`.
public struct UnknownColumn: SiftError, Equatable {
    public let column: String
    public var description: String { "unknown column '\(column)'" }
}

/// Quote a column after checking it exists. Internal (not private) — SQLGenPanels.swift's
/// topNSQL/distinctStatsSQL/histogramSQL share this exact existence check rather than keeping a
/// second copy that could silently drift from it.
func col(_ name: String, _ cols: [String: Column]) throws -> String {
    guard cols[name] != nil else { throw UnknownColumn(column: name) }
    return q(name)
}

/// A column coerced to VARCHAR — for ILIKE, emptiness and length checks on any type.
func asText(_ name: String, _ cols: [String: Column]) throws -> String {
    "CAST(\(try col(name, cols)) AS VARCHAR)"
}

/// Render filters to a WHERE fragment (no WHERE keyword) plus bound params; ("", []) when empty.
public func whereClause(
    _ filters: [Filter], _ cols: [String: Column]
) throws -> (String, [SQLValue]) {
    var parts: [String] = []
    var params: [SQLValue] = []

    for f in filters {
        let c = try col(f.col, cols)

        if Op.nullary.contains(f.op) {
            switch f.op {
            case .isNull: parts.append("\(c) IS NULL")
            case .notNull: parts.append("\(c) IS NOT NULL")
            default: parts.append("\(try asText(f.col, cols)) = ''")   // is_empty
            }
            continue
        }

        guard !f.values.isEmpty else { continue }   // a value-taking op with nothing selected filters nothing

        switch f.op {
        case .eq, .ne, .lt, .le, .gt, .ge:
            parts.append("\(c) \(f.op.rawValue) ?")
            params.append(f.values[0])

        case .between:
            parts.append("\(c) BETWEEN ? AND ?")
            params.append(f.values[0])
            params.append(f.values[1])

        case .contains:
            parts.append("\(try asText(f.col, cols)) ILIKE '%' || ? || '%'")
            params.append(f.values[0])

        case .inList, .notIn:
            // NULL must be split out: `col IN (NULL)` never matches and `col NOT IN (NULL)` is
            // never true, and the distinct panel makes NULL clickable, so this path is normal use.
            let vals = f.values.filter { $0 != .null }
            let hasNull = vals.count != f.values.count
            var ors: [String] = []
            if !vals.isEmpty {
                let placeholders = Array(repeating: "?", count: vals.count).joined(separator: ", ")
                ors.append("\(c) \(f.op == .inList ? "IN" : "NOT IN") (\(placeholders))")
                params.append(contentsOf: vals)
            }
            if f.op == .inList {
                if hasNull { ors.append("\(c) IS NULL") }
                parts.append(ors.count > 1 ? "(" + ors.joined(separator: " OR ") + ")" : ors[0])
            } else {
                // Excluding values must not silently drop NULL rows unless NULL itself is excluded.
                if hasNull {
                    ors.append("\(c) IS NOT NULL")
                    parts.append(ors.count > 1 ? "(" + ors.joined(separator: " AND ") + ")" : ors[0])
                } else {
                    parts.append("(\(ors[0]) OR \(c) IS NULL)")
                }
            }

        case .isNull, .notNull, .isEmpty:
            break   // handled above via the nullary branch; unreachable here
        }
    }

    return (parts.joined(separator: " AND "), params)
}

/// The WHERE fragment prefixed with the keyword, or "" when there are no filters.
private func whereFragment(
    _ filters: [Filter], _ cols: [String: Column]
) throws -> (String, [SQLValue]) {
    let (frag, params) = try whereClause(filters, cols)
    return (frag.isEmpty ? "" : "\nWHERE \(frag)", params)
}

/// ORDER BY with explicit NULLS LAST, so ordering survives a change in engine defaults. Ties on
/// a non-unique column are still unordered across pages — SiftEngine materializes for that.
public func orderBy(_ sort: [(String, String)], _ cols: [String: Column]) throws -> String {
    var terms: [String] = []
    for (name, direction) in sort {
        let d = direction.lowercased().hasPrefix("d") ? "DESC" : "ASC"
        terms.append("\(try col(name, cols)) \(d) NULLS LAST")
    }
    return terms.isEmpty ? "" : "\nORDER BY " + terms.joined(separator: ", ")
}

public func pageSQL(
    _ spec: QuerySpec, cols: [String: Column], rel: String, limit: Int, offset: Int
) throws -> (String, [SQLValue]) {
    let (w, params) = try whereFragment(spec.filters, cols)
    let sortTuples = spec.sort.map { ($0.column, $0.direction.rawValue) }
    let sql = "SELECT *\nFROM \(rel)\(w)\(try orderBy(sortTuples, cols))\nLIMIT ? OFFSET ?"
    return (sql, params + [.int(Int64(limit)), .int(Int64(offset))])
}

/// Measured trap: see source.exact_count — count(*) via projection pushdown ignores uncastable
/// rows; SiftEngine counts the all-varchar relation.
public func countSQL(
    _ spec: QuerySpec, cols: [String: Column], rel: String
) throws -> (String, [SQLValue]) {
    let (w, params) = try whereFragment(spec.filters, cols)
    return ("SELECT count(*) AS n\nFROM \(rel)\(w)", params)
}

/// Format one filter value for display — never for execution.
private func literal(_ v: SQLValue) -> String {
    switch v {
    case .null: return "NULL"
    case .bool(let b): return b ? "TRUE" : "FALSE"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// Python's `str(value)` — used only to interpolate a value into a `%...%` CONTAINS pattern
/// before the whole pattern is wrapped as one string literal by `literal`.
private func pyStr(_ v: SQLValue) -> String {
    switch v {
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .text(let s): return s
    }
}

/// Pretty, human-editable SQL equivalent to the current UI state. Values are inlined ONLY
/// because this is display text for the SQL box/clipboard, never executed — the executed path
/// is `pageSQL` with bound parameters. Do not "fix" this to bind values; that would defeat the
/// entire point of `pageSQL` existing.
public func renderSQL(_ spec: QuerySpec, cols: [String: Column]) -> String {
    var lines = ["SELECT *", "FROM \(q(spec.relation))"]
    var preds: [String] = []
    for f in spec.filters {
        let c = q(f.col)
        switch f.op {
        case .isNull:
            preds.append("\(c) IS NULL")
        case .notNull:
            preds.append("\(c) IS NOT NULL")
        case .isEmpty:
            preds.append("CAST(\(c) AS VARCHAR) = ''")
        // Deliberate defensive deviation (noted in Task 4's review): Python indexes
        // f.values[0]/[1] here unconditionally and would raise IndexError on a malformed filter
        // (empty values for contains, fewer than two for between). These two branches guard with
        // `if let` / `count >= 2` instead and silently drop the predicate. Behavior is otherwise
        // unchanged, and the blast radius is small — renderSQL is display-only, never executed.
        case .contains:
            if let v = f.values.first {
                preds.append("CAST(\(c) AS VARCHAR) ILIKE \(literal(.text("%\(pyStr(v))%")))")
            }
        case .between:
            if f.values.count >= 2 {
                preds.append("\(c) BETWEEN \(literal(f.values[0])) AND \(literal(f.values[1]))")
            }
        case .inList, .notIn:
            let nonNull = f.values.filter { $0 != .null }
            let hasNull = nonNull.count != f.values.count
            let valsStr = nonNull.map { literal($0) }.joined(separator: ", ")
            let kw = f.op == .inList ? "IN" : "NOT IN"
            var frag = valsStr.isEmpty ? "" : "\(c) \(kw) (\(valsStr))"
            if hasNull {
                let nul = f.op == .inList ? "\(c) IS NULL" : "\(c) IS NOT NULL"
                if !valsStr.isEmpty {
                    frag = f.op == .inList ? "(\(frag) OR \(nul))" : "(\(frag) AND \(nul))"
                } else {
                    frag = nul
                }
            }
            preds.append(frag)
        default:   // eq, ne, lt, le, gt, ge
            if let v = f.values.first {
                preds.append("\(c) \(f.op.rawValue) \(literal(v))")
            }
        }
    }
    if !preds.isEmpty {
        lines.append("WHERE " + preds.joined(separator: "\n  AND "))
    }
    if !spec.sort.isEmpty {
        let terms = spec.sort.map { "\(q($0.column)) \($0.direction == .desc ? "DESC" : "ASC")" }
        lines.append("ORDER BY " + terms.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
}

/// Wrap a user SELECT for paging, so non-SELECTs die at parse time. The newlines are
/// load-bearing — measured on DuckDB 1.5.5: the flat form `SELECT * FROM ( <sql> ) AS _q`
/// rejects a legitimate `select 1 -- comment` (the comment swallows the paren); with the paren
/// on its own line, trailing comments work and every dangerous statement (DROP/COPY/ATTACH/
/// INSTALL/PRAGMA/SET/CREATE...AS/EXPORT, `SELECT 1; DROP ...`) still fails with a parse error.
/// That grammar-level rejection — not a keyword blocklist — is the actual enforcement; the guard
/// (Task 5) runs first only so the error message is a sentence instead of a parser dump.
public func wrapUserSQL(_ sql: String, limit: Int, offset: Int) -> (String, [SQLValue]) {
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    return (
        "SELECT * FROM (\n\(trimmed)\n) AS _q\nLIMIT ? OFFSET ?",
        [.int(Int64(limit)), .int(Int64(offset))]
    )
}
