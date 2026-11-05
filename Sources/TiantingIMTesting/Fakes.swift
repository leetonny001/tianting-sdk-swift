import Foundation
import TiantingIM

/// A controllable clock (FE-007): `advance(ms)` runs due timers in order, so heartbeats, timeouts, backoff and
/// throttling can be tested deterministically.
@MainActor
open class FakeClock: IMClock {
    private struct Timer {
        let id: UInt64
        let at: Int64
        let fn: @MainActor () -> Void
    }

    private var t: Int64
    private var nextId: UInt64 = 1
    private var timers: [Timer] = []

    public init(start: Int64 = 1_700_000_000_000) {
        t = start
    }

    open func now() -> Int64 {
        t
    }

    open func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle {
        let timer = Timer(id: nextId, at: t + max(0, ms), fn: fn)
        nextId += 1
        timers.append(timer)
        return TimerHandle(id: timer.id)
    }

    open func clearTimeout(_ handle: TimerHandle) {
        timers.removeAll { $0.id == handle.id }
    }

    /// Moves time forward, running due timers in time order (including those created during the window).
    public func advance(_ ms: Int64) {
        let end = t + ms
        while let due = timers.filter({ $0.at <= end }).min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            timers.removeAll { $0.id == due.id }
            t = due.at
            due.fn()
        }
        t = end
    }

    public var pending: Int { timers.count }
}

public struct SentFrame: Sendable, Equatable {
    public let id: String?
    public let cmd: String
    public let data: JSONValue?
    public let raw: JSONValue
}

/// One fake connection: records frames sent by the client; tests script open, receive and drop.
@MainActor
public final class FakeConnection: TransportConnection {
    public private(set) var sent: [String] = []
    public private(set) var closedWith: (code: Int, reason: String)?
    public let url: String
    private let handlers: TransportHandlers

    init(url: String, handlers: TransportHandlers) {
        self.url = url
        self.handlers = handlers
    }

    public func send(_ text: String) {
        if closedWith == nil { sent.append(text) }
    }

    public func close(code: Int, reason: String) {
        if closedWith == nil { closedWith = (code, reason) }
    }

    /// Simulates the handshake finishing.
    public func open() {
        handlers.onOpen()
    }

    /// Simulates the server sending one frame.
    public func receive(_ frame: JSONValue) {
        handlers.onMessage(frame.jsonString())
    }

    public func receive(text: String) {
        handlers.onMessage(text)
    }

    /// Simulates the connection ending (1006 for a lost network).
    public func drop(_ code: Int = 1006, _ reason: String = "") {
        handlers.onClose(code, reason)
    }

    public func frames() -> [SentFrame] {
        sent.compactMap { s in
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) else { return nil }
            return SentFrame(id: v["id"]?.stringValue, cmd: v["cmd"]?.stringValue ?? "", data: v["data"], raw: v)
        }
    }

    public func frames(_ cmd: String) -> [SentFrame] {
        frames().filter { $0.cmd == cmd }
    }

    /// The last request of a command.
    public func last(_ cmd: String) -> SentFrame? {
        frames(cmd).last
    }

    /// Acks the last request of a command.
    public func ack(_ cmd: String, _ data: JSONValue = [:]) {
        guard let id = last(cmd)?.id else { fatalError("no \(cmd) frame sent") }
        receive(["id": .string(id), "cmd": "ack", "data": data])
    }

    public func ackError(_ cmd: String, _ code: Int, msg: String = "error") {
        guard let id = last(cmd)?.id else { fatalError("no \(cmd) frame sent") }
        receive(["id": .string(id), "cmd": "ack", "error": ["code": .int(Int64(code)), "msg": .string(msg)]])
    }
}

/// A fake transport (FE-007): each `open` creates a `FakeConnection` that tests drive through `connections`.
@MainActor
public final class FakeTransport: IMTransport {
    public private(set) var connections: [FakeConnection] = []

    public init() {}

    public func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        let c = FakeConnection(url: url, handlers: handlers)
        connections.append(c)
        return c
    }

    public var current: FakeConnection {
        guard let c = connections.last else { fatalError("no connection opened") }
        return c
    }
}
