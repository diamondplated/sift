"""Paging and wire serialization."""
import datetime as dt
from decimal import Decimal

from core import source as S
from core import sqlgen
from core.ident import q
from core.types import Filter, QuerySpec, needs_string_transport
from session import jsonable, rows_payload


def _view(con, path, name):
    spec = S.build_source(con, path)
    con.execute(f"CREATE OR REPLACE VIEW {q(name)} AS SELECT * FROM {S.read_expr(spec)}")
    return spec, {c.name: c for c in spec.columns}


def test_pages_are_contiguous_and_non_overlapping(con, data):
    spec, cols = _view(con, data["clean_csv"], "pg1")
    seen = []
    for off in range(0, 1000, 250):
        sql, params = sqlgen.page_sql(QuerySpec("pg1"), cols, q("pg1"), 250, off)
        rows = con.execute(sql, params).fetchall()
        assert len(rows) == 250
        seen.extend(r[0] for r in rows)
    assert seen == list(range(1000))          # order preserved, nothing repeated or skipped


def test_sorted_pages_are_stable_across_offsets(con, data):
    spec, cols = _view(con, data["clean_csv"], "pg2")
    spec_q = QuerySpec("pg2", sort=(("order_id", "desc"),))
    first, params = sqlgen.page_sql(spec_q, cols, q("pg2"), 10, 0)
    second, params2 = sqlgen.page_sql(spec_q, cols, q("pg2"), 10, 10)
    a = [r[0] for r in con.execute(first, params).fetchall()]
    b = [r[0] for r in con.execute(second, params2).fetchall()]
    assert a == list(range(999, 989, -1))
    assert b == list(range(989, 979, -1))
    assert not set(a) & set(b)


def test_filtered_count_matches_the_filtered_rows(con, data):
    spec, cols = _view(con, data["clean_csv"], "pg3")
    spec_q = QuerySpec("pg3", filters=(Filter("region", "in", ("West",)),))
    csql, cparams = sqlgen.count_sql(spec_q, cols, q("pg3"))
    n = con.execute(csql, cparams).fetchone()[0]
    psql, pparams = sqlgen.page_sql(spec_q, cols, q("pg3"), 10_000, 0)
    assert len(con.execute(psql, pparams).fetchall()) == n


# ------------------------------------------------------------- serialization


def test_wide_ints_and_decimals_cross_the_wire_as_strings(con):
    """JS Number loses precision past 2^53, which would silently corrupt order ids.

    Exactly the class of corruption this tool exists to expose, so it must not introduce it.
    """
    cur = con.execute(
        "SELECT 9007199254740993::BIGINT AS big, 123.45::DECIMAL(12,2) AS dec, "
        "42::INTEGER AS small, 'x' AS txt"
    )
    payload = rows_payload(cur.description, cur.fetchall())
    row = payload["rows"][0]
    assert row[0] == "9007199254740993", "BIGINT past 2^53 must be a string"
    assert isinstance(row[1], str) and row[1] == "123.45"
    assert row[2] == 42, "a small INTEGER can stay a JSON number"
    assert row[3] == "x"
    # And the round trip is lossless, unlike float()
    assert int(row[0]) == 9007199254740993
    assert float(9007199254740993) != 9007199254740993


def test_needs_string_transport_picks_the_right_types():
    assert needs_string_transport("BIGINT")
    assert needs_string_transport("HUGEINT")
    assert needs_string_transport("DECIMAL(18,4)")
    assert not needs_string_transport("INTEGER")
    assert not needs_string_transport("DOUBLE")
    assert not needs_string_transport("VARCHAR")


def test_jsonable_handles_every_duckdb_shape(con):
    assert jsonable(None) is None
    assert jsonable(True) is True
    assert jsonable(Decimal("1.5")) == "1.5"
    assert jsonable(3) == 3
    assert jsonable(2 ** 60) == str(2 ** 60)
    assert jsonable(dt.datetime(2026, 1, 4, 9, 11, 2)) == "2026-01-04T09:11:02"
    assert jsonable(dt.date(2026, 1, 4)) == "2026-01-04"
    assert jsonable(b"\xde\xad") == "<blob 2 B>"
    assert jsonable([1, Decimal("2")]) == [1, "2"]
    assert jsonable({"a": Decimal("1")}) == {"a": "1"}


def test_timestamptz_survives_serialization(con):
    """Without pytz installed this raises inside DuckDB, which is why it is a hard requirement."""
    cur = con.execute("SELECT now() AS tz")
    payload = rows_payload(cur.description, cur.fetchall())
    assert isinstance(payload["rows"][0][0], str)
    assert payload["cols"][0]["kind"] == "temporal"


def test_nested_and_blob_columns_are_classified(con):
    cur = con.execute("SELECT [1,2] AS l, {'a':1} AS s, 'x'::BLOB AS b")
    payload = rows_payload(cur.description, cur.fetchall())
    kinds = {c["name"]: c["kind"] for c in payload["cols"]}
    assert kinds["l"] == "nested" and kinds["s"] == "nested" and kinds["b"] == "blob"


def test_sql_mode_wrapping_pages(con, data):
    _view(con, data["clean_csv"], "pg4")
    sql, params = sqlgen.wrap_user_sql("SELECT order_id FROM pg4 ORDER BY order_id", 10, 20)
    rows = con.execute(sql, params).fetchall()
    assert [r[0] for r in rows] == list(range(20, 30))
