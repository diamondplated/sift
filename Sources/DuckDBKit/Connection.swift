import CDuckDB
import Foundation

/// One DuckDB connection. Connections share the catalog and buffer manager but own
/// their transaction, and are NOT safe to use from more than one task — which is why
/// this is deliberately not Sendable. Every unit of work makes its own.
public final class Connection {
    let handle: duckdb_connection

    init(handle: duckdb_connection) {
        self.handle = handle
    }

    deinit {
        var h: duckdb_connection? = handle
        duckdb_disconnect(&h)
    }

    /// Run a statement, discarding any result.
    public func execute(_ sql: String) throws {
        var result = duckdb_result()
        let state = duckdb_query(handle, sql, &result)
        defer { duckdb_destroy_result(&result) }
        if state != DuckDBSuccess {
            throw DuckDBError(duckdb_result_error(&result).map(String.init(cString:)) ?? "")
        }
    }

    /// Cancel whatever this connection is running. Wraps the mechanism
    /// engine/session.py's `cancel` relies on.
    public func interrupt() {
        duckdb_interrupt(handle)
    }
}
