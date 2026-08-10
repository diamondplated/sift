import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// The shared presentation layer — the rules the `sift` grid and the SwiftUI grid both render
// through. Ported from `web/index.html`'s `cellHTML`/`groupDigits`, so these tests are the contract
// that keeps the two consumers from drifting apart again; they had already disagreed once, on
// `1250.50` and on whether a NULL looks like an empty string.
//
// The numbers below are the shipping web renderer's own answers, not this port's preferences.

// MARK: - the three states (design spec §9)

@Test func nullAnEmptyStringAndTheLiteralNASlashAAllRenderDifferently() {
    // The whole product, in one assertion: these are three different facts about a cell and a user
    // must be able to tell them apart, because they filter differently and they mean different
    // things in real data.
    let rendered = [Cell.null, .text(""), .text("N/A"), .text("null")]
        .map { glyph(for: $0, kind: .text) }
    #expect(rendered == ["null", "''", "N/A", "null"])
    #expect(Set(rendered.prefix(3)).count == 3)

    // ...and in a numeric column too, where a missing value is the common case.
    #expect(glyph(for: .null, kind: .number) == "null")
    #expect(glyph(for: .text(""), kind: .number) == "''")
}

// MARK: - doubles

@Test func aWholeDoubleLosesItsPointZeroAndAFractionalOneKeepsSixDigitsAtMost() {
    #expect(doubleGlyph(1.0) == "1")
    #expect(doubleGlyph(980.00) == "980")
    #expect(doubleGlyph(1250.50) == "1,250.5")
    #expect(doubleGlyph(1.0 / 3.0) == "0.333333")
    #expect(doubleGlyph(-1234.5) == "-1,234.5")
    #expect(doubleGlyph(0.5) == "0.5")
    // Rounds at the sixth digit rather than truncating, matching `maximumFractionDigits: 6`.
    #expect(doubleGlyph(0.9999999) == "1")
    #expect(doubleGlyph(2.0 / 3.0) == "0.666667")
}

@Test func aHugeDoubleIsGroupedRatherThanPrintedInExponentNotation() {
    // `String(describing: 1e16)` is "1e+16", which is what the CLI used to print and what the web
    // never does — `Number.isInteger(1e16)` is true, so it groups.
    #expect(doubleGlyph(1e16) == "10,000,000,000,000,000")
    #expect(doubleGlyph(-1e16) == "-10,000,000,000,000,000")
    #expect(!doubleGlyph(1e16).contains("e"))
}

@Test func nonFiniteDoublesArePrintedAsThemselvesRatherThanInvented() {
    #expect(doubleGlyph(Double.nan) == "nan")
    #expect(doubleGlyph(Double.infinity) == "inf")
    #expect(doubleGlyph(-Double.infinity) == "-inf")
    // A negative zero is a distraction, not information.
    #expect(doubleGlyph(-0.0) == "0")
}

@Test func doublesGoThroughTheSharedRuleWhenTheyArriveAsCells() {
    #expect(glyph(for: .double(1250.50), kind: .number) == "1,250.5")
    #expect(glyph(for: .double(980.00), kind: .number) == "980")
}

// MARK: - exact digits

@Test func groupDigitsInsertsSeparatorsWithoutEverParsingTheNumber() {
    #expect(groupDigits("1234567") == "1,234,567")
    #expect(groupDigits("999") == "999")
    #expect(groupDigits("1000") == "1,000")
    #expect(groupDigits("-1234567.25") == "-1,234,567.25")
    // 2^53 + 1: exactly the value a Double cannot hold, and exactly the sort of thing an order-id
    // column contains. It has to survive the comma untouched.
    #expect(groupDigits("9007199254740993") == "9,007,199,254,740,993")
    // Anything that is not a plain digit run passes through rather than being mangled.
    #expect(groupDigits("inf") == "inf")
    #expect(groupDigits("1e+16") == "1e+16")
    #expect(groupDigits("") == "")
}

