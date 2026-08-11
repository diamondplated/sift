import Testing
import DuckDBKit
@testable import SiftUI

/// Holds a fake fetch open, and lets the test know it is open. `arrive()` is called from inside
/// the fetch; `waitUntilInside()` returns once it has been; `release()` lets it finish.
///
/// 🔴 **This exists because a `Task {}` created on the MainActor cannot start before the next
/// suspension point.** Two synchronous `request(...)` calls in a row therefore never overlap, and
/// a test that assumes the first block is "in flight" right after a bare `request` is asserting on
/// something that has not happened — which is how the first draft of this file recorded the wrong
/// fetch order in one test and passed *vacuously* in another (`invalidate()` emptied the want-set
/// before the pump ever ran, so nothing was in flight, nothing was delivered, and deleting the
/// generation guard entirely left it green). Every test below that needs a fetch to be open waits
/// here until it really is. The wait fails by timing out, never by reading a value that was never
/// going to change.
///
/// Everything is `@MainActor`, so a bounded `Task.yield()` spin is enough — no continuations, no
/// second actor.
@MainActor
final class FetchGate {
    private var inside = false
    private var opened = false

    func arrive() async { inside = true; await spin { self.opened } }
    func waitUntilInside() async { await spin { self.inside } }
    func release() { opened = true }

    private func spin(until cond: () -> Bool) async {
        for _ in 0..<100_000 {
            if cond() { return }
            await Task.yield()
        }
        Issue.record("FetchGate timed out — the pump never reached the fetch")
    }
}

// MARK: - PageLoader

@MainActor
@Test func theLoaderFetchesTheBlockNearestTheViewportFirst() async {
    var order: [Int] = []
    let loader = PageLoader<[[Cell]]> { block in
        order.append(block)
        return [[.int(Int64(block))]]
    }
    loader.request(blocks: [0, 1, 2, 3, 4], centre: 3.0)
    await loader.drainForTest()
    #expect(order == [3, 2, 4, 1, 0] || order == [3, 4, 2, 1, 0],
            "nearest-first; ties either side of the centre may go either way")
    #expect(order.first == 3)
}

@MainActor
@Test func aBlockScrolledPastBeforeItsTurnIsNeverFetched() async {
    var fetched: [Int] = []
    let gate = FetchGate()
    let loader = PageLoader<[[Cell]]> { block in
        fetched.append(block)
        if block == 0 { await gate.arrive() }
        return [[.int(Int64(block))]]
    }
    loader.request(blocks: [0, 1, 2], centre: 0)
    await gate.waitUntilInside()             // block 0 really is in flight now
    loader.request(blocks: [9], centre: 9)   // the user scrolled far away
    gate.release()
    await loader.drainForTest()
    #expect(fetched == [0, 9], "1 and 2 were dropped from the want-set, never fetched")
}

@MainActor
@Test func aDeliveryFromAPreviousGenerationIsDiscarded() async {
    var delivered: [Int] = []
    let gate = FetchGate()
    let loader = PageLoader<[[Cell]]> { block in
        if block == 0 { await gate.arrive() }
        return [[.int(Int64(block))]]
    }
    loader.onDeliver = { block, _ in delivered.append(block) }
    loader.request(blocks: [0], centre: 0)
    await gate.waitUntilInside()   // block 0 is OUT of `wanted` and mid-fetch...
    loader.invalidate()            // ...so the generation check is the ONLY thing left
    gate.release()
    await loader.drainForTest()
    #expect(delivered.isEmpty)
}

@MainActor
@Test func theBlockAlreadyInFlightIsNotQueuedAgain() async {
    var fetched: [Int] = []
    let gate = FetchGate()
    let loader = PageLoader<[[Cell]]> { block in
        fetched.append(block)
        if block == 0 { await gate.arrive() }
        return [[.int(Int64(block))]]
    }
    loader.request(blocks: [0, 1], centre: 0)
    await gate.waitUntilInside()
    // The caller re-asks for the same blocks — which is what every scroll tick does, since block 0
    // is not in the cache yet and so is still "needed".
    loader.request(blocks: [0, 1], centre: 0)
    gate.release()
    await loader.drainForTest()
    #expect(fetched == [0, 1], "block 0 was open, not missing — re-asking must not re-run its query")
}

