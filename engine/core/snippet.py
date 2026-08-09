"""Copy-as-code: leave Sift holding the same data in a notebook.

Pure. The point is that the snippet reproduces what is *on screen* — same dialect, same dtypes,
same filters — so a session that started as a quick look can graduate into real analysis without
re-deriving how to read the file.
"""
from __future__ import annotations

from typing import Any, Mapping, Sequence

from .source import read_expr
from .sqlgen import render_sql
from .types import Column, QuerySpec, SourceSpec

# DuckDB type -> pandas dtype. DECIMAL becomes float64 with a comment, because pandas has no
# native decimal dtype and silently using object would surprise people more.
_PANDAS_DTYPE = {
    "BOOLEAN": "boolean",
    "TINYINT": "Int8", "SMALLINT": "Int16", "INTEGER": "Int32", "BIGINT": "Int64",
    "UTINYINT": "UInt8", "USMALLINT": "UInt16", "UINTEGER": "UInt32", "UBIGINT": "UInt64",
    "HUGEINT": "Int64", "FLOAT": "float32", "REAL": "float32", "DOUBLE": "float64",
    "VARCHAR": "string", "UUID": "string",
}

_POLARS_READER = {
    "csv": "scan_csv", "glob_csv": "scan_csv",
    "parquet": "scan_parquet", "glob_parquet": "scan_parquet",
    "json": "read_json", "ndjson": "scan_ndjson",
    "delta": "scan_delta", "xlsx": "read_excel",
}


def _py(v: Any) -> str:
    if v is None or isinstance(v, (bool, int, float)):
        return repr(v)
    return repr(str(v))


def _pandas_dtypes(cols: Sequence[Column]) -> tuple[dict[str, str], list[str]]:
    dtypes, dates = {}, []
    for c in cols:
        t = c.type.upper()
        if c.kind == "temporal":
            dates.append(c.name)
        elif t.startswith(("DECIMAL", "NUMERIC")):
            dtypes[c.name] = "float64"
        elif t in _PANDAS_DTYPE:
            dtypes[c.name] = _PANDAS_DTYPE[t]
    return dtypes, dates


def _ram_warning(spec: SourceSpec) -> str:
    """pandas loads everything; DuckDB does not. Say so with a real number, not a platitude."""
    if spec.fmt not in ("csv", "glob_csv", "json", "ndjson") or spec.key.size < 200 * 1024 * 1024:
        return ""
    gb = spec.key.size / (1024 ** 3)
    return (
        f"# NOTE: {gb:,.1f} GB source. pandas materializes the whole thing — budget roughly "
        f"{gb * 2.5:,.0f} GB of RAM.\n# The duckdb snippet streams instead.\n"
    )


def _pandas_ops(spec: QuerySpec) -> str:
    """Render filters and sort as a pandas chain."""
    lines = []
    for f in spec.filters:
        col = f"df[{_py(f.col)}]"
        if f.op == "is_null":
            lines.append(f"df = df[{col}.isna()]")
        elif f.op == "not_null":
            lines.append(f"df = df[{col}.notna()]")
        elif f.op == "is_empty":
            lines.append(f"df = df[{col}.astype('string') == '']")
        elif f.op == "contains":
            lines.append(
                f"df = df[{col}.astype('string').str.contains({_py(f.values[0])}, case=False, na=False)]"
            )
        elif f.op == "between":
            lines.append(f"df = df[{col}.between({_py(f.values[0])}, {_py(f.values[1])})]")
        elif f.op == "in":
            lines.append(f"df = df[{col}.isin([{', '.join(_py(v) for v in f.values)}])]")
        elif f.op == "not_in":
            lines.append(f"df = df[~{col}.isin([{', '.join(_py(v) for v in f.values)}])]")
        elif f.values:
            op = "==" if f.op == "=" else f.op
            lines.append(f"df = df[{col} {op} {_py(f.values[0])}]")
    if spec.sort:
        by = ", ".join(_py(n) for n, _ in spec.sort)
        asc = ", ".join("False" if str(d).lower().startswith("d") else "True" for _, d in spec.sort)
        many = len(spec.sort) > 1
        lines.append(
            f"df = df.sort_values([{by}], ascending=[{asc}])" if many
            else f"df = df.sort_values({by}, ascending={asc})"
        )
    return "\n".join(lines)


