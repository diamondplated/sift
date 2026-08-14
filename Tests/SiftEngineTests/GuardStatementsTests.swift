import CDuckDB
import Testing
@testable import SiftEngine
import SiftCore

// The SELECT-only gate, connection-needing half. Ported from engine/tests/test_guard.py — its
// own header calls it "the most important test file here." SiftCoreTests/GuardTests.swift covers
// the pure half (comment stripping, denied leading keyword) in isolation; this file covers the
// two cases that pure half cannot decide alone, plus this task's whole reason to exist: proving a
// prepare failure against a table the guard has never seen is NOT treated as a rejection.
//
// The full DENY/ALLOW lists are ported again here (not just the two deferred cases) because
// `assertSelectOnly` composes both halves, and that composition is itself something that can
// regress — e.g. someone reordering the two calls, or dropping the leading-keyword call because
// the type check "should" catch everything. It mostly doesn't: PRAGMA reports its
// `duckdb_prepared_statement_type` as SELECT (measured, matches Python's own documented
// surprise), so only the leading-keyword half catches it.

private let deny = [
    "DROP TABLE x",
    "drop table x",
    "SELECT 1; DROP TABLE x",              // starts with SELECT — only statement counting catches this
    "COPY x TO '/tmp/y'",
    "COPY (SELECT 1) TO '/tmp/y.csv'",
    "ATTACH 'x.db' AS y",
    "DETACH y",
    "INSTALL httpfs",
    "LOAD httpfs",
    "PRAGMA database_list",              // DuckDB reports this as StatementType.SELECT
    "CALL pragma_database_list()",
    "SET enable_external_access=true",
    "RESET threads",
    "CREATE TABLE z AS SELECT 1",
    "CREATE OR REPLACE VIEW v AS SELECT 1",
    "EXPORT DATABASE '/tmp/d'",
    "IMPORT DATABASE '/tmp/d'",
    "INSERT INTO x VALUES (1)",
    "UPDATE x SET a=1",
    "DELETE FROM x",
    "TRUNCATE x",
    "ALTER TABLE x RENAME TO y",
    "CHECKPOINT",
    "BEGIN TRANSACTION",
    "PREPARE p AS SELECT 1",
    "-- just a comment",
    "/* only a block comment */",
    "",
    "   ",
]

private let allow = [
    "SELECT 1",
    "select 1",
    "SELECT * FROM sales WHERE region = 'West'",
    "WITH a AS (SELECT 1) SELECT * FROM a",
    "VALUES (1),(2)",
    "select 1 -- ; drop table x",         // a trailing comment must not be mistaken for a 2nd stmt
    "SELECT 1 /* ; DROP TABLE x */",
    "SELECT '-- not a comment'",          // a comment marker inside a string literal
    "SELECT '; DROP TABLE x'",            // a semicolon inside a string literal
    "FROM sales SELECT *",                // DuckDB's FROM-first form
    "SELECT count(*) FROM sales GROUP BY ALL",
    "EXPLAIN SELECT 1",
]

@Test(arguments: deny)
func deniedByTheCombinedGate(sql: String) {
    #expect(throws: SQLRejected.self) {
        try assertSelectOnly(sql)
    }
}

@Test(arguments: allow)
func allowedByTheCombinedGate(sql: String) throws {
    try assertSelectOnly(sql)   // must not throw
}

// MARK: - The two cases Plan 2's GuardTests.swift deferred here

@Test func statementCountingCatchesASecondStatementBehindAValidLead() {
    // "SELECT 1; DROP TABLE x" starts with SELECT, so the leading-keyword check waves it
    // through — only counting the extracted statements catches the second one.
    #expect(throws: SQLRejected.self) {
        try assertSingleSelectStatement("SELECT 1; DROP TABLE x")
    }
}

