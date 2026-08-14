import DuckDBKit
import Foundation
import SiftCore
import SiftEngine
import SwiftUI

// The Connections screen — Phase 1's only way into remote data from the window. The master switch,
// the saved connections and what each of them is actually doing, and the form that adds one.
//
// 🔴 **TWO CHANNELS, AND EVERY ROW RENDERS BOTH.** `ConnectionOutcome` reports POSTURE — whether the
// filesystem is open in THIS process — and says nothing about whether the DuckDB extension the
// connection reads through is installed. That is a separate per-connection fact arriving through
// `Session.connectionIssues()` and `installExtension`'s own return value. A screen that renders the
// outcome and not the issues tells someone their connection is ready while its reader is missing.
//
// 🔴 **`.activeAfterRelaunch` is a MEASURED property of DuckDB 1.5.5, not defensive pessimism.**
// `disabled_filesystems` only ever GROWS inside one `Database` (remote facts §2), so flipping the
// master switch on issues the secret immediately and cannot open the filesystem until the process
// restarts. The engine measures which case it is rather than asserting it; everything here renders
// what it measured, and nothing here says "relaunch" when it measured `.active`.
//
// Every sentence below is a free function or a constant with its own test, and the `body` only picks
// and places — the same split `StagedDataSheet` makes, and the only thing that makes a windowless
// machine able to check this screen's copy at all.
//
// **`UnsupportedRemoteConfig` is deliberately absent from this file.** A `connections.json` from a
// future version makes `Session.init` THROW (`loadRemoteConfig`), so there is no `Session`, no
// `AppState` and no sheet to render it in — the state is unreachable from here by construction, and
// inventing a second wording for it in a screen that can never show it is exactly what the brief
// forbids. `ConnectionsSheetTests` pins that it really is the launch that refuses, and the sentence
// the user must be shown is `UnsupportedRemoteConfig.description`, wrapped by `loadRemoteConfig`.
// Rendering it belongs to whoever builds the `Session` — see this task's report.

// MARK: - the posture

/// The sentence beside the master switch, and the security posture of the whole feature.
///
/// 🔴 **It names the exfiltration path in as many words.** Remote data on does not merely mean "Sift
/// can read a URL": DuckDB will happily build that URL out of the rows of a local file, so a single
/// `SELECT` in the SQL box is enough to put the contents of a file on this machine into somebody
/// else's access log. Saying only "Sift can read remote files" would be the euphemism version of the
/// same switch, and a user who is told the smaller truth cannot consent to the larger one.
///
/// The second clause is the half that is genuinely reassuring and it is true: the SELECT-only gate
/// (`assertSingleSelectStatement`) is a newline subquery wrap, not a keyword blocklist, so nothing
/// remote can be written to, replaced or deleted however the statement is spelled.
///
/// The last clause is a claim about the CONTROL, not about immediate effect — what a click actually
/// achieves in a running session is `allowRemoteOutcome`'s job, because the two are not the same
/// thing and only one of them can be promised in advance.
public let allowRemoteExplanation = """
    With this on, a SELECT in the SQL box can read a URL — and a URL that DuckDB builds out of your \
    own rows is how the contents of a local file leave this machine. Sift still refuses everything \
    that is not a SELECT, so nothing remote can be written to or deleted. Off is the default, and \
    one click here turns it off again.
    """

/// The one line about SAS URLs, and the only mention of them this screen gets.
///
/// 🔴 **A SAS URL is not a connection and must never be offered as one.** The token is a bearer
/// credential living in the query string; `RemoteURL` splits it off precisely so it cannot reach
/// `spec.target`, `_sift_sources`, `connections.json` or a log, and `wireURL(_:)` is the single
/// choke point that re-attaches it for DuckDB. A "save this SAS URL" field would persist the one
/// string the entire type exists to keep off disk.
public let sasNote = """
    A URL with a SAS token in it is not a connection — paste the whole URL when you open it and \
    Sift keeps the token in memory for that one read, never on disk.
    """

