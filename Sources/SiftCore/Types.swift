import Foundation

// Shared value types for Sift. Pure: no DuckDBKit, no networking, no I/O, so everything here
// stays testable without a connection or a server. Ported from engine/core/types.py.

// MARK: - Literal unions promoted to enums

/// Coarse type bucket the UI branches on (alignment, histogram-vs-top-N, cell rendering).
public enum Kind: String, Sendable {
    case number, text, temporal, bool, nested, blob, other
}

// Fmt and Op keep Python's exact snake_case/symbol raw values rather than Swift's default
// (which would encode .globCsv as "globCsv", .notIn as "notIn"). Two real, still-live reasons,
// not aesthetics: sqlgen.py interpolates f.op directly into SQL text (`f"{c} {f.op} ?"`), so a
// later port can render a filter as `op.rawValue` only because the raw value *is* the SQL
// operator/keyword; and stage.py's CATALOG_DDL persists `fmt VARCHAR` into an on-disk staging
// table, so the string that round-trips through storage has to match what was written before.

public enum Fmt: String, Sendable {
    case csv, parquet, json, ndjson, xlsx, delta
    case globParquet = "glob_parquet"
    case globCsv = "glob_csv"
    /// A derived view over two other tables, not a file on disk.
    case merge
}

public enum Confidence: String, Sendable {
    case exact, high, low
}

public enum Op: String, Sendable {
    case eq = "="
    case ne = "!="
    case lt = "<"
    case le = "<="
    case gt = ">"
    case ge = ">="
    case inList = "in"
    case notIn = "not_in"
    case contains
    case isNull = "is_null"
    case notNull = "not_null"
    case isEmpty = "is_empty"
    case between

    /// Ops that carry no values: the UI renders no input, whereClause() binds nothing.
    public static let nullary: Set<Op> = [.isNull, .notNull, .isEmpty]
}

// MARK: - Extensions Sift recognizes

// The extensions Sift recognizes, defined ONCE. Source detection uses the per-format sets to
// detect a format; ident derivation strips dataExt + compressionExt to derive a table name. Kept
// together so the two never drift (they had: .br and .tab were each in only one of the old copies).
public let csvExt: Set<String> = [".csv", ".tsv", ".txt", ".psv", ".tab"]
public let parquetExt: Set<String> = [".parquet", ".parq", ".pq"]
public let ndjsonExt: Set<String> = [".ndjson", ".jsonl"]
public let jsonExt: Set<String> = [".json"]
public let xlsxExt: Set<String> = [".xlsx", ".xlsm"]
public let xlsExt: Set<String> = [".xls"]
public let compressionExt: Set<String> = [".gz", ".gzip", ".zst", ".zstd", ".bz2", ".xz", ".br"]
public let dataExt: Set<String> = csvExt.union(parquetExt).union(ndjsonExt).union(jsonExt)
    .union(xlsxExt).union(xlsExt)

// MARK: - Type classification

/// Classify a DuckDB type string into the buckets the UI branches on (alignment,
/// histogram-vs-top-N, cell rendering). Deliberately coarse; the exact string is kept for display.
public func kind(of duckdbType: String) -> Kind {
    let t = duckdbType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Nesting first — ordering is load-bearing: STRUCT(a INTEGER) contains the word INTEGER.
    if t == "JSON" || t.hasSuffix("]") || t.hasPrefix("STRUCT") || t.hasPrefix("MAP")
        || t.hasPrefix("UNION") || t.hasPrefix("LIST") || t.hasPrefix("ARRAY") {
        return .nested
    }
    if ["BLOB", "BYTEA", "BINARY", "VARBINARY", "BIT"].contains(t) {
        return .blob
    }
    if t == "BOOLEAN" {
        return .bool
    }
    if t.hasPrefix("TIMESTAMP") || t.hasPrefix("DATE") || t.hasPrefix("TIME")
        || t.hasPrefix("INTERVAL") {
        return .temporal
    }
    if t.hasPrefix("DECIMAL") || t.hasPrefix("NUMERIC") || [
        "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "REAL", "DOUBLE",
    ].contains(t) {
        return .number
    }
    if ["VARCHAR", "CHAR", "TEXT", "STRING", "UUID"].contains(t) || t.hasPrefix("ENUM") {
        return .text
    }
    return .other
}

