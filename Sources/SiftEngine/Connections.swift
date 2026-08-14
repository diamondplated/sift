import Darwin
import DuckDBKit
import Foundation
import SiftCore

// The connections config, the launch posture, secret issuance, and the four operations the
// Connections UI calls. `SiftCore/Remote.swift` decides what a connection IS and what SQL issues
// its credential; `Keychain.swift` holds the credential; this file is the wiring between them and
// the one `Database` a `Session` owns.
//
// 🔴 **THE POSTURE CANNOT CHANGE INSIDE A LIVE `Database`, AND THAT IS THE WHOLE SHAPE OF THIS
// FILE.** MEASURED (`docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md` §2): within one
// `duckdb_database`, `disabled_filesystems` only ever GROWS. Narrowing it, clearing it and
// `RESET`ing it all fail with `Invalid Input Error: File system "…" has been disabled previously,
// it cannot be re-enabled`, and `current_setting('disabled_filesystems')` reads back `''` at every
// point, so the engine cannot even be asked what it currently denies. A second `Database` in the
// same process is clean.
//
// Three consequences, and every one of them is load-bearing:
//
//  1. `harden(allowRemote:)` is a parameter of the one call that runs before any query, and the
//     value comes from a file read BEFORE the `Database` opens. There is no live switch and there
//     never can be one. **Do not "fix" `setAllowRemote` with a `SET` — it cannot work**, and the
//     failure mode of trying is a user who is told remote is off while every read still succeeds.
//  2. Every operation here returns (or records) `ConnectionOutcome`, which says whether what the
//     user just asked for is true in THIS session or only after the next one. That is a return
//     value rather than a comment because a comment cannot be checked and cannot reach a banner.
//  3. The relaunch-free version is a `Session` rebuild — close every open table, drop this
//     `Session`, construct a new one on the same home — and it belongs to the UI, which is the only
//     layer that knows what is open and can put it back. `Session` owns one `Database`, one
//     long-lived `pagingConnection`, the open-table catalog and staged-copy handles; rebuilding
//     those from inside the actor that owns them is "reopen everything" wearing a smaller name.
//
// Secrets are **Database-scoped** (MEASURED §6b: a secret outlives the connection that created it
// and is visible to every sibling), so one connection issues them for the whole engine, and
// **TEMPORARY** (§6c: nothing reaches disk, redaction is on by default and cannot be turned off in
// a running engine). The Keychain is the only place a credential survives a restart.

/// Where a saved connection's credential lives, relative to `~/.sift`.
let connectionsFileName = "connections.json"

/// What the user just asked for, and whether it is true yet.
///
/// 🔴 The two cases are not a UI nicety — they are the only honest report of §2 above. A saved
/// connection is written, keyed and (where the engine allows) issued the moment the user presses
/// Save; whether the ENGINE can act on it depends on a posture that was frozen when this session's
/// `Database` opened.
///
/// `.active` means the credential is live on this engine right now. `.activeAfterRelaunch` means it
/// is saved and correct and this session's engine will not use it — the UI's move is to say
/// "reopen Sift" (or to rebuild the `Session`, see this file's header), never to retry.
///
/// Neither case reports whether the DuckDB extension the connection reads through is actually
/// installed. That is a separate, per-connection fact with its own channel: `connectionIssues()`,
/// which `addConnection` fills in, and `installExtension`'s own return value.
public enum ConnectionOutcome: Sendable, Equatable {
    /// Usable on this session's engine, now.
    case active
    /// Saved, and this session's engine cannot use it. Reopen Sift.
    case activeAfterRelaunch
}

// MARK: - the config file

extension Session {
    /// `<home>/connections.json`. Static so `Session.init` can read the file before there is a
    /// `self` to hang it off, and so `--verify` can plant one in a workspace home.
    static func connectionsPath(in home: String) -> String {
        (home as NSString).appendingPathComponent(connectionsFileName)
    }

