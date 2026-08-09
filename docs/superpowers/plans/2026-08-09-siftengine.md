# SiftEngine Implementation Plan (Native Sift, Plan 3 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `engine/session.py` — the one stateful module — plus the connection-needing half of `source.py` and `guard.py`, into a Swift actor, and add the `sift` CLI that verifies the whole engine headlessly. At the end of this plan the engine works end to end with no Python and no UI.

**Architecture:** `SiftEngine` is a library target depending on `SiftCore` (pure logic) and `DuckDBKit` (the C API wrapper). It is the **only** module holding mutable state. `Session` is an `actor`; every unit of work takes its own `Connection`, because connections are deliberately not `Sendable`. `sift` is a thin executable target over it — thin because a SwiftPM test target cannot import an `executableTarget`, so anything with logic must live in the library.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, Foundation, `SiftCore`, `DuckDBKit`.

**Spec:** `docs/superpowers/specs/2026-08-09-native-sift-design.md` §4, §6, §7, §11, §13a.

**Plan sequence:** 1 DuckDBKit ✅ → 2 SiftCore ✅ → **3 SiftEngine + CLI (this)** → 4 Grid + panels → 5 Bundle and delete.

## What gets deleted rather than ported

`session.py` and `app.py` contain a large amount of code whose only purpose is crossing a process boundary. None of it survives:

- The FastAPI app and all 29 routes; uvicorn; `run_sidecar`; the `{port, token}` stdout handshake; `_port_free`/`_running_instance`/`_handoff`; the browser launch.
- **SSE**: `attach_loop`, `subscribe`, `unsubscribe`, `emit`, `_subscribers`. Roughly 60 lines whose job is telling another process that a row count finished. In-process this is a property change.
- **`jsonable`, `rows_payload`, `needs_string_transport`** — JavaScript number safety. `DuckDBKit.Cell` already carries `Int64`, `Decimal` and 128-bit-as-text correctly, pinned by Plan 1's `DecodeTests`.
- The parent-death watcher (`_exit_when_parent_goes_away`).
- The upload/spill path: `sweep_spill`, `SPILL_DIR`, `copied_from_browser`, `SIFT_MAX_UPLOAD_MB`. These exist only for pathless browser drops.

**Do not port any of the above.** If a task seems to need one, that is a signal the design drifted — stop and report.

## The porting rule

`engine/tests/**` is the spec and is read-only. **Keep every assertion value verbatim**, and port every individual `@pytest.mark.parametrize` case. Across Plans 1 and 2 the function count has repeatedly been the number that hides a dropped case.

**Where a Python test covers deleted machinery, it does not port — but it must be accounted for, not silently dropped.** Five tests in `test_paging.py` (`test_wide_ints_and_decimals_cross_the_wire_as_strings`, `test_needs_string_transport_picks_the_right_types`, `test_jsonable_handles_every_duckdb_shape`, `test_timestamptz_survives_serialization`, `test_nested_and_blob_columns_are_classified`) test `jsonable`/`rows_payload`. Their coverage is now in `Tests/DuckDBKitTests/DecodeTests.swift`. Task 9 maps each one to its replacement explicitly and reports any that has none.

## Global Constraints

- Swift tools **6.0**, platform floor **macOS 14**, zero third-party dependencies.
- `SiftEngine` may import `SiftCore` and `DuckDBKit`. **`SiftCore` must remain Foundation-only** — never add an import to it.
- **`sift` is an `executableTarget`, so no test can import it.** Everything with logic lives in `SiftEngine`; `sift` is argument parsing and printing. If you find yourself testing the CLI, the code is in the wrong module.
- **No `NumberFormatter`/`DateFormatter`/`ISO8601DateFormatter`** for anything a user or a test sees. Three bugs of that shape have shipped on this branch.
- Commit as the repo's configured identity. Never `git reset` this branch.
- **Any script committed needs `git add --chmod=+x`** — `core.fileMode=false` here silently drops the bit and CI dies on a fresh clone.
- Every commit leaves `swift build && swift test` green and warning-free, including the 204 existing tests. Suites run **in parallel**; do not introduce anything needing `.serialized`.
- Do not touch `engine/`, `web/`, `shell/`, `.github/workflows/ci.yml`, or the legacy files at the repo root. They are deleted in Plan 5, not before.

