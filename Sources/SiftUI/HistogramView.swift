import DuckDBKit
import SiftCore
import SiftEngine
import SwiftUI

// The two column lenses that are not a ranked list: a numeric/temporal histogram, and the
// high-cardinality panel a ranked list would be useless for. Ported from `web/index.html:1198-1233`.
//
// Every number on this page is arithmetic done ONCE, in a static function with a test on it, and
// the `body` below only positions rectangles. That split is deliberate: a body cannot be tested,
// and the two defects this kind of view actually ships — a bucket drawn at the wrong index, and a
// bar that computes correctly and draws invisibly — live on opposite sides of it. The first is
// caught by `HistogramView.bars`'s tests, the second only by rendering pixels
// (HistogramRenderTests).
//
// 🔴 No `NumberFormatter` and no `ByteCountFormatter`, here or anywhere a user sees a number: counts
// group through `SiftCore.groupDigits`, percentages through `String(format:)` with no locale (see
// SiftCore/Stage.swift's `grouped`). Four locale bugs of that shape have shipped on this branch.

/// A numeric or temporal column's distribution — the `hist` lens.
public struct HistogramView: View {
    private let panel: HistogramPanel
    private let profile: ColumnProfile?

    /// `profile` supplies the axis ends (the web read `p.min`/`p.max` off the same profile). It is
    /// optional because the panel can name them itself: the first and last non-empty bucket carry
    /// the real extremes as `Cell`s. Absent both, the axis simply has no labels rather than
    /// inventing ones.
    public init(panel: HistogramPanel, profile: ColumnProfile? = nil) {
        self.panel = panel
        self.profile = profile
    }

