import SiftCore

// Everything the grid's column headers decide, as functions over values.
//
// WHY IT IS ITS OWN FILE. The header is drawn by an `NSTableHeaderCell` subclass, and an `NSCell`
// draws into whatever graphics context AppKit hands it — there is no property to read afterwards
// that says what it decided. So the *decisions* (how wide, which caret, what the count reads, how
// much of the column is missing) are pulled out here where a test can name them, and the cell is
// left holding only `NSBezierPath` and `draw(in:)`. Same split as `GridBridge` vs `TableGridView`,
// one layer down.
//
// Ported from `renderHead` / `computeWidths` / `compact` / `cycleSort` (`web/index.html:576-634`,
// `:870-874`). The arithmetic is the web's, constant for constant, because the two builds are
// supposed to lay a file out identically.

// MARK: - widths

/// Column widths in `cols` order — `computeWidths` (`web/index.html:576-583`), rule for rule.
///
/// Two candidate widths, and the wider wins: one from the column *name* (so a header is readable
/// even over a column of one-character values) and one from the widest *value* the profile saw. The
/// 120 is the pre-profile fallback, and it is the reason a profile arriving has to force a column
/// rebuild — see `GridBridge.ColumnStamp`. The 76…320 clamp is what stops one 4 KB JSON blob from
/// asking for a 30,000-point column.
///
/// The 42-character cap beside it is dead arithmetic: 42 characters is 330.8 pt, already past the
/// clamp, so no input exists for which the cap changes the answer. It is kept because this is a
/// line-by-line port and a silently dropped constant is how two implementations begin to disagree —
/// and it is called out here so nobody writes a test that claims to cover it.
///
/// Takes the profile as an array rather than a dictionary because that is how the model holds it and
/// a header has at most a few hundred columns. Profile entries with no `max_len` (or a zero one) are
/// ignored rather than treated as a zero-width column, which is `p.max_len ?` in the original.
public func columnWidths(_ cols: [Column], profile: [ColumnProfile]) -> [Double] {
    var maxLens: [String: Int] = [:]
    for column in profile where (column.maxLen ?? 0) > 0 {
        maxLens[column.name] = column.maxLen
    }
    return cols.map { column in
        let byName = Double(column.name.count) * 7.6 + 26
        let byData = maxLens[column.name].map { Double(min($0, 42)) * 7.4 + 20 } ?? 120
        return max(76, min(320, max(byName, byData))).rounded()
    }
}

// MARK: - sort

/// One click on a column header — `cycleSort` (`web/index.html:870-874`).
///
/// none → asc → desc → none, and the result is at most ONE term: sorting by a second column
/// *replaces* the first rather than adding to it. That is the web build's behaviour and it is
/// deliberate rather than a limitation — `Table.scrollableRows` caps a sorted table at what the
/// engine actually materialized, so every extra sort key is another full pass over the file for a
/// tie-break almost nobody asked for. A multi-key sort is a feature, not a side effect of the header
/// forgetting to clear the previous one.
public func nextSort(for col: String, current: [QuerySpec.SortTerm]) -> [QuerySpec.SortTerm] {
    guard let existing = current.first(where: { $0.column == col }) else {
        return [QuerySpec.SortTerm(column: col, direction: .asc)]
    }
    return existing.direction == .asc
        ? [QuerySpec.SortTerm(column: col, direction: .desc)]
        : []
}

// MARK: - counts

/// A distinct count, shortened to fit under a column name — the web's `compact`
/// (`web/index.html:630-633`): `999`, `1.0k`, `10k`, `1.0M`.
///
/// 🔴 INTEGER arithmetic, not `String(format: "%.1f", Double(n) / 1000)`. Two reasons, and the first
/// one is the whole no-`NumberFormatter` rule wearing a different hat: anything that turns a count
/// into a `Double` on the way to a string is one locale away from rendering `1,0k`. The second is
/// that `printf` rounds an exact tie half-to-EVEN while JavaScript's `toFixed` rounds half-away —
/// `10500` is `10k` under `%.0f` and `11k` in the shipping web build, on a value a real column
/// reaches. The rounding here is the web's.
public func compactCount(_ n: Int) -> String {
    if n < 1_000 { return String(n) }
    if n < 1_000_000 {
        // Below 10k the web keeps one decimal (`4.2k`); above it there is no room for one (`42k`).
        return n < 10_000 ? tenths(n, per: 1_000) + "k" : String(rounded(n, per: 1_000)) + "k"
    }
    return tenths(n, per: 1_000_000) + "M"
}

