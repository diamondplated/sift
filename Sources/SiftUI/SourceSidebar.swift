import AppKit
import SiftCore
import SiftEngine
import SwiftUI
import UniformTypeIdentifiers

// The open-sources list. Ports `SidebarViewController` (shell/Sources/Sift/SidebarViewController.swift)
// and `renderRail` (web/index.html:975-988) into one view.
//
// Everything the AppKit sidebar did as *presentation* stays presentation — the tinted format chip,
// the two-press armed ×, the hover-revealed buttons — and everything the browser rail did as
// *phrasing* stays phrasing, up here rather than in the engine (CellGlyph.swift's header states
// which way each kind of string travels). The shell used to receive `sourceSubtitle` as a finished
// string over the bridge; there is no bridge, so the four sentences below are that function, ported.
//
// 🔴 The order of the rows is `Session.state()`'s and nothing else's. It sorts by `openedAt`, which
// is the order the user opened the files in — re-sorting or re-keying here is exactly how the tab
// bar started shuffling on every launch. `AppState.refresh()` says the same thing on the other side.

// MARK: - the strings

/// `csv · 41.2 MB · 2,412,338 rows · staged`. A verbatim port of `sourceSubtitle`
/// (web/index.html:966-972).
///
/// Three details that are not incidental:
/// * `merge` reads `merged`, and a merge view has **no size** — its `SourceKey` is
///   `("merge://a+b", 0, 0)`, so the web's falsy `if (t.size)` is `size > 0` here.
/// * `glob_` becomes `▤ `, so a folder of parquet reads `▤ parquet` and not `glob_parquet`. A
///   folder source is a folder, said in one glyph.
/// * the row count is `displayRows` — the exact count when there is one, the byte-sample estimate
///   until then. Before Task 5a restored it this was `nil` for every CSV over the exact-count
///   threshold, and the subtitle simply lost its rows segment on the biggest files in the product.
public func sourceSubtitle(_ t: SiftEngine.Table) -> String {
    var parts = [t.spec.fmt == .merge ? "merged" : t.spec.fmt.rawValue.replacing("glob_", with: "▤ ")]
    if t.spec.key.size > 0 { parts.append(humanBytes(t.spec.key.size)) }
    if let rows = t.displayRows { parts.append("\(groupDigits(String(rows))) rows") }
    if t.staged { parts.append("staged") }
    return parts.joined(separator: " · ")
}

/// The row-count phrase — `rowText` (web/index.html:958-963) onto Task 5's fields.
///
/// 🔴 **The `≈ N rows` branch is reachable only because of `Table.displayRows`' estimate fallback.**
/// Before it, `displayRows` was `nil` in precisely the case `!rowsAreExact` describes, so every
/// unexact table took the `counting…` branch and this one could never fire. Removing the fallback
/// makes `theEstimateBranchIsReachable` red, which is the point of that test.
///
/// Counts group through `SiftCore.groupDigits`, the one loop the grid, the CLI and the inspector
/// already share. Never a `NumberFormatter` — without an explicit locale the same number renders
/// four ways.
public func rowText(_ t: SiftEngine.Table) -> String {
    guard let rows = t.displayRows, !t.counting else { return "counting…" }
    if !t.qspec.filters.isEmpty, let unfiltered = t.gridRows {
        return "\(groupDigits(String(rows))) of \(groupDigits(String(unfiltered))) rows"
    }
    return (t.rowsAreExact ? "" : "≈ ") + "\(groupDigits(String(rows))) rows"
}

/// The chip: an SF Symbol and a tint per format. Ported from `SourceCell.symbol(for:)` /
/// `.tint(for:)`, which could only ever be Swift.
///
/// Exhaustive on purpose — no `default`. A seventh `Fmt` is then a compile error here rather than a
/// grey doc icon nobody notices.
public func formatBadge(_ fmt: Fmt) -> (symbol: String, tint: Color) {
    switch fmt {
    case .parquet, .globParquet: return ("square.stack.3d.up.fill", .purple)
    case .delta: return ("clock.arrow.circlepath", .orange)
    case .xlsx: return ("tablecells.fill", .teal)
    case .json, .ndjson: return ("curlybraces", .blue)
    case .globCsv: return ("doc.text.fill", .indigo)
    case .csv: return ("doc.text.fill", .green)
    case .merge: return ("arrow.triangle.merge", .pink)
    }
}

