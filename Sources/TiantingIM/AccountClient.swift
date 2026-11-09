import Foundation

// MARK: - Errors

/// An account endpoint's error: HTTP status + {code, msg, reason?, details?}.
public struct AccountError: Error, Sendable, Equatable {
    public let status: Int
    public let code: Int
    public let message: String
    public let reason: String?
    public let details: [String: JSONValue]?

    public init(status: Int, code: Int, message: String = "", reason: String? = nil, details: [String: JSONValue]? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.reason = reason
        self.details = details
    }
}

/// No error code from the server: the network failed, or the response was not the agreed JSON (a proxy's HTML page).
/// Never carries the underlying error: its text can hold a URL.
public enum AccountNetworkError: Error, Sendable, Equatable {
    case network
    /// No response in 30 seconds. A late one is dropped.
    case timeout
    case invalidResponse
    /// A status without a usable body.
    case status(Int)
    /// The response arrived but the session could not be stored.
    case saveFailed
}

/// No usable account session: not logged in, or it ended (`.ended`). `end`: when `accessToken()` throws, the most recent
/// end; nil when there never was a session.
public struct SessionEndedError: Error, Sendable, Equatable {
    public var end: SessionEnd?

    public init(end: SessionEnd? = nil) {
        self.end = end
    }
}

// MARK: - Session

public enum SessionMode: String, Sendable, Codable {
    case account, demo
}

/// The session the app keeps in the Keychain (F-ACC-03 rule 8). Never printed: `description` and `dump` hide credentials.
///
/// `Codable`, so the app can store it as is. Reading tolerates older shapes: no `mode` means `demo`, and the old
/// `{userId, token}` becomes a demo session (R-CF-11).
public struct AccountSession: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var mode: SessionMode
    public var userId: String
    public var accessToken: String
    /// 0 for a demo session of the old shape.
    public var accessExpiresAt: Int64
    public var refreshToken: String?
    public var refreshExpiresAt: Int64?
    public var absoluteExpiresAt: Int64?

    public init(
        mode: SessionMode = .demo, userId: String, accessToken: String, accessExpiresAt: Int64, refreshToken: String? = nil,
        refreshExpiresAt: Int64? = nil, absoluteExpiresAt: Int64? = nil
    ) {
        self.mode = mode
        self.userId = userId
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
        self.absoluteExpiresAt = absoluteExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case mode, userId, accessToken, accessExpiresAt, refreshToken, refreshExpiresAt, absoluteExpiresAt
        case legacyToken = "token"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        if let token = try c.decodeIfPresent(String.self, forKey: .accessToken) {
            accessToken = token
        } else {
            accessToken = try c.decode(String.self, forKey: .legacyToken)
        }
        // A mode this version does not know is not trusted as an account session.
        mode = (try? c.decodeIfPresent(SessionMode.self, forKey: .mode)) ?? .demo
        accessExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .accessExpiresAt) ?? 0
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        refreshExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .refreshExpiresAt)
        absoluteExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .absoluteExpiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(userId, forKey: .userId)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encode(accessExpiresAt, forKey: .accessExpiresAt)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(refreshExpiresAt, forKey: .refreshExpiresAt)
        try c.encodeIfPresent(absoluteExpiresAt, forKey: .absoluteExpiresAt)
    }

    public var description: String { "AccountSession(mode: \(mode.rawValue), userId: \(userId))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["mode": mode.rawValue, "userId": userId]) }
}

