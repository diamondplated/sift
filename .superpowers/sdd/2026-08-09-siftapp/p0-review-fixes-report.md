# P0 review fixes — report

Base `b852e79` (719 tests). Six commits, **729 tests**, `swift build` warning-free from a wiped
`.build`, `swift run sift --verify` 20/20.

| finding | state |
|---|---|
| C1 Source tab unreachable | fixed, wired + composition test |
| C2 blank undismissable sheet | fixed, all three legs |
| I4 closed tables resurrect | fixed |
| I5 duplicate workbook predicate | orphan deleted |
| I6 two export UIs | sidebar routed to the sheet, save panel deleted |
| M1 `␀ NULL` literal | routed through `SiftEngine.nullGlyph` |
| M2 `"\(error)"` in the five sheets | `localizedDescription` |
| M3 `presentMerge` guard | added |
| M4 `stopPolling` had no caller | `applicationWillTerminate` |
| M5 MergeSheet's captured table list | documented, not fixed — reason below |
| I1, I2, I3's Escape convention | I1/I2 **deferred** (BannerView, untouched). I3's dismissal convention IS fixed |

---

## C1 — the Source tab

`InspectorView.swift:84-88` drew `Note("The source panel arrives with Task 9.")`. Now
`SourceTab(state: state, table: model.table)` — `model.table` rather than `state.active` because it
is the same table and `refresh()` already keeps it current through `models[t.name]?.apply(t)`.

**The test class this kept evading** is `Tests/SiftUITests/CompositionTests.swift`. Its rule: drive
the composing view, never the piece it composes. The wiring assertion is "render `InspectorView`
itself against two unlike tables and require the bitmaps to differ" — a placeholder draws the same
pixels whatever is open, so a constant fails it and a real panel cannot. All three tabs are checked
the same way, plus a "the three tabs draw three different panels" sanity check and an empty-state
check (cropped below the tab strip, which draws its own selected segment).

`InspectorView.init` gains `initialTab:` (default `.schema`) so the composing view is renderable
with a tab forward. The tab is still `@State`.

`cacheDisplay` on an `NSHostingView`, never `ImageRenderer` — `ImageRenderer` lays out no
`ScrollView`, and `InspectorView` owns the pane's only one, so it would have rendered this suite's
whole subject as a blank bitmap.

**Mutation:** restoring the placeholder reddens
`everyInspectorTabMountsItsRealPanelAndNotAPlaceholder` on the Source assertion. Verified.

## C2 — the blank sheet

All three legs.

**(a) subject-aware clearing.** `ModalSheet.export` and `.badRows` now carry `table: String`, and
`ModalSheet.subject` is what `AppState.dismissSheetWithoutASubject()` reads. Called from `close(_:)`
before the engine call, and from `refresh()` — the latter is the poll loop's own entry point and is
therefore the leg that catches a table leaving the catalog without a user action behind it
(Phase 1's dropped connection). `.staged` and `.workbook` have no subject and survive.

Naming the subject also closes a second, quieter hole the review did not name: with the subject
re-derived as `state.active` at render time, switching tabs under an open Export sheet silently
re-pointed it at a different table.

**(b) `.cancelAction` everywhere.** `BadRowsSheet` and `StagedDataSheet` moved their `Close` from
`.defaultAction` to `.cancelAction`. Five sheets, one convention. **This costs Return on those two**
— a SwiftUI `Button` takes one `keyboardShortcut`, and Escape is the reflex key on a read-only
panel, especially BadRows, which a single click on a title-bar label raises.

**(c) the belt.** Both `if let`s gained an `else` rendering `SheetSubjectGone` — a sentence, a
`.cancelAction` button, and `.task { dismiss() }`.

**Mutation:** dropping the dismissal from `refresh()` reddens
`refreshAlsoDismissesASheetWhoseTableLeftTheCatalog`; dropping it from `close(_:)` reddens the
window assertion in `closeDropsTheTableFromTheMirrorBeforeItAwaitsTheEngine` (a completed `close`
cannot see it — `refresh()` cleans up either way — so it is the suspension point that pins it);
emptying `SheetSubjectGone` reddens `theSheetFallbackPaintsRatherThanRenderingABlankModal`. All
three verified.

**Declined:** leg (b) has no test. A `keyboardShortcut` on a SwiftUI `Button` is not observable from
a unit test, through pixels or otherwise. Stated rather than implied.

## I4 — resurrection

`close(_:)` awaited the engine, cleared the model, then awaited `refresh()` — `tables` still named
the table across two suspension points. It now drops the mirror row and moves the selection **before
the first await**, and puts both back in the `catch` when the engine refuses (a live merge reads the
table); `refresh()` restores the row itself. `models[name]` is cleared only on success, so a refused
close keeps its page cache — it used to lose it.

Moving the selection synchronously also stops the detail pane flashing its no-file-open state on the
way to the next table.

`model(for:)` **already** returned nil for names outside the current mirror; no change was needed
there. Stated because the work order asked for both halves: the review's probe (close on the session
directly, then ask for a model) is not fixable synchronously — `Session` is an actor and
`model(for:)` is not `async` — so the mirror is the only truth available to it, and the fix is
keeping the mirror true at every suspension point. The probe is preserved as the first half of
`aTableTheEngineHasClosedIsNotHandedBackAsAViewModel`, with a note saying exactly that much.

