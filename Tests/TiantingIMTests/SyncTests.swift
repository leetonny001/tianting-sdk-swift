import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let AB = "c2c:alice:bob"

/// Port of sdk-ts test/sync.test.ts (FE-004).
@MainActor
final class SyncTests: IMTestCase {
    // AC-MSG-04-3
    func testGapTriggersSyncAfter500ms() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1)))
        c.receive(msgFrame(msg(AB, 3)))
        h.clock.advance(499)
        XCTAssertEqual(c.frames("sync").count, 0)
        h.clock.advance(1)
        await flush()
        XCTAssertEqual(c.last("sync")?.data, ["convId": .string(AB), "afterSeq": 1, "limit": 200])
        c.ack("sync", ["messages": [msg(AB, 2), msg(AB, 3)], "hasMore": false])
        await flush()
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [1, 2, 3])
    }

    // AC-MSG-04-4
    func testGapFilledWithin500msDoesNotSync() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1)))
        c.receive(msgFrame(msg(AB, 3)))
        h.clock.advance(200)
        c.receive(msgFrame(msg(AB, 2)))
        h.clock.advance(400)
        await flush()
        XCTAssertEqual(c.frames("sync").count, 0)
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [1, 2, 3])
    }

    // AC-MSG-02-4
    func testOutOfOrderDisplaysBySeq() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 3)))
        c.receive(msgFrame(msg(AB, 2)))
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [2, 3])
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.msgId, "\(AB)#3")
    }

    // F-MSG-04 rule 1
    func testDedupeByMsgId() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1)))
        c.receive(msgFrame(msg(AB, 1)))
        XCTAssertEqual(h.im.messages(AB).count, 1)
        XCTAssertEqual(h.im.conversations()[0].unread, 1)
        // The duplicate changes nothing, so the UI is not told about it either.
        var notified = 0
        h.im.on {
            if case .messages = $0 { notified += 1 }
        }
        c.receive(msgFrame(msg(AB, 1)))
        XCTAssertEqual(notified, 0)
    }

    // AC-CONN-01-4, TC-CONN-01-08
    func testReconnectCatchesUpOnlyBehindLoadedConversations() async {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login("alice", convs: [conv(AB), conv("c2c:alice:carol")])
        c1.receive(msgFrame(msg(AB, 1)))
        c1.receive(msgFrame(msg(AB, 2)))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack(
            "convs",
            ["convs": [conv(AB, maxSeq: 5, unread: 3), conv("c2c:alice:carol", maxSeq: 9, unread: 9)], "truncated": false])
        await flush()
        // carol's conversation was never loaded, so it is not caught up.
        XCTAssertEqual(c2.frames("sync").map(\.data), [["convId": .string(AB), "afterSeq": 2, "limit": 200]])
        c2.ack("sync", ["messages": [msg(AB, 2), msg(AB, 3), msg(AB, 4), msg(AB, 5)], "hasMore": false])
        await flush()
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [1, 2, 3, 4, 5])
    }

    // C-24, TC-CONN-01-21
    func testCatchUpStartsAtMaxOfLocalAndMinSeq() async {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login("alice", convs: [conv("group:g1", maxSeq: 3)])
        c1.receive(msgFrame(msg("group:g1", 3)))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv("group:g1", maxSeq: 12, minSeq: 11, unread: 2)], "truncated": false])
        await flush()
        XCTAssertEqual(c2.last("sync")?.data, ["convId": "group:g1", "afterSeq": 10, "limit": 200])
    }

    // AC-CONN-01-8
    func testLargeGapLoadsNewestPageThenPages() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login("alice", convs: [conv(AB)])
        c1.receive(msgFrame(msg(AB, 1)))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 251, unread: 250)], "truncated": false])
        await flush()
        XCTAssertEqual(c2.last("sync")?.data, ["convId": .string(AB), "beforeSeq": 252, "limit": 20])
        c2.ack("sync", ["messages": .array((0..<20).map { msg(AB, 232 + Int64($0)) }), "hasMore": true])
        await flush()
        XCTAssertEqual(h.im.messages(AB).map(\.seq), (0..<20).map { 232 + Int64($0) })

        async let more = h.im.loadHistory(AB)
        await flush()
        XCTAssertEqual(c2.last("sync")?.data, ["convId": .string(AB), "beforeSeq": 232, "limit": 20])
        c2.ack("sync", ["messages": .array((0..<20).map { msg(AB, 212 + Int64($0)) }), "hasMore": true])
        let hasMore = try await more
        XCTAssertTrue(hasMore)
        XCTAssertEqual(h.im.messages(AB)[0].seq, 212)
    }

    // F-MSG-05
    func testLoadHistoryFirstPage() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 3, unread: 3)])
        async let p = h.im.loadHistory(AB)
        await flush()
        XCTAssertEqual(c.last("sync")?.data, ["convId": .string(AB), "beforeSeq": 4, "limit": 20])
        c.ack("sync", ["messages": [msg(AB, 1), msg(AB, 2), msg(AB, 3)], "hasMore": false])
        let first = try await p
        XCTAssertFalse(first)
        let n = c.frames().count
        let again = try await h.im.loadHistory(AB)
        XCTAssertFalse(again)
        XCTAssertEqual(c.frames().count, n)
    }

    // F-GRP-03, AC-CONN-01-7
    func testConvAddedAndRemoved() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice")
        c.receive(event("convAdded", ["conv": conv("group:g1", name: "新群", updatedAt: 5)]))
        XCTAssertEqual(h.im.conversations().map(\.name), ["新群"])
        c.receive(event("convRemoved", ["convId": "group:g1"]))
        XCTAssertEqual(h.im.conversations(), [])
        let removed = h.events.compactMap { e -> String? in
            if case .convRemoved(let id, _) = e { return id }
            return nil
        }
        XCTAssertEqual(removed, ["group:g1"])
    }

    // AC-CONV-01-2, AC-CONV-01-4
    func testConversationOrder() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login(
            "alice",
            convs: [conv("group:gB", updatedAt: 100), conv("c2c:alice:bob", updatedAt: 100), conv("group:ga", updatedAt: 50)])
        XCTAssertEqual(h.im.conversations().map(\.convId), ["c2c:alice:bob", "group:gB", "group:ga"])
        c.receive(msgFrame(msg("group:ga", 1, from: "carol", text: "最新", ts: 200)))
        let first = h.im.conversations()[0]
        XCTAssertEqual(first.convId, "group:ga")
        XCTAssertEqual(first.lastMsg?.text, "最新")
        XCTAssertEqual(first.lastMsg?.from, "carol")
        XCTAssertEqual(first.lastMsg?.ts, 200)
    }

    func testStrangerFirstMessageCreatesConversation() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice")
        c.receive(msgFrame(msg("c2c:alice:zed", 1, from: "zed")))
        XCTAssertEqual(h.im.conversations()[0].convId, "c2c:alice:zed")
        XCTAssertEqual(h.im.conversations()[0].name, "zed")
        XCTAssertEqual(h.im.conversations()[0].unread, 1)
    }

    // C-34, AC-SYNC-01-2
    func testOwnMessageFromOtherDeviceAdvancesRead() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 2, unread: 2)])
        c.receive(msgFrame(msg(AB, 3, from: "alice")))
        XCTAssertEqual(h.im.conversations()[0].unread, 0)
        XCTAssertEqual(h.im.conversations()[0].readSeq, 3)
    }

    func testPlaceholderRefreshedOnceFromServer() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice")
        let before = c.frames("convs").count
        c.receive(msgFrame(msg("c2c:alice:zed", 1, from: "zed")))
        c.receive(msgFrame(msg("c2c:alice:zed", 2, from: "zed")))
        XCTAssertEqual(h.im.conversations()[0].name, "zed")
        h.clock.advance(200)
        await flush()
        XCTAssertEqual(c.frames("convs").count, before + 1)
        c.ack("convs", ["convs": [conv("c2c:alice:zed", name: "小泽", maxSeq: 2, unread: 2)], "truncated": false])
        await flush()
        XCTAssertEqual(h.im.conversations()[0].name, "小泽")
        XCTAssertEqual(h.im.conversations()[0].unread, 2)
        c.receive(msgFrame(msg("c2c:alice:zed", 3, from: "zed")))
        h.clock.advance(1_000)
        await flush()
        XCTAssertEqual(c.frames("convs").count, before + 1)
    }

    // PRD-core: SDKs ignore unknown event types, fields and enum values.
    func testUnknownThingsAreIgnored() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login(
            "alice",
            convs: [
                .object([
                    "convId": "group:g1", "type": "future-type", "name": "g", "maxSeq": 0, "readSeq": 0, "minSeq": 1,
                    "unread": 0, "lastMsg": nil, "updatedAt": 0, "myRole": "superadmin", "newField": ["x": 1],
                ])
            ])
        XCTAssertEqual(h.im.conversations()[0].myRole?.rawValue, "superadmin")
        c.receive(event("someFutureEvent", ["x": 1]))
        c.receive(["cmd": "futureCmd", "data": ["x": 1]])
        c.receive(["cmd": "push", "data": ["pushId": "p1", "type": "goal", "data": [:], "ts": 1]])
        c.receive(["unknownTopLevel": 1, "cmd": "pong"])
        var m = msg("group:g1", 1, from: "bob", text: "x")
        if case .object(var o) = m {
            o["type"] = "video"
            o["futureField"] = ["nested": true]
            m = .object(o)
        }
        c.receive(msgFrame(m))
        XCTAssertEqual(h.im.messages("group:g1")[0].type.rawValue, "video")
        c.receive(event("convRemoved", ["convId": "group:g1", "reason": "future-reason", "extra": 1]))
        XCTAssertEqual(h.im.conversationSnapshot("group:g1")?.reason, "future-reason")
        XCTAssertEqual(h.im.state, .connected)
    }

    // C-07 at the frame level: a large sync result is handled whole.
    func testLargeDownstreamFrame() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB, maxSeq: 200, unread: 200)])
        let body = String(repeating: "字", count: 5000)
        async let p = h.im.loadHistory(AB)
        await flush()
        c.ack("sync", ["messages": .array((1...200).map { msg(AB, Int64($0), text: body) }), "hasMore": false])
        _ = try await p
        XCTAssertEqual(h.im.messages(AB).count, 200)
    }
}
