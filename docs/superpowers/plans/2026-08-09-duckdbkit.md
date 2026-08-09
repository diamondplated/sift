# DuckDBKit Implementation Plan (Native Sift, Plan 1 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift wrapper over DuckDB's C API that opens a database, runs parameterized queries, and decodes result chunks into Swift values — with the measured DuckDB 1.5.5 behaviors re-verified against `libduckdb` rather than the Python wheel.

**Architecture:** A SwiftPM `systemLibrary` target (`CDuckDB`) exposes `duckdb.h` through a module map. `DuckDBKit` wraps it in four types — `Database` (owns `duckdb_database`), `Connection` (owns `duckdb_connection`, one per unit of work), `Statement` (prepare + bind), and `Chunk` (columnar decode). The prebuilt universal dylib is fetched by a script and checksum-verified; nothing is compiled from source.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, DuckDB 1.5.5 C API (prebuilt `libduckdb-osx-universal`).

**Spec:** `docs/superpowers/specs/2026-08-09-native-sift-design.md` §5, §6, §12.

**Plan sequence:** 1 DuckDBKit (this) → 2 SiftCore → 3 SiftEngine + CLI verifier → 4 Grid + panels → 5 Bundle and delete.

## Global Constraints

- Swift tools version **6.0**. Platform floor **macOS 14**.
- DuckDB pinned to **1.5.5**. Release asset `libduckdb-osx-universal.zip`, SHA-256 `7b5b8915cc382d0708636fe6385c0cdad5a61c9ff8ba2638b3e2141640783155`.
- **Zero third-party package dependencies.** Foundation and the system toolchain only.
- `Vendor/` and the copied `duckdb.h` are gitignored — never commit the dylib or header.
- `duckdb_fetch_chunk` takes `duckdb_result` **by value**, not by pointer.
- The dylib's install name is `@rpath/libduckdb.dylib`, so an rpath is mandatory for both `swift test` and the bundled app.
- Work happens in the `sift-native` worktree on branch `native`. Never `git reset` this branch — a concurrent session shares the underlying repo.
- Commit as `diamondplated <580248+diamondplated@users.noreply.github.com>`. The repo is configured for this already; do not override it.
- **Any script committed here needs `git add --chmod=+x`.** This repo has `core.fileMode=false` (its `.git` lives on an SMB share), so a plain `chmod +x` + `git add` records mode `100644` and a fresh clone gets a non-executable file — CI then dies on `./scripts/...` with "Permission denied". Verify with `git ls-files -s <path>` showing `100755`. Never "fix" this by changing `core.fileMode`.
- Existing files at the repo root (`engine/`, `web/`, `shell/`, `build-app.sh`, `dev.sh`) stay untouched in this plan. They are deleted in Plan 5.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Package manifest; targets, macOS floor, link and rpath flags |
| `.gitignore` | Add `Vendor/`, `Sources/CDuckDB/duckdb.h`, `.build/` |
| `scripts/fetch-duckdb.sh` | Download, checksum-verify and unpack the pinned libduckdb |
| `Sources/CDuckDB/module.modulemap` | Module map exposing `duckdb.h` and linking `duckdb` |
| `Sources/DuckDBKit/DuckDBError.swift` | Error type carrying DuckDB's message |
| `Sources/DuckDBKit/Database.swift` | Opens the database file, applies hardening, loads extensions |
| `Sources/DuckDBKit/Connection.swift` | One connection; `query`, `execute`, `interrupt` |
| `Sources/DuckDBKit/DBValue.swift` | Bind-parameter enum |
| `Sources/DuckDBKit/Statement.swift` | Prepare, bind, execute |
| `Sources/DuckDBKit/ResultSet.swift` | Owns the `duckdb_result` handle and its column metadata |
| `Sources/DuckDBKit/Cell.swift` | Decoded value enum |
| `Sources/DuckDBKit/ColumnMeta.swift` | Column name, DuckDB type id, decimal scale and width |
| `Sources/DuckDBKit/Chunk.swift` | Chunk → `[[Cell]]` decode, validity-mask aware; extends `ResultSet` with row reading |
| `Tests/DuckDBKitTests/SmokeTests.swift` | Open, query, decode a literal |
| `Tests/DuckDBKitTests/BindingTests.swift` | Bound values round-trip (Task 5 — needs the decoder to read them back) |
| `Tests/DuckDBKitTests/DecodeTests.swift` | Every decodable type, NULL handling, boundaries |
| `Tests/DuckDBKitTests/DuckDB155FactsTests.swift` | Seven of the nine measured behaviors, re-pinned (two need Plan 2 fixtures) |
| `.github/workflows/ci-native.yml` | Build + test on macos-15 |

`Chunk.swift` is the only file with pointer arithmetic. Keeping it alone in one file is deliberate — it is the file most likely to be wrong and the one a reviewer must read closely. `ResultSet` is kept separate from it so that file owns exactly one thing: the result handle's lifetime and the schema.

**Task order is dependency order, and it is load-bearing.** `ColumnMeta` (Task 3) must exist before `ResultSet` (Task 4), which must exist before `Connection.query` can return it, which must exist before the decoder (Task 5) can read rows out of it. Every task leaves `swift build && swift test` green.

---

### Task 1: Package skeleton that links libduckdb

**Files:**
- Create: `scripts/fetch-duckdb.sh`
- Create: `Sources/CDuckDB/module.modulemap`
- Create: `Package.swift`
- Create: `Sources/DuckDBKit/DuckDBError.swift`
- Modify: `.gitignore`
- Test: `Tests/DuckDBKitTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable package whose test binary genuinely links `libduckdb` (proven by a version-pin test, not by a green build); `DuckDBError(message: String)`.

- [ ] **Step 1: Write the fetch script**

Create `scripts/fetch-duckdb.sh`:

```bash
#!/usr/bin/env bash
# Fetches the prebuilt DuckDB library. Nothing is compiled from source: the C++
# amalgamation is 400 files and this keeps the exact version pin the engine's
# measured behaviors depend on.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.5.5"
SHA256="7b5b8915cc382d0708636fe6385c0cdad5a61c9ff8ba2638b3e2141640783155"
URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/libduckdb-osx-universal.zip"

if [ -f Vendor/duckdb/libduckdb.dylib ] && [ -f Sources/CDuckDB/duckdb.h ]; then
  echo "libduckdb ${VERSION} already present; delete Vendor/ to refetch."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading libduckdb ${VERSION}…"
curl -fsSL -o "$tmp/libduckdb.zip" "$URL"

echo "Verifying checksum…"
actual="$(shasum -a 256 "$tmp/libduckdb.zip" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
  echo "CHECKSUM MISMATCH" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi

unzip -oq "$tmp/libduckdb.zip" -d "$tmp/out"
mkdir -p Vendor/duckdb Sources/CDuckDB
cp "$tmp/out/libduckdb.dylib" Vendor/duckdb/
# The header lives beside the module map so the module map needs no -I flag.
cp "$tmp/out/duckdb.h" Sources/CDuckDB/

echo "libduckdb ${VERSION} ready."
```

Then `chmod +x scripts/fetch-duckdb.sh && ./scripts/fetch-duckdb.sh`.

Expected output ends with `libduckdb 1.5.5 ready.`

- [ ] **Step 2: Write the module map**

Create `Sources/CDuckDB/module.modulemap`:

```
module CDuckDB {
    header "duckdb.h"
    link "duckdb"
    export *
}
```

- [ ] **Step 3: Write the package manifest**

Create `Package.swift`:

```swift
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
            dependencies: ["DuckDBKit"]
            // Deliberately no linkerSettings: target linker settings propagate
            // transitively from DuckDBKit, and a second copy makes every `swift test`
            // emit `ld: warning: duplicate -rpath ... ignored`.
        ),
    ]
)
```

- [ ] **Step 4: Update .gitignore**

Append to `.gitignore`:

```
# Native rewrite
.build/
Vendor/
Sources/CDuckDB/duckdb.h
```

- [ ] **Step 5: Write the error type**

Create `Sources/DuckDBKit/DuckDBError.swift`:

```swift
import Foundation

/// A DuckDB failure, carrying the engine's own message.
///
/// Sift shows the first line to the user, because that is the part a human can act
/// on — the rest is a parser dump. `firstLine` reproduces engine/session.py's
/// `_clean_duckdb_error`, including its 400-character cap.
public struct DuckDBError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message.isEmpty ? "Query failed." : message
    }

    public var description: String { message }

    public var firstLine: String {
        let first = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? "Query failed." : String(first.prefix(400))
    }
}
```

- [ ] **Step 6: Write the failing smoke test**

Create `Tests/DuckDBKitTests/SmokeTests.swift`:

```swift
import CDuckDB
import Testing
@testable import DuckDBKit

/// This test is why the module map's `link "duckdb"` directive actually fires.
/// Autolink only activates when some compilation unit imports the module — without
/// an `import CDuckDB` anywhere, `-lduckdb` reaches no link line and the whole suite
/// passes just as happily with the dylib deleted. It earns its place twice: it forces
/// the link, and it pins that the library loaded is the 1.5.5 we checksummed rather
/// than some other copy the linker found first.
@Test func linkedLibraryIsThePinnedDuckDBVersion() {
    #expect(String(cString: duckdb_library_version()) == "v1.5.5")
}

@Test func errorKeepsOnlyTheFirstLine() {
    let e = DuckDBError("Binder Error: no such column\nLINE 1: SELECT nope\n        ^")
    #expect(e.firstLine == "Binder Error: no such column")
}

