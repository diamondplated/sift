import Foundation

// The SELECT-only gate for the SQL box.
//
// The actual enforcement is NOT here — it is the subquery wrapping in SQLGen.wrapUserSQL: a
// non-SELECT cannot occupy a subquery position, so it dies in DuckDB's parser. That is a
// grammar-level guarantee; a keyword blocklist is not. This module runs first purely so the user
// gets a sentence instead of a parser dump — a message improver, allowed to be imperfect.
//
// Measured: DuckDB reports `PRAGMA database_list` as StatementType.SELECT, so statement type
// alone would wave PRAGMA through — hence the explicit keyword check below.
//
// ARCHITECTURAL SPLIT (see task-5-report.md for the full writeup): engine/core/guard.py's
// assert_select_only does three things — strip comments, reject a denied leading keyword, and
// ask DuckDB to parse the SQL (duckdb.extract_statements) to count statements and check the
// statement type. Only the first two are pure; they live here. The third needs a live connection
// in the C API (duckdb_extract_statements(connection, ...)) and SiftCore imports Foundation only,
// so it moves to SiftEngine in Plan 3. One consequence for Plan 3: it must count statements and
// check type *after* this module's checks pass, and it must NOT detect "more than one statement"
// by scanning for a semicolon — a semicolon inside a string literal (`SELECT '; DROP TABLE x'`,
// ported below as an ALLOW case) would then reject a perfectly valid query.

/// The submitted SQL is not accepted by the pure half of the gate. Mirrors Python's
/// `class SqlRejected(ValueError)` — a user-facing sentence, never a parser dump.
public struct SQLRejected: SiftError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Never-acceptable leading keywords, checked after comment stripping. PRAGMA and CALL are here
/// because DuckDB classifies them as SELECT; the rest just make the refusal name the problem.
private let deniedLeadingKeywords: Set<String> = [
    "PRAGMA", "CALL", "EXPORT", "IMPORT", "INSTALL", "LOAD", "ATTACH", "DETACH", "SET", "RESET",
    "COPY", "CREATE", "DROP", "ALTER", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "MERGE", "BEGIN",
    "COMMIT", "ROLLBACK", "CHECKPOINT", "VACUUM", "ANALYZE", "USE", "GRANT", "REVOKE", "PREPARE",
    "EXECUTE", "DEALLOCATE", "COMMENT",
]

/// The leading run of word characters (letters/digits/underscore), uppercased. Stands in for the
/// Python regex's `^\s*(KEYWORD1|KEYWORD2|...)\b` alternation: matching the *whole* leading word
/// and comparing it against the keyword set gets the same word-boundary behavior (`"CREATEX"`
/// must not match `CREATE`) without NSRegularExpression.
private func leadingWord(_ s: String) -> String {
    var word = ""
    for ch in s {
        guard ch.isLetter || ch.isNumber || ch == "_" else { break }
        word.append(ch)
    }
    return word.uppercased()
}

/// Remove `--` line comments and `/* */` block comments, preserving string literals. Hand-rolled
/// rather than regex-only because `SELECT '-- not a comment'` must survive intact. Only used to
/// find the leading keyword.
///
/// Ported character-for-character from engine/core/guard.py's strip_sql_comments, including its
/// edge-case behavior:
///  - an unterminated `'...` or `"...` literal passes through verbatim to the end of the string
///    (it is not truncated, and not treated as a comment);
///  - an unterminated `/*` is dropped to the end of the string and replaced by a single space;
///  - a `--` line comment's own trailing newline is preserved — only the text between `--` and
///    the newline is dropped.
public func stripSQLComments(_ sql: String) -> String {
    let chars = Array(sql)
    let n = chars.count
    var out = ""
    var i = 0
    while i < n {
        let c = chars[i]
        if c == "'" {
            var j = i + 1
            while j < n {
                if chars[j] == "'" {
                    if j + 1 < n && chars[j + 1] == "'" {
                        j += 2
                        continue
                    }
                    break
                }
                j += 1
            }
            out += String(chars[i..<min(j + 1, n)])
            i = j + 1
        } else if c == "\"" {
            var j = i + 1
            while j < n && chars[j] != "\"" {
                j += 1
            }
            out += String(chars[i..<min(j + 1, n)])
            i = j + 1
        } else if c == "-" && i + 1 < n && chars[i + 1] == "-" {
            if let newline = chars[i...].firstIndex(of: "\n") {
                i = newline
            } else {
                i = n
            }
        } else if c == "/" && i + 1 < n && chars[i + 1] == "*" {
            var close: Int? = nil
            var k = i + 2
            while k + 1 < n {
                if chars[k] == "*" && chars[k + 1] == "/" {
                    close = k
                    break
                }
                k += 1
            }
            i = close.map { $0 + 2 } ?? n
            out += " "
        } else {
            out.append(c)
            i += 1
        }
    }
    return out
}

/// Raise `SQLRejected` if `sql` is empty, only a comment, or begins with a keyword that is never
/// a read-only SELECT. This is the pure two-thirds of Python's `assert_select_only` — the
/// remaining third (statement counting and statement-type check via `duckdb.extract_statements`)
/// needs a connection and lives in SiftEngine (Plan 3). Passing this check is necessary but not
/// sufficient for a SQL string to be safe to run; `wrapUserSQL`'s grammar-level rejection is what
/// actually enforces it.
public func assertNoDeniedLeadingKeyword(_ sql: String) throws {
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SQLRejected("Nothing to run.")
    }

    let bare = stripSQLComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bare.isEmpty else {
        throw SQLRejected("That is only a comment.")
    }

    let word = leadingWord(bare)
    if deniedLeadingKeywords.contains(word) {
        throw SQLRejected(
            "Sift only runs SELECT queries, and this starts with \(word). "
                + "Sources are opened read-only; use the Export button to write a file."
        )
    }
}
