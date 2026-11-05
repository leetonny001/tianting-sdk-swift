#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// A real WebSocket that also records what was sent and can simulate a flash disconnect.
@MainActor
private final class SpyTransport: IMTransport {
    private let inner = WebSocketTransport()
    private var conn: TransportConnection?
    private var handlers: TransportHandlers?
    var sent: [JSONValue] = []
    var rawSent: [String] = []
    var urls: [String] = []

    func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        urls.append(url)
        let c = inner.open(url: url, handlers: handlers)
        conn = c
        self.handlers = handlers
        return Recording(inner: c, owner: self)
    }

    /// The server sees the connection end and the client sees a lost network. Closing from this side does not call back on
    /// its own, so the 1006 that a real drop would bring is delivered here.
    func flash() {
        conn?.close(code: 4000, reason: "flash")
        handlers?.onClose(1006, "flash")
    }

    var syncs: [JSONValue] {
        sent.filter { $0["cmd"]?.stringValue == "pushSync" }.compactMap { $0["data"] }
    }

    @MainActor
    private final class Recording: TransportConnection {
        let inner: TransportConnection
        weak var owner: SpyTransport?

        init(inner: TransportConnection, owner: SpyTransport) {
            self.inner = inner
            self.owner = owner
        }

        func send(_ text: String) {
            owner?.rawSent.append(text)
            if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { owner?.sent.append(v) }
            inner.send(text)
        }

        func close(code: Int, reason: String) {
            inner.close(code: code, reason: reason)
        }
    }
}

private final class Lines: IMLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func debug(_ message: String) { add(message) }
    func warn(_ message: String) { add(message) }
    func error(_ message: String) { add(message) }
    private func add(_ m: String) { lock.withLock { lines.append(m) } }
    var all: [String] { lock.withLock { lines } }
}

@MainActor
private final class Rig {
    let im: IMClient
    let transport = SpyTransport()
    let logs = Lines()
    var got: [Push] = []
    var synced: [Int64] = []

    init(url: String, store: PushCursorStore? = nil, platform: Platform = .ios, pushStart: PushStart = .beginning, database: URL? = nil) {
        var o = IMClientOptions(url: url)
        o.platform = platform
        o.systemEvents = false
        o.transport = transport
        o.logger = logs
        o.pushCursorStore = store
        o.pushStart = pushStart
        o.databaseDirectory = database
        var t = IMClientTimings()
        t.backoffBaseMs = 20
        t.backoffMaxMs = 50
        o.timings = t
        im = IMClient(options: o)
        im.onPush { [weak self] in self?.got.append($0) }
        im.onPushSynced { [weak self] in self?.synced.append($0) }
    }
}

