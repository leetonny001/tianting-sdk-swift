import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// TC-CHAT-90-13 (AC-CHAT-90-15), TC-FILE-06-11 (AC-FILE-06-12): the shared cases in protocol/vectors/chat-sync.json
// (PRD-chat F-RCL-03 rules 2, 2a: expired merges monotonically, modVer decides the re-sync). The real IMClient +
// FakeTransport + fake clock: `connect` is the real convs answer after a (re)connect, and every `sync` the SDK sends is
// answered by convId.

/// The SDK's view of a message, written the way the cases write it.
private func view(_ m: Message) -> JSONValue {
    let image = m.body.image
    let file = m.body.file
    var o: [String: JSONValue] = [
        "seq": .int(m.seq ?? -1),
        "type": .string(m.type.rawValue),
        "fileId": .string(image?.fileId ?? file?.fileId ?? ""),
    ]
    if m.type == .file { o["name"] = .string(file?.name ?? "") }
    if image?.expired == true || file?.expired == true { o["expired"] = true }
    return .object(o)
}

/// Expands a case's message into a downstream message (the `消息` entry of `format`).
private func wire(_ convId: String, _ m: JSONValue) -> JSONValue {
    let seq = m["seq"]!.intValue!
    let type = m["type"]!.stringValue!
    let expired = m["expired"] == .bool(true)
    var f: [String: JSONValue] = ["fileId": m["fileId"]!, "size": 100]
    if type == "image" {
        f["width"] = 10
        f["height"] = 10
        f["mime"] = "image/png"
    } else {
        f["name"] = m["name"] ?? ""
        f["mime"] = "application/pdf"
    }
    if expired { f["expired"] = true }
    return [
        "msgId": .string("\(convId)#\(seq)"),
        "clientMsgId": .string("bob-\(convId)-\(seq)"),
        "convId": .string(convId),
        "seq": .int(seq),
        "from": "bob",
        "type": .string(type),
        "body": .object([type: .object(f)]),
        "ts": .int(1000 + seq),
    ]
}

/// Expands a case's conversation (the `会话` entry of `format`); no modVer means an older server.
private func wireConv(_ c: JSONValue) -> JSONValue {
    let maxSeq = c["maxSeq"]!.intValue!
    return conv(c["convId"]!.stringValue!, maxSeq: maxSeq, readSeq: maxSeq, modVer: c["modVer"]?.intValue)
}

@MainActor
private final class ChatSyncRunner {
    let h: Harness
    let me: String
    private var c: FakeConnection?
    private var answered: Set<String> = []

    init(_ h: Harness, me: String) {
        self.h = h
        self.me = me
    }

    /// Answers every unanswered sync until the SDK stops sending them. Returns the conversations synced meanwhile.
    private func drain(_ reply: (String) -> Result<[JSONValue], IMError>) async throws -> [String] {
        var synced: [String] = []
        for _ in 0..<50 {
            let open = c!.frames("sync").filter { !answered.contains($0.id ?? "") }
            if open.isEmpty { return synced.sorted() }
            for f in open {
                answered.insert(f.id ?? "")
                let convId = f.data?["convId"]?.stringValue ?? ""
                synced.append(convId)
                switch reply(convId) {
                case .failure(let e):
                    c!.receive(["id": .string(f.id ?? ""), "cmd": "ack", "error": ["code": .int(Int64(e.code)), "msg": "error"]])
                case .success(let ms):
                    c!.receive([
                        "id": .string(f.id ?? ""), "cmd": "ack",
                        "data": ["messages": .array(ms.map { wire(convId, $0) }), "hasMore": false],
                    ])
                }
            }
            await settle()
        }
        throw NSError(domain: "chat-sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "the SDK keeps sending sync"])
    }

    /// Runs one step; returns the synced conversations for `connect`.
    func step(_ st: JSONValue) async throws -> [String]? {
        switch st["op"]!.stringValue! {
        case "connect":
            if c == nil {
                h.im.connect(token: "token-value")
            } else {
                h.clock.advance(1_000)  // The first backoff, then the reconnect.
                await settle()
            }
            answered = []
            c = await h.login(me, convs: (st["convs"]?.arrayValue ?? []).map(wireConv))
            await settle()
            return try await drain { id in
                if let code = st["errors"]?[id]?.intValue {
                    return .failure(IMError(code: Int(code), message: "error"))
                }
                return .success(st["replies"]?[id]?.arrayValue ?? [])
            }
        case "disconnect":
            c!.drop(1006)
            await settle()
            return nil
        case "load":
            let convId = st["convId"]!.stringValue!
            let t = Task { try await h.im.loadHistory(convId) }
            await settle()
            _ = try await drain { _ in .success(st["messages"]?.arrayValue ?? []) }
            _ = try await t.value
            return nil
        case let op:
            throw NSError(domain: "chat-sync", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown op \(op)"])
        }
    }
}

@MainActor
final class ChatSyncVectorTests: IMTestCase {
    func testChatSyncVectors() async throws {
        let spec = try loadJSON("vectors/chat-sync.json")
        let me = spec["self"]!.stringValue!
        let cases = spec["cases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        let ops = Set(cases.flatMap { $0["steps"]!.arrayValue!.map { $0["op"]!.stringValue! } })
        XCTAssertEqual(ops, ["connect", "disconnect", "load"])
        var ran = 0
        for c in cases {
            let name = c["name"]!.stringValue!
            let h = setup(heartbeatMs: 10 * 365 * DAY)
            let r = ChatSyncRunner(h, me: me)
            let steps = c["steps"]!.arrayValue!
            for (i, st) in steps.enumerated() {
                let at = "\(name) step \(i) \(st["op"]!.stringValue!)"
                let events0 = h.events.count
                let syncs: [String]?
                do {
                    syncs = try await r.step(st)
                } catch {
                    XCTFail("\(at): \(error)")
                    break
                }
                guard let want = st["expect"] else { continue }
                if let ws = want["syncs"] {
                    XCTAssertEqual(strs(syncs ?? ["<not a connect>"]), ws, "\(at): syncs")
                }
                let expired = h.events[events0...].flatMap { e -> [String] in
                    if case .filesExpired(let ids) = e { return ids } else { return [] }
                }
                XCTAssertEqual(strs(expired.sorted()), want["filesExpired"]!, "\(at): filesExpired")
                guard case .object(let messages)? = want["messages"] else {
                    XCTFail("\(at): no messages in expect")
                    continue
                }
                for (convId, w) in messages {
                    XCTAssertEqual(JSONValue.array(h.im.messages(convId).map(view)), w, "\(at): messages of \(convId)")
                }
            }
            // An expired file's name is not kept in memory (F-FILE-06 rule 3): when the last expectation does not show
            // the marker, nothing the client holds does.
            if let last = steps.last(where: { $0["expect"] != nil })?["expect"], !last.jsonString().contains("ZXQ-FILE-NAME") {
                XCTAssertFalse(holds(h.im.debugExport(), "ZXQ-FILE-NAME"), "\(name): the expired name is still in memory")
                XCTAssertFalse(holds(h.im.store, "ZXQ-FILE-NAME"), "\(name): the expired name is still in the store")
            }
            h.im.close()
            ran += 1
        }
        XCTAssertEqual(ran, cases.count)
        print("chat-sync.json: \(ran) cases")
    }
}
