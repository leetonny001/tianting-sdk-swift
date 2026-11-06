import Foundation

// Account session decisions (PRD-chat F-ACC-03 rules 5, 6, 6a, 7): pure functions, no network, storage or timers.
// One to one with server/e2e/accountmodel/model.go and sdk-ts src/account-policy.ts; protocol/vectors/account-session.json
// constrains them. Semantics: docs/sdk/README.md section 6 in tianting-server.

/// Refresh when less than this remains (a quarter of IM_ACCESS_TTL, rule 5). Exactly 6 hours left does not refresh.
let refreshBelowMs: Int64 = 6 * 3600 * 1000
/// This many `superseded` in a row go back to login (rule 6).
let maxSuperseded = 3
/// Timeout of refresh, password change and the other account requests (rule 5, RS5-15).
let accountRequestTimeoutMs: Int64 = 30_000

/// What to tell the user when going back to login (rules 6, 6a). Names as in model.go.
public enum SessionDialog: String, Sendable, Equatable {
    case sessionExpired
    case credentialAnomaly
    case recoverBefore
    case supersededExceeded
    /// A kick without a date, with close code 4012's copy.
    case accountOffline
    case recoveryCodeStale
}

/// The result of one decision. Actions as in model.go. Never holds a credential.
public enum SessionOutcome: Sendable, Equatable {
    case none
    case useLocal
    case backoff
    case keepToken
    case banNotice
    case refresh(attempt: Int64)
    case retryAfter(seconds: Int64?)
    case login(dialog: SessionDialog?, recoverBefore: Int64?)
}

public enum RefreshSource: String, Sendable {
    case start, foreground, timer, kicked
}

/// A failed refresh. `code` 0 means no error code from the server: network error, timeout, or not the agreed JSON.
struct RefreshFailure: Sendable, Equatable {
    var code: Int
    var reason: String?
    var retryAfterSeconds: Int64?
    var recoverBefore: Int64?
}

/// A token's identity. Different `sid`s are different chains whose generations do not compare: a new `sid` starts at
/// gen 1 after a password change or "log out other devices".
public struct TokenLineage: Sendable, Equatable {
    public var sid: String
    public var gen: Int64

    public init(sid: String, gen: Int64) {
        self.sid = sid
        self.gen = gen
    }
}

/// What is known about a rejected token: a connection knows both, a vector only the generation.
struct RejectedToken: Sendable, Equatable {
    var sid: String?
    var gen: Int64?

    init(sid: String? = nil, gen: Int64? = nil) {
        self.sid = sid
        self.gen = gen
    }

    init(_ l: TokenLineage) {
        sid = l.sid
        gen = l.gen
    }
}

/// `sid` and `gen` from a JWT, only for comparing: not verified. Unparsable means ("", 0): the oldest, so the safe path
/// (a refresh) is taken.
func lineageOf(_ token: String) -> TokenLineage {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return TokenLineage(sid: "", gen: 0) }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64),
        let claims = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return TokenLineage(sid: "", gen: 0) }
    return TokenLineage(sid: claims["sid"]?.stringValue ?? "", gen: claims["gen"]?.intValue ?? 0)
}

/// Rule 7: is the local token newer than the rejected one? A changed `sid` always is: the SDK only ever moves from an
/// old `sid` to a new one.
func isLocalNewer(_ local: TokenLineage, than rejected: RejectedToken) -> Bool {
    if let sid = rejected.sid, sid != local.sid { return true }
    return local.gen > (rejected.gen ?? 0)
}

/// Rule 5 and RS5-11: should this session refresh on its own now?
func shouldRefresh(accessExpiresAt: Int64, absoluteExpiresAt: Int64?, now: Int64) -> Bool {
    if accessExpiresAt == absoluteExpiresAt { return false }
    return accessExpiresAt - now < refreshBelowMs
}

/// Rules 6, 6a. `superseded` counts the ones received in a row before this one. As model.go's RefreshFailed: code 0,
/// 4290 and 5xx stay and back off; unlisted codes go to login.
func classifyRefreshFailure(_ f: RefreshFailure, superseded: Int) -> SessionOutcome {
    if f.code == 0 || f.code == ErrorCode.rateLimited || f.code >= 5000 { return .backoff }
    if f.code == ErrorCode.userBanned { return .banNotice }
    if f.code == ErrorCode.refreshTokenInvalid {
        if f.reason == "superseded" {
            if superseded + 1 >= maxSuperseded { return .login(dialog: .supersededExceeded, recoverBefore: nil) }
            return .retryAfter(seconds: positive(f.retryAfterSeconds))
        }
        if f.reason == "replayDetected" {
            return .login(dialog: .credentialAnomaly, recoverBefore: positive(f.recoverBefore))
        }
        return loginWithDate(.sessionExpired, f.recoverBefore)
    }
    return .login(dialog: .sessionExpired, recoverBefore: nil)
}

/// The dialog for a kick: a date always wins (rule 6a).
func kickOutcome(reason: String?, recoverBefore: Int64?) -> SessionOutcome {
    if reason == "tokenInvalid" || reason == "tokenExpired" { return .login(dialog: .sessionExpired, recoverBefore: nil) }
    return loginWithDate(.accountOffline, recoverBefore)
}

private func loginWithDate(_ dialog: SessionDialog, _ recoverBefore: Int64?) -> SessionOutcome {
    if let d = positive(recoverBefore) { return .login(dialog: .recoverBefore, recoverBefore: d) }
    return .login(dialog: dialog, recoverBefore: nil)
}

private func positive(_ v: Int64?) -> Int64? {
    guard let v, v > 0 else { return nil }
    return v
}

/// This kick means the device session is gone (close codes 4010, 4012): the local token must go too.
func kickEndsSession(reason: String?, code: Int) -> Bool {
    guard let reason else { return code == 4010 || code == 4012 }
    let c = kickCloseCode[reason] ?? nil
    return c == 4010 || c == 4012
}

/// Kicks held while a credential change is in flight (F-ACC-04 rule 3). Bans and the like are not. Unknown reasons go by
/// the close code.
func kickIsHoldable(reason: String?, code: Int) -> Bool {
    if reason == "passwordChanged" || reason == "sessionRevoked" || reason == "accountDeleted" { return true }
    return reason == nil && code == 4012
}

/// The PRD's wording (rules 6, 6a, F-ACC-05 rule 1): the same sentence on all clients, so it lives in the SDK.
/// `formatDate` lets the app choose the time zone and format.
public func sessionDialogText(
    _ dialog: SessionDialog?, recoverBefore: Int64? = nil, formatDate: ((Int64) -> String)? = nil
) -> String? {
    switch dialog {
    case .credentialAnomaly:
        return "检测到登录凭证异常，这台设备已下线。如果不是你本人操作，请尽快改密码"
    case .recoverBefore:
        let format = formatDate ?? defaultDialogDate
        return "你的账号凭证有变化。如果不是你本人操作，请在 \(format(recoverBefore ?? 0)) 前用恢复码找回"
    case .sessionExpired, .supersededExceeded:
        return "登录已失效，请重新登录"
    case .accountOffline:
        return "账号已被下线"
    case .recoveryCodeStale:
        return "恢复码已更新，请重新登录查看"
    case nil:
        return nil
    }
}

private func defaultDialogDate(_ ms: Int64) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy/M/d"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
}
