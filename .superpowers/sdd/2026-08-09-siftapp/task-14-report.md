# Task 14 report: the sources sidebar at parity

**Status:** complete. 670 tests (650 base + 20 new), warning-free from a wiped `.build`, no
`.serialized` anywhere, suite runs in parallel. 11 mutations applied, 11 killed, 0 survivors — one
of which found a real bug and is fixed here.

**Rebased onto `b40d291`, not `701705d`.** Task 13 landed mid-task and it changes this task's job in
two places (see "Two collisions with Task 13" below) — building on the older base would have handed
over a patch that adds a second copy of two things Task 13 now owns.

Composition was verified rather than assumed: applied onto `577056f` (the filter bar and banner
stack, which landed on the same file while this was being written), it builds warning-free and the
whole suite is green at **705 tests**. The two edits to `RootView` do not overlap — that task owns
the detail `VStack`, this one owns the sidebar slot and the window modifier, and
`NothingOpenYet(onOpen: onOpen)`'s call site is touched by neither.

Files touched:

- `Sources/SiftUI/SourceSidebar.swift` (new)
- `Tests/SiftUITests/SourceSidebarTests.swift` (new)
- `Sources/SiftUI/RootView.swift` (three hunks, none inside the detail `VStack`)
- `Sources/SiftUI/AppState.swift` (**one hunk, a 14-line deletion** — `rowSummaryText`'s inlined
  copy of the row-count decision tree, now a call to `rowText`)

Nothing under `engine/`, `web/`, `shell/`, `.github/` or the legacy repo-root files was modified;
`web/index.html` was read as the parity oracle and nothing else.

---

## Two collisions with Task 13, both resolved by deleting my copy

**1. The sheet-picker routing and the path queue.** Task 13 shipped `AppState.open(paths:)`,
`needsSheetPicker(_:)` and `ModalSheet.workbook(path:)`, all tested. My first pass had a
`SourceOpener` with its own workbook queue, its own `offersSheetPicker` call and its own
`SheetPickerSheet` presentation. **Deleted.** The sidebar's path box and the window drop now both
call `AppState.open(paths:)` — the same entry the open panel, the Dock icon and Finder "Open With"
use — so there is one place that decides what a workbook is.

**2. `rowText`.** Task 13's `rowSummaryText` contained a byte-for-byte equivalent of
`web/index.html:958-963` inlined, and this brief names `rowText` as a deliverable. That is
[commit 3c114b4](../../..) again — "Two tasks wrote compactCount, and only one of them was right".
`rowSummaryText` is now `"\(rowText(table)) · N cols"` plus the dropped tail: **one decision tree,
two suites pointing at it.** Task 13's tests assert the whole toolbar sentence and stay green
unchanged; mine assert the phrase. If Andrew would rather not carry an `AppState.swift` hunk in this
patch, dropping it leaves both copies compiling and agreeing today — and free to drift tomorrow.

## The four sentences

Everything the sidebar says is a free function beside the view, because a `body` cannot be tested.

| Function | Ports | Note |
|---|---|---|
| `sourceSubtitle(_:)` | `web/index.html:966-972` | `fmt · size · N rows · staged` |
| `rowText(_:)` | `web/index.html:958-963` | onto Task 5's `displayRows`/`rowsAreExact` |
| `formatBadge(_:)` | `SourceCell.symbol(for:)` / `.tint(for:)` | exhaustive over `Fmt`, no `default` |
| `sourceTooltip(_:)` | `SourceCell.configure`'s `toolTip` | path, subtitle, dropped rows |

Three parity details that were easy to lose, each pinned by its own test:

- **`glob_` → `▤ `.** A folder of parquet reads `▤ parquet · 12.0 MB · 900 rows`. `glob_parquet` in
  the window is engine vocabulary leaking into the UI.
- **A merge view has no size.** `merge`'s `SourceKey` is `("merge://a+b", 0, 0)`, so the web's falsy
  `if (t.size)` is `size > 0` here — a `0 B` segment would be a claim about a file that does not
  exist. `merged · 1,204 rows`.
- **`≈ N rows` is reachable now.** It fires on `!rowsAreExact`, which before Task 5a's estimate
  fallback was nil-shaped: `displayRows` was `nil` in exactly the case the branch exists for, so
  every unexact table took `counting…`. `theSidebarsRowPhraseMarksAnEstimateAsApproximate` asserts
  `t.displayRows == 2_400_000` *and* the sentence; mutation 1 (removing the fallback) turns both red.

Counts go through `SiftCore.groupDigits`, sizes through `SiftUI.humanBytes`. The formatter grep is
empty:

```
$ grep -rnE '(NumberFormatter|DateFormatter|ISO8601DateFormatter|ByteCountFormatter)\(|\.formatted\(' Sources/SiftUI Sources/SiftApp
$
```

## The row

