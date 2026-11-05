#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// SDK against a real server over a real URLSessionWebSocketTask (sdk-ts test/integration/sdk.test.ts).
final class CoreIntegrationTests: IntegrationCase {
    func testC2CSendReceiveUnreadRead() async throws {
        let (aid, bid) = (uid("alice"), uid("bob"))
        try await importUsers([bid], nicknames: [bid: "鲍勃"])
        let alice = try await login(aid)
        let bob = try await login(bid)
        let cid = c2cConvId(aid, bid)
        _ = try sendOK(alice, cid, "  你好 👋  ")
        try await untilTrue("ack") { alice.messages(cid).first?.status == .sent }
        XCTAssertEqual(alice.messages(cid)[0].seq, 1)
        XCTAssertEqual(alice.messages(cid)[0].body.text, "你好 👋")
        // First chat: a stand-in conversation is replaced with server data, so the name becomes the nickname.
        try await untilTrue("refreshed from server") { conv(alice, cid)?.name == "鲍勃" }
        XCTAssertEqual(conv(alice, cid)?.unread, 0)
        XCTAssertEqual(conv(alice, cid)?.readSeq, 1)

        let got = try await until("bob receives") { bob.messages(cid).first }
        XCTAssertEqual(got.from, aid)
        XCTAssertEqual(got.seq, 1)
        XCTAssertEqual(got.status, .sent)
        try await untilTrue("bob unread 1") { conv(bob, cid)?.unread == 1 }
        bob.setActiveConversation(cid)
        try await untilTrue("bob read") { conv(bob, cid)?.unread == 0 }
        // The server recorded it too (AC-CONV-02-2): a fresh login sees 0.
        try await sleepMs(100)
        let bob2 = try await login(bid)
        try await untilTrue("bob2 convs") { conv(bob2, cid) != nil }
        XCTAssertEqual(conv(bob2, cid)?.unread, 0)
    }

    // AC-CONV-03-3
    func testSendToUnknownUserPassesCodeThrough() async throws {
        let a = uid("alice")
        let alice = try await login(a)
        let cid = c2cConvId(a, "ghost-\(a)")
        _ = try sendOK(alice, cid, "hi?")
        let m = try await until("failed") { alice.messages(cid).first { $0.status == .failed } }
        XCTAssertEqual(m.error, .code(4042))
    }

    // AC-MSG-03-4
    func testLostAckThenManualRetryDedupes() async throws {
        let (aid, bid) = (uid("alice"), uid("bob"))
        try await importUsers([bid])
        let lostId = "lost-ack-\(aid)"
        let alice = client(newId: { lostId }) { $0.sendTimeoutMs = 800 }
        _ = try await login(aid, alice)
        let bob = try await login(bid)
        let cid = c2cConvId(aid, bid)
        try await srv.admin("POST", "/admin/test/drop-ack", ["clientMsgId": lostId])
        _ = try sendOK(alice, cid, "lost ack")
        let fromBob = try await until("bob receives") { bob.messages(cid).first }
        try await untilTrue("times out") { alice.messages(cid).first?.status == .failed }
        alice.retry(cid, lostId)
        try await untilTrue("retry sent") { alice.messages(cid).first?.status == .sent }
        try await sleepMs(300)
        XCTAssertEqual(bob.messages(cid).count, 1)
        XCTAssertEqual(alice.messages(cid).count, 1)
        XCTAssertEqual(alice.messages(cid)[0].msgId, fromBob.msgId)
        XCTAssertEqual(alice.messages(cid)[0].seq, 1)
    }

    func testConvAddedAndGroupMessage() async throws {
        let (aid, cid2) = (uid("alice"), uid("carol"))
        let alice = try await login(aid)
        let carol = try await login(cid2)
        let g = uid("g")
        try await srv.admin("POST", "/admin/groups", ["groupId": g, "name": "测试群", "members": [aid, cid2]])
        let convId = groupConvId(g)
        try await untilTrue("convAdded") { conv(carol, convId) != nil }
        XCTAssertEqual(conv(carol, convId)?.name, "测试群")
        _ = try sendOK(alice, convId, "hello group")
        try await untilTrue("carol receives") { carol.messages(convId).contains { $0.body.text == "hello group" } }
    }

