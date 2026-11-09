import Foundation
import SQLite3
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-632: images and files (PRD-chat F-FILE-01, 03, 04, 06, 07; F-RCL-03 rules 2, 2a). Fake HTTP + fake object store +
// FakeTransport + fake clock; test names carry the TC-FILE number. Local `swift test` results (macOS), CI not running.

private let AB = "c2c:\(USER):bob"
private let G1 = "group:g1"
private let UPLOADS = "/v1/files/uploads"
private let URLS = "/v1/files/urls"
private let SIG = "X-Amz-Signature=deadbeef"
private let SECRET_NAME = "ZXQ-FILE-NAME.pdf"

private func put(_ key: String) -> JSONValue {
    [
        "url": .string("https://s3.test/chat/tmp/\(key)?\(SIG)"),
        "headers": ["Content-Type": "image/jpeg", "Content-Length": "1000"],
        "expiresAt": 1,
    ]
}

@MainActor
class FileTestCase: AccountTestCase {
    var inputs: URL!

    override func setUp() async throws {
        try await super.setUp()
        inputs = FileManager.default.temporaryDirectory.appendingPathComponent("tt-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: inputs)
        try await super.tearDown()
    }

    /// A file the app produced.
    func makeFile(_ name: String, size: Int, byte: UInt8 = 7) -> URL {
        let u = inputs.appendingPathComponent(name)
        try? Data(repeating: byte, count: size).write(to: u)
        return u
    }

    func image(_ n: Int = 1) -> ProcessedImage {
        ProcessedImage(
            original: LocalUpload(file: makeFile("o\(n)-\(UUID().uuidString)", size: 1000 * n), mime: "image/jpeg"),
            thumb: LocalUpload(file: makeFile("t\(n)-\(UUID().uuidString)", size: 100), mime: "image/jpeg"),
            width: 4000, height: 3000)
    }

    func online() async -> (AccountHarness, FakeConnection) {
        let h = setupAccount()
        h.session(1, DAY)
        let c = await h.online()
        return (h, c)
    }

    func status(_ h: AccountHarness, _ convId: String = AB) -> [String] {
        h.im.messages(convId).map { m in
            "\(m.clientMsgId):\(m.status.rawValue)\(m.error.map { "(\($0))" } ?? "")\(m.seq.map { "#\($0)" } ?? "")"
        }
    }

    func grant(_ h: AccountHarness, _ fileId: String, thumb: Bool = true) {
        var o: [String: JSONValue] = ["fileId": .string(fileId), "put": put("\(fileId)-o")]
        if thumb { o["thumbPut"] = put("\(fileId)-t") }
        h.http.to(UPLOADS).last!.respond(200, .object(o))
    }

    func completeOk(_ h: AccountHarness, _ fileId: String, size: Int64 = 1000) {
        h.http.last("/v1/files/\(fileId)/complete").respond(
            200, ["fileId": .string(fileId), "size": .int(size), "mime": "image/jpeg", "width": 4000, "height": 3000])
    }

    /// Ask -> PUT original (and thumbnail) -> complete.
    func uploadOk(_ h: AccountHarness, _ fileId: String, thumb: Bool = true) async {
        await settle()
        grant(h, fileId, thumb: thumb)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        if thumb {
            h.objectStore.pending[0].respond(200)
            await settle()
        }
        completeOk(h, fileId)
        await settle()
    }

    func sandbox(_ h: AccountHarness) -> [String] {
        let dir = h.base.scratch.appendingPathComponent("attachments")
        guard let users = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return users.flatMap { u in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(u).path)) ?? []).sorted()
        }
    }

    func deletes(_ h: AccountHarness) -> [String] {
        h.http.calls.filter { $0.request.method == .delete }.map(\.path)
    }

    /// AC-FILE-04-11: no presigned URL, signature or file name in the logs.
    func assertCleanLogs(_ h: AccountHarness, file: StaticString = #filePath, line: UInt = #line) {
        let all = h.logs.all.joined(separator: "\n")
        XCTAssertFalse(all.contains("X-Amz"), file: file, line: line)
        XCTAssertFalse(all.contains("s3.test"), file: file, line: line)
        XCTAssertFalse(all.contains("ZXQ-FILE"), file: file, line: line)
    }
}

