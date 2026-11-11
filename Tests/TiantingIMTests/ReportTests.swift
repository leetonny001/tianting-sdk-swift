import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-692 (C6): reporting, 4510, features.moderation, canRetry, canReport (PRD-chat section 10, F-MOD-02, F-MOD-03,
// 13.1). The real IMClient on FakeTransport and a fake clock; frames sent down are checked against frame.schema.json
// (`down`), like everything the SDK sends up (IMTestCase). Same cases as sdk-ts test/report.test.ts
// (tianting-sdk-ts@d5fb273); canReport is frontend-chat 88 (rule of 77). Only marker strings (ZXQ-MOD-*, ZXQ-RPT-*), no
// real words. Local `swift test` results, CI not running.

private let AB = "c2c:alice:bob"
private let G1 = "group:g1"
private let NOTE = "ZXQ-RPT-NOTE"
private let WORD = "ZXQ-MOD-1"

@MainActor
private func downErr(_ c: FakeConnection, _ cmd: String, _ code: Int, reason: String? = nil, msg: String = "x") {
    var e: [String: JSONValue] = ["code": .int(Int64(code)), "msg": .string(msg)]
    if let reason { e["reason"] = .string(reason) }
    down(c, ["id": .string(c.last(cmd)!.id!), "cmd": "ack", "error": .object(e)])
}

/// The error a throwing async call ends with (nil, and a failure, when it succeeds).
@MainActor
private func failure(
    file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
) async -> Error? {
    do {
        try await body()
        XCTFail("expected a failure", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

@MainActor
class ReportTestCase: IMTestCase {
    var watched: [LogBox] = []

    override func tearDown() async throws {
        // AC-MOD-03-8, SDK part (FE-690 item 5): the note never reaches the logs; blocked content neither.
        for l in watched {
            let all = l.all.joined(separator: "\n")
            XCTAssertFalse(all.contains(NOTE), all)
            XCTAssertFalse(all.contains(WORD), all)
        }
        watched = []
        try await super.tearDown()
    }

    func online() async -> (Harness, FakeConnection) {
        let h = setup(heartbeatMs: 10 * 365 * 24 * 3_600_000)  // Moving the clock must not drop the connection.
        watched.append(h.logs)
        let c = await h.cvsOnline([sc(AB), sc(G1)])
        return (h, c)
    }

    /// A report that must be refused before any frame. If one goes out anyway it is answered with 5000, so a broken
    /// check fails the test instead of leaving it waiting for an ack forever.
    func rejected(
        _ h: Harness, _ c: FakeConnection, _ input: ReportInput, file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        let before = c.frames("report").count
        let t = Task { try await h.im.report(input) }
        await settle()
        if c.frames("report").count > before {
            XCTFail("report went out: \(input)", file: file, line: line)
            c.ackError("report", 5000)
        }
        return await errorOf(t, file: file, line: line)
    }

    func reportTask(_ h: Harness, _ input: ReportInput) -> Task<String, Error> {
        Task { try await h.im.report(input) }
    }
}

@MainActor
final class ReportTests: ReportTestCase {
    // AC-MOD-03-1, AC-MOD-03-9 (SDK part)
    func testReportGroupMessageSendsOneSchemaValidFrameAndReturnsTheReportId() async throws {
        let (h, c) = await online()
        let before = c.frames().count
        let convs = h.im.conversations()
        h.events = []
        let t = reportTask(h, .message(convId: G1, msgIds: ["m7"], reason: .abuse))
        await settle()
        XCTAssertEqual(
            c.last("report")?.data, ["targetType": "message", "convId": .string(G1), "msgIds": ["m7"], "reason": "abuse"])
        downAck(c, "report", ["reportId": "rp_01J9ZXQ"])
        let id = try await t.value
        XCTAssertEqual(id, "rp_01J9ZXQ")
        await settle()
        XCTAssertEqual(c.frames().dropFirst(before).map(\.cmd), ["report"])
        XCTAssertEqual(h.im.conversations(), convs)
        let touched = h.events.filter {
            switch $0 {
            case .messages, .conversations, .sendFailed: return true
            default: return false
            }
        }
        XCTAssertTrue(touched.isEmpty, "\(touched)")
    }

    func testThreeTargetsAndTheNoteAsGivenEvenEmpty() async throws {
        let (h, c) = await online()
        let inputs: [ReportInput] = [
            .message(convId: AB, msgIds: ["m1"], reason: .spam, note: NOTE),
            .user("bob", reason: .fraud, note: ""),
            .group("g1", reason: .illegal),
        ]
        for input in inputs {
            let t = reportTask(h, input)
            await settle()
            downAck(c, "report", ["reportId": "rp_1"])
            let id = try await t.value
            XCTAssertEqual(id, "rp_1")
        }
        XCTAssertEqual(
            c.frames("report").map(\.data),
            [
                ["targetType": "message", "convId": .string(AB), "msgIds": ["m1"], "reason": "spam", "note": .string(NOTE)],
                ["targetType": "user", "userId": "bob", "reason": "fraud", "note": ""],
                ["targetType": "group", "groupId": "g1", "reason": "illegal"],
            ])
    }

    // frontend-chat 84
    func testNoteCountsCodePoints200EmojiPass201CodePointsAre4000WithoutAFrame() async throws {
        let (h, c) = await online()
        let t = reportTask(h, .user("bob", reason: .other, note: String(repeating: "😀", count: reportNoteMax)))
        await settle()
        downAck(c, "report", ["reportId": "rp_2"])
        let id = try await t.value
        XCTAssertEqual(id, "rp_2")
        let e = await rejected(h, c, .user("bob", reason: .other, note: String(repeating: "a", count: reportNoteMax + 1)))
        XCTAssertEqual((e as? IMError)?.code, 4000)
        XCTAssertEqual((e as? IMError)?.details?["field"], "note")
        XCTAssertEqual(c.frames("report").count, 1)
    }

    // frontend-chat 85: the apps send one, the interface keeps the array.
    func testTwentyMsgIdsGoOut() async throws {
        let (h, c) = await online()
        let ids = (1...20).map { "m\($0)" }
        let t = reportTask(h, .message(convId: G1, msgIds: ids, reason: .porn))
        await settle()
        downAck(c, "report", ["reportId": "rp_3"])
        let id = try await t.value
        XCTAssertEqual(id, "rp_3")
        XCTAssertEqual(c.last("report")?.data?["msgIds"], strs(ids))
    }

    func testInvalidParametersAre4000WithTheFieldAndNoFrameAndNoNoteInTheError() async throws {
        let (h, c) = await online()
        let many = (0..<21).map { "m\($0)" }
        let cases: [(ReportInput, String)] = [
            (ReportInput(targetType: .message, convId: G1, msgIds: [], reason: .abuse), "msgIds"),
            (ReportInput(targetType: .message, convId: G1, msgIds: many, reason: .abuse), "msgIds"),
            (ReportInput(targetType: .message, convId: G1, msgIds: ["m 7"], reason: .abuse), "msgIds"),
            (ReportInput(targetType: .message, convId: G1, msgIds: [""], reason: .abuse), "msgIds"),
            (ReportInput(targetType: .message, convId: G1, reason: .abuse), "msgIds"),
            (ReportInput(targetType: .message, msgIds: ["m7"], reason: .abuse), "convId"),
            (ReportInput(targetType: .message, convId: "room:r1", msgIds: ["m7"], reason: .abuse), "convId"),
            (ReportInput(targetType: .message, convId: "g1", msgIds: ["m7"], reason: .abuse), "convId"),
            (ReportInput(targetType: .message, convId: "c2c:bob:carol", msgIds: ["m7"], reason: .abuse), "convId"),  // not mine
            (ReportInput(targetType: .message, convId: G1, msgIds: ["m7"], userId: "bob", reason: .abuse), "targetType"),
            (ReportInput(targetType: .message, convId: G1, msgIds: ["m7"], groupId: "g1", reason: .abuse), "targetType"),
            (ReportInput(targetType: .message, convId: G1, msgIds: ["m7"], userId: "", reason: .abuse), "targetType"),
            (ReportInput(targetType: .user, reason: .spam), "userId"),
            (ReportInput(targetType: .user, userId: "u 9", reason: .spam), "userId"),
            (ReportInput(targetType: .user, convId: AB, userId: "bob", reason: .spam), "targetType"),
            (ReportInput(targetType: .user, convId: "", userId: "bob", reason: .spam), "targetType"),
            (ReportInput(targetType: .user, msgIds: ["m7"], userId: "bob", reason: .spam), "targetType"),
            (ReportInput(targetType: .user, userId: "bob", groupId: "", reason: .spam), "targetType"),
            (ReportInput(targetType: .group, reason: .spam), "groupId"),
            (ReportInput(targetType: .group, groupId: "g/1", reason: .spam), "groupId"),
            (ReportInput(targetType: .group, userId: "bob", groupId: "g1", reason: .spam), "targetType"),
            (ReportInput(targetType: "conv", convId: G1, reason: .spam), "targetType"),
            (ReportInput(targetType: .user, userId: "bob", reason: "xxx", note: NOTE), "reason"),
            (ReportInput(targetType: .user, userId: "bob", reason: .spam, note: NOTE + String(repeating: "x", count: 200)), "note"),
        ]
        for (input, field) in cases {
            let e = await rejected(h, c, input)
            let im = e as? IMError
            XCTAssertEqual(im?.code, 4000, "\(input)")
            XCTAssertEqual(im?.details?["field"], .string(field), "\(input)")
            XCTAssertFalse(String(describing: e as Any).contains(NOTE))
            XCTAssertFalse((im?.message ?? "").contains(NOTE))
        }
        XCTAssertEqual(c.frames("report").count, 0)
    }

    func testServerErrorsAreThrownAsTheyAreNeverRetriedEvenAfterTimeAndAReconnect() async throws {
        let (h, c) = await online()
        let cases: [(Int, String?, String?)] = [
            (4292, nil, "今天的举报次数已用完"),
            (4040, "reportTargetInvalid", "无法举报该内容"),
            (4030, "featureDisabled", "举报功能暂不可用"),
            (4290, nil, "操作太频繁，请稍后再试"),
            (5000, nil, nil),
        ]
        for (code, reason, copy) in cases {
            let t = reportTask(h, .message(convId: AB, msgIds: ["m1"], reason: .abuse, note: NOTE))
            await settle()
            downErr(c, "report", code, reason: reason)
            let e = await errorOf(t)
            XCTAssertEqual(e as? IMError, IMError(code: code, message: "x", reason: reason))
            XCTAssertEqual(messageFor(cmd: "report", code: code), copy)
            XCTAssertFalse(String(describing: e as Any).contains(NOTE))
        }
        XCTAssertEqual(c.frames("report").count, cases.count)
        h.clock.advance(120_000)
        await settle()
        let n = await h.cvsReconnect(c, ["convs": [], "truncated": false])
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("report").count, cases.count)
        XCTAssertEqual(n.frames("report").count, 0)
        XCTAssertFalse(encoded(h.im.debugExport()).contains(NOTE))
    }

    func testTimeoutThrowsAndIsNotRetriedOfflineThrowsNotConnectedWithoutAFrame() async throws {
        let (h, c) = await online()
        let t = reportTask(h, .user("bob", reason: .abuse, note: NOTE))
        await settle()
        h.clock.advance(10_000)
        let e = await errorOf(t)
        XCTAssertEqual(e as? IMConnectionError, .timeout(cmd: "report"))
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("report").count, 1)
        h.im.disconnect()
        let off = await failure { _ = try await h.im.report(.user("bob", reason: .abuse)) }
        XCTAssertEqual(off as? IMConnectionError, .notConnected)
        // Invalid parameters are still 4000, before anything else.
        let bad = await failure { _ = try await h.im.report(.user("u 9", reason: .abuse)) }
        XCTAssertEqual((bad as? IMError)?.code, 4000)
        XCTAssertEqual(c.frames("report").count, 1)
    }

    // Before the user is known only the format is checked (sdk-ts does the same).
    func testBeforeLoginOnlyTheFormatIsChecked() async throws {
        let h = setup()
        let other = await failure { _ = try await h.im.report(.message(convId: "c2c:bob:carol", msgIds: ["m1"], reason: .spam)) }
        XCTAssertEqual(other as? IMConnectionError, .notConnected)
        let bad = await failure { _ = try await h.im.report(.message(convId: "c2c:carol:bob", msgIds: ["m1"], reason: .spam)) }
        XCTAssertEqual((bad as? IMError)?.details?["field"], "convId")  // Not in byte order: malformed.
    }

    func testReasonsAreTheSixInUIOrder() {
        XCTAssertEqual(ReportReason.all.map(\.rawValue), ["spam", "abuse", "porn", "fraud", "illegal", "other"])
    }
}

// MARK: 4510

@MainActor
final class BlockedSendTests: ReportTestCase {
    private func failedEvents(_ h: Harness) -> [IMEvent] {
        h.events.filter { if case .sendFailed = $0 { return true } else { return false } }
    }

    // TC-MOD-02-09 (AC-MOD-02-9, SDK part), frontend-chat 81
    func testSend4510FailsWithTheCodeNoWordNoAutomaticOrManualResendDeleteStillWorks() async throws {
        let (h, c) = await online()
        guard case .ok(let m0) = try h.im.send(AB, "含 \(WORD) 的消息") else { return XCTFail("send") }
        let id = m0.clientMsgId
        h.events = []
        downErr(c, "send", 4510, msg: "content blocked")
        await settle()
        let m = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == id })
        XCTAssertEqual(m.status, .failed)
        XCTAssertEqual(m.error, .code(4510))
        XCTAssertNil(m.errorReason)
        XCTAssertEqual(failedEvents(h).count, 1)
        guard case .sendFailed(let cid, let fid, let err) = failedEvents(h)[0] else { return XCTFail() }
        XCTAssertEqual([cid, fid], [AB, id])
        XCTAssertEqual(err, .code(4510))
        XCTAssertEqual(messageFor(cmd: "send", code: 4510), "消息包含不当内容，无法发送")
        XCTAssertFalse(h.im.canRetry(m))

        h.im.retry(AB, id)  // The app has no "重发"; called anyway, nothing goes out.
        await settle()
        h.clock.advance(60_000)
        let n = await h.cvsReconnect(c, ["convs": [sc(AB)], "truncated": false])
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("send").count, 1)
        XCTAssertEqual(n.frames("send").count, 0)
        XCTAssertEqual(h.im.messages(AB).first { $0.clientMsgId == id }?.error, .code(4510))
        XCTAssertEqual(h.im.messages(AB).first { $0.clientMsgId == id }?.status, .failed)
        XCTAssertTrue(h.im.removeFailed(AB, id))  // "删除" as usual
    }

    func testControl5000FailureCanBeRetried() async throws {
        let (h, c) = await online()
        guard case .ok(let m0) = try h.im.send(AB, "hi") else { return XCTFail("send") }
        downErr(c, "send", 5000)
        await settle()
        let m = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == m0.clientMsgId })
        XCTAssertTrue(h.im.canRetry(m))
        h.im.retry(AB, m.clientMsgId)
        await settle()
        XCTAssertEqual(c.frames("send").count, 2)
    }

    func testA4510AfterTheTimeoutTurnsTheFailureInto4510NoSecondSendFailed() async throws {
        let (h, c) = await online()
        guard case .ok(let m0) = try h.im.send(AB, "含 \(WORD)") else { return XCTFail("send") }
        let frameId = c.last("send")!.id!
        h.events = []
        h.clock.advance(11_000)
        await settle()
        let timedOut = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == m0.clientMsgId })
        XCTAssertEqual(timedOut.error, .timeout)
        XCTAssertTrue(h.im.canRetry(timedOut))
        down(c, ["id": .string(frameId), "cmd": "ack", "error": ["code": 4510, "msg": "content blocked"]])
        await settle()
        let m = try XCTUnwrap(h.im.messages(AB).first { $0.clientMsgId == m0.clientMsgId })
        XCTAssertEqual(m.status, .failed)
        XCTAssertEqual(m.error, .code(4510))
        XCTAssertFalse(h.im.canRetry(m))
        XCTAssertEqual(failedEvents(h).count, 1)  // Only the timeout's.
        XCTAssertEqual(c.frames("send").count, 1)
    }

    func testALate4510DoesNotTouchAManualResendInFlight() async throws {
        let (h, c) = await online()
        guard case .ok(let m0) = try h.im.send(AB, "含 \(WORD)") else { return XCTFail("send") }
        let first = c.last("send")!.id!
        h.clock.advance(11_000)
        await settle()
        h.im.retry(AB, m0.clientMsgId)
        await settle()
        XCTAssertEqual(h.im.messages(AB)[0].status, .sending)
        down(c, ["id": .string(first), "cmd": "ack", "error": ["code": 4510, "msg": "content blocked"]])
        await settle()
        XCTAssertEqual(h.im.messages(AB)[0].status, .sending)
        XCTAssertNil(h.im.messages(AB)[0].error)
    }

    func testCanRetryOnlyForFailedAndNotSourceMissing() {
        let h = setup()
        func m(_ s: MessageStatus, _ e: SendFailure?) -> Message {
            Message(
                clientMsgId: "c1", msgId: nil, seq: nil, convId: AB, from: "alice", type: .text, body: MsgBody(text: "x"),
                ts: 1, status: s, error: e, deleted: nil, deletedAt: nil)
        }
        XCTAssertFalse(h.im.canRetry(m(.failed, .sourceMissing)))
        XCTAssertFalse(h.im.canRetry(m(.failed, .code(4510))))
        XCTAssertFalse(h.im.canRetry(m(.sent, nil)))
        XCTAssertFalse(h.im.canRetry(m(.sending, nil)))
        XCTAssertTrue(h.im.canRetry(m(.failed, .timeout)))
        XCTAssertTrue(h.im.canRetry(m(.failed, .code(5000))))
        XCTAssertTrue(h.im.canRetry(m(.failed, .interrupted)))
    }

    // Other WS commands: 4510 thrown as is, the non-message copy (P-48 ⑥).
    func testOtherCommands4510AreThrownAsTheyAreWithTheFormCopy() async throws {
        let (h, c) = await online()
        let calls: [(String, () async throws -> Void)] = [
            ("groupCreate", { _ = try await h.im.createGroup(name: WORD, members: ["bob"]) }),
            ("groupUpdate", { try await h.im.updateGroup("g1", notice: WORD) }),
            ("friendApply", { _ = try await h.im.applyFriend("carol", options: ApplyFriendOptions(message: WORD)) }),
        ]
        for (cmd, call) in calls {
            let t = Task { try await call() }
            await settle()
            downErr(c, cmd, 4510, msg: "content blocked")
            let e = await errorOf(t)
            XCTAssertEqual((e as? IMError)?.code, 4510, cmd)
            XCTAssertNil((e as? IMError)?.details, cmd)
            XCTAssertEqual(messageFor(cmd: cmd, code: 4510), "内容包含不当信息，请修改后重试")
        }
        XCTAssertEqual(c.frames("groupCreate").count, 1)  // 4510 is not a timeout: no retry.
    }
}

