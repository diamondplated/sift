<h1 align="center">Sift</h1>

<p align="center"><strong>Drop a file in. Explore it instantly.</strong></p>

<p align="center">
  A native Mac explorer for data files — schema, profile, grid, and distinct values,<br>
  on files far too big to open any other way.
</p>

<p align="center">
  <a href="https://github.com/diamondplated/sift/actions/workflows/ci-native.yml"><img src="https://github.com/diamondplated/sift/actions/workflows/ci-native.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/DuckDB-1.5.5-yellow.svg" alt="DuckDB 1.5.5">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#what-it-opens">Formats</a> ·
  <a href="#what-you-get">Features</a> ·
  <a href="#things-that-are-the-way-they-are-for-a-reason">Design notes</a> ·
  <a href="SECURITY.md">Security</a> ·
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

- ⚡ **Instant at any size.** Opening is a view over the file, not a read of it. A 6-million-row
  parquet opens with its exact count in under a second — the count comes free from the footer.
- 🔍 **Answers, not rows.** Schema, per-column profile, and top values with counts and share.
- 🔒 **Nothing leaves your machine.** No server, no cloud, no credentials, no telemetry, no
  network egress. One process, one binary; there is no port because there is nothing listening.
- 🧠 **Honest about your data.** `NULL`, `''`, and `'N/A'` stay three different things. Rows the
  parser dropped get counted and shown, not silently discarded. A file whose column structure
  collapsed says so in a sentence, with a one-click way to recover it.

---

## Quick start

```bash
./scripts/fetch-duckdb.sh           # once, needs network — the pinned prebuilt libduckdb
./build-app.sh /Applications        # builds Sift.app and installs it
```

Drag a file onto the Dock icon, double-click a `.parquet`, or right-click → **Open With → Sift**.

The app is self-contained: libduckdb is copied inside the bundle, so it keeps working with this
checkout deleted. There is also a CLI:

```bash
swift run sift ~/Desktop/orders.csv    # schema + first rows at your terminal
swift run sift --verify                # the engine proving itself: 20 checks, every format
```

**Requirements:** macOS 14+. No Xcode needed — everything builds with SwiftPM and the Command Line
Tools. No Python, no Node, no third-party Swift dependencies. None.

---

## What it opens

| Format | Notes |
|---|---|
| **CSV / TSV** | dialect, header and types sniffed; whole-file sniff under 50 MB |
| **`.csv.gz`, `.zst`** | works, but no row estimate — compressed bytes say nothing about row count |
| **Parquet** | exact row count and per-column stats free from the footer |
| **Folder of parquet/CSV** | one globbed table, hive partitions detected, `filename` provenance kept |
| **Delta table** | read through the transaction log, so tombstoned rows stay deleted |
| **JSON / NDJSON** | `read_json_auto` handles both |
| **`.xlsx` / `.xlsm`** | sheet picker with per-sheet dimensions. `.xls` is refused with a "re-save" message |

---

## What you get

**The distinct-values panel.** Top values with counts and share-of-rows. Click to filter, ⌘-click
to multi-select, right-click to exclude. It ignores its own column's filter, so every value stays
visible with the selected ones highlighted.

**Three kinds of missing.** `NULL`, empty string, and `'N/A'` render differently in the grid and are
counted separately in the profile — because in real data feeds they mean three different problems,
and every tool that flattens them into one costs you an afternoon later.

**The rows your file lost.** If a value won't cast to its column's type, DuckDB drops the row. Sift
counts those independently and shows you the offending cells. Nothing disappears quietly — and a
ragged CSV that would silently collapse into one column tells you, with a re-open button that
recovers the real columns.

**Real numbers.** `BIGINT` and `DECIMAL` render exactly — there is no JavaScript in the building to
round them. `10.50` stays `10.50`.

**A SQL box that cannot write.** Run any `SELECT` against what's open. The enforcement isn't a
keyword blocklist (see [below](#things-that-are-the-way-they-are-for-a-reason)).

**Merge, export, and staged-data management** — including one screen that answers "what is this
tool holding on to", with sizes, last-used times, and a purge button.

---

## Layout

```
sift/
  build-app.sh          builds Sift.app (icon drawn with the Cocoa that ships in macOS)
  scripts/fetch-duckdb.sh   downloads + checksum-verifies the pinned libduckdb
  Sources/
    CDuckDB/            the module map over duckdb.h
    DuckDBKit/          Swift over the C API: Database, Connection, chunk decoding
    SiftCore/           pure, Foundation-only: SQL generation, gates, policy
    SiftEngine/         Session — the one actor holding all state
    SiftUI/             every view and view model
    SiftApp/            @main, menus, LaunchServices — nothing with a decision in it
    sift/               the CLI
  Tests/                ~730 tests; the spec
```

`SiftCore` is pure on purpose — importable with no connection and no state, which is why most of
the suite runs in milliseconds:

```bash
swift test          # ~730 tests, ~30 s, fully parallel
```

---

## Things that are the way they are for a reason

<details>
<summary><strong>Native, with no web view in the building</strong></summary><br>

Sift 1.x was a Python engine behind a local web UI. The rewrite deleted the server, the browser,
and the Python — not for fashion: an HTML5 file drop withholds the file's real path, browsers clamp
scroll height (~17.8M px in Safari, silently broken past ~800k rows at 27 px/row), and JS `Number`
rounds integers past 2^53. `NSTableView` asks only for visible rows, LaunchServices hands over real
paths, and `Int64` is `Int64`. Porting also surfaced seven real bugs in the shipping engine —
including sorted paging that threw on page 2 — all fixed in the Swift.
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
**Staged**, ages out after 14 days, and is capped at 20 GB. A staged copy is fingerprinted against
its source — including a folder's individual members, and a timestamp a rewrite can't fake — so a
stale copy is collected, never served. One screen answers "what is this tool holding on to."
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

Verified by probe, pinned executable in `Tests/DuckDBKitTests/DuckDB155FactsTests.swift`; re-run
before bumping the pin.

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
- `read_xlsx` takes `sheet =>` (not `sheet_name`), and cannot list sheets — Sift parses the OOXML
  itself.
- `approx_count_distinct` can exceed the row count (340 for 300 distinct), so it is clamped.
- `duckdb_tables.estimated_size` is estimated **rows**, not bytes.
- `duckdb_interrupt` issued before execution starts is silently swallowed — cancelling a running
  query means re-asserting it in a loop.
</details>

---

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SIFT_HOME` | `~/.sift` | staged data (created 0700) |
| `SIFT_STAGE_BUDGET_GB` | `20` | staged-data ceiling |
| `SIFT_STAGE_MAX_AGE_DAYS` | `14` | age-out for staged tables |

---

## Deliberate limits

Sift is a file explorer, not a warehouse client:

- It reads local files only. There is no connector for a live database, by design.
- It never writes to your source files. Sources are opened read-only; export refuses to overwrite.
- Compressed CSV gives no row estimate until it is read — compressed bytes say nothing about rows.
- `.xls` (the pre-2007 format) is refused rather than half-supported; re-save as `.xlsx`.
- A sorted view reaches its first 5,000,000 rows and says so — a named limit, not a silent one.
- One machine, one user, one window. No server mode, no auth model, because adding one would
  change what this is.

---

## License

[MIT](LICENSE).

Sift bundles no third-party code at all: the only runtime dependency is DuckDB (MIT), vendored as
the prebuilt `libduckdb` with a pinned checksum. The `delta` and `excel` DuckDB extensions are
downloaded from DuckDB's own extension repository on first use.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: `Tests/**` is the spec, and it is
read-only — never weaken a test to make a change pass.
