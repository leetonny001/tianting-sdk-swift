#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// A real WebSocket that can go offline: `disconnect()` drops the connection as a lost network would, and while
/// `online == false` every dial fails at once.
@MainActor
private final class Gate: IMTransport {
    private let inner = WebSocketTransport()
    private var conn: TransportConnection?
    private var handlers: TransportHandlers?
    var online = true

    func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        self.handlers = handlers
        guard online else {
            Task { @MainActor in handlers.onClose(1006, "offline") }
            return Dead()
        }
        let c = inner.open(url: url, handlers: handlers)
        conn = c
        return c
    }

    func disconnect() {
        online = false
        conn?.close(code: 4000, reason: "offline")
        conn = nil
        handlers?.onClose(1006, "offline")
    }

    private final class Dead: TransportConnection {
        func send(_ text: String) {}
        func close(code: Int, reason: String) {}
    }
}

/// FE-682 (C5) against a real im-server (IM_CONV_SETTINGS_ENABLED=1): pin, notifications off, delete, multi-device sync,
/// with real SQLite files for AC-CVS-03-10. Same cases as sdk-ts test/integration/conv-settings.test.ts. The server
/// commands come with BE-483..486; until then convSet and convDelete answer 4001 and these cases fail as they are (not
/// skipped, not relaxed). Local results, CI not running.
@MainActor
final class ConvSettingsIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var server: TestServer?
    var clients: [IMClient] = []
    var dirs: [URL] = []
    let log = ITLog()
    private static var seq = 0

    var srv: TestServer { ConvSettingsIntegrationTests.server! }

    override func setUp() async throws {
        try await super.setUp()
        if ConvSettingsIntegrationTests.server == nil {
            ConvSettingsIntegrationTests.server = try await TestServer.start(env: ["IM_CONV_SETTINGS_ENABLED": "1"])
        }
    }

    override func tearDown() async throws {
        for c in clients { c.close() }
        clients = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        XCTAssertFalse(log.all.contains("ZXQ"), log.all)
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func uid(_ base: String) -> String {
        ConvSettingsIntegrationTests.seq += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(ConvSettingsIntegrationTests.seq)
    }

    private func users(_ ids: String...) async throws {
        try await srv.admin("POST", "/admin/users/import", ["users": ids.map { ["userId": $0] }])
    }

    private func client(_ transport: IMTransport? = nil, directory: URL? = nil) -> IMClient {
        var o = IMClientOptions(url: srv.wsURL)
        o.systemEvents = false
        o.pushCursorStore = nil
        o.logger = log
        o.transport = transport
        o.databaseDirectory = directory
        if let directory { o.fileCacheDirectory = directory.appendingPathComponent("cache") }
        var t = IMClientTimings()
        t.backoffBaseMs = 50
        t.backoffMaxMs = 100
        o.timings = t
        let im = IMClient(options: o)
        clients.append(im)
        return im
    }

    @discardableResult
    private func login(_ userId: String, _ im: IMClient? = nil) async throws -> IMClient {
        let im = im ?? client()
        im.connect(token: try await srv.token(userId))
        try await untilTrue("\(userId) connected") { im.state == .connected && im.userId == userId }
        return im
    }

    @discardableResult
    private func sent(_ im: IMClient, _ convId: String, _ text: String) async throws -> Message {
        guard case .ok(let m) = try im.send(convId, text) else { throw TestServerError("send rejected") }
        return try await until("sent \(text)") {
            im.messages(convId).first { $0.clientMsgId == m.clientMsgId && $0.status == .sent }
        }
    }

    private func conv(_ im: IMClient, _ convId: String) -> Conversation? {
        im.conversations().first { $0.convId == convId }
    }

    private func order(_ im: IMClient) -> [String] {
        im.conversations().map { "\($0.convId):\($0.isPinned):\($0.pinnedAt ?? -1):\($0.isNotifyOff)" }
    }

    private func newDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("im-sdk-swift-c5-\(UUID().uuidString)")
        dirs.append(d)
        return d
    }

    private func onDisk(_ root: URL, _ needle: String) -> [String] {
        let bytes = Data(needle.utf8)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let u as URL in e where (try? Data(contentsOf: u))?.range(of: bytes) != nil { out.append(u.lastPathComponent) }
        return out
    }

    // backend-chat 75
    func testConfigFeaturesConvSettingsIsTrue() async throws {
        var o = AccountClientOptions(baseUrl: srv.httpURL)
        o.systemEvents = false
        let cfg = try await AccountClient(options: o).getConfig()
        XCTAssertEqual(cfg.features.convSettings, true)
    }

    // TC-CVS-04-01 (AC-CVS-04-1)
    func testTC_CVS_04_01_pinAndNotifyOffOnD1ReachD2WithinTwoSeconds() async throws {
        let (u1, u2) = (uid("pa"), uid("pb"))
        try await users(u1, u2)
        let cid = c2cConvId(u1, u2)
        let d1 = try await login(u1)
        let d2 = try await login(u1)
        let b = try await login(u2)
        try await sent(b, cid, "hi")
        try await untilTrue("conv on both devices") { self.conv(d1, cid) != nil && self.conv(d2, cid) != nil }
        let t0 = Date()
        try await d1.setConvPinned(cid, true)
        try await d1.setConvNotifyOff(cid, true)
        let pinnedAt = try XCTUnwrap(conv(d1, cid)?.pinnedAt)
        XCTAssertEqual(conv(d1, cid)?.isPinned, true)
        XCTAssertEqual(conv(d1, cid)?.isNotifyOff, true)
        try await untilTrue("D2 updated", timeout: 2) { self.conv(d2, cid)?.isPinned == true && self.conv(d2, cid)?.isNotifyOff == true }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(conv(d2, cid)?.pinnedAt, pinnedAt)
        XCTAssertEqual(d2.conversations().first?.convId, cid)
        XCTAssertEqual(d2.totalUnread(), 0)
    }

    // TC-CVS-04-05, TC-CVS-03-02 (AC-CVS-04-5, 03-2)
    func testTC_CVS_04_05_deleteOnD1ReachesD2AndANewMessageBringsItBackOnBoth() async throws {
        let (u1, u2) = (uid("da"), uid("db"))
        try await users(u1, u2)
        let cid = c2cConvId(u1, u2)
        let d1 = try await login(u1)
        let d2 = try await login(u1)
        let b = try await login(u2)
        for i in 1...3 { try await sent(b, cid, "ZXQ-CVS-1 第 \(i) 条") }
        try await untilTrue("D2 has 3") { self.conv(d2, cid)?.maxSeq == 3 }
        _ = try await d2.loadHistory(cid)
        XCTAssertEqual(d2.messages(cid).count, 3)
        var deletedOnD2: [String] = []
        _ = d2.on { if case .convDeleted(let id) = $0 { deletedOnD2.append(id) } }
        let t0 = Date()
        try await d1.deleteConv(cid)
        XCTAssertNil(conv(d1, cid))
        try await untilTrue("D2 convDeleted", timeout: 2) { deletedOnD2.contains(cid) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertNil(conv(d2, cid))
        XCTAssertNil(d2.conversationSnapshot(cid))
        for im in [d1, d2] { XCTAssertFalse(exported(im.debugExport()).contains("ZXQ-CVS-1")) }

        try await sent(b, cid, "新的一条")
        for im in [d1, d2] {
            try await untilTrue("reappears with unread 1") { self.conv(im, cid)?.unread == 1 }
            XCTAssertEqual(conv(im, cid)?.minSeq, 4)
            _ = try await im.loadHistory(cid)
            XCTAssertEqual(im.messages(cid).map(\.body.text), ["新的一条"])
        }
        let d3 = try await login(u1)
        try await untilTrue("convs") { self.conv(d3, cid) != nil }
        XCTAssertEqual(conv(d3, cid)?.minSeq, 4)
        XCTAssertEqual(conv(d3, cid)?.unread, 1)
        XCTAssertEqual(conv(b, cid)?.minSeq, 1)  // The other side is not affected.
    }

    // TC-CVS-03-05 (AC-CVS-03-5)
    func testTC_CVS_03_05_d2OfflineWhileD1DeletesTheGroupNotRemovedAndCanStillSend() async throws {
        let (u1, u2) = (uid("ga"), uid("gb"))
        try await users(u1, u2)
        let groupId = uid("g")
        try await srv.admin("POST", "/admin/groups", ["groupId": groupId, "name": groupId, "members": [u1, u2]])
        let g = groupConvId(groupId)
        let gate = Gate()
        let d1 = try await login(u1)
        let d2 = try await login(u1, client(gate))
        let b = try await login(u2)
        try await sent(b, g, "ZXQ-CVS-6")
        try await untilTrue("D2 has g") { (self.conv(d2, g)?.maxSeq ?? 0) > 0 }
        _ = try await d2.loadHistory(g)
        var removed: [String] = []
        _ = d2.on { if case .convRemoved(let id, _) = $0 { removed.append(id) } }
        gate.disconnect()
        try await untilTrue("D2 offline") { d2.state != .connected }
        try await d1.deleteConv(g)
        gate.online = true
        d2.networkOnline()
        try await untilTrue("D2 back", timeout: 10) { d2.state == .connected }
        try await untilTrue("g gone") { self.conv(d2, g) == nil }
        XCTAssertEqual(removed, [])
        XCTAssertNil(d2.conversationSnapshot(g))
        XCTAssertFalse(exported(d2.debugExport()).contains("ZXQ-CVS-6"))
        let mine = try await d2.loadMyGroups()
        XCTAssertTrue(mine.map(\.groupId).contains(groupId))
        try await sent(d2, g, "我还在群里")
        try await untilTrue("u2 receives") { self.conv(b, g)?.lastMsg?.text == "我还在群里" }
    }

    // TC-CVS-04-02 (AC-CVS-04-2)
    func testTC_CVS_04_02_d2OfflineWhileD1PinsOneAndDeletesAnotherMatchesD1AfterReconnect() async throws {
        let (u1, u2, u3) = (uid("oa"), uid("ob"), uid("oc"))
        try await users(u1, u2, u3)
        let c1 = c2cConvId(u1, u2)
        let c2 = c2cConvId(u1, u3)
        let gate = Gate()
        let d1 = try await login(u1)
        let d2 = try await login(u1, client(gate))
        try await sent(try await login(u2), c1, "c1")
        try await sent(try await login(u3), c2, "ZXQ-CVS-7")
        try await untilTrue("D2 has both") { self.conv(d2, c1) != nil && self.conv(d2, c2) != nil }
        _ = try await d2.loadHistory(c2)
        gate.disconnect()
        try await untilTrue("D2 offline") { d2.state != .connected }
        try await d1.setConvPinned(c1, true)
        try await d1.deleteConv(c2)
        gate.online = true
        d2.networkOnline()
        try await untilTrue("D2 back", timeout: 10) { d2.state == .connected }
        try await untilTrue("D2 synced") { self.conv(d2, c1)?.isPinned == true && self.conv(d2, c2) == nil }
        XCTAssertEqual(order(d2), order(d1))
        XCTAssertEqual(d2.messages(c2), [])
        XCTAssertFalse(exported(d2.debugExport()).contains("ZXQ-CVS-7"))
    }

    // AC-CVS-03-12 (F-CVS-03 rule 6a, frontend-chat 65): deleted, removed and added back with historyVisible in the
    // same login: the whole history loads again, with a real SQLite file.
    func testAC_CVS_03_12_rejoinWithHistoryVisibleLoadsTheWholeHistoryAgain() async throws {
        let (u1, u2) = (uid("ra"), uid("rb"))
        try await users(u1, u2)
        let groupId = uid("g")
        try await srv.admin("POST", "/admin/groups", ["groupId": groupId, "name": groupId, "members": [u1, u2], "historyVisible": true])
        let g = groupConvId(groupId)
        let d1 = try await login(u1, client(directory: newDir()))
        let b = try await login(u2)
        for i in 1...3 { try await sent(b, g, "历史 \(i)") }
        try await untilTrue("d1 has 3") { self.conv(d1, g)?.maxSeq ?? 0 >= 3 }
        _ = try await d1.loadHistory(g)
        try await d1.deleteConv(g)
        XCTAssertEqual(d1.messages(g), [])
        try await srv.admin("DELETE", "/admin/groups/\(groupId)/members", ["members": [u1]])
        try await untilTrue("removed") { d1.conversationSnapshot(g) != nil }
        try await srv.admin("POST", "/admin/groups/\(groupId)/members", ["members": [u1]])
        try await untilTrue("back with minSeq 1") { self.conv(d1, g)?.minSeq == 1 }
        while try await d1.loadHistory(g) {}
        let texts = d1.messages(g).compactMap { $0.body.text }
        XCTAssertEqual(texts.filter { $0.hasPrefix("历史") }, ["历史 1", "历史 2", "历史 3"])
    }

    // TC-CVS-03-10 (AC-CVS-03-10, sdk-swift): D2 offline (app killed) holds the c2c conversation with the marker in its
    // SQLite file; D1 deletes it, u2 sends one more; D2 starts again: database files and cache folder without the marker,
    // only the new message shows.
    func testTC_CVS_03_10_restartedD2HasNoOldTextOnDiskAndShowsOnlyTheNewMessage() async throws {
        let (u1, u2) = (uid("ka"), uid("kb"))
        try await users(u1, u2)
        let cid = c2cConvId(u1, u2)
        let dir = newDir()
        let d1 = try await login(u1)
        let b = try await login(u2)
        var d2 = try await login(u1, client(directory: dir))
        for i in 1...3 { try await sent(b, cid, "ZXQ-CVS-10 第 \(i) 条") }
        try await untilTrue("D2 has 3") { self.conv(d2, cid)?.maxSeq == 3 }
        _ = try await d2.loadHistory(cid)
        XCTAssertEqual(d2.messages(cid).count, 3)
        d2.close()  // Killed while offline: the database stays.
        XCTAssertFalse(onDisk(dir, "ZXQ-CVS-10").isEmpty, "control: the marker is on disk")
        try await untilTrue("conv on D1") { self.conv(d1, cid) != nil }
        try await d1.deleteConv(cid)
        try await sent(b, cid, "新的一条")
        d2 = client(directory: dir)
        d2.restoreCache(userId: u1)
        XCTAssertEqual(d2.messages(cid).count, 3)  // Offline it still shows the cache.
        try await login(u1, d2)
        try await untilTrue("only the new message") { d2.messages(cid).map(\.body.text) == ["新的一条"] }
        XCTAssertEqual(conv(d2, cid)?.minSeq, 4)
        XCTAssertEqual(conv(d2, cid)?.unread, 1)
        XCTAssertEqual(onDisk(dir, "ZXQ-CVS-10"), [])
        d2.close()
        XCTAssertEqual(onDisk(dir, "ZXQ-CVS-10"), [])
        let d4 = client(directory: dir)
        d4.restoreCache(userId: u1)
        XCTAssertEqual(d4.messages(cid).map(\.body.text), ["新的一条"])
    }
}
#endif

#if os(macOS)
@MainActor
private func exported(_ e: DebugExport) -> String {
    String(decoding: (try? JSONEncoder().encode(e)) ?? Data(), as: UTF8.self)
}
#endif
