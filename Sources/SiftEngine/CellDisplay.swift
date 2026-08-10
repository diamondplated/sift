import DuckDBKit
import Foundation
import SiftCore

// How one value is shown to a person. THE shared presentation layer: the `sift` CLI's grid calls
// it today and SiftUI's grid will call it tomorrow, because two renderings of the same file that
// disagree is a defect in a product whose entire premise is not lying about data — and they had
// already diverged once, between this CLI and Plan 4's own `glyph(for:kind:)`, before either
// shipped.
//
// WHY HERE AND NOT SiftCore: these rules need `DuckDBKit.Cell`, and SiftCore is Foundation-only by
// contract. `SiftEngine` already imports DuckDBKit, is already imported by the CLI, and will be
// imported by the UI, so it is the one place both consumers can reach.
//
// WHY HERE AND NOT THE UI: note the deliberate asymmetry with the phrasing rules, which go UP into
// the UI (the engine has no business owning English sentences). Cell semantics come DOWN into the
// shared layer instead: whether a value is null, empty, or the literal text `N/A` is *meaning*, not
// wording, and it must not differ between two views of the same file.
//
// Ported from `web/index.html`'s `cellHTML`/`groupDigits` (the shipping renderer), rule for rule.
// One rule simplifies on the way across: the web re-derives a DECIMAL's scale by regexing
// `DECIMAL(p,s)` out of the column type, because JSON lost it. `Cell.decimal` carries the scale
// itself, so this reads it from the value.
//
// 🔴 NO `NumberFormatter`. Without an explicit `.locale` it follows `Locale.current`, and the same
// value renders four ways (MEASURED, DuckDBKit's `Cell.grouped`: en_US "1,234", de_DE "1.234",
// fr_FR "1 234", en_US_POSIX "1234"). `String(format:)` takes no locale and is POSIX, which is why
// it is the only formatter used below. This is the fourth locale trap of this exact shape caught on
// this branch, and it is the one place a grouped thousands separator actually gets produced.

// MARK: - the three states design spec §9 calls non-negotiable

/// SQL NULL: the value was never there. Matches the web grid, which renders the literal word.
public let nullGlyph = "null"

/// The empty string: something was written, and it was nothing. The web draws an empty cell with a
/// `title="empty string, not null"` tooltip; a terminal has no tooltip, so it gets a glyph.
///
/// KNOWN AMBIGUITY, shared with the web: a text cell whose contents are literally `null` or `''`
/// renders identically to the state of the same name. The web distinguishes them by CSS colour;
/// plain text has no equivalent short of quoting every string cell, which would make ordinary
/// output unreadable to save an edge case. `Cell` keeps all three apart, so every filter, profile
/// and export still tells them apart — only the glyph collides.
public let emptyStringGlyph = "''"

// MARK: - one cell

/// The glyph for one value in a column of this `Kind`.
///
/// NULL, `''` and a literal `N/A` are three different answers and must look like three different
/// answers — that distinction is the product (design spec §9), and `Cell.display` deliberately
/// collapses the first two, so nothing user-facing may call `display` for a whole cell.
public func glyph(for cell: Cell, kind: Kind) -> String {
    if cell.isNull { return nullGlyph }
    if case .text(let text) = cell, text.isEmpty { return emptyStringGlyph }

    switch kind {
    case .number:
        switch cell {
        case .int(let value):
            // Exact Int64, grouped as digits — never routed through a Double on the way.
            return groupDigits(String(value))
        case .decimal:
            // `Cell.display` has already spliced the declared scale back in (10.50, not 10.5);
            // grouping only touches the integer part, so the scale survives.
            return groupDigits(cell.display)
        case .double(let value):
            return doubleGlyph(value)
        case .text(let value):
            // HUGEINT arrives as text because Swift has no Int128 on the pinned toolchain. Group
            // it as a digit string; formatting it as a number would reintroduce exactly the
            // rounding the text transport exists to avoid.
            return isPlainNumber(value) ? groupDigits(value) : value
        default:
            return cell.display
        }

    case .bool:
        if case .bool(let value) = cell { return value ? "true" : "false" }
        if case .text(let value) = cell, value == "true" { return "true" }
        return "false"

    case .temporal:
        // `2026-01-15T10:30:00.123456` reads as `2026-01-15 10:30:00`. Sub-second precision is
        // noise in a grid and is still in the value for anyone who filters on it.
        return dropSubsecond(replacingFirstT(cell.display))

    case .text, .nested, .blob, .other:
        return cell.display
    }
}

// MARK: - numbers

