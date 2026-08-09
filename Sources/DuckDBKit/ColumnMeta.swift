import CDuckDB
import Foundation

/// What the decoder needs to know about one result column.
public struct ColumnMeta: Sendable {
    public let name: String
    public let typeID: duckdb_type
    /// DECIMAL only. Digits after the point. DECIMAL keeps its scale in the logical
    /// type, not the value — decoding through Double would lose exactly the precision
    /// this tool exists to preserve.
    public let decimalScale: UInt8
    /// DECIMAL only. Total digits — this picks the backing integer:
    /// <=4 SMALLINT, <=9 INTEGER, <=18 BIGINT, else HUGEINT. Reading a
    /// DECIMAL(4,2) as BIGINT does not fail, it silently returns a wrong number.
    public let decimalWidth: UInt8
    public let typeName: String

    public init(name: String, typeID: duckdb_type, decimalScale: UInt8,
                decimalWidth: UInt8, typeName: String) {
        self.name = name
        self.typeID = typeID
        self.decimalScale = decimalScale
        self.decimalWidth = decimalWidth
        self.typeName = typeName
    }
}
