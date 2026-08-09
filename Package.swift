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
            dependencies: ["DuckDBKit"],
            linkerSettings: duckdbLink
        ),
    ]
)
