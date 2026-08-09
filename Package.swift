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
    ],
    targets: [
        .systemLibrary(name: "CDuckDB", path: "Sources/CDuckDB"),
        .target(
            name: "DuckDBKit",
            dependencies: ["CDuckDB"],
            linkerSettings: duckdbLink
        ),
        .testTarget(
            name: "DuckDBKitTests",
            dependencies: ["DuckDBKit"]
        ),
        // Pure value types only — no dependencies, imports Foundation and nothing else.
        .target(name: "SiftCore"),
        .testTarget(
            name: "SiftCoreTests",
            dependencies: ["SiftCore", "DuckDBKit"],
            resources: [.copy("Fixtures")]
        ),
        // The connection-needing half of core/source.py (and, later in this plan, session.py).
        // No linkerSettings here: DuckDBKit's rpath flags already propagate transitively through
        // this target's dependency on it, and a duplicate `-Xlinker -rpath` emits
        // `ld: warning: duplicate -rpath`.
        .target(
            name: "SiftEngine",
            dependencies: ["SiftCore", "DuckDBKit"]
        ),
        .testTarget(
            name: "SiftEngineTests",
            dependencies: ["SiftEngine", "SiftCore", "DuckDBKit"]
        ),
    ]
)
