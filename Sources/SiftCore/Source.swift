import Foundation

// Turning a path into a queryable relation: format detection, parquet/Delta metadata, hive
// layout, and row estimation. Ported from the pure half of engine/core/source.py.
//
// Functions that need to ask DuckDB something (sniff_csv, parquet_footer, exact_count,
// _describe, and build_source itself) stay behind for Plan 3, which has a connection to give
// them. SiftCore imports Foundation only, so nothing here ever touches a Connection.

/// The path is a format Sift cannot open, with a message aimed at the user. Mirrors Python's
/// `class UnsupportedSource(ValueError)`.
public struct UnsupportedSource: SiftError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A legacy `.xls` file (or something else entirely, saved with an `.xls` name). Mirrors
/// Python's `class LegacyXls(UnsupportedSource)`. Swift errors don't subclass, so this is its
/// own type rather than a case of `UnsupportedSource` — callers that need to tell "refuse and
/// suggest re-saving as .xlsx" apart from every other refusal catch this specifically.
public struct LegacyXls: SiftError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Time travel was requested against a spec that isn't Delta. Mirrors Python's bare
/// `raise ValueError("time travel only applies to Delta tables")`.
public struct TimeTravelUnsupported: SiftError, Equatable {
    public var description: String { "time travel only applies to Delta tables" }
    public init() {}
}

// MARK: - path helpers
//
// `pathName`/`pathSuffix`/`pathStem` come from Ident.swift — this file used to carry its own
// line-for-line copy of the first two. See the note above them there, including the lone-"."
// component gap that had quietly been duplicated into both copies.

/// Return (data extension, is_compressed), seeing through a compression suffix. Mirrors
/// source.py's `_ext_chain`.
private func extChain(_ path: String) -> (ext: String, compressed: Bool) {
    let name = pathName(path)
    let suf = pathSuffix(name).lowercased()
    guard compressionExt.contains(suf) else { return (suf, false) }
    return (pathSuffix(pathStem(name)).lowercased(), true)
}

// MARK: - format detection

/// A Delta table is a directory carrying a `_delta_log/`.
///
/// Why this check exists at all: globbing a Delta table's parquet files is *wrong*. The log's
/// `remove` actions tombstone files that are still physically present, so a raw glob resurrects
/// deleted rows and double-counts updated ones. Measured on a two-version fixture: raw glob 150
/// rows, delta_scan 100. That failure looks like a data bug, not a tool bug, which is exactly
/// why it has to be caught here.
public func isDeltaDir(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let logPath = (path as NSString).appendingPathComponent("_delta_log")
    return FileManager.default.fileExists(atPath: logPath, isDirectory: &isDir) && isDir.boolValue
}

/// Recursively list files under `directory` whose lowercased extension is `ext` (e.g.
/// ".parquet"), sorted lexicographically. The one thing `detectFormat`'s directory branch and
/// `hiveKeys` need from Python's `glob.glob(os.path.join(dir, "**", f"*{ext}"), recursive=True)`:
/// which files exist, not glob's full pattern language.
///
/// `public`: Plan 3's `buildSource` glob branch needs this same recursive list twice — to feed
/// `hiveKeys(directory:files:)`, which is already public and useless without it, and to pick
/// `files[0]` for its `_describe`. It was internal by test convenience, not by design.
public func filesWithExtension(_ ext: String, under directory: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let lowerExt = ext.lowercased()
    var hits: [String] = []
    for case let url as URL in enumerator {
        let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isRegular, "." + url.pathExtension.lowercased() == lowerExt else { continue }
        hits.append(url.path)
    }
    return hits.sorted()
}

private func hasAnyFile(under directory: String, extensions: Set<String>) -> Bool {
    for ext in extensions.sorted() where !filesWithExtension(ext, under: directory).isEmpty {
        return true
    }
    return false
}