    /// The saved config, or the strict default when there is no file.
    ///
    /// 🔴 **A file that exists and cannot be read REFUSES THE SESSION.** This is the one place in
    /// the engine where an unreadable artifact is not collected and defaulted, and the asymmetry is
    /// deliberate. A corrupt *staging token* is disk that regenerates, so `purgeStaged` drops it. A
    /// corrupt *config* is the user's own security decision: defaulting a damaged file to
    /// `allowRemote: false` would be safe, but the same code path defaults a FUTURE-VERSION file —
    /// one that may well say `true`, written by a newer Sift with settings this build cannot see —
    /// and the first save afterwards rewrites the file without them. That is how a revoke gets
    /// undone, or a scope silently widened, with nothing on screen. `RemoteConfig.init(from:)`
    /// already refuses a version it does not know (SiftCore/Remote.swift); this surfaces it instead
    /// of letting it become a shrug.
    static func loadRemoteConfig(_ path: String) throws -> RemoteConfig {
        guard FileManager.default.fileExists(atPath: path) else { return RemoteConfig() }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SessionError(configRefusal(path, "it could not be read"))
        }
        do {
            return try JSONDecoder().decode(RemoteConfig.self, from: data)
        } catch let error as UnsupportedRemoteConfig {
            throw SessionError("Sift cannot use the connections file at \(path): \(error.description).")
        } catch {
            // Deliberately Sift's own words, not `DecodingError`'s: Foundation's version of this is
            // "The data couldn't be read because it isn't in the correct format", which is the
            // Foundation dump the house contract exists to keep off screen.
            throw SessionError(configRefusal(path, "it is not valid JSON"))
        }
    }

    /// Write the config at **0600**, atomically.
    ///
    /// 0600 for the reason `~/.sift` is 0700 and a downloaded cache file is 0600 (spec §11): it
    /// names the storage accounts and key ids a user reaches, which is identity even though it is
    /// never the key itself (the key is in the Keychain, and MEASURED §6c `duckdb_secrets()` prints
    /// `account_name`/`key_id` in the clear while redacting the secret half). One `createFile` with
    /// the mode in it rather than a create-then-chmod — MEASURED (RemoteProbe.swift): unlike
    /// `createDirectory`'s attributes, `createFile`'s ARE applied to a path that already exists, so
    /// a second line would be a mutant nothing could kill.
    ///
    /// The `rename` is not decoration. A torn write here does not lose a cache — it produces a file
    /// that `loadRemoteConfig` REFUSES, which is a Sift that will not start until the user finds and
    /// deletes a file they have never heard of. Written to a per-process temp name and renamed, so
    /// the file at `path` is always one whole config or the previous one.
    static func writeRemoteConfig(_ config: RemoteConfig, to path: String) throws {
        let encoder = JSONEncoder()
        // Human-editable on purpose: this is a small settings file, and a user who wants to delete
        // one connection with a text editor should be able to see what they are deleting.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            throw SessionError("Sift could not encode the connections file for \(path).")
        }

        let temporary = "\(path).\(ProcessInfo.processInfo.processIdentifier).tmp"
        guard FileManager.default.createFile(
            atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionError("Sift could not write the connections file next to \(path).")
        }
        guard rename(temporary, path) == 0 else {
            let failure = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw SessionError("Sift could not save the connections file at \(path) (errno \(failure)).")
        }
    }
}

/// One sentence for a config Sift will not act on. Names the file, because "somewhere in your home
/// directory" is not a fix.
private func configRefusal(_ path: String, _ why: String) -> String {
    "Sift cannot read the connections file at \(path) because \(why). That file decides whether "
        + "this session may reach the network, so Sift refuses to start rather than fall back to a "
        + "posture nobody chose \u{2014} fix it or delete it and set your connections up again."
}

// MARK: - launch posture

/// The extensions the saved posture needs on top of `sessionExtensions`.
///
/// `httpfs` whenever remote is on **and regardless of what is saved**: a pasted `https://` URL needs
/// no saved connection at all, and it is the most common remote source there is. `azure` only when a
/// connection asks for it — it is a second binary to fetch, and MEASURED (§1) it is also what
/// registers the two Azure filesystems `harden()` denies in the strict posture.
///
/// Nothing is loaded in the strict posture. `LOAD` falls through to `INSTALL` (Database.swift), so
/// asking for `httpfs` on a session the user has told not to reach the network would be an outbound
/// request to `extensions.duckdb.org` on behalf of a posture that forbids exactly that.
func remoteExtensions(for config: RemoteConfig) -> [String] {
    guard config.allowRemote else { return [] }
    return config.connections.contains { $0.kind == .azure } ? ["httpfs", "azure"] : ["httpfs"]
}

