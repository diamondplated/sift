import CDuckDB
import Foundation

/// What `loadExtensions` found out about one name.
///
/// 🔴 **Three states because `false` was two answers wearing one hat.** A legal name whose binary
/// is not installed and a name the injection guard threw out both recorded `false`, and spec §11
/// turns this dictionary into "a missing `delta` extension refuses the open" — so nothing above
/// could tell "install azure" from "Sift asked DuckDB for a name it cannot use". One is a sentence
/// with a fix in it; the other is a bug report. **Absent stays a fourth thing: never asked.**
public enum ExtensionState: Sendable, Equatable {
    case loaded
    /// LOAD and INSTALL both failed — carries DuckDB's first line so the UI can say why.
    case unavailable(String)
    /// The name failed the injection guard. A Sift bug, never a user-fixable state.
    case rejectedName
}

/// Owns the one `duckdb_database`. Creating connections from it is thread-safe,
/// which is why this is `@unchecked Sendable` while `Connection` is not.
public final class Database: @unchecked Sendable {
    private var handle: duckdb_database?
    // loadedExtensions, hardened and networkInstalls are written only during configure-time
    // (harden/loadExtensions) and read afterwards, making the unsynchronized collections safe on
    // @unchecked Sendable.
    public private(set) var loadedExtensions: [String: ExtensionState] = [:]
    /// Per-setting outcome of the last `harden()`, keyed by setting name.
    public private(set) var hardened: [String: Bool] = [:]
    /// Every name this `Database` issued an `INSTALL` for, in order — **the decision, not the
    /// delivery**.
    ///
    /// 🔴 It exists because `.loaded` has two provenances and nothing could tell them apart: a
    /// binary already sitting in `~/.duckdb/extensions` from an earlier run, or a download this
    /// process just made. Both this Mac and the macos-15 runner keep that cache warm, so every
    /// assertion about "the extension is present" passes identically whether or not Sift went to
    /// `extensions.duckdb.org` — which is how a strict session's `INSTALL` survived a whole phase
    /// and three written claims that it could not happen. This array is empty on a machine that
    /// installed nothing and non-empty on one that did, on a warm cache and a cold one alike, so a
    /// test can assert what the process DID.
    ///
    /// `INSTALL` is the only outbound network call anything in this package makes. Appended before
    /// the statement runs, so a failed download is recorded too: the request left the machine
    /// either way, and that is what is being measured.
    public private(set) var networkInstalls: [String] = []

    /// The filesystems `harden()` denies, as `disabled_filesystems` wants them: a bare
    /// comma-separated list, no quoting.
    ///
    /// Public because `harden()` is not the only connection in the product that has to apply it —
    /// `SiftEngine.assertSingleSelectStatement` opens its own scratch database for DuckDB's parser
    /// and has to deny the same set. One constant, so the two can never drift apart, and so a task
    /// that broadens the list broadens it everywhere at once.
    ///
    /// MEASURED (`docs/…/2026-08-16-duckdb-remote-facts.md` §1): `SET disabled_filesystems` never
    /// validates a name, and the registry is not introspectable — a typo here is a security layer
    /// that does nothing and says nothing. The two Azure names are the ones that fact went looking
    /// for: `AzureBlobStorageFileSystem` serves `az://`/`azure://`, `AzureDfsStorageFileSystem`
    /// serves `abfss://`/`abfs://`, and `AzureStorageFileSystem` — the name that appears in the
    /// extension's own error text — is a C++ base class that is not registered and blocks nothing.
    /// Because a wrong name is silent, the only defence is behavioral: every name here is dropped
    /// one at a time in `theGateScratchConnectionIsHardenedLikeEveryOtherOne` and in
    /// `hardenDisablesEveryNameOnTheDenyList…`, and the Azure half is read end to end in
    /// `remoteFact1_…`.
    public static let remoteFilesystems =
        "HTTPFileSystem,S3FileSystem,AzureBlobStorageFileSystem,AzureDfsStorageFileSystem"

    public init(path: String) throws {
        var db: duckdb_database?
        var errPtr: UnsafeMutablePointer<CChar>?
        // Tested against DuckDBSuccess, never against the failure enum: that member
        // imports into Swift as `DuckDBError`, which collides with our own error type.
        let state = duckdb_open_ext(path, &db, nil, &errPtr)
        // duckdb_open_ext leaves *out_database untouched on failure, so not calling
        // duckdb_close before throwing is correct—measured against the vendored dylib.
        if state != DuckDBSuccess {
            let msg = errPtr.map { String(cString: $0) } ?? "could not open \(path)"
            if let errPtr { duckdb_free(errPtr) }
            throw DuckDBError(msg)
        }
        self.handle = db
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        if handle != nil { duckdb_close(&handle) }
    }

    public func connect() throws -> Connection {
        var con: duckdb_connection?
        guard duckdb_connect(handle, &con) == DuckDBSuccess, let con else {
            throw DuckDBError("could not open a DuckDB connection")
        }
        return Connection(handle: con)
    }

