// swift-tools-version:5.9
//
// The native shell for Sift: a real .app window over the Python/DuckDB engine.
//
// Built with SwiftPM alone — no Xcode required, which matters because only the Command Line Tools
// are installed here and `xcodebuild` refuses to run without full Xcode. AppKit, WebKit and
// UniformTypeIdentifiers all ship in the CLT SDK, so `swift build` is enough.
//
// Deliberately zero dependencies. The tempting one — duckdb-swift — publishes no stable release
// tags (every tag is a `-dev` prerelease, which SwiftPM's resolver ignores) and vendors a 400-file
// C++ amalgamation. Keeping DuckDB in the Python sidecar means the data layer stays editable by the
// maintain it, without a C++ toolchain in the loop.
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Sift", path: "Sources/Sift")
    ]
)
