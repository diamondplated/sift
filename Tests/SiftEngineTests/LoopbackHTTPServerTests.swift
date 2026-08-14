import DuckDBKit
import Foundation
import Testing
import TestSupport
@testable import SiftEngine

// The oracle's own tests. Every later remote test asserts *how* DuckDB read a URL by reading
// `requestLog`, so a wrong log here would not fail — it would quietly agree with whatever the
// engine did. These pin the semantics through `URLSession` (cheap, offline, always runs) and then
// once through the real consumer, `httpfs`, behind the same `SIFT_REMOTE_FACTS=1` gate the other
// remote-facts tests use.
//
// Nothing here is `.serialized`: each test owns its own server on its own ephemeral port.

private let remoteFacts = ProcessInfo.processInfo.environment["SIFT_REMOTE_FACTS"] == "1"

/// 100 bytes, each equal to its own offset — so a range assertion can name the bytes it expects.
private let counting = Data((0..<100).map { UInt8($0) })

/// One request, on its own ephemeral session so nothing is cached, pooled or carried between
/// tests (a pooled keep-alive socket to a stopped server whose port has been recycled is a real
/// way to make a parallel suite flaky).
@discardableResult
private func fetch(
    _ url: String, method: String = "GET", range: String? = nil
) async throws -> (response: HTTPURLResponse, body: Data) {
    var request = URLRequest(url: try #require(URL(string: url)),
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.httpMethod = method
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (body, response) = try await session.data(for: request)
    return (try #require(response as? HTTPURLResponse), body)
}

// MARK: - GET, HEAD, and the plain cases

@Test func getWithoutARangeServesTheWholeBody() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)

    let (response, body) = try await fetch("\(server.baseURL)/data.bin")
    #expect(response.statusCode == 200)
    #expect(body == counting)
    #expect(response.value(forHTTPHeaderField: "Content-Length") == "100")
    #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    #expect(server.requestLog.map(\.status) == [200])
}

@Test func headReportsTheLengthAndTheRegisteredHeadersWithNoBody() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting,
                    headers: ["ETag": "\"abc123\"", "Last-Modified": "Wed, 13 Aug 2026 00:00:00 GMT"])

    let (response, _) = try await fetch("\(server.baseURL)/data.bin", method: "HEAD")
    #expect(response.statusCode == 200)
    // It must report the length a GET would return: httpfs sizes the object from this.
    #expect(response.value(forHTTPHeaderField: "Content-Length") == "100")
    #expect(response.value(forHTTPHeaderField: "ETag") == "\"abc123\"")
    #expect(response.value(forHTTPHeaderField: "Last-Modified") == "Wed, 13 Aug 2026 00:00:00 GMT")

    // The "no body" half is only checkable on the wire. MEASURED: `URLSession` hands back an
    // empty `Data` for a HEAD whatever the server actually wrote, so a server mutated to send
    // the body with a HEAD passed a `body.isEmpty` assertion here — a test guarding nothing.
    let client = try #require(rawConnection(port: server.port, seconds: 0, microseconds: 300_000))
    defer { close(client) }
    let request = Array("HEAD /data.bin HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    #expect(request.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
        == request.count)
    let wire = String(decoding: drain(client), as: UTF8.self)
    #expect(wire.contains("Content-Length: 100"))
    #expect(wire.hasSuffix("\r\n\r\n"),
            "a HEAD response ends at the header block: \(wire.debugDescription)")

    #expect(server.requestLog.map(\.method) == ["HEAD", "HEAD"])
}

@Test func unknownPathIs404AndAnUnsupportedMethodIs405() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)

    #expect(try await fetch("\(server.baseURL)/missing.bin").response.statusCode == 404)
    let post = try await fetch("\(server.baseURL)/data.bin", method: "POST")
    #expect(post.response.statusCode == 405)
    #expect(post.response.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
    // The method is refused on the request line alone, so an unsupported method beats a bad path.
    #expect(try await fetch("\(server.baseURL)/missing.bin", method: "DELETE")
        .response.statusCode == 405)
    #expect(server.requestLog.map(\.status) == [404, 405, 405])
}

// MARK: - Range

