import Foundation

// Recall notices, quote summaries and labels (PRD-chat F-RCL-02 rule 1a, F-QUO-01, F-QUO-02 rules 2, 3). Pure functions
// shared by pages and IMClient; same semantics as sdk-ts src/recall.ts and sdk-kotlin Recall.kt.

private let quoteLength = 100

/// What a recall notice depends on (F-RCL-02 rule 1a). The chat line and the list summary use the same one (AC-RCL-02-4,
/// 03-6, 03-10). `operatorId` did the recall (`recalledBy`; without it, older data, the sender did); `sender` sent the
/// recalled message.
public struct RecallNotice: Sendable, Hashable {
    public let convType: ConvType
    public let operatorId: String
    public let sender: String
    /// I did the recall.
    public let byMe: Bool
    /// The recalled message is mine.
    public let ofMe: Bool
    /// The sender recalled their own (not an owner or admin recalling someone else's).
    public let own: Bool
}

private func notice(convId: String, from: String, recalledBy: String?, me: String) -> RecallNotice {
    let op = recalledBy.flatMap { $0.isEmpty ? nil : $0 } ?? from
    return RecallNotice(
        convType: convId.hasPrefix("group:") ? .group : .c2c, operatorId: op, sender: from, byMe: op == me,
        ofMe: from == me, own: op == from)
}

/// A message's recall notice data; nil when it is not a recall (a console deletion included).
public func recallNotice(convId: String, message m: Message, me: String) -> RecallNotice? {
    m.recalled == true ? notice(convId: convId, from: m.from, recalledBy: m.recalledBy, me: me) : nil
}

/// A conversation summary's (lastMsg) recall notice data; nil when it is not a recall.
public func recallNotice(convId: String, lastMsg l: LastMsg, me: String) -> RecallNotice? {
    l.recalled == true ? notice(convId: convId, from: l.from, recalledBy: l.recalledBy, me: me) : nil
}

/// The table of F-RCL-02 rule 1a:
/// c2c, own recall: 你撤回了一条消息 / 对方撤回了一条消息; group, own recall: 你撤回了一条消息 / {操作者}撤回了一条消息;
/// an owner or admin recalling someone else's: 你撤回了 {被撤回者} 的一条消息 / {操作者}撤回了你的一条消息 /
/// {操作者}撤回了一条成员消息. `nameOf` is the app's display-name rule (problem 19: remarks are local only).
public func recallText(_ n: RecallNotice, nameOf: (String) -> String) -> String {
    if n.byMe { return n.own ? "你撤回了一条消息" : "你撤回了 \(nameOf(n.sender)) 的一条消息" }
    if n.convType == .c2c { return "对方撤回了一条消息" }
    if n.own { return "\(nameOf(n.operatorId))撤回了一条消息" }
    if n.ofMe { return "\(nameOf(n.operatorId))撤回了你的一条消息" }
    return "\(nameOf(n.operatorId))撤回了一条成员消息"
}

/// A quote summary (F-QUO-02 rule 2, the server's rule): a text's first 100 code points (a message with a quote gives
/// only its own text, F-QUO-01 rule 4); an image "[图片]"; a file "[文件] {name}".
public func quoteSummary(_ m: Message) -> String {
    switch m.type {
    case .image: return "[图片]"
    case .file: return "[文件] \(m.body.file?.name ?? "")"
    default:
        let scalars = (m.body.text ?? "").unicodeScalars
        return String(String.UnicodeScalarView(scalars.prefix(quoteLength)))
    }
}

/// What a quote bar shows (F-QUO-02 rule 3): `.normal` the summary; `.recalled` "引用内容已被撤回"; `.deleted`
/// "引用内容已被删除"; `.expired` "[图片] 已过期" or "[文件] 已过期" (problem 22); an unknown state "引用内容不可用". Render it as
/// plain text (AC-QUO-02-5).
public func quoteLabel(_ q: QuoteView) -> String {
    switch q.state {
    case .normal: return q.text ?? ""
    case .recalled: return "引用内容已被撤回"
    case .deleted: return "引用内容已被删除"
    case .expired: return "\(q.type == .image ? "[图片]" : "[文件]") 已过期"
    default: return "引用内容不可用"
    }
}

/// The message menu items the SDK decides (F-UI-09 extended, PRD-chat 13.3). Report comes with C6; resend and delete of
/// failed messages follow `status` on the page.
public enum MessageAction: String, Sendable, Hashable {
    case copy, quote, recall
}

/// Recall time limits (the defaults of F-RCL-01 rule 1, F-RCL-02 rule 2). The server can be configured otherwise; then its
/// 4097 decides (problem 25).
public let recallWindowMs: Int64 = 120_000
public let groupRecallWindowMs: Int64 = 7 * 86_400_000
