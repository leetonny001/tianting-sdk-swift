import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-682 (C5): pin, notifications off, delete a conversation, multi-device sync, the total unread (PRD-chat section 9,
// F-CVS-01..04, 13.1). The real IMClient on FakeTransport and a fake clock; the frames the tests send down are checked
// against frame.schema.json like everything the SDK sends up (IMTestCase). Same cases as sdk-ts test/conv-settings.test.ts
// (tianting-sdk-ts@97124bd). The local database and the cache folder are in ConvSettingsPersistenceTests. The shared
// chat-sync.json has no C5 cases yet (BE-487). Local `swift test` results, CI not running.

let CVS_AB = "c2c:alice:bob"
let CVS_AC = "c2c:alice:carol"
let CVS_G1 = "group:g1"
let CVS_G2 = "group:g2"
private let AB = CVS_AB
private let AC = CVS_AC
private let G1 = CVS_G1
private let G2 = CVS_G2

/// A schema-valid conversation (groups carry memberCount, myRole, modVer) with the C5 fields.
func sc(
    _ convId: String, name: String? = nil, maxSeq: Int64 = 0, readSeq: Int64 = 0, minSeq: Int64 = 1, unread: Int64 = 0,
    updatedAt: Int64 = 0, mentionUnread: Int64? = nil, firstMentionSeq: Int64? = nil, pinned: Bool? = nil,
    pinnedAt: Int64? = nil, notifyOff: Bool? = nil
) -> JSONValue {
    let group = convId.hasPrefix("group:")
    guard
        case .object(var o) = conv(
            convId, name: name, maxSeq: maxSeq, readSeq: readSeq, minSeq: minSeq, unread: unread, updatedAt: updatedAt,
            memberCount: group ? 3 : nil, myRole: group ? "member" : nil, modVer: 0, mentionUnread: mentionUnread,
            firstMentionSeq: firstMentionSeq)
    else { return nil }
    if let pinned { o["pinned"] = .bool(pinned) }
    if let pinnedAt { o["pinnedAt"] = .int(pinnedAt) }
    if let notifyOff { o["notifyOff"] = .bool(notifyOff) }
    return .object(o)
}

/// Server to client: checked against the schema first, so the fakes cannot drift from the server.
@MainActor
func down(_ c: FakeConnection, _ frame: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
        (try? SchemaValidator.shared().isValid(frame)) == true, "schema: \(frame.jsonString().prefix(400))", file: file,
        line: line)
    c.receive(frame)
}

@MainActor
func downAck(_ c: FakeConnection, _ cmd: String, _ data: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
    down(c, ["id": .string(c.last(cmd)!.id!), "cmd": "ack", "data": data], file: file, line: line)
}

@MainActor
func downError(_ c: FakeConnection, _ cmd: String, _ code: Int, file: StaticString = #filePath, line: UInt = #line) {
    down(
        c, ["id": .string(c.last(cmd)!.id!), "cmd": "ack", "error": ["code": .int(Int64(code)), "msg": "x"]], file: file,
        line: line)
}

@MainActor
func downEvent(_ c: FakeConnection, _ type: String, _ fields: [String: JSONValue]) {
    down(c, event(type, fields))
}

extension Harness {
    /// Connects, completes auth, answers convs (schema-checked).
    func cvsOnline(_ convs: [JSONValue], _ userId: String = "alice", extra: [String: JSONValue] = [:]) async -> FakeConnection {
        im.connect(token: "token-value")
        let c = transport.current
        c.open()
        c.ack("auth", ["userId": .string(userId), "serverTime": .int(clock.now())])
        await flush()
        var data: [String: JSONValue] = ["convs": .array(convs), "truncated": false]
        for (k, v) in extra { data[k] = v }
        downAck(c, "convs", .object(data))
        await settle()
        return c
    }

    /// Drops the connection, reconnects after the backoff, answers convs with `convsAck`.
    func cvsReconnect(_ c: FakeConnection, _ convsAck: [String: JSONValue]) async -> FakeConnection {
        c.drop()
        clock.advance(60_000)
        await flush()
        let n = transport.current
        n.open()
        n.ack("auth", ["userId": "alice", "serverTime": .int(clock.now())])
        await flush()
        downAck(n, "convs", .object(convsAck))
        await settle()
        return n
    }

    /// Opens a conversation: loadHistory answered with `messages`.
    func cvsLoaded(_ c: FakeConnection, _ convId: String, _ messages: [JSONValue]) async throws {
        let t = Task { try await im.loadHistory(convId) }
        await settle()
        downAck(c, "sync", ["messages": .array(messages), "hasMore": false])
        _ = try await t.value
    }

    var ids: [String] { im.conversations().map(\.convId) }

    func find(_ convId: String) -> Conversation? {
        im.conversations().first { $0.convId == convId }
    }

    var convDeletedIds: [String] {
        events.compactMap { if case .convDeleted(let id) = $0 { return id } else { return nil } }
    }

    var removedIds: [String] {
        events.compactMap { if case .convRemoved(let id, _) = $0 { return id } else { return nil } }
    }

    var totals: [Int] {
        events.compactMap { if case .totalUnread(let n) = $0 { return n } else { return nil } }
    }

    var listEvents: Int {
        events.filter { if case .conversations = $0 { return true } else { return false } }.count
    }

    var expiredFiles: [[String]] {
        events.compactMap { if case .filesExpired(let f) = $0 { return f } else { return nil } }
    }

    func dump() -> String { encoded(im.debugExport()) }
}

/// The C5 frame ids: msgIds the schema allows.
func cm(_ convId: String, _ seq: Int64, _ from: String = "bob", _ text: String? = nil) -> JSONValue {
    m(convId, seq, from, text)
}

@MainActor
final class ConvSettingsTests: AccountTestCase {
    private func client() -> Harness {
        setup(heartbeatMs: 10 * 365 * DAY)
    }