// MARK: 4510 on images and files, accounts, features.moderation

@MainActor
final class BlockedAttachmentTests: FileTestCase {
    private let ab = "c2c:\(USER):bob"

    private func blocked(_ kind: MessageType) async throws {
        let (h, c) = await online()
        let m: Message
        if kind == .image {
            m = try h.im.sendImage(ab, image())
            await uploadOk(h, "F1")
        } else {
            m = try h.im.sendFile(
                ab, FileInput(file: makeFile("doc", size: 10), name: "\(WORD).pdf", mime: "application/pdf"))
            await settle()
            grant(h, "F1", thumb: false)
            await settle()
            h.objectStore.pending[0].respond(200)
            await settle()
            h.http.last("/v1/files/F1/complete").respond(200, ["fileId": "F1", "size": 10, "mime": "application/pdf"])
            await settle()
        }
        XCTAssertEqual(c.frames("send").count, 1)
        downErr(c, "send", 4510, msg: "content blocked")
        await settle()
        let now = try XCTUnwrap(h.im.messages(ab).first { $0.clientMsgId == m.clientMsgId })
        XCTAssertEqual(now.status, .failed)
        XCTAssertEqual(now.error, .code(4510))
        XCTAssertFalse(h.im.canRetry(now))
        let uploads = h.http.to("/v1/files/uploads").count
        h.im.retry(ab, m.clientMsgId)
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("send").count, 1)
        XCTAssertEqual(h.http.to("/v1/files/uploads").count, uploads)
        XCTAssertFalse(h.logs.all.joined().contains(WORD))
    }

    // AC-MOD-02-4, client side (a file name that hits)
    func testImage4510FailsNoReuploadNoResend() async throws { try await blocked(.image) }
    func testFile4510FailsNoReuploadNoResend() async throws { try await blocked(.file) }
}

