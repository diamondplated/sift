# Plan 4, Task 11 — SQL mode

**Status:** done. 562 tests pass (550 baseline + 12 new), parallel, no `.serialized`, warning-free
from a wiped `.build`.

## What shipped

| File | Change |
|---|---|
| `Sources/SiftUI/SQLConsole.swift` | new — the pane, `sqlStatusText(owned:)` |
| `Sources/SiftUI/TableViewModel.swift` | additive — `sqlText`/`sqlOwned`/`typeSQL`/`mirrorRenderedSQL`/`runSQL()`/`exitSQLMode()`, `fetchBlock`, `sqlExtent`, `sqlModeExtent` |
| `Tests/SiftUITests/SQLModeTests.swift` | new — 12 tests |

`RootView` is untouched: `SQLConsole(model:onError:)` is a standalone public view for whoever wires
the toolbar's SQL toggle. Its only external requirement is a `TableViewModel` and a banner sink.

## The security surface

**Nothing in `Sources/SiftUI` validates SQL, builds SQL, or re-words an engine error.** The console
shows the text, hands it unmodified to `TableViewModel.runSQL()`, which hands it unmodified to
`Session.runSQL`, which runs `assertSelectOnly` and then `wrapUserSQL`. Whatever sentence comes back
is what the banner gets, via `error.localizedDescription` and nothing else. No `try?` anywhere on the
SQL path.

Three consequences worth naming:

1. **A prepare failure is not a guard rejection.** `SELECT * FROM nonexistent` is legitimate SQL
   against a table the user has not opened; the guard falls through and DuckDB's catalog error
   reaches the user. `aPrepareFailureReportsTheEnginesErrorAndNotARefusal` asserts the message
   contains the table name, is *not* the guard's sentence, and is not an `SQLRejected`.

2. **The gate runs on every block, not just the first.** `fetchBlock` pages SQL mode through
   `Session.runSQL`, matching the web's `/api/sql`-per-block (`web/index.html:834-838`).
   `Session.page` *would* also page a SQL-mode table — it has its own `wrapUserSQL` branch — and on
   an already-accepted query the two are indistinguishable. The difference is that `page` wraps
   `sqlText` without re-asserting it, so text reaching that field by any route other than `runSQL`
   would run on the wrap alone. Re-gating stored SQL before wrapping is exactly what `export` does
   with the same field. `everyBlockInSQLModeGoesBackThroughTheGate` plants `DROP TABLE t` into
   `Table.sqlText` behind `runSQL`'s back and asserts the block fetch refuses it with the guard's
   own sentence — the `Session.page` variant fails the same text, but as a `SessionError` parser
   dump, so the test pins the type *and* the wording.

3. **A refusal is not a state change.** The query runs before anything on screen moves, so a
   rejected statement leaves the table exactly as it was. This is a deliberate divergence from
   `web/index.html:1811-1812`, which wiped the grid before the request and left an empty one sitting
   behind the banner. A statement that passes the gate and then fails to *execute* does empty the
   grid, because the engine has already flipped `sqlMode` and every subsequent block would be
   fetched through the failing SQL — the model re-reads the table rather than guessing which of the
   two happened.

## The one-way door

`exitSQLMode()` is the only exit. Nothing tries to parse SQL back into filters
(`web/index.html:1768-1769`). Entering SQL mode **abandons** the filter spec rather than composing
with it — `enteringSQLModeAbandonsTheFiltersRatherThanComposingWithThem` sets a filter that cuts
1,200 rows to 12, runs `SELECT * FROM t`, and proves row 700 comes back; `Reset to filters` restores
the 12.

The status line is claimed by `typeSQL` and only by `typeSQL`. The web distinguished a user edit
from a programmatic write with the `input` event, which does not fire on `.value =`; a SwiftUI
`onChange` cannot, so the mirror writes `sqlText` directly and the claim lives in the setter the
editor's `Binding` routes through. `mirrorRenderedSQL` sets `sqlOwned = table.sqlMode`, so
re-selecting a tab that is *already* in SQL mode does not tell the user their query mirrors filters
it has nothing to do with.

## The extent

