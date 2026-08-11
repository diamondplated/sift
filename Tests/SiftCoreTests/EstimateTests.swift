import Testing
import Foundation
import TestSupport
@testable import SiftCore

// Row estimation from byte samples. No connection needed. Ported verbatim from
// engine/tests/test_estimate.py — every test in that file is pure, so nothing is skipped here.

private func freshTempDir() throws -> String { TestTemp.dir("estimate") }

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
    let est = try estimateRows(path: p, headerBytes: firstLineByteCount(p))
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
    let est = try estimateRows(path: p, headerBytes: header)   // production chunks/chunkBytes
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
    let est = try estimateRows(path: p, headerBytes: header)
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
    let est = try estimateRows(path: p, headerBytes: header, chunks: 3, chunkBytes: 8192)
    #expect(est.confidence == .high)     // honest about being unable to know
    #expect(est.rows != 60_000)          // and it is indeed off
}

@Test func smallQuotedFileIsNotClaimedExact() throws {
    let dir = try freshTempDir()
    let p = try makeCSV(dir: dir, name: "sq.csv", rows: 300, quotedNewlineRow: 100)
    let est = try estimateRows(path: p, headerBytes: firstLineByteCount(p))
    #expect(est.confidence == .low)
}

@Test func emptyAndHeaderOnly() throws {
    let dir = try freshTempDir()
    let empty = (dir as NSString).appendingPathComponent("e.csv")
    FileManager.default.createFile(atPath: empty, contents: Data())
    #expect(try estimateRows(path: empty).rows == 0)

    let hdr = (dir as NSString).appendingPathComponent("h.csv")
    try "a,b\n".write(toFile: hdr, atomically: true, encoding: .utf8)
    let est = try estimateRows(path: hdr, headerBytes: 4)
    #expect(est.rows == 0)
}

// The `basis` strings are shown on hover and go through the same locale-trap formatter as
// `human()` (Python's `f"{n:,}"`). Asserted verbatim — no test in either language pinned one, so
// a group-separator change was invisible. 200 lines of 10 bytes is exactly 2,000 B, chosen so the
// number is large enough to be grouped at all.
@Test func basisNamesTheByteCountWithACommaGroupSeparator() throws {
    let dir = try freshTempDir()
    let p = (dir as NSString).appendingPathComponent("grouped.csv")
    try String(repeating: "abcdefghi\n", count: 200).write(toFile: p, atomically: true, encoding: .utf8)
    let est = try estimateRows(path: p)
    #expect(est.rows == 200)
    #expect(est.confidence == .exact)
    #expect(est.basis == "counted every byte (2,000 B)")
}

@Test func noTrailingNewlineStillCountsTheLastRow() throws {
    let dir = try freshTempDir()
    let p = (dir as NSString).appendingPathComponent("nt.csv")
    try "a,b\n1,2\n3,4".write(toFile: p, atomically: true, encoding: .utf8)   // final row has no \n
    let est = try estimateRows(path: p, headerBytes: 4)
    #expect(est.rows == 2)
}

// A path that cannot be read must not produce a number. Before this, a missing file reported
// `rows: 0` at `.exact` confidence with the basis "file has no data past the header" — which is
// the correct answer for a real empty file and a fabricated one here — and an unreadable file
// claimed "sampling found no line breaks" without ever having sampled. Python raises on both.
@Test func anUnreadablePathThrowsRatherThanReportingAPlausibleZero() throws {
    let missing = (try freshTempDir() as NSString).appendingPathComponent("nope.csv")
    #expect(throws: UnsupportedSource.self) { try estimateRows(path: missing) }
    #expect(throws: UnsupportedSource.self) {
        try headerByteOffset(path: missing, sniff: SniffHints(skip: 0, header: true))
    }
    // But skip <= 0 never opens the file at all, in either language.
    #expect(try headerByteOffset(path: missing, sniff: SniffHints(skip: 0, header: false)) == 0)
}
