import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-612: session semantics (PRD-chat F-ACC-03 rules 5-7, F-ACC-04 rule 3, F-ACC-05 rule 1), translated from sdk-ts
// test/account-session.test.ts. Fake HTTP + FakeTransport + fake clock; test names carry the TC-ACC number. Local results:
// `swift test` on macOS. Pages and dialogs belong to FE-617, FE-618.

private let kickedExpired = event("kicked", ["reason": "tokenExpired"])

/// TC-ACC-03-10: refreshing under 6 hours while connected.
@MainActor
final class AccountRefreshTests: AccountTestCase {
    func testTC_ACC_03_10_refreshesOnceAndReconnectsWith1000WithoutABanner() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 6 * HOUR + MIN)
        let c1 = await h.online()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.clock.advance(MIN + 1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.http.last(REFRESH).json["refreshToken"]?.stringValue, refreshToken("sid1", 1))
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(c1.closedWith?.code, 1000)
        XCTAssertEqual(c1.closedWith?.reason, "token rotated")
        XCTAssertEqual(h.transport.connections.count, 2)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid1", 2))
        XCTAssertEqual(h.im.state, .connected)
        h.clock.advance(MIN - 1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(w.shownBanners, [])
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
        guard case .ok? = try? h.im.send("c2c:alice_1:bobby", "hi") else { return XCTFail("send") }
        XCTAssertEqual(c2.last("send")?.data?["to"], "bobby")
    }

    func testTC_ACC_03_10_exactlySixHoursLeftDoesNotRefresh() async {
        let h = setupAccount()
        h.session(1, 6 * HOUR + MIN)
        await h.online()
        h.clock.advance(MIN)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    // Rule 5's foreground entry through IMClient: the same call systemEvents makes.
    func testVisibilityChangedReachesTheTokenProvider() async {
        let h = setupAccount()
        h.session(1, 6 * HOUR + MIN)
        await h.online()
        h.clock.advance(MIN - 1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.base.visible = false
        h.account.restore(h.makeSession(1, HOUR))
        h.im.visibilityChanged()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.base.visible = true
        h.im.visibilityChanged()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    func testTC_ACC_03_10_exactlySixHoursLeftDoesNotRefreshOnForeground() async {
        let h = setupAccount()
        h.session(1, 6 * HOUR)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
    }

    // Rule 5: waiting on backoff, a new token dials at once.
    func testNewTokenDialsAtOnceWhileWaitingOnBackoff() async {
        let h = setupAccount()
        h.session(1, 6 * HOUR + MIN)
        let c1 = await h.online()
        h.clock.advance(MIN + 1)
        await settle()
        let refresh = h.http.last(REFRESH)
        c1.drop(1006)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 1)
        refresh.respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        h.transport.current.open()
        XCTAssertEqual(authToken(h.transport.current), jwt("sid1", 2))
    }

    func testNoTimerWithoutAConnectionForegroundChecks() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.clock.advance(DAY / 2)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    // AC-ACC-03-7 at the SDK level: before any auth frame there is a refresh; no login page.
    func testTC_ACC_03_07_expiredOnColdStartRefreshesBeforeAuth() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.store.saved = h.makeSession(1, -HOUR)
        let restored = try await h.account.start()
        XCTAssertEqual(restored?.userId, USER)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 0)
        XCTAssertEqual(h.im.state, .connecting)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        let c = await h.authNew()
        XCTAssertEqual(authToken(c), jwt("sid1", 2))
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
    }

    // AC-ACC-03-11 at the SDK level: offline with an expired token stays connecting, shows the banner, keeps the session;
    // when the network is back the due retry refreshes and connects. The cached list and the page are FE-617's.
    func testTC_ACC_03_11_offlineColdStartKeepsSessionThenConnects() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.store.saved = h.makeSession(1, -HOUR)
        try await h.account.start()
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        h.http.last(REFRESH).fail()
        await settle()
        h.clock.advance(1_000)  // The banner delay and the first backoff.
        await settle()
        XCTAssertEqual(w.banner, [true])
        XCTAssertNotNil(h.account.session)
        XCTAssertNotNil(h.store.saved)
        XCTAssertEqual(w.ended, [])
        XCTAssertEqual(h.transport.connections.count, 0)
        h.http.last(REFRESH).fail()
        await settle()
        h.clock.advance(2_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 3)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        let c = await h.authNew()
        XCTAssertEqual(authToken(c), jwt("sid1", 2))
        XCTAssertEqual(w.banner, [true, false])
        XCTAssertEqual(w.fatal, [])
    }

    // AC-ACC-03-13: killed after the new token is saved and before use: the next launch uses it and is not revoked.
    func testTC_ACC_03_13_killedAfterSaveRestartsWithTheNewToken() async throws {
        let h = setupAccount()
        let srv = FakeAccountSession()
        h.session(1, HOUR)
        h.store.holdSaves = true
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: srv.refresh(1).newGen!, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 1)  // Not used yet.
        h.store.releaseSaves()
        await settle()
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid1", 2))
        // The restart: a new client over the same store.
        let next = h.newClient()
        let restored = try await next.start()
        XCTAssertEqual(restored?.accessToken, jwt("sid1", 2))
        XCTAssertEqual(srv.access(next.localGen), "promoted")
        XCTAssertFalse(srv.revoked)
    }

    // AC-ACC-03-20: killed after sending and before the response: 5 minutes later the old value still works.
    func testTC_ACC_03_20_killedAfterSendRetriesTheOldValue() async throws {
        let h = setupAccount()
        let w = Watch(h)
        let srv = FakeAccountSession()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        _ = srv.refresh(1)  // The server issued; the response never arrives.
        // The restart, 5 minutes later. Its own clock: the killed process's timers do not run.
        let next = h.newClient(clock: FakeClock(start: h.clock.now() + 5 * MIN))
        try await next.start()
        await settle()
        let retry = h.http.calls.last { $0.path == REFRESH }!
        XCTAssertEqual(retry.json["refreshToken"]?.stringValue, refreshToken("sid1", 1))
        let r = srv.refresh(1)
        XCTAssertEqual(r.result, "issued")
        retry.respond(200, authBody(gen: r.newGen!, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(next.localGen, r.newGen)
        XCTAssertEqual(w.ended, [])
        XCTAssertFalse(srv.revoked)
    }

    // AC-ACC-03-18: `{userId, token}` left by an older version is a demo session, connects, and never refreshes.
    func testTC_ACC_03_18_oldSessionShapeIsDemo() async throws {
        let h = setupAccount()
        let w = Watch(h)
        let old = try JSONDecoder().decode(AccountSession.self, from: Data(#"{"userId":"alice_1","token":"old-demo-token"}"#.utf8))
        XCTAssertEqual(old.mode, .demo)
        XCTAssertEqual(old.accessToken, "old-demo-token")
        XCTAssertNil(old.refreshToken)
        let noMode = try JSONDecoder().decode(
            AccountSession.self, from: Data(#"{"userId":"alice_1","accessToken":"t","accessExpiresAt":1}"#.utf8))
        XCTAssertEqual(noMode.mode, .demo)
        let unknownMode = try JSONDecoder().decode(
            AccountSession.self, from: Data(#"{"mode":"future","userId":"alice_1","accessToken":"t"}"#.utf8))
        XCTAssertEqual(unknownMode.mode, .demo)
        XCTAssertEqual(AccountSession(userId: "a", accessToken: "t", accessExpiresAt: 0).mode, .demo)

        h.store.saved = old
        try await h.account.start()
        XCTAssertEqual(h.account.session?.mode, .demo)
        h.clock.advance(DAY)
        h.account.foreground()
        let c = await h.online()
        XCTAssertEqual(authToken(c), "old-demo-token")
        XCTAssertEqual(h.http.calls.count, 0)
        XCTAssertEqual(h.store.saves.count, 0)
        // Its token expires: back to login, no refresh (R-CF-11).
        c.receive(kickedExpired)
        c.drop(4011)
        await settle()
        XCTAssertEqual(w.ended.first?.dialog, .sessionExpired)
        XCTAssertEqual(h.http.calls.count, 0)
    }

    func testSessionRoundTripsThroughCodable() throws {
        let h = setupAccount()
        let s = h.makeSession(3, DAY)
        let back = try JSONDecoder().decode(AccountSession.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.mode, .account)
    }
}

/// R-CF-09: the store contract, new tokens are saved before use.
@MainActor
final class AccountStoreContractTests: AccountTestCase {
    func testTC_ACC_03_13_newTokenIsUsedOnlyAfterSaveReturned() async {
        let h = setupAccount()
        var tokensEvents = 0
        var savedWhenAdopted = false
        h.account.on { e in
            if case .tokens = e {
                tokensEvents += 1
                savedWhenAdopted = h.store.saved?.accessToken == h.account.session?.accessToken
            }
        }
        h.session(1, HOUR)
        let c1 = await h.online()
        await settle()
        h.store.holdSaves = true
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        // The save is still open: nothing uses the new token.
        XCTAssertEqual(h.store.calls.last, "save")
        XCTAssertEqual(h.account.localGen, 1)
        XCTAssertEqual(h.account.session?.accessToken, jwt("sid1", 1))
        XCTAssertEqual(tokensEvents, 0)
        XCTAssertNil(c1.closedWith)
        XCTAssertEqual(h.transport.connections.count, 1)
        h.store.releaseSaves()
        await settle()
        XCTAssertEqual(h.account.localGen, 2)
        XCTAssertEqual(tokensEvents, 1)
        XCTAssertTrue(savedWhenAdopted)
        XCTAssertEqual(c1.closedWith?.code, 1000)
    }

    func testSaveFailureKeepsTheOldTokenAndBacksOff() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.store.failSave = true
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 1)
        h.store.failSave = false
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        XCTAssertEqual(h.http.last(REFRESH).json["refreshToken"]?.stringValue, refreshToken("sid1", 1))
    }

    // The sequence check again after saving: a timeout during the save abandons that response.
    func testAttemptAbandonedDuringTheSaveIsNotAdopted() async {
        let h = setupAccount()
        var tokens = 0
        h.account.on { if case .tokens = $0 { tokens += 1 } }
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.store.holdSaves = true
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        h.clock.advance(30_000)
        h.store.releaseSaves()
        await settle()
        XCTAssertEqual(h.account.localGen, 1)
        XCTAssertEqual(tokens, 0)
    }

    // A clear cannot be overtaken by an earlier save still in progress: nothing stays on disk after logging out.
    func testStoreCallsStayInOrderLogoutDuringSaveLeavesNothing() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.store.holdSaves = true
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        let out = Task { await h.account.logout() }
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 0)  // Its pending record queues behind the open save.
        h.store.releaseSaves()
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        _ = await out.value
        await settle()
        XCTAssertEqual(h.store.calls.last, "clear")
        XCTAssertNil(h.store.saved)
        XCTAssertNil(h.account.session)
    }

    // The session ending while a response is being saved does not bring it back.
    func testSessionEndingDuringApplyAuthSaveIsNotRevived() async {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        let change = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        h.store.holdSaves = true
        h.http.last("/v1/account/logout-others").respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        c.receive(event("kicked", ["reason": "banned"]))
        c.drop(4012)
        await settle()
        XCTAssertNil(h.account.session)
        h.store.releaseSaves()
        let e = await errorOf(change)
        XCTAssertTrue(e is SessionEndedError, "\(String(describing: e))")
        await settle()
        XCTAssertNil(h.account.session)
        XCTAssertNil(h.store.saved)
    }
}

/// TC-ACC-03-12, rule 7.
@MainActor
final class AccountFailureTests: AccountTestCase {
    func testTC_ACC_03_12_503BacksOffStaysAndRecovers() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        await h.online()
        await settle()
        h.http.last(REFRESH).respondError(503, 5030)
        await settle()
        XCTAssertEqual(w.ended, [])
        XCTAssertEqual(h.im.state, .connected)
        h.clock.advance(999)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        h.http.last(REFRESH).respondError(503, 5030)
        await settle()
        h.clock.advance(1_999)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 3)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await h.authNew()
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
    }

    func testTC_ACC_03_12_proxyPageWithoutCodeBacksOff() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(403, text: "<html>captive portal</html>")
        await settle()
        XCTAssertEqual(w.ended, [])
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testHttp200WithMissingFieldsBacksOff() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, ["userId": .string(USER)])
        await settle()
        XCTAssertEqual(w.ended, [])
        XCTAssertEqual(h.account.localGen, 1)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testUnknownErrorCodeWithACodeGoesToLogin() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respondError(400, 4999)
        await settle()
        XCTAssertEqual(w.ended.first?.dialog, .sessionExpired)
    }

    func testBan4034GivesBanNotice() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respondError(403, 4034)
        await settle()
        XCTAssertEqual(w.ended, [SessionEnd(action: .banNotice, code: 4034)])
    }

    func testTC_ACC_03_12_kickedTokenExpiredRefreshesAndReconnects() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c1 = await h.online()
        c1.receive(kickedExpired)
        c1.drop(4011, "tokenExpired")
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)  // Whatever the time left.
        XCTAssertEqual(h.transport.connections.count, 1)  // The old token does not reconnect before the response.
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid1", 2))
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
    }

    func testCloseCode4011WithoutAFrameFollowsRule7() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c1 = await h.online()
        c1.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(w.fatal, [])
    }

    func testMustRefreshSurvivesBackoffWithPlentyOfTimeLeft() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c1 = await h.online()
        c1.drop(4011)
        await settle()
        h.http.last(REFRESH).fail()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)  // The retry happens though 24 hours are left.
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertEqual(w.ended, [])
    }

    func testRule7LocalNewerGenerationReconnectsWithoutRefresh() async {
        let h = setupAccount()
        h.session(5, DAY)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        let c1 = h.transport.current
        c1.open()
        // Dialed, then the local token moved on (another request refreshed) while the connection has not changed yet.
        var moved = h.account.session!
        moved.accessToken = jwt("sid1", 6)
        moved.refreshToken = refreshToken("sid1", 6)
        h.account.restore(moved)
        c1.receive(kickedExpired)
        c1.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        XCTAssertEqual(h.transport.connections.count, 2)
        h.transport.current.open()
        XCTAssertEqual(authToken(h.transport.current), jwt("sid1", 6))
    }

    func testRule7NewSidCountsAsNewerThoughItsGenIsSmaller() async {
        let h = setupAccount()
        h.session(9, DAY, sid: "sid-old")
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        let c1 = h.transport.current
        c1.open()
        var moved = h.account.session!
        moved.accessToken = jwt("sid-new", 1)
        moved.refreshToken = refreshToken("sid-new", 1)
        h.account.restore(moved)
        c1.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        XCTAssertEqual(h.transport.connections.count, 2)
    }

    func testRule7SameSidSameGenRefreshes() {
        XCTAssertFalse(isLocalNewer(TokenLineage(sid: "s", gen: 3), than: RejectedToken(sid: "s", gen: 3)))
        XCTAssertFalse(isLocalNewer(TokenLineage(sid: "s", gen: 3), than: RejectedToken(sid: "s", gen: 4)))
        XCTAssertTrue(isLocalNewer(TokenLineage(sid: "s", gen: 4), than: RejectedToken(sid: "s", gen: 3)))
        XCTAssertTrue(isLocalNewer(TokenLineage(sid: "new", gen: 1), than: RejectedToken(sid: "old", gen: 9)))
        XCTAssertEqual(lineageOf("garbage"), TokenLineage(sid: "", gen: 0))
        XCTAssertEqual(lineageOf("a.!!!.c"), TokenLineage(sid: "", gen: 0))
        XCTAssertEqual(lineageOf(jwt("sid-x", 12)), TokenLineage(sid: "sid-x", gen: 12))
    }

    func testRepeated4011FirstAtOnceThenBackoff() async {
        let h = setupAccount()
        h.session(1, DAY)
        h.http.onRequest = { call in
            let gen = Int64(call.json["refreshToken"]!.stringValue!.split(separator: ".")[2])!
            call.respond(200, authBody(gen: gen + 1, accessExpiresAt: h.clock.now() + DAY))
        }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        h.transport.current.open()
        h.transport.current.drop(4011)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)  // The first at once.
        h.transport.current.open()
        h.transport.current.drop(4011)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)  // The second waits.
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 3)
    }

    func testDemoConnectTokenOn4011StopsWithoutHttp() async {
        let h = setupAccount()
        let w = Watch(h)
        h.im.connect(token: "demo-token")
        let c = await h.base.login("demo")
        c.receive(kickedExpired)
        c.drop(4011, "tokenExpired")
        await settle()
        XCTAssertEqual(w.fatal, [.kicked(reason: "tokenExpired", code: 4011, until: nil)])
        XCTAssertEqual(h.http.calls.count, 0)
        h.clock.advance(60_000)
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testUnknownKickReasonInAccountMode() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c1 = await h.online()
        c1.receive(event("kicked", ["reason": "futureReason"]))
        c1.drop(1006)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertEqual(w.fatal, [])
        let c2 = await h.authNew()
        c2.receive(event("kicked", ["reason": "futureReason"]))
        c2.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal, [.kicked(reason: "futureReason", code: 4012, until: nil)])
        XCTAssertEqual(w.ended.first?.action, .login)
        XCTAssertEqual(w.ended.first?.dialog, .accountOffline)
        XCTAssertEqual(w.ended.first?.origin, .kick)
        XCTAssertNil(h.account.session)
    }

    func testServerShutdownReconnectsInAccountMode() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c1 = await h.online()
        c1.receive(event("kicked", ["reason": "serverShutdown"]))
        c1.drop(1001)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertEqual(w.fatal, [])
        XCTAssertNotNil(h.account.session)
    }
}