@Test func emptyErrorGetsAFallbackMessage() {
    #expect(DuckDBError("").firstLine == "Query failed.")
}

@Test func longErrorIsCappedAt400Characters() {
    let e = DuckDBError(String(repeating: "x", count: 900))
    #expect(e.firstLine.count == 400)
}
```

- [ ] **Step 7: Build and test**

Run: `swift build && swift test --filter DuckDBKitTests`
Expected: 4 tests pass, with no linker warnings in the output.

`swift build` alone proves nothing about linking — `DuckDBKit` compiles to a module
without invoking a linker. The link is proven by `linkedLibraryIsThePinnedDuckDBVersion`
in the test binary. Confirm it is a real proof rather than a tautology: move
`Vendor/duckdb/libduckdb.dylib` aside, re-run `swift test`, and check it fails with
`library 'duckdb' not found` / `Undefined symbols: _duckdb_library_version`. Put the
dylib back — the remaining five tasks need it.

If the build fails with `library 'duckdb' not found`, `scripts/fetch-duckdb.sh` has not been run.

- [ ] **Step 8: Commit**

```bash
git add Package.swift .gitignore scripts/fetch-duckdb.sh Sources/CDuckDB/module.modulemap Sources/DuckDBKit/DuckDBError.swift Tests/DuckDBKitTests/SmokeTests.swift
git commit -m "Add SwiftPM skeleton linking the prebuilt libduckdb"
```

---

### Task 2: Database and Connection

**Files:**
- Create: `Sources/DuckDBKit/Database.swift`
- Create: `Sources/DuckDBKit/Connection.swift`
- Test: `Tests/DuckDBKitTests/SmokeTests.swift` (append)

**Interfaces:**
- Consumes: `DuckDBError`.
- Produces:
  - `final class Database: @unchecked Sendable` with `init(path: String) throws`, `static func inMemory() throws -> Database`, `func connect() throws -> Connection`, `var loadedExtensions: [String: Bool]`, `func harden()`, `func loadExtensions(_ names: [String])`.
  - `final class Connection` (**not** Sendable) with `func execute(_ sql: String) throws`, `func query(_ sql: String) throws -> ResultSet`, `func interrupt()`.
  - `final class ResultSet` with `var columns: [ColumnMeta]` (added in Task 5) and `func nextChunk() -> Chunk?` (added in Task 5). For this task `ResultSet` exposes only `rowCountHint` and holds the `duckdb_result`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/DuckDBKitTests/SmokeTests.swift`:

```swift
@Test func opensAnInMemoryDatabaseAndConnects() throws {
    let db = try Database.inMemory()
    let con = try db.connect()
    try con.execute("CREATE TABLE t (a INTEGER)")
    try con.execute("INSERT INTO t VALUES (1), (2)")
}

@Test func aBadStatementThrowsWithDuckDBsMessage() throws {
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        try con.execute("SELECT * FROM no_such_table")
    }
}

@Test func hardeningRefusesNetworkReadsAndKeepsLocalOnesWorking() throws {
    let db = try Database.inMemory()
    db.harden()
    // Connection opened after harden(): the settings are GLOBAL scope, so they outlive
    // the throwaway connection harden() uses. Measured against libduckdb 1.5.5.
    let con = try db.connect()

    // Local file reads must keep working — the entire product is local file reading.
    // enable_external_access=false would have blocked read_csv itself, which is exactly
    // why harden() deliberately does not set it. `SELECT 1` would NOT test this: it
    // touches no filesystem at all.
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-harden-\(UUID().uuidString).csv")
    try "a,b\n1,2\n".write(to: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: path) }
    try con.execute("SELECT * FROM read_csv('\(path.path)', header=true)")

    // A network read must be refused, and we assert WHICH mechanism refuses it.
    // MEASURED: what actually blocks this path is the extension guard
    // (autoload_known_extensions=false) — httpfs never loads, so disabled_filesystems
    // is never consulted. It is a second layer that only engages once something has
    // loaded httpfs. Asserting only `throws: DuckDBError.self` is worthless here: with
    // harden() deleted entirely the URL simply 404s, which is also a DuckDBError.
    var message = ""
    do {
        try con.execute("SELECT * FROM read_csv_auto('https://example.com/x.csv')")
        Issue.record("a network read succeeded despite hardening")
    } catch let error as DuckDBError {
        message = error.message
    }
    #expect(message.contains("httpfs") || message.contains("HTTPFileSystem"),
            "expected hardening to refuse the read; got: \(message)")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter opensAnInMemoryDatabase`
Expected: FAIL — `cannot find 'Database' in scope`.

- [ ] **Step 3: Write Database**

Create `Sources/DuckDBKit/Database.swift`:

```swift
import CDuckDB
import Foundation

/// Owns the one `duckdb_database`. Creating connections from it is thread-safe,
/// which is why this is `@unchecked Sendable` while `Connection` is not.
public final class Database: @unchecked Sendable {
    private var handle: duckdb_database?
    public private(set) var loadedExtensions: [String: Bool] = [:]

    public init(path: String) throws {
        var db: duckdb_database?
        var errPtr: UnsafeMutablePointer<CChar>?
        // Tested against DuckDBSuccess, never against the failure enum: that member
        // imports into Swift as `DuckDBError`, which collides with our own error type.
        let state = duckdb_open_ext(path, &db, nil, &errPtr)
        if state != DuckDBSuccess {
            let msg = errPtr.map { String(cString: $0) } ?? "could not open \(path)"
            if let errPtr { duckdb_free(errPtr) }
            throw DuckDBError(msg)
        }
        self.handle = db
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        if handle != nil { duckdb_close(&handle) }
    }

    public func connect() throws -> Connection {
        var con: duckdb_connection?
        guard duckdb_connect(handle, &con) == DuckDBSuccess, let con else {
            throw DuckDBError("could not open a DuckDB connection")
        }
        return Connection(handle: con)
    }

    /// Settings applied before any query runs. Blocking the network filesystems is
    /// the part that matters: a SELECT can still read any local file the user could
    /// `cat`, but it cannot ship results anywhere. Failures are logged, never fatal —
    /// Sift must not refuse to start over a hardening setting.
    public func harden() {
        guard let con = try? connect() else { return }
        for stmt in [
            "SET disabled_filesystems='HTTPFileSystem,S3FileSystem'",
            "SET autoinstall_known_extensions=false",
            "SET autoload_known_extensions=false",
            "SET allow_community_extensions=false",
        ] {
            try? con.execute(stmt)
        }
    }

    /// LOAD what we need, since autoloading is disabled by `harden()`. Extension
    /// binaries are per-DuckDB-version, so a version bump needs a fresh INSTALL.
    public func loadExtensions(_ names: [String]) {
        guard let con = try? connect() else { return }
        for name in names {
            if (try? con.execute("LOAD \(name)")) != nil {
                loadedExtensions[name] = true
                continue
            }
            do {
                try con.execute("INSTALL \(name)")
                try con.execute("LOAD \(name)")
                loadedExtensions[name] = true
            } catch {
                loadedExtensions[name] = false
            }
        }
    }
}
```

Every state check in this package compares against `DuckDBSuccess`, never against the
failure member. That member imports into Swift under a name that collides with our own
`DuckDBError` type, and comparing against success sidesteps the collision entirely.

- [ ] **Step 4: Write Connection**

Create `Sources/DuckDBKit/Connection.swift`:

```swift
import CDuckDB
import Foundation

/// One DuckDB connection. Connections share the catalog and buffer manager but own
/// their transaction, and are NOT safe to use from more than one task — which is why
/// this is deliberately not Sendable. Every unit of work makes its own.
public final class Connection {
    let handle: duckdb_connection

    init(handle: duckdb_connection) {
        self.handle = handle
    }

    deinit {
        var h: duckdb_connection? = handle
        duckdb_disconnect(&h)
    }

    /// Run a statement, discarding any result.
    public func execute(_ sql: String) throws {
        var result = duckdb_result()
        let state = duckdb_query(handle, sql, &result)
        defer { duckdb_destroy_result(&result) }
        if state != DuckDBSuccess {
            throw DuckDBError(duckdb_result_error(&result).map(String.init(cString:)) ?? "")
        }
    }

    /// Cancel whatever this connection is running. Wraps the mechanism
    /// engine/session.py's `cancel` relies on.
    public func interrupt() {
        duckdb_interrupt(handle)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter DuckDBKitTests`
Expected: PASS — 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/DuckDBKit/Database.swift Sources/DuckDBKit/Connection.swift Tests/DuckDBKitTests/SmokeTests.swift
git commit -m "Add Database and Connection over the DuckDB C API"
```

---

### Task 3: Cell and ColumnMeta

**Files:**
- Create: `Sources/DuckDBKit/Cell.swift`
- Create: `Sources/DuckDBKit/ColumnMeta.swift`

**Interfaces:**
- Consumes: nothing (pure value types — this is why the task comes first).
- Produces:
  - `enum Cell: Sendable, Equatable { case null, bool(Bool), int(Int64), double(Double), text(String), decimal(Decimal, scale: Int), blob(Int) }` with `var isNull: Bool` and `var display: String`.

    DECIMAL carries its **declared scale** in the payload. `Decimal` canonicalizes
    trailing zeros on `description`, so without the scale riding along, a
    `DECIMAL(10,2)` money column renders `10.5` instead of `10.50` — losing exactly the
    declared precision the Python engine preserves via `str(Decimal)`.
  - `struct ColumnMeta: Sendable { let name: String; let typeID: duckdb_type; let decimalScale: UInt8; let decimalWidth: UInt8; let typeName: String }`

  `Cell.text` carries VARCHAR, HUGEINT/UHUGEINT (128-bit, no Swift native on this
  toolchain), UUID, and temporal values as ISO-8601 — matching what the Python engine's
  `jsonable` produces today. `Cell.blob` carries only a byte count, because the grid
  renders `<blob N B>` and never the bytes.

- [ ] **Step 1: Write Cell**

Create `Sources/DuckDBKit/Cell.swift`:

```swift
import Foundation

