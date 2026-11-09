#if os(macOS)
import CryptoKit
import Foundation
import XCTest

@testable import TiantingIM

/// The minimal fake S3 (Tests/IntegrationResources/fake_s3.py, standard-library Python, 127.0.0.1 only; the same file as
/// sdk-ts). It does not check signatures: it only lets the scheduling logic run (TC-FILE general notes).
final class FakeS3Process: @unchecked Sendable {
    let endpoint: String
    private let process: Process
    private let stdin: Pipe

    init() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IntegrationResources/fake_s3.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script.path]
        let out = Pipe()
        stdin = Pipe()
        p.standardOutput = out
        p.standardInput = stdin
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        var buf = Data()
        while !buf.contains(UInt8(ascii: "\n")) {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { throw TestServerError("fake S3 did not start") }
            buf.append(d)
        }
        let line = String(decoding: buf, as: UTF8.self)
        guard let port = line.split(separator: " ").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { throw TestServerError("fake S3 port") }
        endpoint = "http://127.0.0.1:\(port)"
    }

    /// Environment that turns files on in im-server (IM_FILES_ENABLED) against this fake.
    var env: [String: String] {
        [
            "IM_FILES_ENABLED": "1", "IM_OBJSTORE_ENDPOINT": endpoint, "IM_OBJSTORE_REGION": "us-east-1",
            "IM_OBJSTORE_BUCKET": "chat", "IM_OBJSTORE_PUBLIC_BUCKET": "avatars", "IM_OBJSTORE_PUBLIC_BASE_URL": "\(endpoint)/avatars",
            "IM_OBJSTORE_ACCESS_KEY": "sdk-it-access", "IM_OBJSTORE_SECRET_KEY": "sdk-it-secret-not-real",
        ]
    }

    /// Only the process started here; it also exits by itself when its stdin closes.
    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.terminate()
        process.waitUntilExit()
    }
}

final class ITLog: IMLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func debug(_ m: String) { add(m) }
    func warn(_ m: String) { add(m) }
    func error(_ m: String) { add(m) }
    private func add(_ m: String) {
        lock.lock()
        lines.append(m)
        lock.unlock()
    }
    var all: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// FE-632 against a real im-server (IM_FILES_ENABLED=1) and the fake S3: the sdk-swift part of AC-FILE-02-1 and 03-1
