import DuckDBKit
import Foundation
import SiftCore

// Joins: how well two open tables actually line up on a key, which keys to try, and blending
// two of them into a third. Ported from engine/session.py lines 1017-1113: `join_probe`,
// `unmatched_keys`, `join_candidates`, `_JOINS` and `merge`. (`unstage`, which sits between
// `merge` and `export` in session.py, belongs to the staging lifecycle and is already in
// Staging.swift.)
//
// `join_probe`'s one number prevents more bad analyses than anything else in this file:
// "1,204 of 1,318 match (91.4%)" tells you immediately whether the key is right. It is a
// semi-join over the DISTINCT key tuples of each side, never a full join with a count — the
// shape matters, because a full join multiplies on duplicate keys and would report a number
// that is not "how many of my keys found a partner".
//
// CONNECTION STRATEGY: same as SessionQueries.swift — every function here opens its own
// throwaway `Connection` and never touches the actor-owned `pagingConnection`. Nothing here
// creates a TEMP TABLE, so there is no per-connection state for a second connection to fail to
// see, and none of these is on the paging hot path.

// MARK: - result types

/// How well two tables join on a set of keys. `pct` is a fraction (0.0-1.0), not a percentage —
/// formatting is the UI's job, and this is the value it multiplies.
///
/// A key tuple containing NULL counts toward `leftDistinct` but can never count toward
/// `matched`: SQL's `USING` compares with `=`, and `NULL = NULL` is unknown. That is the honest
/// answer (a NULL key genuinely does not join) and it is what the SEMI JOIN below reports;
/// JoinsTests pins it so it cannot be "fixed" into a lie later.
public struct JoinProbe: Sendable, Equatable {
    public let left: String
    public let right: String
    public let on: [String]
    /// Distinct key tuples on the left — the denominator.
    public let leftDistinct: Int
    public let matched: Int
    public let unmatched: Int
    public let pct: Double
}

/// One column both tables have, and whether their types are compatible enough to join on.
public struct JoinCandidate: Sendable, Equatable {
    public let col: String
    public let leftType: String
    public let rightType: String
    /// Same `Kind`, not the same type string: BIGINT and INTEGER join fine.
    public let compatible: Bool
}

/// The left-side key tuples that found no partner. Same column-metadata-plus-rows shape as
/// `BadRowsPanel` (SessionQueries.swift), which is this port's stand-in for Python's
/// `rows_payload` — there is no JSON wire format anymore, so `Cell`s travel as themselves.
public struct UnmatchedKeys: Sendable {
    public let columns: [TablePage.ColumnInfo]
    public let rows: [[Cell]]
}

/// The four join shapes `merge` can build. Python carries these as a `dict[str, str]` keyed by a
/// caller-supplied string (`_JOINS`), with an "Unknown join type" error for a key that misses.
///
/// An enum instead, for the same reason `QuerySpec.SortDirection`, `Op`, `Fmt` and `Kind` are all
/// enums here where Python had strings (SiftCore/Types.swift states the house rule): it makes it
/// structurally impossible for a caller-supplied string to reach the SQL text at all, which is
/// the whole theme of this file's neighbour, Export.swift. The runtime "unknown join type" error
/// disappears with it — a bad value cannot be constructed. `rawValue` still round-trips a stored
/// or menu-bound string, and `init?(rawValue:)` gives a caller that genuinely has a string one
/// place to reject it.
public enum JoinType: String, Sendable, CaseIterable {
    case inner, left, right, full

    /// The SQL keyword. Not user input, and not reachable from any: the only values that exist
    /// are the four below.
    var sql: String {
        switch self {
        case .inner: return "JOIN"
        case .left: return "LEFT JOIN"
        case .right: return "RIGHT JOIN"
        case .full: return "FULL JOIN"
        }
    }
}

// MARK: - Session

extension Session {

