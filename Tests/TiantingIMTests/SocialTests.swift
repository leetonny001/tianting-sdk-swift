import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let NOW: Int64 = 1_700_000_000_000
private let G = "group:g1"

func friend(_ userId: String, _ ver: Int64, remark: String = "", deleted: Bool = false, nickname: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = [
        "userId": .string(userId), "remark": .string(remark), "source": "other", "createdAt": .int(NOW), "ver": .int(ver),
        "profile": ["nickname": .string(nickname ?? userId.uppercased()), "avatar": "", "official": false],
    ]
    if deleted { o["deleted"] = true }
    return .object(o)
}

func req(
    _ userId: String, _ direction: String, _ ver: Int64, status: String = "pending", message: String = "",
    updatedAt: Int64 = NOW, expireAt: Int64 = NOW + 7 * 86_400_000
) -> JSONValue {
    [
        "userId": .string(userId), "direction": .string(direction), "status": .string(status), "message": .string(message),
        "source": "other", "applyCount": 1, "createdAt": .int(NOW), "updatedAt": .int(updatedAt), "expireAt": .int(expireAt),
        "ver": .int(ver),
        "profile": direction == "in" ? ["nickname": .string(userId), "avatar": "", "official": false] : nil,
    ]
}

func socialPage(
    untilVer: Int64 = 0, latestVer: Int64? = nil, full: Bool = true, hasMore: Bool = false, cursor: String = "",
    friends: [JSONValue] = [], requests: [JSONValue] = [], blocks: [JSONValue] = [], requestSeenVer: Int64 = 0,
    mode: String = "open", strangerMsgLimit: Int64 = 0, official: Bool = false, restart: Bool = false
) -> JSONValue {
    var o: [String: JSONValue] = [
        "full": .bool(full), "untilVer": .int(untilVer), "latestVer": .int(latestVer ?? untilVer), "hasMore": .bool(hasMore),
        "cursor": .string(cursor), "friends": .array(friends), "requests": .array(requests), "blocks": .array(blocks),
        "requestSeenVer": .int(requestSeenVer), "settings": ["searchable": true], "mode": .string(mode),
        "strangerMsgLimit": .int(strangerMsgLimit), "official": .bool(official),
    ]
    if restart { o["restart"] = true }
    return .object(o)
}

