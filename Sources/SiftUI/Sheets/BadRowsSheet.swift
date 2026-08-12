import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

// "The rows your file lost." Ported from `showBadRows` (web/index.html:1306-1330).
//
// 🔴 THIS PANEL IS THE PRODUCT'S HEADLINE CLAIM. Every other tool in this space reads a CSV with
// `ignore_errors` (or its equivalent) and shows you the rows that survived, with nothing anywhere
// saying that some did not. Sift says the number, and then says *which cells* — which is why
// `Cell.list` exists at all.
//
// 🔴 `bad_columns` IS COLUMN 0, AND IT IS A LIST. `SQLGenPanels.badRowsSQL` emits
// `list_filter([...], x -> x IS NOT NULL) AS bad_columns, *`, so `row[0]` decodes as
// `Cell.list([.text("qty"), ...])`. Decoding that LIST element-by-element was a Critical found
// late in the engine work (DuckDBKit Task 1), and `badColumnNames` below is the whole reason it
// was closed: a joined string would have to be re-split downstream, and re-splitting breaks the
// instant a column name contains the separator — in the one product that exists not to mangle
// data. **Do not "simplify" this into `row[0].display.split(separator: ",")`.**
//
// Cells render through `SiftEngine.glyph(for:kind:)`, never `Cell.display` — see CellGlyph.swift's
// header for why that split runs the direction it does.

// MARK: - phrasing

/// `2,120 rows dropped`. Grouped through `SiftCore.groupDigits`, which takes a STRING and never
/// parses it — the same rule the grid's row gutter follows, and never `NumberFormatter`.
public func badRowsHeadline(rows: Int) -> String {
    "\(groupDigits(String(rows))) row\(rows == 1 ? "" : "s") dropped"
}

/// The paragraph under it, verbatim from web/index.html:1308-1311. The web bolds the "not"; a
/// `Text` of a plain `String` does not parse markdown, and the emphasis is not the information.
public func badRowsExplanation(cells: Int) -> String {
    "\(groupDigits(String(cells))) cell\(cells == 1 ? "" : "s") could not be cast to the detected "
        + "type, so DuckDB skipped the whole row. These are not in the grid or in any aggregate. "
        + "Reading the column as text instead keeps them."
}

// MARK: - which cells to paint

/// The columns this row failed to cast, read out of the `bad_columns` LIST in column 0.
///
/// A `Set<String>` and not the raw `[Cell]`: the caller asks "is THIS column name in it" once per
/// cell, and a column name that is not plain text cannot be one (`badRowsSQL` builds the list from
/// `qlit(column.name)` string literals, so every element is `.text` or the row is not ours).
public func badColumnNames(in row: [Cell]) -> Set<String> {
    guard case .list(let items) = (row.first ?? .null) else { return [] }
    return Set(
        items.compactMap { item in
            if case .text(let name) = item { return name }
            return nil
        })
}

/// One sample cell's text: the shared engine glyph, capped at the web's 60 characters
/// (`esc(...).slice(0, 60)`). A sample row exists to be recognised, not read in full.
func badCellText(_ cell: Cell, kind: Kind) -> String {
    String(SiftEngine.glyph(for: cell, kind: kind).prefix(60))
}

// MARK: - the sheet

/// The rows DuckDB dropped, and the cells that cost them.
public struct BadRowsSheet: View {
    private let session: Session
    private let table: String

    @Environment(\.dismiss) private var dismiss
    @State private var panel: BadRowsPanel?
    @State private var error: String?

    public init(session: Session, table: String) {
        self.session = session
        self.table = table
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                // The engine already spells one clean sentence. Shown as itself — never wrapped in
                // prose of our own, and never swallowed by a `try?`.
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if let panel {
                Text(badRowsHeadline(rows: panel.rows)).font(.system(size: 15, weight: .semibold))
                Text(badRowsExplanation(cells: panel.cells))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !panel.data.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        BadRowsTable(panel: panel)
                    }
                    .frame(maxHeight: 340)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760)
        .task {
            do { panel = try await session.badRows(table) } catch { self.error = "\(error)" }
        }
    }
}

/// The sample rows. Split out of `body` so a test can host exactly what ships.
struct BadRowsTable: View {
    let panel: BadRowsPanel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                ForEach(panel.columns.indices, id: \.self) { c in
                    Text(panel.columns[c].name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(panel.data.indices, id: \.self) { r in
                let bad = badColumnNames(in: panel.data[r])
                GridRow {
                    ForEach(panel.columns.indices, id: \.self) { c in
                        BadCell(
                            text: badCellText(panel.data[r][c], kind: panel.columns[c].kind),
                            bad: bad.contains(panel.columns[c].name))
                    }
                }
            }
        }
    }
}

/// One sample cell. Its own view, and not an inline `Text` with a modifier, so the pixel test can
/// render both states and check that the red is really *drawn* — the class of defect that put a
/// `cacheDisplay` check into the grid's tests in the first place (an empty-string cell whose every
/// property said "dotted rule" and which AppKit declined to paint).
struct BadCell: View {
    let text: String
    let bad: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(bad ? Color.red : Color.primary)
            .lineLimit(1)
    }
}