/// A `Double` as the grid shows it: whole values lose their `.0`, everything else keeps at most six
/// fraction digits, and both are thousands-grouped. Ported from the web's
/// `Number.isInteger(n) ? n.toLocaleString() : n.toLocaleString(_, {maximumFractionDigits: 6})`.
///
/// `maximumFractionDigits` is a maximum, not a padding: `1.5` stays `1.5`, it does not become
/// `1.500000`. A DECIMAL column that genuinely wants its trailing zeros is not a Double and does not
/// come through here.
///
/// ONE BRANCH, where the web has two, and that is a merge rather than a shortcut: the web needs
/// `Number.isInteger` because `toLocaleString()` and `toLocaleString(maximumFractionDigits: 6)` pad
/// differently. `%.6f` followed by a trailing-zero trim produces the integer string on its own —
/// `980.0` renders `980.000000`, trims to `980.`, then loses the point. MEASURED against the
/// separate `%.0f` branch this function shipped with for an hour: the two agreed on every value
/// tried including 1e16 and 1e300, and disagreed only on `-0.0`, which is normalized below anyway.
/// A branch that cannot change an answer is a branch a test cannot guard.
public func doubleGlyph(_ value: Double) -> String {
    // nan / inf / -inf: printed as they are. There is no honest number to show, and inventing one
    // is how a sentinel becomes a fact. Not left to `%.6f` — C99 permits it to spell these "NAN"
    // and "INF", while Swift's own description is fixed.
    guard value.isFinite else { return "\(value)" }

    var text = String(format: "%.6f", value)
    // The "." stops this loop before it can reach the integer part: "100.000000" trims to "100.",
    // never to "1".
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    // `-0.0` formats as "-0"; JavaScript's own `(-0).toLocaleString()` is "0", and a negative zero
    // in a grid is a distraction rather than information.
    return groupDigits(text == "-0" ? "0" : text)
}

/// Insert thousands separators into an already-correct digit string.
///
/// 🔴 It takes a STRING and never parses it, which is the entire point: a BIGINT, a HUGEINT and a
/// DECIMAL all reach the grid with exact digits, and routing any of them through a `Double` on the
/// way to a comma would round the value — `9007199254740993` becomes `...992`, silently, in an
/// order-id column. Same reason the web's own `groupDigits` works on the string.
///
/// Anything that is not a plain digit run passes through untouched, so `inf`, `1e+16` from some
/// future producer, or a text value that only looks numeric cannot be mangled here.
///
/// Not a fourth copy of `DuckDBKit.Cell.grouped` or `SiftCore.grouped(_:decimals:)`: both are
/// module-internal and unreachable from here, and neither has this signature — one takes an `Int`,
/// the other a `Double`, and the whole point of this one is that it takes neither.
public func groupDigits(_ text: String) -> String {
    let negative = text.hasPrefix("-")
    let body = negative ? String(text.dropFirst()) : text
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let whole = String(parts[0])
    guard !whole.isEmpty, whole.allSatisfy(isASCIIDigit) else { return text }

    var out = ""
    for (i, digit) in whole.enumerated() {
        if i > 0 && (whole.count - i) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    let fraction = parts.count > 1 ? "." + parts[1] : ""
    return (negative ? "-" : "") + out + fraction
}

/// `^-?\d+(\.\d+)?$`, the web's `NUMERIC_STR`, without NSRegularExpression.
func isPlainNumber(_ text: String) -> Bool {
    var body = Substring(text)
    if body.hasPrefix("-") { body = body.dropFirst() }
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
        whole.allSatisfy(isASCIIDigit)
    else { return false }
    if parts.count == 2 {
        guard !parts[1].isEmpty, parts[1].allSatisfy(isASCIIDigit) else { return false }
    }
    return true
}

/// ASCII `0`-`9` only. `Character.isNumber` is true for Devanagari and Arabic-Indic digits too,
/// which `\d` in the ported regex is not, and which `String(format:)` never produces.
func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c >= "0" && c <= "9" }

// MARK: - timestamps

/// Replace the FIRST `T` only — the web's `String.replace("T", " ")` with a string pattern does
/// exactly one, and a value carrying a second one is not a separator to swallow.
func replacingFirstT(_ text: String) -> String {
    guard let range = text.range(of: "T") else { return text }
    return text.replacingCharacters(in: range, with: " ")
}

/// Drop a trailing `.` followed by digits — the web's `/\.\d+$/`.
func dropSubsecond(_ text: String) -> String {
    guard let dot = text.lastIndex(of: ".") else { return text }
    let fraction = text[text.index(after: dot)...]
    guard !fraction.isEmpty, fraction.allSatisfy(isASCIIDigit) else { return text }
    return String(text[text.startIndex..<dot])
}
