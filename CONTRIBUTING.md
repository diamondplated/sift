# Contributing to Sift

Thanks for looking. Sift is small on purpose, so the bar for new code is "does this earn its
maintenance cost" rather than "is this a nice idea".

## Getting set up

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt -r requirements-dev.txt
# Once, needs network. Extension binaries are per-DuckDB-version, so repeat after a version bump.
.venv/bin/python -c "import duckdb; c=duckdb.connect(); [c.execute(f'INSTALL {e}') for e in ('delta','excel')]"
```

Then either `./dev.sh` for browser mode on <http://127.0.0.1:8642>, or `./build-app.sh` for the
native `.app`. The web layer is byte-identical in both, so UI work is easier to iterate in the
browser.

## The one rule: tests are the spec

`engine/tests/**` is the source of truth for engine behavior. **Never weaken a test to make a change
pass.** If a test pins a symbol name or an output string, that is a contract, not an accident —
several tests deliberately import internals like `core.sqlgen._safe_type`. If you believe a test is
wrong, say so in the PR and argue it; don't quietly edit it.

```bash
.venv/bin/python -m pytest engine/tests -q
```

216 of the 218 tests run in under 10 ms each, because `engine/core/**` is pure — no connection, no
server, no module-level mutable state. Keep it that way: logic belongs in `core/`, where it costs
milliseconds to test. `engine/session.py` is the only stateful module.

The full run is ~28 s, almost entirely two tests that must go through DuckDB (timezone data for the
`TIMESTAMP WITH TIME ZONE` round-trip at ~18 s, and building the Delta fixture at ~9 s). While
iterating on `core/`, skipping both roughly halves it — the remaining ~10 s is the one-time
extension load in the session fixture, not the tests themselves:

```bash
.venv/bin/python -m pytest engine/tests -q -k "not delta and not timestamptz"   # 207 passed, ~10s
```

## Before you open a PR

```bash
.venv/bin/python -m pytest engine/tests -q                  # must be green
sed -n '/^<script>/,/^<\/script>/p' web/index.html | sed '1d;$d' | node --check /dev/stdin
( cd shell && swift build -c release )                      # if you touched shell/
```

Then actually run it end to end. A green unit run is not evidence the app works — several of the
subtle bugs in this codebase's history were only visible with a real multi-million-row file open.
If you touched the grid, test against a large file; the scroll-height bug is invisible under
~800k rows.

## Things not to simplify away

These look like complexity and are not. `AGENTS.md` has the full list and the reasoning; the short
version:

- **The SELECT-only guard plus the newline subquery wrap.** The wrap is the real enforcement, not
  the keyword check. Don't "simplify" it into a blocklist.
- **NULL vs `''` vs `'N/A'` staying distinct** (`allow_quoted_nulls=false`).
- **Wide ints and decimals crossing the wire as strings.** JS `Number` silently rounds past 2^53.
- **Bad-row accounting via `TRY_CAST`** against an all-varchar read, and exact counts from that
  same relation — never a bare `count(*)` on the typed view.
- **The per-launch token, Host pinning, `127.0.0.1`-only bind, and `~/.sift` at `0700`.**

Comments that record a **measured fact** — the DuckDB probe results in `README.md` and
`requirements.txt` — stay. Compress them if you must, but keep the fact. They exist because someone
already lost an afternoon to that behavior.

## Style

Prefer the shortest change that keeps behavior. Delete over add, reuse what's here. Don't reformat
code you're only passing through, and don't rename public symbols without a reason.

Never simplify away validation, security, error handling, or accessibility.

## Reporting bugs

Include the DuckDB version, the file format, and roughly how big the file is — most interesting
bugs here are size- or format-dependent. If you can, say whether it reproduces in browser mode
(`./dev.sh`) or only in the `.app`; that splits the search space immediately.

## Security

Sift reads local files, binds to loopback, and disables network filesystems. If you find something
that breaks one of those properties, please report it privately via GitHub's security advisory
form rather than opening a public issue.
