# Security

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** form on this repository (private vulnerability
reporting is enabled). Please don't open a public issue for an unpatched problem.

Include the DuckDB version, the file format, and roughly how big the file was — most behaviour here
is size- and format-dependent, and it narrows the search immediately.

## What Sift is, from a security standpoint

Sift is a single-user local tool. It opens files on your own machine and shows you what's in them.
There is no server deployment, no multi-tenancy, no account system, and no remote data.

**It reaches no live system.** No database connector, no cloud client, no credentials, no telemetry,
no analytics, no update check. The only outbound network request Sift's dependencies make is the
one-time `INSTALL` of the DuckDB `delta` and `excel` extensions, which you run explicitly during
setup. DuckDB's network filesystems are disabled at runtime.

## The properties that are meant to hold

If you find a way to break one of these, that's a vulnerability and worth reporting:

- **Loopback only.** The engine binds `127.0.0.1` and nothing else. `/api/open` reads any path the
  caller names, so a `--host` flag is deliberately absent and must never be added.
- **Per-launch token plus Host pinning.** Every request carries a token minted at launch
  (`x-sift-token` header or `?t=`), and the `Host` header is checked. The token lives in
  `~/.sift/token`.
- **`~/.sift` is `0700`.** Staged data, the browser-drop spill, and the token all live there.
- **The SQL box cannot write.** The enforcement is *not* the keyword guard — it is that user SQL is
  wrapped as `SELECT * FROM (\n …\n) AS _q`. `DROP`, `COPY`, `ATTACH`, `PRAGMA` and `SET` cannot
  occupy a subquery position, so they die in DuckDB's parser before anything runs. The keyword guard
  exists to produce a better error message, not to be the gate. **A patch that replaces the wrap
  with a blocklist is a security regression**, however much simpler it looks.
- **Sources are read-only.** Sift never writes to a file you opened.
- **Staged data ages out.** Staged tables are purged after 14 days and capped at 20 GB, and the
  **Staged** screen lists everything currently held with sizes and last-used times.
- **The engine dies with its parent.** A watcher terminates the sidecar if the shell goes away, so a
  token-bearing process is not left listening.

## Known and accepted

**A `SELECT` can read any local file you could `cat`.** DuckDB's file-reading functions are
available in the SQL box, and Sift does not sandbox the filesystem. This is accepted rather than
fixed, on the reasoning that Sift runs as you, on your machine, on files you already have — it never
owns the only copy of anything, sources are read-only, and staged tables are rebuildable. Network
filesystems are disabled, so such a read cannot be exfiltrated by the query itself.

If you are running Sift somewhere that reasoning doesn't hold, don't.

**Browser mode copies dropped files.** An HTML5 drop gives no filesystem path, so drops under
`SIFT_MAX_UPLOAD_MB` (default 512) are copied to a spill file in `~/.sift` and badged in the UI as
copied. The native `.app` never does this — LaunchServices supplies the real path and DuckDB reads
in place.

**Staged data is a real copy of your data on disk.** It is exactly as sensitive as the file you
opened. That's the reason for the 0700 mode, the age-out, and the one screen that answers "what is
this tool holding on to".

## Out of scope

- Anything requiring an attacker who already has local code execution as your user. At that point
  they can read the files directly.
- Denial of service from a deliberately malformed file. Sift may refuse it or take a long time; that
  is a bug, not a vulnerability.
- The DuckDB extensions themselves, which are distributed by DuckDB.

## Supported versions

Sift is pre-1.0 and only the current `main` is supported. `requirements.txt` is fully pinned on
purpose — an unpinned floor means a surprise upstream release can change CSV sniffing with nothing
in the repository to explain it. Dependabot alerts are enabled, and the pins are re-verified against
`engine/tests` before any bump.
