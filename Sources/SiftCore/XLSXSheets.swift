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
/// Drains stdout and stderr concurrently while the process runs — `unzip` writes its "caution:
/// filename not matched" diagnostics to stderr, and a large worksheet's stdout can exceed the
/// pipe buffer, so reading either pipe synchronously after `waitUntilExit()` risks a deadlock
/// (the child blocks writing to a full pipe nobody is draining yet).
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

    // Safe despite the mutation happening off the current isolation domain: group.wait() below
    // is the barrier — nothing reads either var until both async blocks have signaled `leave()`.
    nonisolated(unsafe) var outData = Data()
    nonisolated(unsafe) var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.wait()
    process.waitUntilExit()

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

/// A workbook with no `<dimension>` reports (0, 0). See the doc note on `listSheets` for why
/// that's deliberate: `SheetInfo.empty` (`rows <= 1`) then reads this sheet as empty, but the
/// picker still offers it rather than hiding it entirely.
private func parseDimensionRef(_ ref: String) -> (rows: Int, cols: Int) {
    let parts = ref.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard let start = parseCellRef(parts[0]) else { return (0, 0) }
    guard parts.count > 1, let end = parseCellRef(parts[1]) else {
        return (1, 1)   // single-cell ref, e.g. "A1"
    }
    return (rows: end.row - start.row + 1, cols: end.col - start.col + 1)
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
/// A workbook with no `<dimension>` reports `rows: 0, cols: 0` and is treated as **non-empty**
/// by `SheetInfo.empty` (`rows <= 1`), so the picker still offers it rather than hiding it.
public func listSheets(path: String) throws -> [SheetInfo] {
    let workbookXML = try runUnzip(path: path, entry: "xl/workbook.xml")
    let sheets = try parseWorkbookSheets(workbookXML)

    let relsData = try? runUnzip(path: path, entry: "xl/_rels/workbook.xml.rels")
    let targets = relsData.map(parseRelationships) ?? [:]

    return sheets.enumerated().map { index, sheet in
        let target = targets[sheet.rId] ?? "xl/worksheets/sheet\(index + 1).xml"
        let entry = resolveWorksheetEntry(target)
        let dims = (try? runUnzip(path: path, entry: entry)).map(worksheetDimension) ?? (rows: 0, cols: 0)
        return SheetInfo(name: sheet.name, rows: dims.rows, cols: dims.cols)
    }
}