/// "Pending logout" (F-ACC-04 rule 1): only these two values survive an offline logout, and they are not a login state.
public struct PendingLogout: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var sid: String
    public var refreshToken: String

    public init(sid: String, refreshToken: String) {
        self.sid = sid
        self.refreshToken = refreshToken
    }

    public var description: String { "PendingLogout" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Where sessions are persisted: the app's Keychain; the SDK only calls back (FE-612, F-ACC-03 rule 8).
///
/// The contract:
/// - `save` returns only after the value is durable. The SDK uses a new token only after `save` returned (R-CF-09), so
///   a process killed right after still has a token the server accepts. A throw keeps the old token in use and the
///   refresh is retried with backoff.
/// - Until the recovery code is acknowledged `save` is not called at all, and whatever was stored is cleared at once
///   (RS5-13, F-ACC-05 rule 1). Such a process comes back at the login page.
/// - Calls never overlap and arrive in order.
/// - `savePendingLogouts` holds only `sid` and refresh token, and must outlive `clear()`. Keep it apart from the session.
///   It is the one exception to the rule above: an unacknowledged token reaches it when a logout request failed.
@MainActor
public protocol AccountSessionStore: AnyObject {
    func load() async throws -> AccountSession?
    func save(_ session: AccountSession) async throws
    func clear() async throws
    func loadPendingLogouts() async throws -> [PendingLogout]
    func savePendingLogouts(_ pending: [PendingLogout]) async throws
}

// MARK: - Results

/// A login, registration, password change, recovery or "log out other devices" result. Printing it hides the code.
public struct AuthResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var userId: String
    /// Show this generation to the user, then call `ackRecoveryCode`.
    public var recoveryCode: String?
    public var recoveryCodeGen: Int64?
    public var recoveryCodeUnacked: Bool

    public var description: String { "AuthResult(userId: \(userId), recoveryCodeGen: \(recoveryCodeGen.map(String.init) ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["userId": userId]) }
}

/// The response of regenerating a recovery code. Printing it hides the code.
public struct RecoveryCodeResult: Sendable, Equatable, Decodable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var recoveryCode: String
    public var recoveryCodeGen: Int64

    public var description: String { "RecoveryCodeResult(recoveryCodeGen: \(recoveryCodeGen))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["recoveryCodeGen": recoveryCodeGen]) }
}

public enum RegisterMode: String, Sendable, Equatable {
    case closed, invite, open
}

public struct AccountConfig: Sendable, Equatable, Decodable {
    public struct Features: Sendable, Equatable, Decodable {
        public var files: Bool
    }
    public struct Limits: Sendable, Equatable, Decodable {
        public var usernameMinLen: Int
        public var usernameMaxLen: Int
        public var passwordMinLen: Int
        public var passwordMaxLen: Int
        public var nicknameMaxLen: Int
        public var deviceNameMaxLen: Int
    }
    public struct PrivacyNotice: Sendable, Equatable, Decodable {
        public var version: String
        public var url: String?
    }

    public var registerMode: RegisterMode
    public var demoLogin: Bool
    public var features: Features
    public var limits: Limits
    public var privacyNotice: PrivacyNotice?

    private enum CodingKeys: String, CodingKey { case registerMode, demoLogin, features, limits, privacyNotice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A mode this version does not know hides the entrance rather than guessing (F-ACC-07 rule 4).
        registerMode = RegisterMode(rawValue: try c.decode(String.self, forKey: .registerMode)) ?? .closed
        demoLogin = try c.decode(Bool.self, forKey: .demoLogin)
        features = try c.decode(Features.self, forKey: .features)
        limits = try c.decode(Limits.self, forKey: .limits)
        privacyNotice = try c.decodeIfPresent(PrivacyNotice.self, forKey: .privacyNotice)
    }
}

public struct AccountEvents: Sendable, Equatable, Decodable {
    public struct Event: Sendable, Equatable, Decodable {
        public var kind: String
        public var at: Int64
        public var platform: String?
        public var ipPrefix: String?
    }
    public struct OtherSessions: Sendable, Equatable, Decodable {
        public var count: Int
        public var lastActiveAt: Int64?
    }

    public var events: [Event]
    public var otherSessions: OtherSessions
    public var recoveryCodeUnacked: Bool?
}

public enum AccountEvent: Sendable, Equatable {
    /// The session ended; go back to login. `SessionEnd.dialogText()` has the wording.
    case ended(SessionEnd)
    /// The token changed and is already saved. Carries no token: read `session`.
    case tokens
    /// The newest recovery code is not acknowledged: the app forces the save page (F-ACC-05 rule 1).
    case recoveryCodeUnacked
    /// Each decision: only actions and numbers, no credentials. For debugging and the shared vectors.
    case outcome(SessionOutcome)
}

public struct AccountClientOptions {
    /// E.g. https://im.example.com, without /v1.
    public var baseUrl: String
    public var platform: Platform = .ios
    public var deviceName: String?
    public var store: AccountSessionStore?
    /// The system's push token deregistration for an offline logout (F-ACC-04 rule 1): `unregisterForRemoteNotifications`
    /// on iOS. Only the hook exists; APNs comes with C3.
    public var unregisterSystemPushToken: (@MainActor () -> Void)?
    /// Reacts to the network coming back and to foreground changes by itself. Hosts and tests calling `networkOnline()`
    /// and `foreground()` themselves turn this off.
    public var systemEvents = true
    public var logger: IMLogger = SilentLogger()
    public var requestTimeoutMs: Int64 = accountRequestTimeoutMs

    // Test injection.
    public var http: HttpTransport?
    public var clock: IMClock?
    public var random: (() -> Double)?

    public init(baseUrl: String) {
        self.baseUrl = baseUrl
    }
}

// MARK: - Client

private let backoffBaseMs: Int64 = 1_000
private let backoffMaxMs: Int64 = 30_000
private let backoffJitter = 0.2
/// `retryAfterSeconds` comes from a response: the window is 2 minutes, this stops an odd value from delaying forever.
private let retryAfterMaxSeconds: Int64 = 600
/// Long waits run in pieces and recompute.
private let lifeTimerMaxMs: Int64 = 86_400_000
/// One request is retried this many times because of 4011.
private let http4011Retries = 2
private let refreshPath = "/v1/account/token/refresh"
private let logoutPath = "/v1/account/logout"
/// A cap on the record, as sdk-kotlin: a session pushed out expires and `session_purge` clears it.
private let pendingLogoutMax = 8
/// Retries with backoff after a failed send; then it waits for the next foreground or network event.
private let pendingFlushRetries = 5

private enum RefreshResult: Sendable { case ok, retry, ended }

/// One value, awaited by any number of waiters, resumed after the current synchronous work.
@MainActor
private final class Deferred<T: Sendable> {
    private var value: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    func resolve(_ v: T) {
        guard value == nil else { return }
        value = v
        let w = waiters
        waiters = []
        for c in w { c.resume(returning: v) }
    }

    func wait() async -> T {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class Once {
    private var fired = false
    var timer: TimerHandle?
    func fire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

@MainActor
private final class TokenWaiter {
    let rejected: RejectedToken
    let continuation: CheckedContinuation<Void, Error>
    var timer: TimerHandle?

    init(rejected: RejectedToken, continuation: CheckedContinuation<Void, Error>) {
        self.rejected = rejected
        self.continuation = continuation
    }
}

private struct AuthResponse: Sendable, Decodable {
    var userId: String
    var accessToken: String
    var accessExpiresAt: Int64
    var refreshToken: String
    var refreshExpiresAt: Int64
    var absoluteExpiresAt: Int64
    var recoveryCode: String?
    var recoveryCodeGen: Int64?
    var recoveryCodeUnacked: Bool?
}

private struct EmptyResponse: Sendable, Decodable {}

private struct ErrorBody: Decodable {
    var code: Int
    var msg: String?
    var reason: String?
    var details: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey { case code, msg, reason, details }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code)
        // Only `code` decides; anything odd in the rest is dropped.
        msg = try? c.decodeIfPresent(String.self, forKey: .msg)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        details = try? c.decodeIfPresent([String: JSONValue].self, forKey: .details)
    }
}

/// The account HTTP endpoints and the account session (PRD-chat 13.1, F-ACC-03 rules 5-7, F-ACC-04 rule 3). Independent
/// of `IMClient`.
///
///     let account = AccountClient(options: options)   // options.store = your Keychain store
///     _ = try await account.login(username: name, password: password)
///     im.connect(tokenProvider: account.tokenProvider)
///
/// Invariants (docs/sdk/README.md section 6 in tianting-server):
/// - At most one refresh request at a time. After its timeout, that attempt's responses are all dropped.
/// - Refresh, password change, recovery, "log out other devices", login, registration and delete requests share one
///   serial queue.
/// - While a `sid`-changing operation is in flight, kicks on the connection are held until its response.
/// - Tokens, refresh tokens and recovery codes stay out of URLs, logs and errors.
@MainActor
public final class AccountClient {
    private let baseUrl: String
    private let platform: Platform
    private let deviceName: String?
    private let store: AccountSessionStore?
    private let unregisterSystemPushToken: (@MainActor () -> Void)?
    private let http: HttpTransport
    private let clock: IMClock
    private let log: IMLogger
    private let random: () -> Double
    private let timeoutMs: Int64
    private var monitor: SystemEventsMonitor?
    private var adapter: AccountTokenProvider!

    private var current: AccountSession?
    private var lineage = TokenLineage(sid: "", gen: 0)
    private var memoryOnly = false  // Until the recovery code is acknowledged (F-ACC-05 rule 1).
    private var unackedGen: Int64?  // While memory only, the generation waiting: acknowledging another one does not count.

    private struct Inflight {
        let attempt: Int64
        let task: Task<Void, Never>
        let timer: TimerHandle
        let done: Deferred<RefreshResult>
    }
    private var attempt: Int64 = 0
    private var inflight: Inflight?
    private var superseded = 0  // `superseded` in a row.
    private var backoffN = 0
    private var mustRefresh = false  // Refresh regardless of the time left: rejected, or already expired.
    private var retryTimer: TimerHandle?
    private var rereadStore = false  // After `superseded`, read the newest token first (rule 6).
    /// The token a refresh just returned already looks under 6 hours: a clock running fast, or a short TTL. Refreshing
    /// again would get the same answer, reconnect, and loop up to the server's rate limit. So no more refreshing on our
    /// own for this token: the server's 4011 still does (rule 7), and it decides when the token really ended.
    private var shortOnArrival = false
    private var lastFailure: Error?

    private var slotBusy = false  // The serial queue's slot: taken by a refresh or a queued operation.
    private var queue: [@MainActor () -> Void] = []
    private var refreshQueued = false
    private var epoch = 0  // Up by one each time a session ends: a late response cannot revive it.
    private var sessionSeq = 0  // Up by one per new session (login, register, recover, restore): a logout only ends its own (A1).
    private var logoutSeq = 0  // Up by one per logout: a login sent before it is not adopted (logout wins).
    private var logoutHolds = Set<UUID>()  // The `holdDepth` taken by logouts in flight: a new session lets them all go.
    private var lastEnd: SessionEnd?  // The most recent end; cleared by a new session (issue K7).

    private var holdDepth = 0  // A `sid`-changing operation is in flight (F-ACC-04 rule 3).
    private var heldKicks: [(info: KickInfo, decide: @MainActor (KickDecision) -> Void)] = []

    private var waiters: [TokenWaiter] = []
    private var connected = false
    private var lifeTimer: TimerHandle?

    private var listeners: [UUID: @MainActor (AccountEvent) -> Void] = [:]
    private var tokenListeners: [UUID: @MainActor () -> Void] = [:]
    private var endedListeners: [UUID: @MainActor (SessionEnd) -> Void] = [:]
    private var profileListeners: [UUID: @MainActor (String, ProfileChange) -> Void] = [:]

    private var storeTail: Task<Void, Never>?
    private var pendingLogouts: [PendingLogout] = []
    private var pendingLoad: Task<Void, Never>?
    private var flushingPending = false
    private var flushTimer: TimerHandle?
    private var flushFailures = 0
    private var loggingOut: Bool { !logoutHolds.isEmpty }  // The session stays in memory until the server answers; it does not refresh.

    public init(options o: AccountClientOptions) {
        var base = o.baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        baseUrl = base
        platform = o.platform
        deviceName = o.deviceName
        store = o.store
        unregisterSystemPushToken = o.unregisterSystemPushToken
        http = o.http ?? URLSessionHttpTransport()
        clock = o.clock ?? SystemClock()
        log = o.logger
        random = o.random ?? { Double.random(in: 0..<1) }
        timeoutMs = o.requestTimeoutMs
        adapter = AccountTokenProvider(owner: self)
        if o.systemEvents {
            monitor = SystemEventsMonitor(
                online: { [weak self] in self?.networkOnline() },
                visibility: { [weak self] in
                    guard let self, defaultIsVisible() else { return }
                    self.foreground()
                })
        }
    }

    /// The token source for `IMClient.connect(tokenProvider:)`.
    public var tokenProvider: TokenProvider { adapter }

    /// Subscribes to events; handlers run synchronously on the main actor.
    @discardableResult
    public func on(_ handler: @escaping @MainActor (AccountEvent) -> Void) -> IMSubscription {
        let id = UUID()
        listeners[id] = handler
        return IMSubscription { [weak self] in self?.listeners[id] = nil }
    }

    private func emit(_ e: AccountEvent) {
        for h in Array(listeners.values) { h(e) }
    }

    // MARK: State

    /// The current session. It holds tokens; printing it hides them.
    public var session: AccountSession? { current }

    /// The local token's generation. Kept after the session ends: it is only a number.
    public var localGen: Int64 { lineage.gen }

    /// A refresh request is in flight.
    public var refreshInflight: Bool { inflight != nil }

    // MARK: Start and entry points (rule 5)

    /// Starts up: reads the session from the store and checks whether to refresh. An expired one refreshes first, and
    /// `accessToken()` waits for it. A session whose logout was already asked for is not brought back.
    @discardableResult
    public func start() async throws -> AccountSession? {
        await loadPendingIfNeeded()
        if let saved = try await store?.load() {
            let sid = lineageOf(saved.accessToken).sid
            if saved.mode == .account, !sid.isEmpty, pendingLogouts.contains(where: { $0.sid == sid }) {
                // Killed between asking the server and clearing locally: the user already logged out.
                try? await storeWrite { try await $0.clear() }
            } else {
                restore(saved)
            }
        }
        if current != nil { trigger(.start) }
        flushPendingLogouts()
        return current
    }

    /// Restores a session without writing the store or emitting `.tokens`.
    public func restore(_ saved: AccountSession) {
        let isNew = saved.accessToken != current?.accessToken
        if isNew { sessionSeq += 1 }
        current = saved
        lineage = lineageOf(saved.accessToken)
        shortOnArrival = false
        lastEnd = nil
        resetFailures()
        armLifeTimer()
        if isNew { releaseLogoutHolds() }
    }

    /// Back in the foreground.
    @discardableResult
    public func foreground() -> SessionOutcome {
        flushPendingLogouts()
        return trigger(.foreground)
    }

    /// The network came back: sends pending logouts (F-ACC-04 rule 1). A refresh waiting on its retry timer stays
    /// waiting (only the due timer sends, rule 5).
    public func networkOnline() {
        flushPendingLogouts()
    }

    /// The four entry points merged into one (single flight). For `.kicked`, `rejected` is the rejected token's identity
    /// (rule 7). `.timer` is also the path of a due backoff or `superseded` retry.
    @discardableResult
    func trigger(_ source: RefreshSource, rejected: RejectedToken = RejectedToken()) -> SessionOutcome {
        guard let s = current else { return record(.none) }
        if s.mode != .account {
            guard source == .kicked else { return record(.none) }
            let o = SessionOutcome.login(dialog: .sessionExpired, recoverBefore: nil)
            endSession(SessionEnd(action: .login, dialog: .sessionExpired, reason: "tokenExpired", code: 4011))
            return record(o)
        }
        if source == .kicked {
            if isLocalNewer(lineage, than: rejected) { return record(.useLocal) }
            // Access ends at the absolute limit (P-35 L1): a refresh cannot get a later token. The server kicks
            // tokenExpired in the limit's last second; the session ends at once instead of asking one more time.
            if s.absoluteExpiresAt != nil, s.accessExpiresAt == s.absoluteExpiresAt {
                endSession(SessionEnd(action: .login, dialog: .sessionExpired, reason: "expired"))
                return record(.login(dialog: .sessionExpired, recoverBefore: nil))
            }
            mustRefresh = true
        }
        return record(decideRefresh(source))
    }

    /// /v1/* returned 401 / 4011 (rule 7, RS5-10): a newer local token is used as is; otherwise refresh once, merged with
    /// the other entry points.
    @discardableResult
    func http4011(_ rejected: RejectedToken) -> SessionOutcome {
        if isLocalNewer(lineage, than: rejected) { return record(.useLocal) }
        guard current != nil else { return record(.none) }
        mustRefresh = true
        return record(decideRefresh(.kicked))
    }

    private func decideRefresh(_ source: RefreshSource) -> SessionOutcome {
        if inflight != nil || loggingOut { return .none }
        // While waiting on a retry only the due timer sends: `superseded` follows retryAfterSeconds (AC-ACC-03-39), and a
        // trip to the foreground must not produce extra requests.
        if retryTimer != nil, source != .timer { return .none }
        guard let s = current else { return .none }
        if !mustRefresh {
            let now = clock.now()
            if s.accessExpiresAt == s.absoluteExpiresAt, now >= s.accessExpiresAt {
                endSession(SessionEnd(action: .login, dialog: .sessionExpired, reason: "expired"))
                return .login(dialog: .sessionExpired, recoverBefore: nil)
            }
            if shortOnArrival
                || !shouldRefresh(accessExpiresAt: s.accessExpiresAt, absoluteExpiresAt: s.absoluteExpiresAt, now: now)
            {
                return .none
            }
        }
        if slotBusy {
            refreshQueued = true
            return .none
        }
        clearRetryTimer()
        slotBusy = true
        let (outcome, done) = beginRefresh()
        Task { [weak self] in
            _ = await done.wait()
            self?.releaseSlot()
        }
        return outcome
    }

    /// Sends one refresh. The caller owns the slot: a plain refresh takes it whole; a queued password change calls this
    /// inside its own slot (RS5-15).
    private func beginRefresh() -> (SessionOutcome, Deferred<RefreshResult>) {
        attempt += 1
        let n = attempt
        let done = Deferred<RefreshResult>()
        let timer = clock.setTimeout(timeoutMs) { [weak self] in self?.onRefreshTimeout(n) }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.sendRefresh(n)
        }
        inflight = Inflight(attempt: n, task: task, timer: timer, done: done)
        return (.refresh(attempt: n), done)
    }

    private func sendRefresh(_ n: Int64) async {
        if rereadStore { await reloadFromStore() }
        rereadStore = false
        guard inflight?.attempt == n else { return }
        guard let refreshToken = current?.refreshToken else {
            settleRefresh(n, .ended)
            endSession(SessionEnd(action: .login, dialog: .sessionExpired, code: ErrorCode.refreshTokenInvalid))
            return
        }
        let resp: AuthResponse
        do {
            resp = try parseAuth(
                try await perform(
                    AuthResponse.self, .post, refreshPath, body: ["refreshToken": .string(refreshToken)], bearer: nil))
        } catch {
            onRefreshFailed(n, error)
            return
        }
        guard inflight?.attempt == n else {
            log.debug("account: late refresh response \(n) dropped")
            record(.none)
            return
        }
        let next = sessionFrom(resp)
        do {
            if !memoryOnly { try await storeWrite { try await $0.save(next) } }  // New tokens are saved before use.
        } catch {
            log.warn("account: session save failed")
            onRefreshFailed(n, AccountNetworkError.saveFailed)
            return
        }
        guard inflight?.attempt == n else { return }  // Abandoned during the save.
        superseded = 0
        backoffN = 0
        lastFailure = nil
        settleRefresh(n, .ok)
        adopt(next, recoveryCodeUnacked: resp.recoveryCodeUnacked == true, fromRefresh: true)
        record(.keepToken)
    }

    private func onRefreshTimeout(_ n: Int64) {
        guard let f = inflight, f.attempt == n else { return }
        log.warn("account: refresh timed out")
        f.task.cancel()
        lastFailure = AccountNetworkError.timeout
        scheduleBackoff()
        settleRefresh(n, .retry)
        record(.backoff)
    }

    private func onRefreshFailed(_ n: Int64, _ error: Error) {
        guard inflight?.attempt == n else {
            log.debug("account: late refresh failure \(n) dropped")
            record(.none)
            return
        }
        let failure = failureOf(error)
        lastFailure = error
        let o = classifyRefreshFailure(failure, superseded: superseded)
        log.warn("account: refresh failed \(failure.code) \(failure.reason ?? "") -> \(actionName(o))")
        switch o {
        case .backoff:
            scheduleBackoff()
            settleRefresh(n, .retry)
        case .retryAfter:
            superseded += 1
            rereadStore = true
            scheduleRetry(retryAfterMs(failure.retryAfterSeconds))
            settleRefresh(n, .retry)
        case .banNotice:
            settleRefresh(n, .ended)
            endSession(SessionEnd(action: .banNotice, code: failure.code))
        case .login(let dialog, let recoverBefore):
            settleRefresh(n, .ended)
            endSession(
                SessionEnd(
                    action: .login, dialog: dialog, recoverBefore: recoverBefore, reason: failure.reason, code: failure.code))
        default:
            break
        }
        record(o)
    }

    private func settleRefresh(_ n: Int64, _ r: RefreshResult) {
        guard let f = inflight, f.attempt == n else { return }
        clock.clearTimeout(f.timer)
        inflight = nil
        f.done.resolve(r)
    }

    private func reloadFromStore() async {
        guard let store else { return }
        do {
            guard let latest = try await store.load(), let refresh = latest.refreshToken, let s = current,
                latest.userId == s.userId, refresh != s.refreshToken
            else { return }
            let l = lineageOf(latest.accessToken)
            if isLocalNewer(l, than: RejectedToken(lineage)) {
                var updated = latest
                updated.mode = .account
                current = updated
                lineage = l
                shortOnArrival = false
            }
        } catch {
            log.warn("account: session load failed")
        }
    }

    private func scheduleBackoff() {
        let shift = min(backoffN, 32)
        let base = min(backoffBaseMs << Int64(shift), backoffMaxMs)
        backoffN += 1
        scheduleRetry(Int64((Double(base) * (1 + backoffJitter * (2 * random() - 1))).rounded()))
    }

    private func scheduleRetry(_ ms: Int64) {
        clearRetryTimer()
        retryTimer = clock.setTimeout(ms) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.trigger(.timer)
        }
    }

    private func clearRetryTimer() {
        if let t = retryTimer { clock.clearTimeout(t) }
        retryTimer = nil
    }

    private func resetFailures() {
        superseded = 0
        backoffN = 0
        mustRefresh = false
        rereadStore = false
        lastFailure = nil
        clearRetryTimer()
    }

    // MARK: Changing tokens

    private func sessionFrom(_ r: AuthResponse) -> AccountSession {
        AccountSession(
            mode: .account, userId: r.userId, accessToken: r.accessToken, accessExpiresAt: r.accessExpiresAt,
            refreshToken: r.refreshToken, refreshExpiresAt: r.refreshExpiresAt, absoluteExpiresAt: r.absoluteExpiresAt)
    }

    private func adopt(_ next: AccountSession, recoveryCodeUnacked: Bool, fromRefresh: Bool = false) {
        current = next
        lineage = lineageOf(next.accessToken)
        lastEnd = nil
        shortOnArrival =
            fromRefresh
            && shouldRefresh(accessExpiresAt: next.accessExpiresAt, absoluteExpiresAt: next.absoluteExpiresAt, now: clock.now())
        mustRefresh = false
        clearRetryTimer()
        armLifeTimer()
        resolveWaiters()
        emit(.tokens)
        for fn in Array(tokenListeners.values) { fn() }
        if recoveryCodeUnacked { emit(.recoveryCodeUnacked) }
    }

    /// Login, registration, password change, recovery, "log out other devices". Saved only without a recovery code; with
    /// one the old value is cleared and the new one waits for the acknowledgement (F-ACC-05 rule 1).
    private func applyAuth(_ resp: AuthResponse, keepMemoryOnly: Bool = false) async throws -> AuthResult {
        let started = epoch
        let next = sessionFrom(resp)
        memoryOnly = resp.recoveryCode != nil || (keepMemoryOnly && memoryOnly)
        if resp.recoveryCode != nil {
            unackedGen = resp.recoveryCodeGen
        } else if !memoryOnly {
            unackedGen = nil
        }
        do {
            if memoryOnly {
                try await storeWrite { try await $0.clear() }
            } else {
                try await storeWrite { try await $0.save(next) }
            }
        } catch {
            // The server already changed the credentials and the old token is gone: go on with the new one, and the next
            // token change saves again.
            log.warn("account: session save failed")
        }
        if epoch != started {  // Logged out during the save: this response does not revive the session.
            try? await storeWrite { try await $0.clear() }
            throw SessionEndedError()
        }
        resetFailures()
        adopt(next, recoveryCodeUnacked: resp.recoveryCodeUnacked == true)
        flushPendingLogouts()  // The network is clearly up.
        return AuthResult(
            userId: resp.userId, recoveryCode: resp.recoveryCode, recoveryCodeGen: resp.recoveryCode == nil ? nil : resp.recoveryCodeGen,
            recoveryCodeUnacked: resp.recoveryCodeUnacked == true)
    }

    /// The timer while connected (rule 5): refresh under 6 hours; when access ends at the absolute limit there is no more
    /// refreshing, and the session ends at that moment (RS5-11).
    private func armLifeTimer() {
        if let t = lifeTimer { clock.clearTimeout(t) }
        lifeTimer = nil
        guard let s = current, s.mode == .account, connected else { return }
        let now = clock.now()
        let isFinal = s.accessExpiresAt == s.absoluteExpiresAt
        if shortOnArrival { return }
        // Exactly 6 hours left does not refresh, so wait one millisecond past that point.
        let at = isFinal ? s.accessExpiresAt : s.accessExpiresAt - refreshBelowMs + 1
        let delay = max(0, at - now)
        lifeTimer = clock.setTimeout(min(delay, lifeTimerMaxMs)) { [weak self] in
            guard let self else { return }
            self.lifeTimer = nil
            if delay > lifeTimerMaxMs {
                self.armLifeTimer()
                return
            }
            if self.retryTimer == nil { self.trigger(.timer) }  // While waiting on a retry, the due timer sends.
        }
    }

    fileprivate func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        armLifeTimer()
    }

    // MARK: The token source (HTTP and WS share it, RS5-10)

    fileprivate func accessToken() async throws -> String {
        guard let s = current else { throw SessionEndedError(end: lastEnd) }
        if s.mode == .account, !shortOnArrival, clock.now() >= s.accessExpiresAt {
            if s.accessExpiresAt == s.absoluteExpiresAt {
                endSession(SessionEnd(action: .login, dialog: .sessionExpired, reason: "expired"))
                throw SessionEndedError()
            }
            // Expired: refresh first (rule 5).
            try await waitForNewer(RejectedToken(lineage)) {
                self.mustRefresh = true
                self.record(self.decideRefresh(.start))
            }
            // Not checked again: with a clock running fast the new token looks expired too, and checking would refresh
            // forever.
            guard let fresh = current else { throw SessionEndedError() }
            return fresh.accessToken
        }
        if s.mode == .account { trigger(.start) }
        guard let now = current else { throw SessionEndedError() }
        return now.accessToken
    }

    fileprivate func tokenRejected(_ token: String) async throws {
        let rejected = RejectedToken(lineageOf(token))
        try await waitForNewer(rejected) {
            self.trigger(.kicked, rejected: rejected)
        }
    }

    /// Returns once the local token is newer than `rejected`. `then` runs right after the waiter is registered.
    private func waitForNewer(
        _ rejected: RejectedToken, timeoutMs: Int64? = nil, then: @escaping @MainActor () -> Void
    ) async throws {
        guard current != nil else { throw SessionEndedError() }
        if isLocalNewer(lineage, than: rejected) {
            then()
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let w = TokenWaiter(rejected: rejected, continuation: cont)
            if let timeoutMs {
                w.timer = clock.setTimeout(timeoutMs) { [weak self, weak w] in
                    guard let self, let w else { return }
                    self.waiters.removeAll { $0 === w }
                    w.continuation.resume(throwing: self.lastFailure ?? AccountNetworkError.timeout)
                }
            }
            waiters.append(w)
            then()
        }
    }

    private func resolveWaiters() {
        let ready = waiters.filter { isLocalNewer(lineage, than: $0.rejected) }
        waiters.removeAll { w in ready.contains { $0 === w } }
        for w in ready {
            if let t = w.timer { clock.clearTimeout(t) }
            w.continuation.resume()
        }
    }

    // MARK: Kicks (F-ACC-04 rule 3, RS5-15)

    fileprivate func kickReceived(_ info: KickInfo, decide: @escaping @MainActor (KickDecision) -> Void) {
        if holdDepth > 0, kickIsHoldable(reason: info.reason, code: info.code) {
            log.debug("account: kick held while credentials are changing")
            heldKicks.append((info, decide))
            return
        }
        applyKick(info)
        decide(.pass)
    }

    private func applyKick(_ info: KickInfo) {
        guard current != nil, kickEndsSession(reason: info.reason, code: info.code) else { return }
        var end = SessionEnd(action: .login, reason: info.reason, code: info.code, origin: .kick)
        if case .login(let dialog, let recoverBefore) = kickOutcome(reason: info.reason, recoverBefore: info.recoverBefore) {
            end.dialog = dialog
            end.recoverBefore = recoverBefore
        }
        endSession(end)
    }

    /// A `sid`-changing operation finished: success voids the old `sid`'s kicks, failure or timeout applies them (RS5-15).
    private func releaseHeld(succeeded: Bool) {
        holdDepth -= 1
        guard holdDepth == 0 else { return }
        let held = heldKicks
        heldKicks = []
        for (info, decide) in held {
            if succeeded {
                decide(.ignore)
            } else {
                applyKick(info)
                decide(.pass)
            }
        }
    }

    /// A new session exists: a logout in flight only concerns the old one. The old connection went with the token change, so
    /// the kicks it held are void, and the new session's kicks do not wait for it.
    private func releaseLogoutHolds() {
        holdDepth -= logoutHolds.count
        logoutHolds.removeAll()
        guard holdDepth == 0 else { return }
        let held = heldKicks
        heldKicks = []
        for (_, decide) in held { decide(.ignore) }
    }

    // MARK: The serial queue (RS4-03)

    private func enqueue<T: Sendable>(hold: Bool = false, _ fn: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let run: @MainActor () -> Void = { [self] in
                if hold { holdDepth += 1 }
                Task { @MainActor [self] in
                    var ok = false
                    do {
                        let v = try await fn()
                        ok = true
                        cont.resume(returning: v)
                    } catch {
                        cont.resume(throwing: error)
                    }
                    if hold { releaseHeld(succeeded: ok) }
                    releaseSlot()
                }
            }
            if slotBusy {
                queue.append(run)
                return
            }
            slotBusy = true
            run()
        }
    }

    private func releaseSlot() {
        if !queue.isEmpty {
            queue.removeFirst()()
            return
        }
        slotBusy = false
        if refreshQueued {
            refreshQueued = false
            if retryTimer == nil { trigger(.timer) }  // While waiting on a retry, the due timer sends.
        }
    }

    /// Login, registration, recovery: a new session. Usable while a logout is in flight, whose end leaves this session alone (A1).
    private func enqueueNewSession(_ path: String, _ body: JSONValue, hold: Bool = false) async throws -> AuthResult {
        let logouts = logoutSeq
        return try await enqueue(hold: hold) {
            let resp = try parseAuth(try await self.send(AuthResponse.self, .post, path, body: body, bearer: nil))
            if logouts != self.logoutSeq { throw SessionEndedError() }  // Sent before the logout was asked for: logout wins.
            self.sessionSeq += 1  // Before the save: a logout whose clear comes after it then skips the clear.
            let result = try await self.applyAuth(resp)
            self.releaseLogoutHolds()
            return result
        }
    }

    /// A `sid`-changing operation. If a logout happened meanwhile the response is not used (F-ACC-04 rule 1).
    private func rotateInSlot(_ path: String, _ body: JSONValue) async throws -> AuthResult {
        let started = epoch
        let raw = try await inSlot(AuthResponse.self, .post, path, body: body)
        let resp = try parseAuth(raw)
        if started != epoch { throw SessionEndedError() }
        // With the recovery code unacknowledged, tokens from "log out other devices" also stay in memory.
        return try await applyAuth(resp, keepMemoryOnly: true)
    }

    /// A queued request: a needed refresh runs right here in its own slot instead of queueing again, or it would wait for
    /// itself (RS5-15).
    private func inSlot<T: Sendable & Decodable>(
        _ type: T.Type, _ method: HttpMethod, _ path: String, body: JSONValue?
    ) async throws -> T {
        var i = 0
        while true {
            guard let s = current else { throw SessionEndedError() }
            if !shortOnArrival, clock.now() >= s.accessExpiresAt { try await refreshInSlot() }
            guard let token = current?.accessToken else { throw SessionEndedError() }
            do {
                return try await sendAuthed(type, method, path, body: body, token: token)
            } catch {
                guard i < http4011Retries, is4011(error) else { throw error }
                if isLocalNewer(lineage, than: RejectedToken(lineageOf(token))) {
                    record(.useLocal)
                } else {
                    record(.none)
                    try await refreshInSlot()
                }
            }
            i += 1
        }
    }

    private func refreshInSlot() async throws {
        clearRetryTimer()
        mustRefresh = true
        let (outcome, done) = beginRefresh()
        record(outcome)
        switch await done.wait() {
        case .ok: return
        case .ended: throw SessionEndedError()
        case .retry: throw lastFailure ?? AccountNetworkError.network
        }
    }

    // MARK: Account endpoints

    /// GET /v1/config. A failure does not guess a mode: the caller handles it (F-ACC-07 rule 4).
    public func getConfig() async throws -> AccountConfig {
        try await send(AccountConfig.self, .get, "/v1/config", body: nil, bearer: nil)
    }

    public func register(
        username: String, password: String, nickname: String? = nil, inviteCode: String? = nil
    ) async throws -> AuthResult {
        var body = deviceFields()
        body["username"] = .string(username)
        body["password"] = .string(password)
        if let nickname { body["nickname"] = .string(nickname) }
        if let inviteCode { body["inviteCode"] = .string(inviteCode) }
        return try await enqueueNewSession("/v1/account/register", .object(body))
    }

    public func login(username: String, password: String) async throws -> AuthResult {
        var body = deviceFields()
        body["username"] = .string(username)
        body["password"] = .string(password)
        return try await enqueueNewSession("/v1/account/login", .object(body))
    }

    /// Recovery (F-ACC-05): changes the `sid`; the response carries a new recovery code.
    public func recover(username: String, recoveryCode: String, newPassword: String) async throws -> AuthResult {
        var body = deviceFields()
        body["username"] = .string(username)
        body["recoveryCode"] = .string(recoveryCode)
        body["newPassword"] = .string(newPassword)
        return try await enqueueNewSession("/v1/account/recover", .object(body), hold: true)
    }

    /// Refreshes now, merged with the other entry points. Returns once the token changed; throws after 30 seconds without
    /// one, and the background retries go on.
    public func refresh() async throws {
        guard current?.mode == .account else { throw SessionEndedError() }
        try await waitForNewer(RejectedToken(lineage), timeoutMs: timeoutMs) {
            self.mustRefresh = true
            self.record(self.decideRefresh(.foreground))
        }
    }

    /// Password change (F-ACC-04 rule 3): kicks are held while in flight; success changes the token (new `sid`) first and
    /// then ignores the old `sid`'s kick; only failure or timeout applies it.
    public func changePassword(oldPassword: String, newPassword: String) async throws -> AuthResult {
        let body: JSONValue = ["oldPassword": .string(oldPassword), "newPassword": .string(newPassword)]
        return try await enqueue(hold: true) { try await self.rotateInSlot("/v1/account/password", body) }
    }

    /// "Log out other devices" (F-ACC-04 rule 6): the same `sid` change, with no new password.
    public func logoutOthers(password: String) async throws -> AuthResult {
        let body: JSONValue = ["password": .string(password)]
        return try await enqueue(hold: true) { try await self.rotateInSlot("/v1/account/logout-others", body) }
    }

    /// Logout (F-ACC-04 rule 1): tells the server first, then disconnects; also logs out when the server cannot be
    /// reached, keeping `sid` and refresh token as "pending logout" to send when back online. Returns whether the server
    /// confirmed. An in-flight refresh is abandoned, late responses are not adopted, and queued operations fail.
    ///
    /// The record is written and the stored session cleared before the request, so a process killed in between stays
    /// logged out and still sends it. Tokens not yet allowed on disk (RS5-13) reach the record only when the request
    /// failed, as with sdk-kotlin.
    ///
    /// It ends only the session it started on: one logged in while waiting for the answer stays, with no `.ended`, and the
    /// old `sid`'s pending record carries on as usual (A1).
    @discardableResult
    public func logout() async -> Bool {
        guard let s = current else { return true }
        epoch += 1
        logoutSeq += 1
        let seq = sessionSeq
        abandonRefresh()
        guard s.mode == .account else {
            endSession(SessionEnd(action: .logout))
            await storeTail?.value
            return true
        }
        let hold = UUID()
        logoutHolds.insert(hold)
        holdDepth += 1
        let unacked = memoryOnly
        let pending = pendingFor(s)
        await loadPendingIfNeeded()
        if let pending, !unacked { await addPending(pending) }
        // A login may have succeeded while the record was written: the stored session is then the new one.
        if seq == sessionSeq { scheduleStoreWrite { try await $0.clear() } }
        var confirmed = false
        var body: [String: JSONValue] = [:]
        if let r = s.refreshToken { body["refreshToken"] = .string(r) }
        do {
            _ = try await send(EmptyResponse.self, .post, logoutPath, body: .object(body), bearer: s.accessToken)
            confirmed = true
            if let pending { await removePending(pending) }
        } catch {
            log.warn("account: logout not confirmed: \(errorKind(error))")
            if retriableLogoutFailure(error) {
                if let pending, unacked { await addPending(pending) }
                // With a new session the system token is its token: it stays, and the old `sid` unbinds through the record.
                if seq == sessionSeq { unregisterSystemPushToken?() } else { flushPendingLogouts() }
            } else if let pending {
                await removePending(pending)  // The server's answer: sending it again changes nothing.
            }
        }
        if logoutHolds.remove(hold) != nil { holdDepth -= 1 }
        if seq == sessionSeq { endSession(SessionEnd(action: .logout)) }
        await storeTail?.value  // Returning means the token is off the disk.
        return confirmed
    }

    /// Regenerates the recovery code (F-ACC-05 rule 5). The token stays.
    public func regenerateRecoveryCode(password: String) async throws -> RecoveryCodeResult {
        let r = try await authed(RecoveryCodeResult.self, .post, "/v1/account/recovery-code", body: ["password": .string(password)])
        // While memory only, this is the generation to acknowledge. The response can arrive after a later password change:
        // the generation only moves forward.
        if memoryOnly { unackedGen = max(unackedGen ?? 0, r.recoveryCodeGen) }
        return r
    }

    /// Confirms the recovery code was saved. Tokens kept in memory until now reach the store only after this.
    /// `recoveryCodeStale` ends the session: the code changed, go back to login (AC-ACC-05-15).
    public func ackRecoveryCode(gen: Int64) async throws {
        do {
            _ = try await authed(EmptyResponse.self, .post, "/v1/account/recovery-code/ack", body: ["gen": .int(gen)])
        } catch let e as AccountError where e.reason == "recoveryCodeStale" {
            endSession(SessionEnd(action: .login, dialog: .recoveryCodeStale, reason: e.reason, code: e.code))
            throw e
        }
        // An older generation (a password change, recovery or regeneration moved on meanwhile): this generation's token
        // must not reach the store yet (RS5-13).
        guard memoryOnly, gen == unackedGen else { return }
        // A refresh during the save would keep going to memory only, so save until what is stored is what is in use.
        while memoryOnly, gen == unackedGen, let s = current {
            try await storeWrite { try await $0.save(s) }
            if current == s, gen == unackedGen {
                memoryOnly = false
                unackedGen = nil
                return
            }
        }
        if current == nil { try? await storeWrite { try await $0.clear() } }  // Ended during the save.
    }

    /// Changes the profile (F-ACC-06). This device shows it at once (a new avatar after `IMClient` fetched the own profile
    /// again, issue H13); others follow the 10-minute cache.
    public func updateProfile(nickname: String? = nil, avatarFileId: String? = nil) async throws {
        var body: [String: JSONValue] = [:]
        if let nickname { body["nickname"] = .string(nickname) }
        if let avatarFileId { body["avatarFileId"] = .string(avatarFileId) }
        _ = try await authed(EmptyResponse.self, .patch, "/v1/account/profile", body: .object(body))
        // The avatar's address is generated by the server and not in the response: IMClient fetches it (issue H13).
        if let userId = current?.userId, nickname != nil || avatarFileId != nil {
            let change = ProfileChange(nickname: nickname, avatarChanged: avatarFileId != nil)
            for fn in Array(profileListeners.values) { fn(userId, change) }
        }
    }

    /// Recent logins and how many other sessions there are.
    public func listEvents() async throws -> AccountEvents {
        let r = try await authed(AccountEvents.self, .get, "/v1/account/events", body: nil)
        if r.recoveryCodeUnacked == true { emit(.recoveryCodeUnacked) }
        return r
    }

    /// Requests account deletion (F-ACC-08): on success every session is revoked and the local one ends. Kicks are held
    /// while in flight; only failure applies them.
    public func requestDelete(password: String) async throws {
        let body: JSONValue = ["password": .string(password)]
        try await enqueue(hold: true) {
            _ = try await self.inSlot(EmptyResponse.self, .post, "/v1/account/delete", body: body)
            self.endSession(SessionEnd(action: .login, reason: "accountDeleted"))
        }
    }

    /// Cancels a deletion: an anonymous endpoint.
    public func cancelDelete(username: String, password: String) async throws {
        _ = try await send(
            EmptyResponse.self, .post, "/v1/account/delete/cancel",
            body: ["username": .string(username), "password": .string(password)], bearer: nil)
    }

    private func deviceFields() -> [String: JSONValue] {
        var o: [String: JSONValue] = ["platform": .string(platform.rawValue)]
        if let deviceName { o["deviceName"] = .string(deviceName) }
        return o
    }

    /// Other Bearer endpoints under /v1 (the file endpoints, PRD-chat F-FILE-01, 04; RS5-10: HTTP and WS share the
    /// token). 4011 is handled as for the account endpoints (rule 7): a newer local token is used at once, otherwise one
    /// refresh is awaited; at most 2 retries per request. Implements `FileAuth`.
    public func authorized(_ method: HttpMethod, _ path: String, body: JSONValue?) async throws -> JSONValue {
        try await authed(JSONValue.self, method, path, body: body)
    }

    /// A Bearer request outside the queue: on 4011 retries with the local token, or waits for one refresh (rule 7).
    private func authed<T: Sendable & Decodable>(
        _ type: T.Type, _ method: HttpMethod, _ path: String, body: JSONValue?
    ) async throws -> T {
        var i = 0
        while true {
            guard current != nil else { throw SessionEndedError() }
            let token = try await accessToken()
            do {
                return try await sendAuthed(type, method, path, body: body, token: token)
            } catch {
                guard i < http4011Retries, is4011(error) else { throw error }
                let rejected = RejectedToken(lineageOf(token))
                try await waitForNewer(rejected, timeoutMs: timeoutMs) { self.http4011(rejected) }
            }
            i += 1
        }
    }

    private func sendAuthed<T: Sendable & Decodable>(
        _ type: T.Type, _ method: HttpMethod, _ path: String, body: JSONValue?, token: String
    ) async throws -> T {
        do {
            return try await send(type, method, path, body: body, bearer: token)
        } catch let e as AccountError {
            // Access was revoked: like 4012 on the connection, back to login. Not when the token is no longer the current
            // one (the `sid` changed).
            if e.code == 4012 || e.code == 4010, token == current?.accessToken, holdDepth == 0 {
                endSession(SessionEnd(action: .login, dialog: .sessionExpired, code: e.code))
            }
            throw e
        }
    }

    /// One request with the injected clock's timeout. A late response ends here and never reaches the caller.
    private func send<T: Sendable & Decodable>(
        _ type: T.Type, _ method: HttpMethod, _ path: String, body: JSONValue?, bearer: String?
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once()
            let task = Task { @MainActor [self] in
                do {
                    let v = try await perform(type, method, path, body: body, bearer: bearer)
                    if once.fire() {
                        if let timer = once.timer { clock.clearTimeout(timer) }
                        cont.resume(returning: v)
                    }
                } catch {
                    if once.fire() {
                        if let timer = once.timer { clock.clearTimeout(timer) }
                        cont.resume(throwing: error)
                    }
                }
            }
            once.timer = clock.setTimeout(timeoutMs) { [log] in
                guard once.fire() else { return }
                log.warn("account: \(method.rawValue) \(path) timed out")
                task.cancel()
                cont.resume(throwing: AccountNetworkError.timeout)
            }
        }
    }

    /// The exchange. The path holds no credential; logs only have method, path, status and error code.
    private func perform<T: Decodable>(
        _ type: T.Type, _ method: HttpMethod, _ path: String, body: JSONValue?, bearer: String?
    ) async throws -> T {
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
        let req = HttpRequest(method: method, url: baseUrl + path, headers: headers, body: body.map { Data($0.jsonString().utf8) })
        let resp: HttpResponse
        do {
            resp = try await http.request(req)
        } catch {
            throw AccountNetworkError.network  // Not the original error: its text can hold a URL.
        }
        if (200..<300).contains(resp.status) {
            let data = resp.body.isEmpty ? Data("{}".utf8) : resp.body
            guard let v = try? JSONDecoder().decode(T.self, from: data) else {
                throw AccountNetworkError.invalidResponse
            }
            return v
        }
        guard let e = try? JSONDecoder().decode(ErrorBody.self, from: resp.body) else {
            log.warn("account: \(method.rawValue) \(path) status \(resp.status)")
            throw AccountNetworkError.status(resp.status)  // A proxy's page is not the server's decision: no going to login.
        }
        log.debug("account: \(method.rawValue) \(path) \(resp.status) \(e.code)")
        throw AccountError(status: resp.status, code: e.code, message: e.msg ?? "", reason: e.reason, details: e.details)
    }

    // MARK: Pending logouts (F-ACC-04 rule 1)

    private func pendingFor(_ s: AccountSession) -> PendingLogout? {
        guard !lineage.sid.isEmpty, let refresh = s.refreshToken else { return nil }
        return PendingLogout(sid: lineage.sid, refreshToken: refresh)
    }

    /// Everyone waits for the one load: a record added before it finished would otherwise be overwritten.
    private func loadPendingIfNeeded() async {
        if pendingLoad == nil {
            pendingLoad = Task { [weak self] in
                guard let self, let store = self.store else { return }
                do {
                    self.pendingLogouts = try await store.loadPendingLogouts()
                } catch {
                    self.log.warn("account: pending logouts load failed")
                }
            }
        }
        await pendingLoad?.value
    }

    private func addPending(_ p: PendingLogout) async {
        pendingLogouts.removeAll { $0.sid == p.sid }
        pendingLogouts.append(p)
        pendingLogouts = Array(pendingLogouts.suffix(pendingLogoutMax))
        await persistPending()
    }

    private func removePending(_ p: PendingLogout) async {
        pendingLogouts.removeAll { $0.sid == p.sid }
        await persistPending()
    }

    private func persistPending() async {
        let list = pendingLogouts
        do {
            try await storeWrite { try await $0.savePendingLogouts(list) }
        } catch {
            log.warn("account: pending logouts save failed")
        }
    }

    /// An outside event (start, foreground, network, login): start over, with the retry count at zero.
    private func flushPendingLogouts() {
        if let t = flushTimer { clock.clearTimeout(t) }
        flushTimer = nil
        flushFailures = 0
        startPendingFlush()
    }

    private func startPendingFlush() {
        guard !flushingPending else { return }
        flushingPending = true
        Task { [weak self] in
            guard let self else { return }
            let failed = await self.runPendingFlush()
            self.flushingPending = false
            if failed, self.flushFailures < pendingFlushRetries {
                let shift = min(self.flushFailures, 32)
                let base = min(backoffBaseMs << Int64(shift), backoffMaxMs)
                self.flushFailures += 1
                let delay = Int64((Double(base) * (1 + backoffJitter * (2 * self.random() - 1))).rounded())
                self.flushTimer = self.clock.setTimeout(delay) { [weak self] in
                    self?.flushTimer = nil
                    self?.startPendingFlush()
                }
            }
        }
    }

    /// Returns true when it stopped on a failure worth retrying.
    private func runPendingFlush() async -> Bool {
        await loadPendingIfNeeded()
        // The session being logged out right now has its own request.
        let active = current.map { _ in lineage.sid }
        for p in pendingLogouts where p.sid != active {
            do {
                _ = try await send(
                    EmptyResponse.self, .post, logoutPath, body: ["refreshToken": .string(p.refreshToken)], bearer: nil)
            } catch {
                log.warn("account: pending logout not sent: \(errorKind(error))")
                if retriableLogoutFailure(error) { return true }
            }
            await removePending(p)
        }
        return false
    }

    private func retriableLogoutFailure(_ error: Error) -> Bool {
        guard let e = error as? AccountError else { return true }
        return e.code == ErrorCode.rateLimited || e.code >= 5000
    }

    // MARK: Ending

    private func abandonRefresh() {
        guard let f = inflight else { return }
        f.task.cancel()
        settleRefresh(f.attempt, .ended)
    }

    /// Clears local credentials and tells everyone waiting. `localGen` stays.
    private func endSession(_ e: SessionEnd) {
        guard current != nil else { return }
        epoch += 1
        current = nil
        lastEnd = e
        memoryOnly = false
        unackedGen = nil
        shortOnArrival = false
        abandonRefresh()
        resetFailures()
        refreshQueued = false
        if let t = lifeTimer { clock.clearTimeout(t) }
        lifeTimer = nil
        let clearing = scheduleStoreWrite { try await $0.clear() }
        Task { [log] in
            if case .failure = await clearing?.result { log.warn("account: session clear failed") }
        }
        let w = waiters
        waiters = []
        for x in w {
            if let t = x.timer { clock.clearTimeout(t) }
            x.continuation.resume(throwing: SessionEndedError())
        }
        let held = heldKicks
        heldKicks = []
        // Already ended: held kicks have nothing left to do; the connection stays stopped or the fatal follows.
        for (_, decide) in held { decide(e.action == .logout ? .ignore : .pass) }
        for fn in Array(endedListeners.values) { fn(e) }
        emit(.ended(e))
    }

    /// Store calls run one at a time, in order: a `clear` cannot be overtaken by an earlier `save` still in progress.
    @discardableResult
    private func scheduleStoreWrite(
        _ op: @escaping @MainActor (AccountSessionStore) async throws -> Void
    ) -> Task<Void, Error>? {
        guard let store else { return nil }
        let previous = storeTail
        let t = Task { @MainActor in
            await previous?.value
            try await op(store)
        }
        storeTail = Task { @MainActor in _ = try? await t.value }
        return t
    }

    private func storeWrite(_ op: @escaping @MainActor (AccountSessionStore) async throws -> Void) async throws {
        try await scheduleStoreWrite(op)?.value
    }

    @discardableResult
    private func record(_ o: SessionOutcome) -> SessionOutcome {
        emit(.outcome(o))
        return o
    }

    // MARK: For the adapter

    fileprivate func addTokenListener(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        tokenListeners[id] = fn
        return { [weak self] in self?.tokenListeners[id] = nil }
    }

    fileprivate func addEndedListener(_ fn: @escaping @MainActor (SessionEnd) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        endedListeners[id] = fn
        return { [weak self] in self?.endedListeners[id] = nil }
    }

    fileprivate func addProfileListener(_ fn: @escaping @MainActor (String, ProfileChange) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        profileListeners[id] = fn
        return { [weak self] in self?.profileListeners[id] = nil }
    }

    fileprivate func noteRecoveryCodeUnacked() {
        emit(.recoveryCodeUnacked)
    }
}

