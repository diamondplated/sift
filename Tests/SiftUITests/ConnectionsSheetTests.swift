import DuckDBKit
import Foundation
import SiftCore
import Testing
import TestSupport
@testable import SiftEngine
@testable import SiftUI

// The Connections sheet. A SwiftUI `body` cannot be tested, so every decision it makes is a free
// function beside it and everything here drives those directly — the split `StagedDataSheet` and
// `RootView.gridState` already made.
//
// Three claims are load-bearing and each has its own test rather than being a clause in someone
// else's:
//
//  1. **The posture sentence.** It is the security posture of the whole feature, pinned verbatim.
//  2. **`.activeAfterRelaunch` is rendered because the engine MEASURED it.** Two sentences that
//     differ by direction, `nil` for `.active`, and one end-to-end pass driven by a real `Session`
//     so the copy cannot be a constant that happens to read right.
//  3. **The engine's sentences are rendered, never paraphrased.** `connectionIssues()` comes back
//     from a real engine and lands in the row byte for byte.
//
// Nothing here needs the network. Every session below launches STRICT — `remoteExtensions(for:)`
// returns `[]` in that posture, so no `INSTALL` is attempted — and the one that flips the switch
// uses `setAllowRemote`, which issues secrets and does not touch an extension. `CREATE SECRET`
// parses, binds and registers on a bare 1.5.5 with nothing loaded (MEASURED, Task 4).
//
// Nothing is `.serialized`, and every credential written here would go under a test-only Keychain
// service (`Session.keychainService`) — the same split `ConnectionsTests` makes, so no test run can
// touch a credential a user actually saved. In practice nothing below writes one at all.

private let testService = Keychain.service + ".connections-sheet-test"

/// A home with a `connections.json` already on it. The posture is frozen when the `Database` opens
/// (MEASURED, remote facts §2), so planting the file first is the only way to choose it.
private func plantedSession(
    allowRemote: Bool, connections: [ConnectionSpec] = []
) throws -> Session {
    let home = TestTemp.path("connections-sheet")
    try FileManager.default.createDirectory(
        atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Session.writeRemoteConfig(
        RemoteConfig(allowRemote: allowRemote, connections: connections),
        to: Session.connectionsPath(in: home))
    return try Session(home: home, keychainService: testService)
}

private func s3Spec(name: String = "prod") -> ConnectionSpec {
    ConnectionSpec(kind: .s3, name: name, accountName: "AKIAEXAMPLEKEYID", region: "us-east-1")
}

private func chainSpec(name: String = "acct") -> ConnectionSpec {
    ConnectionSpec(kind: .azure, name: name, accountName: "acct", azureAuth: .credentialChain)
}

// MARK: - the master switch

/// 🔴 **The security posture of the whole feature, pinned.** Three things have to be in it and each
/// one is load-bearing: that a `SELECT` can read a URL, that a URL built from local rows is
/// therefore an EXIT for local data, and that SELECT-only still blocks every write. A reworded
/// version that drops the middle clause describes a smaller permission than the switch actually
/// grants, which is the euphemism this test exists to keep out.
@Test func theRemoteSwitchSentenceSaysWhatTurningItOnActuallyAllows() {
    #expect(
        allowRemoteExplanation == """
            With this on, a SELECT in the SQL box can read a URL — and a URL that DuckDB builds \
            out of your own rows is how the contents of a local file leave this machine. Sift \
            still refuses everything that is not a SELECT, so nothing remote can be written to or \
            deleted. Off is the default, and one click here turns it off again.
            """)
}

/// 🔴 **Two sentences, and they are not the same sentence.** `.activeAfterRelaunch` means something
/// different in each direction: switching ON leaves the filesystem closed until the process
/// restarts, while switching OFF drops every credential immediately and still cannot close a
/// filesystem this `Database` already opened — so a `https://` URL, which needs no saved connection,
/// keeps working. One shared "saved, relaunch Sift" would tell a user they had revoked something
/// they had not.
///
/// Mutation: return the same string for both directions and the inequality goes red; drop the `on`
/// parameter's branch entirely and the off-direction assertion goes red first.
@Test func theSwitchSaysSomethingDifferentInEachDirectionAndBothSayRelaunch() {
    let on = allowRemoteOutcome(on: true, .activeAfterRelaunch)
    let off = allowRemoteOutcome(on: false, .activeAfterRelaunch)

    #expect(
        on == """
            Saved. This session started with remote data off, and DuckDB cannot re-open a \
            filesystem it has already closed — relaunch Sift before a remote URL will load.
            """)
    #expect(
        off == """
            Saved, and every saved credential has been dropped from this session. This session \
            started with remote data on, and DuckDB cannot close a filesystem it has already \
            opened — a remote URL stays readable until you relaunch Sift.
            """)
    #expect(on != off, "one sentence for both directions is the half that is wrong")
    // The off sentence must not read as a completed revoke — the credentials are gone, the
    // filesystem is not.
    #expect(off?.contains("stays readable") == true)
}

