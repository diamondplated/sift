import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Delta tables. Ported from engine/tests/test_delta.py.
//
// The whole point of this file is one comparison: a raw parquet glob resurrects tombstoned
// rows, and delta_scan does not. If those two numbers are ever equal the fixture has no
// tombstones and the test proves nothing — so that is asserted too.

private let sharedData = try! corpus()

/// Mirrors core/stage.py's `GB` for exactly the one test that needs it (`shouldDeltaIsNeverStaged`
/// below) — `SiftCore.GB` is module-internal, not `public` (nothing outside stage.py referenced
/// it in Python either), so this is a one-line re-declaration rather than a reason to widen that
/// API surface.
private let GB = 1024 * 1024 * 1024

private func newConnection(extensions: [String] = []) throws -> Connection {
    let db = try Database.inMemory()
    db.loadExtensions(extensions)
    return try db.connect()
}

@Test(.enabled(if: extensionIsAvailable("delta"), "duckdb delta extension not installed"))
func aDeltaDirResolvesToDeltaScanNotAGlob() throws {
    let con = try newConnection(extensions: ["delta"])
    let spec = try buildSource(con, path: sharedData.delta)
    #expect(spec.fmt == .delta)
    #expect(spec.readFn == "delta_scan")
    #expect(readExpr(spec: spec).hasPrefix("delta_scan("))
}

@Test(.enabled(if: extensionIsAvailable("delta"), "duckdb delta extension not installed"))
func tombstonedRowsAreExcluded() throws {
    let con = try newConnection(extensions: ["delta"])
    let spec = try buildSource(con, path: sharedData.delta)
    let deltaRows = try con.query("SELECT count(*) FROM \(readExpr(spec: spec))").allRows()[0][0]
    let globRows = try con.query(
        "SELECT count(*) FROM read_parquet(\(qlit(sharedData.delta + "/*.parquet")))"
    ).allRows()[0][0]

    #expect(deltaRows == .int(100), "delta_scan should honor the version-1 remove action")
    #expect(globRows == .int(150), "the tombstoned file is still on disk, so a raw glob sees it")
    // The assertion that keeps this test honest.
    #expect(globRows != deltaRows, "fixture has no tombstones — this test would pass even if delta support were broken")
}

@Test func aPlainParquetFolderStillGlobs() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.hive)
    #expect(spec.fmt == .globParquet)
    #expect(spec.readFn == "read_parquet")
}

@Test func versionIsReadFromTheLog() throws {
    #expect(deltaVersion(sharedData.delta) == 1)
}

@Test(.enabled(if: extensionIsAvailable("delta"), "duckdb delta extension not installed"))
func timeTravelUsesTheVersionArgument() throws {
    // `version => n` works; the SQL-standard `AT (VERSION => n)` does not parse on 1.5.5.
    let con = try newConnection(extensions: ["delta"])
    let spec = try buildSource(con, path: sharedData.delta)
    let at0 = try readExprAt(spec: spec, version: 0)
    #expect(at0.contains("version=0"))
    let n = try con.query("SELECT count(*) FROM \(at0)").allRows()[0][0]
    #expect(n == .int(150))   // before the delete
}

@Test func readExprAtRefusesNonDelta() throws {
    let con = try newConnection()
    let spec = try buildSource(con, path: sharedData.parquet)
    #expect(throws: TimeTravelUnsupported.self) { _ = try readExprAt(spec: spec, version: 0) }
}

@Test func deltaIsNeverStaged() throws {
    // A flat copy of a Delta table silently pins it to one version, on top of being redundant.
    let d = shouldStage(fmt: .delta, sizeBytes: 50 * GB, freeBytes: 500 * GB)
    #expect(d.stage == false)
    #expect(d.reason.contains("version"))
}
