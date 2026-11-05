import Foundation

private let socialDebounceMs: Int64 = 200  // socialChanged (F-SOC-06 rule 6)
private let socialRetryMs: Int64 = 6_000  // socialFull's rate limit recovers one round per 6 seconds
private let socialPageSize: Int64 = 500
private let usersBatchSize = 100

struct SocialSnapshot {
    var friends: [Friend] = []
    var requests = FriendRequestList(items: [], unseen: 0)
    var blocks: [BlockedUser] = []
    var settings = SocialSettings(searchable: true, mode: .open, strangerMsgLimit: 0)
}

/// One `getUsers` call waiting for all its ids across batches.
final class UsersWaiter {
    private var remaining: Int
    private var continuation: CheckedContinuation<Void, Never>?

    init(count: Int, continuation: CheckedContinuation<Void, Never>) {
        remaining = count
        self.continuation = continuation
    }

    func finishOne() {
        remaining -= 1
        if remaining <= 0 {
            continuation?.resume()
            continuation = nil
        }
    }
}

extension IMClient {
    // MARK: Snapshots

    /// Server time "now": expiry and 30-day checks use it, never the local clock (PRD-core 3.1).
    public func serverNow() -> Int64 {
        clock.now() + serverOffset
    }

    public func friends() -> [Friend] { socialSnap.friends }
    public func friendRequests() -> FriendRequestList { socialSnap.requests }
    public func blocks() -> [BlockedUser] { socialSnap.blocks }
    public func socialSettings() -> SocialSettings { socialSnap.settings }

    /// Whether one social round has finished (the contact list shows a skeleton until then).
    public func socialLoaded() -> Bool { social.loaded }

    /// Whether I am an official account.
    public func isOfficial() -> Bool { social.official }

    /// Syncs from the local socialVer now (e.g. after `respondFriend` returns 4045).
    public func refreshSocial() async {
        social.needSync = true
        startSocialSync()
        await socialRunning?.value
    }

    /// The relation from local data only (same enum as `userSearch.relation`).
    public func relationOf(_ userId: String) -> Relation {
        social.relation(of: userId, me: me, serverNow: serverNow())
    }

    /// The last profile seen (cached, possibly stale); nil when none.
    public func profileOf(_ userId: String) -> UserProfile? {
        profiles.last(userId)
    }

    /// Display name: friend remark, then nickname, then userId (remarks are local, PRD-social 5.5).
    public func displayName(_ userId: String) -> String {
        if let f = social.friends[userId], f.deleted != true, !f.remark.isEmpty { return f.remark }
        if let nick = profiles.last(userId)?.nickname, !nick.isEmpty { return nick }
        return userId
    }

    // MARK: Friends and blocks

    @discardableResult
    public func applyFriend(_ userId: String, options o: ApplyFriendOptions = ApplyFriendOptions()) async throws
        -> String
    {
        var data: [String: JSONValue] = ["to": .string(userId)]
        if let v = o.message { data["message"] = .string(v) }
        if let v = o.source { data["source"] = .string(v.rawValue) }
        if let v = o.sourceRef { data["sourceRef"] = .string(v) }
        if let v = o.remark { data["remark"] = .string(v) }
        let ack = try await socialCommand("friendApply", .object(data))
        return ack.status ?? "pending"
    }

    public enum FriendResponse: String, Sendable {
        case accept, reject
    }

    public func respondFriend(_ userId: String, _ action: FriendResponse, remark: String? = nil) async throws {
        var data: [String: JSONValue] = ["from": .string(userId), "action": .string(action.rawValue)]
        if let remark { data["remark"] = .string(remark) }
        _ = try await socialCommand("friendRespond", .object(data))
    }

    public func deleteFriend(_ userId: String) async throws {
        _ = try await socialCommand("friendDelete", ["userId": .string(userId)])
    }

    public func setFriendRemark(_ userId: String, _ remark: String) async throws {
        _ = try await socialCommand("friendRemark", ["userId": .string(userId), "remark": .string(remark)])
    }

    public func block(_ userId: String) async throws {
        _ = try await socialCommand("block", ["userId": .string(userId)])
    }

    public func unblock(_ userId: String) async throws {
        _ = try await socialCommand("unblock", ["userId": .string(userId)])
    }

    private struct ChangedAck: Decodable {
        var ver: Int64
        var changed: Bool
    }

