# Phase 1, Task 7 — `RemoteProbe.swift`: identity, format, download, refusals

Base `8111a79` (branch `native`). Measured on macOS 26 (Darwin 25.3), arm64, against the vendored
`libduckdb` 1.5.5.

**Status: done.** Warning-free from a wiped `.build`. **817 default tests pass** (793 before, +24
declared, 8 of them gated and skipped). `SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` →
**24/24 green in 0.9 s** (16 before). `swift run sift --verify` → 20/20. Both suites run 3× back to
back with no flake.

Files: `Sources/SiftEngine/RemoteProbe.swift` (new), `Tests/SiftEngineTests/RemoteProbeTests.swift`
(new), `Sources/SiftCore/Types.swift` (the `RemoteRef` addition the task authorised). `Session.swift`
and the sibling's `Keychain.swift` untouched.

---

## 1. Five new measurements, each of which changed the code

Everything below was measured here, against the loopback oracle and the vendored dylib. They are
cited at the line that depends on them.

| # | Question | Answer | What it decided |
|---|---|---|---|
| A | Can a remote object's size be learned without downloading it? | **Yes.** `read_blob` returns `filename, content, size, last_modified`, and `SELECT size FROM read_blob(url)` issues **one HEAD and no GET** | The download cap's first check costs nothing, so it protects the machine and not just the disk |
| B | Can the blob be sliced for a chunked read? | **No.** `substring(BLOB, BIGINT, BIGINT)` is a `Binder Error` on 1.5.5 | The object crosses into Swift as one `to_base64` string; the ceiling and its upgrade path are a `ponytail:` note |
| C | Is `to_base64` → `Data(base64Encoded:)` byte-exact? | **Yes**, on 1 MiB of non-compressible bytes, and 1.33× rather than `hex`'s 2× | No hand-written decoder in the path that produces the cached file |
| D | Does `read_csv` reject JSON? | **No.** `DESCRIBE SELECT * FROM read_csv(<a JSON array>)` SUCCEEDS, reporting two VARCHAR columns named `[{"a":1}` and `{"a":2}]` | The DESCRIBE fallback probes **parquet → json → csv**. CSV before JSON opens every extension-less JSON document as a table of nonsense |
| E | What does DuckDB do when a HEAD's length disagrees with the GET's? | It detects it itself: `HTTP Error: The size reported by HEAD … was 12 bytes, but the full GET downloaded 524288 bytes. You can try to resolve this by enabling SET force_download=true` | Recorded, not relied on — three sentences naming a setting the user has never heard of, and `force_download` is GLOBAL and would kill parquet's range reads. Sift's own post-download check is the one that produces a sentence |

Two facts from the spike were re-measured and held: a DESCRIBE over a remote **parquet** moved
32 KB of a 1.73 MB file in three ranged requests, while a DESCRIBE through `read_csv` or
`read_json_auto` moved 100 % of it; and an http glob is refused at plan time with zero requests
logged.

## 2. The API, as shipped

Every signature is as specified. Deviations, each with its reason:

| Change | Why |
|---|---|
| `downloadRemoteObject`'s `capBytes` gained a default, `remoteDownloadCapBytes` (500 MB) | The task says the cap and its sentence live here; a `public let` beside the sentence is where a caller can read it, and every call site still passes one if it wants to |
| `buildRemoteSource` takes no `fmt` | It is derivable and would be a second source of truth. `cachePath != nil` ⇒ the bytes are local, so `buildSource`'s own magic-byte `detectFormat` decides — a parquet behind a `.csv` URL is caught exactly the way a local one is. `cachePath == nil` ⇒ parquet read in place, which is the only format that may be |
| `buildRemoteSource` takes `fetchedAtNs` | The caller owns the clock, exactly as `remoteStagingToken` requires. The `fetched=` token form is what makes a copy with no server identity un-adoptable, and it only works if distinct fetches produce distinct values |
| `remoteFormat` also throws `LegacyXls` for a remote `.xls` | The local flow refuses it with a sentence naming the way out; a remote one would otherwise be downloaded first and fail confusingly afterwards |
| `remoteFormat` sees through one compression suffix | `RemoteURL.effectiveExt` is the final suffix, so `…/a.csv.gz` reads as `.gz` and would fall through to three DESCRIBE round trips to rediscover something the URL says out loud |
| The DESCRIBE probes run for every scheme, not only http(s) | Fewer branches, and strictly more capable: an extension-less `az://` object with a working secret is detected rather than refused. A scheme that cannot authenticate fails into the same one sentence |
| `SourceSpec.target` became `remote?.cachePath ?? glob ?? key.path` | Otherwise a downloaded object would be re-read from its URL — 200 % of the object per statement (spike §7). `remote` is `nil` for every existing spec, so `target` is unchanged for all of them, and there is a test that says so |

