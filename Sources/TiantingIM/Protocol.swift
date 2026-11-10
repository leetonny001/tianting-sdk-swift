import Foundation

// Protocol types (protocol/schema/frame.schema.json v1, PRD-core v1.3). Social types live in Social.swift.

public struct ConvType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let c2c: ConvType = "c2c"
    public static let group: ConvType = "group"
    public static let room: ConvType = "room"
}

public struct MessageType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let text: MessageType = "text"
    public static let custom: MessageType = "custom"
    public static let tip: MessageType = "tip"
    /// C2 (PRD-chat F-FILE-02, 03).
    public static let image: MessageType = "image"
    public static let file: MessageType = "file"
}

public struct GroupRole: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let owner: GroupRole = "owner"
    public static let admin: GroupRole = "admin"
    public static let member: GroupRole = "member"
}

public enum Platform: String, Sendable {
    case android, ios, web, pc
}

/// A deadline that can also be permanent: `mutedUntil` / `kicked.until`, where JSON null means "forever".
public enum Until: Sendable, Hashable, Codable {
    case permanent
    case at(Int64)
}

/// A group tip message (PRD-social F-SOC-29). Empty `actor` means a system action; at most 20 targets, plus `count`.
public struct TipBody: Sendable, Hashable, Codable {
    public var kind: String
    public var actor: String
    public var targets: [String]
    public var count: Int?
    public var text: String

    public init(kind: String, actor: String, targets: [String], count: Int? = nil, text: String = "") {
        self.kind = kind
        self.actor = actor
        self.targets = targets
        self.count = count
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, default: "")
        actor = c.value(.actor, default: "")
        targets = c.value(.targets, default: [])
        count = c.value(.count, default: nil)
        text = c.value(.text, default: "")
    }
}

/// An image message (PRD-chat F-FILE-02). Downstream size, mime and dimensions are the server's recorded values;
/// `expired == true` means the object is gone and no URL is issued. A local message not uploaded yet has an empty fileId.
public struct ImageBody: Sendable, Hashable, Codable {
    public var fileId: String
    public var width: Int?
    public var height: Int?
    public var size: Int64?
    public var mime: String?
    public var expired: Bool?

    public init(
        fileId: String, width: Int? = nil, height: Int? = nil, size: Int64? = nil, mime: String? = nil, expired: Bool? = nil
    ) {
        self.fileId = fileId
        self.width = width
        self.height = height
        self.size = size
        self.mime = mime
        self.expired = expired
    }
}

/// A file message (F-FILE-03). `name` is the cleaned file name, empty after expiry (F-FILE-06 rule 3). Never logged.
public struct FileBody: Sendable, Hashable, Codable {
    public var fileId: String
    public var name: String?
    public var size: Int64?
    public var mime: String?
    public var expired: Bool?

    public init(fileId: String, name: String? = nil, size: Int64? = nil, mime: String? = nil, expired: Bool? = nil) {
        self.fileId = fileId
        self.name = name
        self.size = size
        self.mime = mime
        self.expired = expired
    }
}

/// The state of a quote (PRD-chat F-QUO-02 rule 1): `normal` carries `text`; `recalled`, `deleted` and `expired` carry no
/// original. Values not known here may come later: `quoteLabel` shows them as "引用内容不可用".
public struct QuoteState: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let normal: QuoteState = "normal"
    public static let recalled: QuoteState = "recalled"
    public static let deleted: QuoteState = "deleted"
    public static let expired: QuoteState = "expired"

    /// One of the four states this SDK knows.
    public var isKnown: Bool { self == .normal || self == .recalled || self == .deleted || self == .expired }
}

/// A downstream quote (F-QUO-01 rule 3, F-QUO-02), assembled by the server when it delivers the message. When the quoted
/// message no longer exists, `state == .deleted` without seq, from or type. `text` only for `.normal`: the first 100 code
/// points of a text, "[图片]", or "[文件] {name}". Upstream only the msgId goes (`send(_:_:quote:)`); a local pending message
/// builds the same structure from the loaded original. The quoted text never goes to logs (`description` leaves it out).
public struct QuoteView: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var msgId: String
    public var seq: Int64?
    public var from: String?
    public var type: MessageType?
    public var state: QuoteState
    public var text: String?

    public init(
        msgId: String, seq: Int64? = nil, from: String? = nil, type: MessageType? = nil, state: QuoteState = .normal,
        text: String? = nil
    ) {
        self.msgId = msgId
        self.seq = seq
        self.from = from
        self.type = type
        self.state = state
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case msgId, seq, from, type, state, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        msgId = try c.decode(String.self, forKey: .msgId)
        seq = c.value(.seq, default: nil)
        from = c.value(.from, default: nil)
        type = c.value(.type, default: nil)
        state = c.value(.state, default: QuoteState(rawValue: "unknown"))
        text = c.value(.text, default: nil)
    }

    public var description: String { "QuoteView(msgId: \(msgId), seq: \(seq.map(String.init) ?? "nil"), state: \(state.rawValue))" }
    public var debugDescription: String { description }
}

