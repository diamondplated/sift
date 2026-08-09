"""The one stateful object: connection, catalog of open sources, background jobs, SSE fan-out.

Everything in core/ is pure and takes what it needs as arguments. All the mutable state, locking,
and threading lives here, so there is exactly one file to reason about for concurrency.

Threading model, in three facts:
  * One DuckDBPyConnection is created at startup.
  * DuckDBPyConnection is NOT thread-safe, so every unit of work takes `con.cursor()`. Cursors
    share the catalog and the buffer manager but own their transaction.
  * Query handlers in app.py are sync `def`, so FastAPI runs them in its threadpool; only the SSE
    endpoint is async.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import datetime as dt
import logging
import os
import re
import shutil
import threading
import time
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any, Iterable, Sequence

import duckdb

from core import profile as prof
from core import snippet as snip
from core import source as src
from core import sqlgen, stage
from core.guard import assert_select_only
from core.ident import q, sanitize_table_name
from core.types import (
    Column,
    ColumnProfile,
    Filter,
    QuerySpec,
    SourceKey,
    SourceSpec,
    needs_string_transport,
)

log = logging.getLogger("sift")

SIFT_HOME = os.path.abspath(os.environ.get("SIFT_HOME", os.path.expanduser("~/.sift")))
DB_PATH = os.path.join(SIFT_HOME, "stage.duckdb")
SPILL_DIR = os.path.join(SIFT_HOME, "spill")

PAGE_ROWS = 500
SORT_MATERIALIZE_MAX = 5_000_000
PROFILE_EAGER_MAX_BYTES = 200 * 1024 * 1024
STAGE_DWELL_SECONDS = 3.0

_EXTENSIONS = ("delta", "excel")

# Formats the Export action can write, verified against DuckDB 1.5.5's COPY. key -> (COPY options,
# file extension). The UI menus list the same keys; an unknown key is a clean 400, not a crash.
EXPORT_FORMATS = {
    "parquet": ("(FORMAT parquet, COMPRESSION zstd)", "parquet"),
    "csv":     ("(FORMAT csv, HEADER)", "csv"),
    "tsv":     ("(FORMAT csv, HEADER, DELIMITER '\t')", "tsv"),
    "json":    ("(FORMAT json, ARRAY true)", "json"),      # a single JSON array
    "ndjson":  ("(FORMAT json)", "ndjson"),                # one object per line
    "xlsx":    ("(FORMAT xlsx, HEADER true)", "xlsx"),      # needs the excel extension (loaded)
}


# --------------------------------------------------------------- serialization


def jsonable(value: Any) -> Any:
    """Make a DuckDB value safe for JSON *and* for JavaScript.

    The subtle one is integers. JSON has no precision limit but JS `Number` does, so a BIGINT
    order id past 2^53 would silently round in the browser — precisely the class of corruption
    this tool exists to expose. Wide ints and decimals therefore cross the wire as strings, and the
    client formats them using the column type it was given alongside.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, int):
        return str(value) if abs(value) > 2 ** 53 - 1 else value
    if isinstance(value, float):
        return value
    if isinstance(value, (dt.datetime, dt.date, dt.time)):
        return value.isoformat()
    if isinstance(value, dt.timedelta):
        return str(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return f"<blob {len(bytes(value)):,} B>"
    if isinstance(value, dict):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    return str(value)  # covers UUID et al.


def rows_payload(description: Sequence[Any], rows: Iterable[Sequence[Any]]) -> dict[str, Any]:
    """Column metadata plus rows as arrays (not objects) — 3-5x smaller, order already known."""
    cols = [{"name": d[0], "type": str(d[1]), "kind": Column.of(d[0], str(d[1])).kind}
            for d in description]
    force_str = [needs_string_transport(c["type"]) for c in cols]
    out = []
    for r in rows:
        out.append([
            (str(v) if (force and v is not None and not isinstance(v, (dt.date, dt.datetime)))
             else jsonable(v))
            for v, force in zip(r, force_str)
        ])
    return {"cols": cols, "rows": out}


# ------------------------------------------------------------------ the table


@dataclass
class Table:
    """One open source and everything the UI knows about it."""
    name: str
    spec: SourceSpec
    qspec: QuerySpec
    sql_mode: bool = False
    sql_text: str | None = None

    row_count: int | None = None            # physical rows in the source
    filtered_count: int | None = None       # rows matching the current filters (None = not yet run)
    bad_rows: int = 0                       # rows dropped because a cell would not cast
    bad_cells: int = 0
    counting: bool = False

    staged: bool = False
    staging: dict[str, Any] | None = None
    stage_decision: stage.StageDecision | None = None

    profile: tuple[ColumnProfile, ...] | None = None
    profiling: bool = False

    copied_from_browser: bool = False
    opened_at: float = field(default_factory=time.time)
    last_used: float = field(default_factory=time.time)
    first_aggregate_at: float | None = None
    notes: list[str] = field(default_factory=list)

    _sortkey: str | None = None             # temp table currently holding a sorted result set
    _uncastable: dict | None = None         # per-column bad-cell counts, computed once by _detect_bad_rows

    @property
    def cols(self) -> dict[str, Column]:
        return {c.name: c for c in self.spec.columns}

    @property
    def grid_rows(self) -> int | None:
        """Rows the grid can actually page through: physical minus rows dropped by ignore_errors."""
        if self.row_count is None:
            return None
        return max(0, self.row_count - self.bad_rows)

    @property
    def visible_rows(self) -> int | None:
        """Rows the grid will page through right now — filtered if any filter is active.

        The scroll extent depends on this, so getting it wrong makes the thumb overshoot the data.
        """
        if self.qspec.filters and self.filtered_count is not None:
            return self.filtered_count
        return self.grid_rows

    def summary(self) -> dict[str, Any]:
        est = self.spec.row_estimate
        return {
            "table": self.name,
            "path": self.spec.key.path,
            "target": self.spec.target,
            "fmt": self.spec.fmt,
            "size": self.spec.key.size,
            "n_cols": len(self.spec.columns),
            "rows": {
                "value": (self.visible_rows if self.visible_rows is not None
                          else (est.rows if est else None)),
                "exact": self.row_count is not None,
                "confidence": ("exact" if self.row_count is not None
                               else (est.confidence if est else None)),
                "basis": ("counted exactly" if self.row_count is not None
                          else (est.basis if est else "counting…")),
                "physical": self.row_count,
                "unfiltered": self.grid_rows,
                "filtered": bool(self.qspec.filters),
            },
            "counting": self.counting,
            "staged": self.staged,
            "staging": self.staging,
            "stage_reason": self.stage_decision.reason if self.stage_decision else None,
            "bad_rows": self.bad_rows,
            "bad_cells": self.bad_cells,
            "sheet": self.spec.sheet,
            "sheets": [{"name": s.name, "rows": s.rows, "cols": s.cols, "empty": s.empty}
                       for s in self.spec.sheets],
            "delta_version": self.spec.delta_version,
            "copied_from_browser": self.copied_from_browser,
            "sql_mode": self.sql_mode,
            "notes": self.notes,
            "opened_at": self.opened_at,
        }


class SiftError(RuntimeError):
    """A user-facing failure; app.py turns this into a 400 with the message intact."""


# ---------------------------------------------------------------- the session


class Session:
    def __init__(self) -> None:
        os.makedirs(SIFT_HOME, mode=0o700, exist_ok=True)
        os.chmod(SIFT_HOME, 0o700)  # tighten it even if the directory already existed
        os.makedirs(SPILL_DIR, mode=0o700, exist_ok=True)

        # DuckDB takes an exclusive lock on the database file, so only one engine can own the shared
        # staged-data store. That is usually right — it is one user's cache. But it must not turn
        # "the browser dev server is already running" into an opaque lock traceback at app launch,
        # so a second engine falls back to a private, disk-backed store it deletes on exit. Staging
        # still works; it just isn't persisted or shared for that session.
        self.db_path = DB_PATH
        self.shared_store = True
        self._sweep_private_stores()
        try:
            self.con = duckdb.connect(DB_PATH)
        except duckdb.Error as exc:
            if "lock" not in str(exc).lower():
                raise
            self.db_path = os.path.join(SIFT_HOME, f"stage-{os.getpid()}.duckdb")
            self.shared_store = False
            self.con = duckdb.connect(self.db_path)
            log.warning(
                "another Sift engine holds %s, so this one is using a private store at %s "
                "(staged data will not persist)", DB_PATH, self.db_path
            )

        self.extensions: dict[str, bool] = {}
        self._harden()
        self._load_extensions()
        self.con.execute(stage.CATALOG_DDL)

        self.tables: dict[str, Table] = {}
        self.lock = threading.RLock()
        self._table_locks: dict[str, threading.Lock] = {}
        self.jobs: dict[str, dict[str, Any]] = {}
        self.pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=4, thread_name_prefix="sift-bg"
        )
        self._subscribers: set[asyncio.Queue] = set()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._job_seq = 0

        self.sweep_spill()
        self.purge_staged(reason="startup")

    # ------------------------------------------------------------- setup

    def _harden(self) -> None:
        """Settings applied before any query runs.

        Blocking the network filesystems is the part that matters: a SELECT can still read any
        local file the user could `cat`, but it cannot ship results anywhere. Local reads keep
        working (verified) — `enable_external_access=false` would have blocked read_csv itself and
        destroyed the whole premise, which is why it is not used.
        """
        for stmt in (
            "SET disabled_filesystems='HTTPFileSystem,S3FileSystem'",
            "SET autoinstall_known_extensions=false",
            "SET autoload_known_extensions=false",
            "SET allow_community_extensions=false",
        ):
            try:
                self.con.execute(stmt)
            except Exception as exc:  # never fail to start over a hardening setting
                log.warning("could not apply %s: %s", stmt, exc)

    def _load_extensions(self) -> None:
        """Explicitly LOAD what we need, since autoloading is disabled above.

        Extension binaries are per-DuckDB-version, so a version bump needs a fresh INSTALL. A
        missing `delta` must never silently degrade to a raw parquet glob — that returns
        confidently wrong row counts — so open_path() refuses Delta folders instead.
        """
        for ext in _EXTENSIONS:
            try:
                self.con.execute(f"LOAD {ext}")
                self.extensions[ext] = True
            except Exception:
                try:
                    self.con.execute(f"INSTALL {ext}")
                    self.con.execute(f"LOAD {ext}")
                    self.extensions[ext] = True
                except Exception as exc:
                    self.extensions[ext] = False
                    log.warning("extension %s unavailable: %s", ext, exc)

    def engine_info(self) -> dict[str, Any]:
        return {
            "duckdb": duckdb.__version__,
            "sift_home": SIFT_HOME,
            "extensions": self.extensions,
            "staged_bytes": self.staged_total_bytes(),
            "shared_store": self.shared_store,
            "db_path": self.db_path,
        }

    # ------------------------------------------------------------- SSE

    def attach_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    def subscribe(self) -> asyncio.Queue:
        qq: asyncio.Queue = asyncio.Queue(maxsize=256)
        self._subscribers.add(qq)
        return qq

    def unsubscribe(self, qq: asyncio.Queue) -> None:
        self._subscribers.discard(qq)

    def emit(self, event: dict[str, Any]) -> None:
        """Publish to every SSE subscriber. Safe to call from a worker thread."""
        loop = self._loop
        if loop is None:
            return

        def fanout():
            for qq in list(self._subscribers):
                try:
                    qq.put_nowait(event)
                except asyncio.QueueFull:
                    pass  # a wedged client must not block the engine

        try:
            loop.call_soon_threadsafe(fanout)
        except RuntimeError:
            pass

    # ------------------------------------------------------- relations

    def table(self, name: str) -> Table:
        with self.lock:
            t = self.tables.get(name)
            if t is None:
                raise SiftError(f"No open table named {name!r}.")
            t.last_used = time.time()
            return t

    def _tlock(self, name: str) -> threading.Lock:
        with self.lock:
            return self._table_locks.setdefault(name, threading.Lock())

    def relation(self, t: Table) -> str:
        """Safe relation SQL for this table — a quoted name, or the user's wrapped query."""
        if t.sql_mode and t.sql_text:
            return f"(\n{t.sql_text.strip()}\n) AS _q"
        return q(t.name)

    def raw_relation(self, t: Table) -> str | None:
        """The all-varchar file expression, or None when the format cannot mis-cast.

        Parquet and Delta carry real types, so there is nothing to sniff wrong and no reject count
        to compute.
        """
        if not src.supports_all_varchar(t.spec):
            return None
        return src.read_expr(t.spec, all_varchar=True)

    # ------------------------------------------------------------- open

    def open_path(self, path: str, name: str | None = None, sheet: str | None = None,
                  copied: bool = False) -> Table:
        path = os.path.realpath(os.path.expanduser(path.strip()))
        if not os.path.exists(path):
            raise SiftError(f"No such file or folder: {path}")

        if src.is_delta_dir(path) and not self.extensions.get("delta"):
            raise SiftError(
                f"{os.path.basename(path)} is a Delta table, but the DuckDB delta extension is not "
                "available, so Sift cannot read it correctly. Reading the parquet files directly "
                "would resurrect deleted rows — refusing rather than showing you wrong numbers. "
                "Fix: run INSTALL delta once with network access."
            )

        try:
            with self.con.cursor() as cur:
                spec = src.build_source(cur, path, sheet=sheet)
        except src.UnsupportedSource as exc:
            raise SiftError(str(exc)) from exc

        with self.lock:
            taken = set(self.tables)
            base = name or sanitize_table_name(
                (spec.sheet or os.path.basename(path)) if spec.fmt == "xlsx"
                else os.path.basename(path)
            )
            tname = base if base not in taken else sanitize_table_name(base, taken)
            t = Table(name=tname, spec=spec, qspec=QuerySpec(relation=tname),
                      copied_from_browser=copied)
            if spec.row_count is not None:
                t.row_count = spec.row_count
            self.tables[tname] = t

        with self.con.cursor() as cur:
            cur.execute(src.create_view_sql(tname, spec))

        if spec.fmt == "xlsx" and spec.sheets:
            t.notes.append(
                f"Sheet “{spec.sheet}” of {len(spec.sheets)}"
                + (" — use the sheet picker to open others" if len(spec.sheets) > 1 else "")
            )
        if spec.fmt in ("glob_parquet", "glob_csv"):
            t.notes.append("Folder read as one table (union by name, with filename provenance)")
        if spec.fmt == "delta":
            t.notes.append(f"Delta table at version {spec.delta_version} — tombstones honored")

        self.emit({"type": "opened", "table": tname})
        self.pool.submit(self._after_open, tname)
        return t

    def _after_open(self, name: str) -> None:
        """Background work: exact count, bad-row detection, profile, staging decision."""
        try:
            t = self.tables.get(name)
            if t is None:
                return
            if t.row_count is None:
                t.counting = True
                self.emit({"type": "counting", "table": name})
                with self.con.cursor() as cur:
                    try:
                        t.row_count = src.exact_count(cur, t.spec)
                    except Exception as exc:
                        log.warning("exact count failed for %s: %s", name, exc)
                    finally:
                        t.counting = False
                self.emit({"type": "count", "table": name, "rows": t.row_count, "exact": True})

            self._detect_bad_rows(t)

            free = shutil.disk_usage(SIFT_HOME).free
            t.stage_decision = stage.should_stage(t.spec.fmt, t.spec.key.size, free)
            self.emit({"type": "state", "table": name})

            if (t.spec.key.size <= PROFILE_EAGER_MAX_BYTES or t.staged
                    or t.spec.fmt in stage.NEVER_STAGE):   # columnar: profiling is cheap
                self.compute_profile(name)

            if t.stage_decision and t.stage_decision.stage and not t.stage_decision.needs_confirm:
                self.pool.submit(self._maybe_stage_after_dwell, name)
        except Exception:
            log.exception("post-open work failed for %s", name)

    def _detect_bad_rows(self, t: Table) -> None:
        """Count cells and rows that would not survive casting to the sniffed types.

        Replaces reject_scans()/reject_errors(), which do not exist in DuckDB 1.5.5. Reads the
        all-varchar relation, so it sees the file as it really is.
        """
        raw = self.raw_relation(t)
        if raw is None:
            return
        with self.con.cursor() as cur:
            try:
                row = cur.execute(sqlgen.uncastable_sql(raw, t.spec.columns)).fetchone()
                # Keep the whole per-column result: compute_profile needs it for n_uncastable and
                # would otherwise re-run this full varchar scan.
                t._uncastable = dict(zip([d[0] for d in cur.description], row))
                t.bad_cells = int(sum(v or 0 for k, v in t._uncastable.items()
                                      if k.endswith("__bad")))
                if t.bad_cells:
                    t.bad_rows = int(
                        cur.execute(sqlgen.bad_row_count_sql(raw, t.spec.columns)).fetchone()[0]
                        or 0
                    )
                    self.emit({"type": "rejects", "table": t.name,
                               "cells": t.bad_cells, "rows": t.bad_rows})
            except Exception as exc:
                log.warning("bad-row detection failed for %s: %s", t.name, exc)

    # ------------------------------------------------------------- paging

    def page(self, name: str, offset: int, limit: int = PAGE_ROWS) -> dict[str, Any]:
        t = self.table(name)
        cols = t.cols
        with self.con.cursor() as cur:
            try:
                if t.sql_mode and t.sql_text:
                    sql, params = sqlgen.wrap_user_sql(t.sql_text, limit, offset)
                else:
                    # A filtered view has a different row count, and the grid's scroll extent is
                    # built from it — so count once per spec change and cache it, not per page.
                    if t.qspec.filters and t.filtered_count is None:
                        csql, cparams = sqlgen.count_sql(t.qspec, cols, q(t.name))
                        t.filtered_count = int(cur.execute(csql, cparams).fetchone()[0] or 0)
                    rel = self._sorted_relation(cur, t)
                    sql, params = sqlgen.page_sql(t.qspec, cols, rel, limit, offset)
                started = time.perf_counter()
                cur.execute(sql, params)
                payload = rows_payload(cur.description, cur.fetchall())
                payload.update(
                    offset=offset, limit=limit,
                    ms=round((time.perf_counter() - started) * 1000, 1),
                    total={"value": t.visible_rows, "exact": t.row_count is not None,
                           "unfiltered": t.grid_rows, "filtered": bool(t.qspec.filters)},
                )
                return payload
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc

    def _sorted_relation(self, cur, t: Table) -> str:
        """Materialize sorted result sets once, then page off the copy.

        Two reasons. A fresh `ORDER BY` per page is a full sort per page; and ties on a non-unique
        sort column are ordered arbitrarily, so the same row could appear on two pages or none.
        """
        if not t.qspec.sort:
            if t._sortkey:
                cur.execute(f"DROP TABLE IF EXISTS {q(t._sortkey)}")
                t._sortkey = None
            return q(t.name)

        key = f"_sift_rs_{abs(hash((t.name, t.qspec, t.staged)))}"
        if t._sortkey == key:
            return q(key)
        if t._sortkey:
            cur.execute(f"DROP TABLE IF EXISTS {q(t._sortkey)}")
        inner, params = sqlgen.page_sql(t.qspec, t.cols, q(t.name), SORT_MATERIALIZE_MAX, 0)
        cur.execute(f"CREATE OR REPLACE TEMP TABLE {q(key)} AS {inner}", params)
        t._sortkey = key
        return q(key)

    def run_sql(self, name: str, sql: str, offset: int, limit: int) -> dict[str, Any]:
        """Execute the SQL box's text.

        guard runs first for a readable message; the real enforcement is the wrapping in
        wrap_user_sql, where a non-SELECT cannot occupy a subquery position and dies in the parser.
        """
        assert_select_only(sql)
        t = self.table(name)
        t.sql_mode, t.sql_text = True, sql
        wrapped, params = sqlgen.wrap_user_sql(sql, limit, offset)
        with self.con.cursor() as cur:
            try:
                started = time.perf_counter()
                cur.execute(wrapped, params)
                payload = rows_payload(cur.description, cur.fetchall())
                payload.update(offset=offset, limit=limit, sql_mode=True,
                               ms=round((time.perf_counter() - started) * 1000, 1),
                               total={"value": None, "exact": False})
                return payload
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc

    def exit_sql_mode(self, name: str) -> Table:
        t = self.table(name)
        t.sql_mode, t.sql_text = False, None
        return t

    # ------------------------------------------------------------- profile

    def compute_profile(self, name: str) -> tuple[ColumnProfile, ...]:
        t = self.table(name)
        if t.profile is not None:
            return t.profile
        t.profiling = True
        with self.con.cursor() as cur:
            try:
                rel = q(t.name)
                cur.execute(f"SUMMARIZE {rel}")
                summ = prof.parse_summarize(cur.description, cur.fetchall())

                cur.execute(sqlgen.profile_extra_sql(rel, t.spec.columns))
                extra = dict(zip([d[0] for d in cur.description], cur.fetchone()))

                # _detect_bad_rows already ran this scan at open and cached it; reuse it.
                t.profile = prof.build_profile(
                    t.spec.columns, summ, extra, t._uncastable or {}, n_rows=extra.get("n")
                )
                for p in t.profile:
                    if prof.looks_like_excel_serial_dates(p) and t.spec.fmt == "xlsx":
                        t.notes.append(
                            f"“{p.name}” looks like Excel serial dates read as numbers "
                            f"({p.min_s}–{p.max_s})"
                        )
                self.emit({"type": "profile", "table": name})
                return t.profile
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc
            finally:
                t.profiling = False

    def profile_of(self, name: str, col: str) -> ColumnProfile:
        p = self.compute_profile(name)
        for c in p:
            if c.name == col:
                return c
        raise SiftError(f"No column {col!r} in {name}.")

    # ------------------------------------------------------------ distinct

    def distinct(self, name: str, col: str, limit: int = 200,
                 search: str | None = None) -> dict[str, Any]:
        t = self.table(name)
        t.first_aggregate_at = t.first_aggregate_at or time.time()
        cols = t.cols
        if col not in cols:
            raise SiftError(f"No column {col!r} in {name}.")
        # Faceting: a column's panel ignores its own filters, so every value stays visible with the
        # selected ones highlighted.
        facet = t.qspec.without_col(col).filters
        rel = self.relation(t)
        with self.con.cursor() as cur:
            try:
                started = time.perf_counter()
                sql, params = sqlgen.topn_sql(rel, col, cols, facet, limit=limit, search=search)
                rows = cur.execute(sql, params).fetchall()

                p = None
                try:
                    p = self.profile_of(name, col)
                except Exception:
                    pass
                approx = p.approx_distinct if p else 0
                sql2, params2 = sqlgen.distinct_stats_sql(
                    rel, col, cols, facet, exact=prof.wants_exact_distinct(approx)
                )
                cur.execute(sql2, params2)
                stats = dict(zip([d[0] for d in cur.description], cur.fetchone()))

                selected = {
                    v for f in t.qspec.filters if f.col == col and f.op in ("=", "in")
                    for v in f.values
                }
                values = [
                    {"label": r[0], "value": jsonable(r[1]), "n": int(r[2]),
                     "frac": float(r[3]), "selected": r[1] in selected}
                    for r in rows
                ]
                n_rows = int(stats.get("n_rows") or 0)
                shown = sum(v["n"] for v in values)
                n_distinct = stats.get("n_distinct_exact")
                exact = n_distinct is not None
                if not exact:
                    n_distinct = prof.clamp_distinct(int(stats.get("n_distinct_approx") or 0),
                                                     n_rows)
                return {
                    "mode": (p.view if p else "topn"),
                    "col": col, "type": cols[col].type, "kind": cols[col].kind,
                    "n_rows": n_rows,
                    "n_nonnull": int(stats.get("n_nonnull") or 0),
                    "n_distinct": {"value": int(n_distinct), "exact": exact},
                    "values": values,
                    "other_n": max(0, n_rows - shown),
                    "shown": len(values),
                    "ms": round((time.perf_counter() - started) * 1000, 1),
                }
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc

    def histogram(self, name: str, col: str, bins: int = 40) -> dict[str, Any]:
        t = self.table(name)
        t.first_aggregate_at = t.first_aggregate_at or time.time()
        cols = t.cols
        if col not in cols:
            raise SiftError(f"No column {col!r} in {name}.")
        p = self.profile_of(name, col)
        rel = self.relation(t)
        with self.con.cursor() as cur:
            try:
                if cols[col].kind == "temporal":
                    row = cur.execute(
                        f"SELECT min(epoch_ms({q(col)}))::DOUBLE, max(epoch_ms({q(col)}))::DOUBLE "
                        f"FROM {rel}"
                    ).fetchone()
                    bounds = (row[0], row[1]) if row and row[0] is not None else None
                else:
                    bounds = prof.numeric_bounds(p)
                params = prof.histogram_params(*(bounds or (None, None)), bins=bins)
                if params is None:
                    return {"mode": "hist", "col": col, "buckets": [], "n_null": p.n_null,
                            "degenerate": True,
                            "reason": "every value is the same, or the range is empty"}
                lo, step, nb = params
                facet = t.qspec.without_col(col).filters
                sql, ps = sqlgen.histogram_sql(rel, col, cols, lo, step, nb, facet)
                started = time.perf_counter()
                rows = cur.execute(sql, ps).fetchall()
                return {
                    "mode": "hist", "col": col, "kind": cols[col].kind,
                    "lo": lo, "step": step, "bins": nb, "n_null": p.n_null,
                    "buckets": [
                        {"b": int(r[0]), "lo": lo + step * int(r[0]),
                         "hi": lo + step * (int(r[0]) + 1),
                         "n": int(r[1]), "b_min": jsonable(r[2]), "b_max": jsonable(r[3])}
                        for r in rows
                    ],
                    "ms": round((time.perf_counter() - started) * 1000, 1),
                }
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc

    def sample_values(self, name: str, col: str, limit: int = 20) -> list[Any]:
        """A random-ish sample, for the high-cardinality panel where top-N says nothing."""
        t = self.table(name)
        with self.con.cursor() as cur:
            try:
                rows = cur.execute(
                    f"SELECT {q(col)} FROM {self.relation(t)} USING SAMPLE {int(limit)} ROWS"
                ).fetchall()
                return [jsonable(r[0]) for r in rows]
            except duckdb.Error:
                return []

    def length_histogram(self, name: str, col: str, bins: int = 24) -> list[dict[str, Any]]:
        t = self.table(name)
        with self.con.cursor() as cur:
            try:
                rows = cur.execute(
                    f"SELECT length(CAST({q(col)} AS VARCHAR)) AS len, count(*) AS n "
                    f"FROM {self.relation(t)} WHERE {q(col)} IS NOT NULL "
                    f"GROUP BY len ORDER BY len LIMIT {int(bins)}"
                ).fetchall()
                return [{"len": int(r[0]), "n": int(r[1])} for r in rows]
            except duckdb.Error:
                return []

    def bad_rows(self, name: str, limit: int = 200) -> dict[str, Any]:
        t = self.table(name)
        raw = self.raw_relation(t)
        if raw is None or not t.bad_cells:
            return {"cells": t.bad_cells, "rows": t.bad_rows, "cols": [], "data": []}
        with self.con.cursor() as cur:
            sql, params = sqlgen.bad_rows_sql(raw, t.spec.columns, limit)
            cur.execute(sql, params)
            payload = rows_payload(cur.description, cur.fetchall())
            return {"cells": t.bad_cells, "rows": t.bad_rows,
                    "cols": payload["cols"], "data": payload["rows"]}

    # ------------------------------------------------------------- filters

    def set_spec(self, name: str, filters: Sequence[Filter],
                 sort: Sequence[tuple[str, str]]) -> Table:
        t = self.table(name)
        cols = t.cols
        for f in filters:
            if f.col not in cols:
                raise SiftError(f"No column {f.col!r} in {name}.")
        for c, _ in sort:
            if c not in cols:
                raise SiftError(f"No column {c!r} in {name}.")
        t.qspec = QuerySpec(relation=t.name, filters=tuple(filters), sort=tuple(sort))
        t.filtered_count = None          # recount on the next page fetch
        t.first_aggregate_at = t.first_aggregate_at or time.time()
        return t

    def rendered_sql(self, name: str) -> str:
        t = self.table(name)
        return t.sql_text if (t.sql_mode and t.sql_text) else sqlgen.render_sql(t.qspec, t.cols)

    def snippet(self, name: str, dialect: str) -> str:
        t = self.table(name)
        return snip.snippet(dialect, t.spec, t.qspec, t.cols,
                            sql_override=t.sql_text if t.sql_mode else None)

    # ------------------------------------------------------------- staging

    def _next_job(self, kind: str) -> str:
        with self.lock:
            self._job_seq += 1
            jid = f"{kind}-{self._job_seq}"
            self.jobs[jid] = {"cancel": False}  # only the cancel flag is ever read
            return jid

    def _maybe_stage_after_dwell(self, name: str) -> None:
        """Stage only once the user has shown interest.

        A drive-by "let me peek at the header" should never pay for a 20 s CTAS, so wait for either
        an aggregate query or a few seconds of dwell on the open table.
        """
        deadline = time.time() + STAGE_DWELL_SECONDS
        while time.time() < deadline:
            t = self.tables.get(name)
            if t is None:
                return
            if t.first_aggregate_at:
                break
            time.sleep(0.1)
        if name in self.tables and not self.tables[name].staged:
            self.stage_now(name)

    def stage_now(self, name: str, force: bool = False) -> str | None:
        t = self.table(name)
        if t.staged or t.staging:
            return None
        free = shutil.disk_usage(SIFT_HOME).free
        decision = stage.should_stage(t.spec.fmt, t.spec.key.size, free)
        t.stage_decision = decision
        if not decision.stage and not force:
            self.emit({"type": "state", "table": name})
            return None
        jid = self._next_job("stage")
        t.staging = {"job_id": jid, "state": "running", "pct": 0.0,
                     "est_seconds": round(decision.est_seconds, 1)}
        self.emit({"type": "staging", "table": name, **t.staging})
        self.pool.submit(self._do_stage, name, jid)
        return jid

    def _do_stage(self, name: str, jid: str) -> None:
        t = self.tables.get(name)
        if t is None:
            return
        with self.con.cursor() as cur:
            before = self._db_bytes()
            try:
                cur.execute(stage.ctas_sql(t.name, src.read_expr(t.spec)))
                if self.jobs.get(jid, {}).get("cancel"):
                    cur.execute(stage.drop_staging_sql(t.name))
                    t.staging = None
                    self.emit({"type": "staging", "table": name, "state": "cancelled"})
                    return
                with self._tlock(name):
                    for attempt in range(3):
                        try:
                            for stmt in stage.swap_sql(t.name):
                                cur.execute(stmt)
                            break
                        except duckdb.Error:
                            try:
                                cur.execute("ROLLBACK")
                            except duckdb.Error:
                                pass
                            if attempt == 2:
                                raise
                            time.sleep(0.15)
                t.staged = True
                t.staging = None
                t._sortkey = None
                t.profile = None                  # re-profile against the native table
                row = cur.execute(f"SELECT count(*) FROM {q(t.name)}").fetchone()
                if row:
                    # After staging the table is materialized, so its own count is now
                    # authoritative and already excludes rows dropped at parse time.
                    t.row_count = int(row[0]) + t.bad_rows
                try:
                    cur.execute("CHECKPOINT")   # flush the WAL so the size delta is meaningful
                except duckdb.Error:
                    pass
                self._record_staged(cur, t, bytes_used=self._db_bytes() - before)
                self.emit({"type": "staged", "table": name, "rows": t.row_count})
                self.compute_profile(name)
            except Exception as exc:
                log.exception("staging failed for %s", name)
                t.staging = None
                self.emit({"type": "error", "table": name, "msg": f"staging failed: {exc}"})
            finally:
                self.jobs.pop(jid, None)

    def cancel(self, job_id: str) -> bool:
        j = self.jobs.get(job_id)
        if not j:
            return False
        j["cancel"] = True
        try:
            self.con.interrupt()
        except Exception:
            pass
        return True

    def _record_staged(self, cur, t: Table, bytes_used: int = 0) -> None:
        """Record a staged table, with the disk it actually cost.

        `bytes_used` is measured as the growth of stage.duckdb across the CTAS. DuckDB exposes no
        per-table byte size — `duckdb_tables.estimated_size` is estimated *rows*, which silently
        produced a "3,000,048 B" reading for a 3M-row table until this was caught.
        """
        cur.execute(
            "INSERT OR REPLACE INTO _sift_sources "
            "(source_token, path, mtime_ns, size, table_name, fmt, staged_at, last_used, "
            " row_count, bytes) VALUES (?,?,?,?,?,?,now(),now(),?,?)",
            [t.spec.key.token(), t.spec.key.path, t.spec.key.mtime_ns, t.spec.key.size,
             t.name, t.spec.fmt, t.row_count, max(0, int(bytes_used))],
        )

    def _db_bytes(self) -> int:
        total = 0
        for p in (self.db_path, self.db_path + ".wal"):
            try:
                total += os.path.getsize(p)
            except OSError:
                pass
        return total

    def _sweep_private_stores(self) -> None:
        """Delete private stores left behind by engines that are no longer running."""
        for name in os.listdir(SIFT_HOME) if os.path.isdir(SIFT_HOME) else []:
            m = re.fullmatch(r"stage-(\d+)\.duckdb(\.wal)?", name)
            if not m:
                continue
            pid = int(m.group(1))
            if pid == os.getpid():
                continue
            try:
                os.kill(pid, 0)          # still alive: leave it alone
            except ProcessLookupError:
                try:
                    os.unlink(os.path.join(SIFT_HOME, name))
                except OSError:
                    pass
            except PermissionError:
                pass

    # ------------------------------------------------- staged-data lifecycle

    def staged_entries(self) -> list[dict[str, Any]]:
        with self.con.cursor() as cur:
            rows = cur.execute(
                "SELECT table_name, path, fmt, staged_at, last_used, row_count, bytes, "
                "       source_token, mtime_ns, size "
                "FROM _sift_sources ORDER BY last_used DESC"
            ).fetchall()
            out = []
            for r in rows:
                exists = os.path.exists(r[1])
                stale = False
                if exists:
                    st = os.stat(r[1])
                    stale = (st.st_mtime_ns != r[8]) or (st.st_size != r[9])
                out.append({
                    "table": r[0], "path": r[1], "fmt": r[2],
                    "staged_at": jsonable(r[3]), "last_used": jsonable(r[4]),
                    "rows": r[5], "bytes": int(r[6] or 0),
                    "source_missing": not exists, "source_changed": stale,
                })
            return out

    def staged_total_bytes(self) -> int:
        """Real bytes on disk, not the sum of per-table estimates.

        This is the number that answers "what is this tool holding on to", so it should be the file
        the user could go and delete, not an accounting artifact.
        """
        return self._db_bytes()

    def purge_staged(self, tables: Sequence[str] | None = None, all_: bool = False,
                     reason: str = "manual") -> dict[str, Any]:
        """Drop staged tables — explicitly, by age, or under size pressure.

        Staged data is a copy of someone's data sitting on a laptop, so it ages out on a clock as
        well as under a size budget; a 20 GB LRU alone would keep a large feed indefinitely as long
        as the total stayed small.
        """
        dropped: list[str] = []
        with self.con.cursor() as cur:
            rows = cur.execute(
                "SELECT table_name, path, bytes, last_used, source_token, mtime_ns, size "
                "FROM _sift_sources"
            ).fetchall()
            entries = [
                stage.StagedEntry(table_name=r[0], path=r[1], bytes=int(r[2] or 0),
                                  last_used=r[3] or dt.datetime.now(), source_token=r[4])
                for r in rows
            ]
            if all_:
                targets = [e.table_name for e in entries]
            elif tables:
                targets = list(tables)
            else:
                budget = int(os.environ.get("SIFT_STAGE_BUDGET_GB", 20)) * stage.GB
                max_age = int(os.environ.get("SIFT_STAGE_MAX_AGE_DAYS",
                                             stage.DEFAULT_MAX_AGE_DAYS))
                aged, over = stage.select_for_purge(
                    entries, dt.datetime.now(), budget_bytes=budget, max_age_days=max_age
                )
                targets = list(aged) + list(over)
                # A staged copy of a file that has since changed on disk is simply wrong.
                for r in rows:
                    if not os.path.exists(r[1]):
                        continue
                    st = os.stat(r[1])
                    if (st.st_mtime_ns != r[5] or st.st_size != r[6]) and r[0] not in targets:
                        targets.append(r[0])

            for name in targets:
                if name in self.tables:
                    continue  # never yank the table out from under an open tab
                cur.execute(f"DROP TABLE IF EXISTS {q(name)}")
                cur.execute("DELETE FROM _sift_sources WHERE table_name = ?", [name])
                dropped.append(name)
            if dropped:
                log.info("purged %d staged table(s) (%s): %s", len(dropped), reason,
                         ", ".join(dropped))
                self.emit({"type": "purged", "tables": dropped, "reason": reason})
            return {"dropped": dropped, "staged_bytes": self.staged_total_bytes()}

    def sweep_spill(self) -> int:
        """Delete browser-drop copies left behind by a previous run."""
        n = 0
        try:
            for entry in os.listdir(SPILL_DIR):
                p = os.path.join(SPILL_DIR, entry)
                shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.unlink(p)
                n += 1
        except OSError:
            pass
        return n

    # ------------------------------------------------------------- joins

    def join_probe(self, left: str, right: str, on: Sequence[str]) -> dict[str, Any]:
        """How well two tables actually join on these keys.

        This one number prevents more bad analyses than any other feature here: "1,204 of 1,318
        match (91.4%)" tells you immediately whether the key is right.
        """
        lt, rt = self.table(left), self.table(right)
        for c in on:
            if c not in lt.cols:
                raise SiftError(f"No column {c!r} in {left}.")
            if c not in rt.cols:
                raise SiftError(f"No column {c!r} in {right}.")
        keys = ", ".join(q(c) for c in on)
        with self.con.cursor() as cur:
            try:
                ldist = cur.execute(
                    f"SELECT count(*) FROM (SELECT DISTINCT {keys} FROM {q(left)})"
                ).fetchone()[0]
                matched = cur.execute(
                    f"SELECT count(*) FROM (SELECT DISTINCT {keys} FROM {q(left)}) a "
                    f"SEMI JOIN (SELECT DISTINCT {keys} FROM {q(right)}) b USING ({keys})"
                ).fetchone()[0]
                ldist, matched = int(ldist), int(matched)
                return {"left": left, "right": right, "on": list(on),
                        "left_distinct": ldist, "matched": matched,
                        "unmatched": ldist - matched,
                        "pct": (matched / ldist) if ldist else 0.0}
            except duckdb.Error as exc:
                raise SiftError(_clean_duckdb_error(exc)) from exc

    def unmatched_keys(self, left: str, right: str, on: Sequence[str],
                       limit: int = 200) -> dict[str, Any]:
        keys = ", ".join(q(c) for c in on)
        with self.con.cursor() as cur:
            cur.execute(
                f"SELECT * FROM (SELECT DISTINCT {keys} FROM {q(left)}) a "
                f"ANTI JOIN (SELECT DISTINCT {keys} FROM {q(right)}) b USING ({keys}) "
                f"LIMIT ?", [int(limit)]
            )
            return rows_payload(cur.description, cur.fetchall())

    def join_candidates(self, left: str, right: str) -> list[dict[str, Any]]:
        """Propose keys by name match plus type compatibility."""
        lt, rt = self.table(left), self.table(right)
        rcols = rt.cols
        return [{"col": name, "left_type": lc.type, "right_type": rcols[name].type,
                 "compatible": lc.kind == rcols[name].kind}
                for name, lc in lt.cols.items() if name in rcols]

    _JOINS = {"inner": "JOIN", "left": "LEFT JOIN", "right": "RIGHT JOIN", "full": "FULL JOIN"}

    def merge(self, left: str, right: str, on: Sequence[str], how: str = "inner",
              name: str | None = None) -> Table:
        """Blend two open tables into a NEW source (a view) that shows up in the sidebar.

        A view, not a copy: instant, no duplication, and it can be Exported to materialize it. The
        right side's key columns are dropped (USING-style) so the join keys aren't duplicated; any
        other name clash is disambiguated by DuckDB's usual `right.col` — surfaced as-is.
        """
        lt, rt = self.table(left), self.table(right)
        join = self._JOINS.get(how.lower())
        if join is None:
            raise SiftError(f"Unknown join type {how!r}.")
        if not on:
            raise SiftError("Pick at least one key column to join on.")
        for c in on:
            if c not in lt.cols:
                raise SiftError(f"No column {c!r} in {left}.")
            if c not in rt.cols:
                raise SiftError(f"No column {c!r} in {right}.")

        with self.lock:
            base = sanitize_table_name(name or f"{left}_{right}", set(self.tables))
        keys = ", ".join(q(c) for c in on)
        # SELECT * with USING keeps one copy of each key and both tables' other columns.
        select = f"SELECT * FROM {q(left)} {join} {q(right)} USING ({keys})"

        with self.con.cursor() as cur:
            cur.execute(f"CREATE OR REPLACE VIEW {q(base)} AS {select}")
            cols = tuple(Column.of(r[0], r[1])
                         for r in cur.execute(f"DESCRIBE {q(base)}").fetchall())
            n = int(cur.execute(f"SELECT count(*) FROM {q(base)}").fetchone()[0])

        spec = SourceSpec(
            key=SourceKey(path=f"merge://{left}+{right}", mtime_ns=0, size=0),
            fmt="merge", read_fn="", columns=cols, row_count=n,
        )
        t = Table(name=base, spec=spec, qspec=QuerySpec(relation=base), row_count=n)
        t.notes.append(f"{how} join of {left} + {right} on {', '.join(on)} — a view; "
                       f"Export it to save a copy")
        with self.lock:
            self.tables[base] = t
        # Profile it eagerly like any freshly-opened source, then announce it.
        self.compute_profile(base)
        self.emit({"type": "opened", "table": base})
        return t

    def unstage(self, name: str) -> Table:
        """Drop a staged table and go back to reading the source in place."""
        t = self.table(name)
        if not t.staged:
            return t
        with self.con.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS {q(t.name)}")
            cur.execute(src.create_view_sql(t.name, t.spec))
            cur.execute("DELETE FROM _sift_sources WHERE table_name = ?", [t.name])
        t.staged = False
        t._sortkey = None
        t.profile = None
        self.compute_profile(name)
        self.emit({"type": "state", "table": name})
        return t

    # ------------------------------------------------------------- export

    def export(self, name: str, dest: str, fmt: str = "parquet",
               overwrite: bool = False) -> dict[str, Any]:
        """Write the current result to disk.

        The one place Sift writes anything. Runs on the engine connection with SQL built here —
        never text from the SQL box — so COPY can never be reached from user input.
        """
        t = self.table(name)
        dest = os.path.abspath(os.path.expanduser(dest))
        if os.path.exists(dest) and not overwrite:
            raise SiftError(f"{dest} already exists. Tick overwrite to replace it.")
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        if t.sql_mode and t.sql_text:
            assert_select_only(t.sql_text)
            inner, params = f"SELECT * FROM (\n{t.sql_text.strip()}\n) AS _q", []
        else:
            inner, params = sqlgen.page_sql(t.qspec, t.cols, q(t.name), 2 ** 62, 0)
        opts = EXPORT_FORMATS.get(fmt.lower(), (None,))[0]
        if opts is None:
            raise SiftError(f"Unsupported export format {fmt!r}.")
        try:
            with self.con.cursor() as cur:
                started = time.perf_counter()
                cur.execute(f"COPY ({inner}) TO '{dest.replace(chr(39), chr(39) * 2)}' {opts}", params)
                return {"dest": dest, "format": fmt,
                        "bytes": os.path.getsize(dest) if os.path.exists(dest) else 0,
                        "ms": round((time.perf_counter() - started) * 1000, 1)}
        except duckdb.Error as exc:
            raise SiftError(_clean_duckdb_error(exc)) from exc

    # ------------------------------------------------------------- misc

    def close_table(self, name: str) -> None:
        t = self.table(name)
        try:
            with self.con.cursor() as cur:
                if t._sortkey:
                    cur.execute(f"DROP TABLE IF EXISTS {q(t._sortkey)}")
                if t.staged:
                    cur.execute("UPDATE _sift_sources SET last_used = now() WHERE table_name = ?",
                                [name])
                else:
                    cur.execute(f"DROP VIEW IF EXISTS {q(name)}")
                # A browser-drop copy has no life beyond its tab.
                if t.copied_from_browser:
                    d = os.path.dirname(t.spec.key.path)
                    if os.path.commonpath([SPILL_DIR, d]) == SPILL_DIR:
                        shutil.rmtree(d, ignore_errors=True)
        finally:
            with self.lock:
                self.tables.pop(name, None)   # must run even if the drop errors
        self.emit({"type": "closed", "table": name})

    def state(self) -> dict[str, Any]:
        with self.lock:
            tables = [t.summary() for t in self.tables.values()]
        return {"tables": tables, "engine": self.engine_info()}

    def shutdown(self) -> None:
        self.pool.shutdown(wait=False, cancel_futures=True)
        try:
            self.con.close()
        except Exception:
            pass
        self.drop_private_store()

    def drop_private_store(self) -> None:
        """Remove a fallback store. Safe to call from the parent-death watcher.

        Kept separate from shutdown() because that path exits the process immediately with
        os._exit, which skips normal teardown. _sweep_private_stores() also catches leftovers on the
        next launch, so this is tidiness rather than the only line of defence.
        """
        if self.shared_store:
            return
        for p in (self.db_path, self.db_path + ".wal"):
            try:
                os.unlink(p)
            except OSError:
                pass


def _clean_duckdb_error(exc: Exception) -> str:
    """First line of a DuckDB error, which is the part a human can act on."""
    msg = str(exc).strip()
    first = msg.split("\n")[0]
    return first[:400] if first else "Query failed."
