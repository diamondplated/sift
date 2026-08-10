import DuckDBKit
import Foundation
import SiftCore

// The read side of the session: SQL mode, profiling, and the three panels (top-N/distinct,
// histogram, bad-rows), plus the small state-only operations around them. Ported from
// engine/session.py lines 542-780: `run_sql`, `exit_sql_mode`, `compute_profile`, `profile_of`,
// `distinct`, `histogram`, `sample_values`, `length_histogram`, `bad_rows`, `set_spec`,
// `rendered_sql`, `snippet`.
//
// Every SQL string and every piece of profiling math already exists in SiftCore — `topNSQL`,
// `distinctStatsSQL`, `histogramSQL`, `profileExtraSQL`, `uncastableSQL`, `badRowsSQL`,
// `renderSQL`, `wrapUserSQL`, `parseSummarize`, `clampDistinct`, `chooseView`,
// `wantsExactDistinct`, `buildProfile`, `histogramParams`, `numericBounds`,
// `looksLikeExcelSerialDates`, `snippet` — so this file is orchestration only: fetch a `Table`,
// build its relation, open a `Connection`, run the SQL SiftCore already generated, decode the
// `Cell`s the way the paging path already does, and persist whatever changed back into
// `Session.tables`.
//
// CONNECTION STRATEGY: unlike `page`/`sortedRelation`/`closeTable` (Session.swift's header, fact
// 3), nothing here touches the shared, actor-owned `pagingConnection` — every function opens its
// own throwaway `Connection` per call, exactly like `openPath`'s initial half and
// `runAfterOpen`'s background pipeline. There is no materialized-sort state here for a second
// connection to fail to see, so there is no reason to share one — and no need for the "never
// awaits inside" proof that makes sharing `pagingConnection` safe.
//
// DECLARATION STYLE: functions that open a `Connection` and run SQL are declared `async throws`,
// matching `page`'s own precedent (synchronous inside, `async` anyway for API consistency — see
// its doc comment). Functions that only read/write `Table` state, with no `Connection`, are
// declared plain `throws`, matching `table(_:)`. Either way every call from outside the actor
// needs `await` regardless of the callee's own `async` keyword — `table(_:)` is proof of that
// (SessionTests.swift calls it `try await session.table(name)`), so this split is a documentation
// choice, not a functional one.

extension Session {

    // MARK: - SQL mode

