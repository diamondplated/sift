import Testing
import Foundation
@testable import SiftCore

// Row estimation from byte samples. No connection needed. Ported verbatim from
// engine/tests/test_estimate.py — every test in that file is pure, so nothing is skipped here.

private func freshTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sift-estimate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// Mirrors Python's `len(open(p, "rb").readline())`: the byte length of the first line,
/// including its terminator.
private func firstLineByteCount(_ path: String) -> Int {
    let handle = FileHandle(forReadingAtPath: path)!
    defer { try? handle.close() }
    var line = Data()
    while true {
        guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else { break }
        line.append(byte)
        if byte.first == 0x0A { break }
    }
    return line.count
}

@Test func smallFileIsCountedExactly() throws {
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "small.csv", rows: 500)
    let est = estimateRows(path: p, headerBytes: firstLineByteCount(p))
    #expect(est.rows == 500)
    #expect(est.confidence == .exact)
}

@Test func largeUnquotedFileEstimatesWithinFivePercent() throws {
    // Accuracy at the production window size, on a deliberately unhelpful file.
    //
    // This fixture's rows GROW in length (note text carries the row number), which is the worst
    // case for extrapolating from samples. At the real 256 KiB window it lands within ~2%; with
    // artificially small windows it degrades to ~7%, so this test uses the defaults the app
    // actually runs with.
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "big.csv", rows: 60_000)
    let header = firstLineByteCount(p)
    let est = estimateRows(path: p, headerBytes: header)   // production chunks/chunkBytes
    #expect(est.confidence == .high)
    let err = abs(Double(est.rows) - 60_000) / 60_000
    #expect(err < 0.05, "got \(est.rows) (\(err) off)")
    #expect(est.basis.contains("no quote characters"))
}

@Test func quotesDowngradeConfidence() throws {
    // A quoted field can contain a newline, which makes line counting overshoot. There is no
    // cheap way to know how often that happens, so the estimate reports low confidence rather
    // than pretending to be exact.
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "q.csv", rows: 60_000, quoteNotes: true)
    let header = firstLineByteCount(p)
    let est = estimateRows(path: p, headerBytes: header)
    #expect(est.confidence == .low)
    #expect(est.basis.contains("quote characters"))
}

@Test func anIsolatedQuotedNewlineOutsideTheSampleIsNotDetected() throws {
    // The known blind spot, asserted so nobody mistakes it for a guarantee.
    //
    // Sampling three windows cannot see a lone quoted newline elsewhere in the file, so the
    // estimate will claim "high" and be slightly over. This is why the UI shows estimates with a
    // visible "≈" and why anything under 64 MB gets a real count instead.
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "one.csv", rows: 60_000, quotedNewlineRow: 30_000)
    let header = firstLineByteCount(p)
    let est = estimateRows(path: p, headerBytes: header, chunks: 3, chunkBytes: 8192)
    #expect(est.confidence == .high)     // honest about being unable to know
    #expect(est.rows != 60_000)          // and it is indeed off
}

@Test func smallQuotedFileIsNotClaimedExact() throws {
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "sq.csv", rows: 300, quotedNewlineRow: 100)
    let est = estimateRows(path: p, headerBytes: firstLineByteCount(p))
    #expect(est.confidence == .low)
}

@Test func emptyAndHeaderOnly() throws {
    let dir = try freshTempDir()
    let empty = (dir as NSString).appendingPathComponent("e.csv")
    FileManager.default.createFile(atPath: empty, contents: Data())
    #expect(estimateRows(path: empty).rows == 0)

    let hdr = (dir as NSString).appendingPathComponent("h.csv")
    try "a,b\n".write(toFile: hdr, atomically: true, encoding: .utf8)
    let est = estimateRows(path: hdr, headerBytes: 4)
    #expect(est.rows == 0)
}

@Test func noTrailingNewlineStillCountsTheLastRow() throws {
    let dir = try freshTempDir()
    let p = (dir as NSString).appendingPathComponent("nt.csv")
    try "a,b\n1,2\n3,4".write(toFile: p, atomically: true, encoding: .utf8)   // final row has no \n
    let est = estimateRows(path: p, headerBytes: 4)
    #expect(est.rows == 2)
}