## Concurrency model — decided here, not per task

Three facts, replacing `session.py`'s docstring:

1. One `DuckDBKit.Database` is opened at launch, against `~/.sift/stage.duckdb`.
2. **Every unit of work takes its own `Connection`.** `Connection` is deliberately not `Sendable`; it must never be shared across tasks. This is the direct analogue of Python's `con.cursor()`.
3. **`Session` is an `actor`.** It owns the table catalog, job registry and staging state. Background work — exact count, bad-row detection, profiling, staging CTAS — runs as detached `Task`s that create their own `Connection` and call back into the actor with results.

The four-worker `ThreadPoolExecutor` becomes structured tasks. There is no SSE; Plan 4 observes the actor directly.

## 🔴 Inherited landmines — read before writing any code

**`interrupt()` is not fire-and-forget.** Measured against libduckdb 1.5.5: a single `duckdb_interrupt` issued before execution begins is **swallowed**, and the query runs to completion (4.20 s in the probe). The flag is cleared as execution starts. Hammering it in a loop cancels reliably (5/5 runs, 0.000–0.002 s). **`Session.cancel` must keep re-asserting the interrupt for as long as the job is meant to be cancelled** — Python's single `con.interrupt()` does not port across. Spec §13a records this.

**The guard's statement check fails on valid SQL.** Python gets a statement type without preparing; the C API needs `duckdb_prepare_extracted_statement` first, and **prepare fails on `SELECT * FROM nonexistent`** (a binder error) where Python would happily report `SELECT`. A prepare failure must therefore **not** be treated as a guard rejection — let the real query path produce the error, or the guard rejects valid SQL against a table the user has not opened yet.

**`Cell.decimal` carries its scale** — `case decimal(Decimal, scale: Int)`. Pattern-matching sites must expect it.

**`SQLValue` and `DBValue` are separate types by design.** `SiftCore` cannot import `DuckDBKit` and vice versa. `SiftEngine` imports both and owns the five-line mapping. `Tests/SiftCoreTests/SQLGenTests.swift:29-37` already contains it — lift it, do not reinvent it.

---

### Task 1: Close the two DuckDBKit gaps Plan 2 escalated

**Ports:** nothing — these are Plan 1 defects found later, recorded in spec §13a.

**Files:** Modify `Sources/DuckDBKit/Chunk.swift`, `Sources/DuckDBKit/ResultSet.swift`; extend `Tests/DuckDBKitTests/DecodeTests.swift`.

**This is the one task permitted to modify `DuckDBKit`.**

**Gap 1 — a first-party query returns a `LIST` the decoder cannot read.** Plan 1 deferred nested types on the premise that they only arrive in *user data*, which the engine would `CAST` to VARCHAR. That premise is false: `SQLGenPanels.badRowsSQL` emits `list_filter([...], x -> x IS NOT NULL) AS bad_columns` — Sift's own SQL producing a `LIST` column. It currently decodes as `⟨unsupported type 24⟩`, so the per-cell highlighting in the "rows your file lost" panel cannot work end to end.

Add a `LIST` case to `Chunk.decodeColumn`. DuckDB's list vectors carry a `duckdb_list_entry` (offset, length) per row plus a child vector — read the child with `duckdb_list_vector_get_child`, and verify the exact spelling against `Sources/CDuckDB/duckdb.h` before writing. **Add a `Cell.list([Cell])` case** rather than joining into text. The panel's whole job is
highlighting *which* cells failed, so it needs the individual column names; a joined string would
have to be re-split, and re-splitting breaks the moment a column name contains the separator — in a
product whose premise is not mangling data. `Cell` gains a case, so check every exhaustive `switch`
over it compiles.

**Gap 2 — JSON classifies as text, not nested.** `duckdb_column_logical_type` reports JSON as type id 17 (`VARCHAR`), so `kind(of:)` buckets a JSON column `.text` where the Python engine gives `nested`, and `chooseView` can route it to the `highcard` panel. `duckdb_logical_type_get_alias` (`duckdb.h:3070`) returns `"JSON"` for such a column and `nil` for a plain VARCHAR. Read the alias in `ResultSet.init` and prefer it when non-nil.

