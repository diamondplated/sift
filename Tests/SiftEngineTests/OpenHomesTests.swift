import Testing
import Foundation
import TestSupport
@testable import SiftEngine

// Spec §13a: two `Session`s on one `SIFT_HOME` are two independent DuckDB instances that cannot
// see each other's catalog, so the second one's flush silently overwrites the first one's. There
// is no lock error in-process — the `sharedStore` fallback reports `true` for both and protects
// nothing — so the only thing that stops it is `Session.init` refusing the second open.
//
// `shutdown()` is actor-isolated, so every call is `await` and every test is `async`. Homes come
// from `TestTemp.path` (unique per call, swept at process exit) — never a bare temporaryDirectory.

private func newHome() -> String { TestTemp.path("openhomes") }

@Test func twoLiveSessionsOnOneHomeAreRefusedRatherThanOverwritingEachOther() async throws {
    let home = newHome()
    let first = try Session(home: home)
    #expect(throws: SessionError.self) { _ = try Session(home: home) }
    await first.shutdown()
}

@Test func aHomeIsClaimableAgainOnceTheSessionHoldingItHasShutDown() async throws {
    let home = newHome()
    let first = try Session(home: home)
    await first.shutdown()
    let second = try Session(home: home)      // must not throw
    await second.shutdown()
}

@Test func twoSessionsOnDifferentHomesBothOpen() async throws {
    let s1 = try Session(home: newHome())
    let s2 = try Session(home: newHome())
    await s1.shutdown()
    await s2.shutdown()
}

/// The sequence a path-only release gets wrong: A hands the home over to B, then A's own deinit
/// runs and — without the token — releases B's claim, letting a third session in alongside B.
/// This test is the whole reason `OpenHomes` stores a UUID. It must go RED if `release` stops
/// comparing tokens; proved by deleting the comparison once and watching it fail.
@Test func aDeallocatedSessionCannotReleaseAClaimItNoLongerHolds() async throws {
    let home = newHome()

    var first: Session? = try Session(home: home)
    await first!.shutdown()
    let second = try Session(home: home)      // legitimate hand-over

    first = nil                                // A's deinit runs here
    // A's deinit must be a no-op: `second` still holds the home.
    #expect(throws: SessionError.self) { _ = try Session(home: home) }

    await second.shutdown()
    let third = try Session(home: home)        // and now it is genuinely free
    await third.shutdown()
}

/// The control for the test above, and it is not optional: that one plants A's deinit and asserts
/// it changes nothing, so it passes for the wrong reason if the deinit never runs at all (delete
/// `Session.deinit` and it still goes green). This proves the deinit both runs at `= nil` and does
/// release — a session dropped without `shutdown()` hands its home back rather than holding it for
/// the life of the process.
@Test func aSessionDroppedWithoutShutdownStillHandsItsHomeBack() async throws {
    let home = newHome()
    var only: Session? = try Session(home: home)
    #expect(only?.siftHome == home, "this is the home it claimed")
    #expect(throws: SessionError.self) { _ = try Session(home: home) }   // held while it lives
    only = nil                                                          // last reference dropped
    let next = try Session(home: home)                                  // …so the deinit freed it
    await next.shutdown()
}

/// A refused open must report what actually went wrong, not the claim. `init` throws before it is
/// fully initialized, so no `deinit` runs and the failure path has to hand the home back itself —
/// if it did not, the FIRST attempt would leave a claim behind and the second would report
/// "already using" instead of the unopenable store. Two attempts is what makes that visible.
@Test func aFailedOpenLeavesNoClaimBehindForTheNextAttemptToTripOver() async throws {
    let home = newHome()
    // A `stage.duckdb` that is a directory cannot be opened as a database — the same unopenable
    // store `ErrorSentenceTests` uses.
    try FileManager.default.createDirectory(
        atPath: (home as NSString).appendingPathComponent("stage.duckdb"),
        withIntermediateDirectories: true
    )

    for attempt in 1...2 {
        do {
            _ = try Session(home: home)
            Issue.record("attempt \(attempt) opened a store that is a directory")
        } catch let error as SessionError {
            #expect(
                !error.message.contains("already using"),
                "attempt \(attempt) reported the claim instead of the real failure: \(error.message)"
            )
        }
    }
}
