import Foundation

/// The mention-count refresh throttle (F-MEN-03 rule 1, uncalibrated): convs at most once per 5 seconds; events inside the
/// window are fetched once when it ends.
let mentionRefreshMs: Int64 = 5_000

/// One running download: the transfer task and why it was stopped, if it was.
@MainActor
final class DownloadHandle {
    var task: Task<Int, Error>?
    /// Set when a recall (true) or a deletion or expiry (false) stopped it.
    var abortedRecalled: Bool?
}

// Recall, quotes and mentions (FE-663, FE-664; PRD-chat F-RCL-01..03, F-QUO-01, 02, F-MEN-01..03, 13.1).
extension IMClient {
    // MARK: Recall

    /// Recalls a message (PRD-chat F-RCL-01, 02, 13.1). On success it is a recall here at once: text, quoted copies of it,
    /// the local database and the file cache are cleared (the server sends no `msgDeleted` to the connection that
    /// recalled, only the ack, problem 27); `recalledAt` is estimated from server time until the next re-sync. Errors are
    /// thrown as `IMError`, never retried (problem 26): 4097 carries `details.windowSeconds`
    /// (`messageFor(cmd: "recall", code: 4097, windowSeconds:)`), 4030 is "你没有权限撤回这条消息" (AC-RCL-02-5), 4044 means
    /// gone or deleted by the console. Recalling twice succeeds (idempotent). Throws `IMConnectionError.notConnected`
    /// before the user is known or while offline, `.timeout` without an ack.
    public func recall(_ convId: String, _ msgId: String) async throws {
        guard !me.isEmpty else { throw IMConnectionError.notConnected }
        _ = try await conn.requestRaw("recall", ["convId": .string(convId), "msgId": .string(msgId)])
        let seq = store.existingList(convId)?.find(msgId: msgId)?.seq
        applyDeleted(convId, msgIds: [msgId], seqs: seq.map { [$0] } ?? [], recall: RecallInfo(by: me, at: serverNow()))
    }

    /// Whether this message can be recalled now ("撤回" in the menu, AC-RCL-01-8): by its `ts` against server time as
    /// corrected by the auth ack, never the device clock. My own within 2 minutes; an owner's or admin's own takes the
    /// wider 7 days; an owner anyone's within 7 days; an admin others' within 7 days (the server answers 4030 when they are
    /// an admin or the owner, which this side does not know, F-RCL-02 rule 1b). Only sent text, image and file messages;
    /// never recalled or deleted ones or tips. Without `myRole` the role from the conversation list is used.
    public func canRecall(_ m: Message, myRole: GroupRole? = nil) -> Bool {
        guard m.status == .sent, m.msgId != nil, m.deleted != true else { return false }
        guard m.type == .text || m.type == .image || m.type == .file else { return false }
        let group = m.convId.hasPrefix("group:")
        let role = group ? (myRole ?? store.conversation(m.convId)?.myRole) : nil
        let manager = role == .owner || role == .admin
        let window: Int64
        if m.from == me {
            window = manager ? max(recallWindowMs, groupRecallWindowMs) : recallWindowMs
        } else if group, manager {
            window = groupRecallWindowMs
        } else {
            return false
        }
        return serverNow() - m.ts <= window
    }

    /// The long-press menu items the SDK decides (F-RCL-03 rule 6): recalled and deleted messages and tips have none (an
    /// empty list, AC-RCL-03-10). Copy is text only; quote needs a sent text, image or file (F-QUO-01 rule 5); recall
    /// follows `canRecall`. With `msgActions` off (`GET /v1/config` features) the page keeps only "复制".
    public func messageActions(_ m: Message, myRole: GroupRole? = nil) -> [MessageAction] {
        if m.deleted == true || m.type == .tip { return [] }
        var out: [MessageAction] = []
        if m.type == .text { out.append(.copy) }
        if m.status == .sent, m.msgId != nil, m.type == .text || m.type == .image || m.type == .file { out.append(.quote) }
        if canRecall(m, myRole: myRole) { out.append(.recall) }
        return out
    }

    /// The recall notice data (F-RCL-02 rule 1a, one table for the chat page and the list summary): c2c or group, whether I
    /// recalled it, whether it was mine. nil when it is not a recall (a console deletion shows "该消息已被删除").
    public func recallNotice(_ m: Message) -> RecallNotice? {
        TiantingIM.recallNotice(convId: m.convId, message: m, me: me)
    }

