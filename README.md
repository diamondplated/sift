<h1 align="center">Sift</h1>

<p align="center"><strong>Drop a file in. Explore it instantly.</strong></p>

<p align="center">
  A local Mac explorer for data files — schema, profile, grid, and distinct values,<br>
  on files far too big to open any other way.
</p>

<p align="center">
  <a href="https://github.com/diamondplated/sift/actions/workflows/ci.yml"><img src="https://github.com/diamondplated/sift/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg" alt="macOS">
  <img src="https://img.shields.io/badge/DuckDB-1.5.5-yellow.svg" alt="DuckDB 1.5.5">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#what-it-opens">Formats</a> ·
  <a href="#what-you-get">Features</a> ·
  <a href="#things-that-are-the-way-they-are-for-a-reason">Design notes</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

![Sift showing a 2.5-million-row parquet file: the grid on the left, and the distinct-values panel
on the right listing N/A, EMPTY and NULL as three separate entries with their own
counts](docs/screenshot.png)

---

## The 4 GB problem

Someone sends you a file. To find out what's in it you open a notebook, write `pd.read_csv`, guess
at dtypes, and run `value_counts()` by hand. If the file is 4 GB, pandas wants ~11 GB of RAM before
it will show you a single row.

Sift skips all of that. DuckDB reads the file **in place**, so nothing is loaded, copied, or
imported — a 20 GB CSV opens as fast as a 2 MB one, and never has to fit in memory.

- ⚡ **Instant at any size.** Opening is a view over the file, not a read of it.
- 🔍 **Answers, not rows.** Schema, per-column profile, and top values with counts and share — in
  one pass, in milliseconds. The screenshot above is 2.5 million rows profiled in 49 ms.
- 🔒 **Nothing leaves your machine.** No database, no cloud, no credentials, no telemetry, no
  network egress. Bound to `127.0.0.1` and staying there.
- 🧠 **Honest about your data.** `NULL`, `''`, and `'N/A'` stay three different things. Rows the
  parser dropped get counted and shown, not silently discarded.

---

## Quick start

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt -r requirements-dev.txt
# Once, needs network. Extension binaries are per-DuckDB-version, so repeat after a version bump.
.venv/bin/python -c "import duckdb; c=duckdb.connect(); [c.execute(f'INSTALL {e}') for e in ('delta','excel')]"
./build-app.sh /Applications        # builds Sift.app and installs it
```

Drag a file onto the Dock icon, or right-click a `.parquet` → **Open With → Sift**.

Prefer a browser? `./dev.sh` serves the same UI on <http://127.0.0.1:8642>.

**Requirements:** macOS 13+, Python 3.12+. No Xcode needed — the native shell builds with SwiftPM.

---

## What it opens

| Format | Notes |
|---|---|
| **CSV / TSV** | dialect, header and types sniffed; whole-file sniff under 50 MB |
| **`.csv.gz`, `.zst`** | works, but no row estimate — compressed bytes say nothing about row count |
| **Parquet** | exact row count and per-column stats free from the footer |
| **Folder of parquet** | one globbed table, hive partitions detected, `filename` provenance kept |
| **Delta table** | read through the transaction log, so tombstoned rows stay deleted |
| **JSON / NDJSON** | `read_json_auto` handles both |
| **`.xlsx`** | sheet picker with per-sheet dimensions. `.xls` is refused with a "re-save" message |

---

## What you get

**The distinct-values panel.** Top values with counts and share-of-rows in a single pass. Click to
filter, ⌘-click to multi-select, right-click to exclude. It ignores its own column's filter, so
every value stays visible with the selected ones highlighted.

**Three kinds of missing.** `NULL`, empty string, and `'N/A'` render differently in the grid and are
counted separately in the profile — because in real data feeds they mean three different problems,
and every tool that flattens them into one costs you an afternoon later.

**The rows your file lost.** If a value won't cast to its column's type, DuckDB drops the row. Sift
counts those independently and shows you the offending cells. Nothing disappears quietly.

**Numbers that survive the trip.** `BIGINT` and `DECIMAL` cross the wire as strings, because JS
`Number` silently rounds past 2^53 — and an order id is exactly the sort of thing that would corrupt.

**A SQL box that cannot write.** Run any `SELECT` against what's open. The enforcement isn't a
keyword blocklist (see [below](#things-that-are-the-way-they-are-for-a-reason)).

**Merge, export, and staged-data management** — including one screen that answers "what is this tool
holding on to", with sizes, last-used times, and a purge button.

---

## Layout

```
sift/
  dev.sh              browser mode on 127.0.0.1:8642
  build-app.sh        builds Sift.app (icon drawn with the Cocoa that ships in macOS)
  bin/sift-open       CLI; starts the engine or hands off to a running one
  engine/
    app.py            FastAPI routes, CLI, sidecar mode
    session.py        the only stateful module: connection, catalog, jobs, SSE
    core/             pure — importable with no connection, no server, no global state
  shell/              SwiftPM package: the native window (no Xcode needed)
  web/index.html      the whole UI, no build step
