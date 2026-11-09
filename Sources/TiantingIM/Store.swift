import Foundation

/// Send state (PRD F-MSG-03; attachments PRD-chat F-FILE-07). Everything from the server is `sent`.
/// Attachments: `processing` (the app's image work) -> `uploading` (ask, PUT, complete) -> `queued` (ready to send:
/// completed, waiting for the connection) -> `sending` -> `sent`; any step can go to `failed`. Text has neither of the
/// first two.
public enum MessageStatus: String, Sendable, Codable {
    case processing, uploading, queued, sending, sent, failed
}

/// Why a send failed: a server error code (4292 upload quota, 4290 with `errorReason == "uploadPendingLimit"`, 4139,
/// 4150, 4096, 5032 ...), or a local reason.
public enum SendFailure: Sendable, Hashable, Codable, CustomStringConvertible {
    case code(Int)
    case timeout
    case kicked
    /// Uploading hit a network error or the object store refused the PUT.
    case network
    /// The app's image processing failed: "无法处理这张图片，请用文件方式发送".
    case process
    /// Copying the file into the SDK's sandbox failed: "存储空间不足".
    case storage
    /// A re-upload is needed but the sandbox copy is gone: "原文件已不可用，请重新选择" (delete only).
    case sourceMissing
    /// Processing or uploading when the app was killed: failed on the next start, never resumed (F-FILE-07 rule 3).
    case interrupted

    public var description: String {
        switch self {
        case .code(let c): return String(c)
        case .timeout: return "timeout"
        case .kicked: return "kicked"
        case .network: return "network"
        case .process: return "process"
        case .storage: return "storage"
        case .sourceMissing: return "sourceMissing"
        case .interrupted: return "interrupted"
        }
    }
}

/// One message as the UI sees it. Unsent and failed messages have no msgId or seq yet.
public struct Message: Sendable, Hashable, Codable {
    public var clientMsgId: String
    public var msgId: String?
    public var seq: Int64?
    public var convId: String
    public var from: String
    public var type: MessageType
    public var body: MsgBody
    /// Server time; unsent messages show local time for now (PRD 3.1).
    public var ts: Int64
    public var status: MessageStatus
    public var error: SendFailure?
    /// Deleted (PRD-admin F-ADM-31): seq, msgId, sender and time stay, the body is empty.
    public var deleted: Bool?
    public var deletedAt: Int64?
    /// The error code's reason, e.g. 4290's `uploadPendingLimit`.
    public var errorReason: String? = nil

    /// An image or file message (C2).
    public var isAttachment: Bool { type == .image || type == .file }
}

/// One conversation as the UI sees it.
public struct Conversation: Sendable, Hashable, Codable {
    public var convId: String
    public var type: ConvType
    public var name: String
    public var maxSeq: Int64
    public var readSeq: Int64
    public var minSeq: Int64
    public var unread: Int64
    public var lastMsg: LastMsg?
    public var updatedAt: Int64
    /// Group member count; nil when absent (the UI then shows only the name).
    public var memberCount: Int?
    /// My role in a group (M4); nil for c2c and older servers.
    public var myRole: GroupRole?
    /// How existing messages look, versioned (F-RCL-03 rule 2); nil on older servers.
    public var modVer: Int64? = nil
}

/// What is kept after being removed from a group (PRD-ui G-UI-21): the conversation leaves the list but the chat
/// page can still show its name and "you are no longer in this group". Lives until logout.
public struct ConversationSnapshot: Sendable, Hashable, Codable {
    public var convId: String
    public var type: ConvType
    public var name: String
    public var removed: Bool = true
    /// The server's value (removed / dissolved / left / anything else); nil when inferred.
    public var reason: String?
}

/// A conversation plus the unread baseline max(readSeq, joinSeq), derived from the server's maxSeq - unread (C-02).
struct ConvState: Sendable, Hashable, Codable {
    var view: Conversation
    var readBase: Int64
    /// The modVer the loaded messages reflect (F-RCL-03 rule 2): a reconnect re-syncs only when the server's differs.
    /// Stored with the conversation, so it survives a cold start.
    var checkedModVer: Int64? = nil
}

