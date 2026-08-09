"""Staging policy and the purge lifecycle. Pure — no connection, no files."""
import datetime as dt

import pytest

from core.stage import (
    GB,
    MB,
    DEFAULT_MAX_AGE_DAYS,
    StagedEntry,
    ctas_sql,
    select_for_purge,
    should_stage,
    staging_name,
    swap_sql,
)

FREE = 500 * GB


@pytest.mark.parametrize("fmt", ["parquet", "glob_parquet", "delta"])
def test_columnar_formats_are_never_staged(fmt):
    d = should_stage(fmt, 100 * GB, FREE)
    assert d.stage is False


def test_small_text_is_not_worth_copying():
    d = should_stage("csv", 5 * MB, FREE)
    assert d.stage is False
    assert "faster" in d.reason


def test_mid_size_text_stages_in_the_background():
    d = should_stage("csv", 500 * MB, FREE)
    assert d.stage is True
    assert d.needs_confirm is False
    assert d.est_seconds > 0


def test_enormous_text_asks_first():
    d = should_stage("csv", 40 * GB, FREE)
    assert d.stage is True
    assert d.needs_confirm is True


def test_refuses_when_the_disk_is_tight():
    d = should_stage("csv", 10 * GB, free_bytes=5 * GB)
    assert d.stage is False
    assert "free" in d.reason


def test_threshold_boundary():
    assert should_stage("csv", 25 * MB - 1, FREE).stage is False
    assert should_stage("csv", 25 * MB, FREE).stage is True


def test_ctas_does_not_disable_insertion_order():
    """Turning off preserve_insertion_order makes the swap VISIBLE as the grid reshuffling."""
    sql = ctas_sql("sales", "read_csv('/x.csv')")
    assert "preserve_insertion_order" not in sql
    assert staging_name("sales") in sql


def test_swap_is_transactional_and_keeps_the_user_facing_name():
    stmts = swap_sql("sales")
    assert stmts[0] == "BEGIN TRANSACTION"
    assert stmts[-1] == "COMMIT"
    assert any('DROP VIEW IF EXISTS "sales"' in s for s in stmts)
    assert any('RENAME TO "sales"' in s for s in stmts)


# --------------------------------------------------------------------- purge

NOW = dt.datetime(2026, 8, 7, 12, 0, 0)


def _entry(name, days_ago, gb):
    return StagedEntry(table_name=name, path=f"/data/{name}.csv",
                       bytes=int(gb * GB), last_used=NOW - dt.timedelta(days=days_ago))


def test_age_out_selects_only_stale_entries():
    entries = [_entry("fresh", 1, 1), _entry("old", 20, 1), _entry("edge", 13, 1)]
    aged, over = select_for_purge(entries, NOW, budget_bytes=100 * GB)
    assert aged == ("old",)
    assert over == ()


def test_size_pressure_evicts_least_recently_used_first():
    entries = [_entry("a", 1, 8), _entry("b", 2, 8), _entry("c", 3, 8)]
    aged, over = select_for_purge(entries, NOW, budget_bytes=20 * GB)
    assert aged == ()
    assert over == ("c",)            # 24 GB total, drop the oldest-used until it fits


def test_nothing_is_reported_in_both_lists():
    entries = [_entry("stale_big", 30, 30), _entry("fresh_big", 1, 30)]
    aged, over = select_for_purge(entries, NOW, budget_bytes=20 * GB)
    assert set(aged).isdisjoint(over)
    assert aged == ("stale_big",)
    # After the age-out only fresh_big remains at 30 GB, still over a 20 GB budget.
    assert over == ("fresh_big",)


def test_recently_used_survives_when_the_budget_already_fits():
    entries = [_entry("a", 0, 1), _entry("b", 0, 1)]
    aged, over = select_for_purge(entries, NOW, budget_bytes=20 * GB)
    assert aged == () and over == ()


def test_default_age_is_two_weeks():
    assert DEFAULT_MAX_AGE_DAYS == 14