/// The DuckDB extension a saved connection reads through. `s3` secrets are httpfs's.
func extensionName(for kind: ConnectionKind) -> String {
    switch kind {
    case .azure: return "azure"
    case .s3: return "httpfs"
    }
}

extension Session {
    /// Issue every saved connection's secret on one connection, best effort, and report what failed.
    ///
    /// 🔴 **One bad credential must not brick the app.** A user whose Keychain item was deleted by
    /// hand, whose account name is empty, or whose connection string DuckDB rejects still has local
    /// files to open — throwing from `Session.init` would take the whole window with it for a
    /// feature they may never use. So the failures land in a `[UUID: String]` the Connections screen
    /// renders next to the offending row, and nothing is swallowed: every branch below produces a
    /// sentence, and `nil` means it really was issued.
    ///
    /// One connection for all of them, because MEASURED (§6b) a secret is Database-scoped: it
    /// outlives the connection that created it and every sibling and every later connection can
    /// resolve it.
    static func issueSecrets(
        _ con: Connection, config: RemoteConfig, service: String, register: Bool = true
    ) -> [UUID: String] {
        var issues: [UUID: String] = [:]
        for spec in config.connections {
            issues[spec.id] = issueSecret(con, spec, service: service, register: register)
        }
        return issues
    }

    /// `nil` when the secret is live on this engine; otherwise the first line of why not.
    ///
    /// 🔴 **`register: false` runs every check and skips only the `CREATE SECRET`,** and the split
    /// is exactly where the two kinds of failure separate. Everything above the statement is
    /// credential resolution — no Keychain item, an unreadable one, a `credentialChain` connection
    /// with no account name — and those sentences are TRUE whatever the posture is: they name a
    /// field to fill in or a credential to re-enter. The statement itself is the only line that can
    /// fail *because of* the posture: `harden()` turns `autoload_known_extensions` off in every
    /// posture, so on a strict session DuckDB answers `Secret type 'azure' does not exist, but it
    /// exists in the azure extension` — a message about an extension, filed against a connection
    /// that is fine, and `connectionRowState` ranks an issue ABOVE the relaunch sentence, so it
    /// paints the row red for a save that went perfectly.
    ///
    /// Suppressing the whole call was the first fix and it was too much: it also threw away the
    /// honest half, on the one posture EVERY user's first connection is saved under — so a typo'd
    /// account name was accepted in silence and only surfaced after a relaunch.
    static func issueSecret(
        _ con: Connection, _ spec: ConnectionSpec, service: String, register: Bool = true
    ) -> String? {
        let secret: String?
        do {
            secret = try Keychain.get(account: spec.id.uuidString, in: service)
                .map { String(decoding: $0, as: UTF8.self) }
        } catch let error as KeychainError {
            return error.description
        } catch {
            return "\(error)"
        }

        // `nil` from `createSecretSQL` is "there is nothing to say to DuckDB", which is a broken
        // connection in every shape but one — and `credentialChain` is not that shape either when
        // the account name is missing. Two sentences, because the fixes are different: one is a
        // credential to re-enter, the other is a field to fill in.
        guard let (sql, params) = createSecretSQL(spec, secretValue: secret) else {
            if spec.kind == .azure, spec.azureAuth == .credentialChain {
                return "\(spec.name) has no storage account name, so there is nothing to hand "
                    + "DuckDB \u{2014} edit it in Connections."
            }
            return "no credential is saved for \(spec.name) \u{2014} open Connections and enter it "
                + "again."
        }
        guard register else { return nil }
        do {
            _ = try con.query(sql, params.map(toDBValue))
        } catch let error as DuckDBError {
            return error.firstLine
        } catch {
            return "\(error)"
        }
        return nil
    }
}

// MARK: - the operations the Connections UI calls

extension Session {
    /// The saved config, exactly as it is on disk. The UI's list.
    public func connections() -> RemoteConfig { remoteConfig }

    /// Why a saved connection's credential is not live on this engine, by connection id. Empty is
    /// the healthy state; a key here is a row the Connections screen must mark.
    public func connectionIssues() -> [UUID: String] { secretIssues }