def _polars_ops(spec: QuerySpec) -> str:
    parts = []
    for f in spec.filters:
        c = f"pl.col({_py(f.col)})"
        if f.op == "is_null":
            parts.append(f".filter({c}.is_null())")
        elif f.op == "not_null":
            parts.append(f".filter({c}.is_not_null())")
        elif f.op == "is_empty":
            parts.append(f".filter({c}.cast(pl.Utf8) == '')")
        elif f.op == "contains":
            parts.append(f".filter({c}.cast(pl.Utf8).str.contains({_py(f.values[0])}, literal=True))")
        elif f.op == "between":
            parts.append(f".filter({c}.is_between({_py(f.values[0])}, {_py(f.values[1])}))")
        elif f.op == "in":
            parts.append(f".filter({c}.is_in([{', '.join(_py(v) for v in f.values)}]))")
        elif f.op == "not_in":
            parts.append(f".filter(~{c}.is_in([{', '.join(_py(v) for v in f.values)}]))")
        elif f.values:
            op = "==" if f.op == "=" else f.op
            parts.append(f".filter({c} {op} {_py(f.values[0])})")
    if spec.sort:
        by = ", ".join(_py(n) for n, _ in spec.sort)
        desc = ", ".join("True" if str(d).lower().startswith("d") else "False" for _, d in spec.sort)
        parts.append(f".sort([{by}], descending=[{desc}])")
    return "".join(f"\n    {p}" for p in parts)


def snippet(
    dialect: str,
    source: SourceSpec,
    spec: QuerySpec,
    cols: Mapping[str, Column],
    sql_override: str | None = None,
) -> str:
    """Generate a runnable snippet for `dialect` in ('duckdb', 'pandas', 'polars', 'sql').

    `sql_override` is the SQL box's text when the user has taken it over — the snippet then carries
    their query verbatim rather than a reconstruction of UI state.
    """
    if dialect == "sql":
        return sql_override or render_sql(spec, cols)

    if dialect == "duckdb":
        body = sql_override or render_sql(spec, cols)
        # Point the query at the file expression rather than at Sift's in-memory table name, so it
        # runs standalone. Extensions only for the formats that require them.
        body = body.replace(f'"{spec.relation}"', read_expr(source))
        pre = {"delta": 'duckdb.sql("INSTALL delta; LOAD delta")\n',
               "xlsx": 'duckdb.sql("INSTALL excel; LOAD excel")\n'}.get(source.fmt, "")
        return (
            "import duckdb\n"
            f"{pre}"
            f'df = duckdb.sql("""\n{body}\n""").df()   # .arrow() / .pl() also work\n'
        )

    if dialect == "pandas":
        warn = _ram_warning(source)
        ops = _pandas_ops(spec)
        tail = f"\n\n{ops}" if ops else ""
        note = ("# The SQL box has been edited; pandas cannot express arbitrary SQL.\n"
                "# This reads the source — re-apply your query with the duckdb snippet.\n"
                ) if sql_override else ""
        if source.fmt in ("csv", "glob_csv"):
            dtypes, dates = _pandas_dtypes(list(cols.values()))
            a = [_py(source.target)]
            if source.read_args.get("delim") not in (",", None):
                a.append(f"sep={_py(source.read_args['delim'])}")
            if source.read_args.get("quote"):
                a.append(f"quotechar={_py(source.read_args['quote'])}")
            if source.read_args.get("skip"):
                a.append(f"skiprows={source.read_args['skip']}")
            if not source.read_args.get("header", True):
                a.append("header=None")
            if dtypes:
                a.append("dtype={" + ", ".join(
                    f"{_py(k)}: {_py(v)}" for k, v in dtypes.items()) + "}")
            if dates:
                a.append(f"parse_dates=[{', '.join(_py(d) for d in dates)}]")
            return ("import pandas as pd\n" + warn + note
                    + "df = pd.read_csv(\n    " + ",\n    ".join(a) + ",\n)" + tail)
        reader = {"parquet": "read_parquet", "glob_parquet": "read_parquet",
                  "json": "read_json", "ndjson": "read_json",
                  "xlsx": "read_excel"}.get(source.fmt)
        if reader is None:  # delta
            return (
                "# pandas has no reader for a Delta table without extra packages.\n"
                "# Use the duckdb snippet, or: pip install deltalake\n"
                "from deltalake import DeltaTable\n"
                f"df = DeltaTable({_py(source.target)}).to_pandas()" + tail
            )
        extra = ""
        if source.fmt == "xlsx" and source.sheet:
            extra = f", sheet_name={_py(source.sheet)}"
        if source.fmt == "ndjson":
            extra = ", lines=True"
        return f"import pandas as pd\n{warn}{note}df = pd.{reader}({_py(source.target)}{extra})" + tail

    if dialect == "polars":
        reader = _POLARS_READER[source.fmt]
        args = [_py(source.target)]
        if source.fmt in ("csv", "glob_csv"):
            if source.read_args.get("delim") not in (",", None):
                args.append(f"separator={_py(source.read_args['delim'])}")
            if source.read_args.get("skip"):
                args.append(f"skip_rows={source.read_args['skip']}")
            if not source.read_args.get("header", True):
                args.append("has_header=False")
        if source.fmt == "xlsx" and source.sheet:
            args.append(f"sheet_name={_py(source.sheet)}")
        collect = "\n    .collect()" if reader.startswith("scan") else ""
        note = ("# The SQL box has been edited; this reads the source without your query.\n"
                if sql_override else "")
        return (
            f"import polars as pl\n{note}"
            f"df = (\n    pl.{reader}({', '.join(args)}){_polars_ops(spec)}{collect}\n)"
        )

    raise ValueError(f"unknown dialect {dialect!r}")
