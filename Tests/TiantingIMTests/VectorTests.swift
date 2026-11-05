import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// The vectors shared by all SDKs and the server (protocol/vectors).
@MainActor
final class VectorTests: IMTestCase {
    // AC-MSG-01-2, AC-MSG-01-3: vectors/text.json
    func testTextVectors() throws {
        let spec = try loadJSON("vectors/text.json")
        let cases = spec["cases"]!.arrayValue!
        XCTAssertGreaterThan(cases.count, 30)
        for c in cases {
            let name = c["name"]!.stringValue!
            XCTAssertEqual(trimText(c["input"]!.stringValue!), c["trimmed"]!.stringValue!, name)
            XCTAssertEqual(Int64(countCodePoints(c["trimmed"]!.stringValue!)), c["length"]!.intValue!, name)
        }
    }

    func testCheckText() {
        XCTAssertEqual(checkText(" \n\t\u{3000} "), .empty)
        XCTAssertEqual(checkText(String(repeating: "字", count: 5000)), .ok(text: String(repeating: "字", count: 5000)))
        XCTAssertEqual(checkText(String(repeating: "😀", count: 5000)), .ok(text: String(repeating: "😀", count: 5000)))
        XCTAssertEqual(
            checkText(String(repeating: "字", count: 5003)),
            .tooLong(text: String(repeating: "字", count: 5003), over: 3))
        XCTAssertEqual(checkText("  hi  "), .ok(text: "hi"))
    }

    // AC-UI-33-13: vectors/convid.json
    func testConvIdVectors() throws {
        let spec = try loadJSON("vectors/convid.json")
        let me = spec["self"]!.stringValue!
        for c in spec["cases"]!.arrayValue! {
            let id = c["convId"]!.stringValue!
            if let ok = c["ok"] {
                let parsed = try parseConvIdStrict(id, me: me)
                XCTAssertEqual(parsed.convType.rawValue, ok["convType"]!.stringValue!, id)
                XCTAssertEqual(parsed.to, ok["to"]!.stringValue!, id)
            } else {
                XCTAssertThrowsError(try parseConvIdStrict(id, me: me), id) { err in
                    XCTAssertEqual((err as? ConvIdError)?.kind.rawValue, c["error"]!.stringValue!, id)
                }
            }
        }
    }

    func testPeerId() {
        XCTAssertEqual(peerId(convId: "c2c:alice:bob", type: .c2c, me: "alice"), "bob")
        XCTAssertEqual(peerId(convId: "c2c:alice:bob", type: .c2c, me: "bob"), "alice")
        XCTAssertNil(peerId(convId: "group:g1", type: .group, me: "alice"))
    }

    func testConvIdByteOrder() {
        XCTAssertEqual(c2cConvId("bob", "alice"), "c2c:alice:bob")
        XCTAssertEqual(c2cConvId("Bob", "alice"), "c2c:Bob:alice")  // ASCII bytes: uppercase sorts first.
        XCTAssertEqual(groupConvId("g1"), "group:g1")
    }

    // AC-UI-21-2: vectors/avatar.json
    func testAvatarVectors() throws {
        let spec = try loadJSON("vectors/avatar.json")
        for c in spec["colors"]!.arrayValue! {
            let id = c["id"]!.stringValue!
            XCTAssertEqual(Int64(fnv1a32(id)), c["fnv1a32"]!.intValue!, id)
            XCTAssertEqual(Int64(avatarColorIndex(id)), c["index"]!.intValue!, id)
        }
        for c in spec["initials"]!.arrayValue! {
            XCTAssertEqual(avatarInitial(c["name"]!.stringValue!), c["initial"]!.stringValue!)
        }
    }

