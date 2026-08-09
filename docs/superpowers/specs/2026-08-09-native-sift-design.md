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
  Vendor/duckdb/                    fetched, gitignored — libduckdb.dylib + duckdb.h + module.modulemap
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
from DuckDB's GitHub release, verifies a hardcoded SHA-256, and unpacks `libduckdb.dylib` and
`duckdb.h` into `Vendor/duckdb/`. The checksum is pinned in the script.

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
  loads extensions.
- `Connection` — owns `duckdb_connection`. The direct analogue of Python's `con.cursor()`: shares
  the catalog and buffer manager, owns its transaction. **Not `Sendable`**; each unit of work
  creates its own and never shares it across tasks.
- `Statement` — `duckdb_prepare` plus typed `bind` calls, driven by a `DBValue` enum
  (`null | bool | int64 | double | string`) matching what `sqlgen` produces as parameters.
- `Chunk` — decodes a `duckdb_data_chunk` into Swift values, honoring the validity bitmask.

`Connection.interrupt()` wraps `duckdb_interrupt`, preserving the cancel path that `Session.cancel`
depends on today.

### Type decoding

The chunk decoder must cover every type `kind_of` classifies. Two need explicit care:

- **`HUGEINT` / `UHUGEINT`** — 128-bit, delivered as a `duckdb_hugeint` struct of `lower: UInt64` /
  `upper: Int64`. Decoded to a Swift `String` via manual 128-bit division, since Swift has no native
  `Int128` on the pinned toolchain.
- **`DECIMAL`** — carries width and scale in the logical type, separate from the value. Decoded to
  `Decimal` using the scale from `duckdb_decimal_scale`, never through `Double`.

`BLOB` renders as `<blob N B>` exactly as `jsonable` does today. Nested types (`STRUCT`, `LIST`,
`MAP`, `UNION`, `JSON`) decode to their DuckDB string representation, matching current behavior.

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
| `core/ident.py` | `SiftCore/Ident.swift` | NFKD normalization via `String.decomposedStringWithCanonicalMapping` |
| `core/guard.py` | `SiftCore/Guard.swift` | Unchanged in behavior — still only a message improver |
| `core/sqlgen.py` | `SiftCore/SQLGen.swift` | Returns `(String, [DBValue])`. The newline subquery wrap is preserved byte-for-byte |
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
