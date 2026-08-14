# AGENTS.md — Sift

Guidance for AI agents working inside `sift/`. Read this before editing. The narrative and
setup live in [README.md](README.md); this file is the working contract — what must not break, and
how to prove you didn't.

## What Sift is

A native Mac tool: drop a file in, explore it instantly. **One SwiftPM package, one binary** —
SwiftUI/AppKit window over a Swift engine (`Session`, an actor) over a vendored `libduckdb`.
No Python, no server, no web view: the 2026 rewrite deleted all three. DuckDB reads files
**in place**, so size is not the constraint. Sift touches **no live system** — local files only,
no credentials, no network egress. The only listener anywhere is `LoopbackHTTPServer` —
the test oracle for the remote-connections work — which binds 127.0.0.1 on an ephemeral
port, is started only by tests or `--verify`, and must never grow a wildcard bind.

## The one rule: tests are the spec

`Tests/**` is the source of truth for behavior — ~730 tests across `DuckDBKitTests`,
`SiftCoreTests`, `SiftEngineTests`, `SiftUITests`. **Never weaken a test to make a change
pass.** If a test pins a symbol or an output string, that is a contract, not an accident. The
suite runs fully **in parallel** and nothing is `.serialized`; a test that only passes
serialized is a bug in the test.

The house bar is **mutation**: when you add a guard, delete it on purpose and confirm its test
goes red. This branch caught 15+ tests that passed while guarding nothing; the discipline is not
optional. Temp paths go through `Tests/TestSupport`'s `TestTemp` — a bare
`FileManager.default.temporaryDirectory` write is how this suite once leaked 24 GB.

## How to build, test, verify — run these, don't assume

```bash
./scripts/fetch-duckdb.sh          # once, needs network — the pinned prebuilt libduckdb
swift build && swift test          # ~730 tests, ~30 s, warning-free is the bar
swift run sift --verify            # the engine end to end: 20 checks, every format
./build-app.sh                     # -> ./Sift.app; verify by MOVING it away from the repo
```

After any engine or UI change, exercise it end to end against a **multi-million-row file** —
several real bugs here were invisible on small files. The window cannot be screenshotted on this
machine (no Screen Recording); the working capture is `cacheDisplay(in:to:)` on a live `NSView`,
control-render-first. `ImageRenderer` is measurably unstable for pixel comparison — don't.

**CI on macos-15 is the only SDK oracle.** This Mac carries a newer SDK and has accepted code
the runner rejects (Sendable inference, system-color resolution) multiple times. Push and read
CI rather than trusting a local green build.

## Architecture, and where the state lives

- `Sources/SiftCore/` is **pure, Foundation-only** (enforced by the package graph): identifier
  quoting, SQL generation, the SELECT-only gate's pure half, format detection, profiling policy,
  staging policy, snippets. Logic goes here, where it costs milliseconds to test.
- `Sources/SiftEngine/Session.swift` is the **only** stateful module: an actor owning the
  catalog, background jobs, staging, profiling. Read its header before touching concurrency —
  the `pagingConnection` invariant (six users, no suspension between acquire and last use) is
  measured, load-bearing, and documented there.
- `Sources/DuckDBKit/` wraps the C API: `Database`, `Connection`, chunk decoding, `harden()`.
- `Sources/SiftUI/` is every view and view-model; `Sources/SiftApp/` is `@main` + menus +
  LaunchServices **and is untestable by construction** (a test target cannot import an
  executable target) — nothing with a decision in it goes there. Same for `Sources/sift/`
  (the CLI): logic lives in `SiftEngine/Verification.swift`.

## Frozen contracts — changing these breaks the app silently

- Security/safety: the SELECT-only guard **plus** the newline subquery-wrap (the wrap is the
  real enforcement — a keyword blocklist is not); `harden()`'s four settings incl. disabled
  network filesystems; `~/.sift` at `0700`; the atomic view→table swap; staged-data
  age-out/budget; one `Session` per home (`OpenHomes` — two on one home are two databases
  overwriting each other).
- Data truth: NULL vs `''` vs `'N/A'` stay distinct end to end (`allow_quoted_nulls=false`,
  `glyph(for:kind:)` — the UI never calls `Cell.display`); `ignore_errors` + `TRY_CAST`
  bad-row accounting; exact counts via the all-varchar relation, never a bare `count(*)` on
  the typed view; approx-distinct is clamped; a `_delta_log/` dir is read via `delta_scan`,
  never a raw parquet glob; cell rendering lives in the engine so the app and the CLI cannot
  disagree; no `NumberFormatter`/`DateFormatter`/`ISO8601DateFormatter` anywhere user-visible
  (four locale bugs shipped that way, one deleted user data).
- Every engine error is **one clean sentence** (`SiftError.description`) — never a parser dump,
  never swallowed with `try?`. That contract was broken and repaired four times; don't be five.

## DuckDB 1.5.5 facts this code depends on (re-verify before bumping the pin)

Pinned executable in `Tests/DuckDBKitTests/DuckDB155FactsTests.swift` and re-verified against
the vendored dylib — not folklore:

- `sniff_csv` reports an absent quote/escape/comment as the literal string `'(empty)'` —
  normalize before feeding it back to `read_csv`.
- `reject_scans()` / `reject_errors()` **do not exist**; bad rows are found with `TRY_CAST`
  against an all-varchar read.
- `count(*)` on a CSV view uses projection pushdown and ignores uncastable rows, so it
  disagrees with `SELECT *`. Count the all-varchar relation.
- `read_xlsx` takes `sheet =>` (not `sheet_name`) and can't list sheets — hence
  `XLSXSheets.swift` parsing the OOXML directly.
- Delta time travel is `version => n`; `AT (VERSION => n)` does not parse.
- The `delta` and `excel` extensions need one online `INSTALL` (`loadExtensions` does
  LOAD→INSTALL→LOAD); autoloading is deliberately off.
- `approx_count_distinct` overshoots (340 for 300 distinct) — clamped in the profile.
- `duckdb_tables().estimated_size` is a **row count, not bytes** — staged bytes are measured
  from storage blocks instead.
- `duckdb_interrupt` before execution starts is **swallowed**; cancelling means hammering it
  in a loop until the job reports stopped (`StageJob`).
- `sortedRelation`'s TEMP TABLE is visible only to the connection that created it — the reason
  `pagingConnection` exists at all.

## Style

Ponytail is on: prefer the shortest change that keeps behavior, delete over add, reuse what's
here. But never simplify away validation, security, error handling, or accessibility, and never
delete a comment that records a **measured fact** — compress it if you must, keep the fact.
Cuts, not churn: don't reformat code you're keeping, don't rename public symbols.
