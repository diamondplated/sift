# AGENTS.md — Sift

Guidance for AI agents working inside `sift/`. Read this before editing. The narrative and
setup live in [README.md](README.md); this file is the working contract — what must not break, and
how to prove you didn't.

## What Sift is

A local Mac tool: drop a file in, explore it instantly. A **Swift + WKWebView shell** (native
window, vibrant sidebar, toolbar) over a **FastAPI + DuckDB engine** it runs as a sidecar, with the
UI as one hand-written `web/index.html`. DuckDB reads files **in place**, so size is not the
constraint. Sift touches **no live system** — local files only, no credentials, no network egress,
bound to `127.0.0.1`.

## The one rule: tests are the spec

Nearly all of that ~28 s is two DuckDB-bound tests (timezone data load ~18 s, Delta fixture ~9 s);
216 of the 218 are under 10 ms. `-k "not delta and not timestamptz"` is the `core/` loop at ~10 s —
the floor is the session fixture's extension load, not the tests.

`engine/tests/**` is the source of truth for engine behavior. It is **read-only** — never weaken a
test to make a change pass. If a test pins a symbol or output string, that is a contract, not an
accident (several tests import internals like `core.sqlgen._safe_type`). Behavior parity is the
bar for any refactor.

## How to build, test, verify — run these, don't assume

```bash
cd sift
.venv/bin/python -m pytest engine/tests -q                 # 218 tests, ~28s. Must stay green.
.venv/bin/python -c "import sys;sys.path.insert(0,'engine');import app;print(len(app.app.routes))"
sed -n '/^<script>/,/^<\/script>/p' web/index.html | sed '1d;$d' | node --check /dev/stdin
( cd shell && swift build -c release )                     # native shell; no Xcode needed
./build-app.sh                                             # -> ./Sift.app, then relaunch it
```
The web layer is identical in browser mode (`dev.sh`, `NATIVE=false`) and the native shell, so
verify UI logic in the browser preview; the native window can't be screenshotted here. After any
engine or web change, exercise it end to end — don't trust a green unit run alone.

## Architecture, and where the state lives

- `engine/core/**` is **pure**: importable with no connection, no server, no module-level mutable
  state. Identifier quoting, SQL generation, the SELECT-only gate, format detection, profiling,
  staging policy, snippets. This is where logic goes and where it's cheap to test.
- `engine/session.py` is the **only** stateful module: the one DuckDB connection, the catalog of
  open tables, background jobs, SSE fan-out. Every request handler takes `con.cursor()` (the
  connection is not thread-safe).
- `engine/app.py` is thin: request → core/session call → JSON. Also the CLI + `--sidecar` mode.
- `web/index.html` is the whole UI, no build step. `shell/` is the native window (Swift, zero deps).

## Frozen contracts — changing these breaks the app silently

- Every HTTP path + JSON shape in `app.py`; the `__SIFT_TOKEN__` / `__SIFT_MAX_UPLOAD_MB__` /
  `__SIFT_NATIVE__` page placeholders; the `window.sift*` JS bridge functions; the sidecar stdout
  handshake `{port, token}`; the `WKScriptMessageHandler` `"sift"` message shapes.
- Security/safety: the SELECT-only guard **plus** the newline subquery-wrap (that wrap is the real
  enforcement — a keyword blocklist is not); disabled network filesystems; per-launch token + Host
  pinning; `127.0.0.1`-only bind; `~/.sift` at `0700`; spill sweep; the parent-death watcher;
  the atomic view→table swap; staged-data age-out/budget.
- Data truth: NULL vs `''` vs `'N/A'` stay distinct (`allow_quoted_nulls=false`); `ignore_errors`
  + `TRY_CAST` bad-row accounting; exact counts via the all-varchar relation, never a bare
  `count(*)` on the typed view; wide ints / decimals cross the wire as **strings**; approx-distinct
  is clamped; a `_delta_log/` dir is read via `delta_scan`, never a raw parquet glob.

## DuckDB 1.5.5 facts this code depends on (re-verify before bumping the pin)

- `sniff_csv` reports an absent quote/escape/comment as the literal string `'(empty)'` — normalize
  it to `''` before feeding it back to `read_csv`.
- `reject_scans()` / `reject_errors()` **do not exist**; bad rows are found with `TRY_CAST` against
  an all-varchar read instead.
- `count(*)` on a CSV view uses projection pushdown and ignores uncastable rows, so it disagrees
  with `SELECT *`. Count the all-varchar relation.
- `read_xlsx` takes `sheet =>` (not `sheet_name`) and can't list sheets — hence openpyxl.
- `pytz` is **required**: without it, fetching a `TIMESTAMP WITH TIME ZONE` value raises.
- Delta time travel is `version => n`; `AT (VERSION => n)` does not parse.
- The `delta` and `excel` extensions need one online `INSTALL`; autoloading is deliberately off.

## Style

Ponytail is on: prefer the shortest change that keeps behavior, delete over add, reuse what's here.
But never simplify away validation, security, error handling, or accessibility, and never delete a
comment that records a **measured fact** (the probe results above) — compress it if you must, keep
the fact. Cuts, not churn: don't reformat code you're keeping, don't rename public symbols.