@MainActor
final class BlockedAccountTests: AccountTestCase {
    func testRegisterAndUpdateProfile4510AreAccountErrors451WithoutDetailsSessionKept() async throws {
        let h = setupAccount()
        let reg = Task {
            _ = try await h.account.register(username: "carol_1", password: "Password-1", nickname: WORD, inviteCode: "INV")
        }
        await settle()
        h.http.last("/v1/account/register").respondError(451, 4510, msg: "content blocked")
        let e1 = await errorOf(reg)
        XCTAssertEqual((e1 as? AccountError)?.status, 451)
        XCTAssertEqual((e1 as? AccountError)?.code, 4510)
        XCTAssertNil((e1 as? AccountError)?.details)
        XCTAssertEqual(messageFor(cmd: "register", code: 4510), "内容包含不当信息，请修改后重试")

        h.session(1, DAY)
        let up = Task { try await h.account.updateProfile(nickname: WORD) }
        await settle()
        h.http.last("/v1/account/profile").respondError(451, 4510, msg: "content blocked")
        let e2 = await errorOf(up)
        XCTAssertEqual((e2 as? AccountError)?.status, 451)
        XCTAssertEqual((e2 as? AccountError)?.code, 4510)
        XCTAssertNotNil(h.account.session)
        XCTAssertEqual(h.http.to("/v1/account/profile").count, 1)
        XCTAssertFalse(h.logs.all.joined().contains(WORD))
    }

