# Native Sift — design

Date: 2026-08-09
Status: approved, ready for an implementation plan
Branch: `native` (merges to `main` as v2.0.0)

---

## 1. What this is

Rebuild Sift as a native macOS application: one SwiftPM package, one binary, no Python at runtime,
no WKWebView, no loopback HTTP server. The reference shape is `diamondplated/latent` — a SwiftPM
package with an executable target, an `.app` assembled by a build script, and zero runtime
dependencies.

The product does not change. Sift still means: drop a file in, explore it instantly, DuckDB reads
it in place, nothing leaves the machine.

## 2. Why

Three reasons, in order of weight.

**Installation is currently the worst thing about the repo.** Today's quick start is `uv venv`, then
`uv pip install` against a pinned `requirements.txt`, then a one-time online `INSTALL delta; INSTALL
excel`, then `./build-app.sh`. Four steps and a Python toolchain before anyone sees a grid. Native,
it is `./scripts/fetch-duckdb.sh && ./build-app.sh`.

**A third of the code exists only to cross a process boundary.** The loopback server, the per-launch
token, the `Host` pinning, the SSE fan-out, the `{port, token}` stdout handshake, the
`__SIFT_TOKEN__` page placeholders, the parent-death watcher, and the pathless-browser-drop spill
path are all scaffolding around "the engine is in another process." In-process they are zero lines.

**Two structural bugs disappear rather than being managed.** The grid's scroll-height workaround
exists because browsers clamp element height (~17.8M px in Safari), which breaks silently past
~800k rows at 27 px/row. `NSTableView` asks only for visible rows. And `BIGINT`/`DECIMAL` currently
cross the wire as strings because JS `Number` rounds past 2^53 — natively `Int64` is `Int64`.

## 3. Decisions already made

| Decision | Choice | Consequence |
|---|---|---|
| Scope of v1 | **Full feature parity, one release** | No window where the native app is the worse one and Python has to stay alive beside it |
| Browser mode (`dev.sh`) | **Deleted** | `web/index.html` goes. A `sift` CLI target becomes the headless verification surface, the role `pv-pipeline` plays in latent |
| Repo strategy | **`native` branch, merged at v2.0.0** | `main` keeps working and the CI badge keeps being true for the length of the rewrite; the final commit on the branch deletes Python |
| Minimum macOS | **14** (up from 13) | Required by `@Observable`. Accepted; README must be updated to say so |
| DuckDB binding | **Prebuilt `libduckdb` C API** | Keeps the exact 1.5.5 pin and the nine measured behaviors that depend on it |

### Why the prebuilt dylib and not `duckdb-swift`

The current README argues the Swift binding is unusable because every tag is a `-dev` prerelease
that SwiftPM's resolver ignores. Verified still true — latest is `v1.6.0-dev11145`. That is an
argument against version *ranges*; a `revision:` pin would sidestep it.

The real reason is the version pin. `requirements.txt`, `README.md` and `AGENTS.md` all document
nine specific measured DuckDB 1.5.5 behaviors this code depends on. `duckdb-swift`'s tags do not
correspond to 1.5.5, so adopting it means abandoning the verified pin *and* compiling a 400-file C++
amalgamation on every cold CI build. Every DuckDB release ships `libduckdb-osx-universal.zip`
(prebuilt universal dylib plus `duckdb.h`), which keeps 1.5.5 exactly, keeps signed `delta`/`excel`
extensions working unchanged, and builds in seconds.

## 4. Architecture

One SwiftPM package. Module boundaries are lifted from the existing Python split, because that split
is already proven and its purity constraint is what makes the tests fast.

```
sift/
  Package.swift
  Vendor/duckdb/                    fetched, gitignored — libduckdb.dylib only
  scripts/fetch-duckdb.sh           downloads and checksum-verifies the pinned libduckdb
  build-app.sh                      assembles Sift.app (exists; gains the dylib copy + rpath step)
  Resources/AppBundle/              Info.plist, Sift.icns
  Sources/
    CDuckDB/                        systemLibrary target — the modulemap over duckdb.h
    DuckDBKit/                      Swift wrapper: Database, Connection, Statement, chunk decoding
    SiftCore/                       port of engine/core/** — pure, no connection, no mutable state
    SiftEngine/                     port of session.py — the one actor
    SiftUI/                         SwiftUI panels + the NSTableView grid
    SiftApp/                        @main, menus, LaunchServices document handling
    sift/                           CLI: --verify self-checks, plus headless open/profile/export
  Tests/
    SiftCoreTests/                  the ported engine/tests/**
    DuckDBKitTests/                 chunk decoding and type round-trips
```

