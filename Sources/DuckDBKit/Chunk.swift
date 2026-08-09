import CDuckDB
import Foundation

extension ResultSet {
    /// The next chunk, or nil when the result is exhausted.
    ///
    /// `duckdb_fetch_chunk` takes the result BY VALUE, not by pointer — passing a
    /// pointer compiles and then misbehaves, so the copy here is deliberate.
    public func nextChunk() -> Chunk? {
        guard let raw = duckdb_fetch_chunk(result) else { return nil }
        let size = Int(duckdb_data_chunk_get_size(raw))
        if size == 0 {
            var c: duckdb_data_chunk? = raw
            duckdb_destroy_data_chunk(&c)
            return nil
        }
        return Chunk(handle: raw, rowCount: size, columns: columns)
    }

    /// Every row. Only for bounded results — Sift pages the grid instead.
    public func allRows() throws -> [[Cell]] {
        var out: [[Cell]] = []
        while let chunk = nextChunk() {
            out.append(contentsOf: chunk.rows())
            chunk.destroy()
        }
        return out
    }
}

/// One columnar batch. Decoding reads each vector's data pointer and validity mask
/// directly — no per-value allocation on the way in, which is the whole reason this
/// path is faster than the JSON one it replaces.
public struct Chunk {
    let handle: duckdb_data_chunk
    public let rowCount: Int
    let columns: [ColumnMeta]

    public func destroy() {
        var c: duckdb_data_chunk? = handle
        duckdb_destroy_data_chunk(&c)
    }

    public func rows() -> [[Cell]] {
        var byColumn: [[Cell]] = []
        byColumn.reserveCapacity(columns.count)
        for (i, meta) in columns.enumerated() {
            byColumn.append(decodeColumn(i, meta))
        }
        var out = [[Cell]](repeating: [], count: rowCount)
        for r in 0..<rowCount {
            out[r] = byColumn.map { $0[r] }
        }
        return out
    }

    private func decodeColumn(_ index: Int, _ meta: ColumnMeta) -> [Cell] {
        let vector = duckdb_data_chunk_get_vector(handle, idx_t(index))
        let validity = duckdb_vector_get_validity(vector)
        guard let data = duckdb_vector_get_data(vector) else {
            return [Cell](repeating: .null, count: rowCount)
        }

        var out = [Cell](repeating: .null, count: rowCount)
        for r in 0..<rowCount {
            if let validity, !duckdb_validity_row_is_valid(validity, idx_t(r)) {
                continue   // already .null
            }
            out[r] = decodeOne(data: data, row: r, meta: meta)
        }
        return out
    }

