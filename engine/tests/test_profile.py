"""Profiling: what SUMMARIZE gives, and which panel each column earns."""
import pytest

from core import profile as prof
from core import source as S
from core import sqlgen
from core.types import Column, ColumnProfile


def test_summarize_returns_the_columns_we_depend_on(con, data):
    spec = S.build_source(con, data["nulls_csv"])
    con.execute(f"CREATE OR REPLACE VIEW p AS SELECT * FROM {S.read_expr(spec)}")
    cur = con.execute("SUMMARIZE p")
    names = [d[0] for d in cur.description]
    for want in prof.SUMMARIZE_COLUMNS:
        assert want in names, f"SUMMARIZE no longer returns {want}"
    parsed = prof.parse_summarize(cur.description, cur.fetchall())
    assert "region" in parsed
    assert parsed["region"]["count"] == 600


def test_null_percentage_arrives_as_a_decimal_and_is_coerced(con, data):
    spec = S.build_source(con, data["nulls_csv"])
    con.execute(f"CREATE OR REPLACE VIEW p2 AS SELECT * FROM {S.read_expr(spec)}")
    cur = con.execute("SUMMARIZE p2")
    parsed = prof.parse_summarize(cur.description, cur.fetchall())
    v = parsed["region"]["null_percentage"]
    assert isinstance(v, float)          # Decimal would break JSON encoding downstream
    assert v > 0


def test_profile_keeps_null_empty_and_nullish_separate(con, data):
    """The distinction the whole tool exists for: NULL, '' and 'N/A' are three different problems."""
    spec = S.build_source(con, data["nulls_csv"])
    rel = "p3"
    con.execute(f"CREATE OR REPLACE VIEW {rel} AS SELECT * FROM {S.read_expr(spec)}")
    cur = con.execute("SUMMARIZE " + rel)
    summ = prof.parse_summarize(cur.description, cur.fetchall())
    cur = con.execute(sqlgen.profile_extra_sql(rel, spec.columns))
    extra = dict(zip([d[0] for d in cur.description], cur.fetchone()))
    profiles = prof.build_profile(spec.columns, summ, extra, n_rows=extra["n"])

    region = next(p for p in profiles if p.name == "region")
    note = next(p for p in profiles if p.name == "note")
    assert region.n_null > 0, "unquoted empty fields read as NULL"
    assert note.n_empty > 0, "explicitly quoted empty strings are NOT null"
    assert note.n_nullish > 0, "'N/A' is neither null nor empty"
    # Disjoint, so each number on screen means exactly one thing.
    assert note.n_empty + note.n_nullish <= note.n


def test_approx_distinct_is_clamped_to_the_row_count():
    """HyperLogLog can overshoot — measured 340 for 300 distinct values.

    "340 distinct" above a 300-row table reads as a bug, so it is clamped before display.
    """
    assert prof.clamp_distinct(340, 300) == 300
    assert prof.clamp_distinct(5, 300) == 5
    assert prof.clamp_distinct(-1, 300) == 0
    assert prof.clamp_distinct(10, 0) == 10       # unknown n: pass it through


@pytest.mark.parametrize("kind,type_,approx,n,want", [
    ("bool", "BOOLEAN", 2, 1000, "topn"),
    ("number", "INTEGER", 12, 100_000, "topn"),       # store_id: categorical in practice
    ("number", "DOUBLE", 100_000, 1_000_000, "hist"),
    ("temporal", "TIMESTAMP", 90_000, 1_000_000, "hist"),
    ("temporal", "DATE", 12, 1_000_000, "topn"),      # a month column is a list, not a chart
    ("text", "VARCHAR", 4, 1_000_000, "topn"),
    ("text", "VARCHAR", 999_000, 1_000_000, "highcard"),
    ("nested", "STRUCT(a INTEGER)", 500, 1000, "topn"),
])
def test_choose_view(kind, type_, approx, n, want):
    col = Column(name="c", type=type_, kind=kind)
    assert prof.choose_view(col, approx, n) == want


def test_exact_distinct_is_only_worth_it_below_a_ceiling():
    assert prof.wants_exact_distinct(50) is True
    assert prof.wants_exact_distinct(4_000_000) is False


def test_histogram_params_refuses_degenerate_ranges():
    assert prof.histogram_params(None, 5.0) is None
    assert prof.histogram_params(5.0, 5.0) is None      # single value: one bar is not a histogram
    assert prof.histogram_params(9.0, 1.0) is None      # inverted
    lo, step, bins = prof.histogram_params(0.0, 100.0, bins=10)
    assert (lo, step, bins) == (0.0, 10.0, 10)


def test_excel_serial_date_detection():
    """A date column that lost its formatting reads as ~45000. The most common Excel surprise."""
    dates = ColumnProfile(name="d", type="DOUBLE", kind="number",
                          min_s="45000.0", max_s="45300.0", approx_distinct=300)
    money = ColumnProfile(name="m", type="DOUBLE", kind="number",
                          min_s="0.0", max_s="98211.44", approx_distinct=5000)
    text = ColumnProfile(name="t", type="VARCHAR", kind="text",
                         min_s="45000", max_s="45300", approx_distinct=300)
    assert prof.looks_like_excel_serial_dates(dates) is True
    assert prof.looks_like_excel_serial_dates(money) is False
    assert prof.looks_like_excel_serial_dates(text) is False
