import DuckDBKit
import Foundation
import Security
import SiftCore
import Testing
import TestSupport
@testable import SiftEngine

// The connections config, the launch posture, secret issuance, and the four operations.
//
// Real `Session`s on real `TestTemp` homes throughout — the questions here are all "what does the
// engine do with this file on disk", and a stub answers none of them. Nothing is `.serialized`:
// every test gets its own home (`Session.init`'s `home:` override and `OpenHomes`' one-session rule
// make that mandatory anyway) and its own connection UUIDs.
//
// **Every credential written here goes under `dev.sift.connections.connections-test`.** The app
// reads `dev.sift.connections`. The two namespaces do not intersect, which is what
// `Session.keychainService` exists for — the same split `KeychainTests` makes one layer down, so no
// test run can add, overwrite or delete a credential a user actually saved.
//
// 🔴 **Nothing here makes a request, and the gate below is what makes that true rather than
// merely likely.** The secret lifecycle itself is offline — `CREATE SECRET` parses, binds and
// registers on a bare 1.5.5 with no extension loaded (MEASURED, Task 4) — and a remote read
// actually working is `--verify`'s `remote connection` check and `RemotePostureTests`, both gated
// behind `SIFT_REMOTE_FACTS=1`.
//
// But a PERMISSIVE `Session` is not offline by itself: `Session.init` asks for `httpfs` (and
// `azure` when a saved connection needs it), `Database.loadExtensions` does LOAD → INSTALL → LOAD,
// and the header this replaced said "nothing here needs the network" while a dozen tests below
// fetched two binaries from `extensions.duckdb.org` on any machine that did not already have them.
// That the assertions were all written `!= nil` rather than `== .loaded` meant the suite PASSED
// offline; AGENTS.md's contract is that it makes no REQUEST, which is a different and stronger
// claim. Every test that plants `allowRemote: true` now carries `permissivePostureIsOffline`.

/// Is this machine already carrying what a permissive `Session` will ask DuckDB for?
///
/// `extensionIsInstalled` is a bare `LOAD` against a `harden()`ed scratch database — no `INSTALL`
/// behind it — so the answer costs microseconds and no packets. Both names, together and once: the
/// two are installed as a pair (CI's remote-facts canary is the one step that fetches them), and one
/// condition that reads "this machine is prepared for the permissive posture" beats two that make a
/// reader work out which test needed which binary.
private let permissivePostureIsOffline =
    extensionIsInstalled("httpfs") && extensionIsInstalled("azure")
private let permissiveSkip: Comment = "duckdb httpfs/azure extensions not installed"

/// The env gate every other file in this target declares for itself — `SIFT_REMOTE_FACTS=1`, CI's
/// separate canary step. One test below needs it; SwiftPM test targets share a module, so this is
/// the same `private let` five other files already carry rather than a new mechanism.
private let remoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

private let testService = Keychain.service + ".connections-test"

private func newHome() -> String { TestTemp.path("connections-tests") }

private func newSession(_ home: String) throws -> Session {
    try Session(home: home, keychainService: testService)
}

