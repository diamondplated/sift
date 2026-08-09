import AppKit

/// The open-sources list, as a real AppKit sidebar.
///
/// Lives in Swift rather than HTML for one reason: vibrancy. An `NSSplitViewItem` created with
/// `sidebarWithViewController:` gets the system's sidebar material, translucency, inset selection
/// pills, and correct behaviour in full screen — none of which a web view can imitate convincingly.
final class SidebarViewController: NSViewController, NSMenuDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()

    var tables: [Bridge.TableInfo] = []
    var active: String?
    /// The row whose × is armed: one click arms it, a second within a couple seconds confirms.
    private var armedClose: String?

    /// Forwarded into the page/shell. onExport is (table, format-key, file-extension); onStage is
    /// (table, stage?) where false means unstage.
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onExport: ((String, String, String) -> Void)?
    var onStage: ((String, Bool) -> Void)?

    // The formats DuckDB's COPY can write. Keys match engine EXPORT_FORMATS; the web menu lists
    // the same six. Presentation lives here for the same reason tint/symbol do — it can only be Swift.
    static let exportFormats: [(key: String, label: String, ext: String)] = [
        ("parquet", "Parquet (zstd)", "parquet"), ("csv", "CSV", "csv"), ("tsv", "TSV", "tsv"),
        ("json", "JSON (array)", "json"), ("ndjson", "NDJSON (lines)", "ndjson"),
        ("xlsx", "Excel", "xlsx"),
    ]

    override func loadView() {
        // A plain NSView: the split view item supplies the sidebar material behind it, so adding
        // our own NSVisualEffectView here would double up and look muddy.
        view = NSView()

        table.headerView = nil
        table.style = .sourceList          // rounded inset selection pill + sidebar metrics
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self          // rebuilt per right-clicked row so Stage/Unstage fits the file
        table.menu = menu
        table.addTableColumn(NSTableColumn(identifier: .init("source")))

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func apply(tables: [Bridge.TableInfo], active: String?) {
        let changed = tables != self.tables
        self.tables = tables
        self.active = active
        if armedClose != nil && !tables.contains(where: { $0.name == armedClose }) {
            armedClose = nil
        }
        if changed { table.reloadData() }
        if let active, let idx = tables.firstIndex(where: { $0.name == active }) {
            if table.selectedRow != idx {
                table.selectRowIndexes([idx], byExtendingSelection: false)
            }
        } else if tables.isEmpty {
            table.deselectAll(nil)
        }
    }

    // ---------------------------------------------------------------- menus

    private static let stageable: Set<String> = ["csv", "glob_csv", "xlsx", "json", "ndjson"]

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let export = NSMenuItem(title: "Export as", action: nil, keyEquivalent: "")
        export.submenu = exportMenu(explicitTable: nil)   // resolve the row when the item fires
        menu.addItem(export)
        // Stage / unstage, when it applies to the right-clicked file.
        if let t = tables[safe: clickedRow] {
            if t.staged {
                menu.addItem(item("Read from Source (unstage)", #selector(unstageClicked)))
            } else if Self.stageable.contains(t.fmt) {
                menu.addItem(item("Stage This File", #selector(stageClicked)))
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Copy Full Path", #selector(copyPathClicked)))
        menu.addItem(item("Copy Table Name", #selector(copyNameClicked)))
        menu.addItem(item("Reveal in Finder", #selector(revealClicked)))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(closeClicked)))
    }

    @objc private func stageClicked() {
        if let t = tables[safe: clickedRow] { onStage?(t.name, true) }
    }
    @objc private func unstageClicked() {
        if let t = tables[safe: clickedRow] { onStage?(t.name, false) }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    /// A format menu. explicitTable set → the ⤓ button (known row); nil → the context menu,
    /// which resolves the right-clicked row when the item fires.
    private func exportMenu(explicitTable: String?) -> NSMenu {
        let menu = NSMenu()
        for f in Self.exportFormats {
            let it = NSMenuItem(title: f.label, action: #selector(exportPicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = explicitTable.map { [$0, f.key, f.ext] } ?? [f.key, f.ext]
            menu.addItem(it)
        }
        return menu
    }

    private var clickedRow: Int { table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }

    @objc private func doubleClicked() {
        guard tables.indices.contains(clickedRow) else { return }
        onSelect?(tables[clickedRow].name)
    }

    @objc private func closeClicked() {
        guard tables.indices.contains(clickedRow) else { return }
        onClose?(tables[clickedRow].name)
    }

    @objc private func revealClicked() {
        guard tables.indices.contains(clickedRow) else { return }
        NSWorkspace.shared.selectFile(tables[clickedRow].path, inFileViewerRootedAtPath: "")
    }

    @objc private func copyPathClicked() { copy(tables[safe: clickedRow]?.path) }
    @objc private func copyNameClicked() { copy(tables[safe: clickedRow]?.name) }

    private func copy(_ s: String?) {
        guard let s else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func exportPicked(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String] else { return }
        if a.count == 3 {
            onExport?(a[0], a[1], a[2])                       // ⤓ button: table is explicit
        } else if let t = tables[safe: clickedRow]?.name {
            onExport?(t, a[0], a[1])                          // context menu: right-clicked row
        }
    }

    // -------------------------------------------------- per-row button actions

    /// ⤓ pressed: pop the format menu anchored under the button.
    fileprivate func showExportMenu(table name: String, anchor: NSView) {
        let menu = exportMenu(explicitTable: name)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    /// × pressed: first press arms (and shows a red confirm state), second within 2.5 s closes.
    fileprivate func closePressed(table name: String) {
        if armedClose == name {
            armedClose = nil
            onClose?(name)
            return
        }
        armedClose = name
        reloadRow(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.armedClose == name { self?.armedClose = nil; self?.reloadRow(name) }
        }
    }

    private func reloadRow(_ name: String) {
        guard let idx = tables.firstIndex(where: { $0.name == name }) else { return }
        table.reloadData(forRowIndexes: [idx], columnIndexes: [0])   // keeps selection
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tables.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SourceCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SourceCell)
            ?? SourceCell(identifier: id)
        let name = tables[row].name
        cell.configure(
            with: tables[row], armed: armedClose == name,
            onDownload: { [weak self] anchor in self?.showExportMenu(table: name, anchor: anchor) },
            onClose: { [weak self] in self?.closePressed(table: name) })
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard tables.indices.contains(row) else { return }
        let name = tables[row].name
        guard name != active else { return }
        active = name
        onSelect?(name)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Source-list row: a tinted format-icon chip, the name/subtitle, and — revealed at the trailing
/// edge — a download (⤓) and a close (×) button. The app-icon list style current macOS sidebars use.
private final class SourceCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    private let chip = NSView()
    private let spinner = NSProgressIndicator()
    private let dlBtn = NSButton()
    private let closeBtn = NSButton()
    private var tint: NSColor = .systemGray
    private var onDownload: ((NSView) -> Void)?
    private var onClose: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        chip.layer?.cornerCurve = .continuous
        badge.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        badge.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])

        // Spins only while the row count is still unknown — a small, honest sign of life.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        configureButton(dlBtn, symbol: "square.and.arrow.down", help: "Export…",
                        action: #selector(downloadPressed))
        configureButton(closeBtn, symbol: "xmark", help: "Close", action: #selector(closePressedBtn))

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)   // absorb slack; buttons stay trailing
        let row = NSStackView(views: [chip, text, spinner, dlBtn, closeBtn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 30),
            chip.heightAnchor.constraint(equalToConstant: 30),
        ])
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureButton(_ b: NSButton, symbol: String, help: String, action: Selector) {
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        b.contentTintColor = .tertiaryLabelColor
        b.toolTip = help
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @objc private func downloadPressed() { onDownload?(dlBtn) }
    @objc private func closePressedBtn() { onClose?() }

    func configure(with info: Bridge.TableInfo, armed: Bool,
                   onDownload: @escaping (NSView) -> Void, onClose: @escaping () -> Void) {
        self.onDownload = onDownload
        self.onClose = onClose
        title.stringValue = info.name
        subtitle.stringValue = info.subtitle
        tint = Self.tint(for: info.fmt)
        badge.image = NSImage(systemSymbolName: Self.symbol(for: info.fmt),
                              accessibilityDescription: info.fmt)
        badge.contentTintColor = tint      // NSColor property: AppKit re-resolves it on theme switch
        applyChipColor()
        subtitle.textColor = info.badRows > 0 ? .systemOrange : .secondaryLabelColor
        info.rows == nil ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        // Armed close: red filled × plus a nudge in the tooltip.
        closeBtn.image = NSImage(systemSymbolName: armed ? "xmark.circle.fill" : "xmark",
                                 accessibilityDescription: "Close")
        closeBtn.contentTintColor = armed ? .systemRed : .tertiaryLabelColor
        closeBtn.toolTip = armed ? "Click again to close" : "Close"
        toolTip = "\(info.path)\n\(info.subtitle)"
            + (info.badRows > 0 ? "\n\(Bridge.TableInfo.grouped(info.badRows)) rows dropped" : "")
    }

    // A raw cgColor is snapshotted at one appearance, so re-resolve it whenever the theme flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChipColor()
    }

    private func applyChipColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chip.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        }
    }

    private static func tint(for fmt: String) -> NSColor {
        switch fmt {
        case "parquet", "glob_parquet": return .systemPurple
        case "delta": return .systemOrange
        case "xlsx": return .systemTeal
        case "json", "ndjson": return .systemBlue
        case "glob_csv": return .systemIndigo
        case "csv": return .systemGreen
        case "merge": return .systemPink
        default: return .systemGray
        }
    }

    private static func symbol(for fmt: String) -> String {
        switch fmt {
        case "parquet", "glob_parquet": return "square.stack.3d.up.fill"
        case "delta": return "clock.arrow.circlepath"
        case "xlsx": return "tablecells.fill"
        case "json", "ndjson": return "curlybraces"
        case "merge": return "arrow.triangle.merge"
        default: return "doc.text.fill"
        }
    }
}
