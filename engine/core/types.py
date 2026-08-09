"""Shared value types for Sift. Pure: no duckdb, no fastapi, no I/O, so everything here
stays testable without a connection or a server."""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from typing import Any, Literal

Kind = Literal["number", "text", "temporal", "bool", "nested", "blob", "other"]
Fmt = Literal["csv", "parquet", "json", "ndjson", "xlsx", "delta", "glob_parquet", "glob_csv",
              "merge"]   # "merge" is a derived view over two other tables, not a file on disk
Confidence = Literal["exact", "high", "low"]
Op = Literal[
    "=", "!=", "<", "<=", ">", ">=", "in", "not_in",
    "contains", "is_null", "not_null", "is_empty", "between",
]

# Ops that carry no values: the UI renders no input, where_clause() binds nothing.
NULLARY_OPS = frozenset({"is_null", "not_null", "is_empty"})

# The extensions Sift recognizes, defined ONCE. source.py uses the per-format sets to detect a
# format; ident.py strips DATA_EXT + COMPRESSION_EXT to derive a table name. Kept together so the
# two never drift (they had: .br and .tab were each in only one of the old copies).
CSV_EXT = {".csv", ".tsv", ".txt", ".psv", ".tab"}
PARQUET_EXT = {".parquet", ".parq", ".pq"}
NDJSON_EXT = {".ndjson", ".jsonl"}
JSON_EXT = {".json"}
XLSX_EXT = {".xlsx", ".xlsm"}
XLS_EXT = {".xls"}
COMPRESSION_EXT = {".gz", ".gzip", ".zst", ".zstd", ".bz2", ".xz", ".br"}
DATA_EXT = CSV_EXT | PARQUET_EXT | NDJSON_EXT | JSON_EXT | XLSX_EXT | XLS_EXT


def kind_of(duckdb_type: str) -> Kind:
    """Classify a DuckDB type string into the buckets the UI branches on (alignment,
    histogram-vs-top-N, cell rendering). Deliberately coarse; the exact string is kept for display.
    """
    t = (duckdb_type or "").strip().upper()
    # Nesting first — ordering is load-bearing: STRUCT(a INTEGER) contains the word INTEGER.
    if t == "JSON" or t.endswith("]") or t.startswith(("STRUCT", "MAP", "UNION", "LIST", "ARRAY")):
        return "nested"
    if t in ("BLOB", "BYTEA", "BINARY", "VARBINARY", "BIT"):
        return "blob"
    if t == "BOOLEAN":
        return "bool"
    if t.startswith(("TIMESTAMP", "DATE", "TIME", "INTERVAL")):
        return "temporal"
    if t.startswith("DECIMAL") or t.startswith("NUMERIC") or t in (
        "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "REAL", "DOUBLE",
    ):
        return "number"
    if t in ("VARCHAR", "CHAR", "TEXT", "STRING", "UUID") or t.startswith("ENUM"):
        return "text"
    return "other"


def needs_string_transport(duckdb_type: str) -> bool:
    """True when values must be JSON-encoded as strings to survive JS: ints wider than 2**53-1
    (the browser silently rounds order ids) and decimals."""
    t = (duckdb_type or "").strip().upper()
    return t in ("BIGINT", "HUGEINT", "UBIGINT", "UHUGEINT") or t.startswith(("DECIMAL", "NUMERIC"))


@dataclass(frozen=True)
class SourceKey:
    """Identity of a file at a point in time. Deliberately (path, mtime, size), not a content
    hash — hashing 10 GB to decide whether a cache entry is warm defeats the purpose."""
    path: str
    mtime_ns: int
    size: int

    def token(self) -> str:
        return f"{self.path}:{self.mtime_ns}:{self.size}"


@dataclass(frozen=True)
class RowEstimate:
    rows: int
    confidence: Confidence
    basis: str  # human-readable, shown on hover: "3x256KiB sample, no quotes seen"


@dataclass(frozen=True)
class Column:
    name: str
    type: str
    kind: Kind = "other"

    @staticmethod
    def of(name: str, type_: str) -> "Column":
        return Column(name=name, type=type_, kind=kind_of(type_))


@dataclass(frozen=True)
class SheetInfo:
    name: str
    rows: int
    cols: int

    @property
    def empty(self) -> bool:
        # openpyxl reports a blank sheet as 1x1 with a None cell; treat <=1 row as nothing to see.
        return self.rows <= 1 or self.cols < 1


@dataclass(frozen=True)
class SourceSpec:
    """Everything needed to build a relation over a file, without re-sniffing it."""
    key: SourceKey
    fmt: Fmt
    read_fn: str                      # read_csv | read_parquet | read_json_auto | read_xlsx | delta_scan
    read_args: dict[str, Any] = field(default_factory=dict)
    columns: tuple[Column, ...] = ()
    row_count: int | None = None      # exact and free (parquet footer, delta log)
    row_estimate: RowEstimate | None = None
    compressed: bool = False
    sheet: str | None = None          # xlsx only
    sheets: tuple[SheetInfo, ...] = ()
    delta_version: int | None = None
    sniff_prompt: str | None = None   # sniff_csv's own reproducible FROM clause, for display
    glob: str | None = None           # the pattern actually handed to read_parquet/read_csv

    @property
    def target(self) -> str:
        """The path or glob the read function is pointed at."""
        return self.glob or self.key.path


@dataclass(frozen=True)
class Filter:
    col: str
    op: Op
    values: tuple[Any, ...] = ()


@dataclass(frozen=True)
class QuerySpec:
    relation: str
    filters: tuple[Filter, ...] = ()
    sort: tuple[tuple[str, Literal["asc", "desc"]], ...] = ()

    def without_col(self, col: str) -> "QuerySpec":
        """Drop one column's filters — the faceting rule for the distinct panel: clicking
        "West" must not make the region panel show only West."""
        return dataclasses.replace(
            self, filters=tuple(f for f in self.filters if f.col != col)
        )


@dataclass(frozen=True)
class ColumnProfile:
    name: str
    type: str
    kind: Kind
    n: int = 0
    n_null: int = 0
    n_empty: int = 0
    n_nullish: int = 0                # NA / N/A / - / ? / whitespace-only
    approx_distinct: int = 0
    exact_distinct: int | None = None
    min_s: str | None = None
    max_s: str | None = None
    avg: float | None = None
    std: float | None = None
    q25: str | None = None
    q50: str | None = None
    q75: str | None = None
    max_len: int | None = None
    n_uncastable: int = 0             # cells that fail TRY_CAST to the sniffed type
    view: Literal["topn", "hist", "highcard"] = "topn"


@dataclass(frozen=True)
class StageDecision:
    stage: bool
    reason: str
    est_seconds: float = 0.0
    needs_confirm: bool = False
