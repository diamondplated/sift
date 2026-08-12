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

    /// The SQL console's text. Written by `typeSQL` (the user) or `mirrorRenderedSQL` (the app);
    /// `sqlOwned` is which of the two last touched it, and the console's status line is that.
    public private(set) var sqlText = ""
    public private(set) var sqlOwned = false

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
    /// SQL mode's extent, grown one delivered block at a time — see `sqlModeExtent`. `nil` outside
    /// SQL mode, which is what hands `scrollExtent` back to the table's own row count.
    private var sqlExtent: Int?

    /// Rows of overscan either side of the viewport — `OVERSCAN` (`web/index.html:423`).
    private let overscan = 8

    public init(session: Session, table: SiftEngine.Table) {
        self.session = session
        self.name = table.name
        self.table = table
        self.columns = table.spec.columns
        loader = PageLoader<TablePage> { [weak self] block in
            guard let self else { throw CancellationError() }
            return try await self.fetchBlock(block)
        }
        loader.onDeliver = { [weak self] block, page in self?.deliver(block, page) }
    }

    // MARK: - what the grid draws

    /// Rows the scroll bar may reach. `Table.scrollableRows` — the estimate until the exact count
    /// lands, capped at what a sort actually materialized (see its doc comment for both halves).
    ///
    /// In SQL mode `sqlExtent` takes over, because nothing counted the user's result and counting it
    /// would mean running their query a second time — see `sqlModeExtent`.
    public var scrollExtent: Int { extentOverride ?? sqlExtent ?? table.scrollableRows ?? 0 }

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

    /// One block, from whichever query is driving the grid.
    ///
    /// 🔴 In SQL mode that is the user's own text, re-run at this offset — `fetchBlock`'s own branch
    /// (`web/index.html:834-838`), which posts to `/api/sql` for every block and not just the first.
    /// It goes through `Session.runSQL`, so **the SELECT-only gate runs again on every block**;
    /// nothing here validates, unwraps or builds SQL of its own.
    ///
    /// **`Session.page` would also page a SQL-mode table** — it has its own `wrapUserSQL` branch —
    /// and on a query that has already been accepted the two are indistinguishable. The difference
    /// is the gate: `page` wraps `sqlText` without re-asserting it, so text that reached the field
    /// by any route other than `runSQL` would execute on the strength of the wrap alone. Re-gating
    /// stored SQL before wrapping it is what `export` does with the same field, for the same reason,
    /// and this keeps the paging path on that side of the line.
    ///
    /// The text comes from `table.sqlText` — what was actually RUN — and deliberately not from the
    /// console's box, which the user may have edited since (the web read the live textarea here and
    /// paged block 3 of a query it had never run block 0 of).
    ///
    /// Not `private`: the suite calls it directly to prove the gate is on every block, which is not
    /// reachable through the pump — a block that throws is dropped by the loader.
    func fetchBlock(_ block: Int) async throws -> TablePage {
        if table.sqlMode, let sql = table.sqlText {
            return try await session.runSQL(name, sql: sql, offset: block * pageRows, limit: pageRows)
        }
        return try await session.page(name, offset: block * pageRows, limit: pageRows)
    }

    private func deliver(_ block: Int, _ page: TablePage) {
        // Taken from the delivered page rather than the spec because in SQL mode the user's query
        // decides what comes back; for everything else the two agree, so there is no mode branch
        // here. `TablePage.ColumnInfo`'s memberwise init is internal, so it cannot be stored out
        // here; `SiftCore.Column` recomputes `kind` through the same `kind(of:)` the engine used,
        // so the value is identical.
        columns = page.columns.map { Column(name: $0.name, type: $0.type) }
        cache.store(page.rows, at: block)
        if table.sqlMode {
            sqlExtent = sqlModeExtent(sqlExtent ?? 0, block: block, rows: page.rows.count)
        }
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

    // MARK: - SQL mode

    /// Run the console's text and page the result from row 0.
    ///
    /// 🔴 **The SELECT-only gate is `Session.runSQL`'s and is not repeated, pre-checked or
    /// re-worded here.** A second, weaker gate in the UI is how a blocklist ends up being the thing
    /// people trust; the engine's is the one that has been attacked. What reaches the engine is
    /// exactly what the user typed, and what the user sees is exactly the sentence it threw.
    ///
    /// The query runs BEFORE anything on screen changes, so a refused statement leaves the table the
    /// user was looking at exactly where it was. The web wiped the grid first
    /// (`web/index.html:1811-1812`) and a refusal left an empty one sitting behind the banner.
    public func runSQL() async throws {
        do {
            let page = try await session.runSQL(name, sql: sqlText, offset: 0, limit: pageRows)
            // `resetGrid()` (`web/index.html:1812`), now that there is a result to put in its place.
            loader.invalidate()
            cache.removeAll()
            // `runSQL` already set `sqlMode`/`sqlText` on the engine's copy — read it back rather
            // than mirroring the two flags here, so `table` stays the single authority for both
            // (see its declaration) and `deliver` below sees SQL mode.
            table = try await session.table(name)
            sqlExtent = 0
            deliver(0, page)
            resetViewport()
        } catch {
            // 🔴 A prepare failure is NOT a guard rejection. `Session.runSQL` flips `sqlMode`/
            // `sqlText` before it runs the query, so `SELECT * FROM nonexistent` — legitimate SQL
            // against a table the user has not opened — has already moved the engine, while a
            // refusal never touched it. Re-read instead of guessing which of the two just happened.
            table = (try? await session.table(name)) ?? table
            if table.sqlMode {
                // The engine moved: every block from here is fetched through SQL that just failed,
                // so the rows still on screen belong to a query this table is no longer showing.
                // An empty grid behind the banner is the honest state; the previous file's rows
                // under the user's failed SQL are not.
                loader.invalidate()
                cache.removeAll()
                sqlExtent = 0
                resetViewport()
            }
            throw error
        }
    }

    /// Back to the filters, and the ONLY way back.
    ///
    /// 🔴 Taking over the box is a one-way door: no attempt is made to parse SQL back into filters
    /// and sort (`web/index.html:1768-1769`), because round-tripping SQL→filters is where tools like
    /// this go to die. The status line says so in words the moment the user types, and this is the
    /// exit it is pointing at.
    public func exitSQLMode() async throws {
        table = try await session.exitSQLMode(name)
        // Re-mirrored rather than cleared — `$("sqlbox").value = r.sql` (`web/index.html:1761`).
        // The box goes back to showing the filter-derived SQL, and the status line back to saying
        // it is a mirror.
        sqlText = try await session.renderedSQL(name)
        sqlOwned = false
        sqlExtent = nil
        loader.invalidate()
        cache.removeAll()
        try await loadFirstPage()
        resetViewport()
    }

    /// Put the rendered SQL in the box without claiming it — `loadTable`'s
    /// `$("sqlbox").value = d.sql` (`web/index.html:552`).
    ///
    /// In SQL mode `renderedSQL` hands back the user's own text, so `sqlOwned` follows the table
    /// rather than being forced false: re-selecting a tab that is in SQL mode must not tell the user
    /// their query mirrors filters it has nothing to do with.
    public func mirrorRenderedSQL() async throws {
        sqlText = try await session.renderedSQL(name)
        sqlOwned = table.sqlMode
    }

    /// The user typed. Claims the box, which is what flips the status line.
    ///
    /// 🔴 Claimed HERE rather than by observing `sqlText` change, because `mirrorRenderedSQL` writes
    /// to it too. The web told the two apart with the `input` event, which does not fire on a
    /// programmatic assignment (`web/index.html:1767`); a SwiftUI `onChange` cannot, and a console
    /// that claimed itself on the mirror would show "your SQL — filters and header controls are
    /// frozen" over a box the user has never touched.
    public func typeSQL(_ text: String) {
        guard text != sqlText else { return }
        sqlText = text
        sqlOwned = true
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

/// SQL mode's scroll extent after `rows` arrived as block `block` — `fetchBlock`'s three-way
/// (`web/index.html:846-855`), minus the branch that does not apply because a SQL page carries no
/// total (`Session.runSQL` sets `total.value` to `nil` on purpose).
///
/// 🔴 **A SQL result has no exact count, so the extent GROWS rather than being known.** Nothing
/// counted it, and counting it would mean running the user's query twice. So each delivered block
/// says one of two things: a SHORT block is the end of the result and pins the total exactly, while
/// a FULL one proves only that at least one more row exists — hence `+ 1`, which is what keeps the
/// scroll bar reachable far enough to ask for the next block and find out.
///
/// `max` on the growing branch and NOT on the pinning branch, both deliberately: blocks arrive
/// nearest-the-viewport-first, so a full block that lands after a short one must not re-grow an
/// extent the end of the result already settled.
func sqlModeExtent(_ current: Int, block: Int, rows: Int) -> Int {
    rows < pageRows ? block * pageRows + rows : max(current, (block + 1) * pageRows + 1)
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
