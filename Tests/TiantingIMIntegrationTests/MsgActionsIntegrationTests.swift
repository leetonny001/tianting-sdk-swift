#if os(macOS)
import Foundation
import Security
import XCTest

@testable import TiantingIM

/// A real WebSocket that can go offline: `disconnect()` drops the connection as a lost network would, and while
/// `online == false` every dial fails at once. Records what was sent.
@MainActor
private final class GatedTransport: IMTransport {
    private let inner = WebSocketTransport()
    private var conn: TransportConnection?
    private var handlers: TransportHandlers?
    var online = true
    var sent: [JSONValue] = []

    func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        self.handlers = handlers
        guard online else {
            Task { @MainActor in handlers.onClose(1006, "offline") }
            return Dead()
        }
        let c = inner.open(url: url, handlers: handlers)
        conn = c
        return Recording(inner: c, owner: self)
    }

    func disconnect() {
        online = false
        conn?.close(code: 4000, reason: "offline")
        conn = nil
        handlers?.onClose(1006, "offline")
    }

    func sentCmds(_ cmd: String) -> [JSONValue] { sent.filter { $0["cmd"]?.stringValue == cmd } }

    private final class Dead: TransportConnection {
        func send(_ text: String) {}
        func close(code: Int, reason: String) {}
    }

    @MainActor
    private final class Recording: TransportConnection {
        let inner: TransportConnection
        weak var owner: GatedTransport?
        init(inner: TransportConnection, owner: GatedTransport) {
            self.inner = inner
            self.owner = owner
        }
        func send(_ text: String) {
            if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { owner?.sent.append(v) }
            inner.send(text)
        }
        func close(code: Int, reason: String) { inner.close(code: code, reason: reason) }
    }
}

