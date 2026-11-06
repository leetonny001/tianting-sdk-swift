#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// FE-612: the SDK against a real im-server (test mode, SQLite, random port), with real HTTP, WebSocket and clock. Same
/// flows as sdk-ts test/integration/account.test.ts. The overlap window is 61 seconds (the configured minimum is 60), so
/// superseded-to-replay really waits a window. Local results on macOS; CI does not run.
private let goodPassword = "Tt-good-pass-2026!"
private let newPassword = "Tt-new-pass-2026!"

@MainActor
private final class KeychainLikeStore: AccountSessionStore {
    var saved: AccountSession?
    var pending: [PendingLogout] = []
    func load() async throws -> AccountSession? { saved }
    func save(_ session: AccountSession) async throws { saved = session }
    func clear() async throws { saved = nil }
    func loadPendingLogouts() async throws -> [PendingLogout] { pending }
    func savePendingLogouts(_ p: [PendingLogout]) async throws { pending = p }
}

/// Fails one transport call on demand, as if the network dropped: everything else goes to the real server.
@MainActor
private final class SwitchableHttp: HttpTransport {
    private let real = URLSessionHttpTransport()
    var offline = false
    func request(_ request: HttpRequest) async throws -> HttpResponse {
        if offline { throw URLError(.notConnectedToInternet) }
        return try await real.request(request)
    }
}

@MainActor
private final class Device {
    let account: AccountClient
    let store = KeychainLikeStore()
    let http = SwitchableHttp()
    let im: IMClient
    let logs = LogSink()
    var fatal: [FatalReason] = []
    var ended: [SessionEnd] = []
    var banner: [Bool] = []
    var notices: [SecurityNotice] = []

    init(srv: TestServer, platform: Platform = .ios) {
        var o = AccountClientOptions(baseUrl: srv.httpURL)
        o.platform = platform
        o.store = store
        o.logger = logs
        o.systemEvents = false
        o.http = http
        account = AccountClient(options: o)
        var io = IMClientOptions(url: srv.wsURL)
        io.platform = platform
        io.systemEvents = false
        io.logger = logs
        io.pushCursorStore = nil
        im = IMClient(options: io)
        im.on { [weak self] e in
            switch e {
            case .fatal(let r): self?.fatal.append(r)
            case .banner(let b): self?.banner.append(b)
            case .securityNotice(let n): self?.notices.append(n)
            default: break
            }
        }
        account.on { [weak self] e in
            if case .ended(let x) = e { self?.ended.append(x) }
        }
    }

    func connect() async throws {
        im.connect(tokenProvider: account.tokenProvider)
        try await untilTrue("connected") { self.im.state == .connected }
    }

    var sid: String { lineageOf(account.session?.accessToken ?? "").sid }
    var gen: Int64 { lineageOf(account.session?.accessToken ?? "").gen }
    var shownBanners: [Bool] { banner.filter { $0 } }
}