/// One decoded value.
///
/// Deliberately NOT a JSON-shaped type. The Python engine converts every value to
/// something JavaScript can hold — which is why BIGINT and DECIMAL cross the wire as
/// strings there, since JS Number silently rounds past 2^53 and an order id is exactly
/// the sort of thing that corrupts. In-process that whole problem is gone: Int64 is
/// Int64 and Decimal is Decimal.
///
/// HUGEINT still becomes text, because it is 128-bit and Swift has no native Int128 on
/// the pinned toolchain. Temporal values become ISO-8601 text, matching
/// session.jsonable's `.isoformat()`.
public enum Cell: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
    /// The scale travels with the value because `Decimal` does not: `Decimal(string:
    /// "10.50")` normalizes to 10.5, so DECIMAL(10,2)'s trailing zero is gone the
    /// instant you ask the value for its own description. Carrying `scale` alongside
    /// lets `display` reconstruct the declared shape instead of a canonicalized one.
    case decimal(Decimal, scale: Int)
    case blob(Int)

    public var isNull: Bool { self == .null }

    /// Display form. `blob` reproduces session.jsonable's `<blob N B>` exactly,
    /// thousands separator included.
    public var display: String {
        switch self {
        case .null:            return ""
        case .bool(let v):     return v ? "true" : "false"
        case .int(let v):      return String(v)
        case .double(let v):   return String(v)
        case .text(let v):     return v
        case .decimal(let v, let scale): return Self.decimalDisplay(v, scale: scale)
        case .blob(let n):
            return "<blob \(Self.grouped(n)) B>"
        }
    }

    /// Re-pads to `scale` digits after the point. `v * 10^scale` is an integer-valued
    /// Decimal (its own description has no decimal point), so splicing it back in by
    /// hand — same trick `Chunk.decodeDecimal` uses on the way in — recovers exactly
    /// the digit count DECIMAL declared, trailing zeros included.
    static func decimalDisplay(_ v: Decimal, scale: Int) -> String {
        guard scale > 0 else { return "\(v)" }
        let scaled = v * pow(Decimal(10), scale)
        let negative = scaled < 0
        var digits = "\(negative ? -scaled : scaled)"
        while digits.count <= scale { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -scale)
        return "\(negative ? "-" : "")\(digits[..<cut]).\(digits[cut...])"
    }

    /// Comma-grouped, unconditionally — matching the Python engine's `f"{n:,}"`, which
    /// is what the grid currently renders.
    ///
    /// Deliberately NOT NumberFormatter. Without an explicit `.locale` it follows
    /// `Locale.current`, and the same value renders four different ways — MEASURED:
    /// en_US "1,234", de_DE "1.234", fr_FR "1 234", en_US_POSIX "1234". A blob size
    /// that changes shape with the user's region is a bug, and one that passes CI only
    /// because the runner happens to be en_US is a worse one.
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }
}
```

- [ ] **Step 2: Write ColumnMeta**

Create `Sources/DuckDBKit/ColumnMeta.swift`:

```swift
import CDuckDB
import Foundation

/// What the decoder needs to know about one result column.
public struct ColumnMeta: Sendable {
    public let name: String
    public let typeID: duckdb_type
    /// DECIMAL only. Digits after the point. DECIMAL keeps its scale in the logical
    /// type, not the value — decoding through Double would lose exactly the precision
    /// this tool exists to preserve.
    public let decimalScale: UInt8
    /// DECIMAL only. Total digits — this picks the backing integer:
    /// <=4 SMALLINT, <=9 INTEGER, <=18 BIGINT, else HUGEINT. Reading a
    /// DECIMAL(4,2) as BIGINT does not fail, it silently returns a wrong number.
    public let decimalWidth: UInt8
    public let typeName: String

    public init(name: String, typeID: duckdb_type, decimalScale: UInt8,
                decimalWidth: UInt8, typeName: String) {
        self.name = name
        self.typeID = typeID
        self.decimalScale = decimalScale
        self.decimalWidth = decimalWidth
        self.typeName = typeName
    }
}
```

- [ ] **Step 3: Write the failing test**

Append to `Tests/DuckDBKitTests/SmokeTests.swift`:

```swift
@Test func blobDisplayMatchesThePythonEngineFormat() {
    // The grid renders this string, so the format is a contract, not a detail — and it
    // must not vary with the machine's region. See Cell.grouped for the measurements.
    #expect(Cell.blob(0).display == "<blob 0 B>")
    #expect(Cell.blob(3).display == "<blob 3 B>")
    #expect(Cell.blob(999).display == "<blob 999 B>")
    #expect(Cell.blob(1000).display == "<blob 1,000 B>")
    #expect(Cell.blob(1234).display == "<blob 1,234 B>")
    #expect(Cell.blob(999999).display == "<blob 999,999 B>")
    #expect(Cell.blob(1000000).display == "<blob 1,000,000 B>")
    #expect(Cell.blob(1234567890).display == "<blob 1,234,567,890 B>")
}

@Test func nullDisplaysAsEmptyAndKnowsItIsNull() {
    #expect(Cell.null.isNull)
    #expect(Cell.null.display == "")
    #expect(!Cell.int(0).isNull)
}
```

- [ ] **Step 4: Run tests**

Run: `swift build && swift test`
Expected: PASS — 9 tests (7 from Tasks 1-2, 2 new). No warnings.

`Cell.grouped` deliberately does not use `NumberFormatter`. Without an explicit
`.locale` it follows `Locale.current`, so the same byte count renders four different
ways — MEASURED: en_US `1,234`, de_DE `1.234`, fr_FR `1 234`, en_US_POSIX `1234`. That
is a production bug, not a test detail: `display` is what the grid renders, and it must
match the Python engine's unconditional-comma `f"{n:,}"`. Hand-rolled grouping is
deterministic by construction and needs no locale pinning.

- [ ] **Step 5: Commit**

```bash
git add Sources/DuckDBKit/Cell.swift Sources/DuckDBKit/ColumnMeta.swift Tests/DuckDBKitTests/SmokeTests.swift
git commit -m "Add Cell and ColumnMeta value types"
```

---

### Task 4: Binding, prepared statements, and ResultSet

**Files:**
- Create: `Sources/DuckDBKit/DBValue.swift`
- Create: `Sources/DuckDBKit/ResultSet.swift`
- Create: `Sources/DuckDBKit/Statement.swift`
- Test: `Tests/DuckDBKitTests/SmokeTests.swift` (append)

**Interfaces:**
- Consumes: `Connection`, `DuckDBError`, `ColumnMeta`.
- Produces:
  - `enum DBValue: Sendable, Equatable { case null, bool(Bool), int(Int64), double(Double), text(String) }`
  - `final class ResultSet` owning a `duckdb_result`, exposing `var columns: [ColumnMeta]`. Row reading (`nextChunk`, `allRows`) is added by Task 5 as an extension.
  - `Connection.query(_ sql: String, _ params: [DBValue] = []) throws -> ResultSet`

  `DBValue`'s five cases are exactly what the Python `core/sqlgen.py` produces as bound
  parameters: filter values, limits and offsets. Nothing else is ever bound —
  identifiers are quoted, never parameterized.

  `ResultSet` lands here rather than with the decoder because `Connection.query` returns
  it; defining it later would leave this task uncompilable.

- [ ] **Step 1: Write DBValue**

Create `Sources/DuckDBKit/DBValue.swift`:

```swift
import Foundation

/// A bound query parameter.
///
/// The invariant this exists to serve, inherited from core/sqlgen.py: identifiers are
/// quoted, values are always bound. Nothing in Sift interpolates a user value into SQL
/// text, so this covers every value that ever reaches DuckDB.
public enum DBValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
}
```

- [ ] **Step 2: Write ResultSet**

Create `Sources/DuckDBKit/ResultSet.swift`:

```swift
import CDuckDB
import Foundation

/// A query result: owns the `duckdb_result` and its column metadata.
///
/// Row reading lives in Chunk.swift as an extension, so this file stays responsible
/// for exactly one thing — the handle's lifetime and the schema.
public final class ResultSet {
    var result: duckdb_result
    public let columns: [ColumnMeta]

    init(result: duckdb_result) {
        var r = result
        var metas: [ColumnMeta] = []
        let count = Int(duckdb_column_count(&r))
        metas.reserveCapacity(count)
        for i in 0..<count {
            let idx = idx_t(i)
            let name = duckdb_column_name(&r, idx).map(String.init(cString:)) ?? ""
            var logical = duckdb_column_logical_type(&r, idx)
            let typeID = duckdb_get_type_id(logical)
            let isDecimal = typeID == DUCKDB_TYPE_DECIMAL
            let scale = isDecimal ? duckdb_decimal_scale(logical) : 0
            let width = isDecimal ? duckdb_decimal_width(logical) : 0
            duckdb_destroy_logical_type(&logical)
            metas.append(ColumnMeta(name: name, typeID: typeID, decimalScale: scale,
                                    decimalWidth: width, typeName: Self.typeName(typeID)))
        }
        self.result = result
        self.columns = metas
    }

