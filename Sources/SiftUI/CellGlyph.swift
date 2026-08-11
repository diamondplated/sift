import DuckDBKit
import SiftCore
import SiftEngine

// What the grid draws for one cell. A ROUTER, not a renderer: every value string on this page comes
// from `SiftEngine.glyph(for:kind:)`, the one shared renderer the `sift` CLI already calls.
//
// WHY THE SPLIT IS THIS WAY ROUND. An earlier draft put the digit rules here, in the UI; the CLI
// then grew its own copy, and the two disagreed on live data — doubles printed as raw Swift
// (`980.0` where the shipping web grid showed `980`), and an empty string was indistinguishable
// from a NULL. Cell semantics — whether a value is null, empty or absent — is *meaning*, so it
// lives in the shared engine and both views agree by construction. *Phrasing* goes the other way
// (`rowsBasis`, `humanBytes`, filter chip labels stay up here): the engine has no business owning
// English sentences, and a terminal and a sidebar want different ones. Do not "correct" either
// direction into the other.
//
// So: no arithmetic below, no `String(format:)`, no digit loop, and no `Cell.display` for a cell's
// glyph. The only decisions this file makes are about the `Cell` *case*, and they are the reason
// NULL, `''` and a literal `N/A` stay three visibly different things (design spec §9): `display` is
// documented-lossy and renders `.null` and `.text("")` identically as `""`, so matching the case
// before ever asking for a string is what keeps them apart.

/// One cell, ready to draw. The case picks the styling; the payload is the engine's string.
///
/// `.null` and `.empty` carry no text on purpose — the view styles them (the web grid used CSS
/// colour) and spells them with `SiftEngine.nullGlyph` / `SiftEngine.emptyStringGlyph`, which are
/// public for exactly that. `.number` is a separate case from `.text` for the same reason the web
/// had `cellClass`: it is right-aligned, by the column's `Kind` and not by whether this particular
/// value parsed — so `N/A` in a number column still lines up with the numbers above it.
public enum CellGlyph: Equatable, Sendable {
    case null
    case empty
    case text(String)
    case bool(Bool)
    case number(String)
}

/// Route one value of a column of this `Kind` to the case the grid draws.
public func glyph(for cell: Cell, kind: Kind) -> CellGlyph {
    if cell.isNull { return .null }
    if case .text(let value) = cell, value.isEmpty { return .empty }
    if case .bool(let value) = cell { return .bool(value) }

    // Everything from here down is the engine's answer, verbatim — including the temporal trim
    // (`2026-08-09T14:03:01.250` → `2026-08-09 14:03:01`), which is one of its `Kind` branches.
    let rendered = SiftEngine.glyph(for: cell, kind: kind)
    return kind == .number ? .number(rendered) : .text(rendered)
}

/// The grid cell's tooltip — the web's `title` attribute, cap included.
///
/// Says the *state* in words for the two states a glyph can collide with (a text cell whose
/// contents are literally `null` or `''` renders like the state of the same name), which is the
/// tooltip's whole job here. `display` is safe below that point precisely because both lossy cases
/// have already returned.
public func tooltip(for cell: Cell) -> String {
    if cell.isNull { return "null" }
    if case .text(let value) = cell, value.isEmpty { return "empty string" }
    return String(cell.display.prefix(300))
}
