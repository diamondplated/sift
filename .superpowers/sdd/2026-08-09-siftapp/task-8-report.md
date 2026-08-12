# Task 8 report — the inspector: Schema tab, Column tab, and the filter actions

**Status:** done. 563 tests pass (550 + 13), warning-free from a wiped `.build`, nothing `.serialized`.

## What landed

| File | What it holds |
|---|---|
| `Sources/SiftUI/FilterActions.swift` | `applyDistinctClick`, `DistinctClick`, the two sentinel labels, `filterValue(for: Cell)` |
| `Sources/SiftUI/InspectorView.swift` | `InspectorTab`, `InspectorView`, `SchemaList`, the missing bar, `countText`/`compactCount`/`percentText`/`shortType` |
| `Sources/SiftUI/ColumnPanel.swift` | `ColumnPanel`, the stats grid, `DistinctList`, `meanText` |
| `Sources/SiftUI/RootView.swift` | one line: `.inspector(isPresented: $state.inspectorVisible) { InspectorView(state: state) }` |
| `Tests/SiftUITests/FilterActionsTests.swift` | 9 tests, pure, no session |
| `Tests/SiftUITests/InspectorRenderTests.swift` | 4 tests: three `ImageRenderer` checks and the number formatting |

## Decisions worth knowing

**`ColumnPanel` takes a `Session`.** The brief's render test writes `ColumnPanel(model:column:)`, which
cannot work: the panel has to call `profileOf`/`distinct`, and `TableViewModel.session` is `private`
(and `TableViewModel.swift` belongs to another task). The initialiser is
`ColumnPanel(session:model:column:)`; `InspectorView` passes `state.session`.

**The pane owns the only `ScrollView`.** `ImageRenderer` lays out no `ScrollView` at all — measured:
a `SchemaList` that wrapped its own rendered as a blank 320×200 bitmap, and so did `ColumnPanel`. A
scroller inside a panel silently costs that panel its entire visual check, so `InspectorView` scrolls
and the panels are plain content. Task 9's `SourceTab` should follow the same rule.

**The profile is read twice, on purpose.** `ColumnPanel` draws `model.profile`'s copy immediately and
replaces it with `profileOf`'s when that lands. Without the first, the panel is empty until a round
trip; without the second, a file too big for `profileIfCheap`'s gate has no stats at all. `Table.profiling`
is read directly for the "Profiling…" note — no mirror anywhere.

**Right-click is a one-item context menu**, not an immediate action. SwiftUI has no immediate
right-click hook; the only way to get one is an `NSViewRepresentable`, which `ImageRenderer` refuses
to draw — it would take the whole panel's visual check with it. ⌘-click reads `NSEvent.modifierFlags`
at the moment of the tap: `TapGesture().modifiers(.command)` is a *different* gesture and the plain
tap swallows both.

**Reload key includes the filters.** `applySpec` re-runs `loadColumn` in the web build
(`index.html:886`); keying the load task on the spec covers that plus any spec change made elsewhere
(the header's sort, Task 10's filter bar), with no cross-task wiring.

`shortType` shortens *every* occurrence rather than the first — JS's `.replace` stops after one, so
`STRUCT(a VARCHAR, b VARCHAR)` came out half-shortened in the web build.

## Mutation testing

Fifteen deliberate breakages, one at a time, each run against the test that claims to guard it.
**Thirteen killed; two survived and both were real holes, now closed.**

| Mutation | Result |
|---|---|
| empty ⌘-toggle leaves an empty `in` instead of dropping the column | KILLED — `removingTheLastCommandClickedValueDropsEveryFilterOnThatColumn` |
| NULL sentinel becomes a one-element `in` instead of `is_null` | KILLED — `theTwoSentinelsAreDetectedByLabelAndBecomeNullaryOps` |
| exclude checked *after* the sentinels (right-click on NULL sets `is_null`) | KILLED — same test |
| replacement drops the whole column instead of just the same op | KILLED — `aClickReplacesOnlyTheSameOpAndLeavesTheColumnsOtherFiltersAlone` |
| ⌘-click always appends, never removes | KILLED — `commandClickTogglesMembershipOfTheColumnsInList` |
| a decimal loses its digits on the way into a filter | KILLED — `everyCellCaseBecomesTheFilterValueThatBindsBackToIt` |
| the missing bar's null (amber) segment is not drawn | KILLED — `theSchemaListDrawsTheMissingBarsSegmentsAndNotJustTheirText` |
| the missing bar's empty (blue) segment is not drawn | **SURVIVED**, then killed — see below |
| the missing bar's uncastable (red) segment is not drawn | **SURVIVED**, left unguarded — see below |
| the selected schema row is not marked | KILLED (guard added with the fix above) |
| sentinel rows styled like every other value | KILLED — `theValueListDrawsTheTwoSentinelRowsInTheirOwnColour` |
| the value list draws no rows, only its footer | KILLED — same test |
| the column panel ignores the column it was handed | **SURVIVED**, then killed — see below |
| percentages always use one decimal | KILLED — `theInspectorsNumbersMatchTheShippingWebBuildsFormatting` |
| `shortType` stops shortening `VARCHAR` | KILLED — same test |
| counts skip the grouping loop | KILLED — same test |
| a mean keeps its trailing zeros | KILLED — same test |