`SiftCore` inherits the existing purity rule verbatim: importable with no connection, no server, no
module-level mutable state. That constraint is why 216 of the current 218 tests run under 10 ms
each, and it is the single most valuable property to carry across.

`SiftEngine` inherits the other half: it is the **only** module holding mutable state.

**Every module above is a library target except `SiftApp` and `sift`.** This is a hard
SwiftPM constraint, not a preference: **a test target cannot import an
`executableTarget`.** Anything that lands in `SiftApp` is permanently untestable, so
`SiftApp` holds `@main`, menu wiring, and LaunchServices plumbing — nothing else. Every
decision, every transformation, every piece of state goes in a library beneath it.

This is precisely how latent ended up with `pv-pipeline`: its `PhotoViewerApp` is an
executable target carrying a 678-line `AppState.swift`, which its test targets cannot
reach. The `sift` CLI plays the same role here — but the CLI is a *supplement* to
library-target tests, never a substitute for them. If a behavior can only be verified
through the CLI, it is in the wrong module.

### Module dependency graph

```
CDuckDB  <-  DuckDBKit  <-  SiftEngine  <-  SiftUI  <-  SiftApp
                              ^                          
                 SiftCore ----+----------------------  sift (CLI)
```

`SiftCore` depends on nothing but Foundation. That is deliberate and load-bearing.

## 5. DuckDB integration

### Acquisition

`scripts/fetch-duckdb.sh` downloads `libduckdb-osx-universal.zip` for the pinned version (**1.5.5**)
from DuckDB's GitHub release, verifies a hardcoded SHA-256, and unpacks `libduckdb.dylib` into
`Vendor/duckdb/` and `duckdb.h` into `Sources/CDuckDB/` — beside the module map, so the module map
needs no `-I` flag. Both are gitignored. The checksum is pinned in the script.

Verified 2026-08-09 against
`https://github.com/duckdb/duckdb/releases/download/v1.5.5/libduckdb-osx-universal.zip`:

- 35 MB zip, SHA-256 `7b5b8915cc382d0708636fe6385c0cdad5a61c9ff8ba2638b3e2141640783155`
- Contains `libduckdb.dylib` (117 MB), `duckdb.h` (244 KB), `duckdb.hpp`, `duckdb_extension.h`
- `lipo -info` reports **x86_64 and arm64** — one artifact covers both, so no per-arch build
- The dylib self-reports `v1.5.5`, so the existing pin is preserved exactly
- Every C API function this design depends on is present in `duckdb.h`: `duckdb_prepare`,
  `duckdb_fetch_chunk`, `duckdb_data_chunk_get_vector`, `duckdb_validity_row_is_valid`,
  `duckdb_decimal_scale`, `duckdb_hugeint_to_double`, `duckdb_interrupt`, and the `duckdb_bind_*`
  family

> Rationale: latent's `scripts/convert_*.py` download model weights without checksum pinning, and
> that is already recorded as a known gap in that repo. Not repeating it here.

`Vendor/` is gitignored. The script is idempotent and refuses to overwrite a good copy.

### Linking

`Sources/CDuckDB` is a SwiftPM `systemLibrary` target carrying a `module.modulemap` that exposes
`duckdb.h`. The root package supplies `unsafeFlags` for the header and library search paths — legal
here because this package is an application, never consumed as a dependency.

`build-app.sh` copies `libduckdb.dylib` into `Sift.app/Contents/Frameworks/` and sets the executable's
install name to `@rpath/libduckdb.dylib` via `install_name_tool`, with `@executable_path/../Frameworks`
on the rpath.

### The wrapper

`DuckDBKit` exposes four types:

- `Database` — owns `duckdb_database`; opens `~/.sift/stage.duckdb`, applies hardening settings,
  loads extensions. Both configure steps record their per-item outcome (`hardened`,
  `loadedExtensions`) — non-fatal, but never silent.
- `Connection` — owns `duckdb_connection`. The direct analogue of Python's `con.cursor()`: shares
  the catalog and buffer manager, owns its transaction. **Not `Sendable`**; each unit of work
  creates its own and never shares it across tasks. `interrupt()` is the one exception, by
  design — it is the cancel path, and exists to be called from another task.
- `ResultSet` — owns the `duckdb_result` and the column metadata. `Connection.query` prepares,
  binds and executes in one call, driven by a `DBValue` enum (`null | bool | int64 | double |
  string`) matching what `sqlgen` produces as parameters. There is no separate `Statement` type;
  prepared-statement handling is entirely inside `query`.
- `Chunk` — decodes a `duckdb_data_chunk` into Swift values, honoring the validity bitmask. A
  reference type with a `deinit`, so the grid's page cache can hold chunks across method
  boundaries without aliasing a C handle. A chunk may outlive the `ResultSet` it came from.