- [ ] **Step 1: Read** spec §13a, `Sources/CDuckDB/duckdb.h` for the list and alias functions, and `Sources/DuckDBKit/Chunk.swift`.
- [ ] **Step 2: Write failing tests** — a `SELECT ['a','b']` list, a `bad_rows_sql`-shaped `list_filter` result, and a JSON column asserting `typeName == "JSON"`.
- [ ] **Step 3: Implement both.**
- [ ] **Step 4: Verify.** Full suite green.
- [ ] **Step 5: Update spec §13a** to record both as closed, with the date.
- [ ] **Step 6: Commit.**

---

### Task 2: SourceProbe — the connection-needing half of `source.py`

**Ports:** `sniff_csv`, `parquet_footer`, `exact_count`, `_describe`, `build_source` from `engine/core/source.py`, plus the tests Plan 2 deferred: the 13 named in `Tests/SiftCoreTests/SourceTests.swift:10-18` and the 3 in `SheetsTests.swift:7-10`, plus all of `engine/tests/test_delta.py`.

**Files:** Create `Sources/SiftEngine/SourceProbe.swift`, `Tests/SiftEngineTests/SourceProbeTests.swift`, `DeltaTests.swift`. Modify `Package.swift`.

**Gotchas:**
- **`sniff_csv` reports an absent quote/escape/comment as the literal 7-character string `(empty)`**, and feeding that back into `read_csv` fails with "cannot exceed a size of 1 byte". Normalize it to `""`. This is DuckDB 1.5.5 fact 1, already pinned in `DuckDB155FactsTests`.
- **Whole-file sniffing under 50 MB** (`sample_size=-1`). That closes the most common failure in this problem space: types inferred from the first 20k rows, and row 400,000 disagrees.
- **`exact_count` counts the all-varchar relation for text formats.** Counting the typed relation is wrong — measured, `count(*)` is answered by projection pushdown without parsing any column, so with an uncastable value present it disagrees with `SELECT *`. Fact 3 pins this.
- **`build_source` refuses a Delta directory when the `delta` extension is missing**, rather than degrading to a parquet glob — a glob resurrects tombstoned rows and returns confidently wrong counts.
- `build_source` for a glob `DESCRIBE`s only the **first** file; with `union_by_name` DuckDB would open every footer, which is seconds on a few thousand files.
- Use `SiftCore.filesWithExtension` (made `public` in Plan 2 for exactly this) and `hiveKeys`.
- The xlsx branch picks the first **non-empty** sheet as default.

- [ ] **Step 1: Read** `engine/core/source.py`'s connection-taking functions and the three test files.
- [ ] **Step 2: Add the `SiftEngine` and `SiftEngineTests` targets** to `Package.swift`. **Do NOT add `linkerSettings`** — they propagate transitively from `DuckDBKit`, and a duplicate emits `ld: warning: duplicate -rpath`.
- [ ] **Step 3: Write `SourceProbe.swift`.**
- [ ] **Step 4: Port the deferred tests**, verbatim.
- [ ] **Step 5: Verify.** Full suite green, parallel-stable.
- [ ] **Step 6: Commit.**

---

### Task 3: Finish the SELECT-only guard

**Ports:** the third check of `engine/core/guard.py`, and the `test_guard.py` cases Plan 2 marked deferred.

**Files:** Create `Sources/SiftEngine/GuardStatements.swift`, `Tests/SiftEngineTests/GuardStatementsTests.swift`.

`SiftCore.Guard` already does comment stripping and the deny-list. This adds statement counting and type checking, which need a connection.

**C API, confirmed present in `Sources/CDuckDB/duckdb.h`:** `duckdb_extract_statements`, `duckdb_prepare_extracted_statement`, `duckdb_prepared_statement_type`, `duckdb_destroy_extracted`.

