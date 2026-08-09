"""SQL generation.

The invariant under test throughout: **identifiers are quoted, values are bound as parameters.**
Nothing user-supplied is ever interpolated into SQL text.
"""
import duckdb
import pytest

from core.ident import q
from core.sqlgen import (
    UnknownColumn,
    bad_row_count_sql,
    count_sql,
    distinct_stats_sql,
    histogram_sql,
    order_by,
    page_sql,
    profile_extra_sql,
    render_sql,
    topn_sql,
    uncastable_sql,
    where_clause,
)
from core.types import Column, Filter, QuerySpec

COLS = {c.name: c for c in [
    Column.of("region", "VARCHAR"),
    Column.of("amount", "DECIMAL(12,2)"),
    Column.of("id", "BIGINT"),
    Column.of("ts", "TIMESTAMP"),
    Column.of("ok", "BOOLEAN"),
]}
EVIL_NAME = '"; DROP TABLE x; --'
EVIL = {EVIL_NAME: Column.of(EVIL_NAME, "VARCHAR")}


def test_a_hostile_column_name_stays_one_quoted_identifier():
    sql, params = where_clause([Filter(EVIL_NAME, "=", ("v",))], EVIL)
    assert sql == '"""; DROP TABLE x; --" = ?'
    assert params == ["v"]
    # And it survives a real parser: the identifier binds, the "statement" inside it does not run.
    con = duckdb.connect()
    con.execute(f'CREATE TABLE t ({q(EVIL_NAME)} VARCHAR)')
    con.execute("INSERT INTO t VALUES ('v')")
    assert con.execute(f"SELECT count(*) FROM t WHERE {sql}", params).fetchone()[0] == 1


def test_values_are_never_inlined():
    sql, params = where_clause([Filter("region", "=", ("O'Brien",))], COLS)
    assert "O'Brien" not in sql
    assert params == ["O'Brien"]


def test_unknown_column_is_rejected_early():
    with pytest.raises(UnknownColumn):
        where_clause([Filter("nope", "=", (1,))], COLS)
    with pytest.raises(UnknownColumn):
        order_by([("nope", "asc")], COLS)


@pytest.mark.parametrize("f,want_sql,want_params", [
    (Filter("region", "=", ("W",)), '"region" = ?', ["W"]),
    (Filter("amount", ">=", (5,)), '"amount" >= ?', [5]),
    (Filter("amount", "between", (1, 9)), '"amount" BETWEEN ? AND ?', [1, 9]),
    (Filter("region", "is_null"), '"region" IS NULL', []),
    (Filter("region", "not_null"), '"region" IS NOT NULL', []),
    (Filter("region", "is_empty"), 'CAST("region" AS VARCHAR) = \'\'', []),
    (Filter("region", "contains", ("oo",)),
     'CAST("region" AS VARCHAR) ILIKE \'%\' || ? || \'%\'', ["oo"]),
    (Filter("region", "in", ("A", "B")), '"region" IN (?, ?)', ["A", "B"]),
])
def test_operator_rendering(f, want_sql, want_params):
    sql, params = where_clause([f], COLS)
    assert sql == want_sql
    assert params == want_params


def test_in_with_null_splits_the_null_out():
    """The distinct panel makes NULL clickable, so multi-select including it is normal use.

    `col IN (NULL)` never matches, so without the split the filter would silently return nothing.
    """
    sql, params = where_clause([Filter("region", "in", ("W", None))], COLS)
    assert sql == '("region" IN (?) OR "region" IS NULL)'
    assert params == ["W"]


def test_not_in_keeps_null_rows_unless_null_is_itself_excluded():
    # Excluding "West" should not also quietly drop rows where region is NULL.
    sql, _ = where_clause([Filter("region", "not_in", ("W",))], COLS)
    assert sql == '("region" NOT IN (?) OR "region" IS NULL)'
    sql2, _ = where_clause([Filter("region", "not_in", ("W", None))], COLS)
    assert sql2 == '("region" NOT IN (?) AND "region" IS NOT NULL)'


def test_value_taking_op_with_no_values_filters_nothing():
    sql, params = where_clause([Filter("region", "in", ())], COLS)
    assert sql == "" and params == []


def test_order_by_is_explicit_about_nulls():
    assert order_by([("amount", "desc")], COLS) == '\nORDER BY "amount" DESC NULLS LAST'
    assert order_by([], COLS) == ""


def test_page_sql_binds_limit_and_offset_last():
    spec = QuerySpec("t", filters=(Filter("region", "=", ("W",)),), sort=(("amount", "desc"),))
    sql, params = page_sql(spec, COLS, q("t"), 500, 1000)
    assert params == ["W", 500, 1000]
    assert "LIMIT ? OFFSET ?" in sql
    assert 'ORDER BY "amount" DESC' in sql