/// System pushes against a real im-server with IM_PUSH_ENABLED=1: the same ground as sdk-ts test/integration/push.test.ts,
/// plus what only a native SDK has: the persistent cursor (PRD-live 4.9).
@MainActor
final class PushIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var server: TestServer?
    private var srv: TestServer { PushIntegrationTests.server! }
    private var rigs: [Rig] = []
    private var dir: URL!
    private static var n = 0

    override func setUp() async throws {
        try await super.setUp()
        if PushIntegrationTests.server == nil {
            PushIntegrationTests.server = try await TestServer.start(env: ["IM_PUSH_ENABLED": "1"])
        }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-push-it-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for r in rigs { r.im.destroy() }
        rigs = []
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func uid(_ base: String) -> String {
        Self.n += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Self.n)
    }

    private func rig(store: PushCursorStore? = nil, platform: Platform = .ios, pushStart: PushStart = .beginning, database: URL? = nil) -> Rig {
        let r = Rig(url: srv.wsURL, store: store, platform: platform, pushStart: pushStart, database: database)
        rigs.append(r)
        return r
    }

    private func ensureUsers(_ ids: String...) async throws {
        try await srv.admin("POST", "/admin/users/import", ["users": ids.map { ["userId": $0] }])
    }

    @discardableResult
    private func pushTo(_ userId: String, text: String? = nil, extra: [String: Any] = [:]) async throws -> String {
        let pushId = (extra["pushId"] as? String) ?? UUID().uuidString
        var body: [String: Any] = [
            "target": "user", "userIds": [userId], "type": "notice", "data": ["text": text ?? "t-\(pushId)"], "pushId": pushId,
        ]
        body.merge(extra) { _, new in new }
        try await srv.signed("POST", "/admin/push", body)
        return pushId
    }

    private func online(_ r: Rig, _ userId: String) async throws {
        r.im.connect(token: try await srv.token(userId))
        try await untilTrue("\(userId) connected") { r.im.state == .connected && r.im.userId == userId }
    }

    /// Logs in and waits for the first catch-up round to end.
    private func ready(_ r: Rig, _ userId: String) async throws {
        let before = r.synced.count
        await flush()
        try await online(r, userId)
        try await untilTrue("\(userId) first pushSynced") { r.synced.count > before }
    }

    private func flush() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testLiveDeliveryWithin3Seconds() async throws {
        // AC-PUSH-01-1
        let u = uid("live")
        try await ensureUsers(u)
        let r = rig()
        try await ready(r, u)
        XCTAssertEqual(r.synced, [0])
        let start = Date()
        let id = try await pushTo(u)
        let p = try await until("live push", timeout: 3) { r.got.first }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(p.pushId, id)
        XCTAssertEqual(p.type, "notice")
        XCTAssertEqual(p.data["text"]?.stringValue, "t-\(id)")
        XCTAssertEqual(p.target, "user")
        XCTAssertEqual(p.pushSeq, 1)
        XCTAssertFalse(p.replayed)
        XCTAssertEqual(r.im.pushCursor(), 1)
    }

    func testOfflinePushesCatchUpInOrderReplayed() async throws {
        let u = uid("off")
        try await ensureUsers(u)
        var ids: [String] = []
        for _ in 0..<3 { ids.append(try await pushTo(u)) }
        try await sleepMs(5)  // T0 strictly later than these.
        let r = rig()
        try await ready(r, u)
        XCTAssertEqual(r.got.map(\.pushId), ids)
        XCTAssertEqual(r.got.map(\.pushSeq), [1, 2, 3])
        XCTAssertTrue(r.got.allSatisfy(\.replayed))
        XCTAssertEqual(r.synced, [3])
        XCTAssertEqual(r.im.pushCursor(), 3)
        XCTAssertEqual(r.transport.syncs, [["afterSeq": 0, "limit": 100]])
    }

    func testPagesOf100AndNothingFromOtherUsers() async throws {
        // AC-PUSH-03-15, AC-PUSH-07-4
        let (u, other) = (uid("page"), uid("other"))
        try await ensureUsers(u, other)
        try await pushTo(other)
        var ids: [String] = []
        for _ in 0..<120 { ids.append(try await pushTo(u)) }
        let r = rig()
        try await ready(r, u)
        XCTAssertEqual(r.got.map(\.pushId), ids)
        XCTAssertEqual(r.transport.syncs, [["afterSeq": 0, "limit": 100], ["afterSeq": 100, "limit": 100]])
        XCTAssertEqual(r.synced, [120])
    }

    func testTtlZeroAndAllOnlyReachOnlineUsers() async throws {
        // AC-PUSH-03-5, AC-ADM-50-3
        let (on, off) = (uid("on"), uid("off"))
        try await ensureUsers(on, off)
        let r = rig()
        try await ready(r, on)
        let zero = try await pushTo(on, extra: ["ttlSeconds": 0])
        try await pushTo(off, extra: ["ttlSeconds": 0])
        let allId = UUID().uuidString
        try await srv.signed("POST", "/admin/push", ["target": "all", "type": "notice", "data": ["text": "all"], "pushId": allId])
        try await untilTrue("both online frames") { r.got.count == 2 }
        XCTAssertEqual(Set(r.got.map(\.pushId)), [zero, allId])
        XCTAssertTrue(r.got.allSatisfy { $0.pushSeq == nil && !$0.replayed })
        XCTAssertEqual(r.got.first { $0.pushId == allId }?.target, "all")
        XCTAssertEqual(r.im.pushCursor(), 0)

        let late = rig()
        try await ready(late, off)
        try await sleepMs(100)
        XCTAssertEqual(late.got.count, 0)
        XCTAssertEqual(late.synced, [0])
    }

    func testEachDeviceReceivesAndCatchesUpOnItsOwn() async throws {
        // AC-PUSH-07-1, AC-PUSH-07-2
        let u = uid("multi")
        try await ensureUsers(u)
        let (a, b) = (rig(platform: .ios), rig(platform: .web))
        try await ready(a, u)
        try await ready(b, u)
        let id = try await pushTo(u)
        try await untilTrue("both devices") { a.got.count == 1 && b.got.count == 1 }
        XCTAssertEqual(a.got[0].pushId, id)
        XCTAssertEqual(b.got[0].pushId, id)
        let c = rig(platform: .pc)
        try await ready(c, u)
        XCTAssertEqual(c.got.map(\.pushId), [id])
        try await sleepMs(100)
        XCTAssertEqual(a.got.count, 1)
    }

    func testSameInstanceOtherAccountWithoutPersistence() async throws {
        // AC-PUSH-07-3, 07-5, 07-6, in memory.
        let (u1, u2) = (uid("swap"), uid("swap"))
        try await ensureUsers(u1, u2)
        let id = UUID().uuidString
        try await srv.signed(
            "POST", "/admin/push",
            ["target": "user", "userIds": [u1, u2], "type": "notice", "data": ["text": "shared"], "pushId": id])
        let r = rig()
        try await ready(r, u1)
        XCTAssertEqual(r.got.map(\.pushId), [id])
        r.im.disconnect()
        XCTAssertNil(r.im.pushCursor())
        try await ready(r, u2)
        XCTAssertEqual(r.got.map(\.pushId), [id, id])
        r.im.disconnect()
        try await ready(r, u1)
        XCTAssertEqual(r.got.map(\.pushId), [id, id, id])
        XCTAssertEqual(r.got[2].replayed, true)
        XCTAssertEqual(r.transport.syncs.last, ["afterSeq": 0, "limit": 100])
    }

    func testPushStartLatest() async throws {
        // AC-PUSH-03-17
        let u = uid("latest")
        try await ensureUsers(u)
        try await pushTo(u)
        try await pushTo(u)
        let r = rig(pushStart: .latest)
        try await ready(r, u)
        XCTAssertEqual(r.got.count, 0)
        XCTAssertEqual(r.im.pushCursor(), 2)
        XCTAssertEqual(r.transport.syncs, [["fromLatest": true]])
        let id = try await pushTo(u)
        let p = try await until("next push") { r.got.first }
        XCTAssertEqual(p.pushId, id)
        XCTAssertEqual(p.pushSeq, 3)
        XCTAssertFalse(p.replayed)
    }

    func testFlashDisconnectCatchesUpNotReplayed() async throws {
        // Section 4.5 rule 4, AC-PUSH-08-1
        let u = uid("flash")
        try await ensureUsers(u)
        let r = rig()
        try await ready(r, u)
        let first = try await pushTo(u)
        try await untilTrue("first push") { r.got.count == 1 }
        r.transport.flash()
        try await untilTrue("down") { r.im.state != .connected }
        let a = try await pushTo(u)
        let b = try await pushTo(u)
        try await untilTrue("caught up") { r.got.count == 3 }
        XCTAssertEqual(r.got.map(\.pushId), [first, a, b])
        XCTAssertTrue(r.got.allSatisfy { !$0.replayed })
        XCTAssertEqual(r.im.pushCursor(), 3)
        XCTAssertEqual(r.transport.syncs.last, ["afterSeq": 1, "limit": 100])
        let c = try await pushTo(u)
        try await untilTrue("live after reconnect") { r.got.count == 4 }
        XCTAssertEqual(r.got[3].pushId, c)
        try await sleepMs(100)
        XCTAssertEqual(r.got.count, 4)
    }

    func testSkippedFrameIsFoundByTheGapAndDeliveredInOrder() async throws {
        // AC-PUSH-11-2
        let u = uid("gap")
        try await ensureUsers(u)
        let r = rig()
        try await ready(r, u)
        let lost = UUID().uuidString
        try await srv.admin("POST", "/admin/test/faults/push-skip-delivery", ["pushId": lost])
        try await pushTo(u, extra: ["pushId": lost])
        try await sleepMs(100)
        XCTAssertEqual(r.got.count, 0)
        let next = try await pushTo(u)
        try await untilTrue("catch-up") { r.got.count == 2 }
        XCTAssertEqual(r.got.map(\.pushId), [lost, next])
        XCTAssertEqual(r.im.pushCursor(), 2)
        XCTAssertEqual(r.transport.syncs.count, 2)
    }

    func testIdempotentReplayIsDeliveredOnce() async throws {
        let u = uid("idem")
        try await ensureUsers(u)
        let r = rig()
        try await ready(r, u)
        let id = UUID().uuidString
        let body: [String: Any] = ["target": "user", "userIds": [u], "type": "notice", "data": ["text": "x"], "pushId": id]
        let first = try await srv.signed("POST", "/admin/push", body)
        XCTAssertEqual(first["created"] as? Bool, true)
        let second = try await srv.signed("POST", "/admin/push", body)
        XCTAssertEqual(second["created"] as? Bool, false)
        try await untilTrue("delivered") { r.got.count == 1 }
        try await sleepMs(150)
        XCTAssertEqual(r.got.count, 1)
    }

    // MARK: The persistent cursor (AC-PUSH-03-16)

    func testFileCursorAcrossRestartLogoutAndKick() async throws {
        let u = uid("cur")
        try await ensureUsers(u)
        let store = FilePushCursorStore(directory: dir.appendingPathComponent("cursors"))
        let db = dir.appendingPathComponent("db")

        let a = rig(store: store, database: db)
        let p1 = try await pushTo(u)
        try await ready(a, u)
        XCTAssertEqual(a.got.map(\.pushId), [p1])
        let p2 = try await pushTo(u)
        try await untilTrue("live") { a.got.count == 2 }
        XCTAssertEqual(a.got[1].pushId, p2)
        XCTAssertEqual(try store.load(userId: u)?.cursor, 2)

        // A restart: a new instance, with one push arriving while the app was not running.
        a.im.close()
        let p3 = try await pushTo(u)
        try await sleepMs(5)
        let b = rig(store: store, database: db)
        try await ready(b, u)
        XCTAssertEqual(b.transport.syncs, [["afterSeq": 2, "limit": 100]])
        XCTAssertEqual(b.got.map(\.pushId), [p3], "only the new one, nothing replayed")
        XCTAssertEqual(b.got[0].replayed, true)

        // Logout deletes the database and keeps the cursor.
        b.im.disconnect()
        let c = rig(store: store, database: db)
        try await ready(c, u)
        XCTAssertEqual(c.transport.syncs, [["afterSeq": 3, "limit": 100]])
        XCTAssertEqual(c.got.count, 0)
        XCTAssertEqual(c.im.pushCursor(), 3)

        // A kick by a real ban, then a new login after the unban (AC-PUSH-03-14: pushes during the ban still arrive).
        try await srv.signed("POST", "/admin/users/\(u)/ban", ["durationSeconds": 86_400, "reason": "it"])
        try await untilTrue("kicked") { c.im.state == .disconnected }
        let p4 = try await pushTo(u)
        try await srv.signed("POST", "/admin/users/\(u)/unban", ["reason": "it"])
        let d = rig(store: store, database: db)
        try await ready(d, u)
        XCTAssertEqual(d.transport.syncs, [["afterSeq": 3, "limit": 100]])
        XCTAssertEqual(d.got.map(\.pushId), [p4])
    }

    func testAccountsKeepTheirOwnCursorOnOneInstance() async throws {
        // AC-PUSH-07-3, AC-PUSH-07-6 with persistence.
        let (u1, u2) = (uid("own"), uid("own"))
        try await ensureUsers(u1, u2)
        let store = FilePushCursorStore(directory: dir.appendingPathComponent("cursors"))
        let id = UUID().uuidString
        try await srv.signed(
            "POST", "/admin/push",
            ["target": "user", "userIds": [u1, u2], "type": "notice", "data": ["text": "s"], "pushId": id])
        let r = rig(store: store)
        try await ready(r, u1)
        r.im.disconnect()
        try await ready(r, u2)
        XCTAssertEqual(r.got.map(\.pushId), [id, id], "not treated as a duplicate across accounts")
        r.im.disconnect()
        try await ready(r, u1)
        XCTAssertEqual(r.got.count, 2, "u1 came back at its own cursor")
        XCTAssertEqual(r.transport.syncs.last, ["afterSeq": 1, "limit": 100])
    }

    // MARK: Logs and files

    func testNoDataOrTokenInLogsAndFiles() async throws {
        // AC-PUSH-08-3 with real traffic and a reconnect; C-52.
        let u = uid("logs")
        try await ensureUsers(u)
        let store = FilePushCursorStore(directory: dir.appendingPathComponent("cursors"))
        let r = rig(store: store)
        let token = try await srv.token(u)
        await flush()
        r.im.connect(token: token)
        try await untilTrue("first round") { r.synced.count == 1 }
        let secret = "SECRET-\(UUID().uuidString)"
        try await pushTo(u, text: secret)
        try await untilTrue("delivered") { r.got.count == 1 }
        r.transport.flash()
        try await untilTrue("second round") { r.synced.count == 2 }
        let logs = r.logs.all.joined(separator: "\n")
        XCTAssertFalse(logs.contains(secret))
        XCTAssertFalse(logs.contains(token))
        XCTAssertTrue(r.transport.urls.allSatisfy { !$0.contains(token) })
        let carrying = r.transport.sent.filter { $0.jsonString().contains(token) }
        XCTAssertTrue(carrying.allSatisfy { $0["cmd"]?.stringValue == "auth" })
        XCTAssertEqual(r.got[0].data["text"]?.stringValue, secret)
        let file = try String(contentsOf: store.fileURL(userId: u), encoding: .utf8)
        XCTAssertFalse(file.contains(secret))
        XCTAssertFalse(file.contains(token))
    }
}