/// Write a `connections.json` into a home that does not exist yet — the shape every "what does the
/// engine read at launch" test needs, since `Session.init` is what creates the directory.
private func plantConfig(_ home: String, _ body: String) throws -> String {
    try FileManager.default.createDirectory(
        atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let path = Session.connectionsPath(in: home)
    try body.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func plantConfig(_ home: String, _ config: RemoteConfig) throws -> String {
    let path = try plantConfig(home, "{}")
    try Session.writeRemoteConfig(config, to: path)
    return path
}

private func readConfig(_ home: String) throws -> RemoteConfig {
    try Session.loadRemoteConfig(Session.connectionsPath(in: home))
}

/// How many secrets are registered on this engine. MEASURED (remote facts §6b): secrets are
/// Database-scoped, so a connection opened now sees every one issued on any sibling.
private func secretCount(_ session: Session) throws -> Int {
    let row = try session.database.connect().query("SELECT count(*) FROM duckdb_secrets()").allRows()[0]
    return cellInt(row[0])
}

private func s3Spec(name: String = "prod") -> ConnectionSpec {
    ConnectionSpec(kind: .s3, name: name, accountName: "AKIAEXAMPLEKEYID", region: "us-east-1")
}

/// The one connection shape that stores NOTHING in the Keychain — DuckDB asks `az login` and the
/// environment instead (spike §9). Every test that is not about credentials uses it, so the suite
/// does not need a working keychain to cover the config and posture paths.
private func chainSpec(name: String = "acct") -> ConnectionSpec {
    ConnectionSpec(kind: .azure, name: name, accountName: "acct", azureAuth: .credentialChain)
}

/// One real save-and-delete under the test service, once per process — the same honest-skip probe
/// `KeychainTests` uses, for the same reason: a locked or headless login keychain is an environment
/// fact, not a defect, and a stub that passed there would prove nothing.
private let keychainUsable: Bool = {
    let account = "connections-probe-" + UUID().uuidString
    defer { try? Keychain.delete(account: account, in: testService) }
    do {
        try Keychain.set(
            Data("probe".utf8), account: account, label: "Sift — availability probe", in: testService
        )
        return true
    } catch let error as KeychainError
        where error.status == errSecInteractionNotAllowed || error.status == errSecNotAvailable {
        return false
    } catch {
        return true   // a real defect: leave the tests enabled so they fail with their own message
    }
}()

// MARK: - what the file decides, and when it is read

/// The default that every existing posture test depends on: no file, strict engine, empty list.
@Test func aHomeWithNoConfigIsStrictAndEmpty() async throws {
    let session = try newSession(newHome())

    #expect(await session.connections() == RemoteConfig())
    #expect(session.allowRemoteAtLaunch == false)
    #expect(session.database.hardened["disabled_filesystems"] == true,
            "a default home must still deny every network filesystem")
    // Never asked for, rather than asked for and failed — the tri-state matters (Database.swift).
    #expect(session.database.loadedExtensions["httpfs"] == nil)
    #expect(await session.connectionIssues().isEmpty)
    // …and no file is written just by opening. A config appears when the user saves something.
    #expect(!FileManager.default.fileExists(atPath: session.connectionsPath))
}

/// 🔴 **The ordering mutation-killer.** The config is read BEFORE the `Database` opens, so a config
/// Sift refuses costs no store file — that is the only externally visible difference between the
/// correct order and the one where the read is moved down a few lines, and it is exactly the
/// difference that matters: the posture is applied to an already-open `Database` and can never be
/// narrowed afterwards (MEASURED §2), so a read that happens after the open is a read that happens
/// too late to be a security decision at all.
///
/// Also the refusal itself: a corrupt file must not quietly become `allowRemote: false`. Safe as
/// that would be, it is the same code path a FUTURE-VERSION file takes, and defaulting that one
/// silently undoes a revoke — see the test below.
@Test func aCorruptConfigRefusesTheSessionBeforeAnyStoreFileExists() throws {
    let home = newHome()
    _ = try plantConfig(home, "{ this is not json")

    var message = ""
    #expect(throws: SessionError.self) {
        do { _ = try newSession(home) } catch let error as SessionError {
            message = error.message
            throw error
        }
    }
    #expect(message.contains("not valid JSON"), "\(message)")
    #expect(message.contains(Session.connectionsPath(in: home)),
            "the refusal must name the file to fix: \(message)")
    // The Foundation dump the house contract exists to keep off screen.
    #expect(!message.contains("The operation couldn"), "\(message)")

    let store = (home as NSString).appendingPathComponent("stage.duckdb")
    #expect(!FileManager.default.fileExists(atPath: store),
            "the store was opened before the config was read")
}

/// A version this build cannot read is refused LOUDLY, and the sentence comes from SiftCore.
///
/// 🔴 This is the case that makes the corrupt-file refusal non-negotiable. A newer Sift writes a
/// field this build cannot see; if this build decoded around it, the next save would rewrite the
/// file without that field — a scope, a switch or a revoke silently dropped, with nothing on screen.
@Test func aFutureVersionConfigRefusesTheSessionWithItsOwnSentence() throws {
    let home = newHome()
    _ = try plantConfig(home, #"{"version": 2, "allowRemote": true, "connections": []}"#)

    var message = ""
    #expect(throws: SessionError.self) {
        do { _ = try newSession(home) } catch let error as SessionError {
            message = error.message
            throw error
        }
    }
    #expect(message.contains("format 2"), "\(message)")
    #expect(message.contains("update Sift"), "\(message)")
    #expect(!FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent("stage.duckdb")))
}

