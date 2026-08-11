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

@Test func emptyFileDoesNotExplode() throws {
    #expect(try estimateRows(path: sharedData.empty).rows == 0)
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
    let off = try headerByteOffset(path: sharedData.weirdCSV, sniff: SniffHints(skip: 3, header: true))
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

// MARK: - the ragged-CSV collapse
//
// The pure half of the fix for the defect the shipped CLI showed on a real file: a CSV whose rows
// do not all carry the same number of fields came back as ONE column literally named
// `order_id,region,amount`, over the words "no rows dropped". `collapsedDelimiter` is the tell, and
// it is pure — the real-sniffer half (that these are the shapes DuckDB actually produces, and that
// null padding really recovers the columns) lives in SiftEngineTests/SourceProbeTests.swift.

@Test func collapsedDelimiterSpotsEachDelimiterLeftInsideAOneColumnHeader() {
    // The four shapes MEASURED on DuckDB 1.5.5: a ragged comma file sniffs as `|`; ragged
    // semicolon, tab and pipe files all sniff as `,`. In every one the real delimiter is still
    // sitting in the surviving column name.
    #expect(collapsedDelimiter(delim: "|", columns: [Column(name: "order_id,region,amount", type: "VARCHAR")]) == ",")
    #expect(collapsedDelimiter(delim: ",", columns: [Column(name: "a;b;c", type: "VARCHAR")]) == ";")
    #expect(collapsedDelimiter(delim: ",", columns: [Column(name: "a\tb\tc", type: "VARCHAR")]) == "\t")
    #expect(collapsedDelimiter(delim: ",", columns: [Column(name: "a|b|c", type: "VARCHAR")]) == "|")
}

@Test func collapsedDelimiterStandsDownOnEveryHealthySingleColumnFile() {
    // Each of these is a legitimate one-column CSV, and firing on one would be worse than
    // detecting nothing at all — a note that cries wolf is a note the reader learns to skip past.
    // The header names are the ones DuckDB really reports for these files (SourceProbeTests feeds
    // it the actual bytes); what matters here is that a plain name never trips the rule.
    for name in ["note", "url", "payload", "amount", "Description of the thing"] {
        #expect(
            collapsedDelimiter(delim: ",", columns: [Column(name: name, type: "VARCHAR")]) == nil,
            "fired on a one-column file named \u{201C}\(name)\u{201D}"
        )
    }
    // The interesting one: a header that genuinely contains a comma. The sniffer picks `,` for it,
    // so the comma in the name IS the chosen delimiter and the detector must stay quiet.
    #expect(collapsedDelimiter(delim: ",", columns: [Column(name: "Last, First", type: "VARCHAR")]) == nil)
    // Multi-character delimiters exist, which is why the rule tests membership rather than
    // equality: a `, ` delimiter still accounts for the comma in the name.
    #expect(collapsedDelimiter(delim: ", ", columns: [Column(name: "Last, First", type: "VARCHAR")]) == nil)
    // And a file that really did sniff into columns is never collapsed, whatever is in the names.
    #expect(
        collapsedDelimiter(
            delim: "|", columns: [Column(name: "a,b", type: "VARCHAR"), Column(name: "c", type: "VARCHAR")]
        ) == nil
    )
    #expect(collapsedDelimiter(delim: ",", columns: []) == nil)
}

@Test func raggedCollapseNoteSaysWhatHappenedAndWhatToDoOrNothingAtAll() {
    let key = SourceKey(path: "/data/ragged.csv", mtimeNs: 0, size: 0)
    let collapsed = SourceSpec(key: key, fmt: .csv, readFn: "read_csv", raggedColumns: 5)
    #expect(
        raggedCollapseNote(collapsed) == "Not every row has the same number of fields, so the "
            + "whole file read as one column \u{2014} re-open with null padding to see all 5"
    )
    // The switch is `raggedColumns`, and a healthy source gets no note at all rather than an
    // empty one that would still render a blank `note:` line in `sift <path>`.
    #expect(raggedCollapseNote(SourceSpec(key: key, fmt: .csv, readFn: "read_csv")) == nil)
    // And a "recovery" that recovers a single column is not a way out. `buildSource` records what
    // null padding measured either way; deciding whether that is worth a sentence is this
    // function's job, so that the number in the note is always an improvement on what is on screen.
    #expect(
        raggedCollapseNote(SourceSpec(key: key, fmt: .csv, readFn: "read_csv", raggedColumns: 1)) == nil
    )
}

