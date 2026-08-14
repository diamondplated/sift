# DuckDB 1.5.5 remote facts — Phase 1, Task 0 measurement spike

Ten questions the remote-connections work is about to build on, each answered by running a probe
against the **vendored `libduckdb` 1.5.5** (`Vendor/duckdb/libduckdb.dylib`, fetched by
`scripts/fetch-duckdb.sh`) through `DuckDBKit`. Nothing here came from the Homebrew CLI, from
DuckDB's docs, or from memory. No product code was written.

Measured 2026-08-13 on macOS 26 (Darwin 25.3), Swift 6.3, arm64, against `b59d771`.

Where a fact deserves a permanent executable pin it lives in
`Tests/DuckDBKitTests/RemoteFactsTests.swift`, gated behind **`SIFT_REMOTE_FACTS=1`** — those
tests need `httpfs`/`azure`/`delta`, and `loadExtensions` does LOAD→INSTALL→LOAD, so leaving them
in the default suite would put the network on the critical path of `swift test`. Measured both
ways: `swift test` runs **729** tests before this change and **729** after it (742 declared, 13
skipped); `SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` runs the 13 in 1.3 s.

**The test oracle.** Probes that need a server use a ~120-line HTTP/1.1 origin server on
`127.0.0.1` with `Range`/206 support, a request log, and a switch for how it treats `Range`
(honor / ignore / reject). It lives at the bottom of `RemoteFactsTests.swift`.

> **Detour worth recording.** The plan called for `NWListener`. On this Mac **every** `NWListener`
> configuration — `on: .any`, an explicit port, with and without `requiredLocalEndpoint`,
> interpreted and compiled — fails with `POSIXErrorCode(22): Invalid argument`, while a plain BSD
> `bind()` on the same port succeeds immediately. The oracle is therefore Darwin sockets. Anything
> later in this plan that assumes `NWListener` works headlessly here needs to check that first.

---

## 1. What are the Azure filesystems actually registered as?

**Question.** `harden()` disables filesystems by name. Adding `azure` as a core extension means
adding its names to that list — and a name that does not exist is accepted silently, so a typo
would be a security hole that no test could see. What are the exact strings?

**Probe.** `SET disabled_filesystems` accepts any string; an unknown name is a no-op, so the name
cannot be read back. The *error class* of a subsequent read is the oracle: a registered name turns
the read into a `Permission Error` that names the filesystem, an unregistered one leaves the read
to fail further down the stack. No Azure account is involved — the credential error is the
negative result.

```sql
-- per guess, on a fresh Database with `azure` loaded
SET disabled_filesystems='<guess>';
SELECT * FROM read_parquet('az://c/x.parquet');
SELECT * FROM read_parquet('abfss://c@a.dfs.core.windows.net/x.parquet');
```

**Measured.** Two registered filesystems, one per URL family:

| Registered name | Serves |
|---|---|
| `AzureBlobStorageFileSystem` | `az://`, `azure://` |
| `AzureDfsStorageFileSystem` | `abfss://`, `abfs://` |

```
disabled_filesystems='AzureBlobStorageFileSystem'
  az://…    -> Permission Error: File system AzureBlobStorageFileSystem has been disabled by configuration
  azure://… -> Permission Error: File system AzureBlobStorageFileSystem has been disabled by configuration
  abfss://… -> IO Error: AzureStorageFileSystem could not open file … (i.e. NOT blocked)

disabled_filesystems='AzureDfsStorageFileSystem'
  az://…    -> Invalid Input Error: No valid Azure credentials found!   (i.e. NOT blocked)
  abfss://… -> Permission Error: File system AzureDfsStorageFileSystem has been disabled by configuration

disabled_filesystems='AzureStorageFileSystem' | 'AzureFileSystem' | 'AzureBlobFileSystem'
  | 'AzureExtensionFileSystem' | 'BlobStorageFileSystem' | 'NotAFileSystem'
  az://…    -> Invalid Input Error: No valid Azure credentials found!   (nothing was disabled)
```

Three traps fell out of this:

- **`AzureStorageFileSystem` is a decoy.** It is the C++ base class and it appears in the
  extension's own error text (`IO Error: AzureStorageFileSystem could not open file: …`), but it is
  not registered. Disabling it blocks nothing. Anyone reading that error message and copying the
  name into `harden()` gets a security layer that does nothing and says nothing.
