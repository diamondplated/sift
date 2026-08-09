"""Format detection, sniffing, and spec building."""
import os

import pytest

from conftest import has_ext
from core import source as S
from core.types import Column


def test_magic_bytes_beat_the_extension(data, tmp_path):
    # A .csv that is really parquet is a genuinely common way to receive data.
    lying = tmp_path / "actually_parquet.csv"
    lying.write_bytes(open(data["parquet"], "rb").read())
    assert S.detect_format(str(lying)) == "parquet"


@pytest.mark.parametrize("key,want", [
    ("clean_csv", "csv"), ("semi_csv", "csv"), ("weird_csv", "csv"), ("gz_csv", "csv"),
    ("parquet", "parquet"), ("ndjson", "ndjson"), ("xlsx", "xlsx"),
])
def test_detect_format(data, key, want):
    assert S.detect_format(data[key]) == want


def test_legacy_xls_is_refused_with_a_useful_message(data):
    with pytest.raises(S.LegacyXls) as e:
        S.detect_format(data["fake_xls"])
    assert ".xlsx" in str(e.value)


def test_delta_directory_is_detected_not_globbed(data):
    assert S.is_delta_dir(data["delta"])
    assert S.detect_format(data["delta"]) == "delta"


def test_folder_of_parquet_is_a_glob(data):
    assert S.detect_format(data["hive"]) == "glob_parquet"


def test_folder_with_nothing_readable_is_refused(tmp_path):
    (tmp_path / "sub").mkdir()
    with pytest.raises(S.UnsupportedSource):
        S.detect_format(str(tmp_path / "sub"))


def test_sniff_normalizes_the_empty_sentinel(con, data):
    """sniff_csv reports an absent quote/escape as the literal string '(empty)'.

    Feeding that back into read_csv fails with "cannot exceed a size of 1 byte", so it must be
    normalized to ''. This is the bug that would otherwise break every unquoted CSV.
    """
    sn = S.sniff_csv(con, data["clean_csv"])
    assert sn["quote"] != S.SNIFF_EMPTY
    assert sn["escape"] != S.SNIFF_EMPTY
    assert sn["comment"] != S.SNIFF_EMPTY
    assert sn["delim"] == ","
    assert sn["header"] is True


def test_sniff_finds_a_semicolon_delimiter(con, data):
    assert S.sniff_csv(con, data["semi_csv"])["delim"] == ";"


def test_sniff_skips_a_junk_preamble(con, data):
    sn = S.sniff_csv(con, data["weird_csv"])
    assert sn["skip"] == 3
    assert [c["name"] for c in sn["columns"]][:2] == ["order_id", "region"]


def test_build_source_csv_bakes_explicit_options(con, data):
    spec = S.build_source(con, data["clean_csv"])
    assert spec.fmt == "csv"
    assert spec.read_fn == "read_csv"
    assert "columns" in spec.read_args          # types pinned, so later queries never re-sniff
    assert spec.read_args["ignore_errors"] is True
    expr = S.read_expr(spec)
    assert expr.startswith("read_csv(")
    assert con.execute(f"SELECT count(*) FROM {expr}").fetchone()[0] == 1000


def test_build_source_gives_small_csvs_an_exact_count(con, data):
    spec = S.build_source(con, data["clean_csv"])
    assert spec.row_count == 1000
    assert spec.row_estimate is None            # no need to guess at this size


def test_quoted_newlines_do_not_inflate_the_count(con, data):
    """Line counting overshoots when a quoted field contains a newline; an exact count must not."""
    spec = S.build_source(con, data["quoted_nl_csv"])
    assert spec.row_count == 400


def test_compressed_csv_gets_neither_count_nor_estimate(con, data):
    # Compressed bytes say nothing about row count, so the UI shows "counting…" rather than a
    # fabricated number.
    spec = S.build_source(con, data["gz_csv"])
    assert spec.compressed is True
    assert spec.row_estimate is None
    assert spec.row_count is None
    assert con.execute(f"SELECT count(*) FROM {S.read_expr(spec)}").fetchone()[0] == 500


def test_parquet_row_count_is_free_and_exact(con, data):
    spec = S.build_source(con, data["parquet"])
    assert spec.row_count == 1000
    assert spec.fmt == "parquet"


def test_all_varchar_relation_drops_the_column_types(con, data):
    spec = S.build_source(con, data["dirty_csv"])
    raw = S.read_expr(spec, all_varchar=True)
    assert "all_varchar=true" in raw
    assert "columns=" not in raw
    types = [r[1] for r in con.execute(f"DESCRIBE SELECT * FROM {raw}").fetchall()]
    assert set(types) == {"VARCHAR"}


def test_supports_all_varchar_only_for_text_formats(con, data):
    assert S.supports_all_varchar(S.build_source(con, data["clean_csv"]))
    # Parquet carries real types, so there is no sniffing to get wrong and no reject count to compute.
    assert not S.supports_all_varchar(S.build_source(con, data["parquet"]))


def test_exact_count_uses_the_physical_relation(con, data):
    """count(*) on the typed relation is answered by projection pushdown without parsing anything.

    With an uncastable value present that makes it disagree with what SELECT * returns, so
    exact_count must go through the all-varchar relation.
    """
    spec = S.build_source(con, data["dirty_csv"])
    assert S.exact_count(con, spec) == 1000


def test_hive_keys_require_a_consistent_layout(data, tmp_path):
    import glob

    files = sorted(glob.glob(os.path.join(data["hive"], "**", "*.parquet"), recursive=True))
    assert S.hive_keys(data["hive"], files) == ("dt", "region")
    # One file at the wrong depth makes the layout inconsistent, and DuckDB errors on
    # hive_partitioning in that case — so Sift must fall back to a plain glob.
    assert S.hive_keys(data["hive"], files + [os.path.join(data["hive"], "stray.parquet")]) == ()


def test_glob_escape_protects_bracketed_directory_names():
    assert S.glob_escape("/data/x[2026]") == "/data/x[[]2026[]]"


def test_build_source_hive_sets_partitioning_and_provenance(con, data):
    spec = S.build_source(con, data["hive"])
    assert spec.fmt == "glob_parquet"
    assert spec.read_args["hive_partitioning"] is True
    assert spec.read_args["union_by_name"] is True
    assert spec.read_args["filename"] is True    # answers "which file has the bad row"
    names = [c.name for c in S._describe(con, S.read_expr(spec))]
    assert "dt" in names and "region" in names and "filename" in names


def test_empty_file_does_not_explode(con, data):
    est = S.estimate_rows(data["empty"])
    assert est.rows == 0


def test_header_byte_offset_counts_preamble_and_header(con, data):
    sn = S.sniff_csv(con, data["weird_csv"])
    off = S.header_byte_offset(data["weird_csv"], sn)
    assert off > 0
    with open(data["weird_csv"], "rb") as f:
        assert f.read(off).count(b"\n") == 4      # 3 junk lines + the header
