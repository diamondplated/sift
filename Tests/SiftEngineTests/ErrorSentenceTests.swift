import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// 🔴 EVERY PUBLIC `Session` METHOD REPORTS FAILURE AS ONE CLEAN SENTENCE.
//
// `SiftError` conforms to `LocalizedError` for exactly this reason (SiftCore/Types.swift): without
// it, Foundation bridges an error to `NSError` and synthesizes
// "The operation couldn't be completed. (DuckDBKit.DuckDBError error 1.)" — which is what
// `sift bad.parquet` printed, and what the UI plan's `banner = error.localizedDescription` would
// have shown, for the single most common user error in the product. DuckDB's own
// `Invalid Input Error: No magic bytes found at end of file '…'` was not truncated, it was
// DISCARDED.
//
// Two independent things are pinned here, and they are not redundant:
//
//  1. **`DuckDBError` itself conforms to `LocalizedError`** (DuckDBKitTests pins that directly).
//     That covers every site nobody has enumerated — including `Session.init`, which the CLI
//     surfaces before any of these methods can run.
//  2. **Every public method wraps a `DuckDBError` into a `SessionError`**, so the engine's public
//     error type stays consistent and a caller can `catch let e as SessionError` and get the
//     sentence. The six below leaked; the other twelve already wrapped.
//
// Each failure here is REACHED, not simulated: a corrupt file for `openPath`, and for the other
// five the catalog state DuckDB genuinely refuses (a `DROP VIEW` against a table, a `DROP TABLE`
// against a view, a missing catalog table, a source file deleted out from under an open tab).
// `Session.database` is internal, so a `@testable` test can put the store into those states the
// same way a crash, a concurrent writer or a user with `rm` would.

private func newSessionHome() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-error-sentence-tests-\(UUID().uuidString)").path
}

private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-error-sentence-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// The shape a Foundation dump has. Nothing the engine throws may ever match it.
private func isAFoundationDump(_ text: String) -> Bool {
    text.contains("The operation couldn") || text.contains("error 1.)")
}

/// Assert one thrown error is a `SessionError` whose sentence survives BOTH string paths.
private func expectSentence(
    _ what: String, _ body: () async throws -> Void,
    contains fragment: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await body()
        Issue.record("\(what) did not throw at all", sourceLocation: sourceLocation)
    } catch let error as SessionError {
        #expect(!isAFoundationDump(error.localizedDescription),
                "\(what) leaked a Foundation dump: \(error.localizedDescription)",
                sourceLocation: sourceLocation)
        #expect(error.localizedDescription == error.message,
                "\(what): localizedDescription and message disagree", sourceLocation: sourceLocation)
        #expect((error as NSError).localizedDescription == error.message,
                "\(what): the bridged NSError path lost the sentence", sourceLocation: sourceLocation)
        if let fragment {
            #expect(error.message.contains(fragment),
                    "\(what) said: \(error.message)", sourceLocation: sourceLocation)
        }
    } catch {
        let detail = "\(what) threw \(type(of: error)) instead of SessionError: \(error.localizedDescription)"
        Issue.record(Comment(rawValue: detail), sourceLocation: sourceLocation)
    }
}

// MARK: - the one that is live in the shipping CLI

/// The four malformed opens `sift <path>` can be pointed at. Every one of them used to print
/// `sift: The operation couldn’t be completed. (DuckDBKit.DuckDBError error 1.)`.
@Test func everyMalformedOpenReportsDuckDBsOwnSentence() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func write(_ name: String, _ bytes: String) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try bytes.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    let cases = [
        ("a corrupt parquet", try write("corrupt.parquet", "this is not a parquet file")),
        ("an empty parquet", try write("empty.parquet", "")),
        ("a corrupt json", try write("corrupt.json", "{\"a\": ")),
        ("a corrupt ndjson", try write("corrupt.ndjson", "{\"a\": 1}\n{not json at all\n")),
    ]
    for (what, path) in cases {
        let session = try Session(home: newSessionHome())
        await expectSentence("openPath on \(what)") { _ = try await session.openPath(path) }
    }
}