/// Keeps `TokenProvider`'s calls off `AccountClient`'s public surface.
@MainActor
private final class AccountTokenProvider: TokenProvider {
    private weak var owner: AccountClient?

    init(owner: AccountClient) {
        self.owner = owner
    }

    func accessToken() async throws -> String {
        guard let owner else { throw SessionEndedError() }
        return try await owner.accessToken()
    }

    func tokenRejected(_ token: String) async throws {
        guard let owner else { throw SessionEndedError() }
        try await owner.tokenRejected(token)
    }

    func kickReceived(_ info: KickInfo, decide: @escaping @MainActor (KickDecision) -> Void) {
        guard let owner else { return decide(.pass) }
        owner.kickReceived(info, decide: decide)
    }

    func connectionChanged(_ connected: Bool) {
        owner?.connectionChanged(connected)
    }

    func foreground() {
        owner?.foreground()
    }

    func onTokenChanged(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        guard let owner else { return {} }
        return owner.addTokenListener(fn)
    }

    func onEnded(_ fn: @escaping @MainActor (SessionEnd) -> Void) -> @MainActor () -> Void {
        guard let owner else { return {} }
        return owner.addEndedListener(fn)
    }

    func onProfileChanged(_ fn: @escaping @MainActor (String, ProfileChange) -> Void) -> @MainActor () -> Void {
        guard let owner else { return {} }
        return owner.addProfileListener(fn)
    }