@MainActor
final class FileSendTests: FileTestCase {
    // F-FILE-07 rule 1
    func testProcessingUploadingQueuedSendingSent() async throws {
        let (h, c) = await online()
        var produce: CheckedContinuation<ProcessedImage, Error>?
        let progress = ProgressBox()
        let img = image()
        let m = try h.im.sendImage(AB, process: { try await withCheckedThrowingContinuation { produce = $0 } }, onProgress: { s, t in progress.add(s, t) })
        XCTAssertEqual(m.status, .processing)
        await settle()
        XCTAssertEqual(h.http.to(UPLOADS).count, 0)
        produce!.resume(returning: img)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:uploading"])
        XCTAssertEqual(h.im.messages(AB)[0].body.image, ImageBody(fileId: "", width: 4000, height: 3000, size: 1000, mime: "image/jpeg"))
        XCTAssertEqual(
            h.http.last(UPLOADS).json,
            ["kind": "image", "name": "image", "size": 1000, "mime": "image/jpeg", "thumb": ["size": 100, "mime": "image/jpeg"]])
        XCTAssertEqual(h.http.last(UPLOADS).bearer, jwt("sid1", 1))
        // The SDK uploads its own sandbox copies, never the app's files.
        XCTAssertEqual(sandbox(h), ["cid-0001-original", "cid-0001-thumb"])
        grant(h, "F1")
        await settle()
        XCTAssertEqual(h.objectStore.calls.count, 1)  // One at a time: the thumbnail after the original.
        let p0 = h.objectStore.calls[0]
        XCTAssertTrue(p0.url.contains("F1-o"))
        XCTAssertEqual(p0.method, "PUT")
        XCTAssertEqual(p0.headers, ["Content-Type": "image/jpeg", "Content-Length": "1000"])
        XCTAssertNotEqual(p0.file.path, img.original.file.path)
        XCTAssertEqual(p0.size, 1000)
        p0.progress(500)
        p0.respond(200)
        await settle()
        XCTAssertTrue(h.objectStore.calls[1].url.contains("F1-t"))
        h.objectStore.calls[1].respond(200)
        await settle()
        XCTAssertEqual(progress.all, [[500, 1100], [1000, 1100], [1100, 1100]])
        XCTAssertEqual(c.frames("send").count, 0)
        h.http.last("/v1/files/F1/complete").respond(
            200, ["fileId": "F1", "size": 990, "mime": "image/jpeg", "width": 4000, "height": 3000])
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:sending"])
        XCTAssertEqual(
            c.last("send")?.data,
            ["convType": "c2c", "to": "bob", "clientMsgId": "cid-0001", "type": "image", "body": ["image": ["fileId": "F1"]]])
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 9])
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:sent#1"])
        XCTAssertEqual(h.im.messages(AB)[0].body.image, ImageBody(fileId: "F1", width: 4000, height: 3000, size: 990, mime: "image/jpeg"))
        XCTAssertEqual(h.im.conversations()[0].lastMsg?.type, "image")
        XCTAssertEqual(sandbox(h), [])  // Sent: the sandbox copies are deleted (F-FILE-07 rule 2).
        XCTAssertTrue(FileManager.default.fileExists(atPath: img.original.file.path))  // The app's file is untouched.
        assertCleanLogs(h)
    }

    // F-FILE-07 rule 8
    func testUploadTimeDoesNotCountTowardTheSendTimeout() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.clock.advance(60_000)  // A slow PUT: a minute and still going.
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:uploading"])
        h.objectStore.pending[0].respond(200)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        completeOk(h, "F1")
        await settle()
        h.clock.advance(9_999)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:sending"])
        h.clock.advance(1)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(timeout)"])
        XCTAssertEqual(c.frames("send").count, 1)
    }

    func testSendFileKindFileNoThumbNameOnlyInTheBody() async throws {
        let (h, c) = await online()
        try h.im.sendFile(G1, FileInput(file: makeFile("doc", size: 5000), name: SECRET_NAME, mime: "application/pdf"))
        await settle()
        XCTAssertEqual(h.http.last(UPLOADS).json, ["kind": "file", "name": .string(SECRET_NAME), "size": 5000, "mime": "application/pdf"])
        grant(h, "F9", thumb: false)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        XCTAssertEqual(h.objectStore.calls.count, 1)
        h.http.last("/v1/files/F9/complete").respond(200, ["fileId": "F9", "size": 5000, "mime": "application/pdf"])
        await settle()
        XCTAssertEqual(c.last("send")?.data?["type"], "file")
        XCTAssertEqual(c.last("send")?.data?["body"], ["file": ["fileId": "F9"]])
        c.ack("send", ["msgId": "m1", "convId": .string(G1), "seq": 1, "ts": 9])
        await settle()
        XCTAssertEqual(h.im.messages(G1)[0].body.file, FileBody(fileId: "F9", name: SECRET_NAME, size: 5000, mime: "application/pdf"))
        assertCleanLogs(h)
    }

    func testProcessingFailureFailsWithProcess() async throws {
        let (h, _) = await online()
        try h.im.sendImage(AB, process: { throw URLError(.cannotDecodeContentData) })
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(process)"])
        XCTAssertEqual(h.http.to(UPLOADS).count, 0)
        XCTAssertTrue(h.base.events.contains { if case .sendFailed(_, _, .process) = $0 { return true } else { return false } })
    }

    func testCopyFailureFailsWithStorage() async throws {
        let (h, _) = await online()
        let gone = inputs.appendingPathComponent("missing")
        try h.im.sendFile(AB, FileInput(file: gone, name: "a.txt"))
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(storage)"])
        XCTAssertEqual(h.http.to(UPLOADS).count, 0)
    }

    // F-FILE-07 rule 3 (in one session)
    func testCompletedWhileDisconnectedQueuesAndSendsOnceAfterReconnect() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        c.drop(1006)
        completeOk(h, "F1")
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:queued"])
        h.clock.advance(1_000)
        await settle()
        let c2 = await h.base.login(USER)
        XCTAssertEqual(c2.last("send")?.data?["clientMsgId"], "cid-0001")
        XCTAssertEqual(c2.last("send")?.data?["body"], ["image": ["fileId": "F1"]])
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[Int64]] = []
    func add(_ a: Int64, _ b: Int64) {
        lock.lock()
        items.append([a, b])
        lock.unlock()
    }
    var all: [[Int64]] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@MainActor
final class FileFailureTests: FileTestCase {
    // TC-FILE-01-12 (AC-FILE-01-12)
    func testTC_FILE_01_12_quotaFailsOnceNoRetry() async throws {
        let (h, _) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        h.http.last(UPLOADS).respondError(429, 4292)
        await settle()
        h.clock.advance(5_000)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(4292)"])
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        let failures = h.base.events.filter { if case .sendFailed = $0 { return true } else { return false } }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(sandbox(h).count, 2)  // Failed: the copy stays for a manual resend.
    }

    // TC-FILE-01-17 (AC-FILE-01-17)
    func testTC_FILE_01_17_pendingLimitNoRetryAndCancelSendsDelete() async throws {
        let (h, c) = await online()
        try h.im.sendFile(AB, FileInput(file: makeFile("a", size: 10), name: "a.txt", mime: "text/plain"))
        await settle()
        h.http.last(UPLOADS).respondError(429, 4290, reason: "uploadPendingLimit")
        await settle()
        h.clock.advance(5_000)
        await settle()
        let failed = h.im.messages(AB)[0]
        XCTAssertEqual(failed.error, .code(4290))
        XCTAssertEqual(failed.errorReason, "uploadPendingLimit")
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        let m = try h.im.sendFile(AB, FileInput(file: makeFile("b", size: 10), name: "b.txt", mime: "text/plain"))
        await settle()
        grant(h, "F2", thumb: false)
        await settle()
        XCTAssertEqual(h.objectStore.pending.count, 1)
        XCTAssertTrue(h.im.cancelUpload(AB, m.clientMsgId))
        await settle()
        XCTAssertTrue(h.objectStore.calls.last!.cancelled)
        XCTAssertEqual(deletes(h), ["/v1/files/uploads/F2"])
        XCTAssertEqual(h.im.messages(AB).map(\.clientMsgId), ["cid-0001"])
        XCTAssertEqual(c.frames("send").count, 0)
        XCTAssertEqual(sandbox(h), ["cid-0001-file"])  // The cancelled one's copy is gone, the failed one's stays.
    }

