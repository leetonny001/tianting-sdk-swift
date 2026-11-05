import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let AB = "c2c:alice:bob"
private let G1 = "group:g1"
private let G2 = "group:g2"
private let SECRET = "ZXQ-DEL-555"

/// Port of sdk-ts test/moderation.test.ts (second batch): bans, deletions, mutes.
@MainActor
final class ModerationTests: IMTestCase {
    private func fatals(_ h: Harness) -> [FatalReason] {
        h.events.compactMap {
            if case .fatal(let r) = $0 { return r }
            return nil
        }
    }

    private func deletedEvent(_ convId: String, _ ids: [String], _ seqs: [Int64]) -> JSONValue {
        event("msgDeleted", ["convId": .string(convId), "msgIds": strs(ids), "seqs": .array(seqs.map { .int($0) })])
    }

    private func assertClean(_ h: Harness, line: UInt = #line) {
        XCTAssertFalse(encoded(h.im.debugExport()).contains(SECRET), line: line)
        XCTAssertFalse(encoded(h.im.conversations()).contains(SECRET), line: line)
        XCTAssertFalse(holds(h.im.store, SECRET), "still somewhere in the store", line: line)
    }

    // MARK: Bans (AC-ADM-13-1, AC-ADM-13-11, AC-UI-43-4)

