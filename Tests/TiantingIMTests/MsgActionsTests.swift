import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-663, FE-664 (C4): recall, quote, mentions (PRD-chat section 8 F-RCL, F-QUO, F-MEN, 13.1). Same semantics as sdk-ts
// test/msg-actions.test.ts and sdk-kotlin MsgActionsTest.kt. The real IMClient + FakeTransport + fake clock ([SDK 钟]);
// the local database, cache folder, cold start and upgrade are in MsgActionsPersistenceTests. Shared cases are in
// ChatSyncVectorTests; every frame the SDK sends is checked against frame.schema.json (IMTestCase). Test names carry the
// TC number. Local `swift test` results, CI not running.

let C4_AB = "c2c:alice:bob"
let C4_G = "group:g1"
let RCL_SECRET = "ZXQ-RCL-2"
let QUO_SECRET = "ZXQ-QUO-1"

/// Message ids with characters the protocol allows (the schema's msgId has no ":" or "#").
func idOf(_ convId: String, _ seq: Int64) -> String {
    convId.filter { $0.isLetter || $0.isNumber } + "-\(seq)"
}

/// A downstream text message; `body` replaces the body, `type` the type.
func m(
    _ convId: String, _ seq: Int64, _ from: String = "bob", _ text: String? = nil, ts: Int64? = nil, body: JSONValue? = nil,
    type: String = "text"
) -> JSONValue {
    guard case .object(var o) = msg(convId, seq, from: from, text: text, ts: ts, msgId: idOf(convId, seq)) else { return nil }
    if let body { o["body"] = body }
    o["type"] = .string(type)
    return .object(o)
}

/// The server's recalled state (sync, a late msg): deleted + recalled, no body.
func recalledMsg(_ convId: String, _ seq: Int64, _ from: String = "bob", by: String? = nil, at: Int64 = 9) -> JSONValue {
    [
        "msgId": .string(idOf(convId, seq)), "clientMsgId": .string("\(from)-\(convId)-\(seq)"), "convId": .string(convId),
        "seq": .int(seq), "from": .string(from), "type": "text", "ts": .int(1000 + seq), "deleted": true, "recalled": true,
        "recalledAt": .int(at), "recalledBy": .string(by ?? from),
    ]
}

func quoteOf(_ convId: String, _ seq: Int64, _ text: String, from: String = "bob") -> JSONValue {
    [
        "msgId": .string(idOf(convId, seq)), "seq": .int(seq), "from": .string(from), "type": "text", "state": "normal",
        "text": .string(text),
    ]
}

/// The list summary when seq is the last message (convs' lastMsg).
func lastOf(_ convId: String, _ seq: Int64, _ from: String, _ text: String) -> JSONValue {
    ["msgId": .string(idOf(convId, seq)), "from": .string(from), "type": "text", "text": .string(text), "ts": .int(1000 + seq)]
}

func recalledEvent(_ convId: String, _ seq: Int64, by: String, at: Int64 = 3) -> JSONValue {
    event(
        "msgDeleted",
        [
            "convId": .string(convId), "msgIds": strs([idOf(convId, seq)]), "seqs": [.int(seq)],
            "recalled": ["by": .string(by), "at": .int(at)],
        ])
}

func deletedEvent(_ convId: String, _ seq: Int64) -> JSONValue {
    event("msgDeleted", ["convId": .string(convId), "msgIds": strs([idOf(convId, seq)]), "seqs": [.int(seq)]])
}

/// An error ack for the last request of `cmd`, with details and reason.
@MainActor
func ackErr(_ c: FakeConnection, _ cmd: String, _ code: Int, details: JSONValue? = nil, reason: String? = nil) {
    var e: [String: JSONValue] = ["code": .int(Int64(code)), "msg": "error"]
    if let details { e["details"] = details }
    if let reason { e["reason"] = .string(reason) }
    c.receive(["id": .string(c.last(cmd)!.id!), "cmd": "ack", "error": .object(e)])
}

@MainActor
extension Harness {
    /// Connects and logs in.
    func online(_ userId: String = "alice", _ convs: [JSONValue] = [], serverTime: Int64? = nil) async -> FakeConnection {
        im.connect(token: "token-value")
        return await login(userId, convs: convs, serverTime: serverTime)
    }

    /// Opens a conversation: loadHistory, the sync answered with `messages`.
    func loaded(_ c: FakeConnection, _ convId: String, _ messages: [JSONValue]) async throws {
        let t = Task { try await im.loadHistory(convId) }
        await settle()
        c.ack("sync", ["messages": .array(messages), "hasMore": false])
        _ = try await t.value
    }

    func bySeq(_ convId: String, _ seq: Int64) -> Message {
        im.messages(convId).first { $0.seq == seq }!
    }

    func convOf(_ convId: String) -> Conversation {
        im.conversations().first { $0.convId == convId }!
    }

    /// Runs `recall` and answers it with `answer` (nil: a plain ack).
    func recall(_ c: FakeConnection, _ convId: String, _ msgId: String, error: (Int, JSONValue?)? = nil) async -> Error? {
        let t = Task { try await im.recall(convId, msgId) }
        await settle()
        if let error { ackErr(c, "recall", error.0, details: error.1) } else { c.ack("recall", [:]) }
        do {
            try await t.value
            return nil
        } catch {
            return error
        }
    }
}

private func member(_ u: String, _ nick: String) -> JSONValue {
    ["userId": .string(u), "nickname": .string(nick), "role": "member", "joinedAt": 1, "avatar": "", "official": false]
}

private let AB = C4_AB
private let G = C4_G

@MainActor
final class MsgActionsTests: IMTestCase {
    private func quiet() -> Harness { setup(heartbeatMs: 10 * 365 * DAY) }  // No heartbeat drop while time moves.

    // MARK: Recall (F-RCL-01..03)

