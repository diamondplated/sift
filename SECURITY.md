# Security

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** form on this repository (private vulnerability
reporting is enabled). Please don't open a public issue for an unpatched problem.

Include the file format and roughly how big the file was — most behaviour here is size- and
format-dependent, and it narrows the search immediately. If it involves a remote source, say which
scheme (`https`, `s3`, `az`, `abfss`) and whether a saved connection was in play.

## What Sift is, from a security standpoint

Sift is a single-user local tool. It opens files on your own machine and shows you what's in them.
There is no server, no port, no multi-tenancy and no account system — one native process, one
binary.

**It reaches nothing until you ask it to.** On a fresh install there is no `connections.json`,
`allowRemote` is `false`, DuckDB's network filesystems are disabled by name, and `httpfs` and
`azure` are never even loaded. No telemetry, no analytics, no update check. The outbound requests a
default install makes are the one-time checksum-verified download of the pinned `libduckdb`
(`scripts/fetch-duckdb.sh`, which you run explicitly) and the one-time `INSTALL` of the DuckDB
`delta` and `excel` extensions from DuckDB's own repository.

Two things used to make that paragraph untrue and no longer do, both fixed in the Phase 1 review:
saving your first connection installed the `azure` or `httpfs` extension over the network
immediately, on the session that had just promised not to; and the SELECT-only gate's parser
connection, which is handed the SQL you type, kept DuckDB's default "install an extension if a query
needs one", so `SELECT * FROM read_csv('https://…')` fetched `httpfs` from DuckDB's repository
before refusing the read. Both now wait for the relaunch you asked for.

**Adding a connection is what turns that off, and it is a decision you make.** Saving the first
connection in **Data → Connections…** sets `allowRemote: true` in the config and writes your
credential to the Keychain, and does nothing else — this session installs no extension and
registers no credential with DuckDB, because it was opened strict and cannot use either. From the
next launch that session's DuckDB is opened without the filesystem deny list and with `httpfs` (and
`azure`, if a saved connection needs it) loaded. From that point Sift can read `https://`, `s3://`,
`az://` and `abfss://` URLs — and so can any `SELECT` you run. See **The trade you are making**, below, which
is the part worth reading twice.

The switch is revocable: turning it off rewrites the config and drops every issued credential
immediately. The *filesystem* stays reachable until you relaunch, because DuckDB's
`disabled_filesystems` can only ever grow inside a live database — it cannot be narrowed, cleared
or reset. Sift says which of the two happened rather than claiming the stronger one; a screen that
reports a revoke that has not taken effect is worse than no screen.

## The properties that are meant to hold

If you find a way to break one of these, that's a vulnerability and worth reporting:

- **The only listener is the test oracle, and it is bound to loopback.**
  `LoopbackHTTPServer` (`Sources/SiftEngine/LoopbackHTTPServer.swift`) binds `INADDR_LOOPBACK` on
  an ephemeral port, is started only by a test or by `sift --verify`, and is never constructed on
  any path a running app can reach. It exists so the remote code can be proved without a network.
  **A patch that gives it a wildcard bind, or starts it from the app, changes what this program
  is.**
- **Remote is off by default and the posture is frozen at launch.** `harden(allowRemote:)` runs
  before the first query, from a config file read before the database opens. There is no live
  switch and there cannot be one; anything claiming to be one is a bug.
- **Credentials live in the Keychain.** `connections.json` is `0600`, carries account names and key
  ids and no secret material, and no Keychain payload ever reaches it. Nothing is written to
  `stage.duckdb` either: DuckDB secrets are issued `TEMPORARY`, they die with the database, and
  `CREATE PERSISTENT SECRET` is deliberately unused — a second on-disk credential store is a second
  thing to get wrong.
- **`CREATE SECRET` is issued engine-side only.** Credentials are bound as parameters, never
  interpolated; the only generated part is the secret's own name, which Sift builds itself. The
  statement is unreachable from the SQL box.
