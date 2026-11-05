import Foundation

// Social relations (PRD-social sections 9, 10; FE-140...FE-143): protocol types, the sync state machine, the profile
// cache. `SocialState` does no networking; it runs the same vectors/social.json as the other SDKs.

public struct Profile: Sendable, Hashable, Codable {
    public var nickname: String
    public var avatar: String
    public var official: Bool

    public init(nickname: String, avatar: String, official: Bool) {
        self.nickname = nickname
        self.avatar = avatar
        self.official = official
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nickname = c.value(.nickname, default: "")
        avatar = c.value(.avatar, default: "")
        official = c.value(.official, default: false)
    }
}

public struct ApplySource: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let search: ApplySource = "search"
    public static let group: ApplySource = "group"
    public static let card: ApplySource = "card"
    public static let conv: ApplySource = "conv"
    public static let other: ApplySource = "other"
    public static let admin: ApplySource = "admin"
}

public struct RequestStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pending: RequestStatus = "pending"
    public static let accepted: RequestStatus = "accepted"
    public static let rejected: RequestStatus = "rejected"
    public static let expired: RequestStatus = "expired"
}

public struct RequestDirection: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let incoming: RequestDirection = "in"
    public static let outgoing: RequestDirection = "out"
}

public struct SocialMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let open: SocialMode = "open"
    public static let friends: SocialMode = "friends"
}

public struct Relation: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let `self`: Relation = "self"
    public static let blocked: Relation = "blocked"
    public static let friend: Relation = "friend"
    public static let pendingIn: Relation = "pendingIn"
    public static let pendingOut: Relation = "pendingOut"
    public static let none: Relation = "none"
}

public struct FriendItem: Sendable, Hashable, Codable {
    public var userId: String
    public var remark: String
    public var source: ApplySource
    public var createdAt: Int64
    public var ver: Int64
    public var deleted: Bool?
    public var profile: Profile?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        remark = c.value(.remark, default: "")
        source = c.value(.source, default: .other)
        createdAt = c.value(.createdAt, default: 0)
        ver = try c.decode(Int64.self, forKey: .ver)
        deleted = c.value(.deleted, default: nil)
        profile = c.value(.profile, default: nil)
    }
}

public struct RequestItem: Sendable, Hashable, Codable {
    public var userId: String
    public var direction: RequestDirection
    public var status: RequestStatus
    public var message: String
    public var source: ApplySource
    public var applyCount: Int
    public var createdAt: Int64
    public var updatedAt: Int64
    public var expireAt: Int64
    public var ver: Int64
    /// The server gives no profile for an outgoing request until the other side accepts.
    public var profile: Profile?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        direction = try c.decode(RequestDirection.self, forKey: .direction)
        status = try c.decode(RequestStatus.self, forKey: .status)
        message = c.value(.message, default: "")
        source = c.value(.source, default: .other)
        applyCount = c.value(.applyCount, default: 1)
        createdAt = c.value(.createdAt, default: 0)
        updatedAt = c.value(.updatedAt, default: 0)
        expireAt = c.value(.expireAt, default: 0)
        ver = try c.decode(Int64.self, forKey: .ver)
        profile = c.value(.profile, default: nil)
    }
}

public struct BlockItem: Sendable, Hashable, Codable {
    public var userId: String
    public var createdAt: Int64
    public var ver: Int64
    public var deleted: Bool?
    /// Nil when the other person is outside my visible range.
    public var profile: Profile?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        createdAt = c.value(.createdAt, default: 0)
        ver = try c.decode(Int64.self, forKey: .ver)
        deleted = c.value(.deleted, default: nil)
        profile = c.value(.profile, default: nil)
    }
}

struct SocialItems: Sendable, Decodable {
    var friends: [FriendItem] = []
    var requests: [RequestItem] = []
    var blocks: [BlockItem] = []

    private enum CodingKeys: String, CodingKey { case friends, requests, blocks }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        friends = c.value(.friends, default: [])
        requests = c.value(.requests, default: [])
        blocks = c.value(.blocks, default: [])
    }
}

