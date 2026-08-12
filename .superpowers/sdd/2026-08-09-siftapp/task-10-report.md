# Task 10 — Filter bar, banners, and the paging cliff

**Status: complete.** 604 tests pass (590 base + 14 new), warning-free from a wiped `.build`, suite
parallel, nothing `.serialized`. Four consecutive full runs, no flakes.

## What shipped

**`Sources/SiftUI/BusyState.swift`** — `BusyState(delay:)` on the `MainActor` (the actor that is
*not* blocked, which is the only reason a timer can announce a stall on the one that is), plus
`BusyOverlay`. `begin` arms a cancellable `Task`; `begin(_:immediately:)` skips the wait for the one
case where the cost is known in advance; `end` always clears. The scrim is a plain translucent wash
rather than `.regularMaterial`, because a material is an `NSVisualEffectView` and `cacheDisplay`
cannot capture one — the overlay would be a hole in the only capture route this machine has.

**`Sources/SiftUI/FilterBar.swift`** — `filterChipLabel` (a verbatim port of `opLabel`), the chips
with their ×s, `clear all`, the no-filters hint, the `SQL mode — filters frozen` chip, and the
`Show SQL`/`Hide SQL` toggle. The toggle is what puts `SQLConsole` on screen; it had been built by
the SQL-mode task and was not reachable from anywhere.

**`Sources/SiftUI/BannerView.swift`** — `BannerStack` in the web's order (staging + Cancel,
`stagingError`, notes, sorted-truncation, block failure, missing extensions, `AppState.banner`),
over three sentence *functions* so the numbers and plurals are testable. The missing-extension list
is `sorted()`: a Swift `Dictionary` is not insertion-ordered and the same two extensions would
otherwise name themselves differently on every launch.

**`TableViewModel`** — `busy` and `pageError`; `begin`/`end` inside the fetch closure (not in
`PageLoader`, whose `init(fetch:)` contract four tests pin); `setSort` calls
`begin(_:immediately:)` when `sortBusyMessage` says the table is over 250,000 rows;
`resetViewport` clears `pageError`.

**`RootView`** — banners, filter bar, console, grid, in `web/index.html:336-368`'s order; the busy
overlay on the grid only.

## The three loose wires

1. **`onColumnSelected`** — wired at the `TableGridView` call site to `AppState.selectedColumn`, a
   new property. `InspectorView`'s selected column moved from `@State` to there, because the click
   that sets it happens two views away; an `.onChange` brings the Column tab forward, matching the
   web's `state.itab = "column"` on the same click. A plain header click did nothing at all before.
2. **`onError`** — wired to `AppState.banner`. A failed shift-click sort was silent; `setSort` runs
   detached, so the banner is the only place that error can go.
3. **`PageLoader.onFailure`** — installed. The hook has existed since Task 4 with nothing on it, so
   a block whose fetch threw was dropped in silence: skeleton rows forever, and in SQL mode a grid
   of placeholders under a console reporting success. It now lands in `pageError`, which
   `BannerStack` draws. It is a property and not a fourth callback, because this file's stated
   ceiling is three closures and the fourth is meant to force a decision, not slip past.

## Tests, and two vacuous ones caught before they shipped

`Tests/SiftUITests/BusyStateTests.swift` (7) and `Tests/SiftUITests/FilterBarTests.swift` (7).
Twenty-one mutations run against them; **19 killed, and the 2 that survived were my own tests being
vacuous, both now fixed**:

* **A pixel digest cannot be used on this view at all.** MEASURED: rendering the *same* `FilterBar`
  three times produced digests `A, A, B` — an `ImageRenderer` bitmap containing an AppKit-backed
  `Button` is not byte-stable between renders. So `digest(x) != digest(y)` passes for two renders of
  *identical* content: written that way first, the SQL-mode check passed with the SQL-mode branch
  deleted. Replaced with channel-ratio ink counts, which were bit-identical across every repeat, and
  asserted only as relationships (this state has more chip ink than that one), never as magnitudes.
* **No fixed-sleep timing assertions.** `Task.sleep(80ms)` then `#expect(busy.visible)` passed alone
  and failed in the full suite: the timer is `MainActor`-bound and 107 parallel tests starve it for
  far longer than the delay. `waitFor` polls for the signal instead, and the negative case uses an
  inverted `waitFor` so "did not fire" is distinguishable from "not scheduled yet".

**Known gap, stated rather than implied:** the one line joining `sortBusyMessage` to
`begin(_:immediately:)` inside `setSort` is not covered. `begin` is synchronous and the sort is not,
and MEASURED on a real 300,000-row CSV that window is 238 ms — a `Task {}` is not guaranteed to have
started inside it, so any test would pass for the wrong reason. Both halves are pinned; the join was
checked by eye.

## What the render showed

Two captures, both `cacheDisplay(in:to:)` on a live `NSHostingView` of the pane (not a window — a
window brings an `NSVisualEffectView` that cannot be captured), over a real 300,000-row CSV:

* **The overlay** — spinner and `Sorting 300,000 rows…` centred over the grid, the rows still legible
  through the scrim, grid header and all. The count is grouped by `groupDigits`. A real sort of the
  same 300,000 rows took 238 ms end to end and left `visible == false` behind it.
* **The pane** — the red `AppState.banner` strip with its Dismiss button, the chip
  `label contains “row1” ×` under it, and the grid below showing the descending sort caret on `id`
  with rows counting down from 199,999.

`ImageRenderer` was used for the bar's four states (it draws SwiftUI text that `cacheDisplay` drops,
and vice versa — the two are mirror images): the no-filters hint, one chip, two chips on one column,
and the amber `SQL mode — filters frozen` chip in place of the chips.

## Concerns

* **The filter bar does not wrap.** The web's toolbar has `flex-wrap`; an `HStack` does not, so a
  great many filters compress rather than flowing to a second line. A wrapping `Layout` is the fix if
  anyone hits it; it is noted in the source.
* **`RootView`, `AppState` and `TableViewModel` edits were kept additive** for the sidebar and
  SQL-mode tasks. `InspectorView.swift` also had to change — it is not in this task's file list, but
  it is where the selected column lived, and the `onColumnSelected` wire is unreachable otherwise.
  The change is three lines plus one `.onChange`.
* **Only the sort announces itself.** A filter over a huge table also blocks the actor (it runs a
  `COUNT`), and only gets the 400 ms path. That is what the brief specifies; widening it is a
  separate decision.
