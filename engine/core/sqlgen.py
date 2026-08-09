"""SQL generation. Pure: every function returns `(sql, params)` or a plain string.

Invariant (pinned by engine/tests/test_sqlgen.py): **identifiers are quoted via ident.q(),
values are always bound as `?` parameters.**

`rel` throughout is already-safe relation SQL — `"tablename"` from ident.q() or a wrapped user
subquery `(...) AS _q`. Callers in session.py decide which; sqlgen never builds it from user input.
"""
from __future__ import annotations

import re
from typing import Any, Iterable, Mapping, Sequence

from .ident import q, qlit
from .types import NULLARY_OPS, Column, Filter, QuerySpec

# Non-NULL values that look like missing data. Compared against lower(trim(...)), so lowercase
# only. '' catches whitespace-only; n_empty/n_nullish below keep true-empty disjoint from it.
NULLISH = (
    "", "na", "n/a", "null", "none", "nil", "-", "--", "—", "?", "#n/a", "#na",
    "nan", "not available", "unknown", ".",
)


class UnknownColumn(KeyError):
    """A filter or sort referenced a column that isn't in the relation."""


def _col(name: str, cols: Mapping[str, Column]) -> str:
    """Quote a column after checking it exists — a typo becomes a clean 400, not a binder error."""
    if name not in cols:
        raise UnknownColumn(name)
    return q(name)


def _as_text(name: str, cols: Mapping[str, Column]) -> str:
    """A column coerced to VARCHAR — for ILIKE, emptiness and length checks on any type."""
    return f"CAST({_col(name, cols)} AS VARCHAR)"


def where_clause(
    filters: Sequence[Filter], cols: Mapping[str, Column]
) -> tuple[str, list[Any]]:
    """Render filters to a WHERE fragment (no WHERE keyword) plus params; ("", []) when empty."""
    parts: list[str] = []
    params: list[Any] = []

    for f in filters:
        c = _col(f.col, cols)
        if f.op in NULLARY_OPS:
            if f.op == "is_null":
                parts.append(f"{c} IS NULL")
            elif f.op == "not_null":
                parts.append(f"{c} IS NOT NULL")
            else:  # is_empty
                parts.append(f"{_as_text(f.col, cols)} = ''")
            continue

        if not f.values:
            continue  # a value-taking op with nothing selected filters nothing

        if f.op in {"=", "!=", "<", "<=", ">", ">="}:
            parts.append(f"{c} {f.op} ?")
            params.append(f.values[0])
        elif f.op == "between":
            lo, hi = f.values[0], f.values[1]
            parts.append(f"{c} BETWEEN ? AND ?")
            params.extend([lo, hi])
        elif f.op == "contains":
            parts.append(f"{_as_text(f.col, cols)} ILIKE '%' || ? || '%'")
            params.append(f.values[0])
        elif f.op in ("in", "not_in"):
            # NULL must be split out: `col IN (NULL)` never matches and `col NOT IN (NULL)` is
            # never true, and the distinct panel makes NULL clickable, so this path is normal use.
            vals = [v for v in f.values if v is not None]
            has_null = len(vals) != len(f.values)
            ors: list[str] = []
            if vals:
                ph = ", ".join("?" for _ in vals)
                ors.append(f"{c} {'IN' if f.op == 'in' else 'NOT IN'} ({ph})")
                params.extend(vals)
            if f.op == "in":
                if has_null:
                    ors.append(f"{c} IS NULL")
                parts.append("(" + " OR ".join(ors) + ")" if len(ors) > 1 else ors[0])
            else:
                # Excluding values must not silently drop NULL rows unless NULL itself is excluded.
                if has_null:
                    ors.append(f"{c} IS NOT NULL")
                    parts.append("(" + " AND ".join(ors) + ")" if len(ors) > 1 else ors[0])
                else:
                    parts.append(f"({ors[0]} OR {c} IS NULL)")
        else:
            raise ValueError(f"unsupported op {f.op!r}")

    return " AND ".join(parts), params


def _where(filters, cols) -> tuple[str, list[Any]]:
    frag, params = where_clause(filters, cols)
    return (f"\nWHERE {frag}" if frag else ""), params


