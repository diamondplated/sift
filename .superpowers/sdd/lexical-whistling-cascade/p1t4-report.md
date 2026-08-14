# Phase 1, Task 4 — the pure layer: URL classification, connections, secret SQL, remote tokens

**Status: done.** Two files, both new, nothing else touched.

- `Sources/SiftCore/Remote.swift` (≈330 lines)
- `Tests/SiftCoreTests/RemoteTests.swift` (27 tests)

`swift test` goes **760 → 787**, green from a wiped `.build`, **zero warnings**, four consecutive
full runs with no flake. `swift run sift --verify` still 20/20. Base `048953e`, measured on
macOS 26 (Darwin 25.3), Swift 6.3, arm64.

---

## 1. The measurement that changed the tests

The task said the secret SQL could only be pinned as strings, because `CREATE SECRET` needs the
`azure`/`httpfs` extensions and those need the network. **That is not true on 1.5.5.** Measured on a
bare `Database.inMemory()` with no extension loaded and no network:

```
OK   CREATE OR REPLACE TEMPORARY SECRET sift_a (TYPE s3, KEY_ID ?, SECRET ?, REGION ?, ENDPOINT ?)
OK   CREATE OR REPLACE TEMPORARY SECRET sift_b (TYPE azure, CONNECTION_STRING ?)
OK   CREATE OR REPLACE TEMPORARY SECRET sift_c (TYPE azure, PROVIDER credential_chain, CHAIN 'cli;env', ACCOUNT_NAME ?)
OK   DROP SECRET IF EXISTS sift_a          OK   DROP SECRET IF EXISTS sift_nope
```

An extension is needed to *use* a secret, not to *create* one. So three tests reach a real engine in
the **default, offline** suite and assert what a string comparison cannot:

- `everySecretShapeParsesAndBindsOnARealEngine` — all five shapes parse, bind, register and drop. A
  wrong placeholder count, an unknown option name or a parser slip fails here, not in production.
- `aBoundCredentialLandsVerbatimAndStaysOffDisk` — an account name of `acct'name;DROP TABLE x;--`
  reads back through `duckdb_secrets()` as `account_name=acct'name;DROP TABLE x;--`. The value rode
  as a parameter and landed byte-for-byte. Also asserts `persistent = false`, `storage = memory`.
- `aBoundConnectionStringIsRedactedWhenReadBack` — `connection_string=redacted`, and the secret text
  is absent. That is the SQL console's view of a live credential, pinned.

**A second thing fell out of it.** The azure secret scopes itself, in DuckDB's own words, to
`azure://,az://,abfss://,abfs://` — all four spellings. That is independent confirmation of spike §1
and it is why `classifyRemote` accepts `azure://` and `abfs://` as aliases (see §3 below).

## 2. The contract, as shipped

Every signature is as specified. Additions and deviations, each with its reason:

| Change | Why |
|---|---|
| `azure://` → `.az`, `abfs://` → `.abfss` recognised | Not new enum cases — table entries. `nil` means **local path**, so an unrecognised alias does not become "unsupported", it becomes silently mis-routed to the local-file flow. Measured above and in spike §1. |
| `sanitized` also drops `user:password@` | A password in the authority is exactly the leak the query strip exists to prevent, and `sanitized` is *the* persisted form. Not carried anywhere else: Sift does not do credentials-in-a-URL. Cost of the alternative — returning `nil` — is routing a real remote URL into the local flow. |
| `sanitized` also drops `#fragment` | Same defect class as the query: a fragment is client-side by definition (no HTTP client sends one), and leaving it on feeds `#anchor` to the extension check and blanks out a real `.csv`. Two lines. |
| `effectiveExt` is dotted and lowercased (`".csv"`) | So `csvExt.contains(u.effectiveExt)` works directly against the sets in Types.swift. An undotted form would need every caller to re-add the dot, which is half of the shipped defect. |
| s3 `REGION ?` is omitted when there is no region | The pinned shape assumes a region. Binding `REGION ''` is not the same as not setting one, and it is worse. Both forms are pinned by test. |
| `accountName` doubles as the s3 **access key id** | `ConnectionSpec` has no `keyId` field and the pinned s3 shape needs one. They are the same fact wearing two names, and measured (spike §6c) they are even redacted identically: `duckdb_secrets()` shows `account_name` and `key_id` in the clear while redacting `connection_string` and `secret`. Documented on the field. |
| `public struct UnsupportedRemoteConfig: SiftError` + `public let remoteConfigVersion = 1` | A version-refusing `init(from:)` needs something to throw, and the house rule is that every error SiftCore throws is a `SiftError` so `"\(error)"` and `.localizedDescription` give the same sentence. |
| `secretName(_:)` is internal, not public | Nothing outside SiftCore needs it — `createSecretSQL`/`dropSecretSQL` both embed it. One word to promote if SiftEngine wants it for diagnostics. |

