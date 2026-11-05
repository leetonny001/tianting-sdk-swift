import Foundation

public enum ConnState: String, Sendable {
    case disconnected, connecting, connected
}

/// Why the connection stopped for good: kicked, or a close code that must not reconnect (1000, 4009...4012, 4429).
public enum FatalReason: Sendable, Equatable {
    /// `until` is only present for `suspended`: the ban's end, or `.permanent`.
    case kicked(reason: String, code: Int, until: Until?)
    case closed(code: Int, reason: String)
}

struct ConnectionTimings: Sendable {
    var heartbeatMs: Int64
    var pongTimeoutMs: Int64
    var requestTimeoutMs: Int64
    var backoffBaseMs: Int64
    var backoffMaxMs: Int64
    /// Backoff jitter ratio (0.2 means +-20%).
    var jitter: Double
}

/// Connection management (FE-003): first-frame auth, heartbeat, reconnect with backoff and jitter, kicks,
/// matching requests to acks.
///
/// States: disconnected -> connecting (open the socket, send auth) -> connected (auth ack received).
/// The token only appears in the auth frame: never in the URL, never in a log line (C-52).
@MainActor
final class Connection {
    typealias Completion = @MainActor (Result<Data, Error>) -> Void
    typealias LateAck = @MainActor (Result<Data, IMError>) -> Void

    var onState: (@MainActor (ConnState) -> Void)?
    var onConnected: (@MainActor (AuthAck) -> Void)?
    var onFrame: (@MainActor (InboundFrame) -> Void)?
    var onFatal: (@MainActor (FatalReason) -> Void)?

    private let url: String
    private let platform: Platform
    private let transport: IMTransport
    private let clock: IMClock
    private let logger: IMLogger
    private let t: ConnectionTimings
    private let random: () -> Double

    private var token = ""
    private var active = false
    private(set) var state: ConnState = .disconnected
    private var conn: TransportConnection?
    private var connGen = 0
    private var attempt = 0
    private var reconnectTimer: TimerHandle?
    private var heartbeatTimer: TimerHandle?
    private var pongTimer: TimerHandle?
    private var kickedReason: String?
    private var kickedUntil: Until?
    private var reqN = 0
    private var authId = ""
    private var pending: [String: Pending] = [:]

    private final class Pending {
        let cmd: String
        let completion: Completion
        let onLateAck: LateAck?
        var timer: TimerHandle?
        var timedOut = false

        init(cmd: String, completion: @escaping Completion, onLateAck: LateAck?) {
            self.cmd = cmd
            self.completion = completion
            self.onLateAck = onLateAck
        }
    }

    init(
        url: String,
        platform: Platform,
        transport: IMTransport,
        clock: IMClock,
        logger: IMLogger,
        timings: ConnectionTimings,
        random: @escaping () -> Double
    ) {
        self.url = url
        self.platform = platform
        self.transport = transport
        self.clock = clock
        self.logger = logger
        self.t = timings
        self.random = random
    }

    /// Starts connecting; only updates the token when already active.
    func start(token: String) {
        self.token = token
        if active { return }
        active = true
        attempt = 0
        dial()
    }

    /// Logs out: closes with 1000 and never reconnects (PRD F-AUTH-05).
    func stop() {
        active = false
        clearReconnect()
        let c = conn
        let open = teardown()
        c?.close(code: 1000, reason: "logout")
        setState(.disconnected)
        failOpen(open)
    }

    /// Network came back: reconnect now when waiting on backoff (PRD F-CONN-01 rule 3).
    func reconnectNow() {
        if active, state == .disconnected, reconnectTimer != nil {
            clearReconnect()
            dial()
        }
    }

