import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let AB = "c2c:alice:bob"

@MainActor
func statusOf(_ h: Harness, _ convId: String = AB) -> [String] {
    h.im.messages(convId).map { m in
        var s = "\(m.clientMsgId):\(m.status.rawValue)"
        if let e = m.error { s += "(\(e))" }
        if let q = m.seq { s += "#\(q)" }
        return s
    }
}

/// Port of sdk-ts test/send.test.ts (FE-005).
@MainActor
final class SendTests: IMTestCase {
    func testOnlineSend() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 4, unread: 4)])
        let r = try h.im.send(AB, "  你好  ")
        XCTAssertEqual(r.message?.status, .sending)
        XCTAssertEqual(r.message?.body.text, "你好")
        XCTAssertEqual(
            c.last("send")?.data,
            ["convType": "c2c", "to": "bob", "clientMsgId": "cid-0001", "type": "text", "body": ["text": "你好"]])
        c.ack("send", ["msgId": "m5", "convId": .string(AB), "seq": 5, "ts": 99])
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#5"])
        let v = h.im.conversations()[0]
        XCTAssertEqual([v.maxSeq, v.readSeq, v.unread], [5, 5, 0])
    }

    func testEmptyAndTooLongAreNotSent() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        XCTAssertEqual(try h.im.send(AB, " \n "), .empty)
        XCTAssertEqual(try h.im.send(AB, String(repeating: "字", count: 5001)), .tooLong(over: 1))
        XCTAssertEqual(c.frames("send").count, 0)
    }

    func testMalformedConvIdIsRejectedBeforeQueueing() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        XCTAssertThrowsError(try h.im.send("nonsense", "hi"))
        XCTAssertEqual(c.frames("send").count, 0)
        XCTAssertEqual(h.im.pendingCount(), 0)
    }

    func testSendBeforeUserKnownThrows() {
        let h = setup()
        XCTAssertThrowsError(try h.im.send(AB, "hi")) { XCTAssertEqual($0 as? IMConnectionError, .notConnected) }
    }

    // AC-MSG-03-1, C-30
    func testTimeoutThenLateAck() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        _ = try h.im.send(AB, "hi")
        h.clock.advance(9_999)
        XCTAssertEqual(statusOf(h), ["cid-0001:sending"])
        h.clock.advance(1)
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:failed(timeout)"])
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1"])
    }

    // AC-MSG-01-9, AC-MSG-07-2, AC-CONV-03-3; FE-140 and PRD-social 10.2: 4035 / 4036 / 4137 / 4292 fail without resend.
    func testErrorCodesPassThroughWithoutResend() async throws {
        for code in [ErrorCode.userNotFound, ErrorCode.rateLimited, ErrorCode.notGroupMember, 4035, 4036, 4137, 4292] {
            let h = setup()
            h.im.connect(token: "t")
            let c = await h.login()
            _ = try h.im.send(AB, "x")
            c.ackError("send", code)
            await flush()
            XCTAssertEqual(statusOf(h), ["cid-0001:failed(\(code))"])
            c.drop(1006)
            let c2 = await h.reconnect()
            XCTAssertEqual(c2.frames("send").count, 0, "code \(code) must not resend")
        }
    }

    // AC-MSG-03-2
    func testOfflineQueueSendsOnceAfterReconnect() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login()
        c1.drop(1006)
        _ = try h.im.send(AB, "offline")
        XCTAssertEqual(statusOf(h), ["cid-0001:queued"])
        let c2 = await h.reconnect()
        XCTAssertEqual(c2.frames("send").map { $0.data?["clientMsgId"] }, ["cid-0001"])
        c2.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1"])
    }

    func testDroppedAfterSendResendsOnce() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login()
        _ = try h.im.send(AB, "x")
        c1.drop(1006)
        XCTAssertEqual(statusOf(h), ["cid-0001:queued"])
        let c2 = await h.reconnect()
        XCTAssertEqual(c2.frames("send").count, 1)
        c2.drop(1006)
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:failed(timeout)"])
    }

    func testAutoResendOnlyOnce() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login()
        c1.drop(1006)
        _ = try h.im.send(AB, "x")
        let c2 = await h.reconnect()
        c2.drop(1006)
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:failed(timeout)"])
    }

    // AC-MSG-03-3, AC-MSG-03-4
    func testManualRetryKeepsClientMsgId() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        _ = try h.im.send(AB, "retry me")
        h.clock.advance(10_000)
        await flush()
        h.im.retry(AB, "cid-0001")
        XCTAssertEqual(c.frames("send").map { $0.data?["clientMsgId"] }, ["cid-0001", "cid-0001"])
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1"])
        XCTAssertEqual(h.im.messages(AB)[0].msgId, "m1")
    }

    func testRetryWhileOfflineQueues() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        _ = try h.im.send(AB, "x")
        c.ackError("send", 4290)
        c.drop(1006)
        h.im.retry(AB, "cid-0001")
        XCTAssertEqual(statusOf(h), ["cid-0001:queued"])
        let c2 = await h.reconnect()
        XCTAssertEqual(c2.frames("send").count, 1)
    }

    // AC-UI-09-5, G-UI-14
    func testRemoveFailed() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        _ = try h.im.send(AB, "sent one")
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        _ = try h.im.send(AB, "fails")
        h.clock.advance(10_000)
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1", "cid-0002:failed(timeout)"])
        XCTAssertEqual(h.im.pendingCount(), 1)
        let frames = c.frames().count

        XCTAssertFalse(h.im.removeFailed(AB, "cid-0001"))
        XCTAssertFalse(h.im.removeFailed(AB, "nope"))
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1", "cid-0002:failed(timeout)"])

        XCTAssertTrue(h.im.removeFailed(AB, "cid-0002"))
        XCTAssertEqual(statusOf(h), ["cid-0001:sent#1"])
        XCTAssertEqual(h.im.pendingCount(), 0)
        let counts = h.events.compactMap { e -> Int? in
            if case .pendingCount(let n) = e { return n }
            return nil
        }
        XCTAssertEqual(counts.last, 0)
        XCTAssertFalse(h.im.removeFailed(AB, "cid-0002"))
        h.im.retry(AB, "cid-0002")
        XCTAssertEqual(c.frames().count, frames)
    }

    func testRemoveFailedRefusesSending() async throws {
        let h = setup()
        h.im.connect(token: "t")
        await h.login()
        _ = try h.im.send(AB, "sending")
        XCTAssertFalse(h.im.removeFailed(AB, "cid-0001"))
        XCTAssertEqual(statusOf(h), ["cid-0001:sending"])
    }

    func testRemovedMessageStaysGone() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        _ = try h.im.send(AB, "timed out")
        h.clock.advance(10_000)
        await flush()
        h.im.removeFailed(AB, "cid-0001")
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(h.im.messages(AB), [])
        c.receive(msgFrame(msg(AB, 1, from: "alice", text: "timed out", clientMsgId: "cid-0001")))
        await flush()
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertEqual(h.im.pendingCount(), 0)
    }

    // AC-AUTH-03-6
    func testKickFailsPending() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        _ = try h.im.send(AB, "a")
        _ = try h.im.send(AB, "b")
        c.receive(event("kicked", ["reason": "banned"]))
        c.drop(4012, "banned")
        await flush()
        XCTAssertEqual(statusOf(h), ["cid-0001:failed(kicked)", "cid-0002:failed(kicked)"])
    }

    // AC-AUTH-03-6 also covers a queued message to a conversation that is not in the list yet.
    func testKickFailsPendingInConversationNotInList() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [])
        c.drop(1006)
        _ = try h.im.send("c2c:alice:newpeer", "first message")
        let c2 = await h.reconnect()
        c2.receive(event("kicked", ["reason": "banned"]))
        c2.drop(4012)
        await flush()
        XCTAssertEqual(statusOf(h, "c2c:alice:newpeer"), ["cid-0001:failed(kicked)"])
    }

    // F-MSG-03 rule 3
    func testUnconfirmedSortAfterSeqMessages() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        _ = try h.im.send(AB, "mine")
        c.receive(msgFrame(msg(AB, 1, from: "bob", text: "hi", clientMsgId: "b1", msgId: "x")))
        XCTAssertEqual(h.im.messages(AB).map(\.clientMsgId), ["b1", "cid-0001"])
        c.ack("send", ["msgId": "m2", "convId": .string(AB), "seq": 2, "ts": 2])
        await flush()
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [1, 2])
    }

    // PRD-social 10.2: generated clientMsgIds never start with "tip-".
    func testDefaultClientMsgIdShape() {
        var o = IMClientOptions(url: "ws://x/ws")
        o.systemEvents = false
        o.transport = FakeTransport()
        let id = o.newId?() ?? UUID().uuidString.lowercased()
        XCTAssertFalse(id.hasPrefix("tip-"))
        XCTAssertGreaterThanOrEqual(id.count, 8)
    }
}