@Test func aRangedGetAnswers206WithTheRightContentRange() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)

    // start-end, open-ended, and suffix — the three forms RFC 9110 defines and httpfs sends.
    for (header, expected, bytes) in [("bytes=10-19", "bytes 10-19/100", 10..<20),
                                      ("bytes=90-", "bytes 90-99/100", 90..<100),
                                      ("bytes=-10", "bytes 90-99/100", 90..<100),
                                      ("bytes=0-0", "bytes 0-0/100", 0..<1)] {
        let (response, body) = try await fetch("\(server.baseURL)/data.bin", range: header)
        #expect(response.statusCode == 206, "\(header)")
        #expect(response.value(forHTTPHeaderField: "Content-Range") == expected, "\(header)")
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "\(bytes.count)", "\(header)")
        #expect(body == counting[bytes], "\(header)")
    }

    // An end past EOF is clamped, not refused — RFC 9110 §14.1.1, and what every origin does.
    let clamped = try await fetch("\(server.baseURL)/data.bin", range: "bytes=95-100000")
    #expect(clamped.response.statusCode == 206)
    #expect(clamped.response.value(forHTTPHeaderField: "Content-Range") == "bytes 95-99/100")
    #expect(clamped.body == counting[95..<100])

    #expect(server.requestLog.map(\.range)
        == ["bytes=10-19", "bytes=90-", "bytes=-10", "bytes=0-0", "bytes=95-100000"])
}

@Test func aRangeThatStartsPastTheEndOfTheFileIs416() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)
    server.register(path: "/empty.bin", body: Data())

    for (path, header) in [("/data.bin", "bytes=100-"), ("/data.bin", "bytes=200-300"),
                           ("/empty.bin", "bytes=0-0")] {
        let (response, body) = try await fetch("\(server.baseURL)\(path)", range: header)
        #expect(response.statusCode == 416, "\(path) \(header)")
        #expect(body.isEmpty)
    }
    #expect(try await fetch("\(server.baseURL)/data.bin", range: "bytes=200-300")
        .response.value(forHTTPHeaderField: "Content-Range") == "bytes */100")
}

@Test func aRangeThisServerCannotParseFallsThroughToTheWholeBody() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)

    // A real origin answers a Range it cannot use with a plain 200 rather than an error, and so
    // does this one: an unknown unit, a multi-range list, or nonsense.
    for header in ["items=0-9", "bytes=0-9,20-29", "bytes=abc-def", "gibberish"] {
        let (response, body) = try await fetch("\(server.baseURL)/data.bin", range: header)
        #expect(response.statusCode == 200, "\(header)")
        #expect(body == counting, "\(header)")
    }
}

@Test func aPathThatIgnoresRangeServes200AndTheWholeBody() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting, rangeMode: .ignore)

    // MEASURED (remote fact 7b): DuckDB handles this personality transparently and still gets the
    // right answer. It is the common CDN/proxy case, so tests have to be able to build one.
    let (response, body) = try await fetch("\(server.baseURL)/data.bin", range: "bytes=10-19")
    #expect(response.statusCode == 200)
    #expect(body == counting)
    #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "none")
    #expect(response.value(forHTTPHeaderField: "Content-Range") == nil)
    #expect(server.requestLog.map(\.range) == ["bytes=10-19"], "the header is still logged")
}

@Test func aPathThatRejectsRangeAlways416s() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting, rangeMode: .reject)

    // The fatal personality (remote fact 7b): 416 whether the range is satisfiable or not.
    for header in ["bytes=0-9", "bytes=999-1000"] {
        let (response, body) = try await fetch("\(server.baseURL)/data.bin", range: header)
        #expect(response.statusCode == 416, "\(header)")
        #expect(body.isEmpty)
    }
    // A request that asks for no range, and a HEAD, are still answered normally — a
    // range-refusing server is not a broken server.
    #expect(try await fetch("\(server.baseURL)/data.bin").response.statusCode == 200)
    #expect(try await fetch("\(server.baseURL)/data.bin", method: "HEAD")
        .response.value(forHTTPHeaderField: "Content-Length") == "100")
    #expect(server.requestLog.map(\.status) == [416, 416, 200, 200])
}

// MARK: - The registry and the log

