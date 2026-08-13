import AppKit
import Foundation
import SiftCore
import SiftEngine
import SwiftUI
import Testing
import TestSupport

@testable import SiftUI

// Light mode, which nothing on this branch had ever looked at.
//
// 🔴 **Every render check written before 2026-08-13 ran in whatever appearance the machine happened
// to be in, and this machine is in dark.** Two suites pinned `.aqua` (`FilterBarTests`,
// `HistogramRenderTests`); the other six did not, and not one of the eight ever compared the two
// appearances. Re-run pinned to `.aqua` and measured off the pixels, two surfaces were broken in
// light and fine in dark — which is the failure an unpinned suite is structurally incapable of
// seeing: it renders each surface once, in one appearance, and asks only whether it differs from
// itself. "These two renders differ" would have passed for both defects. The SQL console's buttons
// really did draw; they drew invisibly.
//
// **Where each assertion lives, and why.** Contrast is asserted as ARITHMETIC over resolved
// `NSColor`s, not as a measurement off a bitmap: `NSBitmapImageRep.colorAt` hands back the display's
// colour space (P3 here), so the same strip measures 4.70 through `usingColorSpace(.sRGB)` and 3.73
// through the rep's own — a difference big enough to move a 4.5 floor, and a difference that
// changes again on a runner with a different display profile. The renders are used for the claims a
// bitmap is actually good for: that the two appearances draw differently at all, and that the one
// surface which must NOT change between them does not.
//
// A fourth private copy of the render helper, matching the three that already exist here for the
// reason `FilterBarTests` gives — a test target cannot export to itself, and a shared render file is
// a file every render task then contends on.

// MARK: - helpers

/// Draw a view through AppKit in one specific appearance and hand back its pixels.
///
/// `cacheDisplay` on an `NSHostingView`, never `ImageRenderer` — measured unstable on this branch
/// (20 renders of identical content produced two distinct bitmaps) and, worse here, `ImageRenderer`
/// does not rasterize the AppKit-backed controls that are the entire subject of the console test.
///
/// 🔴 **No run-loop turn, and that is a deliberate reversal.** The first version of this file spun
/// `RunLoop.current` for 0.3 s per render so bordered buttons would draw their bezels as well as
/// their labels. MEASURED: it took the whole suite from 84 s to 322 s and made two unrelated
/// main-actor render tests flake, because every `@MainActor` test in the suite queues behind a
/// blocking run-loop turn. The label alone is enough — it is the half that changed colour — so the
/// pump is gone and the bezel is not part of any assertion here.
@MainActor
private func render(
    _ view: some View, _ appearance: NSAppearance.Name, _ width: CGFloat, _ height: CGFloat,
    _ tag: String
) throws -> NSBitmapImageRep {
    _ = NSApplication.shared   // AppKit wants an app object before any NSView exists, even headless
    let host = NSHostingView(
        rootView: ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            view
        }
        .frame(width: width, height: height, alignment: .topLeading))
    host.appearance = NSAppearance(named: appearance)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()

    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["SIFT_RENDER_DUMP"],
        let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag).png"))
    }
    return rep
}

/// Every pixel byte, walked by hand, row padding excluded — the same digest the other render suites
/// use and for the same two reasons: `Hasher.combine(someData)` hashes at most the first 80 bytes
/// (blank margin here), and `bytesPerRow` slack is never initialized.
private func digest(_ rep: NSBitmapImageRep) -> UInt64 {
    guard let data = rep.bitmapData else { return 0 }
    let perRow = rep.pixelsWide * rep.samplesPerPixel
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for y in 0..<rep.pixelsHigh {
        let row = data + y * rep.bytesPerRow
        for i in 0..<perRow { hash = (hash ^ UInt64(row[i])) &* 0x0100_0000_01b3 }
    }
    return hash
}

/// WCAG relative luminance, in sRGB.
private func luminance(_ colour: NSColor) -> Double {
    guard let rgb = colour.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
        + 0.0722 * channel(rgb.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// `top` at `alpha` over `bottom`, in sRGB — what the eye sees where a 14 % wash sits on the pane.
private func composite(_ top: NSColor, _ alpha: Double, over bottom: NSColor) -> NSColor {
    guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return top }
    func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * CGFloat(alpha) + y * (1 - CGFloat(alpha)) }
    return NSColor(
        srgbRed: mix(t.redComponent, b.redComponent),
        green: mix(t.greenComponent, b.greenComponent),
        blue: mix(t.blueComponent, b.blueComponent), alpha: 1)
}

/// Resolve dynamic colours as one specific appearance would.
@MainActor
private func asAppearance<T>(_ name: NSAppearance.Name, _ body: () -> T) -> T {
    var out: T!
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = body() }
    return out
}

// MARK: - the banner strip