`sqlModeExtent(_:block:rows:)` — `web/index.html:846-855`. A SQL result has no exact count (nothing
counted it, and counting it means running the user's query twice), so a **short** block is the end
and pins the total exactly, while a **full** one promises only one more row (`+ 1`, which is what
keeps the scroll bar reachable far enough to ask for the next block). `max` is on the growing branch
and nowhere else: blocks arrive nearest-the-viewport-first, so a full block landing after the short
one that found the end must not re-grow past it, and a short block *must* shrink an extent a
speculative full block had guessed.

## Verification

Screen Recording is not granted, so the visual check is `cacheDisplay(in:to:)` on a live
`NSHostingView` of the pane — no permissions, real AppKit drawing, and the pane rather than a window
because `cacheDisplay` cannot capture an `NSVisualEffectView`.
`theConsoleDrawsDarkAndItsStatusLineRedrawsWhenTheBoxIsClaimed` samples the editor background
(brightness < 0.25 — a light box of monospaced text is not a console) and then measures the
rightmost inked pixel column of the status line before and after `typeSQL`, proving the longer
sentence actually redraws. `theOneWayDoorSentenceFitsTheBarWithoutEliding` uses `expansionFrame` —
AppKit's own answer to "did this have to draw an ellipsis" — against the 300-pt budget the bar leaves
beside its two buttons in a narrow window.

## Mutation testing

15 mutations, all killed. The first sweep found **two vacuous assertions and one that never applied**,
which are the interesting rows.

| Mutation | Killed by |
|---|---|
| `assertSelectOnly` deleted from `Session.runSQL` | `aNonSelectComesBackAsTheGuardsOwnSentence`, `aSecondStatementIsRefusedEvenWhenACommentHidesIt`, `everyBlockInSQLModeGoesBackThroughTheGate` |
| `sqlModeExtent` full block loses the `+ 1` | `theSQLExtentGrows…`, `sqlModeBlocksArePaged…`, `enteringSQLModeAbandons…` |
| `sqlModeExtent` short block takes `max` too | `theSQLExtentGrows…` — **survived the first sweep** |
| `deliver` stops growing the SQL extent | 4 tests |
| `fetchBlock` ignores SQL mode | `everyBlockInSQLModeGoesBackThroughTheGate` — **survived the first sweep** |
| `scrollExtent` ignores `sqlExtent` | 4 tests |
| `typeSQL` does not claim the box | 3 tests, including the pixel one |
| `mirrorRenderedSQL` claims the box | 3 tests |
| `exitSQLMode` leaves the SQL extent behind | `takingOverTheBox…`, `enteringSQLModeAbandons…` |
| `exitSQLMode` does not re-mirror the box | `takingOverTheBox…` |
| `runSQL` leaves the grid alone when the engine flipped | `aPrepareFailureReports…` |
| `runSQL` wipes the grid *before* running (the web's order) | `aNonSelectComesBackAsTheGuardsOwnSentence` |
| `sqlStatusText` never changes | `theStatusLine…`, `theConsoleDrawsDark…` |
| the console is not dark | `theConsoleDrawsDark…` |
| the status line copy grows past the bar | `theOneWayDoorSentenceFitsTheBar…`, `theStatusLine…` |

**The two survivors, and what they were hiding.**

- *`sqlModeExtent` short block takes `max` too.* The original test only covered a full block landing
  after a short one — the direction `max` already handles. The case that matters is the opposite:
  block 0 coming back with three rows after a speculative 501 had been guessed. Without the fix, the
  scroll bar reaches 501 rows into a three-row answer.
- *`fetchBlock` ignores SQL mode.* This one is the useful find: `Session.page` **already** wraps
  `sqlText` into a subquery, so paging SQL mode through it produces byte-identical results on any
  accepted query. The branch is only observable through the gate, so the test that kills it had to
  forge `Table.sqlText` and assert the refusal type and wording. Worth knowing that the two paths
  differ *only* in whether the stored SQL is re-asserted.

## Concerns

- **`RootView` wiring is not mine.** `SQLConsole` exists and is tested, but nothing puts it on
  screen — the toolbar's SQL toggle and the `.inspector`/banner plumbing belong to the tasks that own
  `RootView.swift`. Until that lands, SQL mode is reachable only from the model.
- **A block that throws is dropped silently.** `TableViewModel` installs `PageLoader.onDeliver` but
  not `onFailure`, which predates this task. In SQL mode that now means a query that fails on block 7
  (a `LIMIT`-sensitive expression, a dropped source) shows placeholders forever with no banner. The
  first page's failure is reported; later ones are not. Fixing it means an error sink on the model,
  which is banner-shaped and belongs with whoever owns the banner stack.
- **`Session.page`'s SQL-mode branch does not re-gate.** Not touched (engine is out of scope for this
  task) and not currently reachable with unvetted text, since `runSQL` is the only writer of
  `Table.sqlText`. Named here so it is a decision rather than an oversight.
- **`TableViewModel.swift` is shared with the filter-bar task.** Three existing lines are modified
  (the loader's fetch closure, `scrollExtent`, and four lines inside `deliver`); everything else is
  new declarations appended in their own `MARK` section. Should merge, but the loader closure is the
  one hunk worth eyeballing.
