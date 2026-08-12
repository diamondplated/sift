import AppKit
import SiftCore
import SiftEngine
import SiftUI
import SwiftUI

// Thin by construction. A SwiftPM test target cannot import an `executableTarget`, so nothing with
// a decision in it may live here: this file owns the window, the menu bar, the title-bar controls,
// the open panel and the LaunchServices plumbing, and every piece of state and every transformation
// lives in `SiftUI` where `SiftUITests` can reach it. Every menu action below is one call into
// `AppState`, and every keystroke is one call into `KeyNav`. If something here starts wanting a
// test, it is in the wrong target.
//
// AppKit owns `@main` rather than SwiftUI's `App`, deliberately (design spec §9): the recent-
// documents menu, the proxy icon, the title-bar controls and `application(_:open:)` all survive
// from the shipping shell, and none of them has a SwiftUI spelling that keeps its behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var window: NSWindow?

    /// The live row count — the shell's `rowLabel`, with a click recognizer on it.
    ///
    /// The "N dropped" half of the phrase is the way into the bad-rows sheet: in the shell the web
    /// topbar is hidden (`body.native`), so that count was drawn with nothing to click and the
    /// panel was unreachable inside Sift.app. A label with a recognizer rather than a borderless
    /// `NSButton`, because MEASURED an `NSButton`'s `intrinsicContentSize` under-reports an
    /// `attributedTitle` badly (66 pt for a phrase `sizeToFit` measures at 136), and the stack view
    /// it sits in lays out from the intrinsic size — so the count was silently truncated.
    private let rowLabel = NSTextField(labelWithString: "")
    /// Holds the row count and the Open button. Kept, because its frame has to be re-fitted every
    /// time the row phrase changes: a title-bar accessory is laid out from its view's *frame*, and
    /// an `NSStackView` left to size itself inside one measures 2 pt wide (MEASURED: the controls
    /// were present, in the right place, and invisible).
    private let titlebarStack = NSStackView()

    /// Paths that arrived before the window existed. LaunchServices can deliver a Dock drop's
    /// `open` event before `applicationDidFinishLaunching` has returned, and the shell carried the
    /// same buffer for the same reason.
    /// File > Open Recent's submenu, rebuilt on the way open. See `menuNeedsUpdate`.
    private let recentsMenu = NSMenu(title: "Open Recent")

    private var pending: [String] = []
    private var keyMonitor: Any?
    /// Re-entrancy guard for ⌘G. The key monitor still fires inside the alert's modal session, so
    /// without this a second ⌘G stacks another alert on top of the first.
    private var prompting = false

    // MARK: - lifecycle

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
            // `.fullSizeContentView` is safe HERE and nowhere earlier in this plan: it needs a
            // toolbar, because the toolbar occupies the title-bar area and provides the drag
            // region. WITHOUT one the content view covers the title bar, swallows every mouse
            // event, and the window cannot be moved at all. Task 1 was given the plain style mask
            // for exactly that reason; the toolbar arrives four lines below, in the same breath.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sift"
        window.minSize = NSSize(width: 760, height: 520)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("SiftMainWindow")
        window.toolbar = NSToolbar(identifier: "SiftToolbar")
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(
            rootView: RootView(state: state, onOpen: { [weak self] in self?.showOpenPanel() })
        )
        installTitlebarControls(in: window)

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        installKeyMonitor()
        trackChrome()

        if !pending.isEmpty {
            let paths = pending
            pending.removeAll()
            Task { await state.open(paths: paths) }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Carried over from the shell (`shell/Sources/Sift/AppDelegate.swift:36`). One window, and
    /// closing it means you are done — there is no document to leave the app open for.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // `dropPrivateStore()`, not `shutdown()`: `shutdown()` is actor-isolated, so calling it
        // needs an `await`, and a `Task {}` spawned at terminate is not guaranteed to run before
        // the process exits. `dropPrivateStore()` is `nonisolated`, is exactly the cleanup that
        // matters here (removing a per-PID fallback store), and is safe to call redundantly.
        state?.session.dropPrivateStore()
    }

    /// Dock-icon drops, Finder "Open With", `open -a Sift.app file`, and File > Open Recent — all
    /// arrive here with real filesystem URLs, the thing a browser can never provide.
    func application(_ application: NSApplication, open urls: [URL]) {
        note(urls)
        let paths = urls.map(\.path)
        guard let state else {
            pending.append(contentsOf: paths)
            return
        }
        Task { await state.open(paths: paths) }
    }

    /// Every path the app opens goes through here, so File > Open Recent is populated by the act of
    /// opening rather than by a second list kept in parallel with it.
    private func note(_ urls: [URL]) {
        urls.forEach { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
    }

    // MARK: - menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sift", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Sift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Sift", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(showOpenPanel), keyEquivalent: "o")
        let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        // 🔴 NOT the `NSRecentDocumentsMenu` identifier the shell used, and that is MEASURED, not a
        // preference. With the identifier set, AppKit adopts the submenu — and then lists nothing:
        // `NSDocumentController.shared.recentDocumentURLs` was `["small.csv", "mid.csv"]` at the
        // same moment the open submenu contained only "Clear Menu". AppKit populates that menu from
        // the app's *document classes*, and this app has none (it declares `CFBundleDocumentTypes`
        // with no `NSDocumentClass`, which is what lets it appear in "Open With" without becoming
        // document-based). So the shell's Open Recent has been permanently empty, and carrying that
        // over verbatim would have carried over a menu that does nothing.
        //
        // The list itself is still AppKit's — `noteNewRecentDocumentURL` records, prunes and
        // persists it, and `recentDocumentURLs` is what is drawn. Only the drawing is ours.
        recentsMenu.delegate = self
        recents.submenu = recentsMenu
        fileMenu.addItem(recents)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export…", action: #selector(exportAction), keyEquivalent: "e")
        fileMenu.addItem(
            withTitle: "Close Table", action: #selector(closeTableAction), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Nil-targeted, so they reach whatever text field is first responder — the filter bar, the
        // SQL box, ⌘G's own number field. `undo:`/`redo:` are spelled as raw selectors because
        // `NSUndoManager`'s are not methods a `#selector` can be taken of.
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] as [(String, Selector, String)] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // AppKit retitles this to "Hide Sidebar"/"Show Sidebar" itself, because the selector is the
        // standard one — which is what a Mac user expects to read, so it is left to do so.
        viewMenu.addItem(
            withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        let inspector = NSMenuItem(
            title: "Toggle Inspector", action: #selector(toggleInspectorAction), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(inspector)
        // View > Reload is gone on purpose: it reloaded a `WKWebView` that no longer exists.
        // Re-reading a file from disk is unstage/reopen, which the Source tab already offers.
        viewMenu.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // The relocated homes for what used to be toolbar icons.
        let dataItem = NSMenuItem()
        let dataMenu = NSMenu(title: "Data")
        let merge = NSMenuItem(
            title: "Merge Tables…", action: #selector(mergeAction), keyEquivalent: "m")
        merge.keyEquivalentModifierMask = [.command, .shift]
        dataMenu.addItem(merge)
        dataMenu.addItem(
            withTitle: "Manage Staged Data…", action: #selector(stagedAction), keyEquivalent: "")
        dataItem.submenu = dataMenu
        main.addItem(dataItem)

        NSApp.mainMenu = main
    }

    // MARK: - actions
    //
    // One line each, into `AppState`. Anything longer than one line here is a decision that belongs
    // in `SiftUI`, where it can be tested.

    @objc private func toggleSidebar(_ sender: Any?) { state?.toggleSidebar() }
    @objc private func toggleInspectorAction() { state?.toggleInspector() }
    @objc private func exportAction() { state?.presentExport() }
    @objc private func mergeAction() { state?.presentMerge() }
    @objc private func stagedAction() { state?.presentStaged() }
    @objc private func badRowsAction() { state?.presentBadRows() }
    @objc private func closeTableAction() {
        guard let state else { return }
        Task { await state.closeActive() }
    }

    /// A recent item opens by the same path as a Dock drop: `note` first, so choosing it moves it
    /// back to the top of the list.
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let state, let url = sender.representedObject as? URL else { return }
        note([url])
        Task { await state.open(paths: [url.path]) }
    }

    @objc private func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let alert = NSAlert()
        alert.messageText = version.map { "Sift \($0)" } ?? "Sift"
        alert.informativeText = """
            Drop a file in and explore it. DuckDB reads files in place, so size is not the \
            constraint it usually is.

            DuckDB \(state?.engine.duckdbVersion ?? "?")
            """
        alert.runModal()
    }

    @objc private func showOpenPanel() {
        guard let state else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // A folder of parquet/CSV and a Delta table are both directories the engine opens as one
        // table, so the panel has to allow picking one.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Pick files, a folder of parquet, or a Delta table"
        guard panel.runModal() == .OK else { return }
        note(panel.urls)
        let paths = panel.urls.map(\.path)
        Task { await state.open(paths: paths) }
    }

    // MARK: - title bar

    /// Open and the live row count, in the title bar.
    ///
    /// 🔴 An `NSTitlebarAccessoryViewController` and NOT an `NSToolbarDelegate`, and that is
    /// MEASURED rather than a preference. `NavigationSplitView` inside an `NSHostingView`
    /// **replaces** `window.toolbar` with an `NSToolbar` of its own, whose delegate is
    /// `SwiftUI.ToolbarPlatformDelegate`. The shell's `toolbarDefaultItemIdentifiers` *was* called
    /// and the items *were* built — and then the whole toolbar was swapped out from under them,
    /// leaving only SwiftUI's `…navigationSplitView.toggleSidebar` and a separator behind.
    /// `insertItem` into the replacement is refused, because its delegate has never heard of
    /// `siftAdd`. A title-bar accessory is the one strip in that window SwiftUI does not manage.
    ///
    /// The layout the shell's toolbar described survives intact: SwiftUI's own sidebar toggle sits
    /// at the leading edge where `.toggleSidebar` was, and these two sit at the trailing edge,
    /// which is where `.flexibleSpace` put them. `.sidebarTrackingSeparator` is gone for the reason
    /// the plan gives — it tracks an `NSSplitViewController`'s divider, and the split is SwiftUI's.
    private func installTitlebarControls(in window: NSWindow) {
        rowLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(badRowsAction)))

        let open = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Open") ?? NSImage(),
            target: self, action: #selector(showOpenPanel))
        open.bezelStyle = .texturedRounded
        open.isBordered = true
        open.toolTip = "Open a file or folder"

        titlebarStack.orientation = .horizontal
        titlebarStack.alignment = .centerY
        titlebarStack.spacing = 10
        titlebarStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        titlebarStack.setViews([rowLabel, open], in: .leading)
        titlebarStack.translatesAutoresizingMaskIntoConstraints = true
        fitTitlebarStack()

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = titlebarStack
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func fitTitlebarStack() {
        titlebarStack.frame = NSRect(origin: .zero, size: titlebarStack.fittingSize)
    }

    /// Keep the title, the proxy icon and the row count following the catalog.
    ///
    /// `withObservationTracking` re-arms itself: `onChange` fires once, *before* the write lands,
    /// so the re-read is hopped to the next main-actor turn and re-registers for whatever
    /// `applyChrome` touches next time. AppKit has no `@Observable` binding of its own, and a timer
    /// polling `AppState` would be a second poll loop on top of the one it already runs.
    private func trackChrome() {
        withObservationTracking {
            applyChrome()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackChrome() }
        }
    }

    private func applyChrome() {
        guard let state, let window else { return }
        let active = state.active
        window.title = active?.name ?? "Sift"
        // The proxy icon and its ⌘-click path popup, since this is effectively a document window.
        // Only for a table that still has a file behind it — a merge is derived from two others and
        // has no path of its own, and a proxy icon pointing at nothing is worse than none.
        let path = active?.spec.key.path
        window.representedURL = path.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }

        let clickable = (active?.badRows ?? 0) > 0
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        // The only affordance the phrase gets. Without it "12 dropped" reads as text — which is
        // exactly the bug being fixed: a number with no way to ask what it means.
        if clickable { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        rowLabel.attributedStringValue = NSAttributedString(
            string: state.rowSummary, attributes: attributes)
        rowLabel.toolTip = clickable ? "Show the rows that were dropped" : nil
        // "counting…" and "1,048,576 of 2,000,000 rows · 12 cols · 4 dropped" are very different
        // widths, and the accessory does not re-measure itself.
        fitTitlebarStack()
    }

    // MARK: - keyboard

    /// Arrows, page keys, ⌘↑/⌘↓ (and ⌘Home/⌘End), ⌘G, and ⌘1–⌘9.
    ///
    /// A local monitor rather than a responder-chain override, because the grid is an
    /// `NSTableView` inside an `NSHostingView` and neither is this target's to subclass. Every
    /// decision it makes — which key means what, where the jump lands, which table ⌘4 is — is in
    /// `KeyNav`; what is left here is finding the scroll view and moving it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the two `Sendable` facts about the keystroke cross into the main actor —
            // `NSEvent` itself is explicitly non-`Sendable`, and nothing below needs it. Only the
            // four modifiers a shortcut is spelled with are kept: arrow and page keys also carry
            // `.function` and `.numericPad`, so comparing the raw mask would never match anything.
            let typed = event.charactersIgnoringModifiers ?? ""
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let handled = MainActor.assumeIsolated { self?.handle(typed, modifiers) ?? false }
            return handled ? nil : event
        }
    }

    /// Returns whether the keystroke was consumed. Everything it decides is in `KeyNav`.
    private func handle(_ typed: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !prompting, let state, let character = typed.first else { return false }
        let command = modifiers == .command

        if command, let index = tableIndex(forCommandKey: character) {
            state.selectTable(atIndex: index)
            return true
        }
        if command, character == "g" {
            promptForRow()
            return true
        }
        // Scrolling keys act on the grid, and only when the grid has focus. Otherwise they belong
        // to whatever does have it: arrows move the sidebar's selection, and a text field keeps its
        // own. That is the native shape of the web's `if (tag === "input") return`.
        guard modifiers.isEmpty || command, let scroll = focusedGridScrollView(),
            let key = navKey(for: character, command: command), let viewport = viewport(of: scroll)
        else { return false }
        // 🔴 Consumed whether or not it moves anything. `rowTarget` returning nil means "already
        // there", not "not ours" — and letting it fall through instead sends ⌘↓ at the bottom of
        // the table on to AppKit, which MEASURED scrolls the grid back to row 0.
        if let target = rowTarget(
            for: key, firstRow: viewport.firstRow, rowsOnScreen: viewport.rowsOnScreen,
            total: viewport.total) {
            jump(scroll, to: target)
        }
        return true
    }

    /// ⌘G. An `NSAlert` with a number field, because the web's `prompt()` has no AppKit equivalent
    /// and a sheet would need a view in `SiftUI` that only this one shortcut would ever use.
    private func promptForRow() {
        guard let scroll = gridScrollView(), let viewport = viewport(of: scroll),
            viewport.total > 0
        else { return }

        let alert = NSAlert()
        alert.messageText = "Go to row"
        alert.informativeText = "1 – \(groupDigits(String(viewport.total)))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Row number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        prompting = true
        let response = alert.runModal()
        prompting = false
        guard response == .alertFirstButtonReturn,
            let target = gotoRowTarget(
                field.stringValue, rowsOnScreen: viewport.rowsOnScreen, total: viewport.total)
        else { return }
        jump(scroll, to: target)
    }

    /// The grid's scroll view, wherever SwiftUI put it in the view tree.
    ///
    /// Identified by the row-number gutter, because the sidebar's `List` is also an `NSTableView`
    /// in an `NSScrollView` and taking "the first one" would hand the arrow keys to it. The
    /// identifier is `TableGridView`'s `gutterID`, quoted rather than shared because that file is
    /// `SiftUI`'s and this string is the whole of the coupling.
    private func gridScrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
                let table = scroll.documentView as? NSTableView,
                table.tableColumns.first?.identifier.rawValue == "__rownum__" {
                return scroll
            }
            for subview in view.subviews {
                if let found = find(subview) { return found }
            }
            return nil
        }
        guard let content = window?.contentView else { return nil }
        return find(content)
    }

    private func focusedGridScrollView() -> NSScrollView? {
        guard let scroll = gridScrollView(), let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: scroll)
        else { return nil }
        return scroll
    }

    /// Where the grid is and how much of it is showing — the same `scrollTop / ROW_H` and
    /// `ceil(clientHeight / ROW_H)` the grid's own `GridBridge.viewport` computes (that one is
    /// `internal` to `SiftUI`, so it cannot be shared with this target).
    private func viewport(of scroll: NSScrollView) -> (firstRow: Int, rowsOnScreen: Int, total: Int)?
    {
        guard let table = scroll.documentView as? NSTableView else { return nil }
        let rect = scroll.documentVisibleRect
        return (
            max(0, Int((rect.minY / gridRowHeight).rounded(.down))),
            max(1, Int((rect.height / gridRowHeight).rounded(.up))),
            table.numberOfRows
        )
    }

    private func jump(_ scroll: NSScrollView, to row: Int) {
        scroll.contentView.scroll(
            to: NSPoint(x: scroll.contentView.bounds.minX, y: CGFloat(row) * gridRowHeight))
        // Without this the clip view moves and the scroller does not — and, more importantly, no
        // bounds-changed notification reaches `GridBridge`, so the rows jumped to are never
        // fetched and the screen fills with skeletons that never resolve.
        scroll.reflectScrolledClipView(scroll.contentView)
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

// MARK: - open recent

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt every time the submenu opens, so it is never a stale copy of the list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentsMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(
                title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            // Two files can share a name and differ only in their folder, which the title cannot
            // show and this can.
            item.toolTip = url.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "Clear Menu",
                action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        }
    }
}

// MARK: - what can be done right now

extension AppDelegate: NSMenuItemValidation {
    /// Grey out what cannot be done rather than letting the click do nothing. Reached because the
    /// File and Data items are nil-targeted, and this delegate is the end of the responder chain.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let state else { return false }
        switch menuItem.action {
        case #selector(exportAction), #selector(closeTableAction):
            return state.active != nil
        case #selector(mergeAction):
            return state.tables.count >= 2   // a merge needs two tables to merge
        default:
            return true
        }
    }
}
