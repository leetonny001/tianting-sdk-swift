import Foundation

// Reporting (FE-692; PRD-chat C6: F-MOD-03, 13.1). Same rules as sdk-ts FE-690 (tianting-sdk-ts@d5fb273) and
// sdk-kotlin FE-691: the parameters are checked here before any frame goes out.

/// What is reported (F-MOD-03 rule 1).
public struct ReportTargetType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let message: ReportTargetType = "message"
    public static let user: ReportTargetType = "user"
    public static let group: ReportTargetType = "group"
}

/// Why (F-MOD-03 rule 1). UI copy (frontend-chat 78): 垃圾广告 spam, 辱骂骚扰 abuse, 色情低俗 porn, 诈骗 fraud,
/// 违法违规 illegal, 其他 other; nothing preselected.
public struct ReportReason: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let spam: ReportReason = "spam"
    public static let abuse: ReportReason = "abuse"
    public static let porn: ReportReason = "porn"
    public static let fraud: ReportReason = "fraud"
    public static let illegal: ReportReason = "illegal"
    public static let other: ReportReason = "other"
    /// The six the server accepts, in UI order.
    public static let all: [ReportReason] = [.spam, .abuse, .porn, .fraud, .illegal, .other]
}

/// `note` is at most 200 code points, counted like the server (frontend-chat 84).
public let reportNoteMax = 200
/// At most 20 messages at once (the protocol's limit; the first apps report one, frontend-chat 85).
public let reportMsgMax = 20

/// The `report` parameters, the same fields as the command. Exclusive by `targetType`: `message` carries `convId` (c2c
/// or group) and `msgIds` of that conversation, `user` carries `userId`, `group` carries `groupId`. The static builders
/// make the valid shapes; the memberwise initializer exists for whatever the app assembles itself.
public struct ReportInput: Sendable, Equatable {
    public var targetType: ReportTargetType
    public var convId: String?
    public var msgIds: [String]?
    public var userId: String?
    public var groupId: String?
    public var reason: ReportReason
    /// Treated like message text: never logged, never in an error.
    public var note: String?

    public init(
        targetType: ReportTargetType, convId: String? = nil, msgIds: [String]? = nil, userId: String? = nil,
        groupId: String? = nil, reason: ReportReason, note: String? = nil
    ) {
        self.targetType = targetType
        self.convId = convId
        self.msgIds = msgIds
        self.userId = userId
        self.groupId = groupId
        self.reason = reason
        self.note = note
    }

    public static func message(
        convId: String, msgIds: [String], reason: ReportReason, note: String? = nil
    ) -> ReportInput {
        ReportInput(targetType: .message, convId: convId, msgIds: msgIds, reason: reason, note: note)
    }

    public static func user(_ userId: String, reason: ReportReason, note: String? = nil) -> ReportInput {
        ReportInput(targetType: .user, userId: userId, reason: reason, note: note)
    }

    public static func group(_ groupId: String, reason: ReportReason, note: String? = nil) -> ReportInput {
        ReportInput(targetType: .group, groupId: groupId, reason: reason, note: note)
    }
}

/// The `report` ack (C6): a repeat within 24 hours returns the first reportId.
struct ReportAck: Sendable, Decodable {
    var reportId: String
}

/// A local check failed: 4000 with `details.field` naming the field. The message never carries a value (nor the note).
private func badReport(_ field: String) -> IMError {
    IMError(code: ErrorCode.badRequest, message: "invalid report \(field)", details: ["field": .string(field)])
}

/// userId, groupId, msgId: frame.schema.json's id charset, 1 to 64 bytes.
func isValidReportId(_ s: String) -> Bool {
    let n = s.utf8.count
    guard n >= 1, n <= 64 else { return false }
    return s.utf8.allSatisfy { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }
}