    /// Sends a request. The frame goes out synchronously; `completion` runs when the ack, an error, or the timeout
    /// settles it. After a timeout `onLateAck` still receives the ack if it arrives (C-30).
    func request(
        _ cmd: String,
        _ data: JSONValue = .object([:]),
        timeoutMs: Int64? = nil,
        onLateAck: LateAck? = nil,
        completion: @escaping Completion
    ) {
        guard state == .connected, let c = conn else {
            completion(.failure(IMConnectionError.notConnected))
            return
        }
        reqN += 1
        let id = "r\(reqN)"
        let p = Pending(cmd: cmd, completion: completion, onLateAck: onLateAck)
        p.timer = clock.setTimeout(timeoutMs ?? t.requestTimeoutMs) { [weak self, weak p] in
            guard let self, let p else { return }
            p.timedOut = true
            if p.onLateAck == nil { self.pending[id] = nil }
            p.completion(.failure(IMConnectionError.timeout(cmd: cmd)))
        }
        pending[id] = p
        c.send(encodeFrame(id: id, cmd: cmd, data: data))
    }

    func request<T: Decodable>(_ type: T.Type, _ cmd: String, _ data: JSONValue = .object([:])) async throws -> T {
        let raw = try await requestRaw(cmd, data)
        do {
            return try decodeFrameData(T.self, from: raw)
        } catch {
            logger.warn("im: bad \(cmd) ack")
            throw IMConnectionError.badResponse(cmd: cmd)
        }
    }

