"""Turning a path into a queryable relation.

Format detection, CSV sniffing, parquet/Delta metadata, xlsx sheet enumeration, and row estimation.

Functions that need to ask DuckDB something take a connection as their first argument; the rest are
pure. Nothing here holds state.
"""
from __future__ import annotations

import dataclasses
import glob as globmod
import os
import re
from pathlib import Path
from typing import Any, Sequence

from .ident import q, qlit
from .types import (
    COMPRESSION_EXT, CSV_EXT, JSON_EXT, NDJSON_EXT, PARQUET_EXT, XLS_EXT, XLSX_EXT,
    Column, Fmt, RowEstimate, SheetInfo, SourceKey, SourceSpec,
)

# sniff_csv reports an absent quote/escape/comment as this literal string. Passing it back into
# read_csv fails with "the quote option cannot exceed a size of 1 byte" — measured on 1.5.5.
SNIFF_EMPTY = "(empty)"


class UnsupportedSource(ValueError):
    """The path is a format Sift cannot open, with a message aimed at the user."""


class LegacyXls(UnsupportedSource):
    pass


def _ext_chain(path: str) -> tuple[str, bool]:
    """Return (data extension, is_compressed), seeing through a compression suffix."""
    p = Path(path)
    compressed = p.suffix.lower() in COMPRESSION_EXT
    if compressed:
        p = Path(p.stem)
    return p.suffix.lower(), compressed


def is_delta_dir(path: str) -> bool:
    """A Delta table is a directory carrying a _delta_log/.

    Why this check exists at all: globbing a Delta table's parquet files is *wrong*. The log's
    `remove` actions tombstone files that are still physically present, so a raw glob resurrects
    deleted rows and double-counts updated ones. Measured on a two-version fixture: raw glob 150
    rows, delta_scan 100. That failure looks like a data bug, not a tool bug, which is exactly why
    it has to be caught here.
    """
    return os.path.isdir(os.path.join(path, "_delta_log"))


def detect_format(path: str) -> Fmt:
    """Classify a path by magic bytes first, extension second.

    Magic bytes win because a `.csv` that is really an Excel file (or an HTML error page saved with
    the wrong name) is a genuinely common way to receive data.
    """
    if os.path.isdir(path):
        if is_delta_dir(path):
            return "delta"
        if _first_glob(path, PARQUET_EXT):
            return "glob_parquet"
        if _first_glob(path, CSV_EXT):
            return "glob_csv"
        raise UnsupportedSource(
            f"{os.path.basename(path)} is a folder with no .parquet or .csv files in it."
        )

    head = b""
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError as exc:
        raise UnsupportedSource(f"Cannot read {path}: {exc}") from exc

    if head.startswith(b"PAR1"):
        return "parquet"
    if head.startswith(b"\xd0\xcf\x11\xe0"):
        # OLE2 container: legacy .xls (or .doc/.ppt). read_xlsx cannot touch it and neither can
        # openpyxl; xlrd would be a whole extra dependency for a format on its way out.
        raise LegacyXls(
            f"{os.path.basename(path)} is a legacy .xls file. Open it and re-save as .xlsx — "
            "Sift reads the modern format only."
        )
    if head.startswith(b"PK\x03\x04"):
        # A zip container. .xlsx is the case we care about; anything else is not tabular.
        ext, _ = _ext_chain(path)
        if ext in XLSX_EXT:
            return "xlsx"
        raise UnsupportedSource(
            f"{os.path.basename(path)} looks like a zip archive, not a data file."
        )

    ext, compressed = _ext_chain(path)
    if ext in PARQUET_EXT:
        return "parquet"
    if ext in NDJSON_EXT:
        return "ndjson"
    if ext in JSON_EXT:
        return "json"
    if ext in XLSX_EXT:
        return "xlsx"
    if ext in XLS_EXT:
        raise LegacyXls(
            f"{os.path.basename(path)} is a legacy .xls file. Re-save it as .xlsx."
        )
    if ext in CSV_EXT:
        return "csv"

    # No usable extension. Sniff the first bytes for JSON, else assume delimited text — DuckDB's
    # sniffer is good enough that guessing CSV is a reasonable last resort.
    stripped = head.lstrip()
    if stripped[:1] in (b"{", b"["):
        return "json"
    return "csv"