    deinit {
        duckdb_destroy_result(&result)
    }

    static func typeName(_ t: duckdb_type) -> String {
        switch t {
        case DUCKDB_TYPE_BOOLEAN:      return "BOOLEAN"
        case DUCKDB_TYPE_TINYINT:      return "TINYINT"
        case DUCKDB_TYPE_SMALLINT:     return "SMALLINT"
        case DUCKDB_TYPE_INTEGER:      return "INTEGER"
        case DUCKDB_TYPE_BIGINT:       return "BIGINT"
        case DUCKDB_TYPE_UTINYINT:     return "UTINYINT"
        case DUCKDB_TYPE_USMALLINT:    return "USMALLINT"
        case DUCKDB_TYPE_UINTEGER:     return "UINTEGER"
        case DUCKDB_TYPE_UBIGINT:      return "UBIGINT"
        case DUCKDB_TYPE_HUGEINT:      return "HUGEINT"
        case DUCKDB_TYPE_UHUGEINT:     return "UHUGEINT"
        case DUCKDB_TYPE_FLOAT:        return "FLOAT"
        case DUCKDB_TYPE_DOUBLE:       return "DOUBLE"
        case DUCKDB_TYPE_DECIMAL:      return "DECIMAL"
        case DUCKDB_TYPE_VARCHAR:      return "VARCHAR"
        case DUCKDB_TYPE_BLOB:         return "BLOB"
        case DUCKDB_TYPE_DATE:         return "DATE"
        case DUCKDB_TYPE_TIME:         return "TIME"
        case DUCKDB_TYPE_TIMESTAMP:    return "TIMESTAMP"
        case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMP WITH TIME ZONE"
        case DUCKDB_TYPE_UUID:         return "UUID"
        default:                       return "OTHER"
        }
    }
}
```

- [ ] **Step 3: Write Statement and the query entry point**

Create `Sources/DuckDBKit/Statement.swift`:

```swift
import CDuckDB
import Foundation

extension Connection {
    /// Prepare, bind and execute. The only way to run SQL that carries values.
    public func query(_ sql: String, _ params: [DBValue] = []) throws -> ResultSet {
        var stmt: duckdb_prepared_statement?
        let prepared = duckdb_prepare(handle, sql, &stmt)
        defer { duckdb_destroy_prepare(&stmt) }

        if prepared != DuckDBSuccess {
            let msg = duckdb_prepare_error(stmt).map(String.init(cString:)) ?? ""
            throw DuckDBError(msg)
        }

        // DuckDB parameter indexes are 1-based.
        for (offset, value) in params.enumerated() {
            let idx = idx_t(offset + 1)
            let state: duckdb_state
            switch value {
            case .null:          state = duckdb_bind_null(stmt, idx)
            case .bool(let v):   state = duckdb_bind_boolean(stmt, idx, v)
            case .int(let v):    state = duckdb_bind_int64(stmt, idx, v)
            case .double(let v): state = duckdb_bind_double(stmt, idx, v)
            case .text(let v):   state = duckdb_bind_varchar(stmt, idx, v)
            }
            if state != DuckDBSuccess {
                throw DuckDBError("could not bind parameter \(offset + 1)")
            }
        }

        var result = duckdb_result()
        if duckdb_execute_prepared(stmt, &result) != DuckDBSuccess {
            let msg = duckdb_result_error(&result).map(String.init(cString:)) ?? ""
            duckdb_destroy_result(&result)
            throw DuckDBError(msg)
        }
        return ResultSet(result: result)
    }
}
```

- [ ] **Step 4: Write the failing tests**

Append to `Tests/DuckDBKitTests/SmokeTests.swift`:

```swift
@Test func reportsColumnNamesInOrder() throws {
    let con = try Database.inMemory().connect()
    let rs = try con.query("SELECT 1 AS alpha, 2 AS beta")
    #expect(rs.columns.map(\.name) == ["alpha", "beta"])
}

@Test func reportsDecimalScaleAndWidth() throws {
    let con = try Database.inMemory().connect()
    let rs = try con.query("SELECT 1.23::DECIMAL(9,3) AS d")
    #expect(rs.columns[0].typeName == "DECIMAL")
    #expect(rs.columns[0].decimalScale == 3)
    #expect(rs.columns[0].decimalWidth == 9)
}

@Test func aPrepareFailureThrows() throws {
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        _ = try con.query("SELECT * FROM nope WHERE x = ?", [.int(1)])
    }
}

@Test func bindingAcceptsEveryValueKindWithoutThrowing() throws {
    // Values are read back in Task 5, once chunk decoding exists. This asserts the
    // bind path itself accepts all five cases and executes.
    let con = try Database.inMemory().connect()
    let rs = try con.query(
        "SELECT ?::BOOLEAN AS b, ?::BIGINT AS i, ?::DOUBLE AS d, ?::VARCHAR AS s, ?::VARCHAR AS n",
        [.bool(true), .int(42), .double(1.5), .text("hi"), .null]
    )
    #expect(rs.columns.map(\.name) == ["b", "i", "d", "s", "n"])
}
```

- [ ] **Step 5: Run tests**

Run: `swift build && swift test`
Expected: PASS — 13 tests (9 from Tasks 1-3, 4 new). No warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/DuckDBKit/DBValue.swift Sources/DuckDBKit/ResultSet.swift Sources/DuckDBKit/Statement.swift Tests/DuckDBKitTests/SmokeTests.swift
git commit -m "Add parameter binding, prepared statements and ResultSet"
```

---

### Task 5: Chunk decoding

**Files:**
- Create: `Sources/DuckDBKit/Chunk.swift`
- Test: `Tests/DuckDBKitTests/DecodeTests.swift`
- Test: `Tests/DuckDBKitTests/BindingTests.swift`

**Interfaces:**
- Consumes: `Cell`, `ColumnMeta`, `ResultSet`, `Connection`, `DBValue`.
- Produces:
  - `struct Chunk` with `var rowCount: Int`, `func rows() -> [[Cell]]`, `func destroy()`
  - `extension ResultSet` with `func nextChunk() -> Chunk?` and `func allRows() throws -> [[Cell]]`

  Nested types (`STRUCT`, `LIST`, `MAP`, `UNION`, `JSON`) have **no** native decode path
  and return `.text("")`. SiftEngine is responsible for wrapping nested columns in
  `CAST(col AS VARCHAR)` in its SELECT list, reusing the `_as_text` helper that already
  exists in `core/sqlgen.py`. This is a contract, not an omission.

- [ ] **Step 1: Write the failing decode tests**

Create `Tests/DuckDBKitTests/DecodeTests.swift`:

