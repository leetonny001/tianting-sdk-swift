import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// Port of sdk-ts test/connection.test.ts (FE-003).
@MainActor
final class ConnectionTests: IMTestCase {
    private func fatals(_ h: Harness) -> [FatalReason] {
        h.events.compactMap {
            if case .fatal(let r) = $0 { return r }
            return nil
        }
    }

    // C-52
    func testUrlOnlyHasPlatformAndAuthIsFirstFrame() async {
        let h = setup(platform: .pc)
        var states: [ConnState] = []
        h.im.on {
            if case .state(let s) = $0 { states.append(s) }
        }
        h.im.connect(token: "secret-token-xyz")
        let c = h.transport.current
        XCTAssertEqual(c.url, "ws://im.test/ws?platform=pc")
        XCTAssertFalse(c.url.contains("secret"))
        c.open()
        XCTAssertEqual(c.frames()[0].cmd, "auth")
        XCTAssertEqual(c.frames()[0].data, ["token": "secret-token-xyz"])
        XCTAssertEqual(h.im.state, .connecting)
        c.ack("auth", ["userId": "alice", "serverTime": 1])
        XCTAssertEqual(h.im.state, .connected)
        XCTAssertEqual(h.im.userId, "alice")
        XCTAssertEqual(states, [.connecting, .connected])
        await flush()
        XCTAssertNotNil(c.last("convs"))
    }

