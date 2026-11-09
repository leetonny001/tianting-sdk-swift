import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// TC-CHAT-90-13 (AC-CHAT-90-15): account-session.json `attachmentCases`, the attachment send state machine (PRD-chat
// F-FILE-07 rules 1, 3, 4). The real IMClient + FileClient + AccountClient, fake HTTP, fake object store, FakeTransport
// and a fake clock. Unlike sdk-ts, the `persistence: true` cases (cold start) run too: `restart` closes the client
// without logging out and builds a new one on the same local database and sandbox.

private let AB = "c2c:\(USER):bob"
private let UPLOADS = "/v1/files/uploads"

private func presigned(_ key: String) -> JSONValue {
    ["url": .string("https://s3.test/chat/tmp/\(key)"), "headers": [:], "expiresAt": 1]
}

@MainActor
private final class AttachmentRunner {
    let test: AttachmentVectorTests
    let start: JSONValue
    var h: AccountHarness
    /// Every harness of this case (a restart adds one): uploads and sends are counted across all of them.
    var all: [AccountHarness]
    var cid = ""
    private var kind = "image"
    private var produce: CheckedContinuation<ProcessedImage, Error>?
    /// Whether the current client has connected (the first `connect` after a restart dials, later ones reconnect).
    private var dialed = true

    init(_ test: AttachmentVectorTests, start: JSONValue) async {
        self.test = test
        self.start = start
        h = test.newHarness()
        all = [h]
        h.session(1, DAY)
        _ = await h.online()
    }

    private func uploads() -> Int { all.reduce(0) { $0 + $1.http.to(UPLOADS).count } }

    private func sends() -> [SentFrame] {
        all.flatMap { $0.transport.connections.flatMap { $0.frames("send") } }
    }

    private var message: Message? { h.im.messages(AB).first { $0.clientMsgId == cid } }

    private func uploadOk(_ fileId: String) async {
        let thumb = kind == "image"
        var o: [String: JSONValue] = ["fileId": .string(fileId), "put": presigned("\(fileId)-o")]
        if thumb { o["thumbPut"] = presigned("\(fileId)-t") }
        h.http.to(UPLOADS).last!.respond(200, .object(o))
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        if thumb {
            h.objectStore.pending[0].respond(200)
            await settle()
        }
        var done: [String: JSONValue] = ["fileId": .string(fileId), "size": 1000]
        if thumb {
            done["mime"] = "image/jpeg"
            done["width"] = 40
            done["height"] = 30
        } else {
            done["mime"] = "application/pdf"
        }
        h.http.last("/v1/files/\(fileId)/complete").respond(200, .object(done))
        await settle()
    }

    func run(_ st: JSONValue) async throws -> [String: JSONValue] {
        let uploads0 = uploads()
        let sends0 = sends().count
        let op = st["op"]!.stringValue!
        switch op {
        case "pick":
            if let foreign = start["foreignFileId"]?.stringValue, !foreign.isEmpty {
                // There is no public path to such a message yet (forwarding comes later): a failed image carrying
                // somebody else's fileId, no source, never uploaded here.
                cid = "forwarded-0001"
                h.im.store.list(AB).addLocal(
                    Message(
                        clientMsgId: cid, msgId: nil, seq: nil, convId: AB, from: USER, type: .image,
                        body: MsgBody(image: ImageBody(fileId: foreign, width: 10, height: 10, size: 100, mime: "image/jpeg")),
                        ts: 1, status: .failed, error: .timeout, deleted: nil, deletedAt: nil))
                h.im.emitMessages(AB)
            } else if start["kind"]?.stringValue == "file" {
                kind = "file"
                cid = try h.im.sendFile(
                    AB, FileInput(file: test.makeInput("a.pdf", size: 10), name: "a.pdf", mime: "application/pdf")
                ).clientMsgId
            } else if start["processing"] == .bool(true) {
                cid = try h.im.sendImage(AB, process: { try await withCheckedThrowingContinuation { self.produce = $0 } })
                    .clientMsgId
            } else {
                cid = try h.im.sendImage(AB, test.image()).clientMsgId
            }
            await settle()
        case "processed":
            produce!.resume(returning: test.image())
            produce = nil
            await settle()
        case "uploadOk":
            await uploadOk(st["fileId"]!.stringValue!)
        case "uploadFailed":
            var o: [String: JSONValue] = ["fileId": "F-FAIL", "put": presigned("F-FAIL-o")]
            if kind == "image" { o["thumbPut"] = presigned("F-FAIL-t") }
            h.http.to(UPLOADS).last!.respond(200, .object(o))
            await settle()
            h.objectStore.pending[0].fail()
            await settle()
        case "sendAck":
            h.transport.current.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 9])
            await settle()
        case "sendError":
            h.transport.current.ackError("send", Int(st["code"]!.intValue!))
            await settle()
        case "sendTimeout":
            h.clock.advance(10_000)
            await settle()
        case "disconnect":
            h.transport.current.drop(1006)
            await settle()
        case "connect":
            if dialed {
                await settle()
                h.clock.advance(1_000)  // The first backoff.
                await settle()
                _ = await h.base.login(USER)
            } else {
                _ = await h.online()
                dialed = true
            }
            await settle()
        case "retry":
            h.im.retry(AB, cid)
            await settle()
        case "dropSource":
            let src = h.im.sources[cid]
            XCTAssertNotNil(src, "dropSource: no source for \(cid)")
            for name in [src?.original, src?.thumb].compactMap({ $0 }) {
                try FileManager.default.removeItem(at: h.im.sandboxFile(name))
            }
        case "restart":
            h.im.close()  // The process ends: no logout, the local database and sandbox stay.
            h = test.newHarness()
            all.append(h)
            h.session(1, DAY)
            h.im.restoreCache(userId: USER)
            dialed = false
            await settle()
        default:
            throw NSError(domain: "attachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown op \(op)"])
        }
        guard let m = message else {
            throw NSError(domain: "attachment", code: 2, userInfo: [NSLocalizedDescriptionKey: "message \(cid) is gone"])
        }
        let sent = Array(sends()[sends0...])
        var out: [String: JSONValue] = [
            "state": .string(m.status.rawValue),
            "fileId": .string(m.body.image?.fileId ?? m.body.file?.fileId ?? ""),
            "uploads": .int(Int64(uploads() - uploads0)),
            "sends": .array(sent.map { f in f.data?["body"]?["image"]?["fileId"] ?? f.data?["body"]?["file"]?["fileId"] ?? "" }),
            "clientMsgIds": .array(sent.map { $0.data?["clientMsgId"] ?? .null }),
        ]
        if let e = m.error {
            if case .code(let code) = e { out["error"] = .int(Int64(code)) } else { out["error"] = .string(e.description) }
        }
        return out
    }
}

