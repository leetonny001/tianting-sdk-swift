import Foundation
import Network

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
func defaultIsVisible() -> Bool {
    #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState != .background
    #else
        return true
    #endif
}

/// Feeds system signals into the client: the network coming back reconnects at once (F-CONN-01 rule 3), foreground and
/// background changes drive read reports (F-CONV-02 rule 3).
@MainActor
final class SystemEventsMonitor {
    private let path = NWPathMonitor()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(online: @escaping @MainActor () -> Void, visibility: @escaping @MainActor () -> Void) {
        let lastSatisfied = Box(false)
        path.pathUpdateHandler = { update in
            let satisfied = update.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let wasSatisfied = lastSatisfied.value
                    lastSatisfied.value = satisfied
                    if satisfied, !wasSatisfied { online() }
                }
            }
        }
        path.start(queue: DispatchQueue(label: "tianting.im.network-path"))
        #if canImport(UIKit) && !os(watchOS)
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        visibility()
                        online()
                    }
                })
            observers.append(
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { visibility() }
                })
        #endif
    }

    deinit {
        path.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private final class Box: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }
}