- **`SET disabled_filesystems` never validates.** `SET disabled_filesystems='NotAFileSystem'`
  returns success. There is no `duckdb_filesystems()` table function, no `PRAGMA show_filesystems`,
  and nothing in `duckdb_functions()` — the registry is not introspectable. The error class above
  is the only way to check a name, and the only way to keep checking it as versions move.
- **`harden()` blocked neither, at the time of measurement.** Its frozen list was
  `HTTPFileSystem,S3FileSystem`. With `azure` loaded, `az://` sailed past the VFS check and died on
  credentials, not permission.

**Consequence.** `harden()`'s list must become
`'HTTPFileSystem,S3FileSystem,AzureBlobStorageFileSystem,AzureDfsStorageFileSystem'` in the same
change that makes `azure` a core extension — not in a follow-up. Because the list is unvalidated
and the registry is not introspectable, the only defence against a rename is the pin below, which
asserts each Permission Error by name. Order does not matter: setting the name before `LOAD azure`
blocks just as well as setting it after.

**Taken in P1-T3**, which is why the pin's name and its last block changed: `harden()` now denies
all four names, so every Azure URL family is refused by permission on a default database, and the
permissive posture (`harden(allowRemote: true)`) is the control that still reaches the credential
check. The four names are each dropped one at a time in
`theGateScratchConnectionIsHardenedLikeEveryOtherOne` and
`hardenDisablesEveryNameOnTheDenyListAndAllowRemoteDisablesNone`, which need no network.

**Pinned:** `remoteFact1_azureRegistersTwoFilesystemsAndHardenNowBlocksBoth`.

---

## 2. Can `disabled_filesystems` be narrowed or broadened after the first SET?

**Question.** The Connections UI wants a switch: this window may reach the network, that one may
not. Is that a live setting or a restart?

**Probe.** One `Database`, two sibling connections, a third opened afterwards.

```sql
-- on connection A
SET disabled_filesystems='HTTPFileSystem,S3FileSystem';                    -- ok
SET disabled_filesystems='HTTPFileSystem,S3FileSystem,LocalFileSystem';    -- broaden
SET disabled_filesystems='HTTPFileSystem';                                 -- narrow
SET disabled_filesystems='';                                               -- clear
RESET disabled_filesystems;
-- then, on B and on a connection opened after all of the above
SELECT * FROM read_csv('http://127.0.0.1:9/nope.csv');
```

**Measured.** The set is **monotonic and Database-wide**. Broadening succeeds. Narrowing, clearing
and `RESET` all fail identically:

```
Invalid Input Error: File system "LocalFileSystem" has been disabled previously, it cannot be re-enabled
```

`SELECT current_setting('disabled_filesystems')` reads back **`''` at every point**, before and
after — it is write-only in practice, so the UI cannot read the current state out of the engine
either. Sibling connection B is blocked without ever issuing the SET, and so is a connection opened
afterwards (`Permission Error: File system HTTPFileSystem has been disabled by configuration`).

The boundary is the `Database`, not the process: a **second `Database` in the same process is
clean** and its http read fails with `IO Error: Could not connect to server`, not a Permission
Error.

**Consequence.** There is no live enable. "Allow remote for this connection" costs a new
`duckdb_database` — which is cheap, because it is a `Database` restart and not an app restart, and
because `OpenHomes` already makes one-`Session`-per-home the rule. Two shapes fit:

1. **Decide at open time.** A `Session` that is going to talk to a remote source is constructed
   with a `harden()` variant that never disables the network filesystem it needs. Everything else
   keeps today's full lockdown. This is the shape to build — it keeps the default airtight and
   makes "remote" a property of the session, which is what the Connections UI is modelling anyway.
2. **One permissive Database.** Rejected: it would make every local file open share a process-wide
   engine that can egress.

Whatever the UI shows, it must not read the setting back from DuckDB — the value is always `''`.
Sift has to remember what it disabled.

**Pinned:** `remoteFact2_disabledFilesystemsCanOnlyEverBeBroadened`.

---

## 3. Does `delta_scan` work over `http://`, and are tombstones honored?

**Question.** Remote Delta is the most-requested shape after parquet. Does 1.5.5 do it at all?

**Probe.** A real two-version Delta table (v0 adds two parquet files, v1 tombstones the second,
which stays on disk) served by the loopback server, with `delta` and `httpfs` both loaded.

```sql
SELECT count(*) FROM delta_scan('http://127.0.0.1:PORT/dtable');           -- and with a trailing /
SELECT count(*) FROM delta_scan('http://127.0.0.1:PORT/dtable', version => 0);
```