// needs_string_transport is deliberately not ported: it existed only to flag values that must be
// JSON-encoded as strings to survive JavaScript's 2**53-1 integer ceiling. There is no JSON/JS
// wire format anymore, so BIGINT and friends never have to cross as strings in the first place.

// MARK: - Bound query parameters

/// A bound query parameter. Mirrors DuckDBKit's `DBValue` case-for-case, and is a
/// separate type on purpose: SiftCore imports Foundation only, and DuckDBKit is a
/// standalone wrapper that must not learn about Sift. SiftEngine imports both and
/// maps between them in one switch.
public enum SQLValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
}

// MARK: - Source identity

/// Identity of a file at a point in time. Deliberately (path, mtime, size), not a content
/// hash — hashing 10 GB to decide whether a cache entry is warm defeats the purpose.
public struct SourceKey: Sendable, Equatable {
    public let path: String
    public let mtimeNs: Int
    public let size: Int

    public init(path: String, mtimeNs: Int, size: Int) {
        self.path = path
        self.mtimeNs = mtimeNs
        self.size = size
    }

    public func token() -> String {
        "\(path):\(mtimeNs):\(size)"
    }
}

public struct RowEstimate: Sendable, Equatable {
    public let rows: Int
    public let confidence: Confidence
    /// Human-readable, shown on hover: "3x256KiB sample, no quotes seen".
    public let basis: String

    public init(rows: Int, confidence: Confidence, basis: String) {
        self.rows = rows
        self.confidence = confidence
        self.basis = basis
    }
}

public struct Column: Sendable, Equatable {
    public let name: String
    public let type: String
    public let kind: Kind

    public init(name: String, type: String) {
        self.name = name
        self.type = type
        self.kind = SiftCore.kind(of: type)
    }
}

public struct SheetInfo: Sendable, Equatable {
    public let name: String
    public let rows: Int
    public let cols: Int

    public init(name: String, rows: Int, cols: Int) {
        self.name = name
        self.rows = rows
        self.cols = cols
    }

    /// openpyxl reports a blank sheet as 1x1 with a None cell; treat <=1 row as nothing to see.
    public var empty: Bool { rows <= 1 || cols < 1 }
}

/// One value bound into the DuckDB table function a source resolves to (e.g. `read_csv(path,
/// delim=',', header=true)`). Python holds these as `dict[str, Any]`; Swift needs the shapes
/// spelled out because `Any` is neither `Sendable` nor `Equatable`.
///
/// LANDMINE: this deliberately has no case for the CSV column-type override map
/// (`read_args["columns"]`, a `dict[str, str]` in Python). Do NOT add `case columns([String:
/// String])` to cover it. `build_source` builds that map as `{c.name: c.type for c in cols}` in
/// file-column order and relies on Python dicts being insertion-ordered; DuckDB's
/// `read_csv(columns={...})` disables header-name matching entirely and binds each entry
/// *positionally* against the file using that order. A Swift `Dictionary` has no defined
/// iteration order, so storing this map in one and rendering it back out would silently assign
/// the wrong type to the wrong column — a plausible-wrong-value bug, in the one product whose
/// entire premise is not lying about data. `SourceSpec.columns` below is already an ordered
/// `[Column]` holding exactly the (name, type) pairs `columns=` needs — derive the argument from
/// that directly when porting source.py's `read_expr`, and never store it in `readArgs`.
public enum ReadArg: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case text(String)
}

/// Everything needed to build a relation over a file, without re-sniffing it.
public struct SourceSpec: Sendable, Equatable {
    public let key: SourceKey
    public let fmt: Fmt
    /// read_csv | read_parquet | read_json_auto | read_xlsx | delta_scan
    public let readFn: String
    public let readArgs: [String: ReadArg]
    public let columns: [Column]
    /// Exact and free (parquet footer, delta log).
    public let rowCount: Int?
    public let rowEstimate: RowEstimate?
    public let compressed: Bool
    /// xlsx only.
    public let sheet: String?
    public let sheets: [SheetInfo]
    public let deltaVersion: Int?
    /// sniff_csv's own reproducible FROM clause, for display.
    public let sniffPrompt: String?
    /// The pattern actually handed to read_parquet/read_csv.
    public let glob: String?

