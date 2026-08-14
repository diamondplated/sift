# P1 T8 — the `openPath` remote branch

A pasted URL becomes an open table. Everything before this was parts; this is the assembly.

**Base** `7e193c1` (846 tests) → **870 default / 31 gated**, warning-free, nothing `.serialized`.
Files touched: `Sources/SiftEngine/Session.swift`, `Sources/SiftEngine/Staging.swift`,
`Sources/SiftCore/Stage.swift`, `Tests/SiftCoreTests/StageTests.swift`, and the new
`Tests/SiftEngineTests/RemoteOpenTests.swift`. `RemoteProbe.swift` and `RemoteProbeTests.swift`
were not opened for editing; T7's API is called exactly as it stands.

---

## The flow, as shipped

`openPath` splits on `classifyRemote(trimmed)` **before** the `fileExists` guard — the ordering is
the branch. A URL is not a path: `realPath` leaves it alone and `stat` fails, so a gate placed after
`fileExists` answers `No such file or folder: https://…` for every remote source in the product.
`nil` from `classifyRemote` is the local flow, byte-for-byte untouched.

Then four gates, none of which touches a socket, followed by one detached build that does:

1. **Posture** — `allowRemoteAtLaunch`, never `connections().allowRemote`. Two different sentences,
   because the fixes differ: a user who has *already* flipped the switch is told to relaunch, and is
   not sent back to a screen that already says yes. That is T6's `ConnectionOutcome` truth rendered
   as prose.
2. **Extension** — through `installExtension`, not a raw read of `loadedExtensions`. This is a
   deviation from the brief's literal wording and it is deliberate: the brief said absent →
   "Sift bug", but *absent is a reachable, blameless user state* — an `az://` URL on a permissive
   session with no saved Azure connection has no `azure` entry at all, because
   `remoteExtensions(for:)` only asks for it when a connection needs it. Telling that user they hit
   a bug in Sift would be false. `installExtension` is idempotent, free when already loaded, and
   collapses "absent" into `.loaded` (this session is authorised to reach the network, so a first
   INSTALL is exactly what was asked for) or into one of the two real states. The tri-state is then
   genuinely exhaustive and `.rejectedName` keeps the "Sift bug" sentence it deserves.
3. **Azure connection match** — host prefix, else the single azure connection, else a sentence.
   Nothing is looked up *from* the match; the secret was issued at launch and DuckDB resolves it by
   scope. It exists so an unauthenticated Azure URL gets Sift's sentence instead of
   `Invalid Input Error: No valid Azure credentials found!`. A lone connection is accepted whatever
   the host says, because `az://container/blob` names the container and never the account — only
   `abfss://` carries one, and refusing otherwise would make `az://` unopenable for the ordinary
   single-account user.
4. **Detached build** (`buildRemoteOpen`) — its own `Connection`, created inside the task, touching
   no actor state and in particular never `pagingConnection`. The six users of that connection are
   still six; the header's list is unchanged and its invariant is untouched.

**One deviation inside the build, and it is a correction:** the brief ordered HEAD → format. I
reversed it to format → HEAD. The glob and Delta refusals live inside `remoteFormat` and are decided
from the URL text alone, so a HEAD in front of them sends a request on behalf of a source Sift has
already refused — and for Delta that refusal is the only thing between a URL and tombstoned rows
served as live data. With the reversal, `remoteFactOpen_globAndDeltaUrlsAreRefusedThroughOpenPath…`
asserts an **empty** request log, which it could not have done the other way round.

