# Golden test fixtures

These two workbooks are committed rather than generated, and that is deliberate.

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

So these were produced **once** by openpyxl 3.1.5, which is a real OOXML writer, on
2026-08-09 — while the Python engine was still in the tree. Plan 5 deletes that engine,
after which they cannot be regenerated here. Treat them as source, not as build output.

They reproduce, byte-for-byte in content, what `engine/tests/fixtures.py:make_xlsx` and
`engine/tests/test_sheets.py:test_sheet_names_with_quotes_do_not_break_the_expression`
built at test time in the Python suite.

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

## Regenerating, if it ever becomes necessary

Requires a Python with openpyxl; the recipe lived in `engine/tests/fixtures.py` before
that tree was deleted. `git log -- Tests/SiftCoreTests/Fixtures` will find the commit that
added these, and its message carries the generating script.

## A note for the reader implementation

`odd.xlsx`'s sheet name appears in `xl/workbook.xml` as `name="it's a sheet"` — an
apostrophe needs no escaping inside a double-quoted XML attribute. A name containing `&`
or `<` **would** arrive entity-escaped. That is why the reader parses this with
`XMLParser` rather than a regex: the regex works on both these fixtures and then silently
mangles the first workbook a user opens whose sheet is called `R&D`.