    private func code(_ t: Task<Void, Error>) async -> Int? {
        do {
            try await t.value
            return nil
        } catch {
            return (error as? IMError)?.code ?? -1
        }
    }

    // MARK: F-CVS-01 pin

    func testTC_CVS_01_01_pinnedFirstByPinnedAtThenUpdatedAtThenConvIdStableValues() async throws {
        let h = client()
        _ = await h.cvsOnline([
            sc(AB, updatedAt: 300), sc(AC, updatedAt: 100), sc(G1, updatedAt: 50, pinned: true, pinnedAt: 10),
            sc(G2, updatedAt: 1, pinned: true, pinnedAt: 20), sc("c2c:alice:dave", updatedAt: 100),
        ])
        XCTAssertEqual(h.ids, [G2, G1, AB, AC, "c2c:alice:dave"])
        XCTAssertEqual(h.im.conversations(), h.im.conversations())  // G-UI-19
        XCTAssertEqual(h.find(G2)?.pinnedAt, 20)
        XCTAssertNil(h.find(AB)?.pinned)
    }

    /// Same pinnedAt: by updatedAt descending, then convId, as the server's convListOrder (sqlite.go).
    func testPinnedTiesFallBackToUpdatedAtThenConvIdLikeTheServer() async throws {
        let h = client()
        _ = await h.cvsOnline([
            sc(G1, updatedAt: 1, pinned: true, pinnedAt: 10), sc(G2, updatedAt: 5, pinned: true, pinnedAt: 10),
            sc("group:g0", updatedAt: 1, pinned: true, pinnedAt: 10), sc(AB, updatedAt: 9),
        ])
        XCTAssertEqual(h.ids, [G2, "group:g0", G1, AB])
    }

