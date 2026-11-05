import Foundation

// System pushes (PRD-live v1.1 sections 4.3, 4.5, 4.8, 4.9; rules C1-C12). What all SDKs must agree on is
// protocol/vectors/push-sync.json.

/// Where a device with no cursor starts (C10). `.latest` only establishes a cursor, no replay: for the gray rollout.
public enum PushStart: String, Sendable {
    case beginning, latest
}

/// One push handed to the app (section 4.8). `data` belongs to the app: the SDK never logs it (F-PUSH-08 rule 3).
/// The text forms of this type leave `data` out too, so printing a push by accident does not leak it.
public struct Push: Sendable, Equatable {
    public let pushId: String
    public let type: String
    public let data: JSONValue
    public let ts: Int64
    public let target: String
    public let roomId: String?
    public let pushSeq: Int64?
    /// `ts` is earlier than this instance's first auth of this account (section 4.5 rule 4).
    public let replayed: Bool

    public init(
        pushId: String, type: String, data: JSONValue, ts: Int64, target: String, roomId: String? = nil,
        pushSeq: Int64? = nil, replayed: Bool = false
    ) {
        self.pushId = pushId
        self.type = type
        self.data = data
        self.ts = ts
        self.target = target
        self.roomId = roomId
        self.pushSeq = pushSeq
        self.replayed = replayed
    }
}

extension Push: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "Push(\(pushId), type: \(type), target: \(target), pushSeq: \(pushSeq.map(String.init) ?? "-"), replayed: \(replayed))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["pushId": pushId, "type": type, "target": target, "replayed": replayed])
    }
}

/// None of these are calibrated (sections 4.3, 4.4). Tests and rollouts may override them.
public struct PushLimits: Sendable {
    public var stashMax = 200
    public var noSeqQueueMax = 500
    public var seenMax = 2000
    public var gapWaitMs: Int64 = 500
    public var stashFlushMs: Int64 = 5000
    public var backoffMs: [Int64] = [1000, 2000, 4000, 8000, 16000, 30000]

    public init() {}
}

/// Stores the push cursor, separately from the local database (section 4.9): the database is a disposable cache that
/// logout, kicks, corruption and schema upgrades all delete, and a cursor lost with it replays the whole inbox.
/// Holds numbers and pushIds only, never push content. A failed `load` counts as no cursor.
public protocol PushCursorStore: Sendable {
    func load(userId: String) throws -> PushCursorRecord?
    func save(userId: String, cursor: Int64?, recentIds: [String]) throws
}

public struct PushCursorRecord: Sendable, Equatable, Codable {
    /// nil only before `pushStart = .latest` has established a cursor.
    public var cursor: Int64?
    /// In delivery order, oldest first.
    public var recentIds: [String]

    public init(cursor: Int64?, recentIds: [String]) {
        self.cursor = cursor
        self.recentIds = recentIds
    }
}

/// One small JSON file per user, in a directory of its own under Application Support (section 4.9). Writes are atomic: a
/// process killed mid-write leaves the previous batch, so at most one batch is delivered again (AC-PUSH-08-7).
public final class FilePushCursorStore: PushCursorStore {
    public let directory: URL

    /// Application Support/tianting-push-cursors. Survives logout and the local database; goes with the app's data.
    public static var defaultDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("tianting-push-cursors", isDirectory: true)
    }

    public init(directory: URL = FilePushCursorStore.defaultDirectory) {
        self.directory = directory
    }

    /// Hex of the userId, like the database file: case-insensitive file systems must not merge alice and Alice.
    func fileURL(userId: String) -> URL {
        let hex = userId.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("push-\(hex).json")
    }

    public func load(userId: String) throws -> PushCursorRecord? {
        let url = fileURL(userId: userId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PushCursorRecord.self, from: Data(contentsOf: url))
    }

    public func save(userId: String, cursor: Int64?, recentIds: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A new device replays on purpose (section 4.9), so the cursor stays out of backups.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(resource)
        let data = try JSONEncoder().encode(PushCursorRecord(cursor: cursor, recentIds: recentIds))
        try data.write(to: fileURL(userId: userId), options: .atomic)
    }
}