@Test func unregisterTakesThePathAwayAndRegisteringAgainReplacesIt() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)
    #expect(try await fetch("\(server.baseURL)/data.bin").body == counting)

    server.register(path: "/data.bin", body: Data("second".utf8))
    #expect(try await fetch("\(server.baseURL)/data.bin").body == Data("second".utf8))

    server.unregister(path: "/data.bin")
    #expect(try await fetch("\(server.baseURL)/data.bin").response.statusCode == 404)
    // Unregistering something that was never there is a no-op, not a crash.
    server.unregister(path: "/never.bin")
    #expect(server.requestLog.map(\.status) == [200, 200, 404])
}

@Test func theRequestLogRecordsEveryRequestInOrder() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)
    #expect(server.requestLog.isEmpty)

    try await fetch("\(server.baseURL)/data.bin", method: "HEAD")
    try await fetch("\(server.baseURL)/data.bin")
    try await fetch("\(server.baseURL)/data.bin", range: "bytes=0-9")
    try await fetch("\(server.baseURL)/other.bin?ignored=1")

    let log = server.requestLog
    #expect(log.count == 4)
    #expect(log.map(\.method) == ["HEAD", "GET", "GET", "GET"])
    // The query string is trimmed off the logged path, so an assertion can name the object.
    #expect(log.map(\.path) == ["/data.bin", "/data.bin", "/data.bin", "/other.bin"])
    #expect(log.map(\.range) == [nil, nil, "bytes=0-9", nil])
    #expect(log.map(\.status) == [200, 200, 206, 404])
}

@Test func theRequestLogIsSafeToReadWhileTheServerIsServing() async throws {
    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/data.bin", body: counting)

    // 24 requests in flight while the log is read a few hundred times. Without the lock this is a
    // data race on an array that is being appended to from N handler threads — which a sanitizer
    // catches for certain and a plain run catches often (a torn read of `hits` crashes in
    // `Array`'s own retain). The exact final count is the part that always holds.
    await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<24 {
            group.addTask { try await fetch("\(server.baseURL)/data.bin") }
        }
        group.addTask {
            for _ in 0..<400 {
                for hit in server.requestLog { #expect(hit.status == 200 && hit.path == "/data.bin") }
            }
        }
        while let _ = try? await group.next() {}
    }
    #expect(server.requestLog.count == 24)
}

// MARK: - Many servers, and letting go of them

@Test func serversRunInParallelOnDistinctPorts() async throws {
    let servers = try (0..<4).map { _ in try LoopbackHTTPServer() }
    defer { for server in servers { server.stop() } }
    for (index, server) in servers.enumerated() {
        server.register(path: "/who", body: Data("server-\(index)".utf8))
    }
    #expect(Set(servers.map(\.port)).count == 4, "ephemeral ports must not collide")

    // Every server answers only for itself, and they answer concurrently.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, server) in servers.enumerated() {
            group.addTask {
                // Hoisted out of `#expect`: a macro argument is not checked for effects until it
                // expands, so a `try` that lives only inside one leaves the closure inferred
                // non-throwing and the build red.
                for _ in 0..<5 {
                    let body = try await fetch("\(server.baseURL)/who").body
                    #expect(body == Data("server-\(index)".utf8))
                }
            }
        }
        try await group.waitForAll()
    }
    for server in servers { #expect(server.requestLog.count == 5) }
}

@Test func stopLeavesNoSocketsBehind() throws {
    // 50 servers, started and stopped. Each holds one listening socket and one thread that only
    // exits when the socket is closed, so a `stop()` that fails to unblock `accept()` shows up
    // here as +50 descriptors and 50 parked threads. The slack is because the suite runs in
    // parallel — other tests are opening their own files while this counts — and 20 is well under
    // the 50 a total leak costs. `swift test --filter stopLeavesNoSockets` alone measures 0.
    func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
    let before = openDescriptors()
    for _ in 0..<50 {
        let server = try LoopbackHTTPServer()
        server.register(path: "/x", body: counting)
        server.stop()
        server.stop()   // idempotent: the second call must not wait, close twice, or hang
    }
    let after = openDescriptors()
    #expect(after - before < 20, "\(before) -> \(after) descriptors across 50 start/stop cycles")
}

