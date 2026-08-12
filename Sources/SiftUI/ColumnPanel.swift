import AppKit
import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

// The Column tab: what this one column contains, and the clicks that turn any of it into a filter.
// Ported from `renderColumn`/`loadColumn` (`web/index.html:1145-1291`).

/// One column's stats, its value list, and the three clicks on a value row.
public struct ColumnPanel: View {
    private let session: Session
    private let model: TableViewModel
    private let column: String

    /// The lens the user picked, or `nil` while the profile's own `view` is still in charge — the
    /// web's `state.colLens || p.view` (`web/index.html:1129`), which is why this is optional
    /// rather than seeded to `.topn`.
    @State private var lens: ColumnProfile.View?
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var fetched: ColumnProfile?
    @State private var panel: DistinctPanel?
    @State private var error: String?

    public init(session: Session, model: TableViewModel, column: String) {
        self.session = session
        self.model = model
        self.column = column
    }

    /// The profile this panel draws. `profileOf` is the authority once it lands, but the view
    /// model's copy is what makes the panel useful the instant it opens — and it is the ONLY copy
    /// on a file too big for the speculative kick's gate, where `profileOf` is doing a real
    /// `SUMMARIZE` and takes as long as it takes.
    private var profile: ColumnProfile? {
        fetched ?? model.profile.first { $0.name == column }
    }

    private var mode: ColumnProfile.View { lens ?? profile?.view ?? .topn }

    private var type: String { model.columns.first { $0.name == column }?.type ?? "" }

    public var body: some View {
        // No `ScrollView` here: the inspector pane owns the one scroller, because `ImageRenderer`
        // lays out no `ScrollView` and a panel that wraps its own cannot be checked visually at
        // all. See `InspectorView.body`.
        VStack(alignment: .leading, spacing: 8) {
            header
            lensPicker
            if let profile { StatsGrid(profile: profile, panel: panel) }
            if let error {
                // 🔴 Shown, never swallowed. Closing the tab while this panel loads makes the
                // engine throw the clean `No open table named 'x'.`; a `try?` here would turn that
                // into a panel that just sits there empty forever.
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 200 ms after the last keystroke, and not before — `blockTimer`
        // (`web/index.html:1286-1290`). `.task(id:)` cancels the pending sleep on the next
        // keystroke, which is the whole of the debounce.
        .task(id: search) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            debouncedSearch = search
        }
        .task(id: loadKey) { await load() }
    }

    // MARK: - loading

    /// What a reload depends on. The filters are in it as a string because `Filter` is `Equatable`
    /// but not `Hashable`, and they must be in it at all: `applySpec` ends by re-running
    /// `loadColumn` (`web/index.html:886`), and a spec changed anywhere else — the header's sort,
    /// the filter bar — has to reach this panel too.
    private var loadKey: String {
        "\(column)|\(lens?.rawValue ?? "")|\(debouncedSearch)|\(model.table.qspec.filters)"
    }

    /// `profileOf` and `distinct` are the UNGATED entry points, deliberately: a panel the user
    /// opened is not speculative work, and `profileIfCheap`'s cost gate belongs to the kick that
    /// nobody asked for.
    private func load() async {
        do {
            let profile = try await session.profileOf(model.name, col: column)
            fetched = profile
            panel = (lens ?? profile.view) == .topn
                ? try await session.distinct(
                    model.name, col: column, limit: 200, search: debouncedSearch)
                : nil
            error = nil
        } catch {
            self.error = error.localizedDescription
            panel = nil
        }
    }

    private func click(_ value: DistinctPanel.Value, _ modifier: DistinctClick) {
        let next = applyDistinctClick(
            col: column, value: filterValue(for: value.value), label: value.label,
            modifier: modifier, current: model.table.qspec.filters)
        Task {
            do { try await model.setFilters(next) } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: - pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(column).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text(type).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    private var lensPicker: some View {
        Picker("", selection: Binding(get: { mode }, set: { lens = $0 })) {
            Text("VALUES").tag(ColumnProfile.View.topn)
            Text("SPREAD").tag(ColumnProfile.View.hist)
            Text("IDENTITY").tag(ColumnProfile.View.highcard)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .font(.system(size: 10))
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .topn:
            TextField("search values…", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            if let panel {
                DistinctList(panel: panel, onClick: click)
            } else if error == nil {
                Text("loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .hist:
            SpreadLens(session: session, model: model, column: column, profile: profile)
        case .highcard:
            IdentityLens(session: session, model: model, column: column, profile: profile)
        }
    }
}

// MARK: - the stats grid

/// `web/index.html:1177-1193`, row for row: each line appears only when the profile carries it, so
/// a text column shows no mean and a clean column shows no "won't cast".
private struct StatsGrid: View {
    let profile: ColumnProfile
    let panel: DistinctPanel?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            row("rows", countText(profile.n))
            row("distinct", distinctText)
            row("null", countText(profile.nNull))
            row("empty ''", countText(profile.nEmpty))
            if profile.nNullish != 0 { row("null-like", countText(profile.nNullish)) }
            if profile.nUncastable != 0 {
                row("won't cast", countText(profile.nUncastable), colour: .red)
            }
            if let min = profile.minS { row("min", String(min.prefix(22))) }
            if let max = profile.maxS { row("max", String(max.prefix(22))) }
            if let avg = profile.avg { row("mean", meanText(avg)) }
            if let median = profile.q50 { row("median", String(median.prefix(22))) }
            if let maxLen = profile.maxLen { row("max length", countText(maxLen)) }
        }
        .font(.system(size: 10.5))
    }

    /// The PANEL's count when it has an exact one, because it is both exact and filter-aware; the
    /// profile only ever carries the HyperLogLog estimate (`web/index.html:1174-1176`).
    private var distinctText: String {
        if let exact = panel?.nDistinct, exact.exact { return countText(exact.value) }
        let value = profile.exactDistinct ?? profile.approxDistinct
        return (profile.exactDistinct == nil ? "≈ " : "") + countText(value)
    }

    private func row(_ name: String, _ value: String, colour: Color = .primary) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(colour)
                .gridColumnAlignment(.trailing)
        }
    }
}

/// `toLocaleString({ maximumFractionDigits: 3 })`: up to three decimals, trailing zeros dropped,
/// thousands grouped. Hand-rolled, because the formatter that does this follows `Locale.current`
/// and renders the same mean four ways.
func meanText(_ value: Double) -> String {
    var text = String(format: "%.3f", value)
    guard text.contains(".") else { return groupDigits(text) }
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return groupDigits(text)
}

// MARK: - the value list

/// The top-N rows, the footer, and the sentence that explains why a filtered column still shows
/// every value. Split out of `ColumnPanel` so a test can render it against a real `DistinctPanel`
/// — `ImageRenderer` never runs a `.task`, so the loaded state is unreachable from the outside.
struct DistinctList: View {
    let panel: DistinctPanel
    let onClick: (DistinctPanel.Value, DistinctClick) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(panel.values.enumerated()), id: \.offset) { _, value in
                row(value)
            }
            Text(footer)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text("""
                Click to filter · ⌘-click to add · right-click to exclude. This list ignores its \
                own column's filter, so everything stays visible.
                """)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        var text = "showing \(panel.shown) of "
            + (panel.nDistinct.exact ? "" : "≈ ") + countText(panel.nDistinct.value) + " values"
        if panel.otherN != 0 { text += " · \(countText(panel.otherN)) rows in the tail" }
        return text + " · " + String(format: "%.1f", panel.milliseconds) + " ms"
    }