def _first_glob(directory: str, exts: set[str]) -> str | None:
    for ext in sorted(exts):
        hits = globmod.glob(os.path.join(glob_escape(directory), "**", f"*{ext}"), recursive=True)
        if hits:
            return min(hits)
    return None


def glob_escape(path: str) -> str:
    """Escape glob metacharacters in a literal directory path.

    A folder named "data[2026]" would otherwise be interpreted as a character class and silently
    match nothing.
    """
    return re.sub(r"([\[\]*?])", r"[\1]", path)


# ----------------------------------------------------------------- CSV sniffing


def _unsniff(value: Any) -> Any:
    return "" if value == SNIFF_EMPTY else value  # sentinel -> real empty string, see SNIFF_EMPTY


def sniff_csv(con, path: str, sample_size: int = 20480) -> dict[str, Any]:
    """Ask DuckDB to detect dialect and column types, reading only the head of the file.

    For sources small enough that a full pass is free we sniff the *whole* file
    (`sample_size=-1`). That closes the most common failure in this tool's problem space: types
    inferred from the first 20k rows, and row 400,000 disagrees.
    """
    args = f"sample_size={int(sample_size)}" if sample_size > 0 else "sample_size=-1"
    cur = con.execute(f"FROM sniff_csv({qlit(path)}, {args})")
    row = cur.fetchone()
    if row is None:
        raise UnsupportedSource(f"DuckDB could not detect a CSV dialect for {path}.")
    raw = dict(zip([d[0] for d in cur.description], row))
    return {
        "delim": _unsniff(raw.get("Delimiter")),
        "quote": _unsniff(raw.get("Quote")),
        "escape": _unsniff(raw.get("Escape")),
        "comment": _unsniff(raw.get("Comment")),
        "skip": int(raw.get("SkipRows") or 0),
        "header": bool(raw.get("HasHeader")),
        "columns": [
            {"name": c["name"], "type": c["type"]} for c in (raw.get("Columns") or [])
        ],
        "prompt": raw.get("Prompt"),
    }


FULL_SNIFF_MAX_BYTES = 50 * 1024 * 1024  # under this, sniff the whole file — it's free

# Under this, a real count(*) is fast enough to do at open time, which beats any estimate. Above
# it, estimate for first paint and let session.py fire the exact count in the background.
EXACT_COUNT_MAX_BYTES = 64 * 1024 * 1024


def exact_count(con, spec: SourceSpec) -> int:
    """True row count, counted against the all-varchar relation for text formats.

    Counting the *typed* relation would be wrong. Measured on DuckDB 1.5.5: with an uncastable
    value present, `count(*)` on the typed view is answered by projection pushdown without parsing
    any column, so it reports the physical count while `SELECT *` returns fewer rows — the grid
    total would disagree with the grid contents. The all-varchar relation never casts, so its
    count(*) is the physical truth and matches what all-varchar mode displays.
    """
    rel = read_expr(spec, all_varchar=supports_all_varchar(spec))
    return int(con.execute(f"SELECT count(*) FROM {rel}").fetchone()[0])


# ------------------------------------------------------------ parquet and delta


def parquet_footer(con, target: str) -> dict[str, Any]:
    """Exact row count and row-group layout from the footer — no data pages read."""
    row = con.execute(
        f"SELECT sum(num_rows)::BIGINT, sum(num_row_groups)::BIGINT, count(*)::BIGINT "
        f"FROM parquet_file_metadata({qlit(target)})"
    ).fetchone()
    return {
        "num_rows": int(row[0] or 0),
        "num_row_groups": int(row[1] or 0),
        "num_files": int(row[2] or 0),
    }


def delta_version(path: str) -> int | None:
    """Latest committed version, read from the _delta_log filenames."""
    try:
        names = os.listdir(os.path.join(path, "_delta_log"))
    except OSError:
        return None
    versions = [int(m.group(1)) for m in map(re.compile(r"(\d{20})\.json").fullmatch, names) if m]
    return max(versions, default=None)


