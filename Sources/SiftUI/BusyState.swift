import Observation
import SwiftUI

/// "This is taking a moment", and the delay that stops it flickering on every fast page.
///
/// 🔴 **This class is on the `MainActor`, which is the whole reason it works.** `Session.page` runs
/// synchronously on the `Session` actor and never suspends (see its doc comment: the §13a
/// responsiveness cliff, left in on purpose), so a first sorted page over a large table blocks
/// *every other actor call* until the materialization finishes. A flag the blocked actor had to set
/// would therefore arrive after the stall it was meant to announce — which is no announcement at
/// all. The timer lives here, on the actor that is still running, and the blocked one is never
/// asked for permission to draw.
///
/// Three layers cover the wait, and this is only the second of them: every unloaded row is already
/// a skeleton (Task 6), which covers the ordinary sub-second case with no machinery at all; this
/// flips `visible` once a fetch has been outstanding longer than `delay`; and a sort of a large
/// table calls `begin(_:immediately:)` because there the wait is *known* in advance rather than
/// discovered.
@MainActor
@Observable
public final class BusyState {
    /// Whether the overlay should be on screen. False until `delay` has elapsed inside one
    /// `begin`/`end` pair — a page that comes back in 12 ms never draws anything.
    public private(set) var visible = false
    /// What the overlay says. Set by `begin` even when the overlay never becomes visible, which
    /// costs nothing and keeps the two from ever disagreeing.
    public private(set) var message = ""

    /// How long a piece of work has to be outstanding before it is worth telling the user about.
    ///
    /// 🔴 Injectable for the same reason `Session.setStageDwellForTest` exists. A test that really
    /// slept past the shipped 400 ms would add most of a second to a parallel suite to prove a
    /// timer it can prove in 10 ms — and one that waited on the *real* deadline is a flake the
    /// moment the machine is busy. Tests construct `BusyState(delay: .milliseconds(10))`; the app
    /// takes the default, and `theShippedDelayIsStill400ms` is what stops this seam quietly
    /// becoming a different product decision.
    ///
    /// `internal`, reached through `@testable import`: it is a constructor argument, not something
    /// a view ever reads.
    let delay: Duration

    /// `@ObservationIgnored` because no view draws it, and an observed handle would invalidate
    /// every reader on each begin/end pair — including the ones that never became visible.
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(400)) {
        self.delay = delay
    }

    /// Something slow started. The overlay appears `delay` later unless `end()` beats it.
    ///
    /// `immediately: true` skips the wait, for the one case where the cost is known before the work
    /// starts rather than discovered by it — sorting a table too large for the skeleton rows to
    /// cover (`sortBusyMessage`).
    ///
    /// A second `begin` while the overlay is already up replaces the message and leaves it up: this
    /// is one slot, not a stack, and blinking the scrim off and on between two consecutive blocks
    /// would be worse than either state on its own.
    public func begin(_ what: String, immediately: Bool = false) {
        message = what
        timer?.cancel()
        guard !immediately, !visible else {
            timer = nil
            visible = true
            return
        }
        let wait = delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            // `try?` swallows the cancellation, so the check has to be explicit — without it, an
            // `end()` during the sleep would still flip `visible` on the way out.
            guard !Task.isCancelled, let self else { return }
            self.visible = true
        }
    }

    /// The work finished, failed, or was cancelled. Always clears — there is no counter and no
    /// "still one outstanding" state, deliberately: the overlay describes the moment, and a leaked
    /// scrim over a working grid is the worst failure this class has.
    public func end() {
        timer?.cancel()
        timer = nil
        visible = false
        message = ""
    }
}

/// The scrim and the spinner, over the grid only — the sidebar, the inspector and the menu bar stay
/// live, because the thing that is blocked is one actor and not the app.
///
/// Indeterminate on purpose: the engine reports no progress for a sort (`sortedRelation` is a single
/// `CREATE TABLE … AS SELECT`), so a determinate bar here would be inventing a number. 🔴 This
/// comment used to name the staging banner as the one place a determinate bar was honest, on the
/// strength of a `pct` field that was only ever written as `0`. There is now no determinate progress
/// anywhere in the app, because there is nowhere the engine can honestly produce one — staging is
/// the same single CTAS with the same absent callback (see `StagingProgress`).
public struct BusyOverlay: View {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A plain translucent wash rather than `.regularMaterial`: a material is an
        // `NSVisualEffectView`, which `cacheDisplay(in:to:)` cannot capture — so the one route this
        // machine has for looking at the running app would render the overlay as a hole.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }
}