### The three findings

1. **`pixelDigest` was hashing 80 bytes of blank margin.** Foundation's `Data.hash(into:)` mixes in
   the count and *at most the first 80 bytes*. Written the brief's way (`hasher.combine(data)`), the
   digest reported two visibly different `ColumnPanel`s as identical — the two-render rule was
   vacuous, and would have passed for a panel that drew nothing at all. Fixed with
   `data.withUnsafeBytes { hasher.combine(bytes: $0) }`. This is the "twelve vacuous tests" failure
   mode in its purest form: the test failed *first*, which is the only reason it was caught.

2. **The blue missing-bar segment was answered for by the selection highlight.** The schema render
   passed `selected: "note"`, whose accent-tinted row background is itself blue, so deleting the
   empty segment entirely left the test green. The colour assertions now render with `selected: nil`,
   and a second render *with* a selection is digest-compared against it — which guards the highlight
   too, a property nothing covered before.

3. **The column-panel two-render check was satisfied by the header alone.** With
   `model.profile.first` in place of `first { $0.name == column }` — every panel showing the *first*
   column's stats — the bitmaps still differed, because the header draws the column's own name and
   type. The digest now skips the top 48pt, and the mutation dies.

**Left unguarded, deliberately:** the missing bar's third (red, uncastable) segment. No column in the
suite's fixture has an uncastable cell, so nothing red is drawn either way. Producing one needs the
engine suite's gzipped 25,000-row trick, which is a multi-second fixture to prove that a third call to
the same one-line `segment` helper draws. Said out loud in the test.

## What the render showed

PNGs written by the suite (`SIFT_RENDER_OUT=<dir>` to keep them; the temp root is swept by the next
test process even with `SIFT_KEEP_TEST_TEMP=1`).

* **`schema-list.png`** — `3 columns`, then `id ≈12 BIGINT`, `label ≈11 STR`, `note ≈2 STR`. The
  missing bar is right: `id` and `label` are bare grey tracks, `note` shows an amber third followed by
  a blue third and a grey remainder, which is exactly the fixture (a third NULL, a third `''`, a third
  `N/A`). Types are shortened, distinct counts carry the `≈`.
* **`value-list-note.png`** — three rows: `N/A`, `␀ EMPTY`, `␀ NULL`, the two sentinels in amber
  monospace and the ordinary value in body text. Counts `4`, percentages `33.3%`, and the fill bar
  measured **0–106px of 320 (33.4%)** — the proportional bar is proportional. Footer
  `showing 3 of 2 values · 607.4 ms` (2 is `count(DISTINCT)`, which does not count NULL — the
  engine's number, matching the web), then the hint sentence over two lines.
* **`column-panel-label.png` / `column-panel-id.png`** — `label VARCHAR` with rows 400, distinct ≈ 400,
  null 0, empty `''` 0, min `row0`, max `row99`, max length 6; `id BIGINT` with mean 199.5 and median
  200 and no max/min truncation. Each shows exactly the rows its profile carries, and `id` shows the
  Task 9 placeholder because its profile's own view is `hist`.
* The lens `Picker` and search `TextField` are AppKit-backed and come out as `ImageRenderer`'s
  prohibited-symbol placeholder. Both were checked separately through `NSHostingView` +
  `cacheDisplay`, which renders those two controls (the segmented picker with `Schema`/`VALUES`
  selected, the field with its `search values…` placeholder) and — being the exact mirror of this
  limitation — drops most SwiftUI-drawn text instead. Between the two routes every control on the
  page has been seen.

**Layout and appearance beyond that were verified by a human looking at these PNGs, once.** These are
smoke checks, not golden images: they catch a view that fails to lay out, renders blank, or ignores
the column it was handed. They do not catch a view that renders wrongly.

## Concerns for whoever picks this up

* **Task 9 must not wrap its panels in a `ScrollView`** (see above), and will need to replace the two
  `Task 9` placeholder lines in `ColumnPanel.content` — that is a two-line edit inside this task's
  file, which the brief's file list for Task 9 does not mention.
* **`ColumnPanel` renders `.hist`/`.highcard` by default for most columns** (any numeric column with
  more than `numericTopNMaxDistinct` values, any near-unique text column), so until Task 9 lands, the
  Column tab shows a placeholder more often than it shows values. Not a defect, but it will look like
  one.
* The `␀` in the sentinel labels renders through a fallback font as a small `NUL` control picture.
  That is the engine's label (`SQLGenPanels.topNSQL`) and it matches the web build; worth a look on a
  machine with a different font stack.
* Nothing here has been seen in a running window — Screen Recording is not granted and Accessibility
  reports zero windows on this machine.
