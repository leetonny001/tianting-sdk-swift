import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// TC-CHAT-90-13 (AC-CHAT-90-15), TC-FILE-06-11 (AC-FILE-06-12): the shared cases in protocol/vectors/chat-sync.json
// (PRD-chat F-RCL-03 rules 2, 2a: expired merges monotonically, modVer decides the re-sync).
// C4 (FE-663, FE-664): TC-CHAT-90-33 and the same-named cases of TC-RCL-03-11, TC-RCL-03-13, TC-QUO-02-02, TC-QUO-02-06,
// TC-MEN-03-07 run here too: steps `event`, `advance`, expectations `convsFetches`, `mentionUnread`. Every case runs twice,
// in memory and with a real SQLite file (whose raw bytes are searched for the markers at the end), as sdk-kotlin does.
// The real IMClient + FakeTransport + fake clock: `connect` is the real convs answer after a (re)connect, and every `sync`
// the SDK sends is answered by convId. Local results, CI not running.

private func bool(_ m: JSONValue, _ k: String) -> Bool { m[k] == .bool(true) }

/// The SDK's view of a message, written the way the cases write it. A deleted message shows only seq, type, deleted,
/// recalled and recalledBy, and its body must be empty.
private func view(_ m: Message) -> JSONValue {
    var o: [String: JSONValue] = ["seq": .int(m.seq ?? -1), "type": .string(m.type.rawValue)]
    if m.deleted == true {
        XCTAssertEqual(m.body, MsgBody(), "seq \(m.seq ?? -1): the body of a deleted message")
        o["deleted"] = true
        if m.recalled == true { o["recalled"] = true }
        if let by = m.recalledBy { o["recalledBy"] = .string(by) }
        return .object(o)
    }
    let image = m.body.image
    let file = m.body.file
    if m.isAttachment { o["fileId"] = .string(image?.fileId ?? file?.fileId ?? "") }
    if m.type == .file { o["name"] = .string(file?.name ?? "") }
    if image?.expired == true || file?.expired == true { o["expired"] = true }
    if let text = m.body.text { o["text"] = .string(text) }
    if let q = m.body.quote {
        var qo: [String: JSONValue] = ["state": .string(q.state.rawValue)]
        if let s = q.seq { qo["seq"] = .int(s) }
        if let t = q.text { qo["text"] = .string(t) }
        o["quote"] = .object(qo)
    }
    return .object(o)
}

/// A case's message without the default `expired: false`, as `view` writes it.
private func normalize(_ m: JSONValue) -> JSONValue {
    guard case .object(var o) = m else { return m }
    if o["expired"] == .bool(false) { o["expired"] = nil }
    return .object(o)
}

/// Expands a case's message into a downstream message (the `消息` entry of `format`).
private func wire(_ convId: String, _ m: JSONValue) -> JSONValue {
    let seq = m["seq"]!.intValue!
    let type = m["type"]!.stringValue!
    var o: [String: JSONValue] = [
        "msgId": .string("\(convId)#\(seq)"),
        "clientMsgId": .string("bob-\(convId)-\(seq)"),
        "convId": .string(convId),
        "seq": .int(seq),
        "from": "bob",
        "type": .string(type),
        "ts": .int(1000 + seq),
    ]
    if bool(m, "deleted") {
        o["deleted"] = true
        if bool(m, "recalled") {
            o["recalled"] = true
            o["recalledAt"] = .int(2000 + seq)
            o["recalledBy"] = m["recalledBy"]!
        }
        return .object(o)
    }
    if type == "image" || type == "file" {
        var f: [String: JSONValue] = ["fileId": m["fileId"]!, "size": 100]
        if type == "image" {
            f["width"] = 10
            f["height"] = 10
            f["mime"] = "image/png"
        } else {
            f["name"] = m["name"] ?? ""
            f["mime"] = "application/pdf"
        }
        if bool(m, "expired") { f["expired"] = true }
        o["body"] = .object([type: .object(f)])
    } else {
        var b: [String: JSONValue] = ["text": m["text"]!]
        if let q = m["quote"] {
            let qs = q["seq"]!.intValue!
            var qo: [String: JSONValue] = [
                "msgId": .string("\(convId)#\(qs)"), "seq": .int(qs), "from": "bob", "type": "text", "state": q["state"]!,
            ]
            if let t = q["text"] { qo["text"] = t }
            b["quote"] = .object(qo)
        }
        o["body"] = .object(b)
    }
    return .object(o)
}

/// Expands a case's conversation (the `会话` entry of `format`); no modVer means an older server, no mentionUnread means
/// the feature is off or the server is older.
private func wireConv(_ c: JSONValue) -> JSONValue {
    let maxSeq = c["maxSeq"]!.intValue!
    guard case .object(var o) = conv(c["convId"]!.stringValue!, maxSeq: maxSeq, readSeq: maxSeq, modVer: c["modVer"]?.intValue)
    else { return nil }
    if let mu = c["mentionUnread"]?.intValue {
        o["mentionUnread"] = .int(mu)
        if mu > 0 { o["firstMentionSeq"] = .int(maxSeq) }
    }
    return .object(o)
}

