import Foundation

// Identifier handling: filename -> table name, and safe quoting.
//
// Pure. The rule this module exists to enforce: identifiers are quoted, values are
// parameterized. Nothing in Sift ever interpolates a user value into SQL text.
// Ported from engine/core/ident.py.

/// Leaves room for a "_2" collision suffix inside DuckDB's generous identifier limit.
private let nameMax = 60

/// Quote an identifier for DuckDB, doubling embedded quotes.
public func q(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Single-quote a string literal, doubling embedded quotes. Only for read_csv/read_parquet
/// *option* values (a delimiter, a sheet name) which cannot be bound as parameters. Never for
/// user data — that goes through placeholders.
public func qlit(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

/// The last path component, mirroring pathlib.Path(...).name: trailing and repeated slashes
/// are normalized away first (a folder picker hands directory names with a trailing "/").
private func pathName(_ path: String) -> String {
    var trimmed = path
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let idx = trimmed.lastIndex(of: "/") else { return trimmed }
    return String(trimmed[trimmed.index(after: idx)...])
}

/// Mirrors pathlib.Path(...).suffix: the final ".ext", or "" if the name has no extension
/// (a leading dot with nothing before it, e.g. ".csv", or a trailing dot with nothing after
/// it, e.g. "file.", does not count as an extension).
private func pathSuffix(_ name: String) -> String {
    guard let dotIdx = name.lastIndex(of: "."), dotIdx != name.startIndex,
        name.index(after: dotIdx) != name.endIndex
    else { return "" }
    return String(name[dotIdx...])
}

/// Mirrors pathlib.Path(...).stem: the name with its final suffix (if any) removed.
private func pathStem(_ name: String) -> String {
    let suffix = pathSuffix(name)
    return suffix.isEmpty ? name : String(name.dropLast(suffix.count))
}

/// Drop a trailing compression extension and then a data extension.
public func stripDataExtensions(_ filename: String) -> String {
    var name = pathName(filename)
    var suffix = pathSuffix(name).lowercased()
    if compressionExt.contains(suffix) {
        name = pathStem(name)
        suffix = pathSuffix(name).lowercased()
    }
    if dataExt.contains(suffix) {
        name = pathStem(name)
    }
    return name
}

/// Thrown when every collision suffix `_2`..`_999` is already taken. Mirrors Python's
/// `raise ValueError(f"cannot find a free table name for {filename!r}")`.
public struct NoFreeTableName: Error, Equatable, CustomStringConvertible {
    public let filename: String
    public var description: String { "cannot find a free table name for '\(filename)'" }
}

/// Derive a lowercase SQL-safe table name from a filename or directory name:
/// '2026 Sales (final).csv' -> 't_2026_sales_final'; collisions get a _2 suffix.
public func sanitizeTableName(_ filename: String, taken: Set<String> = []) throws -> String {
    var raw = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    while raw.hasSuffix("/") { raw.removeLast() }
    var stem = stripDataExtensions(raw)

    // NFKD then drop combining marks, so "Ünïcode" degrades to "unicode" rather than vanishing.
    let decomposed = stem.decomposedStringWithCompatibilityMapping
    let withoutMarks = String(String.UnicodeScalarView(
        decomposed.unicodeScalars.filter { $0.properties.canonicalCombiningClass == .notReordered }
    ))
    stem = String(withoutMarks.unicodeScalars.filter(\.isASCII)).lowercased()

    // Collapse every run of non [a-z0-9_] characters (and any run of underscores, however they
    // arose) down to a single "_" — combines Python's two regex passes into one scan.
    var collapsed = ""
    var lastWasUnderscore = false
    for scalar in stem.unicodeScalars {
        let v = scalar.value
        let isAlnum = (v >= 97 && v <= 122) || (v >= 48 && v <= 57)   // a-z, 0-9
        if isAlnum {
            collapsed.unicodeScalars.append(scalar)
            lastWasUnderscore = false
        } else if !lastWasUnderscore {
            collapsed.append("_")
            lastWasUnderscore = true
        }
    }
    stem = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

    if stem.isEmpty {
        stem = "data"
    }
    if let first = stem.first, first.isNumber {
        // Not a legal unquoted identifier, and copy-as-pandas snippets show unquoted names.
        stem = "t_" + stem
    }
    stem = String(stem.prefix(nameMax))
    while stem.hasSuffix("_") { stem.removeLast() }

    let takenLower = Set(taken.map { $0.lowercased() })
    if !takenLower.contains(stem) {
        return stem
    }
    for i in 2..<1000 {
        let candidate = "\(stem)_\(i)"
        if !takenLower.contains(candidate) {
            return candidate
        }
    }
    throw NoFreeTableName(filename: filename)
}