private let summaryLength = 100

/// The summary of a deleted last message: keeps no text.
private func deletedLast(msgId: String, from: String, type: String, ts: Int64) -> LastMsg {
    LastMsg(msgId: msgId, from: from, type: type, text: nil, ts: ts, deleted: true)
}

/// Marks a body expired; the file name is cleared, as the server does (F-FILE-06 rule 3).
func expire(_ body: MsgBody) -> MsgBody {
    var b = body
    b.image?.expired = true
    if b.file != nil {
        b.file?.expired = true
        b.file?.name = ""
    }
    return b
}

private func summary(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count > summaryLength else { return text }
    return String(String.UnicodeScalarView(scalars.prefix(summaryLength)))
}

/// One conversation's messages: those with a seq in seq order, those without (unsent / failed) in send order after
/// them (F-MSG-03 rule 3).
@MainActor
final class MessageList {
    private var bySeq: [Int64: Message] = [:]
    private var unsent: [Message] = []
    private var byClient: [String: Message] = [:]
    private var byMsgId: Set<String> = []
    // Known-deleted ids and seqs: a sync result or send ack that arrives later must not bring the text back.
    private var deletedIds: Set<String> = []
    private var deletedSeqs: Set<Int64> = []
    // Failed messages the user removed (G-UI-14). They may have reached the server: later acks and syncs stay out.
    private var removedClient: Set<String> = []
    // Messages whose file is known expired (F-FILE-06 rule 3): `expired` only goes false -> true, a late old sync
    // cannot turn it back (F-RCL-03 rule 2a).
    private var expiredIds: Set<String> = []
    /// File ids that just expired or whose message was deleted in a merge; the client takes them to clear caches.
    var newlyExpired: [String] = []

    /// The earliest loaded seq (for paging back); 0 when nothing is loaded.
    var oldestSeq: Int64 = 0
    var hasMoreHistory = true

    /// Loaded from the network during this login, so a reconnect re-checks it (F-ADM-31 rule 5).
    var touched = false
    /// Restored from disk and not yet checked against the server since the app started.
    var restoredUnverified = false

    // Local database bookkeeping: what `Store.drainChanges` still has to write.
    fileprivate var dirtySeqs: Set<Int64> = []
    fileprivate var clearedOnDisk = false

    /// Merges a server message: dedupes by msgId, merges a pending local message by clientMsgId. Existing messages
    /// merge monotonically (F-RCL-03 rule 2a): `deleted` and a file's `expired` only go false -> true, deletedIds win;
    /// a late old sync carrying text or `expired == false` writes nothing back. Returns the merged message, or nil when
    /// nothing changed.
    func addServer(_ m: ServerMessage) -> Message? {
        if removedClient.contains(m.clientMsgId) { return nil }
        touched = true
        let deleted = m.deleted == true || isDeleted(msgId: m.msgId, seq: m.seq)
        if byMsgId.contains(m.msgId) {
            guard let old = bySeq[m.seq], old.deleted != true else { return nil }
            if deleted { return wipe(old, deletedAt: m.deletedAt) }
            if m.body?.fileExpired == true, !old.body.fileExpired {
                expiredIds.insert(m.msgId)
                var next = old
                next.body = expire(old.body)
                noteExpired(old.body)
                return replace(old, next)
            }
            return nil
        }
        if let local = byClient[m.clientMsgId], local.seq == nil, local.from == m.from {
            unsent.removeAll { $0.clientMsgId == local.clientMsgId }
        }
        var body = m.body ?? MsgBody()
        if !deleted, body.fileExpired || expiredIds.contains(m.msgId) {
            if !expiredIds.contains(m.msgId) { noteExpired(body) }
            expiredIds.insert(m.msgId)
            body = expire(body)
        }
        let msg = Message(
            clientMsgId: m.clientMsgId, msgId: m.msgId, seq: m.seq, convId: m.convId, from: m.from, type: m.type,
            body: deleted ? MsgBody() : body, ts: m.ts, status: .sent, error: nil,
            deleted: deleted ? true : nil, deletedAt: m.deletedAt)
        insert(msg, seq: m.seq)
        return msg
    }

