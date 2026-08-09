import Foundation

/// A DuckDB failure, carrying the engine's own message.
///
/// Sift shows the first line to the user, because that is the part a human can act
/// on — the rest is a parser dump. `firstLine` reproduces engine/session.py's
/// `_clean_duckdb_error`, including its 400-character cap.
public struct DuckDBError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message.isEmpty ? "Query failed." : message
    }

    public var description: String { message }

    public var firstLine: String {
        let first = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? "Query failed." : String(first.prefix(400))
    }
}