struct SocialSyncAck: Sendable, Decodable {
    struct Settings: Sendable, Decodable { var searchable: Bool }

    var full: Bool
    var untilVer: Int64
    var latestVer: Int64
    var hasMore: Bool
    var cursor: String
    var restart: Bool
    var friends: [FriendItem]
    var requests: [RequestItem]
    var blocks: [BlockItem]
    var requestSeenVer: Int64
    var settings: Settings
    var mode: SocialMode
    var strangerMsgLimit: Int
    var official: Bool

    private enum CodingKeys: String, CodingKey {
        case full, untilVer, latestVer, hasMore, cursor, restart, friends, requests, blocks, requestSeenVer, settings,
            mode, strangerMsgLimit, official
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        full = c.value(.full, default: false)
        untilVer = c.value(.untilVer, default: 0)
        latestVer = c.value(.latestVer, default: 0)
        hasMore = c.value(.hasMore, default: false)
        cursor = c.value(.cursor, default: "")
        restart = c.value(.restart, default: false)
        friends = try c.decodeIfPresent([FriendItem].self, forKey: .friends) ?? []
        requests = try c.decodeIfPresent([RequestItem].self, forKey: .requests) ?? []
        blocks = try c.decodeIfPresent([BlockItem].self, forKey: .blocks) ?? []
        requestSeenVer = c.value(.requestSeenVer, default: 0)
        settings = c.value(.settings, default: Settings(searchable: true))
        mode = c.value(.mode, default: .open)
        strangerMsgLimit = c.value(.strangerMsgLimit, default: 0)
        official = c.value(.official, default: false)
    }
}

struct SocialChangeAck: Sendable, Decodable {
    var status: String?
    var ver: Int64
    var changed: Bool
    var items: SocialItems

    private enum CodingKeys: String, CodingKey { case status, ver, changed, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.value(.status, default: nil)
        ver = c.value(.ver, default: 0)
        changed = c.value(.changed, default: false)
        items = c.value(.items, default: SocialItems())
    }
}

/// A `userSearch` result.
public struct SearchedUser: Sendable, Hashable, Codable {
    public var userId: String
    public var nickname: String
    public var avatar: String
    public var official: Bool
    public var relation: Relation
}

/// One `users` item; also the value of the profile cache.
public struct UserProfile: Sendable, Hashable, Codable {
    public var userId: String
    public var nickname: String
    public var avatar: String
    public var official: Bool

    public init(userId: String, nickname: String, avatar: String, official: Bool) {
        self.userId = userId
        self.nickname = nickname
        self.avatar = avatar
        self.official = official
    }
}

public struct MyGroup: Sendable, Hashable, Codable {
    public var groupId: String
    public var name: String
    public var memberCount: Int
    public var joinedAt: Int64
}

public struct SocialSettings: Sendable, Hashable, Codable {
    public var searchable: Bool
    public var mode: SocialMode
    public var strangerMsgLimit: Int
}

public struct GroupInfo: Sendable, Hashable, Codable {
    public var groupId: String
    public var name: String
    public var notice: String
    public var noticeBy: String
    public var noticeAt: Int64
    /// Empty when there is no owner.
    public var owner: String
    /// A hosted group (created by the business side).
    public var managed: Bool
    public var myRole: GroupRole
    public var memberCount: Int
    public var maxMembers: Int
    public var historyVisible: Bool
    public var createdAt: Int64
}

public struct GroupMemberInfo: Sendable, Hashable, Codable {
    public var userId: String
    public var role: GroupRole
    public var joinedAt: Int64
    public var nickname: String
    public var avatar: String
    public var official: Bool
}

public struct GroupMembersPage: Sendable, Hashable, Codable {
    public var members: [GroupMemberInfo]
    public var nextCursor: String
}

public struct GroupInviteResult: Sendable, Hashable, Codable {
    public struct Failure: Sendable, Hashable, Codable {
        public var userId: String
        public var code: Int
    }
    public var added: [String]
    public var failed: [Failure]
}

