# The preamble that ate the file

Status: **done.** 447 -> 456 tests, all green, parallel, no `.serialized`, warning-free from a wiped
`.build`. `sift --verify` is 19 checks, 19 passed. Built on `d4c31ef`.

## The defect

Second instance of the class the ragged fix addressed, found by hand-checking one of that fix's own
false-positive controls. Three lines of prose:

```
notes
this is prose, with a comma
another line; semicolon too
```

printed **0 rows**, two columns the user never wrote, and no note:

```
prose — csv — 0 rows
no rows dropped

  another line   VARCHAR  text
  semicolon too  VARCHAR  text

  (no rows)
```

Measured: the sniffer picks `;` (off line 3), sets `SkipRows: 2`, and uses line 3 as the header. Two
thirds of the file discarded as preamble, the remaining third turned into column names.

## What the detection keys on, and why

**`rowCount == 0` AND `skip > 0`** — a file with content in it produced no rows, having thrown lines
away to get there. Both halves are already on the `SourceSpec`, so the detector is pure, reads no
bytes, and needs no new field:

```swift
public func preambleAteTheFile(_ spec: SourceSpec) -> Int? {
    guard spec.fmt == .csv, spec.rowCount == 0,
        case .int(let skipped)? = spec.readArgs["skip"], skipped > 0
    else { return nil }
    return skipped
}
```

**Why not a line count, which was the steer.** Measured on the file itself, the arithmetic
**balances**: 2 skipped + 1 header + 0 rows = 3 lines. Every line is accounted for. `lines > skip +
header + rows` is *false* here, so a line-count-versus-row-count comparison **cannot detect this
defect at all** — and it would cost a read of a file we know nothing good about. The same
measurement rules out the cheaper "are there bytes past the header" variant (`headerByteOffset` is
already available and would have been free): the preamble *ate* the file, so there are no bytes
past the header either. Nothing is missing in a counting sense; the problem is **which** lines were
discarded, not how many. That is why the tell has to be "lines were thrown away and nothing
survived" rather than any arithmetic over totals.

So: no file read, at any size. The "do not pay it when the row count is healthy" constraint is met
by construction rather than by a guard.

**`skip > 0` is the guard the steer asked for**, and it is the right one on the evidence. Every
zero-row file I could construct that must stay quiet has `SkipRows: 0`:

| file | delim | SkipRows | rows | fires? |
|---|---|---|---|---|
| **the defect** — 3 lines of prose | `;` | **2** | **0** | **yes** |
| 2-line variant of the same | `,` | 1 | 0 | yes |
| header and nothing else | `,` | 0 | 0 | no |
| header + trailing blank line | `,` | 0 | 0 | no |
| genuinely empty file | `,` | 0 | 0 | no |
| one line, no trailing newline | `,` | 0 | 0 | no |
| **3 junk lines + 200 real rows** | `,` | 3 | 200 | no — rows survived |
| 3 blank lines + header + data | `,` | 3 | 1 | no |

The header-only file is the one that looks identical to the defect from the row count alone, which
is exactly why the row count alone is not the rule. And `skip` is a **feature** — `makeCSV` has a
`preamble:` parameter and the shared corpus's `weirdCSV` is 3 junk lines, a BOM, CRLF and 300 real
rows; only a skip that ate everything gets a word.

One boundary, stated rather than papered over: `rowCount` is `nil` for a compressed or over-64MB
CSV at build time (the exact count arrives later, through `Session.swift`, which is not mine this
session). **An unknown row count is not zero** and does not fire — firing there would claim a file
is empty on the strength of not having looked. There is a dedicated test for it, and a mutation
that turns `rowCount == 0` into `rowCount ?? 0 == 0` is killed by it.

## The note

> The first 2 lines were skipped as a preamble, which left no rows at all — re-open without skipping to see them

Pluralised (`The first line was` for one), same voice as the sheet/folder/Delta/ragged notes,
seeded in `Table.init` from the spec alongside the ragged note so no construction site can lose it.
What Sift *shows* is unchanged — still the sniffer's own two columns and empty grid.

## The way out

