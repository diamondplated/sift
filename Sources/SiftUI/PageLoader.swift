/// The block pump: one fetch at a time, nearest the viewport first, results dropped if the grid
/// moved on while they were in flight.
///
/// **Single-flight, because `Task.cancel()` does not cancel an actor call.** The web version held
/// an `AbortController` per block and aborted the ones it had scrolled past (`web/index.html:809`
/// — measured there: a 60-event drag fired 78 requests and the block under the cursor queued
/// behind ones already off screen). There is no equivalent in-process: `await session.page(...)`
/// runs to completion whether or not its task is cancelled, so spawning a task per block would do
/// every query anyway and merely throw the answers away. The abort is replaced by *not starting*:
/// the loader holds a want-set and pumps it one block at a time, so a block dropped from the set
/// before its turn is never fetched at all. That is the property `request` exists to give.
///
/// **Generic over `Payload`** so the tests can drive it with plain `[[Cell]]`. `TablePage` has no
/// public initializer, so a test cannot build one; the app uses `PageLoader<TablePage>`.
@MainActor
public final class PageLoader<Payload> {
    /// Not `@Sendable`, deliberately. The closure is stored on a `@MainActor` type, called only
    /// from the MainActor, and never crosses an isolation boundary — so the annotation buys
    /// nothing, and it costs every caller that captures a `var` (which is every test here):
    /// `error: mutation of captured var 'order' in concurrently-executing code`.
    public typealias Fetch = (Int) async throws -> Payload

    /// Called on the MainActor with a block that survived the generation check.
    public var onDeliver: ((Int, Payload) -> Void)?
    /// Called on the MainActor when a fetch threw. The pump then continues to the next block —
    /// one bad page must not wedge the grid.
    public var onFailure: ((Error) -> Void)?

    /// Bumped by `invalidate()`. A delivery whose generation no longer matches is dropped: the
    /// filter, sort, staged-ness or table changed while it was in flight, so it describes rows
    /// that are no longer what the grid is showing.
    public private(set) var generation = 0

    private let fetch: Fetch
    private var wanted: [Int] = []
    private var centre: Double = 0
    /// The block the pump is awaiting right now, or nil. Kept only so `request` does not queue a
    /// second fetch of a block that is already open — the pump is serial, so the duplicate would
    /// not race, it would simply run the same query again and deliver the same rows twice.
    private var inflight: Int?
    private var pump: Task<Void, Never>?

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Replace the want-set. Nearest-to-`centre` wins, so the rows actually on screen are fetched
    /// before the overscan around them.
    ///
    /// `centre` is in blocks, not rows — the viewport's midpoint divided by the page size, matching
    /// `neededBlocks()`'s `(state.firstRow + visibleRows() / 2) / BLOCK`.
    public func request(blocks: [Int], centre: Double) {
        self.centre = centre
        for b in blocks where !wanted.contains(b) && b != inflight { wanted.append(b) }
        wanted.removeAll { !blocks.contains($0) }
        startPumpIfIdle()
    }

    /// The rows on screen no longer describe what is being fetched. Everything queued is dropped,
    /// and anything already in flight will fail its generation check on the way back.
    ///
    /// `inflight` is cleared too: the open fetch's answer is about to be discarded, so the block it
    /// covers is once again unfetched, and a `request` that still wants it has to be allowed to
    /// re-queue it. Leaving it set would make that block the one cell range in the file that can
    /// never load after a sort.
    public func invalidate() {
        generation += 1
        wanted.removeAll()
        inflight = nil
    }

    private func startPumpIfIdle() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while let self, let block = self.takeNearest() {
                self.inflight = block
                let stamp = self.generation
                do {
                    let payload = try await self.fetch(block)
                    // Not "cancelled" — `Task.cancel()` does not stop an actor call, so the work
                    // has already happened. This only stops it being shown for a spec that is no
                    // longer on screen.
                    if stamp == self.generation { self.onDeliver?(block, payload) }
                } catch {
                    if stamp == self.generation { self.onFailure?(error) }
                }
                self.inflight = nil
            }
            self?.pump = nil
        }
    }

    /// The wanted block closest to the viewport centre, removed from the set.
    private func takeNearest() -> Int? {
        guard let best = wanted.min(by: {
            abs(Double($0) - centre) < abs(Double($1) - centre)
        }) else { return nil }
        wanted.removeAll { $0 == best }
        return best
    }

    /// Test seam: awaits the pump so a test can assert on what was fetched. `internal`, reached
    /// through `@testable import` — it exists for the suite and has no place in the app.
    func drainForTest() async {
        await pump?.value
    }
}
