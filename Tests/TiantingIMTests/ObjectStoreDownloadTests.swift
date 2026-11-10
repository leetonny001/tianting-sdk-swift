#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// Problem 52 (AC-RCL-03-12 "no partial file is left"): `URLSessionObjectStoreTransport.get` streams into the SDK's own
/// file. A cancelled or broken download leaves neither that file nor a `CFNetworkDownload_*.tmp` of URLSession's own.
/// Runs against a real socket on loopback (`ScriptedSocketServer`).
@MainActor
final class ObjectStoreDownloadTests: XCTestCase {
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int64, Int64?)] = []
        func add(_ r: Int64, _ e: Int64?) {
            lock.lock()
            values.append((r, e))
            lock.unlock()
        }
        var last: (Int64, Int64?)? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    private func systemDownloadFiles() -> Set<String> {
        var dirs = [FileManager.default.temporaryDirectory]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first { dirs.append(caches) }
        var found: Set<String> = []
        for d in dirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            for n in names where n.hasPrefix("CFNetworkDownload_") { found.insert(d.appendingPathComponent(n).path) }
        }
        return found
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tt-dl-\(UUID().uuidString).part-x")
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private let partialHead = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1000000\r\n\r\n"

    func testCancelledDownloadLeavesNoPartialFileAnywhere() async throws {
        let body = String(repeating: "a", count: 8192)
        let srv = try ScriptedSocketServer { [partialHead] _, _ in .respond(partialHead + body) }
        defer { srv.stop() }
        let before = systemDownloadFiles()
        let dest = destination()
        defer { try? FileManager.default.removeItem(at: dest) }
        let progress = Progress()
        let t = URLSessionObjectStoreTransport()
        let task = Task { @MainActor in
            try await t.get(url: srv.baseURL + "/chat/o/k?X-Amz-Signature=x", to: dest) { r, e in progress.add(r, e) }
        }
        do {
            try await waitUntil { (progress.last?.0 ?? 0) > 0 }
        } catch {
            task.cancel()
            throw error
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "streams into the SDK's own file")
        XCTAssertEqual(progress.last?.1, 1_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "the partial file is deleted")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(systemDownloadFiles().subtracting(before), [], "URLSession left a temporary file of its own")
    }

    func testBrokenConnectionMidBodyLeavesNoPartialFile() async throws {
        let body = String(repeating: "b", count: 4096)
        let srv = try ScriptedSocketServer { [partialHead] _, _ in .respond(partialHead + body) }
        let before = systemDownloadFiles()
        let dest = destination()
        defer { try? FileManager.default.removeItem(at: dest) }
        let progress = Progress()
        let t = URLSessionObjectStoreTransport()
        let task = Task { @MainActor in
            try await t.get(url: srv.baseURL + "/chat/o/k?X-Amz-Signature=x", to: dest) { r, e in progress.add(r, e) }
        }
        try await waitUntil { (progress.last?.0 ?? 0) > 0 }
        srv.stop()
        do {
            _ = try await task.value
            XCTFail("expected a failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(systemDownloadFiles().subtracting(before), [])
    }

    func testCompleteDownloadWritesTheBody() async throws {
        let body = String(repeating: "c", count: 70_000)
        let srv = try ScriptedSocketServer { _, _ in
            .respond("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        }
        defer { srv.stop() }
        let dest = destination()
        defer { try? FileManager.default.removeItem(at: dest) }
        let progress = Progress()
        let status = try await URLSessionObjectStoreTransport().get(url: srv.baseURL + "/o", to: dest) { r, e in
            progress.add(r, e)
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try Data(contentsOf: dest), Data(body.utf8))
        XCTAssertEqual(progress.last?.0, Int64(body.utf8.count))
        XCTAssertEqual(progress.last?.1, Int64(body.utf8.count))
    }

    func testErrorStatusWritesNothing() async throws {
        let srv = try ScriptedSocketServer { _, _ in
            .respond("HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\n\r\n<Error/>\n")
        }
        defer { srv.stop() }
        let dest = destination()
        defer { try? FileManager.default.removeItem(at: dest) }
        let status = try await URLSessionObjectStoreTransport().get(url: srv.baseURL + "/o", to: dest) { _, _ in }
        XCTAssertEqual(status, 403)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testCancelledBeforeStartThrows() async throws {
        let srv = try ScriptedSocketServer { _, _ in .silent }
        defer { srv.stop() }
        let dest = destination()
        let task = Task { @MainActor in
            try await URLSessionObjectStoreTransport().get(url: srv.baseURL + "/o", to: dest) { _, _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }
}
#endif
