# P1-T1 — tri-state extension outcomes, and the one unhardened connection

Base `385a635` (branch `native`). Measured on macOS 26 (Darwin 25.3), Swift 6.3, arm64, against the
vendored `libduckdb` 1.5.5.

**Status: done.** `swift build` and `swift test` are warning-free from a wiped `.build`.
**732 default tests pass, 745 declared, the 13 remote-facts tests stay gated** (`SIFT_REMOTE_FACTS=1
swift test --filter remoteFact` → 13/13 green in 0.9 s). `swift run sift --verify` → 20/20.

---

## 1. `ExtensionState` replaces the boolean

```swift
public enum ExtensionState: Sendable, Equatable {
    case loaded
    case unavailable(String)   // LOAD and INSTALL both failed — DuckDB's first line
    case rejectedName          // the injection guard threw the name out
}
public private(set) var loadedExtensions: [String: ExtensionState]
```

The mechanism in `loadExtensions` is untouched — LOAD → INSTALL → LOAD, guard first. Only the
recording changed. **Absent still means "never asked"**, and there is now a test that says so.

**Which error `.unavailable` carries, and why.** The *catch* block's — the INSTALL-or-second-LOAD
failure, not the first LOAD's. MEASURED on 1.5.5:

| Statement | Message |
|---|---|
| `LOAD no_such_extension_zzz` | `IO Error: Extension "…/no_such_extension_zzz.duckdb_extension" not found.` |
| `INSTALL no_such_extension_zzz` | `HTTP Error: Failed to download extension … (HTTP 404)` |

The first line is the same uninteresting sentence for every extension that is merely not installed
yet. The second is the one that separates the two things a user can act on: a 404 (no such
extension) from a machine that could not reach `extensions.duckdb.org` at all (no network) — which
is the difference between "run INSTALL azure" and "get online first".

### Ripples, chased to zero

| Site | Change |
|---|---|
| `Session.openPath` delta refusal | `loadedExtensions["delta"] == .loaded` |
| `EngineInfo.extensions` | `[String: ExtensionState]` — public API, CLI surface |
| `Verification.swift` ×3 | `== .loaded` |
| `SiftUI/BannerView.swift` | rewritten, below |
| `Tests/{SiftCore,SiftEngine}Tests/Fixtures.swift` ×6 | `== .loaded` |
| `DuckDB155FactsTests`, `RemoteFactsTests` ×5 | `== .loaded` |
| `SmokeTests` ×2 | rewritten, below |

`SiftUI/BannerView.swift` gained `import DuckDBKit`: `EngineInfo` now exposes a DuckDBKit type, so
anything naming its cases has to see the module. `Session.swift` and `Verification.swift` already
imported it.

**`.rejectedName` is unreachable in production**, and that is the point: `Session` calls
`loadExtensions(["delta", "excel"])` with two literals. It is a state the *engine* can produce and
the *UI* must be able to name, not a state a user can reach.

### The banner: two failures, two sentences

`missingExtensionsBanner` returned `(message, fix)?` and rendered every `false` as one string with
one `INSTALL` list. It now returns `[(message: String, fix: String?)]` — at most two rows:

- `.unavailable` — `DuckDB extensions unavailable: delta (IO Error: …), excel (HTTP Error: …).
  Delta folders and .xlsx will be refused rather than read incorrectly. Fix with one online run of`
  + the `INSTALL …` keycap. **DuckDB's own line travels with each name**, so the banner stops
  giving "run INSTALL delta" as the answer to a machine that is simply offline.
- `.rejectedName` — `Sift bug — report it: Sift asked DuckDB for an extension name it cannot use
  (…). Nothing you install will fix this.` and **no fix line at all**: there is nothing to paste,
  and a sentence rendered in a keycap reads as a command to run.

Both lists stay `sorted()`, for the reason the original comment gives.

---

## 2. The gate's scratch database

`GuardStatements.swift:88-97` opened a bare `duckdb_open`/`duckdb_connect` — every default in place,
`autoload_known_extensions` on, an unrestricted VFS — and it is the connection that gets handed SQL
the user typed. "It only parses" was never a defence: `duckdb_prepare_extracted_statement` is a
*binder* call, and binding `read_csv('http://…')` is what opens the URL.

- `Database.remoteFilesystems` (`public static let`) = `"HTTPFileSystem,S3FileSystem"`, exactly what
  `harden()` set today. `harden()` now interpolates it, so the two lists cannot drift and Task 3
  broadens one string.
- `withGuardScratchConnection` — open, connect, one `duckdb_query` applying the deny list, hand the
  raw `duckdb_connection` to a closure, close both. `assertSingleSelectStatement`'s body moved into
  the closure **verbatim**; its three `return` fall-throughs and both `defer` orderings are
  unchanged (closure defers still run before the outer disconnect/close).
- `Tests/SiftEngineTests` gained an explicit `CDuckDB` dependency, for the reason `SiftEngine`
  already lists one: the test drives a `duckdb_connection`, not a `DuckDBKit.Connection`.

**How the test proves it landed.** Not by reading it back — the spike measured
`current_setting('disabled_filesystems')` as `''` at every point, so a read-back assertion passes
with the hardening deleted. The observable is the **monotonicity**: the disabled set only ever
grows, so through that same connection

