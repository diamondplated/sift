import Foundation

/// A small HTTP/1.1 origin server on `127.0.0.1`, and the oracle every remote test reads its
/// verdict from: register bytes at a path, point DuckDB (or `URLSession`) at
/// `http://127.0.0.1:<port>/<path>`, then assert from `requestLog` *how* those bytes were
/// fetched — ranged or whole-object, one request or four. The log is the whole point; the bytes
/// coming back right is the easy half.
///
/// It ships in `SiftEngine` rather than `Tests/TestSupport` because `--verify` needs it too. It
/// binds the loopback address and nothing else — `INADDR_LOOPBACK` is not a wildcard bind, so
/// nothing off this machine can reach it — and it is only ever started by a test or by `--verify`.
///
/// Two things about its shape are MEASURED, not preference, and both cost a CI cycle to learn
/// (`docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md`):
///
///  1. **Darwin sockets, not `Network.framework`.** On this Mac (macOS 26 / Darwin 25.3) every
///     `NWListener` configuration — `on: .any`, an explicit port, with and without
///     `requiredLocalEndpoint`, compiled and interpreted — fails with
///     `POSIXErrorCode(22): Invalid argument`, while a plain `bind()` on the same port succeeds
///     immediately. Do not "modernize" this back.
///  2. **Real threads, not `DispatchQueue.global()`.** With the accept loop on the global
///     concurrent queue, every server-backed test on the macos-15 runner timed out with an EMPTY
///     request log — thirteen parallel tests, thirteen pool threads each blocked in a
///     `accept()`, 244 s to report nothing. And `accept` returning `EINTR` is a retry, not a
///     failure: treating it as fatal killed the listener permanently.
///
/// The listener thread holds a strong reference back, so a server that is never `stop()`ped never
/// deallocates and its port stays bound. Every user pairs construction with `defer { stop() }`.
///
/// ponytail: a test oracle, not a web server — no routing, no MIME table, no chunked encoding, no
/// request bodies (a `POST` is answered 405 and whatever followed its headers is not drained).
public final class LoopbackHTTPServer: @unchecked Sendable {

    /// How one registered path treats a `Range` header. Both non-default personalities are real
    /// servers Sift will meet, and both are MEASURED against DuckDB (remote fact 7b): a server
    /// that *ignores* ranges is handled transparently and returns the right answer, while a server
    /// that *refuses* them is fatal after 1 + `http_retries` attempts. Tests need to simulate each.
    public enum RangeMode: Sendable {
        /// 206 + `Content-Range`, `Accept-Ranges: bytes`. What an origin that supports ranges does.
        case honor
        /// 200 + the whole body, `Accept-Ranges: none`. The common CDN/proxy case.
        case ignore
        /// 416 to every request carrying a `Range`, satisfiable or not. The fatal case.
        case reject
    }

    private typealias Hit = (method: String, path: String, range: String?, status: Int)

    private struct Resource {
        let body: Data
        let headers: [String: String]
        let mode: RangeMode
    }

    /// The listening socket. Opened here, closed by the accept loop and by nobody else — see
    /// `stop()` for why that ownership rule is load-bearing.
    private let fd: Int32
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var resources: [String: Resource] = [:]
    private var hits: [Hit] = []
    private var clients: Set<Int32> = []
    private var stopped = false

    /// The ephemeral port the kernel handed out. Distinct per server, so servers are parallel-safe.
    public let port: UInt16

    /// `http://127.0.0.1:<port>` — the prefix every registered path hangs off.
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Every request received, in order: method, path, the `Range` header if the client sent one,
    /// and the status answered. Safe to read while the server is serving.
    public var requestLog: [(method: String, path: String, range: String?, status: Int)] {
        lock.withLock { hits }
    }

