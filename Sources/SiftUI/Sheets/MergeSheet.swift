import Foundation
import SiftCore
import SiftEngine
import SwiftUI

// Merge. Ported from `showMerge` (web/index.html:1419-1495).
//
// The overlap probe is a PREVIEW here, not the product — the product is the joined view that lands
// in the sidebar. But the preview is what prevents more bad analyses than anything else in the
// app: "1,204 of 1,318 distinct order_id in orders match returns → 91.4%" tells you in one glance
// whether the key you picked is the key you meant.
//
// 🔴 `JoinType` IS AN ENUM, and the picker binds to `JoinType.allCases` rendering `rawValue`.
// That is not a style choice — Joins.swift made it an enum precisely so a menu string cannot reach
// the SQL text at all. Never construct one from typed input; never build the join keyword here.
//
// 🔴 **Closing a source under a live merge is REFUSED, not cascaded.** `assertNoLiveMerge` throws
// a sentence naming the dependents ("'a' is merged into 'a_b'. Close 'a_b' first."), and that is
// the behaviour: a merge built here creates a real dependency, and closing tabs the user did not
// ask to close is its own surprise. This sheet does not cascade, does not pre-close anything, and
// does not paper over that refusal anywhere.
//
// `unmatchedKeys(_:_:on:limit:)` exists on the engine and the web build never surfaced it. It
// stays unsurfaced — see task-12-brief.md step 6.

// MARK: - phrasing

/// The web's `pct`: `(f * 100).toFixed(f < 0.01 && f > 0 ? 2 : 1) + "%"`. Two decimals only in the
/// band where one would round a real-but-tiny overlap to a flat `0.0%` and read as "no match at
/// all". `String(format:)` is POSIX and takes no locale; `NumberFormatter` is banned branch-wide.
public func joinPercent(_ fraction: Double) -> String {
    let decimals = (fraction > 0 && fraction < 0.01) ? 2 : 1
    return String(format: "%.\(decimals)f", fraction * 100) + "%"
}

/// `1,204 of 1,318 distinct order_id in orders match returns → 91.4%`.
///
/// `JoinProbe.pct` is a fraction (0.0-1.0) by contract, not a percentage — the engine leaves
/// formatting to the UI, and this is the multiply it left behind.
public func overlapSentence(_ probe: JoinProbe) -> String {
    "\(groupDigits(String(probe.matched))) of \(groupDigits(String(probe.leftDistinct))) distinct "
        + "\(probe.on.joined(separator: " + ")) in \(probe.left) match \(probe.right) "
        + "→ \(joinPercent(probe.pct))"
}

/// The second line, or `nil` when every key found a partner. A key tuple containing NULL counts
/// toward `leftDistinct` and can never count toward `matched` (`NULL = NULL` is unknown), so this
/// line is where a NULL-heavy key announces itself.
public func unmatchedSentence(_ probe: JoinProbe) -> String? {
    guard probe.unmatched > 0 else { return nil }
    return "\(groupDigits(String(probe.unmatched))) unmatched (kept only by a left/full join)"
}

/// `Merged into orders_returns — 1,204 rows`. The presenting view raises this; the sheet hands
/// back the `Table` and gets out of the way.
public func mergeToast(_ table: SiftEngine.Table) -> String {
    guard let rows = table.displayRows else { return "Merged into \(table.name)" }
    return "Merged into \(table.name) — \(groupDigits(String(rows))) rows"
}

/// What to say above the key list, given what `joinCandidates` came back with.
public enum MergeKeyPrompt: Equatable, Sendable {
    case sameTable
    case noSharedColumns
    case pick

    public var text: String {
        switch self {
        case .sameTable: return "Pick two different tables."
        case .noSharedColumns: return "These two share no column names — nothing to join on."
        case .pick: return "Join on — tick one or more keys:"
        }
    }
}

public func mergeKeyPrompt(left: String, right: String, candidates: [JoinCandidate])
    -> MergeKeyPrompt
{
    if left == right { return .sameTable }
    return candidates.isEmpty ? .noSharedColumns : .pick
}

// MARK: - the sheet

/// Blend two open tables into a new one.
public struct MergeSheet: View {
    private let session: Session
    private let tables: [String]
    private let onMerged: (SiftEngine.Table) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var left: String
    @State private var right: String
    @State private var how: JoinType = .inner
    @State private var candidates: [JoinCandidate] = []
    @State private var picked: Set<String> = []
    @State private var name = ""
    @State private var probe: JoinProbe?
    @State private var running = false
    @State private var error: String?

