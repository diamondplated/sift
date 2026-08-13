import Foundation
import SiftCore
import SiftEngine
import SwiftUI

// The workbook sheet picker. Ported from `maybeSheetPicker` (web/index.html:1511-1530).
//
// 🔴 **IT IS PRESENTED FOR EVERY WORKBOOK, WHATEVER ITS SHEET COUNT.** `window.siftOpenPaths` —
// the entry point the native shell actually calls, for an in-window drop, a Dock-icon drop, Finder
// "Open With" and File > Open alike — routes every matching path through `maybeSheetPicker`
// unconditionally (web/index.html:1536). Only the browser-only `openPath` used it as a
// failure fallback (:1507). Shortcutting a single-sheet workbook straight to open would be a nicer
// flow, and is deliberately NOT done here: this is a parity release, and a one-sheet picker is a
// visible behaviour change, not an implementation detail.

// Which paths go through this picker is `AppState.needsSheetPicker` and lives there, beside the
// `open(paths:)` that routes on it. The byte-identical `offersSheetPicker` that used to sit here had
// no production caller and its own six-case test in another file — see that function's note.

/// `1,204 × 7`, or `empty`. `cols` is ungrouped, matching the web's `${fmtInt(s.rows)} × ${s.cols}`
/// — a workbook with a thousand columns is not the case worth a separator.
public func sheetRowLabel(_ info: SheetInfo) -> String {
    info.empty ? "empty" : "\(groupDigits(String(info.rows))) × \(info.cols)"
}

/// Everything with something in it, in workbook order. An empty sheet is listed and disabled, not
/// hidden: it is a sheet the user knows exists, and silently dropping it reads as a bug.
public func defaultSheetSelection(_ sheets: [SheetInfo]) -> [String] {
    sheets.filter { !$0.empty }.map(\.name)
}

/// `3 sheets — pick what to open.` Always plural, matching the web's `${d.sheets.length} sheets`
/// — including the "1 sheets" a single-sheet workbook produces. Parity, stated so it is a choice.
public func sheetPickerSubtitle(count: Int) -> String { "\(count) sheets — pick what to open." }

// MARK: - the sheet

/// Which sheets of this workbook to open.
public struct SheetPickerSheet: View {
    private let path: String
    private let onOpen: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sheets: [SheetInfo] = []
    @State private var picked: Set<String> = []
    @State private var loaded = false
    @State private var error: String?

    /// `onOpen` receives the chosen sheet names in workbook order. The presenting view opens each
    /// in turn — it owns the catalog, and this sheet does not reach into it.
    public init(path: String, onOpen: @escaping ([String]) -> Void) {
        self.path = path
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((path as NSString).lastPathComponent).font(.system(size: 15, weight: .semibold))

            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(sheetPickerSubtitle(count: sheets.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sheets, id: \.name) { sheet in
                            HStack(spacing: 6) {
                                Toggle(
                                    sheet.name,
                                    isOn: Binding(
                                        get: { picked.contains(sheet.name) },
                                        set: { on in
                                            if on { picked.insert(sheet.name) }
                                            else { picked.remove(sheet.name) }
                                        })
                                )
                                .font(.system(size: 12))
                                .disabled(sheet.empty)
                                Text(sheetRowLabel(sheet))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    onOpen(sheets.map(\.name).filter { picked.contains($0) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .task { await load() }
    }

    private func load() async {
        do {
            // Detached: `listSheets` shells out to `/usr/bin/unzip` once per worksheet and blocks
            // on the pipe. On the MainActor that is the window freezing for the length of a
            // workbook scan.
            let found = try await Task.detached { [path] in try listSheets(path: path) }.value
            sheets = found
            picked = Set(defaultSheetSelection(found))
        } catch {
            // `listSheets` refuses loudly rather than reporting 0×0 for a worksheet it could not
            // read, and its sentence is the one the user needs. Passed through as itself.
            self.error = "\(error)"
        }
        loaded = true
    }
}