`Connection.interrupt()` wraps `duckdb_interrupt`, preserving the cancel path that `Session.cancel`
depends on today.

### Type decoding

The chunk decoder must cover every type `kind_of` classifies. Two need explicit care:

- **`HUGEINT` / `UHUGEINT`** — 128-bit, delivered as a `duckdb_hugeint` struct of `lower: UInt64` /
  `upper: Int64`. Decoded to a Swift `String` via manual 128-bit division, since Swift has no native
  `Int128` on the pinned toolchain.
- **`DECIMAL`** — carries width and scale in the logical type, separate from the value. Decoded to
  `Decimal` using the scale from `duckdb_decimal_scale`, never through `Double`.

`BLOB` renders as `<blob N B>` exactly as `jsonable` does today.

### Nested types have no decoder — SiftEngine must CAST them

> **Contract for Plan 3.** `DuckDBKit` does **not** decode nested types. `SiftEngine` must wrap
> every nested column in `CAST(col AS VARCHAR)` in its SELECT list, reusing the `_as_text` helper
> that already exists in `core/sqlgen.py`. This is a requirement on the caller, not an omission
> in the decoder. A nested column that reaches the decoder unwrapped renders as a loud marker
> and the user sees no data.

Measured against libduckdb 1.5.5, an unwrapped nested column decodes to:

| Type | Decodes to |
|---|---|
| `INTEGER[]` (LIST) | `⟨unsupported type 24⟩` |
| `STRUCT(a INTEGER)` | `⟨unreadable type 25⟩` |
| `MAP(...)` | `⟨unsupported type 26⟩` |
| `UNION(...)` | `⟨unreadable type 28⟩` |
| `INTEGER[3]` (ARRAY) | `⟨unreadable type 33⟩` |
| `JSON` | works, but only incidentally — DuckDB reports JSON as `VARCHAR` |

A deliberately loud marker, never `""`: an empty string is indistinguishable from real data, and
`NULL` vs `''` vs a sentinel staying distinct is the point of the tool. A **NULL** in a nested
column still decodes as `.null` — the validity mask is consulted before anything else, so the
missing-vs-present distinction holds even where the value itself cannot be read.

`ColumnMeta.typeName` reports nested columns by their bare shape (`LIST`, `STRUCT`, `MAP`,
`UNION`, `ARRAY`) rather than DuckDB's fully parameterized `typeof()` form. Downstream
classification reads the prefix, and the prefix is what matters. Scalar types match `typeof()`
exactly, `DECIMAL` included.

## 6. Concurrency model

Three facts, replacing the three in `session.py`'s docstring:

1. One `duckdb_database` is opened at launch.
2. Every unit of work takes its own `Connection`. Connections are not shared across tasks and are
   not `Sendable`.
3. `Session` is an `actor`. It owns the table catalog, job registry, and staging state. Background
   work — exact count, bad-row detection, profiling, staging CTAS — runs as detached `Task`s that
   create their own `Connection` and call back into the actor with results.

The four-worker `ThreadPoolExecutor` becomes structured tasks. Job cancellation keeps both halves of
today's mechanism: a cancel flag checked between statements, plus `duckdb_interrupt` for a query
already in flight.

### Replacing SSE

`emit()`, `subscribe()`, `unsubscribe()`, the `_subscribers` set, the asyncio queue fan-out and the
`QueueFull` drop-guard are deleted. UI state becomes `@Observable` on an `AppState` type that
SwiftUI observes directly. Every current event type maps to a property mutation:

| SSE event | Becomes |
|---|---|
| `opened`, `closed` | `tables` array mutation |
| `counting`, `count` | `Table.counting` / `Table.rowCount` |
| `rejects` | `Table.badRows` / `Table.badCells` |
| `profile` | `Table.profile` |
| `staging`, `staged` | `Table.staging` / `Table.staged` |
| `purged` | staged-data panel refresh |
| `error` | a banner on `AppState` |
| `state` | nothing — observation is automatic |

### The private-store fallback

`session.py` falls back to a per-PID private store when another engine holds the exclusive lock on
`stage.duckdb`, because the browser dev server and the app could run simultaneously. Browser mode is
gone, so the common cause disappears — but a second app instance (`open -n`) can still do it. The
fallback and `_sweep_private_stores` are kept as-is; the log message is reworded to drop the
reference to the dev server.

## 7. Port map