/// 🔴 **`.active` says nothing about relaunching**, in either direction. The engine measures which
/// case it is; a UI that appended "relaunch Sift" defensively would tell every user of a permissive
/// session to restart an app that is already working.
@Test func nothingTellsTheUserToRelaunchWhenTheEngineMeasuredActive() {
    #expect(allowRemoteOutcome(on: true, .active) == nil)
    #expect(allowRemoteOutcome(on: false, .active) == nil)
    #expect(addedConnectionOutcome(.active, turnedRemoteOn: false) == nil)
    #expect(addedConnectionOutcome(.active, turnedRemoteOn: true)?.contains("relaunch") == false)
}

/// 🔴 **Driven by a real engine, so the copy cannot be a constant that happens to read right.** Both
/// outcomes come out of the same `Session` in the same test: asking a strict session for the posture
/// it already has is `.active` (nothing to relaunch for), and asking it to go permissive is
/// `.activeAfterRelaunch` (the file changed; this `Database` did not). Asserting only against
/// hand-built enum values would pass for a screen wired to neither.
///
/// Offline by construction: a strict launch loads no remote extension, and `setAllowRemote` issues
/// secrets without touching one.
@Test func aRealStrictSessionProducesBothOutcomesAndTheCopyFollowsThem() async throws {
    let session = try plantedSession(allowRemote: false)

    let unchanged = try await session.setAllowRemote(false)
    #expect(unchanged == .active, "a strict session asked to stay strict has nothing to relaunch for")
    #expect(allowRemoteOutcome(on: false, unchanged) == nil)

    let widened = try await session.setAllowRemote(true)
    #expect(widened == .activeAfterRelaunch)
    #expect(allowRemoteOutcome(on: true, widened)?.contains("relaunch Sift") == true)
    // …and the file really did change, which is the half that IS true immediately.
    #expect(await session.connections().allowRemote)
}

// MARK: - saving one

/// Two independent clauses. Saving the first connection turns the master switch on in the file — a
/// posture change the user did not ask for in as many words — and that is a separate fact from
/// whether this session can act on it.
@Test func aSaveSaysWhatItChangedBeyondAddingARow() {
    #expect(
        addedConnectionOutcome(.active, turnedRemoteOn: true)
            == "Saving your first connection turned Allow remote data on.")
    #expect(
        addedConnectionOutcome(.activeAfterRelaunch, turnedRemoteOn: false)
            == "This session started with remote data off, so relaunch Sift before this "
                + "connection can be used.")

    let both = addedConnectionOutcome(.activeAfterRelaunch, turnedRemoteOn: true)
    #expect(both?.contains("turned Allow remote data on") == true)
    #expect(both?.contains("relaunch Sift") == true)
}