/// The permissive launch, end to end but offline: the file decides `harden()`'s deny list AND which
/// extensions are asked for. `.loaded` is deliberately not asserted — that needs a network INSTALL
/// on an unprepared machine, and it is what the gated `--verify` check is for. What IS asserted is
/// that Sift ASKED, which is the decision this file makes.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func aSavedAllowRemoteDecidesThePostureAndTheExtensionsAtLaunch() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true, connections: [chainSpec()]))
    let session = try newSession(home)

    #expect(session.allowRemoteAtLaunch == true)
    // Absent, not `false`: the permissive posture never issues the SET at all.
    #expect(session.database.hardened["disabled_filesystems"] == nil)
    #expect(session.database.hardened["autoload_known_extensions"] == true,
            "a remote session is still not allowed to autoload an extension")
    #expect(session.database.loadedExtensions["httpfs"] != nil,
            "httpfs must be asked for whenever remote is on — a pasted https:// URL needs no connection")
    #expect(session.database.loadedExtensions["azure"] != nil,
            "an azure connection must bring the azure extension with it")
    #expect(await session.connections().connections.map(\.name) == ["acct"])
}

/// `azure` costs a second binary to fetch, so it is asked for only when something needs it.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func azureIsNotLoadedForAnS3OnlyConfig() throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true, connections: [s3Spec()]))
    let session = try newSession(home)

    #expect(session.database.loadedExtensions["httpfs"] != nil, "s3 secrets are httpfs's")
    #expect(session.database.loadedExtensions["azure"] == nil)
}

// MARK: - issuance failures are recorded, never thrown

/// 🔴 **One bad credential must not brick the app.** A saved s3 connection whose Keychain item is
/// gone — deleted by hand in Keychain Access, or restored from a backup without the keychain — has
/// nothing to bind, so `createSecretSQL` produces nothing. That is a broken connection and the user
/// has to be told, but it is not a reason for a window full of local CSVs to refuse to open.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func aMissingCredentialIsRecordedAgainstItsConnectionAndTheSessionStillStarts() async throws {
    let home = newHome()
    let spec = s3Spec(name: "no-key-here")
    _ = try plantConfig(home, RemoteConfig(allowRemote: true, connections: [spec]))

    let session = try newSession(home)   // must not throw
    let issues = await session.connectionIssues()
    #expect(issues[spec.id] != nil, "a connection with no credential reported nothing wrong")
    #expect(issues[spec.id]?.contains("no-key-here") == true, "\(issues[spec.id] ?? "")")
    // No secret was registered for it, which is the state the sentence describes.
    #expect(try secretCount(session) == 0)

    // …and the engine is entirely usable.
    let csv = try makeCSV(dir: TestTemp.dir("connections-csv"), rows: 20)
    #expect(try await session.openPath(csv).rowCount == 20)
}

/// The healthy half of the same path: `credentialChain` stores nothing on purpose, so an absent
/// Keychain item is the CORRECT state for it and must not be reported as a problem.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func aCredentialChainConnectionIssuesWithNoKeychainItemAtAll() async throws {
    let home = newHome()
    let spec = chainSpec()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true, connections: [spec]))
    let session = try newSession(home)

    #expect(await session.connectionIssues().isEmpty)
    #expect(try secretCount(session) == 1, "the chain secret was not issued")
}

/// The strict posture reads no credential at all. A user who turned remote off should not be asked
/// to unlock their keychain at launch on behalf of a session that cannot use what is in it.
@Test func aStrictSessionIssuesNoSecretsEvenWithConnectionsSaved() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: false, connections: [chainSpec()]))
    let session = try newSession(home)

    #expect(try secretCount(session) == 0)
    #expect(await session.connectionIssues().isEmpty)
}

// MARK: - the operations

