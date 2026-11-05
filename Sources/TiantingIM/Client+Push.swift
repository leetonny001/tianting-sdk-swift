import Foundation

extension IMClient {
    /// Subscribes to system pushes (PRD-live section 4.8), on the main actor. This and an iterating `pushes` are the only
    /// subscribers: the general `on` and `events()` do not count (AC-PUSH-08-9). Without a subscriber no `pushSync` is sent.
    /// Takes effect at the next scheduling point, where the backlog goes to everyone registered by then; later subscribers
    /// only get later pushes. Frames with a `pushSeq` are at-least-once (be idempotent on `pushId`), others at-most-once.
    @discardableResult
    public func onPush(_ handler: @MainActor @escaping (Push) -> Void) -> IMSubscription {
        let cancel = pushSync.subscribe(handler)
        return IMSubscription(cancel: cancel)
    }

    /// The same pushes as a stream. Each read of this property makes a new, independent stream. It counts as a subscriber
    /// from its first `next()`, not from its creation (section 4.8), until the task iterating it is cancelled or the stream
    /// and its iterator are released. "Delivered" means buffered here; the buffer is unbounded.
    public var pushes: AsyncStream<Push> {
        let sink = PushStreamSink(sync: pushSync)
        return AsyncStream(
            unfolding: { await sink.next() },
            onCancel: { sink.finish() })
    }

    /// One catch-up round ended (section 4.8). Optional, does not affect delivery.
    @discardableResult
    public func onPushSynced(_ handler: @MainActor @escaping (Int64) -> Void) -> IMSubscription {
        let cancel = pushSync.subscribeSynced(handler)
        return IMSubscription(cancel: cancel)
    }

    /// The push cursor: the highest contiguous sequence delivered. nil before a cursor exists.
    public func pushCursor() -> Int64? {
        pushSync.cursor
    }
}

/// Between `PushSync` and one `pushes` stream. It is owned by the stream's closure only, so it is released with the stream
/// and iterator; `PushSync` holds it weakly, and that release is what unsubscribes when a `for await` loop breaks.
private final class PushStreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Push] = []
    private var waiter: CheckedContinuation<Push?, Never>?
    private var finished = false
    private var started = false
    private var cancelSubscription: (@MainActor @Sendable () -> Void)?
    private weak var sync: PushSync?

    init(sync: PushSync) {
        self.sync = sync
    }

    deinit {
        if let cancel = cancelSubscription { Task { @MainActor in cancel() } }
    }

    func next() async -> Push? {
        await start()
        return await withCheckedContinuation { (cont: CheckedContinuation<Push?, Never>) in
            lock.lock()
            if !buffer.isEmpty {
                let first = buffer.removeFirst()
                lock.unlock()
                cont.resume(returning: first)
            } else if finished {
                lock.unlock()
                cont.resume(returning: nil)
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }

    /// The first `next()` makes this stream a subscriber.
    private func start() async {
        await MainActor.run {
            let alreadyStarted = lock.withLock {
                defer { started = true }
                return started || finished
            }
            guard !alreadyStarted, let sync else { return }
            let cancel = sync.subscribe { [weak self] push in self?.yield(push) }
            lock.withLock { cancelSubscription = cancel }
        }
    }

    private func yield(_ push: Push) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: push)
        } else {
            buffer.append(push)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let w = waiter
        waiter = nil
        let cancel = cancelSubscription
        cancelSubscription = nil
        lock.unlock()
        w?.resume(returning: nil)
        if let cancel { Task { @MainActor in cancel() } }
    }
}