Chip (tinted rounded rect + SF Symbol), name, subtitle, a `ProgressView` while `rowCount == nil`, an
orange subtitle the moment `badRows > 0`, and — revealed on hover, at `opacity(0)` rather than
conditionally inserted, so nothing jumps — ⤓ and ×.

**The armed close is kept.** `closeConfirmed(armedAt:now:)` is the decision, tested at the boundary
in both directions; the red `xmark.circle.fill` and the 2.5 s disarm are presentation around it. It
exists because closing a table throws away its staged-copy adoption and its cached profile, and the
× sits a few pixels from the row you click to select.

Context menu, in the brief's order and copy: `Export as ▸` (the six, labelled by `exportLabel` over
`SiftEngine.exportFormats` — no second format table), `Stage This File` /
`Read from Source (unstage)` when it applies, ―, `Copy Full Path`, `Copy Table Name`,
`Reveal in Finder`, ―, `Close`.

- **Export** ports the shell's `exportViaSavePanel`: pick a destination with `NSSavePanel`, then
  `Session.export(..., overwrite: true)` — the panel has already asked about overwriting by the time
  it returns `.OK`, so that flag is not a second silent decision. The toast is Task 12's
  `exportToast`.
- **Close** goes through `AppState.close`, so the engine's refusal when a live merge reads this table
  arrives on the banner as its own sentence. Not cascaded, not swallowed.
- **Stage/unstage** ports `window.siftStage`: staging is a background job the poll loop picks up,
  unstaging is immediate and refreshes before the sentence lands.

`stageableFormat(_:)` restates `SidebarViewController.stageable` rather than reading
`SiftCore.neverStage`, which is `internal` — and it is menu applicability, not policy.
`Session.stageNow` remains the authority on whether a copy happens.

## Below the list

Dropzone (`web/index.html:342`), path box, drop note — all restorations, unreachable inside
`Sift.app` only because `body.native` hid the rail.

`autoOpenPath(from:to:)` ports the paste handler at `:1796-1799`. SwiftUI's `TextField` has no paste
event, so the rule is **"more than one character arrived at once"** plus the web's own
`startsWith("/") && !includes("\n")`. Growth is what makes it honest: typing can never add two
characters in one change, so hand-typing a path cannot fire it on the first keystroke the way a bare
`hasPrefix("/")` would. Tested from both sides.

## The window drop

`.onDrop(of: [.fileURL], isTargeted:)` on the whole window, and **the drag-hover highlight is
restored**: the shell drove `window.siftDragHint` at `.dropzone.hot` and `.gempty.drop`, so
`isTargeted` here lights the sidebar's dropzone *and* the no-file-open pane. Without it a drag over
the window gives no feedback at all, which reads as "drops are not supported here". It travels as an
environment value (`\.sourceDragHot`) because the two places that light up are on opposite sides of
the split while the drop is on the window above both — and because that keeps `RootView`'s diff to
three hunks with a sibling task editing the same file.

`droppedPaths(from:)` is the only decision the drop makes: which real filesystem paths the drag was
carrying. Everything after that is `AppState.open(paths:)`.

**A drop whose providers resolve to nothing sets the banner** rather than doing nothing — `.fileURL`
is what was asked for, so an empty result is a promise the drag broke.

**🔴 A bug this found.** Mutation testing turned up that `url.isFileURL` was missing:
`URL(dataRepresentation:)` is permissive, and bytes that are not a URL come back as a *relative* URL
whose `.path` is the raw string rather than as `nil`. A provider claiming `public.file-url` and
handing over plain text would have become a path, and the user would have got
`No such file or folder: just some text` for a drag they never made. Guard added, test added, and
removing the guard now turns it red.

The browser copy-the-file path (`uploadFile`, `/api/upload`, `SIFT_MAX_UPLOAD_MB`) is **not** ported;
spec §8 deletes it, and an AppKit drop always knows where the file lives.

## The `RootView` edit

Three hunks: the placeholder `List` → `SourceSidebar(state:)`, `.sourceDrop(state:)` beside
`.inspector`, and `NothingOpenYet` reading `@Environment(\.sourceDragHot)` and tinting its background
under a drag. **Nothing inside the detail `VStack` changed** — `NothingOpenYet(onOpen: onOpen)`'s
call site is untouched, which is why the last one goes through the environment instead of a
parameter.

## Verification

**`ImageRenderer`, not `cacheDisplay`** — `cacheDisplay` cannot capture an `NSVisualEffectView` and
the real sidebar sits on one.

**🔴 `ImageRenderer` cannot draw a `List`.** It is an `NSTableView` underneath, and the first version
of the render test proved it: `SourceSidebar` with a real CSV and a real parquet open came back with
*neither* chip, under one yellow square with a no-entry sign where every row should have been. The
rows are therefore rendered as `SourceRow` directly (which also lets them run over synthetic tables
instead of a live engine), and `SourceSidebar` is rendered for its dropzone and drop note, which are
pure SwiftUI and draw fine. **Swapping `List` for a hand-rolled `LazyVStack` would render, and is
deliberately not done** — the inset selection pill, sidebar metrics and keyboard navigation are why
`SidebarViewController` used `.sourceList`, and a test is not worth losing them. Stated in the test
file's header so it is a known gap rather than an assumed one.

