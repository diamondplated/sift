"""Sift — drop a file in, explore it instantly.

FastAPI over a DuckDB session, serving one hand-written page. Same shape as drydock/backend/main.py:
sync `def` handlers so FastAPI runs them in its threadpool, one async endpoint for SSE, no JS build
step.

Run:  sift/dev.sh                     (or: python engine/app.py [file ...])
Bind: 127.0.0.1 only — /api/open reads any path the caller names, so this must never listen
      on 0.0.0.0. drydock binds 0.0.0.0 because it is containerized; Sift is not.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import shutil
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import webbrowser
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import Body, FastAPI, File, Form, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, StreamingResponse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from core import source as src           # noqa: E402
from core.guard import SqlRejected       # noqa: E402
from core.types import Filter            # noqa: E402
from session import SIFT_HOME, SPILL_DIR, Session, SiftError  # noqa: E402

logging.basicConfig(level=os.environ.get("SIFT_LOG", "INFO"),
                    format="%(asctime)s %(levelname)-5s %(name)s %(message)s")
log = logging.getLogger("sift.app")

PORT = int(os.environ.get("SIFT_PORT", "8642"))
WEB_DIR = Path(__file__).resolve().parent.parent / "web"
MAX_UPLOAD_MB = int(os.environ.get("SIFT_MAX_UPLOAD_MB", "512"))

# Set once the listening socket exists. In sidecar mode the kernel picks the port, so the Host
# check below has to compare against what we actually bound, not the default.
RUNTIME: dict[str, Any] = {"port": PORT, "native": False}

TOKEN_FILE = os.path.join(SIFT_HOME, "token")


def _resolve_token() -> str:
    """Shared secret between the page and repeated CLI invocations.

    A hostile web page can POST a form to localhost without triggering a CORS preflight, but it
    cannot set a custom header — requiring one forces a preflight this server refuses, and the page
    could not read the response anyway.

    Persisted in a 0600 file rather than regenerated per process, because `sift-open` runs as a
    *separate* process for every dropped file and has to authenticate to the instance that is
    already running.
    """
    env = os.environ.get("SIFT_TOKEN")
    if env:
        return env
    try:
        existing = Path(TOKEN_FILE).read_text().strip()
        if existing:
            return existing
    except OSError:
        pass
    token = secrets.token_urlsafe(24)
    try:
        os.makedirs(SIFT_HOME, mode=0o700, exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(token)
        os.chmod(TOKEN_FILE, 0o600)
    except OSError as exc:
        log.warning("could not persist the auth token (%s); CLI handoff will fail", exc)
    return token


TOKEN = _resolve_token()

app = FastAPI(title="Sift", docs_url=None, redoc_url=None, openapi_url=None)
session: Session | None = None


def S() -> Session:
    assert session is not None
    return session


# --------------------------------------------------------------- middleware


@app.middleware("http")
async def gate(request: Request, call_next):
    """Host pinning plus token check. Cheap, and impossible to retrofit convincingly."""
    host = (request.headers.get("host") or "").split(",")[0].strip()
    hostname, _, hostport = host.rpartition(":") if ":" in host else (host, "", "")
    hostname = hostname or host
    if hostname not in ("localhost", "127.0.0.1", "[::1]", "::1", ""):
        # Blocks DNS rebinding: an attacker-controlled name resolving to 127.0.0.1 arrives with
        # its own Host header, not ours.
        return PlainTextResponse("Sift only answers to localhost.", status_code=421)
    if hostport and hostport.isdigit() and int(hostport) != RUNTIME["port"]:
        return PlainTextResponse("Wrong port.", status_code=421)

    path = request.url.path
    if path.startswith("/api/"):
        supplied = request.headers.get("x-sift-token") or request.query_params.get("t")
        if not supplied or not secrets.compare_digest(supplied, TOKEN):
            return JSONResponse({"error": "bad or missing token"}, status_code=403)
    return await call_next(request)


@app.exception_handler(SiftError)
async def sift_error(_: Request, exc: SiftError):
    return JSONResponse({"error": str(exc)}, status_code=400)


@app.exception_handler(SqlRejected)
async def sql_rejected(_: Request, exc: SqlRejected):
    return JSONResponse({"error": str(exc), "kind": "rejected"}, status_code=400)


# ---------------------------------------------------------------- the page


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    html = (html.replace("__SIFT_TOKEN__", TOKEN)
                .replace("__SIFT_MAX_UPLOAD_MB__", str(MAX_UPLOAD_MB))
                # In the native shell, AppKit handles drops and hands over real paths, so the page
                # disables its own HTML5 drop handling and the copy-to-spill fallback entirely.
                .replace("__SIFT_NATIVE__", "true" if RUNTIME["native"] else "false"))
    return HTMLResponse(html)


@app.get("/favicon.ico")
def favicon():
    return PlainTextResponse("", status_code=204)


# ------------------------------------------------------------------- state


@app.get("/api/state")
def api_state() -> dict[str, Any]:
    return S().state()


@app.get("/api/sheets")
def api_sheets(path: str) -> dict[str, Any]:
    """Sheet list for the .xlsx picker, before anything is opened."""
    p = os.path.realpath(os.path.expanduser(path))
    if not os.path.exists(p):
        raise SiftError(f"No such file: {p}")
    try:
        sheets = src.list_sheets(p)
    except Exception as exc:
        raise SiftError(f"Could not read sheets from {os.path.basename(p)}: {exc}") from exc
    return {"path": p, "sheets": [{"name": s.name, "rows": s.rows, "cols": s.cols,
                                   "empty": s.empty} for s in sheets]}


@app.post("/api/open")
def api_open(body: dict = Body(...)) -> dict[str, Any]:
    path = body.get("path")
    if not path:
        raise SiftError("No path given.")
    t = S().open_path(path, name=body.get("name"), sheet=body.get("sheet"))
    return t.summary()


@app.post("/api/upload")
async def api_upload(file: UploadFile = File(...),
                     size: int = Form(default=0)) -> dict[str, Any]:
    """The pathless-browser-drop fallback.

    An HTML5 drop yields a File with no filesystem path — WebKit withholds it deliberately — and
    DuckDB needs a real path to read in place. So the bytes get streamed to a spill file and opened
    from there. The table is badged as copied so nobody wonders why it wasn't instant.
    """
    if size and size > MAX_UPLOAD_MB * 1024 * 1024:
        raise SiftError(
            f"That file is {size / (1024 ** 3):.1f} GB and the browser will not tell Sift where it "
            f"lives, so it would have to be copied first. Drop it on the Sift app icon, or paste "
            f"its path (⌥⌘C in Finder copies one)."
        )
    safe = os.path.basename(file.filename or "dropped.csv")
    target_dir = os.path.join(SPILL_DIR, uuid.uuid4().hex)
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    dest = os.path.join(target_dir, safe)
    written = 0
    try:
        with open(dest, "wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAX_UPLOAD_MB * 1024 * 1024:
                    raise SiftError(f"Upload exceeded {MAX_UPLOAD_MB} MB.")
                out.write(chunk)
    except SiftError:
        shutil.rmtree(target_dir, ignore_errors=True)
        raise
    t = S().open_path(dest, copied=True)   # sets copied_from_browser in the constructor
    t.notes.append(f"Copied into {SIFT_HOME} because the browser withheld the real path")
    return t.summary()


@app.post("/api/close")
def api_close(body: dict = Body(...)) -> dict[str, Any]:
    S().close_table(body["table"])
    return {"ok": True}


@app.get("/api/table/{table}")
def api_table(table: str) -> dict[str, Any]:
    s = S()
    t = s.table(table)
    d = t.summary()
    d["columns"] = [{"name": c.name, "type": c.type, "kind": c.kind} for c in t.spec.columns]
    d["sql"] = s.rendered_sql(table)
    d["spec"] = {
        "filters": [{"col": f.col, "op": f.op, "values": list(f.values)} for f in t.qspec.filters],
        "sort": [[c, dd] for c, dd in t.qspec.sort],
    }
    d["sniff"] = {k: v for k, v in t.spec.read_args.items() if k != "columns"}
    d["sniff_prompt"] = t.spec.sniff_prompt
    return d


# -------------------------------------------------------------------- rows


@app.get("/api/rows/{table}")
def api_rows(table: str, offset: int = 0, limit: int = 500) -> dict[str, Any]:
    return S().page(table, offset=max(0, offset), limit=max(1, min(limit, 5000)))


@app.post("/api/spec")
def api_spec(body: dict = Body(...)) -> dict[str, Any]:
    filters = tuple(
        Filter(col=f["col"], op=f["op"], values=tuple(f.get("values") or ()))
        for f in body.get("filters") or ()
    )
    sort = tuple((s[0], s[1]) for s in body.get("sort") or ())
    s = S()
    s.set_spec(body["table"], filters, sort)
    return {"ok": True, "sql": s.rendered_sql(body["table"])}


@app.post("/api/sql")
def api_sql(body: dict = Body(...)) -> dict[str, Any]:
    return S().run_sql(body["table"], body.get("sql") or "",
                       offset=max(0, int(body.get("offset") or 0)),
                       limit=max(1, min(int(body.get("limit") or 500), 5000)))


@app.post("/api/sqlexit")
def api_sql_exit(body: dict = Body(...)) -> dict[str, Any]:
    s = S()
    s.exit_sql_mode(body["table"])
    return {"ok": True, "sql": s.rendered_sql(body["table"])}


# ----------------------------------------------------------------- profile


@app.get("/api/profile/{table}")
def api_profile(table: str) -> dict[str, Any]:
    p = S().compute_profile(table)
    return {"columns": [
        {"name": c.name, "type": c.type, "kind": c.kind, "n": c.n, "n_null": c.n_null,
         "n_empty": c.n_empty, "n_nullish": c.n_nullish, "approx_distinct": c.approx_distinct,
         "exact_distinct": c.exact_distinct, "min": c.min_s, "max": c.max_s, "avg": c.avg,
         "std": c.std, "q25": c.q25, "q50": c.q50, "q75": c.q75, "max_len": c.max_len,
         "n_uncastable": c.n_uncastable, "view": c.view}
        for c in p
    ]}


@app.get("/api/distinct/{table}/{col}")
def api_distinct(table: str, col: str, limit: int = 200, search: str = "") -> dict[str, Any]:
    return S().distinct(table, col, limit=max(1, min(limit, 2000)), search=search or None)


@app.get("/api/histogram/{table}/{col}")
def api_histogram(table: str, col: str, bins: int = 40) -> dict[str, Any]:
    return S().histogram(table, col, bins=max(4, min(bins, 200)))


@app.get("/api/highcard/{table}/{col}")
def api_highcard(table: str, col: str) -> dict[str, Any]:
    s = S()
    p = s.profile_of(table, col)
    return {"col": col, "n": p.n, "approx_distinct": p.approx_distinct,
            "min": p.min_s, "max": p.max_s, "max_len": p.max_len,
            "sample": s.sample_values(table, col, 20),
            "lengths": s.length_histogram(table, col)}


@app.get("/api/badrows/{table}")
def api_badrows(table: str, limit: int = 200) -> dict[str, Any]:
    return S().bad_rows(table, limit=max(1, min(limit, 2000)))


# ----------------------------------------------------------------- staging


@app.post("/api/stage")
def api_stage(body: dict = Body(...)) -> dict[str, Any]:
    jid = S().stage_now(body["table"], force=bool(body.get("force")))
    t = S().table(body["table"])
    return {"job_id": jid, "staging": t.staging,
            "reason": t.stage_decision.reason if t.stage_decision else None}


@app.post("/api/cancel")
def api_cancel(body: dict = Body(...)) -> dict[str, Any]:
    return {"ok": S().cancel(body["job_id"])}


@app.post("/api/unstage")
def api_unstage(body: dict = Body(...)) -> dict[str, Any]:
    return S().unstage(body["table"]).summary()


@app.get("/api/staged")
def api_staged() -> dict[str, Any]:
    s = S()
    return {"entries": s.staged_entries(), "total_bytes": s.staged_total_bytes(),
            "home": SIFT_HOME,
            "budget_gb": int(os.environ.get("SIFT_STAGE_BUDGET_GB", 20)),
            "max_age_days": int(os.environ.get("SIFT_STAGE_MAX_AGE_DAYS", 14))}


@app.post("/api/purge")
def api_purge(body: dict = Body(default={})) -> dict[str, Any]:
    return S().purge_staged(tables=body.get("tables"), all_=bool(body.get("all")),
                            reason="user")


# ------------------------------------------------------------------- joins


@app.get("/api/joincols")
def api_joincols(left: str, right: str) -> dict[str, Any]:
    return {"candidates": S().join_candidates(left, right)}


@app.post("/api/join_probe")
def api_join_probe(body: dict = Body(...)) -> dict[str, Any]:
    return S().join_probe(body["left"], body["right"], body.get("on") or [])


@app.post("/api/unmatched")
def api_unmatched(body: dict = Body(...)) -> dict[str, Any]:
    return S().unmatched_keys(body["left"], body["right"], body.get("on") or [],
                              limit=int(body.get("limit") or 200))


@app.post("/api/merge")
def api_merge(body: dict = Body(...)) -> dict[str, Any]:
    return S().merge(body["left"], body["right"], body.get("on") or [],
                     how=body.get("how") or "inner", name=body.get("name")).summary()


# --------------------------------------------------------- export/snippets


@app.get("/api/snippet/{table}")
def api_snippet(table: str, dialect: str = "duckdb") -> dict[str, Any]:
    if dialect not in ("duckdb", "pandas", "polars", "sql"):
        raise SiftError(f"Unknown dialect {dialect!r}.")
    return {"dialect": dialect, "text": S().snippet(table, dialect)}


@app.post("/api/export")
def api_export(body: dict = Body(...)) -> dict[str, Any]:
    return S().export(body["table"], body["dest"], fmt=body.get("format") or "parquet",
                      overwrite=bool(body.get("overwrite")))


# --------------------------------------------------------------------- SSE


@app.get("/api/events")
async def api_events(request: Request) -> StreamingResponse:
    s = S()
    s.attach_loop(asyncio.get_running_loop())
    queue = s.subscribe()

    async def gen():
        try:
            yield _sse({"type": "hello", "state": s.state()})
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=20.0)
                    yield _sse(event)
                except asyncio.TimeoutError:
                    yield ": keepalive\n\n"   # keeps proxies and the browser from closing us
        finally:
            s.unsubscribe(queue)

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event, default=str)}\n\n"


# ------------------------------------------------------------- lifecycle


_QUEUED_PATHS: list[str] = []


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI):
    global session
    if session is None:
        session = Session()
    session.attach_loop(asyncio.get_running_loop())
    log.info("sift on http://127.0.0.1:%d  home=%s  duckdb=%s", PORT, SIFT_HOME,
             session.engine_info()["duckdb"])
    missing = [k for k, v in session.extensions.items() if not v]
    if missing:
        log.warning("extensions unavailable: %s — Delta folders and .xlsx will be refused rather "
                    "than read incorrectly. Fix with one online run of: INSTALL %s",
                    ", ".join(missing), "; INSTALL ".join(missing))
    for path in _QUEUED_PATHS:
        try:
            session.open_path(path)
        except Exception as exc:
            log.error("could not open %s: %s", path, exc)
    try:
        yield
    finally:
        session.shutdown()


app.router.lifespan_context = lifespan


# ------------------------------------------------------------------ the CLI


def _running_instance() -> bool:
    """Is an engine already up on our port?

    Required, not a nicety: each `sift-open` is a fresh process, so without a handoff a second
    one would try to bind the same port and lose.
    """
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/api/state",
                                     headers={"X-Sift-Token": TOKEN})
        with urllib.request.urlopen(req, timeout=0.4):
            return True
    except urllib.error.HTTPError:
        return True          # answered (even a 403) => something is listening
    except Exception:
        return False


def _handoff(paths: list[str]) -> bool:
    ok = False
    for p in paths:
        body = json.dumps({"path": os.path.realpath(os.path.expanduser(p))}).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORT}/api/open", data=body,
            headers={"Content-Type": "application/json", "X-Sift-Token": TOKEN},
        )
        try:
            with urllib.request.urlopen(req, timeout=30):
                ok = True
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:300]
            print(f"sift: {p}: {detail}", file=sys.stderr)
        except Exception as exc:
            print(f"sift: could not hand {p} to the running instance: {exc}", file=sys.stderr)
    return ok


def _port_free() -> bool:
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", PORT))
        return True
    except OSError:
        return False
    finally:
        s.close()


def _exit_when_parent_goes_away() -> None:
    """Die when the native shell dies.

    The shell holds our stdin open; when the app quits (or crashes, or is force-killed) the pipe
    closes and this read returns. Without it, a crashed parent leaves an orphaned engine holding the
    port — the exact scar AGENTS.md records for drydock's gateway JVMs.
    """
    def watch() -> None:
        try:
            sys.stdin.read()
        except Exception:
            pass
        try:
            if session is not None:
                session.drop_private_store()
        except Exception:
            pass
        os._exit(0)

    threading.Thread(target=watch, name="sift-parent-watch", daemon=True).start()


def run_sidecar(paths: list[str]) -> int:
    """Serve on a kernel-assigned port and announce it on stdout for the native shell.

    The handshake is a single JSON line, first thing on stdout, so the shell never has to guess a
    port or scrape logs. Port 0 matters because this machine already has plenty of listeners; a
    hardcoded port would collide sooner or later.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(128)
    port = sock.getsockname()[1]
    RUNTIME["port"] = port
    RUNTIME["native"] = True

    _QUEUED_PATHS.extend(os.path.realpath(os.path.expanduser(p)) for p in paths)
    _exit_when_parent_goes_away()

    sys.stdout.write(json.dumps({"port": port, "token": TOKEN}) + "\n")
    sys.stdout.flush()

    config = uvicorn.Config(app, log_level="warning", access_log=False)
    uvicorn.Server(config).run(sockets=[sock])
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    paths = [a for a in argv if not a.startswith("-")]
    no_browser = "--no-browser" in argv

    if "--sidecar" in argv:
        return run_sidecar(paths)

    # Two chances to notice an existing engine: the /api/state probe, and (for the case where a
    # sibling process is mid-startup and not yet answering) whether the port is bindable at all.
    # Passing several paths to one `sift-open` avoids the race; a fast double-invocation can hit it.
    if _running_instance() or not _port_free():
        for _ in range(20):
            if _running_instance():
                break
            time.sleep(0.25)
        # Both processes resolved TOKEN from the same 0600 file, so this authenticates.
        if paths:
            _handoff(paths)
        if not no_browser:
            webbrowser.open(f"http://127.0.0.1:{PORT}/")
        return 0

    _QUEUED_PATHS.extend(os.path.realpath(os.path.expanduser(p)) for p in paths)

    if not no_browser:
        # Fire slightly after the server binds; uvicorn.run blocks.
        threading.Timer(0.8, lambda: webbrowser.open(f"http://127.0.0.1:{PORT}/")).start()

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning", access_log=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
