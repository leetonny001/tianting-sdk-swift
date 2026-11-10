import Foundation

public enum ErrorCategory: String, Sendable {
    case badRequest, forbidden, notFound, rateLimited, server
}

public struct ErrorDescription: Sendable, Equatable {
    public let code: Int
    /// The name in errors.json; "UNKNOWN" for codes this SDK does not know.
    public let name: String
    public let category: ErrorCategory
    public let retryable: Bool
}

/// Describes an error code. Unknown codes fall back on their prefix (C-09): 403x forbidden, 404x not found,
/// 429x rate limited, other 4xxx bad request (none retryable); 5xxx server errors (retryable).
public func describeError(_ code: Int) -> ErrorDescription {
    let known = errorInfoTable[code]
    let prefix = code / 10
    let category: ErrorCategory
    switch prefix {
    case 403: category = .forbidden
    case 404: category = .notFound
    case 429: category = .rateLimited
    default: category = code >= 5000 ? .server : .badRequest
    }
    return ErrorDescription(
        code: code,
        name: known?.name ?? "UNKNOWN",
        category: category,
        retryable: known?.retryable ?? (code >= 5000)
    )
}

/// An error returned by the server (`ack.error`).
public struct IMError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    /// Which person caused a group failure (`error.userId`, or `details.userId`: PRD-core D-1 is undecided).
    public let userId: String?
    /// `error.details` as sent, e.g. 4031's `{scope, groupId?, mutedUntil}`.
    public let details: [String: JSONValue]?
    /// Splits one code: 4040's `quoteUnavailable`, 4030's `mentionAllForbidden` (errors.json `reasons`).
    public let reason: String?

    public init(
        code: Int, message: String = "", userId: String? = nil, details: [String: JSONValue]? = nil, reason: String? = nil
    ) {
        self.code = code
        self.message = message
        self.userId = userId
        self.details = details
        self.reason = reason
    }

    public var errorDescription: ErrorDescription { describeError(code) }
}

/// A request that never got a usable ack.
public enum IMConnectionError: Error, Sendable, Equatable {
    /// No ack in time; it may still arrive later.
    case timeout(cmd: String)
    /// The connection dropped after sending, before the ack.
    case closed
    /// No authenticated connection.
    case notConnected
    /// The ack could not be decoded (a protocol mismatch).
    case badResponse(cmd: String)
}

/// "Command + error code" copy (PRD-social 9.4, ERRORS.md section 2; vectors/social.json `copy`).
/// Lists only command-specific codes; returns nil for the rest, whose default copy belongs to the UI.
/// `strangerMsgLimit` fills 4137's {N}; `name` fills {name} of group failures. `windowSeconds` is `recall` 4097's
/// `details.windowSeconds` (PRD-chat 11.5): 120 gives "2 分钟", 604800 "7 天"; nil means 120.
public func messageFor(
    cmd: String, code: Int, strangerMsgLimit: Int = 0, name: String = "", windowSeconds: Int64? = nil
) -> String? {
    if cmd == "recall", code == ErrorCode.recallWindowExpired {
        return "发送时间超过 \(windowText(windowSeconds ?? 120))，无法撤回"
    }
    guard let template = copyTable["\(cmd):\(code)"] ?? copyTable["*:\(code)"] else { return nil }
    return template
        .replacingOccurrences(of: "{N}", with: String(strangerMsgLimit))
        .replacingOccurrences(of: "{name}", with: name)
}

private func windowText(_ sec: Int64) -> String {
    if sec >= 86_400, sec % 86_400 == 0 { return "\(sec / 86_400) 天" }
    if sec >= 60, sec % 60 == 0 { return "\(sec / 60) 分钟" }
    return "\(sec) 秒"
}

private let dailyQuota = "今天的次数已用完，明天再试"
private let copyTable: [String: String] = [
    "send:4290": "发送太频繁，请稍后再试",
    "*:4290": "操作太频繁，请稍后再试",
    "send:4035": "对方开启了好友验证，你还不是他的好友",
    "send:4036": "消息已发出，但被对方拒收了",
    "send:4137": "对方回复之前，最多只能发送 {N} 条消息",
    "send:4292": "今天发起新聊天的次数已用完，请稍后再试",
    "send:4293": "@所有人次数已用完",
    "recall:4030": "你没有权限撤回这条消息",
    "friendApply:4132": "你的好友数量已达上限",
    "friendRespond:4132": "你的好友数量已达上限",
    "friendRespond:4133": "对方好友数量已达上限",
    "friendApply:4133": "对方好友数量已达上限",
    "friendRespond:4045": "该申请已过期",
    "block:4134": "黑名单已满",
    "friendApply:4292": dailyQuota,
    "userSearch:4292": dailyQuota,
    "block:4292": dailyQuota,
    "unblock:4292": dailyQuota,
    "groupCreate:4035": "{name} 不是你的好友，无法邀请",
    "groupInvite:4035": "{name} 不是你的好友，无法邀请",
    "groupCreate:4135": "{name} 加入的群聊已达上限",
    "groupInvite:4135": "{name} 加入的群聊已达上限",
    "groupCreate:4030": "当前不允许创建群聊",
    "groupCreate:4292": dailyQuota,
    "groupTransfer:4046": "对方已不在群里",
    "groupSetAdmin:4046": "对方已不在群里",
    "groupSetAdmin:4136": "管理员最多 10 人",
]