// MARK: - the other five

@Test func closeTableReportsACatalogRefusalAsASentence() async throws {
    // A staging swap turns the name into a real TABLE, and `DROP VIEW` on a table is a hard
    // `Catalog Error` — the review-I6 window, reconstructed exactly rather than raced.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try makeCSV(dir: dir, name: "x.csv", rows: 5)
    let session = try Session(home: newSessionHome())
    let t = try await session.openPath(path, name: "x")

    let con = try session.database.connect()
    try con.execute("DROP VIEW IF EXISTS \(q(t.name))")
    try con.execute("CREATE TABLE \(q(t.name)) (a INTEGER)")

    await expectSentence("closeTable over a table holding the name") {
        try await session.closeTable(t.name)
    }
}

@Test func unstageReportsACatalogRefusalAsASentence() async throws {
    // The mirror image: `unstage` drops the staged TABLE, and a VIEW under that name makes
    // `DROP TABLE` the hard error instead.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try makeCSV(dir: dir, name: "x.csv", rows: 5)
    let session = try Session(home: newSessionHome())
    let t = try await session.openPath(path, name: "x")
    // `staged = true` without a real copy — the name is still the view `openPath` created.
    _ = await session.applyStaged(t.name, physicalRows: 5, openedAt: t.openedAt, jobID: "none")

    await expectSentence("unstage over a view holding the name") {
        _ = try await session.unstage(t.name)
    }
}

@Test func stagedEntriesAndPurgeStagedReportAMissingCatalogAsASentence() async throws {
    let session = try Session(home: newSessionHome())
    let con = try session.database.connect()
    try con.execute("DROP TABLE IF EXISTS _sift_sources")

    await expectSentence("stagedEntries with no catalog") { _ = try await session.stagedEntries() }
    await expectSentence("purgeStaged with no catalog") { _ = try await session.purgeStaged() }
}

@Test func badRowsReportsAVanishedSourceFileAsASentence() async throws {
    // The panel reads the file through its all-varchar expression, not through the view, so a
    // source deleted while its tab is open fails inside `badRows` itself. Reachable by anyone
    // with `rm`, and it used to arrive as a raw DuckDB dump because this one method deliberately
    // did not wrap — a Python-parity decision that the "one clean sentence" contract outranks.
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try makeCSV(dir: dir, name: "dirty.csv", rows: 50)

    let session = try Session(home: newSessionHome())
    let t = try await session.openPath(path)
    // Let the real background scan land first, so it cannot overwrite the count planted below.
    let deadline = Date().addingTimeInterval(30)
    while try await session.table(t.name).stageDecision == nil {
        if Date() > deadline { Issue.record("the post-open pipeline never landed"); return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // `badCells > 0` is what makes `badRows` actually run its query rather than return the empty
    // panel. Planted through the same isolated apply the real scan uses — a 25,000-row gzip
    // fixture buys nothing here, since it is the QUERY that has to fail, not the scan.
    await session.applyBadRows(
        t.name, BadRowScan(uncastable: ["amount__bad": 1], badCells: 1, badRows: 1),
        openedAt: t.openedAt
    )
    try FileManager.default.removeItem(atPath: path)

    await expectSentence("badRows after the source file vanished") {
        _ = try await session.badRows(t.name)
    }
}

// MARK: - and the conformance that covers the sites nobody enumerated

@Test func sessionInitReportsAnUnopenableStoreAsASentence() async throws {
    // `Session.init` is a public method that throws `DuckDBError` from `Database(path:)`, and it
    // is the first thing the CLI and the app call. A home whose `stage.duckdb` is a directory
    // cannot be opened as a database.
    let home = newSessionHome()
    try FileManager.default.createDirectory(
        atPath: (home as NSString).appendingPathComponent("stage.duckdb"),
        withIntermediateDirectories: true
    )
    await expectSentence("Session.init over an unopenable store") { _ = try Session(home: home) }
}
