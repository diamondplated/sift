"""Identifier handling: filename -> table name, and safe quoting.

Pure. The rule this module exists to enforce: **identifiers are quoted, values are parameterized.**
Nothing in Sift ever interpolates a user value into SQL text.
"""
from __future__ import annotations

import re
import unicodedata
from pathlib import Path
from typing import Collection

from .types import COMPRESSION_EXT, DATA_EXT   # one source of truth for what Sift recognizes

_NAME_MAX = 60  # leaves room for a "_2" collision suffix inside DuckDB's generous limit


def q(identifier: str) -> str:
    """Quote an identifier for DuckDB, doubling embedded quotes."""
    return '"' + str(identifier).replace('"', '""') + '"'


def qlit(value: str) -> str:
    """Single-quote a string literal, doubling embedded quotes. Only for read_csv/read_parquet
    *option* values (a delimiter, a sheet name) which cannot be bound as parameters. Never for
    user data — that goes through placeholders."""
    return "'" + str(value).replace("'", "''") + "'"


def strip_data_extensions(filename: str) -> str:
    """Drop a trailing compression extension and then a data extension."""
    p = Path(filename)
    if p.suffix.lower() in COMPRESSION_EXT:
        p = Path(p.stem)
    if p.suffix.lower() in DATA_EXT:
        p = Path(p.stem)
    return p.name


def sanitize_table_name(filename: str, taken: Collection[str] = ()) -> str:
    """Derive a lowercase SQL-safe table name from a filename or directory name:
    '2026 Sales (final).csv' -> 't_2026_sales_final'; collisions get a _2 suffix."""
    stem = strip_data_extensions(str(filename).strip().rstrip("/"))

    # NFKD then drop combining marks, so "Ünïcode" degrades to "unicode" rather than vanishing.
    stem = unicodedata.normalize("NFKD", stem)
    stem = "".join(c for c in stem if not unicodedata.combining(c))
    stem = stem.encode("ascii", "ignore").decode("ascii").lower()

    stem = re.sub(r"[^a-z0-9_]+", "_", stem)
    stem = re.sub(r"_+", "_", stem).strip("_")

    if not stem:
        stem = "data"
    if stem[0].isdigit():
        # Not a legal unquoted identifier, and copy-as-pandas snippets show unquoted names.
        stem = "t_" + stem
    stem = stem[:_NAME_MAX].rstrip("_")

    taken_lower = {t.lower() for t in taken}
    if stem not in taken_lower:
        return stem
    for i in range(2, 1000):
        cand = f"{stem}_{i}"
        if cand not in taken_lower:
            return cand
    raise ValueError(f"cannot find a free table name for {filename!r}")
