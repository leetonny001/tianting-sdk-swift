#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// Records the cmd of every frame that arrives, with the time (to see that a report pushes nothing to anyone).
@MainActor
private final class Recording: IMTransport {
    private let inner = WebSocketTransport()
    private(set) var inbound: [(cmd: String, at: Date)] = []

    func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        var h = handlers
        let forward = handlers.onMessage
        h.onMessage = { [weak self] text in
            let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            self?.inbound.append((String(describing: o?["cmd"] ?? ""), Date()))
            forward(text)
        }
        return inner.open(url: url, handlers: h)
    }

    func pushed(since t: Date) -> [String] {
        inbound.filter { $0.at >= t && $0.cmd != "ack" && $0.cmd != "pong" }.map(\.cmd)
    }
}

private final class MemoryStore: AccountSessionStore {
    var saved: AccountSession?
    var pending: [PendingLogout] = []
    func load() async throws -> AccountSession? { saved }
    func save(_ session: AccountSession) async throws { saved = session }
    func clear() async throws { saved = nil }
    func loadPendingLogouts() async throws -> [PendingLogout] { pending }
    func savePendingLogouts(_ p: [PendingLogout]) async throws { pending = p }
}

/// Integration-only evidence key (32 bytes, base64), unlike the quarantine and JWT keys.
private let MOD_ENV = [
    "IM_MOD_ENABLED": "1",
    "IM_REPORT_KEY": Data("sdk-it-report-key-0123456789abcd".utf8).base64EncodedString(),
]
private let WORD = "zxqmodword"  // a marker word, not a real one
private let ID = "^[A-Za-z0-9_-]{1,64}$"

/// Shared by both suites: one client per call, all closed in tearDown, logs checked for the markers.
@MainActor
class ModerationC6Case: XCTestCase {
    var clients: [IMClient] = []
    fileprivate var transports: [ObjectIdentifier: Recording] = [:]
    let log = ITLog()
    private static var seq = 0

    var server: TestServer { fatalError("override") }

    override func tearDown() async throws {
        for c in clients { c.destroy() }
        clients = []
        transports = [:]
        XCTAssertFalse(log.all.contains("ZXQ-RPT"), log.all)
        XCTAssertFalse(log.all.contains(WORD), log.all)
        try await super.tearDown()
    }

    func uid(_ base: String) -> String {
        ModerationC6Case.seq += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(ModerationC6Case.seq)
    }

    func users(_ ids: String...) async throws {
        try await server.admin("POST", "/admin/users/import", ["users": ids.map { ["userId": $0] }])
    }

    @discardableResult
    func login(_ userId: String) async throws -> IMClient {
        let t = Recording()
        var o = IMClientOptions(url: server.wsURL)
        o.systemEvents = false
        o.pushCursorStore = nil
        o.logger = log
        o.transport = t
        var timings = IMClientTimings()
        timings.backoffBaseMs = 50
        timings.backoffMaxMs = 100
        o.timings = timings
        let im = IMClient(options: o)
        clients.append(im)
        transports[ObjectIdentifier(im)] = t
        im.connect(token: try await server.token(userId))
        try await untilTrue("\(userId) connected") { im.state == .connected && im.userId == userId }
        return im
    }

    fileprivate func transport(_ im: IMClient) -> Recording { transports[ObjectIdentifier(im)]! }

    @discardableResult
    func sent(_ im: IMClient, _ convId: String, _ text: String) async throws -> Message {
        guard case .ok(let m) = try im.send(convId, text) else { throw TestServerError("send rejected") }
        return try await until("sent \(text)") {
            im.messages(convId).first { $0.clientMsgId == m.clientMsgId && $0.status == .sent }
        }
    }

    func errorOf(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }
}

/// FE-692 (C6) reporting against a real im-server (IM_MOD_ENABLED=1). Same cases as sdk-ts
/// test/integration/report.test.ts (tianting-sdk-ts@d5fb273), except that a c2c conversation I am not in is refused
/// locally (4000), so the server's 4040 is tested with a group message (frontend-chat 91); the group is a hosted one,
/// since `groupCreate` needs two friends. The server side is BE-492..496; on a server without it these cases fail as
/// they are (not skipped, not relaxed). Local results, CI not running.
@MainActor
final class ReportIntegrationTests: ModerationC6Case {
    nonisolated(unsafe) static var srv: TestServer?
    override var server: TestServer { ReportIntegrationTests.srv! }

    override func setUp() async throws {
        try await super.setUp()
        if ReportIntegrationTests.srv == nil { ReportIntegrationTests.srv = try await TestServer.start(env: MOD_ENV) }
    }

