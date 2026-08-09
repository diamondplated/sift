import CDuckDB
import Foundation

extension Connection {
    /// Prepare, bind and execute. The only way to run SQL that carries values.
    public func query(_ sql: String, _ params: [DBValue] = []) throws -> ResultSet {
        var stmt: duckdb_prepared_statement?
        let prepared = duckdb_prepare(handle, sql, &stmt)
        defer { duckdb_destroy_prepare(&stmt) }

        // Not redundant with the execute check below. MEASURED against libduckdb 1.5.5:
        // calling duckdb_execute_prepared on a statement whose prepare FAILED segfaults
        // (exit 139). This guard is crash-preventing, not cosmetic.
        if prepared != DuckDBSuccess {
            let msg = duckdb_prepare_error(stmt).map(String.init(cString:)) ?? ""
            throw DuckDBError(msg)
        }

        // DuckDB parameter indexes are 1-based.
        for (offset, value) in params.enumerated() {
            let idx = idx_t(offset + 1)
            let state: duckdb_state
            switch value {
            case .null:          state = duckdb_bind_null(stmt, idx)
            case .bool(let v):   state = duckdb_bind_boolean(stmt, idx, v)
            case .int(let v):    state = duckdb_bind_int64(stmt, idx, v)
            case .double(let v): state = duckdb_bind_double(stmt, idx, v)
            case .text(let v):   state = duckdb_bind_varchar(stmt, idx, v)
            }
            if state != DuckDBSuccess {
                throw DuckDBError("could not bind parameter \(offset + 1)")
            }
        }

        var result = duckdb_result()
        if duckdb_execute_prepared(stmt, &result) != DuckDBSuccess {
            let msg = duckdb_result_error(&result).map(String.init(cString:)) ?? ""
            duckdb_destroy_result(&result)
            throw DuckDBError(msg)
        }
        return ResultSet(result: result)
    }
}
