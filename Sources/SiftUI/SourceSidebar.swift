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

/// The engine and its version, for the sidebar's last line.
///
/// 🔴 The web build showed engine and version **in-window**; the native port showed it only in
/// About Sift, behind a menu item nobody opens. "Which DuckDB is this" is the first question of
/// every report about a file that read wrong — a delimiter sniffed differently, an extension
/// missing, a type widened — and a version behind a modal is a version nobody ever quotes. The
/// sidebar's foot is the cheapest honest place: always on screen, never in the way, and selectable
/// so it can be pasted into the report it exists for.
///
/// `EngineInfo.duckdbVersion` already carries DuckDB's own leading `v` (`v1.5.5`), so this does not
/// add one — About Sift reads the same field and prints it the same way.
public func engineFooterText(_ engine: EngineInfo) -> String { "DuckDB \(engine.duckdbVersion)" }

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

/// The row's tooltip: where the file is, what it is, when it was fetched, and what was thrown away
/// reading it.  `SourceCell.configure`'s `toolTip`.
///
/// 🔴 `spec.key.path` is the **sanitized** URL for a remote source (`RemoteRef.url` by contract, and
/// `RemoteURL.sanitized`'s own doc: "the ONLY form that may be displayed or persisted"). Never
/// `spec.target` — that is the cache file for a downloaded object, which is not where the user's
/// data lives — and never `wireURL`, which re-attaches the SAS token for DuckDB alone. A signature
/// on screen is a signature in the next screenshot in the next bug report.
public func sourceTooltip(_ t: SiftEngine.Table) -> String {
    var text = "\(t.spec.key.path)\n\(sourceSubtitle(t))"
    if let fetched = remoteFetchedAt(t) { text += "\nFetched from the network \(fetched)" }
    if t.badRows > 0 { text += "\n\(groupDigits(String(t.badRows))) rows dropped" }
    return text
}

// MARK: - remote sources
//
// `spec.remote` is non-nil for exactly the sources that came from a URL, which is why nothing below
// re-derives remoteness from a string. `AppState.needsSheetPicker` and `SourceProbe.isCompressedPath`
// are the two shipped sites that DID ask `NSString.pathExtension` about a URL — see
// `RemoteURL.effectiveExt`, the field that exists because of them.

/// When a remote source's bytes were fetched, as `2026-08-14 14:32`, or `nil` for a local one.
///
/// 🔴 `stagedTimestamp`, not a second clock and not a formatter. `RemoteRef.fetchedAtNs` is UNIX
/// **epoch** nanoseconds — `fetchClockNs()` is `Date().timeIntervalSince1970 * 1e9`, chosen over
/// `uptimeNanoseconds` precisely because the value is compared on a later launch — so it is a wall
/// time and the staged sheet's own hand-rolled renderer is the right one for it. No `DateFormatter`
/// family anywhere near this; see `stagedTimestamp`'s note for the four locale bugs that ban them.
public func remoteFetchedAt(_ t: SiftEngine.Table) -> String? {
    guard let remote = t.spec.remote else { return nil }
    return stagedTimestamp(Date(timeIntervalSince1970: Double(remote.fetchedAtNs) / 1_000_000_000))
}

/// Does this row offer ⟳? A source opened from a URL, and nothing else — `Session.refreshRemote`
/// refuses a local table with a sentence saying Sift already reads it from disk on every query, and
/// offering a button whose only outcome is that sentence is not an affordance.
public func offersRefresh(_ t: SiftEngine.Table) -> Bool { t.spec.remote != nil }

/// Does this row offer the other sheets of its workbook?
///
/// 🔴 **`spec.fmt` and `spec.sheets`, never `needsSheetPicker(spec.key.path)`.** That function is
/// `NSString.pathExtension`, which on `https://h/f.xlsx?sv=…&sig=…` answers with the tail of the SAS
/// signature and on `https://h/get?id=5&fmt=xlsx` answers `xlsx` for a thing that is not one. The
/// spec was built by reading the actual bytes, so it already knows both facts truthfully — and it
/// knows them identically for a local workbook and a remote one, which is why this is one rule
/// rather than two.
///
/// `> 1` because a one-sheet workbook has no choice to offer. The PRE-open picker deliberately keeps
/// its unconditional behaviour (see `SheetPickerSheet`'s header): that is a parity contract, and this
/// is a different question — "what else is in the file I already have open".
public func offersSheetChoice(_ t: SiftEngine.Table) -> Bool {
    t.spec.fmt == .xlsx && t.spec.sheets.count > 1
}

/// The banner after a refresh that worked. The engine's `RefreshOutcome` case, rendered — never
/// re-derived from a side effect.
///
/// 🔴 The two cases are indistinguishable from outside: a refetch that returned identical bytes and
/// an object that never changed leave the same grid, the same row count and the same everything.
/// That is the whole reason `refreshRemote` returns a value at all rather than leaving the caller to
/// guess, and a UI that guessed would put a confident wrong sentence on screen half the time.
///
/// `since` arrives already rendered (`"14:32"`, 24-hour, the user's own time zone, built from
/// `Calendar` components by `clockHHMM`) because this codebase permits no formatter to render a
/// `Date`. It is passed through, not reformatted.
public func refreshOutcomeText(table: String, _ outcome: RefreshOutcome) -> String {
    switch outcome {
    case .unchanged(let since): return "\(table): unchanged since \(since)."
    case .refetched: return "\(table): re-fetched from the source."
    }
}