    // TC-FILE-02-05 (AC-FILE-02-5)
    func testTC_FILE_02_05_cancelMidPutRemovesTheMessageNoSend() async throws {
        let (h, c) = await online()
        let m = try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.objectStore.pending[0].progress(400)
        XCTAssertTrue(h.im.cancelUpload(AB, m.clientMsgId))
        await settle()
        XCTAssertEqual(h.im.messages(AB), [])
        XCTAssertEqual(deletes(h), ["/v1/files/uploads/F1"])
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(c.frames("send").count, 0)
        XCTAssertEqual(h.http.to("/v1/files/F1/complete").count, 0)
        XCTAssertEqual(h.im.pendingCount(), 0)
        XCTAssertEqual(sandbox(h), [])
    }

    func testCancelWhileProcessingDoesNotAskAndTheNextOneUploads() async throws {
        let (h, _) = await online()
        let m1 = try h.im.sendImage(AB, process: { try await withCheckedThrowingContinuation { (_: CheckedContinuation<ProcessedImage, Error>) in } })
        try h.im.sendImage(AB, image())
        await settle()
        XCTAssertEqual(h.http.to(UPLOADS).count, 0)
        XCTAssertTrue(h.im.cancelUpload(AB, m1.clientMsgId))
        await settle()
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        XCTAssertEqual(deletes(h), [])
    }

    // TC-FILE-07-02 (AC-FILE-07-2)
    func testTC_FILE_07_02_sendTimeoutRetryReusesTheFileId() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await uploadOk(h, "F1")
        h.clock.advance(10_000)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(timeout)"])
        h.im.retry(AB, "cid-0001")
        await settle()
        let sends = c.frames("send")
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[1].data, sends[0].data)
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        XCTAssertEqual(h.objectStore.calls.count, 2)
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 9])
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:sent#1"])
    }

    // TC-FILE-07-04 (AC-FILE-07-4)
    func testTC_FILE_07_04_textPassesImagesKeepPickOrderOneAtATime() async throws {
        let (h, c) = await online()
        for n in 1...3 { try h.im.sendImage(AB, image(n)) }
        await settle()
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        _ = try h.im.send(AB, "先到")
        XCTAssertEqual(c.last("send")?.data?["type"], "text")
        c.ack("send", ["msgId": "t", "convId": .string(AB), "seq": 1, "ts": 1])
        await settle()
        XCTAssertEqual(status(h)[0], "cid-0004:sent#1")
        for (i, id) in ["F1", "F2", "F3"].enumerated() {
            XCTAssertEqual(h.http.to(UPLOADS).count, i + 1)
            XCTAssertEqual(h.http.last(UPLOADS).json["size"], .int(Int64(1000 * (i + 1))))
            XCTAssertLessThanOrEqual(h.objectStore.pending.count, 1)
            await uploadOk(h, id)
            XCTAssertEqual(c.last("send")?.data?["clientMsgId"], .string("cid-000\(i + 1)"))
            c.ack("send", ["msgId": .string("m\(id)"), "convId": .string(AB), "seq": .int(Int64(i + 2)), "ts": .int(Int64(2 + i))])
            await settle()
        }
        XCTAssertEqual(status(h), ["cid-0004:sent#1", "cid-0001:sent#2", "cid-0002:sent#3", "cid-0003:sent#4"])
    }

    // TC-FILE-07-07 (AC-FILE-07-7)
    func testTC_FILE_07_07_fivePutFailuresNeverComplete() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        for i in 1...5 {
            await settle()
            grant(h, "F\(i)")
            await settle()
            h.objectStore.pending[0].fail()
            await settle()
            XCTAssertEqual(status(h), ["cid-0001:failed(network)"])
            if i < 5 { h.im.retry(AB, "cid-0001") }
        }
        XCTAssertEqual(h.http.to(UPLOADS).count, 5)
        XCTAssertEqual(h.http.calls.filter { $0.path.hasSuffix("/complete") }.count, 0)  // Only a complete charges quota.
        XCTAssertEqual(deletes(h).count, 5)
        XCTAssertEqual(c.frames("send").count, 0)
    }

    func testRefusedPut403FailsAsNetwork() async throws {
        let (h, _) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.objectStore.pending[0].respond(403)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(network)"])
    }

    private func toComplete(_ h: AccountHarness) async throws {
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
    }

    // F-FILE-07 exceptions: complete 5032
    func testComplete5032BacksOffThreeTimesThenFails() async throws {
        let (h, _) = await online()
        try await toComplete(h)
        let complete = { h.http.to("/v1/files/F1/complete") }
        for (i, wait) in [Int64(1_000), 2_000, 4_000].enumerated() {
            complete().last!.respondError(503, 5032, reason: "completeInProgress")
            await settle()
            h.clock.advance(wait - 1)
            await settle()
            XCTAssertEqual(complete().count, i + 1)
            h.clock.advance(1)
            await settle()
            XCTAssertEqual(complete().count, i + 2)
        }
        complete().last!.respondError(503, 5032)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(5032)"])
        h.clock.advance(60_000)
        await settle()
        XCTAssertEqual(complete().count, 4)
    }

    func testComplete5032ThenSuccessSends() async throws {
        let (h, c) = await online()
        try await toComplete(h)
        h.http.last("/v1/files/F1/complete").respondError(503, 5032)
        await settle()
        h.clock.advance(1_000)
        await settle()
        completeOk(h, "F1")
        await settle()
        XCTAssertEqual(c.frames("send").count, 1)
    }

    func testComplete4096FailsWithoutRetry() async throws {
        let (h, _) = await online()
        try await toComplete(h)
        h.http.last("/v1/files/F1/complete").respondError(409, 4096)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(4096)"])
    }

    // TC-FILE-07-10 (AC-FILE-07-10, RC2-23)
    func testTC_FILE_07_10_send4096UploadsAgainFromTheSandbox() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await uploadOk(h, "F1")
        c.ackError("send", 4096)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:uploading"])
        XCTAssertEqual(h.im.messages(AB)[0].body.image?.fileId, "")
        await uploadOk(h, "F2")
        XCTAssertEqual(c.last("send")?.data?["clientMsgId"], "cid-0001")
        XCTAssertEqual(c.last("send")?.data?["body"], ["image": ["fileId": "F2"]])
        // The 4096 round did not use the automatic resend: a drop still resends once.
        c.drop(1006)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:queued"])
        h.clock.advance(1_000)
        await settle()
        let c2 = await h.base.login(USER)
        XCTAssertEqual(c2.last("send")?.data?["clientMsgId"], "cid-0001")
    }

    func testTC_FILE_07_10_send4096WithoutTheSandboxCopyIsSourceMissing() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await uploadOk(h, "F1")
        try FileManager.default.removeItem(at: h.im.sandboxFile("cid-0001-original"))
        c.ackError("send", 4096)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(sourceMissing)"])
        h.im.retry(AB, "cid-0001")
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(sourceMissing)"])
        XCTAssertEqual(h.http.to(UPLOADS).count, 1)
        XCTAssertTrue(h.im.cancelUpload(AB, "cid-0001"))  // Delete only.
        XCTAssertEqual(h.im.messages(AB), [])
    }

    // TC-FILE-07-05 (AC-FILE-07-5, SDK part)
    func testTC_FILE_07_05_appFileDeletedRetryUsesTheSandboxCopy() async throws {
        let (h, c) = await online()
        let img = image()
        try h.im.sendImage(AB, img)
        await settle()
        grant(h, "F1")
        await settle()
        h.objectStore.pending[0].fail()
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(network)"])
        try FileManager.default.removeItem(at: img.original.file)  // Deleted from the photo library.
        try FileManager.default.removeItem(at: img.thumb.file)
        h.im.retry(AB, "cid-0001")
        await uploadOk(h, "F2")
        c.ack("send", ["msgId": "m1", "convId": .string(AB), "seq": 1, "ts": 9])
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:sent#1"])
        XCTAssertEqual(h.objectStore.puts.last?.size, 100)
        XCTAssertEqual(sandbox(h), [])
    }

    func testKickStopsTheUploadAndFails() async throws {
        let (h, c) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        c.receive(["cmd": "event", "data": ["type": "kicked", "reason": "banned"]])
        c.drop(4012)
        await settle()
        XCTAssertEqual(status(h), ["cid-0001:failed(kicked)"])
        XCTAssertTrue(h.objectStore.calls[0].cancelled)
        XCTAssertEqual(sandbox(h), [])
    }

    // TC-FILE-07-09 (AC-FILE-07-9, SDK part)
    func testTC_FILE_07_09_logoutClearsNineSandboxCopies() async throws {
        let (h, _) = await online()
        for n in 1...9 { try h.im.sendFile(AB, FileInput(file: makeFile("f\(n)", size: 10), name: "f\(n).txt")) }
        for _ in 1...9 {
            await settle()
            h.http.to(UPLOADS).last!.respondError(500, 5000)
            await settle()
        }
        XCTAssertEqual(h.im.messages(AB).filter { $0.status == .failed }.count, 9)
        XCTAssertEqual(sandbox(h).count, 9)
        h.im.disconnect()
        await settle()
        XCTAssertEqual(sandbox(h), [])
    }

    func testLogoutStopsAnUploadAndDeletes() async throws {
        let (h, _) = await online()
        try h.im.sendImage(AB, image())
        await settle()
        grant(h, "F1")
        await settle()
        h.im.disconnect()
        await settle()
        XCTAssertTrue(h.objectStore.calls[0].cancelled)
        XCTAssertEqual(deletes(h), ["/v1/files/uploads/F1"])
        XCTAssertEqual(h.im.messages(AB), [])
    }
}