# ------------------------------------------------------------------ hive layout


HIVE_KV = re.compile(r"([^/=]+)=([^/]+)")


def hive_keys(directory: str, files: Sequence[str]) -> tuple[str, ...]:
    """Partition keys, but only if EVERY file carries the identical key set.

    DuckDB errors out on `hive_partitioning := true` when the layout is inconsistent, so a
    half-partitioned directory must be read as a plain glob instead.
    """
    keysets = []
    for f in files:
        rel = os.path.relpath(f, directory)
        keysets.append(tuple(k for k, _ in HIVE_KV.findall(os.path.dirname(rel))))
    if not keysets or not keysets[0]:
        return ()
    return keysets[0] if len(set(keysets)) == 1 else ()


# ---------------------------------------------------------------- xlsx sheets


def list_sheets(path: str) -> tuple[SheetInfo, ...]:
    """Enumerate sheets with dimensions, without parsing cells.

    openpyxl's read_only mode reads the worksheet dimension record rather than the cells, so this
    stays fast on a large workbook. DuckDB's read_xlsx can read a *named* sheet but offers no way
    to list them, which is the entire reason openpyxl is a dependency.
    """
    import openpyxl

    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        return tuple(
            SheetInfo(name=ws.title, rows=int(ws.max_row or 0), cols=int(ws.max_column or 0))
            for ws in wb.worksheets
        )
    finally:
        wb.close()


# ------------------------------------------------------------- row estimation


def estimate_rows(
    path: str, header_bytes: int = 0, chunks: int = 3, chunk_bytes: int = 262_144
) -> RowEstimate:
    """Estimate row count from byte samples, in a few milliseconds regardless of file size.

    An exact `count(*)` on a multi-GB CSV is a full parallel parse (seconds), which is far too slow
    for first paint. So sample three windows, average bytes-per-row, and extrapolate.

    Confidence is `low` whenever a quote character appears anywhere in the sample: a quoted field
    containing a newline makes line-counting overshoot, and there is no cheap way to tell how often
    that happens. The UI shows low-confidence estimates with visible uncertainty rather than
    pretending.
    """
    size = os.path.getsize(path)
    data_bytes = max(0, size - header_bytes)
    if data_bytes <= 0:
        return RowEstimate(0, "exact", "file has no data past the header")

    # Small enough to read entirely. Even then the answer is only exact if nothing is quoted:
    # a quoted field containing a newline makes physical lines exceed logical rows. Callers should
    # prefer exact_count() at this size — this branch stays honest for when they don't.
    if data_bytes <= chunks * chunk_bytes:
        with open(path, "rb") as f:
            f.seek(header_bytes)
            buf = f.read()
        n = buf.count(b"\n")
        if buf and not buf.endswith(b"\n"):
            n += 1
        if b'"' in buf:
            return RowEstimate(
                n, "low",
                f"counted {n:,} line breaks in {size:,} B, but quote characters are present so "
                f"some may be inside quoted fields",
            )
        return RowEstimate(n, "exact", f"counted every byte ({size:,} B)")

    step = (data_bytes - chunk_bytes) / max(1, chunks - 1)
    lines = sampled = quotes = 0
    with open(path, "rb") as f:
        for i in range(chunks):
            off = header_bytes + int(i * step)
            f.seek(off)
            buf = f.read(chunk_bytes)
            if not buf:
                continue
            if i > 0:  # drop the leading partial line
                nl = buf.find(b"\n")
                if nl == -1:
                    continue
                buf = buf[nl + 1 :]
            nl = buf.rfind(b"\n")  # drop the trailing partial line
            if nl == -1:
                continue
            buf = buf[: nl + 1]
            lines += buf.count(b"\n")
            sampled += len(buf)
            quotes += buf.count(b'"')

    if lines == 0 or sampled == 0:
        return RowEstimate(0, "low", "sampling found no line breaks")

    bytes_per_row = sampled / lines
    rows = int(data_bytes / bytes_per_row)
    kib = chunk_bytes // 1024
    if quotes == 0:
        return RowEstimate(rows, "high", f"{chunks}x{kib}KiB sample, no quote characters seen")
    return RowEstimate(
        rows,
        "low",
        f"{chunks}x{kib}KiB sample; {quotes:,} quote characters seen, so quoted newlines "
        f"may inflate this",
    )


