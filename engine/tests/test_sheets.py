"""Excel: sheet enumeration, the picker's data, and the legacy .xls refusal."""
import pytest

from conftest import has_ext
from core import source as S


def test_sheets_are_enumerated_with_dimensions(data):
    sheets = S.list_sheets(data["xlsx"])
    by_name = {s.name: s for s in sheets}
    assert set(by_name) == {"Summary", "By Store", "Empty"}
    assert by_name["Summary"].rows == 2 and by_name["Summary"].cols == 2
    assert by_name["By Store"].rows == 51
    assert by_name["Empty"].empty is True
    assert by_name["By Store"].empty is False


def test_default_sheet_is_the_first_non_empty(con, data):
    if not has_ext(con, "excel"):
        pytest.skip("duckdb excel extension not installed")
    spec = S.build_source(con, data["xlsx"])
    assert spec.sheet == "Summary"
    assert spec.fmt == "xlsx"
    assert len(spec.sheets) == 3


def test_a_named_sheet_can_be_opened(con, data):
    if not has_ext(con, "excel"):
        pytest.skip("duckdb excel extension not installed")
    spec = S.build_source(con, data["xlsx"], sheet="By Store")
    assert spec.sheet == "By Store"
    assert spec.read_args["sheet"] == "By Store"      # `sheet`, not `sheet_name`
    n = con.execute(f"SELECT count(*) FROM {S.read_expr(spec)}").fetchone()[0]
    assert n == 50                                     # 51 rows minus the header


def test_sheet_names_with_quotes_do_not_break_the_expression(con, tmp_path):
    if not has_ext(con, "excel"):
        pytest.skip("duckdb excel extension not installed")
    import openpyxl

    p = tmp_path / "odd.xlsx"
    wb = openpyxl.Workbook()
    wb.active.title = "it's a sheet"
    wb.active.append(["a"])
    wb.active.append([1])
    wb.save(p)
    spec = S.build_source(con, str(p), sheet="it's a sheet")
    assert con.execute(f"SELECT count(*) FROM {S.read_expr(spec)}").fetchone()[0] == 1


def test_legacy_xls_gets_a_readable_refusal(data):
    with pytest.raises(S.LegacyXls) as e:
        S.build_source(None, data["fake_xls"])
    msg = str(e.value)
    assert ".xlsx" in msg and "legacy" in msg.lower()


def test_a_zip_that_is_not_xlsx_is_refused(tmp_path):
    import zipfile

    p = tmp_path / "notes.zip"
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("a.txt", "hello")
    with pytest.raises(S.UnsupportedSource):
        S.detect_format(str(p))
