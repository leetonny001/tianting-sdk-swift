import Foundation

public struct IMClientTimings: Sendable {
    public var heartbeatMs: Int64 = 30_000
    public var pongTimeoutMs: Int64 = 10_000
    public var requestTimeoutMs: Int64 = 10_000
    public var backoffBaseMs: Int64 = 1_000
    public var backoffMaxMs: Int64 = 30_000
    public var jitter: Double = 0.2
    /// Send timeout (PRD F-MSG-03 rule 1).
    public var sendTimeoutMs: Int64 = 10_000
    /// How long a seq gap may stay open before `sync` (F-MSG-04 rule 2).
    public var gapWaitMs: Int64 = 500
    /// Read-report throttle (F-CONV-02 rule 3).
    public var readThrottleMs: Int64 = 1_000
    /// How long a disconnect lasts before the banner shows (F-CONN-02).
    public var bannerDelayMs: Int64 = 1_000

    public init() {}
}

public struct IMClientOptions {
    /// WebSocket URL, e.g. wss://im.example.com/ws. Never put a token in it (C-52).
    public var url: String
    public var platform: Platform = .ios
    /// Where the per-user SQLite cache lives. nil keeps everything in memory.
    public var databaseDirectory: URL?
    /// How many of a conversation's newest messages stay on disk across launches.
    public var maxCachedMessagesPerConversation = 100
    /// Reacts to network-path and app-lifecycle changes by itself. Tests and hosts driving
    /// `networkOnline()` / `visibilityChanged()` themselves turn this off.
    public var systemEvents = true
    public var timings = IMClientTimings()
    public var logger: IMLogger = SilentLogger()
    /// Whether the app is in the foreground. The default reads the app state on iOS, and is always true elsewhere.
    public var isVisible: (@MainActor () -> Bool)?
    /// Where a device with no cursor starts receiving pushes (PRD-live C10).
    public var pushStart: PushStart = .beginning
    /// The uncalibrated limits of the push catch-up.
    public var pushLimits = PushLimits()
    /// Where the push cursor lives (PRD-live 4.9), apart from the local database: it survives logout, kicks, corruption and
    /// schema upgrades. nil keeps it in memory, so every new instance replays the inbox from 0.
    public var pushCursorStore: PushCursorStore? = FilePushCursorStore()

    // Test injection (FE-007).
    public var transport: IMTransport?
    public var clock: IMClock?
    public var random: (() -> Double)?
    public var newId: (() -> String)?

    public init(url: String) {
        self.url = url
    }
}

/// What the UI can subscribe to.
public enum IMEvent: Sendable {
    case state(ConnState)
    /// Whether to show "connecting / network unavailable": true only after `bannerDelayMs`, false at once on recovery.
    case banner(Bool)
    case conversations([Conversation])
    case messages(convId: String, messages: [Message])
    /// Unread across all conversations changed (G-UI-15).
    case totalUnread(Int)
    /// Queued + sending + failed messages changed (logout confirmation, G-UI-20).
    case pendingCount(Int)
    /// One attempt failed, emitted once per failure (G-UI-22).
    case sendFailed(convId: String, clientMsgId: String, error: SendFailure)
    /// Removed from a group (`convRemoved`, or inferred after a reconnect, G-UI-21). `reason` is the server's value;
    /// nil when inferred. Unknown reasons mean "removed" for display.
    case convRemoved(convId: String, reason: String?)
    /// A mute changed (muted / unmuted, auth ack, convs, send 4031, expiry). Read `muteState(convId)`.
    case muteChanged
    /// Kicked or closed with a non-reconnecting code. The connection has stopped; go to the login page (C-01).
    case fatal(FatalReason)
    case friends([Friend])
    case friendRequests(FriendRequestList)
    case blocks([BlockedUser])
    case socialSettings(SocialSettings)
    /// Group info or members changed; the local conversation is already updated from `info`.
    case groupChanged(groupId: String, info: GroupInfo)
    /// A security notice such as a login on a new device (PRD-chat F-ACC-02 rule 3b). Unknown kinds are not sent.
    case securityNotice(SecurityNotice)
    /// The auth ack says the newest recovery code is not acknowledged (F-ACC-05 rule 1): force the save page.
    case recoveryCodeUnacked
    /// Someone's profile changed; read `profileOf` / `displayName` (F-ACC-06: my nickname shows at once).
    case profileChanged(userId: String)
}

public struct SecurityNotice: Sendable, Equatable {
    public let kind: String
    public let at: Int64
    public let platform: String?
}

/// The security notices this batch knows (server/internal/protocol/frames.go).
private let securityNoticeKinds: Set<String> = ["newDeviceLogin"]

public enum SendResult: Sendable, Equatable {
    case ok(Message)
    case empty
    case tooLong(over: Int)

    public var message: Message? {
        if case .ok(let m) = self { return m }
        return nil
    }
}

public struct ApplyFriendOptions: Sendable {
    public var message: String?
    public var source: ApplySource?
    /// The groupId when `source == .group`.
    public var sourceRef: String?
    /// My remark for them once they accept.
    public var remark: String?

    public init(message: String? = nil, source: ApplySource? = nil, sourceRef: String? = nil, remark: String? = nil) {
        self.message = message
        self.source = source
        self.sourceRef = sourceRef
        self.remark = remark
    }
}

public final class IMSubscription: Sendable {
    private let cancelHandler: @Sendable @MainActor () -> Void

    init(cancel: @escaping @Sendable @MainActor () -> Void) {
        cancelHandler = cancel
    }

    @MainActor
    public func cancel() {
        cancelHandler()
    }
}

