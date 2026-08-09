import Testing
@testable import SiftCore

// The SELECT-only gate, pure half. Ported from engine/tests/test_guard.py — its own header
// calls it "the most important test file here." Note what these tests are and are not covering:
// `assertNoDeniedLeadingKeyword` is a message improver, not the security boundary. The real
// enforcement is the subquery wrap, covered by SQLGenTests.
//
// Two cases in Python's DENY list and test_rejection_messages_are_sentences_not_parser_dumps
// are not decidable by this pure half — "SELECT 1; DROP TABLE x" starts with SELECT, so only
// statement counting (which needs a connection) catches the second statement. Those live in
// Tests/SiftEngineTests/GuardStatementsTests.swift, alongside `assertSelectOnly`, which composes
// this file's check with that one in the right order. Every other DENY case is caught by the
// leading-keyword check or the empty/comment-only guard; every ALLOW case is a leading keyword
// that isn't in the deny list, so the pure half correctly lets all of them through.

// MARK: - DENY (decidable by the pure half)

private let deny = [
    "DROP TABLE x",
    "drop table x",
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

@Test(arguments: deny)
func denied(sql: String) {
    #expect(throws: SQLRejected.self) {
        try assertNoDeniedLeadingKeyword(sql)
    }
}

// MARK: - ALLOW (all decidable by the pure half — none of these start with a denied keyword)

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

@Test(arguments: allow)
func allowed(sql: String) throws {
    try assertNoDeniedLeadingKeyword(sql)   // must not throw
}

// MARK: - Rejection messages are sentences, not parser dumps

@Test func rejectionMessageNamesTheKeywordAndEndsWithAPeriod() {
    #expect(throws: SQLRejected.self) {
        try assertNoDeniedLeadingKeyword("DROP TABLE x")
    }
    do {
        try assertNoDeniedLeadingKeyword("DROP TABLE x")
        Issue.record("expected SQLRejected")
    } catch let e as SQLRejected {
        #expect(e.message.contains("DROP"))
        #expect(e.message.hasSuffix("."))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
    // The "SELECT 1; SELECT 2" -> "one statement at a time" half of this Python test is not
    // decidable by the pure half — see header; ported in
    // Tests/SiftEngineTests/GuardStatementsTests.swift's rejectionMessageNamesOneStatementAtATime.
}

// MARK: - strip_sql_comments preserves string literals

@Test(arguments: [
    ("SELECT 1 -- hi", "SELECT 1", "hi"),
    ("SELECT /* x */ 2", "SELECT", "x"),
    ("SELECT '-- keep'", "-- keep", nil as String?),
    ("SELECT \"we--ird\"", "we--ird", nil as String?),
])
func stripSQLCommentsPreservesLiterals(given: String, wantContains: String, wantMissing: String?) {
    let out = stripSQLComments(given)
    #expect(out.contains(wantContains))
    if let missing = wantMissing {
        #expect(!out.contains(missing))
    }
}