    private func row(_ value: DistinctPanel.Value) -> some View {
        let sentinel = value.label == nullSentinelLabel || value.label == emptySentinelLabel
        return HStack(spacing: 6) {
            Text(value.label)
                .font(.system(size: sentinel ? 11 : 11.5, design: sentinel ? .monospaced : .default))
                .foregroundStyle(sentinel ? Color.orange : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(countText(value.n))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(percentText(value.frac))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Behind the label, proportional to the value's share — the web's `.fill` (`:1268`). The
        // `max(0, …)` also launders a NaN fraction into a zero-width bar rather than a layout the
        // console complains about.
        .background(alignment: .leading) {
            GeometryReader { geo in
                Color.accentColor.opacity(0.16)
                    .frame(width: max(0, geo.size.width * value.frac))
            }
        }
        .overlay {
            if value.selected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        // `NSEvent.modifierFlags` rather than a `TapGesture().modifiers(.command)`: SwiftUI treats
        // the modified gesture as a DIFFERENT gesture, so a plain tap and a ⌘-tap on the same row
        // fight over which one wins and the plain one swallows both. Reading the flags at the
        // moment of the tap is what the shell build did too.
        .onTapGesture {
            onClick(value, NSEvent.modifierFlags.contains(.command) ? .command : .plain)
        }
        // The one divergence from the web's `oncontextmenu`, which excluded on the click itself:
        // SwiftUI has no immediate right-click hook, and the only way to get one is an
        // `NSViewRepresentable` — which `ImageRenderer` refuses to draw, taking the whole panel's
        // visual check with it. A one-item menu costs a click and keeps the check.
        .contextMenu {
            Button("Exclude this value") { onClick(value, .exclude) }
        }
    }
}
