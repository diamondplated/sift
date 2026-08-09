import Foundation

/// A bound query parameter.
///
/// The invariant this exists to serve, inherited from core/sqlgen.py: identifiers are
/// quoted, values are always bound. Nothing in Sift interpolates a user value into SQL
/// text, so this covers every value that ever reaches DuckDB.
public enum DBValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
}
