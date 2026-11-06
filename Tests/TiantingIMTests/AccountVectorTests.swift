import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// TC-CHAT-90-13 (AC-CHAT-90-15): protocol/vectors/account-session.json. `cases` run the real `AccountClient` with fake
/// HTTP and a fake clock: `refresh` really sent a request, `refreshOk` really is an HTTP response, `requestTimeout` really
/// is the clock moving 30 seconds. `source=kicked` calls `trigger` directly, the entry the connection uses; the path through
/// `FakeTransport` is in `AccountSessionTests`. `serverCases` constrain `FakeAccountSession`.
@MainActor
final class AccountVectorTests: AccountTestCase {
    private func httpStatus(_ code: Int) -> Int {
        [4019: 401, 4290: 429, 5030: 503, 4034: 403][code] ?? 400
    }

    private func expected(_ v: JSONValue) -> SessionOutcome {
        switch v["action"]!.stringValue! {
        case "none": return .none
        case "useLocal": return .useLocal
        case "backoff": return .backoff
        case "keepToken": return .keepToken
        case "banNotice": return .banNotice
        case "refresh": return .refresh(attempt: v["attempt"]!.intValue!)
        case "retryAfter": return .retryAfter(seconds: v["retryAfterSeconds"]?.intValue)
        case "login":
            return .login(
                dialog: v["dialog"]?.stringValue.flatMap(SessionDialog.init(rawValue:)), recoverBefore: v["recoverBefore"]?.intValue)
        default:
            XCTFail("unknown action \(v)")
            return .none
        }
    }

