# Security

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** form on this repository (private vulnerability
reporting is enabled). Please don't open a public issue for an unpatched problem.

Include the file format and roughly how big the file was — most behaviour here is size- and
format-dependent, and it narrows the search immediately.

## What Sift is, from a security standpoint

Sift is a single-user local tool. It opens files on your own machine and shows you what's in them.
There is no server, no port, no multi-tenancy, no account system, and no remote data — one native
process, one binary.

**It reaches no live system.** No database connector, no cloud client, no credentials, no telemetry,
no analytics, no update check. The only outbound network requests are the one-time checksum-verified
download of the pinned `libduckdb` (`scripts/fetch-duckdb.sh`, which you run explicitly) and the
one-time `INSTALL` of the DuckDB `delta` and `excel` extensions from DuckDB's own repository.
DuckDB's network filesystems are disabled at runtime.

## The properties that are meant to hold

If you find a way to break one of these, that's a vulnerability and worth reporting:

- **No listener.** Sift 1.x ran a loopback HTTP server; the native rewrite deleted it. There is no
  socket, no token, and no request surface — the UI calls the engine as a library. A patch that
  reintroduces a network listener changes what this program is.
- **`~/.sift` is `0700`.** Staged data lives there.
- **The SQL box cannot write.** The enforcement is *not* the keyword guard — it is that user SQL is
  wrapped as `SELECT * FROM (\n …\n) AS _q`. `DROP`, `COPY`, `ATTACH`, `PRAGMA` and `SET` cannot
  occupy a subquery position, so they die in DuckDB's parser before anything runs. The keyword guard
  exists to produce a better error message, not to be the gate. **A patch that replaces the wrap
  with a blocklist is a security regression**, however much simpler it looks.
- **Export is the one place Sift writes, and it is engine-built.** No user-supplied string reaches a
  `COPY` statement, path, or format; stored SQL is re-validated before wrapping; an existing file is
  never overwritten unless explicitly asked.
- **Sources are read-only.** Sift never writes to a file you opened.
- **Staged data ages out.** Staged tables are purged after 14 days and capped at 20 GB; a staged
  copy is fingerprinted against its source (per-member for folders, with a timestamp that cannot be
  forged from userspace) so a stale copy is collected, never served; and the **Staged** screen lists
  everything currently held with sizes and last-used times.
- **One `Session` per data home.** A second engine on the same `~/.sift` is refused outright — two
  would be two databases silently overwriting each other's writes.

## Known and accepted

**A `SELECT` can read any local file you could `cat`.** DuckDB's file-reading functions are
available in the SQL box, and Sift does not sandbox the filesystem. This is accepted rather than
fixed, on the reasoning that Sift runs as you, on your machine, on files you already have — it never
owns the only copy of anything, sources are read-only, and staged tables are rebuildable. Network
filesystems are disabled, so such a read cannot be exfiltrated by the query itself.

If you are running Sift somewhere that reasoning doesn't hold, don't.

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

Sift is pre-2.0-final and only the current `main` is supported. The DuckDB dependency is a single
prebuilt `libduckdb` pinned by version **and** SHA-256 in `scripts/fetch-duckdb.sh` — an unpinned
floor would mean a surprise upstream release could change CSV sniffing with nothing in the
repository to explain it. The behaviors that pin depends on are executable facts in
`Tests/DuckDBKitTests/DuckDB155FactsTests.swift`, re-verified before any bump.