/// A gap larger than this loads only the newest page; older messages come from paging back (C-24).
private let maxCatchUp: Int64 = 200
private let syncPageSize = 200
private let latestPageSize = 20
private let refreshThrottleMs: Int64 = 30_000  // refreshConversations (G-UI-24)
/// Mutes last up to 30 days: wait in pieces and recompute, so no timer ever has to span that much.
private let muteTimerMaxMs: Int64 = 86_400_000
private let maxSafeInteger: Int64 = 9_007_199_254_740_991

/// The SDK's single entry point (PLAN 3.2). All state lives on the main actor; the UI reads snapshots synchronously
/// and subscribes with `on(_:)` or `events()`.
///
///     let im = IMClient(options: IMClientOptions(url: "wss://host/ws"))
///     im.on { event in ... }
///     im.connect(token: token)
@MainActor
public final class IMClient {
    let t: IMClientTimings
    let clock: IMClock
    let log: IMLogger
    let newId: () -> String
    private let isVisible: @MainActor () -> Bool
    let conn: Connection
    let pushSync: PushSync
    private let databaseDirectory: URL?
    private let maxCached: Int

    var store: Store
    var me = ""
    private var autoUsed: Set<String> = []  // clientMsgIds that already used their one automatic resend
    private var gapTimers: [String: TimerHandle] = [:]
    private var active: String?
    private var lastRead: Int64 = Int64.min / 2
    private var lastTotalUnread: Int64 = 0
    private var lastPendingCount = 0
    private var readTimer: TimerHandle?
    private var bannerTimer: TimerHandle?
    private var bannerShown = false
    private var refreshTimer: TimerHandle?
    private var lastRefreshAt: Int64 = Int64.min / 2
    var serverOffset: Int64 = 0  // server time minus local time (auth ack's serverTime)
    private var mutes = MuteTable()
    private var lastMutes = MuteTable()
    private var lastGroupAllRoles: [GroupRole?] = []
    private var muteTimer: TimerHandle?

    // Social.
    let social = SocialState()
    let profiles: ProfileCache
    var socialTimer: TimerHandle?
    var socialRunning: Task<Void, Never>?
    var socialSnap = SocialSnapshot()
    var usersQueue: [String: [UsersWaiter]] = [:]
    var groupInfoInFlight: [String: Bool] = [:]

    private(set) var database: LocalDatabase?
    private var listeners: [UUID: @MainActor (IMEvent) -> Void] = [:]
    private var systemEvents: SystemEventsMonitor?
    private var provider: TokenProvider?
    private var unsubscribeProvider: [@MainActor () -> Void] = []

    public init(options o: IMClientOptions) {
        t = o.timings
        clock = o.clock ?? SystemClock()
        log = o.logger
        newId = o.newId ?? { UUID().uuidString.lowercased() }
        isVisible = o.isVisible ?? defaultIsVisible
        databaseDirectory = o.databaseDirectory
        maxCached = o.maxCachedMessagesPerConversation
        let clockRef = clock
        profiles = ProfileCache(now: { MainActor.assumeIsolated { clockRef.now() } })
        conn = Connection(
            url: o.url,
            platform: o.platform,
            transport: o.transport ?? WebSocketTransport(),
            clock: clockRef,
            logger: o.logger,
            timings: ConnectionTimings(
                heartbeatMs: o.timings.heartbeatMs,
                pongTimeoutMs: o.timings.pongTimeoutMs,
                requestTimeoutMs: o.timings.requestTimeoutMs,
                backoffBaseMs: o.timings.backoffBaseMs,
                backoffMaxMs: o.timings.backoffMaxMs,
                jitter: o.timings.jitter),
            random: o.random ?? { Double.random(in: 0..<1) })
        let connRef = conn
        pushSync = PushSync(
            clock: clockRef, log: o.logger, pushStart: o.pushStart, limits: o.pushLimits, store: o.pushCursorStore,
            request: { data, completion in connRef.request("pushSync", data, completion: completion) })
        store = Store(me: { "" })
        store = Store(me: { [unowned self] in MainActor.assumeIsolated { self.me } })
        conn.onState = { [weak self] in self?.onState($0) }
        conn.onConnected = { [weak self] in self?.onConnected($0) }
        conn.onFrame = { [weak self] in self?.onFrame($0) }
        conn.onFatal = { [weak self] in self?.onFatal($0) }
        if o.systemEvents {
            systemEvents = SystemEventsMonitor(
                online: { [weak self] in self?.networkOnline() },
                visibility: { [weak self] in self?.visibilityChanged() })
        }
    }

    // MARK: Subscriptions

    /// Subscribes to events; handlers run synchronously on the main actor. Keep the result to `cancel()` later.
    @discardableResult
    public func on(_ handler: @escaping @MainActor (IMEvent) -> Void) -> IMSubscription {
        let id = UUID()
        listeners[id] = handler
        return IMSubscription { [weak self] in
            self?.listeners[id] = nil
        }
    }

    /// The same events as an `AsyncStream` (FE-141). Unbounded buffer; ends when the consumer cancels.
    public func events() -> AsyncStream<IMEvent> {
        AsyncStream { continuation in
            let sub = on { continuation.yield($0) }
            continuation.onTermination = { _ in
                Task { @MainActor in sub.cancel() }
            }
        }
    }

    func emit(_ e: IMEvent) {
        for handler in Array(listeners.values) { handler(e) }
    }

    // MARK: Public: connection

    /// The current user, available after `restoreCache(userId:)` or the first successful connect.
    public var userId: String { me }

    public var state: ConnState { conn.state }

    /// Connects in demo mode, behavior unchanged. Account sessions use `connect(tokenProvider:)`.
    public func connect(token: String) {
        bindProvider(nil)
        conn.start(token: token)
    }

