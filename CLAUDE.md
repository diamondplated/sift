@AGENTS.md

## Where you can and cannot prove anything

Sift builds only on macOS: SwiftUI/AppKit in `SiftUI`/`SiftApp`, `Security` (Keychain) in
`SiftEngine`, and `fetch-duckdb.sh` pulls `libduckdb-osx-universal`. A Claude Code cloud session is
a Linux container with no Swift toolchain, and its proxy refuses `download.swift.org`, so there is
no `swift build`, no `swift test` and no `--verify` there. There is deliberately no SessionStart
hook: one could only pretend.

In a cloud session, then: read and edit, push a branch, open a draft PR, and let CI be the oracle.
Never write "tests pass" from a cloud session; say CI is the only run and link it.

Land changes through a PR: CI runs on PRs and pushes to `main`, on a self-hosted Mac that is also
someone's desktop, and loopback-HTTP tests flake under its load (#5). A red run in an area the
diff never touched is worth one re-run before it is worth a diagnosis.
