import Foundation
import SiftEngine

// The `sift` CLI. Deliberately almost empty: a SwiftPM test target cannot import an
// `executableTarget`, so every line written here is a line no test will ever run. Argument
// parsing, the checks, the exit-status rule and all the formatting live in
// SiftEngine/Verification.swift, which SiftEngineTests does import. This file matches arguments
// to calls and prints strings — nothing else belongs in it.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sift: " + message + "\n" + siftUsage + "\n").utf8))
    exit(2)
}

switch parseArguments(Array(CommandLine.arguments.dropFirst())) {
case .help:
    print(siftUsage)

case .usageError(let message):
    fail(message)

case .verify:
    print("sift \u{2014} verifying the engine end to end\n")
    // Streamed rather than reported at the end: with a real Delta fixture and a staging job in
    // there, a silent multi-second run reads as a hang.
    let report = await runVerification { print(renderCheckResult($0)) }
    print("\n" + renderSummary(report))
    exit(report.exitCode)

case .open(let path, let sheet, let rows, let width):
    do {
        let overview = try await openAndDescribe(path: path, sheet: sheet, rows: rows)
        print(renderOverview(overview, width: width))
    } catch {
        // Every engine error already spells one clean sentence (SiftCore's `SiftError`); printing
        // anything more here would be a parser dump the user cannot act on.
        FileHandle.standardError.write(Data("sift: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