## 3. `RemoteRef` (Types.swift), and the one thing it deliberately does not carry

```swift
public struct RemoteRef: Sendable, Equatable {
    public let url: String            // RemoteURL.sanitized
    public let etag: String?
    public let lastModifiedMs: Int?
    public let contentLength: Int?
    public let fetchedAtNs: Int
    public let cachePath: String?     // nil = read in place (parquet)
    public var stagingToken: String   // derived, never stored
}
```

Added last in `SourceSpec`'s memberwise init with a `nil` default, so every existing construction
site compiles and behaves identically. Pure data, Foundation-only — `SiftCore`'s rule holds.

🔴 **No credential is in it.** A SAS token rides in `RemoteURL.query`, in memory, and is rejoined
to the URL by `wireURL` at the moment of the call that needs it — never stored. A `SourceSpec`
outlives that moment: it is rendered into a `CREATE VIEW` that DuckDB writes into the on-disk store,
and its `key.path` is written into `_sift_sources`. A query string in either place is a bearer
credential on disk. The corollary is a KNOWN GAP for the next task, flagged on `buildRemoteSource`:
an in-place parquet's `target` is the *sanitized* URL, so a pasted SAS does not survive into later
reads. The designed answer is a DuckDB secret (`createSecretSQL`), which resolves by scope and needs
nothing in the URL.

`stagingToken` is derived rather than stored, so the `v3|` format has one spelling, per the
`stagingTokenVersion` comment's own warning.

## 4. `downloadRemoteObject`, and why the cap is checked twice

1. **The claim** — `SELECT size FROM read_blob(?)`, which is one HEAD and no GET (measurement A).
   Over the cap: refused with nothing downloaded. This is the check that matters.
2. **What arrived** — the download lands in a connection-scoped TEMP table, `octet_length` is read
   off it, and only then is the object encoded for the trip into Swift. Over the cap: refused,
   before the encode. Base64-ing 3 GB in order to refuse it is a swap storm, not a refusal.

The second check is not theatre: the claim and the download are two separate HTTP transactions
(`enable_http_metadata_cache` is `false` by default), so the object can be replaced in between. The
test builds exactly that — a server that under-reports on its **first** HEAD and is honest
afterwards.

The file is written in one `createFile` call at 0600, from a fully-formed `Data`. MEASURED: unlike
`createDirectory`, `createFile`'s attributes **are** applied over a path that already exists, so the
chmod I first wrote behind it was a line no mutation could kill; it is gone and the test now
downloads over a stale 0644 file to prove the single call is enough.

DuckDB puts the URL it was handed into its own error text, SAS token and all. Every failure from a
statement that carried a `wireURL` is rethrown as a `DuckDBError` whose message has the query
replaced with `?…`, so `Session`'s existing `catch let error as DuckDBError` mapping is unchanged.

## 5. Tests — 24, of which 16 need no network and no extension

The refusals, the extension table, the whole of `remoteIdentity` and both cached-spec shapes run in
the **default** suite: refusing before the wire is precisely what makes them testable offline, and
the identity probe is `URLSession` talking to a socket. Only `httpfs`-dependent work is gated
(`SIFT_REMOTE_FACTS=1`, named `remoteFactProbe_*` so CI's `--filter remoteFact` canary picks them
up).

Two server personalities `LoopbackHTTPServer` deliberately does not have live in the **test** file
as `RudeServer`, per the task: one that accepts a connection and never answers (the timeout test),
and one whose first HEAD under-reports its length (the second cap test). Same two hard-won rules as
the oracle — Darwin sockets, real `Thread`s, `EINTR` is a retry.

