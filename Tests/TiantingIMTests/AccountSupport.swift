import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

let USER = "alice_1"
let REFRESH = "/v1/account/token/refresh"
let PASSWORD = "/v1/account/password"
let HOUR: Int64 = 3_600_000
let DAY: Int64 = 24 * HOUR
let MIN: Int64 = 60_000
let accountStart: Int64 = 1_800_000_000_000

private func b64url(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// An access token shaped like the server's (only `sid` and `gen` mean anything to the SDK).
func jwt(_ sid: String, _ gen: Int64, sub: String = USER) -> String {
    "\(b64url("{\"alg\":\"HS256\"}")).\(b64url("{\"sub\":\"\(sub)\",\"sid\":\"\(sid)\",\"gen\":\(gen)}")).SIGNATURE-\(sid)-\(gen)"
}

func refreshToken(_ sid: String, _ gen: Int64) -> String {
    "k1.\(sid).\(gen).NONCE\(gen).MAC\(gen)"
}

/// Refresh, login and similar responses. Checked against the schema, so fake data cannot drift from the real server.
func authBody(
    sid: String = "sid1", gen: Int64, accessExpiresAt: Int64, absoluteExpiresAt: Int64? = nil, recoveryCode: String? = nil,
    recoveryCodeGen: Int64 = 2, recoveryCodeUnacked: Bool = false
) -> JSONValue {
    var o: [String: JSONValue] = [
        "userId": .string(USER),
        "accessToken": .string(jwt(sid, gen)),
        "accessExpiresAt": .int(accessExpiresAt),
        "refreshToken": .string(refreshToken(sid, gen)),
        "refreshExpiresAt": .int(accessExpiresAt + DAY),
        "absoluteExpiresAt": .int(absoluteExpiresAt ?? (accessExpiresAt + 365 * DAY)),
    ]
    if let recoveryCode {
        o["recoveryCode"] = .string(recoveryCode)
        o["recoveryCodeGen"] = .int(recoveryCodeGen)
    }
    if recoveryCodeUnacked { o["recoveryCodeUnacked"] = true }
    let body = JSONValue.object(o)
    let valid = (try? SchemaValidator.http().isValid(body, ref: "#/$defs/AuthResponse")) ?? false
    XCTAssertTrue(valid, "authBody does not match http-client.schema.json")
    return body
}

/// The SDK's async chains are longer than `flush()` covers.
@MainActor
func settle() async {
    for _ in 0..<300 { await Task.yield() }
}

@MainActor
final class AccountHarness {
    let base: Harness
    let http = FakeHttp()
    let store = MemorySessionStore()
    var account: AccountClient
    var badRequests: [String] = []
    private var peak = 0
    var unregistered = 0

    var im: IMClient { base.im }
    var files: FileClient { base.files }
    var objectStore: FakeObjectStore { base.objectStore }
    var clock: FakeClock { base.clock }
    var transport: FakeTransport { base.transport }
    var logs: LogBox { base.logs }
    var maxPending: Int { peak }

    init(base: Harness) {
        self.base = base
        var placeholder = AccountClientOptions(baseUrl: "https://im.test")  // `newClient` needs `self`.
        placeholder.http = http
        placeholder.systemEvents = false
        account = AccountClient(options: placeholder)
        account = newClient()
        base.fileAuth.target = account
        http.onRequest = { [unowned self] call in
            self.peak = max(self.peak, self.http.pending.count)
            self.check(call)
        }
    }

    /// Another process on the same store and server (a restart).
    func newClient(clock: FakeClock? = nil) -> AccountClient {
        var o = AccountClientOptions(baseUrl: "https://im.test")
        o.http = http
        o.clock = clock ?? base.clock
        o.store = store
        o.logger = base.logs
        o.random = { 0.5 }
        o.systemEvents = false
        o.unregisterSystemPushToken = { [unowned self] in self.unregistered += 1 }
        return AccountClient(options: o)
    }

    private func check(_ call: FakeHttpCall) {
        guard let schema = try? loadJSON("schema/http-client.schema.json"),
            let key = endpointKey(call.request.method.rawValue, call.path),
            let ep = schema["endpoints"]?[key]
        else {
            badRequests.append("no endpoint \(call.request.method.rawValue) \(call.path)")
            return
        }
        if let name = ep["request"]?.stringValue,
            let v = try? SchemaValidator.http(), !v.isValid(call.json, ref: "#/$defs/\(name)")
        {
            badRequests.append("\(call.path) does not match \(name)")
        }
    }

    /// Connects with the token provider and finishes auth.
    @discardableResult
    func online() async -> FakeConnection {
        im.connect(tokenProvider: account.tokenProvider)
        await settle()
        return await base.login(USER)
    }

    @discardableResult
    func authNew() async -> FakeConnection {
        await settle()
        return await base.login(USER)
    }

