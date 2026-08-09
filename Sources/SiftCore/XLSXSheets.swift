import Foundation

// Excel sheet enumeration, replacing openpyxl (no Swift equivalent).
//
// An .xlsx is a zip. `/usr/bin/unzip -p` pulls individual entries out of it without ever
// unpacking the whole archive to disk, and XMLParser reads what it finds — never a regex,
// because a sheet named "R&D" arrives in workbook.xml as `name="R&amp;D"`, and a regex that
// happens to work on the two committed fixtures would silently mangle the first real workbook
// whose sheet is called that. Ported from engine/core/source.py's `list_sheets`.

/// Run `/usr/bin/unzip -p <path> <entry>` and return the entry's raw bytes.
///
/// One blocking drain on the calling thread, not a pair of `DispatchQueue.global()` tasks: this
/// invocation never writes to the child's stdin, so there is nothing this thread could be
/// blocking that the child is waiting on, and draining stdout synchronously (whatever its size —
/// `readDataToEndOfFile()` loops internally until the pipe closes) cannot deadlock. stderr is
/// read only after the process exits, not concurrently with stdout: `unzip -p` only ever writes
/// a short diagnostic line there ("caution: filename not matched: ..."), never bulk data, so it
/// can't fill a pipe buffer and block the child before it exits. (An earlier version of this
/// function used two `DispatchQueue.global().async` drains plus a `DispatchGroup` — that pattern
/// is what caused a measured deadlock in the test suite, which shared a GCD-thread-hungry
/// subprocess fixture across many parallel tests; see task-9-report.md's review-fix section.
/// This function ships in the app, so it needed the same fix even though nothing here was ever
/// observed hanging directly — the exhaustion risk was real regardless.)
private func runUnzip(path: String, entry: String) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", path, entry]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        throw UnsupportedSource("could not run unzip for \(path): \(error.localizedDescription)")
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let msg = String(data: errData, encoding: .utf8) ?? "unzip exited \(process.terminationStatus)"
        throw UnsupportedSource("could not read \(entry) from \(basenameForXLSX(path)): \(msg)")
    }
    return outData
}

private func basenameForXLSX(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

// MARK: - XML parsing (never regex — see the file header)

private final class WorkbookSheetsDelegate: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rId: String)] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet", let name = attributeDict["name"] else { return }
        let rId = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
        sheets.append((name: name, rId: rId))
    }
}

/// Sheet names and their `r:id`, in workbook order — `<sheets><sheet name="..." r:id="rIdN"/>`.
private func parseWorkbookSheets(_ data: Data) throws -> [(name: String, rId: String)] {
    let parser = XMLParser(data: data)
    let delegate = WorkbookSheetsDelegate()
    parser.delegate = delegate
    guard parser.parse() else {
        throw UnsupportedSource(
            "could not parse workbook.xml: \(parser.parserError?.localizedDescription ?? "unknown error")"
        )
    }
    return delegate.sheets
}

private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship", let id = attributeDict["Id"],
            let target = attributeDict["Target"]
        else { return }
        targets[id] = target
    }
}

/// `r:id -> Target` from `xl/_rels/workbook.xml.rels`, so sheet order (from workbook.xml) maps
/// to the right worksheet file even if a workbook has been reordered or had sheets deleted —
/// the sheetN.xml numbering is not guaranteed to match `<sheets>` order in general.
private func parseRelationships(_ data: Data) -> [String: String] {
    let parser = XMLParser(data: data)
    let delegate = RelationshipsDelegate()
    parser.delegate = delegate
    _ = parser.parse()   // best-effort: a missing/unparsable rels file falls back to positional guessing
    return delegate.targets
}

private final class DimensionDelegate: NSObject, XMLParserDelegate {
    var ref: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "dimension" else { return }
        ref = attributeDict["ref"]
    }
}

/// `A1`, `A1:A1`, `A1:B51` -> 1-based (col, row).
private func parseCellRef(_ s: Substring) -> (col: Int, row: Int)? {
    var colChars = ""
    var idx = s.startIndex
    while idx < s.endIndex, s[idx].isLetter {
        colChars.append(s[idx])
        idx = s.index(after: idx)
    }
    guard !colChars.isEmpty, let row = Int(s[idx...]) else { return nil }
    var col = 0
    for ch in colChars.uppercased() {
        guard let a = ch.asciiValue, let aBase = Character("A").asciiValue else { return nil }
        col = col * 26 + Int(a - aBase) + 1
    }
    return (col, row)
}