    func testTC_RCL_01_01_recallAckRecallsHereAtOnceOthersGetMsgDeletedWithRecalled() async throws {
        // The operator: wiped after the ack (the server sends no msgDeleted to the recalling connection, problem 27).
        let a = setup()
        let ca = await a.online("alice", [conv(AB, maxSeq: 1, lastMsg: lastOf(AB, 1, "alice", "\(RCL_SECRET) 原文"))])
        try await a.loaded(ca, AB, [m(AB, 1, "alice", "\(RCL_SECRET) 原文")])
        let t = Task { try await a.im.recall(AB, idOf(AB, 1)) }
        await settle()
        XCTAssertEqual(ca.last("recall")?.data, ["convId": .string(AB), "msgId": .string(idOf(AB, 1))])
        ca.ack("recall", [:])
        try await t.value
        let x = a.bySeq(AB, 1)
        XCTAssertTrue(x.isDeleted && x.isRecalled)
        XCTAssertEqual(x.recalledBy, "alice")
        XCTAssertEqual(x.recalledAt, a.im.serverNow())  // Estimated from server time; the next re-sync decides.
        XCTAssertEqual(x.body, MsgBody())
        XCTAssertEqual(a.im.recallText(x), "你撤回了一条消息")
        let last = a.convOf(AB).lastMsg!
        XCTAssertTrue(last.deleted == true && last.recalled == true)
        XCTAssertEqual(last.recalledBy, "alice")
        XCTAssertNil(last.text)
        XCTAssertEqual(a.im.recallText(convId: AB, lastMsg: last), "你撤回了一条消息")
        XCTAssertFalse(holds(a.im.store, RCL_SECRET))

        // The other side (bob) and alice's other device: msgDeleted with recalled.
        for (me, want) in [("bob", "对方撤回了一条消息"), ("alice", "你撤回了一条消息")] {
            let h = setup()
            let c = await h.online(me, [conv(AB, maxSeq: 1)])
            try await h.loaded(c, AB, [m(AB, 1, "alice", "\(RCL_SECRET) 原文")])
            c.receive(recalledEvent(AB, 1, by: "alice", at: 5))
            let y = h.bySeq(AB, 1)
            XCTAssertTrue(y.isDeleted && y.isRecalled, me)
            XCTAssertEqual(y.recalledBy, "alice")
            XCTAssertEqual(y.recalledAt, 5)
            XCTAssertEqual(h.im.recallText(y), want, me)
            XCTAssertFalse(holds(h.im.store, RCL_SECRET), me)
        }
    }

