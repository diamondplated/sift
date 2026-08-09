import Foundation

// Copy-as-code: leave Sift holding the same data in a notebook.
//
// Pure. The point is that the snippet reproduces what is *on screen* — same dialect, same
// dtypes, same filters — so a session that started as a quick look can graduate into real
// analysis without re-deriving how to read the file. Ported from engine/core/snippet.py.
//
// Everything this module emits is generated source code a user pastes into a notebook, so a
// wrong quote is a syntax error in their editor, not a cosmetic diff. See pyRepr below.

/// Raised when `dialect` isn't one of "duckdb"/"pandas"/"polars"/"sql". Mirrors Python's
/// bare `raise ValueError(f"unknown dialect {dialect!r}")` — the message uses `!r` (repr), so
/// the port uses `pyRepr` to match it, not a plain quoted string.
public struct UnknownDialect: SiftError, Equatable {
    public let dialect: String
    public init(_ dialect: String) { self.dialect = dialect }
    public var description: String { "unknown dialect \(pyRepr(dialect))" }
}

// MARK: - pyRepr: Python's repr(), pinned against the interpreter

/// Python's `repr()` for a bound query value: `None`/`True`/`False`/the plain numeral for
/// everything but a string, and `pyRepr(String)` (below) for a string.
func pyRepr(_ v: SQLValue) -> String {
    switch v {
    case .null: return "None"
    case .bool(let b): return b ? "True" : "False"
    case .int(let i): return String(i)
    // Swift's default Double description already produces CPython's shortest-round-trip
    // digits — verified against repr() for 1.0, 0.1, -0.0, 1e+100, 1e-05, and a dozen more
    // (see task-10-report.md); no hand-rolled float formatter needed.
    case .double(let d): return String(d)
    case .text(let s): return pyRepr(s)
    }
}

/// Python's `repr()` for a plain string. Every non-`SQLValue` call site in this file (column
/// names, paths, delimiters, dtype names, sheet names) is already a Python `str`, so `_py`'s
/// `repr(str(v))` collapses to `repr(v)` there — this is that.
///
/// The rule, pinned empirically against CPython (see task-10-report.md for the verification
/// table): single-quote normally; switch to double quotes only when the string contains a `'`
/// and no `"` (so the quote character itself never needs escaping); the chosen quote character,
/// backslash, tab, newline and carriage return each get a short escape; anything
/// `str.isprintable()` would refuse (control/format/surrogate/private-use/unassigned characters,
/// the two line/paragraph separators, and any space separator other than ASCII 0x20) gets a
/// `\xXX` / `\uXXXX` / `\UXXXXXXXX` escape sized to the codepoint.
func pyRepr(_ s: String) -> String {
    let hasSingle = s.contains("'")
    let hasDouble = s.contains("\"")
    let quote: Unicode.Scalar = (hasSingle && !hasDouble) ? "\"" : "'"

    var out = String(quote)
    for scalar in s.unicodeScalars {
        if scalar == quote {
            out += "\\"
            out.unicodeScalars.append(quote)
        } else if scalar == "\\" {
            out += "\\\\"
        } else if scalar == "\t" {
            out += "\\t"
        } else if scalar == "\n" {
            out += "\\n"
        } else if scalar == "\r" {
            out += "\\r"
        } else if isPyPrintable(scalar) {
            out.unicodeScalars.append(scalar)
        } else {
            out += hexEscape(scalar.value)
        }
    }
    out.unicodeScalars.append(quote)
    return out
}

/// Mirrors CPython's `Py_UNICODE_ISPRINTABLE`: not printable iff Other* or Separator*, except
/// that ASCII space (the one Zs codepoint everyone actually types) still counts as printable.
private func isPyPrintable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value == 0x20 { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
        .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}

/// `\xXX` below 0x100, `\uXXXX` below 0x10000, else `\UXXXXXXXX` — lowercase hex, mirroring
/// CPython's `unicode_repr`. Hand-rolled rather than `String(format:)`: hex-digit padding has no
/// locale sensitivity either way, but this keeps the whole file free of `String(format:)`.
private func hexEscape(_ value: UInt32) -> String {
    let (digits, prefix) = value < 0x100 ? (2, "\\x") : value < 0x10000 ? (4, "\\u") : (8, "\\U")
    var hex = String(value, radix: 16, uppercase: false)
    while hex.count < digits { hex = "0" + hex }
    return prefix + hex
}

// MARK: - pandas dtype mapping