    func testTC_CVS_01_01_setConvPinnedSendsConvSetMovesToTopBeforeTheAckAndTheAckWins() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, updatedAt: 300), sc(G1, updatedAt: 100)])
        let p = Task { try await h.im.setConvPinned(G1, true) }
        await flush()
        XCTAssertEqual(c.last("convSet")?.data, ["convId": .string(G1), "pinned": true])
        XCTAssertEqual(h.ids, [G1, AB])  // Optimistic.
        XCTAssertEqual(h.find(G1)?.pinned, true)
        XCTAssertEqual(h.find(G1)?.pinnedAt, h.clock.now())
        guard case .conversations(let last)? = h.events.last(where: { if case .conversations = $0 { true } else { false } })
        else { return XCTFail("no conversations event") }
        XCTAssertEqual(last.map(\.convId), [G1, AB])
        downAck(c, "convSet", ["conv": sc(G1, updatedAt: 100, pinned: true, pinnedAt: 777)])
        try await p.value
        XCTAssertEqual(h.find(G1)?.pinnedAt, 777)

        let q = Task { try await h.im.setConvPinned(G1, false) }
        await flush()
        XCTAssertEqual(c.last("convSet")?.data, ["convId": .string(G1), "pinned": false])
        XCTAssertEqual(h.ids, [AB, G1])
        XCTAssertNil(h.find(G1)?.pinned)
        XCTAssertNil(h.find(G1)?.pinnedAt)
        downAck(c, "convSet", ["conv": sc(G1, updatedAt: 100)])
        try await q.value
        XCTAssertEqual(h.ids, [AB, G1])
    }

    func testPinningAgainKeepsPinnedAt() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, pinned: true, pinnedAt: 55)])
        h.clock.advance(10_000)
        let p = Task { try await h.im.setConvPinned(G1, true) }
        await flush()
        XCTAssertEqual(h.find(G1)?.pinnedAt, 55)
        downAck(c, "convSet", ["conv": sc(G1, pinned: true, pinnedAt: 55)])
        try await p.value
        XCTAssertEqual(h.find(G1)?.pinnedAt, 55)
    }

    // frontend-chat 56: any error rolls back, is thrown, and is never retried (4290 is retryable in errors.json).
    func testConvSetFailuresRollBackAreThrownAndNotRetried() async throws {
        for errorCode in [5000, ErrorCode.pinLimitExceeded, ErrorCode.rateLimited, 4030] {
            let h = client()
            let c = await h.cvsOnline([sc(AB, updatedAt: 300), sc(G1, updatedAt: 100)])
            let before = h.im.conversations()
            let p = Task { try await h.im.setConvPinned(G1, true) }
            await flush()
            XCTAssertEqual(h.ids, [G1, AB])
            let n = h.listEvents
            downError(c, "convSet", errorCode)
            let got = await code(p)
            XCTAssertEqual(got, errorCode)
            XCTAssertEqual(h.ids, [AB, G1], "\(errorCode)")
            XCTAssertNil(h.find(G1)?.pinned)
            XCTAssertEqual(h.im.conversations(), before)
            XCTAssertEqual(h.listEvents, n + 1, "the rollback is emitted")
            h.clock.advance(60_000)
            await settle()
            XCTAssertEqual(c.frames("convSet").count, 1, "\(errorCode): not retried")
        }
    }

    func testTimeoutAndOfflineRollBackTooNotifyOffAlike() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 3, unread: 3)])
        let p = Task { try await h.im.setConvNotifyOff(AB, true) }
        await flush()
        XCTAssertEqual(h.find(AB)?.notifyOff, true)
        XCTAssertEqual(h.im.totalUnread(), 0)
        h.clock.advance(11_000)
        do {
            try await p.value
            XCTFail("expected a timeout")
        } catch IMConnectionError.timeout(let cmd) {
            XCTAssertEqual(cmd, "convSet")
        }
        XCTAssertNil(h.find(AB)?.notifyOff)
        XCTAssertEqual(h.im.totalUnread(), 3)
        c.drop()
        await flush()
        do {
            try await h.im.setConvNotifyOff(AB, true)
            XCTFail("expected notConnected")
        } catch IMConnectionError.notConnected {}
        XCTAssertNil(h.find(AB)?.notifyOff)
    }

    func testAnotherDevicesChangeWhileWaitingIsNotRolledBack() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1)])
        let p = Task { try await h.im.setConvPinned(G1, true) }
        await flush()
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": true, "pinnedAt": 900, "notifyOff": true])
        downError(c, "convSet", 5000)
        let got = await code(p)
        XCTAssertEqual(got, 5000)
        XCTAssertEqual(h.find(G1)?.pinned, true)
        XCTAssertEqual(h.find(G1)?.pinnedAt, 900)
        XCTAssertEqual(h.find(G1)?.notifyOff, true)
    }

    func testBadConvIdsAreRefusedLocally() async throws {
        let h = client()
        let c = await h.cvsOnline([])
        for id in ["room:r1", "g1", "c2c:bob:carol"] {
            do {
                try await h.im.setConvPinned(id, true)
                XCTFail(id)
            } catch is ConvIdError {}
            do {
                try await h.im.deleteConv(id)
                XCTFail(id)
            } catch is ConvIdError {}
        }
        XCTAssertEqual(c.frames("convSet").count + c.frames("convDelete").count, 0)
        let fresh = client()
        do {
            try await fresh.im.setConvPinned(AB, true)
            XCTFail("before login")
        } catch IMConnectionError.notConnected {}
    }

    // MARK: F-CVS-02 notifications off and the total unread (rule 4)

    func testTC_CVS_02_02_totalUnreadSkipsNotifyOffUnreadEventSameNumber() async throws {
        let h = client()
        let c = await h.cvsOnline([
            sc(AB, maxSeq: 2, unread: 2), sc(AC, maxSeq: 3, unread: 3),
            sc(G1, maxSeq: 5, unread: 5, mentionUnread: 0, notifyOff: true),
        ])
        XCTAssertEqual(h.im.totalUnread(), 5)
        XCTAssertEqual(h.find(G1)?.unread, 5)  // Unread still counted (rule 3); the list shows a dot.
        XCTAssertEqual(h.find(G1)?.isNotifyOff, true)
        h.events = []
        let p = Task { try await h.im.setConvNotifyOff(G1, false) }
        await flush()
        XCTAssertEqual(c.last("convSet")?.data, ["convId": .string(G1), "notifyOff": false])
        XCTAssertEqual(h.im.totalUnread(), 10)
        XCTAssertEqual(h.totals, [10])
        downAck(c, "convSet", ["conv": sc(G1, maxSeq: 5, unread: 5, mentionUnread: 0)])
        try await p.value
        XCTAssertEqual(h.totals, [10])
        let q = Task { try await h.im.setConvNotifyOff(G1, true) }
        await flush()
        downAck(c, "convSet", ["conv": sc(G1, maxSeq: 5, unread: 5, mentionUnread: 0, notifyOff: true)])
        try await q.value
        XCTAssertEqual(h.totals, [10, 5])
        // A new message in a notify-off conversation: the list updates, unread grows, the total stays (rule 6).
        down(c, msgFrame(cm(G1, 6)))
        await flush()
        XCTAssertEqual(h.find(G1)?.unread, 6)
        XCTAssertEqual(h.im.totalUnread(), 5)
        XCTAssertEqual(h.totals, [10, 5])
    }

    func testTC_CVS_02_05_mentionsInNotifyOffCountReadingThemClearsThem() async throws {
        let h = client()
        let c = await h.cvsOnline([
            sc(AB, maxSeq: 2, unread: 2),
            sc(G1, maxSeq: 5, unread: 5, mentionUnread: 1, firstMentionSeq: 3, notifyOff: true),
        ])
        XCTAssertEqual(h.im.totalUnread(), 3)
        try await h.cvsLoaded(c, G1, (1...5).map { cm(G1, $0) })
        h.im.setActiveConversation(G1)
        await settle()
        XCTAssertEqual(c.last("read")?.data, ["convId": .string(G1), "seq": 5])
        XCTAssertEqual(h.im.totalUnread(), 2)
    }

    func testLiveMentionInNotifyOffAddsOne() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 1, readSeq: 1, mentionUnread: 0, notifyOff: true)])
        guard case .object(var at) = cm(G1, 2) else { return XCTFail() }
        at["body"] = ["text": "@alice", "mentions": ["userIds": ["alice"]]]
        down(c, msgFrame(.object(at)))
        down(c, msgFrame(cm(G1, 3)))
        await flush()
        XCTAssertEqual(h.find(G1)?.unread, 2)
        XCTAssertEqual(h.find(G1)?.mentionUnread, 1)
        XCTAssertEqual(h.im.totalUnread(), 1)
    }

    // MARK: F-CVS-03 delete

    func testDeleteConvSendsUpToSeqLocalMaxLeavesTheListBeforeTheAckPurgesAndEmitsConvDeleted() async throws {
        let h = client()
        let c = await h.cvsOnline([
            sc(AB, maxSeq: 8, readSeq: 8, updatedAt: 9, pinned: true, pinnedAt: 1), sc(AC, updatedAt: 1),
        ])
        try await h.cvsLoaded(c, AB, [7, 8].map { cm(AB, $0, "bob", "ZXQ-CVS-1 第 \($0) 条") })
        down(c, msgFrame(cm(AB, 10, "bob", "ZXQ-CVS-1 第 10 条")))  // Newer than convs' maxSeq.
        await flush()
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        XCTAssertEqual(c.last("convDelete")?.data, ["convId": .string(AB), "upToSeq": 10])
        XCTAssertEqual(h.ids, [AC])
        XCTAssertEqual(h.convDeletedIds, [])  // No draft clearing before it succeeded.
        downAck(c, "convDelete", ["clearedSeq": 10])
        try await p.value
        XCTAssertEqual(h.ids, [AC])
        XCTAssertEqual(h.convDeletedIds, [AB])
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertNil(h.im.conversationSnapshot(AB))  // Not "you are no longer in this group".
        XCTAssertEqual(h.removedIds, [])
        XCTAssertFalse(h.dump().contains("ZXQ-CVS-1"))
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-1"))
    }

    func testDeleteFailuresRestoreTheConversationKeepMessagesAndAreNotRetried() async throws {
        for errorCode in [5000, ErrorCode.rateLimited, 4030] {
            let h = client()
            let c = await h.cvsOnline([sc(AB, maxSeq: 2, updatedAt: 9), sc(AC, updatedAt: 1)])
            try await h.cvsLoaded(c, AB, [cm(AB, 1), cm(AB, 2)])
            _ = try h.im.send(AB, "失败的")
            h.clock.advance(11_000)
            await flush()
            let p = Task { try await h.im.deleteConv(AB) }
            await flush()
            XCTAssertEqual(h.ids, [AC])
            downError(c, "convDelete", errorCode)
            let got = await code(p)
            XCTAssertEqual(got, errorCode)
            XCTAssertEqual(h.ids, [AB, AC])
            XCTAssertEqual(h.im.messages(AB).map { "\($0.seq ?? 0):\($0.status.rawValue)" }, ["1:sent", "2:sent", "0:failed"])
            XCTAssertEqual(h.convDeletedIds, [])
            h.clock.advance(60_000)
            await settle()
            XCTAssertEqual(c.frames("convDelete").count, 1)
        }
    }

    func testUpToSeqIsTheLocalMaxEvenWhenALaterConvsIsOlder() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 5, readSeq: 5, updatedAt: 1)])
        try await h.cvsLoaded(c, AB, [cm(AB, 4), cm(AB, 5)])
        h.clock.advance(31_000)
        let r = Task { try await h.im.refreshConversations() }
        await flush()
        downAck(c, "convs", ["convs": [sc(AB, maxSeq: 3, readSeq: 3, updatedAt: 1)], "truncated": false])
        _ = try await r.value
        XCTAssertEqual(h.find(AB)?.maxSeq, 3)
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        XCTAssertEqual(c.last("convDelete")?.data, ["convId": .string(AB), "upToSeq": 5])
        p.cancel()
    }

    func testTC_CVS_03_02_aNewMessageAfterTheDeletionBringsItBackWithOnlyThatMessage() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, name: "Bob", maxSeq: 10, readSeq: 10, updatedAt: 10, notifyOff: true)])
        try await h.cvsLoaded(c, AB, [9, 10].map { cm(AB, $0, "bob", "ZXQ-CVS-1 \($0)") })
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 10])
        try await p.value
        XCTAssertEqual(h.ids, [])
        down(c, msgFrame(cm(AB, 11, "bob", "新的一条")))
        await flush()
        let v = try XCTUnwrap(h.find(AB))
        XCTAssertEqual(v.name, "Bob")
        XCTAssertEqual(v.unread, 1)
        XCTAssertEqual(v.minSeq, 11)
        XCTAssertEqual(v.readSeq, 10)
        XCTAssertEqual(v.maxSeq, 11)
        XCTAssertEqual(v.notifyOff, true)
        XCTAssertNil(v.pinned)
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [11])
        // Paging: nothing before minSeq, no request.
        let n = c.frames().count
        let more = try await h.im.loadHistory(AB)
        XCTAssertFalse(more)
        XCTAssertEqual(c.frames().count, n)
        // The local stand-in is replaced by the server's soon.
        h.clock.advance(300)
        await settle()
        downAck(c, "convs", [
            "convs": [sc(AB, name: "Bob", maxSeq: 11, readSeq: 10, minSeq: 11, unread: 1, notifyOff: true)], "truncated": false,
        ])
        await settle()
        XCTAssertEqual(h.find(AB)?.unread, 1)
        XCTAssertEqual(h.find(AB)?.minSeq, 11)
        XCTAssertFalse(h.dump().contains("ZXQ-CVS-1"))
    }

    func testALateSyncAnswerFromBeforeTheDeletionIsNotWrittenIn() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 30, readSeq: 30, updatedAt: 1)])
        let load = Task { try await h.im.loadHistory(AB) }  // Sent, answered late.
        await flush()
        let syncId = c.last("sync")!.id!
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 30])
        try await p.value
        down(c, ["id": .string(syncId), "cmd": "ack", "data": ["messages": [cm(AB, 29, "bob", "ZXQ-CVS-3")], "hasMore": true]])
        _ = try await load.value
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertEqual(h.ids, [])
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-3"))
    }

    func testMyMessageWhoseLateAckFallsInTheClearedRangeIsGone() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 1, readSeq: 1, updatedAt: 1)])
        guard case .ok(let sent) = try h.im.send(AB, "ZXQ-CVS-8 在路上") else { return XCTFail() }
        await flush()
        let sendId = c.last("send")!.id!
        down(c, msgFrame(cm(AB, 3)))  // Seen before my ack: upToSeq 3 covers my seq 2.
        await flush()
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 3])
        try await p.value
        XCTAssertEqual(h.im.messages(AB).map(\.clientMsgId), [sent.clientMsgId])  // Sending: left alone.
        down(c, ["id": .string(sendId), "cmd": "ack", "data": ["msgId": "m2", "convId": .string(AB), "seq": 2, "ts": 5]])
        await flush()
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertEqual(h.im.pendingCount(), 0)
        XCTAssertEqual(h.ids, [])
    }

    func testDeleteCancelsUploadsDropsQueuedAndFailedLeavesOtherConversations() async throws {
        let h = setupAccount()
        let ab = "c2c:\(USER):bob"
        let ac = "c2c:\(USER):carol"
        h.session(1, DAY)
        let c = await h.online()
        let inputs = h.base.scratch.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let o = inputs.appendingPathComponent("o")
        let t = inputs.appendingPathComponent("t")
        try Data(repeating: 1, count: 1000).write(to: o)
        try Data(repeating: 2, count: 100).write(to: t)
        _ = try h.im.sendImage(ab, ProcessedImage(
            original: LocalUpload(file: o, mime: "image/jpeg"), thumb: LocalUpload(file: t, mime: "image/jpeg"), width: 4,
            height: 3))
        await settle()
        let put: JSONValue = [
            "url": "https://s3.test/chat/tmp/F1?X-Amz-Signature=1", "headers": ["Content-Type": "image/jpeg"], "expiresAt": 1,
        ]
        h.http.to("/v1/files/uploads").last!.respond(200, ["fileId": "F1", "put": put, "thumbPut": put])
        await settle()
        guard case .ok(let failed) = try h.im.send(ab, "ZXQ-CVS-2 失败的") else { return XCTFail() }
        h.clock.advance(11_000)
        await settle()
        XCTAssertEqual(h.im.messages(ab).first(where: { $0.clientMsgId == failed.clientMsgId })?.status, MessageStatus.failed)
        guard case .ok(let other) = try h.im.send(ac, "别的会话") else { return XCTFail() }
        let p = Task { try await h.im.deleteConv(ab) }
        await settle()
        XCTAssertEqual(c.last("convDelete")?.data, ["convId": .string(ab), "upToSeq": 0])
        XCTAssertEqual(h.http.calls.filter { $0.request.method == .delete }.count, 0)  // Only after it succeeded.
        c.ack("convDelete", ["clearedSeq": 0])
        try await p.value
        await settle()
        XCTAssertEqual(h.im.messages(ab), [])
        XCTAssertEqual(h.http.calls.filter { $0.request.method == .delete }.map(\.path), ["/v1/files/uploads/F1"])
        XCTAssertEqual(h.im.pendingCount(), 1)
        XCTAssertEqual(h.im.messages(ac).map(\.clientMsgId), [other.clientMsgId])
        XCTAssertFalse(encoded(h.im.debugExport()).contains("ZXQ-CVS-2"))
    }

    func testPurgedImagesAndFilesGoThroughFilesExpired() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 1)])
        let pic = m(
            AB, 1, body: ["image": ["fileId": "F9", "width": 1, "height": 1, "size": 1, "mime": "image/png"]], type: "image")
        try await h.cvsLoaded(c, AB, [pic, cm(AB, 2)])
        h.events = []
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 2])
        try await p.value
        XCTAssertEqual(h.expiredFiles, [["F9"]])
        // A file of a purged message is not "expired" for a later message quoting... it is simply unknown.
        XCTAssertFalse(h.im.store.fileExpired("F9"))
    }

    func testClearedSeqBelowTheLocalNewestKeepsTheConversationAndCountsOnlyTheNewer() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 3, readSeq: 3, updatedAt: 1, pinned: true, pinnedAt: 5)])
        try await h.cvsLoaded(c, AB, [cm(AB, 1), cm(AB, 2), cm(AB, 3)])
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        down(c, msgFrame(cm(AB, 4)))
        downAck(c, "convDelete", ["clearedSeq": 3])
        try await p.value
        await flush()
        XCTAssertEqual(h.ids, [AB])
        XCTAssertEqual(h.find(AB)?.minSeq, 4)
        XCTAssertEqual(h.find(AB)?.unread, 1)
        XCTAssertNil(h.find(AB)?.pinned)
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [4])
    }

    func testTC_CVS_03_05_aGroupInDeletedIsNotRemovedNoEventNoSnapshotPurgedAndICanSend() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 12, readSeq: 12, updatedAt: 12), sc(G2, maxSeq: 1, readSeq: 1, updatedAt: 1)])
        try await h.cvsLoaded(c, G1, [cm(G1, 11, "bob", "ZXQ-CVS-1"), cm(G1, 12)])
        let n = await h.cvsReconnect(c, [
            "convs": [sc(G2, maxSeq: 1, readSeq: 1, updatedAt: 1)], "truncated": false,
            "deleted": [["convId": .string(G1), "clearedSeq": 12]],
        ])
        XCTAssertEqual(h.ids, [G2])
        XCTAssertEqual(h.removedIds, [])
        XCTAssertNil(h.im.conversationSnapshot(G1))
        XCTAssertEqual(h.im.messages(G1), [])
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-1"))
        // From the contacts: an empty chat page, sending works and brings the conversation back.
        guard case .ok = try h.im.send(G1, "我还在群里") else { return XCTFail() }
        await flush()
        downAck(n, "send", ["msgId": "g1-13", "convId": .string(G1), "seq": 13, "ts": 5000])
        await flush()
        XCTAssertEqual(h.im.messages(G1).map { "\($0.seq ?? 0):\($0.status.rawValue)" }, ["13:sent"])
        XCTAssertEqual(h.find(G1)?.unread, 0)
    }

    func testTC_CVS_03_05_controlOtherGroupsStillInferredButNotWhenTruncatedOrDeletedTruncated() async throws {
        let cases: [([String: JSONValue], [String])] = [
            (["truncated": false], [G2]), (["truncated": true], []), (["truncated": false, "deletedTruncated": true], []),
        ]
        for (flags, want) in cases {
            let h = client()
            let c = await h.cvsOnline([sc(G1, updatedAt: 2), sc(G2, updatedAt: 1)])
            var ack: [String: JSONValue] = ["convs": [], "deleted": [["convId": .string(G1), "clearedSeq": 0]]]
            for (k, v) in flags { ack[k] = v }
            _ = await h.cvsReconnect(c, ack)
            XCTAssertEqual(h.removedIds, want, "\(flags)")
            XCTAssertNil(h.im.conversationSnapshot(G1))
            XCTAssertEqual(h.im.conversationSnapshot(G2) != nil, !want.isEmpty, "\(flags)")
        }
    }

    func testConvsPurgesListedConversationsBelowMinSeqAndUnsentQuotesOfPurgedMessagesLoseTheirText() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 5, readSeq: 5, updatedAt: 5)])
        try await h.cvsLoaded(c, AB, (1...5).map { cm(AB, $0, "bob", "ZXQ-CVS-4 \($0)") })
        c.drop()
        await flush()
        guard case .ok(let r) = try h.im.send(AB, "回复", quote: QuoteRef(msgId: idOf(AB, 2))),
            case .ok(let keep) = try h.im.send(AB, "回复留下的", quote: QuoteRef(msgId: idOf(AB, 4)))
        else { return XCTFail() }
        XCTAssertEqual(r.body.quote?.text, "ZXQ-CVS-4 2")
        h.clock.advance(60_000)
        await flush()
        let n = h.transport.current
        n.open()
        n.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now())])
        await flush()
        downAck(n, "convs", ["convs": [sc(AB, maxSeq: 5, readSeq: 5, minSeq: 4, updatedAt: 5)], "truncated": false])
        await settle()
        XCTAssertEqual(h.im.messages(AB).compactMap(\.seq), [4, 5])
        let pending = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == r.clientMsgId })
        XCTAssertEqual(pending.body.quote?.state, .deleted)
        XCTAssertNil(pending.body.quote?.text)
        XCTAssertEqual(pending.body.quote?.msgId, idOf(AB, 2))
        let kept = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == keep.clientMsgId })
        XCTAssertEqual(kept.body.quote?.state, .normal)
        XCTAssertEqual(kept.body.quote?.text, "ZXQ-CVS-4 4")
        for s in 1...3 { XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-4 \(s)"), "\(s)") }
    }

    // P-46 ④, frontend-chat 62: the other side's new message quoting a cleared one shows the server's quote.
    func testANewMessageQuotingAClearedOneKeepsTheQuote() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 2)])
        try await h.cvsLoaded(c, AB, [cm(AB, 1), cm(AB, 2)])
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 2])
        try await p.value
        let reply = m(AB, 3, body: ["text": "你看这条", "quote": quoteOf(AB, 1, "m1")])
        down(c, msgFrame(reply))
        await flush()
        XCTAssertEqual(h.im.messages(AB).map { $0.body.quote?.text }, ["m1"])
        XCTAssertEqual(h.im.messages(AB).first?.body.quote?.state, .normal)
    }

    func testConvSetOnAHiddenConversationKeepsItHiddenItReturnsWithTheNewSetting() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 2)])
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        downAck(c, "convDelete", ["clearedSeq": 2])
        try await p.value
        let q = Task { try await h.im.setConvNotifyOff(AB, true) }
        await flush()
        downAck(c, "convSet", ["conv": sc(AB, maxSeq: 2, readSeq: 2, minSeq: 3, updatedAt: 2, notifyOff: true)])
        try await q.value
        XCTAssertEqual(h.ids, [])
        down(c, msgFrame(cm(AB, 3)))
        await flush()
        XCTAssertEqual(h.find(AB)?.notifyOff, true)
        XCTAssertEqual(h.find(AB)?.unread, 1)
    }

    // MARK: F-CVS-04 multi-device

    func testTC_CVS_04_01_convSettingsChangedFromAnotherDeviceWins() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 2, unread: 2, updatedAt: 300), sc(G1, maxSeq: 4, unread: 4, updatedAt: 100)])
        let n0 = h.listEvents
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": true, "pinnedAt": 1234, "notifyOff": false])
        XCTAssertEqual(h.ids, [G1, AB])
        XCTAssertEqual(h.find(G1)?.pinnedAt, 1234)
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": true, "pinnedAt": 1234, "notifyOff": true])
        XCTAssertEqual(h.find(G1)?.notifyOff, true)
        XCTAssertEqual(h.im.totalUnread(), 2)
        XCTAssertEqual(h.listEvents, n0 + 2)
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": true, "pinnedAt": 1234, "notifyOff": true])
        XCTAssertEqual(h.listEvents, n0 + 2, "no change, no event")
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": false, "notifyOff": false])
        XCTAssertEqual(h.ids, [AB, G1])
        XCTAssertNil(h.find(G1)?.pinnedAt)
        XCTAssertNil(h.find(G1)?.notifyOff)
        XCTAssertEqual(h.im.totalUnread(), 6)
        downEvent(c, "convSettingsChanged", ["convId": "group:zz", "pinned": true, "pinnedAt": 1, "notifyOff": false])
        XCTAssertEqual(h.ids, [AB, G1])
    }

    func testTC_CVS_04_05_convDeletedFromAnotherDevicePurgesEmitsAndANewMessageCountsOnlyItself() async throws {
        let h = client()
        let c = await h.cvsOnline([
            sc(AB, maxSeq: 10, readSeq: 6, unread: 4, updatedAt: 10, pinned: true, pinnedAt: 3, notifyOff: true),
            sc(AC, updatedAt: 1),
        ])
        try await h.cvsLoaded(c, AB, [9, 10].map { cm(AB, $0, "bob", "ZXQ-CVS-1 \($0)") })
        downEvent(c, "convDeleted", ["convId": .string(AB), "clearedSeq": 10])
        XCTAssertEqual(h.ids, [AC])
        XCTAssertEqual(h.convDeletedIds, [AB])
        XCTAssertEqual(h.removedIds, [])
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-1"))
        down(c, msgFrame(cm(AB, 11)))
        await flush()
        let v = try XCTUnwrap(h.find(AB))
        XCTAssertEqual([v.minSeq, v.readSeq, v.unread], [11, 10, 1])
        XCTAssertEqual(v.notifyOff, true)
        XCTAssertNil(v.pinned)
        XCTAssertNil(v.pinnedAt)
    }

    // frontend-chat 63: another device's deletion leaves this device's unsent messages alone.
    func testConvDeletedFromAnotherDeviceKeepsUnsentMessages() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 2)])
        try await h.cvsLoaded(c, AB, [cm(AB, 1, "bob", "ZXQ-CVS-9"), cm(AB, 2)])
        guard case .ok(let failed) = try h.im.send(AB, "没发出去的", quote: QuoteRef(msgId: idOf(AB, 1))) else { return XCTFail() }
        h.clock.advance(11_000)
        await flush()
        downEvent(c, "convDeleted", ["convId": .string(AB), "clearedSeq": 2])
        await flush()
        let left = h.im.messages(AB)
        XCTAssertEqual(left.map(\.clientMsgId), [failed.clientMsgId])
        XCTAssertEqual(left.first?.status, .failed)
        XCTAssertEqual(left.first?.body.text, "没发出去的")
        XCTAssertEqual(left.first?.body.quote?.state, .deleted)  // Its quote of a cleared message loses the text (62).
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-9"))
        XCTAssertEqual(h.convDeletedIds, [AB])
        // Sent again later, it brings the conversation back.
        h.im.retry(AB, failed.clientMsgId)
        await flush()
        downAck(c, "send", ["msgId": "ab-3", "convId": .string(AB), "seq": 3, "ts": 5000])
        await flush()
        XCTAssertEqual(h.ids, [AB])
        XCTAssertEqual(h.find(AB)?.unread, 0)
    }

    func testConvDeletedOfAnEmptyGroupRemovesItAMessageBringsItBack() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 0, updatedAt: 5)])
        downEvent(c, "convDeleted", ["convId": .string(G1), "clearedSeq": 0])
        XCTAssertEqual(h.ids, [])
        down(c, msgFrame(cm(G1, 1)))
        await flush()
        XCTAssertEqual(h.find(G1)?.unread, 1)
        XCTAssertEqual(h.find(G1)?.minSeq, 1)
    }

    func testTC_CVS_04_02_reconnectMatchesTheServerPinsNotifyOffAndDeletedPurged() async throws {
        let h = client()
        let c = await h.cvsOnline([
            sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 1), sc(AC, maxSeq: 3, readSeq: 3, updatedAt: 9),
            sc(G1, maxSeq: 1, readSeq: 1, updatedAt: 5, notifyOff: true),
        ])
        try await h.cvsLoaded(c, AB, [cm(AB, 1), cm(AB, 2)])
        try await h.cvsLoaded(c, AC, [cm(AC, 1, "carol", "ZXQ-CVS-5"), cm(AC, 2, "carol"), cm(AC, 3, "carol")])
        _ = await h.cvsReconnect(c, [
            "convs": [
                sc(AB, maxSeq: 2, readSeq: 2, updatedAt: 1, pinned: true, pinnedAt: 99),
                sc(G1, maxSeq: 1, readSeq: 1, updatedAt: 5, notifyOff: true),
            ],
            "truncated": false, "deleted": [["convId": .string(AC), "clearedSeq": 3]],
        ])
        XCTAssertEqual(
            h.im.conversations().map { "\($0.convId):\($0.isPinned):\($0.pinnedAt ?? -1):\($0.isNotifyOff)" },
            ["\(AB):true:99:false", "\(G1):false:-1:true"])
        XCTAssertEqual(h.im.messages(AC), [])
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [1, 2])
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-5"))
    }

    func testOlderServersWithoutC5FieldsBehaveAsInC4() async throws {
        let h = client()
        _ = await h.cvsOnline([sc(AB, maxSeq: 2, unread: 2, updatedAt: 1), sc(AC, maxSeq: 1, unread: 1, updatedAt: 2)])
        XCTAssertEqual(h.ids, [AC, AB])
        XCTAssertEqual(h.im.totalUnread(), 3)
    }

    // backend-chat 75, P-46 ②: the flag only hides the menu; existing settings apply either way.
    func testFeaturesConvSettingsDecodesAndTheSDKAppliesSettingsRegardless() async throws {
        for (features, want) in [
            (#"{"files":true,"convSettings":true}"#, true as Bool?), (#"{"files":true,"convSettings":false}"#, false),
            (#"{"files":true}"#, nil),
        ] {
            let raw = #"{"registerMode":"open","demoLogin":false,"features":\#(features),"limits":{"usernameMinLen":3,"usernameMaxLen":32,"passwordMinLen":8,"passwordMaxLen":64,"nicknameMaxLen":20,"deviceNameMaxLen":40}}"#
            let cfg = try JSONDecoder().decode(AccountConfig.self, from: Data(raw.utf8))
            XCTAssertEqual(cfg.features.convSettings, want, features)
        }
        let h = client()
        _ = await h.cvsOnline([sc(AB, maxSeq: 3, unread: 3, updatedAt: 9, notifyOff: true), sc(AC, updatedAt: 1, pinned: true, pinnedAt: 1)])
        XCTAssertEqual(h.ids, [AC, AB])
        XCTAssertEqual(h.im.totalUnread(), 0)
    }

    // MARK: F-CVS-03 rule 6a, AC-CVS-03-12, frontend-chat 65: back in the group, the old history loads again

    /// Deleted, removed, added back with historyVisible (convAdded, minSeq 1) in the same login: everything loads.
    func testRejoinWithHistoryVisibleLowersTheFloorConvAdded() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 12, readSeq: 12, updatedAt: 12)])
        try await h.cvsLoaded(c, G1, (11...12).map { cm(G1, $0) })
        downEvent(c, "convDeleted", ["convId": .string(G1), "clearedSeq": 12])
        XCTAssertEqual(h.im.messages(G1), [])
        downEvent(c, "convRemoved", ["convId": .string(G1), "reason": "removed"])
        downEvent(c, "convAdded", ["conv": sc(G1, maxSeq: 13, readSeq: 12, minSeq: 1, unread: 1, updatedAt: 13)])
        let more = Task { try await h.im.loadHistory(G1) }
        await settle()
        XCTAssertEqual(c.last("sync")?.data?["beforeSeq"], 14)
        downAck(c, "sync", ["messages": .array((1...13).map { cm(G1, $0) }), "hasMore": false])
        _ = try await more.value
        XCTAssertEqual(h.im.messages(G1).compactMap(\.seq), Array(1...13))
        XCTAssertEqual(h.find(G1)?.minSeq, 1)
    }

    /// convAdded with a higher minSeq purges below it, like convs (frontend-chat 65, sdk-ts 4f2f4cc).
    func testConvAddedPurgesBelowItsMinSeq() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 3, readSeq: 3, updatedAt: 3)])
        try await h.cvsLoaded(c, G1, [cm(G1, 1, "bob", "ZXQ-CVS-ADD"), cm(G1, 2), cm(G1, 3)])
        downEvent(c, "convAdded", ["conv": sc(G1, maxSeq: 3, readSeq: 3, minSeq: 3, updatedAt: 3)])
        await flush()
        XCTAssertEqual(h.im.messages(G1).map(\.seq), [3])
        XCTAssertFalse(holds(h.im.store, "ZXQ-CVS-ADD"))
    }

    /// Removed and added back while offline (no snapshot, no convRemoved): the next convs' lower minSeq is taken as is.
    func testRejoinWhileOfflineLowersTheFloorFromConvs() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 12, readSeq: 12, updatedAt: 12)])
        try await h.cvsLoaded(c, G1, (11...12).map { cm(G1, $0) })
        downEvent(c, "convDeleted", ["convId": .string(G1), "clearedSeq": 12])
        let n = await h.cvsReconnect(c, [
            "convs": [sc(G1, maxSeq: 13, readSeq: 12, minSeq: 1, unread: 1, updatedAt: 13)], "truncated": false,
        ])
        XCTAssertEqual(h.removedIds, [])
        await settle()
        let more = Task { try await h.im.loadHistory(G1) }
        await settle()
        let open = n.frames("sync").last { $0.data?["convId"]?.stringValue == G1 && $0.data?["beforeSeq"] != nil }
        down(n, ["id": .string(try XCTUnwrap(open?.id)), "cmd": "ack", "data": ["messages": .array((1...13).map { cm(G1, $0) }), "hasMore": false]])
        _ = try await more.value
        XCTAssertEqual(h.im.messages(G1).compactMap(\.seq).filter { $0 <= 12 }, Array(1...12))
    }

    // MARK: frames.json (AC-CHAT-90-10, TC-CHAT-90-38)

    func testTC_CHAT_90_38_C5FramesPassOrFailTheSchemaAndDecodeIntoModels() throws {
        let spec = try loadJSON("vectors/frames.json")
        let schema = try SchemaValidator.shared()
        let valid = spec["valid"]!.arrayValue!.filter { $0["name"]!.stringValue!.contains("（C5）") }
        let invalid = spec["invalid"]!.arrayValue!.filter { $0["name"]!.stringValue!.contains("（C5）") }
        XCTAssertEqual(valid.count + invalid.count, 51)
        for v in valid { XCTAssertTrue(schema.isValid(v["frame"]!), v["name"]!.stringValue!) }
        for v in invalid { XCTAssertFalse(schema.isValid(v["frame"]!), v["name"]!.stringValue!) }
        func raw(_ name: String) -> Data {
            Data(valid.first { $0["name"]!.stringValue! == name }!["frame"]!.jsonString().utf8)
        }
        let set = try decodeFrameData(ConvSetAck.self, from: raw("ack convSet 置顶并免打扰（C5）"))
        XCTAssertEqual([set.conv.pinned, set.conv.notifyOff], [true, true])
        XCTAssertEqual(set.conv.pinnedAt, 1_730_000_100_000)
        let none = try decodeFrameData(ConvSetAck.self, from: raw("ack convSet 都取消（不带设置字段）（C5）"))
        XCTAssertNil(none.conv.pinned)
        XCTAssertNil(none.conv.notifyOff)
        XCTAssertEqual(try decodeFrameData(ConvDeleteAck.self, from: raw("ack convDelete（C5）")).clearedSeq, 10)
        XCTAssertEqual(try decodeFrameData(ConvDeleteAck.self, from: raw("ack convDelete 空群（C5）")).clearedSeq, 0)
        let convs = try decodeFrameData(ConvsAck.self, from: raw("ack convs 带 pinned、notifyOff、deleted（C5）"))
        XCTAssertEqual(convs.deleted, [DeletedConv(convId: "group:g5", clearedSeq: 12), DeletedConv(convId: "c2c:u1:u9", clearedSeq: 3)])
        XCTAssertFalse(convs.deletedTruncated)
        XCTAssertEqual(convs.convs.map { $0.pinned == true }, [true, true, false, false])
        let cut = try decodeFrameData(ConvsAck.self, from: raw("ack convs deletedTruncated（C5）"))
        XCTAssertTrue(cut.deletedTruncated)
        let ev = try decodeFrameData(IMClient.ConvSettingsChangedEvent.self, from: raw("event convSettingsChanged 置顶（C5）"))
        XCTAssertEqual(ev.pinnedAt, 1_730_000_100_000)
        let del = try decodeFrameData(IMClient.ConvDeletedEvent.self, from: raw("event convDeleted（C5）"))
        XCTAssertEqual(del.clearedSeq, 10)
        // Older servers: no C5 fields at all.
        let old = try decodeFrameData(ConvsAck.self, from: Data(#"{"cmd":"ack","id":"r1","data":{"convs":[],"truncated":false}}"#.utf8))
        XCTAssertEqual(old.deleted, [])
        XCTAssertFalse(old.deletedTruncated)
    }

    func testEveryC5FrameTheSDKSendsPassesTheSchema() async throws {
        let h = client()
        let c = await h.cvsOnline([sc(G1, maxSeq: 3, updatedAt: 1)])
        for t in [
            Task { try await h.im.setConvPinned(G1, true) }, Task { try await h.im.setConvPinned(G1, false) },
            Task { try await h.im.setConvNotifyOff(G1, true) }, Task { try await h.im.deleteConv(G1) },
        ] {
            _ = t
        }
        await flush()
        XCTAssertEqual(c.frames("convSet").count, 3)
        XCTAssertEqual(c.frames("convDelete").count, 1)
        let schema = try SchemaValidator.shared()
        for f in c.frames("convSet") + c.frames("convDelete") { XCTAssertTrue(schema.isValid(f.raw), f.raw.jsonString()) }
    }
}
