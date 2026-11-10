import Foundation
import SQLite3
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-682 (C5): the local database and the download cache. AC-CVS-03-10 (TC-CVS-03-10, sdk-swift part), the physical
// purge of F-CVS-03 rule 6 ②, the purge that failed or was cut short running again on the next start (F-CVS-03
// exceptions), pinned and notifications off shown on a cold start (F-CVS-04 rule 2), the version 3 -> 4 upgrade. A real
// SQLite file; a new harness on the same folders is "the process was killed and started again"; the raw bytes of every
// file in the database folder (journal included) and in the cache folder are searched. Local `swift test` results.

private let AB = CVS_AB
private let G1 = CVS_G1
private let SECRET = "ZXQ-CVS-10"
private let FILE_SECRET = "ZXQ-CVS-10-FILE"

/// `/v1/files/urls` for every item (no marker in the URLs).
@MainActor
private final class Urls: FileAuth {
    let clock: FakeClock
    init(_ clock: FakeClock) { self.clock = clock }
    func authorized(_ method: HttpMethod, _ path: String, body: JSONValue?) async throws -> JSONValue {
        let items = body?["items"]?.arrayValue ?? []
        return [
            "items": .array(
                items.map {
                    [
                        "fileId": $0["fileId"]!, "variant": $0["variant"]!,
                        "url": .string("https://s3.test/\($0["fileId"]!.stringValue!)/\($0["variant"]!.stringValue!)?sig"),
                        "expiresAt": .int(clock.now() + 120_000),
                    ]
                })
        ]
    }
}

private func pic(_ convId: String, _ seq: Int64, _ fileId: String) -> JSONValue {
    m(convId, seq, body: ["image": ["fileId": .string(fileId), "width": 10, "height": 10, "size": 3, "mime": "image/png"]], type: "image")
}