## 6. Mutations — 17 applied, 15 red, 2 recorded survivors

| # | Mutation | Killed by |
|---|---|---|
| 1 | glob refusal deleted | `aRemoteGlobIsRefusedWithoutTouchingTheNetwork` |
| 2 | Delta refusal deleted | `aRemoteDeltaTableIsRefusedWithASentenceThatSaysToDownloadIt` |
| 3 | legacy `.xls` refusal deleted | `aRemoteXlsIsRefusedTheWayALocalOneIs` |
| 4 | compression suffix not seen through | `theRemoteExtensionTableHolds` |
| 5 | CSV probed before JSON | `remoteFactProbe_jsonIsProbedBeforeCsvBecauseReadCsvAcceptsJson` |
| 6 | pre-download cap bypassed | `remoteFactProbe_theCapRefusesBeforeAnyBodyByteWhenTheServerSaysTooBig` |
| 7 | post-download cap bypassed | `remoteFactProbe_theCapStillRefusesWhenTheServerLiedAboutTheLength` |
| 8 | cache file written 0644 | `remoteFactProbe_theDownloadIsByteExactWrittenAt0600AndFetchedExactlyOnce` |
| 9 | SAS redaction deleted | `remoteFactProbe_aFailedDownloadLeavesNoFileAndNoSasToken` |
| 10 | HEAD status not checked (a 404 becomes an identity) | `aRefusedHeadIsNoIdentityRatherThanAnEmptyOne` |
| 11 | `Last-Modified` recorded in seconds, not ms | `aServerWithNoEtagStillYieldsALastModifiedAndALength` |
| 12 | `acceptsRanges` hard-coded `true` | `acceptsRangesFollowsTheHeaderRatherThanHope` |
| 13 | `target` ignores the cache copy | `aCachedRemoteSourceIsKeyedByItsUrlAndReadFromItsLocalCopy` |
| 14 | `Last-Modified` never reaches the `SourceKey` | `aCachedRemoteSourceIsKeyedByItsUrlAndReadFromItsLocalCopy` |
| 15 | HTTP date parsed in the machine's timezone | `remoteIdentityReadsEtagDateLengthAndRangeSupportOffOneHead` |
| 16 | *(survivor)* the scheme guard on `remoteIdentity` deleted | — `URLSession` refuses `az://`/`s3://` itself with `NSURLErrorUnsupportedURL`, so the `nil` comes out of the same door. Kept and **documented in the code as a clarity guard**: the reason those schemes have no identity is a design fact, not a Foundation limitation |
| 17 | *(survivor)* the `removeItem` after a failed `createFile` deleted | — reachable only through a filesystem that fails part-way, which no test can arrange. Kept and documented; the property it backs up is structural and is tested three times (`!fileExists` after each refusal) |

Mutation 8 is the one worth reading twice: the first version of it stayed green because I had
written `createFile(attributes:)` **and** a `setAttributes` behind it, and each covered the other.
That is what sent me to measure whether the second line does anything (it does not) and to delete
it — a redundancy that also made the guard untestable.

---

## Concerns

1. **CI is unverified.** No push from this clone. The new surfaces most likely to trip macos-15 are
   `URLSession.data(for:)` inside a non-actor `async` free function, and the `RudeServer` raw
   sockets in the test target — though the sibling's `LoopbackHTTPServer` already binds loopback on
   the runner, and fact 10 measured `INSTALL httpfs` as working there.
2. **The SAS-in-`target` gap is real and is the next task's to close** (see §3). Today a pasted
   SAS'd **parquet** URL builds a spec whose reads are anonymous. A pasted SAS'd **CSV** is fine —
   the token is used for the download and never needed again. The refusal-vs-secret decision belongs
   with whoever wires `Session.openPath`.
3. **`stagingToken(spec)` in Staging.swift does not know about `RemoteRef`.** It runs `statInfo` on
   `spec.key.path`, which for a URL simply fails and is skipped, so it produces
   `v3|<url>|<mtime>|<size>` — prefixed correctly, so the purge's format sweep keeps it, and
   self-consistent, so `adoptStagedCopy` still matches. But it is NOT `RemoteRef.stagingToken`, and
   the two will need reconciling when remote sources start being staged. Staging.swift was outside
   this task's file list.
