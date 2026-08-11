import DuckDBKit
import Foundation
import SiftCore
import Testing

@testable import SiftUI

// Two kinds of test in this file, and the difference is deliberate.
//
// ROUTING tests exercise `SiftUI`'s own switch — the three-kinds-of-missing cases, the bool, and
// the tooltip. They belong here and nowhere else.
//
// PARITY-ORACLE tests (decimal, big integer, list, blob, timestamp, double) assert values the
// ENGINE produces, and `SiftEngineTests/CellDisplayTests.swift` asserts them too. That duplication
// is the point: two layers that were each individually "correct" shipped disagreeing on live data
// once already. These fail if `SiftUI` stops routing through the engine, and they fail if the
// engine's rules drift — this plan wants to hear about both.
//
// Deliberately NOT here: a `groupDigits` unit test. After the renderer moved into the engine that
// would be `SiftUITests` testing an engine function through no seam at all — a copy of the engine's
// own test in the wrong target.
//
// This file imports `SiftEngine` nowhere on purpose: its `glyph(for:kind:)` has this one's
// argument labels and a `String` return, and importing both makes every call below an overload
// puzzle for no gain.

@Test func theThreeKindsOfMissingStayThreeDifferentGlyphs() {
    #expect(glyph(for: .null, kind: .text) == .null)
    #expect(glyph(for: .text(""), kind: .text) == .empty)
    #expect(glyph(for: .text("N/A"), kind: .text) == .text("N/A"))
}

@Test func aDecimalKeepsItsDeclaredScale() {
    #expect(
        glyph(for: .decimal(Decimal(string: "10.50")!, scale: 2), kind: .number)
            == .number("10.50"))
}

@Test func bigIntegersGroupWithoutGoingThroughDouble() {
    #expect(
        glyph(for: .int(9_007_199_254_740_993), kind: .number)
            == .number("9,007,199,254,740,993"))
    #expect(
        glyph(for: .text("170141183460469231731687303715884105727"), kind: .number)
            == .number("170,141,183,460,469,231,731,687,303,715,884,105,727"))
}

@Test func aListRendersBracketedAndKeepsItsCardinality() {
    #expect(glyph(for: .list([.text("a"), .null]), kind: .nested) == .text("[a, NULL]"))
    #expect(glyph(for: .list([]), kind: .nested) == .text("[]"))
}

@Test func aBlobKeepsTheEngineSpelling() {
    #expect(glyph(for: .blob(1234), kind: .blob) == .text("<blob 1,234 B>"))
}

@Test func aTimestampLosesItsTAndSubsecondsTheWayTheWebGridDid() {
    #expect(
        glyph(for: .text("2026-08-09T14:03:01.250"), kind: .temporal)
            == .text("2026-08-09 14:03:01"))
}

@Test func aBoolIsACaseNotAString() {
    #expect(glyph(for: .bool(true), kind: .bool) == .bool(true))
}

// `Cell.display` for a DOUBLE is `String(v)` — Swift's shortest-round-trip form, and NOT what the
// web grid rendered. The engine's renderer handles it (integral → grouped integer, fractional →
// six fraction digits with trailing zeros dropped, large magnitude never in exponent form). This
// test is the SEAM check: it fails if `SiftUI` stops routing DOUBLE through the engine.
@Test func aDoubleRendersTheWayTheWebGridRenderedIt() {
    #expect(glyph(for: .double(1.0), kind: .number) == .number("1"))
    #expect(glyph(for: .double(1.0 / 3.0), kind: .number) == .number("0.333333"))
    #expect(glyph(for: .double(1e16), kind: .number) == .number("10,000,000,000,000,000"))
    #expect(glyph(for: .double(-1234.5), kind: .number) == .number("-1,234.5"))
    #expect(glyph(for: .double(.nan), kind: .number) == .number("nan"))
}

/// The tooltip says the missing states in words — the web's `title="empty string, not null"` on a
/// cell that would otherwise be blank. A cell holding the literal text `''` is the case that
/// actually needs it: same two characters on screen, and only the tooltip separates them.
///
/// The 300-character cap is the web's `.slice(0, 300)` — a 2 MB JSON blob in one cell must not
/// become a 2 MB tooltip. `.text("null")` tooltipping as `"null"`, identical to a real NULL, is the
/// web's behaviour too and is deliberately not "fixed" here.
@Test func theTooltipNamesTheStateAndCapsTheValue() {
    #expect(tooltip(for: .null) == "null")
    #expect(tooltip(for: .text("")) == "empty string")
    #expect(tooltip(for: .text("''")) == "''")
    #expect(tooltip(for: .text("N/A")) == "N/A")

    let long = String(repeating: "x", count: 400)
    #expect(tooltip(for: .text(long)).count == 300)
}
