# Task 13 report — menus, toolbar, document handling, keyboard navigation

**Status:** complete. 582 tests pass (550 before, 32 added), warning-free from a wiped `.build`,
suite parallel, nothing `.serialized`.

**Files touched, and only these:** `Sources/SiftUI/KeyNav.swift` (new),
`Tests/SiftUITests/KeyNavTests.swift` (new), `Sources/SiftApp/AppDelegate.swift`,
`Sources/SiftUI/AppState.swift` (additive only — new members appended after `stopPolling()`, plus
`import SiftCore` and two free functions at the end of the file, so it merges with the filter-bar
task).

---

## What shipped

**`KeyNav.swift`** — every decision the keyboard makes, in the target a test can import.
`NavKey`, `rowTarget(for:firstRow:rowsOnScreen:total:)`, `maxFirstRow(total:rowsOnScreen:)`,
`gotoRowTarget(_:rowsOnScreen:total:)`, `navKey(for:command:)`,
`tableIndex(forCommandKey:)`. Ported from `keyNav`/`jumpToRow`/`gotoRow`
(`web/index.html:739-777`) and the ⌘1–⌘9 handler (`:1801-1806`).

**`AppState.swift`** — `ModalSheet`, `modalSheet`, `selectTable(atIndex:)`, `toggleSidebar()`,
`toggleInspector()`, `presentExport()`, `presentMerge()`, `presentStaged()`, `presentBadRows()`,
`closeActive()`, `open(paths:)`, `rowSummary`, plus free functions `rowSummaryText(_:)` and
`needsSheetPicker(_:)`.

**`AppDelegate.swift`** — the full menu bar, `validateMenuItem`, the title-bar controls,
`application(_:open:)` with a pre-launch buffer, the `NSOpenPanel`, `window.title` /
`representedURL` tracking via `withObservationTracking`, and the key monitor.
`.fullSizeContentView` moved here alongside the toolbar. Every action is one call into `AppState`.

---

## Three things that did not survive contact, each with the measurement

### 1. `NSToolbar` cannot be used at all — `NavigationSplitView` takes the window's toolbar

The plan's toolbar spec (`.toggleSidebar`, `+`, `.flexibleSpace`, the row label) was implemented as
an `NSToolbarDelegate` first. Measured, running:

```
TOOLBAR default asked
TOOLBAR item siftAdd
TOOLBAR item siftRows
ITEMS   ["NSToolbarFlexibleSpaceItem", "com.apple.SwiftUI.navigationSplitView.toggleSidebar",
         "com.apple.SwiftUI.splitViewSeparator-0"]
SAME false  DELEGATE Optional(<SwiftUI.ToolbarPlatformDelegate: 0x893cee1c0>)
```

The delegate *was* called and the items *were* built — and then `NavigationSplitView` inside the
`NSHostingView` replaced `window.toolbar` with an `NSToolbar` of its own. `insertItem` into the
replacement is refused (its delegate has never heard of `siftAdd`). Fixing it inside SwiftUI means
`.toolbar {}` in `RootView`, which is another task's file.

**What shipped instead:** an `NSTitlebarAccessoryViewController` (`layoutAttribute = .right`) —
the one strip in that window SwiftUI does not manage. The described layout survives intact:
SwiftUI's own sidebar toggle sits at the leading edge where `.toggleSidebar` was, and the Open `+`
and the row count sit at the trailing edge where `.flexibleSpace` put them. A bare `NSToolbar` is
still assigned at window creation so a toolbar exists at t=0, which is what makes
`.fullSizeContentView` safe. `.sidebarTrackingSeparator` is dropped for the reason the plan gives.

Two sub-measurements, both of which produced an invisible or truncated row count before being
fixed: an `NSStackView` inside a title-bar accessory measures **2 pt wide** unless its `frame` is
set from `fittingSize` by hand; and a borderless `NSButton`'s `intrinsicContentSize` under-reports
an `attributedTitle` badly (**66 pt** for a phrase `sizeToFit` measures at **136 pt**), so the row
count is an `NSTextField` with an `NSClickGestureRecognizer` rather than a button.

### 2. `NSRecentDocumentsMenu` produces a permanently empty menu

