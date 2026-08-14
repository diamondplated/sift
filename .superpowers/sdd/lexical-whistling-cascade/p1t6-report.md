# Phase 1, Task 6 — `Session` wiring: the config, the launch posture, secrets, the operations

Base `33131e5` (branch `native`). Measured on macOS 26 (Darwin 25.3), arm64, against the vendored
`libduckdb` 1.5.5.

**Status: done.** Warning-free from a wiped `.build`. **`swift test` goes 824 → 845**, green on four
consecutive full runs with no flake. `swift run sift --verify` → **21 checks, 20 passed, 1 skipped**
(the new one, gated); `SIFT_REMOTE_FACTS=1 swift run sift --verify` → **21/21**.
`SIFT_REMOTE_FACTS=1 swift test --filter remoteFact` → **24/24**, unchanged.

Files:

- `Sources/SiftEngine/Connections.swift` (new)
- `Sources/SiftEngine/Session.swift` (six stored properties, a delegating `init`, and eight lines
  inside the designated one)
- `Sources/SiftEngine/Verification.swift` (one check)
- `Tests/SiftEngineTests/ConnectionsTests.swift` (new, 21 tests)

`RemoteProbe.swift`, `Keychain.swift`, `LoopbackHTTPServer.swift`, `SiftCore/Remote.swift` and
`DuckDBKit/Database.swift` are untouched — only called.

---

## 1. The measured outcome-enum truth

> *add a connection to a strict session, attempt the remote read, and pin what actually happens*

Measured, and pinned by `theFirstConnectionTurnsRemoteOnInTheFileAndNotInThisEngine`:

| After `addConnection` on a session that started strict | Result |
|---|---|
| `connections.json` on disk | `allowRemote: true`, the connection saved |
| `duckdb_secrets()` | **1** — the credential really is registered on the live engine |
| `database.hardened["disabled_filesystems"]` | still `true` |
| `SELECT count(*) FROM read_parquet('http://…')` through `runSQL` | **refused** |
| `ConnectionOutcome` | `.activeAfterRelaunch` |

So the secret goes live and the *filesystem* does not, exactly as remote fact §2 predicts. The
refusal's sentence on a session with no `httpfs` is DuckDB's extension guard
(`… requires the extension httpfs …`); with `httpfs` loaded it is
`Permission Error: File system HTTPFileSystem has been disabled by configuration`. The test accepts
either, because which one you get depends on whether the extension happens to be installed and
neither is "it worked".

`ConnectionOutcome` therefore has exactly two cases and they are computed differently per operation,
which is the part a single formula would have got wrong:

- `addConnection` → `.active` iff **`allowRemoteAtLaunch && config.allowRemote`**. Both halves are
  needed: the engine's frozen posture, *and* the switch as it stands. The second half is reachable —
  revoke, then add — and without it the enum would claim a connection works on a session whose
  config says remote is off.
- `setAllowRemote(on)` → `.active` iff **`on == allowRemoteAtLaunch`**. Asking for the posture the
  engine already has is not a relaunch. `setAllowRemote(false)` on a *strict* session is `.active`
  and on a *permissive* one is `.activeAfterRelaunch`, and the same asymmetry runs the other way.
- `removeConnection` returns `Void` on purpose: `DROP SECRET` and the Keychain delete both take
  effect immediately in either posture, so there is nothing to defer and nothing to report.

`Session.allowRemoteAtLaunch` is a public `nonisolated let` — the frozen posture as a value, kept
deliberately separate from `connections().allowRemote`, because conflating the two IS the bug.

## 2. The relaunch-free option — decided in code, not in a comment

The rebuild path is named in `Connections.swift`'s header (consequence 3) and in
`ConnectionOutcome`'s doc: **close every open table, drop the `Session`, construct a new one on the
same home** — the UI's job, because the UI is the only layer that knows what is open and can put it
back. `Session` owns one `Database`, one long-lived `pagingConnection`, the open-table catalog and
the staged-copy handles; rebuilding those from inside the actor that owns them is "reopen
everything" wearing a smaller name.

`setAllowRemote`'s doc carries the counter-instruction in as many words: **do not "fix" this with a
`SET` — it cannot work**, and the failure mode of trying is a user told remote is off while every
read still succeeds. The enum is what makes that unfixable-by-accident: `.activeAfterRelaunch` is a
value a caller has to handle, where a comment is a thing a caller can not read.