    /// The `SET`s that make a connection safe to be handed SQL, as `(name, value)` ready to
    /// interpolate. `harden()` issues them; so does the SELECT-only gate's raw scratch connection
    /// (`SiftEngine.withGuardScratchConnection`), which cannot use `harden()` because
    /// `duckdb_extract_statements` needs a raw `duckdb_connection`.
    ///
    /// 🔴 **Public and shared for `remoteFilesystems`' reason, and this list drifted exactly the way
    /// that one was built to prevent.** The gate applied `disabled_filesystems` and none of the
    /// other three, so its scratch connection kept DuckDB's default `autoinstall_known_extensions`
    /// — and `disabled_filesystems` gates the VFS, **not** the extension installer. MEASURED:
    /// `assertSelectOnly("SELECT * FROM read_csv('https://example.com/a.csv')")` on a machine
    /// without `httpfs` downloaded it from `extensions.duckdb.org` in 0.81 s, from a strict session,
    /// out of SQL a user typed. Two lists could not both be right; there is one now.
    public static func hardeningSettings(allowRemote: Bool = false) -> [(name: String, value: String)] {
        var settings = [
            (name: "autoinstall_known_extensions", value: "false"),
            (name: "autoload_known_extensions", value: "false"),
            (name: "allow_community_extensions", value: "false"),
        ]
        if !allowRemote {
            settings.insert((name: "disabled_filesystems", value: "'\(remoteFilesystems)'"), at: 0)
        }
        return settings
    }

    /// Settings applied before any query runs. Blocking the network filesystems is
    /// the part that matters: a SELECT can still read any local file the user could
    /// `cat`, but it cannot ship results anywhere.
    ///
    /// Non-fatal by design — Sift must not refuse to start over a hardening setting — but
    /// never silent: every setting's outcome lands in `hardened`, so a caller or a test can
    /// see which layer is actually in place. MEASURED: a renamed setting throws
    /// `Catalog Error: unrecognized configuration parameter`, so the signal exists, and
    /// discarding it would let a DuckDB rename disable a security layer with nothing to show
    /// for it. The four settings are a frozen contract (design spec §11).
    ///
    /// `allowRemote: true` is the one posture the Connections work adds, and it changes exactly one
    /// setting: `disabled_filesystems` is never SET, so a `LOAD`ed `httpfs`/`azure` can actually
    /// reach the network. The other three still apply — a remote session is still not allowed to
    /// autoload or community-load an extension. MEASURED (§2): the disabled set only ever grows
    /// within a `Database` and reads back `''`, so this cannot be a live toggle and there is nothing
    /// to undo — a posture change is a new `Database`, which is why it is a parameter of the one
    /// call that runs before any query rather than a `var` on the class.
    ///
    /// The default keeps every existing call site both compiling and airtight; `true` only ever
    /// arrives from a user choosing a remote connection.
    ///
    /// In the permissive posture `hardened` has no `disabled_filesystems` key at all. **Absent is
    /// not `false`** — same tri-state discipline as `ExtensionState`: `false` means the SET was
    /// issued and DuckDB refused it, which is a bug report; absent means Sift deliberately never
    /// asked.
    public func harden(allowRemote: Bool = false) {
        let settings = Self.hardeningSettings(allowRemote: allowRemote)
        guard let con = try? connect() else {
            for (name, _) in settings { hardened[name] = false }
            return
        }
        for (name, value) in settings {
            hardened[name] = (try? con.execute("SET \(name)=\(value)")) != nil
        }
    }

    /// LOAD what we need, since autoloading is disabled by `harden()`. Extension
    /// binaries are per-DuckDB-version, so a version bump needs a fresh INSTALL.
    public func loadExtensions(_ names: [String]) {
        guard let con = try? connect() else { return }
        for name in names {
            // DuckDB accepts no bound parameters for LOAD, so the name is interpolated —
            // which makes validating it the only thing between this public API and arbitrary
            // SQL. MEASURED before the guard: loadExtensions(["httpfs; ATTACH 'evil.db'"])
            // created and attached evil.db, and recorded the whole string as loaded.
            // Package invariant, from DBValue.swift: nothing in Sift interpolates a user
            // value into SQL text.
            guard Self.isExtensionName(name) else {
                loadedExtensions[name] = .rejectedName
                continue
            }
            if (try? con.execute("LOAD \(name)")) != nil {
                loadedExtensions[name] = .loaded
                continue
            }
            do {
                networkInstalls.append(name)
                try con.execute("INSTALL \(name)")
                try con.execute("LOAD \(name)")
                loadedExtensions[name] = .loaded
            } catch {
                // The INSTALL-or-second-LOAD failure, not the first LOAD's: the first one always
                // says the same uninteresting thing ("Extension …/<name>.duckdb_extension not
                // found"), while this one distinguishes the two cases a user can act on — a 404
                // from extensions.duckdb.org (no such extension) from a machine that could not
                // reach it at all (no network). MEASURED against the vendored 1.5.5.
                loadedExtensions[name] = .unavailable((error as? DuckDBError)?.firstLine ?? "\(error)")
            }
        }
    }

    /// `^[a-z_][a-z0-9_]*$` — every DuckDB extension name, and nothing that can carry a
    /// statement separator, a quote or whitespace.
    ///
    /// Public for `Database.remoteFilesystems`' reason: `loadExtensions` is no longer the only place
    /// in the product that interpolates an extension name into SQL — `SiftEngine`'s
    /// `extensionIsInstalled` probe does too — and one validator is the only way the two cannot
    /// drift.
    public static func isExtensionName(_ s: String) -> Bool {
        func lower(_ u: Unicode.Scalar) -> Bool { ("a"..."z").contains(u) || u == "_" }
        guard let first = s.unicodeScalars.first, lower(first) else { return false }
        return s.unicodeScalars.allSatisfy { lower($0) || ("0"..."9").contains($0) }
    }
}