```
SET disabled_filesystems='HTTPFileSystem'  -> Invalid Input Error: File system "S3FileSystem" has been disabled previously, it cannot be re-enabled
SET disabled_filesystems='S3FileSystem'    -> Invalid Input Error: File system "HTTPFileSystem" has been disabled previously, it cannot be re-enabled
```

Each half names the *other* name, so the test pins both entries of `remoteFilesystems` rather than
just "the string is non-empty". **Needs no network and no extension** — MEASURED: DuckDB tracks the
disabled set by name whether or not that filesystem is registered, so this works with `httpfs`
absent, which is what keeps the default suite offline.
`aScratchConnectionNobodyHardenedAcceptsThoseSameSets` is the control: both SETs succeed on a
connection nothing hardened (one fresh `Database` each — running both on one connection would
itself be a narrowing and would fail for the right reason on the wrong connection).

Nothing user-visible changed, by design. `swift run sift --verify` still reports `ok SELECT-only
gate`, and the full DENY/ALLOW port in `GuardStatementsTests` is untouched and green.

---

## 3. Mutations run, and what killed each

| # | Mutation | Result |
|---|---|---|
| 1 | `.rejectedName` **and** the catch both record `.unavailable("nope")` (the old conflation, restored) | 🔴 `loadExtensionsRejectsANameThatCarriesSQL` (`.unavailable("nope") == .rejectedName`) **and** `loadExtensionsTellsAMissingBinaryApartFromARejectedName` twice — on `rejected == .rejectedName` and on `missing != rejected` |
| 2 | `.unavailable` swallows the message → `.unavailable("")` | 🔴 `loadExtensionsTellsAMissingBinaryApartFromARejectedName`: `!why.isEmpty` — "the reason DuckDB gave was thrown away" |
| 3 | Banner drops the reason: `unavailable.map { "\(name) (\(why))" }` → `unavailable.map(\.name)` | 🔴 `theMissingExtensionBannerIsPluralised_sorted_andCarriesItsFix` (2 issues) **and** `aRejectedExtensionNameSaysSiftBugRatherThanRunInstall` |
| 4 | Delete the scratch-DB hardening `duckdb_query` line | 🔴 `theGateScratchConnectionIsHardenedLikeEveryOtherOne`, 6 issues (both halves of the loop). Control test stayed green, so the assertion is reading the hardening and not a property DuckDB has anyway |
| 5 | `remoteFilesystems` = `"HTTPFileSystem"` (drop S3) | 🔴 **only** `theGateScratchConnectionIsHardenedLikeEveryOtherOne`, on the full 745-test run |

**Mutation 5 is the finding worth carrying forward.** Narrowing the deny list breaks a security
layer and the entire pre-existing suite stays green: `hardenRecordsWhatItActuallyApplied` and
`aSessionHardensTheDatabaseItHandsEveryQuery` only ever assert that the SET *succeeded*, and the
setting reads back empty, so the *content* of `disabled_filesystems` had nothing pinning it
anywhere. The new gate test is now the only thing in the suite that does. Task 3, which broadens
this list for Azure, is inheriting the only test that would notice a typo in the names it adds —
and per the spike, `SET disabled_filesystems` never validates a name, so a typo is silent.

---

## Concerns

1. **CI is unverified.** I cannot push from this clone, so nothing here has been through macos-15.
   The shape the task flagged — a `Sendable` enum with a `String` payload crossing an actor
   boundary — is `EngineInfo.extensions`, returned from the `nonisolated func engineInfo()` on the
   `Session` actor. It is a plain payload enum of `Sendable` members with an explicit conformance,
   so I do not expect SDK skew, but this Mac has been the wrong oracle twice on this branch.
   The other candidate is `ForEach(Array(…enumerated()), id: \.offset)` over an array of *tuples* in
   `BannerStack` — the notes loop two lines below already does exactly that shape, which is why I
   used it.
2. **`loadExtensionsTellsAMissingBinaryApartFromARejectedName` reaches the network**, as its
   predecessor `loadExtensionsRecordsAMissingExtensionAsFailed` did: an explicit `INSTALL` goes out
   even with `autoinstall_known_extensions=false`, and gets a 404 from `extensions.duckdb.org`. The
   test does not assert the message *content*, only that it is non-empty, so an offline machine
   still passes with a connection error instead. Pre-existing, not introduced, but it is the one
   test in the default suite that talks to the internet and I did not gate it (gating it would take
   the `.unavailable` payload assertion out of the default suite, which the mutation bar wants in).
3. **`Session.openPath`'s delta refusal still hard-codes "Fix: run INSTALL delta once with network
   access."** even though `.unavailable`'s reason is now sitting right there. Left alone
   deliberately: the task scoped that site as a type ripple, `DeltaTests` pins the sentence, and it
   is the natural first customer for Task 2's Connections UI work rather than a drive-by here.
4. **`missingExtensionsBanner`'s signature changed from `(…)?` to `[…]`.** It is `internal`, so the
   blast radius is `BannerStack` and `FilterBarTests`, both updated — but a later task expecting the
   optional will get a compile error rather than a surprise.
5. **Doc touched**: the design spec's open item at
   `docs/superpowers/specs/2026-08-09-native-sift-design.md` §"conflates two failures" is marked
   CLOSED with what replaced it, and `ci-native.yml`'s comment "729 tests, no network" now says 732.
   Both were about to become stale lies that the three following tasks read.