@MainActor
final class FileUrlTests: FileTestCase {
    private func urlItem(_ fileId: String, _ variant: String, at: Int64) -> JSONValue {
        [
            "fileId": .string(fileId), "variant": .string(variant),
            "url": .string("https://s3.test/chat/final/\(fileId)/\(variant)?\(SIG)"), "expiresAt": .int(at),
        ]
    }

    // AC-FILE-04-10, F-FILE-04 rules 1, 6
    func testSixtyInOneTurnAreTwoBatchesThenCached() async throws {
        let (h, _) = await online()
        let items = (0..<60).map { FileUrlItem(fileId: "F\($0)", variant: .thumb) }
        let at = h.clock.now() + 120_000
        let p = Task { try await h.im.getFileUrls(Array(items[0..<30])) }
        let q = Task { try await h.im.getFileUrls(Array(items[30...])) }
        await settle()
        let calls = h.http.to(URLS)
        XCTAssertEqual(calls.map { $0.json["items"]?.arrayValue?.count }, [50, 10])
        calls[0].respond(200, ["items": .array(items[0..<50].map { urlItem($0.fileId, "thumb", at: at) })])
        calls[1].respond(
            200,
            [
                "items": .array(
                    items[50...].enumerated().map { k, i in
                        k == 0 ? ["fileId": .string(i.fileId), "variant": "thumb", "code": 4048] : urlItem(i.fileId, "thumb", at: at)
                    })
            ])
        let all = try await p.value + q.value
        XCTAssertTrue(all[0].url!.contains("F0"))
        XCTAssertEqual(all[50], FileUrlResult(fileId: "F50", variant: .thumb, code: 4048))
        let again = try await h.im.getFileUrls([items[1]])
        XCTAssertTrue(again[0].url!.contains("F1"))
        XCTAssertEqual(h.http.to(URLS).count, 2)
        XCTAssertFalse(String(describing: again[0]).contains("s3.test"))  // Printing never shows the URL.
        h.clock.advance(106_000)  // Under 15 seconds left: ask again.
        let t = Task { try await h.im.getFileUrls([items[1]]) }
        await settle()
        XCTAssertEqual(h.http.to(URLS).count, 3)
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "thumb", at: h.clock.now() + 120_000)]])
        _ = try await t.value
        assertCleanLogs(h)
    }

    func testTheSameItemTwiceAtOnceAsksOnce() async throws {
        let (h, _) = await online()
        let a = Task { try await h.im.getFileUrls([FileUrlItem(fileId: "F1", variant: .original)]) }
        let b = Task { try await h.im.getFileUrls([FileUrlItem(fileId: "F1", variant: .original)]) }
        await settle()
        XCTAssertEqual(h.http.to(URLS).count, 1)
        XCTAssertEqual(h.http.last(URLS).json["items"], [["fileId": "F1", "variant": "original"]])
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "original", at: h.clock.now() + 120_000)]])
        let ra = try await a.value
        let rb = try await b.value
        XCTAssertEqual(ra[0].url, rb[0].url)
    }

    // TC-ACC-03-42 with the real endpoint (AC-ACC-03-42)
    func testTC_ACC_03_42_inFlightUrls4011RetriesWithTheNewLocalToken() async throws {
        let (h, _) = await online()
        let p = Task { try await h.im.getFileUrls([FileUrlItem(fileId: "F1", variant: .thumb)]) }
        await settle()
        let first = h.http.last(URLS)
        XCTAssertEqual(first.bearer, jwt("sid1", 1))
        h.session(2, DAY)  // A refresh changed the token meanwhile.
        first.respondError(401, 4011, reason: "tokenSuperseded")
        await settle()
        let calls = h.http.to(URLS)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].bearer, jwt("sid1", 2))
        XCTAssertEqual(h.http.to(REFRESH).count, 0)
        calls[1].respond(200, ["items": [urlItem("F1", "thumb", at: h.clock.now() + 120_000)]])
        let r = try await p.value
        XCTAssertTrue(r[0].url!.contains("F1"))
    }

    // F-FILE-03 rule 3, AC-FILE-04-10 (cache), AC-FILE-03-5 (SDK part)
    func testDownloadCachesByFileIdAndVariant() async throws {
        let (h, _) = await online()
        let progress = ProgressBox()
        let t = Task { try await h.im.download(fileId: "F1", variant: .original, progress: { r, e in progress.add(r, e ?? -1) }) }
        await settle()
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "original", at: h.clock.now() + 300_000)]])
        await settle()
        XCTAssertEqual(h.objectStore.gets.count, 1)
        XCTAssertTrue(h.objectStore.gets[0].url.contains("F1/original"))
        h.objectStore.gets[0].respond(200, data: Data("PDF-BYTES".utf8))
        let url = try await t.value
        XCTAssertEqual(try Data(contentsOf: url), Data("PDF-BYTES".utf8))
        XCTAssertEqual(url.lastPathComponent, "4631-original")  // Cache names are hex of the fileId, never the URL.
        XCTAssertEqual(progress.all.last, [9, 9])
        // Second time: from the cache, no request at all.
        let again = try await h.im.download(fileId: "F1", variant: .original)
        XCTAssertEqual(again, url)
        XCTAssertEqual(h.http.to(URLS).count, 1)
        XCTAssertEqual(h.objectStore.gets.count, 1)
        XCTAssertEqual(h.im.cachedFile(fileId: "F1", variant: .original), url)
        XCTAssertNil(h.im.cachedFile(fileId: "F1", variant: .thumb))
    }

    // TC-FILE-03-05 (AC-FILE-03-5, SDK part)
    func testTC_FILE_03_05_brokenDownloadLeavesNothingRetryAsksANewUrlFromZero() async throws {
        let (h, _) = await online()
        let t = Task { try await h.im.download(fileId: "F1", variant: .original) }
        await settle()
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "original", at: h.clock.now() + 300_000)]])
        await settle()
        let partFile = h.objectStore.gets[0].file
        h.objectStore.gets[0].fail("offline", partial: Data("PARTIAL".utf8))
        do {
            _ = try await t.value
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .status(0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
        XCTAssertNil(h.im.cachedFile(fileId: "F1", variant: .original))
        let retry = Task { try await h.im.download(fileId: "F1", variant: .original) }
        await settle()
        XCTAssertEqual(h.http.to(URLS).count, 2)  // A new URL, not the cached one.
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "original", at: h.clock.now() + 300_000)]])
        await settle()
        h.objectStore.gets[1].respond(200, data: Data("FULL".utf8))
        let url = try await retry.value
        XCTAssertEqual(try Data(contentsOf: url), Data("FULL".utf8))
    }

    func testExpiredUrl403AsksOnceMore() async throws {
        let (h, _) = await online()
        let t = Task { try await h.im.download(fileId: "F1", variant: .thumb) }
        await settle()
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "thumb", at: h.clock.now() + 120_000)]])
        await settle()
        h.objectStore.gets[0].respond(403)
        await settle()
        XCTAssertEqual(h.http.to(URLS).count, 2)
        h.http.last(URLS).respond(200, ["items": [urlItem("F1", "thumb", at: h.clock.now() + 120_000)]])
        await settle()
        h.objectStore.gets[1].respond(403)
        do {
            _ = try await t.value
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .status(403))
        }
        XCTAssertEqual(h.http.to(URLS).count, 2)
    }

    func testDownloadOfAnInaccessibleFileThrows4048() async throws {
        let (h, _) = await online()
        let t = Task { try await h.im.download(fileId: "F1", variant: .thumb) }
        await settle()
        h.http.last(URLS).respond(200, ["items": [["fileId": "F1", "variant": "thumb", "code": 4048]]])
        do {
            _ = try await t.value
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .unavailable(code: 4048))
        }
        XCTAssertEqual(h.objectStore.gets.count, 0)
    }
}