/// Does `Stage This File` apply to this format? `SidebarViewController.stageable`, which is the
/// complement of `SiftCore.neverStage` (parquet, a parquet glob and Delta are already columnar with
/// footer statistics — a flat copy buys nothing and freezes Delta at one version) minus `merge`,
/// which is a view over two open tables and has no file to copy.
///
/// Restated here rather than read from `neverStage`, which is `internal` to SiftCore: this is a menu
/// item's applicability, and `Session.stageNow` remains the authority on whether a copy happens.
public func stageableFormat(_ fmt: Fmt) -> Bool {
    switch fmt {
    case .csv, .globCsv, .xlsx, .json, .ndjson: return true
    case .parquet, .globParquet, .delta, .merge: return false
    }
}

/// The row's tooltip: where the file is, what it is, and what was thrown away reading it.
/// `SourceCell.configure`'s `toolTip`.
public func sourceTooltip(_ t: SiftEngine.Table) -> String {
    var text = "\(t.spec.key.path)\n\(sourceSubtitle(t))"
    if t.badRows > 0 { text += "\n\(groupDigits(String(t.badRows))) rows dropped" }
    return text
}

/// The path the box should open by itself, or `nil`. Ports the paste handler at
/// web/index.html:1796-1799 — a pasted absolute path with no newline in it opens immediately,
/// because the whole point of ⌥⌘C in Finder is not having to press anything else.
///
/// A *paste* is "more than one character arrived at once". The web had a `paste` event to key off;
/// SwiftUI's `TextField` has no such hook, and growth is the honest substitute — typing can never
/// add two characters in one change, so hand-typing `/Users/...` cannot fire this on its first
/// keystroke the way a bare `hasPrefix("/")` test would.
public func autoOpenPath(from old: String, to new: String) -> String? {
    guard new.count > old.count + 1 else { return nil }
    let path = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), !path.contains("\n") else { return nil }
    return path
}

/// How long the × stays armed. `SidebarViewController.closePressed`'s 2.5 s.
public let armedCloseSeconds: TimeInterval = 2.5

/// Does this press on the × actually close the table?
///
/// The two-press close is not decoration: closing a table throws away its staged-copy adoption and
/// its cached profile, both of which cost real seconds to rebuild, and the × sits a few pixels from
/// the row you click to *select* the table.
public func closeConfirmed(armedAt: Date?, now: Date = Date()) -> Bool {
    guard let armedAt else { return false }
    return now.timeIntervalSince(armedAt) < armedCloseSeconds
}

// MARK: - the drag hint
//
// Spelled out rather than written with SwiftUI's `@Entry` macro, which needs the Xcode 16 SDK — this
// Mac and CI are not on the same one. Five lines that compile everywhere beat a macro that compiles
// in one place.

private struct SourceDragHotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A drag is over the window.
    ///
    /// An environment value rather than a parameter because the two places that light up are on
    /// opposite sides of the split — the sidebar's dropzone and the no-file-open pane — while the
    /// drop itself is on the window above both. The shell drove exactly this over the bridge
    /// (`window.siftDragHint` → `.dropzone.hot` and `.gempty.drop`); without it a drag over the
    /// window gives no feedback at all, which reads as "drops are not supported here".
    public var sourceDragHot: Bool {
        get { self[SourceDragHotKey.self] }
        set { self[SourceDragHotKey.self] = newValue }
    }
}

// MARK: - the sidebar

/// Open sources, the dropzone, the path box and the drop note.
public struct SourceSidebar: View {
    @Bindable private var state: AppState

