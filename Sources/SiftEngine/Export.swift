import DuckDBKit
import Foundation
import SiftCore

// Export: the one place Sift writes anything to the user's disk. Ported from engine/session.py
// lines 1115-1165 (`export`) and its module-level `EXPORT_FORMATS` map (session.py:61).
//
// 🔴 THIS IS A TRUST BOUNDARY, and it is the only one in the engine that produces a file.
// Everything else Sift runs is a SELECT against a read-only source; this runs a COPY. Three
// rules hold it, and all three are load-bearing:
//
//  1. **The COPY statement is BUILT here and never taken from the SQL box.** In SQL-box mode the
//     stored text is re-run through `assertSelectOnly` *before* it is wrapped, not merely
//     trusted because `runSQL` checked it once. That re-check is deliberate belt-and-braces:
//     today `runSQL` is the only writer of `Table.sqlText` and it guards on the way in, so the
//     re-check cannot currently fire — which is exactly why it must be here, because the day a
//     second writer appears (a session restore, a saved view, a URL handler) this is the call
//     that stops `COPY (DROP TABLE x) TO ...` from being assembled. ExportTests drives it
//     through `setSQLTextForTest`.
//  2. **No user-supplied string is ever concatenated into the statement.** The format is a
//     lookup in a fixed table — an unknown key is a typed `SessionError` the caller can render,
//     never a crash and never an interpolation. The destination goes through `qlit`, the same
//     literal-quoting every read path uses (MEASURED: a destination of
//     `od'); COPY (SELECT 42) TO 'pwned.csv` writes ONE file with that literal name and creates
//     no `pwned.csv`). The relation goes through `q`, which survives a table name carrying a
//     double quote — reachable, because `openPath(_:name:)` takes a caller-supplied name
//     verbatim. ExportTests attacks all three.
//  3. **A file is never silently replaced.** Without `overwrite`, the destination is claimed
//     with an exclusive create (`Data.WritingOptions.withoutOverwriting`, i.e. `O_CREAT|O_EXCL`)
//     rather than Python's `os.path.exists` test followed by an unprotected write. Python's
//     shape loses a race — two exports, or an export and any other writer, can both see "does
//     not exist" and the second silently destroys the first's file. Claiming the name IS the
//     check here, so there is no window between them. If the COPY then fails, the placeholder is
//     removed so the destination is left exactly as it was found.
//
// CONNECTION STRATEGY: its own throwaway `Connection`, like everything in SessionQueries.swift
// and Joins.swift — but NOT for the reason an earlier version of this comment gave, which said
// `pagingConnection` was avoided because a large COPY is "seconds of work". That is not what
// makes `pagingConnection` safe to share. Its proof (Session.swift's header, fact 3) is that
// every user runs to completion WITHOUT AWAITING, not that they finish quickly — and `export`
// has no suspension point either, so by that argument it would have been safe on it. The real
// reason is narrower and duller: `pagingConnection` exists to keep `sortedRelation`'s TEMP TABLE
// visible across `page()` calls, nothing here creates or reads one, so there is nothing to share.
//
// And to be explicit about what a separate `Connection` does NOT buy: `export` is an
// actor-isolated method making a synchronous C call, so a large COPY freezes paging for its full
// duration either way. That is a branch-wide tradeoff, not something special about export — the
// design spec's §13a page-latency cliff, which `page` and `runSQL` also accept by design.
// `computeProfile` is the one case measured unacceptable (~1.29 s on a 200-column table) and is
// being detached onto its own connection separately.

// MARK: - the format table

/// One writable output format: the COPY option list DuckDB needs, and the extension the file
/// picker should suggest. Verified against DuckDB 1.5.5's COPY (see `exportFormats`).
public struct ExportFormat: Sendable, Equatable {
    public let key: String
    /// The parenthesized COPY option list, verbatim. A constant — never built from user input.
    public let copyOptions: String
    public let ext: String
}

/// The formats the Export action can write. Ported from session.py's `EXPORT_FORMATS`.
///
/// An ORDERED array, not a `[String: ExportFormat]`, and that is not a style preference: Python's
/// dict is insertion-ordered and both UI menus (web/index.html and the AppKit sidebar) list the
/// six in exactly this order. A Swift `Dictionary` has no iteration order, so keying it would
/// silently throw that away and leave the menu shuffling between launches — the same information
/// loss `SourceSpec.readArgs`' doc comment bans for `columns=`. Look a key up with
/// `exportFormat(named:)`; six linear comparisons is not a cost worth a second data structure.
public let exportFormats: [ExportFormat] = [
    ExportFormat(key: "parquet", copyOptions: "(FORMAT parquet, COMPRESSION zstd)", ext: "parquet"),
    ExportFormat(key: "csv", copyOptions: "(FORMAT csv, HEADER)", ext: "csv"),
    // The delimiter is a real tab character, matching Python's `'\t'` inside a non-raw string.
    ExportFormat(key: "tsv", copyOptions: "(FORMAT csv, HEADER, DELIMITER '\t')", ext: "tsv"),
    ExportFormat(key: "json", copyOptions: "(FORMAT json, ARRAY true)", ext: "json"),
    ExportFormat(key: "ndjson", copyOptions: "(FORMAT json)", ext: "ndjson"),
    // Needs the excel extension, which `Session.init` loads.
    ExportFormat(key: "xlsx", copyOptions: "(FORMAT xlsx, HEADER true)", ext: "xlsx"),
]

