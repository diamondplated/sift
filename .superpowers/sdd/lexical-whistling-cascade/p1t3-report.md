# P1-T3 — `harden(allowRemote:)`, and the Azure names on the deny list

Base `048953e` (branch `native`). Measured on macOS 26 (Darwin 25.3), Swift 6.3, arm64, against the
vendored `libduckdb` 1.5.5.

**Status: done.** `swift build` and `swift build --build-tests` are warning-free from a wiped
`.build`. **764 default tests pass** (760 before), no network. `SIFT_REMOTE_FACTS=1 swift test
--filter remoteFact` → **16/16 green in 5.0 s** (13 before). `swift run sift --verify` → 20/20.

---

## 1. The deny list grows the two Azure names

```swift
public static let remoteFilesystems =
    "HTTPFileSystem,S3FileSystem,AzureBlobStorageFileSystem,AzureDfsStorageFileSystem"
```

One constant, so `harden()` and the gate's scratch database (`withGuardScratchConnection`) still
cannot drift. No plumbing change was needed in `GuardStatements.swift` — it already reads the
constant, so the gate got the Azure names for free.

The spike's warning is the whole design problem here: `SET disabled_filesystems` never validates a
name, the registry is not introspectable, and `current_setting` reads back `''`. A typo is a
security layer that does nothing and says nothing, and no read-back assertion can see it. So both
name pins are **behavioral, and drop one name at a time**:

- `theGateScratchConnectionIsHardenedLikeEveryOtherOne` (SiftEngineTests) — was two names, now
  four, each dropped in turn.
- `hardenDisablesEveryNameOnTheDenyListAndAllowRemoteDisablesNone` (DuckDBKitTests) — new, and it
  pins `harden()` itself rather than the gate's connection. `hardened["disabled_filesystems"] ==
  true` proves the SET *succeeded*, which stays true with the list typo'd to `NotAFileSystem`; this
  proves it *denied*.

Both spell the four names out rather than reading `Database.remoteFilesystems`. A test that derives
its expectation from the constant it is checking cannot notice that constant losing a name.

Gated, the Azure half is now read end to end in
`remoteFact1_azureRegistersTwoFilesystemsAndHardenNowBlocksBoth` (renamed — its last block asserted
the opposite): all four URL families (`az://`, `azure://`, `abfss://`, `abfs://`) refused by
`Permission Error` naming the right filesystem on a default-hardened database, with
`harden(allowRemote: true)` as the control that still runs on to `No valid Azure credentials found`.

## 2. `harden(allowRemote: Bool = false)`

`true` skips exactly one SET — `disabled_filesystems` — and applies the other three unchanged. The
default parameter means every existing call site (`Session.init`, `Verification`, every test) is
untouched and behaves identically; `hardenRecordsWhatItActuallyApplied` did not change by a
character.

In the permissive posture `hardened` has **no** `disabled_filesystems` key. Absent is not `false`:
`false` means DuckDB refused the SET (a bug report), absent means Sift deliberately never asked —
the same tri-state discipline T1 built `ExtensionState` for. Pinned by
`hardenWithAllowRemoteAppliesTheOtherThreeSettingsAndSkipsOnlyTheDenyList`.

It is a parameter of the one call that runs before any query, not a `var`: measured (§2), the
disabled set only ever grows within a `Database`, so a posture change is a new `Database` and there
is nothing to undo.

## 3. Both postures proven over a socket

`remoteFactHarden_allowRemoteDecidesWhetherALoadedHttpfsCanRead`
(`Tests/SiftEngineTests/RemotePostureTests.swift`, new file — SiftEngineTests is where the sibling's
`LoopbackHTTPServer` is reachable): `harden(allowRemote: true)` + `LOAD httpfs` + a parquet read
from the loopback oracle returns 1000 rows and the request log is non-empty; then the same LOAD and
the same URL on a default-hardened `Database` is refused with `Permission Error: File system
HTTPFileSystem has been disabled by configuration`, **and the request log does not grow** — the
refusal is local, not a round trip.

