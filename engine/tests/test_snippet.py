"""Copy-as-code. The contract: the snippet reproduces what is on screen."""
from core import source as S
from core.snippet import snippet
from core.types import Filter, QuerySpec


def _ctx(con, path, name="t", sheet=None):
    spec = S.build_source(con, path, sheet=sheet)
    cols = {c.name: c for c in spec.columns}
    return spec, cols, QuerySpec(name)


def test_duckdb_snippet_carries_the_sniffed_dialect(con, data):
    spec, cols, qs = _ctx(con, data["semi_csv"])
    out = snippet("duckdb", spec, qs, cols)
    assert "import duckdb" in out
    assert "read_csv(" in out
    assert "delim=';'" in out, "a semicolon file must not be reproduced as comma-delimited"
    assert data["semi_csv"] in out


def test_duckdb_snippet_is_runnable_as_written(con, data):
    """The strongest check available: execute the generated SQL and compare row counts."""
    spec, cols, qs = _ctx(con, data["clean_csv"])
    qs = QuerySpec("t", filters=(Filter("region", "in", ("West",)),))
    out = snippet("duckdb", spec, qs, cols)
    sql = out.split('"""')[1]
    n = con.execute(f"SELECT count(*) FROM ({sql})").fetchone()[0]
    expected = con.execute(
        f"SELECT count(*) FROM {S.read_expr(spec)} WHERE region = 'West'").fetchone()[0]
    assert n == expected


def test_pandas_snippet_carries_dtypes_and_filters(con, data):
    spec, cols, qs = _ctx(con, data["clean_csv"])
    qs = QuerySpec("t", filters=(Filter("region", "in", ("West", "South")),),
                   sort=(("order_id", "desc"),))
    out = snippet("pandas", spec, qs, cols)
    assert "import pandas as pd" in out
    assert "dtype=" in out
    assert ".isin(['West', 'South'])" in out
    assert "sort_values('order_id', ascending=False)" in out


def test_pandas_warns_about_ram_on_a_big_text_source(con, data, tmp_path):
    import dataclasses

    spec, cols, qs = _ctx(con, data["clean_csv"])
    # Pretend the file is large; the warning is driven by size, not by reading it.
    big = dataclasses.replace(spec, key=dataclasses.replace(spec.key, size=4 * 1024 ** 3))
    out = snippet("pandas", big, qs, cols)
    assert "GB source" in out and "RAM" in out
    assert "duckdb snippet streams" in out
    # Parquet is memory-mapped and columnar, so no warning there.
    pspec, pcols, pqs = _ctx(con, data["parquet"])
    assert "RAM" not in snippet("pandas", pspec, pqs, pcols)


def test_polars_uses_a_lazy_scan_and_collects(con, data):
    spec, cols, qs = _ctx(con, data["clean_csv"])
    qs = QuerySpec("t", filters=(Filter("amount", ">=", (100,)),))
    out = snippet("polars", spec, qs, cols)
    assert "pl.scan_csv(" in out
    assert ".collect()" in out
    assert 'pl.col(\'amount\') >= 100' in out


def test_polars_parquet_uses_scan_parquet(con, data):
    spec, cols, qs = _ctx(con, data["parquet"])
    assert "pl.scan_parquet(" in snippet("polars", spec, qs, cols)


def test_delta_snippets_load_the_extension(con, data):
    spec, cols, qs = _ctx(con, data["delta"])
    duck = snippet("duckdb", spec, qs, cols)
    assert "INSTALL delta" in duck and "delta_scan(" in duck
    # pandas has no Delta reader without an extra package, so say so rather than emit broken code.
    pd_out = snippet("pandas", spec, qs, cols)
    assert "deltalake" in pd_out


def test_xlsx_snippet_names_the_sheet(con, data):
    spec, cols, qs = _ctx(con, data["xlsx"], sheet="By Store")
    duck = snippet("duckdb", spec, qs, cols)
    assert "read_xlsx(" in duck and "By Store" in duck
    pd_out = snippet("pandas", spec, qs, cols)
    assert "sheet_name='By Store'" in pd_out


def test_sql_dialect_is_the_rendered_sql(con, data):
    spec, cols, qs = _ctx(con, data["clean_csv"])
    qs = QuerySpec("sales", filters=(Filter("region", "=", ("West",)),))
    out = snippet("sql", spec, qs, cols)
    assert out.startswith("SELECT *")
    assert '"sales"' in out


def test_sql_override_wins_and_is_flagged(con, data):
    spec, cols, qs = _ctx(con, data["clean_csv"])
    override = "SELECT region, count(*) FROM sales GROUP BY 1"
    assert snippet("sql", spec, qs, cols, sql_override=override) == override
    assert override in snippet("duckdb", spec, qs, cols, sql_override=override)
    # pandas cannot express arbitrary SQL, so it must say so instead of lying.
    assert "cannot express arbitrary SQL" in snippet("pandas", spec, qs, cols,
                                                    sql_override=override)


def test_filenames_with_quotes_are_escaped_per_dialect(con, tmp_path):
    """An apostrophe in a filename must not break out of the generated string literal."""
    import fixtures as fx

    p = fx.make_csv(tmp_path, "it's data.csv", rows=10)
    spec, cols, qs = _ctx(con, p)

    # SQL doubles the quote, and the result must still parse and read the file.
    duck = snippet("duckdb", spec, qs, cols)
    assert "it''s data.csv" in duck
    sql = duck.split('"""')[1]
    assert con.execute(f"SELECT count(*) FROM ({sql})").fetchone()[0] == 10

    # Python's repr switches to double quotes for a string containing an apostrophe, so the whole
    # path lands inside one intact literal.
    for dialect in ("pandas", "polars"):
        out = snippet(dialect, spec, qs, cols)
        assert f'"{spec.key.path}"' in out, out
        # Compiles, which is the real proof the literal was not broken.
        compile(out, "<snippet>", "exec")