```swift
import Foundation
import Testing
@testable import DuckDBKit

private func one(_ sql: String) throws -> Cell {
    let con = try Database.inMemory().connect()
    return try con.query(sql).allRows()[0][0]
}

@Test func decodesSignedIntegers() throws {
    #expect(try one("SELECT 127::TINYINT") == .int(127))
    #expect(try one("SELECT 32767::SMALLINT") == .int(32767))
    #expect(try one("SELECT 2147483647::INTEGER") == .int(2147483647))
    #expect(try one("SELECT 9223372036854775807::BIGINT") == .int(9223372036854775807))
}

@Test func decodesUnsignedIntegers() throws {
    #expect(try one("SELECT 255::UTINYINT") == .int(255))
    #expect(try one("SELECT 65535::USMALLINT") == .int(65535))
    #expect(try one("SELECT 4294967295::UINTEGER") == .int(4294967295))
}

@Test func decodesFloatsAndBooleans() throws {
    #expect(try one("SELECT true") == .bool(true))
    #expect(try one("SELECT 1.5::DOUBLE") == .double(1.5))
    #expect(try one("SELECT 1.5::FLOAT") == .double(1.5))
}

@Test func decodesShortAndLongStrings() throws {
    // Under 12 bytes DuckDB inlines the string in the struct; past that it is a
    // pointer. Both paths must work, so test either side of the boundary.
    #expect(try one("SELECT 'short'") == .text("short"))
    let long = String(repeating: "a", count: 200)
    #expect(try one("SELECT '\(long)'") == .text(long))
    #expect(try one("SELECT ''") == .text(""))
}

@Test func decodesNullsInEveryPosition() throws {
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT * FROM (VALUES (1, 'a'), (NULL, NULL), (3, 'c')) AS t(n, s)"
    ).allRows()
    #expect(rows[0] == [.int(1), .text("a")])
    #expect(rows[1] == [.null, .null])
    #expect(rows[2] == [.int(3), .text("c")])
}

@Test func decodesHugeIntAsText() throws {
    // 2^70, far past Int64. This is the corruption class Sift exists to expose,
    // so it must survive exactly.
    #expect(try one("SELECT 1180591620717411303424::HUGEINT") == .text("1180591620717411303424"))
    #expect(try one("SELECT (-1180591620717411303424)::HUGEINT") == .text("-1180591620717411303424"))
    #expect(try one("SELECT 0::HUGEINT") == .text("0"))
    #expect(try one("SELECT 42::HUGEINT") == .text("42"))
    #expect(try one("SELECT (-1)::HUGEINT") == .text("-1"))
}

@Test func decodesDecimalAtEveryStorageWidth() throws {
    // Width picks the backing integer: <=4 SMALLINT, <=9 INTEGER, <=18 BIGINT, else
    // HUGEINT. Reading the wrong width returns a plausible wrong number rather than
    // throwing, so all four have to be covered.
    #expect(try one("SELECT 1.23::DECIMAL(4,2)") == .decimal(Decimal(string: "1.23")!, scale: 2))
    #expect(try one("SELECT 12345.678::DECIMAL(9,3)") == .decimal(Decimal(string: "12345.678")!, scale: 3))
    #expect(try one("SELECT 123456789.012::DECIMAL(18,3)")
            == .decimal(Decimal(string: "123456789.012")!, scale: 3))
    #expect(try one("SELECT 1234567890123456789.01::DECIMAL(38,2)")
            == .decimal(Decimal(string: "1234567890123456789.01")!, scale: 2))
    #expect(try one("SELECT (-0.001)::DECIMAL(9,3)") == .decimal(Decimal(string: "-0.001")!, scale: 3))
}

@Test func decodesBlobAsAByteCount() throws {
    #expect(try one("SELECT 'abc'::BLOB") == .blob(3))
}

@Test func readsEveryRowAcrossMultipleChunks() throws {
    // A DuckDB chunk holds 2048 rows, so 5000 forces the multi-chunk path.
    let con = try Database.inMemory().connect()
    let rows = try con.query("SELECT i FROM range(5000) AS t(i)").allRows()
    #expect(rows.count == 5000)
    #expect(rows[0][0] == .int(0))
    #expect(rows[4999][0] == .int(4999))
}

@Test func decodesTimestampsWithSubSecondPrecision() throws {
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56.123456'")
            == .text("2026-08-09T12:34:56.123456"))
    // Rounds to the WRONG SECOND if the formatter path ever comes back.
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56.999999'")
            == .text("2026-08-09T12:34:56.999999"))
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56'")
            == .text("2026-08-09T12:34:56"))
}

@Test func decodesDatesBeforeTheGregorianCutover() throws {
    // ISO8601DateFormatter shifts these 9-10 days; DuckDB DATE is proleptic Gregorian.
    #expect(try one("SELECT DATE '1500-01-01'") == .text("1500-01-01"))
    #expect(try one("SELECT DATE '1582-10-04'") == .text("1582-10-04"))
    #expect(try one("SELECT DATE '0001-01-01'") == .text("0001-01-01"))
    #expect(try one("SELECT DATE '1969-07-20'") == .text("1969-07-20"))
    #expect(try one("SELECT DATE '9999-12-31'") == .text("9999-12-31"))
}

@Test func decodesEveryTimestampScale() throws {
    #expect(try one("SELECT TIMESTAMP_S '2026-08-09 12:34:56'") == .text("2026-08-09T12:34:56"))
    #expect(try one("SELECT TIMESTAMP_MS '2026-08-09 12:34:56.123'") == .text("2026-08-09T12:34:56.123"))
    // What pandas datetime64[ns] becomes in Parquet — previously decoded to "".
    #expect(try one("SELECT TIMESTAMP_NS '2026-08-09 12:34:56.123456789'")
            == .text("2026-08-09T12:34:56.123456789"))
}

@Test func decodesUuidAndInterval() throws {
    #expect(try one("SELECT UUID '10203040-5060-7080-90a0-b0c0d0e0f000'")
            == .text("10203040-5060-7080-90a0-b0c0d0e0f000"))
    // Shape: DuckDB's own CAST(iv AS VARCHAR) rendering (postgres-style) — each
    // component keeps its own sign, zero components are omitted. MEASURED against
    // libduckdb via CLI: months=1, days=-3, micros=7200000000 renders exactly this.
    #expect(try one("SELECT INTERVAL '1 month -3 days 02:00:00'")
            == .text("1 month -3 days 02:00:00"))
    #expect(try one("SELECT INTERVAL '0 days'") == .text("00:00:00"))
    #expect(try one("SELECT INTERVAL '13 months'") == .text("1 year 1 month"))
}

@Test func decimalKeepsItsDeclaredScale() throws {
    // The Python engine returns str(Decimal), which preserves trailing zeros. A money
    // column must not change shape on screen.
    let c = try one("SELECT 10.50::DECIMAL(10,2)")
    #expect(c.display == "10.50")
}

@Test func timeKeepsSubSecondPrecision() throws {
    #expect(try one("SELECT TIME '12:34:56.123456'") == .text("12:34:56.123456"))
    #expect(try one("SELECT TIME '12:34:56'") == .text("12:34:56"))
}

@Test func distinguishesZonedTimestampsFromNaiveOnes() throws {
    // The bug this pins: a naive TIMESTAMP used to get a spurious Z, making it
    // indistinguishable from a genuinely zoned value. Python renders naive bare and
    // aware with an offset; so do we.
    #expect(try one("SELECT TIMESTAMP '2026-08-09 12:34:56'") == .text("2026-08-09T12:34:56"))
    #expect(try one("SELECT TIMESTAMPTZ '2026-08-09 12:34:56+00'")
            == .text("2026-08-09T12:34:56+00:00"))
}

@Test func decodesTimeWithTimezone() throws {
    #expect(try one("SELECT TIMETZ '12:34:56+02:00'") == .text("12:34:56+02:00"))
    #expect(try one("SELECT TIMETZ '12:34:56-05:30'") == .text("12:34:56-05:30"))
}
```

Also create `Tests/DuckDBKitTests/BindingTests.swift`, which finally reads back what
Task 4 could only bind:

```swift
import Testing
@testable import DuckDBKit

@Test func boundValuesRoundTrip() throws {
    let con = try Database.inMemory().connect()
    let rows = try con.query(
        "SELECT ?::BOOLEAN AS b, ?::BIGINT AS i, ?::DOUBLE AS d, ?::VARCHAR AS s, ?::VARCHAR AS n",
        [.bool(true), .int(42), .double(1.5), .text("hi"), .null]
    ).allRows()
    #expect(rows.count == 1)
    #expect(rows[0] == [.bool(true), .int(42), .double(1.5), .text("hi"), .null])
}

@Test func bindsAStringContainingAQuote() throws {
    // The invariant this protects: values are bound, never interpolated. If this ever
    // goes through string concatenation instead, this is the test that catches it.
    let con = try Database.inMemory().connect()
    let rows = try con.query("SELECT ?::VARCHAR AS s", [.text("O'Brien")]).allRows()
    #expect(rows[0] == [.text("O'Brien")])
}

@Test func anExecuteTimeFailureThrowsAndCleansUp() throws {
    // Distinct from a prepare-time failure: this SQL parses and binds fine, then fails
    // during execution, which is the only path that reaches the result-error branch in
    // Connection.query. Every other test in this package fails at prepare instead.
    let con = try Database.inMemory().connect()
    #expect(throws: DuckDBError.self) {
        _ = try con.query("SELECT CAST('abc' AS INTEGER)").allRows()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DecodeTests`
Expected: FAIL — `value of type 'ResultSet' has no member 'allRows'`.

- [ ] **Step 3: Write Chunk**

Create `Sources/DuckDBKit/Chunk.swift`:

