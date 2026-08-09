"""The distinct-values panel, against a live connection."""
from core import source as S
from core import sqlgen
from core.ident import q
from core.types import Column, Filter


def _view(con, path, name):
    spec = S.build_source(con, path)
    con.execute(f"CREATE OR REPLACE VIEW {q(name)} AS SELECT * FROM {S.read_expr(spec)}")
    return spec, {c.name: c for c in spec.columns}


def test_null_and_empty_are_separate_rows(con, data):
    """The headline distinction. Merging them, or dropping them, would hide the actual problem."""
    spec, cols = _view(con, data["nulls_csv"], "d1")
    sql, params = sqlgen.topn_sql(q("d1"), "note", cols, (), limit=50)
    rows = con.execute(sql, params).fetchall()
    labels = [r[0] for r in rows]
    assert "␀ EMPTY" in labels, "quoted empty strings must surface as their own row"

    sql2, params2 = sqlgen.topn_sql(q("d1"), "region", cols, (), limit=50)
    labels2 = [r[0] for r in con.execute(sql2, params2).fetchall()]
    assert "␀ NULL" in labels2


def test_fractions_sum_to_one_and_come_from_the_same_pass(con, data):
    spec, cols = _view(con, data["clean_csv"], "d2")
    sql, params = sqlgen.topn_sql(q("d2"), "region", cols, (), limit=100)
    rows = con.execute(sql, params).fetchall()
    total = sum(float(r[3]) for r in rows)
    assert abs(total - 1.0) < 1e-9
    assert sum(int(r[2]) for r in rows) == 1000


def test_a_filter_on_another_column_narrows_the_denominator(con, data):
    spec, cols = _view(con, data["clean_csv"], "d3")
    f = (Filter("order_id", "<", (500,)),)
    sql, params = sqlgen.topn_sql(q("d3"), "region", cols, f, limit=100)
    rows = con.execute(sql, params).fetchall()
    assert sum(int(r[2]) for r in rows) == 500
    assert abs(sum(float(r[3]) for r in rows) - 1.0) < 1e-9


def test_search_narrows_the_values(con, data):
    spec, cols = _view(con, data["clean_csv"], "d4")
    sql, params = sqlgen.topn_sql(q("d4"), "region", cols, (), limit=100, search="wes")
    rows = con.execute(sql, params).fetchall()
    # Substring, case-insensitive — so "Midwest" matches "wes" too. That is the intent: searching
    # values is for finding them, not for prefix-matching.
    assert sorted(r[0] for r in rows) == ["Midwest", "West"]

    sql2, params2 = sqlgen.topn_sql(q("d4"), "region", cols, (), limit=100, search="nope")
    assert con.execute(sql2, params2).fetchall() == []


def test_other_n_accounts_for_the_tail(con, data):
    spec, cols = _view(con, data["clean_csv"], "d5")
    sql, params = sqlgen.topn_sql(q("d5"), "note", cols, (), limit=5)
    shown = sum(int(r[2]) for r in con.execute(sql, params).fetchall())
    csql, cparams = sqlgen.distinct_stats_sql(q("d5"), "note", cols, ())
    stats = dict(zip([d[0] for d in con.execute(csql, cparams).description],
                     con.execute(csql, cparams).fetchone()))
    assert stats["n_rows"] - shown > 0, "a top-5 of 1000 distinct notes must leave a tail"


def test_exact_distinct_matches_reality(con, data):
    spec, cols = _view(con, data["clean_csv"], "d6")
    sql, params = sqlgen.distinct_stats_sql(q("d6"), "region", cols, (), exact=True)
    cur = con.execute(sql, params)
    stats = dict(zip([d[0] for d in cur.description], cur.fetchone()))
    assert stats["n_distinct_exact"] == 4          # the four regions in the fixture


def test_histogram_buckets_cover_every_row(con, data):
    spec, cols = _view(con, data["clean_csv"], "d7")
    lo, hi = 0.0, 1000.0
    sql, params = sqlgen.histogram_sql(q("d7"), "order_id", cols, lo, (hi - lo) / 10, 10)
    rows = con.execute(sql, params).fetchall()
    assert sum(int(r[1]) for r in rows) == 1000
    assert all(0 <= int(r[0]) < 10 for r in rows), "bucket index must stay in range"


def test_histogram_clamps_the_top_value_into_the_last_bucket(con, data):
    """least(bins-1, …) exists so max(value) does not land in a phantom bucket N."""
    spec, cols = _view(con, data["clean_csv"], "d8")
    sql, params = sqlgen.histogram_sql(q("d8"), "order_id", cols, 0.0, 100.0, 10)
    rows = con.execute(sql, params).fetchall()
    assert max(int(r[0]) for r in rows) == 9


def test_temporal_histogram_runs(con, data):
    con.execute("CREATE OR REPLACE VIEW d9 AS SELECT TIMESTAMP '2026-01-01' "
                "+ INTERVAL (range) HOUR AS ts FROM range(500)")
    cols = {"ts": Column.of("ts", "TIMESTAMP")}
    row = con.execute("SELECT min(epoch_ms(ts))::DOUBLE, max(epoch_ms(ts))::DOUBLE FROM d9").fetchone()
    sql, params = sqlgen.histogram_sql(q("d9"), "ts", cols, row[0], (row[1] - row[0]) / 12, 12)
    rows = con.execute(sql, params).fetchall()
    assert sum(int(r[1]) for r in rows) == 500