    override class func tearDown() {
        srv?.stop()
        srv = nil
        super.tearDown()
    }

    // backend-chat 96
    func testConfigFeaturesModerationIsTrue() async throws {
        var o = AccountClientOptions(baseUrl: server.httpURL)
        o.systemEvents = false
        let cfg = try await AccountClient(options: o).getConfig()
        XCTAssertEqual(cfg.features.moderation, true)
    }

    // TC-MOD-03-01 (AC-MOD-03-1, client side)
    func testTC_MOD_03_01_reportAMessageReturnsAReportIdNobodyGetsAFrameARepeatReturnsTheSameId() async throws {
        let (u1, u2) = (uid("ra"), uid("rb"))
        try await users(u1, u2)
        let conv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let b = try await login(u2)
        let m = try await sent(a, conv, "ZXQ-RPT-3 被举报的消息")
        try await untilTrue("u2 has the conversation") { b.conversations().contains { $0.convId == conv } }
        try await sleepMs(300)  // the pushes of the send itself first
        let t0 = Date()
        let id = try await b.report(.message(convId: conv, msgIds: [m.msgId!], reason: .abuse, note: "ZXQ-RPT-NOTE"))
        XCTAssertNotNil(id.range(of: ID, options: .regularExpression), id)
        try await sleepMs(2_000)
        XCTAssertEqual(transport(a).pushed(since: t0), [])
        XCTAssertEqual(transport(b).pushed(since: t0), [])
        let again = try await b.report(.message(convId: conv, msgIds: [m.msgId!], reason: .abuse))
        XCTAssertEqual(again, id)
    }

    func testReportUserAndGroupNonParticipantAndUnknownUserAreTheSame4040() async throws {
        let (u1, u2, u3) = (uid("rc"), uid("rd"), uid("re"))
        try await users(u1, u2, u3)
        let conv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let b = try await login(u2)
        let c = try await login(u3)
        let m = try await sent(a, conv, "ZXQ-RPT-4")
        try await untilTrue("u2 has the conversation") { b.conversations().contains { $0.convId == conv } }
        let r1 = try await b.report(.user(u1, reason: .spam))
        XCTAssertNotNil(r1.range(of: ID, options: .regularExpression))
        let groupId = uid("g")  // a hosted group (admin API): no friendship needed
        try await server.admin("POST", "/admin/groups", ["groupId": groupId, "name": "ZXQ 举报群", "members": [u1, u2]])
        try await untilTrue("u2 in the group") { b.conversations().contains { $0.convId == groupConvId(groupId) } }
        let r2 = try await b.report(.group(groupId, reason: .illegal))
        XCTAssertNotNil(r2.range(of: ID, options: .regularExpression))

        // A c2c conversation I am not in never leaves the SDK (local 4000, frontend-chat 91); the server's 4040 is
        // tested with a group message from a non-member.
        let local = await errorOf { _ = try await c.report(.message(convId: conv, msgIds: [m.msgId!], reason: .abuse)) }
        XCTAssertEqual((local as? IMError)?.code, 4000)
        XCTAssertEqual((local as? IMError)?.details?["field"], "convId")
        let gm = try await sent(a, groupConvId(groupId), "ZXQ-RPT-5")
        let e1 = await errorOf {
            _ = try await c.report(.message(convId: groupConvId(groupId), msgIds: [gm.msgId!], reason: .abuse))
        }
        let e2 = await errorOf { _ = try await c.report(.user(self.uid("nobody"), reason: .abuse)) }
        for e in [e1, e2] {
            XCTAssertEqual((e as? IMError)?.code, 4040, "\(String(describing: e))")
            XCTAssertEqual((e as? IMError)?.reason, "reportTargetInvalid")
        }
        XCTAssertEqual((e1 as? IMError)?.message, (e2 as? IMError)?.message)
    }
}

/// FE-692 (C6) 4510 against a real im-server with a word list (BE-493, BE-494; the caller needs moderation.words).
@MainActor
final class BlockedIntegrationTests: ModerationC6Case {
    nonisolated(unsafe) static var srv: TestServer?
    override var server: TestServer { BlockedIntegrationTests.srv! }

    override func setUp() async throws {
        try await super.setUp()
        if BlockedIntegrationTests.srv == nil {
            var env = MOD_ENV
            env["IM_REGISTER_MODE"] = "invite"
            let s = try await TestServer.start(env: env, extraScopes: ["moderation.words", "social.friends"])
            BlockedIntegrationTests.srv = s
            try await s.signed("POST", "/admin/moderation/words", ["word": WORD])
        }
    }

    override class func tearDown() {
        srv?.stop()
        srv = nil
        super.tearDown()
    }

