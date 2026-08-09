#!/bin/bash
# Local dev for Sift. Reads only local files — no database, no cloud, no credentials.
#
# Uses this tool's OWN venv (Python 3.12 + the pinned requirements.txt). Create it with:
#   uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python \
#     -r requirements.txt -r requirements-dev.txt
#
# One-time, needs network (extension binaries are per-DuckDB-version, so repeat after a bump):
#   .venv/bin/python -c "import duckdb; c=duckdb.connect(); \
#     [c.execute(f'INSTALL {e}') for e in ('delta','excel')]"
#
# app.py binds 127.0.0.1 only, deliberately — /api/open reads any path the caller names, so a
# --host flag must never be added. Tunables (defaults live in engine/app.py and engine/session.py):
# SIFT_PORT=8642, SIFT_HOME=~/.sift, SIFT_MAX_UPLOAD_MB=512, and — staged data is a copy of real data, so
# it ages out on a clock as well as under size pressure — SIFT_STAGE_BUDGET_GB=20,
# SIFT_STAGE_MAX_AGE_DAYS=14.
set -euo pipefail
cd "$(dirname "$0")"
exec .venv/bin/python engine/app.py "$@"