/// A workbook with no `<dimension>` element at all reports (0, 0) — see `worksheetDimension`
/// below, which is what actually returns that default when parsing finds no `ref` attribute.
private func parseDimensionRef(_ ref: String) -> (rows: Int, cols: Int) {
    let parts = ref.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let start = parseCellRef(parts[0]) else { return (0, 0) }
    guard parts.count > 1, let end = parseCellRef(parts[1]) else {
        return (rows: start.row, cols: start.col)   // single-cell ref, e.g. "A1"
    }
    // openpyxl's max_row/max_column are the END coordinates outright, not a span from the
    // start: `<dimension ref="B2:C10"/>` is 10 rows deep and 3 columns wide (both counted from
    // row/col 1), MEASURED against openpyxl reading the same file — not `(10-2+1)=9` rows. Every
    // fixture before amp.xlsx happened to be anchored at A1, where the two formulas coincide,
    // which is exactly how this was wrong without a ported test catching it.
    return (rows: end.row, cols: end.col)
}

private func worksheetDimension(_ data: Data) -> (rows: Int, cols: Int) {
    let parser = XMLParser(data: data)
    let delegate = DimensionDelegate()
    parser.delegate = delegate
    _ = parser.parse()
    guard let ref = delegate.ref else { return (0, 0) }
    return parseDimensionRef(ref)
}

/// `xl/_rels/workbook.xml.rels`' `Target` is either absolute from the zip root
/// ("/xl/worksheets/sheet1.xml") or relative to `xl/` ("worksheets/sheet1.xml"); both forms are
/// seen in practice.
private func resolveWorksheetEntry(_ target: String) -> String {
    if target.hasPrefix("/") { return String(target.dropFirst()) }
    return "xl/" + target
}

/// Enumerate sheets with dimensions, without parsing cells.
///
/// openpyxl's read_only mode reads the worksheet dimension record rather than the cells, so
/// this stays fast on a large workbook; the same is true here since only `<dimension ref="…">`
/// is read out of each worksheet XML, never `<sheetData>`. DuckDB's `read_xlsx` can read a
/// *named* sheet but offers no way to list them, which is the entire reason this exists.
///
/// A workbook with no `<dimension>` element reports `rows: 0, cols: 0` for that sheet, which
/// makes `SheetInfo.empty` (`rows <= 1`) true — but `list_sheets`/`listSheets` never drops the
/// sheet from the returned list over it, and `build_source`'s `sheets[0]` fallback still picks
/// it as the default when every sheet is empty. The picker is offered the sheet either way;
/// what changes is only whether it's auto-selected ahead of a non-empty sibling.
public func listSheets(path: String) throws -> [SheetInfo] {
    let workbookXML = try runUnzip(path: path, entry: "xl/workbook.xml")
    let sheets = try parseWorkbookSheets(workbookXML)

    let relsData = try? runUnzip(path: path, entry: "xl/_rels/workbook.xml.rels")
    let targets = relsData.map(parseRelationships) ?? [:]

    return try sheets.enumerated().map { index, sheet in
        // Fallback is relative to `xl/` (no leading "xl/" of its own) so it matches the shape
        // `resolveWorksheetEntry` expects from a rels Target — passing "xl/worksheets/sheetN.xml"
        // through there produced "xl/xl/worksheets/sheetN.xml" and unzip failed every time the
        // rels file was unreadable, MEASURED by deleting it and re-zipping.
        let target = targets[sheet.rId] ?? "worksheets/sheet\(index + 1).xml"
        let entry = resolveWorksheetEntry(target)
        // Not `try?`: a worksheet entry that fails to read (wrong resolved path, corrupt
        // archive, anything) must refuse loudly. Silently reporting 0×0 — indistinguishable
        // from the legitimate no-`<dimension>` case above — is a wrong number presented with the
        // same confidence as a right one, in the one product that exists not to do that.
        let dims = worksheetDimension(try runUnzip(path: path, entry: entry))
        return SheetInfo(name: sheet.name, rows: dims.rows, cols: dims.cols)
    }
}