/// Classify a path by magic bytes first, extension second.
///
/// Magic bytes win because a `.csv` that is really an Excel file (or an HTML error page saved
/// with the wrong name) is a genuinely common way to receive data.
public func detectFormat(_ path: String) throws -> Fmt {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        if isDeltaDir(path) { return .delta }
        if hasAnyFile(under: path, extensions: parquetExt) { return .globParquet }
        if hasAnyFile(under: path, extensions: csvExt) { return .globCsv }
        throw UnsupportedSource(
            "\(pathName(path)) is a folder with no .parquet or .csv files in it."
        )
    }

    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw UnsupportedSource("Cannot read \(path): file not found or not readable")
    }
    let head = handle.readData(ofLength: 8)
    try? handle.close()

    if head.starts(with: [0x50, 0x41, 0x52, 0x31]) {   // "PAR1"
        return .parquet
    }
    if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
        // OLE2 container: legacy .xls (or .doc/.ppt). read_xlsx cannot touch it, and there is
        // no Swift equivalent of openpyxl or xlrd for a format on its way out.
        throw LegacyXls(
            "\(pathName(path)) is a legacy .xls file. Open it and re-save as .xlsx — "
                + "Sift reads the modern format only."
        )
    }
    if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {   // "PK\x03\x04"
        // A zip container. .xlsx is the case we care about; anything else is not tabular.
        let (ext, _) = extChain(path)
        if xlsxExt.contains(ext) { return .xlsx }
        throw UnsupportedSource("\(pathName(path)) looks like a zip archive, not a data file.")
    }

    let (ext, _) = extChain(path)
    if parquetExt.contains(ext) { return .parquet }
    if ndjsonExt.contains(ext) { return .ndjson }
    if jsonExt.contains(ext) { return .json }
    if xlsxExt.contains(ext) { return .xlsx }
    if xlsExt.contains(ext) {
        throw LegacyXls("\(pathName(path)) is a legacy .xls file. Re-save it as .xlsx.")
    }
    if csvExt.contains(ext) { return .csv }

    // No usable extension. Sniff the first bytes for JSON, else assume delimited text —
    // DuckDB's sniffer is good enough that guessing CSV is a reasonable last resort.
    let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]
    if let first = head.first(where: { !whitespace.contains($0) }), first == 0x7B || first == 0x5B {
        return .json
    }
    return .csv
}

/// Escape glob metacharacters in a literal directory path.
///
/// A folder named "data[2026]" would otherwise be interpreted as a character class and
/// silently match nothing.
public func globEscape(_ path: String) -> String {
    var out = ""
    out.reserveCapacity(path.count)
    for ch in path {
        switch ch {
        case "[", "]", "*", "?":
            out.append("[")
            out.append(ch)
            out.append("]")
        default:
            out.append(ch)
        }
    }
    return out
}

// MARK: - parquet and delta

/// Latest committed version, read from the `_delta_log` filenames. Pure filesystem — no
/// connection needed — so it ports here even though `Interfaces produced` in the task brief
/// didn't name it; it's neither in that list nor in the deferred-to-Plan-3 list, and it would be
/// silly to make Plan 3 write a directory-listing regex when nothing about it depends on DuckDB.
public func deltaVersion(_ path: String) -> Int? {
    let logDir = (path as NSString).appendingPathComponent("_delta_log")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return nil }
    let versions = names.compactMap { name -> Int? in
        guard name.hasSuffix(".json") else { return nil }
        let digits = name.dropLast(5)   // drop ".json"
        guard digits.count == 20, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
    return versions.max()
}

// MARK: - hive layout

/// The directory component of `file`, relative to `directory`, split on "/". Mirrors
/// `os.path.dirname(os.path.relpath(file, directory))` for the one case source.py needs it in:
/// `file` is always physically under `directory` (found by a glob rooted there).
private func relativeDirParts(of file: String, from directory: String) -> [Substring] {
    var dir = directory
    while dir.hasSuffix("/") { dir.removeLast() }
    var rel = Substring(file)
    if rel.hasPrefix(dir + "/") {
        rel = rel.dropFirst(dir.count + 1)
    }
    guard let slash = rel.lastIndex(of: "/") else { return [] }
    return rel[rel.startIndex..<slash].split(separator: "/", omittingEmptySubsequences: true)
}

/// The key half of one hive `key=value` path segment, or nil if the segment isn't of that
/// shape. Mirrors what `HIVE_KV = re.compile(r"([^/=]+)=([^/]+)")` matches within a single
/// "/"-delimited segment: a non-empty key, then "=", then a non-empty value (which may itself
/// contain "=" — only the first "=" is the separator).
private func hiveKey(_ segment: Substring) -> String? {
    guard let eq = segment.firstIndex(of: "="), eq != segment.startIndex,
        segment.index(after: eq) != segment.endIndex
    else { return nil }
    return String(segment[segment.startIndex..<eq])
}

/// Partition keys, but only if EVERY file carries the identical key set.
///
/// DuckDB errors out on `hive_partitioning := true` when the layout is inconsistent, so a
/// half-partitioned directory must be read as a plain glob instead.
public func hiveKeys(directory: String, files: [String]) -> [String] {
    let keysets = files.map { relativeDirParts(of: $0, from: directory).compactMap(hiveKey) }
    guard let first = keysets.first, !first.isEmpty else { return [] }
    return keysets.allSatisfy { $0 == first } ? first : []
}

