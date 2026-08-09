import Foundation

// Column profiling: what SUMMARIZE gives, what it misses, and which panel a column deserves.
//
// Pure — takes already-fetched values, returns value types. Ported from engine/core/profile.py.
//
// SIGNATURE NOTE: Python's parse_summarize(description, rows) takes a DB-API cursor description
// and raw row tuples of Any. SiftCore imports Foundation only, so DuckDBKit's ColumnMeta/Cell are
// unavailable here — parseSummarize instead takes (columnNames: [String], rows: [[String?]]).
// That is faithful rather than lossy: Python's own _int/_float/_str already accept strings
// (SUMMARIZE returns min/max/avg/std/quantiles as VARCHAR precisely so heterogeneous column
// types share one result shape, approx_unique/count as BIGINT, null_percentage as DECIMAL(9,2)),
// and SiftEngine's caller (Plan 3) converts each Cell with `cell.isNull ? nil : cell.display`,
// which round-trips all of those exactly.

/// The 12 columns SUMMARIZE returns on DuckDB 1.5.5, verified by probe. min/max/avg/std/quantiles
/// come back as VARCHAR so heterogeneous column types share one result shape; null_percentage is
/// DECIMAL(9,2).
public let summarizeColumns: [String] = [
    "column_name", "column_type", "min", "max", "approx_unique", "avg", "std",
    "q25", "q50", "q75", "count", "null_percentage",
]

/// Above this many distinct values, an exact count(DISTINCT) is expensive and useless to read.
private let exactDistinctMax = 100_000

/// A numeric column with few distinct values (store_id with 12) is categorical in practice.
private let numericTopNMaxDistinct = 50

/// One row of SUMMARIZE output, coerced. Mirrors `parse_summarize`'s per-column dict: min/max/
/// quantiles stay `String?` untouched here (`buildProfile` runs them through `looseStr`, a no-op
/// once they are already `String?` — Python's own `_str` does the same nothing-to-do pass at the
/// same call site); approx_unique/count/avg/std/null_percentage are coerced eagerly, matching
/// Python's `parse_summarize` doing the same.
public struct SummarizeRow: Sendable, Equatable {
    public let type: String?
    public let min: String?
    public let max: String?
    public let approxUnique: Int
    public let avg: Double?
    public let std: Double?
    public let q25: String?
    public let q50: String?
    public let q75: String?
    public let count: Int
    public let nullPercentage: Double?

    public init(
        type: String? = nil, min: String? = nil, max: String? = nil, approxUnique: Int = 0,
        avg: Double? = nil, std: Double? = nil, q25: String? = nil, q50: String? = nil,
        q75: String? = nil, count: Int = 0, nullPercentage: Double? = nil
    ) {
        self.type = type
        self.min = min
        self.max = max
        self.approxUnique = approxUnique
        self.avg = avg
        self.std = std
        self.q25 = q25
        self.q50 = q50
        self.q75 = q75
        self.count = count
        self.nullPercentage = nullPercentage
    }
}

/// Index SUMMARIZE output by column name, coercing the numeric-ish fields. `columnNames` is the
/// cursor description's column names, once for every row (mirrors Python's `names = [d[0] for d
/// in description]`); each row in `rows` has every cell already reduced to `String?` (`nil` for
/// SQL NULL) by the caller.
public func parseSummarize(columnNames: [String], rows: [[String?]]) -> [String: SummarizeRow] {
    func index(of name: String) -> Int? { columnNames.firstIndex(of: name) }
    let iName = index(of: "column_name")
    let iType = index(of: "column_type")
    let iMin = index(of: "min")
    let iMax = index(of: "max")
    let iApproxUnique = index(of: "approx_unique")
    let iAvg = index(of: "avg")
    let iStd = index(of: "std")
    let iQ25 = index(of: "q25")
    let iQ50 = index(of: "q50")
    let iQ75 = index(of: "q75")
    let iCount = index(of: "count")
    let iNullPct = index(of: "null_percentage")

    func cell(_ row: [String?], _ i: Int?) -> String? {
        guard let i, i < row.count else { return nil }
        return row[i]
    }

    var out: [String: SummarizeRow] = [:]
    for row in rows {
        guard let name = cell(row, iName) else { continue }
        out[name] = SummarizeRow(
            type: cell(row, iType), min: cell(row, iMin), max: cell(row, iMax),
            approxUnique: looseInt(cell(row, iApproxUnique)),
            avg: looseFloat(cell(row, iAvg)), std: looseFloat(cell(row, iStd)),
            q25: cell(row, iQ25), q50: cell(row, iQ50), q75: cell(row, iQ75),
            count: looseInt(cell(row, iCount)),
            nullPercentage: looseFloat(cell(row, iNullPct))
        )
    }
    return out
}

// MARK: - Lenient coercions (Python's _int / _float / _str)
//
// Every SUMMARIZE value arrives here as a String? (see the signature note above), so these three
// swallow-and-default exactly the way Python's helpers do: looseInt gives up to 0, looseFloat
// gives up to nil, looseStr only ever gives nil for a genuine null. Do not "improve" this into
// throwing — the whole module leans on it staying lenient (a malformed cell degrades the display,
// not the scan).