@MainActor
final class AttachmentVectorTests: IMTestCase {
    private var root: URL!
    private var accounts: [AccountHarness] = []

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inputs"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Every request matches http-client.schema.json (frames are checked by IMTestCase).
        for h in accounts { XCTAssertEqual(h.badRequests, []) }
        accounts = []
        try await super.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private var caseDir: URL!

    /// A client on this case's local database and sandbox. Each one has its own fake clock and fakes.
    func newHarness() -> AccountHarness {
        let base = setup(
            clock: FakeClock(start: accountStart), directory: caseDir.appendingPathComponent("db"),
            heartbeatMs: 10 * 365 * DAY, scratch: caseDir.appendingPathComponent("scratch"))
        let h = AccountHarness(base: base)
        accounts.append(h)
        return h
    }

    func makeInput(_ name: String, size: Int) -> URL {
        let u = root.appendingPathComponent("inputs").appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? Data(repeating: 7, count: size).write(to: u)
        return u
    }

    func image() -> ProcessedImage {
        ProcessedImage(
            original: LocalUpload(file: makeInput("o", size: 1000), mime: "image/jpeg"),
            thumb: LocalUpload(file: makeInput("t", size: 100), mime: "image/jpeg"), width: 40, height: 30)
    }

    func testAttachmentCases() async throws {
        let spec = try loadJSON("vectors/account-session.json")
        let cases = spec["attachmentCases"]!.arrayValue!
        XCTAssertGreaterThanOrEqual(cases.count, 11)
        let ops = Set(cases.flatMap { $0["steps"]!.arrayValue!.map { $0["op"]!.stringValue! } })
        for op in ["pick", "processed", "uploadOk", "uploadFailed", "sendError", "sendTimeout", "retry", "dropSource", "restart"] {
            XCTAssertTrue(ops.contains(op), "no case uses \(op)")
        }
        XCTAssertTrue(cases.contains { $0["start"]?["foreignFileId"]?.stringValue?.isEmpty == false })
        var ran = 0
        var persistent = 0
        for (n, c) in cases.enumerated() {
            let name = c["name"]!.stringValue!
            caseDir = root.appendingPathComponent("case\(n)")
            let r = await AttachmentRunner(self, start: c["start"]!)
            for (i, st) in c["steps"]!.arrayValue!.enumerated() {
                let at = "\(name) step \(i) \(st["op"]!.stringValue!)"
                var got: [String: JSONValue]
                do {
                    got = try await r.run(st)
                } catch {
                    XCTFail("\(at): \(error)")
                    break
                }
                // Every send carries the message's original clientMsgId.
                for id in got.removeValue(forKey: "clientMsgIds")?.arrayValue ?? [] {
                    XCTAssertEqual(id, .string(r.cid), "\(at): clientMsgId changed")
                }
                guard case .object(let want)? = st["expect"] else { continue }
                if want["error"] == nil { got["error"] = nil }  // Compared only when written.
                XCTAssertEqual(JSONValue.object(got), JSONValue.object(want), at)
            }
            for h in r.all { h.im.close() }
            ran += 1
            if c["persistence"] == .bool(true) { persistent += 1 }
        }
        XCTAssertEqual(ran, cases.count)
        XCTAssertGreaterThanOrEqual(persistent, 2)
        print("attachmentCases: \(ran) cases, \(persistent) with persistence")
    }
}
