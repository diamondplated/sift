"""The SELECT-only gate.

The most important test file here. Note what it is and is not testing: `assert_select_only` is a
message improver, and the real enforcement is the subquery wrapping (covered in test_sqlgen and
exercised against a live connection in test_wrap_enforcement). Both layers are checked.
"""
import duckdb
import pytest

from core.guard import SqlRejected, assert_select_only, strip_sql_comments
from core.sqlgen import wrap_user_sql

DENY = [
    "DROP TABLE x",
    "drop table x",
    "SELECT 1; DROP TABLE x",
    "COPY x TO '/tmp/y'",
    "COPY (SELECT 1) TO '/tmp/y.csv'",
    "ATTACH 'x.db' AS y",
    "DETACH y",
    "INSTALL httpfs",
    "LOAD httpfs",
    "PRAGMA database_list",              # DuckDB reports this as StatementType.SELECT
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

ALLOW = [
    "SELECT 1",
    "select 1",
    "SELECT * FROM sales WHERE region = 'West'",
    "WITH a AS (SELECT 1) SELECT * FROM a",
    "VALUES (1),(2)",
    "select 1 -- ; drop table x",         # a trailing comment must not be mistaken for a 2nd stmt
    "SELECT 1 /* ; DROP TABLE x */",
    "SELECT '-- not a comment'",          # a comment marker inside a string literal
    "SELECT '; DROP TABLE x'",
    "FROM sales SELECT *",                # DuckDB's FROM-first form
    "SELECT count(*) FROM sales GROUP BY ALL",
    "EXPLAIN SELECT 1",
]


@pytest.mark.parametrize("sql", DENY)
def test_denied(sql):
    with pytest.raises(SqlRejected):
        assert_select_only(sql)


@pytest.mark.parametrize("sql", ALLOW)
def test_allowed(sql):
    assert_select_only(sql)  # must not raise


def test_rejection_messages_are_sentences_not_parser_dumps():
    with pytest.raises(SqlRejected) as e:
        assert_select_only("DROP TABLE x")
    msg = str(e.value)
    assert "DROP" in msg and msg.endswith(".")
    with pytest.raises(SqlRejected) as e2:
        assert_select_only("SELECT 1; SELECT 2")
    assert "one statement at a time" in str(e2.value)


@pytest.mark.parametrize("given,want_contains,want_missing", [
    ("SELECT 1 -- hi", "SELECT 1", "hi"),
    ("SELECT /* x */ 2", "SELECT", "x"),
    ("SELECT '-- keep'", "-- keep", None),
    ("SELECT \"we--ird\"", "we--ird", None),
])
def test_strip_sql_comments_preserves_literals(given, want_contains, want_missing):
    out = strip_sql_comments(given)
    assert want_contains in out
    if want_missing:
        assert want_missing not in out


# --------------------------------------------------------------------------------------
# The layer that actually enforces things. A non-SELECT cannot occupy a subquery position, so
# DuckDB's parser rejects it — a grammar-level guarantee rather than a keyword blocklist.

DANGEROUS_FOR_WRAP = [
    "DROP TABLE x", "SELECT 1; DROP TABLE x", "COPY (SELECT 1) TO '/tmp/x.csv'",
    "ATTACH 'x.db' AS y", "INSTALL httpfs", "PRAGMA database_list", "SET threads=1",
    "CREATE TABLE z AS SELECT 1", "EXPORT DATABASE '/tmp/d'", "INSERT INTO x VALUES (1)",
]


@pytest.mark.parametrize("sql", DANGEROUS_FOR_WRAP)
def test_wrap_enforcement_rejects_at_parse_time(sql):
    con = duckdb.connect()
    wrapped, params = wrap_user_sql(sql, 5, 0)
    with pytest.raises(duckdb.Error):
        con.execute(wrapped, params)


@pytest.mark.parametrize("sql", [
    "SELECT 1", "WITH a AS (SELECT 1) SELECT * FROM a", "VALUES (1),(2)",
    "select 1 -- trailing comment", "SELECT 1 /* block */",
])
def test_wrap_still_runs_legitimate_selects(sql):
    con = duckdb.connect()
    wrapped, params = wrap_user_sql(sql, 5, 0)
    assert con.execute(wrapped, params).fetchall()


def test_wrap_puts_the_closing_paren_on_its_own_line():
    """The newline is load-bearing, not cosmetic.

    With the flat form `SELECT * FROM ( <sql> ) AS _q`, a trailing `-- comment` swallows the closing
    paren and a perfectly good query is rejected. Measured on DuckDB 1.5.5.
    """
    con = duckdb.connect()
    sql = "select 1 -- x"
    flat = f"SELECT * FROM ( {sql} ) AS _q LIMIT 5"
    with pytest.raises(duckdb.Error):
        con.execute(flat)
    wrapped, params = wrap_user_sql(sql, 5, 0)
    assert "\n) AS _q" in wrapped
    assert con.execute(wrapped, params).fetchall() == [(1,)]