**Gotchas:**
- **A prepare failure is NOT a guard rejection.** See the landmine above — `SELECT * FROM nonexistent` fails to prepare but is a perfectly good SELECT. Treat an unpreparable statement as "not my problem" and let the query path report it.
- The deferred cases are `"SELECT 1; DROP TABLE x"` (needs counting) and the `"one statement at a time"` message for `"SELECT 1; SELECT 2"`. `GuardTests.swift:9-17` names them.
- **Do not pattern-match semicolons.** `test_allowed` contains `SELECT '; DROP TABLE x'` precisely to catch that shortcut.
- Remember the real enforcement is `wrapUserSQL`'s newline subquery wrap, already shipped and pinned. This layer only improves the message.

- [ ] **Step 1: Read** `engine/core/guard.py`, `Sources/SiftCore/Guard.swift`, and the deferred-case comments in `GuardTests.swift`.
- [ ] **Step 2: Write `GuardStatements.swift`.**
- [ ] **Step 3: Port the deferred cases** and delete their deferral comments in `GuardTests.swift`.
- [ ] **Step 4: Add a test** proving a valid `SELECT` against a nonexistent table is **not** rejected by the guard.
- [ ] **Step 5: Verify. Step 6: Commit.**

---

### Task 4: Session — catalog, open, paging

**Ports:** `session.py`'s `Table` dataclass and `Session.__init__`, `open_path`, `_after_open`, `_detect_bad_rows`, `page`, `_sorted_relation`, `table`, `_tlock`, `relation`, `raw_relation`, `engine_info`, `state`, `close_table`, `shutdown`, `drop_private_store`, `_sweep_private_stores`.

**Three things already exist — reuse, do not re-port:**
- `Session.__init__`'s `_harden` and `_load_extensions` are **already** `DuckDBKit.Database.harden()` and `loadExtensions(_:)`, shipped and tested in Plan 1 (including the measured fact that the four `SET`s are GLOBAL scope and outlive the throwaway connection). Call them.
- `_clean_duckdb_error` is **already** `DuckDBError.firstLine`, shipped in Plan 1 with the same 400-character cap.
- `engine_info` reports the DuckDB version, `SIFT_HOME`, which extensions loaded, staged bytes, and whether the store is shared. `Database.loadedExtensions` and `hardened` already carry two of those.

**Files:** Create `Sources/SiftEngine/Session.swift`, `Sources/SiftEngine/Table.swift`, `Tests/SiftEngineTests/SessionTests.swift`.

**Gotchas:**
- **`Session` is an `actor`.** `Table` is a struct held in the actor's catalog, not a reference type shared out.
- **`~/.sift` is created and enforced at `0700`**, even if it already existed. §11 frozen contract.
- **The private-store fallback**: DuckDB takes an exclusive lock on the database file, so a second engine falls back to `stage-<pid>.duckdb` and deletes it on exit. Browser mode is gone so the common cause disappeared, but `open -n` can still do it. Keep the fallback and `_sweep_private_stores` (which uses `kill(pid, 0)` to detect a dead owner); reword the log message to drop the dev-server reference.
- **`_sorted_relation` materializes a sorted result once and pages off the copy.** Two reasons, both in the Python comment: a fresh `ORDER BY` per page is a full sort per page, and ties on a non-unique sort column are ordered arbitrarily, so the same row could appear on two pages or none. Keep the comment.
- **`page` counts the filtered relation once per spec change, not per page** — the grid's scroll extent is built from it.
- **`grid_rows` is `row_count - bad_rows`**; `visible_rows` is the filtered count when filters are active. Getting this wrong makes the scroll thumb overshoot the data.
- `_after_open` runs exact count → bad-row detection → staging decision → eager profile, in that order, as a background `Task`.
- **`_detect_bad_rows` caches its full per-column result** so `compute_profile` does not re-run the whole varchar scan.

- [ ] **Step 1: Read** `engine/session.py` lines 1-540.
- [ ] **Step 2: Write `Table.swift` and `Session.swift`.**
- [ ] **Step 3: Write tests** covering open → page contiguity, the bad-row accounting, `visibleRows` under a filter, and the `0700` enforcement.
- [ ] **Step 4: Verify. Step 5: Commit.**

---

### Task 5: Session — profiling, panels, SQL mode