/// 🔴 **The measured outcome.** Saving the first connection on a strict session writes the file and
/// flips the master switch in it — and the engine still refuses the read, because MEASURED (§2)
/// `disabled_filesystems` cannot be narrowed inside a live `Database`. `.activeAfterRelaunch` is that
/// fact as a return value rather than a comment: the UI's move is "reopen Sift", never "try again".
///
/// 🔴 **`secretCount == 0` is a CORRECTION, and it is a stronger claim than the `== 1` it replaces.**
/// That `1` was real, and it was produced by the defect: `addConnection` installed the `azure`
/// extension over the network first — on the one session whose whole point is not making a request —
/// and the secret then registered because the extension was there. RE-MEASURED on a `harden()`ed
/// 1.5.5 with nothing loaded, every shape Sift issues is refused:
/// `Invalid Input Error: Secret type 'azure' does not exist, but it exists in the azure extension.`
/// (and the same for `s3`/httpfs, and for `PROVIDER credential_chain`). The old header of this file
/// and three other comments cited the opposite as MEASURED; that measurement was taken on a
/// `Database.inMemory()` with no `harden()`, whose `autoload_known_extensions` is DuckDB's default
/// `true`, so DuckDB loaded the extension behind the measurement.
///
/// So the honest state of a strict save is: the file has it, the Keychain has it, the ENGINE has
/// nothing, and the outcome says so. `connectionIssues()` stays empty rather than carrying DuckDB's
/// missing-extension sentence, because `connectionRowState` ranks an issue above
/// `.readyAfterRelaunch` and would paint a perfectly good save red.
@Test func theFirstConnectionTurnsRemoteOnInTheFileAndNotInThisEngine() async throws {
    let home = newHome()
    let session = try newSession(home)
    let spec = chainSpec(name: "first")

    let outcome = try await session.addConnection(spec, secret: nil)
    #expect(outcome == .activeAfterRelaunch)

    // The file says yes…
    let saved = try readConfig(home)
    #expect(saved.allowRemote == true)
    #expect(saved.connections == [spec])
    #expect(await session.connections() == saved, "the in-memory config drifted from the file")
    // …the engine holds nothing, and does not complain about holding nothing…
    #expect(try secretCount(session) == 0,
            "a strict engine registered a secret only a forbidden extension fetch could create")
    #expect(await session.connectionIssues().isEmpty)
    // …and the posture did not move.
    #expect(session.allowRemoteAtLaunch == false)
    #expect(session.database.hardened["disabled_filesystems"] == true)

    // What actually happens when the caller ignores the outcome and reads anyway. Pinned as a
    // message rather than "it threw": with `harden()` deleted this URL would 404 instead, which is
    // also an error and a completely different one.
    let t = try await session.openPath(try makeCSV(dir: TestTemp.dir("connections-csv"), rows: 5))
    var message = ""
    do {
        _ = try await session.runSQL(
            t.name, sql: "SELECT count(*) FROM read_parquet('http://127.0.0.1:9/x.parquet')",
            offset: 0, limit: 1
        )
        Issue.record("a remote read succeeded on a session that started strict")
    } catch let error as SessionError {
        message = error.message
    }
    #expect(message.contains("httpfs") || message.contains("disabled by configuration"),
            "expected the strict engine to refuse the read; got: \(message)")
}

/// 🔴 **The half the test above could not see: a strict save must not touch `extensions.duckdb.org`.**
///
/// `addConnection` used to gate its `installExtension` on `next.allowRemote` — the CONFIG, which it
/// had set to `true` fifteen lines earlier — instead of on the POSTURE. So the very first connection
/// a user ever saved, on the fresh-install session that is strict by construction, ran
/// LOAD → INSTALL → an outbound request, on behalf of a session whose whole point is not making one.
/// `disabled_filesystems` does not stop it: it gates DuckDB's VFS, not its extension installer.
///
/// Two assertions, because "the extension is present" has two provenances and only one of them is a
/// network call:
///
///  * `loadedExtensions["azure"] == nil` is the fourth `ExtensionState` — **never asked** — and it
///    is the one that fails on a warm machine, where `LOAD azure` succeeds from
///    `~/.duckdb/extensions` and the `INSTALL` branch is never reached. Every machine this suite has
///    ever run on is warm, which is exactly why nothing caught this.
///  * `networkInstalls` unchanged across the call is the same claim on a COLD machine, where the
///    request actually leaves. Compared against a snapshot rather than against `[]` because
///    `Session.init` legitimately installs `delta`/`excel` on a machine that has never run Sift, and
///    this test is about what `addConnection` decided, not about what the process arrived carrying.
@Test func savingTheFirstConnectionOnAStrictSessionInstallsNothing() async throws {
    let session = try newSession(newHome())
    let before = session.database.networkInstalls

    #expect(try await session.addConnection(chainSpec(name: "first"), secret: nil)
        == .activeAfterRelaunch)

    #expect(session.database.loadedExtensions["azure"] == nil,
            "a session that started strict asked DuckDB for the azure extension")
    #expect(session.database.networkInstalls == before,
            "a session that started strict installed \(session.database.networkInstalls) over the network")
}

