// The semantics all three SDKs share (issues S1, K7, S3, K5 in frontend-chat, docs/sdk/README.md section 6). sdk-ts has
// test/account-unified.test.ts and sdk-kotlin AccountUnifiedTest with the same cases. Local results only, CI does not run.
import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// Past this many refreshes the fake server stops answering: a loop then fails an assertion instead of hanging the run.
private let answerCap: Int64 = 50

@MainActor
final class AccountUnifiedTests: AccountTestCase {
    /// A fake server: answers every refresh at once with a new token whose expiry comes from `left`.
    private func autoRefresh(_ h: AccountHarness, left: @escaping () -> Int64) {
        let previous = h.http.onRequest
        var gen: Int64 = 100
        h.http.onRequest = { call in
            previous?(call)
            guard call.path == REFRESH, gen - 100 < answerCap else { return }
            gen += 1
            call.respond(200, authBody(gen: gen, accessExpiresAt: h.clock.now() + left()))
        }
    }

    /// `rounds` rounds: a new connection finishes auth by itself, the clock moves on.
    private func run(_ h: AccountHarness, _ rounds: Int) async {
        for _ in 0..<rounds {
            await settle()
            if let c = h.transport.connections.last, c.closedWith == nil, c.last("auth") == nil {
                await h.base.login(USER)
            }
            h.clock.advance(1_000)
        }
        await settle()
    }

    // MARK: S1