@Test func rejectionMessageNamesOneStatementAtATime() {
    do {
        try assertSelectOnly("SELECT 1; SELECT 2")
        Issue.record("expected SQLRejected")
    } catch let e as SQLRejected {
        #expect(e.message.contains("one statement at a time"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

// MARK: - Genuine extract failure (a syntax error, not a rejection reason above)

@Test func aSyntaxErrorIsReportedAsNotValidSQLRatherThanNothingToRun() {
    // "SELEC 1" (typo) makes duckdb_extract_statements itself fail — count 0 with a non-empty
    // duckdb_extract_statements_error — which is a different DENY reason than an empty/
    // comment-only query. Regression guard for GuardStatements.swift:106-108.
    do {
        try assertSingleSelectStatement("SELEC 1")
        Issue.record("expected SQLRejected")
    } catch let e as SQLRejected {
        #expect(e.message.hasPrefix("That is not valid SQL:"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

// MARK: - The landmine this task exists to close

@Test func validSelectAgainstATableTheGuardHasNeverOpenedIsNotRejected() throws {
    // duckdb_prepare_extracted_statement is a binder call: it fails on a table that does not
    // exist in whatever scratch connection the guard used to ask the question, which is true of
    // EVERY real table the user is about to open. That failure must fall through as "not my
    // problem" rather than reject — otherwise the guard refuses valid SQL against any table not
    // already loaded, which is most of them.
    try assertSingleSelectStatement("SELECT * FROM a_table_that_does_not_exist_anywhere")
    try assertSelectOnly("SELECT * FROM a_table_that_does_not_exist_anywhere")
}

// MARK: - The one connection in the engine that harden() never reached

/// 🔴 **The gate opened a raw `duckdb_open` with every default in place.** `autoload_known_extensions`
/// on, `autoinstall_known_extensions` on, no `disabled_filesystems` — the only connection in
/// SiftEngine outside `Database.harden()`, and the one that is handed SQL a user typed. "It only
/// parses" is not a defence: `duckdb_prepare_extracted_statement` is a *binder* call, and binding
/// `read_csv('http://…')` is what opens the URL.
///
/// **Proved by what it forbids, not by reading it back.** MEASURED
/// (`docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md` §2):
/// `current_setting('disabled_filesystems')` returns `''` at every point, even on the connection
/// that set it — a read-back assertion would pass with the hardening deleted. What is observable is
/// the monotonicity: once a filesystem is disabled it can never be re-enabled, so a SET that drops
/// one of the two names fails. Each half names the *other* name, which pins both entries of
/// `Database.remoteFilesystems` rather than just the string being non-empty. Needs no network and
/// no extension — the disabled set is tracked by name whether or not that filesystem is registered.
@Test func theGateScratchConnectionIsHardenedLikeEveryOtherOne() throws {
    // Narrowing to one name at a time: the error names whichever name is being dropped.
    for (narrowTo, mustName) in [("HTTPFileSystem", "S3FileSystem"), ("S3FileSystem", "HTTPFileSystem")] {
        // "" means the SET succeeded, i.e. nothing was disabled to begin with. nil would mean
        // DuckDB could not start at all, which `#require` reports as its own thing.
        let message = try #require(withGuardScratchConnection { con -> String in
            var result = duckdb_result()
            defer { duckdb_destroy_result(&result) }
            guard duckdb_query(con, "SET disabled_filesystems='\(narrowTo)'", &result) != DuckDBSuccess
            else { return "" }
            return duckdb_result_error(&result).map(String.init(cString:)) ?? ""
        })
        #expect(!message.isEmpty,
                "the gate's scratch connection let \(mustName) be re-enabled — it was never disabled")
        #expect(message.contains(mustName), "expected \(mustName) to be locked out; got: \(message)")
        #expect(message.contains("cannot be re-enabled"))
    }
}

/// The control for the test above: the same two SETs succeed on a connection nothing hardened, so
/// the assertion is reading the hardening rather than a property DuckDB has anyway.
@Test func aScratchConnectionNobodyHardenedAcceptsThoseSameSets() throws {
    // A fresh database per SET: the set is monotonic and Database-wide, so running both on one
    // connection would itself be a narrowing and would fail for the right reason on the wrong
    // connection — which is exactly the confusion this control exists to rule out.
    for sql in ["SET disabled_filesystems='HTTPFileSystem'", "SET disabled_filesystems='S3FileSystem'"] {
        var db: duckdb_database?
        #expect(duckdb_open(nil, &db) == DuckDBSuccess)
        defer { duckdb_close(&db) }
        var con: duckdb_connection?
        #expect(duckdb_connect(db, &con) == DuckDBSuccess)
        defer { duckdb_disconnect(&con) }

        #expect(duckdb_query(con, sql, nil) == DuckDBSuccess, "\(sql) failed on an un-hardened connection")
    }
}