**Config version tolerance: refuse loudly, and the asymmetry is deliberate.** An unreadable staging
token is *collected* — the copy is disk that regenerates. An unreadable *config* is the user's own
typing: a newer Sift writes a field this build cannot see, this build decodes around it, the user
edits one connection, and the whole file is rewritten without it. `version != 1` throws;
`version` absent or keys missing *inside* v1 take their defaults, because a version bump is how a
format change announces itself.

**The default is `allowRemote = false`.** Sift's standing promise is that it touches no live system;
a default that quietly allowed egress would break it for every user who never opened the screen.

## 3. Token format decisions

```
with identity:     v3|remote|<sanitized-url>|etag=<e>
                   v3|remote|<sanitized-url>|lm=<ms>|len=<n>
without identity:  v3|remote|<sanitized-url>|fetched=<ns>
```

- **ETag alone, not ETag + date.** An ETag is the server's own content identity; adding
  `Last-Modified` on top can only invalidate a copy that is actually fine (a re-upload of identical
  bytes moves the date, not the tag).
- **`lm` and `len` are required together.** `Last-Modified` has one-second granularity, so alone it
  would adopt a copy of a file rewritten inside the same second. Half an identity is no identity —
  it falls through to `fetched=`. Same rule as the local `SourceKey`'s `(mtime, size)`.
- **Who owns uniqueness.** The caller owns the clock (this function reads none — that is what keeps
  it pure). The *format* owns "distinct `fetchedAtNs` → distinct token", and owns that no `fetched=`
  token can ever equal an identity token. Both are in the doc comment and both are tested. Passing a
  constant is a caller defeating its own cache, not this function forging an identity.
- **A `|` in a field is escaped, not refused.** Refusal does not fit a non-optional return, and a
  `|` in a path is legal (merely unencoded). The escape is `%` → `%25` **then** `|` → `%7C`, and the
  order is not cosmetic: escaping `|` alone sends `a|b` and the already-encoded `a%7Cb` to the same
  token, which is two different objects sharing one staged copy.

## 4. Mutations — 12 applied, 12 red