    func recoveryCodeUnacked() {
        owner?.noteRecoveryCodeUnacked()
    }
}

// MARK: - Helpers

private func is4011(_ error: Error) -> Bool {
    (error as? AccountError)?.code == ErrorCode.tokenExpired
}

private func retryAfterMs(_ seconds: Int64?) -> Int64 {
    guard let seconds, seconds > 0 else { return 1_000 }
    return min(seconds, retryAfterMaxSeconds) * 1000
}

/// `details` carries retryAfterSeconds and recoverBefore (server/internal/account/refresh.go).
private func failureOf(_ error: Error) -> RefreshFailure {
    guard let e = error as? AccountError else { return RefreshFailure(code: 0) }
    return RefreshFailure(
        code: e.code, reason: e.reason, retryAfterSeconds: e.details?["retryAfterSeconds"]?.intValue,
        recoverBefore: e.details?["recoverBefore"]?.intValue)
}

/// An incomplete response counts as a network error: stay on the page, it is not the server's decision.
private func parseAuth(_ r: AuthResponse) throws -> AuthResponse {
    guard !r.accessToken.isEmpty, !r.refreshToken.isEmpty else { throw AccountNetworkError.invalidResponse }
    return r
}

private func errorKind(_ error: Error) -> String {
    if let e = error as? AccountError { return "code \(e.code)" }
    if let e = error as? AccountNetworkError { return "\(e)" }
    return "error"
}

private func actionName(_ o: SessionOutcome) -> String {
    switch o {
    case .none: return "none"
    case .useLocal: return "useLocal"
    case .backoff: return "backoff"
    case .keepToken: return "keepToken"
    case .banNotice: return "banNotice"
    case .refresh: return "refresh"
    case .retryAfter: return "retryAfter"
    case .login: return "login"
    }
}