Carried over verbatim first, exactly as the plan asks. Measured, in a bundled build with
`CFBundleDocumentTypes` declared: with the identifier set AppKit adopts the submenu, and lists
nothing —

```
NOTE ["small.csv"] recents=["small.csv"]
NOTE ["mid.csv"]   recents=["mid.csv", "small.csv"]
… while the open submenu contained:  recent=1 |Clear Menu
```

`recentDocumentURLs` is correct and persists; AppKit fills that menu from the app's *document
classes*, and this app has none (it declares `CFBundleDocumentTypes` with no `NSDocumentClass`,
which is exactly what lets it appear in "Open With" without becoming document-based). **The
shipping shell's Open Recent has therefore always been empty** — carrying it over verbatim would
have carried over a menu that does nothing.

**What shipped instead:** the submenu is drawn from `NSDocumentController.shared.recentDocumentURLs`
in `menuNeedsUpdate`, most-recent first, each item carrying its full path as a tooltip (two files
can share a basename), with a separator and Clear Menu, or "No Recent Files" when empty. The *list*
is still AppKit's — `noteNewRecentDocumentURL` records, prunes and persists it. Only the drawing is
ours. Verified working end to end (below).

### 3. A nav key must be consumed even when the jump would not move

First version returned the event unhandled when `rowTarget` was `nil`. Measured: ⌘↓ at the bottom
of the table then fell through to AppKit, which **scrolled the grid back to row 0**. `nil` means
"already there", not "not ours", so the event is consumed either way now.

---

## Deliberate calls worth flagging

- **Menu titles AppKit rewrites.** "Toggle Sidebar" is drawn by AppKit as "Hide Sidebar" /
  "Show Sidebar", because the selector is the standard one. Left alone — that is what a Mac user
  expects to read, and it tracks the state correctly (verified both ways).
- **Nav keys are gated on the grid having focus.** Arrows/page keys are handled only when the first
  responder is inside the grid's scroll view, so the sidebar keeps its own arrow navigation and a
  text field keeps its typing. That is the native shape of the web's `if (tag === "input") return`.
  ⌘G and ⌘1–⌘9 are global.
- **The grid's scroll view is found by its gutter column identifier** (`__rownum__`). The sidebar's
  `List` is also an `NSTableView` in an `NSScrollView`, so "the first one" would hand the arrow keys
  to the sidebar. The string is quoted rather than shared because `TableGridView.swift` is another
  task's file; it is the whole of the coupling.
- **`.xls` does not route to the sheet picker**, though the web's regex (`/\.xlsx?$/i`) caught it.
  The engine refuses a legacy `.xls` with a sentence explaining why; a picker failing to unzip it
  would replace that sentence with a worse one. The set comes from `SiftCore.xlsxExt`, not a second
  copy.
- **A batch containing several workbooks opens the first one's picker and banners about the rest**
  rather than silently dropping them. Marked `ponytail:` with the upgrade path (a queue).
- **`View > Reload` dropped**, per the plan.

---

## What I ran, and what I saw

`swift run SiftApp` (and a throwaway `.app` bundle in scratch, for the LaunchServices paths). The
window and menus were driven and read back through the accessibility API — Screen Recording is not
granted, but Accessibility is, and it reports menu titles, enabled state, window title, proxy-icon
document URL, title-bar text and the grid's scroll position.