// DuckDB type -> pandas dtype. DECIMAL/NUMERIC become float64 with their own check below,
// because pandas has no native decimal dtype and silently using object would surprise people
// more.
private let pandasDtype: [String: String] = [
    "BOOLEAN": "boolean",
    "TINYINT": "Int8", "SMALLINT": "Int16", "INTEGER": "Int32", "BIGINT": "Int64",
    "UTINYINT": "UInt8", "USMALLINT": "UInt16", "UINTEGER": "UInt32", "UBIGINT": "UInt64",
    "HUGEINT": "Int64", "FLOAT": "float32", "REAL": "float32", "DOUBLE": "float64",
    "VARCHAR": "string", "UUID": "string",
]

private let polarsReader: [Fmt: String] = [
    .csv: "scan_csv", .globCsv: "scan_csv",
    .parquet: "scan_parquet", .globParquet: "scan_parquet",
    .json: "read_json", .ndjson: "scan_ndjson",
    .delta: "scan_delta", .xlsx: "read_excel",
]

/// Python calls this with `list(cols.values())`, and `cols` is always built as `{c.name: c for c
/// in self.spec.columns}` at its one real call site (session.py:154-156) — so iteration order is
/// file-column order, not incidental. `[String: Column]` here is an unordered Swift Dictionary
/// and can't carry that, so the call site passes `source.columns.compactMap { cols[$0.name] }`
/// instead of `Array(cols.values)` — `source.columns` is the ordered `[Column]` that order came
/// from in the first place. Same resolution as the `columns=` landmine in Source.swift: derive
/// from the ordered array, never from the dictionary's own iteration order.
private func pandasDtypes(_ cols: [Column]) -> (dtypes: [(String, String)], dates: [String]) {
    var dtypes: [(String, String)] = []
    var dates: [String] = []
    for c in cols {
        let t = c.type.uppercased()
        if c.kind == .temporal {
            dates.append(c.name)
        } else if t.hasPrefix("DECIMAL") || t.hasPrefix("NUMERIC") {
            dtypes.append((c.name, "float64"))
        } else if let dt = pandasDtype[t] {
            dtypes.append((c.name, dt))
        }
    }
    return (dtypes, dates)
}

// MARK: - read_args lookups

private func readArgText(_ args: [String: ReadArg], _ key: String) -> String? {
    if case .text(let s)? = args[key] { return s }
    return nil
}

private func readArgBool(_ args: [String: ReadArg], _ key: String) -> Bool? {
    if case .bool(let b)? = args[key] { return b }
    return nil
}

private func readArgInt(_ args: [String: ReadArg], _ key: String) -> Int? {
    if case .int(let i)? = args[key] { return i }
    return nil
}

// MARK: - RAM warning

/// pandas loads everything; DuckDB does not. Say so with a real number, not a platitude. Fires
/// only for row-oriented formats above 200 MB.
private func ramWarning(_ spec: SourceSpec) -> String {
    let rowOriented: Set<Fmt> = [.csv, .globCsv, .json, .ndjson]
    guard rowOriented.contains(spec.fmt), spec.key.size >= 200 * 1024 * 1024 else { return "" }
    let gb = Double(spec.key.size) / Double(1024 * 1024 * 1024)
    return "# NOTE: \(grouped(gb, decimals: 1)) GB source. pandas materializes the whole thing "
        + "— budget roughly \(grouped(gb * 2.5, decimals: 0)) GB of RAM.\n"
        + "# The duckdb snippet streams instead.\n"
}

// MARK: - pandas / polars filter+sort chains

