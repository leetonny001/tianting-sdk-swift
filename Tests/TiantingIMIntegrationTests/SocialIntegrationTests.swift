#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// Social and groups against a real server (FE-141...FE-143; each test names the ACs it covers).
final class SocialIntegrationTests: IntegrationCase {
    // AC-SOC-02-1, AC-SOC-03-1, AC-SOC-04-1, AC-SOC-04-2, AC-SOC-06-2 (online), AC-SOC-09-1
    func testApplyRedDotAcceptAcrossDevices() async throws {
        let (aid, bid, cid, did) = (uid("a"), uid("b"), uid("c"), uid("d"))
        try await importUsers([aid, bid, cid, did], nicknames: [aid: "小A", bid: "小B"])
        let a = try await login(aid)
        let b = try await login(bid)
        let bPc = try await login(bid)
        try await untilTrue("first round") { a.socialLoaded() && b.socialLoaded() && bPc.socialLoaded() }

        let found = try await a.searchUser(bid)
        XCTAssertEqual(found?.nickname, "小B")
        XCTAssertEqual(found?.relation, Relation.none)
        let status = try await a.applyFriend(bid, options: ApplyFriendOptions(message: "我是小A", source: .search))
        XCTAssertEqual(status, "pending")
        XCTAssertEqual(a.relationOf(bid), .pendingOut)
        let again = try await a.searchUser(bid)
        XCTAssertEqual(again?.relation, .pendingOut)
        let out = a.friendRequests().items[0]
        XCTAssertEqual(out.userId, bid)
        XCTAssertEqual(out.direction, .outgoing)
        XCTAssertEqual(out.displayName, "小B")
        XCTAssertNil(out.profile)

        try await untilTrue("red dot on both devices", timeout: 2) {
            b.friendRequests().unseen == 1 && bPc.friendRequests().unseen == 1
        }
        let row = b.friendRequests().items[0]
        XCTAssertEqual(row.userId, aid)
        XCTAssertEqual(row.direction, .incoming)
        XCTAssertEqual(row.message, "我是小A")
        XCTAssertEqual(row.item.source, .search)
        XCTAssertEqual(row.displayName, "小A")

        // AC-SOC-04-1: two more applicants, the later one first.
        let c = try await login(cid)
        try await c.applyFriend(bid)
        try await sleepMs(20)
        let d = try await login(did)
        try await d.applyFriend(bid)
        try await untilTrue("three unseen") { b.friendRequests().unseen == 3 }
        let order = b.friendRequests().items.map(\.userId)
        XCTAssertEqual(order.firstIndex(of: did), 0)
        XCTAssertLessThan(order.firstIndex(of: cid)!, order.firstIndex(of: aid)!)

        // AC-SOC-04-2
        b.markFriendRequestsSeen()
        try await untilTrue("red dot cleared on the other device", timeout: 2) { bPc.friendRequests().unseen == 0 }

        try await b.respondFriend(aid, .accept, remark: "同学A")
        XCTAssertEqual(b.friends().map(\.displayName), ["同学A"])
        try await untilTrue("friends on both sides", timeout: 2) { a.friends().count == 1 && bPc.friends().count == 1 }
        XCTAssertEqual(a.relationOf(bid), .friend)
        XCTAssertEqual(bPc.friends()[0].displayName, "同学A")
    }

    // AC-SOC-05-1: alice deletes bob; only alice's list changes and bob sees nothing.
    // AC-SOC-05-4: a remark reaches the other device and never the other person.
    func testDeleteFriendOneSidedAndRemarkPrivate() async throws {
        let (aid, bid) = (uid("a"), uid("b"))
        try await importUsers([aid, bid], nicknames: [aid: "A", bid: "B"])
        let a = try await login(aid)
        let aPc = try await login(aid)
        let b = try await login(bid)
        try await untilTrue("loaded") { a.socialLoaded() && aPc.socialLoaded() && b.socialLoaded() }
        try await befriend(a, aid, b, bid)
        try await untilTrue("aPc friend") { aPc.relationOf(bid) == .friend }

        try await a.setFriendRemark(bid, "老板")
        try await untilTrue("remark on the other device", timeout: 2) {
            aPc.friends().first?.displayName == "老板"
        }
        // Everything bob can get about alice carries no remark.
        let seen = await b.getUsers([aid])
        XCTAssertFalse(String(describing: seen).contains("老板"))
        XCTAssertFalse(String(describing: b.friends()).contains("老板"))
        XCTAssertFalse(String(describing: b.conversations()).contains("老板"))

        let bVerBefore = b.social.ver
        var bFriendEvents = 0
        b.on {
            if case .friends = $0 { bFriendEvents += 1 }
        }
        try await a.deleteFriend(bid)
        XCTAssertEqual(a.friends(), [])
        try await sleepMs(1200)
        XCTAssertEqual(b.friends().map(\.userId), [aid])
        XCTAssertEqual(b.social.ver, bVerBefore)
        XCTAssertEqual(bFriendEvents, 0)
    }