def order_by(sort: Iterable[tuple[str, str]], cols: Mapping[str, Column]) -> str:
    """ORDER BY with explicit NULLS LAST, so ordering survives engine-default changes. Ties on a
    non-unique column are still unordered across pages — session.py materializes for that."""
    terms = []
    for name, direction in sort:
        d = "DESC" if str(direction).lower().startswith("d") else "ASC"
        terms.append(f"{_col(name, cols)} {d} NULLS LAST")
    return ("\nORDER BY " + ", ".join(terms)) if terms else ""


def page_sql(
    spec: QuerySpec, cols: Mapping[str, Column], rel: str, limit: int, offset: int
) -> tuple[str, list[Any]]:
    w, params = _where(spec.filters, cols)
    sql = (
        f"SELECT *\nFROM {rel}"
        f"{w}{order_by(spec.sort, cols)}\nLIMIT ? OFFSET ?"
    )
    return sql, [*params, int(limit), int(offset)]


def count_sql(
    spec: QuerySpec, cols: Mapping[str, Column], rel: str
) -> tuple[str, list[Any]]:
    """Measured trap: see source.exact_count — count(*) via projection pushdown ignores
    uncastable rows; session counts the all-varchar relation."""
    w, params = _where(spec.filters, cols)
    return f"SELECT count(*) AS n\nFROM {rel}{w}", params


def topn_sql(
    rel: str,
    col: str,
    cols: Mapping[str, Column],
    filters: Sequence[Filter] = (),
    limit: int = 200,
    search: str | None = None,
) -> tuple[str, list[Any]]:
    """Top-N distinct values with counts and share-of-rows in a single pass —
    `sum(count(*)) OVER ()` supplies the (filtered) percentage denominator in the same scan.

    Pass `filters` already stripped of this column's own predicates (QuerySpec.without_col) so the
    panel keeps showing every value with the selected ones highlighted.
    """
    c = _col(col, cols)
    txt = _as_text(col, cols)
    w, params = where_clause(filters, cols)
    clauses = [w] if w else []
    if search:
        clauses.append(f"{txt} ILIKE '%' || ? || '%'")
        params = [*params, search]
    where = ("\nWHERE " + " AND ".join(clauses)) if clauses else ""

    sql = f"""SELECT
  CASE WHEN {c} IS NULL THEN '␀ NULL'
       WHEN {txt} = '' THEN '␀ EMPTY'
       ELSE {txt} END AS label,
  {c} AS value,
  count(*) AS n,
  count(*) * 1.0 / sum(count(*)) OVER () AS frac
FROM {rel}{where}
GROUP BY ALL
ORDER BY n DESC, label
LIMIT ?"""
    return sql, [*params, int(limit)]


def distinct_stats_sql(
    rel: str,
    col: str,
    cols: Mapping[str, Column],
    filters: Sequence[Filter] = (),
    exact: bool = False,
) -> tuple[str, list[Any]]:
    """Row/non-null/distinct counts for the panel footer. approx_count_distinct is HyperLogLog and
    can exceed the true row count (measured: 340 for 300 distinct), so callers clamp to n. Exact is
    opt-in: count(DISTINCT) on a high-cardinality column is expensive."""
    c = _col(col, cols)
    w, params = _where(filters, cols)
    extra = f",\n  count(DISTINCT {c}) AS n_distinct_exact" if exact else ""
    sql = (
        f"SELECT\n  count(*) AS n_rows,\n  count({c}) AS n_nonnull,"
        f"\n  approx_count_distinct({c}) AS n_distinct_approx{extra}\nFROM {rel}{w}"
    )
    return sql, params