```

`core/` is pure on purpose: identifier sanitation, SQL generation, the SELECT-only gate, staging
policy and panel selection are all testable in milliseconds without fixtures.

```bash
.venv/bin/python -m pytest engine/tests -q      # 218 tests
```

216 of those 218 finish in under 10 ms each, which is the point of keeping `core/` pure. The ~28 s
wall clock is almost entirely two tests that have to go through DuckDB itself: loading timezone data
for the `TIMESTAMP WITH TIME ZONE` round-trip (~18 s) and building the Delta fixture (~9 s).
Skipping both gets you to ~10 s — the floor is the one-time extension load in the session fixture,
not the tests:

```bash
.venv/bin/python -m pytest engine/tests -q -k "not delta and not timestamptz"   # 207 passed, ~10s
```

---

## Things that are the way they are for a reason

<details>
<summary><strong>The <code>.app</code> is not cosmetic</strong></summary><br>

An HTML5 file drop yields a `File` object with no filesystem path — WebKit withholds it
deliberately. DuckDB needs a real path to read in place, so a browser-only tool would have to copy
multi-GB files before showing anything. LaunchServices hands over the real path. That is what makes
"20 GB opens as fast as 2 MB" true.

In the browser, drops under 512 MB are copied to a spill file and badged as such; above that Sift
refuses and points at the app or the paste-a-path box (⌥⌘C in Finder copies a POSIX path).
</details>

<details>
<summary><strong>The engine is Python, and the window is Swift</strong></summary><br>

DuckDB's Swift binding publishes no stable release tags — every tag is a `-dev` prerelease, which
SwiftPM's resolver ignores — and vendors a 400-file C++ amalgamation. Keeping DuckDB in Python means
the data layer stays editable without a C++ toolchain in the loop. The shell is ~700 lines of AppKit
with zero dependencies.
</details>

<details>
<summary><strong>The grid caps its own scroll height</strong></summary><br>

Browsers clamp element height (~33.5M px Chrome, ~17.8M Safari). At 27 px/row a naive spacer breaks
silently past ~800k rows: the thumb stops tracking and rows repeat. Above the cap, scroll position
maps as a *fraction* and the wheel is handled separately.

Develop against a multi-million-row file, never a 10k-row CSV — the bug is invisible on small files.
</details>

<details>
<summary><strong>Staging is the second step, never the first</strong></summary><br>

A view over the file is instant at any size. The background `CREATE TABLE AS SELECT` only fires for
CSV/JSON above 25 MB, and only after you have run an aggregate or dwelled a few seconds — a drive-by
header peek should not pay for a 20 s copy. Parquet, globs and Delta are never staged.
</details>

<details>
<summary><strong>Staged data is still your data</strong></summary><br>

It lives in `~/.sift/stage.duckdb` (mode 0700), is listed with sizes and last-used times under
**Staged**, ages out after 14 days, and is capped at 20 GB. One screen answers "what is this tool
holding on to", which is the question you want answerable when the files you opened were sensitive.
</details>

<details>
<summary><strong>The SQL box cannot write</strong></summary><br>

The enforcement is not a keyword blocklist — it is that user SQL is wrapped as
`SELECT * FROM (\n …\n) AS _q`, and `DROP`/`COPY`/`ATTACH`/`PRAGMA`/`SET` cannot occupy a subquery
position, so they die in DuckDB's parser. Network filesystems are disabled, so a `SELECT` cannot
exfiltrate.

A `SELECT` *can* still read any local file you could `cat` — accepted, because Sift never owns the
only copy of anything: sources are read-only and staged tables are rebuildable.
</details>

<details>
<summary><strong>DuckDB 1.5.5 specifics this code depends on</strong></summary><br>

Verified by probe; re-run `engine/tests` before bumping the pin.

- `sniff_csv` reports an absent quote/escape/comment as the literal string `'(empty)'`. Passing that
  back into `read_csv` fails with "cannot exceed a size of 1 byte".
- `reject_scans()` / `reject_errors()` **do not exist**, and `store_rejects` produces no queryable
  table. Bad cells are found with `TRY_CAST` against an all-varchar read instead — which is better
  anyway, because it names the column and shows the value.
- `count(*)` on a CSV view is answered by projection pushdown *without parsing any column*, so with
  an uncastable value present it disagrees with what `SELECT *` returns. Row counts therefore run
  against the all-varchar relation.
- `allow_quoted_nulls` defaults to true, which reads a quoted `""` as NULL and makes it
  indistinguishable from a missing value. Sift sets it false.
- `delta_scan` honors tombstones. Time travel is `version => n`; `AT (VERSION => n)` does not parse.
- `read_xlsx` takes `sheet =>` (not `sheet_name`), and cannot list sheets — hence openpyxl.
- `pytz` is required, not optional: without it, fetching any `TIMESTAMP WITH TIME ZONE` raises.
- `approx_count_distinct` can exceed the row count (340 for 300 distinct), so it is clamped.
- `duckdb_tables.estimated_size` is estimated **rows**, not bytes.
</details>

---

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SIFT_PORT` | `8642` | browser mode only; the native shell uses a kernel-assigned port |
| `SIFT_HOME` | `~/.sift` | staged data, spill, auth token (created 0700) |
| `SIFT_STAGE_BUDGET_GB` | `20` | staged-data ceiling |
| `SIFT_STAGE_MAX_AGE_DAYS` | `14` | age-out for staged tables |
| `SIFT_MAX_UPLOAD_MB` | `512` | ceiling on the pathless browser-drop copy |
| `SIFT_ROOT` | — | engine location override, for running the shell from source |

---

## Deliberate limits

Sift is a file explorer, not a warehouse client:

- It reads local files only. There is no connector for a live database, by design.
- It never writes to your source files. Sources are opened read-only.
- Compressed CSV gives no row estimate until it is read — compressed bytes say nothing about rows.
- `.xls` (the pre-2007 format) is refused rather than half-supported; re-save as `.xlsx`.
- One machine, one user. There is no server mode and no auth model beyond loopback + a per-launch
  token, because adding one would change what this is.

---

## License

[MIT](LICENSE).

Sift bundles no third-party data or models. It depends on DuckDB (MIT), FastAPI (MIT), Uvicorn
(BSD-3-Clause), openpyxl (MIT) and pytz (MIT); the `delta` and `excel` DuckDB extensions are
downloaded from DuckDB's own extension repository on first run.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: `engine/tests/**` is the spec, and it is
read-only — never weaken a test to make a change pass.
