import Darwin
import DuckDBKit
import Foundation
import SiftCore

// Turning a path into a queryable relation: the connection-needing half of core/source.py.
// Format detection, glob escaping, hive layout, and row estimation are pure and already live in
// SiftCore's Source.swift — this file calls those and adds only what genuinely needs to ask
// DuckDB something: sniffing a CSV's dialect, reading a parquet footer, counting rows exactly,
// describing a relation's schema, and building the SourceSpec that ties it all together.

// MARK: - CSV sniffing

/// `sniff_csv` reports an absent quote/escape/comment as this literal string. Passing it back
/// into `read_csv` fails with "the quote option cannot exceed a size of 1 byte" — measured on
/// 1.5.5, pinned as fact 1 in `DuckDB155FactsTests`. `sniffCSV` normalizes it away below.
private let sniffEmpty = "(empty)"

/// Under this, sniff the whole file (`sample_size=-1`) — it's free. Above it, sample the head:
/// types inferred from the first 20k rows and disagreeing at row 400,000 is the most common
/// failure in this problem space, so this threshold exists to close it, not to save time.
let fullSniffMaxBytes = 50 * 1024 * 1024

/// Under this, a real `count(*)` is fast enough to do at open time, which beats any estimate.
let exactCountMaxBytes = 64 * 1024 * 1024

/// Dialect and column types detected by DuckDB's sniffer, with `sniffEmpty` already normalized
/// away. Mirrors `sniff_csv`'s Python dict return value.
public struct CSVSniff: Sendable, Equatable {
    public let delim: String
    public let quote: String
    public let escape: String
    public let comment: String
    public let skip: Int
    public let header: Bool
    public let columns: [Column]
    /// `sniff_csv`'s own reproducible `FROM read_csv(...)` clause, for display.
    public let prompt: String?
}

/// Not `private`: Staging.swift decodes the `_sift_sources` catalog's VARCHAR columns (a table
/// name, a path it is about to `stat`) with the same rule and shares this copy. This is the
/// strict decoder — anything that is not `.text` reads as `""`, which for a path means "no such
/// file" rather than a plausible-looking `Cell.display` rendering of whatever else came back.
/// SessionQueries.swift keeps its own, deliberately different `cellText` (falls back to
/// `display`, for values headed to a panel label rather than to a decision); Task 5's review
/// looked at the pair and ruled them genuinely different, unlike `cellInt`'s four copies.
func cellText(_ cell: Cell) -> String {
    if case .text(let s) = cell { return s }
    return ""
}

// `cellInt` lives in Session.swift (widened from `private` to internal) and is shared from
// there — see its doc comment. Not duplicated here: it decodes the same shape (a bare
// count/BIGINT cell), and a second copy is exactly the kind of decoder drift this branch has
// already ruled against twice (Plan 2 Task 4's `col`/`asText`, Plan 2 Task 10's `grouped`).

private func cellBool(_ cell: Cell) -> Bool {
    if case .bool(let b) = cell { return b }
    return false
}

/// A LIST(VARCHAR) cell as `[String]`, NULL elements reading as "" — used only for the sniffer's
/// column names/types, which DuckDB never actually populates with NULL entries.
private func cellTextList(_ cell: Cell) -> [String] {
    guard case .list(let items) = cell else { return [] }
    return items.map { $0.isNull ? "" : cellText($0) }
}

