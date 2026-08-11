import Foundation

/// The one place any test is allowed to name a path on disk.
///
/// **Why a per-process root rather than a `defer` per test.** Every test directory used to be
/// created straight under `FileManager.default.temporaryDirectory` and never removed. MEASURED on
/// 2026-08-11: 55,375 orphaned directories, 22 GB, on a volume with 1.2 GB free — an unrelated
/// `grep` died of `ENOSPC` mid-task. 38 distinct name prefixes across every engine test file, so
/// the failure was systemic and a per-call-site `defer` would only be the same omission waiting to
/// be repeated by the next test written.
///
/// Three properties the suite actually needs, and why `defer` gives none of them:
///
///  1. **Parallel.** Swift Testing runs tests concurrently and nothing here is `.serialized`. Every
///     path handed out carries a fresh UUID, so two tests can never share or race one.
///  2. **Failure and early exit.** Most of the leak came from bodies that threw before their
///     cleanup line. Nothing here is tied to a test body at all: the root is removed by an `atexit`
///     handler, which runs whether the suite passed, failed, or bailed out early.
///  3. **Live `Session`s.** A `Session` holds an open DuckDB store inside its home directory, and
///     `DuckDBKit.Database` exposes no `close()` — the handle is released by ARC, and the detached
///     post-open pipeline (`_after_open`) can outlive the test body that started it. A
///     `defer { removeItem(home) }` therefore deletes the store out from under a live engine. The
///     root is removed once, after every test has reported, so the ordering question does not
///     arise. `Session.shutdown()`/`dropPrivateStore()` stay what they always were — the private
///     fallback store's own cleanup — and are unaffected by this.
///
/// **Opt-out:** `SIFT_KEEP_TEST_TEMP=1` keeps the root and prints its path, for when you are
/// looking at *why* something failed. The default is to delete, which is the safe direction: the
/// bug this exists for is disk that never comes back.
public enum TestTemp {
    /// `<tmp>/sift-tests-<pid>-<uuid>`. Created on first use, removed at process exit.
    public static let root: String = makeRoot()

    /// A unique path under `root` that is **not** created. For a `Session` home (`Session.init`
    /// creates it, at 0700) or any file a test is about to write itself.
    public static func path(_ label: String, _ suffix: String = "") -> String {
        (root as NSString).appendingPathComponent("\(label)-\(UUID().uuidString)\(suffix)")
    }

    /// A unique, freshly created directory under `root`.
    public static func dir(_ label: String) -> String {
        let path = path(label)
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            // Not an `Issue.record`: a temp directory that cannot be created is not one test's
            // failure, it is the disk being full — which is the very thing this file exists to
            // stop causing, and the run should say so loudly rather than 400 times.
            fatalError("could not create \(path): \(error)")
        }
        return path
    }
}

/// Read only by the `atexit` handler below, written once inside `makeRoot`'s `swift_once`. The
/// handler must convert to `@convention(c)`, which forbids captures — hence a global rather than a
/// closed-over local.
private nonisolated(unsafe) var rootToRemove: String?

private let rootPrefix = "sift-tests-"

private func makeRoot() -> String {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
    sweepDeadRoots(base)

    let path = base.appendingPathComponent(
        "\(rootPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
    ).path
    do {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    } catch {
        fatalError("could not create the test temp root \(path): \(error)")
    }

    if ProcessInfo.processInfo.environment["SIFT_KEEP_TEST_TEMP"] == "1" {
        FileHandle.standardError.write(
            Data("SIFT_KEEP_TEST_TEMP=1 — keeping \(path)\n".utf8))
    } else {
        rootToRemove = path
        atexit {
            if let path = rootToRemove { try? FileManager.default.removeItem(atPath: path) }
        }
    }
    return path
}

/// Roots left behind by a run that died on a signal, where `atexit` never got to run. The same
/// `kill(pid, 0)` liveness probe `Session.sweepPrivateStores` uses: it sends no signal, it only
/// asks whether the owner still exists (`ESRCH` vs success/`EPERM`). A concurrent `swift test` in
/// another process is therefore never touched.
private func sweepDeadRoots(_ base: URL) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
    for name in names where name.hasPrefix(rootPrefix) {
        let rest = name.dropFirst(rootPrefix.count)
        guard let dash = rest.firstIndex(of: "-"), let pid = Int32(rest[..<dash]), pid > 0 else {
            continue
        }
        if kill(pid, 0) == 0 { continue }   // still running: someone else's root
        if errno == ESRCH {
            try? FileManager.default.removeItem(atPath: base.appendingPathComponent(name).path)
        }
        // EPERM: alive, owned by another user. Leave it alone.
    }
}
