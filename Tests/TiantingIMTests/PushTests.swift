import Foundation
import SQLite3
import TiantingIMTesting
import XCTest

@testable import TiantingIM

private let MARK = "ZXQ-PUSH-MARK"

private func frame(_ id: String, seq: Int64? = nil, ts: Int64 = 5000, text: String = "x", target: String = "user") -> JSONValue {
    var o: [String: JSONValue] = [
        "pushId": .string(id), "type": "notice", "data": ["text": .string(text)], "ts": .int(ts), "target": .string(target),
    ]
    if let seq { o["pushSeq"] = .int(seq) }
    return .object(o)
}

private func frames(_ r: ClosedRange<Int64>) -> [JSONValue] {
    r.map { (n: Int64) in frame("p\(n)", seq: n) }
}

private func live(_ f: JSONValue) -> JSONValue { ["cmd": "push", "data": f] }

/// A store that stops saving when "the process dies": what is on disk stays as it was.
private final class CrashingStore: PushCursorStore, @unchecked Sendable {
    let inner = MemoryCursorStore()
    var dead = false

    func load(userId: String) throws -> PushCursorRecord? { try inner.load(userId: userId) }

    func save(userId: String, cursor: Int64?, recentIds: [String]) throws {
        if !dead { try inner.save(userId: userId, cursor: cursor, recentIds: recentIds) }
    }
}

@MainActor
final class PushTests: XCTestCase {
    private var dir: URL!
    private var clients: [IMClient] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tianting-push-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for c in clients { c.close() }
        clients = []
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private var cursorDir: URL { dir.appendingPathComponent("cursors") }
    private var dbDir: URL { dir.appendingPathComponent("db") }

    private func make(
        store: PushCursorStore?, database: URL? = nil, logs: LogBox? = nil, clock: FakeClock? = nil,
        limits: PushLimits = PushLimits()
    ) -> (IMClient, FakeTransport) {
        let transport = FakeTransport()
        var o = IMClientOptions(url: "ws://im.test/ws")
        o.transport = transport
        o.clock = clock ?? FakeClock()
        o.random = { 0.5 }
        o.systemEvents = false
        o.databaseDirectory = database
        o.pushCursorStore = store
        o.pushLimits = limits
        if let logs { o.logger = logs }
        let im = IMClient(options: o)
        clients.append(im)
        return (im, transport)
    }

    @discardableResult
    private func auth(_ im: IMClient, _ t: FakeTransport, _ user: String = "u1", serverTime: Int64 = 1000) async -> FakeConnection {
        im.connect(token: "secret-token-xyz")
        im.networkOnline()
        let c = t.current
        c.open()
        c.ack("auth", ["userId": .string(user), "serverTime": .int(serverTime)])
        await flush()
        return c
    }

    private func syncs(_ t: FakeTransport) -> [JSONValue] {
        t.connections.flatMap { $0.frames("pushSync") }.compactMap(\.data)
    }

    private func ackPage(_ c: FakeConnection, _ frames: [JSONValue], latest: Int64, hasMore: Bool = false) async {
        c.ack("pushSync", ["pushes": .array(frames), "hasMore": .bool(hasMore), "latestSeq": .int(latest)])
        await flush()
    }

    /// Delivers pushes 1...41 through a first instance and leaves the cursor in `store` at 41.
    private func seedCursor41(_ store: PushCursorStore, database: URL? = nil) async {
        let (im, t) = make(store: store, database: database)
        var got: [Push] = []
        im.onPush { got.append($0) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, frames(1...41), latest: 41)
        XCTAssertEqual(got.count, 41)
        XCTAssertEqual(im.pushCursor(), 41)
        im.close()
    }

    /// A new connection must ask for afterSeq 41 and replay nothing, even if the server sends the old pushes again.
    private func assertResumesAt41(
        _ im: IMClient, _ t: FakeTransport, _ c: FakeConnection, file: StaticString = #filePath, line: UInt = #line
    ) async {
        XCTAssertEqual(syncs(t).last, ["afterSeq": 41, "limit": 100], file: file, line: line)
        XCTAssertEqual(im.pushCursor(), 41, file: file, line: line)
    }

