"""Sift's pure core.

Every module here is importable without a DuckDB connection, a FastAPI app, or a running server,
and holds no mutable module-level state. That constraint is what makes the interesting logic —
identifier sanitation, SQL generation, the SELECT-only gate, staging policy, view selection —
testable in milliseconds with no fixtures. No connection, no server, no global state.

Stateful things (the connection, the catalog of open sources, background jobs, SSE fan-out) live
in session.py. HTTP lives in app.py.
"""
