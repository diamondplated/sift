import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

/// The window's whole contents: sources on the left, the open table on the right.
public struct RootView: View {
    @Bindable private var state: AppState
    private let onOpen: () -> Void

    /// Whether the SQL console is showing. Per window and not per table — `sqlwrap`'s `display` was
    /// one element for the whole page (`web/index.html:359`), and a toggle that forgot itself on
    /// every tab switch would be worse than one that remembers the wrong thing.
    @State private var showSQL = false

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
            // Banners, filter bar, console, grid — `web/index.html:336-368`'s order. The banners sit
            // ABOVE the toolbar because several of them (staging, a missing extension) are about the
            // engine rather than about this view of the table, and pushing them under the filters
            // would read as though the filters caused them.
            VStack(spacing: 0) {
                BannerStack(state: state)
                if let table = state.active, let model = state.model(for: table.name) {
                    FilterBar(model: model, showSQL: $showSQL) { state.banner = $0 }
                    Divider()
                    if showSQL {
                        SQLConsole(model: model) { state.banner = $0 }
                        Divider()
                    }
                    TableGrid(
                        model: model,
                        onColumnSelected: { state.selectedColumn = $0 },
                        onError: { state.banner = $0 })
                } else {
                    NothingOpenYet(onOpen: onOpen)
                }
            }
        }
        .inspector(isPresented: $state.inspectorVisible) { InspectorView(state: state) }
    }
}

// MARK: - detail

/// The grid, plus the two empty states that only make sense once a table is open.
///
/// Which of them is showing is `gridState(columnCount:scrollExtent:rowCountKnown:)`'s decision, not
/// this body's — a body cannot be tested, and that function's edges can.
private struct TableGrid: View {
    let model: TableViewModel
    let onColumnSelected: (String) -> Void
    let onError: (String) -> Void

    private var state: GridState {
        gridState(
            columnCount: model.columns.count, scrollExtent: model.scrollExtent,
            rowCountKnown: model.table.displayRows != nil)
    }

    var body: some View {
        Group {
            switch state {
            case .noColumns:
                Text("No columns.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noRows, .rows:
                // 🔴 `.id(model.name)`: `NSViewRepresentable` reuses its coordinator for the life of
                // one view identity, and the coordinator holds the model. Without this, switching
                // tabs leaves the previous table's `GridBridge` driving the new table's grid.
                // 🔴 Both closures wired. The header task built them and could not reach this call
                // site: `onColumnSelected` is a plain header click, which without this does
                // *nothing at all*, and `onError` is a failed shift-click sort — `setSort` runs in a
                // detached `Task`, so there is no caller left to throw to and the banner is the only
                // place that error can go.
                TableGridView(
                    model: model, onColumnSelected: onColumnSelected, onError: onError)
                    .id(model.name)
                    // The "no rows match" state deliberately does NOT cover the header —
                    // `web/index.html:198` (`inset: 46px 0 0 0`), so the filters that emptied the
                    // grid are still there to be undone. Opaque, so no stale rows show behind it.
                    .overlay(alignment: .top) {
                        if state == .noRows {
                            Text("No rows match the current filters.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                                .padding(.top, gridHeaderInset)
                        }
                    }
            }
        }
        // The §13a busy overlay, on the GRID and nothing else: the actor is blocked, not the app, so
        // the sidebar, the inspector and the menu bar stay live and the scrim covers exactly the
        // thing that has stopped answering.
        .overlay {
            if model.busy.visible { BusyOverlay(message: model.busy.message) }
        }
        // `id:` so switching tabs re-runs this against the newly selected table. The error is
        // surfaced rather than swallowed: `loadFirstPage` is the only thing standing between the
        // user and an empty window, so a `try?` here would be the silent failure this app is
        // supposed to be the opposite of.
        .task(id: model.name) {
            do { try await model.loadFirstPage() } catch { onError(error.localizedDescription) }
        }
    }
}

/// Height of the `NSTableView` header the "no rows" overlay must not cover.
private let gridHeaderInset: CGFloat = 28

/// The no-file-open state — `showEmptyState("nofile")` (`web/index.html:637-657`), copy included.
private struct NothingOpenYet: View {
    let onOpen: () -> Void

    private let formats = ["csv", "parquet", "json", "ndjson", "xlsx", "delta table", "folder"]

    var body: some View {
        VStack(spacing: 14) {
            Text("⚡")
                .font(.system(size: 30))
                .frame(width: 66, height: 66)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor.opacity(0.28)))
            Text("Nothing open yet").font(.system(size: 16, weight: .semibold))
            Text(
                """
                Drop a file anywhere here, or open one — it loads instantly and stays on disk, \
                so size isn't the constraint it usually is.
                """
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            Button(action: onOpen) { Label("Open a File…", systemImage: "plus") }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            // The formats the open panel will actually accept, said before the user has to guess.
            HStack(spacing: 5) {
                ForEach(formats, id: \.self) { format in
                    Text(format.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .kerning(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
