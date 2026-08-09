import Testing
import Foundation
import DuckDBKit
@testable import SiftCore

// Format detection, glob escaping, hive layout, and row estimation. Ported from
// engine/tests/test_source.py's pure functions.
//
// Skipped, and reported in task-9-report.md's deferred checklist: every test that calls
// `S.sniff_csv`, `S.build_source`, `S._describe`, or `S.exact_count` — all four need a live
// DuckDB connection and stay behind for Plan 3 (see Source.swift's header). That's 13 of the
// file's 22 tests: test_sniff_normalizes_the_empty_sentinel, test_sniff_finds_a_semicolon_
// delimiter, test_sniff_skips_a_junk_preamble, test_build_source_csv_bakes_explicit_options,
// test_build_source_gives_small_csvs_an_exact_count, test_quoted_newlines_do_not_inflate_the_
// count, test_compressed_csv_gets_neither_count_nor_estimate, test_parquet_row_count_is_free_
// and_exact, test_all_varchar_relation_drops_the_column_types, test_supports_all_varchar_only_
// for_text_formats, test_exact_count_uses_the_physical_relation, test_build_source_hive_sets_
// partitioning_and_provenance, test_header_byte_offset_counts_preamble_and_header.
//
// For three of those (the all_varchar test, the supports_all_varchar test, and the
// header_byte_offset test) the function actually under test — read_expr, supports_all_varchar,
// header_byte_offset — IS ported and pure; only the ORIGINAL test's fixture setup went through
// build_source/sniff_csv. Below, past the `// MARK: - supplementary` line, are new tests (not
// ports — the assertions are new, not lifted from Python) that exercise those same functions by
// constructing a SourceSpec/SniffHints by hand instead. Everything above that line is a
// verbatim port.
//
// These tests all read the one lazily-built `sharedData` corpus and run in parallel with no
// suite-level serialization trait — that's deliberate, not an oversight. An earlier version
// needed `.serialized` because building the corpus spawned a `/usr/bin/gzip` subprocess whose
// completion depended on a GCD worker thread (Fixtures.swift's old `makeGzipCSV`), and enough
// parallel tests blocking on the corpus's first-access lock at once could starve that thread —
// a measured deadlock. `makeGzipCSV` now redirects stdin/stdout to real files instead of a
// Pipe, which removes the GCD dependency entirely rather than just lowering the odds of hitting
// it, so serialization is no longer needed here. See task-9-report.md's review-fix section.

private let sharedData = try! corpus()

private func freshTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sift-source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

// MARK: - detect_format

@Test func magicBytesBeatTheExtension() throws {
    // A .csv that is really parquet is a genuinely common way to receive data.
    let dir = try freshTempDir()
    let lying = (dir as NSString).appendingPathComponent("actually_parquet.csv")
    try Data(contentsOf: URL(fileURLWithPath: sharedData.parquet)).write(to: URL(fileURLWithPath: lying))
    #expect(try detectFormat(lying) == .parquet)
}

/// A `KeyPath<FixtureCorpus, String>` would read more directly, but `@Test(arguments:)` requires
/// `Sendable` and `KeyPath` isn't — this enum is the Sendable stand-in.
private enum FixtureFile: Sendable {
    case cleanCSV, semiCSV, weirdCSV, gzCSV, parquet, ndjson, xlsx

    func path(in data: FixtureCorpus) -> String {
        switch self {
        case .cleanCSV: return data.cleanCSV
        case .semiCSV: return data.semiCSV
        case .weirdCSV: return data.weirdCSV
        case .gzCSV: return data.gzCSV
        case .parquet: return data.parquet
        case .ndjson: return data.ndjson
        case .xlsx: return data.xlsx
        }
    }
}

@Test(arguments: [
    (FixtureFile.cleanCSV, Fmt.csv), (.semiCSV, .csv), (.weirdCSV, .csv), (.gzCSV, .csv),
    (.parquet, .parquet), (.ndjson, .ndjson), (.xlsx, .xlsx),
])
private func detectFormatMatchesExpectation(file: FixtureFile, want: Fmt) throws {
    #expect(try detectFormat(file.path(in: sharedData)) == want)
}