def header_byte_offset(path: str, sniff: dict[str, Any]) -> int:
    """Bytes occupied by skipped rows plus the header, so estimation starts at real data."""
    skip = int(sniff.get("skip") or 0) + (1 if sniff.get("header") else 0)
    if skip <= 0:
        return 0
    seen = 0
    with open(path, "rb") as f:
        for _ in range(skip):
            line = f.readline()
            if not line:
                break
            seen += len(line)
    return seen


# --------------------------------------------------------------- building specs


def build_source(con, path: str, sheet: str | None = None) -> SourceSpec:
    """Resolve a path into everything needed to query it, reading as little as possible."""
    path = os.path.realpath(path)
    st = os.stat(path)
    # A directory's st_mtime_ns changes when children are added — the invalidation signal we
    # want for glob/Delta sources too.
    key = SourceKey(path=path, mtime_ns=st.st_mtime_ns, size=st.st_size)
    fmt = detect_format(path)

    if fmt == "parquet":
        meta = parquet_footer(con, path)
        cols = _describe(con, f"read_parquet({qlit(path)})")
        return SourceSpec(key=key, fmt=fmt, read_fn="read_parquet", columns=cols,
                          row_count=meta["num_rows"])

    if fmt == "delta":
        cols = _describe(con, f"delta_scan({qlit(path)})")
        return SourceSpec(key=key, fmt=fmt, read_fn="delta_scan", columns=cols,
                          delta_version=delta_version(path))

    if fmt in ("glob_parquet", "glob_csv"):
        ext = ".parquet" if fmt == "glob_parquet" else ".csv"
        pattern = os.path.join(glob_escape(path), "**", f"*{ext}")
        files = sorted(globmod.glob(pattern, recursive=True))
        keys = hive_keys(path, files)
        args: dict[str, Any] = {"union_by_name": True, "filename": True}
        if keys:
            args["hive_partitioning"] = True
        fn = "read_parquet" if fmt == "glob_parquet" else "read_csv"
        # DESCRIBE only the first file: with union_by_name DuckDB would open every footer, which
        # is seconds on a few thousand files. session.py refines the union schema in the background.
        cols = _describe(con, f"{fn}({qlit(files[0])})") if files else ()
        row_count = parquet_footer(con, pattern)["num_rows"] if fmt == "glob_parquet" else None
        return SourceSpec(key=key, fmt=fmt, read_fn=fn, read_args=args, columns=cols,
                          row_count=row_count, glob=pattern)

    if fmt == "xlsx":
        sheets = list_sheets(path)
        chosen = sheet or next((s.name for s in sheets if not s.empty),
                              sheets[0].name if sheets else None)
        if chosen is None:
            raise UnsupportedSource(f"{os.path.basename(path)} has no sheets.")
        args = {"sheet": chosen}
        cols = _describe(con, f"read_xlsx({qlit(path)}, sheet={qlit(chosen)})")
        rows = next((s.rows for s in sheets if s.name == chosen), None)
        return SourceSpec(key=key, fmt=fmt, read_fn="read_xlsx", read_args=args, columns=cols,
                          sheet=chosen, sheets=sheets,
                          row_count=max(0, rows - 1) if rows else None)

    if fmt in ("json", "ndjson"):
        cols = _describe(con, f"read_json_auto({qlit(path)})")
        _, compressed = _ext_chain(path)
        spec = SourceSpec(key=key, fmt=fmt, read_fn="read_json_auto", columns=cols,
                          compressed=compressed)
        if key.size <= EXACT_COUNT_MAX_BYTES:
            spec = dataclasses.replace(spec, row_count=exact_count(con, spec))
        return spec

    # CSV
    _, compressed = _ext_chain(path)
    sample = -1 if (not compressed and key.size <= FULL_SNIFF_MAX_BYTES) else 20480
    sn = sniff_csv(con, path, sample_size=sample)
    cols = tuple(Column.of(c["name"], c["type"]) for c in sn["columns"])
    args: dict[str, Any] = {
        "delim": sn["delim"],
        "quote": sn["quote"],
        "escape": sn["escape"],
        "header": sn["header"],
        "skip": sn["skip"],
        "columns": {c.name: c.type for c in cols},
        # Non-negotiable for a browsing tool: without this, one uncastable value 29,000 rows in
        # raises a ConversionException the moment the user scrolls or aggregates that far, and the
        # grid dies mid-session. With it, the row is dropped instead — which would be *worse* if
        # it were silent, so Sift independently counts and displays every dropped row via
        # sqlgen.bad_row_count_sql / bad_rows_sql against the all-varchar relation.
        "ignore_errors": True,
        # DuckDB's default (true) reads a QUOTED empty field `""` as NULL, making it
        # indistinguishable from a genuinely absent value. That destroys the distinction this tool
        # exists to show — the grid renders NULL and '' differently on purpose, and the profile
        # counts them separately. A viewer should report what is actually in the file, so:
        #   ,,      -> NULL   (nothing there)
        #   ,"",    -> ''     (an empty string was written deliberately)
        "allow_quoted_nulls": False,
    }
    if sn["comment"]:
        args["comment"] = sn["comment"]
    spec = SourceSpec(key=key, fmt="csv", read_fn="read_csv", read_args=args, columns=cols,
                      compressed=compressed, sniff_prompt=sn["prompt"])

    if not compressed and key.size <= EXACT_COUNT_MAX_BYTES:
        # Cheap enough to be certain. Beats an estimate, and in particular gets quoted-newline
        # files right, where line counting overshoots.
        spec = dataclasses.replace(spec, row_count=exact_count(con, spec))
    elif not compressed:
        spec = dataclasses.replace(
            spec, row_estimate=estimate_rows(path, header_byte_offset(path, sn))
        )
    # Compressed CSV gets neither: compressed bytes say nothing about row count, so the UI shows a
    # live "counting…" spinner instead of a fabricated number.
    return spec


