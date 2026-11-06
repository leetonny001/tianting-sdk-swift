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

public struct MsgBody: Sendable, Hashable, Codable {
    public var text: String?
    public var data: JSONValue?
    public var tip: TipBody?

    public init(text: String? = nil, data: JSONValue? = nil, tip: TipBody? = nil) {
        self.text = text
        self.data = data
        self.tip = tip
    }

    public var isEmpty: Bool { text == nil && data == nil && tip == nil }

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let text { o["text"] = .string(text) }
        if let data { o["data"] = data }
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
    var deleted: Bool?
    var deletedAt: Int64?
}

public struct LastMsg: Sendable, Hashable, Codable {
    public var msgId: String
    public var from: String
    public var type: String
    /// Absent when the last message was deleted (`deleted == true`).
    public var text: String?
    public var ts: Int64
    public var deleted: Bool?

    public init(msgId: String, from: String, type: String, text: String? = nil, ts: Int64, deleted: Bool? = nil) {
        self.msgId = msgId
        self.from = from
        self.type = type
        self.text = text
        self.ts = ts
        self.deleted = deleted
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

    private enum CodingKeys: String, CodingKey {
        case convId, type, name, maxSeq, readSeq, minSeq, unread, lastMsg, updatedAt, memberCount, myRole, mutedUntil, allMuted
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
    }
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

    private enum CodingKeys: String, CodingKey { case convs, truncated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convs = try c.decode([ServerConversation].self, forKey: .convs)
        truncated = c.value(.truncated, default: false)
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