/// SDK fixed (section 4.2).
private let syncLimit: Int64 = 100
private let maxSafeInteger: Int64 = 9_007_199_254_740_991

private struct PushFrame {
    let pushId: String
    let type: String
    let data: JSONValue
    let ts: Int64
    let target: String
    let roomId: String?
    let pushSeq: Int64?

    init?(_ raw: JSONValue) {
        guard let pushId = raw["pushId"]?.stringValue, let type = raw["type"]?.stringValue,
            let target = raw["target"]?.stringValue
        else { return nil }
        switch raw["ts"] {
        case .int(let v): ts = v
        case .double(let v) where v.isFinite && abs(v) < 9e15: ts = Int64(v)
        default: return nil
        }
        if let seq = raw["pushSeq"] {
            guard let v = seq.intValue, v > 0, v <= maxSafeInteger else { return nil }
            pushSeq = v
        } else {
            pushSeq = nil
        }
        self.pushId = pushId
        self.type = type
        self.target = target
        data = raw["data"] ?? .null
        roomId = raw["roomId"]?.stringValue
    }
}

/// The dedupe set: evicts in delivery order; a hit does not refresh (section 4.4, AC-PUSH-06-18).
private struct SeenIds {
    private var order: [String] = []
    private var head = 0
    private var set: Set<String> = []

    func contains(_ id: String) -> Bool { set.contains(id) }

    mutating func insert(_ id: String, max: Int) {
        guard set.insert(id).inserted else { return }
        order.append(id)
        while set.count > max {
            set.remove(order[head])
            head += 1
        }
        if head > 4096, head > order.count / 2 {
            order.removeFirst(head)
            head = 0
        }
    }

    var ordered: [String] { Array(order[head...]) }
}

/// The single-cursor catch-up state machine. `cursor` is the highest contiguous sequence delivered. Frames with a
/// `pushSeq` can always come back from the inbox, so they are dropped without a subscriber and the stash may be cleared
/// when full; only frames without one are queued (C4).
///
/// Everything runs on the main actor, which is the serial queue section 4.8 asks for. A subscription takes effect at the
/// next scheduling point: a main-actor task, or the next network or timer event if that comes first.
@MainActor
final class PushSync {
    typealias Request = @MainActor (JSONValue, @escaping @MainActor (Result<Data, Error>) -> Void) -> Void

    private let clock: IMClock
    private let log: IMLogger
    private let pushStart: PushStart
    private let limits: PushLimits
    private let store: PushCursorStore?
    private let request: Request

    private var subs: [(id: Int, fn: @MainActor (Push) -> Void)] = []
    private var nextId = 0
    private var syncedHandlers: [(id: Int, fn: @MainActor (Int64) -> Void)] = []
    private var pendingActivation = false  // Registered, the scheduling point has not come yet.
    private var activated = false  // Reached the scheduling point and still has subscribers.
    private var generation = 0  // Bumped when the last subscriber leaves or on logout: running delivery loops stop.

    private var user: String?
    private var t0: Int64 = 0
    private var cursorValue: Int64?
    private var seen = SeenIds()
    private var dirty = false  // Delivered or moved since the last save.
    private var noSeqQueue: [PushFrame] = []
    private var stash: [Int64: PushFrame] = [:]

    private var connected = false
    private var disabled = false  // This connection got 4001 (C9).
    private var inflight: InFlight?
    private var requestCounter = 0
    private var failed = false
    private var attempt = 0
    private var roundMax: Int64 = 0  // The highest pushSeq delivered in this round (section 4.8).
    private var gapTimer: TimerHandle?
    private var flushTimer: TimerHandle?
    private var backoffTimer: TimerHandle?

    private struct InFlight {
        let id: Int
        let afterSeq: Int64?  // nil: fromLatest.
    }

    init(
        clock: IMClock, log: IMLogger, pushStart: PushStart, limits: PushLimits, store: PushCursorStore?,
        request: @escaping Request
    ) {
        self.clock = clock
        self.log = log
        self.pushStart = pushStart
        self.limits = limits
        self.store = store
        self.request = request
    }

    var cursor: Int64? { cursorValue }

    // MARK: Subscribers