/// TC-ACC-03-23, single flight.
@MainActor
final class AccountSingleFlightTests: AccountTestCase {
    func testTC_ACC_03_23_fourEntriesMergeTimeoutRetryLateResponseDropped() async throws {
        let h = setupAccount()
        h.session(1, 5 * HOUR)
        try await h.account.start()
        h.account.foreground()
        h.account.trigger(.timer)
        let c1 = await h.online()
        c1.receive(kickedExpired)
        c1.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertTrue(h.account.refreshInflight)

        h.clock.advance(30_000)
        XCTAssertFalse(h.account.refreshInflight)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1_000)  // Backoff of 1 second.
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        let first = h.http.to(REFRESH)[0]
        let second = h.http.to(REFRESH)[1]

        second.respond(200, authBody(gen: 3, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.store.saved?.refreshToken, refreshToken("sid1", 3))
        let saves = h.store.saves.count

        first.respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 3)
        XCTAssertEqual(h.account.session?.refreshToken, refreshToken("sid1", 3))
        XCTAssertEqual(h.store.saved?.refreshToken, refreshToken("sid1", 3))
        XCTAssertEqual(h.store.saves.count, saves)
        XCTAssertLessThanOrEqual(h.maxPending, 2)  // The first was abandoned before the second; its answer may still come.
    }

    func testConcurrentEntriesSendOneRequest() async {
        let h = setupAccount()
        h.session(1, HOUR)
        for _ in 0..<5 {
            h.account.foreground()
            h.account.trigger(.start)
            h.account.trigger(.timer)
            h.account.trigger(.kicked, rejected: RejectedToken(sid: "sid1", gen: 1))
            h.account.http4011(RejectedToken(sid: "sid1", gen: 1))
        }
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.maxPending, 1)
    }

    func testLate4019DoesNotEndTheSession() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.clock.advance(30_000)
        await settle()
        h.clock.advance(1_000)
        await settle()
        let first = h.http.to(REFRESH)[0]
        let second = h.http.to(REFRESH)[1]
        first.respondError(401, 4019, reason: "revoked")
        await settle()
        XCTAssertEqual(w.ended, [])
        XCTAssertTrue(h.account.refreshInflight)
        second.respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 2)
    }

    func testForegroundDuringBackoffDoesNotSendEarly() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).fail()
        await settle()
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }
}