/// 🔴 **Save is disabled exactly where `createSecretSQL` would return `nil`, and nowhere else.**
/// Every one of those cases saves cleanly and then sits in the list wearing "no credential is saved
/// for …", so blocking them is the point. Requiring anything more — a region, an account name under
/// `connectionString` — would refuse a save the engine is perfectly happy with.
///
/// Mutation: drop the `nonBlank(name)` guard and the first assertion goes red; make the s3 branch
/// require only the key id and the fourth goes red; require a region and the last goes red.
@Test func saveIsBlockedExactlyWhereTheEngineCouldNotBuildASecret() {
    // A connection with no name is refused by `addConnection` itself — it is the Keychain item's
    // label and every sentence in the engine names it.
    #expect(
        !canSaveConnection(
            kind: .azure, azureAuth: .credentialChain, name: "  ", account: "acct", secret: ""))

    // `credentialChain` stores nothing; the account name is the only thing there is to bind.
    #expect(
        canSaveConnection(
            kind: .azure, azureAuth: .credentialChain, name: "prod", account: "acct", secret: ""))
    #expect(
        !canSaveConnection(
            kind: .azure, azureAuth: .credentialChain, name: "prod", account: " ", secret: "x"))

    // `connectionString` binds only the string. The account name is display identity, so demanding
    // it would be a rule the engine does not have.
    #expect(
        canSaveConnection(
            kind: .azure, azureAuth: .connectionString, name: "prod", account: "", secret: "DefEnd"))
    #expect(
        !canSaveConnection(
            kind: .azure, azureAuth: .connectionString, name: "prod", account: "acct", secret: ""))

    // s3 needs BOTH halves — `createSecretSQL` refuses a half-empty secret so an anonymous read of
    // a public bucket keeps working.
    #expect(
        canSaveConnection(
            kind: .s3, azureAuth: .credentialChain, name: "prod", account: "AKIA", secret: "shh"))
    #expect(
        !canSaveConnection(
            kind: .s3, azureAuth: .credentialChain, name: "prod", account: "AKIA", secret: " "))
    #expect(
        !canSaveConnection(
            kind: .s3, azureAuth: .credentialChain, name: "prod", account: "", secret: "shh"))
}

/// 🔴 **THE CREDENTIAL NEVER REACHES THE SPEC.** `ConnectionSpec` is written to `connections.json`
/// as plain JSON, so a secret that leaked into any of its fields would be a credential on disk in
/// the clear. Asserted by encoding the spec the form builds and searching the bytes — a field-by-
/// field assertion would pass for a spec that grew a seventh field tomorrow.
@Test func theAddFormNeverPutsTheCredentialIntoTheSavedSpec() throws {
    let secret = "sk-DO-NOT-PERSIST-8f3a9c"
    var draft = ConnectionDraft()
    draft.kind = .s3
    draft.name = "prod"
    draft.account = "AKIAEXAMPLEKEYID"
    draft.region = "us-east-1"
    draft.secret = secret

    let json = String(decoding: try JSONEncoder().encode(draft.spec()), as: UTF8.self)
    #expect(!json.contains(secret), "the credential reached the config file: \(json)")
    #expect(json.contains("AKIAEXAMPLEKEYID"), "…and the non-secret half is still there")
    #expect(draft.secretForEngine == secret, "the credential must still reach the Keychain route")

    // `credentialChain` is the one shape that stores nothing at all, so it must hand the engine
    // `nil` rather than an empty string — an empty Keychain item is an orphan nobody reads.
    var chain = ConnectionDraft()
    chain.kind = .azure
    chain.azureAuth = .credentialChain
    chain.secret = "typed then switched"
    #expect(chain.secretForEngine == nil)
}

// MARK: - one row

/// 🔴 **One fact, one spelling.** `extensionName(for:)` is internal to `SiftEngine`, so this screen
/// carries its own copy to decide which extension a row's Install button asks for. Delete this test
/// and the two can drift — and the drift is an "Install httpfs" button on a row the engine is
/// loading `azure` for, which installs the wrong thing and reports success.
@Test func theExtensionThisScreenNamesIsTheOneTheEngineLoads() {
    #expect(duckDBExtension(for: .azure) == SiftEngine.extensionName(for: .azure))
    #expect(duckDBExtension(for: .s3) == SiftEngine.extensionName(for: .s3))
    #expect(duckDBExtension(for: .azure) == "azure")
    #expect(duckDBExtension(for: .s3) == "httpfs", "s3 secrets are httpfs's")
}