    public init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SessionError("could not create a loopback socket (errno \(errno))")
        }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = Self.loopback(port: 0)   // port 0: the kernel picks a free one
        let bound = Self.withAddress(&addr) { bind(sock, $0, $1) }
        guard bound == 0, listen(sock, 64) == 0 else {
            let failure = errno
            close(sock)
            throw SessionError("could not bind a loopback port (errno \(failure))")
        }

        var me = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        fd = sock
        port = UInt16(bigEndian: me.sin_port)

        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Serve `body` at `path` (`"/data.parquet"`), answering `headers` — `ETag`, `Last-Modified`,
    /// anything a test needs to see come back — on every response for that path. Registering the
    /// same path again replaces it.
    public func register(
        path: String, body: Data, headers: [String: String] = [:], rangeMode: RangeMode = .honor
    ) {
        // `Data(body)` re-bases the slice: a `Data` carved out of another one keeps the parent's
        // indices, and every read below slices from 0.
        lock.withLock {
            resources[path] = Resource(body: Data(body), headers: headers, mode: rangeMode)
        }
    }

    /// Take a path away — subsequent requests for it are 404.
    public func unregister(path: String) {
        lock.withLock { resources[path] = nil }
    }

    /// Stop serving and release the socket and every thread. Idempotent, and safe to call while
    /// requests are in flight.
    ///
    /// The listener is unblocked with a **real connection** rather than by closing the socket
    /// under it: `close()` on an fd another thread is blocked in `accept()` on does not reliably
    /// wake it, and the moment the number is freed the next socket in the process can be handed
    /// the same one — a stale `accept()` then serving somebody else's listener. So the accept loop
    /// owns `fd` and closes it itself, and the probe connection stays open until it has, or the
    /// connection could be reset out of the accept queue before it is ever picked up.
    ///
    /// Live client sockets get `shutdown()`, not `close()`, for the same reason: it wakes a
    /// handler parked in `recv()` without freeing a number the handler still holds.
    public func stop() {
        let victims: [Int32]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { clients.removeAll() }
            return Array(clients)
        }
        guard let victims else { return }
        for client in victims { shutdown(client, SHUT_RDWR) }

        let probe = socket(AF_INET, SOCK_STREAM, 0)
        if probe >= 0 {
            var addr = Self.loopback(port: port)
            _ = Self.withAddress(&addr) { connect(probe, $0, $1) }
        }
        // A listener that already died of a socket error has signalled this long ago; a wait that
        // times out means a leak, which `stopLeavesNoSocketsBehind` is the detector for.
        _ = finished.wait(timeout: .now() + 5)
        if probe >= 0 { close(probe) }
    }

    // MARK: - Accepting

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            // `stopped` is checked before the error is, because the wake-up connection can be
            // reported as ECONNABORTED rather than as a client — and ECONNABORTED is otherwise a
            // `continue`, which would put this thread straight back into a permanent `accept()`.
            if lock.withLock({ stopped }) {
                if client >= 0 { close(client) }
                break
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                break   // a genuinely dead socket, and only that, ends the loop
            }
            guard adopt(client) else { close(client); break }
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(fd)
        finished.signal()
    }

    /// Take ownership of a freshly accepted socket, unless `stop()` got there first. Adoption and
    /// the shutdown check share one critical section: without that, a connection accepted a moment
    /// before `stop()` could be registered a moment after it, and its handler would sit in `recv()`
    /// forever.
    private func adopt(_ client: Int32) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            clients.insert(client)
            return true
        }
    }

    private func serve(_ client: Int32) {
        defer {
            lock.withLock { _ = clients.remove(client) }
            close(client)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            // HTTP/1.1 keep-alive: one connection, as many request heads as the client sends.
            while let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                if !sendAll(client, response(to: head)) { return }
            }
            let n = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func sendAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    // MARK: - Answering

    private func response(to head: String) -> Data {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = request.first ?? "?"
        let path = request.count > 1 ? String(request[1].prefix { $0 != "?" }) : "/"
        let range = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        /// `Content-Length` is always the length of what a GET would return, so a HEAD passes the
        /// full body here and the body is dropped on the way out.
        func reply(_ status: Int, _ reason: String, _ headers: [String: String], _ body: Data) -> Data {
            lock.withLock { hits.append((method, path, range, status)) }
            var text = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                text += "\(name): \(value)\r\n"
            }
            return Data((text + "\r\n").utf8) + (method == "HEAD" ? Data() : body)
        }

        // The method is a property of the request line alone, so it is decided before the path is.
        guard method == "GET" || method == "HEAD" else {
            return reply(405, "Method Not Allowed", ["Allow": "GET, HEAD"], Data())
        }
        guard let resource = lock.withLock({ resources[path] }) else {
            return reply(404, "Not Found", [:], Data())
        }

        var headers = ["Accept-Ranges": resource.mode == .honor ? "bytes" : "none"]
        headers.merge(resource.headers) { _, registered in registered }   // a registration wins
        let total = resource.body.count
        func unsatisfiable() -> Data {
            headers["Content-Range"] = "bytes */\(total)"
            return reply(416, "Range Not Satisfiable", headers, Data())
        }

        // A HEAD reports the whole object whatever it carries: that is what httpfs asks for, and
        // what it sizes the file from.
        if method == "HEAD" { return reply(200, "OK", headers, resource.body) }

        guard let range, resource.mode != .ignore else {
            return reply(200, "OK", headers, resource.body)
        }
        guard resource.mode != .reject else { return unsatisfiable() }

        switch Self.resolve(range, count: total) {
        case .unparsed:
            return reply(200, "OK", headers, resource.body)
        case .unsatisfiable:
            return unsatisfiable()
        case .bytes(let start, let end):
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            return reply(206, "Partial Content", headers, Data(resource.body[start...end]))
        }
    }

    private enum RangeSpec { case bytes(Int, Int), unsatisfiable, unparsed }

    /// The three single-range forms of RFC 9110 §14.1.1 that Sift's consumers actually send:
    /// `bytes=start-end`, `bytes=start-` (to EOF) and `bytes=-suffix` (the last N bytes). Anything
    /// else — a unit that is not `bytes`, a multi-range list, garbage — is `.unparsed` and gets a
    /// plain 200, which is what a real origin does with a `Range` it cannot use.
    private static func resolve(_ header: String, count: Int) -> RangeSpec {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes="), !text.contains(",") else { return .unparsed }
        let parts = text.dropFirst("bytes=".count)
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .unparsed }

        if parts[0].isEmpty {                                       // bytes=-N — the last N bytes
            guard let suffix = Int(parts[1]), suffix > 0, count > 0 else { return .unsatisfiable }
            return .bytes(max(0, count - suffix), count - 1)
        }
        guard let start = Int(parts[0]), start >= 0 else { return .unparsed }
        guard start < count else { return .unsatisfiable }          // past EOF — and any empty body
        if parts[1].isEmpty { return .bytes(start, count - 1) }     // bytes=N- — through to EOF
        guard let end = Int(parts[1]), end >= start else { return .unsatisfiable }
        return .bytes(start, min(end, count - 1))
    }

    // MARK: - sockaddr plumbing

    private static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian    // 127.0.0.1 and nothing else
        return addr
    }

    private static func withAddress<T>(
        _ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
