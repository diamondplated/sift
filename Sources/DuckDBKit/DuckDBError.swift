import Foundation

/// A DuckDB failure, carrying the engine's own message.
///
/// Sift shows the first line to the user, because that is the part a human can act
/// on — the rest is a parser dump. `firstLine` reproduces engine/session.py's
/// `_clean_duckdb_error`, including its 400-character cap.
///
/// 🔴 **`LocalizedError` is not decoration.** `"\(error)"` and `error.localizedDescription`
/// are different code paths in Swift: without this conformance Foundation bridges the
/// error to `NSError` and synthesizes "The operation couldn't be completed.
/// (DuckDBKit.DuckDBError error 1.)" — MEASURED, and shipped. `sift bad.parquet` printed
/// exactly that and DISCARDED (not truncated) DuckDB's own
/// `Invalid Input Error: No magic bytes found at end of file '…'`, because
/// `Sources/sift/main.swift` prints `localizedDescription` and every SwiftUI banner will
/// too. SiftCore's `SiftError` conforms for the same reason; this is the layer below it,
/// and it covers the throw sites nobody has enumerated. SiftEngine additionally wraps
/// DuckDB failures into `SessionError` at each of its public methods, so the engine's own
/// error type stays consistent — the two are belt and braces, not alternatives.
///
/// `errorDescription` returns `firstLine`, never `message`: the whole point is one clean
/// sentence, and the lines below the first are the dump this exists to keep out.
public struct DuckDBError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message.isEmpty ? "Query failed." : message
    }

    public var description: String { message }

    public var errorDescription: String? { firstLine }

    public var firstLine: String {
        let first = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? "Query failed." : String(first.prefix(400))
    }
}
