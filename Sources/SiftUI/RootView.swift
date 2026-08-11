import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

/// The window's whole contents: sources on the left, the open table on the right.
///
/// **Deliberately crude.** Task 6 replaces the detail side with the real virtualized grid over
/// `NSTableView`; until then this draws one page of rows in a `LazyVStack` so there is something
/// to look at and something to be wrong. The one thing it does NOT do crudely is render a cell —
/// see `cell(_:_:)`.
public struct RootView: View {
    @Bindable private var state: AppState
    private let onOpen: () -> Void

    public init(state: AppState, onOpen: @escaping () -> Void) {
        self.state = state
        self.onOpen = onOpen
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            List(state.tables, id: \.name, selection: $state.activeName) { table in
                Text(table.name)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if let banner = state.banner {
                    BannerLine(text: banner) { state.banner = nil }
                }
                if let table = state.active, let model = state.model(for: table.name) {
                    TableRows(model: model) { state.banner = $0 }
                } else {
                    EmptyState(onOpen: onOpen)
                }
            }
        }
    }
}

// MARK: - detail

private struct TableRows: View {
    let model: TableViewModel
    let onError: (String) -> Void

    private let columnWidth: CGFloat = 170

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 16) {
                    ForEach(model.columns, id: \.name) { column in
                        Text(column.name)
                            .bold()
                            .lineLimit(1)
                            .frame(width: columnWidth, alignment: .leading)
                    }
                }
                Divider()
                // One block, straight out of the cache. Task 6's `NSTableView` is what turns
                // `scrollExtent` into a real scroll bar; until then this draws the rows that are
                // there and nothing where they are not.
                ForEach(0..<min(model.scrollExtent, pageRows), id: \.self) { row in
                    HStack(spacing: 16) {
                        if case .loaded(let cells) = model.rowSlot(at: row) {
                            ForEach(model.columns.indices, id: \.self) { column in
                                cell(cells[column], model.columns[column])
                            }
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(12)
        }
        // `id:` so switching tabs re-runs this against the newly selected table. The error is
        // surfaced rather than swallowed: `loadFirstPage` is the only thing standing between the
        // user and an empty window, so a `try?` here would be the silent failure this app is
        // supposed to be the opposite of.
        .task(id: model.name) {
            do { try await model.loadFirstPage() } catch { onError(error.localizedDescription) }
        }
    }

    /// 🔴 A real NULL, a real empty string and a cell whose text is literally `N/A` must remain
    /// three visibly different things — that distinction is the product (spec §9).
    ///
    /// The value string comes from `SiftEngine.glyph(for:kind:)`, the ONE renderer, shared with
    /// the `sift` CLI because two renderings of the same file that disagree is a defect in a tool
    /// whose premise is not lying about data. **Never `Cell.display`**: it renders `.null` and
    /// `.text("")` identically, collapsing two of the three. The UI's own contribution is only the
    /// styling — `nullGlyph`/`emptyStringGlyph` are public constants precisely so it can do that
    /// rather than reuse the CLI's ASCII spelling.
    @ViewBuilder
    private func cell(_ cell: Cell, _ column: Column) -> some View {
        let absent = cell.isNull || cell == .text("")
        Text(glyph(for: cell, kind: column.kind))
            .foregroundStyle(absent ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .italic(absent)
            .lineLimit(1)
            .frame(width: columnWidth, alignment: column.kind == .number ? .trailing : .leading)
    }
}

private struct EmptyState: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("No file open").font(.title2).foregroundStyle(.secondary)
            Button("Open a File…", action: onOpen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One user-facing sentence with a way to dismiss it. Task 10 replaces this with the real banner
/// stack (staging progress, notes, missing extensions, busy).
private struct BannerLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.16))
    }
}