**Ports:** `run_sql`, `exit_sql_mode`, `compute_profile`, `profile_of`, `distinct`, `histogram`, `sample_values`, `length_histogram`, `bad_rows`, `set_spec`, `rendered_sql`, `snippet`.

**Files:** Create `Sources/SiftEngine/SessionQueries.swift`, `Tests/SiftEngineTests/SessionQueriesTests.swift`.

**Gotchas:**
- **The faceting rule**: a column's distinct panel ignores that column's own filters, so every value stays visible with the selected ones highlighted. `QuerySpec.withoutColumn` does it; the test asserts both halves.
- `distinct` clamps `approx_count_distinct` — HyperLogLog overshoots, measured 340 for 300 distinct and re-confirmed through the C API in Plan 1.
- `compute_profile` reuses `_detect_bad_rows`' cached scan rather than re-running it.
- **`bad_rows` now returns a `LIST` column** (`bad_columns`) — Task 1 makes it decodable. If Task 1 chose a `Cell.list` case, consume it; if it chose text, say so in your report.
- `run_sql` calls the guard first for a readable message, then relies on the wrap.
- `set_spec` resets `filtered_count` so the next page recounts.
- Excel-serial-date detection appends a note on the table when the source is xlsx.

- [ ] **Step 1: Read** `engine/session.py` lines 542-780.
- [ ] **Step 2: Write it. Step 3: Test it. Step 4: Verify. Step 5: Commit.**

---

### Task 6: Staging and the staged-data lifecycle

**Ports:** `_next_job`, `_maybe_stage_after_dwell`, `stage_now`, `_do_stage`, `cancel`, `_record_staged`, `_db_bytes`, `staged_entries`, `staged_total_bytes`, `purge_staged`, `unstage`.

**Files:** Create `Sources/SiftEngine/Staging.swift`, `Tests/SiftEngineTests/StagingTests.swift`.

**Gotchas:**
- **🔴 `cancel` must hammer the interrupt.** See the landmine section. A single call before execution starts is swallowed. Loop until the job reports finished or cancelled.
- **Staging is the second step, never the first.** A view over the file is instant at any size; the CTAS fires only for CSV/JSON above 25 MB and only after an aggregate or ~3 seconds of dwell. A drive-by header peek must not pay for a 20 s copy.
- **The view→table swap is transactional and retried** — `BEGIN / DROP VIEW / ALTER TABLE RENAME / COMMIT` under a per-table lock, three attempts with a rollback between.
- After staging, `row_count` becomes the table's own count **plus `bad_rows`**, because the materialized table already excludes rows dropped at parse time.
- **`_record_staged` measures bytes as the growth of `stage.duckdb` across the CTAS.** DuckDB exposes no per-table size — `duckdb_tables.estimated_size` is estimated **rows**, which silently produced a "3,000,048 B" reading for a 3M-row table. That is DuckDB 1.5.5 fact 9, already pinned. `CHECKPOINT` first so the WAL is flushed and the delta is meaningful.
- **`purge_staged` never yanks a table out from under an open tab**, and additionally drops any staged copy whose source file has changed on disk (mtime or size), because a stale copy is simply wrong.
- `SiftCore.selectForPurge` already implements the age-then-size policy; call it rather than re-deriving.

- [ ] **Step 1: Read** `engine/session.py` lines 775-1015.
- [ ] **Step 2: Write it.**
- [ ] **Step 3: Test it**, including a cancel test that proves the hammering works — a single-shot interrupt must be shown insufficient, the way Plan 1's `interruptCancelsAQueryAlreadyInFlight` does.
- [ ] **Step 4: Verify. Step 5: Commit.**

---

### Task 7: Joins, merge, export

**Ports:** `join_probe`, `unmatched_keys`, `join_candidates`, `merge`, `export`.

**Files:** Create `Sources/SiftEngine/Joins.swift`, `Sources/SiftEngine/Export.swift`, and their tests.