| Python | Swift | Notes |
|---|---|---|
| `core/types.py` | `SiftCore/Types.swift` | `Literal` unions become real enums; `needs_string_transport` **deleted** |
| `core/ident.py` | `SiftCore/Ident.swift` | NFKD normalization via `String.decomposedStringWithCompatibilityMapping` — **compatibility**, not canonical; `…CanonicalMapping` is NFD and would have shipped a bug |
| `core/guard.py` | `SiftCore/Guard.swift` | Unchanged in behavior — still only a message improver |
| `core/sqlgen.py` | `SiftCore/SQLGen.swift` + `SQLGenPanels.swift` | Returns `(String, [SQLValue])` — `SQLValue` is SiftCore's own type; `DBValue` lives in `DuckDBKit`, which SiftCore cannot import. The newline subquery wrap is preserved byte-for-byte |
| `core/profile.py` | `SiftCore/Profile.swift` | Takes already-fetched rows, returns structs — unchanged shape |
| `core/stage.py` | `SiftCore/Stage.swift` | Pure decisions; `select_for_purge` ports directly |
| `core/snippet.py` | `SiftCore/Snippet.swift` | Copy-as-code output must stay character-identical |
| `core/source.py` | `SiftCore/Source.swift` + `SiftEngine/SourceProbe.swift` | Pure parts (format detection, glob escaping, hive keys, row estimation, `read_expr`) stay in Core; the parts taking a connection move to Engine |
| `session.py` | `SiftEngine/Session.swift` + `Staging.swift` + `Joins.swift` + `Export.swift` | Split by section; the file is 1,220 lines and does not want to stay one |
| `app.py` | **deleted** | Routes become direct actor method calls. CLI arg parsing moves to the `sift` target |
| `web/index.html` | `SiftUI/**` | See §9 |
| `shell/**` | `SiftApp/**` | Menus, toolbar, document handling and the open-panel logic survive nearly verbatim; the WKWebView, JS bridge and `Sidecar.swift` are deleted |

### The openpyxl gap

`list_sheets` uses openpyxl because DuckDB's `read_xlsx` can read a *named* sheet but cannot list
them. There is no Swift equivalent, and adding a dependency for it would break the zero-dependency
goal.