    /// Connects in account mode with `AccountClient.tokenProvider`: refreshes by itself, reconnects after a token change,
    /// compares generations on 4011 (PRD-chat 13.1, F-ACC-03 rules 5, 7).
    public func connect(tokenProvider: TokenProvider) {
        bindProvider(tokenProvider)
        conn.start(provider: tokenProvider)
    }

    private func bindProvider(_ p: TokenProvider?) {
        if p === provider { return }
        for off in unsubscribeProvider { off() }
        provider = p
        guard let p else {
            unsubscribeProvider = []
            return
        }
        unsubscribeProvider = [
            p.onEnded { [weak self] in self?.onSessionEnded($0) },
            p.onProfileChanged { [weak self] userId, nickname in
                guard let self else { return }
                let last = self.profiles.last(userId)
                self.profiles.put(
                    UserProfile(
                        userId: userId, nickname: nickname, avatar: last?.avatar ?? "", official: last?.official ?? false))
                self.emit(.profileChanged(userId: userId))
            },
        ]
    }

    /// The account session ended. A logout clears the data; anything else goes to login like a kick. Kicks already went
    /// through `fatal` on the connection.
    private func onSessionEnded(_ e: SessionEnd) {
        if e.origin == .kick { return }
        bindProvider(nil)
        conn.stop()
        if e.action == .logout {
            reset()
            me = ""
            return
        }
        onFatal(.session(e))
    }

    /// Shows a logged-in user's cached data before the connection is up (a cold start while offline).
    public func restoreCache(userId: String) {
        guard me.isEmpty || me == userId else { return }
        me = userId
        openDatabase(userId: userId)
    }

    /// Logs out: closes with 1000, stops reconnecting, clears memory and the local database (PRD F-AUTH-05, FE-141).
    public func disconnect() {
        bindProvider(nil)
        conn.stop()
        reset()
        me = ""
    }

    /// Stops without logging out: the local database stays for the next launch.
    public func close() {
        systemEvents = nil
        bindProvider(nil)
        conn.stop()
        commit()
        database?.close()
        database = nil
    }

    /// Releases system observers and logs out.
    public func destroy() {
        disconnect()
        systemEvents = nil
    }

    // MARK: Public: conversations and messages

    public func conversations() -> [Conversation] {
        store.conversations()
    }

    public func messages(_ convId: String) -> [Message] {
        store.messages(convId)
    }

    /// Sends text: inserts a local "sending" message ("queued" when offline), which becomes "sent" on ack.
    /// Empty or too-long text is not sent. Throws `IMConnectionError.notConnected` before the user is known, and
    /// `ConvIdError` for a malformed conversation id.
    public func send(_ convId: String, _ raw: String) throws -> SendResult {
        let text: String
        switch checkText(raw) {
        case .empty: return .empty
        case .tooLong(_, let over): return .tooLong(over: over)
        case .ok(let t): text = t
        }
        guard !me.isEmpty else { throw IMConnectionError.notConnected }  // Must know who I am.
        _ = try parseConvId(convId, me: me)
        let msg = Message(
            clientMsgId: newId(), msgId: nil, seq: nil, convId: convId, from: me, type: .text,
            body: MsgBody(text: text), ts: clock.now(),
            status: conn.state == .connected ? .sending : .queued, error: nil, deleted: nil, deletedAt: nil)
        store.list(convId).addLocal(msg)
        emitMessages(convId)
        if msg.status == .sending { dispatch(convId, msg.clientMsgId) }
        return .ok(msg)
    }

    /// This conversation's current mute; nil when not muted. Expiry uses server time; the user level wins;
    /// a group-wide mute does not restrict owners and admins.
    public func muteState(_ convId: String) -> MuteInfo? {
        mutes.get(convId, now: serverNow(), myRole: store.conversation(convId)?.myRole)
    }

    /// Debug interface (AC-ADM-31-3): a copy of conversations and all messages in memory. Never contains the token.
    public func debugExport() -> DebugExport {
        store.debugExport()
    }

    /// The local database file of the logged-in user, when one is open.
    public var databaseURL: URL? { database?.url }

    /// Manually resends a failed message with its original clientMsgId (PRD F-MSG-03 rule 2).
    public func retry(_ convId: String, _ clientMsgId: String) {
        let list = store.list(convId)
        guard let m = list.local(clientMsgId), m.status == .failed else { return }
        if conn.state == .connected {
            dispatch(convId, clientMsgId)
        } else {
            autoUsed.insert(clientMsgId)  // A manual resend also gets only one automatic resend.
            list.update(clientMsgId) {
                $0.status = .queued
                $0.error = nil
            }
            emitMessages(convId)
        }
    }

    /// Removes a failed message locally (PRD-ui G-UI-14): no frame, no effect on the server. Only for `failed`.
    /// It does not come back for the rest of this login, not even from a late ack or sync.
    @discardableResult
    public func removeFailed(_ convId: String, _ clientMsgId: String) -> Bool {
        guard store.list(convId).removeFailed(clientMsgId) else { return false }
        emitMessages(convId)
        return true
    }

