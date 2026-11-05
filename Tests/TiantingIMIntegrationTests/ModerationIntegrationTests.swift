#if os(macOS)
import Foundation
import XCTest

@testable import TiantingIM

/// PRD-admin second batch against a real server with IM_V13_ADMIN_FEATURES=1 (sdk-ts moderation integration tests,
/// plus the local database the TS SDK does not have).
final class ModerationIntegrationTests: IntegrationCase {
    // AC-ADM-13-1, AC-ADM-13-11
    func testBanKicksAllConnectionsWithUntilAndDoesNotReconnect() async throws {
        let u = uid("ban")
        try await importUsers([u])
        let oldToken = try await srv.token(u)
        let a = try await login(u)
        let b = try await login(u)
        let (la, lb) = (EventLog(a), EventLog(b))
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try await srv.signed("POST", "/admin/users/\(u)/ban", ["durationSeconds": 86_400, "reason": "it"])
        try await untilTrue("both kicked") { !la.fatal.isEmpty && !lb.fatal.isEmpty }
        for r in la.fatal + lb.fatal {
            guard case .kicked(let reason, let code, let banEnd) = r, case .at(let when)? = banEnd else {
                return XCTFail("unexpected \(r)")
            }
            XCTAssertEqual(reason, "suspended")
            XCTAssertEqual(code, 4012)
            XCTAssertLessThan(abs(when - before - 86_400_000), 5_000)
        }
        try await sleepMs(300)  // Backoff is capped at 100ms here: a reconnect would have happened by now.
        XCTAssertEqual(a.state, .disconnected)
        XCTAssertEqual(b.state, .disconnected)

        let late = client()
        let lateLog = EventLog(late)
        late.connect(token: oldToken)
        try await untilTrue("old token kicked") { !lateLog.fatal.isEmpty }
        guard case .kicked("suspended", 4012, _) = lateLog.fatal[0] else {
            return XCTFail("unexpected \(lateLog.fatal[0])")
        }
    }

    func testPermanentBanUntilNull() async throws {
        let u = uid("ban")
        let im = try await login(u)
        let log = EventLog(im)
        try await srv.signed("POST", "/admin/users/\(u)/ban", ["durationSeconds": NSNull(), "reason": "it"])
        try await untilTrue("kicked") { !log.fatal.isEmpty }
        XCTAssertEqual(log.fatal[0], .kicked(reason: "suspended", code: 4012, until: .permanent))
    }

    // AC-ADM-31-1, 31-3, 31-5
    func testDeleteWipesEveryOnlineConnectionAndOfflineSync() async throws {
        let (s, m1, m2, off) = (uid("s"), uid("m"), uid("m"), uid("off"))
        let g = try await hostedGroup([s, m1, m2, off])
        let a = try await login(s)
        let a2 = try await login(s)
        let b = try await login(m1)
        let c = try await login(m2)
        let secret = "ZXQ-DEL-\(uid("x"))"
        _ = try sendOK(a, g.convId, secret)
        func find(_ x: IMClient) -> Message? { x.messages(g.convId).first { $0.body.text == secret } }
        try await untilTrue("ack") { find(a)?.status == .sent }
        let msgId = find(a)!.msgId!
        for x in [a2, b, c] { try await until("delivered") { find(x) } }
        let unread = conv(b, g.convId)!.unread
        XCTAssertGreaterThan(unread, 0)

        try await srv.signed("POST", "/admin/messages/delete", ["convId": g.convId, "msgIds": [msgId], "reason": "it"])
        for x in [a, a2, b, c] {
            try await untilTrue("deleted") { x.messages(g.convId).first { $0.msgId == msgId }?.deleted == true }
            XCTAssertFalse(encodedString(x.debugExport()).contains(secret))
            XCTAssertEqual(conv(x, g.convId)?.lastMsg?.msgId, msgId)
            XCTAssertEqual(conv(x, g.convId)?.lastMsg?.deleted, true)
        }
        XCTAssertEqual(conv(b, g.convId)?.unread, unread)

        let offline = try await login(off)
        try await untilTrue("offline convs") { conv(offline, g.convId) != nil }
        let v = conv(offline, g.convId)!
        XCTAssertEqual(v.lastMsg?.deleted, true)
        XCTAssertNil(v.lastMsg?.text)
        let unreadBefore = v.unread
        _ = try await offline.loadHistory(g.convId)
        let last = offline.messages(g.convId).last!
        XCTAssertEqual(last.msgId, msgId)
        XCTAssertEqual(last.deleted, true)
        XCTAssertTrue(last.body.isEmpty)
        XCTAssertFalse(encodedString(offline.debugExport()).contains(secret))
        XCTAssertEqual(conv(offline, g.convId)?.unread, unreadBefore)
    }