/// The DuckDB extension a saved connection reads through. `s3` secrets are httpfs's.
///
/// 🔴 A second spelling of `SiftEngine.extensionName(for:)`, which is internal to that module and so
/// cannot be called from here. The copy is safe only because
/// `ConnectionsSheetTests.theExtensionThisScreenNamesIsTheOneTheEngineLoads` asserts the two agree
/// for every `ConnectionKind` — delete that test and this becomes the drift that offers an "Install
/// httpfs" button for a connection the engine is loading `azure` for.
public func duckDBExtension(for kind: ConnectionKind) -> String {
    switch kind {
    case .azure: return "azure"
    case .s3: return "httpfs"
    }
}

/// What the master switch just did, or `nil` when the toggle's own position already says it.
///
/// 🔴 **Two sentences, because turning it ON and turning it OFF fail differently**, and a single
/// "relaunch Sift" for both would be wrong in the more dangerous direction. On a session that
/// started permissive, switching off DOES take the credentials away immediately (`setAllowRemote`
/// drops every secret) but CANNOT close the filesystem — so a `https://` URL that needs no saved
/// connection stays readable until the process restarts. A user told only "saved" would believe they
/// had revoked something they had not.
public func allowRemoteOutcome(on: Bool, _ outcome: ConnectionOutcome) -> String? {
    guard outcome == .activeAfterRelaunch else { return nil }
    if on {
        return "Saved. This session started with remote data off, and DuckDB cannot re-open a "
            + "filesystem it has already closed — relaunch Sift before a remote URL will load."
    }
    return "Saved, and every saved credential has been dropped from this session. This session "
        + "started with remote data on, and DuckDB cannot close a filesystem it has already "
        + "opened — a remote URL stays readable until you relaunch Sift."
}