| Checked | What I saw |
|---|---|
| Menu bar structure | `Apple, Sift, File, Edit, View, Data`; File = Open…, Open Recent, ―, Export…, Close Table; View = Toggle Sidebar, Toggle Inspector, Enter Full Screen; Data = Merge Tables…, Manage Staged Data… |
| Enable/disable | Nothing open: Export… and Close Table **disabled**, Merge **disabled**. One table open: Export… and Close Table **enabled**. Two open: Merge **enabled**. |
| ⌘O / File > Open… | Panel opened, picked `small.csv`, table opened |
| `window.title` | Followed the active table (`small` → `big` → `mid`), back to `Sift` when the last table was closed |
| Proxy icon | Window `AXDocument` = `file:///…/big.csv` — the represented URL is set |
| Row count | `400,000 rows · 3 cols` for a 400k CSV, `30 rows · 2 cols` for a 30-row one, drawn at full width (134 pt, not truncated) |
| Dock drop / "Open With" | `open -a Sift.app small.csv` opened it, at launch and again into the running instance — that is `application(_:open:)` |
| Open Recent | Listed `mid.csv`, `small.csv`, ―, Clear Menu; picking `small.csv` opened it |
| ⌘1 / ⌘2 | Switched to the 1st and 2nd open table; title and row count both followed |
| ⌘G | Alert reads "Go to row" / "1 – 400,000"; typing the grouped `200,000` put the scroll bar at `0.50004` on a 400,000-row file |
| Arrows / PageUp / PageDown / ⌘↑ / ⌘↓ | All move the grid by the right amount, and clamp at both ends (repeating ⌘↓ at the bottom and ↑ at the top leave it where it is) |
| ⌘W | Closed the active **table**, selection moved to the remaining one, sidebar went 2 rows → 1, window stayed open |
| ⌘S | Split collapsed (3 AX children → 1) and restored; menu title flipped to "Show Sidebar" |
| About Sift | "Sift 0.0.0-verify" + the blurb + "DuckDB v1.5.5" |
| ⌘Q | Quit cleanly, process gone |

**What I could not check, stated plainly:**

- **Arrow keys after a real mouse click.** A synthesized `click at {x,y}` selected a grid row but
  did *not* move first responder to the grid's `NSTableView`, so the nav keys were verified after
  setting `AXFocused` on the table view instead. A real click makes an `NSTableView` first responder
  by AppKit's own `mouseDown`, but I did not post a hardware mouse event to prove it.
- **Window dragging with `.fullSizeContentView`.** I confirmed a toolbar is present and the title
  bar renders its title, traffic lights and toolbar button; I did not perform a real mouse drag.
- **Anything that needs a sheet.** ⌘E, ⇧⌘M, Manage Staged Data… and the clickable "N dropped" set
  `AppState.modalSheet` and no view renders it in this patch — the sheets are another task's files
  (`Sources/SiftUI/Sheets/`, `RootView.swift`). The same is true of the `.xlsx` routing: a workbook
  sets `modalSheet = .workbook(path:)` and waits for the picker. Those four menu items are
  therefore **inert until the sheets task lands**; the state they set, and the refusals around it,
  are what the tests cover.
