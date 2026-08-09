import Testing
import DuckDBKit
import Foundation
@testable import SiftCore
@testable import SiftEngine

// Fixture builders, trimmed from Tests/SiftCoreTests/Fixtures.swift to exactly what
// SourceProbeTests.swift and DeltaTests.swift need. Not reused directly: SwiftPM test targets
// don't export to one another (see DuckDB155FactsTests.swift's `siftCoreTestsFixture`/
// `extensionIsAvailable` for the same trade-off, made once already on this branch), so this is a
// second small copy rather than a cross-target dependency. The two committed xlsx workbooks
// (book.xlsx, odd.xlsx) ARE reused, via the same #filePath-relative sibling-directory trick —
// no reason to duplicate bytes that already have one canonical home and a README explaining them.

private func join(_ dir: String, _ name: String) -> String {
    URL(fileURLWithPath: dir).appendingPathComponent(name).path
}

private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-engine-fixtures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

func extensionIsAvailable(_ name: String) -> Bool {
    guard let db = try? Database.inMemory() else { return false }
    db.loadExtensions([name])
    return db.loadedExtensions[name] == true
}

/// Tests/SiftCoreTests/Fixtures/<name>.xlsx — see that directory's README for why these three
/// workbooks are committed rather than generated. `#filePath` is this file's own absolute source
/// path at compile time, which `swift test` preserves regardless of process cwd: one
/// `deletingLastPathComponent()` walks SiftEngineTests/ up to Tests/, then back down into the
/// sibling SiftCoreTests/Fixtures/ the golden workbooks actually live in.
func siftCoreTestsFixture(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SiftCoreTests/Fixtures/\(name)").path
}

// MARK: - CSV