    /// How well two tables actually join on these keys. Ported from Python's `join_probe`.
    public func joinProbe(_ left: String, _ right: String, on: [String]) async throws -> JoinProbe {
        let lt = try table(left)
        let rt = try table(right)
        try checkJoinKeys(on, lt, rt)

        let keys = on.map(q).joined(separator: ", ")
        let leftDistinct = "(SELECT DISTINCT \(keys) FROM \(q(lt.name)))"
        let rightDistinct = "(SELECT DISTINCT \(keys) FROM \(q(rt.name)))"
        do {
            let con = try database.connect()
            let ldist = cellInt(try con.query("SELECT count(*) FROM \(leftDistinct)").allRows()[0][0])
            // SEMI JOIN, not `JOIN` with a count: a full join multiplies on duplicate keys, so
            // its count is "how many pairings exist", not "how many of my keys found a partner"
            // — the second is the number the user is reading.
            let matched = cellInt(try con.query(
                "SELECT count(*) FROM \(leftDistinct) a SEMI JOIN \(rightDistinct) b USING (\(keys))"
            ).allRows()[0][0])
            return JoinProbe(
                left: left, right: right, on: on, leftDistinct: ldist, matched: matched,
                unmatched: ldist - matched, pct: ldist > 0 ? Double(matched) / Double(ldist) : 0.0
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// The left-side key tuples with no partner on the right. Ported from Python's
    /// `unmatched_keys`.
    ///
    /// DIVERGENCE, reported as a defect rather than ported: Python's `unmatched_keys` never
    /// calls `self.table(...)` and never checks the key columns, so a closed table or a typo'd
    /// key escapes as a raw `duckdb.BinderException` instead of the one clean sentence every
    /// other method in session.py contracts for — and it has no `except duckdb.Error` either.
    /// It is unreachable through the UI (the panel only calls this after `join_probe` accepted
    /// the same arguments), which is presumably why it shipped. Here it runs the same validation
    /// `joinProbe` does, through the same helper, and reports failures the same way.
    public func unmatchedKeys(
        _ left: String, _ right: String, on: [String], limit: Int = 200
    ) async throws -> UnmatchedKeys {
        let lt = try table(left)
        let rt = try table(right)
        try checkJoinKeys(on, lt, rt)

        let keys = on.map(q).joined(separator: ", ")
        do {
            let con = try database.connect()
            let rs = try con.query(
                "SELECT * FROM (SELECT DISTINCT \(keys) FROM \(q(lt.name))) a "
                    + "ANTI JOIN (SELECT DISTINCT \(keys) FROM \(q(rt.name))) b USING (\(keys)) "
                    + "LIMIT ?",
                [.int(Int64(limit))]
            )
            let rows = try rs.allRows()
            return UnmatchedKeys(
                columns: rs.columns.map {
                    TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
                },
                rows: rows
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Propose keys by name match plus type compatibility. Ported from Python's
    /// `join_candidates`. No connection: both tables' shapes are already in their specs.
    ///
    /// LANDMINE, and the reason this iterates `spec.columns` rather than the `cols` dictionary:
    /// Python's `for name, lc in lt.cols.items()` walks an insertion-ordered dict built from the
    /// file's own column order, so its candidate list comes back in file order every time. A
    /// Swift `Dictionary` has no iteration order at all, so the same call would shuffle the list
    /// between two runs of one session — the same class of silent order loss `ReadArg`'s doc
    /// comment bans for `columns=`. `spec.columns` IS that file order.
    public func joinCandidates(_ left: String, _ right: String) throws -> [JoinCandidate] {
        let lt = try table(left)
        let rt = try table(right)
        let lcols = lt.cols
        let rcols = rt.cols
        var seen = Set<String>()
        return lt.spec.columns.compactMap { column in
            // `seen` plus the `lcols` lookup reproduces the dict Python iterates exactly: a
            // duplicate header appears once, at its FIRST position, carrying the LAST
            // definition's type (`Table.cols`' own "last wins" note).
            guard seen.insert(column.name).inserted,
                let lc = lcols[column.name], let rc = rcols[column.name]
            else { return nil }
            return JoinCandidate(
                col: column.name, leftType: lc.type, rightType: rc.type, compatible: lc.kind == rc.kind
            )
        }
    }

    /// Blend two open tables into a NEW source that shows up in the sidebar. Ported from Python's
    /// `merge`.
    ///
    /// **A view, not a copy** — instant, no duplication, and `export` materializes it on demand.
    /// Do not "improve" this into a CTAS: the whole point is that blending two 5 GB tables costs
    /// nothing until someone asks for bytes on disk.
    ///
    /// The right side's key columns are dropped `USING`-style so the keys are not duplicated.
    /// Any OTHER name clash is DuckDB's to disambiguate, and it is surfaced as-is — MEASURED
    /// against the vendored 1.5.5 (JoinsTests pins it): `a(k, v)` joined to `b(k, v)` yields
    /// `k, v, v_1`, NOT the `right.v` Python's own docstring claims. That docstring is describing
    /// behavior this DuckDB does not have; the port matches the engine, and the test names the
    /// real shape so a future DuckDB changing it is a red test rather than a surprise column.
    @discardableResult
    public func merge(
        _ left: String, _ right: String, on: [String], how: JoinType = .inner, name: String? = nil
    ) async throws -> Table {
        let lt = try table(left)
        let rt = try table(right)
        try checkJoinKeys(on, lt, rt)

        let base = try sanitizeTableName(name ?? "\(left)_\(right)", taken: Set(tables.keys))
        let keys = on.map(q).joined(separator: ", ")
        // SELECT * with USING keeps one copy of each key and both tables' other columns.
        let select = "SELECT * FROM \(q(lt.name)) \(how.sql) \(q(rt.name)) USING (\(keys))"

        let columns: [Column]
        let rowCount: Int
        do {
            let con = try database.connect()
            try con.execute("CREATE OR REPLACE VIEW \(q(base)) AS \(select)")
            columns = try con.query("DESCRIBE \(q(base))").allRows().map {
                Column(name: cellText($0[0]), type: cellText($0[1]))
            }
            rowCount = cellInt(try con.query("SELECT count(*) FROM \(q(base))").allRows()[0][0])
        } catch let error as DuckDBError {
            // Python wraps neither of these three statements, so a join DuckDB refuses (two key
            // columns of genuinely incompatible types, say) escapes `merge` as a raw
            // `duckdb.BinderException` — the one public method in session.py that does not
            // contract for a clean sentence. Wrapped here, like every other one.
            throw SessionError(error.firstLine)
        }

        let spec = SourceSpec(
            key: SourceKey(path: "merge://\(left)+\(right)", mtimeNs: 0, size: 0),
            fmt: .merge, readFn: "", columns: columns, rowCount: rowCount
        )
        nextOpenGeneration += 1
        var t = Table(
            name: base, spec: spec, qspec: QuerySpec(relation: base), openedAt: nextOpenGeneration
        )
        t.rowCount = rowCount
        t.notes.append(
            "\(how.rawValue) join of \(left) + \(right) on \(on.joined(separator: ", ")) "
                + "\u{2014} a view; Export it to save a copy"
        )
        tables[base] = t

        // Profiled eagerly like any freshly-opened source, exactly where Python profiles it.
        // Python then emits `{"type": "opened"}`; in-process the catalog write above IS that.
        _ = try await computeProfile(base)
        // `Table` is a struct, so the profile `computeProfile` just stored lives in the catalog's
        // copy, not in `t` — return the catalog's (the same object Python's caller gets back).
        return tables[base] ?? t
    }
}

// MARK: - shared validation

/// Every key column must exist on both sides, and there must be at least one of them.
///
/// DIVERGENCE, reported: only `merge` rejects an empty key list in Python — `join_probe` and
/// `unmatched_keys` interpolate the empty join into `SELECT DISTINCT  FROM x` and hand the user
/// `Parser Error: syntax error at or near "FROM"`. Same three-word fix for all three callers,
/// and the sentence is the one `merge` already spells.
private func checkJoinKeys(_ on: [String], _ lt: Table, _ rt: Table) throws {
    guard !on.isEmpty else { throw SessionError("Pick at least one key column to join on.") }
    let lcols = lt.cols
    let rcols = rt.cols
    for c in on {
        guard lcols[c] != nil else { throw SessionError("No column '\(c)' in \(lt.name).") }
        guard rcols[c] != nil else { throw SessionError("No column '\(c)' in \(rt.name).") }
    }
}
