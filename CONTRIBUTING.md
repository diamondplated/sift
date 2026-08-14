# Contributing to Sift

Thanks for looking. Sift is small on purpose, so the bar for new code is "does this earn its
maintenance cost" rather than "is this a nice idea".

## Getting set up

```bash
./scripts/fetch-duckdb.sh    # once, needs network — the pinned prebuilt libduckdb
swift build && swift test    # 910 declared (37 gated off), ~30 s
./build-app.sh               # -> ./Sift.app
```

That is the whole setup. No Python, no Node, no Xcode — SwiftPM and the Command Line Tools.
The `delta` and `excel` DuckDB extensions install themselves from DuckDB's own repository on
first use (one-time, needs network), and so do `httpfs` and `azure` the first time someone
saves a remote connection.

37 of those tests carry the `remoteFact` prefix and are gated behind `SIFT_REMOTE_FACTS=1` — the
ones allowed to `INSTALL` an extension, so the default run stays offline; CI runs them as a separate
step. If
you touch anything under `Remote`, `Connections`, `Keychain` or the remote half of `Session`,
run them and say so in the PR:

```bash
SIFT_REMOTE_FACTS=1 swift test --filter remoteFact
```

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
swift run sift --verify               # the engine end to end: 26 checks
```

`--verify` reaches nothing off your machine — its five remote checks run against a loopback
HTTP server it starts and stops itself. Four of them skip, with a sentence, on a machine where
`httpfs` is not already installed; they never install it, because a command you ran to check
your own install has no business making an outbound request.

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
- **`~/.sift` at `0700`**, the staged-data fingerprints, the age-out and the budget — and the
  same rules on `remote-cache/`, whose downloaded objects are `0600` and age out on the same
  clock. They are copies of someone's real data, not a cache of derived bytes.
- **The posture switch, and the honesty about what it cannot do.** `disabled_filesystems` only
  ever grows inside a live DuckDB database, so turning remote on or off changes the file and not
  this session's engine. `ConnectionOutcome` is a return value rather than a comment for exactly
  that reason. Do not "fix" it with a `SET`; it cannot work, and the failure mode is a user told
  remote is off while every read still succeeds.
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

`SECURITY.md` is the full statement and it is worth reading before you touch the remote path.
The short version: remote data is **off** until a user saves a connection, credentials live in
the Keychain and never in `connections.json` or `stage.duckdb`, a SAS query string is
memory-only for one open, and the only listener in the program is the loopback test oracle.

If you find something that breaks one of those, please report it privately via GitHub's security
advisory form rather than opening a public issue.