    func testS1_shortTTLRefreshesOnceAndDoesNotLoop() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 5 * HOUR)
        autoRefresh(h) { 4 * HOUR }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await run(h, 30)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertNil(h.transport.current.closedWith)
        XCTAssertEqual(w.ended, [])
    }

    func testS1_fastClockExpiredAtStartRefreshesFirstThenStaysQuiet() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, -HOUR)
        autoRefresh(h) { -MIN }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 1)
        let c = await h.authNew()
        XCTAssertEqual(authToken(c), jwt("sid1", 101))
        await run(h, 30)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 1)
        h.transport.current.drop(1006)
        await run(h, 3)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertEqual(authToken(h.transport.current), jwt("sid1", 101))
        XCTAssertEqual(w.ended, [])
    }

    func testS1_foregroundTimerAndHttpDoNotRefresh() async throws {
        let h = setupAccount()
        h.session(1, 5 * HOUR)
        autoRefresh(h) { -MIN }
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.account.foreground()
        h.account.trigger(.timer)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)

        let events = Task { try await h.account.listEvents() }
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last("/v1/account/events").respond(200, ["events": [], "otherSessions": ["count": 0]])
        _ = try await events.value

        let change = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last(PASSWORD).respond(200, authBody(sid: "sid2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await change.value
    }

    func testS1_each4011RefreshesAtMostOnce() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 5 * HOUR)
        autoRefresh(h) { 4 * HOUR }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await run(h, 3)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        for i in 1...5 {
            h.transport.current.drop(4011)
            await run(h, 40)  // From the second one on it reconnects with backoff.
            XCTAssertEqual(h.http.to(REFRESH).count, 1 + i)
        }
        XCTAssertEqual(w.ended, [])
    }

    func testS1_tokenFromAPasswordChangeMayRefreshOnce() async throws {
        let h = setupAccount()
        h.session(1, 5 * HOUR)
        autoRefresh(h) { 4 * HOUR }
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        let change = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respond(200, authBody(sid: "sid2", gen: 1, accessExpiresAt: h.clock.now() + 4 * HOUR))
        _ = try await change.value
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testS1_absoluteLimitStillEnds() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 5 * HOUR)
        let at = h.clock.now() + 2 * HOUR
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: at, absoluteExpiresAt: at))
        await settle()
        await h.online()
        h.clock.advance(2 * HOUR)
        await settle()
        XCTAssertEqual(w.ended.map(\.reason), ["expired"])
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    // MARK: K7

    func testK7_neverLoggedInEmitsOneSessionFatal() async {
        let h = setupAccount()
        let w = Watch(h)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(w.fatal, [.session(SessionEnd(action: .login))])
        XCTAssertEqual(h.im.state, .disconnected)
        XCTAssertEqual(h.transport.connections.count, 0)
        h.clock.advance(5 * MIN)
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        XCTAssertEqual(h.transport.connections.count, 0)
    }

    func testK7_fatalCarriesTheEarlierEnd() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 5 * HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respondError(401, 4019, reason: "replayDetected")
        await settle()
        XCTAssertEqual(w.ended.count, 1)
        XCTAssertEqual(w.fatal, [])
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(
            w.fatal, [.session(SessionEnd(action: .login, dialog: .credentialAnomaly, reason: "replayDetected", code: 4019))])
        XCTAssertEqual(h.im.state, .disconnected)
    }

    func testK7_afterAKickTheFatalHasNoOrigin() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        c.receive(event("kicked", ["reason": "passwordChanged"]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(w.fatal.count, 2)
        XCTAssertEqual(
            w.fatal.last, .session(SessionEnd(action: .login, dialog: .accountOffline, reason: "passwordChanged", code: 4012)))
    }

    func testK7_afterLogoutTheActionIsLogout() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let out = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        _ = await out.value
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(w.fatal, [.session(SessionEnd(action: .logout))])
    }

    func testK7_endingWhileWaitingForTheTokenFatalsOnce() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, -HOUR)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        h.http.last(REFRESH).respondError(401, 4019, reason: "revoked")
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        XCTAssertEqual(h.im.state, .disconnected)
    }

    func testK7_loggingInAfterTheFatalConnects() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        let login = Task { try await h.account.login(username: USER, password: "Password-1") }
        await settle()
        h.http.last("/v1/account/login").respond(200, authBody(gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await login.value
        h.im.connect(tokenProvider: h.account.tokenProvider)
        let c = await h.authNew()
        XCTAssertEqual(authToken(c), jwt("sid1", 1))
        XCTAssertEqual(h.im.state, .connected)
        XCTAssertEqual(w.fatal.count, 1)
    }

    // MARK: The ack and a new generation crossing: an ack only counts for the unacknowledged one (F-ACC-05 rule 1, RS5-13)

    private let ackPath = "/v1/account/recovery-code/ack"
    private let regenPath = "/v1/account/recovery-code"
    private let regenBody: JSONValue = ["recoveryCode": "CODE-3", "recoveryCodeGen": 3]

    private func withCode(_ h: AccountHarness, _ sid: String, _ code: Int64) -> JSONValue {
        authBody(sid: sid, gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "CODE-\(code)", recoveryCodeGen: code)
    }

    /// A password change got generation 2, not acknowledged. The `sid` is sid2.
    private func unackedGen2(_ h: AccountHarness) async throws {
        h.session(1, DAY)
        let change = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respond(200, withCode(h, "sid2", 2))
        _ = try await change.value
        XCTAssertNil(h.store.saved)
    }

    /// Still memory only: a refresh is not saved.
    private func stillMemoryOnly(_ h: AccountHarness, sid: String, file: StaticString = #filePath, line: UInt = #line) async {
        let next = h.account.localGen + 1
        h.clock.advance(18 * HOUR + 1)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(sid: sid, gen: next, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.session?.accessToken, jwt(sid, next), file: file, line: line)
        XCTAssertNil(h.store.saved, file: file, line: line)
    }

    private func ack(_ h: AccountHarness, _ gen: Int64) async throws {
        let p = Task { try await h.account.ackRecoveryCode(gen: gen) }
        await settle()
        h.http.last(ackPath).respond(200, [:])
        try await p.value
        await settle()
    }

    func testAck_staleResponseAfterPasswordChangeDoesNotSaveTheNewToken() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        let stale = Task { try await h.account.ackRecoveryCode(gen: 2) }
        await settle()
        let staleCall = h.http.last(ackPath)
        let change = Task { try await h.account.changePassword(oldPassword: "Password-2", newPassword: "Password-3") }
        await settle()
        h.http.last(PASSWORD).respond(200, withCode(h, "sid3", 3))
        _ = try await change.value
        staleCall.respond(200, [:])
        try await stale.value
        await settle()
        XCTAssertNil(h.store.saved)
        await stillMemoryOnly(h, sid: "sid3")
        try await ack(h, 3)
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid3", 2))
    }

    func testAck_staleResponseAfterRegenerateDoesNotSave() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        let stale = Task { try await h.account.ackRecoveryCode(gen: 2) }
        await settle()
        let staleCall = h.http.last(ackPath)
        let regen = Task { try await h.account.regenerateRecoveryCode(password: "Password-2") }
        await settle()
        h.http.last(regenPath).respond(200, regenBody)
        _ = try await regen.value
        staleCall.respond(200, [:])
        try await stale.value
        await settle()
        XCTAssertNil(h.store.saved)
        await stillMemoryOnly(h, sid: "sid2")
        try await ack(h, 3)
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid2", 2))
    }

    func testAck_staleResponseAfterRecoverDoesNotSave() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        let stale = Task { try await h.account.ackRecoveryCode(gen: 2) }
        await settle()
        let staleCall = h.http.last(ackPath)
        let recover = Task { try await h.account.recover(username: USER, recoveryCode: "CODE-2", newPassword: "Password-3") }
        await settle()
        h.http.last("/v1/account/recover").respond(200, withCode(h, "sid3", 3))
        _ = try await recover.value
        staleCall.respond(200, [:])
        try await stale.value
        await settle()
        XCTAssertNil(h.store.saved)
        await stillMemoryOnly(h, sid: "sid3")
        try await ack(h, 3)
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid3", 2))
    }

    func testAck_newGenerationDuringTheSaveKeepsTheFlagAndClears() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        h.store.holdSaves = true
        let stale = Task { try await h.account.ackRecoveryCode(gen: 2) }
        await settle()
        h.http.last(ackPath).respond(200, [:])
        await settle()
        let change = Task { try await h.account.changePassword(oldPassword: "Password-2", newPassword: "Password-3") }
        await settle()
        h.http.last(PASSWORD).respond(200, withCode(h, "sid3", 3))
        await settle()
        h.store.releaseSaves()
        try await stale.value
        _ = try await change.value
        await settle()
        XCTAssertEqual(h.account.session?.accessToken, jwt("sid3", 1))
        XCTAssertNil(h.store.saved)
        await stillMemoryOnly(h, sid: "sid3")
    }

    func testAck_lateRegenerateResponseDoesNotMoveTheGenerationBack() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        let regen = Task { try await h.account.regenerateRecoveryCode(password: "Password-2") }
        await settle()
        let regenCall = h.http.last(regenPath)
        let change = Task { try await h.account.changePassword(oldPassword: "Password-2", newPassword: "Password-3") }
        await settle()
        h.http.last(PASSWORD).respond(200, withCode(h, "sid3", 4))
        _ = try await change.value
        regenCall.respond(200, regenBody)
        _ = try await regen.value
        try await ack(h, 4)
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid3", 1))
    }

    func testAck_logoutOthersKeepsTheGeneration() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        let others = Task { try await h.account.logoutOthers(password: "Password-2") }
        await settle()
        h.http.last("/v1/account/logout-others").respond(200, authBody(sid: "sid3", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await others.value
        XCTAssertNil(h.store.saved)
        try await ack(h, 2)
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid3", 1))
    }

    func testAck_afterAckRefreshSavesAndRegenerateDoesNotGoBackToMemoryOnly() async throws {
        let h = setupAccount()
        try await unackedGen2(h)
        try await ack(h, 2)
        let regen = Task { try await h.account.regenerateRecoveryCode(password: "Password-2") }
        await settle()
        h.http.last(regenPath).respond(200, regenBody)
        _ = try await regen.value
        try await ack(h, 3)
        h.clock.advance(18 * HOUR + 1)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(sid: "sid2", gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid2", 2))
    }

    // MARK: K5. Connection and AccountClient share the main actor, so sdk-kotlin's race does not exist here. These pin why.

    func testK5_responseFirstThenKickNeverReachesTheAccount() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY, sid: "sid-old")
        let c1 = await h.online()
        let change = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respond(200, authBody(sid: "sid-new", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await change.value
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        c1.receive(event("kicked", ["reason": "passwordChanged"]))
        c1.drop(4012)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid-new", 1))
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
        XCTAssertNotNil(h.account.session)
    }

    /// sdk-ts has a one-microtask window here. On the main actor a dial reads the token and opens the socket with no
    /// suspension between them, so whichever step comes first, the old token never outlives the change. Tries each offset.
    func testK5_dialAroundTheSidChangeNeverEndsTheSession() async throws {
        for offset in 0..<16 {
            let h = setupAccount()
            let w = Watch(h)
            h.session(1, DAY, sid: "sid-old")
            let change = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
            await settle()
            h.store.holdSaves = true
            h.http.last(PASSWORD).respond(200, authBody(sid: "sid-new", gen: 1, accessExpiresAt: h.clock.now() + DAY))
            await settle()
            h.store.releaseSaves()
            for _ in 0..<offset { await Task.yield() }
            h.im.connect(tokenProvider: h.account.tokenProvider)
            _ = try await change.value
            await settle()
            let c = h.transport.current
            c.open()
            await settle()
            if authToken(c) == jwt("sid-old", 1), c.closedWith == nil {
                XCTFail("offset \(offset): a live connection kept the old sid")
            }
            if c.closedWith != nil {
                h.transport.current.open()
                await settle()
            }
            XCTAssertEqual(authToken(h.transport.current), jwt("sid-new", 1), "offset \(offset)")
            XCTAssertEqual(w.fatal, [], "offset \(offset)")
            XCTAssertEqual(w.ended, [], "offset \(offset)")
        }
    }

    func testK5_kickOfTheCurrentSidStillApplies() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY, sid: "sid-now")
        let c = await h.online()
        c.receive(event("kicked", ["reason": "passwordChanged"]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.ended.count, 1)
        XCTAssertNil(h.account.session)
    }
}
