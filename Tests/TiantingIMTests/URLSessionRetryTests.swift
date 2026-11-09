#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// PRD-chat 21 item 16: does URLSession re-send a refresh by itself? It runs `URLSessionHttpTransport` against a real
/// socket on loopback and counts what arrives. Local results: `swift test` on macOS, HTTP/1.1 on loopback. HTTP/2 and
/// HTTP/3 behind a real gateway, and iOS itself, are not covered here.
final class ScriptedSocketServer: @unchecked Sendable {
    enum Reply {
        /// Answers and keeps the connection, so the client reuses it.
        case respond(String)
        /// Reads the request, then closes without a byte: a FIN, or an RST.
        case close, reset
        /// Reads the request and never answers.
        case silent
    }

    private let lock = NSLock()
    private var seen: [String] = []
    private var sockets: [Int32] = []
    private var closed = false
    private let listener: Int32
    let port: Int
    private let script: @Sendable (_ index: Int, _ firstLine: String) -> Reply

    init(script: @escaping @Sendable (_ index: Int, _ firstLine: String) -> Reply) throws {
        self.script = script
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw URLError(.cannotConnectToHost) }
        var got = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listener = fd
        port = Int(UInt16(bigEndian: got.sin_port))
        let accept = Thread { [self] in acceptLoop() }
        accept.start()
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// The request lines that arrived, in order.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func stop() {
        lock.lock()
        closed = true
        let open = sockets
        sockets = []
        lock.unlock()
        for s in open { shutdown(s, SHUT_RDWR); close(s) }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func acceptLoop() {
        while true {
            let s = Darwin.accept(listener, nil, nil)
            if s < 0 { return }
            lock.lock()
            if closed {
                lock.unlock()
                close(s)
                return
            }
            sockets.append(s)
            lock.unlock()
            let t = Thread { [self] in serve(s) }
            t.start()
        }
    }

