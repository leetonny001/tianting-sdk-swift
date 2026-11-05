import Foundation

/// The transport seam: production uses `WebSocketTransport`, tests use `FakeTransport` (FE-007).
@MainActor
public protocol IMTransport: AnyObject {
    func open(url: String, handlers: TransportHandlers) -> TransportConnection
}

public struct TransportHandlers {
    public var onOpen: @MainActor () -> Void
    public var onMessage: @MainActor (String) -> Void
    /// The connection ended: `code` is the close code, or 1006 when no close frame arrived.
    public var onClose: @MainActor (_ code: Int, _ reason: String) -> Void

    public init(
        onOpen: @escaping @MainActor () -> Void,
        onMessage: @escaping @MainActor (String) -> Void,
        onClose: @escaping @MainActor (_ code: Int, _ reason: String) -> Void
    ) {
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }
}

@MainActor
public protocol TransportConnection: AnyObject {
    func send(_ text: String)
    func close(code: Int, reason: String)
}

/// `URLSessionWebSocketTask` transport. No header carries credentials and the URL only has `platform`.
///
/// C-07: the default `maximumMessageSize` is 1 MiB and a `sync` page can be 200 x 5000-character messages,
/// so the downstream limit is lifted here.
@MainActor
public final class WebSocketTransport: IMTransport {
    public init() {}

    public func open(url: String, handlers: TransportHandlers) -> TransportConnection {
        let conn = WebSocketConnection(handlers: handlers)
        conn.start(url: url)
        return conn
    }
}

@MainActor
private final class WebSocketConnection: TransportConnection {
    private let handlers: TransportHandlers
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    private var closeInfo: (code: Int, reason: String)?

    init(handlers: TransportHandlers) {
        self.handlers = handlers
    }

    func start(url: String) {
        guard let u = URL(string: url) else {
            finish(code: 1006, reason: "bad url")
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let delegate = SocketDelegate(
            onOpen: { [weak self] in self?.handlers.onOpen() },
            onClose: { [weak self] code, reason in self?.onCloseFrame(code: code, reason: reason) },
            onComplete: { [weak self] in self?.onTaskComplete() }
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        let task = session.webSocketTask(with: u)
        task.maximumMessageSize = Int.max
        self.session = session
        self.task = task
        task.resume()
        receiveNext()
    }

    func send(_ text: String) {
        guard !finished else { return }
        task?.send(.string(text)) { _ in
            // A failed send surfaces through `receive` failing as well: the close is handled there.
        }
    }

    func close(code: Int, reason: String) {
        guard !finished else { return }
        finished = true
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            // A serial hop keeps frames in order and in front of the close notification they preceded.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onReceive(result)
                }
            }
        }
    }

    private func onReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard !finished else { return }
        switch result {
        case .success(.string(let text)):
            handlers.onMessage(text)
            receiveNext()
        case .success(.data(let data)):
            handlers.onMessage(String(decoding: data, as: UTF8.self))
            receiveNext()
        case .success:
            receiveNext()
        case .failure:
            // Frames that came before the close were delivered by the earlier receives. Prefer the close code
            // from the task; if it is not set yet, the delegate is about to deliver it.
            if let info = closeInfo {
                finish(code: info.code, reason: info.reason)
            } else if let code = currentCloseCode() {
                finish(code: code, reason: currentCloseReason())
            } else {
                awaitCloseNotification()
            }
        }
    }

    private func currentCloseCode() -> Int? {
        guard let raw = task?.closeCode.rawValue, raw != URLSessionWebSocketTask.CloseCode.invalid.rawValue else {
            return nil
        }
        return raw
    }

    private func currentCloseReason() -> String {
        task?.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func awaitCloseNotification() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                self.finish(code: self.currentCloseCode() ?? 1006, reason: self.currentCloseReason())
            }
        }
    }

    private func onCloseFrame(code: Int, reason: String) {
        closeInfo = (code, reason)
        // `receive` fails once queued frames are out and finishes the connection. This timer covers a receive that
        // never completes, so a close can never hang.
        awaitCloseNotification()
    }

    private func onTaskComplete() {
        guard !finished else { return }
        if let info = closeInfo {
            finish(code: info.code, reason: info.reason)
        } else {
            awaitCloseNotification()
        }
    }

    private func finish(code: Int, reason: String) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        task = nil
        session = nil
        handlers.onClose(code, reason)
    }
}

/// Delegate callbacks arrive on `OperationQueue.main`.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @MainActor () -> Void
    private let onClose: @MainActor (Int, String) -> Void
    private let onComplete: @MainActor () -> Void

    init(
        onOpen: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor (Int, String) -> Void,
        onComplete: @escaping @MainActor () -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated { onOpen() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        MainActor.assumeIsolated { onClose(closeCode.rawValue, text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { onComplete() }
    }
}