/// 🔴 **MEASURED, and this is the defect.** With `BannerKind.ink` as the bare system hue, the warning
/// strip's own text read **2.09 : 1** against it in light appearance — against 5.68 in dark. The note
/// strip read 3.02 and the error strip 3.11, and the buttons in those rows were worse still
/// (2.09–2.39), because a bordered button darkens the ground under a label that did not change. WCAG
/// AA for body text is 4.5. The banner stack is this app's ENTIRE notification channel — there is no
/// SSE and no toast on this branch — and the worst of the three was the warning, the strip that
/// carries "this file is being copied" and "this sorted view does not reach the end of your data".
///
/// Both appearances are asserted and the floors differ ON PURPOSE. Light is held to AA, which is
/// what the fix delivers. Dark is held to what it already measured, because dark was never broken
/// and this change deliberately does not touch it — lifting dark to AA as well was tried, measured
/// (7.05 / 5.84 / 5.32) and REJECTED on looking at it: the hues went pastel and an error strip
/// stopped reading as urgent. One shared floor would either fail on untouched dark or quietly let
/// light slide back to 2.09.
@MainActor
@Test func theBannerInkIsReadableOnItsOwnStripInBothAppearances() {
    let floors: [(kind: BannerKind, name: String, light: Double, dark: Double)] = [
        (.warning, "warning", 4.5, 5.0), (.info, "note", 4.5, 4.0), (.error, "error", 4.5, 3.5),
    ]
    for row in floors {
        for (appearance, tag, floor) in [
            (NSAppearance.Name.aqua, "light", row.light), (.darkAqua, "dark", row.dark),
        ] {
            let measured = asAppearance(appearance) {
                // `BannerRow` draws `kind.tint.opacity(0.14)` on the pane and `kind.ink` on that.
                let strip = composite(row.kind.base, 0.14, over: .windowBackgroundColor)
                return contrast(strip, NSColor(row.kind.ink))
            }
            #expect(
                measured >= floor,
                "\(row.name) banner text measures \(measured) : 1 in \(tag), under \(floor)")
        }
    }
}

/// The mechanism, where a mutation can reach it: the hue is the system's in dark and a darkened one
/// in light. Without this, replacing the whole dynamic provider with `base` passes every ratio above
/// on dark and fails only on light — this states which half is supposed to have moved.
@MainActor
@Test func theBannerInkIsTheSystemHueInDarkAndADarkenedOneInLight() {
    for kind in [BannerKind.warning, .info, .error] {
        let inDark = asAppearance(.darkAqua) {
            (luminance(NSColor(kind.ink)), luminance(kind.base))
        }
        let inLight = asAppearance(.aqua) {
            (luminance(NSColor(kind.ink)), luminance(kind.base))
        }
        #expect(
            abs(inDark.0 - inDark.1) < 0.01,
            "dark appearance stopped drawing the plain system hue, which this change must not touch")
        #expect(
            inLight.0 < inLight.1,
            "light appearance is still drawing its text in the same hue as the wash beneath it")

        // The wash keeps the bright hue in both appearances — darkening THAT as well would turn a
        // light-mode warning strip into a brown band.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (tint, base) = asAppearance(appearance) {
                (luminance(NSColor(kind.tint)), luminance(kind.base))
            }
            #expect(abs(tint - base) < 0.01, "the strip's wash is no longer the system hue")
        }
    }
    // 🔴 Stated rather than tested: that `BannerRow` reads `tint` for the wash and `ink` for the
    // text is a fact about a `View`'s body, which nothing here can introspect. Swapping them back
    // to one colour is not killed by any assertion in this file — it is caught by looking, which is
    // how the defect was found in the first place.
}

/// …and the strip really does draw two different pictures in the two appearances. Arithmetic over
/// colours cannot see a view that ignores the appearance entirely; this can.
@MainActor
@Test func theBannerStripDrawsDifferentlyInLightAndDark() throws {
    let strip = VStack(spacing: 0) {
        BannerRow(.warning) { Text("Staging into native storage."); Spacer(); Button("Cancel") {} }
        BannerRow(.info) { Text("Folder read as one table."); Spacer(); Button("Re-open") {} }
        BannerRow(.error) { Text("Catalog Error: no such table."); Spacer(); Button("Dismiss") {} }
    }

    // THE CONTROL, first: the same content twice in the same appearance. Every comparison below is
    // "these differ", which means nothing unless the renderer reproduces itself.
    let light = try render(strip, .aqua, 520, 140, "banner-light")
    #expect(
        digest(light) == digest(try render(strip, .aqua, 520, 140, "banner-light-control")),
        "the renderer does not reproduce itself, so nothing below this line means anything")

    let dark = try render(strip, .darkAqua, 520, 140, "banner-dark")
    #expect(digest(dark) != digest(light), "the banner drew identically in both appearances")
}

// MARK: - the SQL console

/// 🔴 **MEASURED: 1.03 : 1 in light appearance.** The console paints a fixed dark surface in both —
/// deliberate, and what the web build does — but every control inside it was still resolving `.aqua`
/// in light appearance, so `Reset to filters` and `Run ⌘↵` drew a light-mode bezel and a near-black
/// label onto a near-black panel. Not faint: gone. The same two buttons measured 9.52 in dark.
///
/// 🔴 **The assertion is that the two appearances render THE SAME**, which is the opposite of the
/// banner's and is the correct claim for this one view: the console is a single surface with a
/// single set of colours, so an appearance-dependent pixel anywhere in it is by construction a
/// control that has not been told what it is sitting on. A "these two differ" test here would pass
/// for exactly the broken state — which is how the defect survived eight render suites.
@MainActor
@Test func theSQLConsoleIsOneDarkSurfaceInBothAppearances() async throws {
    let (_, model) = try await openedFixture(rows: 12)
    let console = SQLConsole(model: model) { _ in }

    let light = try render(console, .aqua, 520, 150, "console-light")
    #expect(
        digest(light) == digest(try render(console, .aqua, 520, 150, "console-light-control")),
        "the renderer does not reproduce itself, so the comparison below means nothing")

    let dark = try render(console, .darkAqua, 520, 150, "console-dark")
    // Something inside it resolving the ambient appearance instead of the surface it is painted on.
    #expect(digest(dark) == digest(light), "the console drew differently in the two appearances")
}
