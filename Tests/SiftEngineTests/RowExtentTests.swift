import Foundation
import Testing
import TestSupport
import SiftCore
@testable import SiftEngine

// What the grid sizes itself from. Two separate defects live here, both of them "the extent lies
// about the data":
//
//  1. `visibleRows` is nil until the background exact count lands, and `buildSource` leaves
//     `spec.rowCount` nil for any CSV over `exactCountMaxBytes` — so a grid sized from
//     `visibleRows` alone is EMPTY on open for exactly the large text files the product exists to
//     open instantly. `displayRows` is Python's `Table.summary()` fallback, which the port dropped.
//  2. A sort materializes at most `sortMaterializeMax` rows and pages past that come back empty,
//     while the count still reports the full total (spec §13a). `scrollableRows` caps it.
//
// Pure `Table` tests, no connection: `Table`, `SourceSpec`, `SourceKey`, `RowEstimate` and
// `QuerySpec` all have public initializers. The two at the bottom go through a real `Session`, so
// the synthetic numbers above are anchored to what `buildSource` really produces.

private func syntheticTable(
    rowCount: Int? = nil, estimate: Int? = nil, sorted: Bool = false
) -> Table {
    let spec = SourceSpec(
        key: SourceKey(path: "/tmp/big.csv", mtimeNs: 0, size: 0), fmt: .csv, readFn: "read_csv",
        columns: [Column(name: "id", type: "BIGINT")],
        rowEstimate: estimate.map { RowEstimate(rows: $0, confidence: .high, basis: "3x256KiB sample") }
    )
    let sort = sorted ? [QuerySpec.SortTerm(column: "id", direction: .asc)] : []
    var t = Table(name: "big", spec: spec, qspec: QuerySpec(relation: "big", sort: sort), openedAt: 1)
    t.rowCount = rowCount
    return t
}

@Test func aLargeCSVSizesItsGridFromTheEstimateBeforeTheExactCountLands() {
    let t = syntheticTable(rowCount: nil, estimate: 2_400_000)
    #expect(t.displayRows == 2_400_000)
    #expect(t.rowsAreExact == false)
    #expect(t.rowsBasis == .estimated("3x256KiB sample"))
    #expect(t.scrollableRows == 2_400_000)
}

@Test func aFileWithNeitherACountNorAnEstimateReportsNothingRatherThanZero() {
    let t = syntheticTable(rowCount: nil, estimate: nil)
    #expect(t.displayRows == nil)
    #expect(t.rowsBasis == .pending)
}

@Test func theExactCountWinsOverTheEstimateOnceItLands() {
    let t = syntheticTable(rowCount: 2_412_338, estimate: 2_400_000)
    #expect(t.displayRows == 2_412_338)
    #expect(t.rowsAreExact)
    #expect(t.rowsBasis == .counted)
}

@Test func anUnsortedTableScrollsThroughEveryRow() {
    let t = syntheticTable(rowCount: 100_000_000)
    #expect(t.scrollableRows == 100_000_000)
    #expect(t.sortTruncated == false)
}

@Test func aSortedTableCannotScrollPastWhatSortedRelationMaterializes() {
    let t = syntheticTable(rowCount: 100_000_000, sorted: true)
    #expect(t.scrollableRows == sortMaterializeMax)
    #expect(t.sortTruncated)
}

@Test func aSortedTableIsCappedOnItsEstimateToo() {
    let t = syntheticTable(rowCount: nil, estimate: 100_000_000, sorted: true)
    #expect(t.scrollableRows == sortMaterializeMax)
    #expect(t.sortTruncated)
}

@Test func aSortedTableUnderTheCapIsNotTruncated() {
    let t = syntheticTable(rowCount: 1_000, sorted: true)
    #expect(t.scrollableRows == 1_000)
    #expect(t.sortTruncated == false)
}

// MARK: - against a real session

/// The cap must be inert on every table anyone actually opens. A synthetic 100M-row `Table` proves
/// the branch; this proves the branch is not in the way of the ordinary case — a real sorted table
/// reaches its last row.
@Test func anOrdinarySortedTableCanStillScrollToItsLastRow() async throws {
    let session = try Session(home: TestTemp.path("rowextent-home"))
    let path = try makeCSV(dir: TestTemp.dir("rowextent"), name: "sorted.csv", rows: 1_000)
    let opened = try await session.openPath(path)
    _ = try await session.setSpec(
        opened.name, filters: [], sort: [QuerySpec.SortTerm(column: "amount", direction: .desc)]
    )

    let t = try await session.table(opened.name)
    #expect(t.displayRows == 1_000)
    #expect(t.scrollableRows == t.displayRows)
    #expect(t.sortTruncated == false)

    // …and the last row the extent promises really comes back.
    let last = try await session.page(opened.name, offset: 999, limit: 1)
    #expect(last.rows.count == 1)
}

/// The premise of the whole `displayRows` fallback, on a real file rather than a hand-built spec:
/// a CSV over `exactCountMaxBytes` opens with NO exact count, and only the estimate stands between
/// the user and an empty grid.
@Test func aCSVOverTheExactCountThresholdOpensWithAnEstimateAndNoCount() async throws {
    let dir = TestTemp.dir("rowextent-big")
    let path = URL(fileURLWithPath: dir).appendingPathComponent("big.csv").path
    // ~73 MB, past the 64 MB `exactCountMaxBytes`. Wide rows rather than many of them, and one
    // block repeated rather than 330,000 interpolations: the threshold is in BYTES, so the cheapest
    // way over it is a fat padding column — which also keeps the background exact count this open
    // kicks off from scanning millions of rows behind the rest of the suite.
    let pad = String(repeating: "x", count: 200)
    var block = ""
    for i in 0..<10_000 { block += "\(i),region \(i % 7),\(i).50,\(pad)\n" }
    var out = "order_id,region,amount,note\n"
    for _ in 0..<33 { out += block }
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    let bytes = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
    #expect(bytes > exactCountMaxBytes, "the fixture must be over the threshold; got \(bytes) B")

    let session = try Session(home: TestTemp.path("rowextent-big-home"))
    let opened = try await session.openPath(path)

    #expect(opened.spec.rowCount == nil, "too big to count at open — this is what 5a exists for")
    let estimate = try #require(opened.spec.rowEstimate)
    #expect(opened.rowCount == nil)
    #expect(opened.visibleRows == nil, "the old extent source: nil, i.e. an empty grid on open")
    #expect(opened.displayRows == estimate.rows, "…and the fallback is what fills it")
    #expect(opened.rowsAreExact == false)
    #expect(opened.rowsBasis == .estimated(estimate.basis))
    // The estimator is a byte sample, not a promise — but it must be in the right postcode.
    #expect(estimate.rows > 230_000 && estimate.rows < 430_000,
            "330,000 real rows; got \(estimate.rows)")
}