4. **An extension-less remote CSV costs three round trips to identify** — a ranged parquet probe,
   then a whole-object `read_json_auto` DESCRIBE, then a whole-object `read_csv` DESCRIBE, and the
   object is then downloaded a third time for the cache. Acceptable for the rare case, but if the
   Connections UI encounters it often, the better shape is: probe parquet, and otherwise download
   once and let `detectFormat` read the magic bytes off the cache. That needs a way to say "not
   parquet, find out locally", which `Fmt` has no case for today.
5. **`byteCount` rounds down to whole MB** (`1.9 MB` prints as `1 MB`). Deliberate — a cap sentence
   needs the magnitude, and no `NumberFormatter` family member may touch a user-visible string —
   but it is a number a user could quibble with.
6. **The 500 MB cap is a guess, not a measurement.** Nothing in the spike says what the right number
   is; it is the value the task named. The memory ceiling behind it is measured and documented on
   `downloadRemoteObject` (≈2.3× the object, because the blob cannot be sliced), so raising the cap
   is not free.

---

# Follow-up (p1t7b) — the deadline is Sift's, not the host's

Base `79083ca`. CI was red on `aServerThatNeverAnswersTimesOutIntoNilRatherThanHanging`: on the
macos-15 runner the probe took **31.05 s** against a 1 s deadline, and the test's flat 10 s ceiling
caught it. Not flakiness — a real gap.

**Status: done.** Warning-free from a wiped `.build`. **845 → 846 tests**, five consecutive full runs
green. `SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` → 24/24. `swift run sift --verify` →
20 passed, 1 skipped (the new remote check, which needs `httpfs`).

## What was actually wrong

`remoteIdentity` documented a 5 s contract and then handed enforcement to
`URLRequest.timeoutInterval`. MEASURED, both ends:

| Machine | Asked | Taken |
|---|---|---|
| This Mac | 0.01 / 0.05 / 0.1 / 0.25 / 1 / 3 s | 0.020 / 0.052 / 0.103 / 0.258 / 1.009 / 3.003 s |
| macos-15 CI | 1 s | **31 s** — the OS default |

There is no timeout value at which the knob fails locally, which is the sharpest form of the SDK
skew AGENTS.md warns about: this Mac makes an unbounded call look bounded to the millisecond.

## The fix

`withDeadline(_:_:)` — a `TaskGroup` racing the work against a `Task.sleep`, first result wins,
loser cancelled. `remoteIdentity` runs its HEAD inside it. The knobs stay, as belt, on a session of
Sift's own (`URLSession.shared`'s configuration is fixed, so `timeoutIntervalForResource` cannot be
set on it at all) — but the race is the enforcement, so the contract holds whatever the host does.

It is a separate function rather than four inlined lines for one reason, stated in a `ponytail:`
note: on a machine where the OS knob works, a test of `remoteIdentity`'s elapsed time cannot tell a
raced probe from an unraced one. `withDeadline` can be tested directly.

## The test bound, and three yardsticks thrown away

Tightening the ceiling to `timeout + 2` (as suggested) failed immediately — but for a reason worth
recording, because it is not about this change at all. MEASURED under the **full parallel suite**
(~850 tests, much of that blocking a cooperative-pool thread inside a synchronous DuckDB call — the
same starvation `StageJob` uses a real `Thread` to escape):

- a bare top-level `Task.sleep(1)` took **6.3 s**;
- a 1 s `withDeadline` fired at **9.3 s** (instrumented: the group's *winner* arrived at 9.26 s and
  the group exited at 9.26 s — so the cancelled loser costs nothing, the sleeper itself is late);
- the same 1 s deadline alone takes **1.02 s**.

So a tight wall-clock bound measures the thread pool, not the deadline. Three self-calibrating
yardsticks were built and deleted in turn: a bare sleep measured *after* the probe (measures a pool
that has already freed up — 1.51 s against a 4.67 s probe), one measured *alongside* it with
`async let` (right idea, wrong machinery — 6.33 s against a 10.12 s probe), and `withDeadline` itself
run alongside on the same budget (closest — within ~3.2 s, the residual being the URLSession child
contending for the same pool). Each is more code and more explanation than the thing it protects.

