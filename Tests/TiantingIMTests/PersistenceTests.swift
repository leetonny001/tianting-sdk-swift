import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let AB = "c2c:alice:bob"
private let G1 = "group:g1"
private let SECRET = "ZXQ-DEL-555"

/// The local database (FE-141, FE-436): survival across launches, and deleted text gone from the raw files.
@MainActor
final class PersistenceTests: IMTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tianting-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    /// Every file the database left in the directory, as raw bytes. Nothing is opened through SQLite.
    private func rawFiles() throws -> [(name: String, data: Data)] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        }
    }

    private func diskContains(_ needle: String) throws -> Bool {
        let bytes = Data(needle.utf8)
        return try rawFiles().contains { $0.data.range(of: bytes) != nil }
    }

    private func onlineClient(convs: [JSONValue], clock: FakeClock? = nil) async -> (Harness, FakeConnection) {
        let h = setup(clock: clock, directory: dir)
        h.im.connect(token: "secret-token-xyz")
        let c = await h.login("alice", convs: convs)
        return (h, c)
    }

    private func deletedEvent(_ convId: String, _ ids: [String], _ seqs: [Int64]) -> JSONValue {
        event("msgDeleted", ["convId": .string(convId), "msgIds": strs(ids), "seqs": .array(seqs.map { .int($0) })])
    }

    // MARK: AC-ADM-31-4 / TC-ADM-31-04: raw bytes

    func testDeletedTextIsGoneFromRawFiles() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: "keep this text")))
        c.receive(msgFrame(msg(G1, 2, text: "秘密 \(SECRET) 中文也算")))
        c.receive(msgFrame(msg(G1, 3, text: "tail \(SECRET) again")))
        XCTAssertTrue(try diskContains(SECRET))  // Control: the check can really see it.
        XCTAssertTrue(try diskContains("中文也算"))
        c.receive(deletedEvent(G1, ["\(G1)#2", "\(G1)#3"], [2, 3]))
        XCTAssertFalse(try diskContains(SECRET))
        XCTAssertFalse(try diskContains("中文也算"))
        XCTAssertTrue(try diskContains("keep this text"))  // Only the deleted ones went.
        XCTAssertEqual(h.im.messages(G1)[1].deleted, true)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.deleted, true)
    }

    // Message text big enough to spill into overflow pages, in several rows, deleted out of order.
    func testDeletedLongTextInOverflowPages() async throws {
        let (_, c) = await onlineClient(convs: [conv(G1)])
        let long = String(repeating: "ABCDEF-\(SECRET)-", count: 300)
        for s in 1...20 { c.receive(msgFrame(msg(G1, Int64(s), text: long))) }
        XCTAssertTrue(try diskContains(SECRET))
        c.receive(deletedEvent(G1, (1...20).map { "\(G1)#\($0)" }, (1...20).map { Int64($0) }))
        XCTAssertFalse(try diskContains(SECRET))
    }

    func testOnlyOneFileAtRestNoWal() async throws {
        let (_, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        XCTAssertEqual(try rawFiles().map(\.name).count, 1)
        c.receive(deletedEvent(G1, ["\(G1)#1"], [1]))
        let names = try rawFiles().map(\.name)
        XCTAssertEqual(names.count, 1, "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-journal") || $0.hasSuffix("-shm") })
    }

    func testSyncReturningDeletedWipesRawFiles() async throws {
        let (h, c1) = await onlineClient(convs: [conv(G1)])
        c1.receive(msgFrame(msg(G1, 1, text: SECRET)))
        c1.receive(msgFrame(msg(G1, 2, text: "tail")))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv(G1, maxSeq: 2, unread: 2)], "truncated": false])
        await flush()
        XCTAssertTrue(try diskContains(SECRET))
        c2.ack("sync", ["messages": [deletedMsg(G1, 1), msg(G1, 2, text: "tail")], "hasMore": false])
        await flush()
        XCTAssertFalse(try diskContains(SECRET))
    }

    func testConvsDeletedLastMsgWipesRawFiles() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        h.clock.advance(31_000)
        async let p = h.im.refreshConversations()
        await flush()
        c.ack("convs", ["convs": [conv(G1, maxSeq: 1, unread: 1, lastMsg: ["msgId": .string("\(G1)#1"), "from": "bob", "type": "text", "ts": 1, "deleted": true])], "truncated": false])
        _ = try await p
        XCTAssertFalse(try diskContains(SECRET))
    }

    // F-ADM-24 rule 7: removal deletes that conversation from the local database, for any reason.
    func testConvRemovedDeletesFromDatabase() async throws {
        for reason: JSONValue? in ["removed", "dissolved", "left", "future-reason", nil] {
            let (h, c) = await onlineClient(convs: [conv(G1), conv(AB)])
            c.receive(msgFrame(msg(G1, 1, text: SECRET)))
            c.receive(msgFrame(msg(AB, 1, text: "keep-c2c")))
            XCTAssertTrue(try diskContains(SECRET))
            var fields: [String: JSONValue] = ["convId": .string(G1)]
            if let reason { fields["reason"] = reason }
            c.receive(event("convRemoved", fields))
            XCTAssertFalse(try diskContains(SECRET), "reason \(String(describing: reason))")
            XCTAssertTrue(try diskContains("keep-c2c"))
            // A message that arrives late for that group does not bring it back either.
            h.im.close()
            let second = setup(directory: dir)
            second.im.restoreCache(userId: "alice")
            XCTAssertNil(second.im.conversations().first { $0.convId == G1 })
            XCTAssertEqual(second.im.messages(G1), [])
            second.im.disconnect()
        }
    }

    func testInferredRemovalAfterReconnectDeletesFromDatabase() async throws {
        let (h, c1) = await onlineClient(convs: [conv(G1)])
        c1.receive(msgFrame(msg(G1, 1, text: SECRET)))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [], "truncated": false])
        await flush()
        XCTAssertFalse(try diskContains(SECRET))
    }

    // Local leave and dissolve go through the same path.
    func testLeaveGroupDeletesFromDatabase() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        async let p: Void = h.im.leaveGroup("g1")
        await flush()
        c.ack("groupLeave", [:])
        try await p
        XCTAssertFalse(try diskContains(SECRET))
    }

    // The VACUUM fallback when SQLite refuses secure_delete: the file is still clean after each wipe.
    func testVacuumFallbackWipes() throws {
        let url = dir.appendingPathComponent("fallback.sqlite")
        let db = try LocalDatabase(url: url, refuseSecureDelete: true)
        defer { db.close() }
        func message(deleted: Bool) -> Message {
            Message(
                clientMsgId: "c1", msgId: "m1", seq: 1, convId: G1, from: "bob", type: .text,
                body: deleted ? MsgBody() : MsgBody(text: SECRET), ts: 1, status: .sent, error: nil,
                deleted: deleted ? true : nil, deletedAt: nil)
        }
        try db.apply(LocalChanges(upsertMessages: [message(deleted: false)]))
        XCTAssertTrue(try diskContains(SECRET))
        try db.apply(LocalChanges(upsertMessages: [message(deleted: true)]))
        XCTAssertFalse(try diskContains(SECRET))
    }

    func testTokenNeverOnDisk() async throws {
        let (_, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: "x")))
        XCTAssertFalse(try diskContains("secret-token-xyz"))
    }

    func testUnsentTextNotOnDisk() async throws {
        let (h, c) = await onlineClient(convs: [conv(AB)])
        _ = try h.im.send(AB, "unsent-\(SECRET)")
        XCTAssertFalse(try diskContains(SECRET))
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 1])
        await flush()
        XCTAssertTrue(try diskContains(SECRET))  // Confirmed: it is a cached message now.
    }

    // MARK: Cleared on logout and kick (FE-141)

    func testLogoutRemovesFiles() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        XCTAssertEqual(try rawFiles().count, 1)
        h.im.disconnect()
        XCTAssertEqual(try rawFiles().count, 0)
    }

    func testKickRemovesFilesEvenWithPendingAndLaterEvents() async throws {
        let (h, c) = await onlineClient(convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1, text: SECRET)))
        _ = try h.im.send(AB, "pending")
        c.receive(event("kicked", ["reason": "suspended", "until": nil]))
        c.drop(4012)
        XCTAssertEqual(try rawFiles().count, 0)
        XCTAssertEqual(h.im.messages(AB).last?.status, .failed)
    }

    func testAccountSwitchWipesPreviousUser() async throws {
        let (h, c1) = await onlineClient(convs: [conv(AB)])
        c1.receive(msgFrame(msg(AB, 1, text: SECRET)))
        c1.drop(1006)
        h.clock.advance(1_000)
        let c2 = h.transport.current
        c2.open()
        c2.ack("auth", ["userId": "carol", "serverTime": .int(h.clock.now())])
        await flush()
        XCTAssertFalse(try diskContains(SECRET))
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertEqual(h.im.userId, "carol")
    }

    // MARK: Across launches

    func testMessagesAndConversationsSurviveRestart() async throws {
        let (h, c) = await onlineClient(convs: [conv(AB, name: "鲍勃", maxSeq: 0, updatedAt: 5, memberCount: nil)])
        c.receive(msgFrame(msg(AB, 1, text: "你好")))
        c.receive(msgFrame(msg(AB, 2, text: "再见")))
        h.im.close()

        let h2 = setup(directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.conversations().map(\.name), ["鲍勃"])
        XCTAssertEqual(h2.im.conversations()[0].unread, 2)
        XCTAssertEqual(h2.im.messages(AB).map(\.body.text), ["你好", "再见"])
        XCTAssertEqual(h2.im.messages(AB).map(\.status), [.sent, .sent])
        XCTAssertEqual(h2.im.userId, "alice")

        // Offline send works once the user is known from the cache, and goes out on connect.
        _ = try h2.im.send(AB, "offline")
        h2.im.connect(token: "t")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h2.clock.now())])
        await flush()
        XCTAssertEqual(c2.frames("send").count, 1)
    }

    // Reconnect behaves as before: catch-up from the cached maxSeq, no duplicates.
    func testRestartCatchesUpFromCachedSeq() async throws {
        let (h, c) = await onlineClient(convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1)))
        c.receive(msgFrame(msg(AB, 2)))
        h.im.close()

        let h2 = setup(directory: dir)
        h2.im.connect(token: "t")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h2.clock.now())])
        await flush()
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 3, unread: 1)], "truncated": false])
        await flush()
        XCTAssertEqual(c2.frames("sync")[0].data, ["convId": .string(AB), "afterSeq": 2, "limit": 200])
        c2.ack("sync", ["messages": [msg(AB, 3)], "hasMore": false])
        await flush()
        XCTAssertEqual(h2.im.messages(AB).map(\.seq), [1, 2, 3])
    }

    // F-ADM-31 rule 5 on a cold start: cached messages get checked once, so one deleted while the app was dead is wiped.
    func testRestartRechecksCachedRangeAndWipes() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        c.receive(msgFrame(msg(G1, 2, text: "tail")))
        h.im.close()
        XCTAssertTrue(try diskContains(SECRET))

        let h2 = setup(directory: dir)
        h2.im.connect(token: "t")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h2.clock.now())])
        await flush()
        c2.ack("convs", ["convs": [conv(G1, maxSeq: 2, unread: 2)], "truncated": false])
        await flush()
        c2.ack("socialSync", socialPage())
        await flush()
        XCTAssertEqual(c2.last("sync")?.data, ["convId": .string(G1), "afterSeq": 0, "limit": 200])
        c2.ack("sync", ["messages": [deletedMsg(G1, 1), msg(G1, 2, text: "tail")], "hasMore": false])
        await flush()
        XCTAssertFalse(try diskContains(SECRET))
    }

    func testRestoredConversationRecheckedOnlyOnce() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1)))
        h.im.close()

        let h2 = setup(directory: dir)
        h2.im.connect(token: "t")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h2.clock.now())])
        await flush()
        c2.ack("convs", ["convs": [conv(G1, maxSeq: 1)], "truncated": false])
        await flush()
        c2.ack("sync", ["messages": [], "hasMore": false])  // Nothing new came back: the list stays untouched.
        await flush()
        XCTAssertEqual(c2.frames("sync").count, 1)
        c2.drop(1006)
        let c3 = await h2.reconnect()
        c3.ack("convs", ["convs": [conv(G1, maxSeq: 1)], "truncated": false])
        await flush()
        XCTAssertEqual(c3.frames("sync").count, 0)
    }

    func testRetentionKeepsNewestMessages() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        for s in 1...30 { c.receive(msgFrame(msg(G1, Int64(s), text: "body-\(s)-end"))) }
        h.im.close()
        let h2 = setup(directory: dir, maxCached: 10)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.messages(G1).map(\.seq), (21...30).map { Int64($0) })
        XCTAssertFalse(try diskContains("body-5-end"))  // Trimmed rows are wiped too.
        XCTAssertTrue(try diskContains("body-25-end"))
    }

    func testGapResetClearsStoredMessages() async throws {
        let (h, c1) = await onlineClient(convs: [conv(AB)])
        c1.receive(msgFrame(msg(AB, 1, text: "before-gap-text")))
        c1.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 251, unread: 250)], "truncated": false])
        await flush()
        c2.ack("sync", ["messages": .array((0..<20).map { msg(AB, 232 + Int64($0)) }), "hasMore": true])
        await flush()
        XCTAssertFalse(try diskContains("before-gap-text"))
        h.im.close()
        let h2 = setup(directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.messages(AB).count, 20)
    }

    func testReadStatePersists() async throws {
        let (h, c) = await onlineClient(convs: [conv(AB, maxSeq: 3, unread: 3)])
        c.receive(event("readUpdated", ["convId": .string(AB), "readSeq": 2]))
        h.im.close()
        let h2 = setup(directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.conversations()[0].readSeq, 2)
        XCTAssertEqual(h2.im.conversations()[0].unread, 1)
    }

    func testTwoUsersDoNotShareAFile() {
        XCTAssertNotEqual(LocalDatabase.fileName(userId: "alice"), LocalDatabase.fileName(userId: "Alice"))
        XCTAssertFalse(LocalDatabase.fileName(userId: "../../etc").contains("/"))
    }

    func testCorruptFileIsRebuilt() async throws {
        let url = dir.appendingPathComponent(LocalDatabase.fileName(userId: "alice"))
        try Data(repeating: 0x41, count: 8192).write(to: url)
        let (h, c) = await onlineClient(convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1, text: "after-rebuild")))
        XCTAssertNotNil(h.im.databaseURL)
        XCTAssertTrue(try diskContains("after-rebuild"))
    }

    // A write that fails drops the cache rather than leaving deleted text behind.
    func testFailedWriteDropsCache() async throws {
        let (h, c) = await onlineClient(convs: [conv(G1)])
        c.receive(msgFrame(msg(G1, 1, text: SECRET)))
        h.im.database?.failNextWrite = true
        c.receive(deletedEvent(G1, ["\(G1)#1"], [1]))
        XCTAssertNil(h.im.databaseURL)
        XCTAssertFalse(try diskContains(SECRET))
        XCTAssertEqual(h.im.messages(G1)[0].deleted, true)  // Memory keeps working.
        c.receive(msgFrame(msg(G1, 2)))
        XCTAssertEqual(h.im.messages(G1).count, 2)
    }

    func testLogoutForgetsUser() async throws {
        let (h, _) = await onlineClient(convs: [])
        h.im.disconnect()
        XCTAssertEqual(h.im.userId, "")
        XCTAssertThrowsError(try h.im.send(AB, "x"))
    }

    func testNoDirectoryMeansMemoryOnly() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(AB)])
        c.receive(msgFrame(msg(AB, 1)))
        XCTAssertNil(h.im.databaseURL)
        XCTAssertEqual(try rawFiles().count, 0)
    }

    // MARK: Social persistence (FE-141)

    // "App killed, restart syncs incrementally from the stored ver": no close(), the file just stays there.
    func testSocialSurvivesKillAndSyncsFromStoredVer() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack(
            "socialSync",
            socialPage(
                untilVer: 7, friends: [friend("bob", 3, remark: "老板")], requests: [req("carol", "in", 5)],
                blocks: [["userId": "dave", "createdAt": 1, "ver": 6, "profile": nil]], requestSeenVer: 2,
                mode: "friends", strangerMsgLimit: 3, official: true))
        await flush()
        XCTAssertEqual(h.im.friends().count, 1)

        let h2 = setup(clock: h.clock, directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertTrue(h2.im.socialLoaded())
        XCTAssertEqual(h2.im.friends().map(\.displayName), ["老板"])
        XCTAssertEqual(h2.im.blocks().map(\.userId), ["dave"])
        XCTAssertEqual(h2.im.friendRequests().unseen, 1)
        XCTAssertEqual(h2.im.socialSettings(), SocialSettings(searchable: true, mode: .friends, strangerMsgLimit: 3))
        XCTAssertTrue(h2.im.isOfficial())
        XCTAssertEqual(h2.im.relationOf("bob"), .friend)

        h2.im.connect(token: "t")
        let c2 = await h2.login("alice")
        XCTAssertEqual(c2.last("socialSync")?.data, ["sinceVer": 7, "limit": 500])
    }

    // PRD-social 10.2: ver and data land together. Killed between pages of an incremental round, the stored ver stays
    // old and the round repeats.
    func testKilledMidIncrementalRoundKeepsOldVer() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack("socialSync", socialPage(untilVer: 5, friends: [friend("bob", 5)]))
        await flush()
        c.receive(event("socialChanged", ["ver": 8]))
        h.clock.advance(200)
        await flush()
        c.ack("socialSync", socialPage(untilVer: 8, full: false, hasMore: true, cursor: "c1", friends: [friend("carol", 6)]))
        await flush()

        let h2 = setup(clock: h.clock, directory: dir)
        h2.im.connect(token: "t")
        let c2 = await h2.login("alice")
        XCTAssertEqual(c2.last("socialSync")?.data, ["sinceVer": 5, "limit": 500])
        XCTAssertEqual(Set(h2.im.friends().map(\.userId)), ["bob", "carol"])  // Page rows are applied; re-merge is harmless.
    }

    // A full round replaces everything in one transaction when it ends: killed halfway, nothing has changed.
    func testKilledMidFullRoundKeepsOldData() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack("socialSync", socialPage(untilVer: 5, friends: [friend("old", 5)]))
        await flush()
        h.im.close()

        let h2 = setup(directory: dir)
        h2.im.connect(token: "t")
        let c2 = await h2.login("alice")
        c2.ack("socialSync", socialPage(untilVer: 9, full: true, hasMore: true, cursor: "c", friends: [friend("new1", 9)]))
        await flush()

        let h3 = setup(directory: dir)
        h3.im.restoreCache(userId: "alice")
        XCTAssertEqual(h3.im.friends().map(\.userId), ["old"])
    }

    func testFullRoundReplacesStoredRows() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack("socialSync", socialPage(untilVer: 5, friends: [friend("old", 5, nickname: "gone-nick")]))
        await flush()
        c.drop(1006)
        let c2 = await h.reconnect()
        c2.ack("convs", ["convs": [], "truncated": false])
        await flush()
        XCTAssertEqual(c2.last("socialSync")?.data, ["sinceVer": 5, "limit": 500])
        c2.ack("socialSync", socialPage(untilVer: 9, full: true, friends: [friend("new", 9)]))
        await flush()
        XCTAssertFalse(try diskContains("gone-nick"))
        h.im.close()
        let h2 = setup(directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.friends().map(\.userId), ["new"])
    }

    func testOwnChangeAndSeenPersistWithVer() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack("socialSync", socialPage(untilVer: 5, requests: [req("carol", "in", 5)]))
        await flush()
        async let p: Void = h.im.setFriendRemark("carol", "卡姐")
        await flush()
        c.ack("friendRemark", ["ver": 6, "changed": true, "items": ["friends": [friend("carol", 6, remark: "卡姐")], "requests": [], "blocks": []]])
        try await p
        h.im.markFriendRequestsSeen()
        h.im.close()
        let h2 = setup(clock: h.clock, directory: dir)
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(h2.im.friends()[0].displayName, "卡姐")
        XCTAssertEqual(h2.im.friendRequests().unseen, 0)
        h2.im.connect(token: "t")
        let c2 = await h2.login("alice")
        XCTAssertEqual(c2.last("socialSync")?.data, ["sinceVer": 6, "limit": 500])
    }

    // PRD-social 10.2: requests past 30 days are dropped locally, once server time is known.
    func testOldRequestsDroppedFromDisk() async throws {
        let (h, c) = await onlineClient(convs: [])
        c.ack("socialSync", socialPage(untilVer: 5, requests: [req("ancient", "in", 5, message: "old-request-text", updatedAt: h.clock.now())]))
        await flush()
        h.im.close()
        XCTAssertTrue(try diskContains("old-request-text"))
        let h2 = setup(clock: h.clock, directory: dir)
        h2.im.connect(token: "t")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now() + requestRetentionMs + 1)])
        await flush()
        XCTAssertFalse(try diskContains("old-request-text"))
        XCTAssertEqual(h2.im.friendRequests().items.count, 0)
    }
}
