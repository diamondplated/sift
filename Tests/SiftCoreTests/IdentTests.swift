import Testing
@testable import SiftCore

// Identifier sanitation and quoting. No connection, no files. Ported from
// engine/tests/test_ident.py.

// MARK: - sanitize_table_name

@Test(arguments: [
    ("2026 Sales (final).csv", "t_2026_sales_final"),   // leading digit must be prefixed
    ("sales.csv", "sales"),
    ("sales.csv.gz", "sales"),                          // double extension
    ("events.ndjson", "events"),
    ("Book1.xlsx", "book1"),
    ("  ???  ", "data"),                                // nothing usable left
    ("", "data"),
    ("Ünïcode Nàme.parquet", "unicode_name"),           // NFKD then ASCII
    ("a---b__c", "a_b_c"),                              // runs collapse
    ("__leading_and_trailing__", "leading_and_trailing"),
    ("MiXeD CaSe", "mixed_case"),
    ("select", "select"),                               // reserved words are fine: always quoted
    ("tab\tsep", "tab_sep"),
    ("2026", "t_2026"),
])
func sanitize(given: String, want: String) throws {
    #expect(try sanitizeTableName(given) == want)
}

@Test func sanitizeTruncatesAndKeepsRoomForASuffix() throws {
    let name = try sanitizeTableName(String(repeating: "x", count: 200) + ".csv")
    #expect(name.count <= 60)
    #expect(try sanitizeTableName(String(repeating: "x", count: 200) + ".csv", taken: [name]) == name + "_2")
}

@Test func sanitizeResolvesCollisionsInOrder() throws {
    let taken: Set<String> = ["sales", "sales_2", "sales_3"]
    #expect(try sanitizeTableName("sales.csv", taken: taken) == "sales_4")
}

// DuckDB identifiers are case-insensitive, so "Sales" colliding with "sales" is a real clash.
@Test func sanitizeCollisionIsCaseInsensitive() throws {
    #expect(try sanitizeTableName("Sales.csv", taken: ["sales"]) == "sales_2")
}

// MARK: - strip_data_extensions

@Test func stripDataExtensionsLeavesUnknownSuffixesAlone() {
    #expect(stripDataExtensions("report.2026.final") == "report.2026.final")
    #expect(stripDataExtensions("data.csv.zst") == "data")
}

// A folder picker hands directory names with a trailing "/"; pathlib.Path("dir/").name == "dir",
// not "" — review fix I1.
@Test func stripDataExtensionsHandlesADirectoryNameWithATrailingSlash() {
    #expect(stripDataExtensions("dir/") == "dir")
}

// Verified against the real Python interpreter: Path("a//b//").name == "b".
@Test func stripDataExtensionsCollapsesRepeatedSeparators() {
    #expect(stripDataExtensions("a//b//") == "b")
}

// MARK: - q

@Test func qDoublesEmbeddedQuotes() {
    #expect(q("region") == "\"region\"")
    #expect(q("we\"ird") == "\"we\"\"ird\"")
    // The injection shape: the whole thing stays one quoted identifier.
    #expect(q("\"; DROP TABLE x; --") == "\"\"\"; DROP TABLE x; --\"")
}

// MARK: - qlit

@Test func qlitDoublesSingleQuotes() {
    #expect(qlit("a'b") == "'a''b'")
    #expect(qlit("plain") == "'plain'")
}
