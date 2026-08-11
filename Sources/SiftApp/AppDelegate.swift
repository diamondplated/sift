import AppKit
import SiftEngine
import SiftUI
import SwiftUI

// Thin by construction. A SwiftPM test target cannot import an `executableTarget`, so nothing with
// a decision in it may live here: this file owns the window, the menu bar and the open panel, and
// every piece of state and every transformation lives in `SiftUI` where `SiftUITests` can reach
// it. If something here starts wanting a test, it is in the wrong target.
//
// Full menus, the toolbar, `application(_:open:)` and the LaunchServices plumbing are Task 13.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state: AppState
        do {
            // Exactly one `Session` for the whole process. Task 2 makes that structural.
            state = AppState(session: try Session())
        } catch {
            presentFatal(error)
            return
        }
        self.state = state
        state.startPolling()

        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 940),
            // 🔴 No `.fullSizeContentView` yet. With a toolbar present the toolbar occupies the
            // title-bar area and provides the drag region, so it is safe; WITHOUT one the content
            // view covers the title bar, swallows every mouse event, and the window cannot be
            // moved at all. Task 13 adds the toolbar and `.fullSizeContentView` together.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sift"
        window.minSize = NSSize(width: 760, height: 520)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("SiftMainWindow")
        window.contentView = NSHostingView(
            rootView: RootView(state: state, onOpen: { [weak self] in self?.showOpenPanel() })
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // `dropPrivateStore()`, not `shutdown()`: `shutdown()` is actor-isolated, so calling it
        // needs an `await`, and a `Task {}` spawned at terminate is not guaranteed to run before
        // the process exits. `dropPrivateStore()` is `nonisolated`, is exactly the cleanup that
        // matters here (removing a per-PID fallback store), and is safe to call redundantly.
        state?.session.dropPrivateStore()
    }

    // MARK: - menu

    private func buildMenu() {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let open = NSMenuItem(
            title: "Open…", action: #selector(showOpenPanel), keyEquivalent: "o")
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Sift", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        appItem.submenu = appMenu

        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func showOpenPanel() {
        guard let state else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // A folder of parquet/CSV and a Delta table are both directories the engine opens as one
        // table, so the panel has to allow picking one.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a data file or folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.open(path: url.path) }
    }

    // MARK: - failure to start

    /// The engine failing to open its store is the one error there is no window to show. Written
    /// fresh here rather than reused from `shell/**`, which is untouchable until Plan 5.
    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Sift could not start its engine"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