Replacement, in `SiftCore/XLSXSheets.swift`: an `.xlsx` is a zip. Run `/usr/bin/unzip -p` (ships with
macOS; latent's `ArchiveExtractor` already uses exactly this) to read `xl/workbook.xml` for sheet
names and order, and each `xl/worksheets/sheetN.xml`'s `<dimension ref="A1:F1000"/>` for row and
column counts. Parse with Foundation's `XMLParser`.

This preserves the two properties that matter: it does not parse cells, so it stays fast on large
workbooks; and a sheet reporting `<= 1` row or `< 1` column is still treated as empty, matching
`SheetInfo.empty`.

Fallback: a workbook with no `<dimension>` element reports `rows: 0, cols: 0` and is treated as
non-empty, so the sheet picker still offers it rather than hiding it.

## 8. What gets deleted

Not moved — deleted, with nothing taking its place:

- The FastAPI app, all 29 routes, uvicorn, and the sidecar mode
- The per-launch token, `Host` pinning, and `127.0.0.1` binding (no socket exists)
- SSE: the endpoint, the subscriber set, the fan-out
- The parent-death watcher
- `jsonable()`, `rows_payload()`, `needs_string_transport()` — JS number-safety, now moot
- The upload/spill path, `SIFT_MAX_UPLOAD_MB`, `sweep_spill()`, and `copied_from_browser`
  (they exist only for pathless browser drops)
- `web/index.html`, `dev.sh`, and the `__SIFT_TOKEN__` / `__SIFT_MAX_UPLOAD_MB__` / `__SIFT_NATIVE__`
  placeholder substitution
- `shell/Sources/Sift/{Bridge,DropWebView,Sidecar}.swift` and the `WKScriptMessageHandler` protocol
- The grid's scroll-height fraction mapping and separate wheel handling
- `requirements.txt`, `requirements-dev.txt`, `pytest.ini`, `.venv`
- Config vars `SIFT_PORT`, `SIFT_MAX_UPLOAD_MB`, `SIFT_ROOT`

`SIFT_HOME`, `SIFT_STAGE_BUDGET_GB` and `SIFT_STAGE_MAX_AGE_DAYS` survive unchanged.

## 9. UI

SwiftUI throughout, with one AppKit escape hatch.

**Window** — `NSSplitViewController` semantics via SwiftUI `NavigationSplitView`: source list in the
sidebar, grid in the content column, column inspector in a trailing `Inspector`. The current shell
already uses `NSSplitViewItem(sidebarWithViewController:)` specifically for system sidebar material
and inset selection pills; `NavigationSplitView` provides the same.

**The grid is `NSTableView` wrapped in `NSViewRepresentable`.** SwiftUI's `Table` requires a
`RandomAccessCollection` of every row, which is wrong for 2.5M rows arriving 500 at a time.
`NSTableView` requests only visible rows.

Grid behavior:
- `numberOfRows` returns `Table.visibleRows` (filtered count when filters are active, else
  physical minus dropped rows) — the same value that drives scroll extent today.
- A page cache keyed by `offset / 500`. A miss returns a placeholder cell and schedules an async
  fetch; the fetch calls `reloadData(forRowIndexes:columnIndexes:)` on arrival.
- `NULL`, `''` and `'N/A'` render distinctly, as they do now. This is non-negotiable.
- Column alignment follows `Column.kind`, matching current behavior.

**Panels**, each a SwiftUI view over the engine actor: column profile, distinct values (with
click / ⌘-click multi-select / right-click exclude, and the faceting rule that a column's panel
ignores its own filters), histogram, high-cardinality sample, bad-rows sheet, staged-data manager,
merge builder, export sheet, xlsx sheet picker, SQL box.

**Menus and toolbar** carry over from `AppDelegate.swift` essentially verbatim, including the
`NSRecentDocumentsMenu` identifier trick, the proxy icon via `window.representedURL`, and the
`NSOpenPanel` configured to accept directories (a folder of parquet, or a Delta table).

## 10. Testing

**`Tests/SiftCoreTests`** — the port of `engine/tests/**`, using swift-testing.

The current AGENTS.md rule is that `engine/tests/**` is the spec and is read-only: never weaken a
test to make a change pass. Porting is technically rewriting, so the rule for this work is:

> Each Swift test keeps its Python original's assertion values verbatim. The Python test file stays
> in the tree until its Swift counterpart asserts the same thing. The Python suite is deleted only
> in the final commit, once every assertion has a Swift equivalent.

Several current tests deliberately import internals (`core.sqlgen._safe_type`). Those stay pinned;
the Swift equivalents are `internal` and tested via `@testable import`.

**`Tests/DuckDBKitTests`** — round-trip decoding for every type in `kind_of`, with explicit cases for
`HUGEINT` boundaries, `DECIMAL` scale, `NULL` validity masks, and `BLOB`.

**`sift --verify`** — the CLI self-verifier, latent's `pv-pipeline` role. Runs the same scenarios as
the test target but needs no test host, so it works on a CommandLineTools-only machine: open each
supported format, profile it, run the distinct panel, exercise the SELECT-only gate, stage and
unstage, merge, and export. This is the replacement for "verify UI logic in the browser preview,"
which is why browser mode could be deleted.

**CI** — `macos-15`, mirroring latent: `swift build`, then `swift run sift --verify`, then
`swift test`. This machine has only the macOS 26 SDK, so CI remains the only oracle for SDK-version
build breaks. Latent hit two (`CGContext` wanting `bitmapInfo` as raw `UInt32`, and
`MLMultiArrayDataType.int8` not existing pre-macOS-26); expect equivalents on any CoreGraphics or
newer-API surface.

## 11. Contracts that survive unchanged

These are behavior, not implementation, and the rewrite must preserve every one:

**Security and safety**
- The SELECT-only gate: `guard` first for a readable message, and the **newline** subquery wrap as
  the actual grammar-level enforcement. The newlines are load-bearing — the flat form rejects a
  legitimate `select 1 -- comment`. A keyword blocklist is not an acceptable substitute.
- `disabled_filesystems='HTTPFileSystem,S3FileSystem'`; `autoinstall_known_extensions=false`;
  `autoload_known_extensions=false`; `allow_community_extensions=false`.

  **Measured 2026-08-09 against libduckdb 1.5.5, and it changes which setting does the
  work.** On a clean install, a `SELECT` against an `https://` URL is refused by the
  *extension* guard — `Missing Extension Error: ... requires the extension httpfs to be
  loaded` — because `autoload_known_extensions=false` stops httpfs ever loading, so
  `disabled_filesystems` is never consulted. `disabled_filesystems` produces its own
  `Permission Error: File system HTTPFileSystem has been disabled by configuration`
  only once something has already loaded httpfs.

  The two are complementary layers covering different states, not redundant belt and
  braces — removing either one leaves a hole the other does not cover. A test asserting
  merely that the query throws proves nothing: with hardening removed entirely the URL
  simply 404s, which throws too. Any test here must assert on the error *message*.

  This applies equally to the current Python engine, which sets the same four options.
- `enable_external_access` stays untouched — setting it false would block `read_csv` itself.
- `~/.sift` created and enforced at `0700`.
- Identifiers quoted via `q()`, values always bound as parameters. Never interpolated.
- `_safe_type`'s whitelist on interpolated DuckDB type names.
- The atomic view→table swap under a per-table lock, with retry.
- Staged-data age-out and budget.

**Data truth**
- `NULL` vs `''` vs `'N/A'` stay three distinct things; `allow_quoted_nulls=false`.
- `ignore_errors=true` paired with independent `TRY_CAST` bad-row accounting — dropped rows are
  counted and shown, never silent.
- Exact counts run against the all-varchar relation, never a bare `count(*)` on the typed view.
- `approx_count_distinct` is clamped to the row count.
- A `_delta_log/` directory is read via `delta_scan`, never a raw parquet glob.
- A missing `delta` extension refuses the open rather than degrading to a glob.
- Staging never fires for `parquet`, `glob_parquet` or `delta`, and only after an aggregate or
  ~3 seconds of dwell.
- Sorted result sets are materialized once and paged from the copy, so ties on a non-unique column
  cannot duplicate or drop rows across pages.

**The nine DuckDB 1.5.5 facts** in `AGENTS.md` remain true and remain documented.

## 12. Risks

| Risk | Mitigation |
|---|---|
| The nine 1.5.5 behaviors were verified through the **Python wheel**, not `libduckdb`. Same engine version, so they should hold — but "should" is not "verified" | Re-probe all nine against `libduckdb` as the first task, before any porting. If one differs, the design changes before code is written, not after |
| `HUGEINT` / `DECIMAL` decoding is fiddly and silently wrong when wrong — exactly the corruption class Sift exists to expose | Explicit boundary tests in `DuckDBKitTests` before the grid renders anything |
| The openpyxl replacement is new code with new failure modes on unusual workbooks | Test against a workbook with: no `<dimension>`, a blank sheet, a sheet with a name needing XML escaping, and >10 sheets |
| macOS 26 SDK trap — build breaks invisible locally | CI on `macos-15` from the first commit on the branch, not added at the end |
| A 6,670-line rewrite is long enough to stall halfway | Branch strategy means `main` is never broken; the CLI verifier lands before the UI so the engine is provable on its own |
| Behavior drift the ported tests do not catch | The Python suite stays runnable in the tree until the final commit, so both can run against the same fixtures |

## 13. Sequencing

Seven phases. Each ends somewhere the branch is coherent.

1. **DuckDBKit + re-probe.** Package skeleton, `fetch-duckdb.sh`, `CDuckDB` modulemap, the wrapper,
   chunk decoding with tests. Re-verify all nine 1.5.5 facts against `libduckdb`. CI green on
   `macos-15`.
2. **SiftCore.** Port `types`, `ident`, `guard`, `sqlgen`, `stage`, `profile`, `snippet`, and the
   pure half of `source`, each with its ported tests. The xlsx sheet reader lands here.
3. **SiftEngine.** The `Session` actor, catalog, open path, paging, filters, profiling, bad-row
   detection, staging, joins, export.
4. **CLI verifier.** `sift --verify` covering every scenario. At this point the entire engine is
   provable with no UI in existence.
5. **Grid.** `NSTableView` representable, page cache, the three-kinds-of-missing rendering, sorting,
   filtering.
6. **Panels.** Profile, distinct, histogram, bad-rows, staged-data, merge, export, sheet picker,
   SQL box. Menus and toolbar.
7. **Bundle and delete.** `build-app.sh` for the native binary, icon, `Info.plist` with document
   types. Delete `engine/`, `web/`, `shell/`, `dev.sh`, `bin/sift-open`, the Python test suite and
   requirements files. Rewrite `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`. Tag
   v2.0.0.

## 13a. Known gaps carried between plans

Measured during the build and deliberately not fixed where they were found. Each entry
names the plan that owns it. Entries have come out of Plans 1, 2 and 3 — this is the
project's cross-plan gap list, not Plan 1's. Nothing here is silently wrong — every unsupported path renders a
loud marker — but each is a real limitation with a known shape.

**`interrupt()` is not fire-and-forget — Plan 3.** Measured against libduckdb 1.5.5: a
single `duckdb_interrupt` call issued before execution begins is **swallowed**, and the
query runs to completion (4.20 s in the probe). The flag is cleared as execution starts,
so a cancel landing one instruction early is indistinguishable from one that never
fired. Hammering the interrupt in a loop cancels reliably (5/5 runs, 0.000–0.002 s,
`INTERRUPT Error: Interrupted!`). `Session.cancel` must therefore **keep re-asserting
the interrupt for as long as the job is meant to be cancelled**, not call it once. The
Python engine's single `con.interrupt()` does not port across.

**A sorted table over 5,000,000 rows silently drops its tail — Plan 4 (grid).**
`Session.sortedRelation` always materializes, and materializes at most `sortMaterializeMax`
(5,000,000) rows. Pages past that come back **empty**, while `visibleRows` still reports the
full row count — so the grid sizes its scroll extent for 100M rows and 95M of them return
nothing. Ported faithfully from `engine/session.py`, which has the identical gap, so this is
not a regression; it is a pre-existing limit that the native grid will make far more visible
than a paged web view did. Recorded 2026-08-09 during Plan 3 Task 4's review. The fix is
either to cap `visibleRows` at the materialized count so the extent tells the truth, or to
re-materialize a window as the user scrolls past it.

**A first-party generated query returns a `LIST`, and the decoder cannot read it — CLOSED
2026-08-09, Plan 3 Task 1.** Plan 1 deferred nested-type decoding on the premise that
nested columns only arrive in *user data*, which SiftEngine would wrap in `CAST(col AS
VARCHAR)`. That premise was false. `sqlgen.bad_rows_sql` emits `list_filter([...], x ->
x IS NOT NULL) AS bad_columns` — Sift's own SQL, generating a `LIST` column — so
`bad_columns` decoded as `⟨unsupported type 24⟩` and the per-cell highlighting in the
"rows your file lost" panel could not work end to end. Fixed by adding a `LIST` case to
`Chunk.decodeColumn`/`decodeOne` (reading `duckdb_list_entry` plus
`duckdb_list_vector_get_child`, duckdb.h:442-449 and :3535) and a `Cell.list([Cell])`
case that keeps each element as its own `Cell` rather than joining into text. Covered by
`DecodeTests.swift`'s LIST tests and, as the actual consumer,
`SQLGenPanelsTests.badRowsSQLDecodesBadColumnsAsTheFailingColumnNames`, which runs
`badRowsSQL`'s generated SQL against a real dirty CSV and asserts the decoded
`bad_columns` names the failing column.

**Six DuckDB types do not decode — Plan 3.** `ENUM` (23), `BIT` (29), `BIGNUM` (35),
`TIME_NS` (39), `VARIANT` (41) and `GEOMETRY` (40) render `⟨unsupported type N⟩`. NULLs
in those columns still decode to `.null` correctly. `TIME_NS` is the notable one — the
direct sibling of the `TIMESTAMP_NS` that Plan 1 does decode. Note that
`DUCKDB_TYPE_VARINT` does not exist on 1.5.5; the type is `BIGNUM`.

*Reassigned from Plan 2 (2026-08-09).* Plan 2 shipped `SiftCore`, which imports
Foundation only and so cannot touch the decoder at all — the fix lives in
`Chunk.decodeColumn`, and the first module that both imports `DuckDBKit` and owns a
result path is `SiftEngine`. Plan 2's own "Deliberately not in this plan" had already
pushed it to "Plan 2's successor work" without naming it; this names it.

**JSON classifies as text, not nested — CLOSED 2026-08-09, Plan 3 Task 1.**
`duckdb_column_logical_type` reports JSON as type id 17 (`VARCHAR`), so a JSON column
arrived from `DuckDBKit` typed `"VARCHAR"`. `duckdb_logical_type_get_alias`
(`duckdb.h:3070`) returns `"JSON"` for such a column and `nil` for a plain VARCHAR —
`ResultSet.init` now reads the alias and prefers it whenever non-nil, freeing the
returned string with `duckdb_free` per duckdb.h:3065.

`kind(of:)` was already correct on its own terms — it returns `.nested` for the string
`"JSON"` — so the gap was entirely upstream of it, in what `DuckDBKit` reported. The
consequence was concrete: `SiftEngine` would have built its `Column`s from `"VARCHAR"`,
so a JSON column classified `.text`, and `chooseView` could then route it to the
**`highcard`** panel — near-unique text is exactly what a column of JSON documents looks
like. Fixing it in `ResultSet.init` fixes the classification everywhere downstream at
once. Covered by `DecodeTests.swift`'s `jsonColumnReportsTypeNameJSON` (paired with
`plainVarcharColumnStillReportsTypeNameVARCHAR` so the alias read can't just always
return `"JSON"`).