Downloads land at `<siftHome>/remote-cache/<fnv1a(sanitized)><suffix>`, directory 0700 (through
`ensureHomeDirectory`, reused rather than re-written), files 0600 (T7's `downloadRemoteObject`).
The URL is hashed rather than sanitized into a filename because an object key can contain `/` and a
percent-decoded `displayName` can contain `..` — both are traversal out of the cache directory.
Hashing the **sanitized** form (not `wireURL`) means two SAS'd fetches of one blob share a cache
entry instead of missing every time the token is re-issued.

`finishOpen` is the tail both branches share — name derivation, generation bump, notes,
`adoptStagedCopy`, catalog insert, detached `runAfterOpen`. Factored rather than copied: every line
of it is a rule with a review or a measurement behind it, and a second copy is a second place for
one of them to be quietly dropped.

## SAS ruling shipped: **download-once, note, no refusal**

The branch taken is the one the controller named as the way out: a SAS'd parquet is downloaded like
a text format, losing range reads and keeping the no-persisted-credential invariant, and the
sentence becomes a **note on the table** rather than an error. `sasParquetNote` carries the
reasoning. Plain `https://` parquet and `az://`-through-a-connection parquet still read in place.

The grep test checks every surface the signature could reach: `spec.target`, `spec.key.path`, the
`sql` DuckDB stored for the created VIEW, both persisted columns of `_sift_sources` (reached by
force-staging, which is also the "Download Local Copy" affordance that pays the note's cost back),
and all four snippet dialects.

## `runAfterOpen`: the adaptation is that there is none

Remote text is a local cache file by the time the pipeline runs, so the exact count and the bad-row
scan are the ordinary local steps reading an ordinary local file — no network, no branch. In-place
remote parquet skips both for the local reasons: `rowCount` came free from the footer, and
`rawRelationExpr` is `nil` for a format carrying real types. This is the download-once design paying
off, and the test proves it from the request log rather than from the row count, because a
re-fetching implementation produces *the same numbers*.

## `shouldStage(transport:)`

`Transport` changes **no threshold and no branch**, and `StageTests.transportChangesNoThresholdAndNoVerdict`
asserts that explicitly, `estSeconds` included. Inventing a different size for remote text would be a
policy no measurement supports — the bytes are local by then. What it changes is the sentence: "only
5.0 MB — re-reading **the downloaded copy** is faster than copying it", because the local wording
describes re-reading *the source*, which for a remote source would mean the network and is not what
happens.

**`stagingSizeBytes` is the substantive half of this, and it was not in the brief.** The decision is
made about the **cache file**, not `key.size`. `key.size` is the server's `Content-Length`, which is
**0** when no length was sent (silently disabling staging for the whole source) and the **compressed**
length for a `.csv.gz` (a 30 MB download that expands to 900 MB judged as 30). `stageNow` reads the
same helper, or the banner offers a copy that `stageNow` then refuses as "only 0 B".

## The three T7 handoffs

- **SAS + in-place parquet** — download-once branch, as above.
- **`stagingToken` reconciliation** — `if let remote = spec.remote { return remote.stagingToken }` is
  now the first line of `stagingToken`. There is no path left where a remote spec reaches the
  stat-based token. `remoteTokenPrefix` (pinned against the real builder, since the compiler cannot
  check it) is what `stagedEntries` and the staleness sweep use to recognise a remote row.
- **Extension-less remote CSV** — no new `Fmt` case, noted in `buildRemoteOpen`'s doc comment:
  `remoteFormat` probes parquet first (which ranges, not downloads), and anything falling past it is
  a text format step 3 was going to download anyway. Buying a case to save that one probe would put a
  second format decision outside `remoteFormat` — two places to disagree about what a URL is.

## Staged-catalog honesty

`stagedEntries` reports a remote row as **neither missing nor changed**. The local rule reads a
failed `stat` as `sourceMissing: true`, which would put a red "source missing" badge on every remote
copy the instant the staged-data panel opened — the plausible-wrong-value failure this product
exists to avoid, in Sift's own UI. Answering the question honestly needs a HEAD per row; `Refresh`
(T10) is where that belongs.

The staleness sweep skips remote rows **explicitly**, not by relying on `statInfo` failing on a URL.
That reliance works today and fails silently the day anything makes such a stat succeed — dropping
every remote copy on the next purge with the suite green.

---

## Tests

`Tests/SiftEngineTests/RemoteOpenTests.swift`, plus three additions to `StageTests`.

**Ungated (17)** — everything a strict session does (each asserting an **empty** request log), the
Azure connection sentences (reached by making `checkRemoteConnection` internal, so a sentence about
a missing connection does not need a network to prove), the staging-token identity rules, the
catalog-honesty pair, and the cache-path/suffix rules.

**Gated `SIFT_REMOTE_FACTS=1` (7, prefixed `remoteFactOpen_`)** — a served CSV, a served parquet, the
SAS'd parquet, adoption in both directions, the stale-copy trap, the staging decision, and the
glob/Delta refusals. Gated because a permissive `Session` asks for `httpfs` in `init` and
`loadExtensions` does LOAD→INSTALL→LOAD.

The served-CSV test is **gzipped**, which was not the plan and is better: it is the only way to get a
real bad row (an uncompressed CSV under `fullSniffMaxBytes` is sniffed whole, so the sniffer types
the column VARCHAR and there is nothing to fail to cast — the same reason `SessionTests` reaches for
gzip), it leaves `spec.rowCount` nil so the exact count *must* come from the background pipeline
reading the cache, and it exercises the `.csv.gz` two-suffix cache rule end to end.

### Mutation bar — all four red, one of them instructively

| Mutation | Result |
|---|---|
| Posture gate deleted | Red. The user gets `Permission Error: File system HTTPFileSystem has been disabled by configuration`, **and a HEAD goes out** — the gate's real job, caught by the empty-log assertion. |
| Token fallthrough restored | Red, and it **reproduces the bug**: the reopened table comes back `staged: true` serving `"AAAA"` from a URL that now returns `"BBBB"`. |
| Count reads the URL, not the cache | Red: **3 GETs and 300 %** of the object across the wire — the spike's measured 200 %-extra, exactly. |
| SAS'd parquet read in place | Red: no note, no cache path, 4 ranged GETs. |

The stale-copy mutation is worth a line. My first version of the adoption test used a server sending
no `Last-Modified`, and the mutation went red for a weak reason (adoption merely stopped working).
`remoteFactOpen_aChangedObjectBehindAReusedDateAndLengthIsNotAdopted` constructs the dangerous
direction instead: same path, same `Last-Modified`, same `Content-Length`, different bytes and a new
`ETag` — a re-upload inside one second of a file whose size did not change. The local
`(path, mtimeNs, size)` token is byte-identical across that change, so the fallthrough adopts the old
copy and serves yesterday's rows forever. This is why `remoteStagingToken` uses the `ETag` **alone**
when one exists rather than combining it with the date.

### Mutation 4's shape is the argument for the ruling

With the SAS branch deleted, the read **succeeded** against the loopback oracle — 4 ranged GETs,
right answer — because the oracle ignores query strings and authenticates nothing. Against real Azure
it is a 403. A regression here works perfectly on every machine that can test it and fails only on
the customer's. The note and the cache path are the only observable difference, which is why both are
asserted.

---

## NEW MEASUREMENT — DuckDB's own external file cache (fold into the facts doc)

Found while debugging a test that expected one GET on a reopen and saw **zero**. Measured on the
vendored 1.5.5 against the loopback oracle, two `read_blob`s of one URL on one `Database`:

| | pass 1 | pass 2 |
|---|---|---|
| `ETag` sent, `enable_external_file_cache=true` (the default) | 1 GET | **0 GETs** |
| `ETag` sent, cache off | 1 GET | 1 GET |
| no `ETag`, cache default | 1 GET | 1 GET |

`enable_external_file_cache` defaults to **`true`** (GLOBAL) and `validate_external_file_cache` to
`VALIDATE_ALL`: a repeat remote read inside one `Database` is revalidated with a HEAD and served from
DuckDB's buffer manager when the server's `ETag` still matches. Without an `ETag` the cache cannot be
validated and the object is refetched.

Three consequences:

1. **"One download per open" is an upper bound, not an exact count.** A reopen of an ETagged URL in
   the same session legitimately costs zero. The reopen assertion is `<= 1` with the measurement
   recorded inline; `== 1` there would pin DuckDB's cache-hit rate rather than Sift's design. The
   cold-session assertion stays exact, which is where the mutation bar bites.
2. **It is not a substitute for Sift's cache.** DuckDB's lives in the buffer manager and dies with
   the `Database`; Sift's is on disk and survives relaunch, and is what the local pipeline sniffs,
   stages and scans against.
3. **A server with no `ETag` gets no benefit from either cache** — the same servers that force the
   `fetched=` token form. The two facts line up, which is reassuring but worth stating.

## Concerns for whoever picks this up

- **The glob/Delta refusals through `openPath` are gated**, and only because gate 2 runs before the
  URL is looked at. The refusals themselves reach no socket (the test asserts an empty log); it is
  the permissive `Session` around them that needs `httpfs`. Moving the extension check after the
  build would ungate them at the cost of a worse sentence for the common case, which is a bad trade.
- **The cache is never swept.** `<siftHome>/remote-cache` grows without bound; T10 owns the sweep.
  Nothing in `purgeStaged` or `sweepPrivateStores` looks at it, and the directory name will not
  collide with either.
- **`checkRemoteConnection` is advisory.** It refuses when it can see no plausible connection, but a
  saved connection whose *credential* is wrong still fails at read time with DuckDB's words.
  `connectionIssues()` is the channel that knows, and nothing joins the two yet — that is a UI join
  (T11), but worth flagging so it does not get lost.
- **`az://` with several saved Azure connections is accepted whenever the host happens to match a
  container name.** The match is a coincidence there, not an authentication. It only ever *allows*,
  never denies wrongly, so the failure mode is DuckDB's credential error rather than Sift's sentence.
- **`fetchClockNs` is wall-clock on purpose** — uptime restarts at zero every boot and this value is
  compared on a later launch. A clock moved backwards by NTP could in principle collide two
  `fetched=` tokens; the window is microseconds against fetches that are milliseconds apart at best.