    /// Is a saved connection usable on THIS engine? Both halves have to be true: the posture the
    /// `Database` was opened with (frozen — §2), and the switch as it stands now.
    private var remoteUsableNow: Bool { allowRemoteAtLaunch && remoteConfig.allowRemote }

    /// Save a connection: Keychain first, then the file — and then, **only on a session that
    /// started permissive**, the extension and the live secret.
    ///
    /// **The order is a failure-mode argument.** A Keychain item with no config entry is an orphan
    /// nobody ever reads; a config entry with no credential is a connection that looks saved and
    /// does not work. So the credential goes down first, and a failure to persist the config takes
    /// it back out again.
    ///
    /// The two halves after the file are gated on `remoteUsableNow` and the long comment at that
    /// line says why for both. In one sentence: a strict session can neither install an extension
    /// (that is an outbound request the posture forbids) nor register a secret without one
    /// (RE-MEASURED — the "`CREATE SECRET` needs no extension" fact this method used to cite was
    /// taken from an un-`harden()`ed `Database` that autoloaded behind the measurement).
    ///
    /// The FIRST connection turns the master switch on in the file — saving one is the user asking
    /// for remote — but see `ConnectionOutcome`: it cannot turn it on in this engine.
    ///
    /// `secret` is the credential's whole payload as text, and it is what
    /// `createSecretSQL(_:secretValue:)` binds: the Azure connection string, or the S3 secret key.
    /// `nil` for `credentialChain`, which by design stores nothing at all.
    public func addConnection(_ spec: ConnectionSpec, secret: String?) async throws -> ConnectionOutcome {
        guard !remoteConfig.connections.contains(where: { $0.id == spec.id }) else {
            throw SessionError(
                "A connection with that id is already saved. Remove it first, or save the edit "
                    + "under a new connection."
            )
        }
        // The name is the only human-readable thing about a connection — it is the Keychain item's
        // label (Keychain.swift: a user auditing their keychain must see which connection an item
        // belongs to instead of 32 hex digits) and it is what every sentence in this file names.
        guard !spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError("A connection needs a name — it is how you tell it from the others.")
        }

        let credential = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCredential = !(credential ?? "").isEmpty
        if hasCredential, let credential {
            do {
                try Keychain.set(
                    Data(credential.utf8), account: spec.id.uuidString,
                    label: "Sift \u{2014} \(spec.name)", in: keychainService
                )
            } catch let error as KeychainError {
                throw SessionError(error.description)
            }
        }

        var next = remoteConfig
        next.connections.append(spec)
        if next.connections.count == 1 { next.allowRemote = true }
        do {
            try Self.writeRemoteConfig(next, to: connectionsPath)
        } catch {
            // The credential we just filed belongs to a connection that does not exist. `try?`
            // because the error the caller must see is the one that made this necessary — a second
            // error thrown from cleanup would replace it with the less useful of the two.
            if hasCredential { try? Keychain.delete(account: spec.id.uuidString, in: keychainService) }
            throw error
        }
        remoteConfig = next