@MainActor
@Test func aBlockStillWantedAfterInvalidateIsFetchedAgain() async {
    var fetched: [Int] = []
    var delivered: [Int] = []
    let gate = FetchGate()
    let loader = PageLoader<[[Cell]]> { block in
        fetched.append(block)
        if fetched.count == 1 { await gate.arrive() }
        return [[.int(Int64(block))]]
    }
    loader.onDeliver = { block, _ in delivered.append(block) }
    loader.request(blocks: [0], centre: 0)
    await gate.waitUntilInside()
    loader.invalidate()                     // the sort changed: the open answer is now wrong
    loader.request(blocks: [0], centre: 0)  // ...but the user is still looking at those rows
    gate.release()
    await loader.drainForTest()
    #expect(fetched == [0, 0], "the discarded fetch leaves block 0 unfetched — it must re-run")
    #expect(delivered == [0], "and exactly the second, current-generation answer reaches the grid")
}

@MainActor
@Test func aFailedBlockIsReportedAndThePumpKeepsGoing() async {
    struct Boom: Error {}
    var fetched: [Int] = []
    var delivered: [Int] = []
    var failures = 0
    let loader = PageLoader<[[Cell]]> { block in
        fetched.append(block)
        if block == 0 { throw Boom() }
        return [[.int(Int64(block))]]
    }
    loader.onDeliver = { block, _ in delivered.append(block) }
    loader.onFailure = { _ in failures += 1 }
    loader.request(blocks: [0, 1], centre: 0)
    await loader.drainForTest()
    #expect(fetched == [0, 1], "one bad page must not wedge the grid")
    #expect(delivered == [1])
    #expect(failures == 1)
}

// MARK: - PageCache

@MainActor
@Test func theCacheEvictsInInsertionOrderAndReadingABlockDoesNotSaveIt() {
    let cache = PageCache(limit: 3)
    for b in 0..<3 { cache.store([[.int(Int64(b))]], at: b) }
    _ = cache[0]   // an LRU would promote block 0 here; FIFO does not
    cache.store([[.int(9)]], at: 3)
    #expect(cache[0] == nil, "FIFO: the first block stored is the first evicted, read or not")
    #expect(cache[1] != nil)
    #expect(cache[3] != nil)
}

@MainActor
@Test func reStoringABlockMovesItToTheTailAndKeepsTheCacheFull() {
    let cache = PageCache(limit: 3)
    for b in 0..<3 { cache.store([[.int(Int64(b))]], at: b) }
    cache.store([[.int(11)]], at: 1)   // a re-store IS a new insertion
    cache.store([[.int(13)]], at: 3)
    #expect(cache[0] == nil, "0 is still the oldest insertion")
    #expect(cache[1] == [[.int(11)]], "1 was re-inserted, so it outlives 0 — and holds the new rows")
    #expect(cache[2] != nil, "three blocks stay live; a duplicate order entry would have cost one")
    #expect(cache[3] != nil)
}

@MainActor
@Test func removeAllForgetsTheInsertionOrderToo() {
    let cache = PageCache(limit: 3)
    for b in 0..<3 { cache.store([[.int(Int64(b))]], at: b) }
    cache.removeAll()
    #expect(cache[1] == nil)
    // Re-filling after a spec change re-fetches the same block numbers. If `removeAll` had left
    // the insertion order behind, this store would push the list to four entries and evict — with
    // the block just stored first in line.
    cache.store([[.int(99)]], at: 0)
    #expect(cache[0] == [[.int(99)]])
}