    /// Pages history backwards (PRD F-MSG-05): first from the newest (beforeSeq = maxSeq + 1, 20 messages), then from
    /// the oldest loaded. Returns whether older messages remain.
    @discardableResult
    public func loadHistory(_ convId: String, limit: Int = 20) async throws -> Bool {
        let list = store.list(convId)
        let conv = store.conversation(convId)
        guard list.hasMoreHistory else { return false }
        if conv == nil, list.oldestSeq == 0, store.maxSeq(convId) == 0 {
            return try await loadUnknown(convId, limit: limit)
        }
        let before = list.oldestSeq != 0 ? list.oldestSeq : max(conv?.maxSeq ?? 0, store.maxSeq(convId)) + 1
        if before <= (conv?.minSeq ?? 1) {
            list.hasMoreHistory = false
            return false
        }
        let ack = try await conn.request(
            SyncAck.self, "sync",
            ["convId": .string(convId), "beforeSeq": .int(before), "limit": .int(Int64(limit))])
        for m in ack.messages { _ = store.applyServerMessage(m) }
        list.hasMoreHistory = ack.hasMore
        emitMessages(convId)
        emitConversations()
        return ack.hasMore
    }

    /// Opening a conversation not known locally (PRD-ui G-UI-26): asks for the newest page without the local minSeq
    /// shortcut. 4032 / 4033 / 4043 are thrown as `IMError` for the UI, neither swallowed nor retried.
    private func loadUnknown(_ convId: String, limit: Int) async throws -> Bool {
        let list = store.list(convId)
        let ack = try await conn.request(
            SyncAck.self, "sync",
            ["convId": .string(convId), "beforeSeq": .int(maxSafeInteger), "limit": .int(Int64(limit))])
        for m in ack.messages { _ = store.applyServerMessage(m) }
        list.hasMoreHistory = ack.hasMore
        emitMessages(convId)
        if !ack.messages.isEmpty {
            emitConversations()
            refreshConversationsSoon()  // Replace the stand-in with server data.
        }
        return ack.hasMore
    }

    /// Sets the open conversation (nil outside the chat page), the basis of read reports.
    public func setActiveConversation(_ convId: String?) {
        active = convId
        maybeReportRead()
    }

    /// Call when the app's visibility changes (done automatically with `systemEvents`).
    public func visibilityChanged() {
        if isVisible() { provider?.foreground() }
        maybeReportRead()
        expireMutes()  // Timers may run late after suspension.
    }

    /// Call when the network returns (done automatically with `systemEvents`): reconnects without waiting for backoff.
    public func networkOnline() {
        conn.reconnectNow()
        expireMutes()
    }

    /// Refreshes the conversation list (PRD-ui G-UI-24), at most once per 30 seconds. Inside that window it returns the
    /// current list.
    @discardableResult
    public func refreshConversations() async throws -> [Conversation] {
        if clock.now() - lastRefreshAt < refreshThrottleMs || conn.state != .connected {
            return store.conversations()
        }
        lastRefreshAt = clock.now()
        applyConvs(try await conn.request(ConvsAck.self, "convs"))
        return store.conversations()
    }

    /// Whether the last conversation list was truncated to the newest 500 (C-03).
    public func truncated() -> Bool {
        store.truncated
    }

    /// The snapshot kept after being removed from a group; nil otherwise.
    public func conversationSnapshot(_ convId: String) -> ConversationSnapshot? {
        store.snapshot(convId)
    }

    public func totalUnread() -> Int64 {
        store.conversations().reduce(0) { $0 + $1.unread }
    }

    /// Queued, sending and failed messages across conversations.
    public func pendingCount() -> Int {
        store.pendingCount()
    }

    // MARK: Connection events

    private func onState(_ s: ConnState) {
        if s == .disconnected { pushSync.onDisconnected() }
        emit(.state(s))
        if s == .connected {
            if let b = bannerTimer { clock.clearTimeout(b) }
            bannerTimer = nil
            if bannerShown {
                bannerShown = false
                emit(.banner(false))
            }
        } else if !bannerShown, bannerTimer == nil {
            bannerTimer = clock.setTimeout(t.bannerDelayMs) { [weak self] in
                guard let self else { return }
                self.bannerTimer = nil
                if self.conn.state != .connected {
                    self.bannerShown = true
                    self.emit(.banner(true))
                }
            }
        }
    }

    /// Connected (or reconnected): convs -> catch up behind conversations -> report read (PRD F-CONN-01 rule 4).
    /// Queued messages go first, as soon as the user is known.
    private func onConnected(_ a: AuthAck) {
        if !me.isEmpty, me != a.userId { reset() }  // A different account.
        me = a.userId
        if database == nil { openDatabase(userId: a.userId) }
        serverOffset = a.serverTime - clock.now()
        if a.recoveryCodeUnacked {
            provider?.recoveryCodeUnacked()
            emit(.recoveryCodeUnacked)
        }
        mutes.setUser(a.mutedUntil)  // Absent means no user-level mute (it may have ended offline).
        mutesChanged()
        purgeOldRequests()
        flushQueued()
        pushSync.onAuth(userId: a.userId, serverTime: a.serverTime)  // Does not wait for convs (AC-PUSH-03-24).
        Task { [weak self] in await self?.runInitialSync() }
    }

    private func runInitialSync() async {
        do {
            let ack = try await conn.request(ConvsAck.self, "convs")
            applyConvs(ack)
            for c in ack.convs { try await catchUp(c) }
            maybeReportRead()
        } catch {
            log.warn("im: initial sync failed: \(describeForLog(error))")
        }
        // convs first, then one social round from the local socialVer (F-SOC-06 rule 10).
        social.needSync = true
        startSocialSync()
        await recheckDeleted()
    }

    /// Re-fetches loaded ranges after a reconnect: messages deleted while disconnected never produce `msgDeleted`, only
    /// `sync` reveals them (F-ADM-31 rule 5). Restored conversations are checked once per launch, conversations loaded
    /// from the network in this login on every reconnect.
    private func recheckDeleted() async {
        for (convId, from, to) in store.loadedRanges() {
            do {
                let list = store.list(convId)
                let changed = try await syncAfter(convId, after: from - 1, until: to)
                list.restoredUnverified = false
                if changed {
                    emitMessages(convId)
                    emitConversations()
                }
            } catch {
                log.warn("im: recheck deleted failed: \(describeForLog(error))")
                return
            }
        }
    }