    func subscribe(_ fn: @escaping @MainActor (Push) -> Void) -> @MainActor @Sendable () -> Void {
        nextId += 1
        let id = nextId
        subs.append((id, fn))
        if !activated, !pendingActivation {
            pendingActivation = true
            Task { @MainActor [weak self] in self?.schedulingPoint() }
        }
        return { [weak self] in self?.unsubscribe(id) }
    }

    func subscribeSynced(_ fn: @escaping @MainActor (Int64) -> Void) -> @MainActor @Sendable () -> Void {
        nextId += 1
        let id = nextId
        syncedHandlers.append((id, fn))
        return { [weak self] in self?.syncedHandlers.removeAll { $0.id == id } }
    }

    private func unsubscribe(_ id: Int) {
        let before = subs.count
        subs.removeAll { $0.id == id }
        if subs.count != before, subs.isEmpty { stop() }
    }

    private func schedulingPoint() {
        guard pendingActivation else { return }
        activate()
        saveIfDirty()
    }

    private func activate() {
        pendingActivation = false
        guard !subs.isEmpty, !activated else { return }
        activated = true
        while !noSeqQueue.isEmpty {
            if !deliver(noSeqQueue.removeFirst()) { return }
        }
        if connected, inflight == nil { startRound() }
    }

    /// All subscribers left (C12). An open request is not cancelled: its late ack is dropped, and if a subscriber is back
    /// by then it is handled normally, without sending a second one.
    private func stop() {
        generation += 1
        activated = false
        stash = [:]
        failed = false
        attempt = 0
        roundMax = 0
        cancelTimers()
    }

    // MARK: Connection and account

    /// Auth succeeded, reconnects included. Does not wait for `convs` or `socialSync` (AC-PUSH-03-24).
    func onAuth(userId: String, serverTime: Int64) {
        if user != userId {
            logout()
            user = userId
            t0 = serverTime
            loadStored(userId)
        }
        connected = true
        disabled = false
        if pendingActivation {
            activate()
        } else if activated {
            startRound()
        }
        saveIfDirty()
    }

    /// The connection ended: an open request counts as failed, timers and backoff reset, the stash stays to merge after the
    /// reconnect (C9).
    func onDisconnected() {
        connected = false
        if pendingActivation { activate() }  // The scheduling point comes before any network event.
        inflight = nil
        failed = false
        attempt = 0
        cancelTimers()
        saveIfDirty()
    }

    /// Clears everything held for the account. With a store, the cursor and the seen ids stay on disk under its key.
    func logout() {
        saveIfDirty()
        connected = false
        inflight = nil
        failed = false
        attempt = 0
        cancelTimers()
        generation += 1
        user = nil
        t0 = 0
        cursorValue = nil
        seen = SeenIds()
        dirty = false
        noSeqQueue = []
        stash = [:]
        roundMax = 0
        disabled = false
    }

    private func loadStored(_ userId: String) {
        var record: PushCursorRecord?
        if let store {
            do {
                record = try store.load(userId: userId)
            } catch {
                log.warn("im: push cursor unreadable: \(describeForLog(error))")
            }
        }
        cursorValue = record?.cursor ?? (pushStart == .latest ? nil : 0)
        for id in record?.recentIds ?? [] { seen.insert(id, max: limits.seenMax) }
        dirty = false
    }

    /// One batch per event (section 4.9): after the delivery, so dying in between repeats at most this batch.
    private func saveIfDirty() {
        guard dirty, let user else { return }
        dirty = false
        guard let store else { return }
        do {
            try store.save(userId: user, cursor: cursorValue, recentIds: seen.ordered)
        } catch {
            log.warn("im: push cursor not saved: \(describeForLog(error))")
        }
    }

    private func setCursor(_ value: Int64) {
        if cursorValue != value { dirty = true }
        cursorValue = value
    }

    // MARK: Live frames