/// `IM_PUSH_ENABLED` off (the default): AC-PUSH-01-4, AC-PUSH-02-14.
@MainActor
final class PushDisabledIntegrationTests: IntegrationCase {
    func testServerWithPushesOffStaysQuiet() async throws {
        do {
            try await srv.signed(
                "POST", "/admin/push",
                ["target": "user", "userIds": ["x"], "type": "notice", "data": [:] as [String: Any], "pushId": UUID().uuidString])
            XCTFail("expected 404")
        } catch {
            XCTAssertTrue(String(describing: error).contains("404"), String(describing: error))
        }
        let (a, b) = (uid("quiet"), uid("quiet"))
        try await importUsers([a, b])
        let r = Rig(url: srv.wsURL)
        defer { r.im.destroy() }
        for _ in 0..<20 { await Task.yield() }
        r.im.connect(token: try await srv.token(a))
        try await untilTrue("one pushSync") { r.transport.syncs.count == 1 }
        try await sleepMs(2_500)  // Backoff would have retried by now: 1 second, then 2.
        XCTAssertEqual(r.transport.syncs, [["afterSeq": 0, "limit": 100]])
        XCTAssertEqual(r.got.count, 0)
        XCTAssertEqual(r.synced, [])
        XCTAssertEqual(r.im.pushCursor(), 0)

        // Unsubscribing and subscribing again does not send either.
        let sub = r.im.onPush { _ in }
        sub.cancel()
        r.im.onPush { _ in }
        try await sleepMs(100)
        XCTAssertEqual(r.transport.syncs.count, 1)

        // Everything else works.
        let convId = c2cConvId(a, b)
        _ = try r.im.send(convId, "开关关闭时消息照常")
        try await untilTrue("message sent") { r.im.messages(convId).first?.status == .sent }

        // Asked once more on the next connection.
        r.transport.flash()
        try await untilTrue("second pushSync after reconnect") { r.transport.syncs.count == 2 }
        XCTAssertEqual(r.im.state, .connected)
    }
}
#endif