    // AC-ADM-31-4 / TC-ADM-31-04: against the real server, read the database files' raw bytes.
    func testDeleteWipesLocalDatabaseBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (s, m) = (uid("s"), uid("m"))
        let g = try await hostedGroup([s, m])
        let sender = try await login(s)
        let receiver = client(directory: dir)
        _ = try await login(m, receiver)
        let secret = "ZXQ-DEL-555-\(uid("x"))"
        _ = try sendOK(sender, g.convId, secret)
        let got = try await until("delivered") { receiver.messages(g.convId).first { $0.body.text == secret } }
        func disk() throws -> Bool {
            let bytes = Data(secret.utf8)
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .contains { try Data(contentsOf: $0).range(of: bytes) != nil }
        }
        XCTAssertTrue(try disk())  // Control.
        try await srv.signed("POST", "/admin/messages/delete", ["convId": g.convId, "msgIds": [got.msgId!], "reason": "it"])
        try await untilTrue("deleted") { receiver.messages(g.convId).first { $0.msgId == got.msgId }?.deleted == true }
        XCTAssertFalse(try disk())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1, "\(files)")
    }

    // Deleted while the app is dead: wiped from disk on the next launch's re-check (F-ADM-31 rule 5).
    func testDeleteWhileAppDeadWipedAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (s, m) = (uid("s"), uid("m"))
        let g = try await hostedGroup([s, m])
        let sender = try await login(s)
        let first = client(directory: dir)
        _ = try await login(m, first)
        let secret = "ZXQ-DEL-RESTART-\(uid("x"))"
        _ = try sendOK(sender, g.convId, secret)
        let got = try await until("delivered") { first.messages(g.convId).first { $0.body.text == secret } }
        first.close()
        try await srv.signed("POST", "/admin/messages/delete", ["convId": g.convId, "msgIds": [got.msgId!], "reason": "it"])

        func disk() throws -> Bool {
            let bytes = Data(secret.utf8)
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .contains { try Data(contentsOf: $0).range(of: bytes) != nil }
        }
        XCTAssertTrue(try disk())
        let second = client(directory: dir)
        _ = try await login(m, second)
        try await untilTrue("wiped from disk") { (try? disk()) == false }
        XCTAssertEqual(second.messages(g.convId).first { $0.msgId == got.msgId }?.deleted, true)
    }

    // AC-ADM-40-4, 40-5
    func testUserMuteAndUnmute() async throws {
        let (u, p) = (uid("u"), uid("p"))
        let g = try await hostedGroup([u, p])
        let im = try await login(u)
        let c2c = c2cConvId(u, p)
        try await srv.signed("POST", "/admin/mute", ["scope": "user", "userId": u, "durationSeconds": 600, "reason": "it"])
        try await untilTrue("muted") { im.muteState(g.convId) != nil }
        XCTAssertEqual(im.muteState(c2c)?.scope, .user)
        guard case .at(let deadline)? = im.muteState(g.convId)?.mutedUntil else { return XCTFail("no deadline") }
        XCTAssertGreaterThan(deadline, im.serverNow())

        let id = try sendOK(im, g.convId, "x")
        let mine: Message = try await until("4031") {
            im.messages(g.convId).first { (m: Message) in m.clientMsgId == id && m.status == .failed }
        }
        XCTAssertEqual(mine.error, .code(4031))

        try await srv.signed("POST", "/admin/unmute", ["scope": "user", "userId": u, "reason": "it"])
        try await untilTrue("unmuted") { im.muteState(g.convId) == nil }
        let back = try sendOK(im, g.convId, "back")
        try await untilTrue("sent") { im.messages(g.convId).first { $0.clientMsgId == back }?.status == .sent }
    }

    // AC-ADM-40-6
    func testMutedWhileOfflineSeenInAuthAck() async throws {
        let u = uid("u")
        try await importUsers([u])
        try await srv.signed("POST", "/admin/mute", ["scope": "user", "userId": u, "durationSeconds": NSNull(), "reason": "it"])
        let im = try await login(u)
        XCTAssertEqual(im.muteState(c2cConvId(u, "other")), MuteInfo(scope: .user, groupId: nil, mutedUntil: .permanent))
    }

    // AC-ADM-41-6
    func testGroupMuteFromConvsAndEventsOnlyThatGroup() async throws {
        let (u, p) = (uid("u"), uid("p"))
        let g1 = try await hostedGroup([u, p])
        let g2 = try await hostedGroup([u, p])
        try await srv.signed("POST", "/admin/mute", ["scope": "group", "groupId": g1.groupId, "userId": u, "durationSeconds": 3600, "reason": "it"])
        let im = try await login(u)
        try await untilTrue("g1 muted from convs") { im.muteState(g1.convId) != nil }
        XCTAssertEqual(im.muteState(g1.convId)?.scope, .group)
        XCTAssertEqual(im.muteState(g1.convId)?.groupId, g1.groupId)
        XCTAssertNil(im.muteState(g2.convId))
        XCTAssertNil(im.muteState(c2cConvId(u, p)))

        let ok = try sendOK(im, g2.convId, "ok")
        let no = try sendOK(im, g1.convId, "no")
        try await untilTrue("g2 sent") { im.messages(g2.convId).first { $0.clientMsgId == ok }?.status == .sent }
        try await untilTrue("g1 4031") { im.messages(g1.convId).first { $0.clientMsgId == no }?.status == .failed }

        try await srv.signed("POST", "/admin/unmute", ["scope": "group", "groupId": g1.groupId, "userId": u, "reason": "it"])
        try await untilTrue("g1 unmuted") { im.muteState(g1.convId) == nil }
        try await srv.signed("POST", "/admin/mute", ["scope": "group", "groupId": g2.groupId, "userId": u, "durationSeconds": NSNull(), "reason": "it"])
        try await untilTrue("g2 muted by event") { im.muteState(g2.convId) != nil }
        XCTAssertEqual(im.muteState(g2.convId)?.mutedUntil, .permanent)
        XCTAssertNil(im.muteState(g1.convId))
    }

    // F-ADM-24 rule 7: dissolved on the real server removes the conversation from the local database.
    func testDissolveDeletesFromLocalDatabase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (s, m) = (uid("s"), uid("m"))
        let g = try await hostedGroup([s, m])
        let sender = try await login(s)
        let receiver = client(directory: dir)
        _ = try await login(m, receiver)
        let log = EventLog(receiver)
        let secret = "ZXQ-DISSOLVE-\(uid("x"))"
        _ = try sendOK(sender, g.convId, secret)
        try await until("delivered") { receiver.messages(g.convId).first { $0.body.text == secret } }
        try await srv.signed("DELETE", "/admin/groups/\(g.groupId)")
        try await untilTrue("dissolved") { !log.removed.isEmpty }
        XCTAssertEqual(log.removed[0].0, g.convId)
        XCTAssertEqual(log.removed[0].1, "dissolved")
        let bytes = Data(secret.utf8)
        let found = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .contains { try Data(contentsOf: $0).range(of: bytes) != nil }
        XCTAssertFalse(found)
    }
}

private func encodedString<T: Encodable>(_ v: T) -> String {
    String(decoding: try! JSONEncoder().encode(v), as: UTF8.self)
}
#endif
