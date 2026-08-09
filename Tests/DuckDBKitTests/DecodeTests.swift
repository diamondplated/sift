import Foundation
import Testing
@testable import DuckDBKit

private func one(_ sql: String) throws -> Cell {
    let con = try Database.inMemory().connect()
    return try con.query(sql).allRows()[0][0]
}

@Test func decodesSignedIntegers() throws {
    #expect(try one("SELECT 127::TINYINT") == .int(127))
    #expect(try one("SELECT 32767::SMALLINT") == .int(32767))
    #expect(try one("SELECT 2147483647::INTEGER") == .int(2147483647))
    #expect(try one("SELECT 9223372036854775807::BIGINT") == .int(9223372036854775807))
}

@Test func decodesUnsignedIntegers() throws {
    #expect(try one("SELECT 255::UTINYINT") == .int(255))
    #expect(try one("SELECT 65535::USMALLINT") == .int(65535))
    #expect(try one("SELECT 4294967295::UINTEGER") == .int(4294967295))
}

@Test func decodesFloatsAndBooleans() throws {
    #expect(try one("SELECT true") == .bool(true))
    #expect(try one("SELECT 1.5::DOUBLE") == .double(1.5))
    #expect(try one("SELECT 1.5::FLOAT") == .double(1.5))
}

@Test func decodesShortAndLongStrings() throws {
    // Under 12 bytes DuckDB inlines the string in the struct; past that it is a
    // pointer. Both paths must work, so test either side of the boundary.
    #expect(try one("SELECT 'short'") == .text("short"))
    let long = String(repeating: "a", count: 200)
    #expect(try one("SELECT '\(long)'") == .text(long))
    #expect(try one("SELECT ''") == .text(""))
}

@Test func decodesNullsInEveryPosition() throws {
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT * FROM (VALUES (1, 'a'), (NULL, NULL), (3, 'c')) AS t(n, s)"
    ).allRows()
    #expect(rows[0] == [.int(1), .text("a")])
    #expect(rows[1] == [.null, .null])
    #expect(rows[2] == [.int(3), .text("c")])
}

@Test func decodesHugeIntAsText() throws {
    // 2^70, far past Int64. This is the corruption class Sift exists to expose,
    // so it must survive exactly.
    #expect(try one("SELECT 1180591620717411303424::HUGEINT") == .text("1180591620717411303424"))
    #expect(try one("SELECT (-1180591620717411303424)::HUGEINT") == .text("-1180591620717411303424"))
    #expect(try one("SELECT 0::HUGEINT") == .text("0"))
    #expect(try one("SELECT 42::HUGEINT") == .text("42"))
    #expect(try one("SELECT (-1)::HUGEINT") == .text("-1"))
}

@Test func decodesDecimalAtEveryStorageWidth() throws {
    // Width picks the backing integer: <=4 SMALLINT, <=9 INTEGER, <=18 BIGINT, else
    // HUGEINT. Reading the wrong width returns a plausible wrong number rather than
    // throwing, so all four have to be covered.
    #expect(try one("SELECT 1.23::DECIMAL(4,2)") == .decimal(Decimal(string: "1.23")!, scale: 2))
    #expect(try one("SELECT 12345.678::DECIMAL(9,3)") == .decimal(Decimal(string: "12345.678")!, scale: 3))
    #expect(try one("SELECT 123456789.012::DECIMAL(18,3)")
            == .decimal(Decimal(string: "123456789.012")!, scale: 3))
    #expect(try one("SELECT 1234567890123456789.01::DECIMAL(38,2)")
            == .decimal(Decimal(string: "1234567890123456789.01")!, scale: 2))
    #expect(try one("SELECT (-0.001)::DECIMAL(9,3)") == .decimal(Decimal(string: "-0.001")!, scale: 3))
}

@Test func decodesBlobAsAByteCount() throws {
    #expect(try one("SELECT 'abc'::BLOB") == .blob(3))
}

@Test func readsEveryRowAcrossMultipleChunks() throws {
    // A DuckDB chunk holds 2048 rows, so 5000 forces the multi-chunk path.
    let con = try Database.inMemory().connect()
    let rows = try con.query("SELECT i FROM range(5000) AS t(i)").allRows()
    #expect(rows.count == 5000)
    #expect(rows[0][0] == .int(0))
    #expect(rows[4999][0] == .int(4999))
}

