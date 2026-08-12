# Task 12 report: the five sheets

**Status:** complete. 574 tests (550 base + 24 new), warning-free from a wiped `.build`, no
`.serialized` anywhere, suite runs in parallel. 23 mutations applied, 23 killed, 0 survivors.

Built against base commit `905fc15` in an isolated clone. Files touched, and only these:

- `Sources/SiftUI/Sheets/BadRowsSheet.swift`
- `Sources/SiftUI/Sheets/StagedDataSheet.swift`
- `Sources/SiftUI/Sheets/ExportSheet.swift`
- `Sources/SiftUI/Sheets/MergeSheet.swift`
- `Sources/SiftUI/Sheets/SheetPickerSheet.swift`
- `Tests/SiftUITests/SheetsTests.swift`
- `Sources/SiftEngine/Staging.swift` (`StagePolicy`, `Session.stagePolicy()`, two `private` →
  internal)

`RootView.swift`, `AppState.swift`, `TableViewModel.swift`, `InspectorView.swift`,
`TableGridView.swift` and `ColumnLayout.swift` are untouched. Every sheet is a standalone `View`
a caller presents; none of them reaches into `AppState`, and each hands its result back through a
closure so the presenting task owns that seam.

---

## The shape each sheet has

A SwiftUI `body` cannot be tested, so the split `RootView.gridState` and `GridBridge` already made
for the grid is repeated here: **every decision lives in a free function beside the sheet, and the
`body` only arranges them.** That is where the 24 tests point, and it is why 23/23 mutations died.

| Sheet | Presented as | Hands back |
|---|---|---|
| `BadRowsSheet` | `(session:table:)` | nothing — read-only |
| `StagedDataSheet` | `(session:)` | nothing — purges in place |
| `ExportSheet` | `(session:table:onExported:)` | the toast sentence |
| `MergeSheet` | `(session:tables:initialLeft:onMerged:)` | the new `Table` |
| `SheetPickerSheet` | `(path:onOpen:)` | the chosen sheet names, in workbook order |

Dismissal is `@Environment(\.dismiss)`, so a caller presenting with `.sheet` gets it free.

**No engine error is wrapped and none is swallowed.** Each sheet renders the engine's own sentence
as itself. `ExportSheet` and `MergeSheet` deliberately *stay open* on a failure (the web build's
behaviour) so the destination or the key can be fixed without retyping the form; `StagedDataSheet`
shows the error above the list rather than falling back to "Nothing staged.", which would be the
panel lying about a store it could not read.

## What each sheet does, and the parity decisions inside it

### Bad rows — the headline claim

`badColumnNames(in:)` matches on `Cell.list` and pulls the failing column names out element by
element. It never touches `display`. The doc comment says so in capitals, and
`badColumnNamesReadsTheListAndNeverResplitsAJoinedString` drives it with a column literally named
`a,b` — the case a joined string cannot survive and the entire reason the LIST decoding Critical
was closed in the engine work.

Sample cells go through `SiftEngine.glyph(for:kind:)` capped at the web's 60 characters. Never
`Cell.display`: `aSampleCellIsTheEngineGlyphAndIsCappedAtSixtyCharacters` pins NULL and `''` as two
different strings, which `display` collapses.

Rendered against a real dirty file, the panel reads:

```
1 row dropped
1 cell could not be cast to the detected type, so DuckDB skipped the whole row. These are not
in the grid or in any aggregate. Reading the column as text instead keeps them.

bad_columns   order_id   region   amount
[amount]      21000      West     N/A          ← "N/A" is red; the other three are not
```

`order_id` is ungrouped there on purpose: this panel reads the **all-varchar** relation, so every
value arrives as text and the engine glyph renders it verbatim — which is exactly what the web
panel does (`esc(String(v))`, no `fmtInt`).

### Staged data

The policy sentence comes from `Session.stagePolicy()`, added to the engine for this. `SiftUI`
never reads `SIFT_STAGE_BUDGET_GB` or `SIFT_STAGE_MAX_AGE_DAYS` — one authority. The budget is
spelled with `budgetBytes / 1_073_741_824`, exact integer division, so it reads **`capped at 20
GB`** and not the `20.0 GB` `humanBytes` would produce. A mutation that swapped the divisor for
10⁹ was killed by two tests.

`lastUsed` is hand-rolled from `Calendar.current.dateComponents` and zero-padded — no
`DateFormatter`, no `ISO8601DateFormatter`. A mutation deleting the padding was killed.

A `drop` reloads rather than removing the row optimistically, because `purgeStagedTables` skips
anything still open — a row genuinely can survive its own drop, and the panel has to be honest
about that.

### Export

`SiftEngine.exportFormats` is the only format table. `SiftUI` supplies six labels and nothing
else. `everyFormatTheEngineOffersHasALabelAndTheOrderIsTheEngines` asserts the keys, the order
*and* that no key falls through to `exportLabel`'s raw-key `default` — so adding a seventh format
to the engine turns that test red rather than shipping a menu entry reading `avro`.

The picker's selection binds to the `String` key and iterates `ForEach(exportFormats, id: \.key)`,
because `ExportFormat` is `Equatable` but not `Hashable`/`Identifiable`.