def histogram_sql(
    rel: str,
    col: str,
    cols: Mapping[str, Column],
    lo: float,
    step: float,
    bins: int,
    filters: Sequence[Filter] = (),
) -> tuple[str, list[Any]]:
    """Fixed-width histogram in one pass, reusing lo/step from the cached profile. Per-bucket true
    min/max feed the tooltip. Deliberately avoids width_bucket() (cross-version signature drift).
    Empty buckets are simply absent; the client fills them."""
    c = _col(col, cols)
    b = f"epoch_ms({c})::DOUBLE" if cols[col].kind == "temporal" else f"{c}::DOUBLE"
    w, params = where_clause(filters, cols)
    clauses = [f"{c} IS NOT NULL"] + ([w] if w else [])
    where = "\nWHERE " + " AND ".join(clauses)
    sql = f"""SELECT
  least(? - 1, greatest(0, floor(({b} - ?) / ?)::INT)) AS b,
  count(*) AS n,
  min({c}) AS b_min,
  max({c}) AS b_max
FROM {rel}{where}
GROUP BY b
ORDER BY b"""
    return sql, [int(bins), float(lo), float(step), *params]


def profile_extra_sql(rel: str, cols: Sequence[Column]) -> str:
    """One scan covering every column, for what SUMMARIZE misses: empty strings and null-like
    sentinels ('NA', '-', '?'). Aliases are index-based (`c0__empty`), not name-based, so two
    columns whose names sanitize identically cannot collide. n_null / n_empty / n_nullish are kept
    disjoint: whitespace-only lands in nullish, true '' in empty."""
    sentinels = ", ".join("'" + s.replace("'", "''") + "'" for s in NULLISH)
    parts = ["count(*) AS n"]
    for i, col in enumerate(cols):
        c = q(col.name)
        txt = f"CAST({c} AS VARCHAR)"
        parts += [
            f"count(*) FILTER (WHERE {c} IS NULL) AS c{i}__null",
            f"count(*) FILTER (WHERE {txt} = '') AS c{i}__empty",
            f"count(*) FILTER (WHERE {c} IS NOT NULL AND {txt} <> ''"
            f" AND lower(trim({txt})) IN ({sentinels})) AS c{i}__nullish",
            f"max(length({txt})) AS c{i}__maxlen",
        ]
    return "SELECT\n  " + ",\n  ".join(parts) + f"\nFROM {rel}"


# A DuckDB type name (from sniff_csv / DESCRIBE) — the one thing here interpolated rather than
# bound, so whitelisted even though the values are engine-generated.
_TYPE_RE = re.compile(r"^[A-Za-z0-9_ ()\[\],]+$")


def _safe_type(t: str) -> str:
    if not _TYPE_RE.match(t or ""):
        raise ValueError(f"refusing to interpolate suspicious type name {t!r}")
    return t


def _castable(col: Column) -> bool:
    """Whether a TRY_CAST check is meaningful — text and nested columns can't fail to be text."""
    return col.kind not in ("text", "other", "nested", "blob")


def _bad_cell(col: Column) -> str:
    """Predicate for 'this varchar cell would not survive casting to the sniffed type'."""
    c = q(col.name)
    return (
        f"({c} IS NOT NULL AND trim({c}) <> ''"
        f" AND TRY_CAST({c} AS {_safe_type(col.type)}) IS NULL)"
    )


def uncastable_sql(rel_varchar: str, cols: Sequence[Column]) -> str:
    """Count cells that would fail to cast, scanning the all-varchar relation. Verified: DuckDB
    1.5.5 has no reject_scans()/reject_errors — store_rejects is accepted but produces no queryable
    table. TRY_CAST names the column and can show the offending value anyway."""
    parts = ["count(*) AS n"]
    for i, col in enumerate(cols):
        if not _castable(col):
            parts.append(f"0 AS c{i}__bad")  # nothing to fail; keeps the result shape uniform
            continue
        parts.append(f"count(*) FILTER (WHERE {_bad_cell(col)}) AS c{i}__bad")
    return "SELECT\n  " + ",\n  ".join(parts) + f"\nFROM {rel_varchar}"


def bad_row_count_sql(rel_varchar: str, cols: Sequence[Column]) -> str:
    """Count ROWS with at least one uncastable cell (uncastable_sql counts cells). This is the
    number that reconciles the grid: the typed relation is read with ignore_errors, so it returns
    physical - bad_rows. Counting the typed relation directly can't produce it — projection
    pushdown answers count(*) without parsing — hence the all-varchar relation."""
    conds = [_bad_cell(c) for c in cols if _castable(c)]
    if not conds:
        return f"SELECT 0 AS n FROM {rel_varchar} LIMIT 1"
    return f"SELECT count(*) AS n\nFROM {rel_varchar}\nWHERE {' OR '.join(conds)}"


