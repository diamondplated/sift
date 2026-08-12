import AppKit
import Foundation

// Row-accurate keyboard navigation, as arithmetic.
//
// This file exists because of where the rest of it has to live. `SiftApp` holds `@main`, the menu
// bar and the key monitor, and a SwiftPM test target cannot import an `executableTarget` — so every
// line put there is permanently untestable. What the keyboard actually *decides* is a handful of
// small integer questions: which key means what, the row a jump lands on, and where it clamps.
// Those are here, where `SiftUITests` can reach them; `AppDelegate` is left holding the AppKit
// wiring and nothing else.
//
// Ported from `keyNav` / `jumpToRow` / `gotoRow` (`web/index.html:739-777`) and the ⌘1–⌘9 handler
// (`:1801-1806`).

/// The six jumps the grid understands.
public enum NavKey: Equatable, Sendable {
    case down
    case up
    case pageDown
    case pageUp
    case top
    case bottom
}

/// The largest first row the viewport can sit at — `maxFirst()` (`web/index.html:596`), which is
/// `Math.max(0, state.total - visibleRows())` with `visibleRows()` itself floored at 1.
///
/// The floor matters: a viewport reported as zero rows tall (a window mid-resize, a grid that has
/// not laid out yet) would otherwise make the last row of the table the last *first* row, and
/// `bottom` would scroll one screen past the data.
public func maxFirstRow(total: Int, rowsOnScreen: Int) -> Int {
    max(0, total - max(1, rowsOnScreen))
}

/// Where a key lands the viewport, or `nil` when it would not move it at all.
///
/// 🔴 `nil` is not "invalid" — it is "already there", and it is the caller's licence to skip the
/// scroll entirely. `jumpToRow` reads exactly this from `setFirstRow`'s `false`
/// (`web/index.html:705-710`): holding ↓ at the bottom of a 40 M-row file must not re-issue a
/// scroll, a bounds-changed notification and a block request per repeat.
public func rowTarget(for key: NavKey, firstRow: Int, rowsOnScreen: Int, total: Int) -> Int? {
    let last = maxFirstRow(total: total, rowsOnScreen: rowsOnScreen)
    // `Math.max(1, visibleRows() - 1)` — a page keeps one row of context, and on a one-row-tall
    // viewport still moves by one rather than standing still.
    let page = max(1, rowsOnScreen - 1)
    let raw: Int
    switch key {
    case .down: raw = firstRow + 1
    case .up: raw = firstRow - 1
    case .pageDown: raw = firstRow + page
    case .pageUp: raw = firstRow - page
    case .top: raw = 0
    case .bottom: raw = last
    }
    let clamped = min(max(0, raw), last)
    return clamped == firstRow ? nil : clamped
}

/// What the user typed into ⌘G's field, as a first row — or `nil` when it holds no digits at all.
///
/// Non-digits are stripped before parsing (`gotoRow`'s `replace(/[^0-9]/g, "")`), so the grouped
/// number the gutter and the toolbar show — `1,048,576` — can be pasted straight back in. Row
/// numbers are 1-based on screen and 0-based here, hence the `- 1`.
///
/// A number too large to be an `Int` is not a refusal: `parseInt` produced a float and `Math.min`
/// clamped it, so `999999999999999999999999` means "the end" and lands there.
public func gotoRowTarget(_ typed: String, rowsOnScreen: Int, total: Int) -> Int? {
    let digits = typed.filter(\.isASCIIDigitForGoto)
    guard !digits.isEmpty else { return nil }
    let requested = Int(digits) ?? Int.max
    return min(max(0, requested - 1), maxFirstRow(total: total, rowsOnScreen: rowsOnScreen))
}

extension Character {
    /// Not `isNumber` and not `isWholeNumber`: both are true of `٣`, `Ⅶ` and `½`, none of which
    /// `Int("…")` can parse — so a field containing one would strip to a non-empty string that then
    /// failed to become a number and silently jumped to the end of the table.
    fileprivate var isASCIIDigitForGoto: Bool { self >= "0" && self <= "9" }
}

/// Which jump a keystroke means, or `nil` to leave the event to AppKit.
///
/// Takes the character rather than the `NSEvent` so the mapping is testable — an `NSEvent` cannot
/// be constructed meaningfully in a unit test, and this is the half with the decisions in it.
///
/// Two spellings of top/bottom, both carried over: ⌘Home / ⌘End is what `keyNav` handled, and ⌘↑ /
/// ⌘↓ is what a Mac keyboard without a Home key actually has. Bare Home/End return `nil` on
/// purpose — AppKit's own `scrollToBeginningOfDocument:` already does the right thing with them,
/// and intercepting would replace correct behaviour with identical behaviour.
public func navKey(for character: Character, command: Bool) -> NavKey? {
    switch character {
    case .upArrow: return command ? .top : .up
    case .downArrow: return command ? .bottom : .down
    case .pageUp: return .pageUp
    case .pageDown: return .pageDown
    case .home: return command ? .top : nil
    case .end: return command ? .bottom : nil
    default: return nil
    }
}

/// Which open table ⌘1–⌘9 selects, as an index, or `nil` for anything else.
///
/// ⌘0 is deliberately not the tenth — `e.key >= "1" && e.key <= "9"` (`web/index.html:1802`). There
/// is no ⌘0 tab anywhere on the platform, and mapping it to a table would shadow the "actual size"
/// shortcut people expect it to be.
public func tableIndex(forCommandKey character: Character) -> Int? {
    guard character >= "1", character <= "9",
        let value = character.wholeNumberValue
    else { return nil }
    return value - 1
}

// AppKit's function-key constants, as the `Character`s `charactersIgnoringModifiers` actually
// delivers. Spelled from the named constants rather than as `\u{F700}` literals so the mapping
// above says what it means.
extension Character {
    fileprivate static let upArrow = functionKey(NSUpArrowFunctionKey)
    fileprivate static let downArrow = functionKey(NSDownArrowFunctionKey)
    fileprivate static let pageUp = functionKey(NSPageUpFunctionKey)
    fileprivate static let pageDown = functionKey(NSPageDownFunctionKey)
    fileprivate static let home = functionKey(NSHomeFunctionKey)
    fileprivate static let end = functionKey(NSEndFunctionKey)

    private static func functionKey(_ code: Int) -> Character {
        // Force-unwrapped, and safe by construction: every `NS*FunctionKey` is a constant in the
        // private-use plane (0xF700-0xF8FF), which contains no surrogates and no unassigned scalars.
        Character(UnicodeScalar(UInt32(code))!)
    }
}