What the renders showed (PNGs under `SIFT_RENDER_OUT`, all six looked at):

- `row-csv`, `row-parquet`, `row-merge` — green/purple/pink chips with the right symbols, name in
  semibold, subtitle beneath, no layout collapse.
- `row-dropped` — subtitle fully orange, reading `csv · 41.2 MB · 2,400,334 rows` (12,004 dropped
  rows correctly off the total).
- `sidebar-empty` / `sidebar-empty-drag` — dashed dropzone going solid-accent and blue-filled under
  a drag; "Nothing open yet."; the drop note with **in place** bold.

**No render assertion is a magnitude.** Nothing compares a pixel count to a number and nothing has a
`* scale` margin in it. Every one is a relationship between two renders on the same machine: the
parquet row has violet ink and no green while the CSV row has green and no violet; the three formats
produce three distinct digests; `amber` appears only in the row that dropped rows; the drag-hot
sidebar differs from the cold one. `verdant` and `amber` are disjoint by construction, so the orange
in the dropped-row check cannot be the green chip answering for the subtitle.

`pixelDigest` uses `Hasher.combine(bytes:)` and never `combine(Data)` — Foundation's `Data.hash`
mixes in at most the first 80 bytes, which here is the blank margin above the chip.

**Mutation results — 11 applied, 11 killed:**

| # | Mutation | Killed by |
|---|---|---|
| 1 | `displayRows` loses its estimate fallback | `theSidebarsRowPhraseMarksAnEstimate…`, `aTableWithOnlyAnEstimate…` |
| 2 | every chip gets one tint | `aSourceRowDrawsItsOwnFormatsChip…` (both directions) |
| 3 | the `badRows > 0` orange is dropped | `…TurnsItOrangeWhenRowsWereDropped` |
| 4 | the `staged` segment is dropped | `aStagedCSVReads…` **and** the row digest |
| 5 | `\.sourceDragHot` never reaches the dropzone | `anEmptySidebarStillDrawsTheDropzone…` |
| 6 | `closeConfirmed` always returns false | `theCloseNeedsTwoPresses…` |
| 7 | `glob_` left unreplaced | `aFolderSourceReads…` |
| 8 | the paste rule drops its "grew by more than one" guard | `aPastedAbsolutePathOpens…` |
| 9 | one unresolvable provider `break`s the drop | `aDropOfSomethingThatIsNotAFile…` |
| 10 | the drop reverses the order files arrived in | `aDropResolvesEveryFileURL…` |
| 11 | `url.isFileURL` removed | `aDropOfSomethingThatIsNotAFile…` — **this one found the bug above** |

Also run: `swift build` from a wiped `.build` with no warnings, the full 670-test suite in parallel,
and an 8-second launch of `SiftApp` (no crash on startup). The GUI was not driven by hand in this
clone.

## Deliberately dropped

- The web rail's `<h3>Open sources</h3>` heading. `SidebarViewController` set `headerView = nil` and
  a `NavigationSplitView` sidebar needs no label for the only list in it.
- The rail's `Data` button group (Merge / Export / Staged). The parity walk sends those to Task 13's
  menus, and Task 13 shipped them.
- The browser upload/spill path, per spec §8.

## Concerns

1. **`SourceSidebar`'s rows have no pixel coverage** for the `List` reason above. `SourceRow` does,
   and the sidebar's job over it is `List { ForEach }` — a regression *between* them (wrong id, wrong
   selection binding) would not be caught by a bitmap.
2. **🔴 Nothing presents `AppState.modalSheet`.** Task 13 sets `.workbook`, `.export`, `.merge`,
   `.staged` and `.badRows`, and its own comment says "rendered by `RootView`'s sheet presentation"
   — which does not exist on `b40d291` and still does not exist on `577056f` (checked). **So a
   dropped or pasted `.xlsx` sets the modal and nothing appears**, exactly like File > Export… and
   every other menu item that routes through it. Not this task's gap, but this task is what makes a
   drop reach it, so it is now reachable three ways instead of one. One `.sheet(item:)` on
   `RootView` closes all five at once and is the last wire in Plan 4.
3. **Concurrency annotations are CI's call.** `droppedPaths(from:)` had to become `@MainActor`
   (`NSItemProvider` is not `Sendable`, and the compiler is right); this Mac compiles the result
   clean, and macos-15 is the only oracle.
4. **The sidebar's export is the shell's `NSSavePanel` flow, not Task 12's `ExportSheet`.** That is
   the parity port — the shell's ⤓ picked a format and a destination and wrote. Both go through
   `Session.export`; they are two entry points, not two implementations.
