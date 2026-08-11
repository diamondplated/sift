import DuckDBKit
import Observation
import SiftCore
import SiftEngine

/// Everything one open table needs on screen: the columns, the block pump feeding a bounded row
/// cache, the scroll extent, the spec, and the profile the header and inspector are built from.
///
/// It owns no rows of its own — `PageLoader` fetches, `PageCache` holds, and `table` is whatever
/// `AppState.refresh()` last pushed in. The three things it decides are *which* blocks are wanted
/// (`ensureVisible`), *when* what it holds stops describing the table (`apply`, `setSpec`), and
/// *whether* to speculatively ask for a profile (`kickProfile`).
///
/// **Ceiling: three callback closures, and no more.** `onProfileArrived`, `onBlockDelivered` and
/// `onViewportReset` are the limit. A fourth is the signal to convert all of them into one small
/// observer protocol the grid conforms to — four separate closures installed in `makeNSView` is the
/// point where a missed installation stops being obvious. Written down so the fourth one forces the
/// decision rather than arriving unnoticed.
@MainActor
@Observable
public final class TableViewModel {
    /// What the grid should draw at a row: rows it has, or the placeholder it draws while the block
    /// covering that row is on its way. `Equatable` because the grid tests compare against
    /// `.pending`, and `Cell` already is.
    public enum RowSlot: Equatable {
        case loaded([Cell])
        case pending
    }

    public let name: String
    /// The catalog's latest copy of this table, pushed in by `AppState.refresh()`. The single
    /// authority for `profiling`, `counting`, `rowCount`, `staged` and the rest — no mirrored
    /// copies, which is why the poll predicate reads `Table.profiling` and nothing here shadows it.
    public private(set) var table: SiftEngine.Table
    public private(set) var columns: [Column] = []
    /// Per-column stats, once a profile has landed. Empty until then: the header falls back to a
    /// fixed width and the Schema tab has nothing to show, which is exactly what shipped before
    /// anything in the app kicked a profile at all.
    public private(set) var profile: [ColumnProfile] = []

    /// Called when a profile lands. The grid re-measures its column widths from `max_len`; the
    /// inspector re-renders. (The web's `loadProfile()` did the same by calling `renderHead()`.)
    public var onProfileArrived: (() -> Void)?
    /// Called with a block index whose rows just arrived, so the grid can
    /// `reloadData(forRowIndexes:columnIndexes:)` for exactly those rows rather than everything.
    public var onBlockDelivered: ((Int) -> Void)?
    /// Called when the viewport has been sent back to row 0 by a spec change — the grid scrolls the
    /// `NSTableView` to the top. See `resetViewport`.
    public var onViewportReset: (() -> Void)?

    private let session: Session
    private let cache = PageCache()
    /// `!` rather than an optional: the fetch closure captures `self`'s `session` and `name`, so it
    /// cannot be built before `init` has stored them, and every use after `init` is non-nil.
    private var loader: PageLoader<TablePage>!
    /// Re-entrancy guard for the speculative kick, and nothing more — it makes no claim about what
    /// the engine is doing internally. `Table.profiling` is that, and it is the engine's.
    private var profileTask: Task<Void, Never>?

    private var firstRow = 0
    private var rowsOnScreen = 1
    private var extentOverride: Int?

    /// Rows of overscan either side of the viewport — `OVERSCAN` (`web/index.html:423`).
    private let overscan = 8

    public init(session: Session, table: SiftEngine.Table) {
        self.session = session
        self.name = table.name
        self.table = table
        self.columns = table.spec.columns
        loader = PageLoader<TablePage> { [session, name] block in
            try await session.page(name, offset: block * pageRows, limit: pageRows)
        }
        loader.onDeliver = { [weak self] block, page in self?.deliver(block, page) }
    }

    // MARK: - what the grid draws

    /// Rows the scroll bar may reach. `Table.scrollableRows` — the estimate until the exact count
    /// lands, capped at what a sort actually materialized (see its doc comment for both halves).
    public var scrollExtent: Int { extentOverride ?? table.scrollableRows ?? 0 }

    public func rowSlot(at row: Int) -> RowSlot {
        let block = row / pageRows
        guard let rows = cache[block], case let index = row - block * pageRows, index < rows.count
        else { return .pending }
        return .loaded(rows[index])
    }

