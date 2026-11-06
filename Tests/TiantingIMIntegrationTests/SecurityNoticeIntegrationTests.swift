#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// FE-620: security notices reaching sdk-swift from a real im-server (test mode, SQLite, random port). Same flows as sdk-ts
/// test/integration/security-notice.test.ts. A server of its own: the tests move the server clock and trust
/// X-Forwarded-For. F-ACC-02 rule 3b, F-ACC-03 rule 4, F-ACC-05 rule 5; issues A13, A14. Local results on macOS; CI does not run.
private let goodPassword = "Tt-good-pass-2026!"
private let newPassword = "Tt-new-pass-2026!"
private let minute: Int64 = 60_000
private let hour: Int64 = 60 * minute

/// Logs notices and kicks in arrival order: the kind, or kicked/reason.
@MainActor
private final class NoticeDevice {
    let account: AccountClient
    let im: IMClient
    var log: [String] = []
    var platforms: [String: String] = [:]

    init(srv: TestServer, platform: Platform) {
        var o = AccountClientOptions(baseUrl: srv.httpURL)
        o.platform = platform
        o.systemEvents = false
        account = AccountClient(options: o)
        var io = IMClientOptions(url: srv.wsURL)
        io.platform = platform
        io.systemEvents = false
        io.pushCursorStore = nil
        im = IMClient(options: io)
        im.on { [weak self] e in
            switch e {
            case .securityNotice(let n):
                self?.log.append(n.kind)
                self?.platforms[n.kind] = n.platform
            case .fatal(.kicked(let reason, _, _, _)):
                self?.log.append("kicked/\(reason)")
            case .fatal(let other):
                self?.log.append("\(other)")
            default: break
            }
        }
    }

    func connect() async throws {
        im.connect(tokenProvider: account.tokenProvider)
        try await untilTrue("connected") { self.im.state == .connected }
    }

    var refreshToken: String { account.session?.refreshToken ?? "" }
}

@MainActor
final class SecurityNoticeIntegrationTests: XCTestCase {
    nonisolated(unsafe) private static var server: TestServer?
    private static var serial = 0
    private var devices: [NoticeDevice] = []
    private var srv: TestServer { SecurityNoticeIntegrationTests.server! }

    override func setUp() async throws {
        try await super.setUp()
        if SecurityNoticeIntegrationTests.server == nil {
            SecurityNoticeIntegrationTests.server = try await TestServer.start(env: [
                "IM_REGISTER_MODE": "invite", "IM_TRUSTED_PROXIES": "127.0.0.1",
            ])
        }
    }