    /// The same for a conversation summary (lastMsg).
    public func recallNotice(convId: String, lastMsg: LastMsg) -> RecallNotice? {
        TiantingIM.recallNotice(convId: convId, lastMsg: lastMsg, me: me)
    }

    /// The recall notice text (the table of F-RCL-02 rule 1a), names by `displayName` (remarks are local, problem 19).
    /// nil when it is not a recall.
    public func recallText(_ m: Message) -> String? {
        recallNotice(m).map { TiantingIM.recallText($0) { self.displayName($0) } }
    }

    public func recallText(convId: String, lastMsg: LastMsg) -> String? {
        recallNotice(convId: convId, lastMsg: lastMsg).map { TiantingIM.recallText($0) { self.displayName($0) } }
    }

    /// The quote bar of a pending message: the loaded original summarized as the server does (F-QUO-02 rule 2), or only
    /// the msgId when it is not loaded.
    func localQuote(_ convId: String, _ msgId: String) -> QuoteView {
        guard let m = store.existingList(convId)?.find(msgId: msgId) else { return QuoteView(msgId: msgId, state: .normal) }
        var q = QuoteView(msgId: msgId, seq: m.seq, from: m.from, type: m.type, state: .normal)
        if m.deleted == true {
            q.state = m.recalled == true ? .recalled : .deleted
        } else {
            q.text = quoteSummary(m)
        }
        return q
    }

    // MARK: Mentions

    /// Searches group members (the @ picker, PRD-chat F-MEN-01 rule 6): `keyword` is a userId prefix (case-sensitive) or a
    /// nickname prefix (ASCII case-insensitive); empty means no search. 30 per minute per user (4290), never retried: the
    /// `IMError` goes to the page. Profiles enter the cache.
    public func searchGroupMembers(_ groupId: String, keyword: String, cursor: String? = nil) async throws
        -> GroupMembersPage
    {
        var data: [String: JSONValue] = ["groupId": .string(groupId)]
        if !keyword.isEmpty { data["keyword"] = .string(keyword) }
        if let cursor, !cursor.isEmpty { data["cursor"] = .string(cursor) }
        let page = try await conn.request(GroupMembersPage.self, "groupMembers", .object(data))
        for m in page.members {
            profiles.put(UserProfile(userId: m.userId, nickname: m.nickname, avatar: m.avatar, official: m.official))
        }
        return page
    }

    func hasMentions(_ convId: String) -> Bool {
        (store.conversation(convId)?.mentionUnread ?? 0) > 0
    }

    /// A group message mentioning me or everyone (not my own, F-MEN-03 rule 6).
    func mentionsMe(_ m: ServerMessage) -> Bool {
        guard let men = m.body?.mentions, m.deleted != true, m.from != me, m.convId.hasPrefix("group:") else { return false }
        return men.all || men.userIds.contains(me)
    }

    /// Fetches convs again for the mention counts, throttled (F-MEN-03 rule 1, R-CF-18): outside the window at once;
    /// inside it once, when the window ends (5 seconds after the last fetch).
    func refreshMentions() {
        guard mentionTimer == nil else { return }
        let wait = mentionFetchAt + mentionRefreshMs - clock.now()
        if wait <= 0 {
            fetchMentions()
            return
        }
        mentionTimer = clock.setTimeout(wait) { [weak self] in
            guard let self else { return }
            self.mentionTimer = nil
            self.fetchMentions()
        }
    }

    private func fetchMentions() {
        guard conn.state == .connected else { return }  // The reconnect's convs carries fresh counts.
        mentionFetchAt = clock.now()
        Task { [weak self] in
            guard let self else { return }
            do {
                self.applyConvs(try await self.conn.request(ConvsAck.self, "convs"))
            } catch {
                self.log.warn("im: mention refresh failed: \(describeForLog(error))")
            }
        }
    }

    /// Logout: the throttle timer goes, and the next login starts with a fresh window.
    func resetMentionRefresh() {
        if let t = mentionTimer { clock.clearTimeout(t) }
        mentionTimer = nil
        mentionFetchAt = Int64.min / 2
    }
}