/// Port of sdk-ts test/read.test.ts (FE-006).
@MainActor
final class ReadTests: IMTestCase {
    // AC-CONV-02-2
    func testReportsLatestSeqAndClearsLocally() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 3, unread: 3)])
        h.im.setActiveConversation(AB)
        XCTAssertEqual(c.last("read")?.data, ["convId": .string(AB), "seq": 3])
        XCTAssertEqual(h.im.conversations()[0].unread, 0)
        XCTAssertEqual(h.im.conversations()[0].readSeq, 3)
    }

    // AC-CONV-02-7
    func testBackgroundDoesNotReport() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        h.visible = false
        h.im.setActiveConversation(AB)
        c.receive(msgFrame(msg(AB, 1)))
        c.receive(msgFrame(msg(AB, 2)))
        XCTAssertEqual(c.frames("read").count, 0)
        XCTAssertEqual(h.im.conversations()[0].unread, 2)
        h.visible = true
        h.im.visibilityChanged()
        XCTAssertEqual(c.last("read")?.data, ["convId": .string(AB), "seq": 2])
        XCTAssertEqual(h.im.conversations()[0].unread, 0)
    }

    // TC-CONV-02-03
    func testThrottle() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        h.im.setActiveConversation(AB)
        for s in 1...5 {
            c.receive(msgFrame(msg(AB, Int64(s))))
            h.clock.advance(100)
        }
        XCTAssertEqual(c.frames("read").map { $0.data?["seq"] }, [1])
        h.clock.advance(600)
        XCTAssertEqual(c.frames("read").map { $0.data?["seq"] }, [1, 5])
    }

    func testNotInConversationNoReport() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        h.im.setActiveConversation(nil)
        c.receive(msgFrame(msg(AB, 1)))
        XCTAssertEqual(c.frames("read").count, 0)
    }

    // C-02, TC-CONV-02-09
    func testUnreadCountsFromJoin() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv("group:g1", maxSeq: 15, minSeq: 11, unread: 5)])
        c.receive(event("readUpdated", ["convId": "group:g1", "readSeq": 3]))
        XCTAssertEqual(h.im.conversations()[0].unread, 5)
        c.receive(event("readUpdated", ["convId": "group:g1", "readSeq": 13]))
        XCTAssertEqual(h.im.conversations()[0].unread, 2)
        c.receive(msgFrame(msg("group:g1", 16)))
        XCTAssertEqual(h.im.conversations()[0].unread, 3)
    }

    // AC-SYNC-02-1
    func testReadNeverGoesBack() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 10, unread: 10)])
        c.receive(event("readUpdated", ["convId": .string(AB), "readSeq": 8]))
        c.receive(event("readUpdated", ["convId": .string(AB), "readSeq": 5]))
        XCTAssertEqual(h.im.conversations()[0].readSeq, 8)
        XCTAssertEqual(h.im.conversations()[0].unread, 2)
    }
}