private struct VectorError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ChatSyncRunner {
    let h: Harness
    let me: String
    private var c: FakeConnection?
    private var answered: Set<String> = []
    /// convs frames the SDK sent during the last `event` or `advance`.
    var fetches = 0

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
        throw VectorError(description: "the SDK keeps sending sync")
    }

    /// Answers the convs the SDK sent for the mention counts in this step (F-MEN-03 rule 1). Returns how many.
    private func answerConvs(_ st: JSONValue) async throws -> Int {
        var n = 0
        for _ in 0..<10 {
            let open = c!.frames("convs").filter { !answered.contains($0.id ?? "") }
            if open.isEmpty { return n }
            for f in open {
                answered.insert(f.id ?? "")
                n += 1
                guard let convs = st["convs"]?.arrayValue else {
                    throw VectorError(description: "step \(st["op"]!) has no convs reply but the SDK fetched convs")
                }
                c!.receive([
                    "id": .string(f.id ?? ""), "cmd": "ack",
                    "data": ["convs": .array(convs.map(wireConv)), "truncated": false],
                ])
            }
            await settle()
        }
        throw VectorError(description: "the SDK keeps sending convs")
    }

    /// Runs one step; returns the synced conversations for `connect`, `event` and `advance`.
    func step(_ st: JSONValue) async throws -> [String]? {
        fetches = 0
        switch st["op"]!.stringValue! {
        case "connect":
            let prev = c
            if prev == nil {
                h.im.connect(token: "token-value")
            } else {
                h.clock.advance(1_000)  // The first backoff, then the reconnect.
                await settle()
            }
            c = await h.login(me, convs: (st["convs"]?.arrayValue ?? []).map(wireConv))
            if let prev, prev === c { throw VectorError(description: "a reconnect should be a new connection") }
            for f in c!.frames("convs") { answered.insert(f.id ?? "") }  // login answered this connection's convs.
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
        case "event":
            c!.receive(["cmd": "event", "data": st["event"]!])
            await settle()
            fetches = try await answerConvs(st)
            return try await drain { _ in .success([]) }
        case "advance":
            h.clock.advance(st["ms"]!.intValue!)
            await settle()
            fetches = try await answerConvs(st)
            return try await drain { _ in .success([]) }
        case let op:
            throw VectorError(description: "unknown op \(op)")
        }
    }
}

/// Every file in a directory (the database and its journal), as raw bytes: whether one holds `needle`.
func filesContaining(_ dir: URL, _ needle: String) -> [String] {
    let bytes = Data(needle.utf8)
    let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return names.filter { (try? Data(contentsOf: $0))?.range(of: bytes) != nil }.map(\.lastPathComponent)
}

/// The TC of an AC (docs/testcases): C4 cases are TC-CHAT-90-33 plus their own TC, C2 cases TC-CHAT-90-13.
private let tcOfAc = [
    "AC-FILE-06-12": "TC-FILE-06-11", "AC-RCL-03-11": "TC-RCL-03-11", "AC-RCL-03-13": "TC-RCL-03-13",
    "AC-QUO-02-2": "TC-QUO-02-02", "AC-QUO-02-6": "TC-QUO-02-06", "AC-MEN-03-7": "TC-MEN-03-07",
]

private func tcOf(_ acs: [String]) -> String {
    let c4 = acs.contains { $0.hasPrefix("AC-QUO-") || $0.hasPrefix("AC-MEN-") || $0 == "AC-RCL-03-13" }
    return ([c4 ? "TC-CHAT-90-33" : "TC-CHAT-90-13"] + acs.map { tcOfAc[$0] ?? $0 }).joined(separator: " ")
}

private let marks = ["ZXQ-FILE-NAME", "ZXQ-RCL-2", "ZXQ-QUO-1"]

