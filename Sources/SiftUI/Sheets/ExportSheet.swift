import Foundation
import SiftCore
import SiftEngine
import SwiftUI

// Export. Ported from `showExport` (web/index.html:1376-1417).
//
// The engine's `export` is the only thing Sift ever writes, and Export.swift's header spells the
// three rules holding that trust boundary. NOTHING HERE MAY WEAKEN THEM: this sheet collects a
// destination string, a format KEY and a boolean, and hands all three to the engine. It builds no
// SQL, and it does not pre-check whether the destination exists — claiming the name IS the check
// (rule 3), and a check up here would only reintroduce the check-then-write race the engine went
// out of its way to close.
//
// 🔴 **`SiftEngine.exportFormats` is the authority on the keys, the order and the extensions.**
// It is a `public let [ExportFormat]` and it is ORDERED on purpose — both shipping menus list the
// six in exactly that order, and a `Dictionary` would shuffle them between launches. SiftUI adds
// the six display labels and NOTHING else; do not declare a second format table here.
//
// 🔴 `ExportFormat` is `Sendable, Equatable` but NOT `Hashable` or `Identifiable`, so the picker's
// selection binds to the `String` key and the `ForEach` is `id: \.key`. Tagging by the struct does
// not compile, and the error does not say why.

// MARK: - the six labels

/// The menu label for one export format key. The engine has no business owning these — see
/// CellGlyph.swift's header for which way each kind of string travels. Ported from the AppKit
/// sidebar's `exportFormats` (`shell/Sources/Sift/SidebarViewController.swift`).
///
/// The `default` is unreachable through the UI, which only ever iterates `exportFormats` — and
/// `everyFormatTheEngineOffersHasALabel` in SheetsTests is what keeps it that way when a seventh
/// format is added to the engine.
public func exportLabel(forKey key: String) -> String {
    switch key {
    case "parquet": return "Parquet (zstd)"
    case "csv": return "CSV"
    case "tsv": return "TSV"
    case "json": return "JSON (array)"
    case "ndjson": return "NDJSON (lines)"
    case "xlsx": return "Excel"
    default: return key
    }
}

// MARK: - the destination

/// `<source dir>/<table>_export.parquet` — the web's
/// `t.path.replace(/\/[^/]*$/, "") + "/" + t.table + "_export.parquet"`.
public func defaultExportDestination(sourcePath: String, table: String) -> String {
    let directory = (sourcePath as NSString).deletingLastPathComponent
    return (directory as NSString).appendingPathComponent("\(table)_export.parquet")
}

/// Swap the destination's trailing extension for the chosen format's. Ports the web's
/// `value.replace(/\.[a-z0-9]+$/i, "." + ext)`, including the part that looks like an oversight and
/// is not: a destination with no trailing extension is left ALONE rather than having one appended.
/// The user typed that, and silently renaming the file they named is not this sheet's call.
public func retargetExtension(_ dest: String, to ext: String) -> String {
    guard let dot = dest.lastIndex(of: ".") else { return dest }
    let suffix = dest[dest.index(after: dot)...]
    guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return dest }
    return dest[..<dot] + "." + ext
}

/// `Wrote 1.5 MB to /data/orders_export.parquet in 12.3 ms`.
///
/// `String(format: "%.1f")`, matching every other timing this branch prints (Verification.swift's
/// line renderer) and never a `NumberFormatter`.
public func exportToast(_ result: ExportResult) -> String {
    "Wrote \(humanBytes(result.bytes)) to \(result.dest) in "
        + String(format: "%.1f", result.milliseconds) + " ms"
}

// MARK: - the sheet

/// Write the current result to disk.
public struct ExportSheet: View {
    private let session: Session
    private let table: SiftEngine.Table
    private let onExported: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dest: String
    @State private var formatKey = "parquet"
    @State private var overwrite = false
    @State private var running = false
    @State private var error: String?

    /// `onExported` receives the toast sentence. The banner lives on `AppState`, which this sheet
    /// deliberately does not reach into — the presenting view owns that seam.
    public init(
        session: Session, table: SiftEngine.Table, onExported: @escaping (String) -> Void
    ) {
        self.session = session
        self.table = table
        self.onExported = onExported
        _dest = State(
            initialValue: defaultExportDestination(
                sourcePath: table.spec.key.path, table: table.name))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export current result").font(.system(size: 15, weight: .semibold))
            Text(
                """
                Writes what the grid is showing — filters, sort, or your SQL — using DuckDB's \
                COPY. The only thing Sift ever writes.
                """
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("destination", text: $dest)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            HStack {
                Picker("", selection: $formatKey) {
                    ForEach(exportFormats, id: \.key) { format in
                        Text(exportLabel(forKey: format.key)).tag(format.key)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: formatKey) { _, key in
                    guard let format = exportFormat(named: key) else { return }
                    dest = retargetExtension(dest, to: format.ext)
                }
                Toggle("overwrite if it exists", isOn: $overwrite).font(.system(size: 12))
                Spacer()
            }

            if let error {
                // One clean sentence from the engine, shown as itself. The sheet STAYS OPEN on a
                // failure (the web build's behaviour too) so the destination can be fixed and
                // retried without retyping it.
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || dest.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func run() async {
        running = true
        defer { running = false }
        do {
            let result = try await session.export(
                table.name, dest: dest, format: formatKey, overwrite: overwrite)
            onExported(exportToast(result))
            dismiss()
        } catch {
            // 🔴 `localizedDescription`, and the same in the other four sheets — they all used to
            // interpolate the error instead, while the other eleven files in `SiftUI` did not. For
            // `DuckDBError` the two differ: `description` is the full multi-line parser dump,
            // `errorDescription` is its first line capped at 400 characters. Inert today only
            // because `Session` wraps every DuckDB failure into a `SessionError` at its public
            // boundary — one missed throw site and the sheets print the dump while the banner
            // prints the sentence. That exact bug class was already fixed once at that boundary.
            self.error = error.localizedDescription
        }
    }
}