    /// Puts a message restored from the local database back, without marking it dirty.
    func restore(_ msg: Message) {
        guard let seq = msg.seq else { return }
        insert(msg, seq: seq)
        dirtySeqs.remove(seq)
        restoredUnverified = true
        if msg.body.fileExpired, let id = msg.msgId { expiredIds.insert(id) }
    }

    private func replace(_ old: Message, _ next: Message) -> Message {
        if let seq = old.seq {
            bySeq[seq] = next
            dirtySeqs.insert(seq)
        }
        byClient[old.clientMsgId] = next
        return next
    }

    private func noteExpired(_ body: MsgBody) {
        if let id = body.fileId, !newlyExpired.contains(id) { newlyExpired.append(id) }
    }

    /// Whether a loaded message carries this file and it is known expired.
    func hasExpiredFile(_ fileId: String) -> Bool {
        bySeq.values.contains { $0.body.fileId == fileId && $0.body.fileExpired }
    }

    private func insert(_ msg: Message, seq: Int64) {
        bySeq[seq] = msg
        byClient[msg.clientMsgId] = msg
        if let id = msg.msgId { byMsgId.insert(id) }
        if oldestSeq == 0 || seq < oldestSeq { oldestSeq = seq }
        dirtySeqs.insert(seq)
    }

    func isDeleted(msgId: String, seq: Int64? = nil) -> Bool {
        if deletedIds.contains(msgId) { return true }
        if let seq, deletedSeqs.contains(seq) { return true }
        return false
    }

    /// Records deleted messages and wipes loaded text. Returns whether any message changed.
    func markDeleted(msgIds: [String], seqs: [Int64]) -> Bool {
        deletedIds.formUnion(msgIds)
        deletedSeqs.formUnion(seqs)
        var changed = false
        for m in Array(bySeq.values) where m.deleted != true && isDeleted(msgId: m.msgId ?? "", seq: m.seq) {
            _ = wipe(m, deletedAt: nil)
            changed = true
        }
        return changed
    }

    private func wipe(_ old: Message, deletedAt: Int64?) -> Message {
        noteExpired(old.body)  // The file's caches go too (F-RCL-03 rule 3).
        var next = old
        next.body = MsgBody()
        next.deleted = true
        if let deletedAt { next.deletedAt = deletedAt }
        if let seq = old.seq {
            bySeq[seq] = next
            dirtySeqs.insert(seq)
        }
        byClient[old.clientMsgId] = next
        return next
    }

    /// Whether local messages without a seq exist: one of them may be what the server already stored.
    var hasUnsent: Bool { !unsent.isEmpty }
    var unsentCount: Int { unsent.count }

    /// Everything held in memory for this conversation (AC-ADM-31-3).
    func debugAll() -> [Message] {
        var seen = Set<Message>()
        var out: [Message] = []
        for m in Array(bySeq.values) + unsent + Array(byClient.values) where seen.insert(m).inserted {
            out.append(m)
        }
        return out
    }

    func addLocal(_ m: Message) {
        unsent.append(m)
        byClient[m.clientMsgId] = m
    }

    func local(_ clientMsgId: String) -> Message? {
        byClient[clientMsgId]
    }

    /// Removes one failed local message and remembers its clientMsgId. Returns false unless it is failed.
    func removeFailed(_ clientMsgId: String) -> Bool {
        removeUnsent(clientMsgId, [.failed])
    }

    /// Removes a local message without a seq whose status is in `statuses` (cancelling an upload, AC-FILE-02-5).
    func removeUnsent(_ clientMsgId: String, _ statuses: Set<MessageStatus>) -> Bool {
        guard let m = byClient[clientMsgId], statuses.contains(m.status), m.seq == nil else { return false }
        unsent.removeAll { $0.clientMsgId == clientMsgId }
        byClient[clientMsgId] = nil
        removedClient.insert(clientMsgId)
        return true
    }

    func has(seq: Int64) -> Bool {
        bySeq[seq] != nil
    }