**Two `Session`s on one home silently corrupt each other — Plan 4 (the UI is what would
construct the second).** Measured 2026-08-09 during Plan 3 Task 6's review, independently by
two reviewers. Two `DuckDBKit.Database` handles opened on the same file *in one process* are
two independent DuckDB instances that cannot see each other's catalog: A inserts and
checkpoints, A sees 2, **B still sees 1**; B then inserts and has written its version over A's
file. Not a shared store with a coordination problem — two uncoordinated writers on one file,
last flush wins. Observed directly: `sharedStore a=true b=true; b sees a's table=0; a sees b's
table=0`.

The `sharedStore` fallback does **not** protect against this. It fires only on a DuckDB *lock*
error, and there is no lock error in-process — which is precisely why both sessions above
report `sharedStore=true`. The guard written for the cross-process case is silently inert for
the in-process one, and the per-PID `stage-<pid>.duckdb` fallback is consequently only ever
reachable across processes.

Nothing constructs two `Session`s today — the app builds exactly one. It becomes live the
moment a second exists on the same home: a multi-window or "new session" path, a preferences
change that rebuilds the engine, or a test suite that opens two on one home. **Plan 4 must not
add a second window without closing this first.** The fix is small — a process-wide set of open
home paths in `Session.init` that either throws or hands back the existing `Database`.