    func requestRaw(_ cmd: String, _ data: JSONValue = .object([:])) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            request(cmd, data) { result in
                cont.resume(with: result)
            }
        }
    }

    private func encodeFrame(id: String, cmd: String, data: JSONValue) -> String {
        JSONValue.object(["id": .string(id), "cmd": .string(cmd), "data": data]).jsonString()
    }

    private func dial() {
        connGen += 1
        let gen = connGen
        kickedReason = nil
        kickedUntil = nil
        setState(.connecting)
        let full = "\(url)?platform=\(platform.rawValue)"
        conn = transport.open(
            url: full,
            handlers: TransportHandlers(
                onOpen: { [weak self] in
                    guard let self, gen == self.connGen else { return }
                    self.authId = "auth\(gen)"
                    // Not logged anywhere: this frame carries the token.
                    self.conn?.send(
                        self.encodeFrame(id: self.authId, cmd: "auth", data: ["token": .string(self.token)]))
                },
                onMessage: { [weak self] text in
                    guard let self, gen == self.connGen else { return }
                    self.onText(text)
                },
                onClose: { [weak self] code, reason in
                    guard let self, gen == self.connGen else { return }
                    self.onClosed(code: code, reason: reason)
                }
            ))
    }

    private struct Header: Decodable {
        var id: String?
        var cmd: String?
        var error: FrameError?
    }

    private struct EventHeader: Decodable {
        struct Body: Decodable { var type: String? }
        var data: Body?
    }

    private struct KickedFrame: Decodable {
        struct Body: Decodable {
            var reason: String?
            var until: Until?
            private enum CodingKeys: String, CodingKey { case reason, until }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                reason = c.value(.reason, default: nil)
                until = (try? c.decodeUntil(forKey: .until)) ?? nil
            }
        }
        var data: Body
    }

    private func onText(_ text: String) {
        let raw = Data(text.utf8)
        guard let h = try? JSONCoding.decoder.decode(Header.self, from: raw), let cmd = h.cmd else {
            logger.warn("im: invalid frame from server")
            return
        }
        switch cmd {
        case "ack":
            onAck(id: h.id, error: h.error, raw: raw)
        case "pong":
            clearPong()
        case "event":
            let type = (try? JSONCoding.decoder.decode(EventHeader.self, from: raw))?.data?.type
            if type == "kicked" {
                // Remember the reason; the close code that follows settles it.
                let k = (try? JSONCoding.decoder.decode(KickedFrame.self, from: raw))?.data
                kickedReason = k?.reason ?? ""
                kickedUntil = k?.until
                return
            }
            onFrame?(InboundFrame(cmd: cmd, eventType: type, raw: raw))
        default:
            onFrame?(InboundFrame(cmd: cmd, eventType: nil, raw: raw))
        }
    }

    private func onAck(id: String?, error: FrameError?, raw: Data) {
        if let id, id == authId, state == .connecting {
            if let error {
                logger.warn("im: auth rejected \(error.code)")
                return  // Credential problems are settled by the kicked event and close code that follow.
            }
            guard let ack = try? decodeFrameData(AuthAck.self, from: raw) else {
                logger.warn("im: bad auth ack")
                return
            }
            attempt = 0
            setState(.connected)
            scheduleHeartbeat()
            onConnected?(ack)
            return
        }
        guard let id, let p = pending.removeValue(forKey: id) else { return }
        if let timer = p.timer { clock.clearTimeout(timer) }
        let err = error.map {
            IMError(
                code: $0.code, message: $0.msg ?? "",
                userId: $0.userId ?? $0.details?["userId"]?.stringValue, details: $0.details)
        }
        if p.timedOut {
            if let err {
                p.onLateAck?(.failure(err))
            } else {
                p.onLateAck?(.success(raw))
            }
            return
        }
        if let err {
            p.completion(.failure(err))
        } else {
            p.completion(.success(raw))
        }
    }

    private func scheduleHeartbeat() {
        heartbeatTimer = clock.setTimeout(t.heartbeatMs) { [weak self] in
            guard let self else { return }
            self.heartbeatTimer = nil
            guard self.state == .connected, let c = self.conn else { return }
            c.send("{\"cmd\":\"ping\"}")
            // No pong within 10 seconds: the network is up but the server is not answering (AC-CONN-01-6).
            self.pongTimer = self.clock.setTimeout(self.t.pongTimeoutMs) { [weak self] in
                guard let self else { return }
                self.pongTimer = nil
                self.logger.warn("im: pong timeout, reconnecting")
                let old = self.conn
                self.onClosed(code: 1006, reason: "pong timeout")
                old?.close(code: 4000, reason: "pong timeout")
            }
            self.scheduleHeartbeat()
        }
    }

    private func onClosed(code: Int, reason: String) {
        let kicked = kickedReason
        let until = kickedUntil
        let open = teardown()
        // Open requests fail last, so their handlers see the outcome: a kick wins over "connection closed".
        defer { failOpen(open) }
        setState(.disconnected)
        guard active else { return }

        // Kicked never reconnects (PRD F-AUTH-03 rule 4), except a server shutdown (C-55).
        if let kicked, kicked != "serverShutdown" {
            active = false
            onFatal?(.kicked(reason: kicked, code: code, until: until))
            return
        }
        // 1000, 4009...4012 and 4429 never reconnect; unlisted codes (1006...) may.
        if kicked == nil, closeReconnect[code] == false {
            active = false
            onFatal?(.closed(code: code, reason: reason))
            return
        }
        scheduleReconnect()
    }

    /// Backoff 1, 2, 4... up to 30 seconds (the cap applies before jitter, C-22), then +-jitter.
    private func scheduleReconnect() {
        let shift = min(attempt, 32)
        let base = min(t.backoffBaseMs << Int64(shift), t.backoffMaxMs)
        let delay = Int64((Double(base) * (1 + t.jitter * (2 * random() - 1))).rounded())
        attempt += 1
        logger.debug("im: reconnect in \(delay)ms")
        reconnectTimer = clock.setTimeout(delay) { [weak self] in
            guard let self else { return }
            self.reconnectTimer = nil
            if self.active { self.dial() }
        }
    }

    /// After a disconnect: stop timers, ignore late callbacks from the old socket. Returns the open requests.
    private func teardown() -> [Pending] {
        connGen += 1
        conn = nil
        if let h = heartbeatTimer { clock.clearTimeout(h) }
        heartbeatTimer = nil
        clearPong()
        let open = Array(pending.values)
        pending = [:]
        for p in open {
            if let timer = p.timer { clock.clearTimeout(timer) }
        }
        return open
    }

    private func failOpen(_ open: [Pending]) {
        for p in open where !p.timedOut {
            p.completion(.failure(IMConnectionError.closed))
        }
    }

    private func clearPong() {
        if let p = pongTimer { clock.clearTimeout(p) }
        pongTimer = nil
    }

    private func clearReconnect() {
        if let r = reconnectTimer { clock.clearTimeout(r) }
        reconnectTimer = nil
    }

    private func setState(_ s: ConnState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }
}