/// TC-ACC-03-26, 03-34, 03-39, 03-41: rules 6 and 6a.
@MainActor
final class AccountDialogTests: AccountTestCase {
    private let before: Int64 = 1_800_518_400_000

    func testTC_ACC_03_26_replayDetectedDialogClearsAndStops() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        let c = await h.online()
        await settle()
        h.http.last(REFRESH).respondError(401, 4019, reason: "replayDetected")
        await settle()
        let end = SessionEnd(action: .login, dialog: .credentialAnomaly, reason: "replayDetected", code: 4019)
        XCTAssertEqual(w.ended, [end])
        XCTAssertEqual(w.ended[0].dialogText(), "检测到登录凭证异常，这台设备已下线。如果不是你本人操作，请尽快改密码")
        XCTAssertEqual(w.fatal, [.session(end)])
        XCTAssertNil(h.account.session)
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(c.closedWith?.code, 1000)
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testTC_ACC_03_34_kickWithDateNoReconnect() async {
        for reason in ["passwordChanged", "sessionRevoked", "accountDeleted"] {
            let h = setupAccount()
            let w = Watch(h)
            h.session(1, DAY)
            let c = await h.online()
            c.receive(event("kicked", ["reason": .string(reason), "recoverBefore": .int(before)]))
            c.drop(4012, reason)
            await settle()
            XCTAssertEqual(w.fatal, [.kicked(reason: reason, code: 4012, until: nil, recoverBefore: before)])
            XCTAssertEqual(w.ended.first?.dialog, .recoverBefore)
            XCTAssertEqual(w.ended.first?.recoverBefore, before)
            XCTAssertEqual(
                w.ended[0].dialogText(formatDate: { _ in "11月13日" }),
                "你的账号凭证有变化。如果不是你本人操作，请在 11月13日 前用恢复码找回")
            h.clock.advance(60_000)
            await settle()
            XCTAssertEqual(h.transport.connections.count, 1)
            XCTAssertNil(h.account.session)
        }
    }

    // TC-ACC-04-15, AC-ACC-04-16: `recoverBefore` lives in `details`.
    func testTC_ACC_03_34_expiredCredentialsChangedShowsDateNotAnomaly() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, -HOUR)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        h.http.last(REFRESH).respondError(401, 4019, reason: "credentialsChanged", details: ["recoverBefore": .int(before)])
        await settle()
        XCTAssertEqual(w.ended.first?.action, .login)
        XCTAssertEqual(w.ended.first?.dialog, .recoverBefore)
        XCTAssertEqual(w.ended.first?.recoverBefore, before)
        guard case .session(let e)? = w.fatal.first else { return XCTFail("fatal") }
        XCTAssertEqual(e.dialog, .recoverBefore)
        XCTAssertEqual(h.transport.connections.count, 0)
    }

    func testKickWithoutDateUsesTheReasonCopy() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        c.receive(event("kicked", ["reason": "passwordChanged"]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.ended[0].dialogText(), "账号已被下线")
    }

    func testTooManyConnectionsDoesNotEndTheAccountSession() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        c.receive(event("kicked", ["reason": "tooManyConnections"]))
        c.drop(4429)
        await settle()
        guard case .kicked("tooManyConnections", _, _, _)? = w.fatal.first else { return XCTFail("fatal") }
        XCTAssertNotNil(h.account.session)
    }

    func testTC_ACC_03_39_4290BacksOffStays() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respondError(429, 4290)
        await settle()
        XCTAssertEqual(w.ended, [])
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    private func superseded(_ h: AccountHarness, _ seconds: Int64 = 120) {
        h.http.last(REFRESH).respondError(401, 4019, reason: "superseded", details: ["retryAfterSeconds": .int(seconds)])
    }

    func testTC_ACC_03_41_supersededRetriesOnTimeThenLogin() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        superseded(h)
        await settle()
        XCTAssertEqual(w.ended, [])
        h.clock.advance(119_999)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        superseded(h)
        await settle()
        XCTAssertEqual(w.ended, [])
        h.clock.advance(120_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 3)
        superseded(h)
        await settle()
        XCTAssertEqual(w.ended.first?.dialog, .supersededExceeded)
        h.clock.advance(600_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 3)
    }

    func testSupersededOddRetryAfterIsCapped() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        superseded(h, 99_999_999)
        await settle()
        h.clock.advance(599_999)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testTC_ACC_03_41_supersededRereadsTheStore() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        superseded(h)
        await settle()
        // A newer value another process or a crashed run stored.
        var newer = h.store.saved!
        newer.accessToken = jwt("sid1", 7)
        newer.refreshToken = refreshToken("sid1", 7)
        h.store.saved = newer
        h.clock.advance(120_000)
        await settle()
        XCTAssertEqual(h.http.last(REFRESH).json["refreshToken"]?.stringValue, refreshToken("sid1", 7))
    }

    func testTC_ACC_03_41_foregroundAndKickDoNotSendEarlyDuringRetryAfter() async {
        let h = setupAccount()
        h.session(1, HOUR)
        let c = await h.online()
        await settle()
        superseded(h)
        await settle()
        h.account.foreground()
        c.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    func testTC_ACC_03_41_successResetsTheCount() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        superseded(h, 1)
        await settle()
        h.clock.advance(1_000)
        await settle()
        superseded(h, 1)
        await settle()
        h.clock.advance(1_000)
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        h.clock.advance(19 * HOUR)
        h.account.foreground()
        await settle()
        for _ in 0..<2 {
            superseded(h, 1)
            await settle()
            h.clock.advance(1_000)
            await settle()
        }
        XCTAssertEqual(w.ended, [])
        superseded(h, 1)
        await settle()
        XCTAssertEqual(w.ended.count, 1)
    }
}

