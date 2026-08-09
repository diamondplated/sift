import Testing
@testable import DuckDBKit

@Test func boundValuesRoundTrip() throws {
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT ?::BOOLEAN AS b, ?::BIGINT AS i, ?::DOUBLE AS d, ?::VARCHAR AS s, ?::VARCHAR AS n",
        [.bool(true), .int(42), .double(1.5), .text("hi"), .null]
    ).allRows()
    #expect(rows.count == 1)
    #expect(rows[0] == [.bool(true), .int(42), .double(1.5), .text("hi"), .null])
}

@Test func bindsAStringContainingAQuote() throws {
    // The invariant this protects: values are bound, never interpolated. If this ever
    // goes through string concatenation instead, this is the test that catches it.
    let con = try Database.inMemory().connect()
    let rows = try con.query("SELECT ?::VARCHAR AS s", [.text("O'Brien")]).allRows()
    #expect(rows[0] == [.text("O'Brien")])
}

@Test func anExecuteTimeFailureThrowsAndCleansUp() throws {
    // Distinct from a prepare-time failure: this SQL parses and binds fine, then fails
    // during execution, which is the only path that reaches the result-error branch in
    // Connection.query. Every other test in this package fails at prepare instead.
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        _ = try con.query("SELECT CAST('abc' AS INTEGER)").allRows()
    }
}