What made all of them unnecessary: **the deadline now has a test with no clock in it.**

```swift
let answer: String? = await withDeadline(0) {
    try? await Task.sleep(nanoseconds: 30_000_000_000)
    return "the slow answer nobody waited for"
}
#expect(answer == nil)
```

A zero budget against 30 s of work: the *answer* says whether the race exists, which is decidable
under any load. It runs in **0.001 s** and goes red immediately instead of thirty seconds later.

With the mechanism pinned that way, the end-to-end test only has to separate 31 from 1, so its bound
is a flat `< 20` — twice the worst jitter measured here, well under the number it exists to fail on,
and with the reasoning and both measurements in the comment beside it.

## Mutations

| Mutation | Result |
|---|---|
| the deadline sleeper deleted from `withDeadline` | 🔴 `theDeadlineIsSiftsOwnClockAndNotTheHostOperatingSystems` — **30.9 s**, the work outlived a zero budget |
| `remoteIdentity` stops calling `withDeadline` (knobs only) | 🟢 **survives locally: 1.018 s vs 1.010 s raced.** This Mac honours the knob to the millisecond, so no assertion about elapsed time can tell the two apart here. It is killed on macos-15, where the same mutant IS the 31 s failure this follow-up exists for — recorded in the code, not hidden |

## Concerns

1. **The surviving mutant above is CI-only, by construction.** Nothing in the local suite proves
   `remoteIdentity` still routes through `withDeadline`; the runner is the oracle. That is now
   written on `withDeadline` itself so the next reader does not "simplify" the race away on the
   evidence of a green local run.
2. **`withTaskGroup` awaits the loser at scope exit.** Instrumented here, the cancelled
   `URLSession.data(for:)` unwinds instantly (winner and exit at the same 9.26 s), so it costs
   nothing — but that is measured on this Mac only. If CI ever shows the deadline firing on time and
   the call still taking 31 s, this is the place to look, and the fix is an unstructured task the
   caller never awaits.
3. **Pool starvation is not mine, but it is now measured.** A 0.3 s `Task.sleep` taking 5.8 s inside
   the suite is the same contention the earlier reports saw as "ten SiftUI profile tests time out
   under load". Any future test that asserts on elapsed time in this suite needs a bound like this
   one's, or the same measurement will bite it.
4. **`sift --verify` now reports 21 checks, one skipped** — the sibling's remote check, gated behind
   `SIFT_REMOTE_FACTS=1`. Not mine, but it changes the line the last report quoted as 20/20.

---

# Follow-up 2 (p1t7c) — the deadline gets off the cooperative pool

Base `7e193c1`. The `TaskGroup` race shipped in p1t7b was still red on CI at **32.4 s**. The race was
real; the racehorse could not reach the track.

**Status: done.** Warning-free from a wiped `.build`. **846 tests**, four consecutive full runs
green. `SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` → 24/24. `swift run sift --verify` →
20 passed, 1 skipped.

## Why the first race lost

A `Task.sleep` child has to be **scheduled before its budget starts counting**. On a 2-core runner
under this suite's load it never got a cooperative thread inside the window, while `URLSession`'s
own threads went on ticking to the OS default. A deadline that queues behind the resource it is
protecting against is not a deadline.

The repo already had the answer and I had already quoted it: `StageJob` escapes the cooperative pool
with a real `Thread`, for this exact reason.

## The mechanism now

```swift
await withCheckedContinuation { continuation in
    let gate = OnceGate(continuation)          // NSLock; first resume wins, the loser is dropped
    let finished = DispatchSemaphore(value: 0)
    let job = Task { let v = await work(); _ = gate.finish(v); finished.signal() }
    Thread.detachNewThread {
        if finished.wait(timeout: .now() + max(0, timeout)) == .timedOut, gate.finish(nil) {
            job.cancel()
        }
    }
}
```

Three properties, each load-bearing:

- **The timer is a real `Thread`**, armed synchronously before any `await`, so the budget starts at
  call time whatever the pool is doing.