**Gotchas:**
- **`join_probe`'s one number prevents more bad analyses than any other feature here**: "1,204 of 1,318 match (91.4%)" tells you immediately whether the key is right. Preserve the semi-join/anti-join shape.
- **`merge` creates a view, not a copy** — instant, no duplication, and exportable to materialize. The right side's key columns are dropped `USING`-style so keys are not duplicated.
- **`export` is the one place Sift writes anything.** SQL is built here, never from the SQL box, so `COPY` can never be reached from user input. In SQL-box mode it re-runs `assertSelectOnly` on the stored text first.
- `EXPORT_FORMATS` is a fixed map; an unknown key is a clean error, not a crash. `xlsx` needs the `excel` extension.
- Export refuses to overwrite unless explicitly told to.

- [ ] **Step 1: Read** `engine/session.py` lines 1017-1165.
- [ ] **Step 2: Write it. Step 3: Test it. Step 4: Verify. Step 5: Commit.**

---

### Task 8: The `sift` CLI verifier

**Files:** Create `Sources/sift/main.swift`, `Sources/SiftEngine/Verification.swift`. Modify `Package.swift`.

This replaces browser mode as the headless verification surface — the role `pv-pipeline` plays in latent. It is the reason Plan 1's "kill browser mode" decision was safe.

**The logic lives in `Sources/SiftEngine/Verification.swift`, not in the executable**, because a test target cannot import an `executableTarget`. `main.swift` parses arguments and prints; everything else is testable library code.

`sift --verify` must exercise, against generated fixtures: opening each supported format; profiling; the distinct panel; the SELECT-only gate; staging and unstaging; merge; and export. It exits non-zero on any failure and prints what failed.

Also provide `sift <path>` to open a file and print schema + first rows — useful on its own and a smoke test of the real path.

- [ ] **Step 1: Read** latent's `Sources/PipelineCLI/*Verifications.swift` if reachable, for the established shape. If not, design it plainly.
- [ ] **Step 2: Write `Verification.swift`** as library code returning structured results.
- [ ] **Step 3: Write a thin `main.swift`.**
- [ ] **Step 4: Add the target to `Package.swift`** and wire `swift run sift --verify` into CI as a third step.
- [ ] **Step 5: Verify** — run it, paste the output.
- [ ] **Step 6: Commit.**

---

### Task 9: Port the end-to-end suites, and account for the deleted ones

**Ports:** `engine/tests/test_paging.py` and `engine/tests/test_distinct.py`.

**Files:** Create `Tests/SiftEngineTests/PagingTests.swift`, `DistinctTests.swift`.

**The accounting task.** Five `test_paging.py` tests cover `jsonable`/`rows_payload`/`needs_string_transport`, which are deleted. **Map each one to its replacement in `Tests/DuckDBKitTests/DecodeTests.swift` and report the mapping.** If any has no replacement — for instance the `kind` classification asserted by `test_nested_and_blob_columns_are_classified` — write the missing test rather than dropping the case.

The rest port normally: paging contiguity, sorted-page stability across offsets, filtered counts matching filtered rows, SQL-mode wrapping, and all nine distinct-panel tests.

- [ ] **Step 1: Read** both Python files and `DecodeTests.swift`.
- [ ] **Step 2: Write the mapping table** into your report **before** writing code.
- [ ] **Step 3: Port what ports; write what is missing.**
- [ ] **Step 4: Verify. Step 5: Commit.**

---

## Done when

- `swift build && swift test` green from a clean checkout, warning-free, parallel-stable, including all 204 existing tests.
- `swift run sift --verify` passes and is wired into CI.
- CI green on `macos-15`.
- Every Python test in `engine/tests/**` has a Swift counterpart asserting the same values, **or** is listed in a report as covering deleted machinery with its replacement named.
- Both spec §13a items closed by Task 1.
- The engine opens every supported format, profiles it, pages it, stages it, merges and exports — with no Python running.

## Deliberately not in this plan

- **Any UI.** The grid and panels are Plan 4. If a task needs a view, the design drifted.
- **Deleting Python.** Plan 5, after the app works end to end.
- The six DuckDB types that still render a loud marker (`ENUM`, `BIT`, `BIGNUM`, `TIME_NS`, `VARIANT`, `GEOMETRY`) and `TIME_TZ`'s sub-minute offsets — recorded in spec §13a and owned by whoever needs them first.