    // TC-MOD-02-09 (AC-MOD-02-9, SDK part)
    func testTC_MOD_02_09_blockedMessageFails4510CannotBeRetriedNotDeliveredNotStored() async throws {
        let (u1, u2) = (uid("ba"), uid("bb"))
        try await users(u1, u2)
        let conv = c2cConvId(u1, u2)
        let a = try await login(u1)
        let b = try await login(u2)
        try await sent(a, conv, "先发一条正常的")
        var failed: [SendFailure] = []
        let sub = a.on { if case .sendFailed(_, _, let e) = $0 { failed.append(e) } }
        defer { sub.cancel() }
        // The word list applies within 10 seconds (AC-MOD-01-1): a new message every 500 ms until one is blocked.
        var blocked: Message?
        let deadline = Date().addingTimeInterval(11)
        while blocked == nil, Date() < deadline {
            guard case .ok(let m0) = try a.send(conv, "含 \(WORD) 的消息 \(Date().timeIntervalSince1970)") else {
                throw TestServerError("send rejected")
            }
            let m = try await until("settled") {
                a.messages(conv).first { $0.clientMsgId == m0.clientMsgId && $0.status != .sending }
            }
            if m.status == .failed { blocked = m } else { try await sleepMs(500) }
        }
        let m = try XCTUnwrap(blocked)
        XCTAssertEqual(m.error, .code(4510))
        XCTAssertNil(m.errorReason)
        XCTAssertFalse(a.canRetry(m))
        XCTAssertEqual(failed.last, .code(4510))
        a.retry(conv, m.clientMsgId)
        try await sleepMs(2_000)
        XCTAssertEqual(a.messages(conv).first { $0.clientMsgId == m.clientMsgId }?.status, .failed)
        XCTAssertFalse(b.messages(conv).contains { $0.clientMsgId == m.clientMsgId })
        _ = try await b.loadHistory(conv)
        XCTAssertFalse(b.messages(conv).contains { $0.clientMsgId == m.clientMsgId })
    }

    func testGroupNameWithTheWordIs4510WithoutDetails() async throws {
        let (u1, u2, u3) = (uid("bc"), uid("bd"), uid("be"))
        try await users(u1, u2, u3)
        // The word check of groupCreate comes after the invitee checks (F-MOD-02 rule 5, backend-chat 112, BE-499 issue 137):
        // the invitees must be friends or the answer is 4035 first. Control: the same members with a plain name work.
        try await server.signed("POST", "/admin/friends/import", ["pairs": [u2, u3].map { ["a": u1, "b": $0] }])
        let a = try await login(u1)
        let ok = try await a.createGroup(name: "正常群名", members: [u2, u3])
        XCTAssertFalse(ok.groupId.isEmpty)
        let e = await errorOf { _ = try await a.createGroup(name: "群 \(WORD)", members: [u2, u3]) }
        XCTAssertEqual((e as? IMError)?.code, 4510, "\(String(describing: e))")
        XCTAssertNil((e as? IMError)?.details)
    }

    func testRegisterAndProfileNicknameWithTheWordAre451_4510WithoutDetails() async throws {
        func invite() async throws -> String {
            let r = try await server.signed(
                "POST", "/admin/invites",
                ["count": 1, "maxUses": 1, "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000])
            return (r["invites"] as! [[String: Any]])[0]["code"] as! String
        }
        let password = "Tt-good-pass-2026!"
        let username = "mod_\(uid(""))"
        var o = AccountClientOptions(baseUrl: server.httpURL)
        o.systemEvents = false
        o.store = MemoryStore()
        o.logger = log
        let account = AccountClient(options: o)
        let e1 = await errorOf {
            _ = try await account.register(
                username: username, password: password, nickname: "昵称\(WORD)", inviteCode: try await invite())
        }
        XCTAssertEqual((e1 as? AccountError)?.status, 451, "\(String(describing: e1))")
        XCTAssertEqual((e1 as? AccountError)?.code, 4510)
        XCTAssertNil((e1 as? AccountError)?.details)
        let r = try await account.register(
            username: username, password: password, nickname: "正常昵称", inviteCode: try await invite())
        if let gen = r.recoveryCodeGen { try await account.ackRecoveryCode(gen: gen) }
        let e2 = await errorOf { try await account.updateProfile(nickname: "新\(WORD)") }
        XCTAssertEqual((e2 as? AccountError)?.status, 451, "\(String(describing: e2))")
        XCTAssertEqual((e2 as? AccountError)?.code, 4510)
        XCTAssertNil((e2 as? AccountError)?.details)
    }
}
#endif
