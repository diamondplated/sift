# Contributing to Sift

Thanks for looking. Sift is small on purpose, so the bar for new code is "does this earn its
maintenance cost" rather than "is this a nice idea".

## Getting set up

```bash
./scripts/fetch-duckdb.sh    # once, needs network — the pinned prebuilt libduckdb
swift build && swift test    # ~730 tests, ~30 s
./build-app.sh               # -> ./Sift.app
```

That is the whole setup. No Python, no Node, no Xcode — SwiftPM and the Command Line Tools.
The `delta` and `excel` DuckDB extensions install themselves from DuckDB's own repository on
first use (one-time, needs network).

## The one rule: tests are the spec

`Tests/**` is the source of truth for behavior. **Never weaken a test to make a change pass.**
If a test pins a symbol name or an output string, that is a contract, not an accident. If you
believe a test is wrong, say so in the PR and argue it; don't quietly edit it.

Two disciplines this suite runs on:

- **Everything runs in parallel and nothing is `.serialized`.** A test that only passes
  serialized is a bug in the test. Temp paths go through `Tests/TestSupport`'s `TestTemp` —
  a bare temp-directory write is how this suite once leaked 24 GB onto a developer's disk.
- **Guards get mutation-tested.** When you add a guard, delete it on purpose and confirm its
  test goes red before you call it covered. This project has caught more than fifteen tests
  that passed while guarding nothing; several were render tests asserting on the wrong pixels.

## Before you open a PR

```bash
swift build 2>&1 | grep -c warning:   # must be 0 — warning-free is the bar, not a nicety
swift test                            # must be green
swift run sift --verify               # the engine end to end: 20 checks
```

Then actually run it end to end. A green unit run is not evidence the app works — several of the
subtle bugs in this codebase's history were only visible with a real multi-million-row file open.
If you touched the grid or the sort, test against a large file with a *non-unique* sort column;
more than one real bug here was invisible on unique keys.

One more oracle: **CI runs macos-15, and your Mac's SDK is probably newer.** Code that compiles
locally has failed there repeatedly (stricter Sendable inference, different system-color
resolution). Treat a local green build as provisional until CI agrees.

## Things not to simplify away

These look like complexity and are not. `AGENTS.md` has the full list and the reasoning; the
short version:

- **The SELECT-only guard plus the newline subquery wrap.** The wrap is the real enforcement,
  not the keyword check. Don't "simplify" it into a blocklist.
- **NULL vs `''` vs `'N/A'` staying distinct**, end to end — `allow_quoted_nulls=false` in the
  engine, `glyph(for:kind:)` in the UI. The UI never calls `Cell.display`; that is what keeps
  the three states apart on screen.
- **Bad-row accounting via `TRY_CAST`** against an all-varchar read, and exact counts from that
  same relation — never a bare `count(*)` on the typed view.
- **`~/.sift` at `0700`**, the staged-data fingerprints, the age-out and the budget.
- **One `Session` per home.** Two on one home are two databases silently overwriting each other;
  the refusal is load-bearing.
- **No `NumberFormatter`/`DateFormatter`/`ISO8601DateFormatter`** anywhere a user can see. Four
  locale bugs shipped that way; one deleted user data.

Comments that record a **measured fact** — the DuckDB probe results in `README.md` and
`AGENTS.md` — stay. Compress them if you must, but keep the fact. They exist because someone
already lost an afternoon to that behavior.

## Style

Prefer the shortest change that keeps behavior. Delete over add, reuse what's here. Don't reformat
code you're only passing through, and don't rename public symbols without a reason.

Never simplify away validation, security, error handling, or accessibility.

## Reporting bugs

Include the file format and roughly how big the file is — most interesting bugs here are size- or
format-dependent. `swift run sift <path>` output is a great attachment: it shows the schema Sift
inferred and what the engine thinks of the file, with no window in the way.

## Security

Sift reads local files, runs no server, and disables network filesystems. If you find something
that breaks one of those properties, please report it privately via GitHub's security advisory
form rather than opening a public issue.