    @discardableResult
    func session(_ gen: Int64, _ accessLeft: Int64, sid: String = "sid1") -> AccountSession {
        let s = makeSession(gen, accessLeft, sid: sid)
        account.restore(s)
        store.saved = s
        return s
    }

    func makeSession(_ gen: Int64, _ accessLeft: Int64, sid: String = "sid1") -> AccountSession {
        AccountSession(
            mode: .account, userId: USER, accessToken: jwt(sid, gen), accessExpiresAt: clock.now() + accessLeft,
            refreshToken: refreshToken(sid, gen), refreshExpiresAt: clock.now() + DAY,
            absoluteExpiresAt: clock.now() + 365 * DAY)
    }
}

/// The `endpoints` key for a request: path parameters like `{fileId}` match the FileId characters.
func endpointKey(_ method: String, _ path: String) -> String? {
    guard case .object(let eps)? = (try? loadJSON("schema/http-client.schema.json"))?["endpoints"] else { return nil }
    if eps["\(method) \(path)"] != nil { return "\(method) \(path)" }
    for k in eps.keys {
        let marked = k.replacingOccurrences(of: "\\{[^}]+\\}", with: "PARAM", options: .regularExpression)
        let pattern =
            "^" + NSRegularExpression.escapedPattern(for: marked).replacingOccurrences(of: "PARAM", with: "[A-Za-z0-9_-]{1,64}")
            + "$"
        if "\(method) \(path)".range(of: pattern, options: .regularExpression) != nil { return k }
    }
    return nil
}

@MainActor
final class Watch {
    var fatal: [FatalReason] = []
    var ended: [SessionEnd] = []
    var banner: [Bool] = []
    var outcomes: [SessionOutcome] = []
    private var subs: [IMSubscription] = []

    init(_ h: AccountHarness) {
        subs.append(
            h.im.on { [unowned self] e in
                switch e {
                case .fatal(let r): self.fatal.append(r)
                case .banner(let b): self.banner.append(b)
                default: break
                }
            })
        subs.append(
            h.account.on { [unowned self] e in
                switch e {
                case .ended(let x): self.ended.append(x)
                case .outcome(let o): self.outcomes.append(o)
                default: break
                }
            })
    }

    var shownBanners: [Bool] { banner.filter { $0 } }
}

@MainActor
class AccountTestCase: IMTestCase {
    private var harnesses: [AccountHarness] = []

    func setupAccount() -> AccountHarness {
        // Not testing heartbeats here: off, or moving the clock with nobody answering pings would drop the connection.
        let h = AccountHarness(base: setup(clock: FakeClock(start: accountStart), heartbeatMs: 10 * 365 * DAY))
        harnesses.append(h)
        return h
    }

    override func tearDown() async throws {
        // Every request any test sent matches http-client.schema.json.
        for h in harnesses { XCTAssertEqual(h.badRequests, []) }
        harnesses = []
        try await super.tearDown()
    }
}

@MainActor
func authToken(_ c: FakeConnection) -> String? {
    c.last("auth")?.data?["token"]?.stringValue
}

/// Awaits a running call and returns its error, or fails when it succeeded.
@MainActor
func errorOf<T>(_ t: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
    do {
        _ = try await t.value
        XCTFail("expected a failure", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

/// The server's decision table (PRD-chat F-ACC-03 rule 4), after server/e2e/accountmodel/server.go. `serverCases` in
/// account-session.json constrain it, then SDK scenarios use it as a fake server.
final class FakeAccountSession {
    var current: Int64 = 1
    var next: Int64 = 2
    var overlapUntil: Int64 = 0
    var overlapMinGen: Int64 = 0
    var pendings: [Int64] = []
    var revoked = false
    var issued = 0
    var now: Int64 = 0
    private let maxPending = 4
    private let issueRate = 20
    private let overlapMs: Int64 = 120_000

    private func promote(_ gen: Int64) {
        overlapUntil = now + overlapMs
        overlapMinGen = current
        current = gen
        pendings = []
    }

    func refresh(_ gen: Int64) -> (result: String, newGen: Int64?) {
        if revoked { return ("alreadyRevoked", nil) }
        let pending = pendings.contains(gen)
        if gen != current, !pending {
            if gen >= overlapMinGen, now < overlapUntil { return ("superseded", nil) }
            revoked = true
            return ("replayDetected", nil)
        }
        if issued >= issueRate { return ("rateLimited", nil) }
        issued += 1
        var result = "issued"
        if pending {
            promote(gen)
            result = "issuedPromoted"
        }
        let newGen = next
        next += 1
        pendings.append(newGen)
        if pendings.count > maxPending { pendings = Array(pendings.suffix(maxPending)) }
        return (result, newGen)
    }

    func access(_ gen: Int64) -> String {
        if revoked { return "sessionRevoked" }
        if gen == current { return "ok" }
        if pendings.contains(gen) {
            promote(gen)
            return "promoted"
        }
        return "tokenExpired"
    }
}