/// TC-ACC-03-44, 03-45.
@MainActor
final class AccountHttp4011Tests: AccountTestCase {
    func testTC_ACC_03_44_threeRequestsRetryWithTheLocalToken() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let results = (0..<3).map { _ in Task { try await h.account.listEvents() } }
        await settle()
        let inflight = h.http.pending
        XCTAssertEqual(inflight.count, 3)
        var moved = h.account.session!
        moved.accessToken = jwt("sid1", 2)
        moved.refreshToken = refreshToken("sid1", 2)
        h.account.restore(moved)
        for c in inflight { c.respondError(401, 4011, reason: "tokenSuperseded") }
        await settle()
        let retries = h.http.pending
        XCTAssertEqual(retries.count, 3)
        for c in retries {
            XCTAssertEqual(c.bearer, jwt("sid1", 2))
            c.respond(200, ["events": [], "otherSessions": ["count": 0]])
        }
        for r in results { _ = try await r.value }
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
    }

    func testTC_ACC_03_44_threeRejectionsMergeIntoOneRefresh() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let results = (0..<3).map { _ in Task { try await h.account.listEvents() } }
        await settle()
        for c in h.http.pending { c.respondError(401, 4011) }
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        for c in h.http.pending {
            XCTAssertEqual(c.bearer, jwt("sid1", 2))
            c.respond(200, ["events": [], "otherSessions": ["count": 0]])
        }
        for r in results { _ = try await r.value }
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    func testTC_ACC_03_44_persistent4011IsCappedAndGoesToTheCaller() async {
        let h = setupAccount()
        h.session(5, DAY)
        h.http.onRequest = { call in
            if call.path == REFRESH {
                let gen = Int64(call.json["refreshToken"]!.stringValue!.split(separator: ".")[2])!
                call.respond(200, authBody(gen: gen + 1, accessExpiresAt: h.clock.now() + DAY))
            } else {
                call.respondError(401, 4011)
            }
        }
        let p = Task { try await h.account.listEvents() }
        let e = await errorOf(p)
        XCTAssertEqual((e as? AccountError)?.code, 4011)
        XCTAssertEqual(h.http.to("/v1/account/events").count, 3)
    }

    func testHttpAndWsShareTheTokenSource() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let c1 = await h.online()
        let p = Task { try await h.account.listEvents() }
        await settle()
        h.http.last("/v1/account/events").respondError(401, 4011)
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(c1.closedWith?.code, 1000)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid1", 2))
        h.http.last("/v1/account/events").respond(200, ["events": [], "otherSessions": ["count": 1]])
        let r = try await p.value
        XCTAssertEqual(r.otherSessions.count, 1)
    }

    func testRefreshStalledHttp4011TimesOutForTheCaller() async {
        let h = setupAccount()
        h.session(1, DAY)
        let p = Task { try await h.account.listEvents() }
        await settle()
        h.http.last("/v1/account/events").respondError(401, 4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.clock.advance(30_000)
        let e = await errorOf(p)
        XCTAssertNotNil(e as? AccountNetworkError)
        await settle()
        h.clock.advance(1_000)  // The background keeps trying.
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testHttp4012EndsTheSession() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let p = Task { try await h.account.listEvents() }
        await settle()
        h.http.last("/v1/account/events").respondError(401, 4012)
        let e = await errorOf(p)
        XCTAssertNotNil(e as? AccountError)
        XCTAssertEqual(w.ended.first?.action, .login)
        XCTAssertEqual(w.ended.first?.dialog, .sessionExpired)
        XCTAssertEqual(w.ended.first?.code, 4012)
    }

    private func capped(_ h: AccountHarness) async {
        h.session(1, 7 * HOUR)
        h.account.foreground()
        await settle()
        h.clock.advance(2 * HOUR)  // 5 hours left.
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        let at = h.clock.now() + 5 * HOUR
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: at, absoluteExpiresAt: at))
        await settle()
    }

    func testTC_ACC_03_45_atAbsoluteLimitNoMoreRefreshEndsAtExpiry() async {
        let h = setupAccount()
        let w = Watch(h)
        await capped(h)
        let c = await h.online()
        h.clock.advance(HOUR)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 1)
        XCTAssertNil(c.closedWith)
        XCTAssertEqual(w.ended, [])
        h.clock.advance(4 * HOUR)
        await settle()
        XCTAssertEqual(w.ended.first?.action, .login)
        XCTAssertEqual(w.ended.first?.dialog, .sessionExpired)
        guard case .session(let e)? = w.fatal.first else { return XCTFail("fatal") }
        XCTAssertEqual(e.dialog, .sessionExpired)
        XCTAssertNil(h.account.session)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    func testTC_ACC_03_45_withoutAConnectionForegroundEnds() async {
        let h = setupAccount()
        let w = Watch(h)
        await capped(h)
        h.clock.advance(6 * HOUR)
        h.account.foreground()
        await settle()
        XCTAssertEqual(w.ended.first?.dialog, .sessionExpired)
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }

    func testTC_ACC_03_45_kickedAtAbsoluteLimitStillRefreshes() async {
        let h = setupAccount()
        await capped(h)
        let c = await h.online()
        c.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    // A local clock running 20 hours fast, or a short TTL: the refreshed token already looks under 6 hours. One refresh,
    // one reconnect, then quiet; the server's 4011 still refreshes. New issue 15: sdk-ts loops here.
    func testTokenLookingShortOnArrivalDoesNotLoopRefresh() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, 5 * HOUR)
        var gen: Int64 = 1
        h.http.onRequest = { call in
            guard call.path == REFRESH else { return }
            gen += 1
            call.respond(200, authBody(gen: gen, accessExpiresAt: h.clock.now() + 4 * HOUR))
        }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid1", 2))
        h.clock.advance(MIN)
        h.account.foreground()
        h.account.trigger(.timer)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertNil(c2.closedWith)
        // Past its local expiry: no refresh either until the server says so.
        h.clock.advance(5 * HOUR)
        c2.drop(1006)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.transport.connections.count, 3)
        h.transport.current.open()
        h.transport.current.drop(4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        XCTAssertEqual(w.ended, [])
    }

    // The next token with enough time left goes back to normal.
    func testShortOnArrivalClearsWithTheNextGoodToken() async {
        let h = setupAccount()
        h.session(1, 5 * HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + 4 * HOUR))
        await settle()
        let rejected = RejectedToken(sid: "sid1", gen: 2)
        h.account.trigger(.kicked, rejected: rejected)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
        h.http.last(REFRESH).respond(200, authBody(gen: 3, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        h.clock.advance(18 * HOUR + 1)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 3)
    }

    // A fast local clock: the new token looks expired too; refreshing must not loop.
    func testFastClockDoesNotLoopRefresh() async {
        let h = setupAccount()
        h.session(1, -HOUR)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() - MIN))
        await settle()
        XCTAssertEqual(h.transport.connections.count, 1)
        h.transport.current.open()
        XCTAssertEqual(authToken(h.transport.current), jwt("sid1", 2))
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
    }
}

/// TC-ACC-04-*: password change, other devices, the queue.
@MainActor
final class AccountCredentialTests: AccountTestCase {
    private let before: Int64 = 1_800_518_400_000

    func testTC_ACC_04_05_passwordChangedKickClears() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        c.receive(event("kicked", ["reason": "passwordChanged", "recoverBefore": .int(before)]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        XCTAssertNil(h.store.saved)
        h.clock.advance(120_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testTC_ACC_04_09_wrongPasswordChangesNothing() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { try await h.account.logoutOthers(password: "wrong") }
        await settle()
        h.http.last("/v1/account/logout-others").respondError(401, 4018)
        let e = await errorOf(p)
        XCTAssertEqual((e as? AccountError)?.code, 4018)
        XCTAssertNil(c.closedWith)
        XCTAssertEqual(w.ended, [])
        XCTAssertEqual(h.account.localGen, 1)
    }

    func testTC_ACC_04_09_rightPasswordHoldsOldSidKickAndReconnects() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(4, DAY, sid: "sid-old")
        let c1 = await h.online()
        let p = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        c1.receive(event("kicked", ["reason": "sessionRevoked"]))
        c1.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(h.transport.connections.count, 1)
        h.clock.advance(500)
        h.http.last("/v1/account/logout-others").respond(200, authBody(sid: "sid-new", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await p.value
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid-new", 1))
        XCTAssertEqual(h.store.saved?.refreshToken, refreshToken("sid-new", 1))
        h.clock.advance(5_000)
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.shownBanners, [])
    }

    func testTC_ACC_04_16_timerDuringPasswordChangeSendsNoRefresh() async throws {
        let h = setupAccount()
        h.session(1, 6 * HOUR + 10_000)
        await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.clock.advance(11_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        h.http.last(PASSWORD).respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "CODE-2"))
        _ = try await p.value
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        XCTAssertEqual(h.maxPending, 1)
    }

    func testTC_ACC_04_16_failedPasswordChangeSendsTheQueuedRefresh() async {
        let h = setupAccount()
        h.session(1, 6 * HOUR + 10_000)
        await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "wrong", newPassword: "Password-2") }
        await settle()
        h.clock.advance(11_000)
        await settle()
        h.http.last(PASSWORD).respondError(401, 4018)
        let e = await errorOf(p)
        XCTAssertEqual((e as? AccountError)?.code, 4018)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        XCTAssertEqual(h.maxPending, 1)
    }

    func testTC_ACC_04_16_passwordChangeWaitsForARunningRefresh() async throws {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.to(PASSWORD).count, 0)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.http.to(PASSWORD).count, 1)
        XCTAssertEqual(h.http.last(PASSWORD).bearer, jwt("sid1", 2))
        h.http.last(PASSWORD).respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C"))
        _ = try await p.value
        XCTAssertEqual(h.maxPending, 1)
    }

    func testTC_ACC_04_16_queuedChangeRefreshesInItsOwnSlot() async throws {
        let h = setupAccount()
        h.session(1, -MIN)
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.calls.map { $0.path }, [REFRESH])
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.http.calls.map { $0.path }, [REFRESH, PASSWORD])
        XCTAssertEqual(h.http.last(PASSWORD).bearer, jwt("sid1", 2))
        h.http.last(PASSWORD).respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C"))
        let r = try await p.value
        XCTAssertEqual(r.recoveryCode, "C")
    }

    func testTC_ACC_04_16_passwordChange4011RefreshesInSlotAndResends() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respondError(401, 4011)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 1)
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.http.to(PASSWORD).count, 2)
        h.http.last(PASSWORD).respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C"))
        _ = try await p.value
    }

    func testTC_ACC_04_16_inSlotRefreshFailureFailsTheChangeAndKeepsRetrying() async {
        let h = setupAccount()
        h.session(1, -MIN)
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(REFRESH).fail()
        let e = await errorOf(p)
        XCTAssertNotNil(e)
        XCTAssertEqual(h.http.to(PASSWORD).count, 0)
        h.clock.advance(1_000)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 2)
    }

    func testTC_ACC_04_16_recoverAndLogoutOthersShareTheQueue() async throws {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        let a = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        let b = Task { try await h.account.recover(username: USER, recoveryCode: "CODE", newPassword: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.pending.map { $0.path }, [REFRESH])
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.http.pending.map { $0.path }, ["/v1/account/logout-others"])
        h.http.pending[0].respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await a.value
        await settle()
        XCTAssertEqual(h.http.pending.map { $0.path }, ["/v1/account/recover"])
        h.http.pending[0].respond(200, authBody(sid: "s3", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C3"))
        _ = try await b.value
        XCTAssertEqual(h.maxPending, 1)
    }

    // MARK: TC-ACC-04-25, the four orders of a password change's response.

    private func newTokens(_ h: AccountHarness) -> JSONValue {
        authBody(sid: "sid-new", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "CODE-2", recoveryCodeGen: 2)
    }

    private func kick(_ c: FakeConnection) {
        c.receive(event("kicked", ["reason": "passwordChanged", "recoverBefore": .int(before)]))
        c.drop(4012)
    }

    private var fatalKick: FatalReason { .kicked(reason: "passwordChanged", code: 4012, until: nil, recoverBefore: before) }

    /// The queue is free: the next operation goes out.
    private func queueFree(_ h: AccountHarness) async {
        let n = h.http.calls.count
        _ = Task { try await h.account.login(username: USER, password: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.calls.count, n + 1)
    }

    func testTC_ACC_04_25_oneNoResponseTimesOutAndTheKickApplies() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        kick(c)
        await settle()
        h.clock.advance(29_999)
        await settle()
        XCTAssertEqual(w.fatal, [])
        h.clock.advance(1)
        let e = await errorOf(p)
        XCTAssertEqual(e as? AccountNetworkError, .timeout)
        await settle()
        XCTAssertEqual(w.fatal, [fatalKick])
        XCTAssertEqual(w.ended.first?.dialog, .recoverBefore)
        XCTAssertEqual(w.ended.first?.origin, .kick)
        XCTAssertNil(h.account.session)
        await queueFree(h)
    }

    func testTC_ACC_04_25_twoResponseAfter31SecondsIsDropped() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        let call = h.http.last(PASSWORD)
        kick(c)
        await settle()
        h.clock.advance(31_000)
        await settle()
        call.respond(200, newTokens(h))
        await settle()
        let e = await errorOf(p)
        XCTAssertEqual(e as? AccountNetworkError, .timeout)
        XCTAssertNil(h.account.session)
        XCTAssertEqual(h.account.localGen, 1)
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.transport.connections.count, 1)
        XCTAssertEqual(w.fatal, [fatalKick])
        await queueFree(h)
    }

    func testTC_ACC_04_25_three500AndAKick() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        kick(c)
        await settle()
        h.http.last(PASSWORD).respondError(500, 5000)
        let e = await errorOf(p)
        XCTAssertEqual((e as? AccountError)?.code, 5000)
        await settle()
        XCTAssertEqual(w.fatal, [fatalKick])
        await queueFree(h)
    }

    func testTC_ACC_04_25_fourResponseBeforeKick() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(3, DAY, sid: "sid-old")
        let c1 = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respond(200, newTokens(h))
        let r = try await p.value
        XCTAssertEqual(r.recoveryCode, "CODE-2")
        XCTAssertEqual(r.recoveryCodeGen, 2)
        await settle()
        XCTAssertEqual(c1.closedWith?.code, 1000)
        kick(c1)  // The old connection's callbacks are void.
        await settle()
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid-new", 1))
        h.clock.advance(5_000)
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [])
        XCTAssertEqual(w.shownBanners, [])
        XCTAssertEqual(h.transport.connections.count, 2)
        await queueFree(h)
    }

    // The real server's order: the kick comes first.
    func testTC_ACC_04_25_kickBeforeResponseIsHeld() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(3, DAY, sid: "sid-old")
        let c1 = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        kick(c1)
        await settle()
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(h.transport.connections.count, 1)
        h.http.last(PASSWORD).respond(200, newTokens(h))
        _ = try await p.value
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        let c2 = await h.authNew()
        XCTAssertEqual(authToken(c2), jwt("sid-new", 1))
        h.clock.advance(5_000)
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.shownBanners, [])
    }

    // Recovery on a device that is online: the same hold (issue 6).
    func testTC_ACC_04_25_recoverHoldsTheKick() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(3, DAY, sid: "sid-old")
        let c1 = await h.online()
        let p = Task { try await h.account.recover(username: USER, recoveryCode: "CODE", newPassword: "Password-2") }
        await settle()
        kick(c1)
        await settle()
        XCTAssertEqual(w.fatal, [])
        h.http.last("/v1/account/recover").respond(200, newTokens(h))
        _ = try await p.value
        await settle()
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertEqual(w.fatal, [])
    }

    // Issue 12: an unknown reason with close code 4012 goes by the close code, so it is held as well.
    func testUnknownReasonWith4012IsHeldDuringAPasswordChange() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(3, DAY, sid: "sid-old")
        let c1 = await h.online()
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        c1.receive(event("kicked", ["reason": "futureReason"]))
        c1.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal, [])
        h.http.last(PASSWORD).respond(200, newTokens(h))
        _ = try await p.value
        await settle()
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(h.transport.connections.count, 2)
    }

    // An HTTP 4012 during a `sid` change, or for a token already replaced, is not this session's end.
    func testHttp4012DuringAChangeOrForAnOldTokenDoesNotEndTheSession() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let during = Task { try await h.account.listEvents() }
        await settle()
        let duringCall = h.http.last("/v1/account/events")
        let p = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        duringCall.respondError(401, 4012)
        _ = await errorOf(during)
        XCTAssertEqual(w.ended, [])
        let stale = Task { try await h.account.listEvents() }
        await settle()
        let staleCall = h.http.calls.last { $0.path == "/v1/account/events" }!
        h.http.last("/v1/account/logout-others").respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await p.value
        await settle()
        staleCall.respondError(401, 4012)
        _ = await errorOf(stale)
        XCTAssertEqual(w.ended, [])
        XCTAssertNotNil(h.account.session)
    }

    func testBanIsNotHeldDuringAPasswordChange() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        _ = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        c.receive(event("kicked", ["reason": "banned"]))
        c.drop(4012)
        await settle()
        guard case .kicked("banned", _, _, _)? = w.fatal.first else { return XCTFail("fatal") }
    }

    func testKickWithoutAChangeInFlightAppliesAtOnce() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        kick(c)
        await settle()
        XCTAssertEqual(w.fatal, [fatalKick])
    }

    func testChangeStillQueuedDoesNotHoldKicks() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, HOUR)
        let c = await h.online()
        _ = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        XCTAssertEqual(h.http.to(PASSWORD).count, 0)  // A refresh is ahead of it.
        kick(c)
        await settle()
        XCTAssertEqual(w.fatal, [fatalKick])
    }
}