    /// The viewport moved. Requests the blocks covering it plus `overscan` rows either way,
    /// nearest-to-centre first — `neededBlocks()` (`web/index.html:800-807`), with the loader doing
    /// the sorting.
    public func ensureVisible(firstRow: Int, rowsOnScreen: Int) {
        self.firstRow = max(0, firstRow)
        self.rowsOnScreen = max(1, rowsOnScreen)
        requestCurrentViewport()
    }

    /// Back to row 0, and say so — the grid scrolls its `NSTableView` to the top when
    /// `onViewportReset` fires. Every spec change ends here; see `applySpec`.
    public func resetViewport() {
        firstRow = 0
        onViewportReset?()
        requestCurrentViewport()
    }

    private func requestCurrentViewport() {
        let first = max(0, firstRow - overscan) / pageRows
        let last = (firstRow + rowsOnScreen + overscan) / pageRows
        // Blocks already held are not re-requested: every scroll tick re-asks for the whole
        // viewport, and `PageLoader` has no cache of its own to notice that it just fetched them.
        // (`ensureBlocks`'s own `!state.blocks.has(b)`, web/index.html:818.)
        let blocks = (first...last).filter { cache[$0] == nil }
        loader.request(
            blocks: blocks, centre: (Double(firstRow) + Double(rowsOnScreen) / 2) / Double(pageRows)
        )
    }

    private func deliver(_ block: Int, _ page: TablePage) {
        // Taken from the delivered page rather than the spec because in SQL mode the user's query
        // decides what comes back; for everything else the two agree, so there is no mode branch
        // here. `TablePage.ColumnInfo`'s memberwise init is internal, so it cannot be stored out
        // here; `SiftCore.Column` recomputes `kind` through the same `kind(of:)` the engine used,
        // so the value is identical.
        columns = page.columns.map { Column(name: $0.name, type: $0.type) }
        cache.store(page.rows, at: block)
        onBlockDelivered?(block)
    }

    // MARK: - loading

    /// Fetch block 0 and kick the profile, in that order — the web's `fetchBlock(0)` then
    /// `loadProfile()` (`web/index.html:551-557`).
    ///
    /// Fetched directly rather than through the loader because this is the one page whose failure
    /// the user must see: it is all that stands between them and an empty window, so it throws and
    /// the caller banners it. Every later block goes through the pump.
    public func loadFirstPage() async throws {
        let stamp = loader.generation
        let page = try await session.page(name, offset: 0, limit: pageRows)
        // The same generation check every pumped block gets. Nothing else would apply it to this
        // one, and a filter applied while the first page was in flight would otherwise plant the
        // unfiltered rows into a cache that had just been cleared for exactly that reason.
        guard stamp == loader.generation else { return }
        deliver(0, page)
        kickProfile()
    }

    /// The catalog's newest copy of this table.
    ///
    /// **A staged or reopened table drops the cache.** The web did this on the `staged` SSE event
    /// (`web/index.html:1838-1843`): the relation underneath is swapped view→native table, so every
    /// cached row describes something that no longer exists. Polling replaced SSE, so `apply` is the
    /// only place that can see the edge — hence the comparison against the previous value rather
    /// than a notification.
    public func apply(_ next: SiftEngine.Table) {
        let swapped = next.staged != table.staged || next.openedAt != table.openedAt
        table = next
        if !next.sqlMode { columns = next.spec.columns }
        guard swapped else { return }
        // The relation underneath changed identity — a staged copy was published or dropped, or the
        // table was closed and reopened under the same name. Cached rows describe the old relation,
        // and the engine dropped its own profile with them (`applyStaged`).
        loader.invalidate()
        cache.removeAll()
        profile = []
        requestCurrentViewport()
        kickProfile()
    }

    // MARK: - filters and sort

    /// Both `throws`, deliberately, though the only way `setSpec` can fail is a column the table
    /// does not have. There is nowhere inside a view model for an error to go that anyone would
    /// ever read, and a swallowed one leaves the user's click doing nothing at all — the same
    /// reason `loadFirstPage` throws and `RootView` banners it.
    public func setSort(_ sort: [QuerySpec.SortTerm]) async throws {
        try await applySpec(filters: table.qspec.filters, sort: sort)
    }

    public func setFilters(_ filters: [Filter]) async throws {
        try await applySpec(filters: filters, sort: table.qspec.sort)
    }