@MainActor
final class ConvSettingsPersistenceTests: IMTestCase {
    private var dir: URL!
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-c5-db-\(UUID().uuidString)")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tt-c5-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: scratch)
    }

    private var url: URL { dir.appendingPathComponent(LocalDatabase.fileName(userId: "alice")) }

    private func open() -> Harness {
        let h = setup(directory: dir, heartbeatMs: 10 * 365 * DAY, scratch: scratch)
        h.fileAuth.target = Urls(h.clock)
        return h
    }

    /// Restarted while offline: shows the cached data.
    private func reopen() -> Harness {
        let h = open()
        h.im.restoreCache(userId: "alice")
        return h
    }

    /// Database folder and cache folder, every file, raw bytes.
    private func onDisk(_ needle: String) -> [String] {
        let bytes = Data(needle.utf8)
        var out: [String] = []
        for root in [dir!, scratch.appendingPathComponent("cache")] {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let u as URL in e where (try? Data(contentsOf: u))?.range(of: bytes) != nil {
                out.append(u.lastPathComponent)
            }
        }
        return out
    }

    private func clean(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(onDisk(needle), [], "\(needle) is still on disk", file: file, line: line)
    }

    private func present(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(onDisk(needle).isEmpty, "control: \(needle) should be on disk", file: file, line: line)
    }

    private func cached() -> [String] {
        let root = scratch.appendingPathComponent("cache")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { u -> String? in
            guard let u = u as? URL, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return u.lastPathComponent
        }
    }

    private func rows(_ sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw LocalDatabaseError(description: "open") }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw LocalDatabaseError(description: "prepare") }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }

    private func execRaw(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw LocalDatabaseError(description: "open")
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalDatabaseError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Online with AB holding 10 messages with the marker (seq 3 an image whose cached download holds the file marker).
    private func seeded() async throws -> (Harness, FakeConnection) {
        let h = open()
        let c = await h.cvsOnline([sc(AB, name: "Bob", maxSeq: 10, readSeq: 10, updatedAt: 10)])
        try await h.cvsLoaded(c, AB, (1...10).map { $0 == 3 ? pic(AB, 3, "F-CVS") : cm(AB, $0, "bob", "\(SECRET) 第 \($0) 条") })
        for v in [FileVariant.thumb, .original] {
            let d = Task { try await h.im.download(fileId: "F-CVS", variant: v) }
            await settle()
            h.objectStore.gets.last!.respond(200, data: Data("\(FILE_SECRET) \(v)".utf8))
            _ = try await d.value
        }
        XCTAssertEqual(cached().count, 2)
        present(SECRET)
        present(FILE_SECRET)
        return (h, c)
    }

    // MARK: AC-CVS-03-10

    /// TC-CVS-03-10 (sdk-swift): D2 offline holds the c2c conversation with the marker; D1 deletes it, u2 sends one more;
    /// D2 starts again and comes online. Its database files and cache folder hold no marker, it shows only the new message.
    func testTC_CVS_03_10_offlineDeviceRestartsAfterADeletionNoOldTextInDatabaseOrCacheOnlyTheNewMessage() async throws {
        let (h, _) = try await seeded()
        h.im.close()  // D2 offline, the app killed: the database stays.
        present(SECRET)
        // Meanwhile D1 deleted up to 10 and u2 sent seq 11: the server's convs has minSeq 11, `deleted` no longer has it.
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(AB).count, 10)  // Offline it still shows the cached content.
        let c2 = await h2.cvsOnline([sc(AB, name: "Bob", maxSeq: 11, readSeq: 10, minSeq: 11, unread: 1, updatedAt: 11)])
        XCTAssertEqual(c2.last("sync")?.data?["afterSeq"], 10)
        downAck(c2, "sync", ["messages": [cm(AB, 11, "bob", "新的一条")], "hasMore": false])
        await settle()
        XCTAssertEqual(h2.im.messages(AB).map(\.seq), [11])
        XCTAssertEqual(h2.find(AB)?.unread, 1)
        XCTAssertEqual(h2.expiredFiles, [["F-CVS"]])
        clean(SECRET)
        clean(FILE_SECRET)
        XCTAssertEqual(cached(), [])
        XCTAssertEqual(try rows("SELECT count(*) FROM pending_purges"), ["0"])
        XCTAssertFalse(holds(h2.im.store, SECRET))
        h2.im.close()
        clean(SECRET)
        let h3 = reopen()
        XCTAssertEqual(h3.im.messages(AB).map { $0.body.text }, ["新的一条"])
        XCTAssertEqual(h3.find(AB)?.minSeq, 11)
    }

    // MARK: AC-CVS-04-5 with the database

    func testTC_CVS_04_05_convDeletedPurgesTheDatabaseAndTheCacheTheConversationRowGoes() async throws {
        let (h, c) = try await seeded()
        downEvent(c, "convDeleted", ["convId": .string(AB), "clearedSeq": 10])
        XCTAssertEqual(h.ids, [])
        XCTAssertEqual(h.convDeletedIds, [AB])
        clean(SECRET)  // Already on disk before the app hears about it.
        clean(FILE_SECRET)
        XCTAssertEqual(cached(), [])
        XCTAssertEqual(try rows("SELECT count(*) FROM messages"), ["0"])
        XCTAssertEqual(try rows("SELECT conv_id FROM conversations"), [])
        XCTAssertEqual(try rows("SELECT count(*) FROM pending_purges"), ["0"])
        h.im.close()
        let h2 = reopen()
        XCTAssertEqual(h2.ids, [])
        XCTAssertEqual(h2.im.messages(AB), [])
    }

    func testDeleteConvPurgesTheDatabaseAndTheCache() async throws {
        let (h, c) = try await seeded()
        let p = Task { try await h.im.deleteConv(AB) }
        await flush()
        present(SECRET)  // Not before the ack.
        downAck(c, "convDelete", ["clearedSeq": 10])
        try await p.value
        clean(SECRET)
        clean(FILE_SECRET)
        XCTAssertEqual(try rows("SELECT count(*) FROM messages"), ["0"])
        // A conversation kept because it has newer messages keeps only those on disk.
        down(c, msgFrame(cm(AB, 11, "bob", "ZXQ-CVS-NEW")))
        await flush()
        XCTAssertEqual(try rows("SELECT seq FROM messages"), ["11"])
        h.im.close()
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(AB).map(\.seq), [11])
        XCTAssertEqual(h2.find(AB)?.minSeq, 11)
        XCTAssertEqual(h2.find(AB)?.unread, 1)
    }

    // F-CVS-03 rule 6 ②: a conversation in the list is purged below its minSeq on disk too.
    func testConvsMinSeqPurgesListedConversationsOnDisk() async throws {
        let (h, c) = try await seeded()
        let n = await h.cvsReconnect(c, [
            "convs": [sc(AB, name: "Bob", maxSeq: 10, readSeq: 10, minSeq: 6, updatedAt: 10)], "truncated": false,
        ])
        _ = n
        XCTAssertEqual(try rows("SELECT seq FROM messages ORDER BY seq"), ["6", "7", "8", "9", "10"])
        for s in 1...5 where s != 3 { XCTAssertEqual(onDisk("\(SECRET) 第 \(s) 条"), [], "\(s)") }
        XCTAssertFalse(onDisk("\(SECRET) 第 6 条").isEmpty)
        clean(FILE_SECRET)
        h.im.close()
    }

    // MARK: F-CVS-03 exceptions: a purge that did not finish runs again on the next start

    func testAPurgeCutShortAfterItsRecordRunsAgainOnTheNextStartRowsPagesAndCachedFiles() async throws {
        let (h, _) = try await seeded()
        h.im.close()
        // The process dies right after the purge was recorded (the rows still there).
        let db = try LocalDatabase(url: url)
        db.interruptNextPurge = true
        XCTAssertThrowsError(try db.apply(LocalChanges(purges: [(AB, 11)])))
        db.close()
        XCTAssertEqual(try rows("SELECT conv_id || ':' || min_seq FROM pending_purges"), ["\(AB):11"])
        present(SECRET)
        XCTAssertEqual(cached().count, 2)
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(AB), [])
        clean(SECRET)
        clean(FILE_SECRET)
        XCTAssertEqual(cached(), [])
        XCTAssertEqual(try rows("SELECT count(*) FROM pending_purges"), ["0"])
        XCTAssertEqual(h2.find(AB)?.name, "Bob")  // Only the messages went.
    }

    /// The same without secure_delete: the VACUUM fallback of C4.
    func testAPurgeCutShortRunsAgainWithTheVacuumFallback() throws {
        let fallback = dir.appendingPathComponent("fallback.sqlite")
        func message(_ seq: Int64, _ text: String) -> Message {
            Message(
                clientMsgId: "c\(seq)", msgId: "m\(seq)", seq: seq, convId: AB, from: "bob", type: .text,
                body: MsgBody(text: text), ts: 1, status: .sent, error: nil, deleted: nil, deletedAt: nil)
        }
        // Long enough for overflow pages: those go to the freelist as they are when secure_delete is off.
        let long = "\(SECRET) " + String(repeating: "长", count: 3000)
        do {
            let db = try LocalDatabase(url: fallback, refuseSecureDelete: true)
            try db.apply(LocalChanges(upsertMessages: [message(1, long), message(2, "留下")]))
            db.interruptNextPurge = true
            XCTAssertThrowsError(try db.apply(LocalChanges(purges: [(AB, 2)])))
            db.close()
        }
        XCTAssertFalse(filesContaining(dir, SECRET).isEmpty)
        let db = try LocalDatabase(url: fallback, refuseSecureDelete: true)
        XCTAssertTrue(try db.hasPendingPurges())
        XCTAssertEqual(try db.runPendingPurges(), [])
        try db.finishPurges()
        XCTAssertFalse(try db.hasPendingPurges())
        XCTAssertEqual(try db.loadChat(maxMessagesPerConversation: 100).messages.map(\.seq), [2])
        db.close()
        XCTAssertEqual(filesContaining(dir, SECRET), [])
    }

    func testThePurgeWithoutSecureDeleteVacuums() throws {
        let fallback = dir.appendingPathComponent("vacuum.sqlite")
        let db = try LocalDatabase(url: fallback, refuseSecureDelete: true)
        defer { db.close() }
        let long = "\(SECRET) " + String(repeating: "长", count: 3000)
        try db.apply(LocalChanges(upsertMessages: [
            Message(
                clientMsgId: "c1", msgId: "m1", seq: 1, convId: AB, from: "bob", type: .text, body: MsgBody(text: long), ts: 1,
                status: .sent, error: nil, deleted: nil, deletedAt: nil)
        ]))
        XCTAssertFalse(filesContaining(dir, SECRET).isEmpty)
        try db.apply(LocalChanges(purges: [(AB, 2)]))
        XCTAssertEqual(filesContaining(dir, SECRET), [])
        XCTAssertTrue(try db.hasPendingPurges())  // Until the client has removed the cached files too.
    }

    /// A purge write that fails drops the whole cache (the C4 rule): nothing of the conversation stays on disk.
    func testAFailedPurgeDropsTheCache() async throws {
        let (h, c) = try await seeded()
        h.im.database?.interruptNextPurge = true
        downEvent(c, "convDeleted", ["convId": .string(AB), "clearedSeq": 10])
        XCTAssertNil(h.im.databaseURL)
        clean(SECRET)
        clean(FILE_SECRET)
        XCTAssertEqual(h.im.messages(AB), [])
    }

    // MARK: F-CVS-04 rule 2: shown first on a cold start, the server's convs wins

    func testPinnedAndNotifyOffShowOnAColdStartThenConvsWins() async throws {
        let h = open()
        _ = await h.cvsOnline([
            sc(AB, maxSeq: 2, unread: 2, updatedAt: 9), sc(G1, maxSeq: 4, unread: 4, updatedAt: 1, pinned: true, pinnedAt: 7),
            sc(CVS_AC, maxSeq: 3, unread: 3, updatedAt: 5, notifyOff: true),
        ])
        h.im.close()
        let h2 = reopen()
        XCTAssertEqual(h2.ids, [G1, AB, CVS_AC])
        XCTAssertEqual(h2.find(G1)?.pinnedAt, 7)
        XCTAssertEqual(h2.find(CVS_AC)?.notifyOff, true)
        XCTAssertEqual(h2.im.totalUnread(), 6)
        _ = await h2.cvsOnline([
            sc(AB, maxSeq: 2, unread: 2, updatedAt: 9, pinned: true, pinnedAt: 8), sc(G1, maxSeq: 4, unread: 4, updatedAt: 1),
            sc(CVS_AC, maxSeq: 3, unread: 3, updatedAt: 5),
        ])
        XCTAssertEqual(h2.ids, [AB, CVS_AC, G1])
        XCTAssertEqual(h2.im.totalUnread(), 9)
        h2.im.close()
        let h3 = reopen()
        XCTAssertEqual(h3.ids, [AB, CVS_AC, G1])
        XCTAssertNil(h3.find(CVS_AC)?.notifyOff)
        XCTAssertNil(h3.find(G1)?.pinned)
    }

    func testAnotherDevicesSettingIsStored() async throws {
        let h = open()
        let c = await h.cvsOnline([sc(AB, updatedAt: 9), sc(G1, updatedAt: 1)])
        downEvent(c, "convSettingsChanged", ["convId": .string(G1), "pinned": true, "pinnedAt": 50, "notifyOff": true])
        h.im.close()
        let h2 = reopen()
        XCTAssertEqual(h2.ids, [G1, AB])
        XCTAssertEqual(h2.find(G1)?.notifyOff, true)
    }

    // MARK: Version 3 -> 4

    func testDatabaseVersion3UpgradesInPlaceTo4KeepingRowsAndRefs() async throws {
        let state = #"{"view":{"convId":"group:g1","type":"group","name":"C4 群","maxSeq":2,"readSeq":2,"minSeq":1,"unread":0,"updatedAt":5,"modVer":4,"mentionUnread":0},"readBase":2,"checkedModVer":4}"#
        let m1 = #"{"clientMsgId":"x1","msgId":"\#(idOf(G1, 1))","seq":1,"convId":"group:g1","from":"bob","type":"text","body":{},"ts":5,"status":"sent","deleted":true,"recalled":true,"recalledBy":"bob"}"#
        let m2 = #"{"clientMsgId":"x2","msgId":"\#(idOf(G1, 2))","seq":2,"convId":"group:g1","from":"bob","type":"text","body":{"text":"C4 的消息"},"ts":6,"status":"sent"}"#
        try execRaw(
            """
            CREATE TABLE conversations (conv_id TEXT PRIMARY KEY, state TEXT NOT NULL);
            CREATE TABLE messages (conv_id TEXT NOT NULL, seq INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY (conv_id, seq));
            CREATE TABLE social_meta (id INTEGER PRIMARY KEY CHECK (id = 1), social_ver INTEGER NOT NULL,
              request_seen_ver INTEGER NOT NULL, settings TEXT NOT NULL, official INTEGER NOT NULL, loaded INTEGER NOT NULL);
            CREATE TABLE friends (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            CREATE TABLE friend_requests (user_id TEXT NOT NULL, direction TEXT NOT NULL, item TEXT NOT NULL,
              PRIMARY KEY (user_id, direction));
            CREATE TABLE blocks (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            \(LocalDatabase.outboxSchema)
            \(LocalDatabase.refsSchema)
            INSERT INTO conversations VALUES ('group:g1', '\(state)');
            INSERT INTO messages VALUES ('group:g1', 1, '\(m1)');
            INSERT INTO messages VALUES ('group:g1', 2, '\(m2)');
            INSERT INTO deleted_refs VALUES ('group:g1', 'id', '\(idOf(G1, 1))');
            PRAGMA user_version=3;
            """)
        let h = reopen()
        XCTAssertEqual(try rows("PRAGMA user_version"), ["4"])
        XCTAssertEqual(try rows("SELECT count(*) FROM pending_purges"), ["0"])
        XCTAssertEqual(h.find(G1)?.name, "C4 群")
        XCTAssertNil(h.find(G1)?.pinned)
        XCTAssertNil(h.find(G1)?.notifyOff)
        XCTAssertEqual(h.im.messages(G1).map { "\($0.seq!):\($0.isRecalled)" }, ["1:true", "2:false"])
        // The upgraded file takes C5 state.
        let c = await h.cvsOnline([sc(G1, name: "C4 群", maxSeq: 2, readSeq: 2, updatedAt: 5, pinned: true, pinnedAt: 3, notifyOff: true)])
        downEvent(c, "convDeleted", ["convId": .string(G1), "clearedSeq": 1])
        await flush()
        h.im.close()
        XCTAssertEqual(try rows("SELECT seq FROM messages"), ["2"])
        let h2 = reopen()
        XCTAssertEqual(h2.find(G1)?.notifyOff, true)
        XCTAssertNil(h2.find(G1)?.pinned)
        XCTAssertEqual(h2.find(G1)?.minSeq, 2)
        XCTAssertEqual(h2.im.messages(G1).map(\.seq), [2])
    }
}
