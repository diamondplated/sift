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

/// How long the copy will take, said as coarsely as the estimate deserves — or `nil` when there is
/// no estimate to say.
///
/// 🔴 **The estimate is a FLOOR, so this rounds UP and never down.** `SiftCore.shouldStage` computes
/// it as `sizeBytes / (250 MB/s)`, and that rate is its own comment's "measured CSV parse rate on an
/// M-series Mac" — i.e. an internal SSD, warm. A file on a spinning disk, an SMB share or any
/// network volume parses several times slower, so the number is the best case and nothing else.
/// `web/index.html:1023-1024` printed it to a tenth of a second ("about 12.4s"), which is a
/// precision claim the estimator cannot support; the first native port rounded to whole seconds,
/// which is the same claim one digit shorter. These steps are the honest resolution: a
/// 12.4-second guess and a 27-second guess are the same statement, and both of them are "half a
/// minute if the disk is slow".
///
/// Literal strings rather than a computed number of minutes, so no `NumberFormatter` is anywhere
/// near a sentence a user reads (see `groupDigits`).
func stagingDuration(estSeconds: Double) -> String? {
    guard estSeconds > 0 else { return nil }
    let steps: [(limit: Double, said: String)] = [
        (10, "10 seconds"), (30, "30 seconds"), (60, "a minute"), (120, "2 minutes"),
        (300, "5 minutes"), (600, "10 minutes"), (1800, "half an hour"),
    ]
    return steps.first { estSeconds <= $0.limit }?.said ?? "over half an hour"
}

/// The staging banner's sentence. A job that has not produced an estimate yet says so rather than
/// claiming a duration — the web's `est_seconds || "?"` said "about ?s", which reads as a broken
/// template rather than as "we do not know".
func stagingText(estSeconds: Double) -> String {
    let base = "Staging into native storage — the grid may be slower"
    guard let duration = stagingDuration(estSeconds: estSeconds) else { return base + " while it runs." }
    return base + " for about \(duration), longer on a slow or network disk."
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

// MARK: - the two escape hatches

/// The way out of a mis-sniffed file, for the note that names it.
///
/// `Session.openPath(nullPadding:skipPreamble:)` has had both since it was written and they are
/// ALTERNATIVES rather than options that combine (pinning `skip` is what defeats `null_padding` —
/// measured, and `openPath` throws on the pair), which is exactly the shape of an enum with two
/// cases rather than two booleans on a button.
public enum ReopenFix: Equatable, Sendable {
    /// `SiftCore.raggedCollapseNote` — the rows carry inconsistent field counts, so the sniffer
    /// settled on a delimiter the file does not contain and the whole file read as one column.
    case nullPadding
    /// `SiftCore.preambleNote` — the sniffer threw the file's own data away as a preamble and
    /// landed on a header matching no rows at all.
    case keepAllLines

    /// What the button says. The verb is the note's own: it ends "— re-open with null padding to
    /// see all 5" / "— re-open without skipping to see them", and a button that said something else
    /// would read as a second, different offer.
    public var title: String {
        switch self {
        case .nullPadding: return "Re-open with Null Padding"
        case .keepAllLines: return "Re-open Keeping All Lines"
        }
    }
}

/// Which fix this note is the note for, or `nil` for every other note.
///
/// 🔴 **Matched by REPRODUCING the note, not by reading words out of it.** `Table.notes` is a flat
/// `[String]`: the sheet note, the folder note, the Delta note and these two all arrive in the same
/// array with nothing on them to say which is which. So the only honest question is "is this string
/// the one `raggedCollapseNote` would produce for THIS table's spec", and the answer comes from
/// calling it. A `note.contains("null padding")` would fire on any future note that mentions the
/// phrase, would offer a null-padded re-open on a table whose spec never collapsed, and would stop
/// firing silently the day the sentence is reworded — which is precisely the failure that leaves an
/// instruction on screen with nothing behind it.
public func reopenFix(for note: String, spec: SourceSpec) -> ReopenFix? {
    if note == raggedCollapseNote(spec) { return .nullPadding }
    if note == preambleNote(spec) { return .keepAllLines }
    return nil
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
                // 🔴 Indeterminate, like the busy overlay's — and for the same reason, which this
                // banner spent its whole life claiming was not true of it. A determinate
                // `ProgressView(value: staging.pct)` stood here; `pct` was written once, as `0`,
                // and never again, so the bar rendered empty for the entire life of every job.
                // There is no number to put here (see `StagingProgress`), so there is no bar.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16)
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
            BannerRow(.info) {
                Text(note)
                // 🔴 The note ends by telling the user to re-open the file a particular way. This
                // is the first thing in the window that can actually do it — and it appears ONLY on
                // the note that names it, which is what `reopenFix` decides. A file with a sheet
                // note and a ragged note shows one button, beside the sentence it answers.
                if let fix = reopenFix(for: note, spec: table.spec) {
                    Spacer(minLength: 12)
                    Button(fix.title) { Task { await state.reopen(table, with: fix) } }
                        .controlSize(.small)
                }
            }
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
