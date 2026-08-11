import Foundation
import TestSupport

// A test target cannot see another test target's files (SwiftPM test targets don't export to one
// another — see Tests/SiftEngineTests/Fixtures.swift's header for the same trade-off made twice
// already on this branch), so this is a third small copy rather than a cross-target dependency.
//
// Paths come from `TestSupport.TestTemp`, the one place any test on this branch is allowed to name
// a path on disk: a per-process root removed by an `atexit` handler. MEASURED on 2026-08-11 before
// it existed: 55,375 orphaned directories, 22 GB, on a volume with 1.2 GB free. Nothing here may
// reintroduce a bare `FileManager.default.temporaryDirectory.appendingPathComponent(UUID())`.

/// A freshly created directory under the suite's per-process temp root.
func tempDir(_ label: String = "siftui") -> URL {
    URL(fileURLWithPath: TestTemp.dir(label))
}

/// A path under the same root that is *not* created — what `Session.init(home:)` wants, since it
/// creates its own home at 0700.
func tempHome() -> String { TestTemp.path("siftui-home") }

/// A CSV with a numeric, a text and a deliberately three-state column: a real NULL (an unquoted
/// missing field), a real empty string (a quoted one), and the literal sentinel "N/A". Those three
/// staying distinct is the product's whole premise (spec §9), and every rendering test needs a row
/// of each — so row `i % 3` picks one, and `rows` must be a multiple of 3 for all three to appear.
@discardableResult
func makeCSV(in dir: URL, name: String = "t.csv", rows: Int = 12) throws -> String {
    var out = "id,label,note\n"
    for i in 0..<rows {
        let note = i % 3 == 0 ? "" : (i % 3 == 1 ? "\"\"" : "N/A")
        out += "\(i),row\(i),\(note)\n"
    }
    let path = dir.appendingPathComponent(name).path
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Wait for `condition` to hold, polling at 20 ms, up to `timeout` seconds. Returns whether it
/// held before the deadline.
///
/// 🔴 **The reason no test here asserts anything immediately after spawning a `Task`.** A `Task {}`
/// is not guaranteed to have started by the next line, so "background work is in flight" is not
/// observable by construction — a test that assumes it passes for the wrong reason. Every
/// background assertion in this target polls for a real signal instead, and the polling itself is
/// what makes the assertion honest: it fails by timing out, not by reading a value that was never
/// going to change.
func waitFor(
    _ timeout: Double = 5, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await MainActor.run(body: condition)
}
