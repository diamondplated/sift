import Foundation

/// One decoded value.
///
/// Deliberately NOT a JSON-shaped type. The Python engine converts every value to
/// something JavaScript can hold — which is why BIGINT and DECIMAL cross the wire as
/// strings there, since JS Number silently rounds past 2^53 and an order id is exactly
/// the sort of thing that corrupts. In-process that whole problem is gone: Int64 is
/// Int64 and Decimal is Decimal.
///
/// HUGEINT still becomes text, because it is 128-bit and Swift has no native Int128 on
/// the pinned toolchain. Temporal values become ISO-8601 text, matching
/// session.jsonable's `.isoformat()`.
public enum Cell: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
    /// The scale travels with the value because `Decimal` does not: `Decimal(string:
    /// "10.50")` normalizes to 10.5, so DECIMAL(10,2)'s trailing zero is gone the
    /// instant you ask the value for its own description. Carrying `scale` alongside
    /// lets `display` reconstruct the declared shape instead of a canonicalized one.
    case decimal(Decimal, scale: Int)
    case blob(Int)
    /// A DuckDB LIST, decoded element-by-element rather than joined into one string.
    ///
    /// Not text: the first consumer is the "rows your file lost" panel's `bad_columns`
    /// column (SQLGenPanels.badRowsSQL emits `list_filter([...]) AS bad_columns`), whose
    /// whole job is naming *which* columns failed so the UI can highlight those specific
    /// cells. A joined string would have to be re-split downstream, and re-splitting
    /// breaks the instant a column name contains the separator — in a product whose
    /// entire premise is not mangling data. Keeping the children as `Cell`s also means
    /// nested LISTs decode for free, with no special-casing.
    case list([Cell])

    public var isNull: Bool { self == .null }

    /// Display form. `blob` reproduces session.jsonable's `<blob N B>` exactly,
    /// thousands separator included.
    ///
    /// **`display` is lossy on purpose and must not be used to decide anything.** It renders
    /// `.null` and `.text("")` identically as `""`, collapsing two of the three states — NULL,
    /// `''`, `'N/A'` — that design spec §9 calls non-negotiable. The distinction survives in
    /// the enum, so the grid, the profile panel and every filter branch on the CASE; only the
    /// glyph on screen comes from here.
    public var display: String {
        switch self {
        case .null:            return ""
        case .bool(let v):     return v ? "true" : "false"
        case .int(let v):      return String(v)
        case .double(let v):   return String(v)
        case .text(let v):     return v
        case .decimal(let v, let scale): return Self.decimalDisplay(v, scale: scale)
        case .blob(let n):
            return "<blob \(Self.grouped(n)) B>"
        case .list(let items):
            // Bracketed, comma-joined `display` of each element — readable in a grid cell,
            // consistent with the file's documented lossiness (NULL and "" already collapse
            // to the same glyph elsewhere; a NULL list element does here too). Real
            // consumers (the bad-rows panel) match on `.list` directly for the column
            // names, never on this string.
            return "[" + items.map(\.display).joined(separator: ", ") + "]"
        }
    }

    /// Re-pads to `scale` digits after the point. `v * 10^scale` is an integer-valued
    /// Decimal (its own description has no decimal point), so splicing it back in by
    /// hand — the same call `Chunk.decodeDecimal` makes on the way in — recovers exactly
    /// the digit count DECIMAL declared, trailing zeros included.
    static func decimalDisplay(_ v: Decimal, scale: Int) -> String {
        guard scale > 0 else { return "\(v)" }
        let scaled = v * pow(Decimal(10), scale)
        let negative = scaled < 0
        return splice("\(negative ? -scaled : scaled)", scale: scale, negative: negative)
    }

    /// Puts a decimal point `scale` digits from the right of an unscaled magnitude,
    /// zero-padding so at least one digit stays in front of it.
    ///
    /// One copy, called from both directions — the decoder on the way in and `display` on
    /// the way out. They were two copies, and two copies of this shape is exactly how the
    /// trailing-zero bug got shipped.
    static func splice(_ magnitude: String, scale: Int, negative: Bool) -> String {
        var digits = magnitude
        while digits.count <= scale { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -scale)
        return "\(negative ? "-" : "")\(digits[..<cut]).\(digits[cut...])"
    }

    /// Comma-grouped, unconditionally — matching the Python engine's `f"{n:,}"`, which
    /// is what the grid currently renders.
    ///
    /// Deliberately NOT NumberFormatter. Without an explicit `.locale` it follows
    /// `Locale.current`, and the same value renders four different ways — MEASURED:
    /// en_US "1,234", de_DE "1.234", fr_FR "1 234", en_US_POSIX "1234". A blob size
    /// that changes shape with the user's region is a bug, and one that passes CI only
    /// because the runner happens to be en_US is a worse one.
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }
}
