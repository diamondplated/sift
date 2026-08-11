import Foundation

/// Process-wide registry of the `SIFT_HOME` paths a live `Session` is holding, and which session
/// holds each.
///
/// Spec §13a: two `Database` handles on one file *in one process* are two independent DuckDB
/// instances that cannot see each other's catalog, so the second one's flush silently overwrites
/// the first one's. That is not lock contention — measured, there is no lock error in-process at
/// all, which is precisely why `Session`'s `sharedStore` fallback never fires for it and reports
/// `true` for both. The only thing that stops it is refusing the second open.
///
/// The value is a token, not a bool, because `release` is called from BOTH `shutdown()` and
/// `deinit` and those can straddle a legitimate hand-over: A shuts down, B claims the same home,
/// then A deallocates. A path-keyed release cannot tell that the entry it is about to remove now
/// belongs to B, so it would hand the home to a third session while B is still writing to it.
/// Comparing the token is what makes that case detectable.
///
/// `@unchecked Sendable` with an explicit lock rather than an actor: `Session.init` is a
/// synchronous throwing initializer and cannot `await`.
final class OpenHomes: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: UUID] = [:]

    /// `true` if `token` took ownership; `false` if someone else already holds `path`.
    func claim(_ path: String, token: UUID) -> Bool {
        lock.withLock {
            guard owners[path] == nil else { return false }
            owners[path] = token
            return true
        }
    }

    /// Release only a claim this token actually holds. Idempotent, and deliberately a no-op for a
    /// path now owned by someone else — see the type's doc comment for the sequence that makes
    /// that distinction load-bearing.
    func release(_ path: String, token: UUID) {
        lock.withLock {
            if owners[path] == token { owners[path] = nil }
        }
    }
}
