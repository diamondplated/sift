"""Identifier sanitation and quoting. No connection, no files."""
import pytest

from core.ident import q, qlit, sanitize_table_name, strip_data_extensions


@pytest.mark.parametrize("given,want", [
    ("2026 Sales (final).csv", "t_2026_sales_final"),   # leading digit must be prefixed
    ("sales.csv", "sales"),
    ("sales.csv.gz", "sales"),                          # double extension
    ("events.ndjson", "events"),
    ("Book1.xlsx", "book1"),
    ("  ???  ", "data"),                                # nothing usable left
    ("", "data"),
    ("Ünïcode Nàme.parquet", "unicode_name"),           # NFKD then ASCII
    ("a---b__c", "a_b_c"),                              # runs collapse
    ("__leading_and_trailing__", "leading_and_trailing"),
    ("MiXeD CaSe", "mixed_case"),
    ("select", "select"),                               # reserved words are fine: always quoted
    ("tab\tsep", "tab_sep"),
    ("2026", "t_2026"),
])
def test_sanitize(given, want):
    assert sanitize_table_name(given) == want


def test_sanitize_truncates_and_keeps_room_for_a_suffix():
    name = sanitize_table_name("x" * 200 + ".csv")
    assert len(name) <= 60
    assert sanitize_table_name("x" * 200 + ".csv", taken={name}) == name + "_2"


def test_sanitize_resolves_collisions_in_order():
    taken = {"sales", "sales_2", "sales_3"}
    assert sanitize_table_name("sales.csv", taken=taken) == "sales_4"


def test_sanitize_collision_is_case_insensitive():
    # DuckDB identifiers are case-insensitive, so "Sales" colliding with "sales" is a real clash.
    assert sanitize_table_name("Sales.csv", taken={"sales"}) == "sales_2"


def test_strip_data_extensions_leaves_unknown_suffixes_alone():
    assert strip_data_extensions("report.2026.final") == "report.2026.final"
    assert strip_data_extensions("data.csv.zst") == "data"


def test_q_doubles_embedded_quotes():
    assert q("region") == '"region"'
    assert q('we"ird') == '"we""ird"'
    # The injection shape: the whole thing stays one quoted identifier.
    assert q('"; DROP TABLE x; --') == '"""; DROP TABLE x; --"'


def test_qlit_doubles_single_quotes():
    assert qlit("a'b") == "'a''b'"
    assert qlit("plain") == "'plain'"