/// Ask DuckDB to detect dialect and column types, reading only the head of the file (or the
/// whole thing — see `fullSniffMaxBytes`).
///
/// `sniff_csv`'s own `Columns` field is a `LIST(STRUCT(name VARCHAR, type VARCHAR))` — a nested
/// type `Chunk.decodeColumn` cannot read element-by-element (STRUCT has no decoder; see its
/// comment). `list_transform` splits it into two `LIST(VARCHAR)` projections instead, each of
/// which decodes for real, rather than asking the decoder for something it was never meant to
/// carry.
public func sniffCSV(_ con: Connection, path: String, sampleSize: Int = 20480) throws -> CSVSniff {
    let args = sampleSize > 0 ? "sample_size=\(sampleSize)" : "sample_size=-1"
    let sql = """
        SELECT Delimiter, Quote, Escape, Comment, SkipRows, HasHeader, Prompt, \
        list_transform(Columns, x -> x.name) AS col_names, \
        list_transform(Columns, x -> x.type) AS col_types \
        FROM sniff_csv(\(qlit(path)), \(args))
        """
    guard let row = try con.query(sql).allRows().first else {
        throw UnsupportedSource("DuckDB could not detect a CSV dialect for \(path).")
    }
    func unsniff(_ s: String) -> String { s == sniffEmpty ? "" : s }
    let names = cellTextList(row[7])
    let types = cellTextList(row[8])
    let columns = zip(names, types).map { Column(name: $0, type: $1) }
    return CSVSniff(
        delim: cellText(row[0]), quote: unsniff(cellText(row[1])), escape: unsniff(cellText(row[2])),
        comment: unsniff(cellText(row[3])), skip: cellInt(row[4]), header: cellBool(row[5]),
        columns: columns, prompt: row[6].isNull ? nil : cellText(row[6])
    )
}

// MARK: - parquet and delta

/// Exact row count and row-group layout from the footer — no data pages read.
public struct ParquetFooter: Sendable, Equatable {
    public let numRows: Int
    public let numRowGroups: Int
    public let numFiles: Int
}

public func parquetFooter(_ con: Connection, target: String) throws -> ParquetFooter {
    let sql = "SELECT sum(num_rows)::BIGINT, sum(num_row_groups)::BIGINT, count(*)::BIGINT "
        + "FROM parquet_file_metadata(\(qlit(target)))"
    let row = try con.query(sql).allRows()[0]
    return ParquetFooter(numRows: cellInt(row[0]), numRowGroups: cellInt(row[1]), numFiles: cellInt(row[2]))
}

/// True row count, counted against the all-varchar relation for text formats.
///
/// Counting the *typed* relation would be wrong. Measured on DuckDB 1.5.5 (fact 3): with an
/// uncastable value present, `count(*)` on the typed view is answered by projection pushdown
/// without parsing any column, so it reports the physical count while `SELECT *` returns fewer
/// rows — the grid total would disagree with the grid contents. The all-varchar relation never
/// casts, so its `count(*)` is the physical truth and matches what all-varchar mode displays.
public func exactCount(_ con: Connection, spec: SourceSpec) throws -> Int {
    let rel = readExpr(spec: spec, allVarchar: supportsAllVarchar(spec))
    let row = try con.query("SELECT count(*) FROM \(rel)").allRows()[0]
    return cellInt(row[0])
}

/// The schema of a relation expression, without reading any rows.
func describe(_ con: Connection, relationExpr: String) throws -> [Column] {
    let rows = try con.query("DESCRIBE SELECT * FROM \(relationExpr)").allRows()
    return rows.map { Column(name: cellText($0[0]), type: cellText($0[1])) }
}

// MARK: - path identity

/// `os.path.realpath` equivalent: resolves symlinks and relative components via the real
/// `realpath(3)` syscall, matching Python's `os.path.realpath` (which is itself a thin wrapper
/// over the same call). Falls back to the input unchanged if the path cannot be resolved (e.g.
/// it doesn't exist) — the caller's own `stat` immediately after will raise the real error.
///
/// Not `private`: `Session.openPath` (Session.swift) needs the identical resolution for its own
/// path argument — one copy, shared within the module, rather than a second one drifting from it.
func realPath(_ path: String) -> String {
    // Passing NULL as the output buffer is a POSIX.1-2008 extension: realpath mallocs a
    // buffer of the right size itself, so there's no PATH_MAX guess to get wrong.
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `mtime_ns` and `size`, read via `stat(2)` directly rather than `FileManager.attributesOfItem`
/// — the latter loses `st_mtime`'s nanosecond component through `Date`, and a directory's mtime
/// changing when children are added is the exact invalidation signal glob/Delta sources need
/// (see `isDeltaDir`'s doc comment on why a raw glob over a Delta table is wrong in the first
/// place; SourceKey identity is the same idea one level up).
///
/// Not `private`: Staging.swift re-stats a staged copy's source to answer "has this file changed
/// since we copied it" — the same two fields, compared against the same `SourceKey` they were
/// read into. A throw there means the file is gone, which is a different answer, not an error.
func statInfo(_ path: String) throws -> (mtimeNs: Int, size: Int) {
    var st = stat()
    guard stat(path, &st) == 0 else {
        throw UnsupportedSource("Cannot read \(path): file not found or not readable")
    }
    let mtimeNs = Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec)
    return (mtimeNs, Int(st.st_size))
}