/// Render filters and sort as a pandas chain.
///
/// `.contains`/`.between` index `f.values[0]`/`[1]` unconditionally in Python and would raise
/// IndexError on a malformed filter (no values selected). Guarded with `if let`/`count >= 2`
/// instead, same defensive deviation SQLGen.swift's `renderSQL` already makes and review already
/// accepted for the identical reason — this is display/snippet code, never executed, and the
/// blast radius of silently dropping a malformed predicate is small.
private func pandasOps(_ spec: QuerySpec) -> String {
    var lines: [String] = []
    for f in spec.filters {
        let col = "df[\(pyRepr(f.col))]"
        switch f.op {
        case .isNull:
            lines.append("df = df[\(col).isna()]")
        case .notNull:
            lines.append("df = df[\(col).notna()]")
        case .isEmpty:
            lines.append("df = df[\(col).astype('string') == '']")
        case .contains:
            if let v = f.values.first {
                lines.append(
                    "df = df[\(col).astype('string').str.contains(\(pyRepr(v)), case=False, na=False)]")
            }
        case .between:
            if f.values.count >= 2 {
                lines.append("df = df[\(col).between(\(pyRepr(f.values[0])), \(pyRepr(f.values[1])))]")
            }
        case .inList:
            let vals = f.values.map { pyRepr($0) }.joined(separator: ", ")
            lines.append("df = df[\(col).isin([\(vals)])]")
        case .notIn:
            let vals = f.values.map { pyRepr($0) }.joined(separator: ", ")
            lines.append("df = df[~\(col).isin([\(vals)])]")
        default:   // eq, ne, lt, le, gt, ge
            if let v = f.values.first {
                let op = f.op == .eq ? "==" : f.op.rawValue
                lines.append("df = df[\(col) \(op) \(pyRepr(v))]")
            }
        }
    }
    if !spec.sort.isEmpty {
        let by = spec.sort.map { pyRepr($0.column) }.joined(separator: ", ")
        let asc = spec.sort.map { $0.direction == .desc ? "False" : "True" }.joined(separator: ", ")
        let many = spec.sort.count > 1
        lines.append(
            many
                ? "df = df.sort_values([\(by)], ascending=[\(asc)])"
                : "df = df.sort_values(\(by), ascending=\(asc))")
    }
    return lines.joined(separator: "\n")
}

private func polarsOps(_ spec: QuerySpec) -> String {
    var parts: [String] = []
    for f in spec.filters {
        let c = "pl.col(\(pyRepr(f.col)))"
        switch f.op {
        case .isNull:
            parts.append(".filter(\(c).is_null())")
        case .notNull:
            parts.append(".filter(\(c).is_not_null())")
        case .isEmpty:
            parts.append(".filter(\(c).cast(pl.Utf8) == '')")
        case .contains:
            if let v = f.values.first {
                parts.append(".filter(\(c).cast(pl.Utf8).str.contains(\(pyRepr(v)), literal=True))")
            }
        case .between:
            if f.values.count >= 2 {
                parts.append(".filter(\(c).is_between(\(pyRepr(f.values[0])), \(pyRepr(f.values[1]))))")
            }
        case .inList:
            let vals = f.values.map { pyRepr($0) }.joined(separator: ", ")
            parts.append(".filter(\(c).is_in([\(vals)]))")
        case .notIn:
            let vals = f.values.map { pyRepr($0) }.joined(separator: ", ")
            parts.append(".filter(~\(c).is_in([\(vals)]))")
        default:   // eq, ne, lt, le, gt, ge
            if let v = f.values.first {
                let op = f.op == .eq ? "==" : f.op.rawValue
                parts.append(".filter(\(c) \(op) \(pyRepr(v)))")
            }
        }
    }
    if !spec.sort.isEmpty {
        let by = spec.sort.map { pyRepr($0.column) }.joined(separator: ", ")
        let desc = spec.sort.map { $0.direction == .desc ? "True" : "False" }.joined(separator: ", ")
        parts.append(".sort([\(by)], descending=[\(desc)])")
    }
    return parts.map { "\n    \($0)" }.joined()
}

// MARK: - snippet

