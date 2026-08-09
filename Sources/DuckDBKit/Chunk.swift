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
            // A nil data pointer means the value lives elsewhere (STRUCT/ARRAY/UNION
            // keep theirs in child vectors), NOT that the rows are NULL. Reporting
            // NULL here would invent missing data.
            //
            // meta.typeID.rawValue, not meta.typeName: ResultSet.typeName collapses
            // every type it doesn't special-case — including STRUCT, ARRAY and UNION,
            // the exact types that reach this branch — down to the single string
            // "OTHER", which names nothing.
            return [Cell](repeating: .text("⟨unreadable type \(meta.typeID.rawValue)⟩"), count: rowCount)
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
            return decodeDecimal(data: data, row: r, meta: meta)
        case DUCKDB_TYPE_VARCHAR:
            var s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            let len = Int(duckdb_string_t_length(s))
            // The String must be built INSIDE the closure: for inlined strings (<=12
            // bytes) duckdb_string_t_data returns a pointer into `s` itself, which is
            // only valid for the lifetime of withUnsafeMutablePointer's callback.
            // MEASURED as latent (no observed mismatch over 4000 rows) rather than
            // active, but it is undefined behavior regardless of whether it happened
            // to work — the one file where that is least acceptable.
            return withUnsafeMutablePointer(to: &s) { sp -> Cell in
                guard let ptr = duckdb_string_t_data(sp) else { return .text("") }
                return .text(String(decoding: UnsafeRawBufferPointer(start: ptr, count: len),
                                    as: UTF8.self))
            }
        case DUCKDB_TYPE_BLOB:
            let s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            return .blob(Int(duckdb_string_t_length(s)))
        case DUCKDB_TYPE_DATE:
            let days = data.assumingMemoryBound(to: duckdb_date.self)[r].days
            return .text(Self.isoDate(daysSinceEpoch: Int(days)))
        case DUCKDB_TYPE_TIME:
            let micros = data.assumingMemoryBound(to: duckdb_time.self)[r].micros
            return .text(Self.isoTime(micros: micros))
        case DUCKDB_TYPE_TIME_TZ:
            let raw = data.assumingMemoryBound(to: duckdb_time_tz.self)[r]
            return .text(Self.isoTimeTz(raw))
        case DUCKDB_TYPE_TIMESTAMP:
            // Naive — no timezone travels with this value, so no offset is appended.
            let micros = data.assumingMemoryBound(to: duckdb_timestamp.self)[r].micros
            return .text(Self.isoTimestamp(micros, perSecond: 1_000_000, fracDigits: 6, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_TZ:
            // DuckDB always stores TIMESTAMP_TZ normalized to UTC, so +00:00 is exact,
            // not a guess.
            let micros = data.assumingMemoryBound(to: duckdb_timestamp.self)[r].micros
            return .text(Self.isoTimestamp(micros, perSecond: 1_000_000, fracDigits: 6, suffix: "+00:00"))
        case DUCKDB_TYPE_TIMESTAMP_S:
            let seconds = data.assumingMemoryBound(to: duckdb_timestamp_s.self)[r].seconds
            return .text(Self.isoTimestamp(seconds, perSecond: 1, fracDigits: 0, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_MS:
            let millis = data.assumingMemoryBound(to: duckdb_timestamp_ms.self)[r].millis
            return .text(Self.isoTimestamp(millis, perSecond: 1_000, fracDigits: 3, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_NS:
            // What pandas datetime64[ns] becomes on the way through Parquet.
            let nanos = data.assumingMemoryBound(to: duckdb_timestamp_ns.self)[r].nanos
            return .text(Self.isoTimestamp(nanos, perSecond: 1_000_000_000, fracDigits: 9, suffix: ""))
        case DUCKDB_TYPE_UUID:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            return .text(Self.uuidString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_INTERVAL:
            let iv = data.assumingMemoryBound(to: duckdb_interval.self)[r]
            return .text(Self.intervalString(months: iv.months, days: iv.days, micros: iv.micros))
        default:
            // Never an empty string: that is indistinguishable from real data, and
            // NULL vs '' vs a sentinel staying distinct is the whole point of this
            // tool. Loud and obviously-not-data instead.
            //
            // Deliberately still landing here, pending real decode paths: ENUM, BIT,
            // BIGNUM (the C API's name for VARINT — there is no DUCKDB_TYPE_VARINT in
            // this header). Also nested types (STRUCT/LIST/MAP/UNION) and JSON — but
            // for those, SiftEngine is expected to CAST(col AS VARCHAR) in the SELECT
            // list before the column ever reaches this decoder, so hitting this branch
            // on a nested column means that contract was not honored upstream, not
            // that this fallback is a substitute for it.
            return .text("⟨unsupported type \(meta.typeID.rawValue)⟩")
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

    private func decodeDecimal(data: UnsafeMutableRawPointer, row r: Int, meta: ColumnMeta) -> Cell {
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
        guard scale > 0 else {
            // Substituting 0 on a parse failure would be a silent wrong number in the
            // one file where that is unforgivable — loud marker instead.
            guard let v = Decimal(string: unscaled) else {
                return .text("⟨unparseable decimal \(unscaled)⟩")
            }
            return .decimal(v, scale: scale)
        }

        let negative = unscaled.hasPrefix("-")
        var digits = negative ? String(unscaled.dropFirst()) : unscaled
        while digits.count <= scale { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -scale)
        let text = "\(negative ? "-" : "")\(digits[..<cut]).\(digits[cut...])"
        guard let v = Decimal(string: text) else {
            return .text("⟨unparseable decimal \(text)⟩")
        }
        return .decimal(v, scale: scale)
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
    //
    // Deliberately NOT Foundation/ISO8601DateFormatter. Two measured failures against
    // libduckdb 1.5.5 ruled it out:
    //   - No fractional-seconds option, and it ROUNDS to the nearest second, so
    //     12:34:56.999999 came back as 12:34:57 — the wrong second, not just missing
    //     precision.
    //   - It applies the 1582 Julian→Gregorian calendar cutover, but DuckDB's DATE is
    //     proleptic Gregorian (extends the modern calendar backwards through 1582).
    //     DATE '1500-01-01' came back 1499-12-23; DATE '0001-01-01' came back
    //     0001-01-03.
    // Integer arithmetic throughout avoids both: no rounding, no calendar cutover.

    /// days-since-1970-01-01 → (year, month, day), proleptic Gregorian.
    /// Howard Hinnant's `civil_from_days` algorithm.
    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097                                  // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365   // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)           // [0, 365]
        let mp = (5 * doy + 2) / 153                                // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                        // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                           // [1, 12]
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    /// `String(format: "%04d", -99)` gives "-099" — the "0" pad character sits between
    /// the sign and the digits, so it pads the whole signed number to 4 characters, not
    /// the magnitude to 4 digits. ISO 8601 expanded form wants "-0099": the minus sign
    /// PLUS 4 digits of magnitude. Formatting the sign and the magnitude separately is
    /// what gets that right for any BC year.
    private static func year4(_ year: Int) -> String {
        year < 0 ? "-" + String(format: "%04d", -year) : String(format: "%04d", year)
    }

    static func isoDate(daysSinceEpoch: Int) -> String {
        let c = civilFromDays(daysSinceEpoch)
        return "\(year4(c.year))-" + String(format: "%02d-%02d", c.month, c.day)
    }

    /// Formats a count of sub-second units since the epoch.
    ///
    /// `perSecond` is the unit scale (1 for seconds, 1_000 for millis, 1_000_000 for
    /// micros, 1_000_000_000 for nanos); `fracDigits` is how many digits that scale
    /// needs. The fraction is emitted only when non-zero, matching Python's
    /// datetime.isoformat(), which omits the fraction entirely for a whole-second
    /// value but never trims within it — isoformat() always prints the fraction at
    /// the full width of the column's own scale once there is a fraction at all (3
    /// digits for millis, 6 for micros, 9 for nanos), and the DECIMAL fix a few lines
    /// away in Cell.swift exists for the identical reason: dropping a trailing zero
    /// misrepresents the column's declared precision. A decisecond column and a
    /// microsecond column must not render identically just because both happen to end
    /// in zeros.
    ///
    /// Integer division throughout: routing micros through Double and a formatter
    /// dropped sub-second precision AND rounded .999999 up to the next second.
    static func isoTimestamp(_ value: Int64, perSecond: Int64, fracDigits: Int,
                             suffix: String) -> String {
        let perDay = 86_400 * perSecond
        var days = Int(value / perDay)
        var rem = value % perDay
        if rem < 0 { rem += perDay; days -= 1 }   // floor, so pre-epoch values are right
        let c = civilFromDays(days)
        let secOfDay = rem / perSecond
        let frac = rem % perSecond
        var s = "\(year4(c.year))-" + String(format: "%02d-%02dT%02d:%02d:%02d",
                       c.month, c.day,
                       secOfDay / 3600, (secOfDay % 3600) / 60, secOfDay % 60)
        if frac != 0 && fracDigits > 0 {
            var digits = String(frac)
            while digits.count < fracDigits { digits = "0" + digits }
            s += "." + digits
        }
        return s + suffix
    }

    static func isoTime(micros: Int64) -> String {
        let secOfDay = micros / 1_000_000
        let frac = micros % 1_000_000
        var s = String(format: "%02d:%02d:%02d",
                       secOfDay / 3600, (secOfDay % 3600) / 60, secOfDay % 60)
        if frac != 0 {
            var digits = String(frac)
            while digits.count < 6 { digits = "0" + digits }
            s += "." + digits
        }
        return s
    }

    /// TIME_TZ packs micros-since-midnight and a UTC offset (in seconds) into 64 bits;
    /// `duckdb_from_time_tz` is the documented way to unpack them, so no manual
    /// bit-shifting here. MEASURED against libduckdb 1.5.5: `'12:34:56+02:00'::TIMETZ`
    /// decomposes to offset == 7200 (i.e. positive == east of UTC, matching the
    /// literal's own sign), so the offset needs no inversion.
    static func isoTimeTz(_ raw: duckdb_time_tz) -> String {
        let d = duckdb_from_time_tz(raw)
        var s = String(format: "%02d:%02d:%02d", d.time.hour, d.time.min, d.time.sec)
        if d.time.micros != 0 {
            var digits = String(d.time.micros)
            while digits.count < 6 { digits = "0" + digits }
            s += "." + digits
        }
        let mag = abs(Int(d.offset))   // offset is bounded to +/-16h, nowhere near Int32.min
        s += (d.offset < 0 ? "-" : "+") + String(format: "%02d:%02d", mag / 3600, (mag % 3600) / 60)
        return s
    }

    // MARK: - UUID

    /// UUID is transported as a hugeint with the top bit of `upper` flipped, so signed
    /// 128-bit comparison sorts the same way UUID bytes do. MEASURED against libduckdb
    /// 1.5.5: UUID '10203040-5060-7080-90a0-b0c0d0e0f000' arrives with upper bit
    /// pattern 0x9020304050607080 — the literal's own leading byte 0x10 with bit 63
    /// flipped to 0x90. XOR with Int64.min's bit pattern undoes exactly that flip.
    static func uuidString(lower: UInt64, upper: Int64) -> String {
        let hi = UInt64(bitPattern: upper) ^ UInt64(bitPattern: Int64.min)
        let hex = String(format: "%016llx%016llx", hi, lower)
        let a = hex.prefix(8)
        let b = hex.dropFirst(8).prefix(4)
        let c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4)
        let e = hex.dropFirst(20).prefix(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    // MARK: - INTERVAL

    /// Renders months/days/micros the same way DuckDB's own `CAST(iv AS VARCHAR)`
    /// does (MEASURED, e.g. `1 month -3 days 02:00:00`, `-25:00:00`, `00:00:00` for a
    /// zero interval) rather than inventing a shape: each component keeps its own
    /// sign, years/months/days are only shown when non-zero, and the time part is
    /// shown only when non-zero — except when the whole interval is zero, in which
    /// case time is the sole "00:00:00".
    static func intervalString(months: Int32, days: Int32, micros: Int64) -> String {
        var parts: [String] = []
        let years = months / 12
        let remMonths = months % 12
        if years != 0 { parts.append("\(years) year\(years.magnitude == 1 ? "" : "s")") }
        if remMonths != 0 { parts.append("\(remMonths) month\(remMonths.magnitude == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(days.magnitude == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            let negative = micros < 0
            let mag = micros.magnitude
            let totalSeconds = Int(mag / 1_000_000)
            let frac = mag % 1_000_000
            var time = String(format: "%02d:%02d:%02d",
                              totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
            if frac != 0 {
                var digits = String(frac)
                while digits.count < 6 { digits = "0" + digits }
                while digits.hasSuffix("0") { digits.removeLast() }
                time += "." + digits
            }
            parts.append((negative ? "-" : "") + time)
        }
        return parts.joined(separator: " ")
    }
}