    private func serve(_ s: Int32) {
        var buffer = Data()
        while true {
            guard let (line, rest) = readRequest(s, &buffer) else { return }
            buffer = rest
            lock.lock()
            let index = seen.count
            seen.append(line)
            lock.unlock()
            switch script(index, line) {
            case .respond(let text):
                _ = text.withCString { send(s, $0, strlen($0), 0) }
            case .close:
                shutdown(s, SHUT_RDWR)
                close(s)
                return
            case .reset:
                var l = linger(l_onoff: 1, l_linger: 0)
                setsockopt(s, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
                close(s)
                return
            case .silent:
                break
            }
        }
    }

    /// Reads one whole request: its first line, and whatever bytes follow it.
    private func readRequest(_ s: Int32, _ buffer: inout Data) -> (String, Data)? {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                var length = 0
                for l in head.split(separator: "\r\n") where l.lowercased().hasPrefix("content-length:") {
                    length = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length {
                    let after = buffer.index(end.upperBound, offsetBy: length)
                    return (String(head.split(separator: "\r\n")[0]), Data(buffer[after...]))
                }
            }
            let n = recv(s, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

private let okKeepAlive = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

@MainActor
final class URLSessionRetryTests: XCTestCase {
    private func transport(timeout: TimeInterval? = nil) -> URLSessionHttpTransport {
        let c = URLSessionHttpTransport.defaultConfiguration()
        if let timeout {
            c.timeoutIntervalForRequest = timeout
            c.timeoutIntervalForResource = timeout
        }
        return URLSessionHttpTransport(configuration: c)
    }

    private func post(_ srv: ScriptedSocketServer, _ path: String = REFRESH) -> HttpRequest {
        HttpRequest(
            method: .post, url: srv.baseURL + path, headers: ["Content-Type": "application/json"],
            body: Data("{\"refreshToken\":\"k1.s.1.n.m\"}".utf8))
    }

    /// Gives a re-send time to show up.
    private func waitForStragglers() async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
    }

    func testRefreshOnAFreshConnectionClosedWithoutAResponseIsSentOnce() async throws {
        let srv = try ScriptedSocketServer { _, _ in .close }
        defer { srv.stop() }
        do {
            _ = try await transport().request(post(srv))
            XCTFail("expected a failure")
        } catch {}
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.filter { $0.hasPrefix("POST") }.count, 1)
    }

    func testRefreshOnAReusedConnectionClosedWithoutAResponseIsNotResent() async throws {
        // The case URLSession does retry for idempotent methods: a keep-alive connection dying after the request went out.
        for last: ScriptedSocketServer.Reply in [.close, .reset] {
            let srv = try ScriptedSocketServer { i, _ in i == 0 ? .respond(okKeepAlive) : last }
            defer { srv.stop() }
            let t = transport()
            let first = try await t.request(post(srv))
            XCTAssertEqual(first.status, 200)
            do {
                _ = try await t.request(post(srv))
                XCTFail("expected a failure")
            } catch {}
            try await waitForStragglers()
            XCTAssertEqual(srv.requests.count, 2, "\(srv.requests)")
        }
    }

    func testControlIdempotentGetOnAReusedConnection() async throws {
        // Shows the harness sees a re-send when there is one: URLSession does re-send a GET here (3 requests for 2 GETs),
        // and the POST tests above would see that extra request line too.
        let srv = try ScriptedSocketServer { i, _ in i == 0 ? .respond(okKeepAlive) : (i == 1 ? .close : .respond(okKeepAlive)) }
        defer { srv.stop() }
        let t = transport()
        let get = HttpRequest(method: .get, url: srv.baseURL + "/v1/config")
        _ = try await t.request(get)
        _ = try? await t.request(get)
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.count, 3, "URLSession's behavior changed: re-check the POST tests")
    }

    // Problem S2 for the object store (FE-632): PUT and GET are idempotent, so URLSession may re-send them by itself.
    // `URLSessionObjectStoreTransport` uses a new session per request: a broken PUT arrives exactly once (a failed upload
    // is the SDK's to retry, from the start, F-FILE-01 rule 2). GETs are still re-sent by URLSession, see below.
    func testObjectStorePutIsSentOnceGetResendIsRecorded() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tt-put-\(UUID().uuidString)")
        try Data(repeating: 1, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for method in ["PUT", "GET"] {
            for last: ScriptedSocketServer.Reply in [.close, .reset] {
                let srv = try ScriptedSocketServer { i, _ in i == 0 ? .respond(okKeepAlive) : last }
                defer { srv.stop() }
                let t = URLSessionObjectStoreTransport()
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tt-get-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dest) }
                let url = srv.baseURL + "/chat/tmp/k?X-Amz-Signature=x"
                if method == "PUT" {
                    let first = try await t.put(url: url, headers: ["Content-Type": "image/jpeg"], file: file) { _ in }
                    XCTAssertEqual(first, 200)
                    do {
                        _ = try await t.put(url: url, headers: ["Content-Type": "image/jpeg"], file: file) { _ in }
                        XCTFail("expected a failure")
                    } catch {}
                } else {
                    let first = try await t.get(url: url, to: dest) { _, _ in }
                    XCTAssertEqual(first, 200)
                    do {
                        _ = try await t.get(url: url, to: dest) { _, _ in }
                        XCTFail("expected a failure")
                    } catch {}
                }
                try await waitForStragglers()
                if method == "PUT" {
                    XCTAssertEqual(srv.requests.filter { $0.hasPrefix(method) }.count, 2, "\(method) \(srv.requests)")
                } else {
                    // Measured (macOS, loopback, HTTP/1.1): even on a fresh connection URLSession re-sends a GET that
                    // got no response (4 request lines for the 2 GETs). Harmless for a download: read-only, the same
                    // short-lived presigned URL, and the SDK writes the file only after a 2xx. Recorded, not prevented.
                    XCTAssertGreaterThanOrEqual(srv.requests.filter { $0.hasPrefix(method) }.count, 2, "\(srv.requests)")
                }
            }
        }
    }

    func testRefreshThatTimesOutIsSentOnce() async throws {
        let srv = try ScriptedSocketServer { _, _ in .silent }
        defer { srv.stop() }
        do {
            _ = try await transport(timeout: 1).request(post(srv))
            XCTFail("expected a timeout")
        } catch {}
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.count, 1)
    }

    func testCancellingARefreshDoesNotResendIt() async throws {
        let srv = try ScriptedSocketServer { _, _ in .silent }
        defer { srv.stop() }
        let t = transport()
        let req = post(srv)
        let task = Task { try await t.request(req) }
        while srv.requests.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        _ = await task.result
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.count, 1)
    }

    func testRedirectIsNotFollowedSoBearerStaysHome() async throws {
        let target = try ScriptedSocketServer { _, _ in .respond(okKeepAlive) }
        defer { target.stop() }
        let moved = "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(target.baseURL)/stolen\r\nContent-Length: 0\r\n\r\n"
        let srv = try ScriptedSocketServer { _, _ in .respond(moved) }
        defer { srv.stop() }
        var req = post(srv)
        req.headers["Authorization"] = "Bearer SECRET"
        let r = try await transport().request(req)
        XCTAssertEqual(r.status, 307)
        try await waitForStragglers()
        XCTAssertEqual(target.requests, [])
    }

    // Measured with the default handling: 2 POSTs. So the challenge cancels: sent once, and a network error.
    func testChallengeOn401IsNotAnsweredWithAResend() async throws {
        let body = "{\"code\":4019,\"msg\":\"x\"}"
        let denied = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let srv = try ScriptedSocketServer { _, _ in .respond(denied) }
        defer { srv.stop() }
        do {
            _ = try await transport().request(post(srv))
            XCTFail("expected a failure")
        } catch {}
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.count, 1)
    }

    // A plain 401 without the header, which is what im-server sends: the body comes through and only one POST arrives.
    func testPlain401ComesThroughOnce() async throws {
        let body = "{\"code\":4019,\"msg\":\"x\"}"
        let denied = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let srv = try ScriptedSocketServer { _, _ in .respond(denied) }
        defer { srv.stop() }
        let r = try await transport().request(post(srv))
        XCTAssertEqual(r.status, 401)
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
        try await waitForStragglers()
        XCTAssertEqual(srv.requests.count, 1)
    }

    // OkHttp re-sends on these (K4 in frontend-chat.md); URLSession must not.
    func testStatusesOkHttpRetriesAreSentOnce() async throws {
        for head in ["503 Service Unavailable\r\nRetry-After: 0", "408 Request Timeout", "421 Misdirected Request", "429 Too Many Requests\r\nRetry-After: 0"] {
            let reply = "HTTP/1.1 \(head)\r\nContent-Length: 0\r\n\r\n"
            let srv = try ScriptedSocketServer { _, _ in .respond(reply) }
            defer { srv.stop() }
            _ = try? await transport().request(post(srv))
            try await waitForStragglers()
            XCTAssertEqual(srv.requests.count, 1, head)
        }
    }

    func testAccountClientOnARealSocketSendsOneRefreshPerAttempt() async throws {
        let srv = try ScriptedSocketServer { _, _ in .close }
        defer { srv.stop() }
        var o = AccountClientOptions(baseUrl: srv.baseURL)
        o.systemEvents = false
        o.random = { 0.5 }
        let clock = RealClockForTest()
        o.clock = clock
        let account = AccountClient(options: o)
        let now = clock.now()
        account.restore(
            AccountSession(
                mode: .account, userId: USER, accessToken: jwt("sid1", 1), accessExpiresAt: now + HOUR,
                refreshToken: refreshToken("sid1", 1), refreshExpiresAt: now + DAY, absoluteExpiresAt: now + 365 * DAY))
        account.foreground()
        try await Task.sleep(nanoseconds: 600_000_000)  // Under the 1-second backoff.
        XCTAssertEqual(srv.requests.count, 1, "\(srv.requests)")
        XCTAssertNotNil(account.session)
    }
}

@MainActor
private final class RealClockForTest: IMClock {
    private let inner = SystemClock()
    func now() -> Int64 { inner.now() }
    func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle { inner.setTimeout(ms, fn) }
    func clearTimeout(_ handle: TimerHandle) { inner.clearTimeout(handle) }
}
#endif
