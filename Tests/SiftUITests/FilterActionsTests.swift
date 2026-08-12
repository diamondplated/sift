import DuckDBKit
import Foundation
import SiftCore
import Testing
@testable import SiftUI

// `applyDistinctClick` is the only place in the app where a click becomes a filter, and it is pure,
// so this is where the inspector's behaviour is actually pinned down. Nothing here needs a session,
// a view or a file.

private let west = SQLValue.text("West")
private let east = SQLValue.text("East")
private let amount = Filter(col: "amount", op: .gt, values: [.int(10)])

private func inRegion(_ values: [SQLValue]) -> Filter {
    Filter(col: "region", op: .inList, values: values)
}

@Test func aPlainClickFiltersToJustThatValueAndReplacesTheColumnsPreviousList() {
    let first = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .plain, current: [])
    #expect(first == [inRegion([west])])

    // The replacement half: clicking a second value is not an addition.
    let second = applyDistinctClick(
        col: "region", value: east, label: "East", modifier: .plain, current: first)
    #expect(second == [inRegion([east])])
}

@Test func aClickLeavesEveryOtherColumnsFiltersExactlyWhereTheyWere() {
    for modifier in [DistinctClick.plain, .command, .exclude] {
        let out = applyDistinctClick(
            col: "region", value: west, label: "West", modifier: modifier, current: [amount])
        #expect(out.first == amount, "\(modifier) moved or dropped another column's filter")
        #expect(out.count == 2)
    }
    // …and the same holds for the sentinels, which take a different branch entirely.
    let nulled = applyDistinctClick(
        col: "region", value: .null, label: "␀ NULL", modifier: .plain, current: [amount])
    #expect(nulled == [amount, Filter(col: "region", op: .isNull)])
}

@Test func aClickReplacesOnlyTheSameOpAndLeavesTheColumnsOtherFiltersAlone() {
    // `addFilter` drops filters matching on BOTH col and op (`web/index.html:890`), so an exclusion
    // already on this column survives a plain click on it.
    let excluded = Filter(col: "region", op: .notIn, values: [east])
    let out = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .plain, current: [excluded])
    #expect(out == [excluded, inRegion([west])])
}

@Test func commandClickTogglesMembershipOfTheColumnsInList() {
    let one = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .plain, current: [])
    let two = applyDistinctClick(
        col: "region", value: east, label: "East", modifier: .command, current: one)
    #expect(two == [inRegion([west, east])], "⌘-click adds rather than replacing")

    let back = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .command, current: two)
    #expect(back == [inRegion([east])], "⌘-clicking a selected value removes it")
}

@Test func removingTheLastCommandClickedValueDropsEveryFilterOnThatColumn() {
    // Not just the `in`: `web/index.html:1279-1280` drops the whole column
    // (`filters.filter(f => f.col !== col)`). An empty `in` left behind is invisible in the
    // generated SQL — `whereClause` skips a value-taking op with no values — while still sitting in
    // the spec, and a surviving `is_null` would leave the user looking at rows they just cleared.
    let current = [amount, Filter(col: "region", op: .isNull), inRegion([west])]
    let out = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .command, current: current)
    #expect(out == [amount])
}

@Test func aRightClickExcludesTheValueRatherThanSelectingIt() {
    let out = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .exclude, current: [])
    #expect(out == [Filter(col: "region", op: .notIn, values: [west])])
}

@Test func theTwoSentinelsAreDetectedByLabelAndBecomeNullaryOps() {
    // Detected by LABEL, exactly as the web does (`:1271-1272`) — the labels are the engine's, from
    // `topNSQL`'s CASE. A one-element `IN (NULL)` matches nothing at all, which is the bug the
    // nullary op exists to avoid.
    let nulls = applyDistinctClick(
        col: "region", value: .null, label: "␀ NULL", modifier: .plain, current: [])
    #expect(nulls == [Filter(col: "region", op: .isNull)])

    let empties = applyDistinctClick(
        col: "region", value: .text(""), label: "␀ EMPTY", modifier: .plain, current: [])
    #expect(empties == [Filter(col: "region", op: .isEmpty)])

    // A value whose label is an ordinary string is NOT a sentinel, even when the value itself is
    // null-shaped — the dispatch is on the label, so this must stay an `in`.
    let ordinary = applyDistinctClick(
        col: "region", value: .text(""), label: "", modifier: .plain, current: [])
    #expect(ordinary == [inRegion([.text("")])])

    // ⌘-click takes the sentinel branch too: the sentinel check sits above the modifier check in
    // the web handler, so a sentinel is never a member of an `in` list.
    let commanded = applyDistinctClick(
        col: "region", value: .null, label: "␀ NULL", modifier: .command,
        current: [inRegion([west])])
    #expect(commanded == [inRegion([west]), Filter(col: "region", op: .isNull)])

    // Right-click does NOT: excluding through the value is what makes `whereClause` emit
    // `IS NOT NULL`, which is what "exclude the nulls" means.
    let excluded = applyDistinctClick(
        col: "region", value: .null, label: "␀ NULL", modifier: .exclude, current: [])
    #expect(excluded == [Filter(col: "region", op: .notIn, values: [.null])])
}

@Test func clickingTheSameValueTwiceReplacesRatherThanAccumulating() {
    let once = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .plain, current: [])
    let twice = applyDistinctClick(
        col: "region", value: west, label: "West", modifier: .plain, current: once)
    #expect(twice == once)
}

@Test func everyCellCaseBecomesTheFilterValueThatBindsBackToIt() {
    #expect(filterValue(for: .null) == .null)
    #expect(filterValue(for: .bool(true)) == .bool(true))
    #expect(filterValue(for: .int(7)) == .int(7))
    #expect(filterValue(for: .double(1.5)) == .double(1.5))
    #expect(filterValue(for: .text("West")) == .text("West"))
    // An empty string must survive as an empty string and not collapse into a null — `''` and NULL
    // being different things is the product's premise, and this is the conversion that could lose
    // it. `.decimal` has no `SQLValue` spelling and falls back to its exact digits, scale included.
    #expect(filterValue(for: .text("")) == .text(""))
    #expect(filterValue(for: .decimal(Decimal(string: "10.5")!, scale: 2)) == .text("10.50"))
}
