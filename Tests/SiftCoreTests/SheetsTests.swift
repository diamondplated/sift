import Testing
import Foundation
import TestSupport
@testable import SiftCore

// Excel: sheet enumeration and the legacy .xls refusal. Ported from engine/tests/test_sheets.py.
//
// Skipped, and reported in task-9-report.md's deferred checklist: three of the six tests need
// `S.build_source` (which needs a live connection, and stays behind for Plan 3) to turn a chosen
// sheet into a queryable relation — test_default_sheet_is_the_first_non_empty,
// test_a_named_sheet_can_be_opened, test_sheet_names_with_quotes_do_not_break_the_expression.
// The last of those is the one that matters most for THIS file (it is the reason odd.xlsx is
// committed at all — see Fixtures/README.md): its first half, "does list_sheets read an
// apostrophe correctly," is pure and is covered below as a supplementary test.
//
// test_legacy_xls_gets_a_readable_refusal calls S.build_source(None, ...) in Python, but
// build_source's very first line is `detect_format(path)`, which is what actually raises
// LegacyXls before anything connection-shaped happens — so it's ported here against
// detectFormat directly, keeping both original assertions (".xlsx" and "legacy" in the message).
//
// No suite-level serialization trait: see SourceTests.swift's header for why that was needed
// once (a GCD-thread-hungry subprocess in a shared fixture) and isn't anymore (the subprocess no
// longer depends on GCD at all — makeGzipCSV and this file's own runUnzip/makeNonXLSXZip all use
// blocking file/pipe I/O on the calling thread now).

private let sharedData = try! corpus()

private struct ZipCreationFailed: Error {}

/// A real (non-xlsx) zip archive, built with `/usr/bin/zip` — mirrors Fixtures.swift's
/// makeGzipCSV pattern (drain synchronously on the calling thread, check the exit status) for
/// the one fixture that file doesn't already provide.
private func makeNonXLSXZip(dir: String) throws -> String {
    let entryName = "a.txt"
    try "hello".write(
        toFile: (dir as NSString).appendingPathComponent(entryName), atomically: true, encoding: .utf8
    )
    let zipPath = (dir as NSString).appendingPathComponent("notes.zip")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    process.arguments = ["-q", zipPath, entryName]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = outPipe
    try process.run()
    _ = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ZipCreationFailed() }
    return zipPath
}

// MARK: - list_sheets

@Test func sheetsAreEnumeratedWithDimensions() throws {
    let sheets = try listSheets(path: sharedData.xlsx)
    let byName = Dictionary(uniqueKeysWithValues: sheets.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["Summary", "By Store", "Empty"])
    #expect(byName["Summary"]?.rows == 2 && byName["Summary"]?.cols == 2)
    #expect(byName["By Store"]?.rows == 51)
    #expect(byName["Empty"]?.empty == true)
    #expect(byName["By Store"]?.empty == false)
}

// MARK: - legacy .xls / non-xlsx zip refusals

@Test func legacyXlsGetsAReadableRefusal() throws {
    #expect(throws: LegacyXls.self) { try detectFormat(sharedData.fakeXLS) }
    do {
        _ = try detectFormat(sharedData.fakeXLS)
        Issue.record("expected LegacyXls")
    } catch let e as LegacyXls {
        #expect(e.message.contains(".xlsx"))
        #expect(e.message.lowercased().contains("legacy"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func aZipThatIsNotXLSXIsRefused() throws {
    let zip = try makeNonXLSXZip(dir: TestTemp.dir("sheets"))
    #expect(throws: UnsupportedSource.self) { try detectFormat(zip) }
}

// MARK: - supplementary (list_sheets on odd.xlsx / amp.xlsx — see the file header)

@Test func listSheetsUnescapesAnApostropheInASheetNameWithoutARegex() throws {
    // The half of test_sheet_names_with_quotes_do_not_break_the_expression that doesn't need
    // build_source: odd.xlsx's sheet is named `it's a sheet` in xl/workbook.xml as a bare,
    // unescaped apostrophe inside a double-quoted XML attribute (see Fixtures/README.md) — the
    // exact case a regex-based reader would get right by accident and an ampersand-named sheet
    // would not.
    let sheets = try listSheets(path: bundledXLSXPath("odd"))
    #expect(sheets.map(\.name) == ["it's a sheet"])
    #expect(sheets[0].rows == 2 && sheets[0].cols == 1)
}

@Test func listSheetsUnescapesAnAmpersandInASheetNameAndReportsANonA1AnchoredDimension() throws {
    // The case the file header's regex warning is actually about: unlike an apostrophe, `&`
    // MUST be entity-escaped inside XML — amp.xlsx's sheet is named "R&D" but arrives in
    // workbook.xml as `name="R&amp;D"`. A `name="([^"]*)"` regex (which passes on odd.xlsx) would
    // return the raw "R&amp;D" here; XMLParser hands back the decoded "R&D".
    //
    // Also the dimension isn't anchored at A1 (`<dimension ref="B2:C10"/>`), which is the
    // fixture that catches parseDimensionRef treating openpyxl's max_row/max_column as a SPAN
    // from the start cell (end - start + 1 = 9x2) instead of the end coordinate outright
    // (10x3, MEASURED against openpyxl) — every other committed fixture happened to start at
    // A1, where the two formulas agree.
    let sheets = try listSheets(path: bundledXLSXPath("amp"))
    #expect(sheets.map(\.name) == ["R&D"])
    #expect(sheets[0].rows == 10 && sheets[0].cols == 3)
}