def _describe(con, relation_expr: str) -> tuple[Column, ...]:
    rows = con.execute(f"DESCRIBE SELECT * FROM {relation_expr}").fetchall()
    return tuple(Column.of(r[0], r[1]) for r in rows)


def _fmt_arg(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, dict):
        inner = ", ".join(f"{qlit(k)}: {qlit(v)}" for k, v in value.items())
        return "{" + inner + "}"
    return qlit(str(value))


def read_expr(spec: SourceSpec, all_varchar: bool = False) -> str:
    """The FROM-clause expression for this source.

    Options are baked in explicitly rather than relying on read_csv_auto, so no later query
    re-sniffs the file. That is the single largest first-paint win for CSV.

    With `all_varchar=True`, no casting happens at all — which is how Sift gets the *physical*
    row count and finds uncastable cells (see sqlgen.uncastable_sql). It's also the one-click
    escape hatch when the sniffer guesses a type wrong.
    """
    args = dict(spec.read_args)
    if all_varchar:
        args.pop("columns", None)
        if spec.read_fn in ("read_csv", "read_xlsx"):
            args["all_varchar"] = True
    parts = [qlit(spec.target)] + [f"{k}={_fmt_arg(v)}" for k, v in args.items()]
    return f"{spec.read_fn}({', '.join(parts)})"


def read_expr_at(spec: SourceSpec, version: int) -> str:
    """Delta time travel. Measured: `version => n` works, `AT (VERSION => n)` does not parse."""
    if spec.fmt != "delta":
        raise ValueError("time travel only applies to Delta tables")
    return f"delta_scan({qlit(spec.target)}, version={int(version)})"


def supports_all_varchar(spec: SourceSpec) -> bool:
    """Only text-ish sources can produce cast failures.

    Parquet and Delta carry real types in their metadata, so there is no sniffing to get wrong and
    no reject count to compute — physical rows always equal typed rows.
    """
    return spec.fmt in ("csv", "glob_csv", "xlsx")


def create_view_sql(name: str, spec: SourceSpec, all_varchar: bool = False) -> str:
    return f"CREATE OR REPLACE VIEW {q(name)} AS SELECT * FROM {read_expr(spec, all_varchar)}"