/// Checks the input and builds the command's data. A field of another target type is 4000 (`targetType`), even when
/// empty. Before the user is known (`me` empty) only the format is checked; participation is the server's to judge.
func reportRequest(_ input: ReportInput, me: String) throws -> JSONValue {
    guard ReportReason.all.contains(input.reason) else { throw badReport("reason") }
    if let note = input.note, countCodePoints(note) > reportNoteMax { throw badReport("note") }
    var out: [String: JSONValue] = [
        "targetType": .string(input.targetType.rawValue), "reason": .string(input.reason.rawValue),
    ]
    switch input.targetType {
    case .message:
        if input.userId != nil || input.groupId != nil { throw badReport("targetType") }
        guard let convId = input.convId else { throw badReport("convId") }
        let who =
            me.isEmpty
            ? String(convId.split(separator: ":", omittingEmptySubsequences: false).dropFirst().first ?? "") : me
        do {
            _ = try parseConvIdStrict(convId, me: who)  // c2c or group only; c2c must include me
        } catch is ConvIdError {
            throw badReport("convId")
        }
        guard let ids = input.msgIds, (1...reportMsgMax).contains(ids.count), ids.allSatisfy(isValidReportId) else {
            throw badReport("msgIds")
        }
        out["convId"] = .string(convId)
        out["msgIds"] = .array(ids.map { .string($0) })
    case .user:
        if input.convId != nil || input.msgIds != nil || input.groupId != nil { throw badReport("targetType") }
        guard let userId = input.userId, isValidReportId(userId) else { throw badReport("userId") }
        out["userId"] = .string(userId)
    case .group:
        if input.convId != nil || input.msgIds != nil || input.userId != nil { throw badReport("targetType") }
        guard let groupId = input.groupId, isValidReportId(groupId) else { throw badReport("groupId") }
        out["groupId"] = .string(groupId)
    default:
        throw badReport("targetType")
    }
    if let note = input.note { out["note"] = .string(note) }
    return .object(out)
}

extension IMClient {
    /// Reports a message, a user or a group (F-MOD-03, 13.1, C6) and returns the reportId. The parameters are checked
    /// here first (exclusive fields by `targetType`, one of the six reasons, 1 to 20 well-formed msgIds, a note of at
    /// most 200 code points, no chat rooms, a c2c conversation that includes me): otherwise `IMError` 4000 with
    /// `details["field"]`, and no frame. Server errors are thrown as they are and never retried: 4292 (今天的举报次数已用完),
    /// 4040 `reportTargetInvalid` (无法举报该内容), 4030 `featureDisabled` (举报功能暂不可用), 4290, 5000, a timeout,
    /// offline (`IMConnectionError`). Copy: `messageFor(cmd: "report", code:)`. Neither side gets a frame about it.
    /// Whether the entries show is `AccountConfig.Features.moderation`; the first apps report one message (R-CF-21),
    /// the interface keeps the array. The note is treated like message text: never logged, never in an error.
    public func report(_ input: ReportInput) async throws -> String {
        let data = try reportRequest(input, me: me)
        let ack = try await conn.request(ReportAck.self, "report", data)
        return ack.reportId
    }

    /// Whether a message's menu offers "举报" (frontend-chat 77, 88; the same rule in the three SDKs, the apps only call
    /// this): someone else's `text`, `image` or `file` that was sent (has a msgId) in a c2c or group conversation I am in.
    /// Not my own, not `tip` or `custom`, not sending, queued or failed, not one deleted by the admin. A recalled one
    /// (its recall notice row, F-MOD-03 rule 2a) only when someone else sent it and I did not recall it (an unknown
    /// recaller counts as someone else); my own message recalled by someone else has none. Only what this device has
    /// read: `seq ≤ readSeq` of the conversation in the local list (the server checks `readSeq ≥ seq`); a conversation
    /// not in the list has none (frontend-chat 92). Whether the feature is on (`Features.moderation`) is the app's to
    /// check as well.
    public func canReport(_ m: Message) -> Bool {
        // The conversation must be in the local list: that also rules out chat rooms, c2c ids that are not mine, and
        // everything before the user is known (the list is empty until then).
        guard m.from != me, !m.from.isEmpty, m.status == .sent, let id = m.msgId, isValidReportId(id),
            m.type == .text || m.type == .image || m.type == .file,
            let seq = m.seq, let conv = store.conversation(m.convId), seq <= conv.readSeq
        else { return false }
        if m.isRecalled { return m.recalledBy != me }
        return !m.isDeleted
    }
}