/// The one cause a failed refresh cannot be told apart from, stated as the conditional it is.
///
/// 🔴 **A SAS-signed source cannot be refreshed, and that is T8's no-persisted-credential ruling
/// holding rather than a defect.** `RemoteRef.url` is sanitized by contract, so `refreshRemote`
/// re-derives a URL with no query, the HEAD comes back 403, and the retry fails with DuckDB's own
/// HTTP line. That line is a status code: true, clean, and useless to act on.
///
/// It is appended to *every* refusal rather than to the signed ones because **there is no honest
/// marker to test.** `RemoteRef` deliberately carries no `hadQuery` flag (T10 declined to add one:
/// a SAS'd parquet gets `sasParquetNote` and a SAS'd CSV gets nothing, and half a signal is worse
/// than none), and inventing one here would mean guessing. A conditional sentence naming the one
/// fix beats a bare 403 on the failure it most often explains; the alternative the brief allows —
/// not offering Refresh at all — would remove it from every unsigned remote source too.
public let refreshSignedURLNote =
    "If you opened this from a signed URL — one with a ?sv=…&sig=… SAS token — Sift never saved the "
    + "signature, so a refresh reaches the server as an anonymous request. Paste the whole URL into "
    + "the box again to re-open it."

/// The engine's own sentence first, then the one thing it cannot know. Never a `try?`, never a
/// paraphrase of the engine's half.
public func refreshFailureText(table: String, error: String) -> String {
    "\(error) \(refreshSignedURLNote)"
}

/// SF Symbols the sidebar draws that are not a format chip.
///
/// 🔴 Named here for the same reason `ToolbarSymbol` exists: `Image(systemName:)` handed a name
/// macOS does not know draws **nothing** and reports nothing — a hit-testable, enabled, invisible
/// button. `theSidebarsSymbolsAllResolve` asks the running system, which matters more than usual
/// here because this Mac carries a newer SDK than the macos-15 runner and the macOS 14 floor is
/// lower than both.
enum SidebarSymbol {
    /// This table came over the network.
    static let remote = "network"
    static let refresh = "arrow.clockwise"
    static let sheets = "tablecells"
    /// The way into the Connections screen.
    static let connections = "externaldrive.connected.to.line.below"

    static let all = [remote, refresh, sheets, connections]
}

