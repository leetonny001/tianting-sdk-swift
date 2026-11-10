import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// TC-CHAT-90-26 (AC-CHAT-90-7, older SDKs): C4's new frames and fields handed to the SDK. Only APIs that existed before
// C4 are used, so the same file also runs in a `git archive c8ec6ff` checkout (the sdk-swift before C4, FE-663 item 4).
// Same case as sdk-kotlin LegacyC4FramesTest.kt. Local `swift test` results, CI not running.

private let g = "group:g1"
private let secret = "ZXQ-RCL-2"

private func legacyMsg(_ seq: Int64, _ from: String, _ body: JSONValue, type: String = "text") -> JSONValue {
    [
        "msgId": .string("g1-\(seq)"), "clientMsgId": .string("\(from)-\(seq)"), "convId": .string(g), "seq": .int(seq),
        "from": .string(from), "type": .string(type), "body": body, "ts": .int(1000 + seq),
    ]
}

private func legacyRecalled(_ seq: Int64) -> JSONValue {
    [
        "msgId": .string("g1-\(seq)"), "clientMsgId": .string("bob-\(seq)"), "convId": .string(g), "seq": .int(seq),
        "from": "bob", "type": "text", "ts": .int(1000 + seq), "deleted": true, "recalled": true, "recalledAt": 9000,
        "recalledBy": "bob",
    ]
}

private func legacyConv(_ maxSeq: Int64, _ lastMsg: JSONValue, modVer: Int64 = 1) -> JSONValue {
    guard case .object(var o) = conv(g, maxSeq: maxSeq, readSeq: 0, unread: maxSeq, lastMsg: lastMsg, myRole: "member")
    else { return nil }
    o["mentionUnread"] = 2
    o["firstMentionSeq"] = 3
    o["modVer"] = .int(modVer)
    return .object(o)
}

private func legacyFilesContaining(_ dir: URL, _ needle: String) -> [String] {
    let bytes = Data(needle.utf8)
    let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return names.filter { (try? Data(contentsOf: $0))?.range(of: bytes) != nil }.map(\.lastPathComponent)
}

@MainActor
final class LegacyC4FramesTests: IMTestCase {
    func testTC_CHAT_90_26_recallQuoteMentionsDoNotCrashShowDeletedAndLeaveNoTextInMemoryOrDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-legacy-c4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = setup(directory: dir, heartbeatMs: 10 * 365 * DAY)
        h.im.connect(token: "token-value")
        let c = await h.login("alice", convs: [legacyConv(4, nil)])
        // Loaded messages with the marker; m2 quotes m1 (with its text) and mentions me; m3 an image, m4 a file.
        let t = Task { try await h.im.loadHistory(g) }
        await settle()
        c.ack(
            "sync",
            [
                "messages": [
                    legacyMsg(1, "bob", ["text": .string("\(secret) 原文")]),
                    legacyMsg(
                        2, "carol",
                        [
                            "text": "@alice 回复",
                            "quote": [
                                "msgId": "g1-1", "seq": 1, "from": "bob", "type": "text", "state": "normal", "text": .string("\(secret) 原文"),
                            ],
                            "mentions": ["userIds": ["alice"]],
                        ]),
                    legacyMsg(3, "bob", ["image": ["fileId": "f1", "width": 1, "height": 1, "size": 1, "mime": "image/png"]], type: "image"),
                    legacyMsg(4, "bob", ["file": ["fileId": "f2", "name": "a.pdf", "size": 1, "mime": "application/pdf"]], type: "file"),
                ],
                "hasMore": false,
            ])
        _ = try await t.value
        XCTAssertFalse(legacyFilesContaining(dir, secret).isEmpty, "control: the text was written to the database")
        // Live: msgDeleted with recalled, a new message with mentions.all and a recalled quote, convAdded with
        // mentionUnread and a recalled lastMsg.
        c.receive(
            event(
                "msgDeleted",
                ["convId": .string(g), "msgIds": ["g1-1"], "seqs": [1], "recalled": ["by": "bob", "at": 9000]]))
        c.receive(
            msgFrame(
                legacyMsg(
                    5, "bob",
                    [
                        "text": "@所有人", "mentions": ["all": true],
                        "quote": ["msgId": "g1-1", "seq": 1, "from": "bob", "type": "text", "state": "recalled"],
                    ])))
        c.receive(
            event(
                "convAdded",
                [
                    "conv": legacyConv(
                        5, ["msgId": "g1-1", "from": "bob", "type": "text", "ts": 1001, "deleted": true, "recalled": true, "recalledBy": "bob"])
                ]))
        // Reconnect: convs' lastMsg plain, the re-sync carries deleted + recalled.
        c.drop(1006)
        await settle()
        h.clock.advance(1_000)
        let c2 = await h.login(
            "alice", convs: [legacyConv(5, ["msgId": "g1-5", "from": "bob", "type": "text", "text": "@所有人", "ts": 1005], modVer: 2)])
        await settle()
        for f in c2.frames("sync") {
            c2.receive([
                "id": .string(f.id ?? ""), "cmd": "ack",
                "data": ["messages": [legacyRecalled(1), legacyMsg(2, "carol", ["text": "@alice 回复"])], "hasMore": false],
            ])
        }
        await settle()
        XCTAssertEqual(h.im.state, .connected)
        let m1 = h.im.messages(g).first { $0.seq == 1 }!
        XCTAssertEqual(m1.deleted, true)  // An older SDK shows "该消息已被删除".
        XCTAssertEqual(m1.body, MsgBody())
        XCTAssertEqual(h.im.messages(g).map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertFalse(holds(h.im.debugExport(), secret), "the text is still in memory")
        XCTAssertFalse(holds(h.im.store, secret), "the text is still in the store")
        h.im.close()
        XCTAssertEqual(legacyFilesContaining(dir, secret), [], "the text is still in the database")
    }
}
