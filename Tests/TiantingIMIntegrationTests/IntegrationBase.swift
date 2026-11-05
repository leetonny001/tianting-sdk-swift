#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// Waits (polling on the main actor) until a condition holds; fails the test on timeout.
@MainActor
@discardableResult
func until<T>(
    _ what: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
    _ fn: () -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let v = fn() { return v }
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)", file: file, line: line)
            throw TestServerError("timed out waiting for \(what)")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
func untilTrue(
    _ what: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
    _ fn: () -> Bool
) async throws {
    try await until(what, timeout: timeout, file: file, line: line) { fn() ? true : nil }
}

func sleepMs(_ ms: UInt64) async throws {
    try await Task.sleep(nanoseconds: ms * 1_000_000)
}

/// Collects `fatal` and similar events for assertions.
@MainActor
final class EventLog {
    var fatal: [FatalReason] = []
    var removed: [(String, String?)] = []
    var settings: [SocialSettings] = []
    var groupChanged: [String] = []

    init(_ im: IMClient) {
        im.on { [weak self] e in
            switch e {
            case .fatal(let r): self?.fatal.append(r)
            case .convRemoved(let id, let reason): self?.removed.append((id, reason))
            case .socialSettings(let s): self?.settings.append(s)
            case .groupChanged(let id, _): self?.groupChanged.append(id)
            default: break
            }
        }
    }
}

@MainActor
class IntegrationCase: XCTestCase {
    nonisolated(unsafe) static var server: TestServer?
    var clients: [IMClient] = []

    var srv: TestServer { IntegrationCase.server! }

    /// One server per test class run: test ids are unique, so tests do not interfere.
    override func setUp() async throws {
        try await super.setUp()
        if IntegrationCase.server == nil {
            IntegrationCase.server = try await TestServer.start()
        }
    }

    override func tearDown() async throws {
        for c in clients { c.destroy() }
        clients = []
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func client(
        url: String? = nil,
        directory: URL? = nil,
        newId: (() -> String)? = nil,
        configure: (inout IMClientTimings) -> Void = { _ in }
    ) -> IMClient {
        var o = IMClientOptions(url: url ?? srv.wsURL)
        o.systemEvents = false
        o.databaseDirectory = directory
        o.newId = newId
        o.pushCursorStore = nil
        var t = IMClientTimings()
        t.backoffBaseMs = 50
        t.backoffMaxMs = 100
        configure(&t)
        o.timings = t
        let im = IMClient(options: o)
        clients.append(im)
        return im
    }

    func login(_ userId: String, _ im: IMClient? = nil, server: TestServer? = nil) async throws -> IMClient {
        let im = im ?? client()
        im.connect(token: try await (server ?? srv).token(userId))
        try await untilTrue("\(userId) connected") { im.state == .connected && im.userId == userId }
        return im
    }

    private static var seq = 0
    func uid(_ base: String) -> String {
        IntegrationCase.seq += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(IntegrationCase.seq)
    }

    func importUsers(_ users: [String], nicknames: [String: String] = [:]) async throws {
        try await srv.admin(
            "POST", "/admin/users/import",
            ["users": users.map { u -> [String: Any] in
                var o: [String: Any] = ["userId": u]
                if let n = nicknames[u] { o["nickname"] = n }
                return o
            }])
    }

    func hostedGroup(_ members: [String], name: String? = nil) async throws -> (groupId: String, convId: String) {
        let g = uid("g")
        try await importUsers(members)
        try await srv.admin("POST", "/admin/groups", ["groupId": g, "name": name ?? g, "members": members])
        return (g, groupConvId(g))
    }

    func conv(_ im: IMClient, _ convId: String) -> Conversation? {
        im.conversations().first { $0.convId == convId }
    }

    func sendOK(_ im: IMClient, _ convId: String, _ text: String) throws -> String {
        guard case .ok(let m) = try im.send(convId, text) else { throw TestServerError("send rejected") }
        return m.clientMsgId
    }

    func befriend(_ a: IMClient, _ aId: String, _ b: IMClient, _ bId: String) async throws {
        try await a.applyFriend(bId)
        try await untilTrue("request arrives") { b.friendRequests().items.contains { $0.userId == aId } }
        try await b.respondFriend(aId, .accept)
        try await untilTrue("friends") { a.relationOf(bId) == .friend }
    }

    func assertThrowsCode(
        _ code: Int, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? IMError)?.code, code, file: file, line: line)
        }
    }
}
#endif