    /// On entering "new friends": the local red dot clears at once and the current socialVer is reported (F-SOC-04 rule 3).
    public func markFriendRequestsSeen() {
        let ver = social.ver
        guard ver > social.requestSeenVer else { return }
        social.requestSeenVer = ver
        persistSocialMeta()
        emitSocial()
        conn.request("friendRequestsSeen", ["ver": .int(ver)]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let raw):
                if let ack = try? decodeFrameData(ChangedAck.self, from: raw) {
                    self.social.applyAck(ver: ack.ver, changed: ack.changed, items: nil)
                    self.persistSocialMeta()
                    self.afterSocialAck()
                }
            case .failure(let err):
                self.log.warn("im: friendRequestsSeen failed: \(describeForLog(err))")
            }
        }
    }

    public func setSearchable(_ searchable: Bool) async throws {
        let ack = try await conn.request(ChangedAck.self, "setPrivacy", ["searchable": .bool(searchable)])
        social.settings.searchable = searchable
        social.applyAck(ver: ack.ver, changed: ack.changed, items: nil)
        persistSocialMeta()
        afterSocialAck()
    }

    private struct SearchAck: Decodable { var user: SearchedUser? }

    /// Exact userId search (absent and unsearchable are both nil). The result enters the profile cache.
    public func searchUser(_ keyword: String) async throws -> SearchedUser? {
        let ack = try await conn.request(SearchAck.self, "userSearch", ["keyword": .string(keyword)])
        if let u = ack.user {
            profiles.put(
                UserProfile(userId: u.userId, nickname: u.nickname, avatar: u.avatar, official: u.official))
        }
        return ack.user
    }

    private struct UsersAck: Decodable { var users: [UserProfile] }

    /// Batch profile lookup (F-SOC-10): cache hits send nothing; calls within one main-actor turn merge, at most 100
    /// per batch. Returns the visible users: invisible and absent are not returned (indistinguishable).
    public func getUsers(_ userIds: [String]) async -> [UserProfile] {
        var seen = Set<String>()
        let ids = userIds.filter { seen.insert($0).inserted }
        let missing = ids.filter { profiles.needsFetch($0) }
        if !missing.isEmpty {
            let first = usersQueue.isEmpty
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let waiter = UsersWaiter(count: missing.count, continuation: cont)
                for id in missing { usersQueue[id, default: []].append(waiter) }
                if first {
                    Task { [weak self] in await self?.flushUsers() }
                }
            }
        }
        return ids.compactMap { profiles.fresh($0) }
    }

    private func flushUsers() async {
        let queue = usersQueue
        usersQueue = [:]
        let ids = queue.keys.sorted(by: bytesLess)
        var i = 0
        while i < ids.count {
            let batch = Array(ids[i..<min(i + usersBatchSize, ids.count)])
            i += usersBatchSize
            do {
                let ack = try await conn.request(
                    UsersAck.self, "users", ["userIds": .array(batch.map { .string($0) })])
                for u in ack.users { profiles.put(u) }
                for id in batch where profiles.fresh(id) == nil { profiles.markMissing(id) }
            } catch {
                log.warn("im: users failed: \(describeForLog(error))")
            }
            for id in batch {
                for waiter in queue[id] ?? [] { waiter.finishOne() }
            }
        }
    }

    private struct MyGroupsAck: Decodable {
        var groups: [MyGroup]
        var nextCursor: String
    }

    /// My groups (F-SOC-11): all pages, by groupId ascending.
    public func loadMyGroups() async throws -> [MyGroup] {
        var out: [MyGroup] = []
        var cursor = ""
        while true {
            let data: JSONValue = cursor.isEmpty ? .object([:]) : ["cursor": .string(cursor)]
            let ack = try await conn.request(MyGroupsAck.self, "myGroups", data)
            out += ack.groups
            if ack.nextCursor.isEmpty { return out }
            cursor = ack.nextCursor
        }
    }

    // MARK: Groups (FE-143)

    private struct GroupCreateAck: Decodable {
        var groupId: String
        var conv: ServerConversation
    }

    /// Creates a group. The generated clientReqId stays the same across timeout retries, so a retry can never create
    /// a second group (F-SOC-21 rule 1).
    public func createGroup(name: String? = nil, members: [String]) async throws -> (
        groupId: String, conv: Conversation
    ) {
        var data: [String: JSONValue] = [
            "clientReqId": .string(newId()),
            "members": .array(members.map { .string($0) }),
        ]
        if let name, !name.isEmpty { data["name"] = .string(name) }
        var attempt = 0
        while true {
            do {
                let ack = try await conn.request(GroupCreateAck.self, "groupCreate", .object(data))
                store.upsertConversation(ack.conv)
                setGroupMute(ack.conv.convId, ack.conv.mutedUntil)
                mutesChanged()
                emitConversations()
                guard let conv = store.conversation(ack.conv.convId) else {
                    throw IMConnectionError.badResponse(cmd: "groupCreate")
                }
                return (ack.groupId, conv)
            } catch IMConnectionError.timeout where attempt < 2 {
                attempt += 1
            }
        }
    }

    public func inviteToGroup(_ groupId: String, members: [String]) async throws -> GroupInviteResult {
        try await conn.request(
            GroupInviteResult.self, "groupInvite",
            ["groupId": .string(groupId), "members": .array(members.map { .string($0) })])
    }

    /// Leaves a group. This connection gets no `convRemoved`, so it is applied locally as "left".
    public func leaveGroup(_ groupId: String) async throws {
        _ = try await conn.requestRaw("groupLeave", ["groupId": .string(groupId)])
        removeLocally(groupId, reason: "left")
    }

    private struct KickAck: Decodable { var removed: [String] }

    @discardableResult
    public func kickFromGroup(_ groupId: String, members: [String]) async throws -> [String] {
        try await conn.request(
            KickAck.self, "groupKick",
            ["groupId": .string(groupId), "members": .array(members.map { .string($0) })]
        ).removed
    }

    public func transferGroupOwner(_ groupId: String, to: String) async throws {
        _ = try await conn.requestRaw("groupTransfer", ["groupId": .string(groupId), "to": .string(to)])
        onGroupChanged(groupId)
    }

    public func setGroupAdmin(_ groupId: String, userId: String, admin: Bool) async throws {
        _ = try await conn.requestRaw(
            "groupSetAdmin", ["groupId": .string(groupId), "userId": .string(userId), "admin": .bool(admin)])
    }

    public func dissolveGroup(_ groupId: String) async throws {
        _ = try await conn.requestRaw("groupDissolve", ["groupId": .string(groupId)])
        removeLocally(groupId, reason: "dissolved")
    }

    public func updateGroup(_ groupId: String, name: String? = nil, notice: String? = nil) async throws {
        var data: [String: JSONValue] = ["groupId": .string(groupId)]
        if let name { data["name"] = .string(name) }
        if let notice { data["notice"] = .string(notice) }
        _ = try await conn.requestRaw("groupUpdate", .object(data))
    }

    /// Group info; also updates the local conversation's myRole, memberCount and name.
    public func getGroupInfo(_ groupId: String) async throws -> GroupInfo {
        let info = try await conn.request(GroupInfo.self, "groupInfo", ["groupId": .string(groupId)])
        if store.updateGroupMeta(
            convId: groupConvId(groupId), name: info.name, memberCount: info.memberCount, myRole: info.myRole)
        {
            emitConversations()
        }
        return info
    }

    /// One page of members (owner, then admins, then members); their profiles enter the cache.
    public func loadGroupMembers(_ groupId: String, cursor: String? = nil) async throws -> GroupMembersPage {
        var data: [String: JSONValue] = ["groupId": .string(groupId)]
        if let cursor, !cursor.isEmpty { data["cursor"] = .string(cursor) }
        let page = try await conn.request(GroupMembersPage.self, "groupMembers", .object(data))
        for m in page.members {
            profiles.put(
                UserProfile(userId: m.userId, nickname: m.nickname, avatar: m.avatar, official: m.official))
        }
        return page
    }

    private func removeLocally(_ groupId: String, reason: String) {
        let convId = groupConvId(groupId)
        store.removeConversation(convId, reason: reason)
        setGroupMute(convId, nil)
        mutesChanged()
        emitConversations()
        emit(.convRemoved(convId: convId, reason: reason))
    }

    /// `groupChanged`: refreshes this group without refetching `convs`; in-flight requests merge (F-SOC-20 rule 5).
    func onGroupChanged(_ groupId: String) {
        if groupInfoInFlight[groupId] != nil {
            groupInfoInFlight[groupId] = true
            return
        }
        groupInfoInFlight[groupId] = false
        Task { [weak self] in
            guard let self else { return }
            var info: GroupInfo?
            do {
                info = try await self.getGroupInfo(groupId)
            } catch {
                self.log.warn("im: groupInfo failed: \(describeForLog(error))")
            }
            let again = self.groupInfoInFlight[groupId] == true
            self.groupInfoInFlight[groupId] = nil
            if again {
                self.onGroupChanged(groupId)
            } else if let info {
                self.emit(.groupChanged(groupId: groupId, info: info))
            }
        }
    }

    // MARK: Sync engine

    private func socialCommand(_ cmd: String, _ data: JSONValue) async throws -> SocialChangeAck {
        let ack = try await conn.request(SocialChangeAck.self, cmd, data)
        cacheProfiles(friends: ack.items.friends, requests: ack.items.requests, blocks: ack.items.blocks)
        social.applyAck(ver: ack.ver, changed: ack.changed, items: ack.items)
        if ack.changed {
            persistSocialRows(
                friends: ack.items.friends.compactMap { social.friends[$0.userId] },
                requests: ack.items.requests.compactMap {
                    social.requests[RequestKey(userId: $0.userId, direction: $0.direction)]
                },
                blocks: ack.items.blocks.compactMap { social.blocks[$0.userId] },
                replaceAll: false,
                includeMeta: true)
        }
        afterSocialAck()
        return ack
    }

    private func afterSocialAck() {
        emitSocial()
        if social.needSync { startSocialSync() }
    }

    private func cacheProfiles(friends: [FriendItem], requests: [RequestItem], blocks: [BlockItem]) {
        for f in friends { profiles.putProfile(f.userId, f.profile) }
        for r in requests { profiles.putProfile(r.userId, r.profile) }
        for b in blocks { profiles.putProfile(b.userId, b.profile) }
    }

    func syncSocialSoon() {
        guard socialTimer == nil else { return }
        socialTimer = clock.setTimeout(socialDebounceMs) { [weak self] in
            guard let self else { return }
            self.socialTimer = nil
            self.startSocialSync()
        }
    }

    /// Runs rounds until none is needed (F-SOC-06 rules 3, 8). One at a time; events during a round are handled after.
    func startSocialSync() {
        guard socialRunning == nil else { return }
        socialRunning = Task { [weak self] in
            await self?.runSocialRounds()
            self?.socialRunning = nil
        }
    }

    private func runSocialRounds() async {
        var rounds = 0
        while social.needSync, conn.state == .connected, rounds < 20 {
            rounds += 1
            let since = social.beginRound()
            var data: JSONValue = ["sinceVer": .int(since), "limit": .int(socialPageSize)]
            do {
                pages: while true {
                    let page = try await conn.request(SocialSyncAck.self, "socialSync", data)
                    cacheProfiles(friends: page.friends, requests: page.requests, blocks: page.blocks)
                    let next = social.applyPage(page)
                    persistSocialPage(page, next)
                    switch next {
                    case .done:
                        break pages
                    case .continue:
                        data = ["cursor": .string(page.cursor), "limit": .int(socialPageSize)]
                    case .restart:
                        data = ["sinceVer": .int(since), "limit": .int(socialPageSize)]
                    }
                }
            } catch {
                social.abortRound()
                log.warn("im: socialSync failed: \(describeForLog(error))")
                // A rate-limited full round (10 per minute, e.g. frequent launches): retry later, otherwise the first
                // round would never finish. Other failures wait for the next event or reconnect.
                if let e = error as? IMError, e.code == ErrorCode.rateLimited {
                    social.needSync = true
                    if socialTimer == nil {
                        socialTimer = clock.setTimeout(socialRetryMs) { [weak self] in
                            guard let self else { return }
                            self.socialTimer = nil
                            self.startSocialSync()
                        }
                    }
                }
                return
            }
            emitSocial()
        }
    }

    /// Recomputes the social snapshots and emits all four events.
    func emitSocial() {
        let now = serverNow()
        let s = social
        var friends: [Friend] = []
        for f in s.friends.values where f.deleted != true {
            let name = [f.remark, f.profile?.nickname ?? "", profiles.last(f.userId)?.nickname ?? ""]
                .first { !$0.isEmpty } ?? f.userId
            friends.append(Friend(item: f, displayName: name, blocked: s.isBlocked(f.userId)))
        }
        friends.sort { bytesLess($0.userId, $1.userId) }
        let items = s.requestList(at: now).map { r -> FriendRequest in
            // Outgoing requests have no profile before they are accepted: use whatever is at hand.
            let nick = r.profile?.nickname ?? profiles.last(r.userId)?.nickname ?? ""
            return FriendRequest(item: r, displayName: nick.isEmpty ? r.userId : nick)
        }
        var blocks: [BlockedUser] = []
        for b in s.blocks.values where b.deleted != true {
            let nick = b.profile?.nickname ?? ""
            blocks.append(BlockedUser(item: b, displayName: nick.isEmpty ? b.userId : nick))
        }
        blocks.sort {
            $0.item.createdAt != $1.item.createdAt
                ? $0.item.createdAt > $1.item.createdAt : bytesLess($0.userId, $1.userId)
        }
        socialSnap = SocialSnapshot(
            friends: friends,
            requests: FriendRequestList(items: items, unseen: s.unseen(at: now)),
            blocks: blocks,
            settings: s.settings)
        emit(.friends(friends))
        emit(.friendRequests(socialSnap.requests))
        emit(.blocks(blocks))
        emit(.socialSettings(socialSnap.settings))
    }

    func clearSocial() {
        if let timer = socialTimer { clock.clearTimeout(timer) }
        socialTimer = nil
        social.clear()
        profiles.clear()
        emitSocial()
    }

    // MARK: Social persistence

    func restoreSocial(_ s: StoredSocial) {
        social.ver = s.ver
        social.requestSeenVer = s.requestSeenVer
        social.settings = s.settings
        social.official = s.official
        social.loaded = s.loaded
        for f in s.friends {
            social.friends[f.userId] = f
            profiles.putProfile(f.userId, f.profile)
        }
        for r in s.requests {
            social.requests[RequestKey(userId: r.userId, direction: r.direction)] = r
            profiles.putProfile(r.userId, r.profile)
        }
        for b in s.blocks {
            social.blocks[b.userId] = b
            profiles.putProfile(b.userId, b.profile)
        }
    }

    /// Drops requests past 30 days once server time is known (PRD-social 10.2).
    func purgeOldRequests() {
        let old = social.purgeExpiredRequests(at: serverNow())
        guard !old.isEmpty else { return }
        persistSocialRows(
            friends: [], requests: [], blocks: [], removedRequests: old, replaceAll: false, includeMeta: false)
        emitSocial()
    }

    private func persistSocialPage(_ page: SocialSyncAck, _ next: PageResult) {
        guard next != .restart else { return }
        if social.isFullRound {
            // A full round replaces everything at once when it ends: nothing is written for earlier pages.
            guard next == .done else { return }
            persistSocialRows(
                friends: Array(social.friends.values),
                requests: Array(social.requests.values),
                blocks: Array(social.blocks.values),
                replaceAll: true,
                includeMeta: true)
        } else {
            // Incremental pages apply one by one; socialVer only advances with the last page's transaction.
            persistSocialRows(
                friends: page.friends.compactMap { social.friends[$0.userId] },
                requests: page.requests.compactMap {
                    social.requests[RequestKey(userId: $0.userId, direction: $0.direction)]
                },
                blocks: page.blocks.compactMap { social.blocks[$0.userId] },
                replaceAll: false,
                includeMeta: next == .done)
        }
    }

    func persistSocialMeta() {
        persistSocialRows(friends: [], requests: [], blocks: [], replaceAll: false, includeMeta: true)
    }

    private func persistSocialRows(
        friends: [FriendItem],
        requests: [RequestItem],
        blocks: [BlockItem],
        removedRequests: [RequestKey] = [],
        replaceAll: Bool,
        includeMeta: Bool
    ) {
        guard let db = database else { return }
        let meta =
            includeMeta
            ? StoredSocial(
                ver: social.ver, requestSeenVer: social.requestSeenVer, settings: social.settings,
                official: social.official, loaded: social.loaded, friends: [], requests: [], blocks: [])
            : nil
        do {
            try db.saveSocial(
                replaceAll: replaceAll, friends: friends, requests: requests, blocks: blocks,
                removedRequests: removedRequests, meta: meta)
        } catch {
            dropDatabaseAfterFailure(error)
        }
    }
}