/// Local copy of a tip message (PRD-ui F-UI-40, vectors/social.json `tips`): "you" for me, `nameOf` for others
/// (may be a local remark). Unknown kinds show "[群通知]".
public func tipText(_ tip: TipBody, me: String, nameOf: (String) -> String) -> String {
    func who(_ u: String) -> String { u == me ? "你" : nameOf(u) }
    let shown = tip.targets.prefix(3).map(who).joined(separator: "、")
    let total = max(tip.count ?? 0, tip.targets.count)
    let targets = total > 3 ? "\(shown) 等 \(total) 人" : shown
    let actor = who(tip.actor)
    let you = tip.actor == me
    let spaced = you ? "你" : "\(actor) "
    switch tip.kind {
    case "created":
        return "\(spaced)创建了群聊"
    case "joined":
        return you ? "你邀请 \(targets) 加入了群聊" : "\(actor) 邀请 \(targets) 加入了群聊"
    case "ownerChanged":
        if !tip.actor.isEmpty { return "\(spaced)将群主转让给 \(targets)" }
        if tip.targets.isEmpty { return "群主已退出群聊" }
        return targets == "你" ? "你已成为群主" : "\(targets) 已成为群主"
    case "adminSet":
        return "\(spaced)将 \(targets) 设为管理员"
    case "adminUnset":
        return "\(spaced)取消了 \(targets) 的管理员"
    case "renamed":
        return "\(spaced)修改群名为\"\(tip.text)\""
    case "noticeUpdated":
        return "\(spaced)更新了群公告"
    default:
        return "[群通知]"
    }
}

/// The local version of the conversation-list summary (same rule as the server's `lastMsg.text`, PRD-social 5.5:
/// nicknames only, never "you"). Used until the next `convs` overwrites it.
public func tipSummary(_ tip: TipBody, nick: (String) -> String) -> String {
    let shown = tip.targets.prefix(3).map(nick).joined(separator: "、")
    let total = max(tip.count ?? 0, tip.targets.count)
    let list = total > 3 ? "\(shown)等 \(total) 人" : shown
    let actor = tip.actor.isEmpty ? "" : nick(tip.actor)
    switch tip.kind {
    case "created", "joined":
        return "\(actor) 邀请 \(list) 加入了群聊"
    case "ownerChanged":
        return tip.targets.isEmpty ? "群主已退出群聊" : "\(list) 已成为群主"
    case "adminSet":
        return "\(list) 已成为管理员"
    case "adminUnset":
        return "\(list) 不再是管理员"
    case "renamed":
        return "\(actor) 修改群名为\"\(tip.text)\""
    case "noticeUpdated":
        return "\(actor) 更新了群公告"
    default:
        return "[群通知]"
    }
}

// MARK: - Snapshots the UI sees

/// A friend (never a tombstone). `displayName` is remark, then nickname, then userId.
public struct Friend: Sendable, Hashable {
    public var item: FriendItem
    public var displayName: String
    public var blocked: Bool
    public var userId: String { item.userId }
    public var remark: String { item.remark }
    public var profile: Profile? { item.profile }
}

/// One "new friends" row: `status` is computed with server time; rows without a server profile use the cache.
public struct FriendRequest: Sendable, Hashable {
    public var item: RequestItem
    public var displayName: String
    public var userId: String { item.userId }
    public var direction: RequestDirection { item.direction }
    public var status: RequestStatus { item.status }
    public var message: String { item.message }
    public var profile: Profile? { item.profile }
}

public struct FriendRequestList: Sendable, Hashable {
    public var items: [FriendRequest]
    public var unseen: Int
}

public struct BlockedUser: Sendable, Hashable {
    public var item: BlockItem
    public var displayName: String
    public var userId: String { item.userId }
}

/// How long requests stay on this device (F-SOC-04 rule 1).
public let requestRetentionMs: Int64 = 30 * 24 * 3600 * 1000

struct RequestKey: Hashable, Sendable {
    let userId: String
    let direction: RequestDirection
}

