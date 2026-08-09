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
    #expect(try one("SELECT 1.23::DECIMAL(4,2)") == .decimal(Decimal(string: "1.23")!))
    #expect(try one("SELECT 12345.678::DECIMAL(9,3)") == .decimal(Decimal(string: "12345.678")!))
    #expect(try one("SELECT 123456789.012::DECIMAL(18,3)") == .decimal(Decimal(string: "123456789.012")!))
    #expect(try one("SELECT 1234567890123456789.01::DECIMAL(38,2)")
            == .decimal(Decimal(string: "1234567890123456789.01")!))
    #expect(try one("SELECT (-0.001)::DECIMAL(9,3)") == .decimal(Decimal(string: "-0.001")!))
}

@Test func decodesTemporalAsISO8601() throws {
    #expect(try one("SELECT DATE '2026-08-09'") == .text("2026-08-09"))
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56'") == .text("2026-08-09T12:34:56Z"))
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