    // AC-AUTH-03-2, AC-AUTH-03-5: and the real close code reaches the SDK as 4012.
    func testForceLogoutStopsReconnecting() async throws {
        let a = uid("alice")
        let alice = try await login(a)
        let log = EventLog(alice)
        try await srv.admin("POST", "/admin/users/\(a)/force-logout", [:])
        try await untilTrue("fatal") { !log.fatal.isEmpty }
        XCTAssertEqual(log.fatal[0], .kicked(reason: "banned", code: 4012, until: nil))
        try await sleepMs(400)
        XCTAssertEqual(alice.state, .disconnected)
    }

    // A bad token: the server closes with 4010 and the SDK stops (ERRORS.md section 4).
    func testBadTokenIsFatal() async throws {
        let im = client()
        let log = EventLog(im)
        im.connect(token: "not-a-real-token")
        try await untilTrue("fatal") { !log.fatal.isEmpty }
        XCTAssertEqual(log.fatal[0], .kicked(reason: "tokenInvalid", code: 4010, until: nil))
        try await sleepMs(300)
        XCTAssertEqual(im.state, .disconnected)
    }

    // C-07: a downstream frame well over URLSession's default 1 MiB limit.
    func testDownstreamFrameOverOneMebibyte() async throws {
        let (aid, bid) = (uid("alice"), uid("bob"))
        try await importUsers([bid])
        let alice = try await login(aid)
        let cid = c2cConvId(aid, bid)
        let body = String(repeating: "字", count: 4990)  // Almost 15 KB in UTF-8.
        for i in 0..<80 {
            _ = try sendOK(alice, cid, body + String(i))
            if i % 15 == 14 { try await sleepMs(1100) }  // Rate limit: 20 per second.
        }
        try await untilTrue("all sent", timeout: 20) {
            alice.messages(cid).filter { $0.status == .sent }.count == 80
        }
        let reader = try await login(bid)
        try await untilTrue("reader convs") { conv(reader, cid) != nil }
        let more = try await reader.loadHistory(cid, limit: 200)
        XCTAssertFalse(more)
        XCTAssertEqual(reader.messages(cid).count, 80)
        XCTAssertEqual(reader.state, .connected)
    }

    // AC-CONN-01-4: disconnected by the server (4408), reconnects by itself, catches up in order.
    func testServerDisconnectReconnectsAndCatchesUp() async throws {
        let idle = try await TestServer.start(env: ["IM_IDLE_TIMEOUT": "1s"])
        defer { idle.stop() }
        let (aid, bid) = (uid("alice"), uid("bob"))
        try await idle.admin("POST", "/admin/users/import", ["users": [["userId": bid]]])
        let alice = client(url: idle.wsURL) {
            $0.heartbeatMs = 60_000
            $0.backoffBaseMs = 200
        }
        let bob = client(url: idle.wsURL) { $0.heartbeatMs = 300 }
        alice.connect(token: try await idle.token(aid))
        bob.connect(token: try await idle.token(bid))
        try await untilTrue("both connected") { alice.state == .connected && bob.state == .connected }
        let cid = c2cConvId(aid, bid)
        _ = try sendOK(bob, cid, "m1")
        try await untilTrue("first message") { alice.messages(cid).count == 1 }
        var states: [ConnState] = []
        alice.on {
            if case .state(let s) = $0 { states.append(s) }
        }
        try await untilTrue("idle disconnect") { states.contains(.disconnected) }
        for t in ["m2", "m3", "m4"] { _ = try sendOK(bob, cid, t) }
        try await untilTrue("caught up", timeout: 10) { alice.messages(cid).count == 4 }
        XCTAssertEqual(alice.messages(cid).map(\.body.text), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(alice.messages(cid).map(\.seq), [1, 2, 3, 4])
    }
}
#endif
