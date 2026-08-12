import Foundation
import SiftCore
import SiftEngine
import SwiftUI

// The staged-data manager. Ported from `showStaged` (web/index.html:1332-1370).
//
// This sheet exists because staging writes A REAL COPY OF THE USER'S DATA to their disk, and a
// tool that does that silently is a tool that has to be found out. Everything here is in service
// of one sentence: here is where it is, here is how much of it there is, and here is the button
// that deletes it.
//
// The policy numbers come from `Session.stagePolicy()`, not from `defaultBudgetBytes` /
// `defaultMaxAgeDays`: `SIFT_STAGE_BUDGET_GB` and `SIFT_STAGE_MAX_AGE_DAYS` may have overridden
// them, and a panel restating a default the engine is not enforcing is worse than no panel.
// SiftUI does not read those variables — one authority (Staging.swift).

// MARK: - byte sizes
//
// 🔴 **TASK 9 OWNS `humanBytes`** (`Sources/SiftUI/Inspector/…`, per task-9-brief.md step 2). This
// copy exists only so Task 12 builds and tests standalone against base commit 905fc15, where Task
// 9 has not landed. When the two branches meet, DELETE THIS BLOCK — Swift will tell you loudly
// ("invalid redeclaration"), which is exactly the merge conflict you want rather than two
// implementations quietly disagreeing about what 1023 bytes is called.

/// `1023 → "1023 B"`, `1024 → "1.0 KB"`. Ported from the web's `human` (web/index.html:464-470).
///
/// NOT `ByteCountFormatter`, which is locale- and unit-convention dependent (it renders `1.05 MB`
/// on a system using SI units, and translates the unit names). NOT `SiftCore.human` either, even
/// though that is the same ladder: it groups its integer branch through `grouped(_:decimals:)`, so
/// 1023 bytes reads `1,023 B` there and `1023 B` here — the web's own output, and what task-9's
/// brief pins. `String(format:)` takes no locale and is POSIX.
public func humanBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(n)
    var unit = 0
    while abs(value) >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: unit == 0 ? "%.0f" : "%.1f", value) + " " + units[unit]
}

// MARK: - phrasing

/// Whole GiB, by exact integer division.
///
/// 🔴 Deliberately NOT `humanBytes(policy.budgetBytes)`, which would render `20.0 GB` and drift
/// from the web's `${d.budget_gb} GB`. The division is exact by construction: `stageBudgetBytes()`
/// parses `SIFT_STAGE_BUDGET_GB` as an `Int` and multiplies by 1024³, and `defaultBudgetBytes` is
/// `20 * GB`, so the value is always a whole number of GiB.
public func stageBudgetGB(_ policy: StagePolicy) -> Int { policy.budgetBytes / 1_073_741_824 }

/// The sentence that says what this copy is and what governs it (web/index.html:1335-1339).
public func stagePolicySentence(home: String, policy: StagePolicy) -> String {
    "Native copies kept in \(home) so reopening a large file is instant. This is a real copy of "
        + "your data on this machine: anything untouched for \(policy.maxAgeDays) days is purged "
        + "automatically, and the total is capped at \(stageBudgetGB(policy)) GB."
}

/// `41.2 MB total of 20 GB.` — `stagedTotalBytes()` is the real file on disk, not a sum of
/// per-table estimates.
public func stagedTotalSentence(totalBytes: Int, policy: StagePolicy) -> String {
    "\(humanBytes(totalBytes)) total of \(stageBudgetGB(policy)) GB."
}

/// The source column: the filename, because the full path is 280 px of ellipsis in the web build
/// and lives in the tooltip there for the same reason.
public func stagedSourceName(_ path: String) -> String { (path as NSString).lastPathComponent }

/// ` (source gone)` / ` (source changed)`, or `nil`. Missing wins: `stagedEntries` can only report
/// `sourceChanged` from a `stat` that succeeded, so the two are never both true — the order is
/// stated anyway so a future change to that derivation cannot silently make it ambiguous.
public func stagedSourceMarker(_ entry: StagedSource) -> String? {
    if entry.sourceMissing { return " (source gone)" }
    if entry.sourceChanged { return " (source changed)" }
    return nil
}

/// `2026-08-11 14:03`, hand-rolled from `Calendar.current`.
///
/// 🔴 NO `DateFormatter`/`ISO8601DateFormatter`. Without an explicit locale and calendar a
/// `DateFormatter` renders this date four ways and, under a non-Gregorian calendar, a different
/// year entirely. The web build sliced an ISO string to 16 characters for exactly this reason;
/// this is that slice, built from components instead of from a string.
public func stagedTimestamp(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    func pad(_ n: Int?, _ width: Int) -> String {
        var digits = String(n ?? 0)
        while digits.count < width { digits = "0" + digits }
        return digits
    }
    return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)) \(pad(c.hour, 2)):\(pad(c.minute, 2))"
}

// MARK: - the sheet

/// What Sift is holding on to, and the two buttons that stop it.
public struct StagedDataSheet: View {
    private let session: Session

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [StagedSource] = []
    @State private var totalBytes = 0
    @State private var loaded = false
    @State private var error: String?

    public init(session: Session) {
        self.session = session
    }

    private var policy: StagePolicy { session.stagePolicy() }   // nonisolated

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Staged data").font(.system(size: 15, weight: .semibold))
            Text(stagePolicySentence(home: session.siftHome, policy: policy))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                Text("Nothing staged.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            ForEach(["table", "source", "size", "last used", ""], id: \.self) {
                                Text($0).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(entries, id: \.table) { entry in
                            GridRow {
                                Text(entry.table).font(.system(size: 12))
                                StagedSourceCell(entry: entry)
                                Text(humanBytes(entry.bytes)).font(.system(size: 12))
                                Text(stagedTimestamp(entry.lastUsed)).font(.system(size: 12))
                                Button("drop") { Task { await purge(tables: [entry.table]) } }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                Text(stagedTotalSentence(totalBytes: totalBytes, policy: policy))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Clear all staged data") { Task { await purge(all: true) } }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760)
        .task { await reload() }
    }

    private func reload() async {
        do {
            entries = try await session.stagedEntries()
            totalBytes = session.stagedTotalBytes()   // nonisolated
            error = nil
        } catch {
            // The engine's own sentence, unwrapped. A `try?` here would leave the panel claiming
            // "Nothing staged." about a store it could not read — the exact shape of lie this
            // whole sheet exists to prevent.
            self.error = "\(error)"
        }
        loaded = true
    }

    /// A purge NEVER yanks a table out from under an open tab — `purgeStagedTables` skips anything
    /// still in the catalog — so a row can survive a `drop`. Reloading rather than removing the row
    /// optimistically is what keeps the panel honest about that.
    private func purge(tables: [String]? = nil, all: Bool = false) async {
        do {
            _ = try await session.purgeStaged(tables: tables, all: all)
        } catch {
            self.error = "\(error)"
        }
        await reload()
    }
}

/// The filename plus its staleness marker, which carries a colour the filename does not.
private struct StagedSourceCell: View {
    let entry: StagedSource

    var body: some View {
        HStack(spacing: 0) {
            Text(stagedSourceName(entry.path)).font(.system(size: 12)).lineLimit(1)
            if let marker = stagedSourceMarker(entry) {
                Text(marker)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.sourceMissing ? Color.red : Color.orange)
            }
        }
        .help(entry.path)
    }
}