/// Who a text @-mentions (F-MEN-01, 02): group chats and text only. Downstream it is what the server kept after filtering.
/// Nicknames are not here: the "@昵称 " in the text is inserted by the app.
public struct Mentions: Sendable, Hashable, Codable {
    public var userIds: [String]
    public var all: Bool

    public init(userIds: [String] = [], all: Bool = false) {
        self.userIds = userIds
        self.all = all
    }

    private enum CodingKeys: String, CodingKey { case userIds, all }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userIds = c.value(.userIds, default: [])
        all = c.value(.all, default: false)
    }

    /// Ids deduplicated and without empty ones; nil when nothing is left (the schema has no empty mentions).
    var normalized: Mentions? {
        var seen = Set<String>()
        let ids = userIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        return ids.isEmpty && !all ? nil : Mentions(userIds: ids, all: all)
    }
}

/// The quote argument of `send` (PRD-chat 13.1): only the quoted message's msgId.
public struct QuoteRef: Sendable, Hashable {
    public var msgId: String
    public init(msgId: String) { self.msgId = msgId }
}

public struct MsgBody: Sendable, Hashable, Codable {
    public var text: String?
    public var data: JSONValue?
    public var tip: TipBody?
    public var image: ImageBody?
    public var file: FileBody?
    /// A quote (C4).
    public var quote: QuoteView?
    /// Who is @-mentioned (C4).
    public var mentions: Mentions?

    public init(
        text: String? = nil, data: JSONValue? = nil, tip: TipBody? = nil, image: ImageBody? = nil, file: FileBody? = nil,
        quote: QuoteView? = nil, mentions: Mentions? = nil
    ) {
        self.text = text
        self.data = data
        self.tip = tip
        self.image = image
        self.file = file
        self.quote = quote
        self.mentions = mentions
    }

    private enum CodingKeys: String, CodingKey { case text, data, tip, image, file, quote, mentions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
        tip = try c.decodeIfPresent(TipBody.self, forKey: .tip)
        image = try c.decodeIfPresent(ImageBody.self, forKey: .image)
        file = try c.decodeIfPresent(FileBody.self, forKey: .file)
        // A malformed quote or mentions does not lose the message.
        quote = c.value(.quote, default: nil)
        mentions = c.value(.mentions, default: nil)
    }

    public var isEmpty: Bool {
        text == nil && data == nil && tip == nil && image == nil && file == nil && quote == nil && mentions == nil
    }

    /// The image's or file's id; nil for other messages and for attachments not uploaded yet.
    public var fileId: String? {
        let id = image?.fileId ?? file?.fileId
        return id?.isEmpty == false ? id : nil
    }

    /// Whether the image or file expired (F-FILE-06 rule 3).
    public var fileExpired: Bool { image?.expired == true || file?.expired == true }

    /// What goes up in `send`: attachments carry only the fileId; the server fills in the rest (F-FILE-02 rule 1). A
    /// quote carries only its msgId (the schema allows nothing else upstream).
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let text { o["text"] = .string(text) }
        if let data { o["data"] = data }
        if let image { o["image"] = ["fileId": .string(image.fileId)] }
        if let file { o["file"] = ["fileId": .string(file.fileId)] }
        if let quote { o["quote"] = ["msgId": .string(quote.msgId)] }
        if let mentions {
            var m: [String: JSONValue] = [:]
            if !mentions.userIds.isEmpty { m["userIds"] = .array(mentions.userIds.map { .string($0) }) }
            if mentions.all { m["all"] = true }
            o["mentions"] = .object(m)
        }
        return .object(o)
    }
}

/// One message from the server (`msg` frame, `sync` result).
struct ServerMessage: Sendable, Decodable {
    var msgId: String
    var clientMsgId: String
    var convId: String
    var seq: Int64
    var from: String
    var type: MessageType
    /// Deleted messages have no body (PRD-core F-MSG-05 rule 7).
    var body: MsgBody?
    var ts: Int64
    /// No body: deleted by the console, or recalled (then `recalled` is true too, PRD-chat F-RCL-01 rule 5a).
    var deleted: Bool?
    var deletedAt: Int64?
    /// Recalled (C4): only present when true, together with `deleted` and no body.
    var recalled: Bool? = nil
    var recalledAt: Int64? = nil
    /// Who recalled it: the sender, or a group owner or admin.
    var recalledBy: String? = nil
}