    /// `tables` is the open catalog's names in the order the sidebar shows them. Two are the
    /// minimum; the presenting view is what refuses to open this sheet with fewer
    /// (`AppState.presentMerge`'s `canMerge` guard, the web's "Open at least two tables to merge
    /// them.").
    ///
    /// 🔴 **Captured by value at presentation, and left that way deliberately.** A table closed
    /// while this sheet is up stays listed and selectable, and picking it fails with the engine's
    /// own "No open table named …" rather than doing something silent. Not fixed here because a
    /// live list is not a one-line change: `left`/`right` are `@State` initialised from this array,
    /// so a table vanishing out of it has to move a selection the user made, mid-probe, and the
    /// two `.task(id:)` re-runs that follow are a re-query against a catalog that just changed.
    /// The list also cannot simply be re-read from `AppState` — this sheet does not reach into it
    /// (that is the seam `onMerged` exists to keep). Filed rather than fudged.
    public init(
        session: Session, tables: [String], initialLeft: String? = nil,
        onMerged: @escaping (SiftEngine.Table) -> Void
    ) {
        self.session = session
        self.tables = tables
        self.onMerged = onMerged
        let first = initialLeft ?? tables.first ?? ""
        _left = State(initialValue: first)
        _right = State(initialValue: tables.first { $0 != first } ?? first)
    }

    private var prompt: MergeKeyPrompt {
        mergeKeyPrompt(left: left, right: right, candidates: candidates)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge tables").font(.system(size: 15, weight: .semibold))
            Text(
                """
                Join two tables into a new dataset. It appears in the sidebar as a view — instant, \
                no copy — and you can explore or export it like any other source.
                """
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("", selection: $left) {
                    ForEach(tables, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Picker("", selection: $how) {
                    // `JoinType.allCases` and `rawValue` — never a hand-written menu of strings.
                    ForEach(JoinType.allCases, id: \.self) { Text("\($0.rawValue) join").tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                Picker("", selection: $right) {
                    ForEach(tables, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            Text(prompt.text).font(.system(size: 12)).foregroundStyle(.secondary)
            if prompt == .pick {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates, id: \.col) { candidate in
                            HStack(spacing: 6) {
                                Toggle(
                                    candidate.col,
                                    isOn: Binding(
                                        get: { picked.contains(candidate.col) },
                                        set: { on in
                                            if on { picked.insert(candidate.col) }
                                            else { picked.remove(candidate.col) }
                                        })
                                )
                                .font(.system(size: 12))
                                .disabled(!candidate.compatible)
                                Text("\(candidate.leftType) / \(candidate.rightType)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if !candidate.compatible {
                                    Text("type mismatch")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.orange)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            TextField("new table name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if let probe {
                VStack(alignment: .leading, spacing: 2) {
                    Text(overlapSentence(probe))
                    if let unmatched = unmatchedSentence(probe) { Text(unmatched) }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge →") { Task { await merge() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || running)
            }
        }
        .padding(16)
        .frame(width: 760)
        .task(id: "\(left)\u{0}\(right)") { await loadKeys() }
        .task(id: "\(left)\u{0}\(right)\u{0}\(picked.sorted().joined(separator: "\u{0}"))") {
            await runProbe()
        }
    }

    private func loadKeys() async {
        picked = []
        probe = nil
        error = nil
        guard left != right else {
            candidates = []
            return
        }
        do {
            candidates = try await session.joinCandidates(left, right)
        } catch {
            candidates = []
            self.error = error.localizedDescription
        }
    }

    /// Live, on every tick. `joinProbe` is a pair of DISTINCT counts and a SEMI JOIN — cheap
    /// enough to run per keystroke on the key list, which is the entire reason it exists as a
    /// preview rather than as something you press a button for.
    private func runProbe() async {
        let keys = candidates.map(\.col).filter { picked.contains($0) }
        guard !keys.isEmpty else {
            probe = nil
            return
        }
        do {
            probe = try await session.joinProbe(left, right, on: keys)
            error = nil
        } catch {
            probe = nil
            self.error = error.localizedDescription
        }
    }

    private func merge() async {
        running = true
        defer { running = false }
        let keys = candidates.map(\.col).filter { picked.contains($0) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let merged = try await session.merge(
                left, right, on: keys, how: how, name: trimmed.isEmpty ? nil : trimmed)
            onMerged(merged)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