    func onLive(raw: Data) {
        if pendingActivation { activate() }  // The scheduling point comes before any network event (section 4.8).
        defer { saveIfDirty() }
        guard let body = try? decodeFrameData(JSONValue.self, from: raw), let f = PushFrame(body) else {
            log.warn("im: invalid push frame")
            return
        }
        guard user != nil else { return }
        guard let seq = f.pushSeq else {
            if activated {
                _ = deliver(f)
            } else {
                noSeqQueue.append(f)
                if noSeqQueue.count > limits.noSeqQueueMax { noSeqQueue.removeFirst() }
            }
            return
        }
        guard activated else { return }  // C12
        guard let cursor = cursorValue else {
            addToStash(f)  // C10: before the fromLatest ack.
            return
        }
        if seq <= cursor {
            _ = deliver(f)  // C3
        } else if seq == cursor + 1 {
            guard deliver(f) else { return }
            setCursor(seq)  // C1
            _ = drainStash(allowTimer: true)
        } else {
            addToStash(f)  // C2
            armGapTimer()
        }
    }

    /// Delivers one frame (one already seen counts as done). False means a callback stopped things: the caller must not
    /// move the cursor or carry on.
    private func deliver(_ f: PushFrame) -> Bool {
        if seen.contains(f.pushId) { return true }
        seen.insert(f.pushId, max: limits.seenMax)
        dirty = true
        if let seq = f.pushSeq, seq > roundMax { roundMax = seq }
        let gen = generation
        let item = Push(
            pushId: f.pushId, type: f.type, data: f.data, ts: f.ts, target: f.target, roomId: f.roomId,
            pushSeq: f.pushSeq, replayed: f.ts < t0)
        for (id, fn) in subs {
            guard subs.contains(where: { $0.id == id }) else { continue }  // An earlier callback unsubscribed it.
            fn(item)
        }
        return gen == generation
    }

    private func addToStash(_ f: PushFrame) {
        let seq = f.pushSeq!
        if stash[seq] == nil, stash.count >= limits.stashMax { stash = [:] }  // All of those can come back.
        stash[seq] = f
        if failed { armFlushTimer() }
    }

    /// C11: takes the frames that connect, in order.
    private func drainStash(allowTimer: Bool) -> Bool {
        for seq in stash.keys.sorted() {
            guard let cursor = cursorValue, seq <= cursor + 1, let f = stash[seq] else { break }
            stash[seq] = nil
            guard deliver(f) else { return false }
            if seq == cursor + 1 { setCursor(seq) }
        }
        if stash.isEmpty {
            cancelGapTimer()
            cancelFlushTimer()
        } else if allowTimer {
            armGapTimer()
        }
        return true
    }

    // MARK: Timers

    private func armGapTimer() {
        guard gapTimer == nil, !stash.isEmpty, connected, !disabled, inflight == nil, backoffTimer == nil else { return }
        gapTimer = clock.setTimeout(limits.gapWaitMs) { [weak self] in
            guard let self else { return }
            self.gapTimer = nil
            self.startRound()
        }
    }

    private func armFlushTimer() {
        guard flushTimer == nil, !stash.isEmpty else { return }
        flushTimer = clock.setTimeout(limits.stashFlushMs) { [weak self] in
            guard let self else { return }
            self.flushTimer = nil
            let frames = self.stash.keys.sorted().compactMap { self.stash[$0] }
            self.stash = [:]
            defer { self.saveIfDirty() }
            // The cursor stays: the next catch-up skips these by pushId.
            for f in frames where !self.deliver(f) { return }
        }
    }

    private func cancelGapTimer() {
        if let h = gapTimer { clock.clearTimeout(h) }
        gapTimer = nil
    }

    private func cancelFlushTimer() {
        if let h = flushTimer { clock.clearTimeout(h) }
        flushTimer = nil
    }

    private func cancelTimers() {
        cancelGapTimer()
        cancelFlushTimer()
        if let h = backoffTimer { clock.clearTimeout(h) }
        backoffTimer = nil
    }

    // MARK: pushSync

    /// A round begins here: pages and backoff retries are not new rounds (section 4.8).
    private func startRound() {
        guard connected, !disabled, inflight == nil else { return }
        roundMax = 0
        send()
    }