private func looseInt(_ v: String?) -> Int {
    guard let v, let i = Int(v) else { return 0 }
    return i
}

private func looseFloat(_ v: String?) -> Double? {
    guard let v, let d = Double(v) else { return nil }
    return d
}

private func looseStr(_ v: String?) -> String? { v }

// MARK: - Distinct-value math

/// HyperLogLog can overshoot the row count — measured 340 for `approx_count_distinct` on 300
/// distinct values (re-confirmed through the DuckDB C API in Task 6), which reads as a bug above
/// a 300-row table, so clamp before display.
public func clampDistinct(_ approx: Int, _ n: Int) -> Int {
    max(0, n <= 0 ? approx : min(approx, n))
}

public func wantsExactDistinct(_ approxDistinct: Int) -> Bool {
    approxDistinct < exactDistinctMax
}

/// Which distinct-values panel to show for this column.
public func chooseView(col: Column, approxDistinct: Int, n: Int) -> ColumnProfile.View {
    if col.kind == .number || col.kind == .temporal {
        return approxDistinct > numericTopNMaxDistinct ? .hist : .topn
    }
    // Near-unique text means an identifier or free text, where a 200-row list tells you nothing;
    // the highcard panel answers "is this a key?" instead. 0.9 * n is computed in Double, matching
    // Python's int-vs-float comparison exactly at the boundary.
    if col.kind == .text, n > 0, Double(approxDistinct) > max(1000.0, 0.9 * Double(n)) {
        return .highcard
    }
    return .topn
}

// MARK: - build_profile

/// Merge the SUMMARIZE pass, the FILTER pass, and the TRY_CAST pass into one profile per column.
///
/// `extra` and `uncastable` are the single-row results of `profileExtraSQL` and `uncastableSQL`,
/// keyed by their generated `c{i}__*` aliases — index-based so that two columns whose names
/// sanitize identically cannot collide.
public func buildProfile(
    cols: [Column], summ: [String: SummarizeRow],
    extra: [String: Int] = [:], uncastable: [String: Int] = [:], nRows: Int? = nil
) -> [ColumnProfile] {
    let n = nRows ?? (extra["n"] ?? 0)
    var out: [ColumnProfile] = []
    out.reserveCapacity(cols.count)
    for (i, col) in cols.enumerated() {
        let s = summ[col.name]
        let approx = clampDistinct(s?.approxUnique ?? 0, n)
        var nNull = extra["c\(i)__null"] ?? 0
        if nNull == 0, let pct = s?.nullPercentage, n != 0 {
            // Fall back to SUMMARIZE's percentage when the FILTER pass hasn't run yet. Python's
            // round() is banker's rounding (half-to-even); Swift's .rounded() default is
            // half-away-from-zero, and they disagree at an exact .5 — .toNearestOrEven matches
            // Python exactly.
            nNull = Int(((pct / 100.0) * Double(n)).rounded(.toNearestOrEven))
        }
        let maxLen = extra["c\(i)__maxlen"] ?? 0
        out.append(ColumnProfile(
            name: col.name, type: col.type, kind: col.kind, n: n, nNull: nNull,
            nEmpty: extra["c\(i)__empty"] ?? 0, nNullish: extra["c\(i)__nullish"] ?? 0,
            approxDistinct: approx, exactDistinct: nil,
            minS: looseStr(s?.min), maxS: looseStr(s?.max),
            avg: s?.avg, std: s?.std,
            q25: looseStr(s?.q25), q50: looseStr(s?.q50), q75: looseStr(s?.q75),
            maxLen: maxLen == 0 ? nil : maxLen,   // zero becomes nil, not 0 — matches `_int(...) or None`
            nUncastable: uncastable["c\(i)__bad"] ?? 0,
            view: chooseView(col: col, approxDistinct: approx, n: n)
        ))
    }
    return out
}

// MARK: - Histogram bounds

/// (lo, step, bins) for `histogramSQL`, or `nil` when a histogram is meaningless (no range, or a
/// single value) so the caller can fall back to the top-N panel.
public func histogramParams(
    lo: Double?, hi: Double?, bins: Int = 40
) -> (lo: Double, step: Double, bins: Int)? {
    guard let lo, let hi, hi > lo else { return nil }
    let b = max(1, bins)
    return (lo, (hi - lo) / Double(b), b)
}

/// Parse min/max out of the VARCHAR-ised SUMMARIZE output for a numeric column.
public func numericBounds(_ p: ColumnProfile) -> (lo: Double, hi: Double)? {
    guard let lo = looseFloat(p.minS), let hi = looseFloat(p.maxS) else { return nil }
    return (lo, hi)
}

/// Excel serial dates land in roughly 25000..50000 (1968..2036) once read as numbers. A numeric
/// column whose whole range sits inside that window is very likely dates that lost their
/// formatting — the single most common Excel surprise, so it earns a badge and a conversion.
public func looksLikeExcelSerialDates(_ p: ColumnProfile) -> Bool {
    guard p.kind == .number, let b = numericBounds(p) else { return false }
    return 25_000.0 <= b.lo && b.hi <= 50_000.0 && p.approxDistinct > 1
}