/// `n / unit` to one decimal place, rounded half-up, without ever building a `Double`.
private func tenths(_ n: Int, per unit: Int) -> String {
    let scaled = rounded(n, per: unit / 10)
    return "\(scaled / 10).\(scaled % 10)"
}

/// `n / unit`, rounded half-up. Written as `n + unit/2` rather than `n * 10 / unit` so a count near
/// `Int.max` cannot overflow on the way to a header label.
private func rounded(_ n: Int, per unit: Int) -> Int { (n + unit / 2) / unit }

// MARK: - the header's three decorations

/// What one column header draws besides its name and type.
///
/// A value, not three loose parameters, because the header cell holds it between draws and
/// `Equatable` is what lets `GridBridge` redraw the header only when something actually moved — a
/// sort click must repaint a caret, and a scroll must not repaint anything.
public struct HeaderDecoration: Equatable {
    /// `"▲"`, `"▼"`, or nothing at all. A third glyph for "unsorted" was considered and dropped: the
    /// web draws an empty span, and a permanent grey caret on all 60 columns reads as noise.
    public let caret: String?
    /// The distinct count, `≈`-prefixed while it is still HyperLogLog's estimate. Empty when there
    /// is no profile yet — a header must not invent a number it does not have.
    public let distinctLabel: String
    /// How much of the column is null, empty or uncastable, `0...1`. Drawn as a bar along the bottom
    /// edge, which is the one place a person sees "this column is 40% empty" without opening
    /// anything.
    public let missingFraction: Double

    public init(caret: String?, distinctLabel: String, missingFraction: Double) {
        self.caret = caret
        self.distinctLabel = distinctLabel
        self.missingFraction = missingFraction
    }
}

/// The three decorations for one column — `renderHead`'s per-column block (`web/index.html:600-613`).
///
/// 🔴 `exactDistinct == nil` is the `≈`, and it is not decoration. `approxDistinct` is HyperLogLog:
/// on a 40M-row column it can be several percent out, and a header that spelled `1,204,318` when
/// the truth is `1,198,006` would be this tool lying in the one place it exists to be trusted. The
/// prefix is the entire difference between an estimate and a fact.
///
/// A `nil` profile is not "zero" — it is "not known yet", and it renders as no label and no bar
/// rather than as a column that is 0% missing with 0 distinct values.
public func headerDecoration(
    _ col: Column, profile: ColumnProfile?, sort: [QuerySpec.SortTerm]
) -> HeaderDecoration {
    let caret = sort.first { $0.column == col.name }
        .map { $0.direction == .asc ? "▲" : "▼" }
    guard let profile else {
        return HeaderDecoration(caret: caret, distinctLabel: "", missingFraction: 0)
    }
    let distinct = profile.exactDistinct ?? profile.approxDistinct
    let label = (profile.exactDistinct == nil ? "≈" : "") + compactCount(distinct)
    return HeaderDecoration(
        caret: caret, distinctLabel: label,
        missingFraction: missingFraction(profile))
}

/// Null + empty + uncastable, over the rows profiled — the web's three summed percentages
/// (`web/index.html:606-609`), clamped.
///
/// Clamped because the three counts are not disjoint: an empty string in a number column is both
/// `n_empty` and `n_uncastable`, so their sum can exceed `n` and the bar would run past the column.
/// `n == 0` is a profile of nothing, which is 0 rather than a division by zero.
private func missingFraction(_ profile: ColumnProfile) -> Double {
    guard profile.n > 0 else { return 0 }
    let missing = profile.nNull + profile.nEmpty + profile.nUncastable
    return min(1, max(0, Double(missing) / Double(profile.n)))
}

/// The header's hover text — the web's `title` attribute (`web/index.html:615-617`), including the
/// last line.
///
/// 🔴 That last line is not a nicety. Plain click opens the column and SHIFT-click sorts, which is
/// the web build's binding and is undiscoverable without being told; a header that only said
/// `name — type` would leave sorting reachable by accident only. Counts go through
/// `SiftCore.groupDigits` — the engine's, on the string, never a `NumberFormatter`.
public func headerTooltip(_ col: Column, profile: ColumnProfile?) -> String {
    var out = "\(col.name) — \(col.type)"
    if let profile {
        let distinct = profile.exactDistinct ?? profile.approxDistinct
        out += "\n\(groupDigits(String(profile.nNull))) null, "
        out += "\(groupDigits(String(profile.nEmpty))) empty, "
        out += "\(profile.exactDistinct == nil ? "≈" : "")\(compactCount(distinct)) distinct"
    }
    return out + "\nclick: values · shift-click: sort"
}