/// FE-663, FE-664 (C4) against a real im-server (IM_MSG_ACTIONS_ENABLED=1): recall, quote, mentions; real URLSession
/// WebSocket, real SQLite files. Same as sdk-kotlin MsgActionsIntegrationTest.kt (sdk-ts test/integration/msg-actions),
/// cold start (AC-RCL-03-4) included. Local results, CI not running.
@MainActor
final class MsgActionsIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var server: TestServer?
    var clients: [IMClient] = []
    let log = ITLog()
    var dirs: [URL] = []
    private static var seq = 0

    var srv: TestServer { MsgActionsIntegrationTests.server! }

    override func setUp() async throws {
        try await super.setUp()
        if MsgActionsIntegrationTests.server == nil {
            // Generated here (TC-RCL general rule E1); the second @all within the hour is 4293.
            var key = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
            MsgActionsIntegrationTests.server = try await TestServer.start(env: [
                "IM_MSG_ACTIONS_ENABLED": "1", "IM_QUARANTINE_KEY": Data(key).base64EncodedString(), "IM_MENTION_ALL_HOURLY": "1",
            ])
        }
    }

    override func tearDown() async throws {
        for c in clients { c.close() }
        clients = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        // 13.1: no quoted text, mention content or recalled text in the logs.
        XCTAssertFalse(log.all.contains("ZXQ"), log.all)
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func uid(_ base: String) -> String {
        MsgActionsIntegrationTests.seq += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(MsgActionsIntegrationTests.seq)
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

    private func sent(
        _ im: IMClient, _ convId: String, _ text: String, quote: QuoteRef? = nil, mentions: Mentions? = nil
    ) async throws -> Message {
        guard case .ok(let m) = try im.send(convId, text, quote: quote, mentions: mentions) else {
            throw TestServerError("send rejected")
        }
        return try await until("sent \(text)") {
            im.messages(convId).first { $0.clientMsgId == m.clientMsgId && $0.status == .sent }
        }
    }

    private func byId(_ im: IMClient, _ convId: String, _ msgId: String) -> Message? {
        im.messages(convId).first { $0.msgId == msgId }
    }

    private func conv(_ im: IMClient, _ convId: String) -> Conversation? {
        im.conversations().first { $0.convId == convId }
    }

    private func clean(_ im: IMClient, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(encoded(im.debugExport()).contains(needle), "\(needle) is still in memory", file: file, line: line)
    }

    private func encoded<T: Encodable>(_ v: T) -> String {
        String(decoding: (try? JSONEncoder().encode(v)) ?? Data(), as: UTF8.self)
    }

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-c4-it-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private func filesContaining(_ dir: URL, _ needle: String) -> [String] {
        let bytes = Data(needle.utf8)
        let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return names.filter { (try? Data(contentsOf: $0))?.range(of: bytes) != nil }.map(\.lastPathComponent)
    }

    private func recallError(_ im: IMClient, _ convId: String, _ msgId: String) async -> IMError? {
        do {
            try await im.recall(convId, msgId)
            return nil
        } catch {
            return error as? IMError
        }
    }

    // MARK: Recall

    func testTC_RCL_01_01_recallAcksOthersAndMyOtherDeviceGetRecalledMsgDeletedWithin2Seconds() async throws {
        let (u1, u2) = (uid("ra"), uid("rb"))
        try await users(u1, u2)
        let cv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let a2 = try await login(u1)
        let b = try await login(u2)
        let m1 = try await sent(a, cv, "ZXQ-RCL-2 原文")
        try await until("u2 receives") { self.byId(b, cv, m1.msgId!) }
        try await until("u1' receives") { self.byId(a2, cv, m1.msgId!) }
        XCTAssertTrue(a.canRecall(m1))

        let t0 = Date()
        try await a.recall(cv, m1.msgId!)
        let mine = byId(a, cv, m1.msgId!)!
        XCTAssertTrue(mine.isDeleted && mine.isRecalled)
        XCTAssertEqual(mine.recalledBy, u1)
        XCTAssertEqual(mine.body, MsgBody())
        for im in [b, a2] {
            let x = try await until("recalled event", timeout: 2) { self.byId(im, cv, m1.msgId!).flatMap { $0.isRecalled ? $0 : nil } }
            XCTAssertEqual(x.recalledBy, u1)
            XCTAssertTrue(x.isDeleted)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(a.recallText(byId(a, cv, m1.msgId!)!), "你撤回了一条消息")
        XCTAssertEqual(a2.recallText(byId(a2, cv, m1.msgId!)!), "你撤回了一条消息")
        XCTAssertEqual(b.recallText(byId(b, cv, m1.msgId!)!), "对方撤回了一条消息")
        XCTAssertEqual(b.messageActions(byId(b, cv, m1.msgId!)!), [])
        for im in [a, a2, b] { clean(im, "ZXQ-RCL-2") }

        // Recalling again succeeds (the client side of AC-RCL-01-4).
        try await a.recall(cv, m1.msgId!)
        // The server's summary is a recall too (AC-RCL-03-5): a new connection shows the notice from lastMsg.
        let b2 = try await login(u2)
        let last = try await until("convs") { self.conv(b2, cv)?.lastMsg }
        XCTAssertTrue(last.deleted == true && last.recalled == true)
        XCTAssertEqual(last.recalledBy, u1)
        XCTAssertEqual(b2.recallText(convId: cv, lastMsg: last), "对方撤回了一条消息")
    }

    func testTC_RCL_01_08_serverTime121SecondsLaterRecallIs4097WithWindowSeconds120() async throws {
        let (u1, u2) = (uid("wa"), uid("wb"))
        try await users(u1, u2)
        let cv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let m1 = try await sent(a, cv, "过期")
        try await srv.admin("POST", "/admin/test/clock", ["nowMs": m1.ts + 121_000])
        do {
            let err = await recallError(a, cv, m1.msgId!)
            try await srv.admin("POST", "/admin/test/clock", ["nowMs": NSNull()])  // The real clock again.
            XCTAssertEqual(err?.code, 4097)
            let ws = err?.details?["windowSeconds"]?.intValue
            XCTAssertEqual(ws, 120)
            XCTAssertEqual(messageFor(cmd: "recall", code: 4097, windowSeconds: ws), "发送时间超过 2 分钟，无法撤回")
            XCTAssertEqual(byId(a, cv, m1.msgId!)?.body.text, "过期")
            XCTAssertFalse(byId(a, cv, m1.msgId!)!.isDeleted)
        }
    }

    func testTC_RCL_03_03_TC_RCL_03_11_recalledWhileOfflineReconnectResyncsOnlyThatConversation() async throws {
        let (u1, u2, u3) = (uid("oa"), uid("ob"), uid("oc"))
        try await users(u1, u2, u3)
        let cv = c2cConvId(u1, u2)
        let quiet = c2cConvId(u3, u2)
        let a = try await login(u1)
        let c = try await login(u3)
        let m1 = try await sent(a, cv, "ZXQ-RCL-2 离线撤回")
        let m3 = try await sent(c, quiet, "不变的会话")
        // u2 opens both after logging in: the login's convs modVer is the baseline (problem 24).
        let gate = GatedTransport()
        let b = try await login(u2, client(gate))
        try await untilTrue("u2 convs") { b.conversations().count == 2 }
        try await b.loadHistory(cv)
        try await b.loadHistory(quiet)
        try await untilTrue("u2 loaded both") { self.byId(b, cv, m1.msgId!) != nil && self.byId(b, quiet, m3.msgId!) != nil }
        gate.disconnect()
        try await untilTrue("u2 offline") { b.state != .connected }
        try await a.recall(cv, m1.msgId!)
        gate.sent = []
        gate.online = true
        b.networkOnline()
        try await untilTrue("u2 back online") { b.state == .connected }
        try await untilTrue("recalled after reconnect") { self.byId(b, cv, m1.msgId!)?.isRecalled == true }
        let resynced = gate.sentCmds("sync").compactMap { $0["data"]?["convId"]?.stringValue }
        XCTAssertTrue(resynced.contains(cv), "\(resynced)")
        XCTAssertFalse(resynced.contains(quiet), "\(resynced)")
        XCTAssertEqual(b.recallText(byId(b, cv, m1.msgId!)!), "对方撤回了一条消息")
        clean(b, "ZXQ-RCL-2")
    }

    func testTC_RCL_03_04_recalledWhileKilledColdStartShowsTheNoticeAndTheDatabaseHasNoText() async throws {
        let (u1, u2) = (uid("ka"), uid("kb"))
        try await users(u1, u2)
        let cv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let d = dir()
        let b = try await login(u2, client(directory: d))
        let m1 = try await sent(a, cv, "ZXQ-RCL-2 杀进程时撤回")
        let m2 = try await sent(a, cv, "补一句", quote: QuoteRef(msgId: m1.msgId!))
        try await until("u2 receives both") { self.byId(b, cv, m2.msgId!) }
        try await b.loadHistory(cv)  // The modVer baseline (problem 24).
        XCTAssertEqual(byId(b, cv, m2.msgId!)?.body.quote?.state, .normal)
        b.close()  // The process ends; the database stays.
        clients.removeAll { $0 === b }
        XCTAssertFalse(filesContaining(d, "ZXQ-RCL-2").isEmpty, "control: the text is in the database")
        try await a.recall(cv, m1.msgId!)

        let b2 = client(directory: d)
        b2.restoreCache(userId: u2)
        XCTAssertEqual(byId(b2, cv, m1.msgId!)?.body.text, "ZXQ-RCL-2 杀进程时撤回")  // Offline: still the last content.
        try await login(u2, b2)
        let x = try await until("recalled after cold start") { self.byId(b2, cv, m1.msgId!).flatMap { $0.isRecalled ? $0 : nil } }
        XCTAssertEqual(b2.recallText(x), "对方撤回了一条消息")
        try await untilTrue("quote cleared") { self.byId(b2, cv, m2.msgId!)?.body.quote?.state == .recalled }
        XCTAssertEqual(quoteLabel(byId(b2, cv, m2.msgId!)!.body.quote!), "引用内容已被撤回")
        clean(b2, "ZXQ-RCL-2")
        b2.close()
        clients.removeAll { $0 === b2 }
        XCTAssertEqual(filesContaining(d, "ZXQ-RCL-2"), [], "the text is still in the database")
    }

    // MARK: Quotes

    func testTC_QUO_01_01_quoteArrivesNormalWithSummaryThenRecallTurnsBothSidesRecalled() async throws {
        let (u1, u2) = (uid("qa"), uid("qb"))
        try await users(u1, u2)
        let cv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let b = try await login(u2)
        let m1 = try await sent(b, cv, "ZXQ-QUO-1 被引用的原文")
        try await until("u1 receives m1") { self.byId(a, cv, m1.msgId!) }
        let m2 = try await sent(a, cv, "回复", quote: QuoteRef(msgId: m1.msgId!))
        let got = try await until("u2 receives m2") { self.byId(b, cv, m2.msgId!) }
        XCTAssertEqual(
            got.body.quote, QuoteView(msgId: m1.msgId!, seq: m1.seq, from: u2, type: .text, state: .normal, text: "ZXQ-QUO-1 被引用的原文"))

        try await b.recall(cv, m1.msgId!)
        try await untilTrue("quote recalled on u1") { self.byId(a, cv, m2.msgId!)?.body.quote?.state == .recalled }
        XCTAssertEqual(quoteLabel(byId(a, cv, m2.msgId!)!.body.quote!), "引用内容已被撤回")
        XCTAssertEqual(quoteLabel(byId(b, cv, m2.msgId!)!.body.quote!), "引用内容已被撤回")
        for im in [a, b] { clean(im, "ZXQ-QUO-1") }
    }

    // MARK: Groups: mentions, owner and admin recalls

    func testTC_MEN_01_01_TC_MEN_03_07_TC_RCL_02_04_TC_MEN_02_05_AC_RCL_02_5_groupMentionsAndManagerRecalls() async throws {
        let (o, a, mm, nn) = (uid("o"), uid("a"), uid("m"), uid("n"))
        try await users(o, a, mm, nn)
        let groupId = uid("g")
        let convId = groupConvId(groupId)
        try await srv.signed(
            "POST", "/admin/groups", ["groupId": groupId, "name": groupId, "members": [o, a, mm, nn], "owner": o])
        let ownerGate = GatedTransport()
        let owner = try await login(o, client(ownerGate))
        try await untilTrue("owner role") { self.conv(owner, convId)?.myRole == .owner }
        try await owner.setGroupAdmin(groupId, userId: a, admin: true)
        let adm = try await login(a)
        let mem = try await login(mm)
        let other = try await login(nn)
        for im in [owner, adm, mem, other] { try await until("group in list") { self.conv(im, convId) } }
        try await untilTrue("admin role") { self.conv(adm, convId)?.myRole == .admin }

        // Member search (F-MEN-01 rule 6): userId prefix.
        let found = try await mem.searchGroupMembers(groupId, keyword: nn)
        XCTAssertEqual(found.members.map(\.userId), [nn])

        // TC-MEN-01-01: m @ n. n's mentionUnread = 1 (live; after a new login the server says 1 too); o has none.
        let at = try await sent(mem, convId, "@\(nn) 看一下", mentions: Mentions(userIds: [nn]))
        let got = try await until("n receives") { self.byId(other, convId, at.msgId!) }
        XCTAssertEqual(got.body.mentions, Mentions(userIds: [nn]))
        XCTAssertEqual(conv(other, convId)?.mentionUnread, 1)
        XCTAssertEqual(conv(other, convId)?.firstMentionSeq, at.seq)
        try await until("o receives") { self.byId(owner, convId, at.msgId!) }
        XCTAssertEqual(conv(owner, convId)?.mentionUnread ?? 0, 0)
        let other2 = try await login(nn)
        try await untilTrue("server mentionUnread=1") { self.conv(other2, convId)?.mentionUnread == 1 }

        // TC-MEN-03-07: the sender recalls the mention; both of n's connections fetch convs within 5 seconds.
        try await mem.recall(convId, at.msgId!)
        for im in [other, other2] {
            try await untilTrue("mention cleared", timeout: 5) { self.conv(im, convId)?.mentionUnread == 0 }
        }

        // TC-RCL-02-04: a recalls m's message (the last one); a's, m's and n's chat pages and list summaries.
        let target = try await sent(mem, convId, "ZXQ-RCL-2 成员的消息")
        for im in [adm, other] { try await until("loaded") { self.byId(im, convId, target.msgId!) } }
        XCTAssertTrue(adm.canRecall(byId(adm, convId, target.msgId!)!))
        try await adm.recall(convId, target.msgId!)
        for (im, text) in [(adm, "你撤回了 \(mm) 的一条消息"), (mem, "\(a)撤回了你的一条消息"), (other, "\(a)撤回了一条成员消息")] {
            let x = try await until(text) { self.byId(im, convId, target.msgId!).flatMap { $0.isRecalled ? $0 : nil } }
            XCTAssertEqual(x.recalledBy, a)
            XCTAssertEqual(im.recallText(x), text)
            let last = try await until("\(text) list") {
                self.conv(im, convId)?.lastMsg.flatMap { $0.msgId == target.msgId && $0.recalled == true ? $0 : nil }
            }
            XCTAssertEqual(last.recalledBy, a)
            XCTAssertEqual(im.recallText(convId: convId, lastMsg: last), text)
            clean(im, "ZXQ-RCL-2")
        }

        // AC-RCL-02-5: the admin recalls the owner's message: 4030, "你没有权限撤回这条消息", nothing changes.
        let om = try await sent(owner, convId, "群主的消息")
        try await until("admin loaded") { self.byId(adm, convId, om.msgId!) }
        XCTAssertTrue(adm.messageActions(byId(adm, convId, om.msgId!)!).contains(.recall))
        let err = await recallError(adm, convId, om.msgId!)
        XCTAssertEqual(err?.code, 4030)
        XCTAssertEqual(messageFor(cmd: "recall", code: 4030), "你没有权限撤回这条消息")
        XCTAssertEqual(byId(adm, convId, om.msgId!)?.body.text, "群主的消息")

        // TC-MEN-02-05: once per hour (test setting): the second @all is 4293, failed, no automatic resend.
        _ = try await sent(owner, convId, "@所有人 第一次", mentions: Mentions(all: true))
        guard case .ok(let r) = try owner.send(convId, "@所有人 第二次", mentions: Mentions(all: true)) else {
            throw TestServerError("send rejected")
        }
        let failed = try await until("4293") {
            owner.messages(convId).first { $0.clientMsgId == r.clientMsgId && $0.status == .failed }
        }
        XCTAssertEqual(failed.error, .code(4293))
        XCTAssertEqual(messageFor(cmd: "send", code: 4293), "@所有人次数已用完")
        ownerGate.sent = []
        ownerGate.disconnect()
        try await untilTrue("owner offline") { owner.state != .connected }
        ownerGate.online = true
        owner.networkOnline()
        try await untilTrue("owner back online") { owner.state == .connected }
        try await sleepMs(300)
        XCTAssertEqual(ownerGate.sentCmds("send"), [])
        XCTAssertEqual(owner.messages(convId).first { $0.clientMsgId == r.clientMsgId }?.error, .code(4293))
    }
}
#endif
