import DuckDBKit
import SiftCore

// Clicking a value in the distinct panel is the shortest path this app has from "I can see it" to
// "show me only that", and this file is the whole of that translation. It is deliberately pure —
// `[Filter]` in, `[Filter]` out, no `Session`, no view — because every one of its edges is a
// behaviour a user can hit in one click and none of them are observable from a rendered view.
//
// Ported from the two handlers on `.vrow` (`web/index.html:1268-1284`), rule for rule.

/// Which of the three clicks the user made. `exclude` is the right-click.
public enum DistinctClick: Sendable {
    case plain
    case command
    case exclude
}

/// The two labels `topNSQL`'s `CASE` emits for the states a value cannot carry
/// (`SiftCore/SQLGenPanels.swift:55-56`), and the reason this dispatch is on the LABEL rather than
/// on the value.
///
/// A NULL row's value really is `.null` and an empty row's really is `.text("")`, so dispatching on
/// the value looks equivalent — but it is not: a text column can legitimately contain the literal
/// string `␀ NULL`, and, far more commonly, `is_null`/`is_empty` are *nullary* ops that read better
/// in the filter chip and generate `IS NULL` / `= ''` rather than a one-element `IN` list. The web
/// dispatches on the label (`v.label === "␀ NULL"`), the labels come from the engine's SQL, and
/// this matches both.
///
/// Spelled here rather than imported because `SQLGenPanels` interpolates them straight into the
/// `CASE` expression; if that ever changes, this is the other end of the pair.
let nullSentinelLabel = "␀ NULL"
let emptySentinelLabel = "␀ EMPTY"

/// The filters a click on `value` should leave behind, given the ones already active.
///
/// Three behaviours worth stating, because each of them is a bug if you get it backwards:
///
///  1. **Replacement is per (column, op), not per column** — `addFilter` (`web/index.html:889-893`)
///     drops only filters that match on both, so clicking a value on a column that already carries
///     an `is_null` or an exclusion adds to it rather than silently discarding it.
///  2. **⌘-click toggles.** Clicking an already-selected value removes it, which is what makes the
///     panel's `selected` highlighting a control rather than a readout.
///  3. **Emptying the ⌘-selection drops EVERY filter on the column, not just the `in`**
///     (`web/index.html:1279-1280`). Leaving an empty `in` behind would be worse than useless:
///     `whereClause` skips a value-taking op with no values, so the filter would be invisible in
///     SQL while still sitting in the spec — and dropping only the `in` while leaving, say, an
///     `is_null` on the same column would leave the user staring at rows they just deselected.
public func applyDistinctClick(
    col: String, value: SQLValue, label: String, modifier: DistinctClick, current: [Filter]
) -> [Filter] {
    func replacing(_ op: Op, _ values: [SQLValue]) -> [Filter] {
        current.filter { $0.col != col || $0.op != op } + [Filter(col: col, op: op, values: values)]
    }

    // Before the sentinel check, exactly as `oncontextmenu` sits outside `onclick`'s two sentinel
    // branches (`web/index.html:1283`). Excluding the two sentinels through their values is
    // correct rather than an oversight: `whereClause` turns `not_in [null]` into `IS NOT NULL` and
    // `not_in ['']` into `<> '' OR IS NULL`, which is what "exclude this row" means for both.
    if modifier == .exclude { return replacing(.notIn, [value]) }

    if label == nullSentinelLabel { return replacing(.isNull, []) }
    if label == emptySentinelLabel { return replacing(.isEmpty, []) }

    guard modifier == .command else { return replacing(.inList, [value]) }

    var values = current.first { $0.col == col && $0.op == .inList }?.values ?? []
    if let at = values.firstIndex(of: value) { values.remove(at: at) } else { values.append(value) }
    return values.isEmpty ? current.filter { $0.col != col } : replacing(.inList, values)
}

/// The panel's decoded value, as something a filter can bind.
///
/// `DistinctPanel.Value.value` is a `Cell` (what the query returned) and a `Filter` holds
/// `SQLValue` (what a query takes) — see `cellEquals` in `SessionQueries.swift`, which is the same
/// gap in the other direction. The four cases with no `SQLValue` spelling (`decimal`, `blob`,
/// `list`, and any future one) fall back to their display text, which DuckDB casts back on the way
/// in; `display` is safe here because none of them is one of the two states it collapses.
func filterValue(for cell: Cell) -> SQLValue {
    switch cell {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .int(let value): return .int(value)
    case .double(let value): return .double(value)
    case .text(let value): return .text(value)
    default: return .text(cell.display)
    }
}