/// Generate a runnable snippet for `dialect` in ("duckdb", "pandas", "polars", "sql").
///
/// `sqlOverride` is the SQL box's text when the user has taken it over — the snippet then
/// carries their query verbatim rather than a reconstruction of UI state. An empty string is
/// treated exactly like `nil`: Python's `sql_override or ...` / `if sql_override:` both treat ""
/// as falsy, and every real caller either omits the override or supplies real text, so this
/// keeps that same "falsy empty string" behavior rather than letting Optional-vs-empty-string
/// diverge from what Python actually does at every one of these call sites.
public func snippet(
    dialect: String, source: SourceSpec, spec: QuerySpec, cols: [String: Column],
    sqlOverride: String? = nil
) throws -> String {
    let override = (sqlOverride?.isEmpty == false) ? sqlOverride : nil

    if dialect == "sql" {
        return override ?? renderSQL(spec, cols: cols)
    }

    if dialect == "duckdb" {
        // Python builds the search string as a raw `f'"{spec.relation}"'`, NOT via ident.q() —
        // no quote-doubling. Matched literally rather than reused via q(), which would escape an
        // embedded `"` differently than what render_sql actually emitted for that relation name.
        let body = (override ?? renderSQL(spec, cols: cols))
            .replacingOccurrences(of: "\"\(spec.relation)\"", with: readExpr(spec: source))
        let pre: String
        switch source.fmt {
        case .delta: pre = "duckdb.sql(\"INSTALL delta; LOAD delta\")\n"
        case .xlsx: pre = "duckdb.sql(\"INSTALL excel; LOAD excel\")\n"
        default: pre = ""
        }
        return "import duckdb\n" + pre
            + "df = duckdb.sql(\"\"\"\n\(body)\n\"\"\").df()   # .arrow() / .pl() also work\n"
    }

    if dialect == "pandas" {
        let warn = ramWarning(source)
        let ops = pandasOps(spec)
        let tail = ops.isEmpty ? "" : "\n\n\(ops)"
        let note = override != nil
            ? "# The SQL box has been edited; pandas cannot express arbitrary SQL.\n"
                + "# This reads the source — re-apply your query with the duckdb snippet.\n"
            : ""

        if source.fmt == .csv || source.fmt == .globCsv {
            let (dtypes, dates) = pandasDtypes(source.columns.compactMap { cols[$0.name] })
            var a = [pyRepr(source.target)]
            if let delim = readArgText(source.readArgs, "delim"), delim != "," {
                a.append("sep=\(pyRepr(delim))")
            }
            if let quote = readArgText(source.readArgs, "quote"), !quote.isEmpty {
                a.append("quotechar=\(pyRepr(quote))")
            }
            if let skip = readArgInt(source.readArgs, "skip"), skip != 0 {
                a.append("skiprows=\(skip)")
            }
            if !(readArgBool(source.readArgs, "header") ?? true) {
                a.append("header=None")
            }
            if !dtypes.isEmpty {
                let inner = dtypes.map { "\(pyRepr($0.0)): \(pyRepr($0.1))" }.joined(separator: ", ")
                a.append("dtype={\(inner)}")
            }
            if !dates.isEmpty {
                a.append("parse_dates=[\(dates.map { pyRepr($0) }.joined(separator: ", "))]")
            }
            return "import pandas as pd\n" + warn + note
                + "df = pd.read_csv(\n    " + a.joined(separator: ",\n    ") + ",\n)" + tail
        }

        let reader: String?
        switch source.fmt {
        case .parquet, .globParquet: reader = "read_parquet"
        case .json, .ndjson: reader = "read_json"
        case .xlsx: reader = "read_excel"
        default: reader = nil   // delta (only real caller of this branch today)
        }
        guard let reader else {
            return "# pandas has no reader for a Delta table without extra packages.\n"
                + "# Use the duckdb snippet, or: pip install deltalake\n"
                + "from deltalake import DeltaTable\n"
                + "df = DeltaTable(\(pyRepr(source.target))).to_pandas()" + tail
        }
        var extra = ""
        if source.fmt == .xlsx, let sheet = source.sheet {
            extra = ", sheet_name=\(pyRepr(sheet))"
        }
        if source.fmt == .ndjson {
            extra = ", lines=True"
        }
        return "import pandas as pd\n\(warn)\(note)df = pd.\(reader)(\(pyRepr(source.target))\(extra))" + tail
    }

    if dialect == "polars" {
        guard let readerFn = polarsReader[source.fmt] else {
            // Never a file source in practice (Fmt.merge is a derived view, not a read
            // function) — Python's dict lookup would raise an uncaught KeyError here; this
            // throws instead, same "don't fatalError/crash a library caller" ruling as Task 2.
            throw UnsupportedSource("no polars reader for format \(source.fmt.rawValue)")
        }
        var args = [pyRepr(source.target)]
        if source.fmt == .csv || source.fmt == .globCsv {
            if let delim = readArgText(source.readArgs, "delim"), delim != "," {
                args.append("separator=\(pyRepr(delim))")
            }
            if let skip = readArgInt(source.readArgs, "skip"), skip != 0 {
                args.append("skip_rows=\(skip)")
            }
            if !(readArgBool(source.readArgs, "header") ?? true) {
                args.append("has_header=False")
            }
        }
        if source.fmt == .xlsx, let sheet = source.sheet {
            args.append("sheet_name=\(pyRepr(sheet))")
        }
        let collect = readerFn.hasPrefix("scan") ? "\n    .collect()" : ""
        let note = override != nil
            ? "# The SQL box has been edited; this reads the source without your query.\n" : ""
        return "import polars as pl\n\(note)"
            + "df = (\n    pl.\(readerFn)(\(args.joined(separator: ", ")))\(polarsOps(spec))\(collect)\n)"
    }

    throw UnknownDialect(dialect)
}