/// TC-ACC-05-*: RS5-13, recovery codes.
@MainActor
final class AccountRecoveryCodeTests: AccountTestCase {
    private func loginWithCode(_ h: AccountHarness, left: Int64 = DAY, gen: Int64 = 3) async throws {
        let login = Task { try await h.account.login(username: USER, password: "Password-1") }
        await settle()
        h.http.last("/v1/account/login").respond(
            200, authBody(gen: 1, accessExpiresAt: h.clock.now() + left, recoveryCode: "C", recoveryCodeGen: gen))
        _ = try await login.value
        await settle()
    }

    func testTC_ACC_05_06_savedOnlyAfterAck() async throws {
        let h = setupAccount()
        let p = Task { try await h.account.register(username: USER, password: "Password-1", inviteCode: "INV") }
        await settle()
        h.http.last("/v1/account/register").respond(
            200, authBody(gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "CODE-1", recoveryCodeGen: 1))
        let r = try await p.value
        XCTAssertEqual(r.userId, USER)
        XCTAssertEqual(r.recoveryCode, "CODE-1")
        XCTAssertEqual(r.recoveryCodeGen, 1)
        XCTAssertNotNil(h.account.session)
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.store.saves.count, 0)
        // The app is killed here: a new instance finds no token.
        let restarted = h.newClient()
        let none = try await restarted.start()
        XCTAssertNil(none)
        let ack = Task { try await h.account.ackRecoveryCode(gen: 1) }
        await settle()
        XCTAssertEqual(h.http.last("/v1/account/recovery-code/ack").json, ["gen": 1])
        XCTAssertNil(h.store.saved)  // Not before the server confirmed.
        h.http.last("/v1/account/recovery-code/ack").respond(200)
        try await ack.value
        XCTAssertEqual(h.store.saved?.refreshToken, refreshToken("sid1", 1))
        XCTAssertEqual(h.store.saved?.mode, .account)
    }

    func testRefreshBeforeAckIsNotSaved() async throws {
        let h = setupAccount()
        try await loginWithCode(h, left: HOUR)
        h.account.foreground()
        await settle()
        h.http.last(REFRESH).respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 2)
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.store.saves.count, 0)
    }

    func testTC_ACC_05_18_passwordChangeClearsOldTokenAndHoldsNewInMemory() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        XCTAssertNotNil(h.store.saved)
        let p = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respond(
            200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C", recoveryCodeGen: 2))
        _ = try await p.value
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.store.saves.count, 0)
        XCTAssertEqual(h.account.session?.refreshToken, refreshToken("s2", 1))
        // Killed on the save page: the next launch goes to login, not to an old token's anomaly dialog.
        let restarted = h.newClient()
        let none = try await restarted.start()
        XCTAssertNil(none)
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
    }

    func testLogoutOthersBeforeAckStaysInMemory() async throws {
        let h = setupAccount()
        try await loginWithCode(h)
        let p = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        h.http.last("/v1/account/logout-others").respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await p.value
        XCTAssertEqual(h.account.session?.refreshToken, refreshToken("s2", 1))
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.store.saves.count, 0)
    }

    // A refresh that lands while the acknowledged token is being saved: what ends up stored is what is in use.
    func testAckSavesTheNewestTokenWhenARefreshLandsDuringTheSave() async throws {
        let h = setupAccount()
        try await loginWithCode(h, left: HOUR)
        h.account.foreground()
        await settle()
        let refresh = h.http.last(REFRESH)
        let ack = Task { try await h.account.ackRecoveryCode(gen: 3) }
        await settle()
        h.store.holdSaves = true
        h.http.last("/v1/account/recovery-code/ack").respond(200)
        await settle()
        refresh.respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertEqual(h.account.localGen, 2)
        h.store.releaseSaves()
        try await ack.value
        XCTAssertEqual(h.store.saved?.accessToken, jwt("sid1", 2))
    }

    func testAckSaveFailureRethrowsAndStaysInMemory() async throws {
        let h = setupAccount()
        try await loginWithCode(h)
        h.store.failSave = true
        let ack = Task { try await h.account.ackRecoveryCode(gen: 3) }
        await settle()
        h.http.last("/v1/account/recovery-code/ack").respond(200)
        let e = await errorOf(ack)
        XCTAssertNotNil(e)
        h.store.failSave = false
        let again = Task { try await h.account.ackRecoveryCode(gen: 3) }
        await settle()
        h.http.last("/v1/account/recovery-code/ack").respond(200)
        try await again.value
        XCTAssertEqual(h.store.saved?.refreshToken, refreshToken("sid1", 1))
    }

    func testTC_ACC_05_18_authAckUnackedReachesTheApp() async {
        let h = setupAccount()
        h.session(1, DAY)
        var viaIm = 0
        var viaAccount = 0
        h.im.on { if case .recoveryCodeUnacked = $0 { viaIm += 1 } }
        h.account.on { if case .recoveryCodeUnacked = $0 { viaAccount += 1 } }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        let c = h.transport.current
        c.open()
        c.ack("auth", ["userId": .string(USER), "serverTime": .int(h.clock.now()), "recoveryCodeUnacked": true])
        await settle()
        XCTAssertEqual(viaIm, 1)
        XCTAssertEqual(viaAccount, 1)
    }

    func testAccountResponseUnackedReachesTheApp() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        var n = 0
        h.account.on { if case .recoveryCodeUnacked = $0 { n += 1 } }
        let p = Task { try await h.account.listEvents() }
        await settle()
        h.http.last("/v1/account/events").respond(200, ["events": [], "otherSessions": ["count": 0], "recoveryCodeUnacked": true])
        _ = try await p.value
        XCTAssertEqual(n, 1)
    }

    func testRegenerateReturnsRecoveryCodeResponseTokenUnchanged() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let p = Task { try await h.account.regenerateRecoveryCode(password: "Password-1") }
        await settle()
        h.http.last("/v1/account/recovery-code").respond(200, ["recoveryCode": "NEW", "recoveryCodeGen": 5])
        let r = try await p.value
        XCTAssertEqual(r.recoveryCode, "NEW")
        XCTAssertEqual(r.recoveryCodeGen, 5)
        XCTAssertEqual(h.account.localGen, 1)
    }

    func testTC_ACC_05_14_staleEndsTheSessionWithoutSaving() async throws {
        let h = setupAccount()
        let w = Watch(h)
        try await loginWithCode(h, gen: 1)
        let ack = Task { try await h.account.ackRecoveryCode(gen: 1) }
        await settle()
        h.http.last("/v1/account/recovery-code/ack").respondError(400, 4000, reason: "recoveryCodeStale")
        let e = await errorOf(ack)
        XCTAssertEqual((e as? AccountError)?.code, 4000)
        XCTAssertEqual((e as? AccountError)?.reason, "recoveryCodeStale")
        XCTAssertEqual(w.ended.first?.action, .login)
        XCTAssertEqual(w.ended.first?.dialog, .recoveryCodeStale)
        XCTAssertEqual(w.ended[0].dialogText(), "恢复码已更新，请重新登录查看")
        XCTAssertNil(h.store.saved)
    }
}

