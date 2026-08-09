import CDuckDB
import Foundation
import SiftCore

// The third check of engine/core/guard.py's assert_select_only: statement counting and
// statement-type checking. SiftCore.assertNoDeniedLeadingKeyword (Guard.swift) already covers
// the other two — comment stripping and the denied-leading-keyword check — and stays
// Foundation-only. This one needs to ask DuckDB's parser something, which needs a connection in
// the C API, so it lives here instead.
//
// Same framing as Guard.swift, repeated because it is easy to lose sight of one module over
// from the code that states it: **this is not the security boundary.** The actual enforcement is
// SiftCore.wrapUserSQL's newline subquery wrap — a non-SELECT cannot occupy a subquery position,
// so it dies in DuckDB's parser, a grammar-level guarantee. This module runs first purely so the
// user gets a sentence instead of a parser dump. A keyword blocklist and a statement-type check
// are both a message improver, allowed to be imperfect.
//
// 🔴 THE LANDMINE: Python calls the module-level `duckdb.extract_statements(sql)`, which reports
// a statement's type without preparing it. The C API has no such shortcut — getting a type
// requires `duckdb_prepare_extracted_statement` first, and prepare is a binder call: it FAILS on
// `SELECT * FROM nonexistent` with a catalog error, even though that is a perfectly good SELECT
// the user is about to open (or has typo'd — either way, the query path's problem, not this
// gate's). Treating a prepare failure as a guard rejection would refuse valid SQL against any
// table not currently open, which is most of them. So: an unpreparable statement is not
// rejected here — it falls through and lets the real query path report the real error.
//
// WHERE THE CONNECTION COMES FROM: notice Python's own version doesn't touch the session's
// connection either — guard.py's docstring says outright "it imports duckdb for the parser but
// never touches a connection." `duckdb.extract_statements` is a bare module-level function that
// parses against a throwaway default context, not the user's catalog. The C API has no
// connectionless form of `duckdb_extract_statements`, so the faithful port is to give it the
// cheapest connection that exists — an in-memory scratch one, opened and closed within this one
// call — rather than threading the session's real `Connection` through (whose handle is
// internal to DuckDBKit besides, by design; see Package.swift's comment on this target).

/// The leading run of a `duckdb_statement_type`'s C name, e.g. `DUCKDB_STATEMENT_TYPE_SELECT` ->
/// `"SELECT"`. Mirrors Python's `str(statements[0].type).rsplit(".", 1)[-1].upper()`, which turns
/// `StatementType.SELECT` into `"SELECT"` — measured to agree case-by-case against the same
/// vendored DuckDB build (see the report's comparison table).
private func statementTypeName(_ t: duckdb_statement_type) -> String {
    switch t {
    case DUCKDB_STATEMENT_TYPE_SELECT: return "SELECT"
    case DUCKDB_STATEMENT_TYPE_INSERT: return "INSERT"
    case DUCKDB_STATEMENT_TYPE_UPDATE: return "UPDATE"
    case DUCKDB_STATEMENT_TYPE_EXPLAIN: return "EXPLAIN"
    case DUCKDB_STATEMENT_TYPE_DELETE: return "DELETE"
    case DUCKDB_STATEMENT_TYPE_PREPARE: return "PREPARE"
    case DUCKDB_STATEMENT_TYPE_CREATE: return "CREATE"
    case DUCKDB_STATEMENT_TYPE_EXECUTE: return "EXECUTE"
    case DUCKDB_STATEMENT_TYPE_ALTER: return "ALTER"
    case DUCKDB_STATEMENT_TYPE_TRANSACTION: return "TRANSACTION"
    case DUCKDB_STATEMENT_TYPE_COPY: return "COPY"
    case DUCKDB_STATEMENT_TYPE_ANALYZE: return "ANALYZE"
    case DUCKDB_STATEMENT_TYPE_VARIABLE_SET: return "VARIABLE_SET"
    case DUCKDB_STATEMENT_TYPE_CREATE_FUNC: return "CREATE_FUNC"
    case DUCKDB_STATEMENT_TYPE_DROP: return "DROP"
    case DUCKDB_STATEMENT_TYPE_EXPORT: return "EXPORT"
    case DUCKDB_STATEMENT_TYPE_PRAGMA: return "PRAGMA"
    case DUCKDB_STATEMENT_TYPE_VACUUM: return "VACUUM"
    case DUCKDB_STATEMENT_TYPE_CALL: return "CALL"
    case DUCKDB_STATEMENT_TYPE_SET: return "SET"
    case DUCKDB_STATEMENT_TYPE_LOAD: return "LOAD"
    case DUCKDB_STATEMENT_TYPE_RELATION: return "RELATION"
    case DUCKDB_STATEMENT_TYPE_EXTENSION: return "EXTENSION"
    case DUCKDB_STATEMENT_TYPE_LOGICAL_PLAN: return "LOGICAL_PLAN"
    case DUCKDB_STATEMENT_TYPE_ATTACH: return "ATTACH"
    case DUCKDB_STATEMENT_TYPE_DETACH: return "DETACH"
    case DUCKDB_STATEMENT_TYPE_MULTI: return "MULTI"
    case DUCKDB_STATEMENT_TYPE_COPY_DATABASE: return "COPY_DATABASE"
    case DUCKDB_STATEMENT_TYPE_UPDATE_EXTENSIONS: return "UPDATE_EXTENSIONS"
    case DUCKDB_STATEMENT_TYPE_MERGE_INTO: return "MERGE_INTO"
    default: return "INVALID"
    }
}

