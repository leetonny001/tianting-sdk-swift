import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// FE-602: the fake HTTP seam, `client` scope error codes, the frames added for C1. Local results: `swift test` on macOS.
@MainActor
final class SharedContractTests: IMTestCase {
    // TC-CHAT-90-12 (AC-CHAT-90-14): every `client` scope code is in the enum, with errors.json's values.
    func testTC_CHAT_90_12_clientScopeCodesMatchErrorsJson() throws {
        let spec = try loadJSON("errors.json")
        let client = spec["errors"]!.arrayValue!.filter { e in
            e["scope"]!.arrayValue!.contains { $0.stringValue == "client" }
        }
        XCTAssertGreaterThan(client.count, 0)
        XCTAssertEqual(clientErrorCodes.sorted(), client.map { Int($0["code"]!.intValue!) }.sorted())
        for e in client {
            let code = Int(e["code"]!.intValue!)
            XCTAssertEqual(describeError(code).name, e["name"]!.stringValue!)
        }
        XCTAssertEqual(ErrorCode.accountCredentialsInvalid, 4018)
        XCTAssertEqual(ErrorCode.refreshTokenInvalid, 4019)
        XCTAssertEqual(ErrorCode.usernameTaken, 4095)
        XCTAssertEqual(ErrorCode.accountLoginLocked, 4294)
        var want: [Int: [String]] = [:]
        if case .object(let reasons)? = spec["reasons"] {
            for (k, v) in reasons where k != "$comment" {
                want[Int(k)!] = v.arrayValue!.map { $0.stringValue! }
            }
        }
        XCTAssertEqual(errorReasons, want)
        XCTAssertEqual(errorReasons[4019]?.contains("replayDetected"), true)
    }

    // TC-CHAT-90-09 (AC-CHAT-90-10): the C1 frames against frame.schema.json, and the HTTP schema really rejects.
    func testTC_CHAT_90_09_c1FramesAgainstSchema() throws {
        let schema = try SchemaValidator.shared()
        for reason in ["passwordChanged", "sessionRevoked", "accountDeleted"] {
            XCTAssertTrue(schema.isValid(event("kicked", ["reason": .string(reason), "recoverBefore": 1_800_000_000_000])))
        }
        XCTAssertTrue(
            schema.isValid(
                event("securityNotice", ["kind": "newDeviceLogin", "at": 1_800_000_000_000, "platform": "ios"])))
        XCTAssertFalse(schema.isValid(event("securityNotice", ["kind": "x", "at": 1_800_000_000_000])))
        XCTAssertTrue(
            schema.isValid([
                "id": "a1", "cmd": "ack",
                "data": ["userId": "alice", "serverTime": 1_800_000_000_000, "recoveryCodeUnacked": true],
            ]))
        let http = try SchemaValidator.http()
        XCTAssertFalse(http.isValid(["userId": "x"], ref: "#/$defs/AuthResponse"))
    }

    // PRD-chat 4.5: the fake records requests, answers late, and can act as a server.
    func testFakeHttpRecordsAndAnswersLate() async throws {
        let http = FakeHttp()
        async let first = http.request(HttpRequest(method: .post, url: "https://im.test/v1/a", body: Data("{\"x\":1}".utf8)))
        await flush()
        XCTAssertEqual(http.pending.count, 1)
        XCTAssertEqual(http.last("/v1/a").json["x"], 1)
        http.last("/v1/a").respond(201, ["ok": true])
        let r = try await first
        XCTAssertEqual(r.status, 201)
        XCTAssertEqual(http.pending.count, 0)
        http.last("/v1/a").respond(500)  // Answering again is harmless.

        http.onRequest = { $0.respondError(401, 4019, reason: "revoked") }
        let e = try await http.request(HttpRequest(method: .get, url: "https://im.test/v1/b"))
        XCTAssertEqual(e.status, 401)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: e.body)["reason"], "revoked")

        http.onRequest = { $0.fail("boom") }
        do {
            _ = try await http.request(HttpRequest(method: .get, url: "https://im.test/v1/c"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? FakeHttpError)?.message, "boom")
        }
    }

    func testHttpRequestNeverPrintsCredentials() {
        let r = HttpRequest(
            method: .post, url: "https://im.test/x?q=SECRET-Q", headers: ["Authorization": "Bearer SECRET-A"],
            body: Data("{\"refreshToken\":\"SECRET-R\"}".utf8))
        var dumped = ""
        dump(r, to: &dumped)
        for text in [String(describing: r), String(reflecting: r), dumped] {
            XCTAssertFalse(text.contains("SECRET"), text)
        }
    }

    // FE-602 item 2, PRD-chat F-ACC-04 rule 5: an unknown reason is ignored when the close code may reconnect, otherwise
    // the close code settles it and the reason goes to the UI as sent.
    func testUnknownKickReasonFollowsTheCloseCode() async {
        let h = setup()
        h.im.connect(token: "t")
        let c1 = await h.login()
        c1.receive(event("kicked", ["reason": "futureReason"]))
        c1.drop(1006)
        h.clock.advance(1_000)
        XCTAssertEqual(h.transport.connections.count, 2)
        XCTAssertTrue(h.logs.all.contains { $0.contains("unknown kick reason") })
        var fatal: [FatalReason] = []
        h.im.on { if case .fatal(let r) = $0 { fatal.append(r) } }
        let c2 = await h.login()
        c2.receive(event("kicked", ["reason": "futureReason"]))
        c2.drop(4012)
        XCTAssertEqual(fatal, [.kicked(reason: "futureReason", code: 4012, until: nil)])
    }

    // AC-ACC-04-5 (SDK part): kicked carries recoverBefore to the UI.
    func testKickedCarriesRecoverBefore() async {
        let h = setup()
        var fatal: [FatalReason] = []
        h.im.on { if case .fatal(let r) = $0 { fatal.append(r) } }
        h.im.connect(token: "t")
        let c = await h.login()
        c.receive(event("kicked", ["reason": "passwordChanged", "recoverBefore": 1_800_518_400_000]))
        c.drop(4012)
        XCTAssertEqual(fatal, [.kicked(reason: "passwordChanged", code: 4012, until: nil, recoverBefore: 1_800_518_400_000)])
    }
}