**`loadedExtensions[name] == false` conflates two failures — Plan 3.** A legal name with
no such extension installed, and a name rejected by the injection guard, both record
`false`. Spec §11 turns this dictionary into "a missing `delta` extension refuses the
open", so a caller cannot distinguish a missing binary from a typo in its own call.

**A mid-stream result error cannot be tested here — Plan 3 if streaming is adopted.**
`allRows()` throws if `duckdb_result_error` is set after the drain, which closes the
silent-truncation hole. But `duckdb_execute_prepared` materializes, so on the current
execution path nothing can fail after the first chunk and the branch is unreachable by
test. It becomes testable only if `Connection.query` moves to
`duckdb_execute_prepared_streaming`.

**`TIME_TZ` offsets drop sub-minute seconds — nobody, unless it bites.** `+15:59:59`
renders `+15:59`. Reachable only with historical LMT-style offsets.

**`Cell.decimal` carries its scale — Plan 2 must know the shape.**
`case decimal(Decimal, scale: Int)`. `Decimal` canonicalizes trailing zeros on
`description`, so without the scale riding along a `DECIMAL(10,2)` money column renders
`10.5` instead of `10.50`. Consequence for pattern-matching: `.decimal(1.5, scale: 2)`
and `.decimal(1.5, scale: 3)` are **not** equal, while two spellings of the same stored
value at the same scale are.

