"""Shared fixtures.

Most of the suite needs neither a connection nor files, because everything interesting in core/ is
pure. The two fixtures here exist for the handful of tests that genuinely have to ask DuckDB
something.
"""
from __future__ import annotations

import duckdb
import pytest

import fixtures as fx


@pytest.fixture(scope="session")
def con():
    """One in-memory connection for the whole session, with the extensions Sift requires.

    Skips rather than fails if an extension is missing: a machine without network access on first
    run cannot INSTALL them, and that should not look like a code defect.
    """
    c = duckdb.connect()
    for ext in ("delta", "excel"):
        try:
            c.execute(f"LOAD {ext}")
        except Exception:
            try:
                c.execute(f"INSTALL {ext}")
                c.execute(f"LOAD {ext}")
            except Exception:
                pass
    return c


def has_ext(con, name: str) -> bool:
    row = con.execute(
        "SELECT loaded FROM duckdb_extensions() WHERE extension_name = ?", [name]
    ).fetchone()
    return bool(row and row[0])


@pytest.fixture(scope="session")
def data(tmp_path_factory, con):
    """The fixture corpus, generated once per session.

    Generated rather than committed: the pathological cases read better as code, and it keeps the
    repo clean and the suite fast.
    """
    d = tmp_path_factory.mktemp("sift-data")
    out = {
        "clean_csv": fx.make_csv(d, "clean.csv", rows=1000),
        "dirty_csv": fx.make_csv(d, "dirty.csv", rows=1000, bad_int_row=500),
        "nulls_csv": fx.make_csv(d, "nulls.csv", rows=600, nulls_every=7,
                                 empties_every=11, nullish_every=13),
        "weird_csv": fx.make_csv(d, "weird.csv", rows=300, crlf=True, bom=True, preamble=3),
        "semi_csv": fx.make_csv(d, "semi.csv", rows=200, delim=";"),
        "quoted_nl_csv": fx.make_csv(d, "qnl.csv", rows=400, quoted_newline_row=100),
        "gz_csv": fx.make_gzip_csv(d),
        "parquet": fx.make_parquet(con, d, rows=1000),
        "ndjson": fx.make_ndjson(d),
        "xlsx": fx.make_xlsx(d),
        "fake_xls": fx.make_fake_xls(d),
        "delta": fx.make_delta(con, d),
        "hive": fx.make_hive_parquet(con, d),
        "empty": str(d / "empty.csv"),
        "dir": str(d),
    }
    open(out["empty"], "w").close()
    return out