`retargetExtension` ports the web's `replace(/\.[a-z0-9]+$/i, "." + ext)` **including its refusal
to append an extension where there is none** — the user typed that path, and silently renaming
their file is not this sheet's call. A mutation that added the append was killed.

The sheet builds no SQL, does not pre-check whether the destination exists, and does not touch
`overwrite` logic: Export.swift's rule 3 makes claiming the name *be* the existence check, and a
check up here would reintroduce the check-then-write race the engine closed.

### Merge

The picker binds to `JoinType.allCases` and renders `rawValue`. No string ever becomes a join
keyword.

The overlap preview is live on every key tick — `joinProbe` is two DISTINCT counts and a SEMI
JOIN, which is why it can be a preview rather than something you press a button for. Against two
real tables it reads `7 of 10 distinct order_id in orders match returns → 70.0%` plus
`3 unmatched (kept only by a left/full join)`. `joinPercent` keeps the web's two-decimal band for a
real-but-tiny overlap so `0.005` reads `0.50%` and not a flat `0.0%` that looks like no match at
all.

**Closing a source under a live merge stays a refusal.** The sheet does not cascade, does not
pre-close anything, and does not paper over the sentence.
`closingASourceUnderALiveMergeIsRefusedWithASentenceNamingIt` asserts the exact text and that the
merge view survives the refusal. Mutating `merge` to stop recording `mergedFrom` killed it.

`unmatchedKeys` stays unsurfaced, per the brief.

### Sheet picker

Presented for **every** workbook, whatever its sheet count, and the plural subtitle keeps the
web's `1 sheets`. Both are pinned by tests so a later "improvement" is a red test, not a silent
behaviour change.

**One deliberate divergence from the web, in two directions.** `offersSheetPicker` uses
`SiftCore.xlsxExt` (`.xlsx`, `.xlsm`) rather than the web's `/\.xlsx?$/i`. That regex routes a
legacy `.xls` — an OLE2 file, not a zip — into a picker that cannot read it, so the user gets an
unzip error instead of the "re-save it as .xlsx" sentence `detectFormat` already spells; and it
misses `.xlsm`, which this engine reads perfectly well. The engine's own set is the authority on
what a workbook is. A mutation restoring the web regex was killed.

`listSheets` runs on a detached task — it shells out to `/usr/bin/unzip` once per worksheet and
blocks on the pipe, which on the MainActor is the window freezing for the length of the scan.

---

## Mutation testing — 23 applied, 23 killed, 0 survivors

Each was applied to the real source, the suite run, and the source restored.