private final class LogSink: IMLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func debug(_ message: String) { add(message) }
    func warn(_ message: String) { add(message) }
    func error(_ message: String) { add(message) }
    private func add(_ m: String) {
        lock.lock()
        lines.append(m)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

@MainActor
final class AccountIntegrationTests: XCTestCase {
    nonisolated(unsafe) private static var server: TestServer?
    private var devices: [Device] = []
    private static var serial = 0

    private var srv: TestServer { AccountIntegrationTests.server! }

    override func setUp() async throws {
        try await super.setUp()
        if AccountIntegrationTests.server == nil {
            AccountIntegrationTests.server = try await TestServer.start(env: [
                "IM_REGISTER_MODE": "invite", "IM_REFRESH_OVERLAP": "61s",
                "IM_TEST_DISABLE_AUTH_LOCK": "1",  // Every test registers from the same address.
            ])
        }
    }

    override func tearDown() async throws {
        for d in devices { d.im.destroy() }
        devices = []
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func device(_ platform: Platform = .ios) -> Device {
        let d = Device(srv: srv, platform: platform)
        devices.append(d)
        return d
    }

    private func invite(_ maxUses: Int) async throws -> (code: String, id: String) {
        let r = try await srv.signed(
            "POST", "/admin/invites",
            ["count": 1, "maxUses": maxUses, "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000])
        let inv = (r["invites"] as! [[String: Any]])[0]
        return (inv["code"] as! String, inv["inviteId"] as! String)
    }

    private func stamp() -> String {
        AccountIntegrationTests.serial += 1
        return String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) + "\(AccountIntegrationTests.serial)"
    }

    /// Registers and acknowledges the recovery code.
    private func newUser(_ d: Device) async throws -> (username: String, recoveryCode: String) {
        let username = "user_\(stamp())"
        let (code, _) = try await invite(1)
        let r = try await d.account.register(username: username, password: goodPassword, inviteCode: code)
        XCTAssertNotNil(r.recoveryCode)
        XCTAssertNil(d.store.saved)  // Not on disk before the acknowledgement.
        try await d.account.ackRecoveryCode(gen: r.recoveryCodeGen!)
        XCTAssertEqual(d.store.saved?.mode, .account)
        return (username, r.recoveryCode!)
    }

    private func accountError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> AccountError? {
        do {
            try await body()
            XCTFail("expected an account error", file: file, line: line)
            return nil
        } catch let e as AccountError {
            return e
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: Register, login, config

    // TC-ACC-09-01
    func testTC_ACC_09_01_configAndInviteMaxUses() async throws {
        let d = device()
        let cfg = try await d.account.getConfig()
        XCTAssertEqual(cfg.registerMode, .invite)
        XCTAssertGreaterThan(cfg.limits.passwordMinLen, 0)
        let (code, id) = try await invite(2)
        let s = stamp()
        for n in [1, 2] {
            let r = try await device().account.register(username: "inv_\(s)\(n)", password: goodPassword, inviteCode: code)
            XCTAssertNotNil(r.recoveryCode)
        }
        let third = await accountError {
            _ = try await d.account.register(username: "inv_\(s)3", password: goodPassword, inviteCode: code)
        }
        XCTAssertEqual(third?.status, 403)
        XCTAssertEqual(third?.code, 4030)
        XCTAssertEqual(third?.reason, "inviteInvalid")
        XCTAssertNil(d.account.session)
        let list = try await srv.signed("GET", "/admin/invites")
        let row = (list["invites"] as! [[String: Any]]).first { ($0["inviteId"] as? String) == id }
        XCTAssertEqual(row?["usedCount"] as? Int, 2)
    }

    // TC-ACC-05-14
    func testTC_ACC_05_14_wrongPasswordTakenUsernameAndStaleCode() async throws {
        let d = device()
        let (username, _) = try await newUser(d)
        let wrong = await accountError { _ = try await self.device().account.login(username: username, password: "wrong-password-1") }
        XCTAssertEqual(wrong?.status, 401)
        XCTAssertEqual(wrong?.code, 4018)
        let (code, _) = try await invite(1)
        let taken = await accountError {
            _ = try await self.device().account.register(username: username, password: goodPassword, inviteCode: code)
        }
        XCTAssertEqual(taken?.status, 409)
        XCTAssertEqual(taken?.code, 4095)

        let d1 = device()
        _ = try await d1.account.login(username: username, password: goodPassword)
        let regenerated = try await d1.account.regenerateRecoveryCode(password: goodPassword)
        let again = try await d1.account.regenerateRecoveryCode(password: goodPassword)
        XCTAssertGreaterThan(again.recoveryCodeGen, regenerated.recoveryCodeGen)
        let stale = await accountError { try await d1.account.ackRecoveryCode(gen: regenerated.recoveryCodeGen) }
        XCTAssertEqual(stale?.status, 400)
        XCTAssertEqual(stale?.code, 4000)
        XCTAssertEqual(stale?.reason, "recoveryCodeStale")
        XCTAssertEqual(d1.ended.first?.dialog, .recoveryCodeStale)
        XCTAssertNil(d1.account.session)
    }

    // TC-ACC-02-13
    func testTC_ACC_02_13_newDeviceNoticeAndEvents() async throws {
        let d1 = device()
        let (username, _) = try await newUser(d1)
        try await d1.connect()
        let started = Date()
        let d2 = device(.android)
        _ = try await d2.account.login(username: username, password: goodPassword)
        try await untilTrue("securityNotice", timeout: 2) { !d1.notices.isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        XCTAssertEqual(d1.notices[0].kind, "newDeviceLogin")
        XCTAssertEqual(d1.notices[0].platform, "android")
        let events = try await d1.account.listEvents()
        XCTAssertGreaterThanOrEqual(events.otherSessions.count, 1)
        XCTAssertGreaterThan(events.events.count, 0)
        // Other kinds reach the SDK too (F-ACC-05 rule 5).
        _ = try await d2.account.regenerateRecoveryCode(password: goodPassword)
        try await untilTrue("recoveryCodeRegenerated", timeout: 2) {
            d1.notices.contains { $0.kind == "recoveryCodeRegenerated" }
        }
        XCTAssertEqual(d1.notices.first { $0.kind == "recoveryCodeRegenerated" }?.platform, "android")
    }

    // MARK: Refresh

    // TC-ACC-03-10
    func testTC_ACC_03_10_refreshReconnectsMessagesFlowNoBanner() async throws {
        let d = device()
        let (username, _) = try await newUser(d)
        let peer = device()
        let (peerName, _) = try await newUser(peer)
        try await peer.connect()
        try await d.connect()
        let (sid, gen) = (d.sid, d.gen)
        try await d.account.refresh()
        XCTAssertEqual(d.sid, sid)
        XCTAssertGreaterThan(d.gen, gen)
        XCTAssertEqual(d.store.saved?.accessToken, d.account.session?.accessToken)
        try await untilTrue("reconnected") { d.im.state == .connected }
        try await sleepMs(1_200)
        XCTAssertEqual(d.shownBanners, [])
        XCTAssertEqual(d.fatal, [])

        _ = try await d.account.listEvents()  // HTTP takes the new generation too (promoted by now).
        let conv = c2cConvId(username, peerName)
        _ = try d.im.send(conv, "after rotate")
        try await untilTrue("peer receives") { peer.im.messages(conv).contains { $0.body.text == "after rotate" } }
        try await d.account.refresh()
        try await untilTrue("reconnected again") { d.im.state == .connected }
        _ = try await d.account.listEvents()
        XCTAssertEqual(d.ended, [])
    }

    // Rules 4, 6, 7, TC-ACC-03-26, TC-ACC-03-41: an attacker promotes; the online victim gets 4011, is not newer, gets
    // superseded, and after the window replayDetected.
    func testTC_ACC_03_26_attackerPromotesVictimSeesAnomaly() async throws {
        let victim = device()
        _ = try await newUser(victim)
        try await victim.connect()
        let stolen = victim.account.session!.refreshToken!
        var r = URLRequest(url: URL(string: "\(srv.httpURL)/v1/account/token/refresh")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": stolen])
        let (data, resp) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let access = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["accessToken"] as! String
        var ev = URLRequest(url: URL(string: "\(srv.httpURL)/v1/account/events")!)
        ev.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (_, evResp) = try await URLSession.shared.data(for: ev)
        XCTAssertEqual((evResp as? HTTPURLResponse)?.statusCode, 200)
        try await untilTrue("victim ended", timeout: 75) { !victim.ended.isEmpty }
        XCTAssertEqual(victim.ended[0].action, .login)
        XCTAssertEqual(victim.ended[0].dialog, .credentialAnomaly)
        XCTAssertEqual(victim.ended[0].reason, "replayDetected")
        XCTAssertEqual(victim.ended[0].code, 4019)
        XCTAssertTrue(victim.ended[0].dialogText()?.contains("检测到登录凭证异常") == true)
        guard case .session(let e)? = victim.fatal.first else { return XCTFail("fatal") }
        XCTAssertEqual(e.dialog, .credentialAnomaly)
        XCTAssertTrue(victim.logs.all.contains { $0.contains("superseded") })
        XCTAssertNil(victim.store.saved)
        XCTAssertEqual(victim.im.state, .disconnected)
    }

    // TC-ACC-03-44, the real version.
    func testTC_ACC_03_44_supersededAccessGets4011WithReason() async throws {
        let d = device()
        _ = try await newUser(d)
        let old = d.account.session!.accessToken
        try await d.account.refresh()
        _ = try await d.account.listEvents()  // Promotes the new generation; the old access is refused from here on.
        var ev = URLRequest(url: URL(string: "\(srv.httpURL)/v1/account/events")!)
        ev.setValue("Bearer \(old)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: ev)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 401)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(body["code"] as? Int, 4011)
        XCTAssertEqual(body["reason"] as? String, "tokenSuperseded")
        XCTAssertEqual(d.account.http4011(RejectedToken(lineageOf(old))), .useLocal)
    }

    // TC-ACC-03-07: expired locally on a cold start refreshes before auth.
    func testTC_ACC_03_07_expiredColdStart() async throws {
        let d = device()
        _ = try await newUser(d)
        var saved = d.account.session!
        let gen = d.gen
        saved.accessExpiresAt = Int64(Date().timeIntervalSince1970 * 1000) - 1_000
        let d2 = device()
        d2.store.saved = saved
        try await d2.account.start()
        try await d2.connect()
        XCTAssertGreaterThan(d2.gen, gen)
        XCTAssertEqual(d2.fatal, [])
    }

    // MARK: Password, other devices, recovery, logout, delete

    // TC-ACC-04-02, TC-ACC-03-34, TC-ACC-04-15
    func testTC_ACC_04_02_passwordChangeOldKickOthersKickedWithDate() async throws {
        let d1 = device()
        let (username, _) = try await newUser(d1)
        let d2 = device(.android)
        _ = try await d2.account.login(username: username, password: goodPassword)
        try await d1.connect()
        try await d2.connect()
        let oldRefresh = d1.account.session!.refreshToken!
        let oldSid = d1.sid

        let wrong = await accountError {
            _ = try await d1.account.changePassword(oldPassword: "wrong-password-1", newPassword: newPassword)
        }
        XCTAssertEqual(wrong?.code, 4018)
        XCTAssertEqual(d1.fatal, [])

        let started = Date()
        let r = try await d1.account.changePassword(oldPassword: goodPassword, newPassword: newPassword)
        XCTAssertNotNil(r.recoveryCode)
        try await untilTrue("d1 reconnected", timeout: 1) { d1.im.state == .connected }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotEqual(d1.sid, oldSid)
        XCTAssertNil(d1.store.saved)  // Not on disk before the acknowledgement.
        try await sleepMs(1_200)
        XCTAssertEqual(d1.fatal, [])
        XCTAssertEqual(d1.ended, [])
        XCTAssertEqual(d1.shownBanners, [])

        try await untilTrue("d2 kicked") { !d2.fatal.isEmpty }
        guard case .kicked("passwordChanged", 4012, _, let before?)? = d2.fatal.first else {
            return XCTFail("d2 fatal \(d2.fatal)")
        }
        // F-ACC-05 rule 5: the other device gets the notice first, the initiating one gets none (issue table A13, A14).
        XCTAssertEqual(d2.notices.map(\.kind), ["passwordChanged"])
        XCTAssertEqual(d1.notices.map(\.kind), [])
        XCTAssertGreaterThan(before, Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(d2.ended.first?.dialog, .recoverBefore)
        XCTAssertEqual(d2.ended.first?.recoverBefore, before)
        XCTAssertNil(d2.account.session)

        // The device whose response was lost: the old refresh is not a replay (TC-ACC-04-15).
        let lost = device()
        var old = d1.account.session!
        old.refreshToken = oldRefresh
        lost.account.restore(old)
        do {
            try await lost.account.refresh()
            XCTFail("expected a failure")
        } catch {}
        XCTAssertEqual(lost.ended.first?.action, .login)
        XCTAssertEqual(lost.ended.first?.dialog, .recoverBefore)
        XCTAssertEqual(lost.ended.first?.reason, "credentialsChanged")
        XCTAssertEqual(lost.ended.first?.code, 4019)

        try await d1.account.ackRecoveryCode(gen: r.recoveryCodeGen!)
        XCTAssertEqual(d1.store.saved?.accessToken, d1.account.session?.accessToken)
        let fresh = try await device().account.login(username: username, password: newPassword)
        XCTAssertEqual(fresh.userId, username)
    }

    // TC-ACC-03-34
    func testTC_ACC_03_34_offlineDeviceOnlineAfterPasswordChange() async throws {
        let d1 = device()
        let (username, _) = try await newUser(d1)
        let offline = device(.android)
        _ = try await offline.account.login(username: username, password: goodPassword)
        _ = try await d1.account.changePassword(oldPassword: goodPassword, newPassword: newPassword)
        offline.im.connect(tokenProvider: offline.account.tokenProvider)
        try await untilTrue("offline device kicked") { !offline.fatal.isEmpty }
        guard case .kicked("passwordChanged", 4012, _, let before?)? = offline.fatal.first else {
            return XCTFail("fatal \(offline.fatal)")
        }
        XCTAssertGreaterThan(before, Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(offline.ended.first?.dialog, .recoverBefore)
        try await sleepMs(1_200)
        XCTAssertEqual(offline.im.state, .disconnected)
    }

    // TC-ACC-04-09
    func testTC_ACC_04_09_logoutOthers() async throws {
        let d1 = device()
        let (username, _) = try await newUser(d1)
        let d2 = device(.android)
        _ = try await d2.account.login(username: username, password: goodPassword)
        try await d1.connect()
        try await d2.connect()
        let sid = d1.sid
        let wrong = await accountError { _ = try await d1.account.logoutOthers(password: "wrong-password-1") }
        XCTAssertEqual(wrong?.code, 4018)
        XCTAssertEqual(d2.fatal, [])
        _ = try await d1.account.logoutOthers(password: goodPassword)
        try await untilTrue("d1 reconnected", timeout: 1) { d1.im.state == .connected }
        XCTAssertNotEqual(d1.sid, sid)
        XCTAssertEqual(d1.store.saved?.accessToken, d1.account.session?.accessToken)
        try await untilTrue("d2 kicked") { !d2.fatal.isEmpty }
        guard case .kicked("sessionRevoked", 4012, _, _)? = d2.fatal.first else { return XCTFail("fatal \(d2.fatal)") }
        try await sleepMs(1_200)
        XCTAssertEqual(d1.fatal, [])
        XCTAssertEqual(d1.shownBanners, [])
        _ = try await d1.account.listEvents()
    }

    // TC-ACC-05-05
    func testTC_ACC_05_05_recovery() async throws {
        let d1 = device()
        let (username, code) = try await newUser(d1)
        try await d1.connect()
        let lost = device(.android)
        let r = try await lost.account.recover(username: username, recoveryCode: code, newPassword: newPassword)
        XCTAssertNotNil(r.recoveryCode)
        XCTAssertNotEqual(r.recoveryCode, code)
        try await untilTrue("old device kicked") { !d1.fatal.isEmpty }
        guard case .kicked("passwordChanged", _, _, _)? = d1.fatal.first else { return XCTFail("fatal \(d1.fatal)") }
        try await lost.account.ackRecoveryCode(gen: r.recoveryCodeGen!)
        let fresh = try await device().account.login(username: username, password: newPassword)
        XCTAssertEqual(fresh.userId, username)
        let old = await accountError { _ = try await self.device().account.login(username: username, password: goodPassword) }
        XCTAssertEqual(old?.code, 4018)
        let reused = await accountError {
            _ = try await self.device().account.recover(username: username, recoveryCode: code, newPassword: goodPassword)
        }
        XCTAssertEqual(reused?.code, 4018)
    }

    // TC-ACC-06-05, the server part.
    func testTC_ACC_06_05_nickname() async throws {
        let d = device()
        let (username, _) = try await newUser(d)
        let peer = device()
        let (peerName, _) = try await newUser(peer)
        try await srv.admin(
            "POST", "/admin/groups", ["groupId": "g\(stamp())", "name": "测试群", "members": [username, peerName]])
        try await peer.connect()
        try await d.connect()
        try await d.account.updateProfile(nickname: "小明")
        XCTAssertEqual(d.im.displayName(username), "小明")
        let users = await peer.im.getUsers([username])
        XCTAssertEqual(users.first?.nickname, "小明")
    }

    // TC-ACC-04-01 (SDK part)
    func testTC_ACC_04_01_logoutRevokes() async throws {
        let d = device()
        _ = try await newUser(d)
        try await d.connect()
        let refresh = d.account.session!.refreshToken!
        let confirmed = await d.account.logout()
        XCTAssertTrue(confirmed)
        try await untilTrue("disconnected") { d.im.state == .disconnected }
        XCTAssertEqual(d.fatal, [])
        XCTAssertEqual(d.ended, [SessionEnd(action: .logout)])
        XCTAssertNil(d.store.saved)
        XCTAssertEqual(d.store.pending, [])
        let again = try await rawRefresh(refresh)
        XCTAssertEqual(again.status, 401)
        XCTAssertEqual(again.body["code"] as? Int, 4019)
        XCTAssertEqual(again.body["reason"] as? String, "revoked")
    }

    private func rawRefresh(_ token: String) async throws -> (status: Int, body: [String: Any]) {
        var r = URLRequest(url: URL(string: "\(srv.httpURL)/v1/account/token/refresh")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": token])
        let (data, resp) = try await URLSession.shared.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    // TC-ACC-04-06, the server part: an offline logout, then the record goes out with only the refresh token.
    func testTC_ACC_04_06_offlineLogoutThenPendingRevokesOnTheServer() async throws {
        let d = device()
        _ = try await newUser(d)
        let refresh = d.account.session!.refreshToken!
        d.http.offline = true
        let confirmed = await d.account.logout()
        XCTAssertFalse(confirmed)
        XCTAssertNil(d.account.session)
        try await untilTrue("store cleared") { d.store.saved == nil }
        XCTAssertEqual(d.store.pending.count, 1)
        // Still valid on the server until the record is sent.
        let before = try await rawRefresh(refresh)
        XCTAssertEqual(before.status, 200)
        d.http.offline = false
        d.account.networkOnline()
        try await untilTrue("record sent") { d.store.pending.isEmpty }
        let after = try await rawRefresh(refresh)
        XCTAssertEqual(after.status, 401)
        XCTAssertEqual(after.body["reason"] as? String, "revoked")
    }

    // F-ACC-08
    func testDeleteCoolingOffCancel() async throws {
        let d = device()
        let (username, _) = try await newUser(d)
        try await d.connect()
        let wrong = await accountError { try await d.account.requestDelete(password: "wrong-password-1") }
        XCTAssertEqual(wrong?.code, 4018)
        XCTAssertNotNil(d.account.session)
        try await d.account.requestDelete(password: goodPassword)
        XCTAssertNil(d.account.session)
        try await untilTrue("disconnected") { d.im.state == .disconnected }
        XCTAssertEqual(d.fatal.count, 1)
        let pending = await accountError { _ = try await self.device().account.login(username: username, password: goodPassword) }
        XCTAssertEqual(pending?.status, 403)
        XCTAssertEqual(pending?.code, 4030)
        XCTAssertEqual(pending?.reason, "accountDeletionPending")
        try await device().account.cancelDelete(username: username, password: goodPassword)
        let back = try await device().account.login(username: username, password: goodPassword)
        XCTAssertEqual(back.userId, username)
    }

    // Logs
    func testLogsHoldNoCredentialsAfterTheFlows() async throws {
        let d = device()
        let (_, recoveryCode) = try await newUser(d)
        try await d.connect()
        let access = d.account.session!.accessToken
        let refresh = d.account.session!.refreshToken!
        try await d.account.refresh()
        let wrong = await accountError {
            _ = try await d.account.changePassword(oldPassword: "wrong-password-1", newPassword: newPassword)
        }
        XCTAssertEqual(wrong?.code, 4018)
        _ = try await d.account.changePassword(oldPassword: goodPassword, newPassword: newPassword)
        XCTAssertGreaterThan(d.logs.all.count, 0)
        for l in d.logs.all {
            for secret in [access, refresh, recoveryCode, goodPassword, newPassword] {
                XCTAssertFalse(l.contains(secret), l)
            }
            XCTAssertFalse(l.contains("eyJ"), l)
            XCTAssertFalse(l.contains("?"), l)
        }
    }
}
#endif