    /// Waits for a stream reader to end by itself, then cancels it: a regression must fail a test, not hang the run.
    private func finish(_ reader: Task<Void, Never>, file: StaticString = #filePath, line: UInt = #line) async {
        let done = Flag()
        let watcher = Task { @MainActor in
            await reader.value
            done.on = true
        }
        for _ in 0..<100 where !done.on {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(done.on, "the reader did not finish", file: file, line: line)
        reader.cancel()
        await watcher.value
    }

    @MainActor private final class Flag { var on = false }

    // MARK: AC-PUSH-08-9

    func testGeneralListenersAreNotSubscribers() async {
        let (im, t) = make(store: nil)
        var general = 0
        im.on { _ in general += 1 }
        let drain = Task { for await _ in im.events() { general += 1 } }
        defer { drain.cancel() }
        await flush()
        let c = await auth(im, t)
        for s: Int64 in 1...3 { c.receive(live(frame("p\(s)", seq: s))) }
        await flush()
        XCTAssertGreaterThan(general, 0)
        XCTAssertEqual(syncs(t), [], "the general on and events() must not start a catch-up")
        XCTAssertEqual(im.pushCursor(), 0)

        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        XCTAssertEqual(syncs(t), [["afterSeq": 0, "limit": 100]])
        await ackPage(c, frames(1...3), latest: 3)
        XCTAssertEqual(got, ["p1", "p2", "p3"])
        XCTAssertEqual(im.pushCursor(), 3)
    }

    func testUniteratedStreamIsNotASubscriberAndIteratingOneIs() async throws {
        let (im, t) = make(store: nil)
        let stream = im.pushes
        await flush()
        let c = await auth(im, t)
        c.receive(live(frame("p1", seq: 1)))
        await flush()
        XCTAssertEqual(syncs(t), [], "a stream nobody iterates does not count")
        XCTAssertEqual(im.pushCursor(), 0)

        var got: [String] = []
        let reader = Task { @MainActor in
            for await p in stream {
                got.append(p.pushId)
                if got.count == 2 { break }
            }
        }
        await flush()
        XCTAssertEqual(syncs(t), [["afterSeq": 0, "limit": 100]])
        await ackPage(c, [frame("p1", seq: 1), frame("p2", seq: 2)], latest: 2)
        await finish(reader)
        XCTAssertEqual(got, ["p1", "p2"])
        XCTAssertEqual(im.pushCursor(), 2, "yielded counts as delivered")
    }

    func testStreamStopsBeingASubscriberWhenCancelled() async {
        let (im, t) = make(store: nil)
        let reader = Task { @MainActor in
            for await _ in im.pushes {}
        }
        await flush()
        let c = await auth(im, t)
        XCTAssertEqual(syncs(t).count, 1)
        await ackPage(c, [], latest: 0)
        reader.cancel()
        await finish(reader)
        await flush()
        c.receive(live(frame("p1", seq: 1)))
        await flush()
        XCTAssertEqual(im.pushCursor(), 0, "with no subscriber left the frame is dropped (C12)")
    }

    func testStreamStopsBeingASubscriberWhenALoopBreaks() async {
        let (im, t) = make(store: nil)
        let reader = Task { @MainActor in
            for await _ in im.pushes { break }
        }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [frame("p1", seq: 1)], latest: 1)
        await finish(reader)
        await flush()
        XCTAssertEqual(im.pushCursor(), 1)
        c.receive(live(frame("p2", seq: 2)))
        await flush()
        XCTAssertEqual(im.pushCursor(), 1, "a released stream no longer counts")
    }