    public init(
        key: SourceKey, fmt: Fmt, readFn: String, readArgs: [String: ReadArg] = [:],
        columns: [Column] = [], rowCount: Int? = nil, rowEstimate: RowEstimate? = nil,
        compressed: Bool = false, sheet: String? = nil, sheets: [SheetInfo] = [],
        deltaVersion: Int? = nil, sniffPrompt: String? = nil, glob: String? = nil
    ) {
        self.key = key
        self.fmt = fmt
        self.readFn = readFn
        self.readArgs = readArgs
        self.columns = columns
        self.rowCount = rowCount
        self.rowEstimate = rowEstimate
        self.compressed = compressed
        self.sheet = sheet
        self.sheets = sheets
        self.deltaVersion = deltaVersion
        self.sniffPrompt = sniffPrompt
        self.glob = glob
    }

    /// The path or glob the read function is pointed at.
    public var target: String { glob ?? key.path }
}

// MARK: - Queries

public struct Filter: Sendable, Equatable {
    public let col: String
    public let op: Op
    public let values: [SQLValue]

    public init(col: String, op: Op, values: [SQLValue] = []) {
        self.col = col
        self.op = op
        self.values = values
    }
}

public struct QuerySpec: Sendable, Equatable {
    public enum SortDirection: String, Sendable {
        case asc, desc
    }

    public struct SortTerm: Sendable, Equatable {
        public let column: String
        public let direction: SortDirection

        public init(column: String, direction: SortDirection) {
            self.column = column
            self.direction = direction
        }
    }

    public let relation: String
    public let filters: [Filter]
    public let sort: [SortTerm]

    public init(relation: String, filters: [Filter] = [], sort: [SortTerm] = []) {
        self.relation = relation
        self.filters = filters
        self.sort = sort
    }

    /// Drop one column's filters — the faceting rule for the distinct panel: clicking
    /// "West" must not make the region panel show only West.
    public func withoutColumn(_ col: String) -> QuerySpec {
        QuerySpec(relation: relation, filters: filters.filter { $0.col != col }, sort: sort)
    }
}

// MARK: - Profiling and staging

public struct ColumnProfile: Sendable, Equatable {
    public enum View: String, Sendable {
        case topn, hist, highcard
    }

    public let name: String
    public let type: String
    public let kind: Kind
    public let n: Int
    public let nNull: Int
    public let nEmpty: Int
    /// NA / N/A / - / ? / whitespace-only.
    public let nNullish: Int
    public let approxDistinct: Int
    public let exactDistinct: Int?
    public let minS: String?
    public let maxS: String?
    public let avg: Double?
    public let std: Double?
    public let q25: String?
    public let q50: String?
    public let q75: String?
    public let maxLen: Int?
    /// Cells that fail TRY_CAST to the sniffed type.
    public let nUncastable: Int
    public let view: View

    public init(
        name: String, type: String, kind: Kind, n: Int = 0, nNull: Int = 0, nEmpty: Int = 0,
        nNullish: Int = 0, approxDistinct: Int = 0, exactDistinct: Int? = nil,
        minS: String? = nil, maxS: String? = nil, avg: Double? = nil, std: Double? = nil,
        q25: String? = nil, q50: String? = nil, q75: String? = nil, maxLen: Int? = nil,
        nUncastable: Int = 0, view: View = .topn
    ) {
        self.name = name
        self.type = type
        self.kind = kind
        self.n = n
        self.nNull = nNull
        self.nEmpty = nEmpty
        self.nNullish = nNullish
        self.approxDistinct = approxDistinct
        self.exactDistinct = exactDistinct
        self.minS = minS
        self.maxS = maxS
        self.avg = avg
        self.std = std
        self.q25 = q25
        self.q50 = q50
        self.q75 = q75
        self.maxLen = maxLen
        self.nUncastable = nUncastable
        self.view = view
    }
}

public struct StageDecision: Sendable, Equatable {
    public let stage: Bool
    public let reason: String
    public let estSeconds: Double
    public let needsConfirm: Bool

    public init(stage: Bool, reason: String, estSeconds: Double = 0.0, needsConfirm: Bool = false) {
        self.stage = stage
        self.reason = reason
        self.estSeconds = estSeconds
        self.needsConfirm = needsConfirm
    }
}
