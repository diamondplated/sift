import Testing
@testable import SiftUI

// The §13a busy overlay's timer, and the one decision above it.
//
// 🔴 **Every test here builds `BusyState(delay: .milliseconds(10))`, never the default.** A test
// that really slept past the shipped 400 ms would add most of a second to a parallel suite to prove
// a timer it can prove in 10 ms, and a test that waited on the *real* deadline is a flake the
// moment the machine is busy. `theShippedDelayIsStill400ms` is what stops that seam quietly
// becoming a different product decision — it is the only test that mentions 400 at all, and it
// never sleeps.
//
// 🔴 And no test here sleeps for a fixed span and then asserts. MEASURED, writing them that way
// first: `Task.sleep(80ms)` then `#expect(busy.visible)` failed in the full suite and passed on its
// own — the timer is `MainActor`-bound and 107 parallel tests, most of them driving an engine from
// the `MainActor`, starve it for far longer than the delay. `waitFor` polls for the signal instead,
// so the test fails by timing out rather than by reading a value that had not been written yet.

@MainActor
@Test func aFetchThatFinishesInsideTheDelayNeverDrawsAnything() async throws {
    let busy = BusyState(delay: .milliseconds(10))
    busy.begin("Loading rows…")
    // Synchronously false: the whole point of the delay is that an ordinary page — which comes back
    // in single-digit milliseconds — never flashes a scrim over the grid.
    #expect(busy.visible == false, "the overlay appeared the instant the fetch started")
    busy.end()
    // Inverted `waitFor`: it returns as soon as the condition holds, so a timer that survived
    // `end()` trips this in milliseconds, while the correct implementation pays the full window.
    // A fixed sleep could not tell "did not fire" from "has not been scheduled yet".
    #expect(
        await waitFor(0.5, { busy.visible }) == false, "the cancelled timer still fired after end()")
}

@MainActor
@Test func workOutstandingPastTheDelayRaisesTheOverlay() async throws {
    let busy = BusyState(delay: .milliseconds(10))
    busy.begin("Loading rows…")
    // 🔴 `await` the timer this `begin` armed, rather than polling a clock for its effect. Both
    // halves are asserted — that a timer exists at all, and that its firing raises the overlay —
    // and neither depends on when the `MainActor` gets around to it. The polling version of this
    // line went red on CI with nothing wrong: the runner has two cores and most of the 919 tests
    // drive an engine from the `MainActor`, so the five-second deadline was reachable by
    // contention alone. See `BusyState.timer`.
    let armed = try #require(busy.timer, "begin() armed no timer, so nothing was ever going to fire")
    await armed.value
    #expect(busy.visible, "the timer fired without raising the overlay")
    #expect(busy.message == "Loading rows…")
}

@MainActor
@Test func aSecondBeginWhileVisibleSwapsTheMessageWithoutBlinkingTheOverlay() async throws {
    let busy = BusyState(delay: .milliseconds(10))
    busy.begin("Loading rows…")
    // Same seam as above: this test is about the *second* begin, so getting to a visible overlay
    // must not be able to fail for timing reasons of its own.
    await (try #require(busy.timer, "begin() armed no timer")).value
    #expect(busy.visible, "nothing to replace if the overlay never came up")

    busy.begin("Sorting 1,000,000 rows…")
    // 🔴 Asserted SYNCHRONOUSLY, and that is the whole test. An implementation that cleared
    // `visible` and re-armed the timer reads false right here, and the scrim would blink off and
    // back on between two consecutive blocks of the same scroll.
    #expect(busy.visible, "the overlay was torn down and rebuilt instead of relabelled")
    #expect(busy.message == "Sorting 1,000,000 rows…")
}

@MainActor
@Test func endAlwaysClearsBothHalves() {
    let busy = BusyState(delay: .milliseconds(10))
    busy.begin("Sorting 1,000,000 rows…", immediately: true)
    #expect(busy.visible)
    busy.end()
    #expect(busy.visible == false)
    // The message goes too. A leaked one is what makes the *next* overlay say the wrong thing for
    // the frame before its own `begin` lands.
    #expect(busy.message == "")
}

/// The sort case: the stall is known before the work starts, so there is nothing to wait to find
/// out. A 30-second delay makes the claim unfalsifiable any other way — if this passes, no timer
/// was involved.
@MainActor
@Test func aKnownStallShowsTheOverlayWithNoWaitAtAll() {
    let busy = BusyState(delay: .seconds(30))
    busy.begin("Sorting 1,000,000 rows…", immediately: true)
    #expect(busy.visible)
    #expect(busy.message == "Sorting 1,000,000 rows…")
}

@MainActor
@Test func theShippedDelayIsStill400ms() {
    #expect(BusyState().delay == .milliseconds(400))
}

/// Which sorts announce themselves. The threshold is about the §13a cliff, not about the sort: below
/// it the skeleton rows already cover the wait, above it the window stops answering.
///
/// KNOWN GAP, stated rather than implied: the one line in `TableViewModel.setSort` that *joins* this
/// to `begin(_:immediately:)` is not covered, and cannot honestly be. `begin` is synchronous and the
/// sort it precedes is not, so a test would have to catch `visible` true between two suspension
/// points — MEASURED on a real 300,000-row CSV, that window is 238 ms and a `Task {}` is not
/// guaranteed to have started inside it, which is precisely the "passes for the wrong reason" shape
/// this suite's `waitFor` exists to avoid. Both halves are pinned here; the join was checked by
/// eye, over a live `NSTableView` (task-10-report.md).
@Test func onlyASortBigEnoughToBlockTheActorAnnouncesItself() {
    #expect(sortBusyMessage(rows: nil) == nil, "a table with no count yet has nothing to promise")
    #expect(sortBusyMessage(rows: 250_000) == nil, "the threshold is exclusive")
    #expect(sortBusyMessage(rows: 250_001) == "Sorting 250,001 rows…")
    // Grouped through `groupDigits`, on the string — never a `NumberFormatter`, whose output
    // changes with the machine's locale.
    #expect(sortBusyMessage(rows: 1_000_000) == "Sorting 1,000,000 rows…")
}