```swift
import CDuckDB
import Foundation

extension ResultSet {
    /// The next chunk, or nil when the result is exhausted.
    ///
    /// `duckdb_fetch_chunk` takes the result BY VALUE, not by pointer — passing a
    /// pointer compiles and then misbehaves, so the copy here is deliberate.
    public func nextChunk() -> Chunk? {
        guard let raw = duckdb_fetch_chunk(result) else { return nil }
        let size = Int(duckdb_data_chunk_get_size(raw))
        if size == 0 {
            var c: duckdb_data_chunk? = raw
            duckdb_destroy_data_chunk(&c)
            return nil
        }
        return Chunk(handle: raw, rowCount: size, columns: columns)
    }

    /// Every row. Only for bounded results — Sift pages the grid instead.
    public func allRows() throws -> [[Cell]] {
        var out: [[Cell]] = []
        while let chunk = nextChunk() {
            out.append(contentsOf: chunk.rows())
            chunk.destroy()
        }
        return out
    }
}

/// One columnar batch. Decoding reads each vector's data pointer and validity mask
/// directly — no per-value allocation on the way in, which is the whole reason this
/// path is faster than the JSON one it replaces.
public struct Chunk {
    let handle: duckdb_data_chunk
    public let rowCount: Int
    let columns: [ColumnMeta]

    public func destroy() {
        var c: duckdb_data_chunk? = handle
        duckdb_destroy_data_chunk(&c)
    }

    public func rows() -> [[Cell]] {
        var byColumn: [[Cell]] = []
        byColumn.reserveCapacity(columns.count)
        for (i, meta) in columns.enumerated() {
            byColumn.append(decodeColumn(i, meta))
        }
        var out = [[Cell]](repeating: [], count: rowCount)
        for r in 0..<rowCount {
            out[r] = byColumn.map { $0[r] }
        }
        return out
    }

    private func decodeColumn(_ index: Int, _ meta: ColumnMeta) -> [Cell] {
        let vector = duckdb_data_chunk_get_vector(handle, idx_t(index))
        let validity = duckdb_vector_get_validity(vector)
        guard let data = duckdb_vector_get_data(vector) else {
            // A nil data pointer means the value lives elsewhere (STRUCT/ARRAY/UNION
            // keep theirs in child vectors), NOT that the rows are NULL. Reporting
            // NULL here would invent missing data.
            //
            // meta.typeID.rawValue, not meta.typeName: ResultSet.typeName collapses
            // every type it doesn't special-case — including STRUCT, ARRAY and UNION,
            // the exact types that reach this branch — down to the single string
            // "OTHER", which names nothing.
            return [Cell](repeating: .text("⟨unreadable type \(meta.typeID.rawValue)⟩"), count: rowCount)
        }

        var out = [Cell](repeating: .null, count: rowCount)
        for r in 0..<rowCount {
            if let validity, !duckdb_validity_row_is_valid(validity, idx_t(r)) {
                continue   // already .null
            }
            out[r] = decodeOne(data: data, row: r, meta: meta)
        }
        return out
    }

    private func decodeOne(data: UnsafeMutableRawPointer, row r: Int, meta: ColumnMeta) -> Cell {
        switch meta.typeID {
        case DUCKDB_TYPE_BOOLEAN:
            return .bool(data.assumingMemoryBound(to: Bool.self)[r])
        case DUCKDB_TYPE_TINYINT:
            return .int(Int64(data.assumingMemoryBound(to: Int8.self)[r]))
        case DUCKDB_TYPE_SMALLINT:
            return .int(Int64(data.assumingMemoryBound(to: Int16.self)[r]))
        case DUCKDB_TYPE_INTEGER:
            return .int(Int64(data.assumingMemoryBound(to: Int32.self)[r]))
        case DUCKDB_TYPE_BIGINT:
            return .int(data.assumingMemoryBound(to: Int64.self)[r])
        case DUCKDB_TYPE_UTINYINT:
            return .int(Int64(data.assumingMemoryBound(to: UInt8.self)[r]))
        case DUCKDB_TYPE_USMALLINT:
            return .int(Int64(data.assumingMemoryBound(to: UInt16.self)[r]))
        case DUCKDB_TYPE_UINTEGER:
            return .int(Int64(data.assumingMemoryBound(to: UInt32.self)[r]))
        case DUCKDB_TYPE_UBIGINT:
            let v = data.assumingMemoryBound(to: UInt64.self)[r]
            return v <= UInt64(Int64.max) ? .int(Int64(v)) : .text(String(v))
        case DUCKDB_TYPE_FLOAT:
            return .double(Double(data.assumingMemoryBound(to: Float.self)[r]))
        case DUCKDB_TYPE_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self)[r])
        case DUCKDB_TYPE_HUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            return .text(Self.hugeintString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_UHUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_uhugeint.self)[r]
            return .text(Self.unsignedString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_DECIMAL:
            return decodeDecimal(data: data, row: r, meta: meta)
        case DUCKDB_TYPE_VARCHAR:
            var s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            let len = Int(duckdb_string_t_length(s))
            // The String must be built INSIDE the closure: for inlined strings (<=12
            // bytes) duckdb_string_t_data returns a pointer into `s` itself, which is
            // only valid for the lifetime of withUnsafeMutablePointer's callback.
            // MEASURED as latent (no observed mismatch over 4000 rows) rather than
            // active, but it is undefined behavior regardless of whether it happened
            // to work — the one file where that is least acceptable.
            return withUnsafeMutablePointer(to: &s) { sp -> Cell in
                guard let ptr = duckdb_string_t_data(sp) else { return .text("") }
                return .text(String(decoding: UnsafeRawBufferPointer(start: ptr, count: len),
                                    as: UTF8.self))
            }
        case DUCKDB_TYPE_BLOB:
            let s = data.assumingMemoryBound(to: duckdb_string_t.self)[r]
            return .blob(Int(duckdb_string_t_length(s)))
        case DUCKDB_TYPE_DATE:
            let days = data.assumingMemoryBound(to: duckdb_date.self)[r].days
            return .text(Self.isoDate(daysSinceEpoch: Int(days)))
        case DUCKDB_TYPE_TIME:
            let micros = data.assumingMemoryBound(to: duckdb_time.self)[r].micros
            return .text(Self.isoTime(micros: micros))
        case DUCKDB_TYPE_TIME_TZ:
            let raw = data.assumingMemoryBound(to: duckdb_time_tz.self)[r]
            return .text(Self.isoTimeTz(raw))
        case DUCKDB_TYPE_TIMESTAMP:
            // Naive — no timezone travels with this value, so no offset is appended.
            let micros = data.assumingMemoryBound(to: duckdb_timestamp.self)[r].micros
            return .text(Self.isoTimestamp(micros, perSecond: 1_000_000, fracDigits: 6, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_TZ:
            // DuckDB always stores TIMESTAMP_TZ normalized to UTC, so +00:00 is exact,
            // not a guess.
            let micros = data.assumingMemoryBound(to: duckdb_timestamp.self)[r].micros
            return .text(Self.isoTimestamp(micros, perSecond: 1_000_000, fracDigits: 6, suffix: "+00:00"))
        case DUCKDB_TYPE_TIMESTAMP_S:
            let seconds = data.assumingMemoryBound(to: duckdb_timestamp_s.self)[r].seconds
            return .text(Self.isoTimestamp(seconds, perSecond: 1, fracDigits: 0, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_MS:
            let millis = data.assumingMemoryBound(to: duckdb_timestamp_ms.self)[r].millis
            return .text(Self.isoTimestamp(millis, perSecond: 1_000, fracDigits: 3, suffix: ""))
        case DUCKDB_TYPE_TIMESTAMP_NS:
            // What pandas datetime64[ns] becomes on the way through Parquet.
            let nanos = data.assumingMemoryBound(to: duckdb_timestamp_ns.self)[r].nanos
            return .text(Self.isoTimestamp(nanos, perSecond: 1_000_000_000, fracDigits: 9, suffix: ""))
        case DUCKDB_TYPE_UUID:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            return .text(Self.uuidString(lower: h.lower, upper: h.upper))
        case DUCKDB_TYPE_INTERVAL:
            let iv = data.assumingMemoryBound(to: duckdb_interval.self)[r]
            return .text(Self.intervalString(months: iv.months, days: iv.days, micros: iv.micros))
        default:
            // Never an empty string: that is indistinguishable from real data, and
            // NULL vs '' vs a sentinel staying distinct is the whole point of this
            // tool. Loud and obviously-not-data instead.
            //
            // Deliberately still landing here, pending real decode paths: ENUM, BIT,
            // BIGNUM (the C API's name for VARINT — there is no DUCKDB_TYPE_VARINT in
            // this header). Also nested types (STRUCT/LIST/MAP/UNION) and JSON — but
            // for those, SiftEngine is expected to CAST(col AS VARCHAR) in the SELECT
            // list before the column ever reaches this decoder, so hitting this branch
            // on a nested column means that contract was not honored upstream, not
            // that this fallback is a substitute for it.
            return .text("⟨unsupported type \(meta.typeID.rawValue)⟩")
        }
    }

    // MARK: - 128-bit integers

    /// DuckDB documents the value as `upper * 2^64 + lower`. Swift has no Int128 on the
    /// pinned toolchain, so this does long division by 10 over the two halves.
    static func hugeintString(lower: UInt64, upper: Int64) -> String {
        if upper < 0 {
            // Two's complement negate across both halves, then print with a sign.
            // The carry into `hi` happens exactly when `lower` was 0.
            let lo = ~lower &+ 1
            var hi = ~UInt64(bitPattern: upper)
            if lower == 0 { hi = hi &+ 1 }
            return "-" + unsignedString(lower: lo, upper: hi)
        }
        return unsignedString(lower: lower, upper: UInt64(upper))
    }

    static func unsignedString(lower: UInt64, upper: UInt64) -> String {
        if upper == 0 { return String(lower) }
        var digits: [Character] = []
        var hi = upper
        var lo = lower
        while hi != 0 || lo != 0 {
            // Divide the 128-bit value by 10, carrying the remainder across halves.
            let hiQuot = hi / 10
            let hiRem = hi % 10
            let (loQuot, loRem) = UInt64(10).dividingFullWidth((high: hiRem, low: lo))
            digits.append(Character(String(loRem)))
            hi = hiQuot
            lo = loQuot
        }
        return String(digits.reversed())
    }

    // MARK: - decimal

    private func decodeDecimal(data: UnsafeMutableRawPointer, row r: Int, meta: ColumnMeta) -> Cell {
        let unscaled: String
        switch Self.decimalStorage(meta) {
        case DUCKDB_TYPE_SMALLINT:
            unscaled = String(data.assumingMemoryBound(to: Int16.self)[r])
        case DUCKDB_TYPE_INTEGER:
            unscaled = String(data.assumingMemoryBound(to: Int32.self)[r])
        case DUCKDB_TYPE_HUGEINT:
            let h = data.assumingMemoryBound(to: duckdb_hugeint.self)[r]
            unscaled = Self.hugeintString(lower: h.lower, upper: h.upper)
        default:
            unscaled = String(data.assumingMemoryBound(to: Int64.self)[r])
        }
        let scale = Int(meta.decimalScale)
        guard scale > 0 else {
            // Substituting 0 on a parse failure would be a silent wrong number in the
            // one file where that is unforgivable — loud marker instead.
            guard let v = Decimal(string: unscaled) else {
                return .text("⟨unparseable decimal \(unscaled)⟩")
            }
            return .decimal(v, scale: scale)
        }

        let negative = unscaled.hasPrefix("-")
        var digits = negative ? String(unscaled.dropFirst()) : unscaled
        while digits.count <= scale { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -scale)
        let text = "\(negative ? "-" : "")\(digits[..<cut]).\(digits[cut...])"
        guard let v = Decimal(string: text) else {
            return .text("⟨unparseable decimal \(text)⟩")
        }
        return .decimal(v, scale: scale)
    }

    /// DECIMAL is stored in the smallest integer its width fits into. Guessing BIGINT
    /// for everything does not fail loudly — it silently returns a wrong number, which
    /// is precisely the corruption class this tool exists to expose.
    static func decimalStorage(_ meta: ColumnMeta) -> duckdb_type {
        switch meta.decimalWidth {
        case 0...4:   return DUCKDB_TYPE_SMALLINT
        case 5...9:   return DUCKDB_TYPE_INTEGER
        case 10...18: return DUCKDB_TYPE_BIGINT
        default:      return DUCKDB_TYPE_HUGEINT
        }
    }

    // MARK: - temporal
    //
    // Deliberately NOT Foundation/ISO8601DateFormatter. Two measured failures against
    // libduckdb 1.5.5 ruled it out:
    //   - No fractional-seconds option, and it ROUNDS to the nearest second, so
    //     12:34:56.999999 came back as 12:34:57 — the wrong second, not just missing
    //     precision.
    //   - It applies the 1582 Julian→Gregorian calendar cutover, but DuckDB's DATE is
    //     proleptic Gregorian (extends the modern calendar backwards through 1582).
    //     DATE '1500-01-01' came back 1499-12-23; DATE '0001-01-01' came back
    //     0001-01-03.
    // Integer arithmetic throughout avoids both: no rounding, no calendar cutover.

    /// days-since-1970-01-01 → (year, month, day), proleptic Gregorian.
    /// Howard Hinnant's `civil_from_days` algorithm.
    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097                                  // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365   // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)           // [0, 365]
        let mp = (5 * doy + 2) / 153                                // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                        // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                           // [1, 12]
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    /// `String(format: "%04d", -99)` gives "-099" — the "0" pad character sits between
    /// the sign and the digits, so it pads the whole signed number to 4 characters, not
    /// the magnitude to 4 digits. ISO 8601 expanded form wants "-0099": the minus sign
    /// PLUS 4 digits of magnitude. Formatting the sign and the magnitude separately is
    /// what gets that right for any BC year.
    private static func year4(_ year: Int) -> String {
        year < 0 ? "-" + String(format: "%04d", -year) : String(format: "%04d", year)
    }

    static func isoDate(daysSinceEpoch: Int) -> String {
        let c = civilFromDays(daysSinceEpoch)
        return "\(year4(c.year))-" + String(format: "%02d-%02d", c.month, c.day)
    }

    /// Formats a count of sub-second units since the epoch.
    ///
    /// `perSecond` is the unit scale (1 for seconds, 1_000 for millis, 1_000_000 for
    /// micros, 1_000_000_000 for nanos); `fracDigits` is how many digits that scale
    /// needs. The fraction is emitted only when non-zero, matching Python's
    /// datetime.isoformat(), which omits the fraction entirely for a whole-second
    /// value but never trims within it — isoformat() always prints microseconds at
    /// full 6-digit width once there is a fraction at all, and the DECIMAL fix a few
    /// lines away in Cell.swift exists for the identical reason: dropping a trailing
    /// zero misrepresents the column's declared precision. A decisecond column and a
    /// microsecond column must not render identically just because both happen to end
    /// in zeros.
    ///
    /// Integer division throughout: routing micros through Double and a formatter
    /// dropped sub-second precision AND rounded .999999 up to the next second.
    static func isoTimestamp(_ value: Int64, perSecond: Int64, fracDigits: Int,
                             suffix: String) -> String {
        let perDay = 86_400 * perSecond
        var days = Int(value / perDay)
        var rem = value % perDay
        if rem < 0 { rem += perDay; days -= 1 }   // floor, so pre-epoch values are right
        let c = civilFromDays(days)
        let secOfDay = rem / perSecond
        let frac = rem % perSecond
        var s = "\(year4(c.year))-" + String(format: "%02d-%02dT%02d:%02d:%02d",
                       c.month, c.day,
                       secOfDay / 3600, (secOfDay % 3600) / 60, secOfDay % 60)
        if frac != 0 && fracDigits > 0 {
            var digits = String(frac)
            while digits.count < fracDigits { digits = "0" + digits }
            s += "." + digits
        }
        return s + suffix
    }

    static func isoTime(micros: Int64) -> String {
        let secOfDay = micros / 1_000_000
        let frac = micros % 1_000_000
        var s = String(format: "%02d:%02d:%02d",
                       secOfDay / 3600, (secOfDay % 3600) / 60, secOfDay % 60)
        if frac != 0 {
            var digits = String(frac)
            while digits.count < 6 { digits = "0" + digits }
            s += "." + digits
        }
        return s
    }

    /// TIME_TZ packs micros-since-midnight and a UTC offset (in seconds) into 64 bits;
    /// `duckdb_from_time_tz` is the documented way to unpack them, so no manual
    /// bit-shifting here. MEASURED against libduckdb 1.5.5: `'12:34:56+02:00'::TIMETZ`
    /// decomposes to offset == 7200 (i.e. positive == east of UTC, matching the
    /// literal's own sign), so the offset needs no inversion.
    static func isoTimeTz(_ raw: duckdb_time_tz) -> String {
        let d = duckdb_from_time_tz(raw)
        var s = String(format: "%02d:%02d:%02d", d.time.hour, d.time.min, d.time.sec)
        if d.time.micros != 0 {
            var digits = String(d.time.micros)
            while digits.count < 6 { digits = "0" + digits }
            s += "." + digits
        }
        let mag = abs(Int(d.offset))   // offset is bounded to +/-16h, nowhere near Int32.min
        s += (d.offset < 0 ? "-" : "+") + String(format: "%02d:%02d", mag / 3600, (mag % 3600) / 60)
        return s
    }

    // MARK: - UUID

    /// UUID is transported as a hugeint with the top bit of `upper` flipped, so signed
    /// 128-bit comparison sorts the same way UUID bytes do. MEASURED against libduckdb
    /// 1.5.5: UUID '10203040-5060-7080-90a0-b0c0d0e0f000' arrives with upper bit
    /// pattern 0x9020304050607080 — the literal's own leading byte 0x10 with bit 63
    /// flipped to 0x90. XOR with Int64.min's bit pattern undoes exactly that flip.
    static func uuidString(lower: UInt64, upper: Int64) -> String {
        let hi = UInt64(bitPattern: upper) ^ UInt64(bitPattern: Int64.min)
        let hex = String(format: "%016llx%016llx", hi, lower)
        let a = hex.prefix(8)
        let b = hex.dropFirst(8).prefix(4)
        let c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4)
        let e = hex.dropFirst(20).prefix(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    // MARK: - INTERVAL

    /// Renders months/days/micros the same way DuckDB's own `CAST(iv AS VARCHAR)`
    /// does (MEASURED, e.g. `1 month -3 days 02:00:00`, `-25:00:00`, `00:00:00` for a
    /// zero interval) rather than inventing a shape: each component keeps its own
    /// sign, years/months/days are only shown when non-zero, and the time part is
    /// shown only when non-zero — except when the whole interval is zero, in which
    /// case time is the sole "00:00:00".
    static func intervalString(months: Int32, days: Int32, micros: Int64) -> String {
        var parts: [String] = []
        let years = months / 12
        let remMonths = months % 12
        if years != 0 { parts.append("\(years) year\(years.magnitude == 1 ? "" : "s")") }
        if remMonths != 0 { parts.append("\(remMonths) month\(remMonths.magnitude == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(days.magnitude == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            let negative = micros < 0
            let mag = micros.magnitude
            let totalSeconds = Int(mag / 1_000_000)
            let frac = mag % 1_000_000
            var time = String(format: "%02d:%02d:%02d",
                              totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60)
            if frac != 0 {
                var digits = String(frac)
                while digits.count < 6 { digits = "0" + digits }
                while digits.hasSuffix("0") { digits.removeLast() }
                time += "." + digits
            }
            parts.append((negative ? "-" : "") + time)
        }
        return parts.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: PASS — 33 tests. No warnings.

Do not weaken a failing assertion to get green. Every expectation in `DecodeTests`
encodes a value that must survive exactly; if one fails, the decoder is wrong.

- [ ] **Step 5: Commit**

```bash
git add Sources/DuckDBKit/Chunk.swift Tests/DuckDBKitTests/DecodeTests.swift Tests/DuckDBKitTests/BindingTests.swift
git commit -m "Decode result chunks into Swift values"
```

---

### Task 6: Re-verify the DuckDB 1.5.5 behaviors, and CI

**Files:**
- Create: `Tests/DuckDBKitTests/DuckDB155FactsTests.swift`
- Create: `.github/workflows/ci-native.yml`

**Interfaces:**
- Consumes: `Database`, `Connection`, `Cell`.
- Produces: an executable record that each documented behavior still holds against
  `libduckdb`. Nothing downstream imports this; it is a tripwire.

This is the task the whole plan exists to de-risk. `README.md` and `AGENTS.md` document
nine behaviors measured through the **Python wheel**. They should hold for the same
engine version through the C API, but "should" is not "verified", and every one of them
shapes SiftCore's SQL. Any failure here changes the design before SiftCore is written.

**Seven of the nine are verified here.** The two that need real `.xlsx` and Delta
fixtures (`read_xlsx`'s `sheet =>` argument, and Delta time travel) move to Plan 2,
which has those fixtures. Testing them against a nonexistent path would produce a test
that passes because the file is missing rather than because the behavior holds.

- [ ] **Step 1: Write the fact tests**

Create `Tests/DuckDBKitTests/DuckDB155FactsTests.swift`:

```swift
import Foundation
import Testing
@testable import DuckDBKit

