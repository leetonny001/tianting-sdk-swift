import Foundation

// Pin, notifications off, delete a conversation, multi-device sync and the total unread (FE-682; PRD-chat C5: F-CVS-01..04,
// 13.1). Same rules as sdk-ts FE-680 (tianting-sdk-ts@97124bd) and sdk-kotlin FE-681; the local database purge is FE-682's.
extension IMClient {
    // MARK: Settings

    /// Pins or unpins a conversation (F-CVS-01). Optimistic: the list changes at once (a new pin goes to the top with the
    /// corrected server time; pinning again keeps `pinnedAt`), and the ack's conversation then wins. Any failure (5000,
    /// 4220 "最多置顶 20 个会话", 4290 "操作过于频繁", 4030 feature off or not allowed, a timeout, offline) rolls back and
    /// is thrown, never retried (frontend-chat 56); a value another device changed meanwhile is not rolled back.
    /// Throws `IMConnectionError.notConnected` before the user is known, `ConvIdError` for a malformed or foreign id.
    public func setConvPinned(_ convId: String, _ pinned: Bool) async throws {
        let now = serverNow()
        try await changeSettings(convId, ["pinned": .bool(pinned)]) { s in
            pinned
                ? ConvSettings(pinned: true, pinnedAt: s.pinned ? s.pinnedAt : now, notifyOff: s.notifyOff)
                : ConvSettings(pinned: false, notifyOff: s.notifyOff)
        }
    }

    /// Turns notifications off or on for a conversation (F-CVS-02): no push, unread still counts, only mentions of me
    /// count towards `totalUnread()`. Optimistic, failures as `setConvPinned`.
    public func setConvNotifyOff(_ convId: String, _ on: Bool) async throws {
        try await changeSettings(convId, ["notifyOff": .bool(on)]) { s in
            ConvSettings(pinned: s.pinned, pinnedAt: s.pinnedAt, notifyOff: on)
        }
    }

    private func changeSettings(
        _ convId: String, _ fields: [String: JSONValue], _ next: (ConvSettings) -> ConvSettings
    ) async throws {
        guard !me.isEmpty else { throw IMConnectionError.notConnected }
        _ = try parseConvIdStrict(convId, me: me)
        let before = store.settings(convId)
        let optimistic = before.map(next)
        if let optimistic, store.setSettings(convId, optimistic) { emitConversations() }
        var data = fields
        data["convId"] = .string(convId)
        let ack: ConvSetAck
        do {
            ack = try await conn.request(ConvSetAck.self, "convSet", .object(data))
        } catch {
            // Only while the local value is still this optimistic one: a `convSettingsChanged` from another device that
            // arrived meanwhile stays (the later one wins, F-CVS-04).
            if let before, let optimistic, store.settings(convId) == optimistic, store.setSettings(convId, before) {
                emitConversations()
            }
            throw error
        }
        store.applyConvAck(ack.conv)
        setGroupMute(ack.conv.convId, ack.conv.mutedUntil, allMuted: ack.conv.allMuted)
        mutesChanged()
        emitConversations()
    }

    // MARK: Delete

    /// Deletes a conversation for me (F-CVS-03; the confirmation dialog is the app's). `upToSeq` is the largest seq seen
    /// here. Optimistic: it leaves the list at once and comes back if the call fails (thrown, never retried, frontend-chat
    /// 56). On success: minSeq = clearedSeq + 1, read up to clearedSeq, unpinned, notifications off kept; everything below
    /// is purged from memory, the local database (rows and free pages) and the download cache (`filesExpired`); this
    /// conversation's uploads are cancelled (the temporary object is deleted on the server), queued and failed messages
    /// dropped (frontend-chat 59; a message already sending is left alone); then `.convDeleted` tells the app to drop the
    /// draft. A new message later brings the conversation back with only that message (AC-CVS-03-2).
    public func deleteConv(_ convId: String) async throws {
        guard !me.isEmpty else { throw IMConnectionError.notConnected }
        _ = try parseConvIdStrict(convId, me: me)
        let upToSeq = max(store.maxSeq(convId), store.conversation(convId)?.maxSeq ?? 0)
        store.hideForDelete(convId)
        emitConversations()
        let ack: ConvDeleteAck
        do {
            ack = try await conn.request(
                ConvDeleteAck.self, "convDelete", ["convId": .string(convId), "upToSeq": .int(upToSeq)])
        } catch {
            if store.cancelDelete(convId) { emitConversations() }
            throw error
        }
        discardUnsent(convId)
        convCleared(convId, ack.clearedSeq)
    }

    /// Drops this conversation's unsent messages: attachments through `cancelUpload` (a requested upload is deleted on the
    /// server), queued and failed text removed. Messages being sent stay.
    private func discardUnsent(_ convId: String) {
        let list = store.list(convId)
        for m in store.messages(convId) where m.seq == nil {
            if m.isAttachment {
                _ = cancelUpload(convId, m.clientMsgId)
            } else if list.removeUnsent(m.clientMsgId, [.queued, .failed]) {
                releaseSource(m.clientMsgId)
            }
        }
    }

    /// My `deleteConv` succeeded, or another device deleted it (`convDeleted`, F-CVS-04 rule 1): clear, purge, leave the
    /// list, and tell the app to drop the draft (frontend-chat 55: drafts go on every device). Unsent messages from another
    /// device's deletion stay (frontend-chat 63): sent later, they bring the conversation back anyway.
    func convCleared(_ convId: String, _ clearedSeq: Int64) {
        _ = store.clearConversation(convId, clearedSeq)
        emitMessages(convId)
        emitConversations()
        emit(.convDeleted(convId: convId))
    }

    // MARK: Events

    struct ConvSettingsChangedEvent: Decodable {
        var convId: String
        var pinned: Bool
        var pinnedAt: Int64?
        var notifyOff: Bool
    }

    struct ConvDeletedEvent: Decodable {
        var convId: String
        var clearedSeq: Int64
    }

    /// Another connection of mine changed pin or notifications off: the event wins (AC-CVS-04-1). Unknown conversations
    /// wait for the next `convs`.
    func onConvSettingsChanged(_ ev: ConvSettingsChangedEvent) {
        let s = ConvSettings(pinned: ev.pinned, pinnedAt: ev.pinned ? ev.pinnedAt : nil, notifyOff: ev.notifyOff)
        if store.setSettings(ev.convId, s) { emitConversations() }
    }

    // MARK: Total unread

    /// The total unread (F-CVS-02 rule 4): the `unread` of normal conversations plus the `mentionUnread` of those with
    /// notifications off (mentions of me count, R-CF-20). The tab badge uses it (AC-CVS-02-2, 02-5); `.totalUnread` is the
    /// same number.
    public func totalUnread() -> Int64 {
        store.conversations().reduce(0) { $0 + ($1.isNotifyOff ? ($1.mentionUnread ?? 0) : $1.unread) }
    }
}
