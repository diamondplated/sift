import SiftCore
import SiftEngine
import SwiftUI

// The inspector: the tab strip, the Schema tab, and the number formatting both tabs share.
// Ported from `renderInspector`/`renderSchema` (`web/index.html:1045-1080`).

/// The three inspector tabs. `source` is declared here and rendered by Task 9 — the enum is the
/// contract between the two, so the picker below already has the segment.
public enum InspectorTab: String, CaseIterable, Sendable {
    case schema, column, source

    var title: String {
        switch self {
        case .schema: return "Schema"
        case .column: return "Column"
        case .source: return "Source"
        }
    }
}

/// The inspector pane: a tab strip over one of three bodies.
///
/// The selected tab and column are `@State` here rather than on `AppState` on purpose — nothing
/// outside this pane reads either one, and the app already has one observable object per open
/// table. The one thing that DOES cross the boundary is `AppState.inspectorVisible`, which the View
/// menu toggles, and that already existed.
public struct InspectorView: View {
    private let state: AppState
    @State private var tab: InspectorTab = .schema
    @State private var column: String?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            // 🔴 The ONE scroller, here rather than inside each tab. Not a style preference:
            // `ImageRenderer` lays out no `ScrollView` at all (MEASURED on this branch — a
            // `SchemaList` that wrapped its own came out a blank 320x200 bitmap), so a scroller
            // inside a panel silently costs that panel its entire visual check. Panels are content;
            // the pane scrolls them.
            ScrollView {
                body(for: state.active.flatMap { state.model(for: $0.name) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
    }

    @ViewBuilder
    private func body(for model: TableViewModel?) -> some View {
        if let model {
            switch tab {
            case .schema:
                SchemaList(model: model, selected: column) { name in
                    column = name
                    tab = .column
                }
            case .column:
                if let column {
                    // `id:` so switching columns rebuilds the panel rather than handing the next
                    // column the previous one's search text and lens.
                    ColumnPanel(session: state.session, model: model, column: column)
                        .id(column)
                } else {
                    Note("Click a column.")
                }
            case .source:
                // Task 9 owns `SourceTab`. Said out loud rather than left blank, because a tab that
                // renders nothing at all reads as a bug rather than as unfinished.
                Note("The source panel arrives with Task 9.")
            }
        } else {
            Note("Nothing open.")
        }
    }
}

/// One secondary sentence, centred in the pane — the inspector's three empty states.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Schema

/// Every column, with how much of it is missing and what type it is.
public struct SchemaList: View {
    private let model: TableViewModel
    private let selected: String?
    private let onSelect: (String) -> Void

    public init(model: TableViewModel, selected: String? = nil, onSelect: @escaping (String) -> Void) {
        self.model = model
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.columns.count) columns")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            ForEach(model.columns, id: \.name) { column in
                row(column)
            }
            // 🔴 `Table.profiling`, the engine's own flag, and NOT a mirror of it on the view
            // model: the profile runs detached (`Session.profileJob`), which is what makes the flag
            // observable at all, and `AppState.refresh()` polls it in. A second copy up here would
            // be a copy that can be wrong.
            if model.table.profiling {
                Text("Profiling…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func row(_ column: Column) -> some View {
        let profile = model.profile.first { $0.name == column.name }
        HStack(spacing: 6) {
            Text(column.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let profile, profile.n > 0 {
                MissingBar(profile: profile)
            }
            if let profile {
                Text((profile.exactDistinct == nil ? "≈" : "")
                    + compactCount(profile.exactDistinct ?? profile.approxDistinct))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(shortType(column.type))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected == column.name ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(column.name) }
    }
}

/// The three-segment missing bar: null, empty and uncastable as fractions of the column's rows.
///
/// Widths are absolute rather than proportional-within-an-`HStack` because the segments do not fill
/// the track — the remainder IS the reading. Only drawn when `n > 0`, which is also what keeps the
/// division safe (`if (p && p.n)`, `web/index.html:1058`).
private struct MissingBar: View {
    let profile: ColumnProfile

    private let width: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            segment(profile.nNull, .orange)
            segment(profile.nEmpty, .blue)
            segment(profile.nUncastable, .red)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 5)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .help("\(countText(profile.nNull)) null · \(countText(profile.nEmpty)) empty · "
            + "\(countText(profile.nNullish)) null-like · \(countText(profile.nUncastable)) won't cast")
    }

    private func segment(_ n: Int, _ colour: Color) -> some View {
        Rectangle().fill(colour).frame(width: width * CGFloat(n) / CGFloat(profile.n))
    }
}

// MARK: - formatting
//
// Every number the inspector draws goes through one of these three. No `NumberFormatter`: without
// an explicit locale the same count renders four ways (`SiftCore.groupDigits`' own note), and this
// pane's whole job is telling the user a true number.

/// Thousands-grouped, through the one grouping loop the grid and the CLI already share.
func countText(_ n: Int) -> String { groupDigits(String(n)) }

/// `compact` (`web/index.html:632`) — the schema row's distinct count, where the shape of the
/// number matters more than its last three digits.
func compactCount(_ n: Int) -> String {
    if n < 1_000 { return String(n) }
    if n < 1_000_000 { return String(format: "%.\(n < 10_000 ? 1 : 0)f", Double(n) / 1_000) + "k" }
    return String(format: "%.1f", Double(n) / 1_000_000) + "M"
}

/// `pct` (`web/index.html:471`): one decimal, or two below 1% so a rare-but-present value does not
/// round to a flat `0.0%` and read as absent.
func percentText(_ fraction: Double) -> String {
    String(format: "%.\(fraction < 0.01 && fraction > 0 ? 2 : 1)f", fraction * 100) + "%"
}

/// `shortType` (`web/index.html:1079`). Every occurrence rather than the first, which is the one
/// deliberate divergence: JS's `.replace(string, …)` and an unflagged regex both stop after one,
/// so `STRUCT(a VARCHAR, b VARCHAR)` came out half-shortened in the web build.
func shortType(_ type: String) -> String {
    type.replacingOccurrences(of: "TIMESTAMP WITH TIME ZONE", with: "TSTZ")
        .replacingOccurrences(of: "DECIMAL", with: "DEC")
        .replacingOccurrences(of: "VARCHAR", with: "STR")
        .replacingOccurrences(of: "BOOLEAN", with: "BOOL")
}