/// (send, receive, URL, download with the same SHA-256), a non-participant gets 4048, the logs carry no URL or name.
/// Local results, CI not running.
@MainActor
final class FileIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var s3: FakeS3Process?
    nonisolated(unsafe) static var server: TestServer?
    var clients: [IMClient] = []
    let log = ITLog()
    var dirs: [URL] = []

    var srv: TestServer { FileIntegrationTests.server! }

    override func setUp() async throws {
        try await super.setUp()
        if FileIntegrationTests.server == nil {
            let s3 = try FakeS3Process()
            FileIntegrationTests.s3 = s3
            FileIntegrationTests.server = try await TestServer.start(env: s3.env)
        }
    }

    override func tearDown() async throws {
        for c in clients { c.destroy() }
        clients = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        // AC-FILE-04-11: no presigned URL, signature or file name in the SDK's logs.
        XCTAssertFalse(log.all.contains("X-Amz"))
        XCTAssertFalse(log.all.contains("127.0.0.1"))
        XCTAssertFalse(log.all.contains("ZXQ-FILE"))
        try await super.tearDown()
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        s3?.stop()
        s3 = nil
        super.tearDown()
    }

    private func scratch() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-file-it-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    private func login(_ userId: String) async throws -> IMClient {
        let token = try await srv.token(userId)
        let s = scratch()
        var o = IMClientOptions(url: srv.wsURL)
        o.systemEvents = false
        o.pushCursorStore = nil
        o.logger = log
        o.attachmentDirectory = s.appendingPathComponent("att")
        o.fileCacheDirectory = s.appendingPathComponent("cache")
        o.files = FileClient(auth: StaticTokenAuth(baseUrl: srv.httpURL, token: token), logger: log)
        let im = IMClient(options: o)
        clients.append(im)
        im.connect(token: token)
        try await untilTrue("\(userId) connected") { im.state == .connected && im.userId == userId }
        return im
    }

    /// A JPEG with only an SOF0 segment: the server's sniffing reads its size without decoding pixels.
    private func jpeg(_ w: Int, _ h: Int, _ size: Int) -> Data {
        var b = [UInt8](repeating: 0, count: size)
        let head: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(h >> 8), UInt8(h & 255), UInt8(w >> 8), UInt8(w & 255), 3,
            1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
        ]
        for (i, x) in head.enumerated() { b[i] = x }
        for i in head.count..<(size - 2) { b[i] = UInt8((i * 31) & 0xFF) }
        b[size - 2] = 0xFF
        b[size - 1] = 0xD9
        return Data(b)
    }

    private func write(_ d: Data) throws -> URL {
        let u = scratch().appendingPathComponent("in")
        try d.write(to: u)
        return u
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func importUsers(_ ids: [String]) async throws {
        try await srv.admin("POST", "/admin/users/import", ["users": ids.map { ["userId": $0] }])
    }

    private func uid(_ s: String) -> String { s + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36) }

    // TC-FILE-02-01 (sdk-swift)
    func testTC_FILE_02_01_jpegSentReceivedThumbThenOriginalSameValues() async throws {
        let a = uid("sa"), b = uid("sb")
        try await importUsers([b])
        let u1 = try await login(a)
        let u2 = try await login(b)
        let conv = c2cConvId(a, b)
        let original = jpeg(1920, 1080, 2 << 20)
        let thumb = jpeg(480, 270, 30_000)
        let img = ProcessedImage(
            original: LocalUpload(file: try write(original), mime: "image/jpeg"),
            thumb: LocalUpload(file: try write(thumb), mime: "image/jpeg"), width: 1920, height: 1080)
        var statuses: [MessageStatus] = []
        let sub = u1.on { e in
            if case .messages(let id, let list) = e, id == conv, let s = list.first?.status, statuses.last != s { statuses.append(s) }
        }
        defer { sub.cancel() }
        try u1.sendImage(conv, img)
        let sent = try await until("u1 sent", timeout: 20) { u1.messages(conv).first { $0.status == .sent } }
        XCTAssertEqual(statuses, [.uploading, .sending, .sent])
        let got = try await until("u2 receives", timeout: 10) { u2.messages(conv).first }
        XCTAssertEqual(got.type, .image)
        XCTAssertEqual(got.body.image, sent.body.image)
        XCTAssertEqual(got.body.image?.width, 1920)
        XCTAssertEqual(got.body.image?.height, 1080)
        XCTAssertEqual(got.body.image?.size, Int64(original.count))
        XCTAssertEqual(got.body.image?.mime, "image/jpeg")
        let fileId = try XCTUnwrap(got.body.image?.fileId)
        let t = try await u2.download(fileId: fileId, variant: .thumb)
        XCTAssertEqual(sha(try Data(contentsOf: t)), sha(thumb))
        let o = try await u2.download(fileId: fileId, variant: .original)
        XCTAssertEqual(sha(try Data(contentsOf: o)), sha(original))
        XCTAssertEqual(u2.conversations().first { $0.convId == conv }?.lastMsg?.type, "image")
    }

    // TC-FILE-03-01 (sdk-swift)
    func testTC_FILE_03_01_groupPdfDownloadedWithTheSameSha256() async throws {
        let a = uid("ga"), b = uid("gb"), c = uid("gc"), g = uid("gfiles")
        try await importUsers([a, b, c])
        try await srv.admin("POST", "/admin/groups", ["groupId": g, "name": g, "members": [a, b, c]])
        let u1 = try await login(a)
        let u2 = try await login(b)
        let conv = groupConvId(g)
        try await untilTrue("u1 sees group") { u1.conversations().contains { $0.convId == conv } }
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(Data((0..<(5 << 20)).map { UInt8(($0 * 7) & 0xFF) }))
        let name = "ZXQ-FILE-报告.pdf"
        try u1.sendFile(conv, FileInput(file: try write(pdf), name: name, mime: "application/pdf"))
        _ = try await until("u1 sent", timeout: 20) { u1.messages(conv).first { $0.type == .file && $0.status == .sent } }
        let got = try await until("u2 receives", timeout: 10) { u2.messages(conv).first { $0.type == .file } }
        XCTAssertEqual(got.body.file?.name, name)
        XCTAssertEqual(got.body.file?.size, Int64(pdf.count))
        XCTAssertEqual(got.body.file?.mime, "application/pdf")
        let f = try await u2.download(fileId: try XCTUnwrap(got.body.file?.fileId), variant: .original)
        XCTAssertEqual(sha(try Data(contentsOf: f)), sha(pdf))
        XCTAssertFalse(f.lastPathComponent.contains("ZXQ"))
    }

    // AC-FILE-04-1 as the SDK sees it
    func testNonParticipantGets4048LikeAnUnknownFileId() async throws {
        let a = uid("xa"), b = uid("xb"), c = uid("xc")
        try await importUsers([b])
        let u1 = try await login(a)
        let u3 = try await login(c)
        let conv = c2cConvId(a, b)
        try u1.sendImage(
            conv,
            ProcessedImage(
                original: LocalUpload(file: try write(jpeg(100, 100, 2000)), mime: "image/jpeg"),
                thumb: LocalUpload(file: try write(jpeg(50, 50, 1000)), mime: "image/jpeg"), width: 100, height: 100))
        let sent = try await until("sent", timeout: 20) { u1.messages(conv).first { $0.status == .sent } }
        let r = try await u3.getFileUrls([
            FileUrlItem(fileId: try XCTUnwrap(sent.body.image?.fileId), variant: .original),
            FileUrlItem(fileId: "nonexistent123", variant: .original),
        ])
        XCTAssertEqual(r.map(\.code), [4048, 4048])
        do {
            _ = try await u3.download(fileId: try XCTUnwrap(sent.body.image?.fileId), variant: .thumb)
            XCTFail("expected 4048")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .unavailable(code: 4048))
        }
    }
}
#endif