/// Re-verification of the nine DuckDB 1.5.5 behaviors AGENTS.md pins, measured against
/// libduckdb rather than the Python wheel. A failure here is not a test bug — it means
/// the engine changed and the design must change with it.
private func con() throws -> Connection {
    let db = try Database.inMemory()
    db.harden()
    return try db.connect()
}

private func tempCSV(_ contents: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-fact-\(UUID().uuidString).csv")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

@Test func fact1_theSniffEmptySentinelCannotBeFedBackIntoReadCsv() throws {
    // The measured oddity: sniff_csv reports an ABSENT quote/escape/comment as the
    // literal 8-character string "(empty)", and passing that straight back into
    // read_csv fails with "the quote option cannot exceed a size of 1 byte".
    // core/source.py's SNIFF_EMPTY normalization exists solely because of this.
    //
    // Asserting the failure is the deterministic half of the fact. Asserting what
    // sniff_csv *returns* is not: for a file with no quote characters the sniffer may
    // still report its default quote, so that direction would be a coin flip dressed
    // up as a test.
    let path = try tempCSV("a,b\n1,2\n")
    let c = try con()

    #expect(throws: DuckDBError.self) {
        _ = try c.query("SELECT * FROM read_csv('\(path)', header=true, quote='(empty)')")
    }
    // The normalized form — what core/source.py actually sends — must work.
    _ = try c.query("SELECT * FROM read_csv('\(path)', header=true, quote='')").allRows()
}