    func testTC_CHAT_90_13_cases() async throws {
        let spec = try loadJSON("vectors/account-session.json")
        let cases = spec["cases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        var sources = Set<String>()
        for c in cases {
            for st in c["steps"]!.arrayValue! { if let s = st["source"]?.stringValue { sources.insert(s) } }
            try await run(c)
        }
        XCTAssertEqual(sources, ["start", "foreground", "timer", "kicked"])
    }

    private func run(_ c: JSONValue) async throws {
        let name = c["name"]!.stringValue!
        let steps = c["steps"]!.arrayValue!
        let clock = FakeClock(start: steps.compactMap { $0["nowMs"]?.intValue }.first ?? accountStart)
        let http = FakeHttp()
        var o = AccountClientOptions(baseUrl: "https://im.test")
        o.http = http
        o.clock = clock
        o.random = { 0.5 }
        o.systemEvents = false
        let account = AccountClient(options: o)
        let start = c["start"]!
        let mode = SessionMode(rawValue: start["mode"]!.stringValue!)!
        let gen = start["accessGen"]!.intValue!
        account.restore(
            AccountSession(
                mode: mode, userId: USER, accessToken: jwt("sid1", gen), accessExpiresAt: start["accessExpiresAt"]!.intValue!,
                refreshToken: mode == .account ? refreshToken("sid1", gen) : nil,
                absoluteExpiresAt: start["absoluteExpiresAt"]!.intValue!))
        XCTAssertEqual(account.localGen, gen, name)
        var outcomes: [SessionOutcome] = []
        account.on { if case .outcome(let x) = $0 { outcomes.append(x) } }
        var attempts: Int64 = 0
        for (i, s) in steps.enumerated() {
            let op = s["op"]!.stringValue!
            let at = "\(name) step \(i + 1) \(op)"
            outcomes = []
            switch op {
            case "trigger":
                if let now = s["nowMs"]?.intValue, now > clock.now() { clock.advance(now - clock.now()) }
                let source = RefreshSource(rawValue: s["source"]!.stringValue!)!
                account.trigger(source, rejected: RejectedToken(gen: s["rejectedGen"]?.intValue))
            case "http4011":
                account.http4011(RejectedToken(gen: s["rejectedGen"]?.intValue ?? 0))
            case "requestTimeout":
                clock.advance(30_000)
            case "refreshOk":
                await settle()
                let t = s["tokens"]!
                http.to(REFRESH)[Int(s["attempt"]!.intValue!) - 1].respond(
                    200,
                    authBody(
                        gen: t["accessGen"]!.intValue!, accessExpiresAt: t["accessExpiresAt"]!.intValue!,
                        absoluteExpiresAt: t["absoluteExpiresAt"]!.intValue!))
            case "refreshFailed":
                await settle()
                let f = s["failure"]!
                let call = http.to(REFRESH)[Int(s["attempt"]!.intValue!) - 1]
                let code = Int(f["code"]!.intValue!)
                if code == 0 {
                    call.fail()
                } else {
                    var details: [String: JSONValue] = [:]
                    if let v = f["retryAfterSeconds"]?.intValue, v != 0 { details["retryAfterSeconds"] = .int(v) }
                    if let v = f["recoverBefore"]?.intValue, v != 0 { details["recoverBefore"] = .int(v) }
                    call.respondError(
                        httpStatus(code), code, reason: f["reason"]?.stringValue, details: details.isEmpty ? nil : details)
                }
            default:
                XCTFail("unknown op \(op)")
            }
            await settle()
            let want = expected(s["expect"]!)
            XCTAssertEqual(outcomes.last ?? .none, want, at)
            XCTAssertEqual(account.localGen, s["localGen"]!.intValue!, "\(at) localGen")
            XCTAssertEqual(account.refreshInflight, s["inflight"]! == .bool(true), "\(at) inflight")
            if case .refresh(let n) = want { attempts = n }
            XCTAssertEqual(Int64(http.to(REFRESH).count), attempts, "\(at) refresh requests sent")
        }
    }

    func testTC_CHAT_90_13_serverCases() throws {
        let spec = try loadJSON("vectors/account-session.json")
        let cases = spec["serverCases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let s = FakeAccountSession()
            for (i, step) in c["steps"]!.arrayValue!.enumerated() {
                let op = step["op"]!.stringValue!
                let at = "\(c["name"]!.stringValue!) step \(i + 1) \(op)"
                switch op {
                case "advance":
                    s.now += step["ms"]?.intValue ?? 0
                case "access":
                    XCTAssertEqual(s.access(step["gen"]!.intValue!), step["result"]!.stringValue!, at)
                default:
                    if let repeats = step["repeat"]?.intValue {
                        for _ in 0..<repeats { _ = s.refresh(step["gen"]!.intValue!) }
                    } else {
                        let r = s.refresh(step["gen"]!.intValue!)
                        XCTAssertEqual(r.result, step["result"]!.stringValue!, at)
                        if let g = step["newGen"]?.intValue { XCTAssertEqual(r.newGen, g, at) }
                    }
                }
                XCTAssertEqual(s.current, step["current"]!.intValue!, "\(at) current")
                XCTAssertEqual(s.revoked, step["revoked"]! == .bool(true), "\(at) revoked")
                XCTAssertEqual(s.overlapMinGen, step["overlapMinGen"]!.intValue!, "\(at) overlapMinGen")
                XCTAssertEqual(s.now < s.overlapUntil, step["inWindow"]! == .bool(true), "\(at) inWindow")
                XCTAssertEqual(s.pendings, step["pendings"]!.arrayValue!.map { $0.intValue! }, "\(at) pendings")
            }
        }
    }

    // The SDK against the fake server: 3 rounds of refresh and reconnect, each promoted, no superseded, no revocation.
    func testSdkAgainstFakeServerRefreshesCleanly() async {
        let h = setupAccount()
        let srv = FakeAccountSession()
        h.session(1, 5 * HOUR)
        h.http.onRequest = { call in
            srv.now = h.clock.now()
            let gen = Int64(call.json["refreshToken"]!.stringValue!.split(separator: ".")[2])!
            let r = srv.refresh(gen)
            XCTAssertTrue(r.result.hasPrefix("issued"), r.result)
            call.respond(200, authBody(gen: r.newGen!, accessExpiresAt: h.clock.now() + DAY))
        }
        func authed() async {
            await settle()
            let conn = h.transport.current
            conn.open()
            let gen = lineageOf(authToken(conn) ?? "").gen
            XCTAssertNotEqual(srv.access(gen), "tokenExpired")
            conn.ack("auth", ["userId": .string(USER), "serverTime": .int(h.clock.now())])
            await settle()
            conn.ack("convs", ["convs": [], "truncated": false])
            await settle()
        }
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await authed()  // Under 6 hours: refreshing starts at dialing, and the new token reconnects with 1000.
        for _ in 0..<3 {
            h.clock.advance(18 * HOUR + 60_000)  // Into the last 6 hours: the connected timer refreshes.
            await authed()
        }
        XCTAssertFalse(srv.revoked)
        XCTAssertEqual(srv.current, h.account.localGen)
        XCTAssertGreaterThanOrEqual(h.account.localGen, 4)
    }
}
