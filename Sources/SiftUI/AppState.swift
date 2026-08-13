import Observation
import SiftCore
import SiftEngine
import SwiftUI

/// The one `Session`, the catalog mirror, the poll loop and the banner.
///
/// One window, one `Session`, N open tables — the app is single-window (`tabbingMode =
/// .disallowed`), and exactly one `Session` is constructed for the whole process. Task 2 makes
/// that structural rather than a convention.
@MainActor
@Observable
public final class AppState {
    public let session: Session
    public let engine: EngineInfo

    /// Mirror of the actor's catalog, refreshed by `poll()`. Read-only for views.
    ///
    /// `SiftEngine.Table` spelled out, here and everywhere below: this file imports SwiftUI, which
    /// has its own `Table`, and a bare `Table` is a hard "ambiguous for type lookup" error. The
    /// collision is a useful reminder rather than an annoyance — SwiftUI's `Table` is available on
    /// the macOS 14 floor and is exactly what this app must never use, since it needs a
    /// `RandomAccessCollection` of *every* row.
    public private(set) var tables: [SiftEngine.Table] = []
    public var activeName: String?
    /// Bound to `NavigationSplitView(columnVisibility:)` in `RootView`, and flipped by View >
    /// Toggle Sidebar (Task 13). SwiftUI owns the split now, so this replaces the shell's
    /// `NSSplitViewController.toggleSidebar`.
    public var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Bound to `.inspector(isPresented:)` (Task 8) and flipped by View > Toggle Inspector.
    public var inspectorVisible = true
    /// One user-facing sentence, or nil. Python emitted `{"type": "error"}` over SSE; there is no
    /// SSE, so the banner IS the notification — an open that fails without setting this is a
    /// silent failure, and the user's click just does nothing.
    public var banner: String?
    /// The column the inspector's Column tab is about.
    ///
    /// Here rather than as `@State` inside `InspectorView` because the two things that set it are
    /// two views apart: the Schema tab's own list, and a plain click on a grid column header
    /// (`GridBridge.onColumnSelected`, wired in `RootView`). The web kept the same value in the same
    /// place, as `state.col`, for the same reason.
    public var selectedColumn: String?

    /// `@ObservationIgnored` on both, deliberately. Views observe the `TableViewModel` objects
    /// themselves, never this dictionary — and `model(for:)` is called from `RootView.body`, so an
    /// observed dictionary would mean body *writing* to something body *read*, which invalidates
    /// the view it is in the middle of building. `pollTask` is never anything a view draws.
    @ObservationIgnored private var models: [String: TableViewModel] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init(session: Session) {
        self.session = session
        self.engine = session.engineInfo()   // nonisolated
    }

    public var active: SiftEngine.Table? { tables.first { $0.name == activeName } }