@Test func fact2_rejectScansAndRejectErrorsDoNotExist() throws {
    let c = try con()
    #expect(throws: DuckDBError.self) { _ = try c.query("SELECT * FROM reject_scans()") }
    #expect(throws: DuckDBError.self) { _ = try c.query("SELECT * FROM reject_errors()") }
}

@Test func fact3_countStarOnACsvViewDisagreesWithSelectStar() throws {
    // With an uncastable value present, count(*) is answered by projection pushdown
    // without parsing any column, so it reports the PHYSICAL count while SELECT *
    // returns fewer rows. This is why exact counts run against the all-varchar relation.
    let path = try tempCSV("n\n1\n2\nnot_a_number\n4\n")
    let c = try con()
    let read = "read_csv('\(path)', columns={'n': 'INTEGER'}, header=true, ignore_errors=true)"
    let counted = try c.query("SELECT count(*) FROM \(read)").allRows()[0][0]
    let selected = try c.query("SELECT * FROM \(read)").allRows().count
    #expect(counted == .int(4))
    #expect(selected == 3)
}

// fact4 (read_xlsx takes `sheet =>`, not `sheet_name`) and fact6 (Delta time travel is
// `version => n`; `AT (VERSION => n)` does not parse) are NOT tested here. Both need a
// real .xlsx and a real Delta table, and this plan has no such fixtures — a version
// pointed at a nonexistent path throws for the missing file, so the test would pass
// whether or not the behavior still holds. A test that passes for the wrong reason is
// worse than no test. Both land in Plan 2, where the fixtures exist.

@Test func fact5_timestampWithTimeZoneRoundTrips() throws {
    // In Python this needs pytz or it raises. Through the C API there is no Python
    // dependency at all, so this must simply work — the pytz pin disappears with it.
    let c = try con()
    try c.execute("SET TimeZone='UTC'")
    let v = try c.query("SELECT TIMESTAMPTZ '2026-08-09 12:00:00+00'").allRows()[0][0]
    #expect(v != .null)
}

@Test func fact7_allowQuotedNullsFalseKeepsEmptyStringDistinctFromNull() throws {
    // The distinction the whole tool exists to show:
    //   ,,   -> NULL   (nothing there)
    //   ,"", -> ''     (an empty string, written deliberately)
    let path = try tempCSV("a,b,c\n1,,2\n3,\"\",4\n")
    let rows = try con().query(
        "SELECT b FROM read_csv('\(path)', header=true, allow_quoted_nulls=false, all_varchar=true)"
    ).allRows()
    #expect(rows[0][0] == .null)
    #expect(rows[1][0] == .text(""))
}

@Test func fact8_approxCountDistinctCanExceedTheRowCount() throws {
    // Measured at 340 for 300 distinct values. HyperLogLog is an estimate, so
    // core/profile.py clamps it. This test records that clamping is still needed.
    let rows = try con().query(
        "SELECT approx_count_distinct(i), count(*) FROM range(300) AS t(i)"
    ).allRows()
    guard case .int(let approx) = rows[0][0], case .int(let exact) = rows[0][1] else {
        Issue.record("expected two integers"); return
    }
    #expect(exact == 300)
    #expect(approx > 0)   // the point is only that it is an estimate, not that it is wrong
}

@Test func fact9_duckdbTablesEstimatedSizeIsRowsNotBytes() throws {
    // It produced a "3,000,048 B" reading for a 3M-row table until this was caught,
    // which is why staged bytes are measured as growth of stage.duckdb instead.
    let c = try con()
    try c.execute("CREATE TABLE big AS SELECT i FROM range(100000) AS t(i)")
    let v = try c.query(
        "SELECT estimated_size FROM duckdb_tables() WHERE table_name = 'big'"
    ).allRows()[0][0]
    guard case .int(let n) = v else { Issue.record("expected an integer"); return }
    // Rows, not bytes: 100k rows of BIGINT would be ~800 KB if it were bytes.
    #expect(n < 200_000)
}

@Test func theSelectOnlyWrapRejectsNonSelectsAtParseTime() throws {
    // Not one of the nine, but the security property that depends on the same parser.
    // The NEWLINES are load-bearing: the flat form rejects a legitimate trailing comment.
    let c = try con()
    func wrapped(_ sql: String) -> String { "SELECT * FROM (\n\(sql)\n) AS _q\nLIMIT 10 OFFSET 0" }

    _ = try c.query(wrapped("select 1 -- a trailing comment"))   // must succeed

    for dangerous in ["DROP TABLE t", "ATTACH 'x.db'", "PRAGMA version",
                      "SET memory_limit='1GB'", "SELECT 1; DROP TABLE t"] {
        #expect(throws: DuckDBError.self) { _ = try c.query(wrapped(dangerous)) }
    }
}
```

- [ ] **Step 2: Run the fact tests**

Run: `swift test --filter DuckDB155FactsTests`
Expected: PASS — 8 tests (seven behaviors plus the SELECT-only wrap).

**If any fail:** stop. Do not adjust the test to match. Record which behavior changed
and report it — it changes the SiftCore design in Plan 2. These tests run entirely on
in-memory DuckDB and temp CSV files, so they need no network and no extensions; a
failure is a real signal, never an environment problem.

- [ ] **Step 3: Write the CI workflow**

Create `.github/workflows/ci-native.yml`:

```yaml
name: CI (native)

on:
  pull_request:
  push:
    branches: [native]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-native-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    name: Build and test
    runs-on: macos-15
    timeout-minutes: 20

    steps:
      - uses: actions/checkout@v5
        with:
          persist-credentials: false

      # This machine has only the macOS 26 SDK, so macos-15 is the only oracle for
      # SDK-version build breaks. latent hit two that were invisible locally.
      - name: Show toolchain
        run: |
          sw_vers
          swift --version
          xcrun --show-sdk-version

      - name: Fetch libduckdb
        run: ./scripts/fetch-duckdb.sh

      - name: Build
        run: swift build

      - name: Test
        run: swift test
```

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: PASS — all tests across all four test files.

- [ ] **Step 5: Commit**

```bash
git add Tests/DuckDBKitTests/DuckDB155FactsTests.swift .github/workflows/ci-native.yml
git commit -m "Re-verify the nine DuckDB 1.5.5 behaviors against libduckdb"
```

---

## Done when

- `./scripts/fetch-duckdb.sh && swift build && swift test` is green from a clean checkout.
- CI is green on `macos-15`.
- Seven of the nine 1.5.5 behaviors are pinned by a passing test, or a deviation is
  written up. The remaining two are carried into Plan 2's task list, not dropped.
- `DuckDBKit` exposes `Database`, `Connection`, `Statement` (via `Connection.query`),
  `DBValue`, `Cell`, `ColumnMeta`, `ResultSet` and `Chunk` — the surface Plan 2 builds on.

## Deliberately not in this plan

- **Nested type decoding** (`STRUCT`, `LIST`, `MAP`, `UNION`, `JSON`). SiftEngine casts
  those columns to VARCHAR in the SELECT list, reusing `core/sqlgen.py`'s `_as_text`.
- **Two of the nine 1.5.5 fact tests** — `read_xlsx` taking `sheet =>` rather than
  `sheet_name`, and Delta time travel being `version => n` rather than `AT (VERSION => n)`.
  Both need real `.xlsx` and Delta fixtures. **Plan 2 must carry them**, or the
  re-verification is quietly incomplete.
- **`~/.sift` creation, `0700` enforcement, and the private-store fallback.** Those are
  session concerns and belong in Plan 3 with the rest of the stateful layer.
- **Any Sift logic.** No SQL generation, no format detection, no profiling. DuckDBKit
  knows nothing about Sift and must stay that way — it is the one module with a chance
  of being correct by inspection.