@Test func stopReleasesAConnectionThatIsStillOpen() throws {
    let server = try LoopbackHTTPServer()
    server.register(path: "/x", body: counting)

    // A raw socket rather than URLSession, because the thing under test is what the *server* does
    // to a live keep-alive connection, and URLSession's pool hides it. The 2 s receive timeout is
    // what turns a hang into a failure: a `stop()` that does not shut its clients down leaves this
    // handler thread parked in recv() forever, and the test has to report that, not join it.
    let client = try #require(rawConnection(port: server.port))
    defer { close(client) }
    let request = Array("GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    #expect(request.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }
        == request.count)

    var buffer = [UInt8](repeating: 0, count: 4096)
    #expect(recv(client, &buffer, buffer.count, 0) > 0, "the response")

    server.stop()
    // Now the handler is parked in recv() waiting for a second request on a keep-alive connection.
    // stop() shuts it down, so this reads EOF (or a reset, if the timing puts unread bytes in the
    // server's buffer) rather than timing out with EAGAIN.
    let n = recv(client, &buffer, buffer.count, 0)
    #expect(n == 0 || (n < 0 && errno == ECONNRESET), "n=\(n) errno=\(errno)")
}

/// A connected client socket with a receive timeout, or nil. The timeout is what turns "the
/// server never answered" into a failure instead of a hung suite.
private func rawConnection(port: UInt16, seconds: Int = 2, microseconds: Int32 = 0) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var timeout = timeval(tv_sec: seconds, tv_usec: microseconds)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { close(fd); return nil }
    return fd
}

/// Everything the server writes before it goes quiet — the socket's receive timeout ends the
/// read, so this is only for a response the test expects to be complete.
private func drain(_ fd: Int32) -> Data {
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { return out }
        out.append(contentsOf: buffer[0..<n])
    }
}

// MARK: - The real consumer

/// The oracle's customer is `httpfs`, not `URLSession`, and this is the assertion style every
/// later remote test copies: run one statement, then read off the log *how* it was served.
///
/// GATED behind `SIFT_REMOTE_FACTS=1` for the same reason as the other remote-facts tests:
/// `loadExtensions` does LOAD→INSTALL→LOAD, so a machine without `httpfs` reaches for the network,
/// and the default `swift test` must stay offline.
///
///     SIFT_REMOTE_FACTS=1 swift test --filter remoteFact
@Test(.enabled(if: remoteFacts))
func remoteFactParquetReadThroughTheOracleIsRangedNotWholeObject() throws {
    let path = (TestTemp.dir("loopback-parquet") as NSString).appendingPathComponent("big.parquet")
    try Database.inMemory().connect().execute("""
        COPY (SELECT range AS id, 'name-' || range AS name, range % 97 AS m FROM range(500000))
        TO '\(path)' (FORMAT parquet)
        """)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))

    let server = try LoopbackHTTPServer()
    defer { server.stop() }
    server.register(path: "/big.parquet", body: bytes)

    let database = try Database.inMemory()
    database.loadExtensions(["httpfs"])
    try #require(database.loadedExtensions["httpfs"] == .loaded, "httpfs must be installed")
    let connection = try database.connect()
    // Everything here is on 127.0.0.1, so 5 s is generous — and it is the difference between a
    // broken environment failing in seconds and burning the shipped 30 s default through its
    // retries. MEASURED on the first CI canary: 244 s to report nothing. GLOBAL, not a bare SET,
    // because a bare SET is session-local whatever `duckdb_settings().scope` claims (fact 8).
    try connection.execute("SET GLOBAL http_timeout=5")

    #expect(try connection.query("SELECT count(*) FROM read_parquet('\(server.baseURL)/big.parquet')")
        .allRows()[0][0] == .int(500_000))

    // The verdict, read off the log: every GET was a 206 for a named byte range, and the bytes
    // asked for are a rounding error against the file — a `count(*)` answered from the footer
    // alone. A whole-object download would be one GET of `bytes=0-<size-1>`.
    let gets = server.requestLog.filter { $0.method == "GET" }
    #expect(!gets.isEmpty, "\(server.requestLog)")
    #expect(gets.allSatisfy { $0.status == 206 }, "\(server.requestLog)")
    let requested = gets.reduce(0) { $0 + span($1.range) }
    #expect(requested < bytes.count / 20,
            "footer only: \(requested) of \(bytes.count) B — \(server.requestLog)")
}

/// Bytes covered by a logged `bytes=start-end` header.
private func span(_ range: String?) -> Int {
    guard let range, range.hasPrefix("bytes=") else { return 0 }
    let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return 0 }
    return end - start + 1
}