    // AC-UI-13-9: vectors/pinyin-groups.json
    func testPinyinVectors() throws {
        let spec = try loadJSON("vectors/pinyin-groups.json")
        let cases = spec["cases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 50)
        for c in cases {
            let name = c["name"]!.stringValue!
            XCTAssertEqual(pinyinGroup(name), c["group"]!.stringValue!, name)
        }
    }

    // frames.json: `valid` passes the schema, `invalid` does not (proves the schema check used on all sent frames).
    func testFrameVectorsAgainstSchema() throws {
        let spec = try loadJSON("vectors/frames.json")
        let schema = try SchemaValidator.shared()
        for v in spec["valid"]!.arrayValue! {
            XCTAssertTrue(schema.isValid(v["frame"]!), "valid: \(v["name"]!.stringValue!)")
        }
        for v in spec["invalid"]!.arrayValue! {
            XCTAssertFalse(schema.isValid(v["frame"]!), "invalid: \(v["name"]!.stringValue!)")
        }
    }

    // frames.json: everything the SDK can receive decodes into its models.
    func testValidFramesDecodeIntoModels() throws {
        let spec = try loadJSON("vectors/frames.json")
        func raw(_ name: String) throws -> Data {
            let v = spec["valid"]!.arrayValue!.first { $0["name"]!.stringValue! == name }!
            return Data(v["frame"]!.jsonString().utf8)
        }
        XCTAssertEqual(try decodeFrameData(AuthAck.self, from: raw("auth ack")).userId, "alice")
        XCTAssertEqual(try decodeFrameData(AuthAck.self, from: raw("ack auth muted")).mutedUntil, .permanent)
        XCTAssertNil(try decodeFrameData(AuthAck.self, from: raw("auth ack")).mutedUntil)
        XCTAssertEqual(try decodeFrameData(SendAck.self, from: raw("ack send ok")).seq, 42)
        XCTAssertEqual(try decodeFrameData(SyncAck.self, from: raw("ack sync")).messages[0].clientMsgId, "6f1c2a4e-0001")
        XCTAssertEqual(try decodeFrameData(ConvsAck.self, from: raw("ack convs")).convs.count, 2)
        let tipConvs = try decodeFrameData(ConvsAck.self, from: raw("会话 lastMsg 是 tip、from 为空"))
        XCTAssertEqual(tipConvs.convs[0].myRole, .member)
        XCTAssertEqual(try decodeFrameData(ServerMessage.self, from: raw("msg c2c")).body?.text, "hi")
        let deleted = try decodeFrameData(ServerMessage.self, from: raw("deleted message"))
        XCTAssertNil(deleted.body)
        XCTAssertEqual(deleted.deletedAt, 1_730_000_100_000)
        let tip = try decodeFrameData(ServerMessage.self, from: raw("tip 消息：from 可以为空"))
        XCTAssertEqual(tip.body?.tip?.kind, "ownerChanged")
        XCTAssertEqual(tip.from, "")
    }

    // frames.json: every valid downstream frame is handled without breaking the connection; schema-invalid ones too.
    func testAllDownstreamFramesAreSafe() async throws {
        let spec = try loadJSON("vectors/frames.json")
        let h = setup()
        h.im.connect(token: "t")
        let c = await h.login("alice", convs: [conv("group:g1")])
        let frames = (spec["valid"]!.arrayValue! + spec["invalid"]!.arrayValue!).map { $0["frame"]! }
        for f in frames {
            guard let cmd = f["cmd"]?.stringValue, cmd == "event" || cmd == "msg" || cmd == "push" else { continue }
            if f.jsonString().contains("kicked") { continue }
            c.receive(f)
        }
        await flush()
        XCTAssertEqual(h.im.state, .connected)
    }

    // Generated tables agree with errors.json, both directions.
    func testErrorCodesMatchSpec() throws {
        let spec = try loadJSON("errors.json")
        let all = spec["errors"]!.arrayValue!
        let forSdk = all.filter { e in
            e["scope"]!.arrayValue!.contains { $0.stringValue != "console" }
        }
        XCTAssertLessThan(forSdk.count, all.count)  // console-only codes are really being filtered.
        XCTAssertEqual(errorInfoTable.count, forSdk.count)
        for e in forSdk {
            let code = Int(e["code"]!.intValue!)
            let d = describeError(code)
            XCTAssertEqual(d.name, e["name"]!.stringValue!)
            XCTAssertEqual(d.retryable, e["retryable"]! == .bool(true), e["name"]!.stringValue!)
            XCTAssertEqual(errorInfoTable[code]?.message, e["message"]!.stringValue!)
        }
        for c in spec["closeCodes"]!.arrayValue! {
            XCTAssertEqual(closeReconnect[Int(c["code"]!.intValue!)], c["reconnect"]! == .bool(true))
        }
        XCTAssertEqual(closeReconnect.count, spec["closeCodes"]!.arrayValue!.count)
        for k in spec["kickReasons"]!.arrayValue! {
            let want = k["closeCode"]!.intValue.map(Int.init)
            XCTAssertEqual(kickCloseCode[k["reason"]!.stringValue!] ?? nil, want)
        }
        XCTAssertEqual(ErrorCode.muted, 4031)
        XCTAssertEqual(CloseCode.tokenRevoked, 4012)
    }

    #if os(macOS)
    // ErrorCodes.gen.swift is exactly what the generator produces from this errors.json.
    func testGeneratedFileIsCurrent() throws {
        let root = protocolDir.deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", root.appendingPathComponent("scripts/gen-errors/gen_errors.py").path, "--check"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
    #endif

    func testUnknownErrorCodesFallBackOnPrefix() {
        XCTAssertEqual(
            describeError(4999), ErrorDescription(code: 4999, name: "UNKNOWN", category: .badRequest, retryable: false))
        XCTAssertEqual(describeError(4039).category, .forbidden)
        XCTAssertEqual(describeError(4049).category, .notFound)
        XCTAssertEqual(describeError(4299).category, .rateLimited)
        XCTAssertFalse(describeError(4299).retryable)
        XCTAssertEqual(describeError(5999).category, .server)
        XCTAssertTrue(describeError(5999).retryable)
        XCTAssertFalse(describeError(4292).retryable)  // FE-140: 4292 never retries.
    }

    // vectors/social.json `cases`: same state machine as the server's reference client.
    func testSocialSyncVectors() throws {
        let spec = try loadJSON("vectors/social.json")
        let cases = spec["cases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 11)
        for c in cases {
            let name = c["name"]!.stringValue!
            let s = SocialState()
            var last = ""
            for st in c["steps"]!.arrayValue! {
                switch st["type"]!.stringValue! {
                case "begin":
                    _ = s.beginRound()
                case "page":
                    let p = try JSONDecoder().decode(SocialSyncAck.self, from: Data(st["data"]!.jsonString().utf8))
                    last = s.applyPage(p).rawValue
                case "event":
                    s.onSocialChanged(st["ver"]!.intValue!)
                default:
                    let a = try JSONDecoder().decode(SocialChangeAck.self, from: Data(st["data"]!.jsonString().utf8))
                    s.applyAck(ver: a.ver, changed: a.changed, items: a.items)
                }
            }
            let now = c["nowMs"]!.intValue!
            let want = c["expect"]!
            XCTAssertEqual(s.ver, want["socialVer"]!.intValue!, name)
            var friends: [String: JSONValue] = [:]
            for f in s.friends.values where f.deleted != true { friends[f.userId] = .string(f.remark) }
            XCTAssertEqual(JSONValue.object(friends), want["friends"]!, name)
            var requests: [String: JSONValue] = [:]
            for r in s.requestList(at: now) { requests["\(r.userId)/\(r.direction.rawValue)"] = .string(r.status.rawValue) }
            XCTAssertEqual(JSONValue.object(requests), want["requests"]!, name)
            let blocks = s.blocks.values.filter { $0.deleted != true }.map(\.userId).sorted()
            XCTAssertEqual(strs(blocks), want["blocks"]!, name)
            XCTAssertEqual(Int64(s.unseen(at: now)), want["unread"]!.intValue!, name)
            XCTAssertEqual(s.needSync, want["needSync"]! == .bool(true), name)
            XCTAssertEqual(last, want["lastNext"]?.stringValue ?? "", name)
        }
    }

    // vectors/social.json `copy` (AC-SOC-08-8's strings).
    func testCopyVectors() throws {
        let spec = try loadJSON("vectors/social.json")
        for x in spec["copy"]!.arrayValue! {
            let want = x["text"]!.stringValue!
                .replacingOccurrences(of: "{N}", with: "3")
                .replacingOccurrences(of: "{name}", with: "bob")
            XCTAssertEqual(
                messageFor(cmd: x["cmd"]!.stringValue!, code: Int(x["code"]!.intValue!), strangerMsgLimit: 3, name: "bob"),
                want)
        }
        XCTAssertEqual(messageFor(cmd: "send", code: ErrorCode.quotaExceeded), "今天发起新聊天的次数已用完，请稍后再试")
        XCTAssertEqual(messageFor(cmd: "setPrivacy", code: 4290), "操作太频繁，请稍后再试")
        XCTAssertNil(messageFor(cmd: "send", code: 4042))
    }

    // vectors/social.json `tips` (AC-SOC-29-5).
    func testTipVectors() throws {
        let spec = try loadJSON("vectors/social.json")
        let tips = spec["tips"]!.arrayValue!
        XCTAssertGreaterThan(tips.count, 10)
        for c in tips {
            let tip = try JSONDecoder().decode(TipBody.self, from: Data(c["tip"]!.jsonString().utf8))
            let text = tipText(tip, me: c["me"]!.stringValue!) { u in c["names"]?[u]?.stringValue ?? u }
            XCTAssertEqual(text, c["text"]!.stringValue!)
        }
    }

    func testTipSummaryUsesNicknamesOnly() {
        let tip = TipBody(kind: "joined", actor: "alice", targets: ["bob", "carol"])
        XCTAssertEqual(tipSummary(tip) { $0 }, "alice 邀请 bob、carol 加入了群聊")
        XCTAssertEqual(tipSummary(TipBody(kind: "future", actor: "", targets: [])) { $0 }, "[群通知]")
        XCTAssertEqual(
            tipSummary(TipBody(kind: "joined", actor: "a", targets: ["b", "c", "d", "e"])) { $0 },
            "a 邀请 b、c、d等 4 人 加入了群聊")
    }
}