    /// Catches one conversation up. Only those with local messages: unopened ones wait for `loadHistory`, otherwise a
    /// first login would fetch history for every conversation.
    private func catchUp(_ c: ServerConversation) async throws {
        let local = store.maxSeq(c.convId)
        if local == 0 || c.maxSeq <= local { return }
        let start = max(local, c.minSeq - 1)  // C-24
        let list = store.list(c.convId)
        if c.maxSeq - start > maxCatchUp {
            // Too large a gap: only the newest page, the middle comes from paging (AC-CONN-01-8).
            list.resetServer()
            let ack = try await conn.request(
                SyncAck.self, "sync",
                [
                    "convId": .string(c.convId), "beforeSeq": .int(c.maxSeq + 1),
                    "limit": .int(Int64(latestPageSize)),
                ])
            for m in ack.messages { _ = store.applyServerMessage(m) }
            list.hasMoreHistory = ack.hasMore
        } else {
            _ = try await syncAfter(c.convId, after: start, until: c.maxSeq)
        }
        emitMessages(c.convId)
        emitConversations()
    }

    /// Syncs forward from `after` until `until` or the end. Returns whether local messages changed.
    private func syncAfter(_ convId: String, after start: Int64, until: Int64) async throws -> Bool {
        var after = start
        var changed = false
        while true {
            let ack = try await conn.request(
                SyncAck.self, "sync",
                ["convId": .string(convId), "afterSeq": .int(after), "limit": .int(Int64(syncPageSize))])
            for m in ack.messages where store.applyServerMessage(m) { changed = true }
            let last = ack.messages.last?.seq ?? after
            if !ack.hasMore || last >= until || last <= after { return changed }
            after = last
        }
    }

    private func onFrame(_ f: InboundFrame) {
        if f.cmd == "msg" {
            guard let m = try? decodeFrameData(ServerMessage.self, from: f.raw) else {
                log.warn("im: bad msg frame")
                return
            }
            onMessage(m)
            return
        }
        if f.cmd == "push" {
            pushSync.onLive(raw: f.raw)
            return
        }
        guard f.cmd == "event", let type = f.eventType else { return }  // Unknown commands are ignored.
        do {
            try onEvent(type, raw: f.raw)
        } catch {
            log.warn("im: bad \(type) event")
        }
    }