**`Session.page` blocks the whole actor while it materializes a sort — Plan 4 (grid) needs
to plan a spinner around it.** `page`, `sortedRelation` and `closeTable` deliberately
share one long-lived `Connection` (`SiftEngine/Session.swift` fact 3) rather than one
per call, because a materialized sort (`TEMP TABLE`) is visible only to the connection
that created it. That sharing is safe only because those three methods never suspend —
which also means the first sorted page over a large table (materializing up to
`sortMaterializeMax`, 5,000,000 rows) blocks every other actor call for however long
that takes: opening a second source, switching to another open table, and every
in-flight background scan's result all wait. Python ran this in a threadpool, where only
the calling request stalled. Documented on `page`'s own doc comment as a deliberate,
un-fixed cliff (Task 4 review I6) — the grid needs to show a busy state across that
window rather than assume paging is always instant.

---

## 14. Out of scope

- Distributing a signed binary. Releases stay source-only. Notarization needs an Apple Developer ID,
  and those credentials are Andrew's to handle. screenwren already carries a `workflow_dispatch`
  notarize workflow that could be copied later if wanted.

- **The Mac App Store, and therefore App Sandbox.** Sift reads paths the user names, which is what
  it is for; the sandbox exists to prevent exactly that. Two documented features die under it — the
  paste-a-path box (a typed path is not a user selection, so the sandbox denies it) and the SQL
  box's ability to read a file that is not already open.

  Recorded because the usual objections to sandboxing Sift do **not** survive this rewrite. The
  Python sidecar, the loopback HTTP server, and the ordeal of bundling a Python runtime all
  disappear, and the primary flows — Dock drop, Finder "Open With", File > Open — are user-selected
  and would be granted. In-process DuckDB reading a user-granted path is fine; a separate Python
  process reading it was the hard case. The native app is therefore far more sandbox-viable than the
  current one. It is still not worth doing.

  None of this affects the distribution path actually in use. screenwren notarizes for **Developer
  ID direct distribution** (`codesign` → `notarytool` → `stapler`), which requires the hardened
  runtime and no sandbox whatsoever. If Sift is ever signed, that is the route. One consequence to
  remember then: the bundled `libduckdb.dylib` must be signed too, or library validation rejects it
  at launch.

- A phone or remote companion. `PhotoServe` proves it is ~160 lines in latent, but nothing here
  needs it, and adding a server back is exactly what this rewrite removes.
- Any change to what Sift does. No new formats, no live database connector, no write path beyond the
  existing Export. The deliberate limits in the README stand.
