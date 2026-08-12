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

* **The capture route has to be `cacheDisplay`, not `ImageRenderer`.** MEASURED, 20 renders of
  identical content each way: `ImageRenderer` produced **two** distinct bitmaps, `cacheDisplay` on an
  `NSHostingView` produced **one**. An unstable capture makes every "these two renders differ"
  assertion vacuous — written on `ImageRenderer` first, the SQL-mode check passed with the SQL-mode
  branch deleted. (First written up here as "a pixel digest cannot be used on a view containing an
  AppKit `Button`", then as row padding; both wrong. It is the renderer, and the fix is to stop using
  it. See the correction below.)
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

## Correction: the render test went red on CI, and why the replacement cannot

The first version counted pixels "leaning amber" in one render and compared that count against a
render of **different content**. It passed here and inverted on the macos-15 runner
(`amber 2486 > amber 3861`): `Color.accentColor` resolves to a different hue there, so the blue
chips themselves counted as amber and two of them out-ambered the one amber chip. **A count compared
across two different contents measures the renderer as much as the code.** The ink-ratio idea was
stable across repeats *here*, which is exactly what made it look safe — repeat-stability on one
machine says nothing about agreement between two.

It now uses the technique the histogram task already established, rather than a fourth invention:

* **`cacheDisplay` on an `NSHostingView`, pinned to `NSAppearance(.aqua)`** — no appearance variance,
  and the stable capture route measured above.
* **A control first.** The same model is rendered twice and the two buffers must be identical. Every
  later assertion is an inequality, which is only evidence if the renderer reproduces itself; a
  renderer too unstable to compare now fails the *control*, with a message saying so, instead of
  flaking on the real assertion. Verified by injecting a random opacity into `FilterBar`: the control
  is what goes red, at its own line.
* **Digest over every pixel byte, walked by hand, row padding excluded.** `Hasher.combine(someData)`
  hashes at most the first 80 bytes — blank margin on this strip.

**Why this is environment-independent, by construction:** both sides of every comparison come out of
one rasterizer, in one process, at one scale, in one appearance, microseconds apart. A runner with
different fonts, a different backing scale, different antialiasing or a different accent colour moves
*both* buffers the same way, so it cannot flip an equality or an inequality — the only thing that
differs between the two renders is the model, which is the thing under test. Nothing asserts a
magnitude, a colour, a coordinate, or a `* scale` term; the only numeric literals left in the file
are in the digest loop itself.

Two extra guards came out of re-running mutation on the rewrite: with `Text(filterChipLabel(filter))`
replaced by `Text("")` the whole test stayed green, because a chip of a different *width* is still a
different picture. Two filters that differ in exactly one string — same op, same geometry — now pin
that the chip draws its label and its column name.

**Also found, and not mine:** `SQLModeTests.theStatusLineRedrawsWhenTheBoxIsClaimed` fails its own
control roughly one full-suite run in one at `577056f` (pristine, twice). It is green at `8b1b7be`,
so a sibling has already fixed it; this patch is rebased onto that tip.

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