/// Port of sdk-ts test/counts.test.ts and test/snapshots.test.ts (FE-383's behaviors).
@MainActor
final class CountsAndSnapshotsTests: IMTestCase {
    private let G = "group:g1"
    private let AC = "c2c:alice:carol"

    // AC-UI-23-1, AC-UI-23-3
    func testTotalUnread() async {
        let h = setup()
        var totals: [Int] = []
        h.im.on {
            if case .totalUnread(let n) = $0 { totals.append(n) }
        }
        h.im.connect(token: "t")
        let c = await h.login(
            "alice", convs: [conv(AB, maxSeq: 2, unread: 2), conv(AC, maxSeq: 5, unread: 5), conv(G)])
        XCTAssertEqual(h.im.totalUnread(), 7)
        c.receive(msgFrame(msg(AB, 3)))
        XCTAssertEqual(h.im.totalUnread(), 8)
        h.im.setActiveConversation(AC)
        XCTAssertEqual(h.im.totalUnread(), 3)
        XCTAssertEqual(totals, [7, 8, 3])
    }

    // AC-UI-16-2
    func testPendingCount() async throws {
        let h = setup()
        var counts: [Int] = []
        h.im.on {
            if case .pendingCount(let n) = $0 { counts.append(n) }
        }
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        _ = try h.im.send(AB, "one")
        XCTAssertEqual(h.im.pendingCount(), 1)
        h.clock.advance(10_000)
        await flush()
        XCTAssertEqual(h.im.messages(AB)[0].status, .failed)
        XCTAssertEqual(h.im.pendingCount(), 1)
        _ = try h.im.send(AC, "two")
        XCTAssertEqual(h.im.pendingCount(), 2)
        c.ack("send", ["msgId": "m2", "convId": .string(AC), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(h.im.pendingCount(), 1)
        h.im.retry(AB, "cid-0001")
        XCTAssertEqual(h.im.pendingCount(), 1)
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 2])
        await flush()
        XCTAssertEqual(h.im.pendingCount(), 0)
        XCTAssertEqual(counts, [1, 2, 1, 0])
        _ = try h.im.send(AB, "three")
        h.im.disconnect()
        XCTAssertEqual(h.im.pendingCount(), 0)
    }