- **A SAS token is memory-only, for the length of one open.** A `?sv=…&sig=…` query is a bearer
  credential. `RemoteURL.sanitized` — the URL with its query gone — is the only form that is ever
  displayed or persisted, and `wireURL(_:)` is the single choke point that re-attaches the
  signature for one DuckDB call. It must not appear in `spec.target`, `spec.key.path`, the SQL
  DuckDB stores for a created view, either persisted column of `_sift_sources`, a cache filename,
  `connections.json`, any snippet dialect, or any error message. This is why a SAS-signed parquet
  is downloaded rather than read in place, and why the app says so. The one thing Sift keeps is
  `RemoteRef.signed` — a **boolean**, "this URL arrived with a query", and never the query, the
  signature, or a length or prefix of either. It is in memory only, it is not persisted and not part
  of any cache identity, and it exists so that refreshing or re-opening such a source is refused with
  a sentence naming the fix instead of quietly sent as an anonymous request.
- **The SQL box cannot write.** The enforcement is *not* the keyword guard — it is that user SQL is
  wrapped as `SELECT * FROM (\n …\n) AS _q`. `DROP`, `COPY`, `ATTACH`, `PRAGMA` and `SET` cannot
  occupy a subquery position, so they die in DuckDB's parser before anything runs. The keyword
  guard exists to produce a better error message, not to be the gate. **A patch that replaces the
  wrap with a blocklist is a security regression**, however much simpler it looks.
- **Export is the one place Sift writes, and it is engine-built.** No user-supplied string reaches a
  `COPY` statement, path, or format; stored SQL is re-validated before wrapping; an existing file is
  never overwritten unless explicitly asked.
- **Sources are read-only.** Sift never writes to a file you opened, local or remote.
- **Staged and downloaded data ages out.** `~/.sift` is `0700` and so is the `remote-cache/`
  directory inside it; every downloaded object is `0600`. Staged tables are purged after 14 days and
  capped at 20 GB; a downloaded copy is collected on the same clock, and immediately if nothing
  points at it. A staged copy is fingerprinted against its source (per-member for folders, by
  `ETag` or `Last-Modified`+`Content-Length` for a URL, with a timestamp that cannot be forged from
  userspace) so a stale copy is collected, never served. The **Staged** screen lists everything
  currently held — the DuckDB store *and* the downloaded copies — with sizes and last-used times.
- **One `Session` per data home.** A second engine on the same `~/.sift` is refused outright — two
  would be two databases silently overwriting each other's writes.

## Known and accepted

**A `SELECT` can read any local file you could `cat`.** DuckDB's file-reading functions are
available in the SQL box, and Sift does not sandbox the filesystem. This is accepted rather than
fixed, on the reasoning that Sift runs as you, on your machine, on files you already have — it never
owns the only copy of anything, sources are read-only, and staged tables are rebuildable.

**The trade you are making when you turn remote on.** With a connection saved, a `SELECT` in the
SQL box can read a URL — and a query that can read a local file *and* reach a URL can send the
first to the second. `SELECT * FROM read_csv('/…/secrets.csv')` joined against a remote table is a
read; a URL carrying data in its path is a write nobody stops. The SELECT-only gate still holds —
no `COPY TO`, no `ATTACH`, nothing that writes — so this is exfiltration by a crafted read, not by
a write, and the shape it takes is bounded by that. It is the stated cost of the feature, not a
hole: remote data is off until you ask for it, adding a connection is what asks, and the switch is
in one screen with one toggle. If you are running Sift somewhere that trade is not yours to make,
don't turn it on.

**Staged and downloaded data is a real copy of your data on disk.** A downloaded remote object is
exactly as sensitive as the blob you pulled it from — same reasoning as a staged local table, same
0700 directory, same 0600 files, same age-out, same one screen that answers "what is this tool
holding on to".

## Out of scope

- Anything requiring an attacker who already has local code execution as your user. At that point
  they can read the files directly.
- Denial of service from a deliberately malformed file. Sift may refuse it or take a long time; that
  is a bug, not a vulnerability.
- The DuckDB extensions themselves, which are distributed by DuckDB.
- The contents of a remote object you deliberately pointed Sift at, and what the server on the other
  end logs about the request.

## Supported versions

Sift is pre-2.0-final and only the current `main` is supported. The DuckDB dependency is a single
prebuilt `libduckdb` pinned by version **and** SHA-256 in `scripts/fetch-duckdb.sh` — an unpinned
floor would mean a surprise upstream release could change CSV sniffing with nothing in the
repository to explain it. The behaviors that pin depends on are executable facts in
`Tests/DuckDBKitTests/DuckDB155FactsTests.swift` and `Tests/DuckDBKitTests/RemoteFactsTests.swift`,
re-verified before any bump.