/// Port of sdk-ts test/social.test.ts (FE-141...FE-143).
@MainActor
final class SocialTests: IMTestCase {
    private func loggedIn() async -> (Harness, FakeConnection) {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv("c2c:alice:bob", maxSeq: 1)])
        return (h, c)
    }

    // FE-141
    func testRoundAfterConvsPagedOneCallback() async {
        let (h, c) = await loggedIn()
        let cmds = c.frames().map(\.cmd)
        XCTAssertGreaterThan(cmds.firstIndex(of: "socialSync")!, cmds.firstIndex(of: "convs")!)
        XCTAssertEqual(c.last("socialSync")?.data, ["sinceVer": 0, "limit": 500])
        XCTAssertFalse(h.im.socialLoaded())
        var seen: [Int] = []
        h.im.on {
            if case .friends(let l) = $0 { seen.append(l.count) }
        }
        c.ack("socialSync", socialPage(untilVer: 3, hasMore: true, cursor: "c1", friends: [friend("bob", 2)]))
        await flush()
        XCTAssertEqual(c.last("socialSync")?.data, ["cursor": "c1", "limit": 500])
        c.ack("socialSync", socialPage(untilVer: 3, friends: [friend("carol", 3)], mode: "friends", strangerMsgLimit: 3))
        await flush()
        XCTAssertEqual(seen, [2])
        XCTAssertEqual(h.im.friends().map(\.displayName), ["BOB", "CAROL"])
        XCTAssertEqual(h.im.socialSettings(), SocialSettings(searchable: true, mode: .friends, strangerMsgLimit: 3))
        XCTAssertTrue(h.im.socialLoaded())
    }

    // F-SOC-06 rule 3: restart abandons the round and keeps the sinceVer.
    func testRestartKeepsSinceVer() async {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 5))
        await flush()
        c.receive(event("socialChanged", ["ver": 9]))
        h.clock.advance(200)
        await flush()
        c.ack("socialSync", socialPage(untilVer: 9, full: false, hasMore: true, cursor: "c1", friends: [friend("x", 8)]))
        await flush()
        c.ack("socialSync", socialPage(restart: true))
        await flush()
        XCTAssertEqual(c.last("socialSync")?.data, ["sinceVer": 5, "limit": 500])
    }

    func testSocialChangedDebounce() async {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 5))
        await flush()
        let before = c.frames("socialSync").count
        c.receive(event("socialChanged", ["ver": 5]))
        h.clock.advance(300)
        await flush()
        XCTAssertEqual(c.frames("socialSync").count, before)
        c.receive(event("socialChanged", ["ver": 6]))
        c.receive(event("socialChanged", ["ver": 7]))
        h.clock.advance(199)
        await flush()
        XCTAssertEqual(c.frames("socialSync").count, before)
        h.clock.advance(1)
        await flush()
        XCTAssertEqual(c.frames("socialSync").count, before + 1)
        XCTAssertEqual(c.last("socialSync")?.data, ["sinceVer": 5, "limit": 500])
    }

    // AC-SOC-01-6, F-SOC-01 rule 4
    func testSettingsChangedEvent() async {
        let (h, c) = await loggedIn()
        var got: [SocialSettings] = []
        h.im.on {
            if case .socialSettings(let s) = $0 { got.append(s) }
        }
        c.receive(event("socialSettingsChanged", ["mode": "open", "strangerMsgLimit": 3]))
        XCTAssertEqual(got.last, SocialSettings(searchable: true, mode: .open, strangerMsgLimit: 3))
        c.receive(event("someFutureEvent", ["x": 1]))
    }

    // F-SOC-06 rule 7
    func testOwnChangeAckContinuousAndGap() async throws {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 5))
        await flush()
        async let p: Void = h.im.respondFriend("bob", .accept, remark: "同学")
        await flush()
        XCTAssertEqual(c.last("friendRespond")?.data, ["from": "bob", "action": "accept", "remark": "同学"])
        c.ack("friendRespond", ["ver": 6, "changed": true, "items": ["friends": [friend("bob", 6, remark: "同学")], "requests": [], "blocks": []]])
        try await p
        XCTAssertEqual(h.im.friends()[0].userId, "bob")
        XCTAssertEqual(h.im.friends()[0].displayName, "同学")
        let n = c.frames("socialSync").count
        async let q: Void = h.im.deleteFriend("bob")
        await flush()
        c.ack("friendDelete", ["ver": 9, "changed": true, "items": ["friends": [friend("bob", 9, deleted: true)], "requests": [], "blocks": []]])
        try await q
        await flush()
        XCTAssertEqual(h.im.friends(), [])
        XCTAssertEqual(c.frames("socialSync").count, n + 1)
        XCTAssertEqual(c.last("socialSync")?.data, ["sinceVer": 6, "limit": 500])
    }

    func testCommandErrorsCarryCode() async {
        let (h, c) = await loggedIn()
        async let p: Void = h.im.respondFriend("carol", .accept)
        await flush()
        c.ackError("friendRespond", ErrorCode.friendRequestNotFound)
        do {
            try await p
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? IMError)?.code, 4045)
        }
    }

    func testRateLimitedRoundRetries() async {
        let (h, c) = await loggedIn()
        c.ackError("socialSync", ErrorCode.rateLimited)
        await flush()
        XCTAssertFalse(h.im.socialLoaded())
        let n = c.frames("socialSync").count
        h.clock.advance(5_999)
        await flush()
        XCTAssertEqual(c.frames("socialSync").count, n)
        h.clock.advance(1)
        await flush()
        XCTAssertEqual(c.frames("socialSync").count, n + 1)
        c.ack("socialSync", socialPage(untilVer: 1))
        await flush()
        XCTAssertTrue(h.im.socialLoaded())
    }

    func testKickClearsSocial() async {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 1, friends: [friend("bob", 1)]))
        await flush()
        XCTAssertEqual(h.im.friends().count, 1)
        c.receive(event("kicked", ["reason": "banned"]))
        c.drop(4012, "revoked")
        await flush()
        XCTAssertEqual(h.im.friends(), [])
        XCTAssertFalse(h.im.socialLoaded())
    }

    // AC-SOC-04-1, AC-SOC-04-5
    func testRedDotOrderAndExpiry() async {
        let (h, c) = await loggedIn()
        c.ack(
            "socialSync",
            socialPage(
                untilVer: 9, requests: [
                    req("old", "in", 2),
                    req("expired", "in", 3, expireAt: NOW - 1),
                    req("carol", "in", 8, updatedAt: NOW - 10),
                    req("dave", "in", 9, updatedAt: NOW - 5),
                    req("rejected", "in", 7, status: "rejected"),
                    req("mine", "out", 6),
                ], requestSeenVer: 2))
        await flush()
        // The harness clock starts exactly at NOW.
        let r = h.im.friendRequests()
        XCTAssertEqual(r.unseen, 2)
        XCTAssertEqual(r.items.first { $0.userId == "expired" }?.status, .expired)
        let order = r.items.map(\.userId)
        XCTAssertLessThan(order.firstIndex(of: "dave")!, order.firstIndex(of: "carol")!)
        h.im.markFriendRequestsSeen()
        XCTAssertEqual(h.im.friendRequests().unseen, 0)
        XCTAssertEqual(c.last("friendRequestsSeen")?.data, ["ver": 9])
    }

    // AC-SOC-04-5: server time, not the local clock.
    func testExpiryUsesServerTime() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = h.transport.current
        c.open()
        c.ack("auth", ["userId": "alice", "serverTime": .int(NOW + 8 * 86_400_000)])
        await flush()
        c.ack("convs", ["convs": [], "truncated": false])
        await flush()
        c.ack("socialSync", socialPage(untilVer: 1, requests: [req("bob", "in", 1)]))
        await flush()
        XCTAssertEqual(h.im.friendRequests().items[0].status, .expired)
        XCTAssertEqual(h.im.friendRequests().unseen, 0)
    }

    func testRelationOfPriority() async {
        let (h, c) = await loggedIn()
        c.ack(
            "socialSync",
            socialPage(
                untilVer: 5,
                friends: [friend("bob", 1), friend("dave", 1)],
                requests: [req("carol", "in", 3), req("erin", "out", 4)],
                blocks: [["userId": "dave", "createdAt": .int(NOW), "ver": 2, "profile": nil]]))
        await flush()
        XCTAssertEqual(
            ["alice", "dave", "bob", "carol", "erin", "frank"].map { h.im.relationOf($0) },
            [.`self`, .blocked, .friend, .pendingIn, .pendingOut, .none])
        XCTAssertEqual(h.im.friends().first { $0.userId == "dave" }?.blocked, true)
    }

    // F-SOC-06 rule 9, AC-SOC-09-1, AC-SOC-13-7 (official flag from search)
    func testOutgoingRequestUsesSearchProfile() async throws {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 1))
        await flush()
        async let s = h.im.searchUser("erin")
        await flush()
        c.ack("userSearch", ["user": ["userId": "erin", "nickname": "艾琳", "avatar": "", "official": true, "relation": "none"]])
        let found = try await s
        XCTAssertEqual(found?.nickname, "艾琳")
        XCTAssertEqual(found?.official, true)
        XCTAssertEqual(found?.relation, Relation.none)
        async let a = h.im.applyFriend("erin", options: ApplyFriendOptions(message: "你好", source: .search))
        await flush()
        XCTAssertEqual(c.last("friendApply")?.data, ["to": "erin", "message": "你好", "source": "search"])
        c.ack("friendApply", ["status": "pending", "ver": 2, "changed": true, "items": ["friends": [], "requests": [req("erin", "out", 2)], "blocks": []]])
        let status = try await a
        XCTAssertEqual(status, "pending")
        let row = h.im.friendRequests().items[0]
        XCTAssertEqual(row.userId, "erin")
        XCTAssertNil(row.profile)
        XCTAssertEqual(row.displayName, "艾琳")
    }

    func testSearchMissReturnsNil() async throws {
        let (h, c) = await loggedIn()
        async let s = h.im.searchUser("nobody")
        await flush()
        c.ack("userSearch", ["user": nil])
        let found = try await s
        XCTAssertNil(found)
    }

    // F-SOC-10: merge, batches of 100, cache hits.
    func testGetUsersMergesAndBatches() async {
        let (h, c) = await loggedIn()
        let ids = (0..<150).map { "u\($0)" }
        async let a = h.im.getUsers(Array(ids[0..<120]))
        async let b = h.im.getUsers(Array(ids[100...]))
        await flush()
        XCTAssertEqual(c.frames("users").map { $0.data?["userIds"]?.arrayValue?.count }, [100])
        let first = c.last("users")!.data!["userIds"]!.arrayValue!.map { $0.stringValue! }
        c.ack("users", ["users": .array(first.enumerated().filter { $0.offset % 2 == 0 }.map {
            ["userId": .string($0.element), "nickname": .string($0.element), "avatar": "", "official": false]
        })])
        await flush()
        XCTAssertEqual(c.last("users")?.data?["userIds"]?.arrayValue?.count, 50)
        c.ack("users", ["users": []])
        let (ra, rb) = await (a, b)
        let visible = Set(first.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        XCTAssertEqual(Set(ra.map(\.userId)), visible.intersection(ids[0..<120]))
        XCTAssertEqual(Set(rb.map(\.userId)), visible.intersection(ids[100...]))
        let sent = c.frames("users").count
        let cached = await h.im.getUsers([visible.first!])
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(c.frames("users").count, sent)
    }

    // One call whose ids span two batches gets all of them, not only the first batch's.
    func testGetUsersAcrossBatchesWaitsForAll() async {
        let (h, c) = await loggedIn()
        let ids = (0..<130).map { "u\($0)" }
        async let a = h.im.getUsers(ids)
        await flush()
        let profile: (JSONValue) -> JSONValue = { ["userId": $0, "nickname": $0, "avatar": "", "official": false] }
        c.ack("users", ["users": .array(c.last("users")!.data!["userIds"]!.arrayValue!.map(profile))])
        await flush()
        c.ack("users", ["users": .array(c.last("users")!.data!["userIds"]!.arrayValue!.map(profile))])
        let got = await a
        XCTAssertEqual(got.count, 130)
    }

    func testMissingUsersNotRequeriedUntilSyncGivesProfile() async {
        let (h, c) = await loggedIn()
        async let a = h.im.getUsers(["ghost"])
        await flush()
        c.ack("users", ["users": []])
        let none = await a
        XCTAssertEqual(none, [])
        let sent = c.frames("users").count
        let again = await h.im.getUsers(["ghost"])
        XCTAssertEqual(again, [])
        XCTAssertEqual(c.frames("users").count, sent)
        c.ack("socialSync", socialPage(untilVer: 1, friends: [friend("ghost", 1)]))
        await flush()
        let found = await h.im.getUsers(["ghost"])
        XCTAssertEqual(found.first?.nickname, "GHOST")
    }

    // AC-SOC-10-8
    func testProfileCacheTTL() {
        var now: Int64 = 0
        let cache = ProfileCache(now: { now })
        cache.put(UserProfile(userId: "bob", nickname: "B", avatar: "", official: false))
        now = 10 * 60 * 1000 - 1
        XCTAssertEqual(cache.fresh("bob")?.nickname, "B")
        now += 1
        XCTAssertNil(cache.fresh("bob"))
        XCTAssertEqual(cache.last("bob")?.nickname, "B")
        XCTAssertTrue(cache.needsFetch("bob"))
    }

    // AC-SOC-10-8 through the client: past 10 minutes a read refetches and shows the new nickname.
    func testGetUsersRefetchesAfterTTL() async {
        let (h, c) = await loggedIn()
        async let a = h.im.getUsers(["bob"])
        await flush()
        c.ack("users", ["users": [["userId": "bob", "nickname": "旧", "avatar": "", "official": false]]])
        _ = await a
        h.clock.advance(599_999)  // The connection drops without pongs, so it is re-established below.
        let sentBefore = h.transport.connections.count
        XCTAssertGreaterThanOrEqual(sentBefore, 1)
        XCTAssertEqual(h.im.profileOf("bob")?.nickname, "旧")
        h.clock.advance(1)
        h.im.networkOnline()
        let c2 = h.transport.current
        if h.im.state != .connected {
            c2.open()
            c2.ack("auth", ["userId": "alice", "serverTime": .int(h.clock.now())])
            await flush()
        }
        async let b = h.im.getUsers(["bob"])
        await flush()
        c2.ack("users", ["users": [["userId": "bob", "nickname": "新", "avatar": "", "official": false]]])
        let fresh = await b
        XCTAssertEqual(fresh.first?.nickname, "新")
    }

    // AC-SOC-10-9, AC-SOC-10-7 (the nickname source)
    func testSyncProfileOverwritesCacheAtOnce() async {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 1, friends: [friend("bob", 1, nickname: "新的")]))
        await flush()
        XCTAssertEqual(h.im.profileOf("bob")?.nickname, "新的")
        XCTAssertEqual(h.im.displayName("bob"), "新的")
    }

    // AC-SOC-11-3, AC-SOC-11-4
    func testContactsSummary() async throws {
        let h = setup()
        h.im.connect(token: "t")
        // alice has a c2c with the stranger carol.
        let c = await h.login("alice", convs: [conv("c2c:alice:carol", maxSeq: 1, unread: 1), conv("group:g1"), conv("group:g2")])
        c.ack(
            "socialSync",
            socialPage(untilVer: 4, friends: [friend("b1", 1), friend("b2", 2), friend("b3", 3)], requests: [req("x", "in", 4)]))
        await flush()
        XCTAssertEqual(h.im.friends().count, 3)
        XCTAssertFalse(h.im.friends().map(\.userId).contains("carol"))
        XCTAssertEqual(h.im.friendRequests().unseen, 1)
        async let g = h.im.loadMyGroups()
        await flush()
        c.ack("myGroups", ["groups": [["groupId": "g1", "name": "A", "memberCount": 3, "joinedAt": 1], ["groupId": "g2", "name": "B", "memberCount": 5, "joinedAt": 2]], "nextCursor": ""])
        let groups = try await g
        XCTAssertEqual(groups.count, 2)
    }

    func testLoadMyGroupsPages() async throws {
        let (h, c) = await loggedIn()
        async let p = h.im.loadMyGroups()
        await flush()
        XCTAssertEqual(c.last("myGroups")?.data, [:])
        c.ack("myGroups", ["groups": [["groupId": "g1", "name": "A", "memberCount": 3, "joinedAt": 1]], "nextCursor": "g1"])
        await flush()
        XCTAssertEqual(c.last("myGroups")?.data, ["cursor": "g1"])
        c.ack("myGroups", ["groups": [["groupId": "g2", "name": "B", "memberCount": 5, "joinedAt": 2]], "nextCursor": ""])
        let groups = try await p
        XCTAssertEqual(groups.map(\.groupId), ["g1", "g2"])
    }

    // AC-SOC-09-7 at the SDK level.
    func testSetSearchable() async throws {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 1))
        await flush()
        async let p: Void = h.im.setSearchable(false)
        await flush()
        XCTAssertEqual(c.last("setPrivacy")?.data, ["searchable": false])
        c.ack("setPrivacy", ["ver": 2, "changed": true])
        try await p
        XCTAssertFalse(h.im.socialSettings().searchable)
    }

    // PRD-social: 2000 friends over 4 pages, one replace and one callback (AC-SOC-06-14's SDK part).
    func testFullRoundOfTwoThousandFriendsEmitsOnce() async {
        let (h, c) = await loggedIn()
        var calls: [Int] = []
        h.im.on {
            if case .friends(let l) = $0 { calls.append(l.count) }
        }
        for p in 0..<4 {
            c.ack(
                "socialSync",
                socialPage(
                    untilVer: 1, hasMore: p < 3, cursor: "c\(p)",
                    friends: (0..<500).map { friend("f\($0)-\(p)", 1) }))
            await flush()
        }
        XCTAssertEqual(calls, [2000])
    }

    // MARK: Groups

    func testCreateGroupRetriesWithSameRequestId() async throws {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage())
        await flush()
        async let p = h.im.createGroup(members: ["bob", "carol"])
        await flush()
        let first = c.last("groupCreate")!.data!["clientReqId"]
        h.clock.advance(10_001)
        await flush()
        XCTAssertEqual(c.frames("groupCreate").count, 2)
        XCTAssertEqual(c.frames("groupCreate")[1].data?["clientReqId"], first)
        c.ack("groupCreate", ["groupId": "g1", "conv": conv(G, name: "x", memberCount: 3, myRole: "owner")])
        let r = try await p
        XCTAssertEqual(r.conv.myRole, .owner)
        XCTAssertEqual(r.conv.memberCount, 3)
        XCTAssertTrue(h.im.conversations().map(\.convId).contains(G))
    }

    func testGroupErrorCarriesUserId() async {
        let (h, c) = await loggedIn()
        async let a = h.im.createGroup(members: ["bob", "dave"])
        await flush()
        c.receive(["id": .string(c.last("groupCreate")!.id!), "cmd": "ack", "error": ["code": 4035, "msg": "x", "userId": "dave"]])
        do {
            _ = try await a
            XCTFail()
        } catch {
            XCTAssertEqual((error as? IMError)?.code, 4035)
            XCTAssertEqual((error as? IMError)?.userId, "dave")
        }
        async let b = h.im.createGroup(members: ["bob", "eve"])
        await flush()
        c.receive(["id": .string(c.last("groupCreate")!.id!), "cmd": "ack", "error": ["code": 4035, "msg": "x", "details": ["userId": "eve"]]])
        do {
            _ = try await b
            XCTFail()
        } catch {
            XCTAssertEqual((error as? IMError)?.userId, "eve")
        }
    }

    // AC-SOC-29-5, PRD-social 10.2: stored, counted unread, empty `from`, local summary, no convs refetch.
    func testTipMessage() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G, name: "g")])
        let n = c.frames("convs").count
        c.receive(msgFrame([
            "msgId": "m1", "clientMsgId": "tip-1", "convId": .string(G), "seq": 1, "from": "", "type": "tip",
            "body": ["tip": ["kind": "ownerChanged", "actor": "", "targets": [], "text": ""]], "ts": 5,
        ]))
        XCTAssertEqual(h.im.conversations()[0].unread, 1)
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.type, "tip")
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.text, "群主已退出群聊")
        h.clock.advance(200)
        await flush()
        XCTAssertEqual(c.frames("convs").count, n)
        // The first conversations event a listener sees already has the summary.
        let last = h.events.compactMap { e -> LastMsg?? in
            if case .conversations(let l) = e { return l.first?.lastMsg }
            return nil
        }.last
        XCTAssertEqual(last??.text, "群主已退出群聊")
    }

    func testUnknownTipKind() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G)])
        c.receive(msgFrame([
            "msgId": "m1", "clientMsgId": "tip-1", "convId": .string(G), "seq": 1, "from": "", "type": "tip",
            "body": ["tip": ["kind": "future", "actor": "", "targets": [], "text": ""]], "ts": 5,
        ]))
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.text, "[群通知]")
        XCTAssertEqual(tipText(h.im.messages(G)[0].body.tip!, me: "alice") { $0 }, "[群通知]")
    }

    // AC-SOC-20-10 (client part): several groupChanged merge into at most two groupInfo requests.
    func testGroupChangedMerges() async {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G, name: "g", memberCount: 3, myRole: "member")])
        let convs = c.frames("convs").count
        for _ in 0..<3 { c.receive(event("groupChanged", ["groupId": "g1"])) }
        await flush()
        XCTAssertEqual(c.frames("groupInfo").count, 1)
        let info: [String: JSONValue] = [
            "groupId": "g1", "name": "新名", "memberCount": 5, "myRole": "admin", "notice": "", "noticeBy": "", "noticeAt": 0,
            "owner": "bob", "managed": false, "maxMembers": 500, "historyVisible": false, "createdAt": 1,
        ]
        c.ack("groupInfo", .object(info))
        await flush()
        XCTAssertEqual(c.frames("groupInfo").count, 2)
        var next = info
        next["memberCount"] = 6
        c.ack("groupInfo", .object(next))
        await flush()
        let v = h.im.conversations()[0]
        XCTAssertEqual(v.name, "新名")
        XCTAssertEqual(v.memberCount, 6)
        XCTAssertEqual(v.myRole, .admin)
        let seen = h.events.compactMap { e -> String? in
            if case .groupChanged(let id, _) = e { return id }
            return nil
        }
        XCTAssertEqual(seen, ["g1"])
        XCTAssertEqual(c.frames("convs").count, convs)
    }

    func testLeaveAndDissolveKeepSnapshot() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G, name: "g"), conv("group:g2", name: "h")])
        async let p: Void = h.im.leaveGroup("g1")
        await flush()
        c.ack("groupLeave", [:])
        try await p
        XCTAssertEqual(h.im.conversations().map(\.convId), ["group:g2"])
        XCTAssertEqual(h.im.conversationSnapshot(G)?.reason, "left")
        XCTAssertEqual(h.im.conversationSnapshot(G)?.name, "g")
        async let q: Void = h.im.dissolveGroup("g2")
        await flush()
        c.ack("groupDissolve", [:])
        try await q
        XCTAssertEqual(h.im.conversationSnapshot("group:g2")?.reason, "dissolved")
    }

    // Every group command's frame shape (each is also checked against frame.schema.json in tearDown).
    func testGroupCommandFrames() async throws {
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv(G)])
        async let a = h.im.inviteToGroup("g1", members: ["d"])
        await flush()
        XCTAssertEqual(c.last("groupInvite")?.data, ["groupId": "g1", "members": ["d"]])
        c.ack("groupInvite", ["added": ["d"], "failed": [["userId": "e", "code": 4035]]])
        let invited = try await a
        XCTAssertEqual(invited.added, ["d"])
        XCTAssertEqual(invited.failed[0].code, 4035)

        async let k = h.im.kickFromGroup("g1", members: ["d"])
        await flush()
        XCTAssertEqual(c.last("groupKick")?.data, ["groupId": "g1", "members": ["d"]])
        c.ack("groupKick", ["removed": ["d"]])
        let removed = try await k
        XCTAssertEqual(removed, ["d"])

        async let s: Void = h.im.setGroupAdmin("g1", userId: "b", admin: true)
        await flush()
        XCTAssertEqual(c.last("groupSetAdmin")?.data, ["groupId": "g1", "userId": "b", "admin": true])
        c.ack("groupSetAdmin", [:])
        try await s

        async let u: Void = h.im.updateGroup("g1", name: "n", notice: "m")
        await flush()
        XCTAssertEqual(c.last("groupUpdate")?.data, ["groupId": "g1", "name": "n", "notice": "m"])
        c.ack("groupUpdate", [:])
        try await u

        async let t: Void = h.im.transferGroupOwner("g1", to: "b")
        await flush()
        XCTAssertEqual(c.last("groupTransfer")?.data, ["groupId": "g1", "to": "b"])
        c.ack("groupTransfer", [:])
        try await t
        await flush()
        XCTAssertEqual(c.frames("groupInfo").count, 1)  // A transfer refreshes group info.
    }

    func testMembersPageCachesProfiles() async throws {
        let (h, c) = await loggedIn()
        async let p = h.im.loadGroupMembers("g1")
        await flush()
        XCTAssertEqual(c.last("groupMembers")?.data, ["groupId": "g1"])
        c.ack("groupMembers", ["members": [["userId": "bob", "role": "owner", "joinedAt": 1, "nickname": "阿博", "avatar": "", "official": false]], "nextCursor": "x"])
        let page = try await p
        XCTAssertEqual(page.nextCursor, "x")
        XCTAssertEqual(h.im.profileOf("bob")?.nickname, "阿博")
    }

    func testRemarkBlockAndUnblockFrames() async throws {
        let (h, c) = await loggedIn()
        c.ack("socialSync", socialPage(untilVer: 1, friends: [friend("bob", 1)]))
        await flush()
        async let r: Void = h.im.setFriendRemark("bob", "老板")
        await flush()
        XCTAssertEqual(c.last("friendRemark")?.data, ["userId": "bob", "remark": "老板"])
        c.ack("friendRemark", ["ver": 2, "changed": true, "items": ["friends": [friend("bob", 2, remark: "老板")], "requests": [], "blocks": []]])
        try await r
        XCTAssertEqual(h.im.displayName("bob"), "老板")
        async let b: Void = h.im.block("bob")
        await flush()
        XCTAssertEqual(c.last("block")?.data, ["userId": "bob"])
        c.ack("block", ["ver": 3, "changed": true, "items": ["friends": [], "requests": [], "blocks": [["userId": "bob", "createdAt": 1, "ver": 3, "profile": nil]]]])
        try await b
        XCTAssertEqual(h.im.blocks().map(\.userId), ["bob"])
        XCTAssertEqual(h.im.relationOf("bob"), .blocked)
        async let ub: Void = h.im.unblock("bob")
        await flush()
        c.ack("unblock", ["ver": 4, "changed": true, "items": ["friends": [], "requests": [], "blocks": [["userId": "bob", "createdAt": 1, "ver": 4, "deleted": true, "profile": nil]]]])
        try await ub
        XCTAssertEqual(h.im.blocks().map(\.userId), [])
    }

    // PRD-core: unknown enum values in social rows do not break a sync round.
    func testUnknownSocialEnumsTolerated() async {
        let (h, c) = await loggedIn()
        var row = friend("bob", 1)
        if case .object(var o) = row {
            o["source"] = "future-source"
            o["futureField"] = 1
            row = .object(o)
        }
        c.ack("socialSync", socialPage(untilVer: 1, friends: [row], requests: [req("carol", "sideways", 1), req("dave", "in", 1, status: "future-status")], mode: "future-mode"))
        await flush()
        XCTAssertTrue(h.im.socialLoaded())
        XCTAssertEqual(h.im.friends().count, 1)
        XCTAssertEqual(h.im.socialSettings().mode.rawValue, "future-mode")
        XCTAssertEqual(h.im.friendRequests().unseen, 0)
    }
}