    /// 🔴 `nullPadding`/`skipPreamble` are threaded through, and until 2026-08-13 they were not.
    /// `Session.openPath` has carried both since it was written, the `sift` CLI has had both
    /// switches, and `raggedCollapseNote`/`preambleNote` end by telling the user in as many words to
    /// "re-open with null padding" / "re-open without skipping" — while this method, the ONLY way a
    /// path reaches the engine from the window, could pass neither. The instruction on screen was
    /// one no Mac user had any way to follow. `BannerView`'s note row is the affordance; see
    /// `reopen(_:with:)`.
    ///
    /// The defaults are the engine's own, so every existing call site is unchanged.
    public func open(
        path: String, sheet: String? = nil, nullPadding: Bool = false, skipPreamble: Bool = true
    ) async {
        do {
            let t = try await session.openPath(
                path, sheet: sheet, nullPadding: nullPadding, skipPreamble: skipPreamble)
            await refresh()
            activeName = t.name
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Close this table and open its file again with one of the two escape hatches on — what the
    /// note's own "re-open …" means.
    ///
    /// A REPLACEMENT, not a second table, and the close is what makes it one: `openPath` uniquifies
    /// a taken name, so opening first would leave the collapsed `orders` sitting beside the
    /// recovered `orders_2` for the user to tidy up, with the broken one still selected. Closing
    /// frees the name, so the recovered table keeps the one the user already knows.
    ///
    /// `sheet:` is carried but not exercised, stated plainly: both of today's fixes are CSV-only
    /// (`preambleAteTheFile` requires `fmt == .csv`, and `raggedColumns` is only ever set on a CSV
    /// or a folder of them), so `spec.sheet` is nil on every table that can reach here. It is
    /// passed anyway because dropping it is the one mistake this must not make if a third fix ever
    /// applies to a workbook — re-opening one without its sheet lands on whichever sheet
    /// `buildSource` auto-picks and serves a different sheet's rows under the same name.
    public func reopen(_ table: SiftEngine.Table, with fix: ReopenFix) async {
        await close(table.name)
        // `close` puts a refusal on the banner and carries on — a live merge reading this table is
        // the one that happens. Opening a second copy on top of that sentence would be the app
        // doing something other than what the button said.
        guard !tables.contains(where: { $0.name == table.name }) else { return }
        await open(
            path: table.spec.key.path, sheet: table.spec.sheet,
            nullPadding: fix == .nullPadding, skipPreamble: fix != .keepAllLines)
    }

    public func close(_ name: String) async {
        do { try await session.closeTable(name) } catch { banner = error.localizedDescription }
        models[name] = nil
        // `refresh()` moves the selection off a table that is no longer in the catalog, which
        // covers closing the active one — there is deliberately no second check here.
        await refresh()
    }

    public func refresh() async {
        let snapshot = await session.state()
        // NOT re-sorted and NOT re-keyed. `Session.state()` already sorts by `openedAt`, which is
        // the order the user opened the files in; putting these through a dictionary or a second
        // sort here is how the tab bar started shuffling on every launch in the first place.
        tables = snapshot.tables
        if let activeName, !tables.contains(where: { $0.name == activeName }) {
            self.activeName = tables.first?.name
        }
        for t in tables { models[t.name]?.apply(t) }
    }

    /// One view model per open table, created lazily and kept so the page cache survives a tab
    /// switch — the web build cleared its blocks on every switch and re-fetched (`resetGrid`).
    public func model(for name: String) -> TableViewModel? {
        guard let t = tables.first(where: { $0.name == name }) else { return nil }
        if let existing = models[name] { return existing }
        let m = TableViewModel(session: session, table: t)
        models[name] = m
        return m
    }

    /// Adaptive polling replaces SSE. 250 ms while the engine is doing something the user is
    /// waiting on, 2 s otherwise. Every user action calls `refresh()` directly as well, so this
    /// only has to catch *background* progress: the exact count, bad-row detection, the profile,
    /// and a staging job.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let busy = self.tables.contains {
                    $0.counting || $0.staging != nil || $0.profiling
                }
                try? await Task.sleep(nanoseconds: busy ? 250_000_000 : 2_000_000_000)
            }
        }
    }

    public func stopPolling() { pollTask?.cancel(); pollTask = nil }

    // MARK: - what the menus, the toolbar and the keyboard ask for
    //
    // Every menu item and every toolbar button is one call into this section. Nothing in `SiftApp`
    // may decide anything: a test target cannot import an `executableTarget`, so a decision made
    // there is a decision nothing will ever check.

    /// The one modal the window is showing, or `nil`.
    ///
    /// Set here, rendered by `RootView`'s sheet presentation. One optional rather than five
    /// booleans, because two modals up at once is not a state this app has — and five booleans is
    /// exactly how it would become one.
    /// `Identifiable` so one `.sheet(item:)` in `RootView` presents all five. The id is the
    /// case, not the payload: presenting `.workbook` for a second file while the first picker
    /// is up should replace it, not stack.
    public enum ModalSheet: Equatable, Sendable, Identifiable {
        case export
        case merge
        case staged
        /// The rows `ignore_errors` dropped. Reachable at last: in the shell the web topbar is
        /// hidden (`body.native`), so the count was shown with nothing to click.
        case badRows
        /// A workbook on its way in, waiting for a sheet to be chosen. See `needsSheetPicker`.
        case workbook(path: String)
        public var id: String {
            switch self {
            case .export: return "export"
            case .merge: return "merge"
            case .staged: return "staged"
            case .badRows: return "badRows"
            case .workbook: return "workbook"
            }
        }
    }

    public var modalSheet: ModalSheet?

    /// ⌘1–⌘9. Out-of-range is a no-op, not a crash: ⌘7 with three tables open is a thing a user
    /// does by accident constantly.
    public func selectTable(atIndex index: Int) {
        guard tables.indices.contains(index) else { return }
        activeName = tables[index].name
    }

    /// View > Toggle Sidebar. The split is SwiftUI's now, so this is a binding flip rather than the
    /// shell's `NSSplitViewController.toggleSidebar`.
    ///
    /// `.all` is the way back rather than `.automatic`: `.automatic` lets SwiftUI pick, and what it
    /// picks in a two-column split is `.all` — so spelling it means the second ⌘S is not a guess.
    public func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    /// View > Toggle Inspector.
    public func toggleInspector() { inspectorVisible.toggle() }

    // MARK: - what can be done right now
    //
    // 🔴 ONE authority per rule, read by all three consumers: `AppDelegate.validateMenuItem` (which
    // greys the menu item), `RootView`'s toolbar (which greys the button) and the `present*` guard
    // below (which refuses the action however it was reached). Until the toolbar existed, the first
    // and third were two separate spellings of the same sentence in two different targets — one of
    // which no test can import. That is how a menu item and a toolbar button start disagreeing about
    // whether the same thing can be done.

    /// Export and Close Table both act on the open table.
    public var canExport: Bool { active != nil }

    /// A merge needs two tables to merge.
    public var canMerge: Bool { tables.count >= 2 }

    /// Whether the toolbar's row phrase is a way into the bad-rows sheet. A count with nothing to
    /// click is the bug this restores: in the shell the web topbar is hidden (`body.native`), so
    /// "12 dropped" was drawn as text and the panel behind it was unreachable inside Sift.app.
    public var canShowBadRows: Bool { (active?.badRows ?? 0) > 0 }

    /// File > Export…, Data > Merge Tables…, Data > Manage Staged Data…, and the toolbar's
    /// "N dropped".
    public func presentExport() {
        guard canExport else { return }
        modalSheet = .export
    }

    public func presentMerge() { modalSheet = .merge }

    public func presentStaged() { modalSheet = .staged }

    public func presentBadRows() {
        guard canShowBadRows else { return }
        modalSheet = .badRows
    }

    /// File > Close Table (⌘W). Closes the open table, not the window — `close(_:)` moves the
    /// selection, and `applicationShouldTerminateAfterLastWindowClosed` means closing the window
    /// would quit.
    public func closeActive() async {
        guard let activeName else { return }
        await close(activeName)
    }

    /// Everything that arrives as a filesystem path: the open panel, a Dock-icon drop, Finder
    /// "Open With", `open -a Sift.app file`.
    ///
    /// ponytail: one workbook at a time. The picker is a single modal, so a batch carrying several
    /// opens the first and says so rather than silently dropping the rest. If picking sheets for a
    /// pile of workbooks in one go ever becomes a real request, queue them here — the banner is the
    /// place that will have to change.
    public func open(paths: [String]) async {
        var workbooks: [String] = []
        for path in paths {
            if needsSheetPicker(path) { workbooks.append(path) } else { await open(path: path) }
        }
        guard let first = workbooks.first else { return }
        modalSheet = .workbook(path: first)
        if workbooks.count > 1 {
            banner =
                "Opened the sheet picker for \((first as NSString).lastPathComponent). "
                + "Open the other \(workbooks.count - 1) workbook(s) one at a time."
        }
    }

    /// The toolbar's live row count, or "" when nothing is open.
    public var rowSummary: String { active.map { rowSummaryText($0) } ?? "" }
}

