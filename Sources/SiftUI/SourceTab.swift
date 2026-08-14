import SiftCore
import SiftEngine
import SwiftUI

// The inspector's Source tab: where this table came from, how big it is, how its row count was
// arrived at, and the two things a person can do about it — pick a different sheet, or stage it.
// Ported from `web/index.html:1082-1143` (`renderSource`).
//
// Everything the user reads here is a *sentence*, and sentences live in the UI. The engine hands up
// values — `Table.RowsBasis`, `StageDecision.reason`, `SourceSpec` — and this file is the only place
// that turns them into English. That is the same directional rule `CellGlyph.swift` states from the
// other side: cell *semantics* comes down from the engine so the CLI and the grid cannot disagree
// about what a null is; *phrasing* goes up so a terminal and a sidebar can word it differently.

/// Where this table came from — and the two buttons that change it.
public struct SourceTab: View {
    private let state: AppState
    private let table: SiftEngine.Table

    public init(state: AppState, table: SiftEngine.Table) {
        self.state = state
        self.table = table
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(table.name).font(.system(size: 13, weight: .semibold))
            // Wrapping, not eliding: a path the user cannot read the end of is a path that does not
            // answer the one question this line exists for — *which* of the four `data.csv`s is this.
            Text(table.spec.key.path)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Self.stats(table), id: \.label) { stat in
                    GridRow {
                        Text(stat.label).foregroundStyle(.secondary)
                        Text(stat.value)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .font(.system(size: 11))

            Text(rowsBasisText(table.rowsBasis))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if table.spec.sheets.count > 1 {
                Text("Sheets").font(.system(size: 11, weight: .semibold))
                ForEach(table.spec.sheets, id: \.name) { sheet in
                    Button {
                        // The same route the sidebar's "Open Another Sheet…" takes — one rule about
                        // which path a re-open uses, and one refusal for a signed source, rather
                        // than two views each spelling `open(path: spec.key.path, sheet:)`.
                        Task { await state.openSheet(of: table, sheet: sheet.name) }
                    } label: {
                        HStack {
                            Text(sheet.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Self.sheetDetail(sheet))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                }
            }

            Text("Staging").font(.system(size: 11, weight: .semibold))
            Text(Self.stagingNote(table))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch Self.staging(table) {
            case .staged:
                Button("Read from source instead") {
                    Task {
                        do {
                            _ = try await state.session.unstage(table.name)
                            await state.refresh()
                        } catch {
                            // Surfaced, never swallowed: the button's whole promise is that the next
                            // read comes off the file, and a failure that says nothing leaves the
                            // user believing it did.
                            state.banner = error.localizedDescription
                        }
                    }
                }
            case .stageable:
                Button("Stage this file") {
                    Task {
                        do {
                            // `force: true` — the user asked, so the policy's own answer (which is
                            // what put the reason in the note above) does not get a veto.
                            _ = try await state.session.stageNow(table.name, force: true)
                            await state.refresh()
                        } catch {
                            state.banner = error.localizedDescription
                        }
                    }
                }
            case .neither:
                EmptyView()
            }

            if let prompt = table.spec.sniffPrompt {
                Text("Detected dialect").font(.system(size: 11, weight: .semibold))
                Text(Self.dialectText(prompt))
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(red: 26 / 255, green: 35 / 255, blue: 43 / 255))
                    .foregroundStyle(Color(red: 185 / 255, green: 201 / 255, blue: 212 / 255))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - what the panel says

    struct Stat: Equatable {
        let label: String
        let value: String
    }

    /// The stats grid, in the web's order. Rows that would say nothing are absent rather than
    /// blank — a `sheet` row on a CSV is noise, and a `staged: no` row is a claim about a feature
    /// the user has not met yet.
    nonisolated static func stats(_ table: SiftEngine.Table) -> [Stat] {
        var out: [Stat] = [
            Stat(label: "format", value: table.spec.fmt.rawValue),
            Stat(label: "size", value: humanBytes(table.spec.key.size)),
            Stat(label: "columns", value: String(table.spec.columns.count)),
            Stat(label: "rows", value: rowsText(table)),
        ]
        // Physical rows only when they differ from the number above: on an unfiltered, clean table
        // the two are the same and the second copy just invites the question "which is right".
        if let physical = table.rowCount, physical != table.displayRows {
            out.append(Stat(label: "physical rows", value: groupDigits(String(physical))))
        }
        if table.badCells > 0 {
            out.append(Stat(label: "bad cells", value: groupDigits(String(table.badCells))))
        }
        if table.staged { out.append(Stat(label: "staged", value: "yes")) }
        if let sheet = table.spec.sheet { out.append(Stat(label: "sheet", value: sheet)) }
        if let version = table.spec.deltaVersion {
            out.append(Stat(label: "delta version", value: String(version)))
        }
        return out
    }

    /// The row count, with `≈` in front of it when it is the byte-sample estimate rather than a
    /// count. 🔴 The tilde is the whole difference between "this file has 4,812,004 rows" and "we
    /// guessed 4,812,004"; dropping it is the product telling its one lie.
    nonisolated static func rowsText(_ table: SiftEngine.Table) -> String {
        guard let rows = table.displayRows else { return "…" }
        return (table.rowsAreExact ? "" : "≈") + groupDigits(String(rows))
    }

    nonisolated static func sheetDetail(_ sheet: SheetInfo) -> String {
        sheet.empty ? "empty" : "\(groupDigits(String(sheet.rows)))×\(sheet.cols)"
    }

    /// Which of the three staging states this table is in.
    enum Staging: Equatable {
        case staged
        case stageable
        case neither
    }

    /// Formats worth offering a copy of. A `Set<Fmt>`, not of strings: `web/index.html` compared
    /// `t.fmt` against `["csv", "glob_csv", …]` and a typo in one of those literals is a silently
    /// missing button. Mirrors `SidebarViewController.stageable`.
    ///
    /// This set only decides whether to OFFER the button. `SiftCore.shouldStage` remains the
    /// authority on whether staging is a good idea, and its reason is what the note quotes.
    nonisolated static let stageable: Set<Fmt> = [.csv, .globCsv, .xlsx, .json, .ndjson]

    nonisolated static func staging(_ table: SiftEngine.Table) -> Staging {
        if table.staged { return .staged }
        return stageable.contains(table.spec.fmt) ? .stageable : .neither
    }

    /// The paragraph above the button — what staging is, in this table's particular case.
    nonisolated static func stagingNote(_ table: SiftEngine.Table) -> String {
        switch staging(table) {
        case .staged:
            return "Staged: a native copy lives on disk, so scrolling and grouping this file are "
                + "instant. It uses disk and holds a copy of the data."
        case .stageable:
            let base = "Reading the file in place. Stage it to keep a native copy — scrolling and "
                + "grouping become instant on large files, at the cost of some disk and a copy of "
                + "the data."
            // The engine's own reason for the decision it already made, so "why is it offering me
            // this" and "why did it not do it itself" have the same answer.
            guard let reason = table.stageDecision?.reason else { return base }
            return base + " " + reason + "."
        case .neither:
            return table.spec.fmt == .merge
                ? "A merged view — export it if you want a saved copy."
                : "Already columnar with per-file statistics, so staging would not make it faster."
        }
    }

    /// The sniffer's own FROM clause, one argument per line. The web broke on `", "` for exactly
    /// this reason: a `read_csv` call with a dozen arguments is one unreadable line otherwise.
    nonisolated static func dialectText(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: ", ", with: ",\n  ")
    }
}

/// A byte count a person can read: `0 B`, `1023 B`, `1.0 KB`, `1.5 MB`, `1.0 TB`.
///
/// 🔴 **Hand-rolled, and not `ByteCountFormatter`.** That class follows `Locale.current` for the
/// decimal separator and — worse — switches between the SI and binary conventions by region and by
/// `countStyle`, so the same 1,572,864-byte file reads `1.5 MB` here and `1.65 MB` on a machine set
/// up slightly differently. A file size that changes with the user's region is the same class of
/// defect as the four locale bugs already shipped on this branch.
///
/// Lives in `SiftUI`, not `SiftCore`, by the directional rule at the top of this file: this is
/// phrasing, and the `sift` CLI prints no byte sizes. 🔴 If it ever does, that is the moment to move
/// this down — sharing it speculatively before then is how `SiftCore` acquires an English-language
/// layer nobody asked for.
public func humanBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(n)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    // Bytes get no decimal (`1023 B`, not `1023.0 B`); every larger unit gets exactly one. No
    // grouping, matching the web's `human` — `1023 B` is the largest number this can ever print
    // without a unit behind it, so there is nothing to group.
    return String(format: unit == 0 ? "%.0f" : "%.1f", value) + " " + units[unit]
}