    func testSuspendedDoesNotReconnect() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        c.receive(event("kicked", ["reason": "suspended", "until": 1_730_000_000_000]))
        c.drop(4012, "suspended")
        XCTAssertEqual(fatals(h), [.kicked(reason: "suspended", code: 4012, until: .at(1_730_000_000_000))])
        h.clock.advance(300_000)
        h.im.networkOnline()
        XCTAssertEqual(h.transport.connections.count, 1)
        XCTAssertEqual(h.im.state, .disconnected)
    }

    func testPermanentBanIsNotMissingUntil() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login()
        c.receive(event("kicked", ["reason": "suspended", "until": nil]))
        c.drop(4012)
        XCTAssertEqual(fatals(h), [.kicked(reason: "suspended", code: 4012, until: .permanent)])
    }

    func testKickDuringHandshake() {
        let h = setup()
        h.im.connect(token: "old")
        let c = h.transport.current
        c.open()
        c.receive(event("kicked", ["reason": "suspended", "until": nil]))
        c.drop(4012)
        XCTAssertEqual(fatals(h), [.kicked(reason: "suspended", code: 4012, until: .permanent)])
        h.clock.advance(60_000)
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testUnknownReasonAndBareClose() async {
        for kicked in [true, false] {
            let h = setup()
            h.im.connect(token: "t")
            let c = await h.login()
            if kicked { c.receive(event("kicked", ["reason": "xyz"])) }
            c.drop(4012)
            XCTAssertEqual(
                fatals(h),
                [kicked ? .kicked(reason: "xyz", code: 4012, until: nil) : .closed(code: 4012, reason: "")])
            h.clock.advance(60_000)
            XCTAssertEqual(h.transport.connections.count, 1)
        }
    }

    // MARK: Deletions (AC-ADM-31-1, 31-3, 31-5)

    private func chat(_ h: Harness) async -> FakeConnection {
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: "keep me")))
        c.receive(msgFrame(msg(G1, 2, text: "秘密 \(SECRET)")))
        c.receive(msgFrame(msg(G1, 3, text: "tail")))
        return c
    }

    func testMsgDeletedWipesMemoryKeepsSeqAndUnread() async {
        let h = setup()
        let c = await chat(h)
        XCTAssertEqual(h.im.conversations()[0].unread, 3)
        XCTAssertTrue(holds(h.im.store, SECRET))  // Control: it really was in memory.
        var seen = 0
        h.im.on {
            if case .messages = $0 { seen += 1 }
        }
        c.receive(deletedEvent(G1, ["\(G1)#2"], [2]))
        assertClean(h)
        let list = h.im.messages(G1)
        XCTAssertEqual(list.map(\.seq), [1, 2, 3])
        XCTAssertEqual(list[1].msgId, "\(G1)#2")
        XCTAssertEqual(list[1].from, "bob")
        XCTAssertEqual(list[1].deleted, true)
        XCTAssertTrue(list[1].body.isEmpty)
        XCTAssertEqual(list[0].body.text, "keep me")
        XCTAssertEqual(list[2].body.text, "tail")
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(h.im.conversations()[0].unread, 3)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.text, "tail")
    }

    func testDeletingLastMessageMakesPlaceholderSummary() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.text, SECRET)
        c.receive(deletedEvent(G1, ["\(G1)#1"], [1]))
        let last = h.im.conversations()[0].lastMsg
        XCTAssertEqual(last?.deleted, true)
        XCTAssertEqual(last?.msgId, "\(G1)#1")
        XCTAssertNil(last?.text)
        XCTAssertEqual(h.im.conversations()[0].unread, 1)
        assertClean(h)
        c.receive(msgFrame(msg(G1, 2, text: "fresh")))
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.text, "fresh")
        XCTAssertNil(h.im.conversations()[0].lastMsg?.deleted)
    }

    func testSyncedDeletedMessage() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1, maxSeq: 2, unread: 2)])
        async let p = h.im.loadHistory(G1)
        await flush()
        c.ack("sync", ["messages": [msg(G1, 1), deletedMsg(G1, 2)], "hasMore": false])
        _ = try await p
        let m = h.im.messages(G1)[1]
        XCTAssertEqual(m.seq, 2)
        XCTAssertEqual(m.deleted, true)
        XCTAssertEqual(m.deletedAt, 5000)
        XCTAssertTrue(m.body.isEmpty)
        XCTAssertEqual(m.status, .sent)
        XCTAssertEqual(h.im.conversations()[0].unread, 2)
    }

    // A frame that breaks the schema (deleted with a body, frames.json `invalid`) still must not keep the text.
    func testDeletedFlagWinsOverBody() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1)])
        var m = msg(G1, 1, text: SECRET)
        if case .object(var o) = m {
            o["deleted"] = true
            m = .object(o)
        }
        c.receive(msgFrame(m))
        assertClean(h)
        XCTAssertEqual(h.im.messages(G1)[0].deleted, true)
    }

    func testLateSyncCannotRestoreText() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1, maxSeq: 2)])
        async let p = h.im.loadHistory(G1)
        await flush()
        c.receive(deletedEvent(G1, ["\(G1)#2"], [2]))
        c.ack("sync", ["messages": [msg(G1, 1), msg(G1, 2, text: SECRET)], "hasMore": false])
        _ = try await p
        assertClean(h)
        XCTAssertEqual(h.im.messages(G1)[1].deleted, true)
    }

    func testLateConvsCannotRestoreSummary() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        c.receive(deletedEvent(G1, ["\(G1)#1"], [1]))
        h.clock.advance(31_000)
        async let p = h.im.refreshConversations()
        await flush()
        c.ack(
            "convs",
            [
                "convs": [
                    conv(G1, maxSeq: 1, lastMsg: ["msgId": .string("\(G1)#1"), "from": "bob", "type": "text", "text": .string(SECRET), "ts": 1])
                ],
                "truncated": false,
            ])
        _ = try await p
        assertClean(h)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.deleted, true)
    }

    func testDeletionBeforeAckCannotRestoreText() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        _ = try h.im.send(AB, SECRET)
        c.receive(deletedEvent(AB, ["m9"], [9]))
        c.ack("send", ["msgId": "m9", "convId": .string(AB), "seq": 9, "ts": 5])
        await flush()
        assertClean(h)
        XCTAssertEqual(h.im.messages(AB).count, 1)
        XCTAssertEqual(h.im.messages(AB)[0].seq, 9)
        XCTAssertEqual(h.im.messages(AB)[0].deleted, true)
        XCTAssertEqual(h.im.messages(AB)[0].status, .sent)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.deleted, true)
    }

    func testTimedOutLocalMessageMatchedBySync() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        let r = try h.im.send(AB, SECRET)
        let cid = r.message!.clientMsgId
        h.clock.advance(10_000)
        await flush()
        XCTAssertEqual(h.im.messages(AB)[0].error, .timeout)
        c.receive(deletedEvent(AB, ["m9"], [9]))
        await flush()
        XCTAssertEqual(c.last("sync")?.data, ["convId": .string(AB), "afterSeq": 8, "limit": 200])
        c.ack("sync", ["messages": [deletedMsg(AB, 9, from: "alice", msgId: "m9", clientMsgId: cid)], "hasMore": false])
        await flush()
        assertClean(h)
        XCTAssertEqual(h.im.messages(AB).count, 1)
        XCTAssertEqual(h.im.pendingCount(), 0)
        let before = c.frames("send").count
        h.im.retry(AB, cid)
        XCTAssertEqual(c.frames("send").count, before)
    }

    func testDeletedWhileDisconnectedRechecked() async {
        let h = setup()
        let c1 = await chat(h)
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv(G1, maxSeq: 3, unread: 3)], "truncated": false])
        await flush()
        XCTAssertEqual(c2.last("sync")?.data, ["convId": .string(G1), "afterSeq": 0, "limit": 200])
        c2.ack("sync", ["messages": [msg(G1, 1), deletedMsg(G1, 2), msg(G1, 3)], "hasMore": false])
        await flush()
        assertClean(h)
        XCTAssertEqual(h.im.messages(G1).map(\.seq), [1, 2, 3])
        XCTAssertEqual(h.im.conversations()[0].unread, 3)
    }

    func testConvsLastMsgDeletedWipesLoadedCopy() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        h.clock.advance(31_000)
        async let p = h.im.refreshConversations()
        await flush()
        c.ack(
            "convs",
            [
                "convs": [
                    conv(G1, maxSeq: 1, unread: 1, lastMsg: ["msgId": .string("\(G1)#1"), "from": "bob", "type": "text", "ts": 1, "deleted": true])
                ],
                "truncated": false,
            ])
        _ = try await p
        assertClean(h)
        XCTAssertEqual(h.im.conversations()[0].unread, 1)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.deleted, true)
    }

    func testDebugExportHasNoToken() async {
        let h = setup()
        h.im.connect(token: "secret-token-xyz")
        let c = await h.login("alice", convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1)))
        var dump = h.im.debugExport()
        XCTAssertFalse(encoded(dump).contains("secret-token-xyz"))
        dump.messages[G1]![0].body.text = "changed"
        XCTAssertEqual(h.im.messages(G1)[0].body.text, "m1")
    }

    // MARK: Mutes (AC-ADM-40-4, 40-5, 40-6, 41-6, AC-UI-41-5)

    private func online(_ h: Harness) async -> FakeConnection {
        h.im.connect(token: "t")
        return await h.login("alice", convs: [conv(AB), conv(G1), conv(G2)])
    }

    private func muted(_ f: [String: JSONValue]) -> JSONValue { event("muted", f) }
    private func unmuted(_ f: [String: JSONValue]) -> JSONValue { event("unmuted", f) }

    private func muteEvents(_ h: Harness) -> Int {
        h.events.filter {
            if case .muteChanged = $0 { return true }
            return false
        }.count
    }

    func testUserMute() async {
        let h = setup()
        let c = await online(h)
        let base = muteEvents(h)
        let until = h.clock.now() + 600_000
        c.receive(muted(["scope": "user", "mutedUntil": .int(until)]))
        for id in [AB, G1, G2] {
            XCTAssertEqual(h.im.muteState(id), MuteInfo(scope: .user, groupId: nil, mutedUntil: .at(until)))
        }
        XCTAssertEqual(muteEvents(h), base + 1)
        c.receive(muted(["scope": "user", "mutedUntil": nil]))
        XCTAssertEqual(h.im.muteState(AB), MuteInfo(scope: .user, groupId: nil, mutedUntil: .permanent))
        c.receive(unmuted(["scope": "user"]))
        for id in [AB, G1, G2] { XCTAssertNil(h.im.muteState(id)) }
        XCTAssertEqual(muteEvents(h), base + 3)
    }

    func testGroupMuteScopesAndUserPriority() async {
        let h = setup()
        let c = await online(h)
        let until = h.clock.now() + 3_600_000
        c.receive(muted(["scope": "group", "groupId": "g1", "mutedUntil": .int(until)]))
        XCTAssertEqual(h.im.muteState(G1), MuteInfo(scope: .group, groupId: "g1", mutedUntil: .at(until)))
        XCTAssertNil(h.im.muteState(G2))
        XCTAssertNil(h.im.muteState(AB))
        c.receive(muted(["scope": "user", "mutedUntil": .int(h.clock.now() + 60_000)]))
        XCTAssertEqual(h.im.muteState(G1)?.scope, .user)
        c.receive(unmuted(["scope": "user"]))
        XCTAssertEqual(h.im.muteState(G1), MuteInfo(scope: .group, groupId: "g1", mutedUntil: .at(until)))
        c.receive(unmuted(["scope": "group", "groupId": "g2"]))
        XCTAssertEqual(h.im.muteState(G1)?.scope, .group)
        c.receive(unmuted(["scope": "group", "groupId": "g1"]))
        XCTAssertNil(h.im.muteState(G1))
    }

    func testUnknownScopeIgnored() async {
        let h = setup()
        let c = await online(h)
        c.receive(muted(["scope": "groupAll", "groupId": "g1", "mutedUntil": nil]))
        XCTAssertNil(h.im.muteState(G1))
    }

    // frames.json `invalid`: a `muted` without mutedUntil is not a permanent mute.
    func testMutedWithoutDeadlineIgnored() async {
        let h = setup()
        let c = await online(h)
        c.receive(muted(["scope": "user"]))
        XCTAssertNil(h.im.muteState(AB))
    }

    func testAuthAckMutedUntil() async {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = h.transport.current
        c1.open()
        let until = h.clock.now() + 86_400_000
        c1.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now()), "mutedUntil": .int(until)])
        XCTAssertEqual(h.im.muteState(AB), MuteInfo(scope: .user, groupId: nil, mutedUntil: .at(until)))
        await flush()
        c1.drop(1006)
        h.clock.advance(1_000)
        let c2 = h.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now()), "mutedUntil": nil])
        XCTAssertEqual(h.im.muteState(AB), MuteInfo(scope: .user, groupId: nil, mutedUntil: .permanent))
        await flush()
        c2.drop(1006)
        h.clock.advance(5_000)
        let c3 = h.transport.current
        c3.open()
        c3.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now())])
        XCTAssertNil(h.im.muteState(AB))
    }

    func testConvsMutedUntil() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let until = h.clock.now() + 3_600_000
        let c = await h.login("alice", convs: [conv(G1, mutedUntil: .int(until)), conv(G2), conv(AB)])
        XCTAssertEqual(h.im.muteState(G1), MuteInfo(scope: .group, groupId: "g1", mutedUntil: .at(until)))
        XCTAssertNil(h.im.muteState(G2))
        XCTAssertNil(h.im.muteState(AB))
        h.clock.advance(31_000)
        async let p = h.im.refreshConversations()
        await flush()
        c.ack("convs", ["convs": [conv(G1, mutedUntil: .null), conv(G2)], "truncated": false])
        _ = try await p
        XCTAssertEqual(h.im.muteState(G1)?.mutedUntil, .permanent)
        c.receive(["cmd": "pong"])
        h.clock.advance(31_000)
        async let q = h.im.refreshConversations()
        await flush()
        c.ack("convs", ["convs": [conv(G1), conv(G2)], "truncated": false])
        _ = try await q
        XCTAssertNil(h.im.muteState(G1))
    }

    func testSend4031UpdatesMuteFromDetails() async throws {
        let h = setup()
        let c1 = await online(h)
        let r = try h.im.send(G1, "x")
        let until = h.clock.now() + 600_000
        c1.receive([
            "id": .string(c1.last("send")!.id!), "cmd": "ack",
            "error": ["code": 4031, "msg": "muted", "details": ["scope": "group", "groupId": "g1", "mutedUntil": .int(until)]],
        ])
        await flush()
        XCTAssertEqual(h.im.messages(G1)[0].status, .failed)
        XCTAssertEqual(h.im.messages(G1)[0].error, .code(4031))
        XCTAssertEqual(h.im.muteState(G1), MuteInfo(scope: .group, groupId: "g1", mutedUntil: .at(until)))
        XCTAssertNil(h.im.muteState(G2))
        let failed = h.events.compactMap { e -> String? in
            if case .sendFailed(let conv, let id, let err) = e { return "\(conv)/\(id)/\(err)" }
            return nil
        }
        XCTAssertEqual(failed, ["\(G1)/\(r.message!.clientMsgId)/4031"])
        c1.drop(1006)
        let c2 = await h.reconnect()
        XCTAssertEqual(c2.frames("send").count, 0)
    }

    func testSend4031PermanentAndMissingDetails() async throws {
        let h = setup()
        let c = await online(h)
        _ = try h.im.send(AB, "x")
        c.receive([
            "id": .string(c.last("send")!.id!), "cmd": "ack",
            "error": ["code": 4031, "msg": "muted", "details": ["scope": "user", "mutedUntil": nil]],
        ])
        await flush()
        XCTAssertEqual(h.im.muteState(G2), MuteInfo(scope: .user, groupId: nil, mutedUntil: .permanent))
        let h2 = setup()
        let c2 = await online(h2)
        _ = try h2.im.send(AB, "x")
        c2.ackError("send", 4031)
        await flush()
        XCTAssertEqual(h2.im.messages(AB)[0].error, .code(4031))
        XCTAssertNil(h2.im.muteState(AB))
    }

    func testExpiryUsesServerTime() async {
        for skew: Int64 in [3_600_000, -3_600_000] {
            let h = setup()
            h.im.connect(token: "t")
            let c = h.transport.current
            c.open()
            let serverNow = h.clock.now() + skew
            c.ack("auth", ["userId": "alice", "serverTime": .int(serverNow)])
            await flush()
            c.ack("convs", ["convs": [conv(AB)], "truncated": false])
            await flush()
            let base = muteEvents(h)
            c.receive(muted(["scope": "user", "mutedUntil": .int(serverNow + 600_000)]))
            XCTAssertEqual(muteEvents(h), base + 1)
            h.clock.advance(599_999)  // Heartbeats go unanswered here, which must not affect mutes.
            XCTAssertNotNil(h.im.muteState(AB))
            XCTAssertEqual(muteEvents(h), base + 1)
            h.clock.advance(1)
            XCTAssertNil(h.im.muteState(AB))
            XCTAssertEqual(muteEvents(h), base + 2)
        }
    }

    func testThirtyDayMuteNoEarlyExpiryNoLoop() async {
        final class OverflowClock: FakeClock {
            override func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle {
                super.setTimeout(ms > 2_147_483_647 ? 1 : ms, fn)
            }
        }
        let h = setup(clock: OverflowClock())
        let c = await online(h)
        let day: Int64 = 86_400_000
        c.receive(muted(["scope": "user", "mutedUntil": .int(h.clock.now() + 30 * day)]))
        c.receive(muted(["scope": "group", "groupId": "g1", "mutedUntil": .int(h.clock.now() + 40 * day)]))
        h.clock.advance(29 * day)
        XCTAssertEqual(h.im.muteState(AB)?.scope, .user)
        h.clock.advance(day)
        XCTAssertNil(h.im.muteState(AB))
        XCTAssertEqual(h.im.muteState(G1)?.scope, .group)
        h.clock.advance(10 * day)
        XCTAssertNil(h.im.muteState(G1))
        XCTAssertFalse(h.im.hasMuteTimer)
    }

    func testRemovalClearsGroupMute() async {
        let h = setup()
        let c = await online(h)
        c.receive(muted(["scope": "group", "groupId": "g1", "mutedUntil": nil]))
        c.receive(event("convRemoved", ["convId": .string(G1), "reason": "removed"]))
        c.receive(event("convAdded", ["conv": conv(G1)]))
        XCTAssertNil(h.im.muteState(G1))
        c.receive(muted(["scope": "user", "mutedUntil": nil]))
        h.im.disconnect()
        XCTAssertNil(h.im.muteState(AB))
    }

    func testMuteStateReadsServerTimeDirectly() async {
        let h = setup()
        let c = await online(h)
        c.receive(muted(["scope": "user", "mutedUntil": .int(h.clock.now() - 1)]))
        XCTAssertNil(h.im.muteState(AB))
    }
}