    func testOnPushAndStreamBothReceive() async {
        let (im, t) = make(store: nil)
        var a: [String] = []
        var b: [String] = []
        im.onPush { a.append($0.pushId) }
        let reader = Task { @MainActor in
            for await p in im.pushes {
                b.append(p.pushId)
                break
            }
        }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [frame("p1", seq: 1)], latest: 1)
        await finish(reader)
        XCTAssertEqual(a, ["p1"])
        XCTAssertEqual(b, ["p1"])
    }

    // MARK: Ordering that the vectors cannot show (each of their steps ends at a scheduling point)

    func testFrameRightAfterSubscribeGoesThroughTheSchedulingPointFirst() async {
        let (im, t) = make(store: nil)
        let c = await auth(im, t)
        c.receive(live(frame("a1", target: "all")))
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        c.receive(live(frame("a2", target: "all")))  // No await: no task has run yet.
        XCTAssertEqual(got, ["a1", "a2"], "the queue first, then the new frame, in arrival order")
        XCTAssertEqual(syncs(t), [["afterSeq": 0, "limit": 100]])
    }

    func testAckIsHandledBeforeTheFrameThatFollowedIt() async {
        let (im, t) = make(store: nil)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        // Same run-loop turn: nothing yields between the two frames.
        c.ack("pushSync", ["pushes": .array([frame("p1", seq: 1)]), "hasMore": false, "latestSeq": 1])
        XCTAssertEqual(im.pushCursor(), 1)
        c.receive(live(frame("p2", seq: 2)))
        XCTAssertEqual(got, ["p1", "p2"])
        XCTAssertEqual(im.pushCursor(), 2)
        XCTAssertEqual(syncs(t).count, 1)
    }

    func testDoesNotWaitForConvsAndFailureLeavesConvsAlone() async {
        // AC-PUSH-03-24
        let (im, t) = make(store: nil)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        XCTAssertEqual(c.frames("convs").count, 1)
        XCTAssertEqual(syncs(t).count, 1, "sent while convs is unanswered")
        await ackPage(c, [frame("p1", seq: 1)], latest: 1)
        XCTAssertEqual(got, ["p1"])
        c.ack("convs", ["convs": .array([conv("group:g1", name: "群")]), "truncated": false])
        await flush()
        XCTAssertEqual(im.conversations().count, 1)

        let (im2, t2) = make(store: nil)
        im2.onPush { _ in }
        await flush()
        let c2 = await auth(im2, t2)
        c2.ackError("pushSync", 5000)
        await flush()
        c2.ack("convs", ["convs": .array([conv("group:g1", name: "群")]), "truncated": false])
        await flush()
        XCTAssertEqual(im2.conversations().count, 1)
    }

    func testRealRequestTimeoutCountsAsFailure() async {
        // C9: the SDK's own 10-second request timeout.
        let clock = FakeClock()
        let (im, t) = make(store: nil, clock: clock)
        im.onPush { _ in }
        await flush()
        await auth(im, t)
        XCTAssertEqual(syncs(t).count, 1)
        clock.advance(10_000)
        XCTAssertEqual(syncs(t).count, 1)
        clock.advance(999)
        XCTAssertEqual(syncs(t).count, 1)
        clock.advance(1)
        XCTAssertEqual(syncs(t).count, 2)
    }

    func testMalformedAckBacksOffAndFrameIsSkipped() async {
        let clock = FakeClock()
        let logs = LogBox()
        let (im, t) = make(store: nil, logs: logs, clock: clock)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        c.ack("pushSync", ["pushes": "nope", "hasMore": false, "latestSeq": 3])
        await flush()
        XCTAssertEqual(im.pushCursor(), 0)
        clock.advance(1000)
        XCTAssertEqual(syncs(t).count, 2)
        // A bad frame in a page is skipped; the rest still arrive. A bad live frame changes nothing.
        await ackPage(c, [["pushId": "bad"], frame("p1", seq: 1)], latest: 1)
        XCTAssertEqual(got, ["p1"])
        c.receive(["cmd": "push", "data": ["pushId": "p2"]])
        await flush()
        XCTAssertEqual(got, ["p1"])
    }

    // MARK: AC-PUSH-03-16: the cursor survives the local database

    func testCursorSurvivesLogoutOnTheSameInstance() async {
        let store = FilePushCursorStore(directory: cursorDir)
        let (im, t) = make(store: store, database: dbDir)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, frames(1...41), latest: 41)
        got = []

        im.disconnect()
        XCTAssertNil(im.pushCursor(), "memory is cleared")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dbDir.path).filter { $0.contains("sqlite") }, [],
            "logout deleted the database")

        let c2 = await auth(im, t, serverTime: 9000)
        await assertResumesAt41(im, t, c2)
        await ackPage(c2, [frame("p41", seq: 41), frame("p42", seq: 42)], latest: 42)
        XCTAssertEqual(got, ["p42"], "seen ids came back from the file too")
    }

    func testCursorSurvivesAKick() async {
        let store = FilePushCursorStore(directory: cursorDir)
        let (im, t) = make(store: store, database: dbDir)
        var fatal = 0
        im.on { if case .fatal = $0 { fatal += 1 } }
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, frames(1...41), latest: 41)
        c.receive(event("kicked", ["reason": "kickedByOtherDevice"]))
        c.drop(4009)
        await flush()
        XCTAssertEqual(fatal, 1)
        got = []

        // Logging in again on the same instance, and on a new one (what the app does).
        let c2 = await auth(im, t, serverTime: 9000)
        await assertResumesAt41(im, t, c2)
        await ackPage(c2, [frame("p41", seq: 41)], latest: 41)
        XCTAssertEqual(got, [])
        im.close()

        let (im3, t3) = make(store: store, database: dbDir)
        im3.onPush { got.append($0.pushId) }
        await flush()
        let c3 = await auth(im3, t3, serverTime: 9000)
        await assertResumesAt41(im3, t3, c3)
        await ackPage(c3, [frame("p41", seq: 41)], latest: 41)
        XCTAssertEqual(got, [])
    }

    func testCursorSurvivesACorruptDatabase() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        await seedCursor41(store, database: dbDir)
        let file = dbDir.appendingPathComponent(LocalDatabase.fileName(userId: "u1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try Data("this is not a sqlite file, not at all".utf8).write(to: file)

        let (im, t) = make(store: store, database: dbDir)
        im.onPush { _ in }
        await flush()
        let c = await auth(im, t)
        XCTAssertNotNil(im.databaseURL, "the database was rebuilt")
        await assertResumesAt41(im, t, c)
    }

    func testCursorSurvivesASchemaUpgrade() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        await seedCursor41(store, database: dbDir)
        let file = dbDir.appendingPathComponent(LocalDatabase.fileName(userId: "u1"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db, "CREATE TABLE IF NOT EXISTS marker(x); INSERT INTO marker VALUES (1); PRAGMA user_version=0;", nil, nil, nil),
            SQLITE_OK)
        sqlite3_close(db)

        let (im, t) = make(store: store, database: dbDir)
        im.onPush { _ in }
        await flush()
        let c = await auth(im, t)
        XCTAssertNotNil(im.databaseURL)
        await assertResumesAt41(im, t, c)

        // The upgrade did run: the version moved on.
        im.close()
        var check: OpaquePointer?
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &check), SQLITE_OK)
        sqlite3_prepare_v2(check, "PRAGMA user_version", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), LocalDatabase.schemaVersion)
        sqlite3_finalize(stmt)
        sqlite3_close(check)
    }

    func testC8ResetSurvivesARestartAndSeenIdsStillDedupe() async {
        let store = FilePushCursorStore(directory: cursorDir)
        await seedCursor41(store)
        let (im, t) = make(store: store)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [], latest: 3)  // latestSeq < afterSeq: C8.
        XCTAssertEqual(syncs(t).last, ["afterSeq": 0, "limit": 100])
        XCTAssertEqual(try store.load(userId: "u1")?.cursor, 0, "the reset is on disk before the process can die")
        im.close()

        let (im2, t2) = make(store: store)
        im2.onPush { got.append($0.pushId) }
        await flush()
        let c2 = await auth(im2, t2)
        XCTAssertEqual(syncs(t2), [["afterSeq": 0, "limit": 100]])
        await ackPage(c2, [frame("p1", seq: 1), frame("p2", seq: 2), frame("new3", seq: 3)], latest: 3)
        XCTAssertEqual(got, ["new3"])
        XCTAssertEqual(im2.pushCursor(), 3)
    }

    func testAccountsKeepSeparateFilesAndCaseDoesNotMerge() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        try store.save(userId: "alice", cursor: 7, recentIds: ["a"])
        try store.save(userId: "Alice", cursor: 9, recentIds: ["b"])
        XCTAssertEqual(try store.load(userId: "alice"), PushCursorRecord(cursor: 7, recentIds: ["a"]))
        XCTAssertEqual(try store.load(userId: "Alice"), PushCursorRecord(cursor: 9, recentIds: ["b"]))
        XCTAssertNil(try store.load(userId: "bob"))
    }

    func testCursorFileHasNumbersAndIdsOnly() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        let logs = LogBox()
        let (im, t) = make(store: store, logs: logs)
        im.onPush { _ in }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [frame("p1", seq: 1, text: MARK)], latest: 1)
        c.receive(live(frame("a1", text: MARK, target: "all")))
        await flush()

        let file = store.fileURL(userId: "u1")
        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data(MARK.utf8)))
        XCTAssertNil(raw.range(of: Data("secret-token-xyz".utf8)))
        let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["cursor", "recentIds"])
        XCTAssertEqual(object["cursor"] as? Int, 1)
        XCTAssertEqual(object["recentIds"] as? [String], ["p1", "a1"])
        XCTAssertEqual(
            try cursorDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testDefaultStoreIsAFileOutsideTheDatabase() {
        let o = IMClientOptions(url: "ws://x")
        let store = o.pushCursorStore as? FilePushCursorStore
        XCTAssertNotNil(store)
        XCTAssertEqual(store?.directory.lastPathComponent, "tianting-push-cursors")
        XCTAssertEqual(
            store?.directory.deletingLastPathComponent().lastPathComponent,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.lastPathComponent)
    }

    func testDamagedCursorFileCountsAsNoCursor() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        try store.save(userId: "u1", cursor: 41, recentIds: [])
        try Data("{".utf8).write(to: store.fileURL(userId: "u1"))
        let logs = LogBox()
        let (im, t) = make(store: store, logs: logs)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        XCTAssertEqual(syncs(t), [["afterSeq": 0, "limit": 100]])
        await ackPage(c, [frame("p1", seq: 1)], latest: 1)
        XCTAssertEqual(got, ["p1"])
        XCTAssertEqual(try store.load(userId: "u1")?.cursor, 1, "the next save repairs the file")
    }

    func testFailedSaveDoesNotStopDelivery() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocked = dir.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: blocked)
        let logs = LogBox()
        let (im, t) = make(store: FilePushCursorStore(directory: blocked), logs: logs)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [frame("p1", seq: 1)], latest: 1)
        c.receive(live(frame("p2", seq: 2)))
        await flush()
        XCTAssertEqual(got, ["p1", "p2"])
        XCTAssertEqual(im.pushCursor(), 2)
        XCTAssertTrue(logs.all.contains { $0.contains("push cursor not saved") })
    }

    // MARK: AC-PUSH-08-7: at-least-once across a crash

    func testCrashBetweenCallbackAndSaveDeliversAgain() async throws {
        let store = CrashingStore()
        try store.save(userId: "u1", cursor: 41, recentIds: [])
        let (im, t) = make(store: store)
        var firstRun: [String] = []
        var diskDuringCallback: Int64?
        im.onPush { [store] p in
            firstRun.append(p.pushId)
            diskDuringCallback = try? store.load(userId: "u1")?.cursor
            store.dead = true  // The process is gone before the batch reaches disk.
        }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [frame("p42", seq: 42, ts: 5000)], latest: 42)
        XCTAssertEqual(firstRun, ["p42"])
        XCTAssertEqual(diskDuringCallback, 41, "the cursor is saved after the delivery, never before")
        XCTAssertEqual(try store.load(userId: "u1")?.cursor, 41)
        im.close()

        // ts is later than the new T0 here: replayed=false. Then earlier than it: replayed=true.
        for (serverTime, replayed) in [(Int64(1000), false), (Int64(9000), true)] {
            let (im2, t2) = make(store: store)
            var second: [Push] = []
            im2.onPush { second.append($0) }
            await flush()
            let c2 = await auth(im2, t2, serverTime: serverTime)
            XCTAssertEqual(syncs(t2), [["afterSeq": 41, "limit": 100]])
            await ackPage(c2, [frame("p42", seq: 42, ts: 5000)], latest: 42)
            XCTAssertEqual(second.map(\.pushId), ["p42"], "delivered exactly once more")
            XCTAssertEqual(second.first?.replayed, replayed)
            im2.close()
        }
    }

    func testBatchIsSavedOncePerEvent() async throws {
        let store = MemoryCursorStore()
        let (im, t) = make(store: store)
        im.onPush { _ in }
        await flush()
        let c = await auth(im, t)
        let before = store.saves
        await ackPage(c, frames(1...100), latest: 100)
        XCTAssertEqual(store.saves, before + 1, "one ack, one write")
        c.receive(live(frame("p101", seq: 101)))
        XCTAssertEqual(store.saves, before + 2, "one live frame, one write, synchronously")
        c.receive(live(frame("p101", seq: 101)))
        XCTAssertEqual(store.saves, before + 2, "nothing changed, nothing written")
    }

    func testDisconnectingInsideACallbackKeepsWhatWasDelivered() async throws {
        let store = MemoryCursorStore()
        let (im, t) = make(store: store)
        var got: [String] = []
        im.onPush { [weak im] p in
            got.append(p.pushId)
            if p.pushId == "a1" { im?.disconnect() }
        }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [], latest: 0)
        c.receive(live(frame("a1", target: "all")))
        await flush()
        XCTAssertEqual(try store.load(userId: "u1")?.recentIds, ["a1"])
    }

    // MARK: AC-PUSH-06-18: the persistent part

    func testDedupeSetOnDiskEvictsInDeliveryOrder() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        var limits = PushLimits()
        limits.seenMax = 2
        let (im, t) = make(store: store, limits: limits)
        var got: [String] = []
        im.onPush { got.append($0.pushId) }
        await flush()
        let c = await auth(im, t)
        await ackPage(c, [], latest: 0)
        for id in ["a", "b", "a", "c"] { c.receive(live(frame(id, target: "all"))) }
        await flush()
        XCTAssertEqual(got, ["a", "b", "c"])
        XCTAssertEqual(try store.load(userId: "u1")?.recentIds, ["b", "c"], "a hit does not refresh; frames without a seq count")
        im.close()

        // After a restart: b is still seen, a is delivered again.
        let (im2, t2) = make(store: store, limits: limits)
        var got2: [String] = []
        im2.onPush { got2.append($0.pushId) }
        await flush()
        let c2 = await auth(im2, t2)
        await ackPage(c2, [], latest: 0)
        for id in ["b", "a"] { c2.receive(live(frame(id, target: "all"))) }
        await flush()
        XCTAssertEqual(got2, ["a"])
    }

    func testDefaultLimitOnDiskKeepsTheNewest2000() async throws {
        let store = FilePushCursorStore(directory: cursorDir)
        let (im, t) = make(store: store)
        im.onPush { _ in }
        await flush()
        let c = await auth(im, t)
        for start in stride(from: Int64(1), through: 2001, by: 100) {
            let end = min(start + 99, 2001)
            await ackPage(c, frames(start...end), latest: end, hasMore: end < 2001)
        }
        let ids = try XCTUnwrap(store.load(userId: "u1")?.recentIds)
        XCTAssertEqual(ids.count, 2000)
        XCTAssertEqual(ids.first, "p2")
        XCTAssertEqual(ids.last, "p2001")
        XCTAssertEqual(try store.load(userId: "u1")?.cursor, 2001)
    }

    func testReplayedIsStrictlyBeforeT0AndT0HoldsAcrossReconnects() async {
        // Section 4.5 rule 4, AC-PUSH-08-1: ts == T0 is not old.
        let (im, t) = make(store: nil)
        var got: [Push] = []
        im.onPush { got.append($0) }
        await flush()
        let c = await auth(im, t, serverTime: 1000)
        await ackPage(c, [frame("old", seq: 1, ts: 999), frame("same", seq: 2, ts: 1000), frame("new", seq: 3, ts: 1001)], latest: 3)
        XCTAssertEqual(got.map(\.replayed), [true, false, false])
        c.drop(1006)
        got = []
        let c2 = await auth(im, t, serverTime: 5000)
        await ackPage(c2, [frame("flash", seq: 4, ts: 2000)], latest: 4)
        XCTAssertEqual(got.map(\.replayed), [false], "T0 stays at the first auth")
    }

    // MARK: F-PUSH-08 rule 3

    func testDataNeverReachesLogsOrDescriptions() async {
        // AC-PUSH-08-3, including the failure paths.
        let logs = LogBox()
        let clock = FakeClock()
        let (im, t) = make(store: nil, logs: logs, clock: clock)
        var got: [Push] = []
        im.onPush { got.append($0) }
        await flush()
        let c = await auth(im, t)
        c.ackError("pushSync", 5000)
        clock.advance(1000)
        await ackPage(c, [frame("p1", seq: 1, text: MARK), ["pushId": "bad", "data": ["text": .string(MARK)]]], latest: 1)
        c.receive(live(frame("p2", seq: 2, text: MARK)))
        c.receive(["cmd": "push", "data": ["pushId": "bad2", "data": ["text": .string(MARK)]]])
        c.drop(1006)
        await flush()
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].data["text"]?.stringValue, MARK, "the app still gets it")
        XCTAssertFalse(logs.all.isEmpty)
        for line in logs.all {
            XCTAssertFalse(line.contains(MARK), line)
            XCTAssertFalse(line.contains("secret-token-xyz"), line)
        }
        XCTAssertFalse(String(describing: got[0]).contains(MARK))
        XCTAssertFalse(String(reflecting: got[0]).contains(MARK))
        var dumped = ""
        dump(got[0], to: &dumped)
        XCTAssertFalse(dumped.contains(MARK))
    }
}