def bad_rows_sql(
    rel_varchar: str, cols: Sequence[Column], limit: int = 200
) -> tuple[str, list[Any]]:
    """The rows containing uncastable cells; `bad_columns` is a list so the UI can highlight the
    offending cells rather than just flagging the row."""
    checkable = [c for c in cols if _castable(c)]
    if not checkable:
        return f"SELECT * FROM {rel_varchar} LIMIT 0", []
    conds, labels = [], []
    for col in checkable:
        cond = _bad_cell(col)
        conds.append(cond)
        labels.append(f"CASE WHEN {cond} THEN {qlit(col.name)} END")
    sql = (
        f"SELECT list_filter([{', '.join(labels)}], x -> x IS NOT NULL) AS bad_columns, *\n"
        f"FROM {rel_varchar}\nWHERE {' OR '.join(conds)}\nLIMIT ?"
    )
    return sql, [int(limit)]


def render_sql(spec: QuerySpec, cols: Mapping[str, Column]) -> str:
    """Pretty, human-editable SQL equivalent to the current UI state. Values are inlined ONLY
    because this is display text for the SQL box/clipboard, never executed — the executed path is
    page_sql with bound parameters."""
    lines = ["SELECT *", f"FROM {q(spec.relation)}"]
    preds: list[str] = []
    for f in spec.filters:
        c = q(f.col)
        if f.op == "is_null":
            preds.append(f"{c} IS NULL")
        elif f.op == "not_null":
            preds.append(f"{c} IS NOT NULL")
        elif f.op == "is_empty":
            preds.append(f"CAST({c} AS VARCHAR) = ''")
        elif f.op == "contains":
            preds.append(f"CAST({c} AS VARCHAR) ILIKE {_lit(f'%{f.values[0]}%')}")
        elif f.op == "between":
            preds.append(f"{c} BETWEEN {_lit(f.values[0])} AND {_lit(f.values[1])}")
        elif f.op in ("in", "not_in"):
            vals = ", ".join(_lit(v) for v in f.values if v is not None)
            kw = "IN" if f.op == "in" else "NOT IN"
            frag = f"{c} {kw} ({vals})" if vals else ""
            if any(v is None for v in f.values):
                nul = f"{c} IS NULL" if f.op == "in" else f"{c} IS NOT NULL"
                frag = f"({frag} OR {nul})" if vals and f.op == "in" else (
                    f"({frag} AND {nul})" if vals else nul
                )
            preds.append(frag)
        elif f.values:
            preds.append(f"{c} {f.op} {_lit(f.values[0])}")
    if preds:
        lines.append("WHERE " + "\n  AND ".join(preds))
    if spec.sort:
        lines.append(
            "ORDER BY "
            + ", ".join(
                f"{q(n)} {'DESC' if str(d).lower().startswith('d') else 'ASC'}"
                for n, d in spec.sort
            )
        )
    return "\n".join(lines)


def _lit(v: Any) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def wrap_user_sql(sql: str, limit: int, offset: int = 0) -> tuple[str, list[Any]]:
    """Wrap a user SELECT for paging, so non-SELECTs die at parse time. The newlines are
    load-bearing — measured on DuckDB 1.5.5: the flat form `SELECT * FROM ( <sql> ) AS _q` rejects
    a legitimate `select 1 -- comment` (the comment swallows the paren); with the paren on its own
    line, trailing comments work and every dangerous statement (DROP/COPY/ATTACH/INSTALL/PRAGMA/
    SET/CREATE...AS/EXPORT, `SELECT 1; DROP ...`) still fails with a ParserException. That
    grammar-level rejection — not a keyword blocklist — is the actual enforcement; core.guard runs
    first only so the error message is a sentence instead of a parser dump."""
    return f"SELECT * FROM (\n{sql.strip()}\n) AS _q\nLIMIT ? OFFSET ?", [int(limit), int(offset)]
