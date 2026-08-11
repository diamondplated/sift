import DuckDBKit
import Foundation
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

    public func open(path: String, sheet: String? = nil) async {
        do {
            let t = try await session.openPath(path, sheet: sheet)
            await refresh()
            activeName = t.name
        } catch {
            banner = error.localizedDescription
        }
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
}

// TASK 5 replaces this.
//
// Everything one open table needs *for Task 1 only*: the columns and the first page, so the crude
// grid in RootView has something to draw. Task 5 replaces it outright with the real thing (page
// cache, extent, spec, panels) — do not grow it here, and do not leave two.
@MainActor
@Observable
public final class TableViewModel {
    public let name: String
    /// The catalog's latest copy of this table, pushed in by `AppState.refresh()`. The single
    /// authority for `profiling`, `counting`, `rowCount` and the rest — no mirrored copies.
    public private(set) var table: SiftEngine.Table
    public private(set) var columns: [Column] = []
    public private(set) var firstPage: [[Cell]] = []

    private let session: Session

    public init(session: Session, table: SiftEngine.Table) {
        self.session = session
        self.name = table.name
        self.table = table
    }

    public func apply(_ table: SiftEngine.Table) { self.table = table }

    public func loadFirstPage() async throws {
        let page = try await session.page(name, offset: 0, limit: pageRows)
        // `TablePage.ColumnInfo`'s memberwise init is internal, so it cannot be stored or rebuilt
        // out here; `SiftCore.Column` has a public one and recomputes `kind` through the same
        // `kind(of:)` the engine used, so the value is identical.
        columns = page.columns.map { Column(name: $0.name, type: $0.type) }
        firstPage = page.rows
    }
}
