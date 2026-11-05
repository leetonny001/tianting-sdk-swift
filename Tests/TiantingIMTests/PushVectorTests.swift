import Foundation
import TiantingIMTesting
import XCTest

@testable import TiantingIM

/// A cursor store in memory that outlives client instances, like a file across a process restart.
final class MemoryCursorStore: PushCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: PushCursorRecord] = [:]
    var saves = 0

    func load(userId: String) throws -> PushCursorRecord? {
        lock.withLock { records[userId] }
    }

    func save(userId: String, cursor: Int64?, recentIds: [String]) throws {
        lock.withLock {
            saves += 1
            records[userId] = PushCursorRecord(cursor: cursor, recentIds: recentIds)
        }
    }

    func put(_ userId: String, cursor: Int64?, recentIds: [String] = []) {
        lock.withLock { records[userId] = PushCursorRecord(cursor: cursor, recentIds: recentIds) }
    }
}

/// Longer than any time a case advances: only the `requestTimeout` step fires a request timeout.
private let requestTimeout: Int64 = 9_000_000_000

/// A fake clock that remembers request timers, so `requestTimeout` fires only pushSync's one, without moving time.
@MainActor
private final class RecordingClock: FakeClock {
    var requestTimers: [(fn: @MainActor () -> Void, handle: TimerHandle, sentBefore: Int)] = []
    var sentCount: @MainActor () -> Int = { 0 }

    override func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle {
        let handle = super.setTimeout(ms, fn)
        if ms == requestTimeout { requestTimers.append((fn, handle, sentCount())) }
        return handle
    }
}

private typealias Item = [String: JSONValue]

private func objects(_ v: JSONValue?) -> [Item] {
    (v?.arrayValue ?? []).compactMap { if case .object(let o) = $0 { return o } else { return nil } }
}

private func expand(_ items: [Item]) -> [Item] {
    items.flatMap { it -> [Item] in
        guard let range = it["seqRange"]?.arrayValue, let a = range[0].intValue, let b = range[1].intValue else {
            return [it]
        }
        var rest = it
        rest["seqRange"] = nil
        let prefix = rest.removeValue(forKey: "idPrefix")?.stringValue ?? "p"
        return (a...b).map { n in
            var o = rest
            o["pushId"] = .string("\(prefix)\(n)")
            o["pushSeq"] = .int(n)
            return o
        }
    }
}

private func toFrame(_ it: Item) -> JSONValue {
    var o: Item = ["type": "notice", "data": ["text": "x"], "target": "user"]
    o.merge(it) { _, new in new }
    return .object(o)
}

private func field(_ p: Push, _ key: String) -> JSONValue? {
    switch key {
    case "pushId": return .string(p.pushId)
    case "type": return .string(p.type)
    case "data": return p.data
    case "ts": return .int(p.ts)
    case "target": return .string(p.target)
    case "roomId": return p.roomId.map { .string($0) }
    case "pushSeq": return p.pushSeq.map { .int($0) }
    case "replayed": return .bool(p.replayed)
    default: return nil
    }
}

/// Runs protocol/vectors/push-sync.json through the real `IMClient` with a fake transport and clock. Never edits the cases.
@MainActor
final class PushVectorTests: XCTestCase {
    private var failures: [String] = []

    private func check(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { failures.append(message()) }
    }

    private func makeClient(
        _ config: JSONValue?, clock: RecordingClock, transport: FakeTransport, store: PushCursorStore?
    ) -> IMClient {
        var o = IMClientOptions(url: "ws://im.test/ws")
        o.transport = transport
        o.clock = clock
        o.random = { 0.5 }
        o.systemEvents = false
        o.isVisible = { true }
        var t = IMClientTimings()
        t.requestTimeoutMs = requestTimeout
        t.sendTimeoutMs = requestTimeout
        t.heartbeatMs = requestTimeout * 2
        o.timings = t
        o.pushCursorStore = store
        if config?["pushStart"]?.stringValue == "latest" { o.pushStart = .latest }
        if let v = config?["stashMax"]?.intValue { o.pushLimits.stashMax = Int(v) }
        if let v = config?["noSeqQueueMax"]?.intValue { o.pushLimits.noSeqQueueMax = Int(v) }
        if let v = config?["seenMax"]?.intValue { o.pushLimits.seenMax = Int(v) }
        return IMClient(options: o)
    }

