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

/// Progress of an in-flight staging job. Not populated by anything in this file — `stage_now`/
/// `_do_stage` are a later task — but the field exists on `Table` now so that task only adds a
/// setter, not a type.
public struct StagingProgress: Sendable, Equatable {
    public let jobID: String
    public let state: String
    public let pct: Double
    public let estSeconds: Double

    public init(jobID: String, state: String, pct: Double, estSeconds: Double) {
        self.jobID = jobID
        self.state = state
        self.pct = pct
        self.estSeconds = estSeconds
    }
}

public struct Table: Sendable {
    public let name: String
    public let spec: SourceSpec
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

    public var profile: [ColumnProfile]?
    public var profiling: Bool = false

    public let openedAt: Date
    public var lastUsed: Date
    public var firstAggregateAt: Date?
    public var notes: [String] = []

    /// Name of the temp table currently holding a sorted result set, or `nil` when the current
    /// page request carries no sort. Set only by `Session.sortedRelation`.
    var sortKey: String?
    /// Per-column bad-cell counts from `Session`'s single all-varchar scan
    /// (`c0__bad`, `c1__bad`, ... plus `n`), cached so a future profiling task does not have to
    /// re-run that scan. Consumed starting Task 5.
    var uncastable: [String: Int]?

    public init(name: String, spec: SourceSpec, qspec: QuerySpec) {
        self.name = name
        self.spec = spec
        self.qspec = qspec
        let now = Date()
        self.openedAt = now
        self.lastUsed = now
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
}
