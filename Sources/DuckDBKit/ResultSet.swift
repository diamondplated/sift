import CDuckDB
import Foundation

/// A query result: owns the `duckdb_result` and its column metadata.
///
/// Row reading lives in Chunk.swift as an extension, so this file stays responsible
/// for exactly one thing — the handle's lifetime and the schema.
public final class ResultSet {
    var result: duckdb_result
    public let columns: [ColumnMeta]

    init(result: duckdb_result) {
        var r = result
        var metas: [ColumnMeta] = []
        let count = Int(duckdb_column_count(&r))
        metas.reserveCapacity(count)
        for i in 0..<count {
            let idx = idx_t(i)
            let name = duckdb_column_name(&r, idx).map(String.init(cString:)) ?? ""
            var logical = duckdb_column_logical_type(&r, idx)
            let typeID = duckdb_get_type_id(logical)
            let isDecimal = typeID == DUCKDB_TYPE_DECIMAL
            let scale = isDecimal ? duckdb_decimal_scale(logical) : 0
            let width = isDecimal ? duckdb_decimal_width(logical) : 0
            duckdb_destroy_logical_type(&logical)
            metas.append(ColumnMeta(name: name, typeID: typeID, decimalScale: scale,
                                    decimalWidth: width, typeName: Self.typeName(typeID)))
        }
        self.result = result
        self.columns = metas
    }

    deinit {
        duckdb_destroy_result(&result)
    }

    static func typeName(_ t: duckdb_type) -> String {
        switch t {
        case DUCKDB_TYPE_BOOLEAN:      return "BOOLEAN"
        case DUCKDB_TYPE_TINYINT:      return "TINYINT"
        case DUCKDB_TYPE_SMALLINT:     return "SMALLINT"
        case DUCKDB_TYPE_INTEGER:      return "INTEGER"
        case DUCKDB_TYPE_BIGINT:       return "BIGINT"
        case DUCKDB_TYPE_UTINYINT:     return "UTINYINT"
        case DUCKDB_TYPE_USMALLINT:    return "USMALLINT"
        case DUCKDB_TYPE_UINTEGER:     return "UINTEGER"
        case DUCKDB_TYPE_UBIGINT:      return "UBIGINT"
        case DUCKDB_TYPE_HUGEINT:      return "HUGEINT"
        case DUCKDB_TYPE_UHUGEINT:     return "UHUGEINT"
        case DUCKDB_TYPE_FLOAT:        return "FLOAT"
        case DUCKDB_TYPE_DOUBLE:       return "DOUBLE"
        case DUCKDB_TYPE_DECIMAL:      return "DECIMAL"
        case DUCKDB_TYPE_VARCHAR:      return "VARCHAR"
        case DUCKDB_TYPE_BLOB:         return "BLOB"
        case DUCKDB_TYPE_DATE:         return "DATE"
        case DUCKDB_TYPE_TIME:         return "TIME"
        case DUCKDB_TYPE_TIMESTAMP:    return "TIMESTAMP"
        case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMP WITH TIME ZONE"
        case DUCKDB_TYPE_UUID:         return "UUID"
        default:                       return "OTHER"
        }
    }
}