**Measured.** It does not work, and it fails before the network:

```
IO Error: DeltaKernel ObjectStoreError (8): Error interacting with object store:
Generic HTTP error: Error performing GET
http://127.0.0.1:PORT/dtable/_delta_log/_last_checkpoint in 106.667µs - HTTP error: builder error
```

**The server logged zero requests.** Identical for the trailing-slash form and for
`version => 0`. Loading `httpfs` changes nothing: delta-kernel-rs carries its own `object_store`
and never routes through DuckDB's HTTP filesystem, so httpfs's settings, secrets, retries and
timeouts do not apply to Delta at all. The same fixture read locally returns 100 rows with the
tombstone honored, so the fixture is sound.

The tombstone question is therefore unanswerable over http — and the fallback is worse than
useless: reading the same two files as a plain remote parquet list **works** and returns **150**,
the tombstoned rows included. That is exactly the failure the frozen contract "a `_delta_log/` dir
is read via `delta_scan`, never a raw parquet glob" exists to prevent, and over http the contract
cannot be satisfied at all.

**Consequence.** Remote Delta over `http(s)://` is out of scope for this phase. A URL whose
directory contains `_delta_log/` must be **refused with a clean sentence**, never silently
downgraded to a parquet read — a silent downgrade would show deleted rows as live data, which is
the single worst thing this tool can do. Whether `az://` Delta works is a different question
(delta-kernel-rs has native Azure object-store support and would use its own credentials, not the
`azure` extension's secret) and it needs the manual checklist.

**Pinned:** `remoteFact3_deltaScanOverHttpFailsInsideTheKernel` — including the assertion that not
one request reached the server, and that the forbidden glob fallback really does return 150.

---

## 4. Is a remote glob supported?

**Question.** `read_parquet('http://…/*.parquet')` is the first thing anyone types.

**Probe.**

```sql
SELECT count(*) FROM read_parquet('http://127.0.0.1:PORT/*.parquet');
SELECT count(*) FROM glob('http://127.0.0.1:PORT/*.parquet');
SET allow_asterisks_in_http_paths=true;   -- then the same read again
SELECT count(*) FROM read_parquet(['http://127.0.0.1:PORT/a.parquet','http://127.0.0.1:PORT/b.parquet']);
```

**Measured.** Refused, at plan time, before any request:

```
Invalid Input Error: Globs (`*`) for generic HTTP file is are not supported.
```

(the grammar slip is DuckDB's; the pin matches loosely so an upstream typo fix does not fail it.)
`glob()` gives the same error. The server logged **zero** requests for both.

`allow_asterisks_in_http_paths` (default `false`, `GLOBAL`) is **not** a glob switch — it stops
treating `*` as a glob character, so the asterisk goes out as a literal path byte:

```
HEAD /*.parquet -> 404
HTTP Error: HTTP GET error on 'http://127.0.0.1:PORT/*.parquet' (HTTP 404 Not Found)
```

The explicit list form works and is the supported multi-file shape: 2000 rows from two files,
each fetched with its own HEAD + ranged GET.

**Consequence.** No wildcard in any remote-source UI. A pasted URL containing `*` gets an
up-front, local rejection with a sentence that says "list the files" — not a round trip, not
DuckDB's message. Multi-file remote sources are an explicit list, which means the Connections UI
needs a way to build one (paste several URLs / a manifest), and that is a real feature, not a
detail. `allow_asterisks_in_http_paths` must stay `false`: turning it on only converts a clear
error into a confusing 404.

**Pinned:** `remoteFact4_httpGlobsAreRefusedNotExpanded`.

---

## 5. Is `read_blob` over httpfs byte-exact, and does it range?

**Question.** This is the planned download path for remote `.xlsx` (which cannot be read in place —
`XLSXSheets.swift` parses the OOXML directly and needs the whole file).

**Probe.** 4 MiB of non-compressible bytes, served over loopback, compared to the same bytes read
from disk, with the request log captured.

```sql
SELECT octet_length(content), md5(content) FROM read_blob('http://127.0.0.1:PORT/blob.bin');
SELECT octet_length(content), md5(content) FROM read_blob('/…/blob.bin');
```

**Measured.** Byte-exact — identical length and identical md5 — and it is a **whole-object
download wearing a Range header**:

```
HEAD /blob.bin           -> 200
GET  /blob.bin  Range: bytes=0-4194303  -> 206 (4194304 B)
```

Exactly one HEAD and exactly one GET, whose range spans the entire object. Repeated at 9 MiB: same
two requests, one range, `bytes=0-9437183`. There is no chunking, no resume, and no progress
granularity — the request is atomic from Sift's point of view.

**Consequence.** `read_blob` is a correct but blunt download. Consequences for the remote-xlsx
path, in order:

- It is safe to trust the bytes. No checksum step is needed on top.
- **There is no progress and no cancel.** One `duckdb_query` that runs until the whole object
  arrives, and `duckdb_interrupt` before execution starts is already known to be swallowed
  (AGENTS.md). A 500 MB remote workbook is an un-cancellable spinner. If the download needs to be
  cancellable or show progress, it cannot be `read_blob` — it has to be Sift's own `URLSession`
  download, which also gets us byte counts for free.
- Size has to be checked **before** the read, from the HEAD that httpfs is going to do anyway, and
  refused against the staging budget rather than discovered afterwards.

**Pinned:** `remoteFact5_readBlobOverHttpIsByteExactAndUnchunked`.

---

## 6. `CREATE SECRET` semantics

The highest-stakes group of the ten: the design issues secrets from engine code on one connection
and reads through throwaway connections.

### 6a. Can parameters be bound?

**Probe.**

```sql
CREATE SECRET s1 (TYPE azure, ACCOUNT_NAME ?)                 -- .text("bound_account")
CREATE SECRET s2 (TYPE azure, ACCOUNT_NAME ?, SCOPE ?)
CREATE SECRET s3 (TYPE s3,    KEY_ID ?, SECRET ?)
CREATE SECRET s4 (TYPE azure, CONNECTION_STRING ?)
CREATE SECRET s5 (TYPE ?,     ACCOUNT_NAME 'x')
CREATE SECRET s6 (TYPE azure, PROVIDER ?, ACCOUNT_NAME 'x')
CREATE SECRET ?  (TYPE azure, ACCOUNT_NAME 'x')               -- the NAME
```

**Measured — and this reverses the assumption the task was written on.** Every **value** position
binds, including `CONNECTION_STRING`, `SECRET`, `BEARER_TOKEN`, `SCOPE`, `TYPE` and `PROVIDER`, and
the bound value lands verbatim (`account_name=bound_account`, `scope=az://only-this-container`,
`key_id=AKIA_ID`). Only the secret's **name** is a parser-level identifier:

```
CREATE SECRET ? (TYPE azure, …)  ->  Parser Error: syntax error at or near "?"
```

**Consequence.** This is the good outcome and it should be taken. Credentials go through
`DBValue`, exactly like every other value in Sift — the package invariant "nothing in Sift
interpolates a user value into SQL text" survives contact with secrets, which was the thing most at
risk in this design. The account name, connection string, SAS token and scope are all bound. Only
the secret's *name* is generated, and it must go through the same `^[a-z_][a-z0-9_]*$` treatment
`Database.isExtensionName` already applies to `LOAD` — best generated by Sift (`sift_conn_<n>`) and
never taken from user text at all.

### 6b. Are secrets per-connection or per-Database?

**Probe.** Create on connection A, let A be released (`duckdb_disconnect` runs), then read from a
connection made afterwards. Then check a second `Database` in the same process.

**Measured.** **Database-scoped.** The secret survives the death of the connection that created it,
is visible to every sibling connection, and `which_secret('az://c/x.parquet', 'azure')` resolves to
it from a connection that never saw the `CREATE`. A different `Database` in the same process sees
`count(*) = 0`.

**Consequence.** The design works as drawn: issue the secret once on the engine's connection, and
every throwaway connection can read remote data. The corollary is the safety one — a secret is
visible to *everything* on that `Database`, including the SQL console. The SELECT-only guard stops
`SELECT * FROM duckdb_secrets()` from being a write, not from being a read, so what the console can
see is decided entirely by 6c's redaction.

### 6c. Temporary by default, and what redaction shows

**Probe.** A file-backed `Database`, `SET secret_directory` into a `TestTemp` dir, one
`CREATE SECRET` carrying a recognisable key, `CHECKPOINT`, then grep the `.duckdb` file and reopen
it.

**Measured.**

- **`TEMPORARY` is the default**: `persistent = false`, `storage = 'memory'`.
- **Nothing reaches disk.** The key string does not appear anywhere in the `.duckdb` file, and
  `secret_directory` is never created. Reopening the same file finds `count(*) = 0`.
- `CREATE PERSISTENT SECRET` is the opt-in, and it writes `<name>.duckdb_secret` into
  `secret_directory` — never into the `.duckdb` file.
- **Redaction is on by default and is field-aware.** `duckdb_secrets()` returns
  `connection_string=redacted`, `secret=redacted`, `bearer_token=redacted`, while `account_name`,
  `key_id`, `provider` and `scope` are shown in the clear.
- `duckdb_secrets(redact=false)` → `Invalid Input Error: Displaying unredacted secrets is disabled`.
- `SET allow_unredacted_secrets=true` →
  `Invalid Input Error: Cannot change allow_unredacted_secrets setting while database is running`.
  It is a **start-up-only** option, so a running engine can never be talked into printing a
  credential.

**Consequence.** Sift issues `TEMPORARY` secrets, always, and never passes
`allow_unredacted_secrets` at open time. Credentials live in the Keychain, are bound into
`CREATE SECRET` at open, and die with the `Database`. Two things follow that the UI must respect:
`account_name` and `key_id` are **not** redacted, so anything that surfaces `duckdb_secrets()` is
leaking identity if not the key; and if a connection ever needs to survive a restart, the store is
the Keychain and `CREATE PERSISTENT SECRET` stays unused — a second on-disk credential store is a
second thing to get wrong.

**Pinned:** `remoteFact6a_createSecretAcceptsBoundValuesButNotABoundName`,
`remoteFact6b_secretsAreDatabaseScopedNotConnectionScoped`,
`remoteFact6c_secretsAreTemporaryByDefaultAndRedactedOnRead`.

---

## 7. `sniff_csv` / `read_csv` over http — ranged, or whole object?

**Question.** Sift plans to stage remote CSV on open and read remote parquet in place. Is that the
right split, or is CSV cheap enough to read in place too?

**Probe.** An 8.5 MB CSV (400 000 rows) and a 28.6 MB parquet (2 000 000 rows), served over
loopback, with every request logged.

**Measured — CSV is a whole-object download, and `sample_size` does not touch it.**

| Statement | Requests | Bytes moved |
|---|---|---|
| `sniff_csv(url)` | HEAD + 1 GET `bytes=0-8536549` | 8 536 550 (100 %) |
| `sniff_csv(url, sample_size=20)` | HEAD + 1 GET `bytes=0-8536549` | 8 536 550 (100 %) |
| `read_csv(url) LIMIT 5` | HEAD + **2** GETs, both full-object | 17 073 100 (**200 %**) |
| `read_csv(url)` `count(*)` | HEAD + 2 GETs, both full-object | 17 073 100 (200 %) |

`sample_size` bounds the **rows inspected**, not the bytes fetched. And a bare `read_csv` pays for
the object **twice** — a sniff pass and a scan pass — so a preview of the first five rows of a
remote CSV costs twice the file.

**Measured — parquet really does range-read.**

| Statement | Requests | Bytes moved |
|---|---|---|
| `count(*)` | HEAD + 2 GETs of the footer (`bytes=28574615-28607382`) | 65 536 (0.2 %) |
| `WHERE id BETWEEN 1999000 AND 1999100` | footer + one 135 785 B row-group range | 201 321 (0.7 %) |
| `sum(m)` (one column) | footer + 17 per-row-group column-chunk ranges of ~8.4 KB | 202 950 (0.7 %) |
| `SELECT * LIMIT 5` | footer + one 1 753 459 B range | 1 818 995 (6 %) |
| `parquet_metadata()` | HEAD + 1 footer GET | 32 768 (0.1 %) |

Every GET is a genuine 206. Note the footer is fetched **twice** on every statement:
`enable_http_metadata_cache` is `false` by default.

**Measured — against a server that will not serve ranges.** Two behaviours, and only one of them
breaks:

- **Ignores `Range`, answers 200 with the whole body** (the common CDN/proxy case): works
  transparently. `read_csv` returns the right count, `read_parquet` and `read_blob` too. DuckDB
  accepts the 200 and reads the body.
- **Rejects with 416**: fatal, after the initial GET plus `http_retries` (3) more — **4 GET
  attempts**, then

  ```
  HTTP Error: HTTP GET error on 'http://…/data.csv' (HTTP 416 Range Not Satisfiable)
  This could mean the file was changed. Try disabling the duckdb http metadata cache if enabled,
  and confirm the server supports range requests.
  ```

**Consequence.**

- **Staging remote CSV on open is not a convenience, it is the only correct design.** Reading in
  place would re-download the whole object on every query, and the very first preview already
  costs 2×. Stage once, on open, into the existing staged-data budget and age-out — the budget
  needs a **remote** dimension, because 200 % of an unknown size is now a real number.
- **Remote parquet in place is confirmed.** `count(*)` costs 64 KB of a 28.6 MB file. The engine's
  paging and profiling already project columns and push down filters, so they get the benefit for
  free. Turning `enable_http_metadata_cache=true` (globally — see fact 8) is a one-line halving of
  the per-statement footer cost and should be part of the remote path.
- The 416 message is DuckDB's, it is three sentences, and it names a setting the user has never
  heard of. It has to be caught and turned into one clean sentence ("that server does not support
  range requests — Sift can download the file instead"), which is also the moment to offer staging.
  The 4-attempt retry means the user waits through the default 100/400/1600 ms backoff first.

**Pinned:** `remoteFact7a_csvOverHttpDownloadsTheWholeObjectWhateverTheSampleSize`,
`remoteFact7b_aServerThatRefusesRangesFailsButOneThatIgnoresThemWorks`,
`remoteFact7c_parquetOverHttpReallyDoesRangeRead`.

---

## 8. The httpfs timeout/retry knobs on 1.5.5, and their real scope

**Probe.** `SELECT name, value, description, input_type, scope FROM duckdb_settings()
WHERE name LIKE '%http%'` after `LOAD httpfs`, then `SET` / `SET GLOBAL` / `SET SESSION` on one
connection and a read from a sibling and from a connection opened afterwards.

**Measured — the knobs.** Sixteen settings; the ones that matter:

| Name | Default | Type | `scope` column |
|---|---|---|---|
| `http_timeout` | `30` (seconds, read/write/connect/retry) | UBIGINT | GLOBAL |
| `http_retries` | `3` | UBIGINT | GLOBAL |
| `http_retry_wait_ms` | `100` | UBIGINT | GLOBAL |
| `http_retry_backoff` | `4` | FLOAT | GLOBAL |
| `http_keep_alive` | `true` | BOOLEAN | GLOBAL |
| `enable_http_metadata_cache` | `false` | BOOLEAN | GLOBAL |
| `httpfs_connection_caching` | `false` | BOOLEAN | GLOBAL |
| `httpfs_client_implementation` | `default` | VARCHAR | GLOBAL |
| `allow_asterisks_in_http_paths` | `false` | BOOLEAN | GLOBAL |
| `http_proxy` / `_username` / `_password` | `''` | VARCHAR | GLOBAL |
| `enable_http_logging`, `http_logging_output` | deprecated | | LOCAL |

Retry arithmetic, confirmed against the 416 server: **1 initial attempt + `http_retries`** = 4 GETs,
with waits of 100 / 400 / 1600 ms.

**Measured — the trap.** The `scope` column says `GLOBAL`, and a bare `SET` is **session-local
anyway**:

```
A: SET http_timeout=3000         A reads 3000   B reads 30      new connection reads 30
A: SET GLOBAL http_timeout=10000 A reads 3000   B reads 10000   new connection reads 10000
A: SET SESSION http_timeout=…    A only
```

`scope` means "this setting *can* hold a global value", not "`SET` writes the global one". A
session override still wins on the connection that set it.

And before `LOAD httpfs`, `http_timeout` / `http_retries` / `http_retry_wait_ms` /
`http_retry_backoff` are **absent from `duckdb_settings()` entirely** — yet `SET http_retries=7`
**succeeds**, silently, while `SET totally_made_up_setting=1` is refused. DuckDB reserves the names
for the not-yet-loaded extension. The value sticks to that one connection; every connection opened
after the LOAD gets the default.

**Consequence.** Two rules for any remote timeout/retry configuration, and both are the kind of
thing that produces a bug report reading "the timeout setting does nothing":

1. **Always `SET GLOBAL`.** Sift hands work to throwaway connections. A bare `SET http_timeout` on
   the engine connection would configure exactly one connection and no queries.
2. **Always after `LOAD`.** A pre-LOAD `SET` is neither an error nor an effect.

The defaults are also wrong for an interactive tool: a 30 s timeout with 3 retries and 4× backoff
is a worst case of about 32 s of user-visible hang before the error appears. The remote path should
set `http_timeout` down and `http_retries` to 1, and `enable_http_metadata_cache=true` to stop
paying for the parquet footer twice per statement.

**Pinned:** `remoteFact8_httpTimeoutAndRetryKnobsAndTheirRealScope` — defaults, the declared scope,
the `SET`/`SET GLOBAL` split, and the silent pre-LOAD `SET`.

---

## 9. Does the azure extension expose a transport option on 1.5.5?

**Probe.** `SELECT name, value, description, scope FROM duckdb_settings() WHERE name LIKE '%azure%'`
after `LOAD azure`. No account required.

**Measured.** Yes — **`azure_transport_option_type`**, default `'default'`, GLOBAL, described as
"Underlying adapter to use with the Azure SDK … Valid values are: default, curl", and
`SET azure_transport_option_type='curl'` is accepted at runtime. Eighteen `azure_*` settings exist;
the ones the design will care about:

| Name | Default | Note |
|---|---|---|
| `azure_transport_option_type` | `default` | `default` \| `curl` |
| `azure_read_buffer_size` | `8388608` | 8 MiB |
| `azure_read_transfer_chunk_size` | `8388608` | max bytes per request |
| `azure_read_transfer_concurrency` | `5` | threads per parallel read |
| `azure_endpoint` | `blob.core.windows.net` | overridable |
| `azure_credential_chain` | `NULL` | e.g. `'cli;workload_identity;managed_identity;env'` |
| `azure_storage_connection_string` | `NULL` | the settings-based alternative to a secret |
| `azure_http_logging_redact_headers` | `Authorization` | redaction is on by default |
| `azure_http_logging_redact_query_params` | `sig` | SAS signature redacted by default |

**Consequence.** The knob exists, so the historical macOS reason for reaching for it — the default
WinHTTP/libcurl adapter misbehaving — is addressable without a version bump. Leave it at `default`
and keep `'curl'` as a documented escape hatch in the connection troubleshooting path rather than a
setting in the UI. Two better finds sit next to it: `azure_credential_chain` is the hook for "use
my `az login`" (no secret at all, which is the nicest possible credential story on a Mac), and the
Azure HTTP log **already redacts `Authorization` and `sig`** by default, so enabling Azure logging
for diagnostics does not leak a SAS token.

**Pinned:** `remoteFact9_azureTransportOptionTypeExists`.

---

## 10. CI canary: do `INSTALL httpfs` / `INSTALL azure` work on macos-15?

**Question.** Everything above ran on a Mac where the extensions were already installed. CI is the
only SDK oracle this project has, and it is also the only place where a cold `INSTALL` from
`extensions.duckdb.org` is exercised. Does the runner have the network and the signed binaries?

**Probe.** Branch `p1t0-ci-canary` with a draft PR, adding one step to
`.github/workflows/ci-native.yml`:

```yaml
      - name: Remote facts canary (httpfs + azure)
        env:
          SIFT_REMOTE_FACTS: "1"
        run: swift test --filter remoteFact
```

`SIFT_REMOTE_FACTS` is set only in that step, so the `swift test` step above it is untouched and
the main suite stays offline.

**Measured — run 1 (`31758872022`, red, and worth every minute).** The canary answered its
question and caught a bug that would otherwise have shipped as an intermittent test.

- **`INSTALL httpfs` and `INSTALL azure` work on macos-15.** Every test that only needs an
  extension passed on the runner: facts 1, 2, 6a, 6b, 6c, 8 and 9. Signed binaries for DuckDB
  1.5.5 exist for the runner's platform (`arm64e-apple-macos14.0`) and the runner has the network.
  All the Azure and secret findings above are therefore reproduced on a second machine, not just
  this Mac.
- **Every server-backed test failed, all with an empty request log**:
  `IO Error: Timeout was reached error for HTTP HEAD to 'http://127.0.0.1:PORT/…'`. Nothing was
  ever accepted. The whole step took **244 s**, all thirteen tests reporting at the same instant —
  every one of them sitting on the default 30 s `http_timeout` through its retries.

That is a defect in the oracle, not in DuckDB, and there were two of them. The accept loop ran on
`DispatchQueue.global()` with a blocking `accept()` — the textbook thread-starvation antipattern,
and thirteen parallel tests each blocked a pool thread — and `accept` returning `-1` with `EINTR`
was treated as fatal, killing the listener permanently. Both fixed: a real `Thread` per listener
and per connection, and only a genuinely dead socket ends the loop. `recv`/`send` retry on `EINTR`
too. The server-backed tests now also set `SET GLOBAL http_timeout=5` (loopback needs nothing
like 30 s), so a future environment that cannot reach the oracle fails in seconds instead of four
minutes.

**Measured — run 2 (`31759402330`), on the fixed oracle: green.** All 13 pass on macos-15 in
1.4 s, and the whole job drops from 6 m 37 s to 1 m 50 s. **Every fact in this document is now
reproduced on a second machine** — a different core count and a different SDK — so none of the ten
is an artifact of this Mac.

**Consequence.** Keep the canary step on the branch and keep the tests gated: the default suite
stays offline and CI stays a real check on `INSTALL`. Two lessons beyond the verdict: this project's
"CI is the only SDK oracle" rule extends to **concurrency and sockets**, not just the SDK — a
3-core runner surfaced a threading bug thirteen parallel tests could not surface on this Mac; and
any test that reaches the network must cap its own timeout, or one broken assumption costs four
minutes of CI per run. `INSTALL` being available on the runner does **not** settle the shipping
question: the app still cannot assume a user has network access at first open, so vendoring
`httpfs`/`azure` alongside `libduckdb` in `fetch-duckdb.sh` remains the right call for the app
bundle.

---

## 11. DuckDB caches remote objects itself, and it is on by default

Measured during Task 8, not during the spike — found by debugging a test that expected one GET on a
reopen and saw **zero**. Two `read_blob`s of one URL on one `Database`, against the loopback oracle:

| | pass 1 | pass 2 |
|---|---|---|
| `ETag` sent, `enable_external_file_cache=true` (the default) | 1 GET | **0 GETs** |
| `ETag` sent, cache off | 1 GET | 1 GET |
| no `ETag`, cache default | 1 GET | 1 GET |

`enable_external_file_cache` defaults to `true` (GLOBAL) and `validate_external_file_cache` to
`VALIDATE_ALL`: a repeat remote read inside one `Database` is revalidated with a HEAD and then served
out of the buffer manager when the server's `ETag` still matches. With no `ETag` there is nothing to
validate against and the object is refetched in full.

**Consequences, all three load-bearing:**

1. **"One download per open" is an upper bound, not an exact count.** A reopen of an ETagged URL
   inside one session legitimately costs zero GETs. A reopen assertion is therefore `<= 1`; `== 1`
   would pin DuckDB's cache-hit rate rather than Sift's design. The **cold-session** assertion stays
   exact, and that is where the mutation bar bites — restoring the read-the-URL-not-the-cache bug
   still shows 3 GETs and 300 % of the object across the wire.
2. **It is not a substitute for Sift's own cache.** DuckDB's lives in the buffer manager and dies
   with the `Database`. Sift's is a file on disk that survives relaunch and is what the local
   pipeline sniffs, stages, counts and bad-row-scans against.
3. **A server that sends no `ETag` gets no benefit from either cache** — and those are the same
   servers that force the fetched-per-open staging token, so a Sift copy of such an object is never
   adopted across opens either. The two mechanisms degrade together, which is the honest behaviour
   but means the worst case is a full refetch every time.

---

## Requires the manual checklist (an Azure account, not guessable)

Honest list of what this spike could not measure. None of it is guessed above.

1. **`az://` end-to-end with real credentials.** Everything Azure here stops at
   `Invalid Input Error: No valid Azure credentials found!` or at DNS. That a secret is *accepted*
   and *scoped* is measured; that it *authenticates* is not.
2. **Which Azure credential shapes actually work** — connection string, account key, SAS token,
   `azure_credential_chain` with `az login`, managed identity. The parameters bind; whether each
   provider resolves on a Mac with no Azure CLI is unmeasured.
3. **Azure-side read behaviour.** Whether `az://` parquet range-reads the way `http://` does, how
   `azure_read_transfer_chunk_size` / `_concurrency` actually shard a read, and what the request
   count looks like against real Blob Storage. The loopback oracle cannot answer this — the azure
   extension does not go through httpfs.
4. **Delta over `az://`.** Fact 3 rules out `http://`. delta-kernel-rs has its own Azure
   object-store backend and its own credential path, so `az://` Delta may work where `http://`
   cannot. Untested, and it is the difference between "remote Delta is out of scope" and "remote
   Delta is Azure-only".
5. **Container/blob listing.** Fact 4 rules out http globs, but `az://container/*.parquet` may work
   — the Azure filesystem can list a container, which generic HTTP cannot. If it does, the
   "explicit list only" consequence in fact 4 is http-only.
6. **Error text for a wrong key / expired SAS / missing container.** Every engine error must be one
   clean sentence, and that mapping cannot be written against errors nobody has seen.
7. **`abfss://` beyond the VFS gate.** `AzureDfsStorageFileSystem` is confirmed registered; nothing
   past the permission check was reachable without an account.