@MainActor
final class FileExpiryTests: FileTestCase {
    private func img(_ convId: String, _ seq: Int64, _ fileId: String, expired: Bool = false) -> JSONValue {
        var m = msg(convId, seq)
        guard case .object(var o) = m else { return m }
        o["type"] = "image"
        var body: [String: JSONValue] = ["fileId": .string(fileId), "width": 10, "height": 10, "size": 100, "mime": "image/png"]
        if expired { body["expired"] = true }
        o["body"] = ["image": .object(body)]
        m = .object(o)
        return m
    }

    private func fileMsg(_ convId: String, _ seq: Int64, _ fileId: String, expired: Bool = false) -> JSONValue {
        guard case .object(var o) = msg(convId, seq) else { return nil }
        o["type"] = "file"
        var body: [String: JSONValue] = [
            "fileId": .string(fileId), "name": .string(expired ? "" : SECRET_NAME), "size": 100, "mime": "application/pdf",
        ]
        if expired { body["expired"] = true }
        o["body"] = ["file": .object(body)]
        return .object(o)
    }

    /// Account mode: the dial waits on the token provider, so let it run before and after the backoff.
    private func reconnect(_ h: AccountHarness) async -> FakeConnection {
        await settle()
        h.clock.advance(1_000)
        await settle()
        let c = h.transport.current
        c.open()
        c.ack("auth", ["userId": .string(USER), "serverTime": .int(h.clock.now())])
        await settle()
        return c
    }

