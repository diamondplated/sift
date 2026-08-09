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
    case decimal(Decimal)
    case blob(Int)

    public var isNull: Bool { self == .null }

    /// Display form. `blob` reproduces session.jsonable's `<blob N B>` exactly,
    /// thousands separator included.
    public var display: String {
        switch self {
        case .null:            return ""
        case .bool(let v):     return v ? "true" : "false"
        case .int(let v):      return String(v)
        case .double(let v):   return String(v)
        case .text(let v):     return v
        case .decimal(let v):  return "\(v)"
        case .blob(let n):
            return "<blob \(Self.grouped(n)) B>"
        }
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
