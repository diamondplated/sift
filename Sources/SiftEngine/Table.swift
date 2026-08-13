import Foundation
import SiftCore

// One open source and everything the UI knows about it. Ported from engine/session.py's
// `Table` dataclass (lines 123-210) — `summary()` is not ported: it exists in Python only to
// shape a JSON payload for the browser, and there is no JSON wire format anymore (SiftUI, in a
// later plan, observes `Session`'s catalog directly). `copied_from_browser` is also dropped —
// browser-drop mode is gone, per the design spec's "what gets deleted" list.
//
// A struct, not a class: `Session` (the actor) holds these in its `tables` dictionary and is the
// only thing that mutates one — read-modify-write through the dictionary, never a shared
// reference handed out and mutated from outside. `Sendable` because a background `Task` (Task 4's
// `_after_open` port) passes a snapshot of one across an isolation boundary to compute results
// off the actor.

/// Progress of an in-flight staging job. Written by `Session.stageNow` and cleared by whichever
/// of `applyStaged`/`finishStage` ends the job (Staging.swift).
///
/// 🔴 **There is no `pct`, and there cannot be one.** This struct carried a `Double pct` from the
/// Python port until 2026-08-13. It had exactly one write site — `stageNow`, which wrote `0` — and
/// exactly one read site: a *determinate* `ProgressView(value:)` in the staging banner. So the bar
/// rendered 0 % for the entire life of every staging job that ever ran, and read as a copy that had
/// not started.
///
/// A real percentage is not available to be written. The copy is one `CREATE TABLE … AS SELECT`
/// inside `runStage`; DuckDB's C API offers no row-level callback for it, and the obvious substitute
/// — the store's growth, `dbBytes()` — is measured elsewhere in this file to be unusable as a
/// per-job number: it is the WHOLE store, so two jobs in flight charge each other (`stagedBytes`'
/// review-I4 measurement, 262,144 B alone vs 413 B beside a 30 MB copy), and it moves at CHECKPOINT
/// rather than continuously, which would draw 0 % until the job was over anyway. The field is gone
/// rather than left at zero: a field that only a liar can read is how the bar comes back.
public struct StagingProgress: Sendable, Equatable {
    public let jobID: String
    public let state: String
    /// The engine's own guess at how long the copy takes, from `StageDecision.estSeconds`. A FLOOR,
    /// not a promise — see `SiftUI.stagingText`, which is what decides how coarsely to say it.
    public let estSeconds: Double

    public init(jobID: String, state: String, estSeconds: Double) {
        self.jobID = jobID
        self.state = state
        self.estSeconds = estSeconds
    }
}

public struct Table: Sendable {
    public let name: String
    /// `internal(set)`, not `let`: read-only to every consumer outside this module (`Table` is a
    /// struct, so nothing outside can mutate the catalog's copy anyway), while `Session`'s test
    /// seam `setSourceSpecForTest` can point a real, tiny table at a spec that claims to be 30 GB
    /// — the only way to exercise `profileIfCheap`'s cost gate without writing 30 GB.
    public internal(set) var spec: SourceSpec
    public var qspec: QuerySpec
    public var sqlMode: Bool = false
    public var sqlText: String?

    /// Physical rows in the source, once known exactly (see `Session`'s background count).
    public var rowCount: Int?
    /// Rows matching the current filters — `nil` means "not yet counted for this spec".
    public var filteredCount: Int?
    /// Rows dropped because at least one cell would not cast to its sniffed type.
    public var badRows: Int = 0
    public var badCells: Int = 0
    public var counting: Bool = false

    public var staged: Bool = false
    public var staging: StagingProgress?
    public var stageDecision: StageDecision?
    /// Why the last staging job failed, or `nil` if it did not. This is Python's
    /// `emit({"type": "error", "table": name, "msg": "staging failed: ..."})`: SSE is gone, and
    /// per Session.swift's header the state change IS the notification — but a background copy
    /// that dies must still say so somewhere, or the table just silently stays unstaged forever.
    /// A cancelled job leaves this `nil`; the user asked for that one.
    public var stagingError: String?

    public var profile: [ColumnProfile]?
    public var profiling: Bool = false

    /// This table's open generation — a monotonic counter (`Session.nextOpenGeneration`), NOT a
    /// wall-clock time, despite the name Python's `opened_at: float = time.time()` suggested it
    /// keep. Its only job is telling one open of a table apart from a LATER open reusing the same
    /// name, so `runAfterOpen`'s background callbacks can detect a close-and-reopen and refuse to
    /// write a stale result onto the new table (review C1). A `Date` did that job too, but only by
    /// margin, not by construction: MEASURED, `Date()` collided on 152,341 of 200,000 back-to-back
    /// constructions (~0.95µs clock granularity), safe here only because a real close-and-reopen
    /// is never that fast (measured minimum 1.116ms, 1,170x the resolution) — a margin a future
    /// caller could erode without warning. A counter can't collide, full stop.
    public let openedAt: Int
    public var lastUsed: Date
    public var firstAggregateAt: Date?
    public var notes: [String] = []