    override func tearDown() async throws {
        for d in devices { d.im.destroy() }
        devices = []
        _ = try await srv.admin("POST", "/admin/test/clock", ["nowMs": NSNull()])
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func device(_ platform: Platform) -> NoticeDevice {
        let d = NoticeDevice(srv: srv, platform: platform)
        devices.append(d)
        return d
    }

    /// A new account: d1 (web) registers and acknowledges, d2 (ios) logs in. Neither is connected.
    private func pair() async throws -> (username: String, recoveryCode: String, d1: NoticeDevice, d2: NoticeDevice) {
        SecurityNoticeIntegrationTests.serial += 1
        let username = "notice_" + String(nowMs(), radix: 36) + "\(SecurityNoticeIntegrationTests.serial)"
        let r = try await srv.signed("POST", "/admin/invites", ["count": 1, "maxUses": 1, "expiresAt": nowMs() + 86_400_000])
        let code = (r["invites"] as! [[String: Any]])[0]["code"] as! String
        let d1 = device(.web)
        let reg = try await d1.account.register(username: username, password: goodPassword, inviteCode: code)
        try await d1.account.ackRecoveryCode(gen: reg.recoveryCodeGen!)
        let d2 = device(.ios)
        _ = try await d2.account.login(username: username, password: goodPassword)
        return (username, reg.recoveryCode!, d1, d2)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func setClock(_ ms: Int64) async throws { _ = try await srv.admin("POST", "/admin/test/clock", ["nowMs": ms]) }

    private func quiet() async throws { try await sleepMs(200) }

    /// A refresh that skips the SDK: whoever holds a stolen refresh token.
    private func rawRefresh(_ token: String, ip: String? = nil) async throws -> (status: Int, accessToken: String?) {
        var req = URLRequest(url: URL(string: srv.httpURL + "/v1/account/token/refresh")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ip { req.setValue(ip, forHTTPHeaderField: "X-Forwarded-For") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": token])
        let (data, res) = try await URLSession.shared.data(for: req)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((res as! HTTPURLResponse).statusCode, body?["accessToken"] as? String)
    }

    private func rawEventsStatus(_ bearer: String) async throws -> Int {
        var req = URLRequest(url: URL(string: srv.httpURL + "/v1/account/events")!)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (_, res) = try await URLSession.shared.data(for: req)
        return (res as! HTTPURLResponse).statusCode
    }

    // AC-ACC-03-25
    func testRefreshReplayReachesOtherDevices() async throws {
        let p = try await pair()
        try await p.d2.connect()
        let stolen = p.d1.refreshToken
        let now = nowMs()
        try await setClock(now)
        let x = try await rawRefresh(stolen)
        XCTAssertEqual(x.status, 200)
        // The attacker promotes; after the window the old value is a replay.
        let promoted = try await rawEventsStatus(x.accessToken!)
        XCTAssertEqual(promoted, 200)
        try await setClock(now + 3 * minute)
        let replay = try await rawRefresh(stolen)
        XCTAssertEqual(replay.status, 401)
        try await untilTrue("refreshReplay") { p.d2.log.contains("refreshReplay") }
        XCTAssertEqual(p.d2.platforms["refreshReplay"], "web")
    }

    // AC-ACC-03-45
    func testRefreshRateLimitedReachesOtherDevicesInTheSixthHour() async throws {
        let p = try await pair()
        try await p.d2.connect()
        let held = p.d1.refreshToken
        let start = nowMs()
        for h in 0..<6 {
            try await setClock(start + Int64(h) * hour)
            for i in 0..<21 {
                let r = try await rawRefresh(held)
                XCTAssertEqual(r.status, i == 20 ? 429 : 200)
            }
            if h == 4 {
                try await quiet()
                XCTAssertEqual(p.d2.log, [])
            }
        }
        try await untilTrue("refreshRateLimited") { p.d2.log.contains("refreshRateLimited") }
        XCTAssertEqual(p.d2.platforms["refreshRateLimited"], "web")
    }

    // A13
    func testNewIpPrefixReachesOthersOncePerPrefixNotTheInitiator() async throws {
        let p = try await pair()
        try await p.d1.connect()
        try await p.d2.connect()
        let first = try await rawRefresh(p.d1.refreshToken, ip: "192.0.2.1")
        XCTAssertEqual(first.status, 200)
        try await untilTrue("newIpPrefix") { p.d2.log.contains("newIpPrefix") }
        XCTAssertEqual(p.d2.platforms["newIpPrefix"], "web")
        try await quiet()
        XCTAssertEqual(p.d1.log, [])
        _ = try await rawRefresh(p.d1.refreshToken, ip: "192.0.2.77")
        try await quiet()
        XCTAssertEqual(p.d2.log, ["newIpPrefix"])
    }

    // F-ACC-02 rule 3b
    func testPasswordRecoveredNoticeComesBeforeTheKickOnEveryDevice() async throws {
        let p = try await pair()
        try await p.d1.connect()
        try await p.d2.connect()
        _ = try await device(.web).account.recover(username: p.username, recoveryCode: p.recoveryCode, newPassword: newPassword)
        try await untilTrue("both kicked") { p.d1.log.count >= 2 && p.d2.log.count >= 2 }
        XCTAssertEqual(p.d1.log, ["passwordRecovered", "kicked/passwordChanged"])
        XCTAssertEqual(p.d2.log, ["passwordRecovered", "kicked/passwordChanged"])
    }

    // F-ACC-05 rule 5
    func testPasswordChangedNoticeComesBeforeTheKickInitiatorGetsNeither() async throws {
        let p = try await pair()
        try await p.d1.connect()
        try await p.d2.connect()
        _ = try await p.d1.account.changePassword(oldPassword: goodPassword, newPassword: newPassword)
        try await untilTrue("d2 kicked") { p.d2.log.count >= 2 }
        XCTAssertEqual(p.d2.log, ["passwordChanged", "kicked/passwordChanged"])
        XCTAssertEqual(p.d2.platforms["passwordChanged"], "web")
        try await quiet()
        XCTAssertEqual(p.d1.log, [])
    }

    // A14
    func testRecoveryCodeRegeneratedInitiatorGetsNoNotice() async throws {
        let p = try await pair()
        try await p.d1.connect()
        try await p.d2.connect()
        _ = try await p.d1.account.regenerateRecoveryCode(password: goodPassword)
        try await untilTrue("recoveryCodeRegenerated") { p.d2.log.contains("recoveryCodeRegenerated") }
        try await quiet()
        XCTAssertEqual(p.d1.log, [])
    }
}
#endif