    // backend-chat 96, frontend-chat 76
    func testFeaturesModerationOnOffAndMissingOnOlderServers() async throws {
        let cases: [(JSONValue, Bool?)] = [
            (["files": true, "moderation": true], true),
            (["files": true, "moderation": false], false),
            (["files": true], nil),
        ]
        for (features, want) in cases {
            let h = setupAccount()
            let p = Task { try await h.account.getConfig() }
            await settle()
            h.http.last("/v1/config").respond(
                200,
                [
                    "registerMode": "open", "demoLogin": false, "features": features,
                    "limits": [
                        "usernameMinLen": 4, "usernameMaxLen": 32, "passwordMinLen": 8, "passwordMaxLen": 128,
                        "nicknameMaxLen": 32, "deviceNameMaxLen": 64,
                    ],
                ])
            let cfg = try await p.value
            XCTAssertEqual(cfg.features.moderation, want)
            XCTAssertEqual(cfg.features.moderation == true, want == true)
        }
    }
}

// MARK: Cold start (FE-691/692 item 1: the failure reason is stored, still no "重发" after a restart)

@MainActor
final class BlockedRestartTests: IMTestCase {
    private var base: URL!
    private let http = FakeHttp()

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tt-blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("inputs"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    private func start() -> Harness {
        let h = setup(directory: base.appendingPathComponent("db"), scratch: base.appendingPathComponent("scratch"))
        h.fileAuth.target = StaticTokenAuth(baseUrl: "https://im.test", token: "demo-token", http: http)
        return h
    }

    func testABlocked4510FileIsStillBlockedAfterAColdStartNoRetryNoUpload() async throws {
        let h = start()
        h.im.connect(token: "demo-token")
        let c = await h.login("alice")
        let src = base.appendingPathComponent("inputs/doc")
        try Data(repeating: 3, count: 10).write(to: src)
        let m = try h.im.sendFile(AB, FileInput(file: src, name: "\(WORD).pdf", mime: "application/pdf"))
        await settle()
        http.to("/v1/files/uploads").last!.respond(
            200,
            [
                "fileId": "F1",
                "put": ["url": "https://s3.test/chat/tmp/F1?X-Amz-Signature=1", "headers": [:], "expiresAt": 1],
            ])
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        http.last("/v1/files/F1/complete").respond(200, ["fileId": "F1", "size": 10, "mime": "application/pdf"])
        await settle()
        downErr(c, "send", 4510, msg: "content blocked")
        await settle()
        XCTAssertEqual(h.im.messages(AB).first?.error, .code(4510))
        h.im.close()  // Killed: the database stays.

        let h2 = start()
        h2.im.restoreCache(userId: "alice")
        let restored = try XCTUnwrap(h2.im.messages(AB).first { $0.clientMsgId == m.clientMsgId })
        XCTAssertEqual(restored.status, .failed)
        XCTAssertEqual(restored.error, .code(4510))
        h2.im.connect(token: "demo-token")
        let c2 = await h2.login("alice")
        await settle()
        XCTAssertFalse(h2.im.canRetry(restored))
        h2.im.retry(AB, m.clientMsgId)
        h2.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c2.frames("send").count, 0)
        XCTAssertEqual(http.to("/v1/files/uploads").count, 1)
        XCTAssertTrue(h2.im.removeFailed(AB, m.clientMsgId))
        h2.im.close()
    }
}