enum PageResult: String {
    case `continue`, restart, done
}

/// Local relation-sync state (PRD-social 10.2).
final class SocialState {
    var ver: Int64 = 0
    var friends: [String: FriendItem] = [:]  // Includes tombstones: needed when keeping the larger ver.
    var requests: [RequestKey: RequestItem] = [:]
    var blocks: [String: BlockItem] = [:]
    var requestSeenVer: Int64 = 0
    var settings = SocialSettings(searchable: true, mode: .open, strangerMsgLimit: 0)
    var official = false
    /// At least one round finished (the contact list shows a skeleton until then).
    var loaded = false
    /// A(nother) round should start.
    var needSync = false

    private var inRound = false
    private var full = false
    private var untilVer: Int64 = 0
    private var staged: SocialState?
    private var pendingEv: Int64 = 0

    /// Starts a round; returns the first page's sinceVer.
    func beginRound() -> Int64 {
        inRound = true
        staged = nil
        needSync = false
        return ver
    }

    /// Whether the current or just-finished round replaces everything.
    var isFullRound: Bool { full }

    /// Applies one page (F-SOC-06 rules 3, 8).
    func applyPage(_ p: SocialSyncAck) -> PageResult {
        if p.restart {
            staged = nil
            return .restart
        }
        if staged == nil {
            full = p.full
            untilVer = p.untilVer
            staged = p.full ? SocialState() : self
        }
        let t = staged!
        for f in p.friends { t.mergeFriend(f) }
        for r in p.requests { t.mergeRequest(r) }
        for b in p.blocks { t.mergeBlock(b) }
        if p.hasMore { return .continue }
        if full {
            friends = t.friends
            requests = t.requests
            blocks = t.blocks
        }
        ver = untilVer
        requestSeenVer = p.requestSeenVer
        settings = SocialSettings(
            searchable: p.settings.searchable, mode: p.mode, strangerMsgLimit: p.strangerMsgLimit)
        official = p.official
        inRound = false
        staged = nil
        loaded = true
        needSync = p.latestVer > untilVer || pendingEv > untilVer
        pendingEv = 0
        return .done
    }

    /// Abandons the running round (a request failed).
    func abortRound() {
        inRound = false
        staged = nil
    }

    /// `socialChanged {ver}` (F-SOC-06 rule 6; the caller debounces).
    func onSocialChanged(_ v: Int64) {
        if inRound {
            pendingEv = max(pendingEv, v)
            return
        }
        if v > ver { needSync = true }
    }

    /// The ack of a change I made (F-SOC-06 rule 7).
    func applyAck(ver v: Int64, changed: Bool, items: SocialItems?) {
        guard changed else { return }
        if let items {
            for f in items.friends { mergeFriend(f) }
            for r in items.requests { mergeRequest(r) }
            for b in items.blocks { mergeBlock(b) }
        }
        if v == ver + 1 {
            ver = v
        } else if v > ver + 1 {
            needSync = true
        }
    }

    private func mergeFriend(_ f: FriendItem) {
        if let old = friends[f.userId], f.ver < old.ver { return }
        friends[f.userId] = f
    }

    private func mergeRequest(_ r: RequestItem) {
        let k = RequestKey(userId: r.userId, direction: r.direction)
        if let old = requests[k], r.ver < old.ver { return }
        requests[k] = r
    }

    private func mergeBlock(_ b: BlockItem) {
        if let old = blocks[b.userId], b.ver < old.ver { return }
        blocks[b.userId] = b
    }

    func isFriend(_ userId: String) -> Bool {
        guard let f = friends[userId] else { return false }
        return f.deleted != true
    }

    func isBlocked(_ userId: String) -> Bool {
        guard let b = blocks[userId] else { return false }
        return b.deleted != true
    }

    /// A request not accepted by `expireAt` is expired (server time).
    static func status(of r: RequestItem, at serverNow: Int64) -> RequestStatus {
        r.status != .accepted && r.expireAt <= serverNow ? .expired : r.status
    }