| # | Mutation | Killed by |
|---|---|---|
| M1 | `badColumnNames` re-splits a joined `display` string | `badColumnNamesReadsTheListAndNeverResplitsAJoinedString`, `theBadRowsPanelNamesTheColumnThatFailedAndNoOther` |
| M2 | `badRowsHeadline` always plural | `theBadRowsHeadlineAndParagraphCountRowsAndCellsSeparately` |
| M3 | `badCellText` drops the 60-character cap | `aSampleCellIsTheEngineGlyphAndIsCappedAtSixtyCharacters` |
| M4 | `badCellText` uses `Cell.display` instead of the engine glyph | `aSampleCellIsTheEngineGlyphAndIsCappedAtSixtyCharacters` |
| M5 | `BadCell` paints every cell the same colour | `theOffendingCellIsPaintedRedAndItsNeighbourIsNot` |
| M6 | `humanBytes` groups its byte branch (`SiftCore.human`'s shape) | `humanBytesIsTheWebsLadderExactly` |
| M7 | `stageBudgetGB` divides by 10⁹ instead of 2³⁰ | `stagePolicyReportsTheLimitsThisSessionIsEnforcing`, `theStagePolicySentenceStatesWholeGigabytes` |
| M8 | `stagedTimestamp` drops the zero padding | `aStagedTimestampIsYearMonthDayHourMinuteWithNoFormatter` |
| M9 | `stagedSourceMarker` checks "changed" before "gone" | `aMissingOrChangedSourceIsMarkedAndAHealthyOneIsNot` |
| M10 | `exportLabel` loses one label and falls through to the raw key | `everyFormatTheEngineOffersHasALabelAndTheOrderIsTheEngines` |
| M11 | `retargetExtension` appends an extension the user did not type | `theDestinationFollowsTheChosenFormatsExtension` |
| M12 | `exportToast` prints two decimals of milliseconds | `theExportToastSpellsBytesDestinationAndMilliseconds` |
| M13 | `joinPercent` always rounds to one decimal | `aTinyRealOverlapKeepsTwoDecimalsAndAZeroKeepsOne` |
| M14 | `overlapSentence` swaps matched and the denominator | `theOverlapSentenceIsTheOneNumberThatStopsABadJoin` |
| M15 | `unmatchedSentence` shows the line when nothing is unmatched | `aPerfectJoinHasNoUnmatchedLine` |
| M16 | `mergeKeyPrompt` loses the same-table case | `theKeyPromptSaysWhichOfTheThreeSituationsThisIs` |
| M17 | `offersSheetPicker` uses the web's `/\.xlsx?$/i` | `thePickerIsOfferedForEveryWorkbookAndNotForALegacyXls` |
| M18 | `defaultSheetSelection` ticks the empty sheets too | `everyNonEmptySheetIsTickedAndAnEmptyOneIsListedButNot` |
| M19 | `sheetRowLabel` stops grouping its row count | `everyNonEmptySheetIsTickedAndAnEmptyOneIsListedButNot` |
| M20 | `sheetPickerSubtitle` "fixes" the plural | `aSingleSheetWorkbookStillGetsThePickerAndItsPluralSubtitle` |
| M21 | `mergeToast` drops the row count | `mergeToastCountsTheRowsTheNewViewActuallyHas` |
| M22 | `Session.stagePolicy` reports a budget it is not enforcing | `stagePolicyReportsTheLimitsThisSessionIsEnforcing` |
| M23 | `merge` stops recording `mergedFrom` (the close-refusal's input) | `closingASourceUnderALiveMergeIsRefusedWithASentenceNamingIt` |

One test in the file is a **pin rather than a guard** and is labelled as such:
`theCandidateKeysComeBackWithBothTypesAndTheirCompatibility` asserts the engine's own
`joinCandidates` shape, which is a dependency of this sheet rather than logic it owns. It would
not survive a mutation of anything in `Sources/SiftUI/Sheets/`, and it is not counted above.

## Verification, and one finding about how to do it

`theOffendingCellIsPaintedRedAndItsNeighbourIsNot` reads **pixels**, not properties, through
`NSHostingView` + `cacheDisplay(in:to:)` on a live `NSView` inside a plain borderless `NSWindow`.
It compares the *fraction* of ink that is red-dominant rather than "is there a red pixel",
because antialiased glyph edges carry colour fringes either way. `BadCell` had to become its own
small view for this — an inline `Text` with a modifier is not something a test can host.

🔴 **`cacheDisplay` on an `NSHostingView` captures only part of a SwiftUI tree.** Driving the five
sheets by hand, each one laid out and its `.task` ran, but a full-sheet capture came back with
only fragments drawn (a `TextField` and the one red cell, on a blank field); `layer.render(in:)`
was no better and came back vertically flipped as well. A **single leaf view** captures reliably,
which is exactly the shape the permanent pixel test uses. To see a whole composed sheet, use
`ImageRenderer` over a static composition instead — these sheets are pure SwiftUI, so the
`NSViewRepresentable` restriction that rules `ImageRenderer` out for the grid does not apply here.
That is how the bad-rows picture above was produced. Worth knowing before the next person spends
half an hour on it.

By hand, all five presented in a live window without crashing and composed to sane fitting sizes —
760×166 (bad rows, one sample row), 760×165 (staged, "Nothing staged."), 520×192 (export),
760×243 (merge, keys loaded), 520×172 (picker, three sheets listed from a real `.xlsx` built with
`/usr/bin/zip`).

## Concerns for whoever integrates this

1. **`humanBytes` is declared here and Task 9 owns it.** Task 9's brief produces
   `public func humanBytes(_ n: Int) -> String`; this branch needs it and was built against a base
   where Task 9 has not landed, so `StagedDataSheet.swift` carries a copy behind a loud
   `TASK 9 OWNS THIS — DELETE THIS BLOCK` comment. When the branches meet, Swift raises "invalid
   redeclaration" and the fix is deleting the block. That collision is deliberate: a compile error
   is a better outcome than two implementations quietly disagreeing about what 1023 bytes is
   called. The copy is written to task-9's own pinned values (`1023 → "1023 B"`, the web's ladder),
   which differ from `SiftCore.human` — that one groups its byte branch and says `1,023 B`.
2. **Nothing presents these yet.** Task 13 owns the seam. Each sheet's initializer and callback are
   listed in the table above; `offersSheetPicker(path:)` is the predicate `siftOpenPaths`' port
   should route on.
3. **`stagePolicy()` widened two `private` free functions in `Staging.swift` to internal.** No
   other file in that module defines those names, so a merge conflict there is unlikely, but it is
   the one engine file this task edits.
4. **The bad-rows test costs a 25,000-row CSV and a `gzip` subprocess.** That detour is
   load-bearing, not laziness: under `fullSniffMaxBytes` the sniffer reads the whole file and
   correctly widens the column to VARCHAR, leaving nothing to detect. A compressed CSV samples only
   the first 20,480 rows, which is what makes a genuinely dirty table reachable. It is a third copy
   of `SiftEngineTests`' `gzip` helper — SwiftPM test targets cannot import one another, the same
   trade-off `Fixtures.swift` records twice already.
5. **No real `.xlsx` in `SheetPickerSheet`'s automated coverage.** `listSheets` is already covered
   in `SiftCoreTests` against committed workbooks that `SiftUITests` cannot reach, so the tests
   here drive `sheetRowLabel`/`defaultSheetSelection`/`offersSheetPicker` over synthetic
   `SheetInfo`s. The one line that calls `listSheets` was exercised by hand against a real
   workbook (see above) but is not pinned by a test.