    /// AB has F1 (image) and F2 (file), G1 has G1F; F1's thumbnail is downloaded and cached.
    private func loaded() async throws -> (AccountHarness, FakeConnection) {
        let h = setupAccount()
        h.session(1, DAY)
        h.im.connect(tokenProvider: h.account.tokenProvider)
        await settle()
        let c1 = await h.base.login(USER, convs: [conv(AB, maxSeq: 2, modVer: 3), conv(G1, maxSeq: 1, modVer: 7)])
        let l1 = Task { try await h.im.loadHistory(AB) }
        await settle()
        c1.ack("sync", ["messages": [img(AB, 1, "F1"), fileMsg(AB, 2, "F2")], "hasMore": false])
        _ = try await l1.value
        let l2 = Task { try await h.im.loadHistory(G1) }
        await settle()
        c1.ack("sync", ["messages": [img(G1, 1, "G1F")], "hasMore": false])
        _ = try await l2.value
        let d = Task { try await h.im.download(fileId: "F1", variant: .thumb) }
        await settle()
        h.http.last(URLS).respond(
            200,
            ["items": [["fileId": "F1", "variant": "thumb", "url": .string("https://s3.test/x?\(SIG)"), "expiresAt": .int(h.clock.now() + 120_000)]]])
        await settle()
        h.objectStore.gets[0].respond(200, data: Data("THUMB".utf8))
        _ = try await d.value
        return (h, c1)
    }

    // TC-FILE-06-11 (AC-FILE-06-12)
    func testTC_FILE_06_11_onlyTheChangedConversationResyncsAndCachesClear() async throws {
        let (h, c1) = try await loaded()
        XCTAssertNotNil(h.im.cachedFile(fileId: "F1", variant: .thumb))
        c1.drop(1006)
        let c2 = await reconnect(h)
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 2, modVer: 4), conv(G1, maxSeq: 1, modVer: 7)], "truncated": false])
        await settle()
        XCTAssertEqual(c2.frames("sync").map { $0.data?["convId"] }, [.string(AB)])
        c2.ack("sync", ["messages": [img(AB, 1, "F1", expired: true), fileMsg(AB, 2, "F2", expired: true)], "hasMore": false])
        await settle()
        let ms = h.im.messages(AB)
        XCTAssertEqual(ms[0].body.image?.expired, true)
        XCTAssertEqual(ms[1].body.file?.expired, true)
        XCTAssertEqual(ms[1].body.file?.name, "")
        let expiredEvents = h.base.events.compactMap { e -> [String]? in if case .filesExpired(let ids) = e { return ids } else { return nil } }
        XCTAssertEqual(Set(expiredEvents.flatMap { $0 }), ["F1", "F2"])
        XCTAssertNil(h.im.cachedFile(fileId: "F1", variant: .thumb))  // The local cache is cleared.
        // Known expired: no URL request (AC-FILE-06-6, SDK part), no download.
        let n = h.http.to(URLS).count
        let r = try await h.im.getFileUrls([FileUrlItem(fileId: "F1", variant: .thumb)])
        XCTAssertEqual(r, [FileUrlResult(fileId: "F1", variant: .thumb, code: 4048)])
        do {
            _ = try await h.im.download(fileId: "F2", variant: .original)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .unavailable(code: 4048))
        }
        XCTAssertEqual(h.http.to(URLS).count, n)
        // The URL cache forgot it as well: asking FileClient directly sends a request.
        let direct = Task { try await h.files.getFileUrls([FileUrlItem(fileId: "F1", variant: .thumb)]) }
        await settle()
        XCTAssertEqual(h.http.to(URLS).count, n + 1)
        h.http.last(URLS).respond(200, ["items": [["fileId": "F1", "variant": "thumb", "code": 4048]]])
        _ = try await direct.value
        // Reconnect again with the same modVer: nothing re-synced.
        c2.drop(1006)
        let c3 = await reconnect(h)
        c3.ack("convs", ["convs": [conv(AB, maxSeq: 2, modVer: 4), conv(G1, maxSeq: 1, modVer: 7)], "truncated": false])
        await settle()
        XCTAssertEqual(c3.frames("sync").count, 0)
        XCTAssertFalse(holds(h.im.debugExport(), SECRET_NAME))
        assertCleanLogs(h)
    }

    // F-RCL-03 rule 2a
    func testLateOldMessageDoesNotUnexpire() async throws {
        let (h, c1) = try await loaded()
        c1.receive(msgFrame(img(AB, 1, "F1", expired: true)))
        await settle()
        XCTAssertEqual(h.im.messages(AB)[0].body.image?.expired, true)
        c1.receive(msgFrame(img(AB, 1, "F1")))
        await settle()
        XCTAssertEqual(h.im.messages(AB)[0].body.image?.expired, true)
        c1.receive(msgFrame(fileMsg(AB, 2, "F2", expired: true)))
        c1.receive(msgFrame(fileMsg(AB, 2, "F2")))
        await settle()
        XCTAssertEqual(h.im.messages(AB)[1].body.file?.expired, true)
        XCTAssertEqual(h.im.messages(AB)[1].body.file?.name, "")
    }

    func testAfterAGapResetPagingBackDoesNotUnexpire() async throws {
        let (h, c1) = try await loaded()
        c1.receive(msgFrame(img(AB, 1, "F1", expired: true)))
        await settle()
        c1.drop(1006)
        let c2 = await reconnect(h)
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 500, modVer: 3), conv(G1, maxSeq: 1, modVer: 7)], "truncated": false])
        await settle()
        XCTAssertEqual(c2.last("sync")?.data?["beforeSeq"], 501)
        c2.ack("sync", ["messages": [msg(AB, 500)], "hasMore": true])
        await settle()
        XCTAssertEqual(h.im.messages(AB).map(\.seq), [500])
        let t = Task { try await h.im.loadHistory(AB, limit: 200) }
        await settle()
        c2.ack("sync", ["messages": [img(AB, 1, "F1"), msg(AB, 499)], "hasMore": false])
        _ = try await t.value
        XCTAssertEqual(h.im.messages(AB)[0].body.image?.expired, true)
    }

    func testDeletionStaysMonotonicToo() async throws {
        let (h, c1) = try await loaded()
        c1.receive(event("msgDeleted", ["convId": .string(AB), "msgIds": strs(["\(AB)#2"]), "seqs": [2]]))
        await settle()
        XCTAssertEqual(h.im.messages(AB)[1].deleted, true)
        c1.receive(msgFrame(fileMsg(AB, 2, "F2")))
        await settle()
        XCTAssertEqual(h.im.messages(AB)[1].deleted, true)
        XCTAssertEqual(h.im.messages(AB)[1].body, MsgBody())
        XCTAssertFalse(holds(h.im.debugExport(), SECRET_NAME))
    }

    func testOlderServerWithoutModVerStillResyncsEverything() async throws {
        let (h, c1) = try await loaded()
        c1.drop(1006)
        let c2 = await reconnect(h)
        c2.ack("convs", ["convs": [conv(AB, maxSeq: 2), conv(G1, maxSeq: 1)], "truncated": false])
        await settle()
        c2.ack("sync", ["messages": [], "hasMore": false])
        await settle()
        c2.ack("sync", ["messages": [], "hasMore": false])
        await settle()
        XCTAssertEqual(Set(c2.frames("sync").compactMap { $0.data?["convId"]?.stringValue }), [AB, G1])
    }
}