@Test func decodesTimestampsWithSubSecondPrecision() throws {
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56.123456'")
            == .text("2026-08-09T12:34:56.123456"))
    // Rounds to the WRONG SECOND if the formatter path ever comes back.
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56.999999'")
            == .text("2026-08-09T12:34:56.999999"))
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56'")
            == .text("2026-08-09T12:34:56"))
}

@Test func decodesDatesBeforeTheGregorianCutover() throws {
    // ISO8601DateFormatter shifts these 9-10 days; DuckDB DATE is proleptic Gregorian.
    #expect(try one("SELECT DATE '1500-01-01'") == .text("1500-01-01"))
    #expect(try one("SELECT DATE '1582-10-04'") == .text("1582-10-04"))
    #expect(try one("SELECT DATE '0001-01-01'") == .text("0001-01-01"))
    #expect(try one("SELECT DATE '1969-07-20'") == .text("1969-07-20"))
    #expect(try one("SELECT DATE '9999-12-31'") == .text("9999-12-31"))
}

@Test func decodesEveryTimestampScale() throws {
    #expect(try one("SELECT TIMESTAMP_S '2026-08-09 12:34:56'") == .text("2026-08-09T12:34:56"))
    #expect(try one("SELECT TIMESTAMP_MS '2026-08-09 12:34:56.123'") == .text("2026-08-09T12:34:56.123"))
    // What pandas datetime64[ns] becomes in Parquet — previously decoded to "".
    #expect(try one("SELECT TIMESTAMP_NS '2026-08-09 12:34:56.123456789'")
            == .text("2026-08-09T12:34:56.123456789"))
}

@Test func decodesUuidAndInterval() throws {
    #expect(try one("SELECT UUID '10203040-5060-7080-90a0-b0c0d0e0f000'")
            == .text("10203040-5060-7080-90a0-b0c0d0e0f000"))
    // Shape: DuckDB's own CAST(iv AS VARCHAR) rendering (postgres-style) — each
    // component keeps its own sign, zero components are omitted. MEASURED against
    // libduckdb via CLI: months=1, days=-3, micros=7200000000 renders exactly this.
    #expect(try one("SELECT INTERVAL '1 month -3 days 02:00:00'")
            == .text("1 month -3 days 02:00:00"))
    #expect(try one("SELECT INTERVAL '0 days'") == .text("00:00:00"))
    #expect(try one("SELECT INTERVAL '13 months'") == .text("1 year 1 month"))
    // intervalString deliberately DOES trim trailing zeros, unlike the timestamp
    // paths — this matches DuckDB's own CAST(... AS VARCHAR). Verified against it.
    #expect(try one("SELECT INTERVAL '0.12 seconds'") == .text("00:00:00.12"))
}

@Test func decimalKeepsItsDeclaredScale() throws {
    // The Python engine returns str(Decimal), which preserves trailing zeros. A money
    // column must not change shape on screen.
    let c = try one("SELECT 10.50::DECIMAL(10,2)")
    #expect(c.display == "10.50")
}

@Test func timeKeepsSubSecondPrecision() throws {
    #expect(try one("SELECT TIME '12:34:56.123456'") == .text("12:34:56.123456"))
    #expect(try one("SELECT TIME '12:34:56'") == .text("12:34:56"))
}

@Test func distinguishesZonedTimestampsFromNaiveOnes() throws {
    // The bug this pins: a naive TIMESTAMP used to get a spurious Z, making it
    // indistinguishable from a genuinely zoned value. Python renders naive bare and
    // aware with an offset; so do we.
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56'") == .text("2026-08-09T12:34:56"))
    #expect(try one("SELECT TIMESTAMPTZ '2026-08-09 12:34:56+00'")
            == .text("2026-08-09T12:34:56+00:00"))
}

@Test func decodesTimeWithTimezone() throws {
    #expect(try one("SELECT TIMETZ '12:34:56+02:00'") == .text("12:34:56+02:00"))
    #expect(try one("SELECT TIMETZ '12:34:56-05:30'") == .text("12:34:56-05:30"))
}
