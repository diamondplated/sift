# Phase 1, Task 2 — `LoopbackHTTPServer`

**Status: done.** Two files, both new, nothing else touched.

- `Sources/SiftEngine/LoopbackHTTPServer.swift` (≈280 lines)
- `Tests/SiftEngineTests/LoopbackHTTPServerTests.swift` (15 tests: 14 unit, 1 gated)

`swift test` goes **742 → 757 declared**, all green from a wiped `.build` with **zero warnings**.
`SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` runs **14** (the spike's 13 plus mine) in
0.9 s. `swift run sift --verify` still 20/20. The loopback tests were run 5× back to back with no
flake.

## What it is

Started from the spike's oracle at the bottom of `Tests/DuckDBKitTests/RemoteFactsTests.swift` and
kept both non-negotiable lessons, with the measured reasons carried into the doc comment:

1. **Darwin sockets, not `Network.framework`** — `NWListener` cannot bind on this Mac at all.
2. **Real threads, not `DispatchQueue.global()`** — a blocking `accept()` on the global pool
   starved 13 parallel tests on CI into empty-log timeouts. `EINTR` from `accept` is a retry.

What changed from the spike, all of it demanded by the contract: a live registry
(`register`/`unregister`) instead of a fixed file map fixed at init, per-path response headers,
**per-path** range personality instead of a whole-server mode, and a clean `stop()`.

## Contract, as shipped

```swift
public init() throws
public let port: UInt16
public var baseURL: String                              // "http://127.0.0.1:<port>"  (added)
public func register(path:body:headers: = [:], rangeMode: RangeMode = .honor)   // (added param)
public func unregister(path:)
public var requestLog: [(method: String, path: String, range: String?, status: Int)]
public func stop()
public enum RangeMode: Sendable { case honor, ignore, reject }
```

Two additions to the stated signature, both defaulted so every call written against the spec still
compiles:

- **`rangeMode:` on `register`** — the task requires ignore-Range and always-416 to be *switchable
  per path*, and the given `register` had nowhere to say so. A defaulted fourth parameter was the
  smaller change than a second `setRangeMode(path:)` call every fixture would have to make.
- **`baseURL`** — one line, and otherwise every remote test re-derives the same string.

Semantics, each pinned by a test:

| Case | Answer |
|---|---|
| `GET`, no `Range` | 200 + whole body, `Accept-Ranges: bytes` |
| `HEAD` | 200, `Content-Length` of the **whole** object, registered headers, **no body** |
| `Range: bytes=s-e` / `bytes=N-` / `bytes=-N` | 206 + correct `Content-Range`; an end past EOF is clamped |
| `Range` starting past EOF (and any range on an empty body) | 416 + `Content-Range: bytes */total` |
| `Range` this parser cannot use (other unit, multi-range, garbage) | 200 + whole body, like a real origin |
| `rangeMode: .ignore` | 200 + whole body, `Accept-Ranges: none`, header still logged |
| `rangeMode: .reject` | 416 to any `Range`, satisfiable or not; a plain GET and a HEAD still work |
| unknown path | 404 |
| unsupported method | 405 + `Allow: GET, HEAD`, decided **before** the path (so `DELETE /missing` is 405) |

Registered headers override the generated ones; header order is sorted so wire assertions are
stable.

## `stop()` — why it is shaped the way it is

The requirement was "no leaked threads/sockets", and the obvious `close(fd)` does not meet it.
Closing a descriptor another thread is blocked in `accept()` on does not reliably wake it, and the
instant the number is free the next socket in the process can be handed it — a stale `accept()`
then serving somebody else's listener. So:

- the accept loop **owns** the listening fd and is the only thing that closes it;
- `stop()` unblocks it with a **real loopback connection**, held open until the listener has exited
  (a probe closed too early can be reset out of the accept queue and never picked up);
- live client sockets get `shutdown()`, not `close()` — it wakes a handler parked in `recv()`
  without freeing a number that handler still holds;
- adoption of an accepted socket and the shutdown check share one critical section, so a connection
  accepted a moment before `stop()` cannot be registered a moment after it and park forever;
- `stop()` is idempotent and waits (5 s cap) for the listener to actually be gone, so the fd probe
  in the test measures a settled state.

The listener thread holds a strong reference back, so an instance that is never stopped never
deallocates — documented on the type, and every test pairs construction with `defer { stop() }`.

## Mutation results — 12 applied, 12 red

| Mutation | Test that went red |
|---|---|
| drop `Content-Range` from the 206 | `aRangedGetAnswers206WithTheRightContentRange` |
| stop understanding `bytes=-N` | `aRangedGetAnswers206WithTheRightContentRange` |
| serve 200 for a range past EOF | `aRangeThatStartsPastTheEndOfTheFileIs416` |
| log every request as a 200 | `theRequestLogRecordsEveryRequestInOrder` |
| never wake the listener out of `accept()` | `stopLeavesNoSocketsBehind` |
| leave live client sockets alone on `stop()` | `stopReleasesAConnectionThatIsStillOpen` |
| send a body with a HEAD | `headReportsTheLengthAndTheRegisteredHeadersWithNoBody` |
| report `Content-Length: 0` on a HEAD | `headReportsTheLengthAndTheRegisteredHeadersWithNoBody` |
| forget the registered headers | `headReportsTheLengthAndTheRegisteredHeadersWithNoBody` |
| honour `Range` on an `.ignore` path | `aPathThatIgnoresRangeServes200AndTheWholeBody` |
| only 416 an unsatisfiable range on a `.reject` path | `aPathThatRejectsRangeAlways416s` |
| answer 404 before 405 | `unknownPathIs404AndAnUnsupportedMethodIs405` |

**One mutant survived the first pass and is worth recording.** "Send a body with a HEAD" stayed
green against `#expect(body.isEmpty)`, because `URLSession` discards a HEAD response body before a
test can ever see it — the assertion was guarding nothing, exactly the failure mode AGENTS.md
warns about. The HEAD test now also speaks HTTP over a raw socket and asserts the response ends at
the header block. Both HEAD mutants die on it.

## Proved against the real consumer

`remoteFactParquetReadThroughTheOracleIsRangedNotWholeObject` (gated on `SIFT_REMOTE_FACTS=1`,
named to join `--filter remoteFact` so the CI canary step picks it up) loads `httpfs`, reads a
500 000-row parquet through `http://127.0.0.1:<port>/big.parquet`, gets 500 000 back, and then
asserts **from the request log**: every GET is a 206 for a named byte range, and the bytes asked
for total under 5 % of the file — a `count(*)` answered from the footer alone. That is the
assertion style later remote tests copy. It also `SET GLOBAL http_timeout=5` (GLOBAL, not a bare
SET — fact 8), so a broken environment fails in seconds instead of the 244 s the first canary run
cost.

## Concerns

1. **The log has no byte count.** The contract's tuple is `(method, path, range, status)`, so an
   assertion like the spike's `gets.first?.sent == csv.count` cannot be written. For a 206 the
   requested span is recoverable from the `Range` header (the gated test does exactly that), but
   for a `.ignore` path answering 200 there is no way to tell from the log how many bytes crossed
   the wire. If a later task needs "how much was transferred" rather than "was it ranged", the
   tuple needs a fifth field — a breaking change to every call site, so better decided now than
   later.
2. **No `clearLog()`.** The spike had one and used it to separate phases within a test. Deliberately
   not shipped: tests can take `requestLog.count` before and slice after. Say the word if the later
   tasks want it back.
3. **`--verify` is not wired to it.** `Verification.swift` was owned by a sibling task this
   session, so the type ships in `SiftEngine` ready for it but nothing in the CLI calls it yet.
4. **AGENTS.md now has a stale line.** "Sift touches no live system … There is no port to bind
   because there is no server." There is one now: loopback-only, never a wildcard bind, and only
   started by a test or `--verify`. `AGENTS.md` was not on this task's file list, so the sentence
   is left for whoever owns that file to qualify.
5. **The fd-leak test carries slack.** It asserts the descriptor count moves by fewer than 20
   across 50 start/stop cycles; a real leak costs 50. The slack is because the suite is parallel
   and other tests are opening their own files while it counts — run alone the delta is 0. A
   tighter bound would be flaky, not stronger.
6. **The concurrency test is honest about its limits.** `theRequestLogIsSafeToReadWhileTheServerIsServing`
   runs 24 requests against several hundred log reads; without a sanitizer, an unlocked `hits`
   fails often rather than always. The exact final count is the part that holds every run.
