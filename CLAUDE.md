@AGENTS.md

## Where you can and cannot prove anything

Sift builds only on macOS: SwiftUI/AppKit in `SiftUI`/`SiftApp`, `Security` (Keychain) in
`SiftEngine`, and `fetch-duckdb.sh` pulls `libduckdb-osx-universal`. A Claude Code cloud session is
a Linux container with no Swift toolchain, and its proxy refuses `download.swift.org`, so there is
no `swift build`, no `swift test` and no `--verify` there. There is deliberately no SessionStart
hook: one could only pretend.

In a cloud session, then: read and edit, push a branch, open a draft PR, and let CI be the oracle.
Never write "tests pass" from a cloud session; say CI is the only run and link it.

## Where AGENTS.md has drifted

- CI no longer runs on GitHub-hosted `macos-15`. Since #3 it runs on a self-hosted MacBook Air
  (`runs-on: [self-hosted, macOS, air]`) carrying the macOS 26 SDK, which is someone's desktop.
  Loopback-HTTP tests flake under its load (#5); a red run on an untouched area is worth one
  re-run before it is worth a diagnosis.
- CI runs on `pull_request` and on pushes to `native`, a branch that no longer exists. A direct
  push to `main` runs nothing, so land changes through a PR.
- The default branch is `main`.
