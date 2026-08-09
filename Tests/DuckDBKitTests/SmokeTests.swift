import Testing
import CDuckDB
@testable import DuckDBKit

// Forces an actual link against libduckdb (module autolink only fires on import)
// and pins that the loaded library is genuinely the 1.5.5 build we checksummed.
@Test func linkedLibraryIsThePinnedDuckDBVersion() {
    #expect(String(cString: duckdb_library_version()) == "v1.5.5")
}

@Test func errorKeepsOnlyTheFirstLine() {
    let e = DuckDBError("Binder Error: no such column\nLINE 1: SELECT nope\n        ^")
    #expect(e.firstLine == "Binder Error: no such column")
}

@Test func emptyErrorGetsAFallbackMessage() {
    #expect(DuckDBError("").firstLine == "Query failed.")
}

@Test func longErrorIsCappedAt400Characters() {
    let e = DuckDBError(String(repeating: "x", count: 900))
    #expect(e.firstLine.count == 400)
}