    /// Requests within 30 days, by updatedAt descending (F-SOC-04 rule 1).
    func requestList(at serverNow: Int64) -> [RequestItem] {
        let cutoff = serverNow - requestRetentionMs
        return requests.values
            .filter { $0.updatedAt >= cutoff }
            .map { r -> RequestItem in
                var r = r
                r.status = SocialState.status(of: r, at: serverNow)
                return r
            }
            .sorted { a, b in
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                if a.userId != b.userId { return bytesLess(a.userId, b.userId) }
                return bytesLess(a.direction.rawValue, b.direction.rawValue)
            }
    }

    /// Red dot: incoming, pending, not expired, ver > requestSeenVer (F-SOC-04 rule 2).
    func unseen(at serverNow: Int64) -> Int {
        requestList(at: serverNow).filter {
            $0.direction == .incoming && $0.status == .pending && $0.ver > requestSeenVer
        }.count
    }

    /// Relation from local data only (same enum and priority as `userSearch.relation`).
    func relation(of userId: String, me: String, serverNow: Int64) -> Relation {
        if userId == me { return .`self` }
        if isBlocked(userId) { return .blocked }
        if isFriend(userId) { return .friend }
        func pending(_ d: RequestDirection) -> Bool {
            guard let r = requests[RequestKey(userId: userId, direction: d)] else { return false }
            return SocialState.status(of: r, at: serverNow) == .pending
                && r.updatedAt >= serverNow - requestRetentionMs
        }
        if pending(.incoming) { return .pendingIn }
        if pending(.outgoing) { return .pendingOut }
        return .none
    }

    /// Requests past the 30-day window: dropped from local state (PRD-social 10.2).
    func purgeExpiredRequests(at serverNow: Int64) -> [RequestKey] {
        let cutoff = serverNow - requestRetentionMs
        let old = requests.filter { $0.value.updatedAt < cutoff }.map(\.key)
        for k in old { requests[k] = nil }
        return old
    }

    /// Kicked or logged out (F-AUTH-03).
    func clear() {
        ver = 0
        friends = [:]
        requests = [:]
        blocks = [:]
        requestSeenVer = 0
        settings = SocialSettings(searchable: true, mode: .open, strangerMsgLimit: 0)
        official = false
        loaded = false
        needSync = false
        inRound = false
        full = false
        untilVer = 0
        staged = nil
        pendingEv = 0
    }
}

/// Profile cache (F-SOC-10 rule 6): one entry per userId, valid 10 minutes; any server reply with a profile overwrites.
@MainActor
final class ProfileCache {
    static let ttlMs: Int64 = 10 * 60 * 1000
    private var entries: [String: (p: UserProfile, at: Int64)] = [:]
    /// People `users` did not return (invisible or absent): not re-queried while fresh.
    private var misses: [String: Int64] = [:]
    private let now: () -> Int64

    init(now: @escaping () -> Int64) {
        self.now = now
    }

    func put(_ p: UserProfile) {
        entries[p.userId] = (p, now())
        misses[p.userId] = nil
    }

    func markMissing(_ userId: String) {
        misses[userId] = now()
    }

    func needsFetch(_ userId: String) -> Bool {
        if fresh(userId) != nil { return false }
        guard let at = misses[userId] else { return true }
        return now() - at >= ProfileCache.ttlMs
    }

    func putProfile(_ userId: String, _ p: Profile?) {
        guard let p else { return }
        put(UserProfile(userId: userId, nickname: p.nickname, avatar: p.avatar, official: p.official))
    }

    /// Within the TTL only; nil when stale (the caller re-queries).
    func fresh(_ userId: String) -> UserProfile? {
        guard let e = entries[userId], now() - e.at < ProfileCache.ttlMs else { return nil }
        return e.p
    }

    /// The last known profile, stale or not (for display until the new query returns).
    func last(_ userId: String) -> UserProfile? {
        entries[userId]?.p
    }

    func clear() {
        entries = [:]
        misses = [:]
    }
}