/// Raise `SQLRejected` unless `sql` extracts to exactly one statement whose type is SELECT or
/// EXPLAIN. Ported from the back half of Python's `assert_select_only` — the half that needs
/// `duckdb.extract_statements`.
///
/// Assumes the pure checks (`SiftCore.assertNoDeniedLeadingKeyword`) already ran; this function
/// does not repeat the empty/comment-only/denied-keyword checks. Use `assertSelectOnly(_:)` below
/// to run the full gate in the right order.
public func assertSingleSelectStatement(_ sql: String) throws {
    // Open-connect-close a throwaway in-memory database purely so the parser has somewhere to
    // run — see the file header. This can realistically only fail if DuckDB itself cannot start
    // an in-memory instance, which is not the submitted SQL's fault, so failure here falls
    // through rather than blaming the query.
    var db: duckdb_database?
    guard duckdb_open(nil, &db) == DuckDBSuccess else { return }
    defer { duckdb_close(&db) }

    var con: duckdb_connection?
    guard duckdb_connect(db, &con) == DuckDBSuccess, let con else { return }
    defer {
        var c: duckdb_connection? = con
        duckdb_disconnect(&c)
    }

    // Must be destroyed on every path — success, zero statements, and extract failure alike;
    // duckdb.h is explicit that this holds even when nothing was extracted.
    var extracted: duckdb_extracted_statements?
    let count = duckdb_extract_statements(con, sql, &extracted)
    defer { duckdb_destroy_extracted(&extracted) }

    if count == 0 {
        let errMsg = extracted.flatMap(duckdb_extract_statements_error).map(String.init(cString:)) ?? ""
        if !errMsg.isEmpty {
            throw SQLRejected("That is not valid SQL: \(errMsg)")
        }
        throw SQLRejected("Nothing to run.")
    }
    if count > 1 {
        throw SQLRejected(
            "Sift runs one statement at a time — it found \(count). "
                + "Remove the semicolon and everything after it."
        )
    }

    // Must be destroyed on every path too — including a failed prepare, per duckdb.h.
    var prepared: duckdb_prepared_statement?
    let prepState = duckdb_prepare_extracted_statement(con, extracted, 0, &prepared)
    defer { duckdb_destroy_prepare(&prepared) }

    // THE LANDMINE: a failed prepare is not a guard rejection — see file header. Whatever broke
    // (most commonly a table the user hasn't opened yet) is the query path's problem to report.
    guard prepState == DuckDBSuccess, let prepared else { return }

    let kind = statementTypeName(duckdb_prepared_statement_type(prepared))
    if kind != "SELECT" && kind != "EXPLAIN" {
        throw SQLRejected("Sift only runs SELECT queries; that is a \(kind) statement.")
    }
}

/// The full SELECT-only gate, in the same order as Python's `assert_select_only`: pure checks
/// first (cheap, and name PRAGMA/CALL correctly even though DuckDB reports PRAGMA as
/// `StatementType.SELECT`), then statement counting and type via a connection.
public func assertSelectOnly(_ sql: String) throws {
    try assertNoDeniedLeadingKeyword(sql)
    try assertSingleSelectStatement(sql)
}