/// 🔴 **The precedence IS the function**, and each step is a different failure if it moves.
///
/// Mutations, each naming this test:
///  * delete `guard allowRemote` → the first assertion goes red (a saved row claims to be ready on a
///    session that is not allowed to reach anything);
///  * delete `if let issue` → the third goes red (the engine's own sentence is swallowed by a
///    posture message);
///  * delete `guard usableNow` → the fifth goes red (a strict session, which has loaded no remote
///    extension at all, tells every row its extension is missing and offers a button whose
///    `INSTALL` cannot succeed);
///  * collapse `.rejectedName` into `.unavailable` → the last goes red (a Sift bug is reported as
///    something the user can install their way out of).
@Test func aRowsStateIsDecidedInThatOrderAndTheOrderMatters() {
    let spec = chainSpec()
    func state(
        issue: String? = nil, ext: ExtensionState? = .loaded, allowRemote: Bool = true,
        usableNow: Bool = true
    ) -> ConnectionRowState {
        connectionRowState(
            spec, issue: issue, extensionState: ext, allowRemote: allowRemote, usableNow: usableNow)
    }

    // 1. The switch beats everything: nothing saved is in use, so nothing else is worth saying.
    #expect(state(issue: "anything", ext: .rejectedName, allowRemote: false) == .remoteOff)

    // 2. The engine's sentence beats the posture and beats the extension — `addConnection`'s own
    //    order, where the credential's failure is the more actionable of the two.
    #expect(state(issue: "no credential is saved for acct.") == .issue("no credential is saved for acct."))
    #expect(
        state(issue: "engine said so", ext: .unavailable("offline"), usableNow: false)
            == .issue("engine said so"))

    // 3. A relaunch beats a missing extension: a strict session has loaded nothing remote, so the
    //    extension is not what is wrong and its Install button could not succeed anyway.
    #expect(state(ext: nil, usableNow: false) == .readyAfterRelaunch)
    #expect(state(ext: .unavailable("offline"), usableNow: false) == .readyAfterRelaunch)

    // 4. Then the extension, carrying DuckDB's own first line — "run INSTALL azure" is the wrong
    //    advice for a machine that is simply offline.
    #expect(
        state(ext: .unavailable("Connection failed"))
            == .extensionMissing(name: "azure", why: "Connection failed"))
    #expect(state(ext: .unavailable("x")).text.contains("the azure extension is not installed"))

    // 5. Ready, including the fourth `ExtensionState` state — never asked. Absence is the lack of
    //    evidence of a problem, and every path that would have asked records its failure as an issue.
    #expect(state() == .ready)
    #expect(state(ext: nil) == .ready)

    // 6. The one case that is a Sift bug and says so.
    #expect(state(ext: .rejectedName) == .siftBug("azure"))
    #expect(state(ext: .rejectedName).text.contains("bug in Sift"))
}

/// The colour is a claim about whether something is WRONG, and two of the six states are not.
///
/// Mutation: make `.remoteOff` or `.readyAfterRelaunch` a problem and this goes red — the normal
/// strict posture, which is the default every user starts in, would paint its whole list red.
@Test func onlyABrokenRowReadsAsBroken() {
    #expect(!ConnectionRowState.ready.isProblem)
    #expect(!ConnectionRowState.readyAfterRelaunch.isProblem)
    #expect(!ConnectionRowState.remoteOff.isProblem)
    #expect(ConnectionRowState.issue("x").isProblem)
    #expect(ConnectionRowState.extensionMissing(name: "azure", why: "y").isProblem)
    #expect(ConnectionRowState.siftBug("azure").isProblem)
}

/// 🔴 **The engine's sentence, byte for byte, out of a real engine.** `connectionIssues()` is the
/// only channel a failed issuance has, and the house contract is one clean sentence per error — a
/// screen that summarised it ("this connection has a problem") or prefixed it would be a second
/// wording that drifts the first time the engine's changes.
///
/// The s3 spec with no Keychain item is the shape `ConnectionsTests` already proves produces a
/// sentence: `createSecretSQL` needs both halves, and there is no secret to find.
///
/// Also the end-to-end half of the precedence claim: this session is strict, so the row WOULD be
/// `.readyAfterRelaunch` — and the real issue beats it.
@Test func aRowRendersTheEnginesOwnSentenceAndNeverASecondWordingForIt() async throws {
    let spec = s3Spec(name: "no-key-here")
    let session = try plantedSession(allowRemote: false, connections: [spec])
    // Strict at launch, so nothing was issued yet; this is what fills `connectionIssues()`.
    #expect(try await session.setAllowRemote(true) == .activeAfterRelaunch)

    let sentence = try #require(
        await session.connectionIssues()[spec.id],
        "a connection with no credential reported nothing wrong")
    #expect(sentence.contains("no-key-here"), "\(sentence)")

    let allowRemote = await session.connections().allowRemote
    let state = connectionRowState(
        spec, issue: sentence, extensionState: nil,
        allowRemote: allowRemote,
        usableNow: session.allowRemoteAtLaunch && allowRemote)
    #expect(state == .issue(sentence))
    #expect(state.text == sentence, "the engine's sentence was reworded on its way to the row")
    #expect(state.isProblem)
}