        // 🔴 **`remoteUsableNow`, NOT `next.allowRemote`, and the difference is the whole bug this
        // line was.** `installExtension` falls through to `INSTALL`, which is an outbound request to
        // `extensions.duckdb.org`. The old gate was the CONFIG — which this method had set to `true`
        // fifteen lines earlier — so the very first connection a user ever saved, on the
        // fresh-install session that is strict by construction, made that request on behalf of a
        // posture that forbids exactly it. MEASURED: `disabled_filesystems` gates DuckDB's VFS and
        // not its extension installer, so the call also SUCCEEDED, and on a machine that cannot
        // reach the repository it is a synchronous DuckDB call on the actor — `addConnection`
        // freezes the whole `Session` for DuckDB's HTTP timeout × retries.
        //
        // Nothing is lost by waiting: this save is `.activeAfterRelaunch`, and the relaunch's
        // `remoteExtensions(for:)` does the install in the permissive posture where it belongs.
        //
        // 🔴 **The SECRET is inside this gate too, and that is a correction to a measured fact this
        // file used to state.** The old comment here read "MEASURED (Task 4, on a bare 1.5.5 with
        // nothing loaded and no network): `CREATE SECRET` needs no extension to PARSE, bind and
        // register — only to be USED." **That is false, and it was measured on a `Database` that
        // had not been `harden()`ed** — DuckDB's own `autoload_known_extensions` defaults to `true`,
        // so the engine silently autoloaded (and on a cold machine autoINSTALLED) the extension the
        // statement needed. Sift's `harden()` sets it to `false` in EVERY posture, so the product
        // never gets that rescue. RE-MEASURED against the vendored 1.5.5, hardened, nothing loaded:
        //
        //     TYPE s3    -> Invalid Input Error: Secret type 's3' does not exist, but it exists in
        //                   the httpfs extension.
        //     TYPE azure -> Invalid Input Error: Secret type 'azure' does not exist, but it exists
        //                   in the azure extension.
        //     TYPE azure, PROVIDER credential_chain -> …provider 'credential_chain' … does not
        //                   exist, but it exists in the azure extension.
        //
        // So on a strict session there is no shape of connection whose secret can register, and the
        // only thing issuing one could produce is a DuckDB sentence about a missing extension —
        // which is a worse way of saying `.activeAfterRelaunch`, and which `connectionRowState`
        // ranks ABOVE the relaunch sentence, so it would paint the row red for a save that went
        // perfectly. The credential is in the Keychain and the config is on disk; the next launch's
        // `issueSecrets` puts it on an engine that can hold it.
        var extensionIssue: String?
        if remoteUsableNow {
            switch installExtension(extensionName(for: spec.kind)) {
            case .loaded:
                extensionIssue = nil
            case .unavailable(let why):
                extensionIssue = "the DuckDB \(extensionName(for: spec.kind)) extension is not "
                    + "available here: \(why)"
            case .rejectedName:
                extensionIssue = "Sift asked DuckDB for an extension name it cannot use "
                    + "(\(extensionName(for: spec.kind))) \u{2014} this is a bug in Sift."
            }
        }
        // 🔴 **Outside the posture gate, with `register:` inside it.** What the INSTALL above is
        // gated on is the outbound request; what the checks below find — no credential saved, a
        // `credentialChain` connection with no account name — is a mistake the user just made, in
        // the form they just filled in. Every user's FIRST connection is saved on a strict session,
        // so keeping these behind the gate meant the one save most likely to contain a typo was the
        // one that accepted it in silence and reported it a relaunch later. `register` skips only
        // the `CREATE SECRET`, which is the single line that can fail for the posture rather than
        // for the connection — see `issueSecret`.
        //
        // On a permissive session the extension is loaded by the branch above, so the secret can
        // really register, and its failure is the more actionable of the two when both went wrong.
        let con = try engineConnection()
        secretIssues[spec.id] =
            Self.issueSecret(con, spec, service: keychainService, register: remoteUsableNow)
            ?? extensionIssue
        return remoteUsableNow ? .active : .activeAfterRelaunch
    }

    /// Forget a connection: drop its secret, delete its credential, rewrite the file.
    ///
    /// 🔴 **Removing the last connection does NOT turn remote off.** A pasted `https://` URL needs
    /// no saved connection, so an empty list is not a request to revoke — the master switch is
    /// `setAllowRemote`, and making it a side effect of a delete would silently disarm a posture the
    /// user set on purpose (and, because the posture cannot be narrowed live, would not even take
    /// effect until the next launch, so the UI would be lying twice).
    public func removeConnection(_ id: UUID) async throws {
        guard let spec = remoteConfig.connections.first(where: { $0.id == id }) else {
            throw SessionError("There is no saved connection with that id.")
        }
        let con = try engineConnection()
        // Best effort, and the only `try?` here that is not a cleanup path: MEASURED (§6c) the
        // secret is TEMPORARY, so it holds no disk and dies with the `Database` regardless. Letting
        // a failed DROP refuse the removal would leave a user unable to delete a connection because
        // of a credential they are trying to get rid of.
        try? con.execute(dropSecretSQL(spec))

        do {
            try Keychain.delete(account: id.uuidString, in: keychainService)
        } catch let error as KeychainError {
            // NOT best effort: a credential that could not be deleted must not lose the config row
            // that is the only thing pointing at it.
            throw SessionError(error.description)
        }

        var next = remoteConfig
        next.connections.removeAll { $0.id == id }
        try Self.writeRemoteConfig(next, to: connectionsPath)
        remoteConfig = next
        secretIssues[id] = nil
    }

    /// The master switch, and the one operation whose whole point is a posture change.
    ///
    /// 🔴 **The file changes; this engine does not.** MEASURED (§2): `disabled_filesystems` only
    /// grows inside a live `Database`, so turning remote ON cannot open a session that started
    /// strict, and turning it OFF cannot close one that started permissive. What this method CAN do
    /// immediately is take the credentials away — the secrets are dropped, so a revoke stops every
    /// saved connection from resolving even while the filesystem stays reachable — and that is worth
    /// having, but it is not the revoke and it must not be described as one. The return value says
    /// which it was.
    ///
    /// Turning it back on re-issues the secrets, so a revoke followed by a change of mind is
    /// genuinely `.active` again on a session that started permissive.
    public func setAllowRemote(_ on: Bool) async throws -> ConnectionOutcome {
        var next = remoteConfig
        next.allowRemote = on
        try Self.writeRemoteConfig(next, to: connectionsPath)
        remoteConfig = next

        let con = try engineConnection()
        if on {
            // `register: remoteUsableNow` — the credential checks always run, the `CREATE SECRET`
            // only on a session that can hold one. Turning this switch on from a strict session
            // used to file DuckDB's "Secret type 'azure' does not exist" against every saved
            // connection, and `connectionRowState` ranks an issue ABOVE the relaunch sentence, so
            // the screen answered a perfect save with a message about extensions instead of
            // "reopen Sift" — which is what `.activeAfterRelaunch` below already says. What the
            // user actually broke still reaches them; see `issueSecret`.
            secretIssues = Self.issueSecrets(
                con, config: next, service: keychainService, register: remoteUsableNow)
        } else {
            // Same best-effort reasoning as `removeConnection`, one per saved connection.
            for spec in next.connections { try? con.execute(dropSecretSQL(spec)) }
            secretIssues = [:]
        }
        return on == allowRemoteAtLaunch ? .active : .activeAfterRelaunch
    }

    /// LOAD (and, failing that, INSTALL) one extension, reporting what happened.
    ///
    /// The tri-state is `Database`'s and it is the point: `.unavailable` carries DuckDB's own first
    /// line, which distinguishes "no such extension" from "this machine has no network" — two
    /// different sentences for the user. `.rejectedName` is a Sift bug, never a user-fixable state.
    ///
    /// Idempotent and cheap when the extension is already loaded, which is the common call.
    ///
    /// 🔴 **Every caller is responsible for the posture, because this method cannot see it.** An
    /// `INSTALL` is the one outbound request Sift makes, and `harden()` does not stop it — the
    /// disabled-filesystem set gates DuckDB's VFS, not its extension installer. There are exactly
    /// three call sites and all three are gated on a session that started PERMISSIVE:
    /// `addConnection` above (`remoteUsableNow`), `Session.checkRemoteExtension` (unreachable on a
    /// strict session — `buildRemoteOpen` throws "not allowed to reach the network" first), and the
    /// Connections sheet's Install button (only rendered for `.extensionMissing`, which
    /// `connectionRowState` produces only when `usableNow`). A fourth call site has to earn its own
    /// gate; there is no guard here to fall back on.
    ///
    /// ⚠️ This is the only post-`init` writer of `Database.loadedExtensions`, whose header notes the
    /// dictionary is unsynchronized because it is written at configure time and read afterwards.
    /// Every call here is actor-isolated, so the writes are serialized against each other; the one
    /// reader that is not is `Session.engineInfo()`, which the app calls once while building
    /// `AppState`, long before any Connections sheet exists.
    public func installExtension(_ name: String) -> ExtensionState {
        if database.loadedExtensions[name] == .loaded { return .loaded }
        database.loadExtensions([name])
        return database.loadedExtensions[name]
            ?? .unavailable("DuckDB reported nothing at all about \(name).")
    }

    /// A throwaway connection for a one-shot statement, with DuckDB's first line turned into the
    /// house sentence. Deliberately NOT `pagingConnection`: secrets are Database-scoped (§6b), so
    /// any connection will do, and staying off the shared one keeps this file out of the
    /// no-suspension invariant Session.swift's header documents.
    private func engineConnection() throws -> Connection {
        do {
            return try database.connect()
        } catch let error as DuckDBError {
            throw SessionError(error.firstLine)
        }
    }
}