/// F-ACC-02, 04, 06, 08, 09 and the HTTP conventions.
@MainActor
final class AccountOtherTests: AccountTestCase {
    func testTC_ACC_06_05_nicknameShowsAtOnceOthersAfterTenMinutes() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        var changed: [String] = []
        h.im.on { if case .profileChanged(let id) = $0 { changed.append(id) } }
        let p = Task { try await h.account.updateProfile(nickname: "小明") }
        await settle()
        XCTAssertEqual(h.http.last("/v1/account/profile").json, ["nickname": "小明"])
        h.http.last("/v1/account/profile").respond(200)
        try await p.value
        XCTAssertEqual(changed, [USER])
        XCTAssertEqual(h.im.displayName(USER), "小明")

        // Other devices: a 10-minute cache (F-SOC-10).
        let q = Task { try await h.im.getUsers(["bobby"]) }
        await settle()
        c.ack("users", ["users": [["userId": "bobby", "nickname": "旧名", "avatar": "", "official": false]]])
        _ = try await q.value
        _ = Task { try await h.im.getUsers(["bobby"]) }
        await settle()
        XCTAssertEqual(c.frames("users").count, 1)
        h.clock.advance(10 * MIN)
        _ = Task { try await h.im.getUsers(["bobby"]) }
        await settle()
        XCTAssertEqual(c.frames("users").count, 2)
    }

    func testTC_ACC_02_13_securityNoticeReachesTheAppUnknownKindIgnored() async {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        var got: [SecurityNotice] = []
        h.im.on { if case .securityNotice(let n) = $0 { got.append(n) } }
        c.receive(event("securityNotice", ["kind": "newDeviceLogin", "at": 123, "platform": "ios"]))
        c.receive(event("securityNotice", ["kind": "somethingNew", "at": 124, "platform": "ios"]))
        await settle()
        XCTAssertEqual(got, [SecurityNotice(kind: "newDeviceLogin", at: 123, platform: "ios")])
    }

    // AC-ACC-03-25, AC-ACC-03-45, F-ACC-05 rule 5.
    func testSecurityNoticeAllFourServerKindsPass() async {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        var got: [String] = []
        h.im.on { if case .securityNotice(let n) = $0 { got.append(n.kind) } }
        let kinds = [
            "newDeviceLogin", "passwordChanged", "passwordRecovered", "recoveryCodeRegenerated", "refreshReplay", "refreshRateLimited",
            "newIpPrefix",
        ]
        for k in kinds + ["futureKind", ""] {
            c.receive(event("securityNotice", ["kind": .string(k), "at": 1, "platform": "ios"]))
        }
        await settle()
        XCTAssertEqual(got, kinds)
    }

    func testTC_ACC_09_01_inviteUsedUpReachesTheAppWithoutASession() async {
        let h = setupAccount()
        let p = Task { try await h.account.register(username: "carol_1", password: "Password-1", inviteCode: "INV") }
        await settle()
        h.http.last("/v1/account/register").respondError(403, 4030, reason: "inviteInvalid")
        let e = await errorOf(p) as? AccountError
        XCTAssertEqual(e?.status, 403)
        XCTAssertEqual(e?.code, 4030)
        XCTAssertEqual(e?.reason, "inviteInvalid")
        XCTAssertNil(h.account.session)
    }

    func testDeleteRequestWrongPasswordThenSuccess() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let wrong = Task { try await h.account.requestDelete(password: "wrong") }
        await settle()
        h.http.last("/v1/account/delete").respondError(401, 4018)
        let e = await errorOf(wrong)
        XCTAssertEqual((e as? AccountError)?.code, 4018)
        XCTAssertNil(c.closedWith)

        let ok = Task { try await h.account.requestDelete(password: "Password-1") }
        await settle()
        c.receive(event("kicked", ["reason": "accountDeleted"]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal, [])
        h.http.last("/v1/account/delete").respond(200)
        try await ok.value
        await settle()
        XCTAssertEqual(w.fatal.count, 1)
        XCTAssertNil(h.account.session)
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testDeletionPendingLoginCarriesDetailsCancelIsAnonymous() async throws {
        let h = setupAccount()
        let p = Task { try await h.account.login(username: USER, password: "Password-1") }
        await settle()
        h.http.last("/v1/account/login").respondError(403, 4030, reason: "accountDeletionPending", details: ["deleteAt": 123])
        let e = await errorOf(p) as? AccountError
        XCTAssertEqual(e?.reason, "accountDeletionPending")
        XCTAssertEqual(e?.details?["deleteAt"], 123)
        let c = Task { try await h.account.cancelDelete(username: USER, password: "Password-1") }
        await settle()
        XCTAssertNil(h.http.last("/v1/account/delete/cancel").bearer)
        h.http.last("/v1/account/delete/cancel").respond(200)
        try await c.value
    }

    func testNoSessionThrowsSessionEndedWithoutARequest() async {
        let h = setupAccount()
        let a = await errorOf(Task { try await h.account.listEvents() })
        XCTAssertTrue(a is SessionEndedError)
        let b = await errorOf(Task { try await h.account.changePassword(oldPassword: "a", newPassword: "b") })
        XCTAssertTrue(b is SessionEndedError)
        XCTAssertEqual(h.http.calls.count, 0)
    }

    func testTimeoutUsesTheInjectedClock() async {
        let h = setupAccount()
        let p = Task { try await h.account.getConfig() }
        await settle()
        h.clock.advance(29_999)
        await settle()
        XCTAssertEqual(h.http.pending.count, 1)
        h.clock.advance(1)
        let e = await errorOf(p)
        XCTAssertEqual(e as? AccountNetworkError, .timeout)
    }

    func testGetConfigHasNoBearerAndDecodes() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let p = Task { try await h.account.getConfig() }
        await settle()
        XCTAssertNil(h.http.last("/v1/config").bearer)
        h.http.last("/v1/config").respond(
            200,
            [
                "registerMode": "invite", "demoLogin": false, "features": ["files": false],
                "limits": [
                    "usernameMinLen": 4, "usernameMaxLen": 32, "passwordMinLen": 8, "passwordMaxLen": 128, "nicknameMaxLen": 32,
                    "deviceNameMaxLen": 64,
                ],
                "somethingNew": 1,
            ])
        let cfg = try await p.value
        XCTAssertEqual(cfg.registerMode, .invite)
        XCTAssertFalse(cfg.demoLogin)
        XCTAssertEqual(cfg.limits.passwordMinLen, 8)
    }

    // TC-CHAT-90-09: all 14 calls are in `endpoints` and their bodies match the schema (checked in tearDown).
    func testTC_CHAT_90_09_everyEndpointIsCoveredAndMatchesTheSchema() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        let a = h.account
        let direct: [Task<Void, Error>] = [
            Task { _ = try await a.getConfig() },
            Task { _ = try await a.listEvents() },
            Task { try await a.updateProfile(nickname: "小明") },
            Task { _ = try await a.regenerateRecoveryCode(password: "Password-1") },
            Task { try await a.ackRecoveryCode(gen: 2) },
            Task { try await a.cancelDelete(username: USER, password: "Password-1") },
        ]
        await settle()
        for c in h.http.calls { c.respond(200, ["recoveryCode": "C", "recoveryCodeGen": 2, "events": [], "otherSessions": ["count": 0]]) }
        await settle()
        for t in direct { _ = await t.result }
        let queued: [@MainActor () -> Task<Void, Error>] = [
            { Task { _ = try await a.register(username: USER, password: "Password-1", nickname: "小明", inviteCode: "INV") } },
            { Task { _ = try await a.login(username: USER, password: "Password-1") } },
            { Task { _ = try await a.recover(username: USER, recoveryCode: "CODE", newPassword: "Password-2") } },
            { Task { _ = try await a.changePassword(oldPassword: "Password-1", newPassword: "Password-2") } },
            { Task { _ = try await a.logoutOthers(password: "Password-1") } },
            { Task { try await a.requestDelete(password: "Password-1") } },
        ]
        for run in queued {
            let t = run()
            await settle()
            h.http.pending[0].respondError(400, 4000)
            _ = await t.result
            await settle()
        }
        let out = Task { await a.logout() }
        await settle()
        h.http.pending[0].respond(200)
        _ = await out.value
        await settle()
        var seen = Set(h.http.calls.map { "\($0.request.method.rawValue) \($0.path)" })
        seen.insert("POST \(REFRESH)")  // The other tests send it.
        guard case .object(let endpoints)? = try loadJSON("schema/http-client.schema.json")["endpoints"] else {
            return XCTFail("endpoints")
        }
        XCTAssertEqual(Set(endpoints.keys).subtracting(seen), [])
    }

    // TC-CHAT-90-09: response shapes the SDK decodes are the schema's: the schema's examples through the real decoders.
    func testResponseDecodersAcceptSchemaShapedBodies() async throws {
        let http = try SchemaValidator.http()
        let events: JSONValue = [
            "events": [["kind": "login", "at": 1, "platform": "ios", "ipPrefix": "1.2.3.0/24"]],
            "otherSessions": ["count": 1, "lastActiveAt": 2],
        ]
        XCTAssertTrue(http.isValid(events, ref: "#/$defs/EventsResponse"))
        let decoded = try JSONDecoder().decode(AccountEvents.self, from: Data(events.jsonString().utf8))
        XCTAssertEqual(decoded.events[0].platform, "ios")
        let code: JSONValue = ["recoveryCode": "C", "recoveryCodeGen": 2]
        XCTAssertTrue(http.isValid(code, ref: "#/$defs/RecoveryCodeResponse"))
    }
}

