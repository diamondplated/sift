import Foundation

/// The page → shell message contract.
///
/// The page stays the single source of truth for engine state: it already fetches /api/state and
/// receives SSE updates, so having Swift poll separately would mean two views of the world that can
/// disagree. Instead the page pushes what the native chrome needs to draw, and the shell calls back
/// into JS for actions.
enum Bridge {
    struct TableInfo: Decodable, Equatable {
        let name: String
        let fmt: String
        let size: Int
        let rows: Int?
        let staged: Bool
        let badRows: Int
        let path: String
        /// "csv · 143.8 MB · 3,000,048 rows" — formatted once by the page (sourceSubtitle) and sent
        /// over the bridge, so the native sidebar and the web rail can never format it differently.
        let subtitle: String

        static func grouped(_ n: Int) -> String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }

    struct StatePayload: Decodable {
        let tables: [TableInfo]
        let active: String?
        /// Pre-formatted by the page so the number in the toolbar always matches the grid.
        let rowSummary: String?
    }

    static func decode<T: Decodable>(_ body: Any, as type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// A JS call with one string argument, quoted via JSONSerialization so a filename containing a
    /// quote or a backslash cannot break out of the expression.
    static func call(_ fn: String, _ arg: String) -> String {
        var literal = "\"\""
        if let data = try? JSONSerialization.data(withJSONObject: [arg]),
           let json = String(data: data, encoding: .utf8), json.count >= 2 {
            literal = String(json.dropFirst().dropLast())
        }
        return "window.\(fn) && window.\(fn)(\(literal))"
    }
}
