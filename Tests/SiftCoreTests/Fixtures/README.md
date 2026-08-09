# Golden test fixtures

These four workbooks are committed rather than generated, and that is deliberate.

## Why they are not generated

Everything else in this suite's corpus is built at test time — CSVs are written directly,
parquet and Delta tables are produced by DuckDB itself. `.xlsx` is the exception, because
nothing in the native toolchain writes one. macOS ships `unzip` but not a spreadsheet
writer, and the package takes no third-party dependencies.

The tempting alternative is to hand-write the OOXML and zip it with `/usr/bin/zip`. That
is a trap: the generator and the `XLSXSheets` reader would encode the same assumptions
about the format, so a shared misunderstanding would produce a green suite while both
halves were wrong about real Excel files. A fixture is only an oracle if something other
than the code under test produced it.

So these were produced by openpyxl 3.1.5, which is a real OOXML writer, while the Python
engine was still in the tree. Plan 5 deletes that engine, after which they cannot be
regenerated here. Treat them as source, not as build output.

`book.xlsx` and `odd.xlsx` were produced on 2026-08-09 and reproduce, byte-for-byte in
content, what `engine/tests/fixtures.py:make_xlsx` and
`engine/tests/test_sheets.py:test_sheet_names_with_quotes_do_not_break_the_expression`
built at test time in the Python suite. `amp.xlsx` was added later the same day, during
Task 9's review-fix pass, to close a gap the review caught: nothing exercised the case the
`XMLParser`-not-regex decision and the empty-`<dimension>` handling both exist for. It has
no Python-suite equivalent — it did not need one, since it targets bugs the port itself
introduced, not behavior being carried over.

`excel_serial.xlsx` was added during the SiftEngine plan's Task 5 review-fix pass (still
2026-08-09), in a throwaway venv (`python3 -m venv`, `pip install openpyxl==3.1.5`) since the
system Python is externally managed — `engine/` and `requirements.txt` were both still in the
tree at the time (this plan does not delete them; Plan 5 does), so generating it followed the
exact same recipe as `amp.xlsx`, not the hand-rolled-OOXML trap warned about above.

## What each one is for

**`book.xlsx`** — three sheets, exercising sheet enumeration and the empty-sheet rule:

| sheet | `<dimension ref>` | rows | cols | `SheetInfo.empty` |
|---|---|---|---|---|
| `Summary` | `A1:B2` | 2 | 2 | false |
| `By Store` | `A1:B51` | 51 | 2 | false |
| `Empty` | `A1:A1` | 1 | 1 | **true** (`rows <= 1`) |

`Summary` is first and non-empty, so it is also the default-sheet pick. `By Store` has 51
rows, which is 50 data rows once the header is dropped — the number the read-through test
asserts.

**`odd.xlsx`** — one sheet named `it's a sheet` (`<dimension ref="A1:A2"/>`, 2 rows by 1
col): the apostrophe case. It needs no escaping inside a double-quoted XML attribute, so
`xl/workbook.xml` carries it as the literal `name="it's a sheet"` — a naive
`name="([^"]*)"` regex gets this one right too, which is exactly why it doesn't prove
anything about the ampersand case below.

**`amp.xlsx`** — one sheet named `R&D`, generated with:

```python
import openpyxl
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "R&D"
ws["B2"] = "top-left"
ws["C10"] = "bottom-right"
wb.save("amp.xlsx")
```

Two things this proves that `book.xlsx`/`odd.xlsx` don't:

1. `&` **must** be entity-escaped inside XML, so `xl/workbook.xml` carries the sheet name
   as `name="R&amp;D"`. A regex that happens to pass on `odd.xlsx`'s unescaped apostrophe
   returns the raw `"R&amp;D"` here; only a real XML parser decodes it back to `R&D`. This
   is the exact scenario the file header of `XLSXSheets.swift` and this README's original
   revision both cited as the reason to use `XMLParser` — before there was a fixture to
   back it.
2. Writing only the corner cells `B2` and `C10` makes openpyxl compute
   `<dimension ref="B2:C10"/>` — not anchored at `A1`. openpyxl reports this sheet as
   `max_row=10, max_column=3` (the END coordinate outright), not `9`/`2` (a span from the
   start cell). `book.xlsx` and `odd.xlsx` are both anchored at `A1`, where a
   start-to-end-inclusive span and the bare end coordinate happen to produce the same
   number — which is how a span-based bug in `parseDimensionRef` shipped past both of them
   during Task 9 and was only caught in review.

**`excel_serial.xlsx`** — one sheet (`Sheet1`), two columns, five data rows:

```python
import openpyxl
wb = openpyxl.Workbook()
ws = wb.active
ws.title = "Sheet1"
ws["A1"] = "id"
ws["B1"] = "serial"
values = [25100, 30000, 35000, 40000, 45999]
for i, v in enumerate(values, start=2):
    ws[f"A{i}"] = i - 1
    ws[f"B{i}"] = v
wb.save("excel_serial.xlsx")
```

Exercises `SessionQueries.computeProfile`'s Excel-serial-date note: `serial`'s five values sit
entirely inside `looksLikeExcelSerialDates`' 25,000–50,000 window, with more than one distinct
value, and `id` is an ordinary small integer that must NOT trigger the same note — the two
columns together pin that the check is column-scoped, not table-wide. Unlike `book.xlsx`/
`odd.xlsx`/`amp.xlsx` (which pin `XLSXSheets.swift`'s sheet-enumeration parsing), this one is
consumed by `Tests/SiftEngineTests/SessionQueriesTests.swift` — it needs real numeric *data* in
a specific range, not a specific sheet-metadata shape.

## Regenerating, if it ever becomes necessary

Requires a Python with openpyxl. Every workbook's generating script is inlined above;
`book.xlsx`/`odd.xlsx`'s recipe lived in `engine/tests/fixtures.py` before that tree was
deleted — `git log -- Tests/SiftCoreTests/Fixtures` will find the commit that added them,
and its message carries the generating script.