/// The other side of it: a session that STARTED permissive is allowed to fetch what it just saved,
/// and the row it produces has to be able to say the extension is missing. Asserted as "Sift asked",
/// never as `.loaded` — `.loaded` needs a binary this machine may not have, which is the gated
/// `--verify` check's job.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func savingAConnectionOnAPermissiveSessionAsksForItsExtension() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true))
    let session = try newSession(home)

    _ = try await session.addConnection(chainSpec(name: "first"), secret: nil)

    #expect(session.database.loadedExtensions["azure"] != nil,
            "a permissive session did not ask for the extension the connection reads through")
}

/// The same operation on a session that STARTED permissive is `.active` — the connection works now.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func aConnectionAddedToAPermissiveSessionIsActiveImmediately() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true))
    let session = try newSession(home)

    #expect(try await session.addConnection(chainSpec(), secret: nil) == .active)
    #expect(try secretCount(session) == 1)
}

/// Add → remove, through the Keychain and through `duckdb_secrets()`, on a real engine.
///
/// 🔴 **On a PERMISSIVE session, which is a correction and a strengthening.** This used to run on a
/// strict one and assert `secretCount == 1`, and it passed only because `addConnection` installed
/// `httpfs` over the network first — a strict engine cannot register a `TYPE s3` secret at all
/// (RE-MEASURED; see `theFirstConnectionTurnsRemoteOnInTheFileAndNotInThisEngine`). So the
/// add-and-drop of a live secret was never exercised on a posture that could hold one, and now it
/// is: `.active` rather than `.activeAfterRelaunch` is asserted as part of the round trip.
@Test(.enabled(if: keychainUsable && permissivePostureIsOffline, permissiveSkip))
func addingAndRemovingAConnectionRoundTripsTheFileTheKeychainAndTheSecret() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true))
    let session = try newSession(home)
    let spec = s3Spec(name: "round trip")
    defer { try? Keychain.delete(account: spec.id.uuidString, in: testService) }

    #expect(try await session.addConnection(spec, secret: "SUPERSECRETKEY123") == .active)

    #expect(try readConfig(home).connections == [spec])
    #expect(try Keychain.get(account: spec.id.uuidString, in: testService)
        == Data("SUPERSECRETKEY123".utf8))
    #expect(try secretCount(session) == 1)
    #expect(await session.connectionIssues().isEmpty)

    try await session.removeConnection(spec.id)

    #expect(try readConfig(home).connections.isEmpty)
    #expect(try Keychain.get(account: spec.id.uuidString, in: testService) == nil,
            "the credential outlived the connection that pointed at it")
    #expect(try secretCount(session) == 0, "the secret is still live on the engine after a removal")
    #expect(await session.connectionIssues().isEmpty)
}

/// 🔴 Removing the last connection does NOT revoke the master switch. A pasted `https://` URL needs
/// no saved connection, so an empty list is not a request to go strict — and because the posture
/// cannot be narrowed live anyway, an auto-revoke would change the file without changing the engine
/// and leave the UI saying something untrue.
@Test func removingTheLastConnectionLeavesAllowRemoteAlone() async throws {
    let home = newHome()
    let session = try newSession(home)
    let spec = chainSpec()

    _ = try await session.addConnection(spec, secret: nil)
    #expect(try readConfig(home).allowRemote == true)

    try await session.removeConnection(spec.id)
    let after = try readConfig(home)
    #expect(after.connections.isEmpty)
    #expect(after.allowRemote == true, "the delete quietly revoked the user's own switch")
    #expect(await session.connections().allowRemote == true)
}