`buildSource(con, path:, skipPreamble: false)`, mirroring `nullPadding` exactly: it pins `skip=0`
on the sniff so the sniffer cannot discard the file's data. Measured recovery — 1 column `notes`,
both lines of prose back:

```
read_csv(prose.csv, skip=0)  ->  cols ["notes"], 2 rows
                                 ["this is prose, with a comma"], ["another line; semicolon too"]
```

Unlike the ragged note's column count, this one promises no number and needs no measuring pass:
pinning `skip` to 0 on a file that skipped at least one line structurally cannot come back with
less than it had.

**The two escape hatches are alternatives, not combinable, and that is a DuckDB fact.**
`skipPreamble: false` works by pinning `skip` — and a pinned `skip` is precisely what defeats
`null_padding` (the landmine documented last round). Asking for both would silently get neither.
Nothing needs them together: a file that collapsed into one column still has rows, and a file whose
preamble ate it has none. Documented on `buildSource` rather than enforced, since no caller wants it.

## Mutation results — 12 run, 11 killed, 1 bad mutation

| # | mutation | killed by |
|---|---|---|
| N1 | drop the `skip > 0` half (header-only files now fire) | 4 tests, incl. both false-positive suites |
| N2 | treat an UNKNOWN row count as zero | `preambleAteTheFileNeedsBothHalvesOfTheTell` |
| N3 | drop the `rows == 0` half (real preambles now fire) | 4 tests, incl. `aRealPreambleInFrontOfRealDataStaysSilent` |
| N4 | stop pluralising ("The first 1 lines were") | `preambleNoteSaysHowMuchWasLostAndHowToGetItBackOrNothingAtAll` |
| N5 | change the sentence | that test + the `--verify` check |
| N6 | `sniffCSV`: silently ignore `skipPreamble` | `notSkippingIsTheWayOutAndItReallyGetsTheRowsBack`, the check |
| N7 | `buildSource`: drop `skipPreamble` on the way to the sniff | same |
| N8 | `Table.init`: stop seeding the preamble note | the check + the CLI end-to-end test |
| N9 | fixture: remove the semicolon the sniffer latches onto | both end-to-end tests (the check is not a no-op) |
| N10 | fixture: remove the comma from line 2 | the `--verify` check |
| N12 | fixture: give the preamble control no preamble at all | the `--verify` check (the control really is one) |
| N11 | fixture: give the preamble control no header | **survived — bad mutation** |

N11 is reported for honesty, not as a gap: removing the header from the "real preamble + real data"
control still leaves it a real preamble in front of real data, so the property the test claims is
not violated and nothing should have gone red. N12 is the mutation that actually tests that
control's integrity, and it is killed.

The regression test was written first and observed failing on `d4c31ef`
(`aFileWhosePreambleAteItSaysSo`, on the rendered `sift <path>` output).

## Files

Source: `SiftCore/Source.swift` (`preambleAteTheFile`, `preambleNote`),
`SiftEngine/SourceProbe.swift` (`sniffCSV`/`buildSource` `skipPreamble:`),
`SiftEngine/Table.swift` (note seeding), `SiftEngine/Verification.swift` (three fixtures + the
`skipped preamble` check).
Tests: `SiftCoreTests/SourceTests.swift`, `SiftEngineTests/SourceProbeTests.swift`,
`SiftEngineTests/VerificationTests.swift`.

No new `SourceSpec` field this time — the whole tell was already in the spec.

Not touched: `Session.swift`, `SessionQueries.swift`, `Staging.swift`,
`ProfileGenerationTests.swift`, `Sources/sift/main.swift`, `engine/`, `web/`, `shell/`,
`.github/workflows/ci.yml`.

## Note for the pending `Session.openPath` wiring

When the three lines for `nullPadding` go in, `skipPreamble` wants the same treatment — it is the
same shape and the same default:

```swift
public func openPath(_ path: String, name: String? = nil, sheet: String? = nil,
                     nullPadding: Bool = false, skipPreamble: Bool = true) async throws -> Table {
    spec = try buildSource(con, path: resolved, sheet: sheet,
                           nullPadding: nullPadding, skipPreamble: skipPreamble)
```
