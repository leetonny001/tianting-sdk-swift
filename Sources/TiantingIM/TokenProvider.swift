import Foundation

/// A kick the connection received. `reason` is nil when no `kicked` frame came or its reason is unknown: the close code
/// decides.
public struct KickInfo: Sendable, Equatable {
    public var reason: String?
    public var code: Int
    public var recoverBefore: Int64?

    public init(reason: String?, code: Int, recoverBefore: Int64? = nil) {
        self.reason = reason
        self.code = code
        self.recoverBefore = recoverBefore
    }
}

/// `.pass`: treat as a kick (back to login). `.ignore`: caused by our own `sid` change, reconnect with the new token.
public enum KickDecision: Sendable, Equatable {
    case pass, ignore
}

/// The account session ended; the app goes back to login.
public struct SessionEnd: Sendable, Equatable {
    public enum Action: String, Sendable { case login, banNotice, logout }
    public enum Origin: String, Sendable { case kick }

    public var action: Action
    public var dialog: SessionDialog?
    public var recoverBefore: Int64?
    /// The direct cause: 4019's reason, or the kick reason.
    public var reason: String?
    public var code: Int?
    /// `.kick`: from a kick on the connection; `IMClient`'s `fatal` already carried the same information.
    public var origin: Origin?

    public init(
        action: Action, dialog: SessionDialog? = nil, recoverBefore: Int64? = nil, reason: String? = nil, code: Int? = nil,
        origin: Origin? = nil
    ) {
        self.action = action
        self.dialog = dialog
        self.recoverBefore = recoverBefore
        self.reason = reason
        self.code = code
        self.origin = origin
    }

    /// The wording to show, or nil.
    public func dialogText(formatDate: ((Int64) -> String)? = nil) -> String? {
        sessionDialogText(dialog, recoverBefore: recoverBefore, formatDate: formatDate)
    }
}

/// Where `IMClient.connect(tokenProvider:)` gets tokens (PRD-chat 13.1, F-ACC-03 rule 5, RS5-10: HTTP and WS share one
/// source). `AccountClient.tokenProvider` implements it. `connect(token:)` has none of this (demo mode).
@MainActor
public protocol TokenProvider: AnyObject {
    /// Called before dialing. Refreshes first when expired; throws when the session ended.
    func accessToken() async throws -> String
    /// The connection got `kicked/tokenExpired` or close code 4011 (rule 7). After it returns, `accessToken()` is
    /// usable; throws when the session ended.
    func tokenRejected(_ token: String) async throws
    /// The connection was kicked (close codes 4010, 4012). `decide` may run later: the kick can be held (F-ACC-04 rule 3).
    func kickReceived(_ info: KickInfo, decide: @escaping @MainActor (KickDecision) -> Void)
    /// Timer-based refresh only runs while connected (rule 5).
    func connectionChanged(_ connected: Bool)
    /// Back in the foreground (rule 5).
    func foreground()
    /// The token changed: an open connection closes with 1000 and reconnects at once (rule 5). Returns the unsubscriber.
    func onTokenChanged(_ fn: @escaping @MainActor () -> Void) -> @MainActor () -> Void
    func onEnded(_ fn: @escaping @MainActor (SessionEnd) -> Void) -> @MainActor () -> Void
    /// The account's profile changed (F-ACC-06): this device shows the new nickname at once.
    func onProfileChanged(_ fn: @escaping @MainActor (_ userId: String, _ nickname: String) -> Void) -> @MainActor () -> Void
    /// The server says the newest recovery code generation is not acknowledged (F-ACC-05 rule 1).
    func recoveryCodeUnacked()
}
