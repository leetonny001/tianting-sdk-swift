import CoreFoundation
import Foundation

// MARK: - Clock

public struct TimerHandle: Hashable, Sendable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// All time-based logic goes through this (FE-007): tests inject `FakeClock`.
@MainActor
public protocol IMClock: AnyObject {
    /// Milliseconds since the epoch.
    func now() -> Int64
    func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle
    func clearTimeout(_ handle: TimerHandle)
}

@MainActor
public final class SystemClock: IMClock {
    private var nextId: UInt64 = 1
    private var items: [UInt64: DispatchWorkItem] = [:]

    public init() {}

    public func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func setTimeout(_ ms: Int64, _ fn: @escaping @MainActor () -> Void) -> TimerHandle {
        let id = nextId
        nextId += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.items[id] = nil
                fn()
            }
        }
        items[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms))), execute: item)
        return TimerHandle(id: id)
    }

    public func clearTimeout(_ handle: TimerHandle) {
        items.removeValue(forKey: handle.id)?.cancel()
    }
}

// MARK: - Logger

/// The SDK never prints directly. Log lines never carry the token or message text (FE-003 item 7).
public protocol IMLogger: Sendable {
    func debug(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public struct SilentLogger: IMLogger {
    public init() {}
    public func debug(_ message: String) {}
    public func warn(_ message: String) {}
    public func error(_ message: String) {}
}

// MARK: - Text (PRD 3.1, C-26, C-27; vectors/text.json)

public let maxTextLength = 5000

/// Strips leading and trailing Unicode White_Space (25 characters; U+FEFF and U+200B are not White_Space).
public func trimText(_ s: String) -> String {
    let scalars = s.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    while start < end, scalars[start].properties.isWhitespace {
        start = scalars.index(after: start)
    }
    while end > start {
        let prev = scalars.index(before: end)
        guard scalars[prev].properties.isWhitespace else { break }
        end = prev
    }
    return String(scalars[start..<end])
}

/// Counts Unicode code points: an emoji counts 1, a ZWJ sequence counts its code points (C-27).
public func countCodePoints(_ s: String) -> Int {
    s.unicodeScalars.count
}

public enum TextCheck: Sendable, Equatable {
    case ok(text: String)
    case empty
    /// `over` is how many code points exceed the limit (the "N too many" hint, C-28).
    case tooLong(text: String, over: Int)
}

public func checkText(_ raw: String) -> TextCheck {
    let text = trimText(raw)
    let n = countCodePoints(text)
    if n == 0 { return .empty }
    if n > maxTextLength { return .tooLong(text: text, over: n - maxTextLength) }
    return .ok(text: text)
}

// MARK: - Placeholder avatars (PRD-ui F-UI-21; vectors/avatar.json)

/// FNV-1a 32-bit over UTF-8 bytes.
public func fnv1a32(_ s: String) -> UInt32 {
    var h: UInt32 = 0x811c_9dc5
    for b in s.utf8 {
        h ^= UInt32(b)
        h = h &* 0x0100_0193
    }
    return h
}

/// Palette index 0...7: userId for people, groupId for groups.
public func avatarColorIndex(_ id: String) -> Int {
    Int(fnv1a32(id) % 8)
}

/// The first code point of the trimmed display name, with ASCII lowercase uppercased.
public func avatarInitial(_ name: String) -> String {
    guard let first = trimText(name).unicodeScalars.first else { return "?" }
    if first.value >= 0x61, first.value <= 0x7A {
        return String(UnicodeScalar(first.value - 32)!)
    }
    return String(first)
}

// MARK: - Pinyin grouping (PRD-ui F-UI-13 rule 4; vectors/pinyin-groups.json)

/// Contact-list section letter: A...Z or "#". Latin letters (including full-width) are uppercased; Han characters
/// use the default pinyin reading from `CFStringTransform`; everything else is "#".
public func pinyinGroup(_ name: String) -> String {
    guard let first = name.unicodeScalars.first else { return "#" }
    let folded = String(first).precomposedStringWithCompatibilityMapping
    if folded.unicodeScalars.count == 1, let s = folded.unicodeScalars.first, isAsciiLetter(s) {
        return folded.uppercased()
    }
    guard first.properties.isIdeographic else { return "#" }
    let latin = NSMutableString(string: String(first))
    CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
    CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
    guard let s = (latin as String).unicodeScalars.first, isAsciiLetter(s) else { return "#" }
    return String(s).uppercased()
}

private func isAsciiLetter(_ s: UnicodeScalar) -> Bool {
    (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
}

// MARK: - Mutes (PRD-admin F-ADM-40, 41)

public struct MuteInfo: Sendable, Equatable {
    public enum Scope: String, Sendable {
        case user, group
    }
    public let scope: Scope
    public let groupId: String?
    /// Server time; `.permanent` when forever.
    public let mutedUntil: Until
}

private func isActive(_ until: Until, _ now: Int64) -> Bool {
    switch until {
    case .permanent: return true
    case .at(let t): return t > now
    }
}

/// One user-level entry and one entry per group. All `now`s are server time.
struct MuteTable: Equatable {
    private var user: Until?
    private var groups: [String: Until] = [:]

    mutating func setUser(_ until: Until?) {
        user = until
    }

    mutating func setGroup(_ groupId: String, _ until: Until?) {
        groups[groupId] = until
    }

    /// The mute for this conversation: the user level wins (F-ADM-41 rule 2); a group mute only affects that group.
    func get(_ convId: String, now: Int64) -> MuteInfo? {
        if let user, isActive(user, now) { return MuteInfo(scope: .user, groupId: nil, mutedUntil: user) }
        guard convId.hasPrefix("group:") else { return nil }
        let groupId = String(convId.dropFirst("group:".count))
        guard let until = groups[groupId], isActive(until, now) else { return nil }
        return MuteInfo(scope: .group, groupId: groupId, mutedUntil: until)
    }

    /// The earliest expiry; nil when nothing can expire.
    func nextExpiry() -> Int64? {
        var next: Int64?
        for until in [user].compactMap({ $0 }) + Array(groups.values) {
            if case .at(let t) = until, next == nil || t < next! { next = t }
        }
        return next
    }

    mutating func purge(now: Int64) {
        if let u = user, !isActive(u, now) { user = nil }
        groups = groups.filter { isActive($0.value, now) }
    }

    mutating func clear() {
        user = nil
        groups = [:]
    }
}