/// F-ACC-04 rule 1: logout and pending logout.
@MainActor
final class AccountLogoutTests: AccountTestCase {
    func testLogoutTellsTheServerFirstThen1000KicksMeanwhileDoNotCount() async {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { await h.account.logout() }
        await settle()
        let call = h.http.last("/v1/account/logout")
        XCTAssertEqual(call.json, ["refreshToken": .string(refreshToken("sid1", 1))])
        XCTAssertEqual(call.bearer, jwt("sid1", 1))
        XCTAssertNil(c.closedWith)
        c.receive(event("kicked", ["reason": "sessionRevoked"]))
        c.drop(4012)
        await settle()
        XCTAssertEqual(w.fatal, [])
        call.respond(200)
        let confirmed = await p.value
        XCTAssertTrue(confirmed)
        await settle()
        XCTAssertEqual(w.fatal, [])
        XCTAssertEqual(w.ended, [SessionEnd(action: .logout)])
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.store.pendingLogouts, [])
        XCTAssertEqual(h.unregistered, 0)
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(h.transport.connections.count, 1)
    }

    func testLogoutClosesWith1000() async {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        let p = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        _ = await p.value
        XCTAssertEqual(c.closedWith?.code, 1000)
    }

    // TC-ACC-04-06: offline logout: local logout at once; only `sid` and refresh stay; sent when back online.
    func testTC_ACC_04_06_offlineLogoutThenNetworkReturns() async throws {
        let h = setupAccount()
        let w = Watch(h)
        h.session(1, DAY)
        let p = Task { await h.account.logout() }
        await settle()
        // Written before the request: a process killed here still logs out.
        XCTAssertEqual(h.store.pendingLogouts, [PendingLogout(sid: "sid1", refreshToken: refreshToken("sid1", 1))])
        h.http.last("/v1/account/logout").fail()
        let confirmed = await p.value
        XCTAssertFalse(confirmed)
        await settle()
        XCTAssertNil(h.account.session)
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(w.ended, [SessionEnd(action: .logout)])
        XCTAssertEqual(h.unregistered, 1)  // The system's token deregistration hook.
        XCTAssertEqual(h.store.pendingLogouts.count, 1)
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 1)

        h.account.networkOnline()
        await settle()
        let again = h.http.last("/v1/account/logout")
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 2)
        XCTAssertNil(again.bearer)  // The access token is gone.
        XCTAssertEqual(again.json, ["refreshToken": .string(refreshToken("sid1", 1))])
        h.account.networkOnline()  // No duplicate while one is in flight.
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 2)
        again.respond(200)
        await settle()
        XCTAssertEqual(h.store.pendingLogouts, [])
        h.account.networkOnline()
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 2)
    }

    // TC-ACC-04-06: the record survives a restart, and start() sends it.
    func testTC_ACC_04_06_pendingLogoutSurvivesARestart() async throws {
        let h = setupAccount()
        h.store.pendingLogouts = [PendingLogout(sid: "sid9", refreshToken: refreshToken("sid9", 4))]
        let restarted = h.newClient()
        let s = try await restarted.start()
        XCTAssertNil(s)
        await settle()
        XCTAssertEqual(h.http.last("/v1/account/logout").json, ["refreshToken": .string(refreshToken("sid9", 4))])
        h.http.last("/v1/account/logout").respond(200)
        await settle()
        XCTAssertEqual(h.store.pendingLogouts, [])
    }

    func testPendingLogoutKeptOn5xxAnd429DroppedOnTheServersAnswer() async {
        let h = setupAccount()
        h.store.pendingLogouts = [PendingLogout(sid: "sid9", refreshToken: refreshToken("sid9", 4))]
        h.account.networkOnline()
        await settle()
        h.http.last("/v1/account/logout").respondError(503, 5030)
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.count, 1)
        h.account.networkOnline()
        await settle()
        h.http.last("/v1/account/logout").respondError(429, 4290)
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.count, 1)
        h.account.networkOnline()
        await settle()
        h.http.last("/v1/account/logout").fail()
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.count, 1)
        h.account.networkOnline()
        await settle()
        h.http.last("/v1/account/logout").respondError(401, 4019, reason: "invalid")
        await settle()
        XCTAssertEqual(h.store.pendingLogouts, [])
    }

    // Killed during logout: the session and the record are both on disk. The user already logged out.
    func testKilledDuringLogoutDoesNotComeBackLoggedIn() async throws {
        let h = setupAccount()
        h.store.saved = h.makeSession(1, DAY)
        h.store.pendingLogouts = [PendingLogout(sid: "sid1", refreshToken: refreshToken("sid1", 1))]
        let restarted = h.newClient()
        let s = try await restarted.start()
        XCTAssertNil(s)
        await settle()
        XCTAssertNil(h.store.saved)
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 1)
    }

    func testAnotherSidsPendingLogoutLeavesTheSessionAlone() async throws {
        let h = setupAccount()
        h.store.saved = h.makeSession(1, DAY)
        h.store.pendingLogouts = [PendingLogout(sid: "old", refreshToken: refreshToken("old", 2))]
        let restarted = h.newClient()
        let s = try await restarted.start()
        XCTAssertEqual(s?.userId, USER)
        await settle()
        XCTAssertEqual(h.http.last("/v1/account/logout").json, ["refreshToken": .string(refreshToken("old", 2))])
    }

    func testTwoOfflineLogoutsKeepBothRecords() async throws {
        let h = setupAccount()
        h.session(1, DAY, sid: "s1")
        let a = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").fail()
        _ = await a.value
        await settle()
        h.session(1, DAY, sid: "s2")
        let b = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").fail()
        _ = await b.value
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.map { $0.sid }, ["s1", "s2"])
    }

    // As sdk-kotlin (issue 14): an unacknowledged token is written to the record only when the request failed.
    func testLogoutBeforeAckWritesTheRecordOnlyOnFailure() async throws {
        for fails in [false, true] {
            let h = setupAccount()
            let login = Task { try await h.account.login(username: USER, password: "Password-1") }
            await settle()
            h.http.last("/v1/account/login").respond(
                200, authBody(gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "C", recoveryCodeGen: 3))
            _ = try await login.value
            await settle()
            let p = Task { await h.account.logout() }
            await settle()
            XCTAssertEqual(h.store.pendingLogouts, [])
            if fails { h.http.last("/v1/account/logout").fail() } else { h.http.last("/v1/account/logout").respond(200) }
            _ = await p.value
            await settle()
            XCTAssertEqual(h.store.pendingLogouts.count, fails ? 1 : 0)
            XCTAssertNil(h.store.saved)
            XCTAssertFalse(h.store.calls.contains("save"))
            XCTAssertEqual(h.unregistered, fails ? 1 : 0)
        }
    }

    // Killed before the answer: the login state is already gone and the record already written.
    func testTC_ACC_04_06_killedBeforeTheAnswerStaysLoggedOut() async throws {
        let h = setupAccount()
        h.session(1, DAY)
        _ = Task { await h.account.logout() }
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.count, 1)
        XCTAssertNil(h.store.saved)
        let restarted = h.newClient(clock: FakeClock(start: h.clock.now()))
        let s = try await restarted.start()
        XCTAssertNil(s)
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 2)
    }

    // Returning from logout means the store call finished, however slow the Keychain is.
    func testLogoutReturnsOnlyAfterTheStoreIsClear() async {
        let h = setupAccount()
        h.session(1, DAY)
        h.store.holdClears = true
        var returned = false
        let out = Task {
            let r = await h.account.logout()
            returned = true
            return r
        }
        await settle()
        h.store.releaseSaves()  // The clear before the request.
        h.store.holdClears = true
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        await settle()
        XCTAssertFalse(returned)
        h.store.releaseSaves()
        _ = await out.value
        XCTAssertTrue(returned)
    }

    // A session still in memory while logging out does not refresh and write itself back.
    func testNoRefreshWhileLoggingOut() async {
        let h = setupAccount()
        h.session(1, HOUR)
        _ = Task { await h.account.logout() }
        await settle()
        h.account.foreground()
        h.account.trigger(.timer)
        await settle()
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        XCTAssertNil(h.store.saved)
    }

    // A rotation answered while the logout is in flight is not adopted.
    func testRotationAnsweredDuringLogoutIsNotAdopted() async {
        let h = setupAccount()
        h.session(1, DAY)
        let change = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        let call = h.http.last("/v1/account/logout-others")
        let out = Task { await h.account.logout() }
        await settle()
        call.respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY))
        let e = await errorOf(change)
        XCTAssertTrue(e is SessionEndedError)
        XCTAssertEqual(h.account.localGen, 1)
        h.http.last("/v1/account/logout").respond(200)
        _ = await out.value
        XCTAssertNil(h.store.saved)
    }

    // TC-ACC-04-06: a failed send retries with backoff a few times, then waits for the next event; one request at a time.
    func testTC_ACC_04_06_failedSendBacksOffThenWaits() async {
        let h = setupAccount()
        h.store.pendingLogouts = [PendingLogout(sid: "sid9", refreshToken: refreshToken("sid9", 4))]
        h.account.networkOnline()
        h.account.networkOnline()
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 1)
        for wait: Int64 in [1_000, 2_000, 4_000, 8_000, 16_000] {
            h.http.last("/v1/account/logout").fail()
            await settle()
            h.clock.advance(wait - 1)
            await settle()
            let before = h.http.to("/v1/account/logout").count
            h.clock.advance(1)
            await settle()
            XCTAssertEqual(h.http.to("/v1/account/logout").count, before + 1)
        }
        h.http.last("/v1/account/logout").fail()
        await settle()
        h.clock.advance(HOUR)
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 6)
        h.account.foreground()
        await settle()
        XCTAssertEqual(h.http.to("/v1/account/logout").count, 7)
    }

    func testPendingRecordsAreCappedAndSentInOrder() async {
        let h = setupAccount()
        h.store.pendingLogouts = (1...3).map { PendingLogout(sid: "s\($0)", refreshToken: refreshToken("s\($0)", 1)) }
        h.account.networkOnline()
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        await settle()
        h.http.last("/v1/account/logout").fail()
        await settle()
        XCTAssertEqual(h.store.pendingLogouts.map { $0.sid }, ["s2", "s3"])
        for n in 0..<9 {
            h.session(1, DAY, sid: "x\(n)")
            let p = Task { await h.account.logout() }
            await settle()
            h.http.pending.first { $0.bearer != nil }?.fail()
            _ = await p.value
            await settle()
        }
        XCTAssertEqual(h.store.pendingLogouts.count, 8)
        XCTAssertEqual(h.store.pendingLogouts.last?.sid, "x8")
    }

    func testLoginSendsPendingLogouts() async throws {
        let h = setupAccount()
        h.store.pendingLogouts = [PendingLogout(sid: "old", refreshToken: refreshToken("old", 2))]
        let login = Task { try await h.account.login(username: USER, password: "Password-1") }
        await settle()
        h.http.last("/v1/account/login").respond(200, authBody(gen: 1, accessExpiresAt: h.clock.now() + DAY))
        _ = try await login.value
        await settle()
        XCTAssertEqual(h.http.last("/v1/account/logout").json, ["refreshToken": .string(refreshToken("old", 2))])
    }

    func testLateRefreshAndPasswordResponsesDoNotReviveAfterLogout() async {
        let h = setupAccount()
        h.session(1, HOUR)
        h.account.foreground()
        await settle()
        let refresh = h.http.last(REFRESH)
        let p = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").respond(200)
        _ = await p.value
        refresh.respond(200, authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY))
        await settle()
        XCTAssertNil(h.account.session)
        XCTAssertNil(h.store.saved)

        let h2 = setupAccount()
        h2.session(1, DAY)
        let change = Task { try await h2.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        let pw = h2.http.last(PASSWORD)
        let out = Task { await h2.account.logout() }
        await settle()
        h2.http.last("/v1/account/logout").respond(200)
        _ = await out.value
        pw.respond(200, authBody(sid: "s2", gen: 1, accessExpiresAt: h2.clock.now() + DAY, recoveryCode: "C"))
        let e = await errorOf(change)
        XCTAssertTrue(e is SessionEndedError)
        XCTAssertNil(h2.account.session)
    }

    func testDemoLogoutSendsNothing() async {
        let h = setupAccount()
        h.account.restore(AccountSession(userId: USER, accessToken: "demo", accessExpiresAt: 0))
        let confirmed = await h.account.logout()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(h.http.calls.count, 0)
    }
}