public struct LastMsg: Sendable, Hashable, Codable {
    public var msgId: String
    public var from: String
    public var type: String
    /// Absent when the last message was deleted (`deleted == true`).
    public var text: String?
    public var ts: Int64
    public var deleted: Bool?
    /// Recalled (C4, F-RCL-03 rule 4): then `deleted` is true too, and `recalledBy` says who.
    public var recalled: Bool?
    public var recalledBy: String?

    public init(
        msgId: String, from: String, type: String, text: String? = nil, ts: Int64, deleted: Bool? = nil,
        recalled: Bool? = nil, recalledBy: String? = nil
    ) {
        self.msgId = msgId
        self.from = from
        self.type = type
        self.text = text
        self.ts = ts
        self.deleted = deleted
        self.recalled = recalled
        self.recalledBy = recalledBy
    }
}

/// One `convs` item, or the payload of `convAdded`.
struct ServerConversation: Sendable, Decodable {
    var convId: String
    var type: ConvType
    var name: String
    var maxSeq: Int64
    var readSeq: Int64
    var minSeq: Int64
    var unread: Int64
    var lastMsg: LastMsg?
    var updatedAt: Int64
    var memberCount: Int?
    var myRole: GroupRole?
    /// Only present while I am muted in that group; `.permanent` for JSON null.
    var mutedUntil: Until?
    /// Only present while the group has a group-wide mute (P1, F-ADM-42); owners and admins get it too but are not restricted.
    var allMuted: Bool
    /// The version of how existing messages look (C2: file expiry); a change re-syncs this conversation (F-RCL-03
    /// rule 2). Older servers do not send it.
    var modVer: Int64?
    /// Unread messages mentioning me, @all included (F-MEN-03 rule 1, C4). Absent when the feature is off or on older servers.
    var mentionUnread: Int64?
    /// The first unread seq mentioning me; absent when `mentionUnread == 0`.
    var firstMentionSeq: Int64?
    /// Pinned (PRD-chat F-CVS-01, C5); absent when not pinned and on older servers.
    var pinned: Bool?
    /// When it was pinned, only with `pinned == true`: pinned conversations sort by it, newest first (rule 3).
    var pinnedAt: Int64?
    /// Notifications off (F-CVS-02, C5): no push, unread still counts. Not `muted` (that is a mute in a group).
    var notifyOff: Bool?

    private enum CodingKeys: String, CodingKey {
        case convId, type, name, maxSeq, readSeq, minSeq, unread, lastMsg, updatedAt, memberCount, myRole, mutedUntil, allMuted,
            modVer, mentionUnread, firstMentionSeq, pinned, pinnedAt, notifyOff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convId = try c.decode(String.self, forKey: .convId)
        type = try c.decode(ConvType.self, forKey: .type)
        name = c.value(.name, default: "")
        maxSeq = try c.decode(Int64.self, forKey: .maxSeq)
        readSeq = c.value(.readSeq, default: 0)
        minSeq = c.value(.minSeq, default: 1)
        unread = c.value(.unread, default: 0)
        lastMsg = try c.decodeIfPresent(LastMsg.self, forKey: .lastMsg)
        updatedAt = c.value(.updatedAt, default: 0)
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount)
        myRole = try c.decodeIfPresent(GroupRole.self, forKey: .myRole)
        mutedUntil = try c.decodeUntil(forKey: .mutedUntil)
        allMuted = c.value(.allMuted, default: false)
        modVer = try? c.decodeIfPresent(Int64.self, forKey: .modVer)
        mentionUnread = try? c.decodeIfPresent(Int64.self, forKey: .mentionUnread)
        firstMentionSeq = try? c.decodeIfPresent(Int64.self, forKey: .firstMentionSeq)
        pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
        pinnedAt = pinned == true ? (try? c.decodeIfPresent(Int64.self, forKey: .pinnedAt)) : nil
        notifyOff = try? c.decodeIfPresent(Bool.self, forKey: .notifyOff)
    }
}

/// One `convs.deleted` item (F-CVS-03 rule 6, C5): a conversation I deleted that has had no new message since.
struct DeletedConv: Sendable, Decodable, Hashable {
    var convId: String
    var clearedSeq: Int64
}

/// The `convSet` ack (C5): the whole conversation after the change.
struct ConvSetAck: Sendable, Decodable {
    var conv: ServerConversation
}

/// The `convDelete` ack (C5): min(upToSeq, maxSeq), never below an earlier value.
struct ConvDeleteAck: Sendable, Decodable {
    var clearedSeq: Int64
}

struct SendAck: Sendable, Decodable {
    var msgId: String
    var convId: String
    var seq: Int64
    var ts: Int64
}

struct SyncAck: Sendable, Decodable {
    var messages: [ServerMessage]
    var hasMore: Bool
}

struct ConvsAck: Sendable, Decodable {
    var convs: [ServerConversation]
    var truncated: Bool
    /// Conversations I deleted with no new message since (C5): a group missing from `convs` but here is not "removed".
    /// Older servers do not send it.
    var deleted: [DeletedConv] = []
    /// `deleted` was cut at its limit (C5): like `truncated`, no "removed" inference then (frontend-chat 54).
    var deletedTruncated = false