Same file: `remoteFactSecrets_redactionSurvivesTheUserSQLWrap`. `CREATE SECRET` (s3 shape, dummy
values, bound as parameters per §6a), then `SELECT * FROM duckdb_secrets()` through `wrapUserSQL` —
the wrap a console query actually passes — asserting no cell carries the dummy key, and that
`key_id` *is* in the clear (the identity half the UI has to respect). The SELECT-only gate does not
stop that query; it is a read. DuckDB's redaction is the only thing between a user's SQL and the
credential, and this is what notices if that default ever moves.

Both are gated behind `SIFT_REMOTE_FACTS=1` and named to match CI's `--filter remoteFact`.

## 4. Mutations run, and what killed each

| # | Mutation | Killed by |
|---|---|---|
| 1 | drop `HTTPFileSystem` from `remoteFilesystems` | 🔴 `hardenDisablesEveryNameOnTheDenyList…` and `theGateScratchConnectionIsHardenedLikeEveryOtherOne`, both naming `HTTPFileSystem` |
| 2 | drop `S3FileSystem` | 🔴 the same two, naming `S3FileSystem` |
| 3 | drop `AzureBlobStorageFileSystem` | 🔴 the same two, naming `AzureBlobStorageFileSystem` |
| 4 | drop `AzureDfsStorageFileSystem` | 🔴 the same two, naming `AzureDfsStorageFileSystem` |
| 5 | delete the branch, deny always (`if true`) | 🔴 offline: `hardenWithAllowRemoteAppliesTheOtherThreeSettings…` (2 issues) + `hardenDisablesEveryNameOnTheDenyList…`. Gated: `remoteFactHarden_…` (permissive half) + `remoteFact1_…` (permissive control) |
| 6 | delete the branch, deny never (`if false`) | 🔴 offline: `hardenRecordsWhatItActuallyApplied`, `hardenDisablesEveryNameOnTheDenyList…` (8 issues), `aSessionHardensTheDatabaseItHandsEveryQuery`. Gated: `remoteFactHarden_…` (strict half, incl. the request log growing) + `remoteFact1_…` (all four Azure URLs) |

5 and 6 are the pair the task asked for: each direction of deleting the branch turns exactly one
half of each pair red, in both the offline and the gated suite.

## 5. Docs

- **Design spec §11** — the frozen-contract paragraph gains an "Amended by the Connections work
  (P1-T3)" note: the *content* is now four names and why those two Azure names (one per URL family,
  `AzureStorageFileSystem` is a decoy), `allowRemote: true` is a deliberate user-chosen posture,
  the other three settings and every existing call site are unchanged, and a posture is chosen once
  at open because the setting only ever grows.
- **Remote-facts spec §1** — the "harden() currently blocks neither" bullet is now past tense, the
  consequence records that P1-T3 took it, and the `Pinned:` line follows the test's rename.

---

## Concerns

1. **CI is unverified.** Nothing here has been through macos-15; I cannot push from this clone. The
   gated tests need a cold `INSTALL httpfs`/`INSTALL azure` on the runner, which fact 10 already
   measured as working, and `remoteFactHarden_…` binds a loopback socket, which the sibling's
   `LoopbackHTTPServer` tests already do on the runner. The one genuinely new CI surface is the
   `SET GLOBAL http_timeout=5` on a `harden(allowRemote: true)` database.
2. **`Tests/SiftEngineTests/RemotePostureTests.swift` is a new file.** The two gated tests could not
   live in `DuckDBKitTests` — `LoopbackHTTPServer` is in `SiftEngine`, and `wrapUserSQL`/`toDBValue`
   need SiftCore and `@testable SiftEngine`. No `Package.swift` change was needed. It reads
   `server.requestLog` only through `.count` and `.isEmpty`, so the sibling adding a field to the
   log tuple should not touch it.
3. **One flaky observation, not mine.** During mutation 3 the machine was loaded and eight SiftUI
   profile tests timed out on `waitFor { !model.profile.isEmpty }` (tests taking 40-48 s). They pass
   on every unloaded run, including the final wiped-`.build` run. Worth knowing if CI ever goes red
   there under parallel load.
4. **`az://` still stops at the credential check.** Everything Azure here is the VFS gate; that a
   secret authenticates remains on the manual checklist, exactly as the spike left it.