/// The identity half of a row names the account or the key id — both of which are already in
/// `connections.json` in the clear and both of which `duckdb_secrets()` prints unredacted — and
/// never anything from the Keychain.
@Test func aRowNamesWhatItReachesAndHowItSignsIn() {
    #expect(connectionDetail(chainSpec()) == "Azure · acct · az login")
    #expect(
        connectionDetail(
            ConnectionSpec(
                kind: .azure, name: "p", accountName: "store", azureAuth: .connectionString))
            == "Azure · store · connection string in your Keychain")
    #expect(connectionDetail(s3Spec()) == "S3 · AKIAEXAMPLEKEYID · us-east-1")
    #expect(
        connectionDetail(
            ConnectionSpec(
                kind: .s3, name: "m", accountName: "K", region: "us-west-2",
                endpoint: "minio.local:9000"))
            == "S3 · K · us-west-2 · minio.local:9000")

    // Hand-edited configs, which is the only way to reach either: the gap is named rather than
    // rendered as an empty run of separators.
    #expect(connectionDetail(ConnectionSpec(kind: .azure, name: "p", azureAuth: .credentialChain))
        == "Azure · no account name · az login")
    #expect(connectionDetail(ConnectionSpec(kind: .azure, name: "p")).hasSuffix("no sign-in method saved"))
    #expect(connectionDetail(ConnectionSpec(kind: .s3, name: "p")) == "S3 · no key id · no region")
}

/// The removal confirmation says the part that is not recoverable, because that is the only reason
/// there is a confirmation at all.
@Test func removingAConnectionSaysTheKeychainItemGoesWithIt() {
    #expect(
        removeConnectionConfirmation("prod") == """
            Remove prod? Its credential is deleted from your Keychain as well, and Sift cannot get \
            it back — you would have to enter it again.
            """)
}

/// 🔴 **A SAS URL is not a connection**, and the single line this screen gives it says exactly that
/// and exactly why. The token is a bearer credential in the query string; `RemoteURL` splits it off
/// so it cannot reach a config file, the staging catalog or a log, and a "save this SAS URL" field
/// would persist the one string that whole type exists to keep off disk.
@Test func theSasLineSaysItIsNotAConnectionAndNeverTouchesDisk() {
    #expect(
        sasNote == """
            A URL with a SAS token in it is not a connection — paste the whole URL when you open \
            it and Sift keeps the token in memory for that one read, never on disk.
            """)
}

// MARK: - the route

/// The sheet is about the APP, not about an open table — so it has no subject, and nothing that
/// happens to the catalog may dismiss it.
///
/// Mutation: give `.connections` a subject in `ModalSheet.subject` and the second half goes red.
/// `dismissSheetWithoutASubject` would then close the Connections screen the moment a table left the
/// catalog — which, for a table opened over a connection the user is in the middle of removing, is
/// precisely when the screen is most needed.
@MainActor
@Test func connectionsIsASheetAboutTheAppAndSurvivesTheCatalogChanging() async throws {
    #expect(AppState.ModalSheet.connections.id == "connections")
    #expect(AppState.ModalSheet.connections.subject == nil)

    let state = AppState(session: try Session(home: tempHome()))
    await state.open(path: try makeCSV(in: tempDir(), rows: 3))
    let name = try #require(state.activeName)

    state.presentConnections()
    #expect(state.modalSheet == .connections)
    await state.close(name)
    #expect(state.modalSheet == .connections, "the connections screen was dismissed by a close")
}

/// No `can*` guard, deliberately — and the state a guard would most plausibly have been written for
/// is the one the screen has the most to say in: remote off, nothing saved, which is where the
/// master switch itself lives.
@MainActor
@Test func theConnectionsScreenOpensWithNothingSavedAndNothingOpen() throws {
    let state = AppState(session: try Session(home: tempHome()))
    #expect(state.tables.isEmpty)
    state.presentConnections()
    #expect(state.modalSheet == .connections)
}