@MainActor
final class ChatSyncVectorTests: IMTestCase {
    private var dirs: [URL] = []

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        try await super.tearDown()
    }

    private var cases: [JSONValue] {
        get throws { try loadJSON("vectors/chat-sync.json")["cases"]!.arrayValue! }
    }

    func testTC_CHAT_90_13_casesCoverModVerChangedUnchangedOldServerFailureUnloadedAndLateAnswers() throws {
        let cases = try cases
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        let ops = Set(cases.flatMap { $0["steps"]!.arrayValue!.map { $0["op"]!.stringValue! } })
        XCTAssertTrue(ops.isSuperset(of: ["connect", "disconnect", "load"]), "\(ops)")
    }

    func testTC_CHAT_90_33_c4CasesArePresent() throws {
        let cases = try cases
        let acs = Set(cases.flatMap { $0["acs"]!.arrayValue!.map { $0.stringValue! } })
        for ac in ["AC-RCL-03-13", "AC-QUO-02-2", "AC-QUO-02-6", "AC-MEN-03-7"] { XCTAssertTrue(acs.contains(ac), ac) }
        let withEvents = cases.filter { c in
            c["steps"]!.arrayValue!.contains { ["event", "advance"].contains($0["op"]!.stringValue!) }
        }
        XCTAssertEqual(withEvents.count, 4)
        XCTAssertEqual(cases.count, 13)  // C2's 7 + C4's 6
        let ops = Set(cases.flatMap { $0["steps"]!.arrayValue!.map { $0["op"]!.stringValue! } })
        XCTAssertEqual(ops, ["connect", "disconnect", "load", "event", "advance"])
    }

    /// One case; `dir` set runs it on a real SQLite file. Returns failures as text, so all cases run.
    private func run(_ c: JSONValue, me: String, dir: URL?) async -> [String] {
        var problems: [String] = []
        let h = setup(directory: dir, heartbeatMs: 10 * 365 * DAY)
        let r = ChatSyncRunner(h, me: me)
        let steps = c["steps"]!.arrayValue!
        for (i, st) in steps.enumerated() {
            let op = st["op"]!.stringValue!
            let at = "step \(i) \(op)"
            let events0 = h.events.count
            let syncs: [String]?
            do {
                syncs = try await r.step(st)
            } catch {
                problems.append("\(at): \(error)")
                break
            }
            guard let want = st["expect"] else { continue }
            if let ws = want["syncs"] {
                if strs(syncs ?? ["<not a connect>"]) != ws { problems.append("\(at): syncs \(syncs ?? []) != \(ws)") }
            } else if op == "event" || op == "advance", syncs != [] {
                problems.append("\(at): syncs \(syncs ?? [])")
            }
            let expired = h.events[events0...].flatMap { e -> [String] in
                if case .filesExpired(let ids) = e { return ids } else { return [] }
            }
            if strs(expired.sorted()) != want["filesExpired"]! { problems.append("\(at): filesExpired \(expired)") }
            guard case .object(let messages)? = want["messages"] else {
                problems.append("\(at): no messages in expect")
                continue
            }
            for (convId, w) in messages {
                let got = JSONValue.array(h.im.messages(convId).map(view))
                let wanted = JSONValue.array((w.arrayValue ?? []).map(normalize))
                if got != wanted { problems.append("\(at): \(convId)\n  got  \(got.jsonString())\n  want \(wanted.jsonString())") }
            }
            if let n = want["convsFetches"]?.intValue, Int64(r.fetches) != n {
                problems.append("\(at): convsFetches \(r.fetches) != \(n)")
            }
            if case .object(let mu)? = want["mentionUnread"] {
                var got: [String: JSONValue] = [:]
                for v in h.im.conversations() { if let n = v.mentionUnread { got[v.convId] = .int(n) } }
                if JSONValue.object(got) != .object(mu) { problems.append("\(at): mentionUnread \(got) != \(mu)") }
            }
        }
        // Expired names, recalled text and quoted text stay out of memory and the database (F-FILE-06 rule 3, F-RCL-03
        // rule 3, F-QUO-02 rule 4): a marker the last expectation does not show is nowhere in the SDK or the file.
        let last = steps.last(where: { $0["expect"] != nil })?["expect"]?.jsonString() ?? ""
        let gone = marks.filter { !last.contains($0) }
        for mark in gone {
            if holds(h.im.debugExport(), mark) { problems.append("\(mark) is still in memory (debugExport)") }
            if holds(h.im.store, mark) { problems.append("\(mark) is still in the store") }
        }
        h.im.close()
        if let dir {
            for mark in gone where !filesContaining(dir, mark).isEmpty {
                problems.append("\(mark) is still in the database files \(filesContaining(dir, mark))")
            }
        }
        return problems
    }

    /// F-RCL-03 rules 2, 2a (monotonic merge, modVer re-sync), F-QUO-02 rule 4, F-MEN-03 rule 1: all 13 cases, in memory
    /// and on SQLite.
    func testChatSyncVectors() async throws {
        let spec = try loadJSON("vectors/chat-sync.json")
        let me = spec["self"]!.stringValue!
        var ran = 0
        for c in try cases {
            let name = "\(tcOf(c["acs"]!.arrayValue!.map { $0.stringValue! })) \(c["name"]!.stringValue!)"
            for disk in [false, true] {
                var dir: URL?
                if disk {
                    let d = FileManager.default.temporaryDirectory.appendingPathComponent("chat-sync-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                    dirs.append(d)
                    dir = d
                }
                let problems = await run(c, me: me, dir: dir)
                for p in problems { XCTFail("\(name) [\(disk ? "SQLite" : "memory")]: \(p)") }
                ran += 1
            }
        }
        XCTAssertEqual(ran, 26)
        print("chat-sync.json: \(ran / 2) cases x (memory, SQLite)")
    }
}