/// The toolbar's row-count phrase: `rowText` (`web/index.html:958-963`) wrapped in
/// `pushNativeState`'s `summary` (`:1570-1589`), one decision tree, both halves.
///
/// A free function taking a `Table` rather than a method on `AppState`, so every branch is
/// reachable from a test with a planted table — "counting…" in particular cannot be produced by
/// opening a real file small enough for a test to wait on.
///
/// 🔴 **The row phrase itself is `SourceSidebar`'s `rowText`, not a second copy of it.** Task 13 and
/// Task 14 each ported `web/index.html:958-963` and landed within hours of each other, which on this
/// branch is already a named failure — see commit 3c114b4, "Two tasks wrote compactCount, and only
/// one of them was right". The toolbar's contribution is the ` · N cols · N dropped` tail; the
/// count sentence has exactly one implementation, and both suites point at it.
///
/// Digits are grouped by `SiftCore.groupDigits`, the same function the row-number gutter and the
/// CLI use. Not `NumberFormatter`: without an explicit locale the same count renders four ways.
public func rowSummaryText(_ table: SiftEngine.Table) -> String {
    var summary = "\(rowText(table)) · \(table.spec.columns.count) cols"
    if table.badRows > 0 { summary += " · \(groupDigits(String(table.badRows))) dropped" }
    return summary
}