@Test func raggedCollapseNoteSaysFolderWhenItWasAFolder() {
    // A folder collapses one file at a time, so "the whole file" would be quietly wrong — the kind
    // of small inaccuracy that makes a reader distrust the rest of the sentence.
    let key = SourceKey(path: "/data/daily", mtimeNs: 0, size: 0)
    let folder = SourceSpec(key: key, fmt: .globCsv, readFn: "read_csv", raggedColumns: 5)
    #expect(raggedCollapseNote(folder)?.contains("every file in the folder") == true)
    #expect(raggedCollapseNote(folder)?.contains("whole file") == false)
    #expect(raggedCollapseNote(folder)?.hasSuffix("to see all 5") == true)
}

// MARK: - the preamble that ate the file
//
// The pure half of the second mis-sniff: three lines of prose sniffed as `;`, the first two thrown
// away as a preamble and the third used as the header, leaving an empty grid. The tell is
// rows == 0 AND skip > 0 — both already on the spec, so this reads no bytes. The real-sniffer half
// (that these are the shapes DuckDB actually produces) is in SiftEngineTests/SourceProbeTests.swift.

private func csvSpec(rows: Int?, skip: Int?, fmt: Fmt = .csv) -> SourceSpec {
    var args: [String: ReadArg] = ["delim": .text(","), "header": .bool(true)]
    if let skip { args["skip"] = .int(skip) }
    return SourceSpec(
        key: SourceKey(path: "/data/x.csv", mtimeNs: 0, size: 120), fmt: fmt, readFn: "read_csv",
        readArgs: args, columns: [Column(name: "a", type: "VARCHAR")], rowCount: rows
    )
}

@Test func preambleAteTheFileNeedsBothHalvesOfTheTell() {
    // The defect: lines thrown away, and nothing left.
    #expect(preambleAteTheFile(csvSpec(rows: 0, skip: 2)) == 2)
    #expect(preambleAteTheFile(csvSpec(rows: 0, skip: 1)) == 1)

    // A header and nothing else. Genuinely zero rows — and the file that looks EXACTLY like the
    // defect if you only look at the row count, which is why the row count alone is not the rule.
    #expect(preambleAteTheFile(csvSpec(rows: 0, skip: 0)) == nil)
    // `skip` is a feature. Junk lines in front of real data are supported and must stay silent,
    // however many were skipped.
    #expect(preambleAteTheFile(csvSpec(rows: 200, skip: 3)) == nil)
    #expect(preambleAteTheFile(csvSpec(rows: 1, skip: 9)) == nil)
    // 🔴 An UNKNOWN row count is not zero. A compressed or over-64MB CSV gets no count at build
    // time, and firing there would claim the file is empty on the strength of not having looked.
    #expect(preambleAteTheFile(csvSpec(rows: nil, skip: 2)) == nil)
    // Only the plain-CSV branch bakes `skip` at all; nothing else can produce this shape.
    #expect(preambleAteTheFile(csvSpec(rows: 0, skip: 2, fmt: .globCsv)) == nil)
    #expect(preambleAteTheFile(csvSpec(rows: 0, skip: nil)) == nil)
}

@Test func preambleNoteSaysHowMuchWasLostAndHowToGetItBackOrNothingAtAll() {
    #expect(
        preambleNote(csvSpec(rows: 0, skip: 2)) == "The first 2 lines were skipped as a preamble, "
            + "which left no rows at all \u{2014} re-open without skipping to see them"
    )
    // One line is "The first line was", not "The first 1 lines were" — the same pluralisation care
    // `renderDropped` takes over "1 row dropped".
    #expect(preambleNote(csvSpec(rows: 0, skip: 1))?.hasPrefix("The first line was skipped") == true)
    #expect(preambleNote(csvSpec(rows: 0, skip: 1))?.contains("1 lines") == false)
    // A healthy file gets no note at all, rather than an empty one that would still render a blank
    // `note:` line in `sift <path>`.
    #expect(preambleNote(csvSpec(rows: 200, skip: 3)) == nil)
    #expect(preambleNote(csvSpec(rows: 0, skip: 0)) == nil)
}
