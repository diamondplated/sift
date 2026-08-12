import SiftCore
import SiftEngine
import SwiftUI

// The banner stack — `renderBanners` (`web/index.html:1021-1042`), plus the three things the web
// build had no way to say: a staging job that died, a sorted view that does not reach the end of
// the file, and a block the pump could not fetch.
//
// Every sentence in here is a *function*, and the views below only place them. That is not
// ceremony: a banner is the app's entire notification channel (there is no SSE and no toast on this
// branch), a `View`'s body cannot be tested, and every one of these strings has a number or a plural
// in it.

/// The staging banner's sentence. `est_seconds || "?"` (`web/index.html:1023-1024`) — a job that has
/// not produced an estimate yet says so rather than claiming zero seconds.
///
/// Rounded to whole seconds, which the web did not do: `estSeconds` is a Double and "about 12.4s"
/// promises a precision the estimator does not have. No `NumberFormatter` — see `groupDigits`.
func stagingText(estSeconds: Double) -> String {
    let seconds = estSeconds > 0 ? String(Int(estSeconds.rounded())) : "?"
    return "Staging into native storage — the grid may be slower for about \(seconds)s."
}

/// The §13a truncation sentence: what the sorted view reaches, out of what is there, and the way
/// out. `Table.sortTruncated` is when to show it.
///
/// Both numbers group through `SiftCore.groupDigits`, on the string, so a count never round-trips
/// through a `Double` on its way to a comma.
func sortTruncationText(rows: Int) -> String {
    "Sorted view reaches the first \(groupDigits(String(sortMaterializeMax))) rows of "
        + "\(groupDigits(String(rows))). Clear the sort to page the rest."
}

/// The missing-extension warning and its fix line, or `nil` when everything loaded.
///
/// 🔴 **Sorted.** The web iterated `Object.entries`, which is insertion-ordered; this reads a Swift
/// `Dictionary`, whose order is not stable *between runs of the same process*. Unsorted, the same
/// two missing extensions would name themselves in a different order each launch, and the sentence
/// would look like it was describing a changing situation.
///
/// Returned as two pieces because the fix is drawn as a `.kbd` — monospaced, so `INSTALL excel` is
/// visibly a thing to paste rather than a thing to read.
func missingExtensionsBanner(_ extensions: [String: Bool]) -> (message: String, fix: String)? {
    let missing = extensions.filter { !$0.value }.keys.sorted()
    guard !missing.isEmpty else { return nil }
    return (
        "DuckDB extension\(missing.count > 1 ? "s" : "") unavailable: "
            + "\(missing.joined(separator: ", ")). Delta folders and .xlsx will be refused rather "
            + "than read incorrectly. Fix with one online run of",
        missing.map { "INSTALL \($0)" }.joined(separator: "; ")
    )
}

// MARK: - the stack

/// Everything the app has to say about the active table, stacked above the grid.
///
/// Order is the web's, and it is a priority order rather than a chronological one: the job that is
/// running now, then the job that failed, then what the file itself needs said about it, then what
/// this *view* of the file cannot reach, then what the engine cannot do at all, and last the one
/// free-text error slot.
public struct BannerStack: View {
    private let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let table = state.active {
                tableBanners(table)
            }
            if let missing = missingExtensionsBanner(state.engine.extensions) {
                BannerRow(.warning) {
                    Text(missing.message)
                    Text(missing.fix)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        .textSelection(.enabled)
                }
            }
            // The one free-text slot: whatever the last user action threw. Dismissible because
            // nothing else clears it — it is not derived from any state that changes on its own.
            if let banner = state.banner {
                BannerRow(.error) {
                    Text(banner).textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button("Dismiss") { state.banner = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func tableBanners(_ table: SiftEngine.Table) -> some View {
        if let staging = table.staging {
            BannerRow(.warning) {
                Text(stagingText(estSeconds: staging.estSeconds))
                // Determinate, unlike the busy overlay's: a staging copy reports a real `pct`, and
                // this is the one place in the app where a progress *value* is not invented.
                ProgressView(value: staging.pct)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Spacer(minLength: 12)
                Button("Cancel") {
                    Task { await state.session.cancel(staging.jobID) }
                }
                .controlSize(.small)
            }
        }
        // A background copy that died has nowhere else to go: Python emitted an SSE error and there
        // is no SSE, so without this the table silently stays unstaged forever. A *cancelled* job
        // leaves this nil — the user asked for that one (see `Table.stagingError`).
        if let failure = table.stagingError {
            BannerRow(.warning) { Text(failure).textSelection(.enabled) }
        }
        // Indexed rather than `id: \.self`: two notes are just strings and a file that produced the
        // same note twice would collide into one row.
        ForEach(Array(table.notes.enumerated()), id: \.offset) { _, note in
            BannerRow(.info) { Text(note) }
        }
        if table.sortTruncated, let rows = table.displayRows {
            BannerRow(.warning) { Text(sortTruncationText(rows: rows)) }
        }
        if let model = state.model(for: table.name), let failure = model.pageError {
            BannerRow(.error) {
                Text(failure).textSelection(.enabled)
                Spacer(minLength: 12)
                Button("Dismiss") { model.pageError = nil }
            }
        }
    }
}

// MARK: - one banner

/// `.banner` (`web/index.html:315-319`): a rounded tinted strip, inset from the pane's edges.
///
/// The three tints are the same three the inspector's missing bars use — amber, azure, red — so a
/// colour means the same thing in both places.
enum BannerKind {
    case warning
    case info
    case error

    var ink: Color {
        switch self {
        case .warning: return .orange
        case .info: return .blue
        case .error: return .red
        }
    }
}

struct BannerRow<Content: View>: View {
    private let kind: BannerKind
    private let content: Content

    init(_ kind: BannerKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 9) { content }
            .font(.system(size: 11.5))
            .foregroundStyle(kind.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 10))
    }
}