// MARK: - row estimation

/// The subset of `sniff_csv`'s output that `headerByteOffset` needs. Full CSV sniffing needs a
/// DuckDB connection (`sniff_csv`) and stays behind for Plan 3; this is the seam Plan 3 will
/// populate from the real sniff result.
public struct SniffHints: Sendable, Equatable {
    public let skip: Int
    public let header: Bool
    public init(skip: Int, header: Bool) {
        self.skip = skip
        self.header = header
    }
}

/// Estimate row count from byte samples, in a few milliseconds regardless of file size.
///
/// An exact `count(*)` on a multi-GB CSV is a full parallel parse (seconds), which is far too
/// slow for first paint. So sample three windows, average bytes-per-row, and extrapolate.
///
/// Confidence is `low` whenever a quote character appears anywhere in the sample: a quoted
/// field containing a newline makes line-counting overshoot, and there is no cheap way to tell
/// how often that happens. The UI shows low-confidence estimates with visible uncertainty
/// rather than pretending.
public func estimateRows(
    path: String, headerBytes: Int = 0, chunks: Int = 3, chunkBytes: Int = 262_144
) -> RowEstimate {
    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
    let dataBytes = max(0, size - headerBytes)
    if dataBytes <= 0 {
        return RowEstimate(rows: 0, confidence: .exact, basis: "file has no data past the header")
    }

    guard let handle = FileHandle(forReadingAtPath: path) else {
        return RowEstimate(rows: 0, confidence: .low, basis: "sampling found no line breaks")
    }
    defer { try? handle.close() }

    // Small enough to read entirely. Even then the answer is only exact if nothing is quoted: a
    // quoted field containing a newline makes physical lines exceed logical rows. Callers should
    // prefer an exact count at this size — this branch stays honest for when they don't.
    if dataBytes <= chunks * chunkBytes {
        handle.seek(toFileOffset: UInt64(headerBytes))
        let buf = handle.readDataToEndOfFile()
        var n = countBytes(0x0A, in: buf)
        if !buf.isEmpty && buf.last != 0x0A { n += 1 }
        if buf.contains(0x22) {
            return RowEstimate(
                rows: n, confidence: .low,
                basis: "counted \(grouped(Double(n), decimals: 0)) line breaks in "
                    + "\(grouped(Double(size), decimals: 0)) B, but quote characters are "
                    + "present so some may be inside quoted fields"
            )
        }
        return RowEstimate(
            rows: n, confidence: .exact, basis: "counted every byte (\(grouped(Double(size), decimals: 0)) B)"
        )
    }

    let step = Double(dataBytes - chunkBytes) / Double(max(1, chunks - 1))
    var lines = 0, sampled = 0, quotes = 0
    for i in 0..<chunks {
        let off = headerBytes + Int(Double(i) * step)
        handle.seek(toFileOffset: UInt64(off))
        var buf = handle.readData(ofLength: chunkBytes)
        if buf.isEmpty { continue }
        if i > 0 {
            guard let nl = buf.firstIndex(of: 0x0A) else { continue }   // drop the leading partial line
            buf = buf[(nl + 1)...]
        }
        guard let nl = buf.lastIndex(of: 0x0A) else { continue }        // drop the trailing partial line
        buf = buf[...nl]
        lines += countBytes(0x0A, in: buf)
        sampled += buf.count
        quotes += countBytes(0x22, in: buf)
    }

    if lines == 0 || sampled == 0 {
        return RowEstimate(rows: 0, confidence: .low, basis: "sampling found no line breaks")
    }

    let bytesPerRow = Double(sampled) / Double(lines)
    let rows = Int(Double(dataBytes) / bytesPerRow)
    let kib = chunkBytes / 1024
    if quotes == 0 {
        return RowEstimate(
            rows: rows, confidence: .high, basis: "\(chunks)x\(kib)KiB sample, no quote characters seen"
        )
    }
    return RowEstimate(
        rows: rows, confidence: .low,
        basis: "\(chunks)x\(kib)KiB sample; \(grouped(Double(quotes), decimals: 0)) quote "
            + "characters seen, so quoted newlines may inflate this"
    )
}

private func countBytes(_ byte: UInt8, in data: Data) -> Int {
    data.reduce(0) { $0 + ($1 == byte ? 1 : 0) }
}