/// Section 13.1, FE-610 item 6: credentials stay out of URLs, logs, events and errors.
@MainActor
final class AccountSecrecyTests: AccountTestCase {
    func testCredentialsStayOutOfLogsUrlsEventsAndErrors() async throws {
        let h = setupAccount()
        var secrets: Set<String> = ["Password-1", "Password-2", "CODE-SECRET", "CODE-SECRET-2", "INV-SECRET"]
        var seen: [String] = []
        h.account.on { seen.append("\($0)") }
        h.im.on { if case .fatal(let r) = $0 { seen.append("\(r)") } }
        var errors: [String] = []
        func remember(_ t: Task<AuthResult, Error>) async {
            do {
                let r = try await t.value
                errors += [String(describing: r), String(reflecting: r)]
            } catch {
                errors += [String(describing: error), String(reflecting: error), error.localizedDescription]
            }
        }
        func track(_ body: JSONValue) -> JSONValue {
            secrets.insert(body["accessToken"]!.stringValue!)
            secrets.insert(body["refreshToken"]!.stringValue!)
            return body
        }

        let reg = Task { try await h.account.register(username: USER, password: "Password-1", inviteCode: "INV-SECRET") }
        await settle()
        h.http.last("/v1/account/register").respond(
            200, track(authBody(gen: 1, accessExpiresAt: h.clock.now() + HOUR, recoveryCode: "CODE-SECRET", recoveryCodeGen: 1)))
        await remember(reg)
        let c1 = await h.online()
        await settle()
        h.http.last(REFRESH).respond(200, track(authBody(gen: 2, accessExpiresAt: h.clock.now() + DAY)))
        await settle()
        await h.authNew()
        XCTAssertEqual(c1.closedWith?.code, 1000)

        let wrong = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        h.http.last(PASSWORD).respondError(401, 4018)
        await remember(wrong)
        await settle()
        let pw = Task { try await h.account.changePassword(oldPassword: "Password-1", newPassword: "Password-2") }
        await settle()
        let last = track(authBody(sid: "s2", gen: 1, accessExpiresAt: h.clock.now() + DAY, recoveryCode: "CODE-SECRET-2"))
        h.http.last(PASSWORD).respond(200, last)
        await remember(pw)
        await settle()
        await h.authNew()

        let failing = Task { try await h.account.logoutOthers(password: "Password-1") }
        await settle()
        h.http.pending[0].fail("failed https://im.test/?token=\(last["accessToken"]!.stringValue!)")
        await remember(failing)
        await settle()

        // A session, a pending record and the results printed: nothing shows.
        let session = h.account.session!
        errors += [String(describing: session), String(reflecting: session)]
        var dumped = ""
        dump(session, to: &dumped)
        let pending = PendingLogout(sid: "s2", refreshToken: session.refreshToken!)
        dump(pending, to: &dumped)
        errors += [dumped, String(describing: pending)]
        h.account.foreground()
        let lg = Task { await h.account.logout() }
        await settle()
        h.http.last("/v1/account/logout").fail("failed https://im.test/?r=\(session.refreshToken!)")
        _ = await lg.value
        await settle()

        XCTAssertGreaterThan(h.logs.all.count, 0)
        let urls = h.http.calls.map { $0.request.url } + h.transport.connections.map { $0.url }
        for (name, lines) in [("logs", h.logs.all), ("urls", urls), ("events", seen), ("errors", errors)] {
            for line in lines {
                for s in secrets { XCTAssertFalse(line.contains(s), "\(name) holds a credential: \(line.prefix(60))") }
                XCTAssertFalse(line.contains("Bearer"), "\(name) holds Bearer")
            }
        }
        XCTAssertTrue(h.http.calls.allSatisfy { !$0.request.url.contains("?") })
        // The log has no query string at all, nor any URL.
        XCTAssertFalse(h.logs.all.contains { $0.contains("?") || $0.contains("https://") })
    }

    func testRecoveryResultsHideTheCodeWhenPrinted() throws {
        let code = try JSONDecoder().decode(
            RecoveryCodeResult.self, from: Data(#"{"recoveryCode":"CODE-SECRET","recoveryCodeGen":2}"#.utf8))
        let auth = AuthResult(userId: "u", recoveryCode: "CODE-SECRET", recoveryCodeGen: 2, recoveryCodeUnacked: false)
        var dumped = ""
        dump(code, to: &dumped)
        dump(auth, to: &dumped)
        for text in [dumped, String(describing: code), String(reflecting: code), String(describing: auth), String(reflecting: auth)] {
            XCTAssertFalse(text.contains("CODE-SECRET"), text)
        }
        XCTAssertEqual(code.recoveryCode, "CODE-SECRET")
    }
}