// MARK: canReport (frontend-chat 77, 88)

@MainActor
final class CanReportTests: ReportTestCase {
    /// Both conversations read up to 5: the made-up messages (seq 1) have been seen here.
    override func online() async -> (Harness, FakeConnection) {
        let h = setup(heartbeatMs: 10 * 365 * 24 * 3_600_000)
        watched.append(h.logs)
        let c = await h.cvsOnline([sc(AB, maxSeq: 5, readSeq: 5), sc(G1, maxSeq: 5, readSeq: 5)])
        return (h, c)
    }

    private func message(
        from: String = "bob", type: MessageType = .text, status: MessageStatus = .sent, convId: String = AB,
        msgId: String? = "m1", deleted: Bool? = nil, recalled: Bool? = nil, recalledBy: String? = nil
    ) -> Message {
        var m = Message(
            clientMsgId: "c1", msgId: msgId, seq: msgId == nil ? nil : 1, convId: convId, from: from, type: type,
            body: MsgBody(text: "x"), ts: 1, status: status, error: status == .failed ? .code(5000) : nil,
            deleted: deleted, deletedAt: deleted == true ? 2 : nil)
        m.recalled = recalled
        m.recalledBy = recalledBy
        return m
    }

    func testOthersSentTextImageFileOnly() async throws {
        let (h, _) = await online()
        for t in [MessageType.text, .image, .file] {
            XCTAssertTrue(h.im.canReport(message(type: t)), t.rawValue)
            XCTAssertTrue(h.im.canReport(message(type: t, convId: G1)), t.rawValue)
        }
        XCTAssertFalse(h.im.canReport(message(from: "alice")))  // my own
        XCTAssertFalse(h.im.canReport(message(type: .tip)))
        XCTAssertFalse(h.im.canReport(message(from: "", type: .tip)))
        XCTAssertFalse(h.im.canReport(message(type: .custom)))
        XCTAssertFalse(h.im.canReport(message(type: "voice")))  // unknown types: no
        for s in [MessageStatus.sending, .queued, .failed, .uploading, .processing] {
            XCTAssertFalse(h.im.canReport(message(from: "alice", status: s, msgId: nil)), s.rawValue)
            XCTAssertFalse(h.im.canReport(message(status: s)), s.rawValue)
        }
        XCTAssertFalse(h.im.canReport(message(msgId: nil)))
        XCTAssertFalse(h.im.canReport(message(convId: "room:r1")))
        XCTAssertFalse(h.im.canReport(message(convId: "c2c:bob:carol")))
        XCTAssertFalse(h.im.canReport(message(convId: "c2c:alice:zed")))  // not in the local list (frontend-chat 92)
    }