## 3. Decisions worth flagging

| Decision | Why |
|---|---|
| **Secrets are issued at launch only when `allowRemote` is true** | A secret on a strict engine is inert — every network filesystem is denied — and issuing one means reading the Keychain, which on a locked one is a prompt. A user who turned remote off must not be asked to unlock their keychain on behalf of a session that cannot use what is in it. `addConnection` still issues live, because it has just turned the switch on in the file. Pinned by `aStrictSessionIssuesNoSecretsEvenWithConnectionsSaved`. |
| **`installExtension` is called from `addConnection` only when the config says remote is on** | `Database.loadExtensions` falls through `LOAD` → `INSTALL`, which is an outbound request to `extensions.duckdb.org`. Making one on behalf of a posture that forbids exactly that would break the product's standing promise for a binary the session cannot use anyway. |
| **`httpfs` is loaded whenever remote is on, `azure` only when a connection asks** | A pasted `https://` URL needs no saved connection and is the most common remote source there is; `azure` is a second binary to fetch. Pinned both ways (`aSavedAllowRemote…`, `azureIsNotLoadedForAnS3OnlyConfig`) on the tri-state — *asked for* vs *never asked*, since `.loaded` needs a network INSTALL. |
| **The Keychain payload is the credential as plain UTF-8, for both kinds** | `Keychain.swift`'s header describes the s3 payload as "the key material as JSON, keyed the way `ConnectionSpec` names it". Nothing implements that, and `createSecretSQL(_:secretValue:)` takes **one** `String?` for every shape — so a JSON envelope would exist only to be unwrapped again. That file is explicit that it "stores bytes and does not know what they mean"; this is the caller deciding. **If a future connection kind needs two secret fields, that comment is the design to come back to.** It was out of scope to edit. |
| **`Session.keychainService`, an internal seam on a second `init`** | The public `Keychain` API has no service parameter, so without a seam every test that exercised `addConnection` would write real credentials under `dev.sift.connections` — the exact thing `KeychainTests`' `.test` namespace exists to prevent, one layer down. `public init(home:)` delegates; there is no public way to set it. |
| **A throwaway `Connection` for every operation, never `pagingConnection`** | Secrets are Database-scoped (§6b), so any connection will do — and staying off the shared one keeps this file entirely outside the no-suspension invariant `Session.swift`'s header documents. |
| **The config is written to a per-pid temp name and `rename`d** | A torn write here does not lose a cache, it produces a file `loadRemoteConfig` **refuses** — a Sift that will not start until the user finds and deletes a file they have never heard of. `createFile(attributes:)` carries the 0600 in one call (MEASURED in RemoteProbe: unlike `createDirectory`, `createFile`'s attributes ARE applied to an existing path, so a create-then-chmod would be a mutant nothing could kill), and `rename` preserves the mode. |
| **An empty connection name is refused** | It is the Keychain item's `label`, and an unnamed item is exactly the anonymous "32 hex digits" row that `label` exists to prevent. One line, one test. |
| **A duplicate connection id is refused** | Two rows sharing an id means one `removeConnection` deletes both and one Keychain item serves two connections. Not silently tolerated. |
| **`removeConnection` on an unknown id throws** | It needs the spec to build the `DROP SECRET`, and the caller has the list. Same shape as `Session.table(_:)`'s "No open table named …". |

## 4. Every `try?` in the new code, and why

Three, all documented at the line:

1. `removeConnection`'s `DROP SECRET` — MEASURED §6c, the secret is `TEMPORARY` and holds no disk, so
   a failed drop costs this session's memory and nothing else. Letting it refuse the removal would
   leave a user unable to delete a connection *because of* the credential they are deleting.
2. `setAllowRemote(false)`'s per-connection drops — same argument, once per connection.
3. `addConnection`'s Keychain rollback after a failed save — the error the caller must see is the one
   that made the rollback necessary; a second error thrown from cleanup would replace it with the
   less useful of the two. Same pattern as `downloadRemoteObject`'s half-written-file cleanup.

Everything else produces a sentence. Issuance failures are **recorded** in
`connectionIssues() -> [UUID: String]`, never swallowed and never thrown: every branch of
`issueSecret` returns either `nil` (it really was issued) or a first-line reason, including two
different sentences for the two ways `createSecretSQL` can return `nil` (a missing credential, and a
`credentialChain` with no account name — different fixes).

## 5. Mutation bar

Each applied, `swift test --filter ConnectionsTests` run, each **red**, each reverted:

| Mutation | Goes red |
|---|---|
| Config read moved **after** the `Database` opens | `aCorruptConfigRefusesTheSessionBeforeAnyStoreFileExists`, `aFutureVersionConfigRefusesTheSession…` — via `stage.duckdb` now existing. That file's absence is the only externally visible difference between the two orders, and it is the right one: a read that happens after the open is a read that happens too late to be a security decision. |
| `0o600` → `0o644` | `theConfigIsWrittenAt0600` |
| Refusal swallowed (both `catch`es return `RemoteConfig()`) | both refusal tests, 7 assertions |
| Issuance failure thrown from `init` instead of recorded | `aMissingCredentialIsRecorded…`, `azureIsNotLoadedForAnS3OnlyConfig` |
| Last-connection auto-revoke added | `removingTheLastConnectionLeavesAllowRemoteAlone` |
| `addConnection` always returns `.active` | `theFirstConnectionTurnsRemoteOnInTheFileAndNotInThisEngine` |
| `harden(allowRemote:)` → `harden()` | `aSavedAllowRemoteDecidesThePostureAndTheExtensionsAtLaunch`, `revokingDropsTheSecrets…` |

## 6. `--verify`

The strict default is untouched: no `connections.json` in a workspace home means the strict posture,
and the twenty existing checks all still pass unchanged. The new `remote connection` check plants
`allowRemote: true` in a workspace's own home *before* the `Session` opens it and proves the whole
chain — the file is read first, `harden()` skips the deny list because of it, `httpfs` is loaded
because of it, and `SELECT count(*) FROM read_parquet('http://127.0.0.1:<port>/…')` comes back with
1000 through `runSQL` (so through the SELECT-only gate and `wrapUserSQL`, not a hand-built
connection), with the loopback server's request log non-empty.

Gated behind `SIFT_REMOTE_FACTS=1` and reported as a **skip** with the switch to flip, per the file's
rule 3: `httpfs` may need a network INSTALL, and a command a user runs to check their own install
must not reach for the network on its own.

## 7. Concerns for whoever picks this up

1. **`installExtension` is the first post-`init` writer of `Database.loadedExtensions`**, whose own
   header says the dictionary is unsynchronized *because* it is written at configure time and read
   afterwards. Every call is actor-isolated so the writes are serialized; the one reader that is not
   is `Session.engineInfo()` (`nonisolated`), which the app calls once while building `AppState`,
   long before a Connections sheet can exist. Flagged at the call site. The clean fix is inside
   `DuckDBKit`, which was out of scope — either a lock around that dictionary or an isolated
   accessor.
2. **`connectionIssues()` is the only channel for a per-connection extension failure.**
   `ConnectionOutcome` reports the *posture* and nothing else, so a connection can come back
   `.active` while `httpfs` failed to install. That is documented on the enum, and the UI has to
   render both — an outcome banner and a per-row issue — or a user will be told a connection is
   ready when its reader is missing. A third enum case was considered and rejected as scope; if the
   UI finds it awkward, that is the place to revisit.
3. **Nothing here opens a remote URL yet.** `addConnection` issues the credential and `RemoteProbe`
   knows how to read one, but no `Session.openPath` accepts a URL — that is a later task, and it is
   the task that will find out whether the secret's scope resolves for a real `az://` object.
4. **`ConnectionSpec` has no edit path.** `addConnection` refuses a duplicate id, so editing a saved
   connection today is remove-then-add, which briefly deletes the credential. If the UI wants
   in-place edits, `updateConnection` belongs next to these four rather than being simulated by the
   caller.
5. **Cross-process writers of `connections.json` race, last one wins.** Two Sift instances on one
   home already fall back to a private store; the config file is shared and the `rename` only makes
   each write atomic, not ordered. Not worth a lock file until two instances on one home is a
   supported thing.