@Test func exactIntegersAndDecimalsKeepEveryDigitAndTheirDeclaredScale() {
    #expect(glyph(for: .int(9_007_199_254_740_993), kind: .number) == "9,007,199,254,740,993")
    #expect(glyph(for: .int(-42), kind: .number) == "-42")
    // DECIMAL(12,2): the trailing zero is declared, so it stays — and grouping only touches the
    // integer part.
    #expect(glyph(for: .decimal(Decimal(string: "1250.5")!, scale: 2), kind: .number) == "1,250.50")
    #expect(glyph(for: .decimal(Decimal(string: "3")!, scale: 2), kind: .number) == "3.00")
}

@Test func aHugeIntArrivingAsTextIsGroupedAsDigitsNotReformattedAsANumber() {
    // HUGEINT crosses as text because there is no Int128 on the pinned toolchain.
    let hugeint = "170141183460469231731687303715884105727"
    let rendered = glyph(for: .text(hugeint), kind: .number)
    #expect(rendered == "170,141,183,460,469,231,731,687,303,715,884,105,727")
    #expect(rendered.filter(\.isNumber) == hugeint)
    // Text in a numeric column that is not a plain number is left exactly as it is.
    #expect(glyph(for: .text("1.2e5"), kind: .number) == "1.2e5")
    #expect(glyph(for: .text("N/A"), kind: .number) == "N/A")
}

// MARK: - the other kinds

@Test func boolsRenderAsTrueOrFalseWhicheverShapeTheyArriveIn() {
    #expect(glyph(for: .bool(true), kind: .bool) == "true")
    #expect(glyph(for: .bool(false), kind: .bool) == "false")
    #expect(glyph(for: .text("true"), kind: .bool) == "true")
    #expect(glyph(for: .text("no"), kind: .bool) == "false")
    #expect(glyph(for: .null, kind: .bool) == "null")
}

@Test func timestampsDropTheirTSeparatorAndSubSecondNoise() {
    #expect(glyph(for: .text("2026-01-15T10:30:00.123456"), kind: .temporal) == "2026-01-15 10:30:00")
    #expect(glyph(for: .text("2026-01-15T10:30:00"), kind: .temporal) == "2026-01-15 10:30:00")
    #expect(glyph(for: .text("2026-01-15"), kind: .temporal) == "2026-01-15")
    // A second "T" is part of the value, not a second separator to swallow.
    #expect(glyph(for: .text("2026-01-15T10:30:00 TZT"), kind: .temporal) == "2026-01-15 10:30:00 TZT")
    // A trailing dot with no digits is not sub-second precision.
    #expect(glyph(for: .text("10:30:00."), kind: .temporal) == "10:30:00.")
}

@Test func textNestedAndBlobKeepTheEnginesOwnRendering() {
    #expect(glyph(for: .text("first, with comma"), kind: .text) == "first, with comma")
    #expect(glyph(for: .list([.text("a"), .null]), kind: .nested) == "[a, NULL]")
    #expect(glyph(for: .blob(1234), kind: .blob) == "<blob 1,234 B>")
}

// MARK: - the renderer really uses it

@Test func theGridRendersThroughTheSharedRulesNotThroughCellDisplay() {
    let columns = [
        TablePage.ColumnInfo(name: "amount", type: "DOUBLE", kind: .number),
        TablePage.ColumnInfo(name: "note", type: "VARCHAR", kind: .text),
    ]
    let lines = renderGrid(
        columns: columns,
        rows: [
            [.double(1250.50), .null],
            [.double(980.00), .text("")],
            [.null, .text("N/A")],
        ],
        width: 100
    )
    // `Cell.display` would give "1250.5"/"980.0" and blank for both of the first two notes.
    #expect(lines[1].contains("1,250.5"))
    #expect(lines[2].contains("980"))
    #expect(!lines[2].contains("980.0"))
    #expect(lines[1].hasSuffix("null"))
    #expect(lines[2].hasSuffix("''"))
    #expect(lines[3].contains("null") && lines[3].hasSuffix("N/A"))
}
