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

/// One fake HTTP request: the test decides when and how it ends, late responses included.
@MainActor
public final class FakeHttpCall {
    public let request: HttpRequest
    public private(set) var settled = false
    private var continuation: UnsafeContinuation<HttpResponse, Error>?

    init(request: HttpRequest, continuation: UnsafeContinuation<HttpResponse, Error>) {
        self.request = request
        self.continuation = continuation
    }

    /// The URL's path, without the host.
    public var path: String { URLComponents(string: request.url)?.path ?? request.url }

    /// The parsed request body; empty when there is none.
    public var json: JSONValue {
        guard let body = request.body, let v = try? JSONDecoder().decode(JSONValue.self, from: body) else { return [:] }
        return v
    }

    public var bearer: String? {
        request.headers["Authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") }
    }

    /// Answers with a JSON body. Answering a settled call does nothing, like a late response on a real network.
    public func respond(_ status: Int, _ body: JSONValue = [:]) {
        respond(status, text: body.jsonString())
    }

    public func respond(_ status: Int, text: String) {
        settled = true
        continuation?.resume(returning: HttpResponse(status: status, body: Data(text.utf8)))
        continuation = nil
    }

    /// Answers with the server's error shape, `ErrorResponse`.
    public func respondError(
        _ status: Int, _ code: Int, reason: String? = nil, details: [String: JSONValue]? = nil, msg: String = "error"
    ) {
        var o: [String: JSONValue] = ["code": .int(Int64(code)), "msg": .string(msg)]
        if let reason { o["reason"] = .string(reason) }
        if let details { o["details"] = .object(details) }
        respond(status, .object(o))
    }

    /// Simulates a network error. The message can carry a URL, as real errors do; the SDK must not pass it on.
    public func fail(_ message: String = "network error") {
        settled = true
        continuation?.resume(throwing: FakeHttpError(message: message))
        continuation = nil
    }
}

public struct FakeHttpError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A fake HTTP transport (PRD-chat 4.5; `FakeTransport` only has the WebSocket): records every request and leaves it
/// open for the test. `onRequest` answers automatically, to build a fake server. Cancellation is ignored on purpose: an
/// abandoned request can still get a late response, which the SDK has to drop.
@MainActor
public final class FakeHttp: HttpTransport {
    public private(set) var calls: [FakeHttpCall] = []
    public var onRequest: (@MainActor (FakeHttpCall) -> Void)?

    public init() {}

    public func request(_ request: HttpRequest) async throws -> HttpResponse {
        try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<HttpResponse, Error>) in
            let call = FakeHttpCall(request: request, continuation: cont)
            calls.append(call)
            onRequest?(call)
        }
    }

    /// Every request to a path, in the order sent.
    public func to(_ path: String) -> [FakeHttpCall] {
        calls.filter { $0.path == path }
    }

    /// The last request to a path.
    public func last(_ path: String) -> FakeHttpCall {
        guard let c = to(path).last else { fatalError("no request to \(path)") }
        return c
    }

    /// Requests not answered yet.
    public var pending: [FakeHttpCall] {
        calls.filter { !$0.settled }
    }
}
