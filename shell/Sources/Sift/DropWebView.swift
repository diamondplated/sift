import AppKit
import WebKit

/// A web view that intercepts file drops at the AppKit layer.
///
/// This is the single most important class in the shell, and the reason the native app exists at
/// all. An HTML5 drop inside the page yields a `File` object with **no filesystem path** — WebKit
/// withholds it deliberately. DuckDB needs a real path to read a file in place, so a page-level drop
/// would force copying multi-GB files before showing anything.
///
/// Overriding the `NSDraggingDestination` methods here means the drop never reaches the page, and we
/// hand JavaScript the real POSIX paths instead. The page checks `NATIVE` and disables its own drop
/// handling so the two can never both fire.
final class DropWebView: WKWebView {
    var onDrop: (([String]) -> Void)?
    var onDragHint: ((Bool) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func paths(from info: NSDraggingInfo) -> [String] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: opts) as? [URL] ?? []
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragHint?(!paths(from: sender).isEmpty)
        return paths(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return paths(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHint?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !paths(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHint?(false)
        let found = paths(from: sender)
        guard !found.isEmpty else { return false }
        onDrop?(found)
        return true
    }
}