    private struct ConvAddedEvent: Decodable { var conv: ServerConversation }
    private struct ConvRemovedEvent: Decodable {
        var convId: String
        var reason: String?
    }
    private struct ReadUpdatedEvent: Decodable {
        var convId: String
        var readSeq: Int64
    }
    private struct GroupChangedEvent: Decodable { var groupId: String }
    private struct MsgDeletedEvent: Decodable {
        var convId: String
        var msgIds: [String]?
        var seqs: [Int64]?
    }
    private struct MutedEvent: Decodable {
        var scope: String?
        var groupId: String?
        var mutedUntil: Until?
        private enum CodingKeys: String, CodingKey { case scope, groupId, mutedUntil }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = c.value(.scope, default: nil)
            groupId = c.value(.groupId, default: nil)
            // A malformed `muted` has no usable deadline; treated as forever only when explicitly null.
            mutedUntil = try c.decodeUntil(forKey: .mutedUntil)
        }
    }
    private struct SecurityNoticeEvent: Decodable {
        var kind: String
        var at: Int64
        var platform: String?
    }
    private struct SocialChangedEvent: Decodable { var ver: Int64 }
    private struct SettingsChangedEvent: Decodable {
        var mode: SocialMode
        var strangerMsgLimit: Int
    }

    private func onEvent(_ type: String, raw: Data) throws {
        switch type {
        case "securityNotice":
            let ev = try decodeFrameData(SecurityNoticeEvent.self, from: raw)
            if securityNoticeKinds.contains(ev.kind) {
                emit(.securityNotice(SecurityNotice(kind: ev.kind, at: ev.at, platform: ev.platform)))
            }
        case "convAdded":
            let ev = try decodeFrameData(ConvAddedEvent.self, from: raw)
            store.upsertConversation(ev.conv)
            setGroupMute(ev.conv.convId, ev.conv.mutedUntil, allMuted: ev.conv.allMuted)
            mutesChanged()
            emitConversations()
        case "convRemoved":
            let ev = try decodeFrameData(ConvRemovedEvent.self, from: raw)
            store.removeConversation(ev.convId, reason: ev.reason)
            setGroupMute(ev.convId, nil)  // Removal clears the group's mute (F-ADM-41 rule 4).
            mutesChanged()
            emitConversations()
            emit(.convRemoved(convId: ev.convId, reason: ev.reason))
        case "readUpdated":
            let ev = try decodeFrameData(ReadUpdatedEvent.self, from: raw)
            if store.advanceRead(ev.convId, ev.readSeq) { emitConversations() }
        case "groupChanged":
            onGroupChanged(try decodeFrameData(GroupChangedEvent.self, from: raw).groupId)
        case "msgDeleted":
            let ev = try decodeFrameData(MsgDeletedEvent.self, from: raw)
            onMsgDeleted(ev.convId, msgIds: ev.msgIds ?? [], seqs: ev.seqs ?? [])
        case "muted":
            let ev = try decodeFrameData(MutedEvent.self, from: raw)
            guard let until = ev.mutedUntil else { return }
            applyMute(scope: ev.scope, groupId: ev.groupId, until: until)
        case "unmuted":
            let ev = try decodeFrameData(MutedEvent.self, from: raw)
            applyMute(scope: ev.scope, groupId: ev.groupId, until: nil)
        case "socialChanged":
            social.onSocialChanged(try decodeFrameData(SocialChangedEvent.self, from: raw).ver)
            if social.needSync { syncSocialSoon() }
        case "socialSettingsChanged":
            let ev = try decodeFrameData(SettingsChangedEvent.self, from: raw)
            social.settings.mode = ev.mode
            social.settings.strangerMsgLimit = ev.strangerMsgLimit
            persistSocialMeta()
            emitSocial()
        default:
            break  // Unknown event types are ignored (protocol README section 3 rule 9).
        }
    }

    /// A deletion (PRD-admin F-ADM-31): wipes the text from memory and disk, turns the summary into a placeholder,
    /// leaves unread alone. If unconfirmed local messages exist (timed out, ack lost), the deleted one may be among
    /// them; the event only has msgId and seq, so pull from the server to match by clientMsgId and clear the queued
    /// copy as well.
    private func onMsgDeleted(_ convId: String, msgIds: [String], seqs: [Int64]) {
        let changed = store.deleteMessages(convId: convId, msgIds: msgIds, seqs: seqs)
        if changed { emitMessages(convId) }
        emitConversations()
        let list = store.list(convId)
        let top = seqs.max() ?? 0
        let local = store.maxSeq(convId)
        guard list.hasUnsent, top > local else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.syncAfter(convId, after: local != 0 ? local : top - 1, until: top)
                self.emitMessages(convId)
                self.emitConversations()
            } catch {
                self.log.warn("im: deleted sync failed: \(describeForLog(error))")
            }
        }
    }

    /// Updates the mute table. Unknown scopes are ignored. `until == nil` lifts the mute.
    private func applyMute(scope: String?, groupId: String?, until: Until?) {
        if scope == "user" {
            mutes.setUser(until)
        } else if scope == "group", let groupId {
            mutes.setGroup(groupId, until)
        } else if scope == "groupAll", let groupId {
            mutes.setGroupAll(groupId, on: until != nil)
        } else {
            return
        }
        mutesChanged()
    }

    /// `send` returned 4031: updates state from `details` so the UI shows the bar. The message only fails, no resend.
    private func onMutedAck(_ details: [String: JSONValue]?) {
        if details?["scope"]?.stringValue == "groupAll", let groupId = details?["groupId"]?.stringValue {
            onGroupAllDenied(groupId)
            return
        }
        guard let details, let value = details["mutedUntil"] else { return }
        let until: Until
        switch value {
        case .null: until = .permanent
        case .int(let t): until = .at(t)
        case .double(let t): until = .at(Int64(t))
        default: return
        }
        applyMute(scope: details["scope"]?.stringValue, groupId: details["groupId"]?.stringValue, until: until)
    }

    /// A send was refused under a group-wide mute: the server wins and the bar shows. If the local role still says
    /// owner or admin, it is stale, so fetch it again.
    private func onGroupAllDenied(_ groupId: String) {
        mutes.setGroupAll(groupId, on: true, denied: true)
        mutesChanged()
        let role = store.conversation(groupConvId(groupId))?.myRole
        if role == .owner || role == .admin { onGroupChanged(groupId) }
    }

    func setGroupMute(_ convId: String, _ until: Until?, allMuted: Bool = false) {
        guard convId.hasPrefix("group:") else { return }
        let groupId = String(convId.dropFirst("group:".count))
        mutes.setGroup(groupId, until)
        mutes.setGroupAll(groupId, on: allMuted)
    }

    /// A fresh role arrived (`groupInfo`).
    func groupRoleRefreshed(_ groupId: String) {
        mutes.clearGroupAllDenied(groupId)
        mutesChanged()
    }

    /// Emits on change, and re-arms for the earliest expiry.
    func mutesChanged() {
        if let m = muteTimer { clock.clearTimeout(m) }
        muteTimer = nil
        // Whether a group-wide mute restricts me also depends on my role: tell the UI when that changes too.
        let roles = mutes.groupAllIds.map { store.conversation(groupConvId($0))?.myRole }
        if mutes != lastMutes || roles != lastGroupAllRoles {
            lastMutes = mutes
            lastGroupAllRoles = roles
            emit(.muteChanged)
        }
        guard let next = mutes.nextExpiry() else { return }
        let wait = min(max(0, next - serverNow()), muteTimerMaxMs)
        muteTimer = clock.setTimeout(wait) { [weak self] in
            guard let self else { return }
            self.muteTimer = nil
            self.expireMutes()
        }
    }

    private func expireMutes() {
        mutes.purge(now: serverNow())
        mutesChanged()
    }

    /// Internal: whether a mute timer is armed (test visibility for "no timer loop left behind").
    var hasMuteTimer: Bool { muteTimer != nil }

    /// A live message: merge, detect gaps (F-MSG-04 rule 2), report read when needed.
    private func onMessage(_ m: ServerMessage) {
        let prev = store.maxSeq(m.convId)
        guard store.applyServerMessage(m) else { return }
        // A tip's summary follows the server's rule (nicknames only, F-SOC-29 rule 6) until the next `convs`
        // overwrites it. Refetching would make every online member of a big group request at once.
        if m.type == .tip, let tip = m.body?.tip {
            let text = tipSummary(tip) { self.profileOf($0)?.nickname ?? $0 }
            store.setLastMsgText(convId: m.convId, msgId: m.msgId, text: text)
        }
        emitMessages(m.convId)
        emitConversations()
        if store.hasPlaceholder(m.convId) { refreshConversationsSoon() }
        // Only for already-loaded conversations: prev == 0 means none of its messages are here.
        if prev > 0, m.seq > prev + 1 { scheduleGapCheck(m.convId, after: prev, until: m.seq) }
        if m.convId == active { maybeReportRead() }
    }

    /// After a stand-in conversation appears: refetch `convs` shortly to replace it (name, minSeq, unread). Several
    /// triggers within 200ms merge into one.
    private func refreshConversationsSoon() {
        guard refreshTimer == nil, conn.state == .connected else { return }
        refreshTimer = clock.setTimeout(200) { [weak self] in
            guard let self else { return }
            self.refreshTimer = nil
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.applyConvs(try await self.conn.request(ConvsAck.self, "convs"))
                } catch {
                    self.log.warn("im: refresh conversations failed: \(describeForLog(error))")
                }
            }
        }
    }

    /// Applies a `convs` result. Groups present before and absent now count as removed (not when truncated).
    func applyConvs(_ ack: ConvsAck) {
        let gone = store.setConversations(ack.convs, truncated: ack.truncated)
        lastRefreshAt = clock.now()
        for c in ack.convs {
            setGroupMute(c.convId, c.mutedUntil, allMuted: c.allMuted)
            // Having missed msgDeleted, the summary is the only clue: wipe the loaded copy too.
            if let l = c.lastMsg, l.deleted == true,
                store.deleteMessages(convId: c.convId, msgIds: [l.msgId], seqs: [])
            {
                emitMessages(c.convId)
            }
        }
        for id in gone { setGroupMute(id, nil) }
        mutesChanged()
        emitConversations()
        for id in gone { emit(.convRemoved(convId: id, reason: nil)) }
    }

    private func scheduleGapCheck(_ convId: String, after: Int64, until: Int64) {
        guard gapTimers[convId] == nil else { return }
        gapTimers[convId] = clock.setTimeout(t.gapWaitMs) { [weak self] in
            guard let self else { return }
            self.gapTimers[convId] = nil
            let list = self.store.list(convId)
            var missing = false
            var s = after + 1
            while s < until {
                if !list.has(seq: s) {
                    missing = true
                    break
                }
                s += 1
            }
            guard missing else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.syncAfter(convId, after: after, until: until)
                    self.emitMessages(convId)
                    self.emitConversations()
                } catch {
                    self.log.warn("im: gap sync failed: \(describeForLog(error))")
                }
            }
        }
    }

    /// Kicked or a non-reconnecting close: sending and queued messages fail (AC-AUTH-03-6), social state and the local
    /// database are cleared (PRD-social 10.2, FE-141), the UI goes back to login.
    private func onFatal(_ r: FatalReason) {
        bindProvider(nil)
        clearSocial()
        for id in store.allListIds() { failPending(id) }
        destroyDatabase()
        emit(.fatal(r))
    }

    private func failPending(_ convId: String) {
        let list = store.list(convId)
        let pending = list.pendingMessages()
        for m in pending {
            list.update(m.clientMsgId) {
                $0.status = .failed
                $0.error = .kicked
            }
        }
        if !pending.isEmpty { emitMessages(convId) }
        for m in pending { emit(.sendFailed(convId: convId, clientMsgId: m.clientMsgId, error: .kicked)) }
    }

    // MARK: Sending

    private func dispatch(_ convId: String, _ clientMsgId: String) {
        let list = store.list(convId)
        guard
            let m = list.update(
                clientMsgId,
                {
                    $0.status = .sending
                    $0.error = nil
                })
        else { return }
        emitMessages(convId)
        guard let parsed = try? parseConvId(convId, me: me) else { return }
        let type = m.type
        // The body is read when the ack arrives: the message may have been deleted meanwhile, so the callback must not
        // hold its own copy of the text.
        let onAck: @MainActor (SendAck) -> Void = { [weak self, weak list] ack in
            guard let self, let list else { return }
            _ = self.store.applyServerMessage(
                ServerMessage(
                    msgId: ack.msgId, clientMsgId: clientMsgId, convId: ack.convId, seq: ack.seq, from: self.me,
                    type: type, body: list.local(clientMsgId)?.body, ts: ack.ts, deleted: nil, deletedAt: nil))
            self.emitMessages(convId)
            self.emitConversations()
            if self.store.hasPlaceholder(convId) { self.refreshConversationsSoon() }
        }
        let data: JSONValue = [
            "convType": .string(parsed.convType.rawValue),
            "to": .string(parsed.to),
            "clientMsgId": .string(clientMsgId),
            "type": .string(m.type.rawValue),
            "body": m.body.json,
        ]
        conn.request(
            "send", data, timeoutMs: t.sendTimeoutMs,
            // The ack arrived after the timeout: it wins, the message becomes sent (C-30).
            onLateAck: { [weak self] result in
                switch result {
                case .success(let raw):
                    if let ack = try? decodeFrameData(SendAck.self, from: raw) { onAck(ack) }
                case .failure(let err):
                    if err.code == ErrorCode.muted { self?.onMutedAck(err.details) }
                }
            },
            completion: { [weak self, weak list] result in
                guard let self, let list else { return }
                switch result {
                case .success(let raw):
                    if let ack = try? decodeFrameData(SendAck.self, from: raw) {
                        onAck(ack)
                    } else {
                        self.fail(convId, clientMsgId, .timeout)
                    }
                case .failure(let err):
                    if let im = err as? IMError, im.code == ErrorCode.muted { self.onMutedAck(im.details) }
                    // Another path may already have changed the state (e.g. kicked): only handle "still sending".
                    guard list.local(clientMsgId)?.status == .sending else { return }
                    if let im = err as? IMError {
                        self.fail(convId, clientMsgId, .code(im.code))
                    } else if case IMConnectionError.timeout = err {
                        self.fail(convId, clientMsgId, .timeout)
                    } else if !self.autoUsed.contains(clientMsgId) {
                        // The connection dropped after sending: one automatic resend after reconnect (F-MSG-03 rule 2).
                        self.autoUsed.insert(clientMsgId)
                        list.update(clientMsgId) { $0.status = .queued }
                        self.emitMessages(convId)
                    } else {
                        self.fail(convId, clientMsgId, .timeout)
                    }
                }
            })
    }

    private func fail(_ convId: String, _ clientMsgId: String, _ error: SendFailure) {
        let list = store.list(convId)
        guard let m = list.local(clientMsgId), m.status == .sending else { return }  // A late ack already won.
        list.update(clientMsgId) {
            $0.status = .failed
            $0.error = error
        }
        emitMessages(convId)
        emit(.sendFailed(convId: convId, clientMsgId: clientMsgId, error: error))
    }

    /// Sends queued messages after a reconnect; each goes out automatically once.
    private func flushQueued() {
        for c in store.allListIds().sorted(by: bytesLess) {
            for m in store.list(c).pendingMessages() where m.status == .queued {
                autoUsed.insert(m.clientMsgId)
                dispatch(c, m.clientMsgId)
            }
        }
    }

    // MARK: Read reports

    /// Reports read when visible, in that conversation, with something unread, at most once per second
    /// (PRD F-CONV-02 rule 3). Local unread clears at once; the report carries the latest seq.
    private func maybeReportRead() {
        guard let convId = active, isVisible(), conn.state == .connected else { return }
        guard let c = store.conversation(convId) else { return }
        let latest = max(c.maxSeq, store.maxSeq(convId))
        guard latest > c.readSeq else { return }
        let wait = lastRead + t.readThrottleMs - clock.now()
        if wait > 0 {
            if readTimer == nil {
                readTimer = clock.setTimeout(wait) { [weak self] in
                    guard let self else { return }
                    self.readTimer = nil
                    self.maybeReportRead()
                }
            }
            return
        }
        lastRead = clock.now()
        _ = store.advanceRead(convId, latest)
        emitConversations()
        conn.request("read", ["convId": .string(convId), "seq": .int(latest)]) { [weak self] result in
            if case .failure(let err) = result {
                self?.log.warn("im: read failed: \(describeForLog(err))")
            }
        }
    }

    // MARK: Emitting

    func emitConversations() {
        commit()
        emit(.conversations(store.conversations()))
        let total = totalUnread()
        if total != lastTotalUnread {
            lastTotalUnread = total
            emit(.totalUnread(Int(total)))
        }
    }

    func emitMessages(_ convId: String) {
        commit()
        emit(.messages(convId: convId, messages: store.messages(convId)))
        emitPendingCount()
    }

    private func emitPendingCount() {
        let n = pendingCount()
        if n != lastPendingCount {
            lastPendingCount = n
            emit(.pendingCount(n))
        }
    }

    private func reset() {
        for timer in gapTimers.values { clock.clearTimeout(timer) }
        gapTimers = [:]
        if let r = readTimer { clock.clearTimeout(r) }
        readTimer = nil
        destroyDatabase()
        pushSync.logout()
        store = Store(me: { [unowned self] in MainActor.assumeIsolated { self.me } })
        mutes.clear()
        mutesChanged()
        clearSocial()
        autoUsed = []
        active = nil
        lastRead = Int64.min / 2
        emitConversations()
        emitPendingCount()
    }

    // MARK: Local database

    private func openDatabase(userId: String) {
        guard database == nil, let dir = databaseDirectory else { return }
        let url = dir.appendingPathComponent(LocalDatabase.fileName(userId: userId))
        do {
            database = try openOrRebuild(url: url)
            let chat = try database!.loadChat(maxMessagesPerConversation: maxCached)
            store.restore(convStates: chat.conversations, messages: chat.messages)
            if let s = try database!.loadSocial() { restoreSocial(s) }
            emitConversations()
            emitSocial()
        } catch {
            log.warn("im: local database unavailable: \(describeForLog(error))")
            database?.destroy()
            database = nil
        }
    }

    /// Opens the cache; a damaged file is removed and rebuilt, since the server has everything again.
    private func openOrRebuild(url: URL) throws -> LocalDatabase {
        do {
            return try LocalDatabase(url: url)
        } catch {
            log.warn("im: rebuilding local database")
            LocalDatabase.removeFiles(at: url)
            return try LocalDatabase(url: url)
        }
    }

    /// Writes everything pending to the database. Called before each UI notification, so what a listener can observe
    /// is already on disk. A failed write drops the whole cache rather than risk keeping deleted text.
    func commit() {
        guard let db = database else {
            _ = store.drainChanges()
            return
        }
        do {
            try db.apply(store.drainChanges())
        } catch {
            dropDatabaseAfterFailure(error)
        }
    }

    func dropDatabaseAfterFailure(_ error: Error) {
        log.warn("im: local database write failed, dropping the cache: \(describeForLog(error))")
        destroyDatabase()
    }

    func destroyDatabase() {
        database?.destroy()
        database = nil
    }
}

/// Text for a log line: never includes message text or the token.
func describeForLog(_ error: Error) -> String {
    switch error {
    case let e as IMError: return "code \(e.code)"
    case let e as IMConnectionError:
        switch e {
        case .timeout(let cmd): return "timeout \(cmd)"
        case .closed: return "closed"
        case .notConnected: return "notConnected"
        case .badResponse(let cmd): return "badResponse \(cmd)"
        }
    case let e as LocalDatabaseError: return e.description
    default: return String(describing: type(of: error))
    }
}
