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
    // loadedExtensions and hardened are written only during configure-time (harden/
    // loadExtensions) and read afterwards, making the unsynchronized dictionaries safe on
    // @unchecked Sendable.
    public private(set) var loadedExtensions: [String: ExtensionState] = [:]
    /// Per-setting outcome of the last `harden()`, keyed by setting name.
    public private(set) var hardened: [String: Bool] = [:]

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
    /// that does nothing and says nothing.
    public static let remoteFilesystems = "HTTPFileSystem,S3FileSystem"

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
    public func harden() {
        let settings = [
            ("disabled_filesystems", "'\(Self.remoteFilesystems)'"),
            ("autoinstall_known_extensions", "false"),
            ("autoload_known_extensions", "false"),
            ("allow_community_extensions", "false"),
        ]
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
    static func isExtensionName(_ s: String) -> Bool {
        func lower(_ u: Unicode.Scalar) -> Bool { ("a"..."z").contains(u) || u == "_" }
        guard let first = s.unicodeScalars.first, lower(first) else { return false }
        return s.unicodeScalars.allSatisfy { lower($0) || ("0"..."9").contains($0) }
    }
}
