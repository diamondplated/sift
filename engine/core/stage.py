"""Staging policy and the staged-data lifecycle.

Pure: decisions only. session.py owns the thread that carries them out. The first step is always
a view over the file (instant at any size); staging is the second, and only where it pays.
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import Sequence

from .ident import q
from .types import Fmt, StageDecision

MB = 1024 * 1024
GB = 1024 * MB

STAGE_MIN_BYTES = 25 * MB        # below: a full re-parse is under ~100 ms, a view is imperceptible
STAGE_CONFIRM_BYTES = 20 * GB    # above: a CTAS is minutes and many GB of disk, so ask first
PARSE_BYTES_PER_SEC = 250 * MB   # measured CSV parse rate on an M-series Mac; only the "~20 s" hint

# Never worth staging: parquet/glob are already columnar and compressed with footer statistics and
# row-group skipping; a flat copy of delta additionally freezes the table at one version.
NEVER_STAGE: frozenset[Fmt] = frozenset({"parquet", "glob_parquet", "delta"})

STAGE_SUFFIX = "__stage"


def should_stage(
    fmt: Fmt,
    size_bytes: int,
    free_bytes: int,
    threshold_bytes: int = STAGE_MIN_BYTES,
) -> StageDecision:
    """Decide whether this source earns a native DuckDB copy.

    The payoff is not just aggregate speed: `LIMIT/OFFSET` on a CSV view is O(offset), while a
    native table seeks by row group. Staging and smooth scrolling are the same feature.
    """
    if fmt in NEVER_STAGE:
        return StageDecision(
            False,
            "already columnar with per-file statistics — a copy would only duplicate it"
            + (" and pin the table to one version" if fmt == "delta" else ""),
        )
    if size_bytes < threshold_bytes:
        return StageDecision(
            False, f"only {_human(size_bytes)} — re-reading it is faster than copying it"
        )
    if free_bytes < size_bytes:
        # Conservative: DuckDB usually compresses CSV below 1x, but running the disk to zero on
        # someone's laptop is not a risk worth taking for a speed-up.
        return StageDecision(
            False,
            f"only {_human(free_bytes)} free on disk for a {_human(size_bytes)} source",
        )
    est = size_bytes / PARSE_BYTES_PER_SEC
    if size_bytes > STAGE_CONFIRM_BYTES:
        return StageDecision(
            True, f"{_human(size_bytes)} — this will take a while and use real disk",
            est_seconds=est, needs_confirm=True,
        )
    return StageDecision(
        True, f"{_human(size_bytes)} of text — a native copy makes scrolling and grouping instant",
        est_seconds=est,
    )


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:,.0f} {unit}" if unit == "B" else f"{n:,.1f} {unit}"
        n /= 1024.0


def staging_name(table: str) -> str:
    return f"{table}{STAGE_SUFFIX}"


def ctas_sql(table: str, read_expr: str) -> str:
    """Materialize the source into native storage under a temporary name.

    Deliberately does NOT set `preserve_insertion_order = false`: rows would land out of order,
    making the swap *visible* as the grid silently reshuffling under the user mid-scroll.
    """
    return f"CREATE OR REPLACE TABLE {q(staging_name(table))} AS SELECT * FROM {read_expr}"


def swap_sql(table: str) -> list[str]:
    """Replace the view with the staged table under the same user-facing name. DuckDB DDL is
    transactional, so the rename is invisible to readers and the user's typed SQL keeps working.
    session.py holds a per-table lock across these and retries on conflict.
    """
    return [
        "BEGIN TRANSACTION",
        f"DROP VIEW IF EXISTS {q(table)}",
        f"ALTER TABLE {q(staging_name(table))} RENAME TO {q(table)}",
        "COMMIT",
    ]


def drop_staging_sql(table: str) -> str:
    return f"DROP TABLE IF EXISTS {q(staging_name(table))}"


# ------------------------------------------------------- staged-data lifecycle

DEFAULT_BUDGET_BYTES = 20 * GB
DEFAULT_MAX_AGE_DAYS = 14


@dataclass(frozen=True)
class StagedEntry:
    """A row of the _sift_sources catalog, as far as purge decisions are concerned."""
    table_name: str
    path: str
    bytes: int
    last_used: dt.datetime
    source_token: str = ""


def select_for_purge(
    entries: Sequence[StagedEntry],
    now: dt.datetime,
    budget_bytes: int = DEFAULT_BUDGET_BYTES,
    max_age_days: int = DEFAULT_MAX_AGE_DAYS,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Pick staged tables to evict. Returns (aged_out, over_budget) table names.

    Staged data is *client* data on a laptop, so it ages out on a clock as well as under size
    pressure — an LRU alone would keep a large feed around indefinitely while the total stayed
    small. Age-out runs first, the size check applies to what survives, so nothing is ever
    reported in both lists.
    """
    cutoff = now - dt.timedelta(days=max_age_days)
    aged = tuple(e.table_name for e in entries if e.last_used < cutoff)
    aged_set = set(aged)
    survivors = [e for e in entries if e.table_name not in aged_set]

    # Evict least-recently-used first until the total fits.
    total = sum(e.bytes for e in survivors)
    over: list[str] = []
    for e in sorted(survivors, key=lambda x: x.last_used):
        if total <= budget_bytes:
            break
        over.append(e.table_name)
        total -= e.bytes
    return aged, tuple(over)


CATALOG_DDL = """
CREATE TABLE IF NOT EXISTS _sift_sources (
    source_token VARCHAR PRIMARY KEY,
    path         VARCHAR,
    mtime_ns     BIGINT,
    size         BIGINT,
    table_name   VARCHAR,
    fmt          VARCHAR,
    staged_at    TIMESTAMP,
    last_used    TIMESTAMP,
    row_count    BIGINT,
    bytes        BIGINT
)
"""
