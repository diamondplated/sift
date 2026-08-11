import AppKit

// Top-level code in main.swift, not @main: @main on an NSApplicationDelegate needs the
// deprecated @NSApplicationMain, and this form is explicit about activation policy — without
// setActivationPolicy(.regular) a binary run outside a bundle gets no menu bar and no Dock tile,
// which reads exactly like "the app didn't launch".
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