    @Environment(\.sourceDragHot) private var dragHot
    @State private var pathText = ""

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if state.tables.isEmpty {
                // `renderRail`'s `<div class="rail-note">Nothing open yet.</div>`.
                Text("Nothing open yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(12)
            } else {
                List(state.tables, id: \.name, selection: $state.activeName) { table in
                    SourceRow(table: table, state: state)
                }
            }
            Divider()
            dropzone
            pathBox
            dropNote
        }
    }

    /// `web/index.html:342` — the dashed target, and the one place a drag anywhere in the window
    /// says so in the sidebar.
    private var dropzone: some View {
        VStack(spacing: 2) {
            Text("Drop a file here").font(.system(size: 12))
            Text("CSV · Parquet · JSON · XLSX · folder · Delta")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(
            dragHot ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    dragHot ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .foregroundStyle(dragHot ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// The paste-a-path box. It shipped in `web/index.html` and was unreachable inside `Sift.app`
    /// only because `body.native` hid the rail that held it, so this is a restoration.
    ///
    /// 🔴 It opens through `AppState.open(paths:)` — the same entry the open panel, a Dock-icon drop,
    /// Finder "Open With" and `open -a Sift.app` all use — so a pasted workbook reaches the sheet
    /// picker by the one route that decides that, and not by a second copy of the rule.
    private var pathBox: some View {
        HStack(spacing: 6) {
            TextField("…or paste a path (⌥⌘C in Finder)", text: $pathText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(submit)
                .onChange(of: pathText) { old, new in
                    guard let path = autoOpenPath(from: old, to: new) else { return }
                    pathText = ""
                    Task { await state.open(paths: [path]) }
                }
            Button("Open", action: submit)
                .controlSize(.small)
                .disabled(pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var dropNote: some View {
        Text(
            """
            Files are read **in place** — nothing is copied, so a 20 GB file opens as fast as a \
            2 MB one. Drop here, on the Dock icon, or use Finder's Open With.
            """
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submit() {
        let path = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        pathText = ""
        Task { await state.open(paths: [path]) }
    }
}

// MARK: - one row

/// The format chip, the name, the subtitle, and — on hover — ⤓ and ×.
///
/// `internal`, not `private`: `SourceSidebarTests` renders it. SwiftUI's `List` is `NSTableView`
/// underneath, so `ImageRenderer` replaces the whole list with a prohibited-symbol placeholder and
/// the only way to get a look at a row's pixels is to render the row.
struct SourceRow: View {
    let table: SiftEngine.Table
    let state: AppState

    @State private var hovering = false
    /// When the × was armed, or `nil`. See `closeConfirmed`.
    @State private var armedAt: Date?

    private var badge: (symbol: String, tint: Color) { formatBadge(table.spec.fmt) }
    private var armed: Bool { armedAt != nil }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: badge.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(badge.tint)
                .frame(width: 30, height: 30)
                .background(badge.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(table.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Orange the moment a row was thrown away reading this file. The count itself is in
                // the tooltip and the bad-rows sheet; this is the part you see without asking.
                Text(sourceSubtitle(table))
                    .font(.system(size: 11))
                    .foregroundStyle(table.badRows > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            // A small, honest sign of life while the background count is still running.
            if table.rowCount == nil {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
            }
            exportMenu
            closeButton
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(sourceTooltip(table))
        .contextMenu { menu }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(exportFormats, id: \.key) { format in
                Button(exportLabel(forKey: format.key)) { export(format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("Export…")
        .opacity(hovering ? 1 : 0)
    }

    private var closeButton: some View {
        Button(action: closePressed) {
            Image(systemName: armed ? "xmark.circle.fill" : "xmark")
                .foregroundStyle(armed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help(armed ? "Click again to close" : "Close")
        .opacity(hovering || armed ? 1 : 0)
    }

    @ViewBuilder
    private var menu: some View {
        Menu("Export as") {
            ForEach(exportFormats, id: \.key) { format in
                Button(exportLabel(forKey: format.key)) { export(format) }
            }
        }
        if table.staged {
            Button("Read from Source (unstage)") { stage(false) }
        } else if stageableFormat(table.spec.fmt) {
            Button("Stage This File") { stage(true) }
        }
        Divider()
        Button("Copy Full Path") { copy(table.spec.key.path) }
        Button("Copy Table Name") { copy(table.name) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(table.spec.key.path, inFileViewerRootedAtPath: "")
        }
        Divider()
        // Straight to the close — the context menu is already a deliberate two-step, and the
        // engine's refusal (a live merge reads this table) comes back as a sentence on the banner.
        Button("Close") { Task { await state.close(table.name) } }
    }

    // MARK: - actions

    /// First press arms and turns the × red; a second within `armedCloseSeconds` closes.
    private func closePressed() {
        if closeConfirmed(armedAt: armedAt) {
            armedAt = nil
            Task { await state.close(table.name) }
            return
        }
        let stamp = Date()
        armedAt = stamp
        Task {
            // Slightly past the window, so the red × never outlives the decision it stands for.
            try? await Task.sleep(nanoseconds: UInt64((armedCloseSeconds + 0.1) * 1_000_000_000))
            if armedAt == stamp { armedAt = nil }
        }
    }

    /// Pick a destination, then write. Ports the shell's `exportViaSavePanel` — the panel has
    /// already asked about overwriting by the time it returns `.OK`, which is why `overwrite: true`
    /// here is not a second silent decision.
    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table.name)_export.\(format.ext)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let result = try await state.session.export(
                    table.name, dest: url.path, format: format.key, overwrite: true)
                state.banner = exportToast(result)
            } catch {
                state.banner = error.localizedDescription
            }
        }
    }

    /// `window.siftStage` (web/index.html:1596-1607). Staging is a background job the poll loop
    /// picks up; unstaging is immediate, so the catalog is refreshed before the sentence lands.
    private func stage(_ on: Bool) {
        Task {
            do {
                if on {
                    try await state.session.stageNow(table.name, force: true)
                    state.banner = "Staging \(table.name)…"
                } else {
                    _ = try await state.session.unstage(table.name)
                    await state.refresh()
                    state.banner = "\(table.name): now reading from source"
                }
            } catch {
                state.banner = error.localizedDescription
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - the window drop

extension View {
    /// The whole window is the drop target — a drag anywhere in it opens the file, and lights both
    /// places that say so.
    ///
    /// The browser's copy-the-file path (`uploadFile`, `/api/upload`, `SIFT_MAX_UPLOAD_MB`) is
    /// deliberately not ported: it existed only because a browser drop does not say where the file
    /// lives. An AppKit drop does, and spec §8 deletes the rest.
    public func sourceDrop(state: AppState) -> some View {
        modifier(SourceDrop(state: state))
    }
}

private struct SourceDrop: ViewModifier {
    let state: AppState
    @State private var hot = false

    func body(content: Content) -> some View {
        content
            .environment(\.sourceDragHot, hot)
            .onDrop(of: [.fileURL], isTargeted: $hot) { providers in
                Task {
                    let paths = await droppedPaths(from: providers)
                    // `open(paths:)`, the one entry every path in this app arrives through — the
                    // open panel, the Dock icon, Finder "Open With" and this. It is what routes a
                    // workbook to the sheet picker; a second copy of that rule here is how `.xlsm`
                    // ends up handled in only one of them.
                    if paths.isEmpty {
                        // A drop that visibly lands and then does nothing is the silent failure
                        // this app exists to be the opposite of. `.fileURL` is what was asked for,
                        // so an empty result is a promise the drag broke, not a user error.
                        state.banner = "Nothing in that drop was a file on disk."
                    } else {
                        await state.open(paths: paths)
                    }
                }
                return true
            }
    }
}

/// Real filesystem paths out of a drop, in the order they were dropped.
///
/// `internal` so `SourceSidebarTests` can hand it synthetic providers — an `NSItemProvider` is the
/// only part of the drop that can be built without a drag.
///
/// `@MainActor` because `NSItemProvider` is not `Sendable`: the providers `onDrop` hands over are
/// the drag's own objects, and letting them cross an isolation boundary is a data race the compiler
/// is right to refuse. Nothing here blocks — `loadItem` suspends.
@MainActor
func droppedPaths(from providers: [NSItemProvider]) async -> [String] {
    var found: [String] = []
    for provider in providers {
        // 🔴 `url.isFileURL` is load-bearing, not belt-and-braces. `URL(dataRepresentation:)` is
        // permissive: hand it bytes that are not a URL at all and it returns a RELATIVE url whose
        // `.path` is the raw string — which would go to the engine as a path and come back as
        // "No such file or folder: <whatever those bytes were>". MEASURED by mutation: without this
        // clause a provider carrying plain bytes under the `public.file-url` identifier produced a
        // path, and the test built to catch exactly that passed anyway.
        // `loadDataRepresentation`, not `loadItem`. `loadItem` returns `any NSSecureCoding`, which
        // is not `Sendable`, so awaiting it from here is a hard error under the macOS 15 SDK's
        // stricter concurrency checking — accepted silently by this machine's newer SDK and caught
        // only by CI, which is the second time that exact skew has bitten this branch. The data
        // representation is what the code wanted anyway; the cast to `Data` is gone with it.
        // Bridged by hand rather than awaiting `loadItem`. `loadItem` returns `any NSSecureCoding`,
        // which is not `Sendable`, so awaiting it here is a hard error under the macOS 15 SDK's
        // stricter concurrency checking — accepted silently by this machine's newer SDK and caught
        // only by CI, the second time that exact skew has bitten this branch. `Data` IS `Sendable`,
        // so resuming the continuation with it crosses the boundary legally, and the completion
        // handler is the only spelling available on the floor version.
        guard let data = await loadFileURLData(from: provider),
            let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL
        else { continue }
        found.append(url.path)
    }
    return found
}


/// One drag item's `public.file-url` bytes, or nil. See `droppedPaths` for why this is bridged by
/// hand instead of awaiting `loadItem` directly.
@MainActor
private func loadFileURLData(from provider: NSItemProvider) async -> Data? {
    await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            continuation.resume(returning: data)
        }
    }
}