    // AC-CONN-01-6
    func testHeartbeatAndPongTimeout() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        h.clock.advance(30_000)
        XCTAssertEqual(c.sent.filter { $0 == "{\"cmd\":\"ping\"}" }.count, 1)
        c.receive(["cmd": "pong"])
        h.clock.advance(30_000)
        XCTAssertEqual(c.sent.filter { $0 == "{\"cmd\":\"ping\"}" }.count, 2)
        h.clock.advance(9_999)
        XCTAssertEqual(h.im.state, .connected)
        h.clock.advance(1)
        XCTAssertEqual(h.im.state, .disconnected)
        XCTAssertNotNil(c.closedWith)
        h.clock.advance(1_000)
        XCTAssertEqual(h.transport.connections.count, 2)
    }

    // AC-CONN-01-5, C-22
    func testBackoffSequenceAndReset() async {
        let h = setup()
        h.im.connect(token: "t")
        var gaps: [Int64] = []
        for _ in 0..<7 {
            h.transport.current.drop(1006)
            let before = h.transport.connections.count
            var waited: Int64 = 0
            while h.transport.connections.count == before {
                h.clock.advance(100)
                waited += 100
            }
            gaps.append(waited)
        }
        XCTAssertEqual(gaps, [1000, 2000, 4000, 8000, 16000, 30000, 30000])
        await h.login()
        h.transport.current.drop(1006)
        h.clock.advance(999)
        XCTAssertEqual(h.transport.connections.count, 8)
        h.clock.advance(1)
        XCTAssertEqual(h.transport.connections.count, 9)
    }

    func testJitterWithinTwentyPercent() {
        for (r, want) in [(0.0, Int64(800)), (0.999999, Int64(1200))] {
            let h = setup(random: r)
            h.im.connect(token: "t")
            h.transport.current.drop(1006)
            h.clock.advance(want - 1)
            XCTAssertEqual(h.transport.connections.count, 1)
            h.clock.advance(1)
            XCTAssertEqual(h.transport.connections.count, 2)
        }
    }

    // F-CONN-01 rule 3
    func testNetworkOnlineReconnectsImmediately() {
        let h = setup()
        h.im.connect(token: "t")
        h.transport.current.drop(1006)
        h.clock.advance(1_000)
        h.transport.current.drop(1006)
        XCTAssertEqual(h.transport.connections.count, 2)
        h.im.networkOnline()
        XCTAssertEqual(h.transport.connections.count, 3)
    }

    // AC-AUTH-02-4, AC-AUTH-02-10, AC-AUTH-03-5
    func testKickedDoesNotReconnect() async {
        for (reason, code) in [("tokenInvalid", 4010), ("tokenExpired", 4011), ("banned", 4012), ("tooManyConnections", 4429)] {
            let h = setup()
            h.im.connect(token: "t")
            let c = await h.login()
            c.receive(event("kicked", ["reason": .string(reason)]))
            c.drop(code, reason)
            XCTAssertEqual(fatals(h), [.kicked(reason: reason, code: code, until: nil)])
            h.clock.advance(120_000)
            XCTAssertEqual(h.transport.connections.count, 1)
        }
    }

    func testNonReconnectingCloseCodesWithoutKick() {
        for code in [1000, 4009, 4010, 4011, 4012, 4429] {
            let h = setup()
            h.im.connect(token: "t")
            h.transport.current.drop(code, "x")
            XCTAssertEqual(fatals(h), [.closed(code: code, reason: "x")])
            h.clock.advance(60_000)
            XCTAssertEqual(h.transport.connections.count, 1, "code \(code)")
        }
    }

    // C-55, C-52, ERRORS.md section 4
    func testReconnectingCloseCodes() async {
        let cases: [(Int, String?)] = [(1001, "serverShutdown"), (1001, nil), (1006, nil), (1011, nil), (4400, nil), (4401, nil), (4408, nil), (4999, nil)]
        for (code, kicked) in cases {
            let h = setup()
            h.im.connect(token: "t")
            let c = await h.login()
            if let kicked { c.receive(event("kicked", ["reason": .string(kicked)])) }
            c.drop(code)
            h.clock.advance(1_000)
            XCTAssertEqual(fatals(h), [], "code \(code)")
            XCTAssertEqual(h.transport.connections.count, 2, "code \(code)")
        }
    }

    // AC-AUTH-05-1
    func testLogoutClosesWith1000AndClears() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv("c2c:alice:bob", maxSeq: 1, unread: 1, updatedAt: 1)])
        XCTAssertEqual(h.im.conversations().count, 1)
        h.im.disconnect()
        XCTAssertEqual(c.closedWith?.code, 1000)
        XCTAssertEqual(c.closedWith?.reason, "logout")
        XCTAssertEqual(h.im.state, .disconnected)
        XCTAssertEqual(h.im.conversations(), [])
        h.clock.advance(60_000)
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    // FE-003 item 7: no token, and no message text, in any log line.
    func testLogsCarryNoSecrets() async {
        let h = setup()
        h.im.connect(token: "super-secret-token")
        let c = await h.login()
        c.receive(text: "not json")
        c.receive(event("msgDeleted", ["convId": 1]))
        c.receive(msgFrame(["msgId": "m", "text": "private-text"]))
        _ = try? h.im.send("c2c:alice:bob", "secret-body")
        c.ackError("send", 4042)
        c.drop(1006)
        h.clock.advance(1_000)
        h.transport.current.open()
        let all = h.logs.all.joined(separator: "\n")
        XCTAssertFalse(h.logs.all.isEmpty)
        XCTAssertFalse(all.contains("super-secret-token"))
        XCTAssertFalse(all.contains("secret-body"))
        XCTAssertFalse(all.contains("private-text"))
    }

    // AC-CONN-02-3, F-CONN-02
    func testBanner() async {
        let h = setup()
        var banner: [Bool] = []
        h.im.on {
            if case .banner(let b) = $0 { banner.append(b) }
        }
        h.im.connect(token: "t")
        await h.login()
        banner = []
        h.transport.current.drop(1006)
        h.clock.advance(500)
        h.im.networkOnline()
        await h.login()
        h.clock.advance(5_000)
        XCTAssertEqual(banner, [])

        h.transport.current.drop(1006)
        h.clock.advance(999)
        XCTAssertEqual(banner, [])
        h.clock.advance(1)
        XCTAssertEqual(banner, [true])
        h.clock.advance(1_000)
        await h.login()
        XCTAssertEqual(banner, [true, false])
    }

    func testEventsAsyncStream() async {
        let h = setup()
        let stream = h.im.events()
        var it = stream.makeAsyncIterator()
        h.im.connect(token: "t")
        guard case .state(.connecting)? = await it.next() else {
            return XCTFail("expected connecting state")
        }
    }
}
