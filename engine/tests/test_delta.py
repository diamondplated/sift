"""Delta tables.

The whole point of this file is one comparison: a raw parquet glob resurrects tombstoned rows, and
delta_scan does not. If those two numbers are ever equal the fixture has no tombstones and the test
proves nothing — so that is asserted too.
"""
import os

import pytest

from conftest import has_ext
from core import source as S

pytestmark = pytest.mark.usefixtures("con")


def _skip_without_delta(con):
    if not has_ext(con, "delta"):
        pytest.skip("duckdb delta extension not installed")


def test_a_delta_dir_resolves_to_delta_scan_not_a_glob(con, data):
    _skip_without_delta(con)
    spec = S.build_source(con, data["delta"])
    assert spec.fmt == "delta"
    assert spec.read_fn == "delta_scan"
    assert S.read_expr(spec).startswith("delta_scan(")


def test_tombstoned_rows_are_excluded(con, data):
    _skip_without_delta(con)
    spec = S.build_source(con, data["delta"])
    delta_rows = con.execute(f"SELECT count(*) FROM {S.read_expr(spec)}").fetchone()[0]
    glob_rows = con.execute(
        f"SELECT count(*) FROM read_parquet('{data['delta']}/*.parquet')"
    ).fetchone()[0]

    assert delta_rows == 100, "delta_scan should honor the version-1 remove action"
    assert glob_rows == 150, "the tombstoned file is still on disk, so a raw glob sees it"
    # The assertion that keeps this test honest.
    assert glob_rows != delta_rows, (
        "fixture has no tombstones — this test would pass even if delta support were broken"
    )


def test_a_plain_parquet_folder_still_globs(con, data):
    spec = S.build_source(con, data["hive"])
    assert spec.fmt == "glob_parquet"
    assert spec.read_fn == "read_parquet"


def test_version_is_read_from_the_log(con, data):
    _skip_without_delta(con)
    assert S.delta_version(data["delta"]) == 1


def test_time_travel_uses_the_version_argument(con, data):
    """`version => n` works; the SQL-standard `AT (VERSION => n)` does not parse on 1.5.5."""
    _skip_without_delta(con)
    spec = S.build_source(con, data["delta"])
    at0 = S.read_expr_at(spec, 0)
    assert "version=0" in at0
    assert con.execute(f"SELECT count(*) FROM {at0}").fetchone()[0] == 150   # before the delete


def test_read_expr_at_refuses_non_delta(con, data):
    spec = S.build_source(con, data["parquet"])
    with pytest.raises(ValueError):
        S.read_expr_at(spec, 0)


def test_delta_is_never_staged():
    """A flat copy of a Delta table silently pins it to one version, on top of being redundant."""
    from core.stage import GB, should_stage

    d = should_stage("delta", 50 * GB, free_bytes=500 * GB)
    assert d.stage is False
    assert "version" in d.reason
