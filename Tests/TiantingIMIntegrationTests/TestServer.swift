#if os(macOS)
import CryptoKit
import Foundation
import XCTest

/// A real im-server for integration tests: compiles server/cmd/im-server, runs it in test mode on free ports.
/// Same approach as sdk-ts test/integration/server.ts. The server source comes from TIANTING_SERVER_DIR, or a sibling
/// checkout (../tianting-server/server, ../im-mvp/server); without one the tests skip.
final class TestServer: @unchecked Sendable {
    static let adminKey = "sdk-it-admin-key-0123456789abcdef"
    private static let callerId = "sdk-it"
    private static let callerSecret = "sdk-it-caller-secret-0123456789abcdef"
    private static let callerScopes = ["user.ban", "msg.delete", "mute.write", "social.settings", "group.dissolve", "group.write", "push.user", "push.all", "account.invite", "user.read"]

    let wsURL: String
    /// http://127.0.0.1:port, for the account endpoints.
    let httpURL: String
    private let adminBase: String
    private let process: Process

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func serverDir() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["TIANTING_SERVER_DIR"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, relativeTo: repoRoot))
        } else {
            candidates.append(repoRoot.appendingPathComponent("../tianting-server/server"))
            candidates.append(repoRoot.appendingPathComponent("../im-mvp/server"))
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("cmd/im-server").path)
        }
    }

    private static let buildLock = NSLock()
    nonisolated(unsafe) private static var builtBinary: URL?

    private static func build(dir: URL) throws -> URL {
        buildLock.lock()
        defer { buildLock.unlock() }
        if let b = builtBinary { return b }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-sdk-swift-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bin = out.appendingPathComponent("im-server")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["go", "build", "-o", bin.path, "./cmd/im-server"]
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TestServerError("go build failed") }
        builtBinary = bin
        return bin
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestServerError("socket") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { throw TestServerError("bind") }
        var got = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: got.sin_port))
    }

    /// Starts a server. Throws `XCTSkip` when no server source is around.
    static func start(env extra: [String: String] = [:]) async throws -> TestServer {
        guard let dir = serverDir() else {
            throw XCTSkip("no tianting-server checkout; set TIANTING_SERVER_DIR to run integration tests")
        }
        let bin = try build(dir: dir)
        return try await TestServer(binary: bin, extraEnv: extra)
    }

    private init(binary: URL, extraEnv: [String: String]) async throws {
        let port = try TestServer.freePort()
        let adminPort = try TestServer.freePort()
        let data = FileManager.default.temporaryDirectory
            .appendingPathComponent("im-sdk-swift-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let callers = data.appendingPathComponent("callers.json")
        let spec: [[String: Any]] = [
            [
                "id": TestServer.callerId, "alg": "hmac-sha256",
                "secret": Data(TestServer.callerSecret.utf8).base64EncodedString(), "scopes": TestServer.callerScopes,
                // Whoever holds push.all must list its types, or the server refuses to start (PRD-live F-PUSH-09 rule 3).
                "pushTypes": ["notice", "promo"],
            ]
        ]
        try JSONSerialization.data(withJSONObject: spec).write(to: callers)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: callers.path)
        var env = ProcessInfo.processInfo.environment
        env["IM_ADDR"] = "127.0.0.1:\(port)"
        env["IM_ADMIN_ADDR"] = "127.0.0.1:\(adminPort)"
        env["IM_DB"] = data.appendingPathComponent("im.db").path
        env["IM_ADMIN_KEY"] = TestServer.adminKey
        env["IM_JWT_SECRET"] = "sdk-it-jwt-secret-0123456789"
        env["IM_TEST_MODE"] = "1"
        env["IM_METRICS_ADDR"] = "off"
        env["IM_ADMIN_CALLERS"] = callers.path
        // Second-batch moderation features (PRD-admin), on for every integration run.
        env["IM_V13_ADMIN_FEATURES"] = "1"
        env["IM_QUARANTINE_KEY"] = "sdk-it-quarantine-key-0123456789abcdef"
        for (k, v) in extraEnv { env[k] = v }
        let p = Process()
        p.executableURL = binary
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        wsURL = "ws://127.0.0.1:\(port)/ws"
        httpURL = "http://127.0.0.1:\(port)"
        adminBase = "http://127.0.0.1:\(adminPort)"
        let ready = URL(string: "http://127.0.0.1:\(port)/readyz")!
        for i in 0... {
            if let (_, r) = try? await URLSession.shared.data(from: ready), (r as? HTTPURLResponse)?.statusCode == 200 {
                break
            }
            if i > 200 { throw TestServerError("im-server did not start") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Only this process: the one started here.
    func stop() {
        process.terminate()
        process.waitUntilExit()
    }

    var pid: Int32 { process.processIdentifier }

    /// Calls the admin API with the legacy key (the nine v1.2 endpoints and test-mode routes).
    @discardableResult
    func admin(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: adminBase + path)!)
        req.httpMethod = method
        req.setValue(TestServer.adminKey, forHTTPHeaderField: "X-Admin-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await perform(req, method: method, path: path)
    }

    /// Calls the admin API with a caller signature (protocol/ADMIN.md "auth"), as second-batch endpoints require.
    @discardableResult
    func signed(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let raw = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        for i in nonceBytes.indices { nonceBytes[i] = UInt8.random(in: 0...255) }
        let nonce = base64url(Data(nonceBytes))
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let toSign = [method, path, timestamp, nonce, hash, "it", "", ""].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(toSign.utf8), using: SymmetricKey(data: Data(TestServer.callerSecret.utf8)))
        var req = URLRequest(url: URL(string: adminBase + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(TestServer.callerId, forHTTPHeaderField: "X-IM-Caller")
        req.setValue(timestamp, forHTTPHeaderField: "X-IM-Timestamp")
        req.setValue(nonce, forHTTPHeaderField: "X-IM-Nonce")
        req.setValue("it", forHTTPHeaderField: "X-IM-Operator")
        req.setValue(base64url(Data(mac)), forHTTPHeaderField: "X-IM-Signature")
        if !raw.isEmpty { req.httpBody = raw }
        return try await perform(req, method: method, path: path)
    }

    private func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func perform(_ req: URLRequest, method: String, path: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestServerError("\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
        }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func token(_ userId: String) async throws -> String {
        let r = try await admin("POST", "/admin/users/token", ["userId": userId])
        return r["token"] as! String
    }
}

struct TestServerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
