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

/// A session store for tests and app previews: remembers the calls in order, and can hold a save open or make it fail.
@MainActor
public final class MemorySessionStore: AccountSessionStore {
    public var saved: AccountSession?
    public var pendingLogouts: [PendingLogout] = []
    public private(set) var saves: [AccountSession] = []
    public private(set) var clears = 0
    /// Every call, in order, e.g. "save" (tests of the order against HTTP and token use).
    public private(set) var calls: [String] = []
    public var failSave = false
    /// While true, a `save` waits until `releaseSaves()`.
    public var holdSaves = false
    /// While true, a `clear` waits until `releaseSaves()`.
    public var holdClears = false
    /// While true, a `savePendingLogouts` waits until `releaseSaves()`.
    public var holdPending = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func load() async throws -> AccountSession? {
        calls.append("load")
        return saved
    }

    public func save(_ session: AccountSession) async throws {
        calls.append("save")
        if holdSaves { await withCheckedContinuation { heldSaves.append($0) } }
        if failSave { throw FakeHttpError(message: "disk full") }
        saved = session
        saves.append(session)
    }

    public func clear() async throws {
        calls.append("clear")
        if holdClears { await withCheckedContinuation { heldSaves.append($0) } }
        saved = nil
        clears += 1
    }

    public func loadPendingLogouts() async throws -> [PendingLogout] {
        calls.append("loadPending")
        return pendingLogouts
    }

    public func savePendingLogouts(_ pending: [PendingLogout]) async throws {
        calls.append("savePending")
        if holdPending { await withCheckedContinuation { heldSaves.append($0) } }
        pendingLogouts = pending
    }

    public func releaseSaves() {
        holdSaves = false
        holdClears = false
        holdPending = false
        let held = heldSaves
        heldSaves = []
        for c in held { c.resume() }
    }
}

/// One fake object store request (PUT or GET): the test decides progress and the outcome. Cancelling the calling task
/// fails it, as URLSession does.
@MainActor
public final class FakeObjectStoreCall {
    public let method: String
    public let url: String
    public let headers: [String: String]
    /// PUT: the file the SDK sent (its bytes are read at call time into `body`). GET: where the SDK wants the bytes.
    public let file: URL
    public let body: Data
    public private(set) var settled = false
    public private(set) var cancelled = false
    private var continuation: CheckedContinuation<Int, Error>?
    private let sentProgress: (@Sendable (Int64) -> Void)?
    private let receivedProgress: (@Sendable (Int64, Int64?) -> Void)?

    init(
        method: String, url: String, headers: [String: String], file: URL,
        sent: (@Sendable (Int64) -> Void)?, received: (@Sendable (Int64, Int64?) -> Void)?
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.file = file
        body = method == "PUT" ? ((try? Data(contentsOf: file)) ?? Data()) : Data()
        sentProgress = sent
        receivedProgress = received
    }

    private var result: Result<Int, Error>?

    func attach(_ c: CheckedContinuation<Int, Error>) {
        if let result {
            c.resume(with: result)
            return
        }
        continuation = c
    }

    private func finish(_ r: Result<Int, Error>) {
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    /// The size of what was PUT.
    public var size: Int { body.count }

    /// Reports progress: bytes sent (PUT) or received (GET).
    public func progress(_ n: Int64, of total: Int64? = nil) {
        sentProgress?(n)
        receivedProgress?(n, total)
    }

    /// Ends the request. A 2xx GET writes `data` to the destination; a 2xx PUT reports all bytes sent first.
    public func respond(_ status: Int = 200, data: Data = Data()) {
        guard !settled else { return }
        settled = true
        if (200..<300).contains(status) {
            if method == "PUT" { sentProgress?(Int64(body.count)) }
            if method == "GET" {
                try? data.write(to: file)
                receivedProgress?(Int64(data.count), Int64(data.count))
            }
        }
        finish(.success(status))
    }

    /// A network error, or a GET broken off after `partial` bytes were written (the SDK must remove them).
    public func fail(_ message: String = "network error", partial: Data? = nil) {
        guard !settled else { return }
        settled = true
        if let partial { try? partial.write(to: file) }
        finish(.failure(FakeHttpError(message: message)))
    }

    func cancel() {
        guard !settled else { return }
        cancelled = true
        fail("cancelled")
    }
}

/// A fake object store (PRD-chat 4.5): records every PUT and GET and leaves them open for the test. `auto` answers 200.
@MainActor
public final class FakeObjectStore: ObjectStoreTransport {
    public private(set) var calls: [FakeObjectStoreCall] = []
    public var auto = false

    public init() {}

    public func put(url: String, headers: [String: String], file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int
    {
        let call = FakeObjectStoreCall(method: "PUT", url: url, headers: headers, file: file, sent: progress, received: nil)
        return try await run(call)
    }

    public func get(url: String, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int {
        let call = FakeObjectStoreCall(method: "GET", url: url, headers: [:], file: destination, sent: nil, received: progress)
        return try await run(call)
    }

    private func run(_ call: FakeObjectStoreCall) async throws -> Int {
        calls.append(call)
        if auto { call.respond(200) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in call.attach(c) }
        } onCancel: {
            Task { @MainActor in call.cancel() }
        }
    }

    public var pending: [FakeObjectStoreCall] { calls.filter { !$0.settled } }
    public var puts: [FakeObjectStoreCall] { calls.filter { $0.method == "PUT" } }
    public var gets: [FakeObjectStoreCall] { calls.filter { $0.method == "GET" } }
}