    // F-MOD-03 rule 2a: the recall notice row, only for someone else's message that someone else recalled.
    func testRecalledOnlyWhenSomeoneElsesAndNotRecalledByMeAdminDeletedNever() async throws {
        let (h, _) = await online()
        XCTAssertTrue(h.im.canReport(message(deleted: true, recalled: true, recalledBy: "bob")))
        XCTAssertTrue(h.im.canReport(message(convId: G1, deleted: true, recalled: true, recalledBy: "carol")))
        XCTAssertTrue(h.im.canReport(message(deleted: true, recalled: true)))  // who recalled unknown (older server)
        XCTAssertFalse(h.im.canReport(message(convId: G1, deleted: true, recalled: true, recalledBy: "alice")))
        XCTAssertFalse(h.im.canReport(message(from: "alice", deleted: true, recalled: true, recalledBy: "alice")))
        XCTAssertFalse(h.im.canReport(message(from: "alice", convId: G1, deleted: true, recalled: true, recalledBy: "bob")))
        XCTAssertFalse(h.im.canReport(message(deleted: true)))  // deleted by the admin
        XCTAssertFalse(h.im.canReport(message(type: .tip, deleted: true, recalled: true, recalledBy: "bob")))
    }

    func testRealMessagesFromTheStoreAndNothingBeforeLogin() async throws {
        let h = setup()
        watched.append(h.logs)
        let c = await h.cvsOnline([sc(G1, maxSeq: 3, readSeq: 2, unread: 1)])
        try await h.cvsLoaded(
            c, G1,
            [
                msg(G1, 1, from: "bob", msgId: "m1"), msg(G1, 2, from: "alice", msgId: "m2"),
                msg(G1, 3, from: "bob", msgId: "m3"),
            ])
        let ms = h.im.messages(G1)
        // frontend-chat 92: seq 3 is above readSeq 2, not seen here yet.
        XCTAssertEqual(ms.map { h.im.canReport($0) }, [true, false, false])
        guard case .ok(let mine) = try h.im.send(G1, "hi") else { return XCTFail("send") }
        XCTAssertFalse(h.im.canReport(mine))
        let fresh = setup()
        XCTAssertFalse(fresh.im.canReport(ms[0]))  // who "me" is is unknown
    }
}