| # | Mutation | Test that went red |
|---|---|---|
| 1 | query never stripped | `theClassificationTableHolds`, `aQueryStringNeverBecomesAnExtension`, `theSASTokenReachesNothingThatIsShownOrStored`, `anEmptyQueryIsNoQuery`, `aTokenIsBuiltFromTheSanitizedURLSoNoSASEverReachesTheCatalog` |
| 2 | `effectiveExt` from `NSString.pathExtension` on the raw input (the shipped defect) | `aQueryStringNeverBecomesAnExtension`, `theClassificationTableHolds`, `theSASTokenReachesNothingThatIsShownOrStored` |
| 3 | connection string `qlit`-ed into the SQL text instead of bound | `aHostileSecretValueRidesAsAValueAndNeverEntersTheSQL`, `theAzureConnectionStringShapeIsPinned` |
| 4 | `fetched=0` constant instead of the caller's clock | `theFetchedFormIsDifferentOnEveryFetch`, `halfAnIdentityIsNoIdentity`, `aPipeInsideAFieldCannotForgeAFieldBoundary` |
| 5 | `user:password@` kept in `sanitized` | `aPasswordInTheAuthorityIsDroppedRatherThanPersisted`, `theClassificationTableHolds` |
| 6 | escape `\|` without escaping `%` first | `aPipeInsideAFieldCannotForgeAFieldBoundary` |
| 7 | no config version guard | `aConfigFromAnUnknownFormatIsRefusedLoudly` |
| 8 | drop the `azure://` / `abfs://` aliases | `theClassificationTableHolds` |
| 9 | drop `TEMPORARY` from `CREATE SECRET` | `theAzureCredentialChainShapeIsPinned`, `theAzureConnectionStringShapeIsPinned`, `theS3ShapeIsPinnedWithAndWithoutItsOptionalParts` |
| 10 | fragment left glued to the path | `theClassificationTableHolds` |
| 11 | accept `Last-Modified` with no length | `halfAnIdentityIsNoIdentity` |
| 12 | bind `REGION ''` instead of omitting the clause | `theS3ShapeIsPinnedWithAndWithoutItsOptionalParts` |

**Mutation 9 is the one worth reading twice.** Only the *string* pins killed it — the real-engine
test stayed green, correctly, because `TEMPORARY` **is** the default on 1.5.5 (spike §6c), so
dropping the keyword changes no behaviour today. The string pins are therefore the entire defence
against a future DuckDB default change quietly starting to persist credentials. Do not relax them
into `contains("SECRET")`.

## Concerns

1. 🔴 **`"v3"` is spelled twice and nothing can check it.** `SiftEngine.stagingTokenVersion` is
   internal to `Staging.swift`, and SiftCore sits below SiftEngine, so the constant cannot be
   shared from where it lives. If the two ever disagree, `purgeStaged`'s format sweep
   (`!token.hasPrefix("v3|")`) deletes **every remote cache on every purge**, silently, with the
   whole suite green. The fix is one move — hoist `stagingTokenVersion` into `Remote.swift` and
   delete the copy in `Staging.swift` — and `Staging.swift` was outside this task's file list. Both
   ends are pinned by a literal in the meantime; whoever owns Staging.swift next should do the move.
2. **`accountName` carrying the s3 key id is an interpretation, not something the plan stated.** The
   pinned s3 shape needs a `KEY_ID` and the struct has no field for one. If a `keyId` field is
   preferred, it is a two-line change plus the doc comment; the tests name `accountName` in three
   places.
3. **Classification is structural only, on purpose.** A `*` in the path (globs refused before the
   wire, spike §4) and a `_delta_log/` directory (remote Delta cannot work at all, spike §3) both
   need a clean refusal sentence, and neither is here — `nil` already means "local path", so
   overloading it with two refusals would mis-route them. Those belong to whoever builds the open
   path.
4. **CI is unverified** — no push from this clone. The shapes most likely to trip macos-15 are the
   custom `init(from:)` alongside synthesized `Encodable` (which relies on the compiler still
   synthesizing `CodingKeys`) and `Identifiable` on a `Codable`+`Sendable` struct. Both compile
   warning-free here from a wiped `.build`, but this Mac has been the wrong oracle before.
5. **Ten SiftUI profile tests time out when the machine is contended.** Seen during this session
   while a second `swift test` and a clone were running: `waitFor { !model.profile.isEmpty }` blows
   its 30 s budget in `ColumnLayoutTests`/`TableViewModelTests`/`GridBridgeTests`. Not caused by
   this change — reproduced with both new files moved out of the tree, and green on four
   consecutive uncontended runs with them back — but the budget is close enough to the edge that a
   slower CI runner could see it.
6. **`ConnectionSpec.init` defaults `id` to `UUID()`.** Not a clock read and not a purity violation
   of any function here, but it is the one non-deterministic thing in the file; every test passes an
   explicit UUID.