/// Cold starts with the local database (F-FILE-07 rule 3; AC-FILE-07-1 SDK part) and the schema upgrade.
@MainActor
final class FileRestartTests: IMTestCase {
    private var dir: URL!
    private var scratch: URL!
    private var inputs: URL!
    private let http = FakeHttp()

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tt-restart-\(UUID().uuidString)")
        dir = base.appendingPathComponent("db")
        scratch = base.appendingPathComponent("scratch")
        inputs = base.appendingPathComponent("inputs")
        for d in [dir!, inputs!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        try await super.tearDown()
    }

    private func start() -> Harness {
        let h = setup(directory: dir, scratch: scratch)
        h.fileAuth.target = StaticTokenAuth(baseUrl: "https://im.test", token: "demo-token", http: http)
        return h
    }

    private func image() -> ProcessedImage {
        let o = inputs.appendingPathComponent("o-\(UUID().uuidString)")
        let t = inputs.appendingPathComponent("t-\(UUID().uuidString)")
        try? Data(repeating: 1, count: 1000).write(to: o)
        try? Data(repeating: 2, count: 100).write(to: t)
        return ProcessedImage(
            original: LocalUpload(file: o, mime: "image/jpeg"), thumb: LocalUpload(file: t, mime: "image/jpeg"), width: 4, height: 3)
    }

    private func grant(_ fileId: String) {
        http.to(UPLOADS).last!.respond(
            200,
            [
                "fileId": .string(fileId), "put": put("\(fileId)-o"), "thumbPut": put("\(fileId)-t"),
            ])
    }

    private func sandboxNames() -> [String] {
        let d = scratch.appendingPathComponent("attachments")
        let users = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        return users.flatMap { ((try? FileManager.default.contentsOfDirectory(atPath: d.appendingPathComponent($0).path)) ?? []).sorted() }
    }

    // TC-FILE-07-01 (AC-FILE-07-1, SDK part)
    func testTC_FILE_07_01_killedWhileUploadingFailsOnRestartNoAutoUploadRetryFromScratch() async throws {
        let h = start()
        h.im.connect(token: "demo-token")
        _ = await h.login("alice")
        try h.im.sendImage("c2c:alice:bob", image())
        await settle()
        grant("F1")
        await settle()
        XCTAssertEqual(h.objectStore.pending.count, 1)
        h.im.close()  // Killed: no logout, the database stays.

        let h2 = start()
        h2.im.restoreCache(userId: "alice")
        let m = h2.im.messages("c2c:alice:bob")
        XCTAssertEqual(m.map(\.status), [.failed])
        XCTAssertEqual(m.first?.error, .interrupted)
        XCTAssertEqual(m.first?.clientMsgId, "cid-0001")
        h2.im.connect(token: "demo-token")
        let c = await h2.login("alice")
        await settle()
        h2.clock.advance(10_000)
        await settle()
        XCTAssertEqual(http.to(UPLOADS).count, 1)  // Nothing uploaded by itself.
        XCTAssertEqual(c.frames("send").count, 0)
        h2.im.retry("c2c:alice:bob", "cid-0001")
        await settle()
        XCTAssertEqual(http.to(UPLOADS).count, 2)  // From scratch: a new upload.
        grant("F2")
        await settle()
        h2.objectStore.pending[0].respond(200)
        await settle()
        h2.objectStore.pending[0].respond(200)
        await settle()
        http.last("/v1/files/F2/complete").respond(200, ["fileId": "F2", "size": 1000, "mime": "image/jpeg", "width": 4, "height": 3])
        await settle()
        XCTAssertEqual(c.last("send")?.data?["clientMsgId"], "cid-0001")
        XCTAssertEqual(c.last("send")?.data?["body"], ["image": ["fileId": "F2"]])
        c.ack("send", ["msgId": "m1", "convId": "c2c:alice:bob", "seq": 1, "ts": 9])
        await settle()
        XCTAssertEqual(h2.im.messages("c2c:alice:bob").map(\.status), [.sent])
        XCTAssertEqual(sandboxNames(), [])
        // The outbox row is gone too: a third start has nothing unsent.
        h2.im.close()
        let h3 = start()
        h3.im.restoreCache(userId: "alice")
        XCTAssertEqual(h3.im.messages("c2c:alice:bob").map(\.status), [.sent])
    }

