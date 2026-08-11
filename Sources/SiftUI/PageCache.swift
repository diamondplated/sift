import DuckDBKit

/// The decoded rows of the blocks the grid is currently willing to keep, bounded to `limit`.
///
/// A "block" is `SiftEngine.pageRows` rows — the engine's own page size, used as the cache key's
/// unit so a block boundary and a `Session.page` boundary can never drift apart. There is
/// deliberately no second page-size constant in this file; the block *index* is all the cache
/// knows, and multiplying it back into a row offset is the caller's job.
///
/// **Eviction is FIFO by insertion, not LRU, and that is deliberate.** The shipping web grid
/// pushes the block onto `state.order` when it is stored and shifts the oldest off when the list
/// passes `MAX_BLOCKS` (`web/index.html:423`, `web/index.html:826-830`); nothing touches a block
/// on read. Ported as-is rather than "fixed" into an LRU, because with nearest-first fetching
/// (`PageLoader`) insertion order already tracks the viewport: blocks arrive in the order the
/// viewport asked for them. A read-touch would do the opposite of what it looks like — it would
/// keep alive a block the user has just scrolled *away* from (the one still on screen while the
/// new rows load) at the expense of one they are about to reach.
///
/// 24 blocks is 12,000 rows. The bound exists because a long scroll through a 50M-row file would
/// otherwise hold every row it ever touched.
@MainActor
public final class PageCache {
    private var blocks: [Int: [[Cell]]] = [:]
    /// Insertion order, oldest first. One entry per live block — see `store`.
    private var order: [Int] = []
    private let limit: Int

    /// - Parameter limit: how many blocks to keep. Defaults to the web grid's `MAX_BLOCKS`.
    public init(limit: Int = 24) {
        self.limit = limit
    }

    /// The block's rows, or nil if it was never stored or has been evicted. **Reading does not
    /// extend a block's life** — see the type's note on FIFO.
    public subscript(block: Int) -> [[Cell]]? { blocks[block] }

    /// Store a block, evicting the oldest insertions until the cache is back within `limit`.
    ///
    /// Re-storing a block already held moves it to the tail rather than appending a second entry
    /// for it: a re-store *is* a new insertion, and it is the only case the web version gets wrong
    /// — there, the duplicate entry in `state.order` is shifted off later and deletes a block that
    /// the rest of `order` still claims is live, leaving the cache holding fewer than `MAX_BLOCKS`
    /// blocks. (Its `if (old !== b)` guard is what keeps that from deleting the block outright.)
    /// Same FIFO order, one fewer way to be wrong.
    public func store(_ rows: [[Cell]], at block: Int) {
        if blocks.updateValue(rows, forKey: block) != nil {
            order.removeAll { $0 == block }
        }
        order.append(block)
        while order.count > limit {
            blocks.removeValue(forKey: order.removeFirst())
        }
    }

    /// Drop everything. Called when the rows on screen stop describing what the cache holds — a
    /// filter, a sort, a staging change or a different table — alongside `PageLoader.invalidate()`.
    public func removeAll() {
        blocks.removeAll()
        order.removeAll()
    }
}