/// Revoking: the file changes, the credentials go away NOW, and the engine stays permissive until
/// the next launch. Three separate claims, and only the middle one is immediate.
@Test(.enabled(if: permissivePostureIsOffline, permissiveSkip))
func revokingDropsTheSecretsButLeavesTheEnginePermissiveUntilRelaunch() async throws {
    let home = newHome()
    _ = try plantConfig(home, RemoteConfig(allowRemote: true, connections: [chainSpec()]))
    let session = try newSession(home)
    #expect(try secretCount(session) == 1)

    #expect(try await session.setAllowRemote(false) == .activeAfterRelaunch)
    #expect(try readConfig(home).allowRemote == false)
    #expect(try secretCount(session) == 0, "a revoke left the credentials live on the engine")
    #expect(await session.connectionIssues().isEmpty)
    #expect(session.database.hardened["disabled_filesystems"] == nil,
            "the engine posture moved — it cannot, and pretending it did is the bug")

    // …and changing your mind puts them back, on a session that started permissive.
    #expect(try await session.setAllowRemote(true) == .active)
    #expect(try secretCount(session) == 1)
    #expect(try readConfig(home).allowRemote == true)
}

/// Asking for the posture the engine already has is `.active` — there is nothing to relaunch for.
@Test func settingTheSwitchToThePostureTheEngineAlreadyHasIsActive() async throws {
    let session = try newSession(newHome())
    #expect(try await session.setAllowRemote(false) == .active)
    #expect(try await session.setAllowRemote(true) == .activeAfterRelaunch)
}

@Test func aDuplicateConnectionIdIsRefusedWithASentence() async throws {
    let session = try newSession(newHome())
    let spec = chainSpec()
    _ = try await session.addConnection(spec, secret: nil)

    var message = ""
    do {
        _ = try await session.addConnection(spec, secret: nil)
        Issue.record("the same connection was saved twice")
    } catch let error as SessionError {
        message = error.message
    }
    #expect(message.contains("already saved"), "\(message)")
    #expect(await session.connections().connections.count == 1)
}

/// An unnamed connection would file a Keychain item labelled "Sift — ", which is the anonymous item
/// `Keychain.set`'s `label` exists to prevent.
@Test func aConnectionWithNoNameIsRefused() async throws {
    let session = try newSession(newHome())
    var message = ""
    do {
        _ = try await session.addConnection(chainSpec(name: "  "), secret: nil)
        Issue.record("an unnamed connection was saved")
    } catch let error as SessionError {
        message = error.message
    }
    #expect(message.contains("needs a name"), "\(message)")
    #expect(await session.connections().connections.isEmpty)
}

@Test func removingAConnectionThatIsNotThereSaysSo() async throws {
    let session = try newSession(newHome())
    var message = ""
    do {
        try await session.removeConnection(UUID())
        Issue.record("removing an unknown connection succeeded")
    } catch let error as SessionError {
        message = error.message
    }
    #expect(message.contains("no saved connection"), "\(message)")
}

// MARK: - the file on disk

/// 🔴 0600, for the reason `~/.sift` is 0700 and a downloaded cache file is 0600: this file names
/// the storage accounts and access key ids a user reaches. The key itself is in the Keychain, but
/// MEASURED (§6c) `duckdb_secrets()` prints `account_name` and `key_id` in the clear, so identity is
/// exactly what leaks when this is world-readable.
@Test func theConfigIsWrittenAt0600() async throws {
    let home = newHome()
    let session = try newSession(home)
    _ = try await session.addConnection(chainSpec(), secret: nil)

    let attrs = try FileManager.default.attributesOfItem(atPath: session.connectionsPath)
    #expect(attrs[.posixPermissions] as? Int == 0o600,
            "connections.json is \(String(describing: attrs[.posixPermissions]))")
}