    private func send() {
        requestCounter += 1
        let id = requestCounter
        let afterSeq = cursorValue
        inflight = InFlight(id: id, afterSeq: afterSeq)
        cancelGapTimer()
        let data: JSONValue =
            if let afterSeq {
                ["afterSeq": .int(afterSeq), "limit": .int(syncLimit)]
            } else {
                ["fromLatest": true]
            }
        // A callback, not async/await: the ack is handled in frame order, before the frame that followed it.
        request(data) { [weak self] result in
            guard let self, let req = self.inflight, req.id == id else { return }  // C5: stale acks are ignored.
            defer { self.saveIfDirty() }
            switch result {
            case .success(let raw): self.onAck(req, raw)
            case .failure(let error): self.onFail(error)
            }
        }
    }

    private func onFail(_ error: Error) {
        inflight = nil
        if let e = error as? IMError, e.code == ErrorCode.unknownCmd {
            disabled = true  // The server has pushes off: stay quiet for this connection (C9).
            cancelGapTimer()
            return
        }
        log.warn("im: pushSync failed: \(describeForLog(error))")
        guard activated else { return }
        failed = true
        let delay = limits.backoffMs[min(attempt, limits.backoffMs.count - 1)]
        attempt += 1
        backoffTimer = clock.setTimeout(delay) { [weak self] in
            guard let self else { return }
            self.backoffTimer = nil
            self.send()
        }
        armFlushTimer()
    }

    private func onAck(_ req: InFlight, _ raw: Data) {
        inflight = nil
        guard activated else { return }  // C12: a late ack is dropped, nothing delivered, the cursor stays.
        guard let body = try? decodeFrameData(JSONValue.self, from: raw), let latestSeq = body["latestSeq"]?.intValue
        else {
            onFail(IMConnectionError.badResponse(cmd: "pushSync"))
            return
        }
        guard let afterSeq = req.afterSeq else {
            succeeded()
            setCursor(latestSeq)  // C10: pushes and hasMore are ignored.
            if drainStash(allowTimer: true) { finishRound(latestSeq) }
            return
        }
        guard let pushes = body["pushes"]?.arrayValue, case .bool(let hasMore)? = body["hasMore"] else {
            onFail(IMConnectionError.badResponse(cmd: "pushSync"))
            return
        }
        var page: [PushFrame] = []
        var pageMax: Int64 = 0
        for item in pushes {
            guard let f = PushFrame(item), let seq = f.pushSeq else {
                log.warn("im: invalid push in pushSync ack")
                continue
            }
            page.append(f)
            pageMax = max(pageMax, seq)
        }
        if hasMore {
            guard pageMax > afterSeq else {
                // C6: breaks the server's guarantee; failing avoids spinning on the same request.
                onFail(IMConnectionError.badResponse(cmd: "pushSync"))
                return
            }
            succeeded()
            guard deliverPage(page, upTo: pageMax) else { return }
            setCursor(max(cursorValue ?? 0, pageMax))
            if drainStash(allowTimer: false) { send() }  // C6: connect the stash, then the next page.
            return
        }
        succeeded()
        if latestSeq < afterSeq {
            // C8: the server restored from a backup. Skips C11, restarts the round, pushId dedupes.
            setCursor(0)
            stash = [:]
            cancelTimers()
            roundMax = 0
            saveIfDirty()
            send()
            return
        }
        guard deliverPage(page, upTo: latestSeq) else { return }
        setCursor(max(cursorValue ?? 0, latestSeq))  // C7: moves even on an empty result, so an expired tail cannot hold it.
        if drainStash(allowTimer: true) { finishRound(latestSeq) }
    }

    private func succeeded() {
        failed = false
        attempt = 0
        cancelFlushTimer()
    }

    /// C6, C7: merges the page with stashed frames not above `limit`, delivers in order, skips what was seen.
    private func deliverPage(_ page: [PushFrame], upTo limit: Int64) -> Bool {
        var merged = page
        for seq in stash.keys.sorted() where seq <= limit {
            if let f = stash.removeValue(forKey: seq) { merged.append(f) }
        }
        merged.sort { $0.pushSeq! < $1.pushSeq! }
        for f in merged where !deliver(f) { return false }
        return true
    }

    private func finishRound(_ latestSeq: Int64) {
        let value = max(latestSeq, roundMax)
        for (_, fn) in syncedHandlers { fn(value) }
    }
}