/// Whether a path goes to the sheet picker instead of straight to `open(path:)`.
///
/// EVERY `.xlsx`/`.xlsm`, not only multi-sheet workbooks — `siftOpenPaths`
/// (`web/index.html:1533-1537`) routes on the extension alone, because which sheet a one-sheet
/// workbook contains is still a thing the user is entitled to see named before it opens.
///
/// `.xls` deliberately does not route here even though the web's regex (`/\.xlsx?$/i`) caught it:
/// the engine refuses a legacy `.xls` with a sentence explaining why, and a sheet picker failing to
/// read a file that is not a zip would replace that sentence with a worse one.
///
/// `SiftCore.xlsxExt` rather than a second list: the set the engine detects a workbook by and the
/// set the picker fires on are the same fact, and two copies is how `.xlsm` ends up in only one.
public func needsSheetPicker(_ path: String) -> Bool {
    xlsxExt.contains("." + (path as NSString).pathExtension.lowercased())
}

// MARK: - what LaunchServices hands over
//
// Pure functions here, in `SiftUI`, rather than inline in `AppDelegate`. `SiftApp` is an
// `executableTarget` and no SwiftPM test target can import one, so a decision made there is a
// decision nothing will ever check — which is precisely how `urls.map(\.path)` shipped.

/// What each URL means to the engine.
///
/// 🔴 **`URL.path` is the right accessor for a `file:` URL and the wrong one for every other
/// scheme**, and `application(_:open:)` used it on all of them. `URL.path` is documented to be the
/// path COMPONENT — so scheme, host, query and fragment are simply discarded:
/// `sift://open/Users/andrew/orders.csv` arrives as `/open/Users/andrew/orders.csv`, and
/// `https://example.com/data.csv` arrives as `/data.csv`. Both of those are perfectly plausible
/// local paths, so the best case is the engine refusing a file the user never named, and the worst
/// case is a machine where the stripped path happens to exist and Sift opens the WRONG FILE with
/// nothing on screen suggesting anything went sideways.
///
/// Anything that is not a file keeps its whole `absoluteString`, so the engine's own
/// "No such file or folder: …" names back exactly what it was handed. This is not a claim that Sift
/// can open a URL — it cannot, `openPath` stats the path — it is a claim that a refusal quotes the
/// thing that was refused.
public func openArguments(_ urls: [URL]) -> [String] {
    urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
}

/// Which of them belong in File > Open Recent: the file URLs, and nothing else.
///
/// `NSDocumentController.noteNewRecentDocumentURL` is the OS's own documents list — drawn with a
/// file icon, resolved against the filesystem, persisted across launches. A non-file URL recorded in
/// it is a menu entry that can never re-open anything.
///
/// Applied inside `AppDelegate.note(_:)` rather than at one call site, so the open panel, a Dock
/// drop, Finder "Open With" and Open Recent itself all get the same rule from the same place.
public func recentDocuments(_ urls: [URL]) -> [URL] {
    urls.filter(\.isFileURL)
}