    /// Changes a local message's status; returns the new value.
    @discardableResult
    func update(_ clientMsgId: String, _ change: (inout Message) -> Void) -> Message? {
        guard var next = byClient[clientMsgId] else { return nil }
        change(&next)
        byClient[clientMsgId] = next
        if let i = unsent.firstIndex(where: { $0.clientMsgId == clientMsgId }) { unsent[i] = next }
        if let seq = next.seq {
            bySeq[seq] = next
            dirtySeqs.insert(seq)
        }
        return next
    }

    /// Drops loaded server messages (a gap over 200 keeps only the newest page, C-24), keeps unsent and failed ones.
    func resetServer() {
        for m in bySeq.values { byClient[m.clientMsgId] = nil }
        bySeq = [:]
        byMsgId = []
        oldestSeq = 0
        hasMoreHistory = true
        dirtySeqs = []
        clearedOnDisk = true
    }

    /// Local messages still in progress (processing, uploading, queued, sending).
    func pendingMessages() -> [Message] {
        unsent.filter { $0.status != .failed && $0.status != .sent }
    }

    /// Unsent image and file messages: the outbox that survives a restart (F-FILE-07 rule 3).
    func unsentAttachments() -> [Message] {
        unsent.filter(\.isAttachment)
    }

    func snapshot() -> [Message] {
        bySeq.values.sorted { $0.seq! < $1.seq! } + unsent
    }

    var maxLoadedSeq: Int64 {
        bySeq.keys.max() ?? 0
    }

    fileprivate func message(seq: Int64) -> Message? {
        bySeq[seq]
    }

    fileprivate func allSeqs() -> [Int64] {
        Array(bySeq.keys)
    }
}

/// Everything that still has to reach the local database, applied in one transaction.
struct LocalChanges {
    var upsertConvs: [ConvState] = []
    var deleteConvs: [String] = []
    /// Conversations whose stored messages are all deleted (removed from a group, gap reset).
    var clearMessages: [String] = []
    var upsertMessages: [Message] = []

    var isEmpty: Bool {
        upsertConvs.isEmpty && deleteConvs.isEmpty && clearMessages.isEmpty && upsertMessages.isEmpty
    }
}

/// Local data: the conversation list and each conversation's messages (the data half of FE-004).
@MainActor
final class Store {
    private let me: () -> String
    private var convs: [String: ConvState] = [:]
    private var msgs: [String: MessageList] = [:]
    /// The largest seq this device knows per conversation (received messages and ack seqs).
    private var localMax: [String: Int64] = [:]
    private var snapshots: [String: ConversationSnapshot] = [:]
    private var placeholders: Set<String> = []
    /// Whether the last `convs` was truncated to the newest 500 (C-03).
    private(set) var truncated = false

    // Local database bookkeeping.
    private var dirtyConvs: Set<String> = []
    private var removedConvs: Set<String> = []
    /// Conversations I was removed from: messages stay in memory for the session, but not on disk.
    private var diskEvicted: Set<String> = []

    init(me: @escaping () -> String) {
        self.me = me
    }

    // MARK: Conversations

    /// Replaces the list with a `convs` result. Returns groups inferred as "removed" (present before, absent now: the
    /// server does not replay removals that happened offline, G-UI-21). No inference when truncated or for c2c.
    func setConversations(_ list: [ServerConversation], truncated: Bool) -> [String] {
        var next: [String: ConvState] = [:]
        for c in list { next[c.convId] = fromServer(c) }
        var gone: [String] = []
        if !truncated {
            for (id, c) in convs where c.view.type == .group && next[id] == nil && !placeholders.contains(id) {
                snapshots[id] = ConversationSnapshot(convId: id, type: c.view.type, name: c.view.name)
                gone.append(id)
                evictFromDisk(id)
            }
        }
        for id in next.keys {
            snapshots[id] = nil
            restoreToDisk(id)
        }
        for id in convs.keys where next[id] == nil { removedConvs.insert(id) }
        for id in next.keys where convs[id] != next[id] {
            dirtyConvs.insert(id)
            removedConvs.remove(id)
        }
        convs = next
        placeholders = []
        self.truncated = truncated
        return gone.sorted(by: bytesLess)
    }