    // G-UI-22
    func testSendFailedOncePerFailure() async throws {
        let h = setup()
        var got: [String] = []
        h.im.on {
            if case .sendFailed(let conv, let id, let err) = $0 { got.append("\(conv)/\(id)/\(err)") }
        }
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        _ = try h.im.send(AB, "hi")
        c.ackError("send", 4290)
        await flush()
        h.im.retry(AB, "cid-0001")
        c.ackError("send", 4290)
        await flush()
        _ = try h.im.send(AB, "later")
        h.clock.advance(10_000)
        await flush()
        c.ack("send", ["msgId": "m2", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertEqual(got, ["\(AB)/cid-0001/4290", "\(AB)/cid-0001/4290", "\(AB)/cid-0002/timeout"])
    }

    // G-UI-19, AC-UI-90-7: immutable values, only the changed conversation differs.
    func testSnapshotsStable() async {
        let h = setup()
        h.im.connect(token: "t")
        let list = (0..<500).map { conv("c2c:alice:u" + String(format: "%03d", $0), updatedAt: Int64($0)) }
        let c = await h.login("alice", convs: list)
        let before = h.im.conversations()
        XCTAssertEqual(h.im.conversations(), before)
        c.receive(msgFrame(msg("c2c:alice:u250", 1, from: "u250")))
        await flush()
        let after = h.im.conversations()
        let byId = Dictionary(uniqueKeysWithValues: before.map { ($0.convId, $0) })
        XCTAssertEqual(after.filter { byId[$0.convId] != $0 }.map(\.convId), ["c2c:alice:u250"])
    }

    // G-UI-02, G-UI-24
    func testMemberCountAndRefreshThrottle() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G, memberCount: 5), conv("group:g2")])
        XCTAssertEqual(h.im.conversations().first { $0.convId == G }?.memberCount, 5)
        XCTAssertNil(h.im.conversations().first { $0.convId == "group:g2" }?.memberCount)
        XCTAssertFalse(h.im.truncated())

        let n = c.frames("convs").count
        _ = try await h.im.refreshConversations()
        XCTAssertEqual(c.frames("convs").count, n)
        h.clock.advance(29_999)
        _ = try await h.im.refreshConversations()
        XCTAssertEqual(c.frames("convs").count, n)
        h.clock.advance(1)
        async let p = h.im.refreshConversations()
        await flush()
        XCTAssertEqual(c.frames("convs").count, n + 1)
        c.ack("convs", ["convs": [conv(G, memberCount: 7), conv("group:g2")], "truncated": true])
        _ = try await p
        XCTAssertEqual(h.im.conversations().first { $0.convId == G }?.memberCount, 7)
        XCTAssertTrue(h.im.truncated())
    }

    // G-UI-21
    func testRemovedSnapshot() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G, name: "周末球局")])
        c.receive(event("convRemoved", ["convId": .string(G), "reason": "dissolved"]))
        XCTAssertEqual(h.im.conversations(), [])
        XCTAssertEqual(
            h.im.conversationSnapshot(G),
            ConversationSnapshot(convId: G, type: .group, name: "周末球局", removed: true, reason: "dissolved"))
        c.receive(event("convAdded", ["conv": conv(G, name: "周末球局")]))
        XCTAssertNil(h.im.conversationSnapshot(G))
        c.receive(event("convRemoved", ["convId": .string(G)]))
        XCTAssertNotNil(h.im.conversationSnapshot(G))
        XCTAssertNil(h.im.conversationSnapshot(G)?.reason)
        h.im.disconnect()
        XCTAssertNil(h.im.conversationSnapshot(G))
    }

    // G-UI-21: inferred on reconnect; not for c2c; not when truncated.
    func testInferredRemoval() async {
        let h = setup()
        var removed: [String] = []
        h.im.on {
            if case .convRemoved(let id, _) = $0 { removed.append(id) }
        }
        h.im.connect(token: "t")
        await h.login("alice", convs: [conv(G, name: "g1"), conv(AB), conv("group:g2")])
        h.transport.current.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv("group:g2")], "truncated": false])
        await flush()
        XCTAssertEqual(removed, [G])
        XCTAssertEqual(h.im.conversationSnapshot(G)?.name, "g1")
        XCTAssertNil(h.im.conversationSnapshot(AB))

        c2.drop(1006)
        let c3 = await h.reconnect(after: 2_000)
        c3.ack("convs", ["convs": [], "truncated": true])
        await flush()
        XCTAssertEqual(removed, [G])
        XCTAssertNil(h.im.conversationSnapshot("group:g2"))
    }

    // G-UI-26
    func testOpenUnknownConversationErrors() async {
        for code in [4033, 4043, 4032] {
            let h = setup()
            h.im.connect(token: "t")
            let c = await h.login("alice")
            async let p = h.im.loadHistory(G)
            await flush()
            XCTAssertEqual(
                c.last("sync")?.data, ["convId": .string(G), "beforeSeq": 9_007_199_254_740_991, "limit": 20])
            c.ackError("sync", code)
            do {
                _ = try await p
                XCTFail("expected \(code)")
            } catch {
                XCTAssertEqual((error as? IMError)?.code, code)
            }
        }
    }

    func testOpenUnknownConversationWithHistory() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice")
        async let p = h.im.loadHistory(G)
        await flush()
        c.ack("sync", ["messages": [msg(G, 1), msg(G, 2)], "hasMore": false])
        let more = try await p
        XCTAssertFalse(more)
        XCTAssertEqual(h.im.messages(G).map(\.seq), [1, 2])
        XCTAssertEqual(h.im.conversations().map(\.convId), [G])

        async let q = h.im.loadHistory(AB)
        await flush()
        c.ack("sync", ["messages": [], "hasMore": false])
        let more2 = try await q
        XCTAssertFalse(more2)
        XCTAssertEqual(h.im.conversations().map(\.convId), [G])
    }
}