/// Write a CSV and return its path. Trimmed from SiftCoreTests' `makeCSV`: only the knobs
/// SourceProbeTests actually uses (rows, delim, crlf, bom, preamble, badIntRow, quotedNewlineRow)
/// — always headered, never ragged, no null/empty/nullish sentinels, matching the Python
/// fixtures those tests read (clean_csv, semi_csv, weird_csv, dirty_csv, qnl_csv).
func makeCSV(
    dir: String, name: String = "sales.csv", rows: Int = 1000, delim: String = ",",
    crlf: Bool = false, bom: Bool = false, preamble: Int = 0,
    badIntRow: Int? = nil, quotedNewlineRow: Int? = nil
) throws -> String {
    let path = join(dir, name)
    let eol = crlf ? "\r\n" : "\n"
    let regions = ["West", "Midwest", "South", "Northeast"]

    var out = ""
    if bom { out += "\u{FEFF}" }
    for i in 0..<preamble {
        out += "# generated file, junk line \(i)\(eol)"
    }
    out += ["order_id", "region", "amount", "note"].joined(separator: delim) + eol
    for i in 0..<rows {
        let region = regions[i % regions.count]
        var amount = "\(i).50"
        if let bir = badIntRow, i == bir { amount = "N/A" }
        var note = "note \(i)"
        if let qnr = quotedNewlineRow, i == qnr { note = "\"line one\(eol)line two\"" }
        let fields = [String(i), region, amount, note]
        out += fields.joined(separator: delim) + eol
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - Parquet / hive / delta (written by DuckDB itself)

func makeParquet(con: Connection, dir: String, name: String = "t.parquet", rows: Int = 1000) throws -> String {
    let path = join(dir, name)
    try con.execute(
        "COPY (SELECT range AS order_id, "
            + "['West','Midwest','South','Northeast'][(range % 4) + 1] AS region, "
            + "(range * 1.5)::DECIMAL(12,2) AS amount, "
            + "CASE WHEN range % 50 = 0 THEN NULL ELSE 'note ' || range END AS note "
            + "FROM range(\(rows))) TO \(qlit(path)) (FORMAT parquet)"
    )
    return path
}

/// A hive-partitioned dataset: dt=.../region=.../part-0.parquet.
func makeHiveParquet(con: Connection, dir: String, name: String = "events", rows: Int = 400) throws -> String {
    let root = join(dir, name)
    let combos = [("2026-08-01", "West"), ("2026-08-01", "South"),
                  ("2026-08-02", "West"), ("2026-08-02", "South")]
    for (d, region) in combos {
        let part = URL(fileURLWithPath: root)
            .appendingPathComponent("dt=\(d)")
            .appendingPathComponent("region=\(region)")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        let partFile = part.appendingPathComponent("part-0.parquet").path
        try con.execute(
            "COPY (SELECT range AS id, (range * 2)::BIGINT AS qty FROM range(\(rows / 4))) "
                + "TO \(qlit(partFile)) (FORMAT parquet)"
        )
    }
    return root
}

private func jsonString(_ obj: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? ""
}

private func jsonLine(_ obj: [String: Any]) throws -> String {
    try jsonString(obj) + "\n"
}

/// A minimal but real Delta table whose version 1 tombstones a still-present file — see
/// Tests/SiftCoreTests/Fixtures.swift's `makeDelta` (identical logic) for the full rationale.
func makeDelta(con: Connection, dir: String, name: String = "dtable",
                kept: Int = 100, tombstoned: Int = 50) throws -> String {
    let root = join(dir, name)
    let logDir = join(root, "_delta_log")
    try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

    let part0 = "part-0.parquet"
    let part1 = "part-1.parquet"
    try con.execute(
        "COPY (SELECT range AS id, 'a' AS g FROM range(\(kept))) TO \(qlit(join(root, part0))) (FORMAT parquet)")
    try con.execute(
        "COPY (SELECT range AS id, 'b' AS g FROM range(\(kept), \(kept + tombstoned))) "
            + "TO \(qlit(join(root, part1))) (FORMAT parquet)")

    let schema: [String: Any] = [
        "type": "struct",
        "fields": [
            ["name": "id", "type": "long", "nullable": true, "metadata": [String: Any]()],
            ["name": "g", "type": "string", "nullable": true, "metadata": [String: Any]()],
        ],
    ]
    let schemaString = try jsonString(schema)

    func size(_ filename: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: join(root, filename))
        return (attrs[.size] as? Int) ?? 0
    }

    let fixedMs = 1_770_000_000_000
    var log0 = try jsonLine(["protocol": ["minReaderVersion": 1, "minWriterVersion": 2]])
    log0 += try jsonLine(["metaData": [
        "id": UUID().uuidString.lowercased(),
        "format": ["provider": "parquet", "options": [String: Any]()],
        "schemaString": schemaString,
        "partitionColumns": [String](),
        "configuration": [String: Any](),
        "createdTime": fixedMs,
    ]])
    for p in [part0, part1] {
        log0 += try jsonLine(["add": [
            "path": p, "partitionValues": [String: Any](), "size": try size(p),
            "modificationTime": fixedMs, "dataChange": true,
        ]])
    }
    try log0.write(toFile: join(logDir, "00000000000000000000.json"), atomically: true, encoding: .utf8)

    let log1 = try jsonLine(["remove": [
        "path": part1, "deletionTimestamp": fixedMs + 1000,
        "dataChange": true, "partitionValues": [String: Any](),
        "size": try size(part1),
    ]])
    try log1.write(toFile: join(logDir, "00000000000000000001.json"), atomically: true, encoding: .utf8)

    return root
}

// MARK: - NDJSON

func makeNDJSON(dir: String, name: String = "events.ndjson", rows: Int = 200) throws -> String {
    let path = join(dir, name)
    var out = ""
    for i in 0..<rows {
        let region = i % 2 == 0 ? "West" : "South"
        out += "{\"id\": \(i), \"region\": \"\(region)\", \"nested\": {\"a\": \(i)}}\n"
    }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - Gzip CSV
//
// Blocking file-redirected `/usr/bin/gzip -c`, not a Pipe — see Tests/SiftCoreTests/Fixtures.swift's
// `makeGzipCSV` for the MEASURED GCD-thread-starvation deadlock this form avoids.
func makeGzipCSV(dir: String, name: String = "sales.csv.gz", rows: Int = 500) throws -> String {
    let path = join(dir, name)
    var text = "id,region\n"
    for i in 0..<rows {
        text += "\(i),\(i % 2 == 0 ? "South" : "West")\n"
    }
    let inputPath = join(dir, ".\(UUID().uuidString).csv")
    try text.write(toFile: inputPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: inputPath) }
    FileManager.default.createFile(atPath: path, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = FileHandle(forReadingAtPath: inputPath)
    process.standardOutput = FileHandle(forWritingAtPath: path)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DuckDBError("gzip exited \(process.terminationStatus)")
    }
    return path
}

// MARK: - The whole corpus, built once

struct FixtureCorpus: Sendable {
    let dir: String
    let cleanCSV: String
    let dirtyCSV: String
    let semiCSV: String
    let weirdCSV: String
    let quotedNLCSV: String
    let gzCSV: String
    let parquet: String
    let ndjson: String
    let hive: String
    let delta: String
    let deltaAvailable: Bool
    let excelAvailable: Bool
}

func corpus() throws -> FixtureCorpus {
    let dir = try tempDir()
    let db = try Database.inMemory()
    db.loadExtensions(["delta", "excel"])
    let con = try db.connect()

    return FixtureCorpus(
        dir: dir,
        cleanCSV: try makeCSV(dir: dir, name: "clean.csv", rows: 1000),
        dirtyCSV: try makeCSV(dir: dir, name: "dirty.csv", rows: 1000, badIntRow: 500),
        semiCSV: try makeCSV(dir: dir, name: "semi.csv", rows: 200, delim: ";"),
        weirdCSV: try makeCSV(dir: dir, name: "weird.csv", rows: 300, crlf: true, bom: true, preamble: 3),
        quotedNLCSV: try makeCSV(dir: dir, name: "qnl.csv", rows: 400, quotedNewlineRow: 100),
        gzCSV: try makeGzipCSV(dir: dir),
        parquet: try makeParquet(con: con, dir: dir, rows: 1000),
        ndjson: try makeNDJSON(dir: dir),
        hive: try makeHiveParquet(con: con, dir: dir),
        delta: try makeDelta(con: con, dir: dir),
        deltaAvailable: db.loadedExtensions["delta"] == true,
        excelAvailable: db.loadedExtensions["excel"] == true
    )
}