    // AC-SOC-06-2 (offline part): a change made while one device is away is there after it reconnects.
    func testChangeWhileOtherDeviceDisconnected() async throws {
        let (aid, bid) = (uid("a"), uid("b"))
        try await importUsers([aid, bid])
        let a = try await login(aid)
        let b = try await login(bid)
        try await untilTrue("loaded") { a.socialLoaded() && b.socialLoaded() }
        try await b.applyFriend(aid)
        try await untilTrue("incoming") { a.friendRequests().items.count == 1 }
        // The "web" device of alice goes away; it comes back as a new connection after "pc" accepted.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(aid)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let web = client(directory: dir)
        _ = try await login(aid, web)
        try await untilTrue("web loaded") { web.socialLoaded() }
        web.close()
        try await a.respondFriend(bid, .accept)

        let web2 = client(directory: dir)
        web2.restoreCache(userId: aid)
        XCTAssertEqual(web2.friends(), [])
        let start = Date()
        _ = try await login(aid, web2)
        try await untilTrue("reconnected device catches up", timeout: 5) { web2.relationOf(bid) == .friend }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // AC-SOC-07-1, AC-SOC-07-5
    func testBlockRejectsAndSyncsAcrossDevices() async throws {
        let (aid, bid) = (uid("a"), uid("b"))
        try await importUsers([aid, bid])
        let a = try await login(aid)
        let aPc = try await login(aid)
        let b = try await login(bid)
        try await untilTrue("loaded") { a.socialLoaded() && aPc.socialLoaded() }
        try await a.block(bid)
        XCTAssertEqual(a.relationOf(bid), .blocked)
        try await untilTrue("block synced", timeout: 2) { aPc.blocks().first?.userId == bid }
        let cid = c2cConvId(aid, bid)
        _ = try sendOK(b, cid, "hi")
        let m = try await until("failed") { b.messages(cid).first { $0.status == .failed } }
        XCTAssertEqual(m.error, .code(4036))
        XCTAssertEqual(messageFor(cmd: "send", code: 4036), "消息已发出，但被对方拒收了")
        try await sleepMs(300)
        XCTAssertEqual(b.messages(cid).count, 1)
        XCTAssertEqual(a.messages(cid), [])
        try await a.unblock(bid)
        try await untilTrue("unblock synced", timeout: 2) { aPc.blocks().isEmpty }
        XCTAssertEqual(a.blocks().count, 0)
        _ = try sendOK(b, cid, "again")
        try await untilTrue("delivered") { a.messages(cid).contains { $0.body.text == "again" } }
    }

    // AC-SOC-09-7, AC-SOC-09-1 (unsearchable returns nil)
    func testSearchablePrivacyAcrossDevices() async throws {
        let (aid, bid) = (uid("a"), uid("b"))
        try await importUsers([aid, bid])
        let a = try await login(aid)
        let aPc = try await login(aid)
        let b = try await login(bid)
        try await untilTrue("loaded") { a.socialLoaded() && aPc.socialLoaded() }
        try await a.setSearchable(false)
        XCTAssertFalse(a.socialSettings().searchable)
        try await untilTrue("other device", timeout: 2) { !aPc.socialSettings().searchable }
        let found = try await b.searchUser(aid)
        XCTAssertNil(found)
    }

    // AC-SOC-08-8: friends-only mode returns 4035 and the copy; open mode's 4137 carries strangerMsgLimit.
    func testFriendsOnlyAndStrangerLimit() async throws {
        let friendsOnly = try await TestServer.start(env: ["IM_SOCIAL_DEFAULTS": #"{"mode":"friends"}"#])
        defer { friendsOnly.stop() }
        let (aid, bid) = (uid("a"), uid("b"))
        try await friendsOnly.admin("POST", "/admin/users/import", ["users": [["userId": aid], ["userId": bid]]])
        let a = client(url: friendsOnly.wsURL)
        _ = try await login(aid, a, server: friendsOnly)
        let cid = c2cConvId(aid, bid)
        _ = try sendOK(a, cid, "hi")
        let m = try await until("4035") { a.messages(cid).first { $0.status == .failed } }
        XCTAssertEqual(m.error, .code(4035))
        XCTAssertEqual(messageFor(cmd: "send", code: 4035), "对方开启了好友验证，你还不是他的好友")

        let limited = try await TestServer.start(env: ["IM_SOCIAL_DEFAULTS": #"{"mode":"open","strangerMsgLimit":2}"#])
        defer { limited.stop() }
        let (cId, dId) = (uid("c"), uid("d"))
        try await limited.admin("POST", "/admin/users/import", ["users": [["userId": cId], ["userId": dId]]])
        let c = client(url: limited.wsURL)
        _ = try await login(cId, c, server: limited)
        try await untilTrue("c loaded") { c.socialLoaded() }
        XCTAssertEqual(c.socialSettings().strangerMsgLimit, 2)
        let conv2 = c2cConvId(cId, dId)
        for t in ["1", "2", "3"] {
            _ = try sendOK(c, conv2, t)
            try await sleepMs(100)
        }
        let over = try await until("4137") { c.messages(conv2).first { $0.status == .failed } }
        XCTAssertEqual(over.error, .code(4137))
        XCTAssertEqual(
            messageFor(cmd: "send", code: 4137, strangerMsgLimit: c.socialSettings().strangerMsgLimit),
            "对方回复之前，最多只能发送 2 条消息")
    }

    // AC-SOC-10-7, AC-SOC-10-9: nicknames via users; a sync carrying a new profile shows at once.
    // AC-SOC-13-7: the official flag from search and users.
    func testProfilesAndOfficialFlag() async throws {
        let (aid, bid, kefu) = (uid("a"), uid("b"), uid("kefu"))
        let g = try await hostedGroup([aid, bid])  // Imports the members without nicknames first.
        try await importUsers([aid, bid, kefu], nicknames: [bid: "群友", kefu: "客服"])
        let a = try await login(aid)
        let got = await a.getUsers([bid, "nobody-\(aid)"])
        XCTAssertEqual(got.map(\.nickname), ["群友"])
        XCTAssertEqual(a.displayName(bid), "群友")
        _ = g

        try await srv.signed("PUT", "/admin/users/\(kefu)/official", ["official": true])
        let found = try await a.searchUser(kefu)
        XCTAssertEqual(found?.official, true)
        XCTAssertEqual(a.profileOf(kefu)?.official, true)

        // AC-SOC-10-9: bob becomes a friend under a new nickname; alice's next sync overwrites the cache at once.
        let b = try await login(bid)
        try await untilTrue("loaded") { a.socialLoaded() && b.socialLoaded() }
        try await importUsers([bid], nicknames: [bid: "新昵称"])
        try await a.applyFriend(bid)
        try await untilTrue("b sees it") { !b.friendRequests().items.isEmpty }
        try await b.respondFriend(aid, .accept)
        try await untilTrue("new nickname without expiry") { a.displayName(bid) == "新昵称" }
    }

    // AC-SOC-11-3, AC-SOC-11-4: contact data; a stranger's c2c stays out of friends.
    func testContactsOverview() async throws {
        let (aid, f1, f2, f3, stranger, applicant) = (uid("a"), uid("f"), uid("f"), uid("f"), uid("s"), uid("r"))
        try await importUsers([aid, f1, f2, f3, stranger, applicant])
        let a = try await login(aid)
        for f in [f1, f2, f3] {
            let other = try await login(f)
            try await befriend(a, aid, other, f)
        }
        _ = try await hostedGroup([aid, f1])
        _ = try await hostedGroup([aid, f2])
        let s = try await login(stranger)
        let cid = c2cConvId(aid, stranger)
        _ = try sendOK(s, cid, "hello stranger")
        try await untilTrue("c2c arrives") { conv(a, cid) != nil }
        let r = try await login(applicant)
        try await r.applyFriend(aid)
        try await untilTrue("request") { a.friendRequests().unseen == 1 }
        XCTAssertEqual(a.friends().count, 3)
        XCTAssertFalse(a.friends().map(\.userId).contains(stranger))
        let groups = try await a.loadMyGroups()
        XCTAssertEqual(groups.count, 2)
    }

    // AC-SOC-01-6: the settings event from the business side reaches all connections.
    func testSocialSettingsChangedReachesAllConnections() async throws {
        let a = uid("a")
        try await importUsers([a])
        let web = try await login(a)
        let pc = try await login(a)
        try await untilTrue("loaded") { web.socialLoaded() && pc.socialLoaded() }
        try await srv.signed("PATCH", "/admin/settings/social", ["strangerMsgLimit": 3])
        try await untilTrue("both get it", timeout: 2) {
            web.socialSettings().strangerMsgLimit == 3 && pc.socialSettings().strangerMsgLimit == 3
        }
        XCTAssertEqual(web.socialSettings().mode, .open)
        try await srv.signed("PATCH", "/admin/settings/social", ["strangerMsgLimit": 0])
    }
}

final class GroupIntegrationTests: IntegrationCase {
    // AC-SOC-21-1, 22-1, 23-1, 24-1, 25-1, 26-1, 27-1, 27-4 (notice), 28-5 (paging), 29-5, 20-10 (client part)
    func testGroupLifecycle() async throws {
        let (aid, bid, cid, did) = (uid("gm"), uid("gm"), uid("gm"), uid("gm"))
        try await importUsers([aid, bid, cid, did], nicknames: [aid: aid, bid: bid, cid: cid, did: did])
        let a = try await login(aid)
        let aOther = try await login(aid)
        let b = try await login(bid)
        let c = try await login(cid)
        let d = try await login(did)
        try await befriend(a, aid, b, bid)
        try await befriend(a, aid, c, cid)
        try await befriend(a, aid, d, did)

        // AC-SOC-21-1
        let created = try await a.createGroup(members: [bid, cid])
        let (groupId, convId) = (created.groupId, created.conv.convId)
        XCTAssertEqual(created.conv.type, .group)
        XCTAssertEqual(created.conv.myRole, .owner)
        XCTAssertEqual(created.conv.memberCount, 3)
        try await untilTrue("convAdded on all", timeout: 2) {
            conv(b, convId) != nil && conv(c, convId) != nil && conv(aOther, convId) != nil
        }
        XCTAssertEqual(conv(b, convId)?.myRole, .member)
        func tip(_ im: IMClient, _ kind: String) -> Message? {
            im.messages(convId).first { $0.type == .tip && $0.body.tip?.kind == kind }
        }
        b.setActiveConversation(convId)
        _ = try await b.loadHistory(convId)
        let createdTip = try await until("created tip") { tip(b, "created") }
        XCTAssertEqual(createdTip.seq, 1)
        XCTAssertEqual(createdTip.body.tip?.actor, aid)
        XCTAssertEqual(createdTip.body.tip?.targets, [bid, cid])
        XCTAssertEqual(tipText(createdTip.body.tip!, me: bid) { $0 }, "\(aid) 创建了群聊")
        XCTAssertEqual(tipText(createdTip.body.tip!, me: aid) { $0 }, "你创建了群聊")
        await b.refreshConversationsIgnoringThrottle()
        XCTAssertEqual(conv(b, convId)?.lastMsg?.text, "\(aid) 邀请 \(bid)、\(cid) 加入了群聊")

        // AC-SOC-22-1, AC-SOC-29-5
        let invited = try await a.inviteToGroup(groupId, members: [did])
        XCTAssertEqual(invited.added, [did])
        XCTAssertEqual(invited.failed, [])
        try await untilTrue("d convAdded", timeout: 2) { conv(d, convId) != nil }
        let joined = try await until("joined tip") { tip(b, "joined") }
        XCTAssertEqual(joined.body.tip?.actor, aid)
        XCTAssertEqual(joined.body.tip?.targets, [did])
        XCTAssertEqual(tipText(joined.body.tip!, me: aid) { $0 }, "你邀请 \(did) 加入了群聊")
        XCTAssertEqual(tipText(joined.body.tip!, me: bid) { $0 }, "\(aid) 邀请 \(did) 加入了群聊")
        try await untilTrue("memberCount via groupChanged") { conv(b, convId)?.memberCount == 4 }
        // The local summary equals the server's text: no jump on refresh.
        XCTAssertEqual(conv(b, convId)?.lastMsg?.text, "\(aid) 邀请 \(did) 加入了群聊")
        await b.refreshConversationsIgnoringThrottle()
        XCTAssertEqual(conv(b, convId)?.lastMsg?.text, "\(aid) 邀请 \(did) 加入了群聊")

        try await a.setGroupAdmin(groupId, userId: bid, admin: true)
        try await untilTrue("b becomes admin") { conv(b, convId)?.myRole == .admin }

        // AC-SOC-27-1, AC-SOC-27-4
        try await b.updateGroup(groupId, name: "周六球局", notice: "九点")
        try await untilTrue("renamed") { conv(a, convId)?.name == "周六球局" }
        try await until("renamed tip") { tip(c, "renamed") }
        let noticeTip = try await until("notice tip") { tip(c, "noticeUpdated") }
        XCTAssertEqual(tipText(noticeTip.body.tip!, me: cid) { $0 }, "\(bid) 更新了群公告")
        let info = try await a.getGroupInfo(groupId)
        XCTAssertEqual(info.notice, "九点")
        XCTAssertEqual(info.noticeBy, bid)
        XCTAssertEqual(info.owner, aid)
        XCTAssertFalse(info.managed)

        // AC-SOC-24-1
        await assertThrowsCode(4030) { _ = try await b.kickFromGroup(groupId, members: [aid]) }
        let removed = try await b.kickFromGroup(groupId, members: [did])
        XCTAssertEqual(removed, [did])
        try await untilTrue("d removed", timeout: 2) { d.conversationSnapshot(convId)?.reason == "removed" }
        // The group's maxSeq does not move for a removal.
        let seqAtKick = conv(a, convId)?.maxSeq
        _ = try sendOK(d, convId, "after kick")
        let kickedSend = try await until("4033") { d.messages(convId).first { $0.status == .failed } }
        XCTAssertEqual(kickedSend.error, .code(4033))
        XCTAssertEqual(conv(a, convId)?.maxSeq, seqAtKick)

        // AC-SOC-28-5: member paging, owner first.
        let page = try await a.loadGroupMembers(groupId)
        XCTAssertEqual(page.members.map(\.userId), [aid, bid, cid])
        XCTAssertEqual(page.members.map(\.role), [.owner, .admin, .member])
        XCTAssertEqual(page.nextCursor, "")

        // AC-SOC-25-1
        try await a.transferGroupOwner(groupId, to: cid)
        try await untilTrue("c becomes owner") { conv(c, convId)?.myRole == .owner }
        let ownerInfo = try await a.getGroupInfo(groupId)
        XCTAssertEqual(ownerInfo.owner, cid)
        XCTAssertEqual(ownerInfo.myRole, .member)
        try await until("ownerChanged tip") { tip(b, "ownerChanged") }
        await assertThrowsCode(4030) { _ = try await a.kickFromGroup(groupId, members: [bid]) }

        // AC-SOC-23-1
        let seqAtLeave = conv(c, convId)?.maxSeq
        try await a.leaveGroup(groupId)
        XCTAssertNil(conv(a, convId))
        XCTAssertEqual(a.conversationSnapshot(convId)?.reason, "left")
        try await untilTrue("other device gets left", timeout: 2) { aOther.conversationSnapshot(convId)?.reason == "left" }
        await assertThrowsCode(4033) { _ = try await a.getGroupInfo(groupId) }
        let afterLeave = try await c.getGroupInfo(groupId)
        XCTAssertEqual(afterLeave.memberCount, 2)
        XCTAssertEqual(conv(c, convId)?.maxSeq, seqAtLeave)
        _ = try sendOK(a, convId, "after leave")
        let leftSend = try await until("4033 after leaving") { a.messages(convId).first { $0.status == .failed } }
        XCTAssertEqual(leftSend.error, .code(4033))

        // AC-SOC-26-1
        try await c.dissolveGroup(groupId)
        XCTAssertEqual(c.conversationSnapshot(convId)?.reason, "dissolved")
        try await untilTrue("b sees dissolved", timeout: 2) { b.conversationSnapshot(convId)?.reason == "dissolved" }
        // A member offline during the dissolve no longer has it.
        let later = try await login(did)
        try await untilTrue("d loaded") { later.socialLoaded() }
        XCTAssertNil(conv(later, convId))
    }

    // FE-143: Error.userId from a real 4035.
    func testCreateFailureCarriesUserId() async throws {
        let (e, f, g) = (uid("gm"), uid("gm"), uid("gm"))
        try await importUsers([e, f, g], nicknames: [e: e, f: f, g: g])
        let eIm = try await login(e)
        let fIm = try await login(f)
        try await befriend(eIm, e, fIm, f)
        do {
            _ = try await eIm.createGroup(members: [f, g])
            XCTFail("should fail")
        } catch {
            XCTAssertEqual((error as? IMError)?.code, 4035)
            XCTAssertEqual((error as? IMError)?.userId, g)
        }
    }

    // AC-SOC-27-4's data and AC-SOC-28-5's paging beyond one page: all members can be walked with the cursor.
    func testMemberPagingWalksEveryone() async throws {
        let owner = uid("o")
        let members = (0..<120).map { _ in uid("m") }
        try await importUsers(members + [owner])
        let g = try await hostedGroup([owner] + Array(members.prefix(100)), name: "大群")
        try await srv.admin("POST", "/admin/groups/\(g.groupId)/members", ["members": Array(members.suffix(20))])
        let im = try await login(owner)
        var all: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await im.loadGroupMembers(g.groupId, cursor: cursor)
            all += page.members.map(\.userId)
            cursor = page.nextCursor.isEmpty ? nil : page.nextCursor
            pages += 1
        } while cursor != nil
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(Set(all).count, 121)
    }

    // PRD-admin F-ADM-24: removed through the admin API arrives as reason "removed"; the group leaves the list.
    func testRemovedByAdminCarriesReason() async throws {
        let (aid, bid) = (uid("a"), uid("b"))
        let g = try await hostedGroup([aid, bid])
        let a = try await login(aid)
        try await untilTrue("sees group") { conv(a, g.convId) != nil }
        let log = EventLog(a)
        try await srv.signed("DELETE", "/admin/groups/\(g.groupId)/members", ["members": [aid]])
        try await untilTrue("convRemoved") { !log.removed.isEmpty }
        XCTAssertEqual(log.removed[0].0, g.convId)
        XCTAssertEqual(log.removed[0].1, "removed")
        XCTAssertNil(conv(a, g.convId))
    }

    // AC-SOC-20-10: ten members leave in a second; an online member's groupInfo stays correct and groupChanged stays low.
    func testBurstOfLeavesMergesGroupChanged() async throws {
        let watcher = uid("w")
        let leavers = (0..<10).map { _ in uid("l") }
        let g = try await hostedGroup([watcher] + leavers)
        let w = try await login(watcher)
        try await untilTrue("watcher sees group") { conv(w, g.convId) != nil }
        let log = EventLog(w)
        var ims: [IMClient] = []
        for l in leavers { ims.append(try await login(l)) }
        for im in ims { try await im.leaveGroup(g.groupId) }
        try await untilTrue("final member count", timeout: 5) { conv(w, g.convId)?.memberCount == 1 }
        try await sleepMs(2000)
        XCTAssertLessThanOrEqual(log.groupChanged.count, 4)
        let info = try await w.getGroupInfo(g.groupId)
        XCTAssertEqual(info.memberCount, 1)
    }
}

extension IMClient {
    /// For tests: `refreshConversations` has a 30-second throttle (G-UI-24).
    func refreshConversationsIgnoringThrottle() async {
        if let ack = try? await conn.request(ConvsAck.self, "convs") {
            applyConvs(ack)
        }
    }
}
#endif