/// The round trip that matters at launch: what one session writes, the next one reads. Written by
/// the real `addConnection` and read by the real `loadRemoteConfig`, so a change to either end
/// breaks this rather than only breaking on a user's machine.
@Test func whatOneSessionSavesTheNextOneReads() async throws {
    let home = newHome()
    let s3 = s3Spec(name: "warehouse")
    let azure = ConnectionSpec(
        kind: .azure, name: "cold storage", accountName: "coldacct", azureAuth: .connectionString
    )

    // Two connections through the real API, on a home that is then handed to a fresh Session.
    let writer = try newSession(home)
    _ = try await writer.addConnection(s3, secret: nil)
    _ = try await writer.addConnection(azure, secret: nil)
    await writer.shutdown()

    let reloaded = try Session.loadRemoteConfig(Session.connectionsPath(in: home))
    #expect(reloaded.version == remoteConfigVersion)
    #expect(reloaded.allowRemote == true)
    #expect(reloaded.connections == [s3, azure], "the saved connections did not survive the round trip")
}

/// A failed save must not strand a credential for a connection nobody can see. Pointed at a home
/// whose config path has been turned into a DIRECTORY, so the atomic rename cannot land.
@Test(.enabled(if: keychainUsable))
func aConfigThatCannotBeSavedTakesTheCredentialBackOut() async throws {
    let home = newHome()
    let session = try newSession(home)
    try FileManager.default.createDirectory(
        atPath: session.connectionsPath, withIntermediateDirectories: true
    )
    let spec = s3Spec(name: "doomed")
    defer { try? Keychain.delete(account: spec.id.uuidString, in: testService) }

    await #expect(throws: SessionError.self) {
        _ = try await session.addConnection(spec, secret: "SUPERSECRETKEY123")
    }
    #expect(try Keychain.get(account: spec.id.uuidString, in: testService) == nil,
            "the credential outlived the save that failed")
    #expect(await session.connections().connections.isEmpty,
            "a failed save left the connection in the in-memory list")
}

// MARK: - installExtension

/// The two states that cost nothing to reach. `.unavailable` is the third and it is below, gated —
/// see that test for why it cannot live here.
@Test func installExtensionReportsTheLoadedAndRejectedStates() async throws {
    let session = try newSession(newHome())
    let before = session.database.networkInstalls

    // Already loaded at launch, so this is the cheap path and must not re-LOAD anything.
    #expect(await session.installExtension("delta") == .loaded)
    // A name that cannot be a DuckDB extension is a Sift bug, not a user-fixable state. Rejected by
    // the name guard, so it never reaches DuckDB at all — the assertion below says so rather than
    // trusting it.
    #expect(await session.installExtension("httpfs; ATTACH 'evil.db'") == .rejectedName)

    #expect(session.database.networkInstalls == before,
            "neither of these two states may cost an INSTALL; got \(session.database.networkInstalls)")
}

/// 🔴 **The third state, and the one that cannot be reached offline.** `.unavailable` means LOAD and
/// INSTALL both failed, so producing it needs an `INSTALL` — and `INSTALL no_such_extension_zzz` is a
/// request to `extensions.duckdb.org` that comes back 404. That is a network call, which puts this
/// test in the gated set by AGENTS.md's own rule ("those are the ones allowed to `INSTALL` an
/// extension over the network") rather than in the default run, where it had been quietly living.
///
/// The `remoteFact` prefix is the `--filter` CI's canary step selects on, so this is a rename with a
/// job, not a label.
@Test(.enabled(if: remoteFacts))
func remoteFactInstall_aLegalNameWithNoBinaryAnywhereIsUnavailableWithAReason() async throws {
    let session = try newSession(newHome())

    let missing = await session.installExtension("no_such_extension_zzz")
    if case .unavailable(let why) = missing {
        #expect(!why.isEmpty, "an unavailable extension reported no reason")
    } else {
        Issue.record("expected .unavailable, got \(missing)")
    }
    // The state and the act, separately: `.unavailable` is what Sift reports, and the INSTALL is
    // what it did to find out. Nothing else in this file may append to that array.
    #expect(session.database.networkInstalls.last == "no_such_extension_zzz",
            "the INSTALL was not recorded; got \(session.database.networkInstalls)")
}
