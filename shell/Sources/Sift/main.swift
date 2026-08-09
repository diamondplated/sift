import AppKit

// Hand-rolled entry point rather than @main: an executable SwiftPM target has no Info.plist at
// build time, so the activation policy has to be set explicitly for the app to get a Dock icon and
// a menu bar. build-app.sh supplies the real Info.plist when it assembles the bundle.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
