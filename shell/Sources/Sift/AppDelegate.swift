import AppKit
import UniformTypeIdentifiers
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var split: NSSplitViewController!
    private var sidebar: SidebarViewController!
    private var web: DropWebView!
    private var sidecar: Sidecar!
    private var handshake: Sidecar.Handshake?

    private let rowLabel = NSTextField(labelWithString: "")
    /// Paths that arrived before the page finished loading — LaunchServices delivers `open` events
    /// for a Dock drop before applicationDidFinishLaunching has returned.
    private var pending: [String] = []
    private var loaded = false

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        let root = Self.engineRoot()
        sidecar = Sidecar(root: root)
        do {
            let hs = try sidecar.start()
            handshake = hs
            web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(hs.port)/")!))
        } catch {
            presentFatal(error)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { sidecar?.stop() }

    /// Dock-icon drops, Finder "Open With", and `open -a Sift.app file` all arrive here with real
    /// filesystem URLs — the thing a browser can never provide.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map(\.path)
        paths.forEach {
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: $0))
        }
        loaded ? send(paths) : pending.append(contentsOf: paths)
    }

    // MARK: - window

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(self, name: "sift")

        web = DropWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.setValue(false, forKey: "drawsBackground")
        web.onDrop = { [weak self] paths in self?.send(paths) }
        web.onDragHint = { [weak self] on in
            self?.web.evaluateJavaScript("window.siftDragHint && window.siftDragHint(\(on))")
        }

        sidebar = SidebarViewController()
        sidebar.onSelect = { [weak self] name in
            self?.eval(Bridge.call("siftSelectTable", name))
        }
        sidebar.onClose = { [weak self] name in
            self?.eval(Bridge.call("siftCloseTable", name))
        }
        sidebar.onExport = { [weak self] table, key, ext in
            self?.exportViaSavePanel(table: table, formatKey: key, ext: ext)
        }
        sidebar.onStage = { [weak self] table, stage in
            guard let json = try? JSONSerialization.data(withJSONObject: [table, stage] as [Any]),
                  let args = String(data: json, encoding: .utf8) else { return }
            self?.eval("window.siftStage && window.siftStage.apply(null, \(args))")
        }

        let content = NSViewController()
        content.view = web

        split = NSSplitViewController()
        // sidebarWithViewController is what buys the system sidebar material, the inset selection
        // pills, and correct full-screen behaviour. It is the whole reason this list is not HTML.
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 200
        sideItem.maximumThickness = 340
        sideItem.canCollapse = true
        sideItem.holdingPriority = .defaultLow
        let mainItem = NSSplitViewItem(viewController: content)
        mainItem.minimumThickness = 480
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(mainItem)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Sift"
        window.contentViewController = split
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("SiftMainWindow")
        window.tabbingMode = .disallowed

        // With a toolbar present, the toolbar occupies the title bar area and provides the drag
        // region, so .fullSizeContentView is safe here. Without one it is NOT: the web view would
        // cover the title bar, swallow every mouse event, and the window could not be moved at all.
        let toolbar = NSToolbar(identifier: "SiftToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sift", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sift", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sift", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument), keyEquivalent: "o")
        let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "Open Recent")
        // AppKit populates and prunes this once the menu carries the magic identifier.
        recentsMenu.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
        recents.submenu = recentsMenu
        fileMenu.addItem(recents)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export…", action: #selector(exportAction), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Close Table", action: #selector(closeTable),
                         keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (t, a, k) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] as [(String, Selector, String)] {
            editMenu.addItem(withTitle: t, action: a, keyEquivalent: k)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar),
                         keyEquivalent: "s")
        // The page's own toggles are hidden in the shell (its topbar is gone), so the inspector
        // needs a native way in or it becomes unreachable once collapsed.
        let insp = NSMenuItem(title: "Toggle Inspector", action: #selector(toggleInspector),
                              keyEquivalent: "i")
        insp.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(insp)
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Enter Full Screen",
                         action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // The relocated homes for what used to be toolbar icons.
        let dataItem = NSMenuItem()
        let dataMenu = NSMenu(title: "Data")
        let merge = NSMenuItem(title: "Merge Tables…", action: #selector(mergeAction),
                               keyEquivalent: "m")
        merge.keyEquivalentModifierMask = [.command, .shift]
        dataMenu.addItem(merge)
        dataMenu.addItem(withTitle: "Manage Staged Data…", action: #selector(stagedAction),
                         keyEquivalent: "")
        dataItem.submenu = dataMenu
        main.addItem(dataItem)

        NSApp.mainMenu = main
    }

    // MARK: - actions

    @objc private func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Sift \(version)"
        alert.informativeText = """
        Drop a file in and explore it. DuckDB reads files in place, so size is not the constraint \
        it usually is.

        Engine: \(sidecar?.root.path ?? "?")
        """
        alert.runModal()
    }

    @objc private func reload() { web.reload() }
    @objc private func toggleSidebar() { split.toggleSidebar(nil) }
    @objc private func toggleInspector() {
        eval("window.siftAction && window.siftAction('inspector')")
    }
    @objc private func exportAction() { eval("window.siftAction && window.siftAction('export')") }
    @objc private func stagedAction() { eval("window.siftAction && window.siftAction('staged')") }
    @objc private func mergeAction() { eval("window.siftAction && window.siftAction('merge')") }
    @objc private func closeTable() { eval("window.siftAction && window.siftAction('close')") }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true       // a folder of parquet, or a Delta table
        panel.allowsMultipleSelection = true
        panel.message = "Pick files, a folder of parquet, or a Delta table"
        if panel.runModal() == .OK {
            let paths = panel.urls.map(\.path)
            paths.forEach {
                NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: $0))
            }
            send(paths)
        }
    }

    /// Native destination picker, then hand the path to the page's one export path.
    private func exportViaSavePanel(table: String, formatKey: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table)_export.\(ext)"
        panel.canCreateDirectories = true
        if let ct = UTType(filenameExtension: ext) { panel.allowedContentTypes = [ct] }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url,
                  let json = try? JSONSerialization.data(withJSONObject: [table, url.path, formatKey]),
                  let args = String(data: json, encoding: .utf8) else { return }
            // NSSavePanel already handled overwrite confirmation; .apply splats the JSON-escaped args.
            self?.eval("window.siftExport && window.siftExport.apply(null, \(args))")
        }
    }

    // MARK: - bridging

    private func eval(_ js: String) { web.evaluateJavaScript(js) }

    private func send(_ paths: [String]) {
        guard !paths.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: paths),
              let arg = String(data: json, encoding: .utf8) else { return }
        eval("window.siftOpenPaths && window.siftOpenPaths(\(arg))")
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Sift could not start its engine"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Where the Python engine lives. A symlink in the bundle points at the checkout, so `git pull`
    /// updates the engine without rebuilding the app.
    private static func engineRoot() -> URL {
        if let res = Bundle.main.resourceURL {
            let linked = res.appendingPathComponent("engine-root")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path) {
                return URL(fileURLWithPath: target)
            }
            if FileManager.default.fileExists(
                atPath: linked.appendingPathComponent("engine/app.py").path) {
                return linked
            }
        }
        if let override = ProcessInfo.processInfo.environment["SIFT_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

// MARK: - toolbar

private extension NSToolbarItem.Identifier {
    static let siftAdd = NSToolbarItem.Identifier("siftAdd")
    static let siftRows = NSToolbarItem.Identifier("siftRows")
}

extension AppDelegate: NSToolbarDelegate {
    // Just the essentials: sidebar toggle, Open, and the live row count. Merge / Staged live in the
    // Data menu; Export is a per-row ⤓ button and File > Export.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .siftAdd, .sidebarTrackingSeparator, .siftRows, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .siftRows:
            rowLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                       weight: .regular)
            rowLabel.textColor = .secondaryLabelColor
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = rowLabel
            item.visibilityPriority = .low
            return item
        case .siftAdd:
            return button(id, symbol: "plus", label: "Open", action: #selector(openDocument))
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, symbol: String, label: String,
                        action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                         ?? NSImage(), target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = true
        item.view = b
        return item
    }
}

// MARK: - page messages

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["type"] as? String else { return }
        // The empty-state "Open a File" button asks the shell for the native open panel.
        if kind == "open" { openDocument(); return }
        guard kind == "state",
              let payload = Bridge.decode(body, as: Bridge.StatePayload.self) else { return }
        sidebar.apply(tables: payload.tables, active: payload.active)
        rowLabel.stringValue = payload.rowSummary ?? ""
        let name = payload.active ?? ""
        window.title = name.isEmpty ? "Sift" : name
        // Gives the title bar a proxy icon and the usual ⌘-click path popup, since this is
        // effectively a document window.
        let path = payload.tables.first { $0.name == name }?.path
        window.representedURL = path.map { URL(fileURLWithPath: $0) }
    }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if !pending.isEmpty {
            send(pending)
            pending.removeAll()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentFatal(error)
    }

    /// Keep everything inside the app: only our own origin loads in the web view; anything else goes
    /// to the real browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if (url.host == "127.0.0.1" && url.port == handshake?.port) || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        }
    }
}