@Test func legacyXlsIsRefusedWithAUsefulMessage() throws {
    #expect(throws: LegacyXls.self) { try detectFormat(sharedData.fakeXLS) }
    do {
        _ = try detectFormat(sharedData.fakeXLS)
        Issue.record("expected LegacyXls")
    } catch let e as LegacyXls {
        #expect(e.message.contains(".xlsx"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func deltaDirectoryIsDetectedNotGlobbed() throws {
    #expect(isDeltaDir(sharedData.delta))
    #expect(try detectFormat(sharedData.delta) == .delta)
}

@Test func folderOfParquetIsAGlob() throws {
    #expect(try detectFormat(sharedData.hive) == .globParquet)
}

@Test func folderWithNothingReadableIsRefused() throws {
    let dir = try freshTempDir()
    let sub = (dir as NSString).appendingPathComponent("sub")
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    #expect(throws: UnsupportedSource.self) { try detectFormat(sub) }
}

// MARK: - hive_keys / glob_escape

@Test func hiveKeysRequireAConsistentLayout() throws {
    let files = filesWithExtension(".parquet", under: sharedData.hive)
    #expect(hiveKeys(directory: sharedData.hive, files: files) == ["dt", "region"])
    // One file at the wrong depth makes the layout inconsistent, and DuckDB errors on
    // hive_partitioning in that case — so Sift must fall back to a plain glob.
    let stray = (sharedData.hive as NSString).appendingPathComponent("stray.parquet")
    #expect(hiveKeys(directory: sharedData.hive, files: files + [stray]) == [])
}

@Test func globEscapeProtectsBracketedDirectoryNames() {
    #expect(globEscape("/data/x[2026]") == "/data/x[[]2026[]]")
}

// MARK: - estimate_rows / header_byte_offset

@Test func emptyFileDoesNotExplode() {
    #expect(estimateRows(path: sharedData.empty).rows == 0)
}

// MARK: - supplementary (new tests for ported functions whose ORIGINAL test needed
// build_source/sniff_csv — see the file header)

@Test func allVarcharRelationDropsTheColumnTypesFromReadExpr() throws {
    // Stands in for test_all_varchar_relation_drops_the_column_types: build_source is deferred,
    // so the CSV SourceSpec it would have produced for dirty_csv is constructed by hand here
    // instead (same shape build_source's CSV branch always produces: delim/quote/escape/header/
    // skip/ignore_errors/allow_quoted_nulls plus the ordered columns list).
    let cols = [
        Column(name: "order_id", type: "BIGINT"), Column(name: "region", type: "VARCHAR"),
        Column(name: "amount", type: "DOUBLE"), Column(name: "note", type: "VARCHAR"),
    ]
    let spec = SourceSpec(
        key: SourceKey(path: sharedData.dirtyCSV, mtimeNs: 0, size: 0), fmt: .csv, readFn: "read_csv",
        readArgs: [
            "delim": .text(","), "header": .bool(true), "skip": .int(0),
            "ignore_errors": .bool(true), "allow_quoted_nulls": .bool(false),
        ],
        columns: cols
    )
    let raw = readExpr(spec: spec, allVarchar: true)
    #expect(raw.contains("all_varchar=true"))
    #expect(!raw.contains("columns="))

    let con = try Database.inMemory().connect()
    let types = try con.query("DESCRIBE SELECT * FROM \(raw)").allRows().map { row -> String in
        guard case .text(let t) = row[1] else { return "" }
        return t
    }
    #expect(Set(types) == ["VARCHAR"])
}

@Test func supportsAllVarcharOnlyForTextFormats() {
    // Stands in for test_supports_all_varchar_only_for_text_formats: supports_all_varchar reads
    // only spec.fmt, so a hand-built spec (any read_fn/columns — irrelevant to this function)
    // exercises exactly the same branch build_source's real dirty_csv/parquet specs would.
    let key = SourceKey(path: "/x", mtimeNs: 0, size: 0)
    #expect(supportsAllVarchar(SourceSpec(key: key, fmt: .csv, readFn: "read_csv")))
    // Parquet carries real types, so there is no sniffing to get wrong and no reject count to
    // compute.
    #expect(!supportsAllVarchar(SourceSpec(key: key, fmt: .parquet, readFn: "read_parquet")))
}

@Test func headerByteOffsetCountsPreambleAndHeader() throws {
    // Stands in for test_header_byte_offset_counts_preamble_and_header: sniff_csv is deferred,
    // so the SniffHints it would have produced for weird_csv (preamble=3 junk lines, then a real
    // header — see Fixtures.swift's makeCSV) is supplied directly instead of sniffed.
    let off = headerByteOffset(path: sharedData.weirdCSV, sniff: SniffHints(skip: 3, header: true))
    #expect(off > 0)
    let head = FileHandle(forReadingAtPath: sharedData.weirdCSV)!.readData(ofLength: off)
    #expect(head.filter { $0 == 0x0A }.count == 4)   // 3 junk lines + the header
}

// MARK: - the `columns=` ordering landmine
//
// `read_csv(columns={…})` disables auto-detection and binds each entry POSITIONALLY against the
// file, so file-column order is a correctness dependency: a wrong order silently assigns the
// wrong type to every column — a plausible-wrong-value bug in the one product that exists not to
// produce those. It carries a 12-line LANDMINE comment in Types.swift and was the headline risk
// of two tasks, and nothing asserted it: `allVarcharRelationDropsTheColumnTypesFromReadExpr`
// above only asserts the argument is ABSENT, and SnippetTests compares the snippet against a
// query built from this same `readExpr`, so a scramble cancels out on both sides. Mutating
// `columnsArgValue` to `columns.reversed()` left all 195 tests green. These two assert the whole
// expression verbatim instead.

@Test func readExprRendersColumnsInFileOrderNeitherSortedNorReversed() {
    // Names deliberately in no alphabetical relation to their file order (sorted would be
    // alpha/bravo/mike/zulu, reversed would be bravo/mike/alpha/zulu), and every column carries a
    // DIFFERENT type, so any permutation renders a visibly different string.
    let cols = [
        Column(name: "zulu_when", type: "TIMESTAMP"),
        Column(name: "alpha_id", type: "BIGINT"),
        Column(name: "mike_amount", type: "DECIMAL(12,2)"),
        Column(name: "bravo_note", type: "VARCHAR"),
    ]
    let spec = SourceSpec(
        key: SourceKey(path: "/data/orders.csv", mtimeNs: 0, size: 0), fmt: .csv,
        readFn: "read_csv",
        readArgs: ["delim": .text(","), "header": .bool(true), "skip": .int(0)],
        columns: cols
    )
    #expect(readExpr(spec: spec) == """
        read_csv('/data/orders.csv', delim=',', header=true, skip=0, \
        columns={'zulu_when': 'TIMESTAMP', 'alpha_id': 'BIGINT', \
        'mike_amount': 'DECIMAL(12,2)', 'bravo_note': 'VARCHAR'})
        """)
}

@Test func readExprOmitsColumnsEntirelyForAnEmptyColumnList() {
    // `columns={}` is a DuckDB parse error, and Python never emits the argument when there is
    // nothing to put in it. The `!spec.columns.isEmpty` guard that mirrors that was unpinned too.
    let spec = SourceSpec(
        key: SourceKey(path: "/data/orders.csv", mtimeNs: 0, size: 0), fmt: .csv,
        readFn: "read_csv", readArgs: ["header": .bool(true)], columns: []
    )
    #expect(readExpr(spec: spec) == "read_csv('/data/orders.csv', header=true)")
}

@Test func deltaVersionReadsTheLatestCommittedVersionFromTheLogFilenames() throws {
    // Not from Python's suite (no test_delta_version exists there either — it's only exercised
    // indirectly through build_source, which is deferred); delta_version is pure, so it's ported
    // here and given its own check per the "leave one runnable check" rule.
    #expect(deltaVersion(sharedData.delta) == 1)   // makeDelta writes versions 0 and 1
    #expect(deltaVersion(try freshTempDir()) == nil)   // no _delta_log at all
}