    private func applySpec(filters: [Filter], sort: [QuerySpec.SortTerm]) async throws {
        table = try await session.setSpec(name, filters: filters, sort: sort)
        // In flight for the old spec, and about to be wrong: `invalidate` is what stops it landing.
        loader.invalidate()
        cache.removeAll()
        // Awaited, and before the reset, for two reasons: it is the new spec's first rows, and
        // `page` is also what recomputes `filteredCount` — which `setSpec` just cleared, so the
        // `Table` it returned still reports the UNFILTERED count.
        try await loadFirstPage()
        // …so this is the first copy that knows the filter matched 12 rather than 1,000,000. An
        // extent taken from the one above would have promised the old number until the next poll.
        table = try await session.table(name)
        // 🔴 Row 0, NOT "wherever the thumb was". `applySpec` calls `resetGrid()` in the web build
        // (`web/index.html:585-592`), which sets `firstRow = 0` and `scrollTop = 0`. A filter that
        // cuts 1,000,000 rows to 12 leaves the thumb parked past the end of the data, asking for
        // blocks that no longer exist.
        resetViewport()
    }

    // MARK: - profiling

    /// Fired after the first block lands, and again after every spec change. The engine's
    /// `runAfterOpen` deliberately does NOT do this (its own doc comment says so) and `merge` is the
    /// only other caller in the tree — so without this the grid never gets column widths, carets,
    /// distinct counts, missing bars or the Schema tab's contents.
    ///
    /// 🔴 **`profileIfCheap`, never `computeProfile`.** This is a profile nobody asked for, and the
    /// gate (`SiftCore.shouldProfileEagerly`: 200 MB, or staged, or columnar) is what stops it
    /// `SUMMARIZE`ing a 30 GB CSV that Python deliberately skips. The speculative entry point IS the
    /// gated one, so the gate cannot be forgotten here; a table that fails it simply has no profile
    /// until the user opens a panel, and `profileOf` stays ungated because a panel the user opened
    /// is not speculative.
    ///
    /// Fire-and-forget, and single-flight: `profileTask` is the re-entrancy guard, and the engine
    /// coalesces on top of it, so a kick and a panel's `profileOf` moments later share one
    /// `SUMMARIZE`.
    ///
    /// Not `private`: the suite calls it twice in a row to pin `profileTask`, which is only
    /// reachable synchronously — `loadFirstPage` suspends before it kicks, and a test that has
    /// already suspended cannot prove a re-entrancy guard.
    func kickProfile() {
        guard profileTask == nil, profile.isEmpty else { return }
        profileTask = Task { [weak self] in
            guard let self else { return }
            let profiled = (try? await self.session.profileIfCheap(self.name)) ?? false
            // Read back the CATALOG's copy rather than the job's own return value: `applyProfile`
            // is the single authority on whether a result belongs to the table now open under this
            // name, and a table that moved underneath this kick must not have another file's
            // numbers drawn over it. A gate refusal (`profiled == false`) leaves `profile` empty
            // and reads exactly right: no profile until the user opens a panel.
            if profiled, let t = try? await self.session.table(self.name), t.openedAt == self.table.openedAt {
                self.profile = t.profile ?? []
            }
            self.profileTask = nil
            if !self.profile.isEmpty { self.onProfileArrived?() }
        }
    }

    // MARK: - test seams
    //
    // `internal`, reached through `@testable import`. They exist for the suite and have no place in
    // the app.

    /// Awaits the block pump, so a test can assert on what arrived rather than on when.
    func drainForTest() async {
        await loader.drainForTest()
        await profileTask?.value
    }

    /// A scroll extent without a file behind it — Task 6's grid geometry over 100M rows without
    /// 100M rows. `nil` puts the real table back in charge.
    func overrideScrollExtentForTest(_ rows: Int?) { extentOverride = rows }
}

/// The sentence for a `Table.RowsBasis`, shown under the row count.
///
/// Lives here rather than in `SiftEngine` because the engine has two consumers — this app and the
/// `sift` CLI — and they want different wording. `summary()`'s three branches, verbatim.
public func rowsBasisText(_ basis: SiftEngine.Table.RowsBasis) -> String {
    switch basis {
    case .counted: return "counted exactly"
    case .estimated(let how): return how
    case .pending: return "counting…"
    }
}
