"""Row estimation from byte samples. No connection needed."""
import gzip
import os

import fixtures as fx
from core.source import estimate_rows, header_byte_offset


def _rows_in(path, header_lines=1):
    with open(path, "rb") as f:
        return sum(1 for _ in f) - header_lines


def test_small_file_is_counted_exactly(tmp_path):
    p = fx.make_csv(tmp_path, "small.csv", rows=500)
    est = estimate_rows(p, header_bytes=len(open(p, "rb").readline()))
    assert est.rows == 500
    assert est.confidence == "exact"


def test_large_unquoted_file_estimates_within_five_percent(tmp_path):
    """Accuracy at the production window size, on a deliberately unhelpful file.

    This fixture's rows GROW in length (note text carries the row number), which is the worst case
    for extrapolating from samples. At the real 256 KiB window it lands within ~2%; with artificially
    small windows it degrades to ~7%, so this test uses the defaults the app actually runs with.
    """
    p = fx.make_csv(tmp_path, "big.csv", rows=60_000)
    header = len(open(p, "rb").readline())
    est = estimate_rows(p, header_bytes=header)      # production chunks/chunk_bytes
    assert est.confidence == "high"
    err = abs(est.rows - 60_000) / 60_000
    assert err < 0.05, f"got {est.rows} ({err:.1%} off)"
    assert "no quote characters" in est.basis


def test_quotes_downgrade_confidence(tmp_path):
    """A quoted field can contain a newline, which makes line counting overshoot.

    There is no cheap way to know how often that happens, so the estimate reports low confidence
    rather than pretending to be exact.
    """
    p = fx.make_csv(tmp_path, "q.csv", rows=60_000, quote_notes=True)
    header = len(open(p, "rb").readline())
    est = estimate_rows(p, header_bytes=header)
    assert est.confidence == "low"
    assert "quote characters" in est.basis


def test_an_isolated_quoted_newline_outside_the_sample_is_not_detected(tmp_path):
    """The known blind spot, asserted so nobody mistakes it for a guarantee.

    Sampling three windows cannot see a lone quoted newline elsewhere in the file, so the estimate
    will claim "high" and be slightly over. This is why the UI shows estimates with a visible "≈"
    and why anything under 64 MB gets a real count instead (see source.EXACT_COUNT_MAX_BYTES).
    """
    p = fx.make_csv(tmp_path, "one.csv", rows=60_000, quoted_newline_row=30_000)
    header = len(open(p, "rb").readline())
    est = estimate_rows(p, header_bytes=header, chunks=3, chunk_bytes=8192)
    assert est.confidence == "high"          # honest about being unable to know
    assert est.rows != 60_000                # and it is indeed off


def test_small_quoted_file_is_not_claimed_exact(tmp_path):
    p = fx.make_csv(tmp_path, "sq.csv", rows=300, quoted_newline_row=100)
    est = estimate_rows(p, header_bytes=len(open(p, "rb").readline()))
    assert est.confidence == "low"


def test_empty_and_header_only(tmp_path):
    empty = tmp_path / "e.csv"
    empty.write_text("")
    assert estimate_rows(str(empty)).rows == 0

    hdr = tmp_path / "h.csv"
    hdr.write_text("a,b\n")
    est = estimate_rows(str(hdr), header_bytes=4)
    assert est.rows == 0


def test_no_trailing_newline_still_counts_the_last_row(tmp_path):
    p = tmp_path / "nt.csv"
    p.write_text("a,b\n1,2\n3,4")     # final row has no \n
    est = estimate_rows(str(p), header_bytes=4)
    assert est.rows == 2
