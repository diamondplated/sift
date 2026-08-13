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
            SourceSidebar(state: state)
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
            // 🔴 **`.toolbar` HERE, and not an `NSToolbarDelegate` in `SiftApp`.** Task 13 measured
            // the reason and then had to work around it: `NavigationSplitView` inside an
            // `NSHostingView` REPLACES `window.toolbar` with an `NSToolbar` of its own, whose
            // delegate is `SwiftUI.ToolbarPlatformDelegate`. The shell's
            // `toolbarDefaultItemIdentifiers` was called and its items were built — and then the
            // whole toolbar was swapped out from under them, so Open and the row count ended up in
            // an `NSTitlebarAccessoryViewController` (the one strip SwiftUI does not manage) with
            // its frame re-fitted by hand on every catalog change.
            //
            // 🔴 **On the DETAIL column, not on the `NavigationSplitView`.** MEASURED against the
            // running app, 1480 pt wide with room to spare: attached to the split view, every
            // trailing item was pushed into the "more toolbar items" overflow popup and Merge landed
            // at x=215 — inside the sidebar's own toolbar region, ahead of the sidebar toggle. The
            // split view's toolbar is divided per column, so `.primaryAction` there is trailing OF
            // THE SIDEBAR. Attached to the detail column the same items lay out at x=1473/1510/1547,
            // at the window's trailing edge, with no overflow.
            //
            // The bare `NSToolbar` assigned at window creation must stay: `.fullSizeContentView`
            // needs a toolbar to exist at t=0 or the content view covers the title bar, swallows
            // every mouse event and the window cannot be moved at all. SwiftUI replaces it a moment
            // later with this one.
            .toolbar { toolbarItems }
        }
        .inspector(isPresented: $state.inspectorVisible) { InspectorView(state: state) }
        // The whole window is the drop target. It publishes `\.sourceDragHot`, which is how the
        // sidebar's dropzone and the empty state below both learn that a drag is over it.
        .sourceDrop(state: state)
        // The five sheets, presented from one place. Every route that raises one — the File menu,
        // the toolbar, the clickable dropped-rows chip, a dropped workbook, the sidebar's context
        // menu — sets `AppState.modalSheet` and stops; until this modifier existed they all set a
        // value nothing read, so five finished features were unreachable.
        .sheet(item: $state.modalSheet) { which in
            switch which {
            case .export:
                if let t = state.active {
                    ExportSheet(session: state.session, table: t) { state.banner = $0 }
                }
            case .merge:
                MergeSheet(
                    session: state.session, tables: state.tables.map(\.name),
                    initialLeft: state.activeName
                ) { merged in
                    Task { await state.refresh(); state.activeName = merged.name }
                }
            case .staged:
                StagedDataSheet(session: state.session)
            case .badRows:
                if let t = state.active {
                    BadRowsSheet(session: state.session, table: t.name)
                }
            case .workbook(let path):
                SheetPickerSheet(path: path) { picked in
                    Task { for name in picked { await state.open(path: path, sheet: name) } }
                }
            }
        }
    }

    /// Open at the leading edge beside SwiftUI's own sidebar toggle, and at the trailing edge the
    /// live row count followed by the three sheets that used to be reachable only from the menu bar.
    ///
    /// Every one of them is `state.can*` or one `present*` call — nothing here decides anything, for
    /// the same reason `AppDelegate`'s actions are one line each: a `View`'s body cannot be tested,
    /// so a rule written in one is a rule nothing checks. The greying reads the SAME properties
    /// `validateMenuItem` does, so the menu item and the button cannot disagree.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: onOpen) { Label("Open", systemImage: ToolbarSymbol.open) }
                .help("Open a file or folder")
        }
        // One `ToolbarItem` each rather than a `ToolbarItemGroup`: a group is one indivisible unit
        // to the overflow logic, so all four go behind the » the moment SwiftUI thinks any of them
        // is tight. Separate items are placed and overflowed individually.
        ToolbarItem(placement: .primaryAction) { RowSummaryItem(state: state) }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentMerge() } label: {
                Label("Merge Tables", systemImage: ToolbarSymbol.merge)
            }
            .disabled(!state.canMerge)
            .help("Merge two open tables on a shared key")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentExport() } label: {
                Label("Export", systemImage: ToolbarSymbol.export)
            }
            .disabled(!state.canExport)
            .help("Write the open table out as CSV, Parquet, JSON or XLSX")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.presentStaged() } label: {
                Label("Staged Data", systemImage: ToolbarSymbol.staged)
            }
            .help("Manage the native copies Sift is holding on disk")
        }
    }
}

// MARK: - the toolbar's pieces

/// The SF Symbols the toolbar draws.
///
/// 🔴 Named here rather than written inline so `theToolbarsSymbolsAllResolve` can prove each one
/// exists on the floor version. `Label(_, systemImage:)` given a name macOS does not know draws
/// NOTHING and reports nothing — a toolbar button that is present, enabled, hit-testable and
/// invisible, which is a worse bug than the one this toolbar is replacing.
enum ToolbarSymbol {
    static let open = "plus"
    static let merge = "arrow.triangle.merge"
    static let export = "square.and.arrow.down"
    static let staged = "internaldrive"

    static let all = [open, merge, export, staged]
}

/// The live row count — and, when rows were dropped, the way into the bad-rows sheet.
///
/// 🔴 The click target is the whole reason this is not a plain `Text`. "12 dropped" drawn with no
/// way to ask what it means is the defect Task 13 was fixing when it put a click recognizer on an
/// `NSTextField` in the title bar; the phrase carries the product's headline claim and the panel
/// behind it was otherwise unreachable inside `Sift.app`. The underline is the only affordance it
/// gets, and it appears only when there is something to show — an underlined phrase that does
/// nothing would be worse than none.
///
/// Not `.disabled()` on a single button: greying the phrase would dim the row COUNT, which is
/// information rather than a control, on every clean file in the product.
private struct RowSummaryItem: View {
    let state: AppState

    var body: some View {
        if state.canShowBadRows {
            Button { state.presentBadRows() } label: { phrase.underline() }
                .buttonStyle(.plain)
                .help("Show the rows that were dropped")
        } else {
            phrase
        }
    }

    /// `monospacedDigit`, matching the title-bar label this replaces: the count changes every poll
    /// while a background count runs, and proportional digits make the whole phrase twitch.
    private var phrase: some View {
        Text(state.rowSummary)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
    /// `.gempty.drop` (`web/index.html:1543`) — the second half of the shell's drag hint, so a drag
    /// over the window lights the pane the user is actually looking at as well as the sidebar.
    /// Read from the environment rather than passed in, so `RootView`'s call site stays untouched.
    @Environment(\.sourceDragHot) private var dragHot

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
        .background(dragHot ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}
