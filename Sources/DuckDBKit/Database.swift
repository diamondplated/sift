import CDuckDB
import Foundation

/// Owns the one `duckdb_database`. Creating connections from it is thread-safe,
/// which is why this is `@unchecked Sendable` while `Connection` is not.
public final class Database: @unchecked Sendable {
    private var handle: duckdb_database?
    // loadedExtensions and hardened are written only during configure-time (harden/
    // loadExtensions) and read afterwards, making the unsynchronized dictionaries safe on
    // @unchecked Sendable.
    public private(set) var loadedExtensions: [String: Bool] = [:]
    /// Per-setting outcome of the last `harden()`, keyed by setting name.
    public private(set) var hardened: [String: Bool] = [:]

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
            ("disabled_filesystems", "'HTTPFileSystem,S3FileSystem'"),
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
                loadedExtensions[name] = false
                continue
            }
            if (try? con.execute("LOAD \(name)")) != nil {
                loadedExtensions[name] = true
                continue
            }
            do {
                try con.execute("INSTALL \(name)")
                try con.execute("LOAD \(name)")
                loadedExtensions[name] = true
            } catch {
                loadedExtensions[name] = false
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