def test_count_sql_carries_the_filters():
    spec = QuerySpec("t", filters=(Filter("region", "in", ("W", "E")),))
    sql, params = count_sql(spec, COLS, q("t"))
    assert params == ["W", "E"]
    assert sql.startswith("SELECT count(*)")


def test_topn_excludes_its_own_column_filters():
    """Faceting. Without it, clicking "West" makes the region panel show only West."""
    spec = QuerySpec("t", filters=(Filter("region", "in", ("W",)),
                                   Filter("amount", ">", (5,))))
    facet = spec.without_col("region").filters
    assert [f.col for f in facet] == ["amount"]
    sql, params = topn_sql(q("t"), "region", COLS, facet, limit=10)
    assert params == [5, 10]
    assert "␀ NULL" in sql and "␀ EMPTY" in sql
    # The percentage denominator comes from the same pass — no companion count query.
    assert "sum(count(*)) OVER ()" in sql


def test_topn_search_adds_one_bound_param():
    sql, params = topn_sql(q("t"), "region", COLS, (), limit=5, search="wes")
    assert params == ["wes", 5]
    assert "ILIKE" in sql


def test_distinct_stats_exact_is_opt_in():
    sql, _ = distinct_stats_sql(q("t"), "region", COLS, (), exact=False)
    assert "count(DISTINCT" not in sql
    sql2, _ = distinct_stats_sql(q("t"), "region", COLS, (), exact=True)
    assert 'count(DISTINCT "region")' in sql2


def test_histogram_reuses_profile_bounds_so_it_is_one_pass():
    sql, params = histogram_sql(q("t"), "amount", COLS, 0.0, 10.0, 5)
    assert params[:3] == [5, 0.0, 10.0]
    assert "min(" in sql and "max(" in sql       # true per-bucket range for the tooltip
    assert "width_bucket" not in sql             # avoided deliberately for version stability


def test_histogram_uses_epoch_ms_for_temporal():
    sql, _ = histogram_sql(q("t"), "ts", COLS, 0.0, 10.0, 5)
    assert 'epoch_ms("ts")' in sql


def test_profile_extra_uses_index_aliases_not_names():
    """Two columns whose names sanitize identically must not collide in the result shape."""
    cols = (Column.of("a b", "VARCHAR"), Column.of("a-b", "VARCHAR"))
    sql = profile_extra_sql(q("t"), cols)
    assert "c0__empty" in sql and "c1__empty" in sql
    assert "a b__empty" not in sql


def test_profile_extra_keeps_null_empty_and_nullish_disjoint():
    sql = profile_extra_sql(q("t"), tuple(COLS.values()))
    assert "IS NULL) AS c0__null" in sql
    assert "= '') AS c0__empty" in sql
    # nullish excludes both real NULL and true empty, so whitespace-only lands in exactly one bucket
    assert "IS NOT NULL AND CAST(\"region\" AS VARCHAR) <> ''" in sql


def test_uncastable_skips_text_columns_but_keeps_the_shape():
    sql = uncastable_sql(q("t"), tuple(COLS.values()))
    assert "0 AS c0__bad" in sql          # region is VARCHAR: nothing to fail
    assert "TRY_CAST" in sql              # amount/id/ts are checked


def test_bad_row_count_is_rows_not_cells():
    sql = bad_row_count_sql(q("t"), tuple(COLS.values()))
    assert sql.startswith("SELECT count(*)")
    assert " OR " in sql                  # any bad cell makes the row bad


def test_uncastable_refuses_a_suspicious_type_name():
    from core.sqlgen import _safe_type

    with pytest.raises(ValueError):
        _safe_type("BIGINT); DROP TABLE x; --")
    assert _safe_type("DECIMAL(12,2)") == "DECIMAL(12,2)"
    assert _safe_type("TIMESTAMP WITH TIME ZONE") == "TIMESTAMP WITH TIME ZONE"


def test_render_sql_is_readable_and_quoted():
    spec = QuerySpec("sales", filters=(Filter("region", "in", ("West", "Midwest")),
                                       Filter("amount", ">=", (100,))),
                     sort=(("amount", "desc"),))
    out = render_sql(spec, COLS)
    assert out.splitlines()[0] == "SELECT *"
    assert 'FROM "sales"' in out
    assert "'West', 'Midwest'" in out
    assert 'ORDER BY "amount" DESC' in out


def test_render_sql_escapes_quotes_in_displayed_literals():
    spec = QuerySpec("t", filters=(Filter("region", "=", ("O'Brien",)),))
    assert "'O''Brien'" in render_sql(spec, COLS)