**Mutation:** moving `tables.removeAll` back below the await reddens
`closeDropsTheTableFromTheMirrorBeforeItAwaitsTheEngine` on both assertions. The window is observed
with `Task.yield()`, an actor hand-off rather than a sleep — **15/15 clean runs**, checked because
this branch already carries three timing-fragile tests (M7) and a fourth was not on offer.

## I5, I6

`offersSheetPicker` deleted with its six-case duplicate test; `needsSheetPicker` carries a note
naming the collision as the third on this branch and the first where the loser was still alive.

The sidebar's ⤓ and its "Export as" context submenu now call `presentExport(table:)` — the row's own
table, so exporting the third table in the list no longer requires selecting it first. The
`NSSavePanel` path and its unconditional `overwrite: true` are gone.

## M5 — declined, with the reason

`MergeSheet`'s `tables:` is captured by value at presentation and stays that way. Not one line:
`left`/`right` are `@State` seeded from that array, so a live list has to move a selection the user
made, mid-probe, and re-run two `.task(id:)` queries against a catalog that just changed. The list
also cannot simply be re-read from `AppState` — this sheet deliberately does not reach into it, which
is the seam `onMerged` exists to keep. Today a closed table stays listed and picking it fails with
the engine's own "No open table named …". Documented at the `init` rather than fudged.

## Not done, as instructed

⌘F rebinding, the `BIGI…` width floor, toolbar placement. I1 (`stagingText` "about 0s") and I2
(Cancel discarding the engine's `false`) — `BannerView.swift` was not opened. `AppearanceTests.swift`
and the SQL console colours were not touched.

---

## Verification

```
swift build           # from a wiped .build — Build complete, 0 warnings
swift test            # 729 tests passed, 0 warnings
swift run sift --verify   # 20 checks: 20 passed, 0 failed, 0 skipped
./build-app.sh        # Sift.app built, signed, satisfies its Designated Requirement
```

**The GUI walk could not be driven.** This session is non-interactive, so the computer-use
permission dialog was auto-denied (`io.github.diamondplated.sift: user_denied`) and there is no way
to click. What was done instead, in two parts:

*The app itself* — built, code-signed, launched, and handed `live.csv` (500 rows) through
LaunchServices. It stayed up and wrote no crash report.

*The walk* — driven headlessly through the real `AppState` over a real 300-row CSV, the same route
the review used, with real pixels captured through `NSHostingView` + `cacheDisplay` and **looked at**:

| step | observed |
|---|---|
| open | `300 rows · 4 cols`, banner nil |
| inspector Source tab | the real panel: name, full wrapping selectable path, `format csv / size 5.8 KB / columns 4 / rows 300`, `counted exactly`, the Staging paragraph carrying the engine's own reason (*"only 5.8 KB — re-reading it is faster than copying it"*), a **Stage this file** button, and the detected-dialect box |
| Stage | stats gain `staged yes`, the paragraph becomes the staged one, the button becomes **Read from source instead** |
| Unstage | back to `.stageable` and the original sentence |
| ⌘E | `modalSheet == .export(table: "orders")`; the sheet draws destination, format picker, overwrite toggle, Cancel + Export |
| ⌘W under it | `modalSheet == nil`, 0 tables — **no blank sheet, no force-quit** |
| sidebar ⤓ | `.export(table: "orders")` while `activeName == "second"` — the row's table, not the selection |
| the fallback | draws "That table is no longer open." and a Close button |

One thing the headless route cannot show: a whole `RootView` rendered offscreen comes out as three
empty columns with the dividers drawn — `NavigationSplitView` does not populate its columns without
a real window. Pre-existing and already documented on this branch ("the native window can't be
screenshotted here"); it is why the per-view renders above are the evidence.