/// Bytes occupied by skipped rows plus the header, so estimation starts at real data.
public func headerByteOffset(path: String, sniff: SniffHints) -> Int {
    let skip = sniff.skip + (sniff.header ? 1 : 0)
    if skip <= 0 { return 0 }
    guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
    defer { try? handle.close() }
    var seen = 0
    for _ in 0..<skip {
        let line = readLine(from: handle)
        if line.isEmpty { break }
        seen += line.count
    }
    return seen
}

/// Read up to and including the next "\n", or whatever remains at EOF. Empty only at EOF with
/// nothing left to read — mirrors Python's binary-mode `f.readline()`.
private func readLine(from handle: FileHandle) -> Data {
    var line = Data()
    while true {
        // try? on a throwing `Data?`-returning call flattens to `Data?`: nil on either an I/O
        // error or a clean EOF, which is the same "stop" signal Python's `f.readline() == b""`
        // gives at the end of the loop.
        guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else { break }
        line.append(byte)
        if byte[byte.startIndex] == 0x0A { break }
    }
    return line
}

// MARK: - building read expressions

private func formatReadArg(_ arg: ReadArg) -> String {
    switch arg {
    case .bool(let v): return v ? "true" : "false"
    case .int(let v): return String(v)
    case .text(let v): return qlit(v)
    }
}

/// The `columns={name: type, ...}` argument, in exactly `columns`' order.
///
/// LANDMINE, see Types.swift's `ReadArg`: this must be built from the ordered `[Column]` array,
/// never from a `[String: ReadArg]`/dictionary. `read_csv(columns={...})` disables
/// auto-detection and binds each entry *positionally* against the file, so file-column order is
/// a correctness dependency, not cosmetics — a Swift `Dictionary` has no defined iteration
/// order, and rendering one here would silently assign the wrong type to the wrong column.
private func columnsArgValue(_ columns: [Column]) -> String {
    "{" + columns.map { "\(qlit($0.name)): \(qlit($0.type))" }.joined(separator: ", ") + "}"
}

/// The FROM-clause expression for this source.
///
/// Options are baked in explicitly rather than relying on `read_csv_auto`, so no later query
/// re-sniffs the file. That is the single largest first-paint win for CSV.
///
/// With `allVarchar: true`, no casting happens at all — which is how Sift gets the *physical*
/// row count and finds uncastable cells. It's also the one-click escape hatch when the sniffer
/// guesses a type wrong.
public func readExpr(spec: SourceSpec, allVarchar: Bool = false) -> String {
    var parts: [String] = [qlit(spec.target)]
    for key in spec.readArgs.keys.sorted() {
        parts.append("\(key)=\(formatReadArg(spec.readArgs[key]!))")
    }
    // Only the plain CSV format's read_args carry an implicit columns= clause (glob_csv's
    // read_fn is also "read_csv", but never gets one — see build_source's glob branch, which
    // stays behind for Plan 3). all_varchar drops all casting, columns included. An empty
    // `columns` array renders `columns={}`, which DuckDB rejects at parse time — Python never
    // emits the argument at all when there's nothing to put in it, gating on `cols` being
    // non-empty rather than only on format, so this mirrors that gate rather than assuming
    // build_source never produces an empty column list.
    if spec.fmt == .csv, !allVarchar, !spec.columns.isEmpty {
        parts.append("columns=\(columnsArgValue(spec.columns))")
    }
    if allVarchar, spec.readFn == "read_csv" || spec.readFn == "read_xlsx" {
        parts.append("all_varchar=true")
    }
    return "\(spec.readFn)(\(parts.joined(separator: ", ")))"
}

/// Delta time travel. Measured: `version => n` works, `AT (VERSION => n)` does not parse.
public func readExprAt(spec: SourceSpec, version: Int) throws -> String {
    guard spec.fmt == .delta else { throw TimeTravelUnsupported() }
    return "delta_scan(\(qlit(spec.target)), version=\(version))"
}

/// Only text-ish sources can produce cast failures.
///
/// Parquet and Delta carry real types in their metadata, so there is no sniffing to get wrong
/// and no reject count to compute — physical rows always equal typed rows.
public func supportsAllVarchar(_ spec: SourceSpec) -> Bool {
    spec.fmt == .csv || spec.fmt == .globCsv || spec.fmt == .xlsx
}

public func createViewSQL(name: String, spec: SourceSpec, allVarchar: Bool = false) -> String {
    "CREATE OR REPLACE VIEW \(q(name)) AS SELECT * FROM \(readExpr(spec: spec, allVarchar: allVarchar))"
}