    func upsertConversation(_ c: ServerConversation) {
        convs[c.convId] = fromServer(c)
        dirtyConvs.insert(c.convId)
        removedConvs.remove(c.convId)
        placeholders.remove(c.convId)
        snapshots[c.convId] = nil  // Pulled back in: drop the snapshot (G-UI-21).
        restoreToDisk(c.convId)
    }

    /// Removed from a group: leaves the list, keeps a snapshot, and leaves the local database (F-ADM-24 rule 7).
    func removeConversation(_ convId: String, reason: String?) {
        let c = convs[convId]?.view
        let colon = convId.firstIndex(of: ":").map { convId.index(after: $0) } ?? convId.startIndex
        snapshots[convId] = ConversationSnapshot(
            convId: convId,
            type: c?.type ?? (convId.hasPrefix("group:") ? .group : .c2c),
            name: c?.name ?? String(convId[colon...]),
            reason: reason)
        convs[convId] = nil
        removedConvs.insert(convId)
        dirtyConvs.remove(convId)
        evictFromDisk(convId)
    }

    private func evictFromDisk(_ convId: String) {
        diskEvicted.insert(convId)
        msgs[convId]?.clearedOnDisk = true
        msgs[convId]?.dirtySeqs = []
    }

    private func restoreToDisk(_ convId: String) {
        guard diskEvicted.remove(convId) != nil, let l = msgs[convId] else { return }
        l.dirtySeqs.formUnion(l.allSeqs())
    }

    func snapshot(_ convId: String) -> ConversationSnapshot? {
        snapshots[convId]
    }

    func conversation(_ convId: String) -> Conversation? {
        convs[convId]?.view
    }

    /// By updatedAt descending, then convId ascending (same as the server). Values are immutable: unchanged
    /// conversations compare equal, so the UI can diff with `==` (G-UI-19).
    func conversations() -> [Conversation] {
        convs.values
            .map(\.view)
            .sorted { a, b in
                a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : bytesLess(a.convId, b.convId)
            }
    }

    private func fromServer(_ c: ServerConversation) -> ConvState {
        // This `convs` may predate a deletion: a known-deleted last message must not bring its text back.
        var last = c.lastMsg
        if let l = last, l.deleted != true, msgs[c.convId]?.isDeleted(msgId: l.msgId) == true {
            last = deletedLast(msgId: l.msgId, from: l.from, type: l.type, ts: l.ts)
        }
        let view = Conversation(
            convId: c.convId, type: c.type, name: c.name, maxSeq: c.maxSeq, readSeq: c.readSeq, minSeq: c.minSeq,
            unread: c.unread, lastMsg: last, updatedAt: c.updatedAt, memberCount: c.memberCount, myRole: c.myRole,
            modVer: c.modVer)
        // Not loaded yet: what loads later is at least this version, so it is the baseline. Loaded: keep the old value
        // until a re-sync succeeds.
        let loaded = (msgs[c.convId]?.oldestSeq ?? 0) > 0
        let checked = loaded ? convs[c.convId]?.checkedModVer : (c.modVer ?? convs[c.convId]?.checkedModVer)
        return ConvState(view: view, readBase: c.maxSeq - c.unread, checkedModVer: checked)
    }

    /// The modVer the loaded messages of a conversation reflect.
    func checkedModVer(_ convId: String) -> Int64? {
        convs[convId]?.checkedModVer
    }

    /// A re-sync of a conversation's loaded range succeeded at this modVer.
    func markChecked(_ convId: String, _ modVer: Int64) {
        guard var c = convs[convId], c.checkedModVer != modVer else { return }
        c.checkedModVer = modVer
        convs[convId] = c
        dirtyConvs.insert(convId)
    }

    /// Takes the file ids that expired or whose message was deleted in a merge: the caller clears URL and file caches
    /// (F-FILE-06 rule 3, AC-FILE-06-12).
    func takeExpiredFiles() -> [String] {
        var out: [String] = []
        for l in msgs.values where !l.newlyExpired.isEmpty {
            out += l.newlyExpired
            l.newlyExpired = []
        }
        return out
    }