/// `Path(path).suffix.lower() in COMPRESSION_EXT`, checking only the final extension — mirrors
/// `_ext_chain`'s compressed check. `pathName`/`pathSuffix` are `SiftCore`-internal (this file
/// lives in a different module), so this reads the extension through `NSString` instead, which
/// is the native equivalent for exactly this one field.
private func isCompressedPath(_ path: String) -> Bool {
    compressionExt.contains("." + (path as NSString).pathExtension.lowercased())
}

// MARK: - building specs

/// Resolve a path into everything needed to query it, reading as little as possible.
public func buildSource(_ con: Connection, path: String, sheet: String? = nil) throws -> SourceSpec {
    let resolvedPath = realPath(path)
    let (mtimeNs, size) = try statInfo(resolvedPath)
    // A directory's st_mtime_ns changes when children are added — the invalidation signal wanted
    // for glob/Delta sources too.
    let key = SourceKey(path: resolvedPath, mtimeNs: mtimeNs, size: size)
    let fmt = try detectFormat(resolvedPath)

    switch fmt {
    case .parquet:
        let meta = try parquetFooter(con, target: resolvedPath)
        let cols = try describe(con, relationExpr: "read_parquet(\(qlit(resolvedPath)))")
        return SourceSpec(key: key, fmt: fmt, readFn: "read_parquet", columns: cols, rowCount: meta.numRows)

    case .delta:
        let cols = try describe(con, relationExpr: "delta_scan(\(qlit(resolvedPath)))")
        return SourceSpec(
            key: key, fmt: fmt, readFn: "delta_scan", columns: cols, deltaVersion: deltaVersion(resolvedPath)
        )

    case .globParquet, .globCsv:
        let ext = fmt == .globParquet ? ".parquet" : ".csv"
        // DuckDB-facing pattern: escaped, since read_parquet/parquet_file_metadata interpret
        // "[...]" as a glob character class. The on-disk listing below needs no such escaping —
        // filesWithExtension isn't a glob matcher, it enumerates the literal directory.
        let pattern = globEscape(resolvedPath) + "/**/*" + ext
        let files = filesWithExtension(ext, under: resolvedPath)
        let keys = hiveKeys(directory: resolvedPath, files: files)
        var args: [String: ReadArg] = ["union_by_name": .bool(true), "filename": .bool(true)]
        if !keys.isEmpty { args["hive_partitioning"] = .bool(true) }
        let fn = fmt == .globParquet ? "read_parquet" : "read_csv"
        // DESCRIBE only the first file: with union_by_name DuckDB would open every footer, which
        // is seconds on a few thousand files. session.py refines the union schema in the background.
        let cols = try files.isEmpty ? [] : describe(con, relationExpr: "\(fn)(\(qlit(files[0])))")
        let rowCount = fmt == .globParquet ? try parquetFooter(con, target: pattern).numRows : nil
        return SourceSpec(
            key: key, fmt: fmt, readFn: fn, readArgs: args, columns: cols, rowCount: rowCount, glob: pattern
        )

    case .xlsx:
        let sheets = try listSheets(path: resolvedPath)
        // Python selects by truthiness (`sheet or auto-pick`), so an empty string auto-selects
        // same as omitting the argument. `sheet ?? …` alone would instead try to open a sheet
        // literally named "" and fail loud — caught in Task 2's review, closed here now that
        // Task 4 adds the first caller that can pass one through from the UI.
        let chosen = sheet.flatMap { $0.isEmpty ? nil : $0 } ?? sheets.first(where: { !$0.empty })?.name
            ?? sheets.first?.name
        guard let chosen else {
            throw UnsupportedSource("\((resolvedPath as NSString).lastPathComponent) has no sheets.")
        }
        let cols = try describe(con, relationExpr: "read_xlsx(\(qlit(resolvedPath)), sheet=\(qlit(chosen)))")
        let rows = sheets.first(where: { $0.name == chosen })?.rows
        return SourceSpec(
            key: key, fmt: fmt, readFn: "read_xlsx", readArgs: ["sheet": .text(chosen)], columns: cols,
            rowCount: rows.map { max(0, $0 - 1) }, sheet: chosen, sheets: sheets
        )

    case .json, .ndjson:
        let cols = try describe(con, relationExpr: "read_json_auto(\(qlit(resolvedPath)))")
        let compressed = isCompressedPath(resolvedPath)
        var rowCount: Int?
        if key.size <= exactCountMaxBytes {
            let probe = SourceSpec(key: key, fmt: fmt, readFn: "read_json_auto", columns: cols, compressed: compressed)
            rowCount = try exactCount(con, spec: probe)
        }
        return SourceSpec(
            key: key, fmt: fmt, readFn: "read_json_auto", columns: cols, rowCount: rowCount, compressed: compressed
        )

    case .csv:
        let compressed = isCompressedPath(resolvedPath)
        let sampleSize = (!compressed && key.size <= fullSniffMaxBytes) ? -1 : 20480
        let sn = try sniffCSV(con, path: resolvedPath, sampleSize: sampleSize)
        var args: [String: ReadArg] = [
            "delim": .text(sn.delim), "quote": .text(sn.quote), "escape": .text(sn.escape),
            "header": .bool(sn.header), "skip": .int(sn.skip),
            // Non-negotiable for a browsing tool: without this, one uncastable value 29,000 rows
            // in raises a ConversionException the moment the user scrolls or aggregates that far,
            // and the grid dies mid-session. With it, the row is dropped instead — which would be
            // *worse* if it were silent, so Sift independently counts and displays every dropped
            // row via SQLGenPanels' bad-row queries against the all-varchar relation.
            "ignore_errors": .bool(true),
            // DuckDB's default (true) reads a QUOTED empty field `""` as NULL, making it
            // indistinguishable from a genuinely absent value. A viewer should report what is
            // actually in the file, so: ,,  -> NULL (nothing there); ,"", -> '' (written deliberately).
            "allow_quoted_nulls": .bool(false),
        ]
        if !sn.comment.isEmpty { args["comment"] = .text(sn.comment) }
        // Note: no "columns" key here — read_expr derives columns={...} directly from the ordered
        // SourceSpec.columns array below, never from readArgs. See Types.swift's ReadArg LANDMINE.

        var rowCount: Int?
        var rowEstimate: RowEstimate?
        if !compressed && key.size <= exactCountMaxBytes {
            // Cheap enough to be certain. Beats an estimate, and in particular gets
            // quoted-newline files right, where line counting overshoots.
            let probe = SourceSpec(
                key: key, fmt: .csv, readFn: "read_csv", readArgs: args, columns: sn.columns,
                compressed: compressed, sniffPrompt: sn.prompt
            )
            rowCount = try exactCount(con, spec: probe)
        } else if !compressed {
            let offset = try headerByteOffset(path: resolvedPath, sniff: SniffHints(skip: sn.skip, header: sn.header))
            rowEstimate = try estimateRows(path: resolvedPath, headerBytes: offset)
        }
        // Compressed CSV gets neither: compressed bytes say nothing about row count, so the UI
        // shows a live "counting…" spinner instead of a fabricated number.
        return SourceSpec(
            key: key, fmt: .csv, readFn: "read_csv", readArgs: args, columns: sn.columns,
            rowCount: rowCount, rowEstimate: rowEstimate, compressed: compressed, sniffPrompt: sn.prompt
        )

    case .merge:
        // detectFormat never returns .merge for a real path — merge sources are constructed
        // directly by Session.merge (Task 7), never resolved from a path here.
        throw UnsupportedSource("merge is not buildable from a path")
    }
}