    func testTC_RCL_01_08_canRecallUsesServerTimeNotTheDeviceClock() async throws {
        let h = quiet()
        let server = h.clock.now() - 600_000  // The device clock is 10 minutes ahead of the server.
        let c = await h.online("alice", [conv(AB, maxSeq: 3)], serverTime: server)
        try await h.loaded(
            c, AB,
            [
                m(AB, 1, "alice", "60 秒前", ts: server - 60_000), m(AB, 2, "alice", "121 秒前", ts: server - 121_000),
                m(AB, 3, "alice", "恰好 120 秒", ts: server - 120_000),
            ])
        XCTAssertEqual((1...3).map { h.im.canRecall(h.bySeq(AB, Int64($0))) }, [true, false, true])
        XCTAssertEqual(h.im.messageActions(h.bySeq(AB, 1)), [.copy, .quote, .recall])
        XCTAssertEqual(h.im.messageActions(h.bySeq(AB, 2)), [.copy, .quote])

        // The menu stayed open 70 seconds: tapping "撤回" lets the server decide; 4097 with windowSeconds, no change, no retry.
        h.clock.advance(70_000)
        XCTAssertFalse(h.im.canRecall(h.bySeq(AB, 1)))
        let err = await h.recall(c, AB, idOf(AB, 1), error: (4097, ["windowSeconds": 120])) as? IMError
        XCTAssertEqual(err?.code, ErrorCode.recallWindowExpired)
        let ws = err?.details?["windowSeconds"]?.intValue
        XCTAssertEqual(messageFor(cmd: "recall", code: 4097, windowSeconds: ws), "发送时间超过 2 分钟，无法撤回")
        XCTAssertEqual(messageFor(cmd: "recall", code: 4097, windowSeconds: 604_800), "发送时间超过 7 天，无法撤回")
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("recall").count, 1)
        XCTAssertEqual(h.bySeq(AB, 1).body.text, "60 秒前")
        XCTAssertFalse(h.bySeq(AB, 1).isDeleted)
    }

    func testTC_RCL_01_08_groupWindowsAndRoles() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 5, myRole: "member")])
        let now = h.clock.now()
        let tip = m(
            G, 5, "", "", ts: now - 1_000,
            body: ["tip": ["kind": "created", "actor": "bob", "targets": [], "text": ""]], type: "tip")
        try await h.loaded(
            c, G,
            [
                m(G, 1, "bob", "别人 6 天前", ts: now - 6 * DAY), m(G, 2, "bob", "别人 8 天前", ts: now - 8 * DAY),
                m(G, 3, "alice", "自己 1 天前", ts: now - DAY), m(G, 4, "alice", "自己 60 秒前", ts: now - 60_000), tip,
            ])
        func can(_ role: GroupRole) -> [Bool] { (1...5).map { h.im.canRecall(h.bySeq(G, Int64($0)), myRole: role) } }
        XCTAssertEqual(can(.owner), [true, false, true, true, false])
        XCTAssertEqual(can(.admin), [true, false, true, true, false])  // Another admin's: the server says 4030 (rule 1b).
        XCTAssertEqual(can(.member), [false, false, false, true, false])
        // Without a role, the conversation list's myRole.
        XCTAssertEqual([1, 4].map { h.im.canRecall(h.bySeq(G, Int64($0))) }, [false, true])
        XCTAssertEqual(h.im.messageActions(h.bySeq(G, 5)), [])  // Tips have no menu.
    }

    func testAC_RCL_02_5_adminRecallingAnotherAdminGets4030AndNothingChanges() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 1, myRole: "admin")])
        try await h.loaded(c, G, [m(G, 1, "bob", "管理员 bob 的消息", ts: h.clock.now() - 1_000)])
        XCTAssertTrue(h.im.messageActions(h.bySeq(G, 1)).contains(.recall))
        let err = await h.recall(c, G, idOf(G, 1), error: (ErrorCode.forbidden, nil)) as? IMError
        XCTAssertEqual(err?.code, 4030)
        XCTAssertEqual(messageFor(cmd: "recall", code: 4030), "你没有权限撤回这条消息")
        XCTAssertEqual(h.bySeq(G, 1).body.text, "管理员 bob 的消息")
    }

    func testTC_RCL_02_04_managerRecallReadsTheSameOnChatPageAndList() async throws {
        let names = ["a": "阿管", "m": "小明", "n": "小牛"]
        let want = ["a": "你撤回了 小明 的一条消息", "m": "阿管撤回了你的一条消息", "n": "阿管撤回了一条成员消息"]
        for me in ["a", "m", "n"] {
            let h = setup()
            let c = await h.online(
                me, [conv(G, maxSeq: 1, lastMsg: lastOf(G, 1, "m", "\(RCL_SECRET) 成员的消息"), myRole: me == "a" ? "admin" : "member")])
            // Names come from member profiles (remarks are local, problem 19).
            let p = Task { try await h.im.loadGroupMembers("g1") }
            await settle()
            c.ack("groupMembers", ["members": .array(names.sorted { $0.key < $1.key }.map { member($0.key, $0.value) }), "nextCursor": ""])
            _ = try await p.value
            try await h.loaded(c, G, [m(G, 1, "m", "\(RCL_SECRET) 成员的消息", ts: h.clock.now() - 1_000)])
            if me == "a" {
                let e = await h.recall(c, G, idOf(G, 1))
                XCTAssertNil(e)
            } else {
                c.receive(recalledEvent(G, 1, by: "a", at: 9))
            }
            let last = h.convOf(G).lastMsg!
            XCTAssertTrue(last.deleted == true && last.recalled == true)
            XCTAssertEqual(last.recalledBy, "a")
            XCTAssertNil(last.text)
            XCTAssertEqual(h.im.recallText(h.bySeq(G, 1)), want[me], me)
            XCTAssertEqual(h.im.recallText(convId: G, lastMsg: last), want[me], "\(me) list")
            XCTAssertFalse(holds(h.im.store, RCL_SECRET))
        }
    }

    func testTC_RCL_03_01_recalledMsgDeletedWipesMemoryImageGoesViaFilesExpiredUnreadAndOrderKept() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(AB, maxSeq: 2)])
        let img = m(
            AB, 2, body: ["image": ["fileId": "f-zxq", "width": 1, "height": 1, "size": 1, "mime": "image/png"]], type: "image")
        try await h.loaded(c, AB, [m(AB, 1, "bob", "\(RCL_SECRET) 原文"), img])
        let before = h.events.count
        c.receive(
            event(
                "msgDeleted",
                [
                    "convId": .string(AB), "msgIds": strs([idOf(AB, 1), idOf(AB, 2)]), "seqs": [1, 2],
                    "recalled": ["by": "bob", "at": 7],
                ]))
        XCTAssertFalse(holds(h.im.store, RCL_SECRET))
        XCTAssertFalse(holds(h.im.store, "f-zxq"))
        XCTAssertEqual(h.im.messages(AB).map { "\($0.seq!):\($0.isDeleted):\($0.isRecalled)" }, ["1:true:true", "2:true:true"])
        XCTAssertTrue(h.im.messages(AB).allSatisfy { $0.body == MsgBody() })
        let expired = h.events[before...].compactMap { e -> [String]? in
            if case .filesExpired(let ids) = e { return ids } else { return nil }
        }
        XCTAssertEqual(expired, [["f-zxq"]])
        XCTAssertEqual(h.convOf(AB).updatedAt, 0)  // Unread and order stay (F-RCL-01 rule 6).
        XCTAssertEqual(h.convOf(AB).unread, 0)
    }

    func testTC_RCL_03_03_TC_RCL_03_11_recalledOfflineReconnectResyncsOnlyTheChangedConversation() async throws {
        let h = setup()
        let (c1, c2, c3) = ("c2c:alice:bob", "c2c:alice:carol", "c2c:alice:dave")
        var c = await h.online("alice", [conv(c1, maxSeq: 1, modVer: 1), conv(c2, maxSeq: 1, modVer: 1), conv(c3, maxSeq: 1, modVer: 1)])
        for id in [c1, c2, c3] {
            try await h.loaded(c, id, [m(id, 1, String(id.split(separator: ":")[2]), "\(RCL_SECRET) 原文")])
        }
        c.drop(1006)
        await settle()
        h.clock.advance(1_000)
        c = await h.login("alice", convs: [conv(c1, maxSeq: 1, modVer: 2), conv(c2, maxSeq: 1, modVer: 1), conv(c3, maxSeq: 1, modVer: 1)])
        await settle()
        XCTAssertEqual(c.frames("sync").map { $0.data?["convId"]?.stringValue }, [c1])
        c.ack("sync", ["messages": [recalledMsg(c1, 1, "bob", at: 3)], "hasMore": false])
        await settle()
        let x = h.bySeq(c1, 1)
        XCTAssertTrue(x.isDeleted && x.isRecalled)
        XCTAssertEqual(x.recalledBy, "bob")
        XCTAssertEqual(h.im.recallText(x), "对方撤回了一条消息")
        XCTAssertFalse(holds(h.im.messages(c1), RCL_SECRET))
        XCTAssertEqual(c.frames("sync").count, 1)
    }

    func testTC_RCL_03_06_groupOwnRecallListSummary() async throws {
        for (me, want) in [("u1", "你撤回了一条消息"), ("n", "u1撤回了一条消息")] {
            let h = setup()
            // From convs (the group was never opened): lastMsg with recalled and recalledBy.
            _ = await h.online(
                me,
                [
                    conv(G, maxSeq: 4, lastMsg: [
                        "msgId": "x4", "from": "u1", "type": "text", "ts": 4, "deleted": true, "recalled": true, "recalledBy": "u1",
                    ])
                ])
            XCTAssertEqual(h.im.recallText(convId: G, lastMsg: h.convOf(G).lastMsg!), want, me)
        }
    }

    func testTC_RCL_03_10_c2cNoticesAndRecalledLinesHaveNoMenu() {
        var line = Message(
            clientMsgId: "x", msgId: "x", seq: 1, convId: "c2c:u1:u2", from: "u1", type: .text, body: MsgBody(), ts: 0,
            status: .sent, error: nil, deleted: true, deletedAt: nil, recalled: true, recalledBy: "u1")
        XCTAssertEqual(recallText(recallNotice(convId: line.convId, message: line, me: "u2")!) { $0 }, "对方撤回了一条消息")
        XCTAssertEqual(recallText(recallNotice(convId: line.convId, message: line, me: "u1")!) { $0 }, "你撤回了一条消息")
        // A console deletion is no recall: no recall notice ("该消息已被删除").
        var deleted = line
        deleted.recalled = nil
        deleted.recalledBy = nil
        XCTAssertNil(recallNotice(convId: line.convId, message: deleted, me: "u2"))
        let h = setup()
        line.ts = h.clock.now()
        XCTAssertEqual(h.im.messageActions(line), [])
        XCTAssertFalse(h.im.canRecall(line))
        // The list summary uses the same table (old data without recalledBy: the sender recalled it).
        let last = LastMsg(msgId: "x", from: "u1", type: "text", ts: 0, deleted: true, recalled: true)
        XCTAssertEqual(recallText(recallNotice(convId: "c2c:u1:u2", lastMsg: last, me: "u2")!) { $0 }, "对方撤回了一条消息")
    }

    func testTC_RCL_03_13_lateOldAnswerBringsBackNeitherTextNorQuote() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 2)])
        try await h.loaded(c, G, [m(G, 1, "bob", "\(RCL_SECRET) 原文")])
        c.receive(recalledEvent(G, 1, by: "bob"))
        // A late old sync (read before the recall).
        let late = [
            m(G, 1, "bob", "\(RCL_SECRET) 原文"),
            m(G, 2, "carol", body: ["text": "回复", "quote": quoteOf(G, 1, "\(RCL_SECRET) 原文")]),
        ]
        let t = Task { try await h.im.loadHistory(G) }
        await settle()
        c.ack("sync", ["messages": .array(late), "hasMore": false])
        _ = try? await t.value
        for x in late { c.receive(msgFrame(x)) }  // The same may come late on the live channel.
        let m1 = h.bySeq(G, 1)
        XCTAssertTrue(m1.isDeleted && m1.isRecalled)
        XCTAssertEqual(m1.body, MsgBody())
        XCTAssertEqual(h.bySeq(G, 2).body.quote, QuoteView(msgId: idOf(G, 1), seq: 1, from: "bob", type: .text, state: .recalled))
        XCTAssertFalse(holds(h.im.store, RCL_SECRET))
    }

    func testF_RCL_03_rule2a_recalledOnlyGoesFalseToTrue() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 2)])
        try await h.loaded(c, G, [m(G, 1), m(G, 2)])
        c.receive(deletedEvent(G, 1))
        c.receive(recalledEvent(G, 2, by: "bob"))
        XCTAssertEqual(h.im.messages(G).map { "\($0.isDeleted):\($0.isRecalled)" }, ["true:false", "true:true"])
        c.receive(recalledEvent(G, 1, by: "bob", at: 4))  // Learned later that the console deletion was a recall.
        c.receive(deletedEvent(G, 2))  // A known recall stays a recall.
        XCTAssertEqual(
            h.im.messages(G).map { "\($0.isDeleted):\($0.isRecalled):\($0.recalledBy ?? "")" }, ["true:true:bob", "true:true:bob"])
    }

    func testF_RCL_03_rule2a_syncRevealsTheRecallAfterAConsoleWipeTextNeverReturns() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 1, lastMsg: lastOf(G, 1, "bob", RCL_SECRET))])
        try await h.loaded(c, G, [m(G, 1, "bob", RCL_SECRET)])
        c.receive(deletedEvent(G, 1))
        c.receive(msgFrame(recalledMsg(G, 1, "bob", at: 9)))
        c.receive(msgFrame(m(G, 1, "bob", RCL_SECRET)))
        let x = h.bySeq(G, 1)
        XCTAssertTrue(x.isDeleted && x.isRecalled)
        XCTAssertEqual(x.recalledBy, "bob")
        XCTAssertEqual(x.recalledAt, 9)
        XCTAssertEqual(x.body, MsgBody())
        let last = h.convOf(G).lastMsg!
        XCTAssertTrue(last.deleted == true && last.recalled == true)
        XCTAssertEqual(last.recalledBy, "bob")
        XCTAssertFalse(holds(h.im.store, RCL_SECRET))
    }

    func testF_RCL_03_rules2a_4_summaryRecallOnlyGoesFalseToTrue() async throws {
        let h = quiet()
        let c = await h.online("alice", [conv(G, maxSeq: 1, lastMsg: lastOf(G, 1, "bob", RCL_SECRET))])
        try await h.loaded(c, G, [m(G, 1, "bob", RCL_SECRET)])
        c.receive(deletedEvent(G, 1))
        XCTAssertEqual(h.convOf(G).lastMsg?.deleted, true)
        XCTAssertNil(h.convOf(G).lastMsg?.recalled)
        c.receive(recalledEvent(G, 1, by: "bob"))
        XCTAssertEqual(h.convOf(G).lastMsg?.recalled, true)
        XCTAssertEqual(h.convOf(G).lastMsg?.recalledBy, "bob")
        // convs made before the recall (only deleted, or still with the text): the summary stays a recall.
        let stale: [JSONValue] = [
            ["msgId": .string(idOf(G, 1)), "from": "bob", "type": "text", "ts": 1001, "deleted": true],
            lastOf(G, 1, "bob", RCL_SECRET),
        ]
        for s in stale {
            h.clock.advance(31_000)
            let t = Task { try await h.im.refreshConversations() }
            await settle()
            c.ack("convs", ["convs": [conv(G, maxSeq: 1, lastMsg: s)], "truncated": false])
            _ = try await t.value
            let last = h.convOf(G).lastMsg!
            XCTAssertTrue(last.deleted == true && last.recalled == true, "\(last)")
            XCTAssertNil(last.text)
        }
        XCTAssertFalse(holds(h.im.store, RCL_SECRET))
    }

    // Problem 32: the same as sdk-kotlin.
    func testF_RCL_03_rule4_missedMsgDeletedConvsLastMsgRecalledWipesTheLoadedOneAsARecall() async throws {
        let h = quiet()
        let c = await h.online("alice", [conv(G, maxSeq: 1, lastMsg: lastOf(G, 1, "bob", RCL_SECRET))])
        try await h.loaded(c, G, [m(G, 1, "bob", RCL_SECRET)])
        h.clock.advance(31_000)
        let t = Task { try await h.im.refreshConversations() }
        await settle()
        c.ack(
            "convs",
            [
                "convs": [
                    conv(G, maxSeq: 1, lastMsg: [
                        "msgId": .string(idOf(G, 1)), "from": "bob", "type": "text", "ts": 1001, "deleted": true,
                        "recalled": true, "recalledBy": "bob",
                    ])
                ],
                "truncated": false,
            ])
        _ = try await t.value
        let x = h.bySeq(G, 1)
        XCTAssertTrue(x.isDeleted && x.isRecalled)
        XCTAssertEqual(x.recalledBy, "bob")
        XCTAssertEqual(h.im.recallText(x), "bob撤回了一条消息")
        XCTAssertFalse(holds(h.im.store, RCL_SECRET))
    }

    // Problem 26.
    func testF_RCL_01_recallTimeoutIsNotRetriedNotConnectedThrows() async throws {
        let n = setup()
        do {
            try await n.im.recall(AB, "x")
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? IMConnectionError, .notConnected)
        }
        let h = quiet()
        let c = await h.online("alice", [conv(AB, maxSeq: 1)])
        try await h.loaded(c, AB, [m(AB, 1, "alice", "原文", ts: h.clock.now())])
        let t = Task { try await h.im.recall(AB, idOf(AB, 1)) }
        await settle()
        h.clock.advance(60_000)
        do {
            try await t.value
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? IMConnectionError, .timeout(cmd: "recall"))
        }
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("recall").count, 1)
        XCTAssertFalse(h.bySeq(AB, 1).isDeleted)
    }

    // MARK: Quotes (F-QUO-01, 02)

    func testTC_QUO_01_01_sendWithQuoteSendsOnlyTheMsgIdPendingBubbleHasTheBar() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(AB, maxSeq: 1)])
        let long = String(repeating: "长", count: 150)
        try await h.loaded(c, AB, [m(AB, 1, "bob", long)])
        XCTAssertNotNil(try h.im.send(AB, "回复你", quote: QuoteRef(msgId: idOf(AB, 1))).message)
        XCTAssertEqual(c.last("send")?.data?["body"], ["text": "回复你", "quote": ["msgId": .string(idOf(AB, 1))]])
        let want = QuoteView(
            msgId: idOf(AB, 1), seq: 1, from: "bob", type: .text, state: .normal, text: String(repeating: "长", count: 100))
        XCTAssertEqual(h.im.messages(AB).last?.body.quote, want)  // The first 100 code points (F-QUO-02 rule 2).
        c.ack("send", ["msgId": "mine-2", "convId": .string(AB), "seq": 2, "ts": 5])
        XCTAssertEqual(h.bySeq(AB, 2).status, .sent)
        XCTAssertEqual(h.bySeq(AB, 2).body.quote, want)

        // The other side gets the server's quote.
        let b = setup()
        let cb = await b.online("bob", [conv(AB, maxSeq: 1)])
        try await b.loaded(cb, AB, [m(AB, 1, "bob", long)])
        cb.receive(
            msgFrame(m(AB, 2, "alice", body: ["text": "回复你", "quote": quoteOf(AB, 1, String(repeating: "长", count: 100))])))
        XCTAssertEqual(b.bySeq(AB, 2).body.quote, want)
        XCTAssertEqual(quoteLabel(b.bySeq(AB, 2).body.quote!), String(repeating: "长", count: 100))
        // The quoted message was never loaded: only its msgId (normal, no text); the server's version comes later.
        _ = try b.im.send(AB, "引用很早的", quote: QuoteRef(msgId: "old-1"))
        XCTAssertEqual(b.im.messages(AB).last?.body.quote, QuoteView(msgId: "old-1", state: .normal))
    }

    func testF_QUO_02_rules2_3_summariesAndLabels() throws {
        func msgOf(_ type: MessageType, _ body: MsgBody) -> Message {
            Message(
                clientMsgId: "x", msgId: nil, seq: nil, convId: G, from: "bob", type: type, body: body, ts: 0, status: .sent,
                error: nil, deleted: nil, deletedAt: nil)
        }
        XCTAssertEqual(quoteSummary(msgOf(.image, MsgBody(image: ImageBody(fileId: "f")))), "[图片]")
        XCTAssertEqual(quoteSummary(msgOf(.file, MsgBody(file: FileBody(fileId: "f", name: "a.pdf")))), "[文件] a.pdf")
        XCTAssertEqual(
            quoteSummary(msgOf(.text, MsgBody(text: "自己的话", quote: QuoteView(msgId: "x", text: "更早的")))), "自己的话")
        XCTAssertEqual(quoteLabel(QuoteView(msgId: "x", state: .recalled)), "引用内容已被撤回")
        XCTAssertEqual(quoteLabel(QuoteView(msgId: "x", state: .deleted)), "引用内容已被删除")
        XCTAssertEqual(quoteLabel(QuoteView(msgId: "x", type: .image, state: .expired)), "[图片] 已过期")
        XCTAssertEqual(quoteLabel(QuoteView(msgId: "x", type: .file, state: .expired)), "[文件] 已过期")
        // An unknown state: "引用内容不可用"; a missing one too.
        let q = try JSONCoding.decoder.decode(QuoteView.self, from: Data(#"{"msgId":"x","state":"hidden"}"#.utf8))
        XCTAssertFalse(q.state.isKnown)
        XCTAssertEqual(quoteLabel(q), "引用内容不可用")
        let none = try JSONCoding.decoder.decode(QuoteView.self, from: Data(#"{"msgId":"x"}"#.utf8))
        XCTAssertEqual(quoteLabel(none), "引用内容不可用")
        // HTML stays plain text for the page to render as text (AC-QUO-02-5).
        XCTAssertEqual(quoteLabel(QuoteView(msgId: "x", text: "<img src=x onerror=alert(1)>")), "<img src=x onerror=alert(1)>")
        // Descriptions leave the quoted text out (13.1: never in logs).
        let secret = QuoteView(msgId: "x", text: "ZXQ")
        XCTAssertFalse("\(secret)".contains("ZXQ"))
        XCTAssertFalse(String(reflecting: secret).contains("ZXQ"))
    }

    func testTC_QUO_02_02_msgDeletedWithRecalledClearsReceivedAndPendingQuotes() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 2)])
        try await h.loaded(
            c, G,
            [m(G, 1, "bob", "\(QUO_SECRET) 原文"), m(G, 2, "carol", body: ["text": "回复", "quote": quoteOf(G, 1, "\(QUO_SECRET) 原文")])])
        c.drop(1006)  // Pending: a queued m3 quotes m1 too.
        await settle()
        _ = try h.im.send(G, "我也回复", quote: QuoteRef(msgId: idOf(G, 1)))
        XCTAssertEqual(h.im.messages(G).last?.body.quote?.text, "\(QUO_SECRET) 原文")
        let c2 = await h.reconnect()
        c2.receive(recalledEvent(G, 1, by: "bob"))
        let q2 = h.bySeq(G, 2).body.quote!
        XCTAssertEqual(q2, QuoteView(msgId: idOf(G, 1), seq: 1, from: "bob", type: .text, state: .recalled))
        XCTAssertEqual(quoteLabel(q2), "引用内容已被撤回")
        let q3 = h.im.messages(G).last!.body.quote!
        XCTAssertEqual(q3.state, .recalled)
        XCTAssertNil(q3.text)
        XCTAssertFalse(holds(h.im.store, QUO_SECRET))
    }

    func testF_QUO_02_rule4_consoleDeletionMakesQuotesDeleted() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 2)])
        try await h.loaded(c, G, [m(G, 1, "bob", QUO_SECRET), m(G, 2, "carol", body: ["text": "回复", "quote": quoteOf(G, 1, QUO_SECRET)])])
        c.receive(deletedEvent(G, 1))
        XCTAssertEqual(quoteLabel(h.bySeq(G, 2).body.quote!), "引用内容已被删除")
        XCTAssertFalse(h.bySeq(G, 1).isRecalled)
        _ = try h.im.send(G, "再引用", quote: QuoteRef(msgId: idOf(G, 1)))
        XCTAssertEqual(h.im.messages(G).last?.body.quote?.state, .deleted)
        XCTAssertFalse(holds(h.im.store, QUO_SECRET))
    }

    func testSendWithQuote4040FailsWithReasonNoResendLogsCarryNoQuoteOrMentions() async throws {
        let h = quiet()
        let c = await h.online("alice", [conv(G, maxSeq: 1)])
        try await h.loaded(c, G, [m(G, 1, "bob", "\(QUO_SECRET) 原文")])
        _ = try h.im.send(G, "@小王 ZXQ-MEN-NAME", quote: QuoteRef(msgId: idOf(G, 1)), mentions: Mentions(userIds: ["wang"]))
        ackErr(c, "send", 4040, reason: "quoteUnavailable")
        let x = h.im.messages(G).last!
        XCTAssertEqual(x.status, .failed)
        XCTAssertEqual(x.error, .code(4040))
        XCTAssertEqual(x.errorReason, "quoteUnavailable")
        h.clock.advance(30_000)
        await settle()
        XCTAssertEqual(c.frames("send").count, 1)
        let logs = h.logs.all.joined(separator: "\n")
        XCTAssertFalse(logs.contains(QUO_SECRET))
        XCTAssertFalse(logs.contains("ZXQ-MEN-NAME"))
        XCTAssertFalse(logs.contains("小王"))
    }

    // MARK: Mentions (F-MEN-01..03, FE-664)

    func testTC_MEN_01_01_mentionGoesUpDedupedReceiverCountsUpOthersDoNot() async throws {
        let u1 = setup()
        let c1 = await u1.online("u1", [conv(G, maxSeq: 4, mentionUnread: 0)])
        _ = try u1.im.send(G, "@小王 看一下", mentions: Mentions(userIds: ["u2", "u2", ""]))
        XCTAssertEqual(c1.last("send")?.data?["body"], ["text": "@小王 看一下", "mentions": ["userIds": ["u2"]]])
        c1.ack("send", ["msgId": "g1-5", "convId": .string(G), "seq": 5, "ts": 5])
        XCTAssertEqual(u1.convOf(G).mentionUnread, 0)  // My own does not count.
        // Neither does an @all from my other device (F-MEN-03 rule 6).
        c1.receive(msgFrame(m(G, 6, "u1", body: ["text": "@所有人", "mentions": ["all": true]])))
        XCTAssertEqual(u1.convOf(G).mentionUnread, 0)

        let incoming = m(G, 5, "u1", body: ["text": "@小王 看一下", "mentions": ["userIds": ["u2"]]])
        for (me, n, first) in [("u2", Int64(1), Int64?(5)), ("u3", 0, nil)] {
            let h = setup()
            let c = await h.online(me, [conv(G, maxSeq: 4, readSeq: 4, mentionUnread: 0)])
            c.receive(msgFrame(incoming))
            XCTAssertEqual(h.im.messages(G).last?.body.mentions, Mentions(userIds: ["u2"]))
            XCTAssertEqual(h.convOf(G).mentionUnread, n, me)
            XCTAssertEqual(h.convOf(G).firstMentionSeq, first, me)
        }

        // @all counts; reading up to the newest here clears it (the jump button goes).
        let h = setup()
        let c = await h.online("u3", [conv(G, maxSeq: 4, readSeq: 4, mentionUnread: 0)])
        c.receive(msgFrame(m(G, 6, "o", body: ["text": "@所有人", "mentions": ["all": true]])))
        XCTAssertEqual(h.convOf(G).mentionUnread, 1)
        XCTAssertEqual(h.convOf(G).firstMentionSeq, 6)
        h.im.setActiveConversation(G)
        await settle()
        XCTAssertEqual(c.last("read")?.data, ["convId": .string(G), "seq": 6])
        XCTAssertEqual(h.convOf(G).mentionUnread, 0)
        XCTAssertNil(h.convOf(G).firstMentionSeq)
        // A conversation the server never counted (feature off, older server) is not guessed.
        let old = setup()
        let co = await old.online("u2", [conv(G, maxSeq: 4, readSeq: 4)])
        co.receive(msgFrame(incoming))
        XCTAssertNil(old.convOf(G).mentionUnread)
    }

    func testF_MEN_03_rule1_mentionsBeforeTheReadPositionDoNotCount() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 10, readSeq: 10, mentionUnread: 0)])
        try await h.loaded(c, G, [m(G, 10)])
        c.receive(msgFrame(m(G, 8, "bob", body: ["text": "@alice 早的", "mentions": ["userIds": ["alice"]]])))
        XCTAssertEqual(h.convOf(G).mentionUnread, 0)
        c.receive(msgFrame(m(G, 11, "bob", body: ["text": "@alice 新的", "mentions": ["userIds": ["alice"]]])))
        XCTAssertEqual(h.convOf(G).mentionUnread, 1)
        XCTAssertEqual(h.convOf(G).firstMentionSeq, 11)
    }

    func testF_MEN_01_rule1_mentionsInC2CThrowBeforeQueueingEmptyMentionsAreLeftOut() async throws {
        let h = setup()
        let c = await h.online("alice")
        XCTAssertThrowsError(try h.im.send(AB, "@bob", mentions: Mentions(userIds: ["bob"]))) { e in
            XCTAssertTrue((e as? IMArgumentError)?.description.contains("group") == true)
        }
        XCTAssertEqual(h.im.messages(AB), [])
        _ = try h.im.send(G, "纯文本", mentions: Mentions(userIds: [], all: false))
        XCTAssertEqual(c.last("send")?.data?["body"], ["text": "纯文本"])
    }

    func testTC_MEN_02_05_atAll4293FailsWithCopyNoAutoResendAfterReconnect4131Too() async throws {
        let h = quiet()
        let c = await h.online("o", [conv(G, maxSeq: 1, myRole: "owner")])
        _ = try h.im.send(G, "@所有人 开会", mentions: Mentions(all: true))
        XCTAssertEqual(c.last("send")?.data?["body"], ["text": "@所有人 开会", "mentions": ["all": true]])
        ackErr(c, "send", 4293, details: ["retryAfterSeconds": 600])
        let mine = h.im.messages(G).last!
        XCTAssertEqual(mine.status, .failed)
        XCTAssertEqual(mine.error, .code(ErrorCode.mentionAllLimited))
        XCTAssertTrue(h.events.contains { if case .sendFailed(_, _, .code(4293)) = $0 { return true } else { return false } })
        XCTAssertEqual(messageFor(cmd: "send", code: 4293), "@所有人次数已用完")
        // 4131 (too many mentioned, a development bug) fails the same way.
        _ = try h.im.send(G, "@很多人", mentions: Mentions(userIds: (1...21).map { "u\($0)" }))
        ackErr(c, "send", ErrorCode.batchLimitExceeded)
        XCTAssertEqual(h.im.messages(G).last?.error, .code(4131))
        c.drop(1006)
        await settle()
        let c2 = await h.reconnect(userId: "o")
        c2.ack("convs", ["convs": [conv(G, maxSeq: 1, myRole: "owner")], "truncated": false])
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c2.frames("send").count, 0)
        XCTAssertEqual(statusOf(h, G), ["cid-0001:failed(4293)", "cid-0002:failed(4131)"])
    }

    func testTC_MEN_03_07_noMentionsNoConvsFetchNorWhileDisconnected() async throws {
        let h = quiet()
        let c = await h.online(
            "alice",
            [conv(G, maxSeq: 9, mentionUnread: 0), conv("group:g2", maxSeq: 9), conv("group:g3", maxSeq: 9, mentionUnread: 1, firstMentionSeq: 9)])
        let before = c.frames("convs").count
        c.receive(event("readUpdated", ["convId": .string(G), "readSeq": 9]))
        c.receive(event("msgDeleted", ["convId": "group:g2", "msgIds": ["x"], "seqs": [3]]))
        h.clock.advance(10_000)
        await settle()
        XCTAssertEqual(c.frames("convs").count, before)
        // With mentions: a second event inside the window waits for its end; disconnected by then, nothing is fetched.
        c.receive(event("readUpdated", ["convId": "group:g3", "readSeq": 9]))
        await settle()
        XCTAssertEqual(c.frames("convs").count, before + 1)
        c.ack("convs", ["convs": [conv("group:g3", maxSeq: 9, mentionUnread: 1, firstMentionSeq: 9)], "truncated": false])
        await settle()
        c.receive(event("readUpdated", ["convId": "group:g3", "readSeq": 9]))
        c.drop(1006)
        await settle()
        h.clock.advance(5_000)
        await settle()
        XCTAssertEqual(c.frames("convs").count, before + 1)
        XCTAssertFalse(h.logs.all.contains { $0.contains("mention refresh failed") })  // Not even tried offline.
    }

    func testTC_MEN_03_07_refreshAppliesTheWholeConvsLogoutDropsTheThrottleTimer() async throws {
        let h = quiet()
        let c = await h.online("alice", [conv(G, maxSeq: 9, mentionUnread: 1, firstMentionSeq: 5)])
        c.receive(recalledEvent(G, 5, by: "bob"))
        await settle()
        XCTAssertEqual(c.frames("convs").count, 2)
        c.ack("convs", ["convs": [conv(G, name: "新群名", maxSeq: 9, mentionUnread: 0)], "truncated": false])
        await settle()
        XCTAssertEqual(h.convOf(G).mentionUnread, 0)
        XCTAssertNil(h.convOf(G).firstMentionSeq)
        XCTAssertEqual(h.convOf(G).name, "新群名")
        // A new @me (+1 here); a readUpdated inside the window waits; logging out and in, the old timer fetches nothing.
        c.receive(msgFrame(m(G, 10, "bob", body: ["text": "@alice", "mentions": ["userIds": ["alice"]]])))
        XCTAssertEqual(h.convOf(G).mentionUnread, 1)
        XCTAssertEqual(h.convOf(G).firstMentionSeq, 10)
        c.receive(event("readUpdated", ["convId": .string(G), "readSeq": 10]))
        await settle()
        XCTAssertEqual(c.frames("convs").count, 2)
        h.im.disconnect()
        let c2 = await h.online("alice", [conv(G, maxSeq: 10, mentionUnread: 1, firstMentionSeq: 10)])
        h.clock.advance(10_000)
        await settle()
        XCTAssertEqual(c2.frames("convs").count, 1)
        // The first event of the new login fetches at once (the window was reset too).
        c2.receive(event("readUpdated", ["convId": .string(G), "readSeq": 10]))
        await settle()
        XCTAssertEqual(c2.frames("convs").count, 2)
    }

    func testF_MEN_01_rule6_searchGroupMembersKeywordProfilesCached4290NotRetried() async throws {
        let h = quiet()
        let c = await h.online("alice")
        let p = Task { try await h.im.searchGroupMembers("g1", keyword: "zh") }
        await settle()
        XCTAssertEqual(c.last("groupMembers")?.data, ["groupId": "g1", "keyword": "zh"])
        c.ack("groupMembers", ["members": [member("zhang", "张三")], "nextCursor": ""])
        let page = try await p.value
        XCTAssertEqual(page.members.map(\.userId), ["zhang"])
        XCTAssertEqual(h.im.displayName("zhang"), "张三")
        let p2 = Task { try await h.im.searchGroupMembers("g1", keyword: "", cursor: "cur") }
        await settle()
        XCTAssertEqual(c.last("groupMembers")?.data, ["groupId": "g1", "cursor": "cur"])
        c.ack("groupMembers", ["members": [], "nextCursor": ""])
        _ = try await p2.value
        let p3 = Task { try await h.im.searchGroupMembers("g1", keyword: "z") }
        await settle()
        ackErr(c, "groupMembers", ErrorCode.rateLimited)
        do {
            _ = try await p3.value
            XCTFail("expected 4290")
        } catch {
            XCTAssertEqual((error as? IMError)?.code, 4290)
        }
        h.clock.advance(5_000)
        await settle()
        XCTAssertEqual(c.frames("groupMembers").count, 3)
    }

    // MARK: Frames (AC-CHAT-90-10)

    func testTC_CHAT_90_32_c4FramesTheSdkSendsMatchTheSchema() async throws {
        let h = setup()
        let c = await h.online("alice", [conv(G, maxSeq: 3, myRole: "owner")])
        try await h.loaded(c, G, [m(G, 3, "bob", "被引用的原文", ts: h.clock.now())])
        _ = try h.im.send(G, "@bob 看这条", quote: QuoteRef(msgId: idOf(G, 3)), mentions: Mentions(userIds: ["bob", "bob"]))
        _ = try h.im.send(G, "@所有人 开会", mentions: Mentions(all: true))
        _ = try h.im.send(AB, "单聊引用", quote: QuoteRef(msgId: "m1"))
        let r = Task { try await h.im.recall(G, idOf(G, 3)) }
        let s = Task { try await h.im.searchGroupMembers("g1", keyword: "zh") }
        await settle()
        let schema = try SchemaValidator.shared()
        XCTAssertTrue(Set(c.frames().map(\.cmd)).isSuperset(of: ["recall", "send", "groupMembers"]))
        for f in c.frames() { XCTAssertTrue(schema.isValid(f.raw), f.cmd) }
        XCTAssertEqual(c.last("groupMembers")?.data, ["groupId": "g1", "keyword": "zh"])
        XCTAssertEqual(
            c.frames("send")[0].data?["body"],
            ["text": "@bob 看这条", "quote": ["msgId": .string(idOf(G, 3))], "mentions": ["userIds": ["bob"]]])
        r.cancel()
        s.cancel()
    }

    func testTC_CHAT_90_32_c4DownstreamFramesDecodeIntoTheModels() throws {
        let valid = try loadJSON("vectors/frames.json")["valid"]!.arrayValue!
        func frame(_ name: String) -> Data {
            Data(valid.first { $0["name"]?.stringValue == name }!["frame"]!.jsonString().utf8)
        }
        let q = try decodeFrameData(ServerMessage.self, from: frame("msg quote state=normal（C4）")).body!.quote!
        XCTAssertEqual(q.state, .normal)
        XCTAssertEqual(q.text, "被引用的原文")
        let gone = try decodeFrameData(ServerMessage.self, from: frame("msg quote 原消息已不存在（C4）")).body!.quote!
        XCTAssertEqual(gone, QuoteView(msgId: "m3", state: .deleted))
        let men = try decodeFrameData(ServerMessage.self, from: frame("msg 带 mentions.all（C4）")).body!.mentions!
        XCTAssertTrue(men.all)
        let sync = try decodeFrameData(SyncAck.self, from: frame("ack sync 含撤回的消息（C4）"))
        XCTAssertEqual(sync.messages.map { $0.recalled == true }, [false, true, true])
        XCTAssertEqual(sync.messages[1].recalledBy, "u1")
        let convs = try decodeFrameData(ConvsAck.self, from: frame("ack convs lastMsg 撤回、mentionUnread（C4）"))
        XCTAssertEqual(convs.convs.map(\.mentionUnread), [2, 0])
        XCTAssertEqual(convs.convs.map(\.firstMentionSeq), [5, nil])
        XCTAssertEqual(convs.convs[0].lastMsg?.recalled, true)
        XCTAssertEqual(convs.convs[0].lastMsg?.recalledBy, "o")
        let added = try decodeFrameData(
            [String: JSONValue].self, from: frame("event convAdded 带 mentionUnread（C4）"))["conv"]!
        let conv = try JSONCoding.decoder.decode(ServerConversation.self, from: Data(added.jsonString().utf8))
        XCTAssertEqual(conv.mentionUnread, 0)
    }

    // Problem 36 (BE-479, F-UI-09 rule 4): `GET /v1/config` features.msgActions.
    func testConfigFeaturesMsgActions() throws {
        func features(_ f: JSONValue) throws -> AccountConfig.Features {
            try JSONCoding.decoder.decode(AccountConfig.Features.self, from: Data(f.jsonString().utf8))
        }
        XCTAssertEqual(try features(["files": true, "msgActions": true]).msgActions, true)
        XCTAssertEqual(try features(["files": true, "msgActions": false]).msgActions, false)
        XCTAssertNil(try features(["files": true]).msgActions)  // Older servers.
        // The schema's config response allows it.
        let body: JSONValue = [
            "registerMode": "invite", "demoLogin": false, "features": ["files": false, "msgActions": true],
            "limits": [
                "usernameMinLen": 4, "usernameMaxLen": 32, "passwordMinLen": 8, "passwordMaxLen": 128, "nicknameMaxLen": 32,
                "deviceNameMaxLen": 64,
            ],
        ]
        let cfg = try JSONCoding.decoder.decode(AccountConfig.self, from: Data(body.jsonString().utf8))
        XCTAssertEqual(cfg.features.msgActions, true)
        XCTAssertFalse(cfg.features.files)
    }
}