    private func decodeOne(data: UnsafeMutableRawPointer, row r: Int, meta: ColumnMeta) -> Cell {
        switch meta.typeID {
        case DUCKDB_TYPE_BOOLEAN:
            return .bool(data.assumingMemoryBound(to: Bool.self)[r])
        case DUCKDB_TYPE_TINYINT:
            return .int(Int64(data.assumingMemoryBound(to: Int8.self)[r]))
        case DUCKDB_TYPE_SMALLINT:
            return .int(Int64(data.assumingMemoryBound(to: Int16.self)[r]))
        case DUCKDB_TYPE_INTEGER:
            return .int(Int64(data.assumingMemoryBound(to: Int32.self)[r]))
        case DUCKDB_TYPE_BIGINT:
            return .int(data.assumingMemoryBound(to: Int64.self)[r])
        case DUCKDB_TYPE_UTINYINT:
            return .int(Int64(data.assumingMemoryBound(to: UInt8.self)[r]))
        case DUCKDB_TYPE_USMALLINT:
            return .int(Int64(data.assumingMemoryBound(to: UInt16.self)[r]))
        case DUCKDB_TYPE_UINTEGER:
            return .int(Int64(data.assumingMemoryBound(to: UInt32.self)[r]))
        case DUCKDB_TYPE_UBIGINT:
            let v = data.assumingMemoryBound(to: UInt64.self)[r]
            return v <= UInt64(Int64.max) ? .int(Int64(v)) : .text(String(v))
        case DUCKDB_TYPE_FLOAT:
            return .double(Double(data.assumingMemoryBound(to: Float.self)[r]))
        case DUCKDB_TYPE_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self)[r])
        case DUCKDB_TYPE_HUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            return .text(Self.hugeintString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_UHUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_uhugeint.self)[r]
            return .text(Self.unsignedString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_DECIMAL:
            return .decimal(decodeDecimal(data: data, row: r, meta: meta))
        case DUCKDB_TYPE_VARCHAR:
            var s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            let len = Int(duckdb_string_t_length(s))
            guard let ptr = withUnsafeMutablePointer(to: &s, { duckdb_string_t_data($0) }) else {
                return .text("")
            }
            return .text(String(decoding: UnsafeRawBufferPointer(start: ptr, count: len),
                                as: UTF8.self))
        case DUCKDB_TYPE_BLOB:
            let s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            return .blob(Int(duckdb_string_t_length(s)))
        case DUCKDB_TYPE_DATE:
            let days = data.assumingMemoryBound(to: duckdb_date.self)[r].days
            return .text(Self.isoDate(daysSinceEpoch: Int(days)))
        case DUCKDB_TYPE_TIME:
            let micros = data.assumingMemoryBound(to: duckdb_time.self)[r].micros
            return .text(Self.isoTime(micros: micros))
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_TZ:
            let micros = data.assumingMemoryBound(to: duckdb_timestamp.self)[r].micros
            return .text(Self.isoTimestamp(micros: micros))
        default:
            // Nested and unhandled types. SiftEngine casts these to VARCHAR in the
            // SELECT list, so this branch should be unreachable in Sift itself.
            return .text("")
        }
    }

    // MARK: - 128-bit integers

    /// DuckDB documents the value as `upper * 2^64 + lower`. Swift has no Int128 on the
    /// pinned toolchain, so this does long division by 10 over the two halves.
    static func hugeintString(lower: UInt64, upper: Int64) -> String {
        if upper < 0 {
            // Two's complement negate across both halves, then print with a sign.
            // The carry into `hi` happens exactly when `lower` was 0.
            let lo = ~lower &+ 1
            var hi = ~UInt64(bitPattern: upper)
            if lower == 0 { hi = hi &+ 1 }
            return "-" + unsignedString(lower: lo, upper: hi)
        }
        return unsignedString(lower: lower, upper: UInt64(upper))
    }

    static func unsignedString(lower: UInt64, upper: UInt64) -> String {
        if upper == 0 { return String(lower) }
        var digits: [Character] = []
        var hi = upper
        var lo = lower
        while hi != 0 || lo != 0 {
            // Divide the 128-bit value by 10, carrying the remainder across halves.
            let hiQuot = hi / 10
            let hiRem = hi % 10
            let (loQuot, loRem) = UInt64(10).dividingFullWidth((high: hiRem, low: lo))
            digits.append(Character(String(loRem)))
            hi = hiQuot
            lo = loQuot
        }
        return String(digits.reversed())
    }

    // MARK: - decimal

    private func decodeDecimal(data: UnsafeMutableRawPointer, row r: Int, meta: ColumnMeta) -> Decimal {
        let unscaled: String
        switch Self.decimalStorage(meta) {
        case DUCKDB_TYPE_SMALLINT:
            unscaled = String(data.assumingMemoryBound(to: Int16.self)[r])
        case DUCKDB_TYPE_INTEGER:
            unscaled = String(data.assumingMemoryBound(to: Int32.self)[r])
        case DUCKDB_TYPE_HUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            unscaled = Self.hugeintString(lower: h.lower, upper: h.upper)
        default:
            unscaled = String(data.assumingMemoryBound(to: Int64.self)[r])
        }
        let scale = Int(meta.decimalScale)
        guard scale > 0 else { return Decimal(string: unscaled) ?? 0 }

        let negative = unscaled.hasPrefix("-")
        var digits = negative ? String(unscaled.dropFirst()) : unscaled
        while digits.count <= scale { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -scale)
        let text = "\(negative ? "-" : "")\(digits[..<cut]).\(digits[cut...])"
        return Decimal(string: text) ?? 0
    }

    /// DECIMAL is stored in the smallest integer its width fits into. Guessing BIGINT
    /// for everything does not fail loudly — it silently returns a wrong number, which
    /// is precisely the corruption class this tool exists to expose.
    static func decimalStorage(_ meta: ColumnMeta) -> duckdb_type {
        switch meta.decimalWidth {
        case 0...4:   return DUCKDB_TYPE_SMALLINT
        case 5...9:   return DUCKDB_TYPE_INTEGER
        case 10...18: return DUCKDB_TYPE_BIGINT
        default:      return DUCKDB_TYPE_HUGEINT
        }
    }

    // MARK: - temporal

    private static let epoch = Date(timeIntervalSince1970: 0)

    static func isoDate(daysSinceEpoch: Int) -> String {
        let d = epoch.addingTimeInterval(Double(daysSinceEpoch) * 86_400)
        return isoFormatter(withTime: false).string(from: d)
    }

    static func isoTimestamp(micros: Int64) -> String {
        let d = epoch.addingTimeInterval(Double(micros) / 1_000_000)
        return isoFormatter(withTime: true).string(from: d)
    }

    static func isoTime(micros: Int64) -> String {
        let total = micros / 1_000_000
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func isoFormatter(withTime: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = withTime ? [.withInternetDateTime] : [.withFullDate]
        return f
    }
}