- **`Toggle Inspector`** flips `inspectorVisible`, which nothing binds yet (Task 8's inspector).
- **A real `.app` bundle.** Verification used a hand-rolled bundle in scratch; `build-app.sh` at the
  repo root still builds the old shell and is out of scope here.

---

## Mutation results

36 mutations, one at a time, each reverted after. **35 killed, 1 equivalent.** Every test in
`KeyNavTests.swift` is killed by at least one.

| Mutation | Result | Killed |
|---|---|---|
| `maxFirstRow` drops the `rowsOnScreen` floor | KILLED | `aZeroHeightViewportIsTreatedAsOneRow` |
| `maxFirstRow` drops the zero floor | KILLED | `aTableShorterThanTheWindowCannotScroll` |
| a page is a whole screen, no context row | KILLED | `aPageIsOneScreenLessOneRowOfContext` |
| a page loses its `max(1,)` floor | KILLED | `aPageOnAOneRowViewportStillMovesOneRow` |
| down and up swapped | KILLED | `downAndUpMoveExactlyOneRow`, `upStopsAtZero`, `aFirstRowAlreadyPastTheEndIsPulledBack` |
| unchanged jump no longer returns `nil` | KILLED | `aJumpThatWouldNotMoveTheViewportIsNil` + 3 more |
| upper clamp removed | KILLED | `pagesClampRatherThanOvershoot`, `downStopsWithTheLastScreenfulShowing`, `aFirstRowAlreadyPastTheEndIsPulledBack` |
| `bottom` = last **row** (`total - 1`) | **EQUIVALENT** | — see below |
| `bottom` lands one row short (`last - 1`) | KILLED | `topAndBottomGoAllTheWay`, `aJumpThatWouldNotMoveTheViewportIsNil` |
| `top` lands one row down (`raw = 1`) | KILLED | `topAndBottomGoAllTheWay`, `aJumpThatWouldNotMoveTheViewportIsNil` |
| ⌘G is not one-based | KILLED | `goToRowIsOneBasedOnScreenAndZeroBasedInside`, `goToRowAcceptsAGroupedNumber` |
| ⌘G strips with `isNumber` | KILLED | `goToRowWithoutADigitIsRefusedRatherThanTreatedAsZero` (the `٣` case) |
| ⌘G treats no digits as row 1 | KILLED | same |
| ⌘G treats an over-large number as row 1 | KILLED | `goToRowClampsAtBothEnds` |
| ⌘-arrow is just an arrow | KILLED | `arrowsScrollAndCommandArrowsJumpToTheEnds` |
| bare Home/End are intercepted | KILLED | `pageKeysNeedNoModifierAndHomeEndNeedCommand` |
| nav key swallows an ordinary character | KILLED | `anOrdinaryCharacterIsNotANavigationKey` |
| ⌘N is the Nth, one-based | KILLED | `commandOneThroughNineSelectTheNthTable` |
| ⌘0 is the tenth table | KILLED | same |
| `.xls` also routes to the picker | KILLED | `workbooksRouteThroughTheSheetPickerAndNothingElseDoes` |
| extension match becomes case-sensitive | KILLED | same (`BOOKS.XLSX`) |
| a workbook opens without the picker | KILLED | `openingABatchOpensTheOrdinaryFilesAndQueuesOneWorkbook` |
| the extra workbooks are dropped silently | KILLED | same (the banner half) |
| an out-of-range ⌘N clears the selection | KILLED | `commandNumberSelectsByPositionAndIgnoresAnIndexThatIsNotThere` |
| the sidebar toggle only closes | KILLED | `toggleSidebarAndInspectorGoBothWays` |
| the inspector toggle only opens | KILLED | same |
| export opens with nothing open | KILLED | `exportAndBadRowsRefuseWhenThereIsNothingToActOn` |
| bad rows opens with no bad rows | KILLED | same |
| merge is wired to the staged sheet | KILLED | `mergeAndStagedAreAlwaysReachable` |
| close-active closes nothing | KILLED | `closeActiveClosesTheOpenTableAndIsANoOpWithNothingOpen` |
| a count in flight shows the estimate anyway | KILLED | `aCountInFlightSaysSoRatherThanShowingTheEstimate` |
| an estimate is presented as a count | KILLED | `anEstimatedCountIsMarkedApproximate` |
| the row phrase does not group its digits | KILLED | `theRowPhraseGroupsItsDigitsAndNamesTheColumns`, `theToolbarIsEmptyWithNothingOpenAndFollowsTheActiveTable` |
| zero dropped rows is still announced | KILLED | `droppedRowsAreCountedOnlyWhenThereAreSome` + 1 |
| the filtered phrase quotes one count twice | KILLED | `aFilteredCountIsShownAgainstTheUnfilteredOne` |
| nothing open invents a row count | KILLED | `theToolbarIsEmptyWithNothingOpenAndFollowsTheActiveTable` |

**The equivalent mutant, and why it is not a vacuous test.** `case .bottom: raw = last` →
`raw = total - 1` survived. It is behaviourally identical for *every* input: `last` is
`total - max(1, rowsOnScreen)`, so `last <= total - 1` always holds and the very next line's
`min(raw, last)` collapses the two. The two replacement mutants above (`last - 1` and `top`
returning `1`) are not equivalent, and both go red.

---

## Concerns for whoever integrates this

1. **Four menu items and the workbook routing are inert until the sheets land.** ⌘E, ⇧⌘M, Manage
   Staged Data…, the "N dropped" click, and every `.xlsx`/`.xlsm` set `AppState.modalSheet` and stop
   there. Binding `modalSheet` in `RootView` is the last wire.
2. **`AppState.ModalSheet` may collide with whatever the sheets task named its own presentation
   state.** It is nested inside `AppState` and the property is `modalSheet`, to keep the collision
   surface as small as possible.
3. **The grid taking first responder is worth one human click.** If a real click does not focus the
   grid, the arrow keys will look dead — the fix would be a `makeFirstResponder` in
   `TableGridView.makeNSView`, which is not this task's file.
4. **The `"__rownum__"` string in `AppDelegate.gridScrollView()`** is coupled to
   `TableGridView.swift`'s private `gutterID`. If that identifier is ever renamed, keyboard
   navigation stops silently.