    // F-FILE-07 rule 3: a completed one waiting to send goes out once by itself.
    func testCompletedAndQueuedIsSentOnceAfterRestart() async throws {
        let h = start()
        h.im.connect(token: "demo-token")
        let c = await h.login("alice")
        try h.im.sendImage("c2c:alice:bob", image())
        await settle()
        grant("F1")
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        h.objectStore.pending[0].respond(200)
        await settle()
        c.drop(1006)
        http.last("/v1/files/F1/complete").respond(200, ["fileId": "F1", "size": 1000, "mime": "image/jpeg", "width": 4, "height": 3])
        await settle()
        XCTAssertEqual(h.im.messages("c2c:alice:bob").map(\.status), [.queued])
        h.im.close()

        let h2 = start()
        h2.im.connect(token: "demo-token")
        let c2 = await h2.login("alice")
        XCTAssertEqual(c2.frames("send").count, 1)
        XCTAssertEqual(c2.last("send")?.data?["body"], ["image": ["fileId": "F1"]])
        XCTAssertEqual(http.to(UPLOADS).count, 1)
        c2.drop(1006)  // That one automatic send is used up.
        await settle()
        h2.clock.advance(1_000)
        await settle()
        let c3 = await h2.login("alice")
        XCTAssertEqual(c3.frames("send").count, 0)
        XCTAssertEqual(h2.im.messages("c2c:alice:bob").first?.status, .failed)
    }

    func testOrphanSandboxFilesAreRemovedOnStart() async throws {
        let h = start()
        h.im.connect(token: "demo-token")
        _ = await h.login("alice")
        h.im.close()
        let userDir = scratch.appendingPathComponent("attachments").appendingPathComponent(
            "alice".utf8.map { String(format: "%02x", $0) }.joined())
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: userDir.appendingPathComponent("stray"))
        let h2 = start()
        h2.im.restoreCache(userId: "alice")
        XCTAssertEqual(sandboxNames(), [])
    }

    // Version 1 -> 2 keeps the stored rows (local database upgrade).
    func testVersionOneDatabaseUpgradesInPlace() async throws {
        let file = dir.appendingPathComponent(LocalDatabase.fileName(userId: "alice"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let conv = #"{"readBase":0,"view":{"convId":"group:g1","lastMsg":null,"maxSeq":1,"minSeq":1,"name":"老群","readSeq":0,"type":"group","unread":0,"updatedAt":5}}"#
        let message = #"{"body":{"text":"old text kept"},"clientMsgId":"c1","convId":"group:g1","from":"bob","msgId":"group:g1#1","seq":1,"status":"sent","ts":5,"type":"text"}"#
        let sql = """
            CREATE TABLE conversations (conv_id TEXT PRIMARY KEY, state TEXT NOT NULL);
            CREATE TABLE messages (conv_id TEXT NOT NULL, seq INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY (conv_id, seq));
            CREATE TABLE social_meta (id INTEGER PRIMARY KEY CHECK (id = 1), social_ver INTEGER NOT NULL, request_seen_ver INTEGER NOT NULL, settings TEXT NOT NULL, official INTEGER NOT NULL, loaded INTEGER NOT NULL);
            CREATE TABLE friends (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            CREATE TABLE friend_requests (user_id TEXT NOT NULL, direction TEXT NOT NULL, item TEXT NOT NULL, PRIMARY KEY (user_id, direction));
            CREATE TABLE blocks (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            INSERT INTO conversations VALUES ('group:g1', '\(conv)');
            INSERT INTO messages VALUES ('group:g1', 1, '\(message)');
            PRAGMA user_version=1;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let h = start()
        h.im.restoreCache(userId: "alice")
        XCTAssertEqual(h.im.conversations().map(\.name), ["老群"])
        XCTAssertEqual(h.im.messages("group:g1").map(\.body.text), ["old text kept"])
        var check: OpaquePointer?
        sqlite3_open(file.path, &check)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(check, "PRAGMA user_version", -1, &stmt, nil)
        sqlite3_step(stmt)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 2)
        sqlite3_finalize(stmt)
        sqlite3_close(check)
    }

    // F-RCL-03 rule 2: the checked modVer survives a cold start, so an unchanged conversation is not re-synced.
    func testModVerBaselineSurvivesAColdStart() async throws {
        let h = start()
        h.im.connect(token: "demo-token")
        let c = await h.login("alice", convs: [conv("group:g1", maxSeq: 1, modVer: 5), conv("group:g2", maxSeq: 1, modVer: 1)])
        c.receive(msgFrame(msg("group:g1", 1)))
        c.receive(msgFrame(msg("group:g2", 1)))
        await settle()
        h.im.close()
        let h2 = start()
        h2.im.connect(token: "demo-token")
        let c2 = h2.transport.current
        c2.open()
        c2.ack("auth", ["userId": "alice", "serverTime": .int(h2.clock.now())])
        await flush()
        c2.ack("convs", ["convs": [conv("group:g1", maxSeq: 1, modVer: 5), conv("group:g2", maxSeq: 1, modVer: 2)], "truncated": false])
        await settle()
        XCTAssertEqual(c2.frames("sync").compactMap { $0.data?["convId"]?.stringValue }, ["group:g2"])
    }
}
