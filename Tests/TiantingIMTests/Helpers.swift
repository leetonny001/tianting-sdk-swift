import Foundation
import XCTest

@testable import TiantingIM
import TiantingIMTesting

let protocolDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol")

func loadJSON(_ relativePath: String) throws -> JSONValue {
    let data = try Data(contentsOf: protocolDir.appendingPathComponent(relativePath))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

/// Lets main-actor tasks and continuations run (the SDK's async chains).
@MainActor
func flush() async {
    for _ in 0..<60 { await Task.yield() }
}

final class LogBox: IMLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func debug(_ message: String) { add(message) }
    func warn(_ message: String) { add(message) }
    func error(_ message: String) { add(message) }
    private func add(_ m: String) {
        lock.lock()
        lines.append(m)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

@MainActor
final class Harness {
    let im: IMClient
    let clock: FakeClock
    let transport: FakeTransport
    let logs = LogBox()
    var visible = true
    var events: [IMEvent] = []

    init(
        clock: FakeClock? = nil,
        random: Double = 0.5,  // zero jitter, exact backoff
        platform: Platform = .ios,
        directory: URL? = nil,
        maxCached: Int = 100,
        heartbeatMs: Int64? = nil
    ) {
        let clock = clock ?? FakeClock()
        self.clock = clock
        let transport = FakeTransport()
        self.transport = transport
        var opts = IMClientOptions(url: "ws://im.test/ws")
        opts.platform = platform
        opts.transport = transport
        opts.clock = clock
        opts.random = { random }
        opts.systemEvents = false
        opts.databaseDirectory = directory
        opts.maxCachedMessagesPerConversation = maxCached
        opts.logger = logs
        opts.pushCursorStore = nil
        if let heartbeatMs { opts.timings.heartbeatMs = heartbeatMs }
        var n = 0
        opts.newId = {
            n += 1
            return "cid-" + String(format: "%04d", n)
        }
        var box: Harness?
        opts.isVisible = { box?.visible ?? true }
        im = IMClient(options: opts)
        box = self
        im.on { [weak self] in self?.events.append($0) }
    }

    /// Opens the current connection, completes auth, answers convs with the given list.
    @discardableResult
    func login(_ userId: String = "alice", convs: [JSONValue] = [], serverTime: Int64? = nil) async -> FakeConnection {
        let c = transport.current
        c.open()
        c.ack("auth", ["userId": .string(userId), "serverTime": .int(serverTime ?? clock.now())])
        await flush()
        c.ack("convs", ["convs": .array(convs), "truncated": false])
        await flush()
        return c
    }

    /// Reconnect path: wait out the first backoff (1 second), complete auth, leave `convs` for the test to answer.
    func reconnect(after ms: Int64 = 1_000, userId: String = "alice") async -> FakeConnection {
        clock.advance(ms)
        let c = transport.current
        c.open()
        c.ack("auth", ["userId": .string(userId), "serverTime": .int(clock.now())])
        await flush()
        return c
    }
}

func conv(
    _ convId: String,
    name: String? = nil,
    type: String? = nil,
    maxSeq: Int64 = 0,
    readSeq: Int64 = 0,
    minSeq: Int64 = 1,
    unread: Int64 = 0,
    lastMsg: JSONValue = nil,
    updatedAt: Int64 = 0,
    memberCount: Int64? = nil,
    myRole: String? = nil,
    mutedUntil: JSONValue? = nil,
    allMuted: Bool = false
) -> JSONValue {
    var o: [String: JSONValue] = [
        "convId": .string(convId),
        "type": .string(type ?? (convId.hasPrefix("group:") ? "group" : "c2c")),
        "name": .string(name ?? convId),
        "maxSeq": .int(maxSeq),
        "readSeq": .int(readSeq),
        "minSeq": .int(minSeq),
        "unread": .int(unread),
        "lastMsg": lastMsg,
        "updatedAt": .int(updatedAt),
    ]
    if let memberCount { o["memberCount"] = .int(memberCount) }
    if let myRole { o["myRole"] = .string(myRole) }
    if let mutedUntil { o["mutedUntil"] = mutedUntil }
    if allMuted { o["allMuted"] = true }
    return .object(o)
}

func msg(
    _ convId: String, _ seq: Int64, from: String = "bob", text: String? = nil, ts: Int64? = nil,
    clientMsgId: String? = nil, msgId: String? = nil
) -> JSONValue {
    [
        "msgId": .string(msgId ?? "\(convId)#\(seq)"),
        "clientMsgId": .string(clientMsgId ?? "\(from)-\(convId)-\(seq)"),
        "convId": .string(convId),
        "seq": .int(seq),
        "from": .string(from),
        "type": "text",
        "body": ["text": .string(text ?? "m\(seq)")],
        "ts": .int(ts ?? (1000 + seq)),
    ]
}

func deletedMsg(
    _ convId: String, _ seq: Int64, from: String = "bob", msgId: String? = nil, clientMsgId: String? = nil
) -> JSONValue {
    [
        "msgId": .string(msgId ?? "\(convId)#\(seq)"),
        "clientMsgId": .string(clientMsgId ?? "\(from)-\(convId)-\(seq)"),
        "convId": .string(convId),
        "seq": .int(seq),
        "from": .string(from),
        "type": "text",
        "ts": .int(1000 + seq),
        "deleted": true,
        "deletedAt": 5000,
    ]
}

func msgFrame(_ m: JSONValue) -> JSONValue {
    ["cmd": "msg", "data": m]
}

func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    var data = fields
    data["type"] = .string(type)
    return ["cmd": "event", "data": .object(data)]
}

func strs(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }

/// Base class: every frame any test's client sent must pass frame.schema.json.
@MainActor
class IMTestCase: XCTestCase {
    private var harnesses: [Harness] = []

    func setup(
        clock: FakeClock? = nil, random: Double = 0.5, platform: Platform = .ios, directory: URL? = nil,
        maxCached: Int = 100, heartbeatMs: Int64? = nil
    ) -> Harness {
        let h = Harness(
            clock: clock, random: random, platform: platform, directory: directory, maxCached: maxCached,
            heartbeatMs: heartbeatMs)
        harnesses.append(h)
        return h
    }

    override func tearDown() async throws {
        let schema = try SchemaValidator.shared()
        for h in harnesses {
            for c in h.transport.connections {
                for f in c.frames() {
                    XCTAssertTrue(
                        schema.isValid(f.raw), "frame failed frame.schema.json: \(f.raw.jsonString().prefix(300))")
                }
            }
        }
        harnesses = []
        try await super.tearDown()
    }
}

extension JSONValue {
    /// Nicer than comparing in tests: returns the object's keys.
    var keys: [String] {
        if case .object(let o) = self { return Array(o.keys) }
        return []
    }
}

/// Walks an object graph with Mirror, including private fields, looking for a string anywhere in memory.
/// Stricter than `debugExport`: it does not rely on the export being written correctly.
func holds(_ root: Any, _ needle: String) -> Bool {
    var seen = Set<ObjectIdentifier>()
    func walk(_ v: Any, depth: Int) -> Bool {
        if depth > 40 { return false }
        if let s = v as? String { return s.contains(needle) }
        let m = Mirror(reflecting: v)
        if m.displayStyle == .class, let o = (v as AnyObject?) {
            let id = ObjectIdentifier(o)
            if seen.contains(id) { return false }
            seen.insert(id)
        }
        for c in m.children where walk(c.value, depth: depth + 1) { return true }
        var sup = m.superclassMirror
        while let s = sup {
            for c in s.children where walk(c.value, depth: depth + 1) { return true }
            sup = s.superclassMirror
        }
        return false
    }
    return walk(root, depth: 0)
}

func encoded<T: Encodable>(_ v: T) -> String {
    String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
}