/// The path **or URL** the box should open by itself, or `nil`. Ports the paste handler at
/// web/index.html:1796-1799 — a pasted absolute path with no newline in it opens immediately,
/// because the whole point of ⌥⌘C in Finder is not having to press anything else.
///
/// A *paste* is "more than one character arrived at once". The web had a `paste` event to key off;
/// SwiftUI's `TextField` has no such hook, and growth is the honest substitute — typing can never
/// add two characters in one change, so hand-typing `/Users/...` cannot fire this on its first
/// keystroke the way a bare `hasPrefix("/")` test would. That rule is unchanged by the URL half:
/// `https://` is eight keystrokes, and none of them may open anything.
///
/// 🔴 **`SiftCore.classifyRemote` is the authority on what a remote URL is, and a second opinion
/// here would be a bug rather than a duplication.** It already knows every scheme spelling DuckDB's
/// own azure secret scopes to (`az`/`azure`/`abfss`/`abfs`, plus `s3`/`http`/`https`), and its `nil`
/// means **local path** — so a scheme this function decided about on its own and got wrong would not
/// be "unsupported", it would be a URL handed silently to the local-file flow to come back as a
/// missing file. Copying a blob URL and pasting it into Sift is the gesture this whole phase was
/// designed around; it must not be decided by `hasPrefix("http")`.
///
/// The **whole** pasted string is returned, query included. The SAS token has to reach DuckDB, and
/// `Session.openPath` → `classifyRemote` → `wireURL` is the single choke point that keeps it in
/// memory: the box clears itself, `RemoteRef.url` stores the sanitized form, and nothing on the way
/// renders what was pasted.
public func autoOpenPath(from old: String, to new: String) -> String? {
    guard new.count > old.count + 1 else { return nil }
    let path = new.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.contains("\n") else { return nil }
    guard path.hasPrefix("/") || classifyRemote(path) != nil else { return nil }
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
            engineLine
        }
    }

    /// The engine, named in the window, and the way into Connections. See `engineFooterText`.
    private var engineLine: some View {
        HStack(spacing: 8) {
            Text(engineFooterText(state.engine))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                // Selectable, because the whole point of it being on screen is that it can be pasted
                // into a bug report without anyone hunting through the About box for it.
                .textSelection(.enabled)
                .help("The DuckDB build Sift is reading your files with")
            Spacer(minLength: 4)
            connectionsButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 🔴 **In the window, not only in the menu bar.** Phase 0's survey found Merge, Export and
    /// Staged Data had all been buried in menus when the web build had them on screen, and this is
    /// the same mistake one step further along: a user who has never opened a remote source has no
    /// reason to go looking in a menu for a screen they do not know exists — and the engine's own
    /// refusals ("switch remote sources on in Data → Connections…, then relaunch Sift") name a place
    /// that, until this button and its menu item, did not exist anywhere in the product.
    ///
    /// It decides nothing: one `presentConnections()`, whose guard question is answered in
    /// `AppState` (there isn't one, deliberately — the state this screen has most to say in is the
    /// one a guard would refuse to open it in).
    private var connectionsButton: some View {
        Button { state.presentConnections() } label: {
            Label("Connections…", systemImage: SidebarSymbol.connections)
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Remote data: the master switch, and the connections Sift has saved")
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
            // The placeholder is the only place the URL route is advertised at all — the dropzone
            // above it can only ever mean a file, and `ConnectionsSheet.sasNote` already tells the
            // user to "paste the whole URL when you open it" about a box that, until now, would not
            // take one.
            TextField("…or paste a path or URL (⌥⌘C in Finder)", text: $pathText)
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
                HStack(spacing: 3) {
                    // 🔴 The glyph is LEADING, so it survives the `.tail` truncation the subtitle
                    // takes in a 220 pt sidebar. "This table came over the network" is the fact the
                    // row was missing entirely — the URL is in the tooltip, and a tooltip is not
                    // something anyone reads before they need it.
                    if offersRefresh(table) {
                        Image(systemName: SidebarSymbol.remote)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    // Orange the moment a row was thrown away reading this file. The count itself is
                    // in the tooltip and the bad-rows sheet; this is the part you see without asking.
                    Text(sourceSubtitle(table))
                        .font(.system(size: 11))
                        .foregroundStyle(
                            table.badRows > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // A small, honest sign of life while the background count is still running.
            if table.rowCount == nil {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14)
            }
            if offersRefresh(table) { refreshButton }
            exportButton
            closeButton
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(sourceTooltip(table))
        .contextMenu { menu }
    }

    /// 🔴 One export UI, and it is `ExportSheet`. This used to be a six-format `Menu` that opened an
    /// `NSSavePanel` and then wrote with `overwrite: true` unconditionally — a second, poorer export
    /// reached from the MORE discoverable of the two places: no format explanation, no "the only
    /// thing Sift ever writes" sentence, and a failure that closed the panel and bannered rather
    /// than staying open so the destination could be fixed without retyping it. `presentExport`
    /// names this row's table, so ⤓ on a row that is not the selected one still exports that row.
    private var exportButton: some View {
        Button { state.presentExport(table: table.name) } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help("Export…")
        .opacity(hovering ? 1 : 0)
    }

    /// ⟳, on remote rows only. The counterpart of the fetched-at line in the tooltip: one says when
    /// these bytes arrived, the other asks the server whether they are still current.
    ///
    /// It names this row's table rather than the selected one, exactly as ⤓ does — `presentExport`'s
    /// note explains why, and the same reasoning holds harder here: a refresh of the wrong table
    /// costs a download.
    private var refreshButton: some View {
        Button { Task { await state.refreshRemote(table.name) } } label: {
            Image(systemName: SidebarSymbol.refresh)
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .help("Check the source for new data")
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
        Button("Export…") { state.presentExport(table: table.name) }
        if offersRefresh(table) {
            Button("Refresh from Source") { Task { await state.refreshRemote(table.name) } }
        }
        // The other sheets of a workbook that is already open. For a remote one this is the only
        // route there is: the pre-open picker shells `/usr/bin/unzip` at a path, and a URL has no
        // local path until the bytes have been downloaded — which, by the time this row exists, they
        // have been. T10 made the second sheet cost zero downloads.
        if offersSheetChoice(table) {
            Button("Open Another Sheet…") { state.presentSheets(table: table.name) }
        }
        if table.staged {
            Button("Read from Source (unstage)") { stage(false) }
        } else if stageableFormat(table.spec.fmt) {
            Button("Stage This File") { stage(true) }
        }
        Divider()
        // The sanitized URL for a remote source, which is the string the user wants and the only one
        // they may have: `spec.key.path` IS `RemoteRef.url`, and no SAS token has ever been in it.
        Button("Copy Full Path") { copy(table.spec.key.path) }
        Button("Copy Table Name") { copy(table.name) }
        // Only for a row that has a file behind it. `selectFile` handed a URL — or a merge view's
        // `merge://a+b` — returns false and does nothing at all, which is a menu item that lies.
        // Same stat, and the same reasoning, as the proxy icon in `AppDelegate.applyChrome`.
        if FileManager.default.fileExists(atPath: table.spec.key.path) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(table.spec.key.path, inFileViewerRootedAtPath: "")
            }
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