    /// The open tables a `merge` view reads, or empty for anything backed by a file. Recorded
    /// rather than parsed back out of `spec.key.path` ("merge://a+b") because a table named
    /// `a+b` would make that string ambiguous, and because it dies with the table for free.
    ///
    /// `closeTable` refuses to close a table this names — see Joins.swift's `assertNoLiveMerge`.
    /// Without it, closing a merged table's source left the merge in the catalog looking fine
    /// and throwing a raw `Catalog Error` on every read.
    public var mergedFrom: [String] = []

    /// Name of the temp table currently holding a sorted result set, or `nil` when the current
    /// page request carries no sort. Set only by `Session.sortedRelation`.
    var sortKey: String?
    /// Per-column bad-cell counts from `Session`'s single all-varchar scan
    /// (`c0__bad`, `c1__bad`, ... plus `n`), cached so a future profiling task does not have to
    /// re-run that scan. Consumed starting Task 5.
    var uncastable: [String: Int]?

    public init(name: String, spec: SourceSpec, qspec: QuerySpec, openedAt: Int) {
        self.name = name
        self.spec = spec
        self.qspec = qspec
        self.openedAt = openedAt
        self.lastUsed = Date()
        // Seeded here, not appended by `openPath` alongside the sheet/folder/Delta notes, because
        // these are properties of the SPEC rather than of one code path that happened to open it:
        // a table built from a mis-sniffed source carries its note whoever constructed it, and
        // there is no way to add a second construction site that quietly loses it.
        self.notes = [raggedCollapseNote(spec), preambleNote(spec)].compactMap { $0 }
    }

    /// This table's columns keyed by name. `uniquingKeysWith` (last wins), not
    /// `uniqueKeysWithValues` (which traps on a duplicate key) — mirrors Python's
    /// `{c.name: c for c in self.spec.columns}` dict comprehension, which silently lets a later
    /// duplicate header win rather than crashing on a file that has one.
    public var cols: [String: Column] {
        Dictionary(spec.columns.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Rows the grid can actually page through: physical minus rows dropped by `ignore_errors`.
    public var gridRows: Int? {
        guard let rowCount else { return nil }
        return max(0, rowCount - badRows)
    }

    /// Rows the grid will page through right now — filtered if any filter is active.
    ///
    /// The scroll extent depends on this, so getting it wrong makes the thumb overshoot the data.
    public var visibleRows: Int? {
        if !qspec.filters.isEmpty, let filteredCount {
            return filteredCount
        }
        return gridRows
    }

    /// Rows to show, and to size the grid from: the exact/filtered count once known, otherwise
    /// the cheap byte-sample estimate. Ports `Table.summary()`'s `rows.value`
    /// (`visible_rows if visible_rows is not None else est.rows`).
    ///
    /// The fallback is not cosmetic. `openPath` sets `rowCount` only from `spec.rowCount`, which
    /// `buildSource` leaves nil for any CSV above `exactCountMaxBytes` — so without this a
    /// multi-GB CSV shows an EMPTY grid from open until a detached background count finishes,
    /// which is precisely the case the product is sold on.
    public var displayRows: Int? { visibleRows ?? spec.rowEstimate?.rows }

    /// Whether `displayRows` is counted or estimated. `summary()`'s `rows.exact`.
    public var rowsAreExact: Bool { rowCount != nil }

    /// How `displayRows` was arrived at. `summary()`'s `rows.basis`, all three branches — but as
    /// a value, not a sentence.
    ///
    /// Python returned the literal string because its engine served exactly one consumer. This
    /// engine has two (`SiftUI` and the `sift` CLI), which want different phrasing, and keeping
    /// user-facing sentences out of `SiftEngine` means a wording change never touches the engine.
    public enum RowsBasis: Sendable, Equatable {
        case counted
        /// The byte-sample estimator's own description, e.g. "3x256KiB sample, no quotes seen".
        case estimated(String)
        case pending
    }

    public var rowsBasis: RowsBasis {
        if rowCount != nil { return .counted }
        if let basis = spec.rowEstimate?.basis { return .estimated(basis) }
        return .pending
    }

    /// Rows the grid can actually reach right now — `displayRows`, capped at what
    /// `Session.sortedRelation` will have materialized.
    ///
    /// Spec §13a: a sorted result set is materialized once, at most `sortMaterializeMax` rows, and
    /// pages past that come back EMPTY while the count still reports the full total. Sizing the
    /// extent from the count would promise 100M rows and deliver 5M followed by 95M blank ones.
    /// Capping makes the extent true; `sortTruncated` is how the UI says the tail exists and how
    /// to reach it. The alternative §13a names — re-materializing a window per scroll — was
    /// rejected: `sortedRelation`'s own measurement shows tie order is not reproducible across
    /// separate materializations, so two windows can duplicate or drop rows at their seam.
    public var scrollableRows: Int? {
        guard let rows = displayRows else { return nil }
        return qspec.sort.isEmpty ? rows : min(rows, sortMaterializeMax)
    }

    /// `true` when a sort is active and there are more rows than the materialized copy holds.
    public var sortTruncated: Bool {
        guard !qspec.sort.isEmpty, let rows = displayRows else { return false }
        return rows > sortMaterializeMax
    }
}
