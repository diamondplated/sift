// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The dylib's install name is @rpath/libduckdb.dylib, so both `swift test` and any
// executable need an rpath pointing at Vendor/duckdb. An absolute path computed from
// the manifest's own location is the only form that works for every build product
// without per-invocation flags. build-app.sh rewrites this for the shipped bundle.
let vendorPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/duckdb")
    .path

let duckdbLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(vendorPath)", "-Xlinker", "-rpath", "-Xlinker", vendorPath])
]

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DuckDBKit", targets: ["DuckDBKit"]),
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftEngine", targets: ["SiftEngine"]),
        .executable(name: "sift", targets: ["sift"]),
    ],
    targets: [
        .systemLibrary(name: "CDuckDB", path: "Sources/CDuckDB"),
        // Test-only, and deliberately NOT a test target: SwiftPM test targets cannot import one
        // another (the reason Tests/SiftEngineTests/Fixtures.swift is a second copy of
        // Tests/SiftCoreTests/Fixtures.swift), and all three of them need the same temp-directory
        // root. Lives under Tests/ so it cannot be mistaken for shipping code, and is depended on
        // by nothing else, so it never reaches Sift.app.
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .target(
            name: "DuckDBKit",
            dependencies: ["CDuckDB"],
            linkerSettings: duckdbLink
        ),
        .testTarget(
            name: "DuckDBKitTests",
            dependencies: ["DuckDBKit", "TestSupport"]
        ),
        // Pure value types only — no dependencies, imports Foundation and nothing else.
        .target(name: "SiftCore"),
        .testTarget(
            name: "SiftCoreTests",
            dependencies: ["SiftCore", "DuckDBKit", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        // The connection-needing half of core/source.py (and, later in this plan, session.py).
        // No linkerSettings here: DuckDBKit's rpath flags already propagate transitively through
        // this target's dependency on it, and a duplicate `-Xlinker -rpath` emits
        // `ld: warning: duplicate -rpath`.
        //
        // CDuckDB is listed explicitly because GuardStatements.swift calls
        // duckdb_extract_statements directly: it needs a raw duckdb_connection, and
        // DuckDBKit.Connection.handle is internal to that module by design (Task 3 must not touch
        // Sources/DuckDBKit/**). MEASURED: this edge is not strictly required today — SwiftPM
        // puts a `.systemLibrary` target's module map on the whole graph's Clang-importer search
        // path, so `import CDuckDB` here compiles even with this line removed, because DuckDBKit
        // already imports it. That is undocumented SwiftPM behavior, not a contract; declared
        // explicitly so this target's build does not depend on it staying true.
        .target(
            name: "SiftEngine",
            dependencies: ["SiftCore", "DuckDBKit", "CDuckDB"]
        ),
        .testTarget(
            name: "SiftEngineTests",
            dependencies: ["SiftEngine", "SiftCore", "DuckDBKit", "TestSupport"]
        ),
        // The headless verification surface, and the reason browser mode could be deleted. Kept
        // deliberately thin — a test target cannot import an `executableTarget`, so everything it
        // does lives in SiftEngine/Verification.swift instead. No linkerSettings, for the same
        // reason SiftEngine has none: DuckDBKit's rpath flags propagate transitively, and
        // repeating them emits `ld: warning: duplicate -rpath`.
        .executableTarget(
            name: "sift",
            dependencies: ["SiftEngine"]
        ),
    ]
)