/// What a save just did beyond adding a row, or `nil` when the new row says it all.
///
/// Two independent clauses rather than four spelled-out branches: the first connection turns the
/// master switch on in the file (`addConnection`), which is a posture change the user did not ask
/// for in as many words and must therefore be said out loud; the second is the same measured
/// relaunch fact as above. Either, both, or neither can be true.
public func addedConnectionOutcome(_ outcome: ConnectionOutcome, turnedRemoteOn: Bool) -> String? {
    var parts: [String] = []
    if turnedRemoteOn {
        parts.append("Saving your first connection turned Allow remote data on.")
    }
    if outcome == .activeAfterRelaunch {
        parts.append(
            "This session started with remote data off, so relaunch Sift before this connection "
                + "can be used.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// The confirmation before a removal, because it deletes the Keychain item too.
///
/// Not recoverable from Sift and the sentence says so: `removeConnection` deletes the credential
/// outright, and Sift never held a copy of it anywhere else.
public func removeConnectionConfirmation(_ name: String) -> String {
    "Remove \(name)? Its credential is deleted from your Keychain as well, and Sift cannot get it "
        + "back — you would have to enter it again."
}

// MARK: - one row

/// What a saved connection is doing on THIS engine, right now.
public enum ConnectionRowState: Equatable, Sendable {
    /// Usable now.
    case ready
    /// Saved and correct; this session's `Database` cannot reach it. See `ConnectionOutcome`.
    case readyAfterRelaunch
    /// The engine's own sentence from `connectionIssues()`, rendered verbatim.
    case issue(String)
    /// The reader is missing, with DuckDB's own first line for why. Carries the Install button.
    case extensionMissing(name: String, why: String)
    /// `.rejectedName`. The one case that is a Sift bug rather than anything the user can fix.
    case siftBug(String)
    /// The master switch is off, so nothing saved is in use.
    case remoteOff

    public var text: String {
        switch self {
        case .ready: return "ready"
        case .readyAfterRelaunch: return "ready after you relaunch Sift"
        case .issue(let sentence): return sentence
        case .extensionMissing(let name, let why):
            return "the \(name) extension is not installed — \(why)"
        case .siftBug(let name):
            return "Sift asked DuckDB for an extension name it cannot use (\(name)) — this is a "
                + "bug in Sift, and nothing you install will fix it."
        case .remoteOff: return "not in use — remote data is off"
        }
    }

    /// Whether this row is a problem, which is the only thing its colour means. `.remoteOff` and
    /// `.readyAfterRelaunch` are deliberately NOT problems: both are exactly what the user asked
    /// for, and painting them red would make the normal strict posture look broken.
    public var isProblem: Bool {
        switch self {
        case .ready, .readyAfterRelaunch, .remoteOff: return false
        case .issue, .extensionMissing, .siftBug: return true
        }
    }
}

/// Which of the six a row is. **The precedence is the whole function**, and each step has a reason:
///
///  1. **Remote off wins over everything.** Nothing saved is in use, so every other sentence would
///     be describing a connection that is not being asked to do anything.
///  2. **The engine's own issue beats the extension.** This is `addConnection`'s own order, stated
///     there: "the secret's own failure is the more actionable of the two when both went wrong".
///     Following it means one fact never gets two different sentences depending on where it is read.
///  3. **A relaunch beats a missing extension, and that is a security ordering as well as a copy
///     one.** A session that started strict has loaded NOTHING remote (`remoteExtensions` returns
///     `[]` in the strict posture), so every row would otherwise claim its extension is missing when
///     a relaunch is what actually loads it — and the Install button that claim carries would fire
///     `INSTALL` over a filesystem `harden()` has disabled, i.e. a network call that cannot succeed
///     on a session whose whole point is not making one.
///
/// `extensionState == nil` is the fourth `ExtensionState` state — **never asked** — and it reads as
/// ready on purpose: every path that would have asked (`remoteExtensions` at launch,
/// `addConnection`'s own install) records its failure in `connectionIssues()`, which step 2 already
/// rendered. Absence is the lack of evidence of a problem, not evidence of one.
public func connectionRowState(
    _ spec: ConnectionSpec, issue: String?, extensionState: ExtensionState?,
    allowRemote: Bool, usableNow: Bool
) -> ConnectionRowState {
    guard allowRemote else { return .remoteOff }
    if let issue { return .issue(issue) }
    guard usableNow else { return .readyAfterRelaunch }
    switch extensionState {
    case .rejectedName: return .siftBug(duckDBExtension(for: spec.kind))
    case .unavailable(let why):
        return .extensionMissing(name: duckDBExtension(for: spec.kind), why: why)
    case .loaded, nil: return .ready
    }
}

/// May a clean save be read as proof that the connection's DuckDB extension is loaded?
///
/// How this screen's extension snapshot learns about a load that happened after launch, WITHOUT a
/// second LOAD→INSTALL: `addConnection` installs the extension itself and reports only its FAILURE,
/// into `connectionIssues()` — so a clean save is proof, and a launch snapshot still saying
/// `.unavailable` (a machine that was offline when Sift started) can be corrected from it. Calling
/// `installExtension` again from the sheet would instead double the network cost of every FAILED
/// save, which is the one case where the call is expensive.
///
/// Three conditions, and each rules out a different way of being wrong:
///
///  * `saved` — a save that THREW leaves no issue either, because there is no connection to have
///    one, and an absent issue must not read as proof of anything.
///  * `usableNow` — the POSTURE, never `config.allowRemote`, which is the switch in the file that
///    this very save just turned on. `addConnection` installs nothing on a session that started
///    strict (that would be the outbound request the strict posture forbids), so a clean save there
///    is proof of a credential and of nothing whatever about an extension.
///  * no `issue` — `addConnection` routes the extension's failure through `connectionIssues()`, so
///    an issue is the counter-evidence.
///
/// Pure and separate from the sheet for this file's usual reason: a `private func` on a `View`
/// cannot be tested, and `theExtensionSnapshotIsOnlyUpdatedByASaveThatProvesSomething` is what
/// stands between this rule and the sheet quietly recording a fact nothing established.
public func aSaveProvesTheExtensionLoaded(saved: Bool, usableNow: Bool, issue: String?) -> Bool {
    saved && usableNow && issue == nil
}

/// The identity half of a row: what kind of connection it is and which account, key or bucket it
/// reaches. Every value here is already in `connections.json` in the clear and is redacted the same
/// way by `duckdb_secrets()` — the secret half is in the Keychain and appears nowhere on this screen.
public func connectionDetail(_ spec: ConnectionSpec) -> String {
    switch spec.kind {
    case .azure:
        let account = nonBlank(spec.accountName) ?? "no account name"
        switch spec.azureAuth {
        case .credentialChain: return "Azure · \(account) · az login"
        case .connectionString: return "Azure · \(account) · connection string in your Keychain"
        // Only a hand-edited config reaches here. `createSecretSQL` returns nil for it, so the row
        // also carries the engine's "no credential is saved" sentence; this half names the gap.
        case nil: return "Azure · \(account) · no sign-in method saved"
        }
    case .s3:
        var parts = ["S3", nonBlank(spec.accountName) ?? "no key id"]
        parts.append(nonBlank(spec.region) ?? "no region")
        if let endpoint = nonBlank(spec.endpoint) { parts.append(endpoint) }
        return parts.joined(separator: " · ")
    }
}

/// Whether Save has enough to build a connection that will actually work.
///
/// 🔴 **The rule is `createSecretSQL`'s, not a prettier one.** Every case it returns `nil` for is a
/// connection that saves cleanly and then sits in the list wearing "no credential is saved for …",
/// so those are the cases Save is disabled for — and NOTHING else is required, however much it looks
/// like it ought to be. `region` in particular is optional to the engine, so demanding it here would
/// block a save the engine is perfectly happy with; the Azure account name is ignored entirely under
/// `connectionString`, where it is display identity and nothing more.
public func canSaveConnection(
    kind: ConnectionKind, azureAuth: AzureAuth, name: String, account: String, secret: String
) -> Bool {
    guard nonBlank(name) != nil else { return false }
    switch kind {
    case .azure:
        switch azureAuth {
        case .credentialChain: return nonBlank(account) != nil
        case .connectionString: return nonBlank(secret) != nil
        }
    case .s3:
        return nonBlank(account) != nil && nonBlank(secret) != nil
    }
}

/// Trim to `nil` — an empty field is a missing value here, exactly as it is in `createSecretSQL`.
func nonBlank(_ s: String?) -> String? {
    guard let s else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// MARK: - the sheet

/// Remote data: the switch, what is saved, and what each of them is doing.
public struct ConnectionsSheet: View {
    private let session: Session
    /// `EngineInfo.extensions` as it was when `AppState` was built.
    ///
    /// 🔴 Passed in rather than read live. `Database.loadedExtensions` is documented unsynchronized —
    /// written at configure time and read afterwards — and `Session.installExtension` is its only
    /// post-init writer. Calling `session.engineInfo()` from this sheet would put a MainActor read
    /// beside actor-isolated writes on that dictionary. So this screen reads a value copied once at
    /// launch and updates it only from `installExtension`'s own return, which is actor-isolated.
    private let extensionsAtLaunch: [String: ExtensionState]

    @Environment(\.dismiss) private var dismiss
    @State private var config = RemoteConfig()
    @State private var issues: [UUID: String] = [:]
    @State private var extensions: [String: ExtensionState] = [:]
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pendingRemoval: ConnectionSpec?
    @State private var adding = false
    @State private var draft = ConnectionDraft()

    public init(session: Session, extensionsAtLaunch: [String: ExtensionState]) {
        self.session = session
        self.extensionsAtLaunch = extensionsAtLaunch
    }

    /// Both halves, the way `Session.remoteUsableNow` computes it: the posture the `Database` was
    /// opened with (frozen — remote facts §2) and the switch as it stands now.
    private var usableNow: Bool { session.allowRemoteAtLaunch && config.allowRemote }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connections").font(.system(size: 15, weight: .semibold))

            Toggle("Allow remote data", isOn: allowRemoteBinding)
                .font(.system(size: 12, weight: .medium))
                .disabled(!loaded)
            Text(allowRemoteExplanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let notice {
                BannerRow(.warning) { Text(notice).textSelection(.enabled) }
            }
            if let error {
                BannerRow(.error) { Text(error).textSelection(.enabled) }
            }

            Divider()

            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if config.connections.isEmpty {
                Text("No saved connections.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(config.connections) { spec in
                            ConnectionRow(
                                spec: spec, state: rowState(spec),
                                onInstall: { Task { await install(spec.kind) } },
                                onRemove: { pendingRemoval = spec })
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Text(sasNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if adding {
                Divider()
                AddConnectionForm(draft: $draft, onCancel: { adding = false }) {
                    Task { await save() }
                }
            }

            HStack {
                Button("Add Connection…") { adding = true }
                    .disabled(!loaded || adding)
                    .help("Save an Azure or S3 connection")
                Spacer()
                // `.cancelAction` — see `BadRowsSheet` for why these two moved off `.defaultAction`.
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 640)
        .confirmationDialog(
            "Remove connection?", isPresented: removalBinding, titleVisibility: .visible,
            presenting: pendingRemoval
        ) { spec in
            Button("Remove", role: .destructive) { Task { await remove(spec) } }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { spec in
            Text(removeConnectionConfirmation(spec.name))
        }
        .task { await reload() }
    }

    private func rowState(_ spec: ConnectionSpec) -> ConnectionRowState {
        connectionRowState(
            spec, issue: issues[spec.id], extensionState: extensions[duckDBExtension(for: spec.kind)],
            allowRemote: config.allowRemote, usableNow: usableNow)
    }

    /// The switch. Optimistic so the control moves under the finger, and put back by `setAllow` if
    /// the engine refuses — a toggle that stays where the user left it while the file on disk says
    /// otherwise is the one failure this screen cannot have.
    private var allowRemoteBinding: Binding<Bool> {
        Binding(
            get: { config.allowRemote },
            set: { on in
                config.allowRemote = on
                Task { await setAllow(on) }
            })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func reload() async {
        config = await session.connections()
        issues = await session.connectionIssues()
        // Seeded once, then owned by this screen: see `extensionsAtLaunch`.
        if !loaded { extensions = extensionsAtLaunch }
        loaded = true
    }

    private func setAllow(_ on: Bool) async {
        do {
            let outcome = try await session.setAllowRemote(on)
            notice = allowRemoteOutcome(on: on, outcome)
            error = nil
        } catch {
            // The engine's own sentence. A `try?` here would leave the toggle claiming a posture the
            // file on disk does not have, which is the whole shape of lie this screen exists to
            // prevent.
            self.error = error.localizedDescription
            self.notice = nil
        }
        await reload()
    }

    private func save() async {
        let spec = draft.spec()
        let wasEmpty = config.connections.isEmpty
        var saved = false
        do {
            let outcome = try await session.addConnection(spec, secret: draft.secretForEngine)
            notice = addedConnectionOutcome(outcome, turnedRemoteOn: wasEmpty)
            error = nil
            adding = false
            draft = ConnectionDraft()
            saved = true
        } catch {
            self.error = error.localizedDescription
            self.notice = nil
        }
        await reload()
        if aSaveProvesTheExtensionLoaded(saved: saved, usableNow: usableNow,
                                         issue: issues[spec.id]) {
            extensions[duckDBExtension(for: spec.kind)] = .loaded
        }
    }

    private func remove(_ spec: ConnectionSpec) async {
        pendingRemoval = nil
        do {
            try await session.removeConnection(spec.id)
            error = nil
            notice = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    /// LOAD, and failing that INSTALL. Only ever reached from a row in `.extensionMissing`, which
    /// `connectionRowState` produces only when the switch is on AND this session is permissive — so
    /// the outbound `INSTALL` this can make is one the user has explicitly authorised.
    private func install(_ kind: ConnectionKind) async {
        let name = duckDBExtension(for: kind)
        extensions[name] = await session.installExtension(name)
    }
}

/// One saved connection: what it is, what it is doing, and the two things that can be done to it.
private struct ConnectionRow: View {
    let spec: ConnectionSpec
    let state: ConnectionRowState
    let onInstall: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).font(.system(size: 12, weight: .semibold))
                Text(connectionDetail(spec))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.text)
                        .font(.system(size: 11))
                        .foregroundStyle(state.isProblem ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if case .extensionMissing(let name, _) = state {
                        Button("Install") { onInstall() }
                            .controlSize(.small)
                            .help("Ask DuckDB to load or install \(name)")
                    }
                }
            }
            Spacer(minLength: 12)
            Button("Remove") { onRemove() }
                .controlSize(.small)
                .help("Forget this connection and delete its credential")
        }
    }
}

// MARK: - adding one

/// The add form's fields, and the one place they become a `ConnectionSpec`.
///
/// 🔴 **`secret` is never part of the spec.** `ConnectionSpec` is written to `connections.json` as
/// plain JSON, so the credential goes to `Session.addConnection(_:secret:)` as its own argument and
/// from there straight into the Keychain. `spec()` below cannot reach `secret` even by accident.
struct ConnectionDraft {
    var kind: ConnectionKind = .azure
    var azureAuth: AzureAuth = .credentialChain
    var name = ""
    /// The Azure storage account name, or the S3 access key id — `ConnectionSpec.accountName` is one
    /// field for both because they are the same fact wearing two names.
    var account = ""
    var region = ""
    var endpoint = ""
    var secret = ""

    /// Whether this shape stores anything at all. `credentialChain` deliberately does not: DuckDB
    /// asks `az login` and the environment, and Sift holds no credential.
    var wantsSecret: Bool { kind == .s3 || azureAuth == .connectionString }

    /// `nil` for the one shape that has no credential, so no empty Keychain item is ever written.
    var secretForEngine: String? { wantsSecret ? secret : nil }

    var canSave: Bool {
        canSaveConnection(
            kind: kind, azureAuth: azureAuth, name: name, account: account, secret: secret)
    }

    func spec() -> ConnectionSpec {
        ConnectionSpec(
            kind: kind, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            accountName: nonBlank(account),
            azureAuth: kind == .azure ? azureAuth : nil,
            region: kind == .s3 ? nonBlank(region) : nil,
            endpoint: kind == .s3 ? nonBlank(endpoint) : nil)
    }
}

private struct AddConnectionForm: View {
    @Binding var draft: ConnectionDraft
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $draft.kind) {
                Text("Azure Blob Storage").tag(ConnectionKind.azure)
                Text("S3").tag(ConnectionKind.s3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                field("Name", text: $draft.name, prompt: "prod")
                if draft.kind == .azure {
                    GridRow {
                        Text("Sign in with").font(.system(size: 12)).gridColumnAlignment(.trailing)
                        // The title is spelled even though it is hidden: `.labelsHidden()` drops the
                        // visual label and keeps the accessibility one, and `Picker("")` would leave
                        // VoiceOver reading an unnamed control.
                        Picker("Sign in with", selection: $draft.azureAuth) {
                            Text("az login").tag(AzureAuth.credentialChain)
                            Text("Connection string").tag(AzureAuth.connectionString)
                        }
                        .labelsHidden()
                    }
                    field("Account name", text: $draft.account, prompt: "mystorageaccount")
                    if draft.azureAuth == .connectionString {
                        secureField("Connection string", text: $draft.secret)
                    }
                } else {
                    field("Access key id", text: $draft.account, prompt: "AKIA…")
                    secureField("Secret access key", text: $draft.secret)
                    field("Region", text: $draft.region, prompt: "us-east-1")
                    field("Endpoint", text: $draft.endpoint, prompt: "optional — blank means AWS")
                }
            }

            Text(
                draft.wantsSecret
                    ? "The credential goes to your Keychain. It is never written to Sift's "
                        + "connections file."
                    : "Nothing is stored: DuckDB asks the Azure CLI and your environment for the "
                        + "credential at read time."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).gridColumnAlignment(.trailing)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).gridColumnAlignment(.trailing)
            SecureField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}