    /// Whether a loaded message's file is known expired (no URL request then, AC-FILE-06-6).
    func fileExpired(_ fileId: String) -> Bool {
        msgs.values.contains { $0.hasExpiredFile(fileId) }
    }

    /// All unsent image and file messages.
    func unsentAttachments() -> [Message] {
        msgs.values.flatMap { $0.unsentAttachments() }
    }

    /// Moves the read position forward only (own report, other device, sending counts as reading).
    func advanceRead(_ convId: String, _ seq: Int64) -> Bool {
        guard var c = convs[convId], seq > c.view.readSeq else { return false }
        c.view.readSeq = seq
        recount(&c)
        convs[convId] = c
        dirtyConvs.insert(convId)
        return true
    }

    private func recount(_ c: inout ConvState) {
        c.view.unread = max(0, c.view.maxSeq - max(c.readBase, c.view.readSeq))
    }

    // MARK: Messages

    func list(_ convId: String) -> MessageList {
        if let l = msgs[convId] { return l }
        let l = MessageList()
        msgs[convId] = l
        return l
    }

    func allListIds() -> [String] {
        Array(msgs.keys)
    }

    func messages(_ convId: String) -> [Message] {
        msgs[convId]?.snapshot() ?? []
    }

    func maxSeq(_ convId: String) -> Int64 {
        localMax[convId] ?? 0
    }

    /// Merges one server message and updates the conversation's maxSeq, unread and last message. My own messages
    /// (from another device) add no unread and advance reading (C-34). Returns whether it was new.
    func applyServerMessage(_ m: ServerMessage) -> Bool {
        let merged = list(m.convId).addServer(m)
        bumpMax(m.convId, m.seq)
        guard let merged else { return false }
        var c = convs[m.convId] ?? newConversation(m)
        if m.seq > c.view.maxSeq {
            c.view.maxSeq = m.seq
            c.view.lastMsg =
                merged.deleted == true
                ? deletedLast(msgId: m.msgId, from: m.from, type: m.type.rawValue, ts: m.ts)
                : LastMsg(
                    msgId: m.msgId, from: m.from, type: m.type.rawValue, text: summary(merged.body.text ?? ""),
                    ts: m.ts)
            c.view.updatedAt = max(c.view.updatedAt, m.ts)
        } else if merged.deleted == true, let l = c.view.lastMsg, l.msgId == m.msgId {
            c.view.lastMsg = deletedLast(msgId: l.msgId, from: l.from, type: l.type, ts: l.ts)
        }
        if m.from == me() { c.view.readSeq = max(c.view.readSeq, m.seq) }
        recount(&c)
        convs[m.convId] = c
        dirtyConvs.insert(m.convId)
        removedConvs.remove(m.convId)
        return true
    }

    /// A deletion (msgDeleted, or `lastMsg.deleted` from convs): wipes the text and turns the summary into a
    /// placeholder. Seqs keep no holes and unread does not change (C-02). Messages not loaded yet are remembered,
    /// so a later sync or ack cannot write their text back. Returns whether loaded messages changed.
    func deleteMessages(convId: String, msgIds: [String], seqs: [Int64]) -> Bool {
        let changed = list(convId).markDeleted(msgIds: msgIds, seqs: seqs)
        if var c = convs[convId], let l = c.view.lastMsg, l.deleted != true,
            msgIds.contains(l.msgId) || seqs.contains(c.view.maxSeq)
        {
            c.view.lastMsg = deletedLast(msgId: l.msgId, from: l.from, type: l.type, ts: l.ts)
            convs[convId] = c
            dirtyConvs.insert(convId)
        }
        return changed
    }

    /// Conversations with server messages this login or awaiting first verification, and their seq ranges.
    func loadedRanges() -> [(convId: String, from: Int64, to: Int64)] {
        msgs.compactMap { id, l in
            guard l.oldestSeq > 0, l.touched || l.restoredUnverified else { return nil }
            return (id, l.oldestSeq, l.maxLoadedSeq)
        }
        .sorted { bytesLess($0.convId, $1.convId) }
    }

