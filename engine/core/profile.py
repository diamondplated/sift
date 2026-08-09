"""Column profiling: what SUMMARIZE gives, what it misses, and which panel a column deserves.

Pure — takes already-fetched rows, returns dataclasses.
"""
from __future__ import annotations

from typing import Any, Literal, Mapping, Sequence

from .types import Column, ColumnProfile

# The 12 columns SUMMARIZE returns on DuckDB 1.5.5, verified by probe. min/max/avg/std/quantiles
# come back as VARCHAR so heterogeneous column types share one result shape; null_percentage is
# DECIMAL(9,2), which arrives in Python as a Decimal.
SUMMARIZE_COLUMNS = (
    "column_name", "column_type", "min", "max", "approx_unique", "avg", "std",
    "q25", "q50", "q75", "count", "null_percentage",
)

# Above this many distinct values, an exact count(DISTINCT) is expensive and useless to read.
EXACT_DISTINCT_MAX = 100_000

# A numeric column with few distinct values (store_id with 12) is categorical in practice.
NUMERIC_TOPN_MAX_DISTINCT = 50


def parse_summarize(description: Sequence[Any], rows: Sequence[Sequence[Any]]) -> dict[str, dict]:
    """Index SUMMARIZE output by column name, coercing the numeric-ish fields."""
    names = [d[0] for d in description]
    out: dict[str, dict] = {}
    for row in rows:
        rec = dict(zip(names, row))
        out[rec["column_name"]] = {
            "type": rec.get("column_type"),
            "min": rec.get("min"),
            "max": rec.get("max"),
            "approx_unique": _int(rec.get("approx_unique")),
            "avg": _float(rec.get("avg")),
            "std": _float(rec.get("std")),
            "q25": rec.get("q25"),
            "q50": rec.get("q50"),
            "q75": rec.get("q75"),
            "count": _int(rec.get("count")),
            "null_percentage": _float(rec.get("null_percentage")),
        }
    return out


def _int(v: Any) -> int:
    try:
        return int(v)          # Decimal included
    except (TypeError, ValueError):
        return 0


def _float(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _str(v: Any) -> str | None:
    return None if v is None else str(v)


def clamp_distinct(approx: int, n: int) -> int:
    """HyperLogLog can overshoot the row count — measured 340 for 300 distinct values, which
    reads as a bug above a 300-row table, so clamp before display."""
    return max(0, approx if n <= 0 else min(approx, n))


def choose_view(
    col: Column, approx_distinct: int, n: int
) -> Literal["topn", "hist", "highcard"]:
    """Which distinct-values panel to show for this column."""
    if col.kind in ("number", "temporal"):
        return "hist" if approx_distinct > NUMERIC_TOPN_MAX_DISTINCT else "topn"
    # Near-unique text means an identifier or free text, where a 200-row list tells you nothing;
    # the highcard panel answers "is this a key?" instead.
    if col.kind == "text" and n > 0 and approx_distinct > max(1000, 0.9 * n):
        return "highcard"
    return "topn"


def wants_exact_distinct(approx_distinct: int) -> bool:
    return approx_distinct < EXACT_DISTINCT_MAX


def build_profile(
    cols: Sequence[Column],
    summ: Mapping[str, dict],
    extra: Mapping[str, Any] | None = None,
    uncastable: Mapping[str, Any] | None = None,
    n_rows: int | None = None,
) -> tuple[ColumnProfile, ...]:
    """Merge the SUMMARIZE pass, the FILTER pass, and the TRY_CAST pass into one profile per column.

    `extra` and `uncastable` are the single-row results of sqlgen.profile_extra_sql and
    sqlgen.uncastable_sql, keyed by their generated `c{i}__*` aliases — index-based so that two
    columns whose names sanitize identically cannot collide.
    """
    extra = extra or {}
    uncastable = uncastable or {}
    n = int(n_rows if n_rows is not None else extra.get("n") or 0)

    out: list[ColumnProfile] = []
    for i, col in enumerate(cols):
        s = summ.get(col.name, {})
        approx = clamp_distinct(_int(s.get("approx_unique")), n)
        n_null = _int(extra.get(f"c{i}__null"))
        if not n_null and s.get("null_percentage") is not None and n:
            # Fall back to SUMMARIZE's percentage when the FILTER pass hasn't run yet.
            n_null = int(round((s["null_percentage"] / 100.0) * n))
        out.append(
            ColumnProfile(
                name=col.name,
                type=col.type,
                kind=col.kind,
                n=n,
                n_null=n_null,
                n_empty=_int(extra.get(f"c{i}__empty")),
                n_nullish=_int(extra.get(f"c{i}__nullish")),
                approx_distinct=approx,
                exact_distinct=None,
                min_s=_str(s.get("min")),
                max_s=_str(s.get("max")),
                avg=_float(s.get("avg")),
                std=_float(s.get("std")),
                q25=_str(s.get("q25")),
                q50=_str(s.get("q50")),
                q75=_str(s.get("q75")),
                max_len=_int(extra.get(f"c{i}__maxlen")) or None,
                n_uncastable=_int(uncastable.get(f"c{i}__bad")),
                view=choose_view(col, approx, n),
            )
        )
    return tuple(out)


def histogram_params(
    lo: float | None, hi: float | None, bins: int = 40
) -> tuple[float, float, int] | None:
    """(lo, step, bins) for sqlgen.histogram_sql, or None when a histogram is meaningless
    (no range, or a single value) so the caller can fall back to the top-N panel."""
    if lo is None or hi is None or hi <= lo:
        return None
    bins = max(1, int(bins))
    return float(lo), (float(hi) - float(lo)) / bins, bins


def numeric_bounds(p: ColumnProfile) -> tuple[float, float] | None:
    """Parse min/max out of the VARCHAR-ised SUMMARIZE output for a numeric column."""
    lo, hi = _float(p.min_s), _float(p.max_s)
    if lo is None or hi is None:
        return None
    return lo, hi


def looks_like_excel_serial_dates(p: ColumnProfile) -> bool:
    """Excel serial dates land in roughly 25000..50000 (1968..2036) once read as numbers. A
    numeric column whose whole range sits inside that window is very likely dates that lost their
    formatting — the single most common Excel surprise, so it earns a badge and a conversion."""
    if p.kind != "number":
        return False
    b = numeric_bounds(p)
    return b is not None and 25_000.0 <= b[0] and b[1] <= 50_000.0 and p.approx_distinct > 1