- **The wait is a `DispatchSemaphore`, not `Thread.sleep`** — the thread is released the instant the
  work wins, instead of parked for the whole budget on every successful probe.
- **The loser is cancelled and never awaited**, so a slow unwind cannot hold the caller. The honest
  cost is one unstructured `Task` that outlives the call.

`OnceGate` exists because a `CheckedContinuation` resumed twice is a crash. `@unchecked Sendable`
for the same reason `StageJob` is, and everything crossing the boundary goes through its lock.

## The local reproduction the plan asked for: built six ways, and it does not reproduce

The prize was turning the unkillable Mutant A ("race removed, knobs only") into a killable one by
saturating the pool inside the test. I built it and measured it, twice over: jammers blocking on a
semaphore and jammers **spinning on the CPU** (the pool grows extra threads when its own are
*blocked*, so only a spin actually jams it), at 1x, 2x and 4x the core count, three trials each.

| Jam | A — `Thread` timer | B — `Task.sleep` timer | C — knobs only |
|---|---|---|---|
| spin x1 | 1.01 s | 1.07 s | 1.00 s |
| spin x1 | 1.01 s | 1.06 s | 1.01 s |
| spin x4 | 1.01 s | 1.03 s | 1.01 s |
| spin x4 | 1.00 s | 1.04 s | 1.00 s |
| blocked x1/x2/x4 (9 trials) | 1.00–1.02 s | 1.06 s | 1.00–1.01 s |

**All three variants answer in ~1.0 s under every saturation this machine can be put into.** An
8-core Mac over-subscribes for blocked threads and time-slices spinning ones; it cannot be starved
the way a 2-core runner is. One early reading of C = 4.02 s was cross-test interference from a
second jamming test running in parallel, not a reproducible separation — chased down and discarded
rather than shipped as a green bar.

So the harness is **not shipped**. It would have been a 5-second, load-sensitive test in an already
contended parallel suite, proving nothing on the machine that runs it. What is shipped instead is
the finding, written on `withDeadline` itself so the next person does not spend the same afternoon.

## The failure that proves the deadline is now real

Three tests went red the moment the `Thread` timer landed —
`acceptsRangesFollowsTheHeaderRatherThanHope`, `anUnparseableLastModified…`, and the etag/date/length
one — because a HEAD that **succeeds** but whose delivery is starved past 5 s now gets cut off. That
is correct in the app and reachable in this suite, and it is the clearest evidence available that
the budget is being enforced: under the old mechanism the deadline was starved by exactly as much as
the response, so the response always won.

Fixed where it belongs: those tests are about *parsing*, so they now pass an explicit
`parsingBudget` (60 s) instead of silently riding the 5 s default. A test about header parsing must
not be a test about the deadline.

## Mutations

| Mutation | Result |
|---|---|
| the timer thread deleted | 🔴 `theDeadlineIsSiftsOwnClockAndNotTheHostOperatingSystems` — **30.7 s**, work outlived a zero budget |
| the `Thread` swapped back to a `Task.sleep` | 🟢 survives locally (0.001 s) — this Mac cannot be starved, see the table |
| `remoteIdentity` stops calling `withDeadline` | 🟢 survives locally (1.017 s vs 1.010 s raced) — unchanged from p1t7b |

## Concerns

1. **Two mutants survive locally and CI is the only oracle for both.** That is now measured rather
   than asserted — six jam configurations, twelve trials — and recorded on `withDeadline`. If a
   future change makes the deadline pool-dependent again, only the runner will say so.
2. **The unstructured `Task` outlives the call when the deadline wins.** It is cancelled, and
   `URLSession` unwinds it promptly here, but nothing awaits it. That is the deliberate price of not
   letting a slow loser hold the caller — the thing that made the `TaskGroup` version wrong.
3. **`parsingBudget` is 60 s, which is generous on purpose.** If a parsing test ever fails on the
   deadline again, the pool is starved for a minute and the suite has a bigger problem than this
   file.
4. **One OS thread per probe, for at most the budget.** `remoteIdentity` is called once per remote
   open, so this is cheap — but a caller that probed hundreds of URLs in a loop would want a shared
   timer, and there is no such caller today.