    private func run(_ c: JSONValue, limit: Int64, schema: SchemaValidator) async {
        let name = c["name"]!.stringValue!
        let config = c["config"]
        var store: MemoryCursorStore?
        if case .bool(true)? = config?["persistence"] {
            let s = MemoryCursorStore()
            if case .object(let stored)? = config?["stored"] {
                for (user, rec) in stored {
                    let ids = expand(objects(rec["seen"])).compactMap { $0["pushId"]?.stringValue }
                    s.put(user, cursor: rec["cursor"]?.intValue, recentIds: ids)
                }
            }
            store = s
        }

        var clock = RecordingClock()
        var transport = FakeTransport()
        var allTransports = [transport]
        clock.sentCount = { [t = transport] in t.connections.last?.sent.count ?? 0 }
        var im = makeClient(config, clock: clock, transport: transport, store: store)
        var delivered: [String: [Push]] = [:]
        var unsubs: [String: IMSubscription] = [:]
        var onDeliver: (pushId: String, id: String)?
        var synced: [Int64] = []
        im.onPushSynced { synced.append($0) }
        var seenFrames: [ObjectIdentifier: Int] = [:]
        var lastReq: (conn: FakeConnection, id: String, index: Int)?

        func newRequests() -> [JSONValue] {
            var out: [JSONValue] = []
            for conn in transport.connections {
                let frames = conn.frames()
                let key = ObjectIdentifier(conn)
                for i in (seenFrames[key] ?? 0)..<frames.count where frames[i].cmd == "pushSync" {
                    lastReq = (conn, frames[i].id!, i)
                    out.append(frames[i].data!)
                }
                seenFrames[key] = frames.count
            }
            return out
        }

        let networkOps: Set<String> = ["connect", "disconnect", "live", "ack", "ackError", "requestTimeout", "advance"]
        for (i, step) in c["steps"]!.arrayValue!.enumerated() {
            let op = step["op"]!.stringValue!
            let at = "\(name) #\(i) \(op)"
            let before = Set(unsubs.keys)
            if networkOps.contains(op) { await flush() }  // The scheduling point comes before network events and timers.
            if let u = step["unsubscribeOnDeliver"], let p = u["pushId"]?.stringValue, let id = u["id"]?.stringValue {
                onDeliver = (p, id)
            } else {
                onDeliver = nil
            }
            let stepRequests = newRequests()

            switch op {
            case "subscribe":
                let id = step["id"]!.stringValue!
                delivered[id] = delivered[id] ?? []
                unsubs[id] = im.onPush { p in
                    delivered[id, default: []].append(p)
                    if let o = onDeliver, o.pushId == p.pushId, o.id == id {
                        unsubs[id]?.cancel()
                        unsubs[id] = nil
                    }
                }
            case "unsubscribe":
                let id = step["id"]!.stringValue!
                unsubs[id]?.cancel()
                unsubs[id] = nil
            case "tick":
                break
            case "connect":
                // "userId changes" with the old connection still up: a socket cannot re-auth, so it goes down first.
                if im.state == .connected { transport.current.drop(1006) }
                im.connect(token: "token")
                im.networkOnline()
                let conn = transport.current
                conn.open()
                conn.ack("auth", ["userId": step["userId"]!, "serverTime": step["serverTime"]!])
            case "disconnect":
                transport.current.drop(1006)
            case "logout":
                im.disconnect()
            case "live":
                for f in expand(objects(step["frames"])) {
                    transport.current.receive(["cmd": "push", "data": toFrame(f)])
                }
            case "ack":
                if let r = lastReq {
                    r.conn.receive([
                        "id": .string(r.id), "cmd": "ack",
                        "data": [
                            "pushes": .array(expand(objects(step["pushes"])).map(toFrame)),
                            "hasMore": step["hasMore"] ?? nil, "latestSeq": step["latestSeq"] ?? nil,
                        ],
                    ])
                }
            case "ackError":
                if let r = lastReq {
                    r.conn.receive([
                        "id": .string(r.id), "cmd": "ack", "error": ["code": step["code"]!, "msg": "x"],
                    ])
                }
            case "requestTimeout":
                let index = lastReq?.index ?? -1
                if let t = clock.requestTimers.last(where: { $0.sentBefore == index }) {
                    clock.clearTimeout(t.handle)
                    t.fn()
                } else {
                    failures.append("\(at): no request timer")
                }
            case "advance":
                clock.advance(step["ms"]!.intValue!)
            case "restart":
                im.close()
                clock = RecordingClock()
                transport = FakeTransport()
                allTransports.append(transport)
                clock.sentCount = { [t = transport] in t.connections.last?.sent.count ?? 0 }
                im = makeClient(config, clock: clock, transport: transport, store: store)
                im.onPushSynced { synced.append($0) }
                unsubs = [:]
                lastReq = nil
            default:
                failures.append("\(at): unknown op")
            }
            if op != "subscribe" { await flush() }  // Every step but subscribe ends with a scheduling point.

            let want = step["expect"]
            let requests = stepRequests + newRequests()
            let wantRequests = (want?["requests"]?.arrayValue ?? []).map { r -> JSONValue in
                guard case .object(var o) = r, o["afterSeq"] != nil else { return r }
                o["limit"] = .int(limit)
                return .object(o)
            }
            check(requests == wantRequests, "\(at) requests: got \(requests), want \(wantRequests)")
            let wantSynced = (want?["pushSynced"]?.arrayValue ?? []).compactMap(\.intValue)
            check(synced == wantSynced, "\(at) pushSynced: got \(synced), want \(wantSynced)")
            synced = []

            let ids = before.union(unsubs.keys)
            for id in delivered.keys.sorted() {
                let got = delivered[id] ?? []
                delivered[id] = []
                let wanted: [Item]
                if case .object(let to)? = want?["deliveredTo"] {
                    wanted = expand(objects(to[id]))
                } else if let d = want?["delivered"], ids.contains(id) {
                    wanted = expand(objects(d))
                } else {
                    wanted = []
                }
                check(
                    got.map(\.pushId) == wanted.compactMap { $0["pushId"]?.stringValue },
                    "\(at) delivered to \(id): got \(got.map(\.pushId)), want \(wanted.compactMap { $0["pushId"]?.stringValue })")
                for (g, w) in zip(got, wanted) {
                    for (k, v) in w {
                        check(field(g, k) == v, "\(at) \(g.pushId).\(k): got \(String(describing: field(g, k))), want \(v)")
                    }
                }
            }
            if let wantCursor = want?["cursor"] {
                check(im.pushCursor() == wantCursor.intValue, "\(at) cursor: got \(String(describing: im.pushCursor())), want \(wantCursor)")
            }
        }
        // Every frame any client sent must pass frame.schema.json, as in the other unit tests.
        for t in allTransports {
            for conn in t.connections {
                for f in conn.frames() {
                    check(schema.isValid(f.raw), "\(name): frame failed the schema: \(f.cmd)")
                }
            }
        }
        im.destroy()
    }

    func testPushSyncVectors() async throws {
        let spec = try loadJSON("vectors/push-sync.json")
        let cases = spec["cases"]!.arrayValue!
        XCTAssertEqual(cases.count, 71)
        let limit = spec["defaults"]!["limit"]!.intValue!
        let schema = try SchemaValidator.shared()
        var passed = 0
        for c in cases {
            let before = failures.count
            await run(c, limit: limit, schema: schema)
            if failures.count == before { passed += 1 }
        }
        print("push-sync.json: \(passed)/\(cases.count) cases passed")
        XCTAssertEqual(passed, 71, failures.joined(separator: "\n"))
    }
}
