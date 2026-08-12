import SiftCore
import SwiftUI

// The strip above the grid: one chip per active filter, `clear all`, and the SQL console's toggle.
// Ported from `renderToolbar`/`opLabel` (`web/index.html:900-941`), rule for rule.

/// One filter, as the chip says it — `opLabel` (`web/index.html:929-941`), verbatim.
///
/// The column name is NOT in here: the chip draws it in bold beside this, exactly as the web's
/// `<b>${col}</b> ${opLabel(x)}` does, and a test that pinned "amount = 3" could not tell a missing
/// bold from a missing space.
public func filterChipLabel(_ f: Filter) -> String {
    let v = f.values.map(filterValueText)
    switch f.op {
    case .isNull: return "is null"
    case .notNull: return "is not null"
    case .isEmpty: return "is empty"
    // Three or more values stop being readable as a list and start being a count. Two is the web's
    // threshold and it is a judgement about chip width, not about filters.
    case .inList: return v.count > 2 ? "in \(v.count) values" : "= " + v.joined(separator: ", ")
    case .notIn: return "≠ " + v.joined(separator: ", ")
    case .contains: return "contains \u{201C}\(v.first ?? "")\u{201D}"
    case .between: return "\(v.first ?? "") … \(v.count > 1 ? v[1] : "")"
    // `=`, `!=`, `<`, `<=`, `>`, `>=` — the raw wire spelling is already the operator the user
    // would write, so there is nothing to translate. Same `default` branch as the web's.
    default: return "\(f.op.rawValue) " + v.joined(separator: ", ")
    }
}

/// One filter value as text — the web's `x === null ? "␀ NULL" : String(x)`.
///
/// `nullSentinelLabel` rather than a second copy of the glyph: it is the same string the distinct
/// panel's NULL row carries, and `applyDistinctClick` dispatches on it (see FilterActions.swift).
/// Deliberately not routed through `groupDigits` — these are *values*, not counts, and an id of
/// 1000000 must render as the thing the user would type back in.
func filterValueText(_ value: SQLValue) -> String {
    switch value {
    case .null: return nullSentinelLabel
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .text(let s): return s
    }
}

/// The filter strip for one open table.
public struct FilterBar: View {
    private let model: TableViewModel
    @Binding private var showSQL: Bool
    private let onError: (String) -> Void

    public init(
        model: TableViewModel, showSQL: Binding<Bool>, onError: @escaping (String) -> Void
    ) {
        self.model = model
        self._showSQL = showSQL
        self.onError = onError
    }

    private var filters: [Filter] { model.table.qspec.filters }

    public var body: some View {
        HStack(spacing: 6) {
            if model.table.sqlMode {
                // 🔴 The chips are not merely hidden here — they are REPLACED, by a chip that says
                // why. In SQL mode the spec's filters are still in the catalog and still describe
                // nothing on screen, so drawing them would be the app lying about what the grid is
                // showing; drawing nothing at all would leave the user wondering where their
                // filters went. `SQLConsole`'s status line is the other half of this sentence.
                Text("SQL mode — filters frozen")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            } else if filters.isEmpty {
                // The one place the app says how the header works. `TableGridView`'s plain-click /
                // shift-click split is not guessable, and this is where a user with no filters is
                // already looking.
                Text("No filters — click a column header to see its values, shift-click to sort.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                // Indexed, and NOT keyed by column: a column can carry several filters at once —
                // `applyDistinctClick`'s replacement is per (column, op), so an `is_null` and a
                // `not_in` on the same column are two chips with two separate ×s. Keying by column
                // would collapse them and remove the wrong one.
                //
                // Known gap, stated rather than hidden: an `HStack` does not wrap, so a great many
                // filters compress rather than flowing onto a second line (the web's toolbar has
                // `flex-wrap`). A wrapping `Layout` is the fix if anyone ever hits it.
                ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                    FilterChip(filter: filter) { remove(at: index) }
                }
                Button("clear all") { apply([]) }
            }
            Spacer(minLength: 8)
            Button(showSQL ? "Hide SQL" : "Show SQL") { showSQL.toggle() }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: 32)
    }

    /// Drops one chip. Index-based, matching `removeFilter(i)` (`web/index.html:894-898`) — see the
    /// `ForEach` above for why a column is not a key.
    private func remove(at index: Int) {
        var next = filters
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        apply(next)
    }

    /// 🔴 The error is surfaced, not swallowed. `setFilters` can only fail on a column the table
    /// does not have, which is exactly the case where the user's × would otherwise appear to work
    /// and change nothing.
    private func apply(_ next: [Filter]) {
        Task {
            do { try await model.setFilters(next) } catch { onError(error.localizedDescription) }
        }
    }
}

/// `.fchip` (`web/index.html:141-147`): bold column, the op label, and an × that removes it.
private struct FilterChip: View {
    let filter: Filter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(filter.col).bold()
            Text(filterChipLabel(filter))
            Button(action: remove) {
                Text("×").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("remove")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor.opacity(0.35)))
    }
}