    private enum CodingKeys: String, CodingKey { case convs, truncated, deleted, deletedTruncated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convs = try c.decode([ServerConversation].self, forKey: .convs)
        truncated = c.value(.truncated, default: false)
        deleted = c.value(.deleted, default: [])
        deletedTruncated = c.value(.deletedTruncated, default: false)
    }
}

struct AuthAck: Sendable, Decodable {
    var userId: String
    var serverTime: Int64
    var mutedUntil: Until?
    var recoveryCodeUnacked: Bool

    private enum CodingKeys: String, CodingKey { case userId, serverTime, mutedUntil, recoveryCodeUnacked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        serverTime = try c.decode(Int64.self, forKey: .serverTime)
        mutedUntil = try c.decodeUntil(forKey: .mutedUntil)
        recoveryCodeUnacked = c.value(.recoveryCodeUnacked, default: false)
    }
}

/// `error` of an ack frame.
struct FrameError: Sendable, Decodable {
    var code: Int
    var msg: String?
    var userId: String?
    /// Splits one code (4040 `quoteUnavailable`, 4030 `mentionAllForbidden`; errors.json `reasons`).
    var reason: String?
    var details: [String: JSONValue]?
}

/// A downstream frame that is not an ack: keeps the raw bytes so each consumer decodes only what it needs.
struct InboundFrame: Sendable {
    var cmd: String
    var eventType: String?
    var raw: Data
}

/// Decodes `{"data": T}` out of a raw frame.
func decodeFrameData<T: Decodable>(_ type: T.Type, from raw: Data) throws -> T {
    try JSONCoding.decoder.decode(FrameEnvelope<T>.self, from: raw).data
}

private struct FrameEnvelope<T: Decodable>: Decodable {
    var data: T
}

// MARK: - Conversation ids

/// A c2c conversation id: `c2c:{smaller userId}:{larger userId}`, compared by ASCII bytes (same as the server).
public func c2cConvId(_ a: String, _ b: String) -> String {
    bytesLess(a, b) ? "c2c:\(a):\(b)" : "c2c:\(b):\(a)"
}

public func groupConvId(_ groupId: String) -> String {
    "group:\(groupId)"
}

func bytesLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// A conversation id that is malformed (`invalid`), or well-formed without me as a participant (`notParticipant`).
public struct ConvIdError: Error, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case invalid, notParticipant
    }
    public let kind: Kind
    public let convId: String
}

public struct ParsedConvId: Sendable, Equatable {
    public let convType: ConvType
    public let to: String
}

private func isValidId(_ s: Substring) -> Bool {
    let n = s.utf8.count
    guard n >= 1, n <= 64 else { return false }
    return s.utf8.allSatisfy { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }
}

/// Strict parsing for routing (PRD-ui G-UI-03, vectors/convid.json). Two equal ids are only valid when both are `me`.
public func parseConvIdStrict(_ convId: String, me: String) throws -> ParsedConvId {
    let parts = convId.split(separator: ":", omittingEmptySubsequences: false)
    if parts.first == "c2c", parts.count == 3 {
        let (a, b) = (parts[1], parts[2])
        guard isValidId(a), isValidId(b), !b.utf8.lexicographicallyPrecedes(a.utf8) else {
            throw ConvIdError(kind: .invalid, convId: convId)
        }
        guard a == me || b == me else { throw ConvIdError(kind: .notParticipant, convId: convId) }
        return ParsedConvId(convType: .c2c, to: String(a == me ? b : a))
    }
    if parts.first == "group", parts.count == 2, isValidId(parts[1]) {
        return ParsedConvId(convType: .group, to: String(parts[1]))
    }
    throw ConvIdError(kind: .invalid, convId: convId)
}

/// The other party of a c2c conversation; nil for groups.
public func peerId(convId: String, type: ConvType, me: String) -> String? {
    guard type == .c2c else { return nil }
    let parts = convId.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    return String(parts[1] == me ? parts[2] : parts[1])
}

/// SDK-internal parsing for building `send`: does not check participants. Routing must use `parseConvIdStrict`.
func parseConvId(_ convId: String, me: String) throws -> ParsedConvId {
    let parts = convId.split(separator: ":", omittingEmptySubsequences: false)
    switch parts.first {
    case "c2c" where parts.count == 3:
        return ParsedConvId(convType: .c2c, to: String(parts[1] == me ? parts[2] : parts[1]))
    case "group" where parts.count == 2, "room" where parts.count == 2:
        return ParsedConvId(convType: ConvType(rawValue: String(parts[0])), to: String(parts[1]))
    default:
        throw ConvIdError(kind: .invalid, convId: convId)
    }
}