// MARK: frames.json C6 (TC-CHAT-90-46)

@MainActor
final class ReportFrameVectorTests: ReportTestCase {
    func testC6CasesAreAllThere() throws {
        let spec = try loadJSON("vectors/frames.json")
        let c6 = { (k: String) in spec[k]!.arrayValue!.filter { $0["name"]!.stringValue!.contains("（C6") } }
        XCTAssertEqual(c6("valid").count, 13)
        XCTAssertEqual(c6("invalid").count, 32)
        let schema = try SchemaValidator.shared()
        for v in c6("valid") { XCTAssertTrue(schema.isValid(v["frame"]!), v["name"]!.stringValue!) }
        for v in c6("invalid") { XCTAssertFalse(schema.isValid(v["frame"]!), v["name"]!.stringValue!) }
    }

    func testValidC6AcksDecode() throws {
        let spec = try loadJSON("vectors/frames.json")
        let v = spec["valid"]!.arrayValue!.first { $0["name"]!.stringValue! == "ack report（C6）" }!
        XCTAssertEqual(try decodeFrameData(ReportAck.self, from: Data(v["frame"]!.jsonString().utf8)).reportId, "rp_01J9ZXQ")
    }

    /// The frames.json `report` cases as ReportInput: nil when the shape cannot be written in Swift (a missing reason or
    /// targetType, a non-string note or msgIds, an unknown field), which the type system rules out instead.
    private func input(_ data: JSONValue) -> ReportInput? {
        guard case .object(let o) = data, o.keys.allSatisfy(["targetType", "convId", "msgIds", "userId", "groupId", "reason", "note"].contains),
            let tt = o["targetType"]?.stringValue, let reason = o["reason"]?.stringValue
        else { return nil }
        // An absent field is nil; a present one must be a string, or the shape is not writable.
        for k in ["convId", "userId", "groupId", "note"] where o[k] != nil && o[k]?.stringValue == nil { return nil }
        let (convId, userId, groupId, note) = (
            o["convId"]?.stringValue, o["userId"]?.stringValue, o["groupId"]?.stringValue, o["note"]?.stringValue
        )
        var ids: [String]?
        if let m = o["msgIds"] {
            guard let a = m.arrayValue else { return nil }
            ids = a.compactMap(\.stringValue)
        }
        return ReportInput(
            targetType: ReportTargetType(rawValue: tt), convId: convId, msgIds: ids, userId: userId, groupId: groupId,
            reason: ReportReason(rawValue: reason), note: note)
    }