    func debugExport() -> DebugExport {
        var messages: [String: [Message]] = [:]
        for (id, l) in msgs { messages[id] = l.debugAll() }
        return DebugExport(
            conversations: convs.values.map(\.view), snapshots: Array(snapshots.values), messages: messages)
    }

    func bumpMax(_ convId: String, _ seq: Int64) {
        if seq > maxSeq(convId) { localMax[convId] = seq }
    }

    /// Whether a local stand-in conversation exists (not in the server's list yet): `convs` should be refreshed soon.
    func hasPlaceholder(_ convId: String) -> Bool {
        placeholders.contains(convId)
    }

    func setLastMsgText(convId: String, msgId: String, text: String) {
        guard var c = convs[convId], let l = c.view.lastMsg, l.msgId == msgId, l.deleted != true else { return }
        c.view.lastMsg?.text = summary(text)
        convs[convId] = c
        dirtyConvs.insert(convId)
    }

    /// After `groupChanged`: applies `groupInfo` to the local conversation (F-SOC-20 rule 5). Returns whether it changed.
    func updateGroupMeta(convId: String, name: String, memberCount: Int, myRole: GroupRole) -> Bool {
        guard var c = convs[convId],
            c.view.name != name || c.view.memberCount != memberCount || c.view.myRole != myRole
        else { return false }
        c.view.name = name
        c.view.memberCount = memberCount
        c.view.myRole = myRole
        convs[convId] = c
        dirtyConvs.insert(convId)
        return true
    }

    /// First message of a conversation not in the list: a stand-in until `convs` replaces it.
    private func newConversation(_ m: ServerMessage) -> ConvState {
        let parts = m.convId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let type = parts.first ?? "c2c"
        let a = parts.count > 1 ? parts[1] : ""
        let b = parts.count > 2 ? parts[2] : ""
        let view = Conversation(
            convId: m.convId, type: ConvType(rawValue: type),
            name: type == "c2c" ? (a == me() ? b : a) : a,
            maxSeq: 0, readSeq: 0, minSeq: 1, unread: 0, lastMsg: nil, updatedAt: 0, memberCount: nil, myRole: nil)
        placeholders.insert(m.convId)
        return ConvState(view: view, readBase: 0)
    }

    // MARK: Local database

    /// Collects what changed since the last call. Unsent messages stay in memory only.
    func drainChanges() -> LocalChanges {
        var out = LocalChanges()
        out.upsertConvs = dirtyConvs.compactMap { convs[$0] }
        out.deleteConvs = Array(removedConvs)
        dirtyConvs = []
        removedConvs = []
        for (id, l) in msgs {
            if l.clearedOnDisk {
                out.clearMessages.append(id)
                l.clearedOnDisk = false
            }
            guard !l.dirtySeqs.isEmpty else { continue }
            if !diskEvicted.contains(id) {
                out.upsertMessages += l.dirtySeqs.compactMap { l.message(seq: $0) }
            }
            l.dirtySeqs = []
        }
        return out
    }

    /// Fills the store from the local database on startup.
    func restore(convStates: [ConvState], messages: [Message]) {
        for c in convStates { convs[c.view.convId] = c }
        for m in messages {
            list(m.convId).restore(m)
            if let seq = m.seq { bumpMax(m.convId, seq) }
        }
        dirtyConvs = []
        removedConvs = []
    }

    /// Puts a restored outbox message back (unsent, so not in the messages table).
    func restoreUnsent(_ m: Message) {
        list(m.convId).addLocal(m)
    }

    func pendingCount() -> Int {
        msgs.values.reduce(0) { $0 + $1.unsentCount }
    }
}

/// A copy of what is in memory (AC-ADM-31-3). Never contains the token.
public struct DebugExport: Sendable, Codable {
    public var conversations: [Conversation]
    public var snapshots: [ConversationSnapshot]
    public var messages: [String: [Message]]
}