/// Look up a format by key, case-insensitively (Python's `EXPORT_FORMATS.get(fmt.lower(), ...)`).
///
/// `lowercased()` without a `Locale`, deliberately: Swift's is the locale-independent root
/// mapping, so "XLSX" resolves the same in Istanbul as in Kansas City. This is the one place a
/// caller-supplied string is compared against anything, and it is compared — never interpolated.
public func exportFormat(named key: String) -> ExportFormat? {
    let wanted = key.lowercased()
    return exportFormats.first { $0.key == wanted }
}

/// What one export wrote. `milliseconds` is rounded to one decimal, matching every other timing
/// this engine reports.
public struct ExportResult: Sendable, Equatable {
    public let dest: String
    public let format: String
    public let bytes: Int
    public let milliseconds: Double
}

/// The LIMIT `pageSQL` is handed for a whole-table export: `2**62`, ported verbatim from Python.
/// `pageSQL` always emits `LIMIT ? OFFSET ?`, so "no limit" has to be spelled as a number bigger
/// than any table; this one still fits in the `Int64` the parameter binds as.
private let exportRowCap = 1 << 62

// MARK: - Session

extension Session {

    /// Write the current result to disk. Ported from Python's `export`.
    ///
    /// See this file's header for the three rules this is holding. The ordering below differs
    /// from Python's on purpose: everything that can be rejected — the table, the format, the
    /// SELECT-only re-check — is rejected BEFORE anything touches the filesystem. Python looks
    /// the format up last, after `os.makedirs` has already run, so `export(fmt="parqet")` leaves
    /// a directory tree behind for a call that was never going to write a file.
    @discardableResult
    public func export(
        _ name: String, dest: String, format: String = "parquet", overwrite: Bool = false
    ) async throws -> ExportResult {
        let t = try table(name)
        guard let output = exportFormat(named: format) else {
            throw SessionError("Unsupported export format '\(format)'.")
        }

        let inner: String
        let params: [SQLValue]
        if t.sqlMode, let text = t.sqlText {
            // Rule 1. Re-checked here, not trusted from `runSQL`. `relation(t)` produces the
            // identical `(\n<text>\n) AS _q` wrap Python spells inline, and it is the same wrap
            // `page`/`computeProfile` read this table through — one definition, not two.
            try assertSelectOnly(text)
            inner = "SELECT * FROM \(relation(t))"
            params = []
        } else {
            (inner, params) = try pageSQL(
                t.qspec, cols: t.cols, rel: q(t.name), limit: exportRowCap, offset: 0
            )
        }

        let path = Self.absolutePath(dest)
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory.isEmpty ? "." : directory, withIntermediateDirectories: true
            )
        } catch {
            throw SessionError("Cannot create \(directory): \(error.localizedDescription)")
        }

        // Rule 3. Claiming the name IS the existence check — no check-then-write window.
        //
        // The cost, stated rather than hidden: this opens a *different*, smaller window Python
        // does not have. A crash or SIGKILL between the claim and the COPY leaves a zero-byte
        // file that blocks its own retry with "already exists" until the user deletes it. Judged
        // the better trade by a wide margin — a lost check-then-write race silently destroys
        // someone's file, while a stale placeholder is one visible, empty, deletable file.
        var claimed = false
        if !overwrite {
            do {
                try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                claimed = true
            } catch {
                // Whatever the underlying errno, if something is sitting there now this is the
                // sentence the user needs — including when the exclusive create lost a race, the
                // case Python's `os.path.exists` cannot see at all.
                if FileManager.default.fileExists(atPath: path) {
                    throw SessionError("\(path) already exists. Tick overwrite to replace it.")
                }
                throw SessionError("Cannot write \(path): \(error.localizedDescription)")
            }
        }
        // Leave the destination exactly as it was found if the COPY does not happen. Only ever
        // removes the zero-byte placeholder this call just created — never a pre-existing file,
        // which by definition could not have been claimed.
        var wrote = false
        defer {
            if claimed && !wrote { try? FileManager.default.removeItem(atPath: path) }
        }

        // Rule 2. Every part of this string is either a constant or already-escaped: `inner` is
        // SQLGen's own output over quoted identifiers, `qlit(path)` doubles embedded quotes, and
        // `copyOptions` is a literal from the table above. Values ride as bound parameters.
        let sql = "COPY (\(inner)) TO \(qlit(path)) \(output.copyOptions)"
        do {
            let con = try database.connect()
            let started = DispatchTime.now()
            _ = try con.query(sql, params.map(toDBValue))
            let milliseconds = millisecondsSince(started)
            wrote = true
            return ExportResult(
                dest: path, format: output.key, bytes: fileSize(path), milliseconds: milliseconds
            )
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }

    /// `os.path.abspath(os.path.expanduser(dest))`: expand `~`, resolve against the working
    /// directory, and collapse `.`/`..`.
    ///
    /// `URL.standardizedFileURL`, NOT the `NSString.standardizingPath` this reads like a job for.
    /// MEASURED, the two agree on every absolute input tried (including under a symlinked temp
    /// directory) and differ on exactly one thing that matters: `standardizingPath` leaves a
    /// RELATIVE path relative. `abspath` never does, and neither can this — DuckDB would resolve
    /// the relative path against the process working directory while `ExportResult.dest` handed
    /// the caller back a string that names no particular file.
    static func absolutePath(_ dest: String) -> String {
        URL(fileURLWithPath: (dest as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