    public var body: some View {
        if panel.degenerate {
            Text(Self.degenerateText(panel))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let axis = Self.axis(panel, profile: profile)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 1) {
                    if let nulls = Self.nullBar(panel) {
                        // 9 pt and set apart by its own gap, exactly like `.hist i.nul` — a null
                        // count is not a bucket and must not read as the first one.
                        bar(nulls, color: Self.nullColor)
                            .frame(width: 9)
                            .padding(.trailing, 5)
                    }
                    ForEach(Array(Self.bars(panel).enumerated()), id: \.offset) { slot in
                        bar(slot.element, color: Self.barColor)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.plotHeight)
                HStack(spacing: 8) {
                    // 🔴 `.fixedSize()` on each LABEL, not on the HStack. Cutting the axis at the
                    // web's 18 characters silently removes the seconds from `2026-08-09 14:03:01` —
                    // a number that is WRONG on screen, in a product whose premise is not lying
                    // about data — so each end is laid out at its intrinsic width and never elides.
                    // On the stack it would collapse the `Spacer` too, and both ends would draw
                    // jammed together on the left (MEASURED: they did).
                    Text(axis.min).fixedSize()
                    Spacer(minLength: 4)
                    Text(axis.max).fixedSize()
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                Text(Self.caption(panel))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bar(_ slot: Bar, color: Color) -> some View {
        // Bottom-aligned inside a full-height cell: an `HStack(alignment: .bottom)` of differently
        // sized rectangles would otherwise centre them, and the bars would float.
        Color.clear.overlay(alignment: .bottom) {
            Rectangle()
                .fill(color)
                .frame(height: max(1, slot.fraction * Self.plotHeight))
                .help(slot.tooltip)
        }
    }

    // MARK: - the arithmetic

    /// One drawn bar: how tall, and what it says on hover.
    struct Bar: Equatable {
        /// 0…1 of the plot height. A bucket with rows in it never falls below 2 %, so a single row
        /// among a million is still visible — `Math.max(n ? 2 : 0, …)` in the web.
        let fraction: Double
        let tooltip: String
    }

    nonisolated static let plotHeight: CGFloat = 96
    static var barColor: Color { Color.accentColor.opacity(0.75) }
    /// The web's `--stale` amber (`#b07d1e`). Fixed rather than semantic: this bar means "the rows
    /// that are NOT in any bucket", and it has to be the one colour on the plot that is not the
    /// bar colour, in both appearances.
    static var nullColor: Color { Color(red: 176 / 255, green: 125 / 255, blue: 30 / 255) }

    /// A bar per bin, in bin order.
    ///
    /// 🔴 Mapped by `Bucket.b` over `0..<bins`, never by array position. Empty buckets are simply
    /// ABSENT from the engine's result (`histogramSQL`'s `GROUP BY b` emits no row for them), so
    /// walking `panel.buckets` in order draws bucket 7 in slot 3 and shifts every bar after it —
    /// a plausible, entirely wrong distribution.
    nonisolated static func bars(_ panel: HistogramPanel) -> [Bar] {
        guard let bins = panel.bins, bins > 0 else { return [] }
        let byIndex = Dictionary(panel.buckets.map { ($0.b, $0) }, uniquingKeysWith: { first, _ in first })
        let tallest = peak(panel)
        return (0..<bins).map { i in
            guard let bucket = byIndex[i] else { return Bar(fraction: 0, tooltip: "0 rows") }
            let kind = panel.kind ?? .number
            return Bar(
                fraction: max(0.02, Double(bucket.n) / Double(tallest)),
                tooltip: "\(groupDigits(String(bucket.n))) rows\n"
                    + "\(SiftEngine.glyph(for: bucket.bMin, kind: kind))"
                    + " … \(SiftEngine.glyph(for: bucket.bMax, kind: kind))"
            )
        }
    }

    /// The amber bar in front of the buckets, or `nil` when nothing is null.
    ///
    /// Scaled against `max(tallest bucket, nNull)` rather than the buckets alone, so a column that
    /// is mostly null does not draw a bar twenty times the plot height.
    nonisolated static func nullBar(_ panel: HistogramPanel) -> Bar? {
        guard panel.nNull > 0 else { return nil }
        return Bar(
            fraction: max(0.02, Double(panel.nNull) / Double(max(peak(panel), panel.nNull))),
            tooltip: "\(groupDigits(String(panel.nNull))) null (excluded from the buckets)"
        )
    }

    /// The tallest bucket, floored at 1 so an all-empty panel cannot divide by zero.
    nonisolated private static func peak(_ panel: HistogramPanel) -> Int {
        max(1, panel.buckets.map(\.n).max() ?? 0)
    }

    /// The two ends of the axis: the profile's own min/max, falling back to the extremes the
    /// buckets carry.
    nonisolated static func axis(_ panel: HistogramPanel, profile: ColumnProfile?) -> (min: String, max: String) {
        let kind = panel.kind ?? .number
        let low = profile?.minS ?? panel.buckets.first.map { SiftEngine.glyph(for: $0.bMin, kind: kind) }
        let high = profile?.maxS ?? panel.buckets.last.map { SiftEngine.glyph(for: $0.bMax, kind: kind) }
        return (low ?? "", high ?? "")
    }

    nonisolated static func caption(_ panel: HistogramPanel) -> String {
        let bins = panel.bins ?? 0
        guard panel.nNull > 0 else { return "\(bins) buckets" }
        return "\(bins) buckets · \(groupDigits(String(panel.nNull))) null shown separately in amber"
    }

    /// What a column with nothing to plot says instead. The reason comes from the engine, which is
    /// the only thing that knows which of the two degenerate cases it hit.
    nonisolated static func degenerateText(_ panel: HistogramPanel) -> String {
        "No spread to plot — \(panel.reason ?? "")."
    }
}

// MARK: - what the Column tab mounts

/// The `SPREAD` lens: fetch the panel, then draw it.
///
/// A wrapper rather than a fetch inside `HistogramView` — the view stays pure and testable against a
/// hand-built panel, and `ColumnPanel` gains exactly one line per lens. It carries its own `.task`
/// rather than joining `ColumnPanel.load()` for the same reason: this is Task 9's seam into a file
/// Task 8 owns, and the smaller it is the less there is to collide over.
///
/// 🔴 No `ScrollView` here or below. The inspector pane owns the only one — see
/// `ColumnPanel.body`'s note — and a second, nested one breaks the layout.
public struct SpreadLens: View {
    private let session: Session
    private let model: TableViewModel
    private let column: String
    private let profile: ColumnProfile?
    @State private var panel: HistogramPanel?
    @State private var error: String?

    public init(session: Session, model: TableViewModel, column: String, profile: ColumnProfile?) {
        self.session = session
        self.model = model
        self.column = column
        self.profile = profile
    }

    public var body: some View {
        Group {
            if let error {
                // Shown, never swallowed: closing the tab mid-load throws the engine's clean
                // sentence, and a `try?` here would leave an empty panel sitting there forever.
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            } else if let panel {
                HistogramView(panel: panel, profile: profile)
            } else {
                Text("loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        // Keyed on the filters too: the histogram is faceted (`qspec.withoutColumn(col).filters`),
        // so a filter applied anywhere else changes this plot.
        .task(id: "\(model.name)|\(column)|\(model.table.qspec.filters)") {
            do {
                panel = try await session.histogram(model.name, col: column)
                error = nil
            } catch {
                self.error = error.localizedDescription
                panel = nil
            }
        }
    }
}

/// The `IDENTITY` lens: the string-length shape and a sample, fetched together.
public struct IdentityLens: View {
    private let session: Session
    private let model: TableViewModel
    private let column: String
    private let profile: ColumnProfile?
    @State private var lengths: [LengthBucket] = []
    @State private var sample: [Cell] = []
    @State private var error: String?

    public init(session: Session, model: TableViewModel, column: String, profile: ColumnProfile?) {
        self.session = session
        self.model = model
        self.column = column
        self.profile = profile
    }

    public var body: some View {
        Group {
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            } else if let profile {
                HighCardView(profile: profile, lengths: lengths, sample: sample)
            } else {
                Text("loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(model.name)|\(column)|\(model.table.qspec.filters)") {
            do {
                lengths = try await session.lengthHistogram(model.name, col: column)
                sample = try await session.sampleValues(model.name, col: column)
                error = nil
            } catch {
                self.error = error.localizedDescription
                lengths = []
                sample = []
            }
        }
    }
}

// MARK: - high cardinality

/// The lens for a column with so many distinct values that a ranked list says nothing: how many
/// distinct, the shape of their string lengths, and a handful of actual values.
public struct HighCardView: View {
    private let profile: ColumnProfile
    private let lengths: [LengthBucket]
    private let sample: [Cell]

    public init(profile: ColumnProfile, lengths: [LengthBucket], sample: [Cell]) {
        self.profile = profile
        self.lengths = lengths
        self.sample = sample
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.headline(profile))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !lengths.isEmpty {
                let tallest = max(1, lengths.map(\.n).max() ?? 0)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(lengths, id: \.len) { bucket in
                        Color.clear.overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(HistogramView.barColor)
                                .frame(
                                    height: max(
                                        1, Double(bucket.n) / Double(tallest) * Self.lengthPlotHeight))
                                .help(Self.lengthTooltip(bucket))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.lengthPlotHeight)
                HStack {
                    // Per label, not on the stack — see `HistogramView`'s axis for why.
                    Text("len \(lengths[0].len)").fixedSize()
                    Spacer(minLength: 4)
                    Text("len \(lengths[lengths.count - 1].len)").fixedSize()
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Text("Sample").font(.system(size: 11, weight: .semibold))
            ForEach(Array(sample.enumerated()), id: \.offset) { item in
                Text(Self.sampleLabel(item.element, kind: profile.kind))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    nonisolated static let lengthPlotHeight: CGFloat = 56

    /// The sentence that explains why there is no ranked list here.
    nonisolated static func headline(_ profile: ColumnProfile) -> String {
        let fraction = profile.n > 0 ? Double(profile.approxDistinct) / Double(profile.n) : 0
        return "\(groupDigits(String(profile.approxDistinct))) distinct of "
            + "\(groupDigits(String(profile.n))) rows (\(pct(fraction))) — this looks like an "
            + "identifier, so a ranked list would tell you nothing."
    }

    /// The web's `pct`: one decimal, two when the value is small enough that one would read `0.0%`.
    /// `String(format:)` with no locale, never `NumberFormatter` — see this file's header.
    nonisolated static func pct(_ fraction: Double) -> String {
        String(format: fraction < 0.01 && fraction > 0 ? "%.2f" : "%.1f", fraction * 100) + "%"
    }

    nonisolated static func lengthTooltip(_ bucket: LengthBucket) -> String {
        "length \(bucket.len): \(groupDigits(String(bucket.n))) rows"
    }

    /// A sampled value, or the null sentinel. Routed through `glyph(for:kind:)` — the `Cell` case,
    /// not `Cell.display`, which renders a null and an empty string identically (design spec §9).
    nonisolated static func sampleLabel(_ cell: Cell, kind: Kind) -> String {
        // Annotated, not inferred: `SiftEngine` exports a `glyph(for:kind:)` returning `String`
        // and this module exports one returning `CellGlyph`, so the type is what picks the
        // overload.
        let routed: CellGlyph = glyph(for: cell, kind: kind)
        switch routed {
        case .null: return "␀ NULL"
        case .empty: return SiftEngine.emptyStringGlyph
        case .text(let text), .number(let text): return text
        case .bool(let value): return value ? "true" : "false"
        }
    }
}
