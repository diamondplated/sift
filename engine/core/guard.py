"""The SELECT-only gate for the SQL box.

The actual enforcement is NOT here — it is the subquery wrapping in sqlgen.wrap_user_sql: a
non-SELECT cannot occupy a subquery position, so it dies in DuckDB's parser. That is a
grammar-level guarantee; a keyword blocklist is not. This module runs first purely so the user
gets a sentence instead of a parser dump — a message improver, allowed to be imperfect.

It imports duckdb for the parser but never touches a connection, so it stays unit-testable.

Measured: DuckDB reports `PRAGMA database_list` as StatementType.SELECT, so statement type alone
would wave PRAGMA through — hence the explicit keyword check below.
"""
from __future__ import annotations

import re

import duckdb


class SqlRejected(ValueError):
    """The submitted SQL is not a single read-only SELECT."""


# Never-acceptable leading keywords, checked after comment stripping. PRAGMA and CALL are here
# because DuckDB classifies them as SELECT; the rest just make the refusal name the problem.
_DENY_LEAD = re.compile(
    r"^\s*(PRAGMA|CALL|EXPORT|IMPORT|INSTALL|LOAD|ATTACH|DETACH|SET|RESET|COPY|CREATE|DROP|ALTER"
    r"|INSERT|UPDATE|DELETE|TRUNCATE|MERGE|BEGIN|COMMIT|ROLLBACK|CHECKPOINT|VACUUM|ANALYZE"
    r"|USE|GRANT|REVOKE|PREPARE|EXECUTE|DEALLOCATE|COMMENT)\b",
    re.IGNORECASE,
)


def strip_sql_comments(sql: str) -> str:
    """Remove -- line comments and /* */ block comments, preserving string literals.

    Only used to find the leading keyword. Hand-rolled rather than regex-only because
    `SELECT '-- not a comment'` must survive.
    """
    out: list[str] = []
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            out.append(sql[i : j + 1])
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and sql[j] != '"':
                j += 1
            out.append(sql[i : j + 1])
            i = j + 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j == -1 else j
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j == -1 else j + 2
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def assert_select_only(sql: str) -> None:
    """Raise SqlRejected unless `sql` is exactly one read-only SELECT.

    Accepts SELECT, WITH ... SELECT, VALUES, TABLE, FROM-first (DuckDB's `FROM t SELECT *`),
    and DESCRIBE/SUMMARIZE/EXPLAIN, which are read-only and genuinely useful in the SQL box.
    """
    if not sql or not sql.strip():
        raise SqlRejected("Nothing to run.")

    bare = strip_sql_comments(sql).strip()
    if not bare:
        raise SqlRejected("That is only a comment.")

    m = _DENY_LEAD.match(bare)
    if m:
        raise SqlRejected(
            f"Sift only runs SELECT queries, and this starts with {m.group(1).upper()}. "
            "Sources are opened read-only; use the Export button to write a file."
        )

    try:
        statements = duckdb.extract_statements(sql)
    except Exception as exc:  # a syntax error is the user's problem, but say so cleanly
        raise SqlRejected(f"That is not valid SQL: {exc}") from exc

    if len(statements) == 0:
        raise SqlRejected("Nothing to run.")
    if len(statements) > 1:
        raise SqlRejected(
            f"Sift runs one statement at a time — it found {len(statements)}. "
            "Remove the semicolon and everything after it."
        )

    kind = str(statements[0].type).rsplit(".", 1)[-1].upper()
    if kind not in ("SELECT", "EXPLAIN"):
        raise SqlRejected(f"Sift only runs SELECT queries; that is a {kind} statement.")