    /// Execute the SQL box's text and page the result. Ported from Python's `run_sql`.
    ///
    /// The guard runs FIRST, before `t` is even fetched — a rejected query never touches the
    /// table, matching Python's ordering exactly. `assertSelectOnly` exists only to turn a bad
    /// query into a sentence; the actual enforcement is `wrapUserSQL`'s newline subquery wrap,
    /// where a non-SELECT cannot occupy a subquery position and dies in DuckDB's own parser (see
    /// GuardStatements.swift's header). Do not reorder these two calls.
    public func runSQL(_ name: String, sql: String, offset: Int, limit: Int) async throws -> TablePage {
        try assertSelectOnly(sql)
        var t = try table(name)
        t.sqlMode = true
        t.sqlText = sql
        tables[name] = t

        let (wrapped, params) = wrapUserSQL(sql, limit: limit, offset: offset)
        do {
            let con = try database.connect()
            let started = DispatchTime.now()
            let rs = try con.query(wrapped, params.map(toDBValue))
            let fetched = try rs.allRows()
            let columns = rs.columns.map {
                TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
            }
            return TablePage(
                columns: columns, rows: fetched, offset: offset, limit: limit,
                milliseconds: millisecondsSince(started),
                // No filtered/unfiltered concept in raw SQL mode — Python's own payload omits
                // both keys here (`total={"value": None, "exact": False}`); `nil`/`false` are the
                // nearest Swift equivalents in a struct that must give every field a value.
                total: TablePage.Total(value: nil, exact: false, unfiltered: nil, filtered: false)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Ported from Python's `exit_sql_mode`.
    public func exitSQLMode(_ name: String) throws -> Table {
        var t = try table(name)
        t.sqlMode = false
        t.sqlText = nil
        tables[name] = t
        return t
    }

    // MARK: - profiling

    /// Compute (and cache) this table's per-column profile. Ported from Python's
    /// `compute_profile`.
    ///
    /// Reuses `Table.uncastable` — the full per-column result Task 4's `detectBadRows` cached at
    /// open — instead of re-running the all-varchar scan `uncastableSQL` represents. That scan
    /// reads every cell of every text column; running it twice per open is exactly the cost this
    /// cache exists to avoid.
    public func computeProfile(_ name: String) async throws -> [ColumnProfile] {
        var t = try table(name)
        if let profile = t.profile { return profile }
        t.profiling = true
        defer {
            t.profiling = false
            tables[name] = t
        }

        do {
            let con = try database.connect()
            let rel = relation(t)

            let summRS = try con.query("SUMMARIZE \(rel)")
            let summRows = try summRS.allRows()
            let summ = parseSummarize(
                columnNames: summRS.columns.map(\.name),
                // Profile.swift's own signature note: `cell.isNull ? nil : cell.display`
                // round-trips a SUMMARIZE cell exactly, since SUMMARIZE returns min/max/quantiles
                // as VARCHAR precisely so heterogeneous columns share one result shape.
                rows: summRows.map { row in row.map { $0.isNull ? nil : $0.display } }
            )

            let extraRS = try con.query(profileExtraSQL(rel, t.spec.columns))
            let extraRow = try extraRS.allRows()[0]
            var extra: [String: Int] = [:]
            for (i, meta) in extraRS.columns.enumerated() { extra[meta.name] = cellInt(extraRow[i]) }

            let profile = buildProfile(
                cols: t.spec.columns, summ: summ, extra: extra, uncastable: t.uncastable ?? [:],
                nRows: extra["n"]
            )
            t.profile = profile
            for p in profile where looksLikeExcelSerialDates(p) && t.spec.fmt == .xlsx {
                t.notes.append(
                    "\u{201C}\(p.name)\u{201D} looks like Excel serial dates read as numbers "
                        + "(\(p.minS ?? "")\u{2013}\(p.maxS ?? ""))"
                )
            }
            return profile
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// Ported from Python's `profile_of`.
    public func profileOf(_ name: String, col: String) async throws -> ColumnProfile {
        let profile = try await computeProfile(name)
        guard let match = profile.first(where: { $0.name == col }) else {
            throw SessionError("No column '\(col)' in \(name).")
        }
        return match
    }

    // MARK: - distinct panel

    /// Ported from Python's `distinct`.
    public func distinct(
        _ name: String, col: String, limit: Int = 200, search: String? = nil
    ) async throws -> DistinctPanel {
        // Set unconditionally, even if `col` turns out not to exist below — matches Python, which
        // mutates the live `Table` before the column check ever runs.
        var t = try table(name)
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t

        let cols = t.cols
        guard let column = cols[col] else { throw SessionError("No column '\(col)' in \(name).") }

        // Faceting: this column's own filters are dropped so every value stays visible with the
        // selected ones highlighted — clicking "West" must not make the region panel show only
        // West. `selectedValues` below, by contrast, reads the UNFACETED filters on purpose: a
        // selected value must still highlight even though its own filter was just dropped from
        // the query that fetches the row list.
        let facet = t.qspec.withoutColumn(col).filters
        let rel = relation(t)
        do {
            let con = try database.connect()
            let started = DispatchTime.now()
            let (sql, params) = try topNSQL(rel, col, cols: cols, filters: facet, limit: limit, search: search)
            let rows = try con.query(sql, params.map(toDBValue)).allRows()

            // Swallowed exactly like Python's bare `except Exception: pass` — a table with no
            // profile yet (or one that fails to compute) still renders the panel, just without
            // the "chosen view" hint or a seed for whether to ask DuckDB for an exact distinct
            // count.
            let p = try? await profileOf(name, col: col)
            let approx = p?.approxDistinct ?? 0
            let (statsSQL, statsParams) = try distinctStatsSQL(
                rel, col, cols: cols, filters: facet, exact: wantsExactDistinct(approx)
            )
            let statsRS = try con.query(statsSQL, statsParams.map(toDBValue))
            let statsRow = try statsRS.allRows()[0]
            var stats: [String: Cell] = [:]
            for (i, meta) in statsRS.columns.enumerated() { stats[meta.name] = statsRow[i] }

            let selectedValues: [SQLValue] = t.qspec.filters
                .filter { $0.col == col && ($0.op == .eq || $0.op == .inList) }
                .flatMap(\.values)

            let values: [DistinctPanel.Value] = rows.map { row in
                let value = row[1]
                return DistinctPanel.Value(
                    label: panelLabel(row[0]), value: value, n: cellInt(row[2]), frac: cellDouble(row[3]),
                    selected: selectedValues.contains { cellEquals(value, $0) }
                )
            }
            let nRows = cellInt(stats["n_rows"] ?? .int(0))
            let shown = values.reduce(0) { $0 + $1.n }
            let nDistinct: Int
            let exact: Bool
            if let exactCell = stats["n_distinct_exact"] {
                exact = true
                nDistinct = cellInt(exactCell)
            } else {
                exact = false
                nDistinct = clampDistinct(cellInt(stats["n_distinct_approx"] ?? .int(0)), nRows)
            }

            return DistinctPanel(
                mode: p?.view ?? .topn, col: col, type: column.type, kind: column.kind,
                nRows: nRows, nNonnull: cellInt(stats["n_nonnull"] ?? .int(0)),
                nDistinct: .init(value: nDistinct, exact: exact),
                values: values, otherN: max(0, nRows - shown), shown: values.count,
                milliseconds: millisecondsSince(started)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - histogram panel

    /// Ported from Python's `histogram`.
    public func histogram(_ name: String, col: String, bins: Int = 40) async throws -> HistogramPanel {
        var t = try table(name)
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t

        let cols = t.cols
        guard let column = cols[col] else { throw SessionError("No column '\(col)' in \(name).") }
        // NOT swallowed, unlike `distinct`'s own `profileOf` call above — Python leaves this one
        // to propagate; it runs before the `try`/`except duckdb.Error` block even starts.
        let p = try await profileOf(name, col: col)
        let rel = relation(t)

        do {
            let con = try database.connect()
            let bounds: (lo: Double, hi: Double)?
            if column.kind == .temporal {
                let row = try con.query(
                    "SELECT min(epoch_ms(\(q(col))))::DOUBLE, max(epoch_ms(\(q(col))))::DOUBLE FROM \(rel)"
                ).allRows()[0]
                bounds = row[0].isNull ? nil : (cellDouble(row[0]), cellDouble(row[1]))
            } else {
                bounds = numericBounds(p)
            }
            guard let params = histogramParams(lo: bounds?.lo, hi: bounds?.hi, bins: bins) else {
                return HistogramPanel(
                    col: col, kind: nil, lo: nil, step: nil, bins: nil, nNull: p.nNull, buckets: [],
                    degenerate: true, reason: "every value is the same, or the range is empty",
                    milliseconds: nil
                )
            }

            let facet = t.qspec.withoutColumn(col).filters
            let (sql, sqlParams) = try histogramSQL(
                rel, col, cols: cols, lo: params.lo, step: params.step, bins: params.bins, filters: facet
            )
            let started = DispatchTime.now()
            let rows = try con.query(sql, sqlParams.map(toDBValue)).allRows()
            let buckets = rows.map { row -> HistogramPanel.Bucket in
                let b = cellInt(row[0])
                return HistogramPanel.Bucket(
                    b: b, lo: params.lo + params.step * Double(b), hi: params.lo + params.step * Double(b + 1),
                    n: cellInt(row[1]), bMin: row[2], bMax: row[3]
                )
            }
            return HistogramPanel(
                col: col, kind: column.kind, lo: params.lo, step: params.step, bins: params.bins,
                nNull: p.nNull, buckets: buckets, degenerate: false, reason: nil,
                milliseconds: millisecondsSince(started)
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    // MARK: - the smaller panels

    /// A random-ish sample, for the high-cardinality panel where top-N says nothing. Ported from
    /// Python's `sample_values`. Query failures are swallowed — the same `try/except
    /// duckdb.Error: return []` as Python, since this is a nice-to-have panel, not a correctness
    /// path — but a missing table still throws, since Python's own `t = self.table(name)` runs
    /// outside that try.
    public func sampleValues(_ name: String, col: String, limit: Int = 20) async throws -> [Cell] {
        let t = try table(name)
        let rel = relation(t)
        guard let con = try? database.connect(),
            let rows = try? con.query("SELECT \(q(col)) FROM \(rel) USING SAMPLE \(limit) ROWS"),
            let fetched = try? rows.allRows()
        else { return [] }
        return fetched.map { $0[0] }
    }

    /// Ported from Python's `length_histogram`. Same error-swallowing contract as `sampleValues`.
    public func lengthHistogram(_ name: String, col: String, bins: Int = 24) async throws -> [LengthBucket] {
        let t = try table(name)
        let rel = relation(t)
        let sql = "SELECT length(CAST(\(q(col)) AS VARCHAR)) AS len, count(*) AS n "
            + "FROM \(rel) WHERE \(q(col)) IS NOT NULL GROUP BY len ORDER BY len LIMIT \(bins)"
        guard let con = try? database.connect(), let rows = try? con.query(sql),
            let fetched = try? rows.allRows()
        else { return [] }
        return fetched.map { LengthBucket(len: cellInt($0[0]), n: cellInt($0[1])) }
    }

    /// The rows containing uncastable cells, for the "rows your file lost" panel. Ported from
    /// Python's `bad_rows`. `bad_columns` (`data[i][0]`) decodes as `Cell.list` — Task 1 closed
    /// the DuckDBKit gap that made this possible, and consuming it here (rather than a joined
    /// string) is the entire reason that gap was closed: the UI highlights individual cells, not
    /// just the row.
    ///
    /// Unlike every other function in this file, query failures here are NOT converted to
    /// `SessionError` — Python's `bad_rows` has no `try/except duckdb.Error` around this call
    /// either, so a `badRowsSQL` or query failure propagates as a raw `DuckDBError` (or
    /// `UnsafeTypeName`/`UnknownColumn`) unchanged. Preserved rather than "fixed": this is a
    /// behavioral port, not a correctness upgrade Python itself never made.
    public func badRows(_ name: String, limit: Int = 200) async throws -> BadRowsPanel {
        let t = try table(name)
        guard let raw = rawRelation(t), t.badCells > 0 else {
            return BadRowsPanel(cells: t.badCells, rows: t.badRows, columns: [], data: [])
        }
        let (sql, params) = try badRowsSQL(raw, t.spec.columns, limit: limit)
        let con = try database.connect()
        let rs = try con.query(sql, params.map(toDBValue))
        let fetched = try rs.allRows()
        let columns = rs.columns.map {
            TablePage.ColumnInfo(name: $0.name, type: $0.typeName, kind: kind(of: $0.typeName))
        }
        return BadRowsPanel(cells: t.badCells, rows: t.badRows, columns: columns, data: fetched)
    }

    // MARK: - filters / sort

    /// Replace the table's query spec, after validating every filter/sort column actually exists
    /// — a typo becomes a clean `SessionError`, not a binder dump. Ported from Python's
    /// `set_spec`.
    ///
    /// Resets `filteredCount` to `nil` so the next `page()` recounts — the invalidation half of
    /// Task 4's `pageCountsTheFilteredRelationOncePerSpecChangeNotPerPage`, which guards that the
    /// count STAYS cached across pages of the same spec; this is what makes it re-derive once the
    /// spec actually changes.
    public func setSpec(_ name: String, filters: [Filter], sort: [QuerySpec.SortTerm]) throws -> Table {
        var t = try table(name)
        let cols = t.cols
        for f in filters {
            guard cols[f.col] != nil else { throw SessionError("No column '\(f.col)' in \(name).") }
        }
        for s in sort {
            guard cols[s.column] != nil else { throw SessionError("No column '\(s.column)' in \(name).") }
        }
        t.qspec = QuerySpec(relation: t.name, filters: filters, sort: sort)
        t.filteredCount = nil
        if t.firstAggregateAt == nil { t.firstAggregateAt = Date() }
        tables[name] = t
        return t
    }

    /// Ported from Python's `rendered_sql`.
    public func renderedSQL(_ name: String) throws -> String {
        let t = try table(name)
        if t.sqlMode, let text = t.sqlText { return text }
        return renderSQL(t.qspec, cols: t.cols)
    }

    /// Ported from Python's `snippet`. Calls through `SiftCore.snippet` (module-qualified): an
    /// unqualified call from inside a method of the same name would recurse into itself instead
    /// of reaching SiftCore's free function.
    public func snippet(_ name: String, dialect: String) throws -> String {
        let t = try table(name)
        return try SiftCore.snippet(
            dialect: dialect, source: t.spec, spec: t.qspec, cols: t.cols,
            sqlOverride: t.sqlMode ? t.sqlText : nil
        )
    }
}

// MARK: - panel result types
//
// No JSON wire format exists anymore (Table.swift's header makes the same call for `summary()`),
// so these carry `Cell`/`SQLValue` directly rather than Python's `jsonable`-flattened `dict`.

public struct DistinctPanel: Sendable {
    public struct Value: Sendable {
        public let label: String
        public let value: Cell
        public let n: Int
        public let frac: Double
        public let selected: Bool
    }
    public struct DistinctCount: Sendable {
        public let value: Int
        public let exact: Bool
    }

    public let mode: ColumnProfile.View
    public let col: String
    public let type: String
    public let kind: Kind
    public let nRows: Int
    public let nNonnull: Int
    public let nDistinct: DistinctCount
    public let values: [Value]
    public let otherN: Int
    public let shown: Int
    public let milliseconds: Double
}

public struct HistogramPanel: Sendable {
    public struct Bucket: Sendable {
        public let b: Int
        public let lo: Double
        public let hi: Double
        public let n: Int
        public let bMin: Cell
        public let bMax: Cell
    }

    public let col: String
    /// `nil` only in the degenerate case, matching Python's dict, which simply omits the key.
    public let kind: Kind?
    public let lo: Double?
    public let step: Double?
    public let bins: Int?
    public let nNull: Int
    public let buckets: [Bucket]
    public let degenerate: Bool
    public let reason: String?
    public let milliseconds: Double?
}

public struct LengthBucket: Sendable, Equatable {
    public let len: Int
    public let n: Int
}

public struct BadRowsPanel: Sendable {
    public let cells: Int
    public let rows: Int
    public let columns: [TablePage.ColumnInfo]
    public let data: [[Cell]]
}

// MARK: - small Cell helpers local to this file
//
// `toDBValue`/`cellInt` (the SQLValue<->DBValue mapping, and Cell->Int for every count(*)-shaped
// result above) already exist in Session.swift, widened from `private` to internal so every file
// in this module shares one copy of each rather than a second copy that could silently drift —
// this branch has already ruled against exactly that duplication twice (Plan 2 Task 4's `col`/
// `asText`, Plan 2 Task 10's `grouped`), and both of these are decoders: drift changes a parsed
// value, not a format. `cellText`/`cellDouble`/`cellEquals` below have no equivalent elsewhere
// yet — same "swallow instead of throw" contract as SiftCore.Profile's looseInt/looseFloat: a
// shape a query should never actually produce degrades rather than throws.

/// The distinct panel's row label. Named `panelLabel`, not `cellText`, only because SourceProbe's
/// deliberately different `cellText` (strict: anything not `.text` reads as `""`) had to widen to
/// internal for Staging.swift, and two same-named top-level functions in one module collide even
/// when one is `private`. The pair stays two functions — Task 5's review looked at them and ruled
/// them genuinely different, unlike `cellInt`'s four copies: this one falls back to `display`
/// because a top-N label is a glyph, while the other one's result decides whether a file is
/// purged.
private func panelLabel(_ cell: Cell) -> String {
    if case .text(let s) = cell { return s }
    return cell.display
}

private func cellDouble(_ cell: Cell) -> Double {
    switch cell {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return 0
    }
}

/// Python's `r[1] in selected` compares two values of the SAME dynamic type (both raw DB values).
/// Swift keeps them as two different types — `Cell`, decoded from the topN query, and `SQLValue`,
/// bound into a filter — so this is the equality between them. The int/double cross-case matches
/// Python's own numeric equality (`5 == 5.0` is `True` there too).
private func cellEquals(_ cell: Cell, _ value: SQLValue) -> Bool {
    switch (cell, value) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.text(let a), .text(let b)): return a == b
    case (.int(let a), .double(let b)): return Double(a) == b
    case (.double(let a), .int(let b)): return a == Double(b)
    default: return false
    }
}

/// Elapsed milliseconds since `started`, rounded to one decimal place — matches every `round(...,
/// 1)` call in Python's own `time.perf_counter()` timings.
///
/// Not `private`: Export.swift times its COPY the same way and shares this rather than keeping a
/// second copy of the same rounding, on the same grounds as `cellInt`/`toDBValue` above.
func millisecondsSince(_ started: DispatchTime) -> Double {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
    return (elapsed * 10).rounded() / 10
}