    // SDK-sent C6 frames conform (checked in tearDown too); the invalid report vectors are refused here, no frame.
    func testSentReportFramesConformAndInvalidVectorsAreRefusedLocally() async throws {
        let h = setup()
        watched.append(h.logs)
        let c = await h.cvsOnline([sc(G1)])
        let ids = (1...20).map { "m\($0)" }
        let good: [ReportInput] = [
            .message(convId: G1, msgIds: ["m7"], reason: .abuse),
            .message(convId: AB, msgIds: ["m1", "m2"], reason: .spam, note: "ZXQ-RPT-1"),
            .message(convId: G1, msgIds: ids, reason: .porn),
            .user("u9", reason: .fraud, note: ""),
            .group("g1", reason: .other, note: String(repeating: "举", count: 200)),
        ]
        for i in good { _ = reportTask(h, i) }
        await settle()
        let spec = try loadJSON("vectors/frames.json")
        var refused = 0
        for v in spec["invalid"]!.arrayValue! {
            let f = v["frame"]!
            guard f["cmd"]?.stringValue == "report", f["id"] != nil, let data = f["data"] else { continue }
            guard let i = input(data) else { continue }
            let e = await rejected(h, c, i)
            XCTAssertEqual((e as? IMError)?.code, 4000, v["name"]!.stringValue!)
            refused += 1
        }
        XCTAssertEqual(refused, 20)
        await settle()
        let sent = c.frames("report")
        XCTAssertEqual(sent.count, 5)
        let schema = try SchemaValidator.shared()
        for f in sent { XCTAssertTrue(schema.isValid(f.raw), f.raw.jsonString()) }
    }
}
