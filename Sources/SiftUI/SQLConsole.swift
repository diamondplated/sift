import SiftEngine
import SwiftUI

// The SQL box: a monospaced editor on a dark console, a status line, `Run ⌘↵` and
// `Reset to filters`. `.sqlwrap` / `.sqlbar` (`web/index.html:148-155, 359-367`).
//
// 🔴 **THIS FILE CONTAINS NO SQL AND NO VALIDATION, AND THAT IS THE POINT.** SQL mode is the one
// place a user's own text reaches the database. The SELECT-only gate is `SiftEngine`'s
// (`assertSelectOnly`, run first by `Session.runSQL` and again by `export` on the stored text), and
// it has been attacked hard and holds: multi-statement text, a leading COPY/ATTACH/INSTALL/CREATE,
// comment-hidden second statements, paren and format-string breakouts, embedded nulls and quote
// injection in paths and table names all refuse, with nothing written outside the destination. The
// enforcement underneath the message is grammar-level — `wrapUserSQL`'s newline subquery wrap, in
// which a non-SELECT cannot occupy a subquery position.
//
// So this view does exactly three things with the user's text: show it, hand it unmodified to
// `TableViewModel.runSQL()`, and show whatever sentence comes back. It adds no keyword check of its
// own (a second, weaker gate in the UI is how a blocklist becomes the thing people trust), it does
// not pre-validate and then send something else, and it does not `try?` an engine error away or
// re-word it — the guard reports one clean sentence and this project has broken that contract four
// times already.
//
// One consequence worth stating because it reads like a bug: `SELECT * FROM nonexistent` is NOT
// refused here. It fails to *prepare*, which is a query-path error about a table the user has not
// opened, not a guard rejection (GuardStatements.swift's landmine note). The engine lets it
// through and reports the catalog error; so does this.

/// The console's status line, which is also the one-way-door warning.
///
/// Two states and no third — `web/index.html:1762, 1770`, verbatim. `owned` is
/// `TableViewModel.sqlOwned`: the user has typed in the box, so the filters and the header controls
/// no longer describe what the grid is showing, and nothing will try to parse their SQL back into
/// filters to make them again. `Reset to filters` is the only way back, and this sentence is what
/// tells them before they find out.
public func sqlStatusText(owned: Bool) -> String {
    owned ? "your SQL — filters and header controls are frozen" : "mirrors the filters above"
}

/// The SQL box for one open table.
public struct SQLConsole: View {
    private let model: TableViewModel
    private let onError: (String) -> Void

    public init(model: TableViewModel, onError: @escaping (String) -> Void) {
        self.model = model
        self.onError = onError
    }

    // `--console-bg` / `--console-ink` (`web/index.html:12`). Dark in both appearances on purpose:
    // the console is not a document surface, and the web build gives it the same two colours under
    // `prefers-color-scheme: light` and `dark` alike. Computed rather than module-level `let`s —
    // a global of a type whose `Sendable` conformance moves between SDKs is a hard error in Swift 6
    // mode, and `gutterFont` already pays for that lesson one file over.
    private var consoleBackground: Color { Color(red: 0x1a / 255, green: 0x23 / 255, blue: 0x2b / 255) }
    private var consoleInk: Color { Color(red: 0xb9 / 255, green: 0xc9 / 255, blue: 0xd4 / 255) }

    /// Routed through `typeSQL` rather than binding `sqlText` directly: the setter is what claims
    /// the box, and the model's mirror must be able to write the same property without claiming it.
    private var text: Binding<String> {
        Binding(get: { model.sqlText }, set: { model.typeSQL($0) })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: text)
                // `.sqlwrap textarea`: 11.5 px monospace, 9/11 padding, 76 px minimum.
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(consoleInk)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
                .frame(minHeight: 76)

            HStack(spacing: 8) {
                Text(sqlStatusText(owned: model.sqlOwned))
                    .font(.system(size: 11, weight: model.sqlOwned ? .bold : .regular))
                    .foregroundStyle(model.sqlOwned ? Color.accentColor : consoleInk.opacity(0.65))
                    // The one-way-door warning is the whole reason the line exists; an elided one
                    // stops being a warning. `.sqlbar .own`, plus a line that never truncates.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Reset to filters") {
                    Task { await report { try await model.exitSQLMode() } }
                }
                Button {
                    Task { await report { try await model.runSQL() } }
                } label: {
                    // "Run ⌘↵" — the shortcut is spelled out because it is the only way to run
                    // without leaving the editor, and `.keyboardShortcut` draws nothing itself.
                    Text("Run \u{2318}\u{21A9}")
                }
                // 🔴 On the BUTTON, not on the editor. A `TextEditor` swallows Return, and there is
                // no key handler to hang ⌘↵ off; a button's shortcut is dispatched by the window
                // regardless of what holds focus, which is what makes ⌘↵ work while the user is
                // still typing — `$("sqlbox").keydown` (`web/index.html:1773-1775`).
                .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            .overlay(alignment: .top) { Divider().opacity(0.35) }
        }
        .background(consoleBackground)
        // 🔴 **The console is a dark REGION, not a dark rectangle.** MEASURED, light appearance:
        // `Reset to filters` and `Run ⌘↵` rendered at a contrast ratio of **1.03** against the
        // console — a dark bezel and near-black label on a near-black panel, invisible. The panel is
        // deliberately dark in both appearances (see `consoleBackground`), but every control inside
        // it was still resolving `.aqua`, so it drew light-mode chrome onto a dark-mode surface.
        // In dark appearance the same two buttons measure 9.52. Declaring the subtree dark makes the
        // controls, the divider and the editor's caret and selection resolve against the surface
        // they are actually on; both appearances now measure the same, because the console IS the
        // same in both.
        .environment(\.colorScheme, .dark)
        // `id:` so switching tabs re-mirrors against the newly selected table, and the error is
        // surfaced rather than swallowed — `RootView`'s own `.task(id:)` makes the same call.
        .task(id: model.name) {
            await report { try await model.mirrorRenderedSQL() }
        }
    }

    /// Whatever the engine threw, as its own sentence. Not re-worded, not summarised, not
    /// swallowed: `SessionError`/`SQLRejected` are already one clean user-facing sentence each, and
    /// every layer that has tried to improve on them here has made them worse.
    private func report(_ work: () async throws -> Void) async {
        do { try await work() } catch { onError(error.localizedDescription) }
    }
}
