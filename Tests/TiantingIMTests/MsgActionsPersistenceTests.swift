import Foundation
import SQLite3
import TiantingIMTesting
import XCTest

@testable import TiantingIM

// FE-663 (C4): the local database, the cache folder, cold starts, the upgrade, downloads stopped by a recall
// (AC-RCL-03-2, 03-4, the SDK part of 03-12, 03-13; AC-QUO-02-2, 02-6). A real SQLite file: a new harness on the same
// folder is "the process was killed and started again"; the raw bytes of the database files (journal included) are
// searched. Same cases as sdk-kotlin MsgActionsPersistenceTest.kt. Local `swift test` results, CI not running.

private let AB = C4_AB
private let G = C4_G

/// `/v1/files/urls` for every item (no marker in the URLs).
@MainActor
private final class FakeUrls: FileAuth {
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

private func img(_ convId: String, _ seq: Int64, _ fileId: String) -> JSONValue {
    m(convId, seq, body: ["image": ["fileId": .string(fileId), "width": 10, "height": 10, "size": 3, "mime": "image/png"]], type: "image")
}

private func fileMsg(_ convId: String, _ seq: Int64, _ fileId: String, _ name: String) -> JSONValue {
    m(convId, seq, body: ["file": ["fileId": .string(fileId), "name": .string(name), "size": 3, "mime": "application/pdf"]], type: "file")
}

@MainActor
final class MsgActionsPersistenceTests: IMTestCase {
    private var dir: URL!
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-c4-db-\(UUID().uuidString)")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tt-c4-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A client on the shared database folder and cache folder (a restart reuses both).
    private func open(_ clock: FakeClock? = nil) -> Harness {
        let h = setup(clock: clock, directory: dir, heartbeatMs: 10 * 365 * DAY, scratch: scratch)
        h.fileAuth.target = FakeUrls(h.clock)
        return h
    }

    /// Restarted while offline: shows the cached data.
    private func reopen(_ userId: String = "alice") -> Harness {
        let h = open()
        h.im.restoreCache(userId: userId)
        return h
    }

    private func clean(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(filesContaining(dir, needle), [], "\(needle) is still in the database files", file: file, line: line)
    }

    private func present(_ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(filesContaining(dir, needle).isEmpty, "control: \(needle) should be in the database", file: file, line: line)
    }

    /// Every file in the download cache (recursively), names only.
    private func cached() -> [String] {
        let root = scratch.appendingPathComponent("cache")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { u -> String? in
            guard let u = u as? URL, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return u.lastPathComponent
        }
    }

    private func download(_ h: Harness, _ fileId: String, _ v: FileVariant) -> Task<URL, Error> {
        Task { try await h.im.download(fileId: fileId, variant: v) }
    }

    // MARK: AC-RCL-03-2: the database and the cache folder

    func testTC_RCL_03_02_afterTwoRecallsTheDatabaseHasNoTextOrQuotedTextAndNoCachedFiles() async throws {
        let h = open()
        let c = await h.online("alice", [conv(G, maxSeq: 3, lastMsg: lastOf(G, 3, "carol", "回复"))])
        try await h.loaded(
            c, G,
            [
                m(G, 1, "bob", "\(RCL_SECRET) 原文"), img(G, 2, "f-img"),
                m(G, 3, "carol", body: ["text": "回复", "quote": quoteOf(G, 1, "\(RCL_SECRET) 原文")]),
            ])
        for v in [FileVariant.thumb, .original] {
            let d = download(h, "f-img", v)
            await settle()
            h.objectStore.gets.last!.respond(200, data: Data([1, 2, 3]))
            _ = try await d.value
        }
        XCTAssertEqual(cached().count, 2)
        present(RCL_SECRET)
        c.receive(recalledEvent(G, 1, by: "bob"))
        c.receive(recalledEvent(G, 2, by: "bob"))
        await settle()
        XCTAssertEqual(cached(), [])
        clean(RCL_SECRET)
        h.im.close()
        clean(RCL_SECRET)
        clean("f-img")
        // Cold start: the recalls and the cleared quote are there, the text is not.
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(G).map(\.isRecalled), [true, true, false])
        XCTAssertEqual(h2.bySeq(G, 3).body.quote?.state, .recalled)
        XCTAssertFalse(holds(h2.im.store, RCL_SECRET))
    }

    // MARK: AC-RCL-03-4: recalled while the app was killed

    func testTC_RCL_03_04_recalledWhileKilledColdStartResyncsByModVerAndTheDatabaseHasNoText() async throws {
        let h = open()
        let c = await h.online("bob", [conv(AB, maxSeq: 2, modVer: 1)])
        try await h.loaded(
            c, AB,
            [
                m(AB, 1, "alice", "\(RCL_SECRET) 原文"),
                m(AB, 2, "alice", body: ["text": "补一句", "quote": quoteOf(AB, 1, "\(RCL_SECRET) 原文", from: "alice")]),
            ])
        h.im.close()  // Killed: the database stays.
        present(RCL_SECRET)

        let h2 = open()
        h2.im.restoreCache(userId: "bob")
        XCTAssertEqual(h2.bySeq(AB, 1).body.text, "\(RCL_SECRET) 原文")  // Offline it still shows the last content.
        let c2 = await h2.online(
            "bob",
            [conv(AB, maxSeq: 2, lastMsg: ["msgId": .string(idOf(AB, 2)), "from": "alice", "type": "text", "text": "补一句", "ts": 1002], modVer: 2)])
        await settle()
        XCTAssertEqual(c2.frames("sync").map { $0.data?["convId"]?.stringValue }, [AB])
        c2.ack(
            "sync",
            [
                "messages": [
                    recalledMsg(AB, 1, "alice"),
                    m(AB, 2, "alice", body: [
                        "text": "补一句",
                        "quote": ["msgId": .string(idOf(AB, 1)), "seq": 1, "from": "alice", "type": "text", "state": "recalled"],
                    ]),
                ],
                "hasMore": false,
            ])
        await settle()
        let x = h2.bySeq(AB, 1)
        XCTAssertTrue(x.isRecalled)
        XCTAssertEqual(h2.im.recallText(x), "对方撤回了一条消息")
        XCTAssertEqual(quoteLabel(h2.bySeq(AB, 2).body.quote!), "引用内容已被撤回")
        clean(RCL_SECRET)
        h2.im.close()
        clean(RCL_SECRET)
    }

    // MARK: AC-RCL-03-13 across a cold start: deleted_refs (problem 17)

    func testTC_RCL_03_13_unloadedRecallLivesInDeletedRefsLateOldAnswerAfterColdStartRestoresNothing() async throws {
        let h = open()
        let c = await h.online("alice", [conv(G, maxSeq: 6)])
        try await h.loaded(c, G, [m(G, 6, "carol", "最新")])  // m4, m5 never loaded.
        c.receive(recalledEvent(G, 5, by: "bob", at: 77))
        h.im.close()

        let h2 = open()
        let c2 = await h2.online("alice", [conv(G, maxSeq: 6)])
        let late = [
            m(G, 4, "carol", body: ["text": "回复", "quote": quoteOf(G, 5, "\(RCL_SECRET) 原文")]),
            m(G, 5, "bob", "\(RCL_SECRET) 原文"),
        ]
        let t = Task { try await h2.im.loadHistory(G) }
        await settle()
        c2.ack("sync", ["messages": .array(late), "hasMore": false])
        _ = try await t.value
        let m5 = h2.bySeq(G, 5)
        XCTAssertTrue(m5.isDeleted && m5.isRecalled)
        XCTAssertEqual(m5.recalledBy, "bob")
        XCTAssertEqual(m5.recalledAt, 77)
        XCTAssertEqual(h2.im.recallText(m5), "bob撤回了一条消息")
        XCTAssertEqual(h2.bySeq(G, 4).body.quote, QuoteView(msgId: idOf(G, 5), seq: 5, from: "bob", type: .text, state: .recalled))
        XCTAssertFalse(holds(h2.im.store, RCL_SECRET))
        clean(RCL_SECRET)
        let url = h2.im.databaseURL!
        h2.im.close()
        clean(RCL_SECRET)
        XCTAssertEqual(Set(try rows(url, "SELECT kind FROM deleted_refs")), ["id", "seq", "recalled"])
    }

    // MARK: AC-QUO-02-2: quoted text in memory and in the database

    func testTC_QUO_02_02_recalledQuotedMessageLeavesNoQuotedTextInTheDatabaseColdStartShowsRecalled() async throws {
        let h = open()
        let c = await h.online("alice", [conv(G, maxSeq: 2)])
        try await h.loaded(
            c, G,
            [m(G, 1, "bob", "\(QUO_SECRET) 原文"), m(G, 2, "carol", body: ["text": "回复", "quote": quoteOf(G, 1, "\(QUO_SECRET) 原文")])])
        c.drop(1006)
        await settle()
        _ = try h.im.send(G, "我也回复", quote: QuoteRef(msgId: idOf(G, 1)))  // Queued: unsent text stays in memory only.
        present(QUO_SECRET)
        let c2 = await h.reconnect()
        c2.receive(recalledEvent(G, 1, by: "bob"))
        clean(QUO_SECRET)
        XCTAssertFalse(holds(h.im.store, QUO_SECRET))
        h.im.close()
        clean(QUO_SECRET)
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(G).compactMap(\.body.quote).map(quoteLabel), ["引用内容已被撤回"])
    }

    /// Without secure_delete, a cleared quote VACUUMs the file like a deletion (problem 35).
    func testVacuumFallbackScrubsAClearedQuote() throws {
        let url = dir.appendingPathComponent("fallback.sqlite")
        let db = try LocalDatabase(url: url, refuseSecureDelete: true)
        defer { db.close() }
        func message(_ q: QuoteView) -> Message {
            Message(
                clientMsgId: "c2", msgId: "m2", seq: 2, convId: G, from: "carol", type: .text,
                body: MsgBody(text: "回复", quote: q), ts: 1, status: .sent, error: nil, deleted: nil, deletedAt: nil)
        }
        // Long enough for overflow pages: those go to the freelist as they are when secure_delete is off.
        let long = "\(QUO_SECRET) " + String(repeating: "长", count: 2000)
        try db.apply(LocalChanges(upsertMessages: [message(QuoteView(msgId: "m1", seq: 1, text: long))]))
        present(QUO_SECRET)
        try db.apply(LocalChanges(upsertMessages: [message(QuoteView(msgId: "m1", seq: 1, state: .recalled))], wiped: true))
        clean(QUO_SECRET)
    }

    // MARK: The SDK part of AC-RCL-03-12: recalled while downloading (problem 33)

    func testTC_RCL_03_12_downloadStopsOnRecallThrowsDownloadAbortedEmitsEventLeavesNoPartialFile() async throws {
        let h = open()
        let c = await h.online("alice", [conv(AB, maxSeq: 2)])
        try await h.loaded(c, AB, [fileMsg(AB, 1, "f-big", "ZXQ-FILE-NAME.pdf"), fileMsg(AB, 2, "f-other", "other.pdf")])
        let d = download(h, "f-big", .original)
        let other = download(h, "f-other", .original)
        await settle()
        let get = h.objectStore.gets.first { $0.url.contains("f-big") }!
        try Data(repeating: 7, count: 1000).write(to: get.file)  // Half written.
        get.progress(1000, of: 4000)
        XCTAssertTrue(cached().contains { $0.contains(".part") })
        c.receive(recalledEvent(AB, 1, by: "bob"))
        await settle()
        guard get.cancelled else {
            XCTFail("the download was not stopped")
            get.respond(200, data: Data([1]))  // Let the task end instead of hanging the run.
            return
        }
        do {
            _ = try await d.value
            XCTFail("expected DownloadAbortedError")
        } catch {
            XCTAssertEqual(error as? DownloadAbortedError, DownloadAbortedError(fileId: "f-big", recalled: true))
        }
        XCTAssertTrue(get.cancelled)
        let aborted = h.events.compactMap { e -> String? in
            if case .downloadAborted(let id, let r) = e { return "\(id):\(r)" } else { return nil }
        }
        XCTAssertEqual(aborted, ["f-big:true"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: get.file.path))  // The partial file is gone.
        // Another file's download goes on.
        h.objectStore.gets.first { $0.url.contains("f-other") }!.respond(200, data: Data([1]))
        let otherURL = try await other.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
        XCTAssertEqual(cached().count, 1)
        // A console deletion (not a recall) stops it too, recalled == false.
        let d2 = download(h, "f-other", .thumb)
        await settle()
        c.receive(deletedEvent(AB, 2))
        await settle()
        do {
            _ = try await d2.value
            XCTFail("expected DownloadAbortedError")
        } catch {
            XCTAssertEqual(error as? DownloadAbortedError, DownloadAbortedError(fileId: "f-other", recalled: false))
        }
        XCTAssertEqual(cached(), [])  // The partial file and the earlier download both went.
        XCTAssertFalse(h.logs.all.joined().contains("ZXQ-FILE"))
    }

    func testCancellingTheDownloadYourselfThrowsCancelledWithoutDownloadAborted() async throws {
        let h = open()
        let c = await h.online("alice", [conv(AB, maxSeq: 1)])
        try await h.loaded(c, AB, [fileMsg(AB, 1, "f-big", "a.pdf")])
        let d = download(h, "f-big", .original)
        await settle()
        d.cancel()
        await settle()
        do {
            _ = try await d.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertEqual(error as? FileTransferError, .cancelled)
        }
        func aborted() -> Int { h.events.filter { if case .downloadAborted = $0 { return true } else { return false } }.count }
        XCTAssertEqual(aborted(), 0)
        XCTAssertEqual(cached(), [])
        c.receive(recalledEvent(AB, 1, by: "bob"))  // Recalled afterwards: nothing is running any more.
        XCTAssertEqual(aborted(), 0)
    }

    // MARK: Mention counts in the database (FE-664 / FE-662 item 1)

    func testMentionCountsPersistAcrossColdStartsAndClearingOnReadIsStoredToo() async throws {
        let h = open()
        let c = await h.online("alice", [conv(G, maxSeq: 9, readSeq: 4, unread: 5, mentionUnread: 2, firstMentionSeq: 5)])
        c.receive(msgFrame(m(G, 10, "bob", body: ["text": "@所有人", "mentions": ["all": true]])))
        h.im.close()
        let h2 = reopen()
        XCTAssertEqual(h2.convOf(G).mentionUnread, 3)
        XCTAssertEqual(h2.convOf(G).firstMentionSeq, 5)
        let c2 = await h2.online("alice", [conv(G, maxSeq: 10, readSeq: 4, unread: 6, mentionUnread: 3, firstMentionSeq: 5)])
        h2.im.setActiveConversation(G)
        await settle()
        XCTAssertEqual(c2.last("read")?.data, ["convId": .string(G), "seq": 10])
        XCTAssertEqual(h2.convOf(G).mentionUnread, 0)
        h2.im.close()
        let h3 = reopen()
        XCTAssertEqual(h3.convOf(G).mentionUnread, 0)
        XCTAssertNil(h3.convOf(G).firstMentionSeq)
    }

    // MARK: Version 2 -> 3 (problem 34)

    private func rows(_ url: URL, _ sql: String) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw LocalDatabaseError(description: "open") }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw LocalDatabaseError(description: "prepare") }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? String(sqlite3_column_int64(stmt, 0)))
        }
        return out
    }

    private func execRaw(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw LocalDatabaseError(description: "open")
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalDatabaseError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// A version 2 file as the C2 SDK (c8ec6ff) wrote it: conversation (with its modVer baseline), a sent and a deleted
    /// message, an outbox row.
    private func createV2(version: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent(LocalDatabase.fileName(userId: "alice"))
        let state = #"{"view":{"convId":"group:g1","type":"group","name":"老群","maxSeq":3,"readSeq":2,"minSeq":1,"unread":1,"updatedAt":5,"modVer":4},"readBase":2,"checkedModVer":4}"#
        let m1 = #"{"clientMsgId":"x1","msgId":"\#(idOf(G, 1))","seq":1,"convId":"group:g1","from":"bob","type":"text","body":{"text":"老消息"},"ts":5,"status":"sent"}"#
        let m2 = #"{"clientMsgId":"x2","msgId":"\#(idOf(G, 2))","seq":2,"convId":"group:g1","from":"bob","type":"text","body":{},"ts":6,"status":"sent","deleted":true}"#
        try execRaw(
            url,
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
            INSERT INTO conversations VALUES ('group:g1', '\(state)');
            INSERT INTO messages VALUES ('group:g1', 1, '\(m1)');
            INSERT INTO messages VALUES ('group:g1', 2, '\(m2)');
            PRAGMA user_version=\(version);
            """)
        return url
    }

    func testDatabaseVersion2UpgradesInPlaceTo3KeepingRowsAndBaselineOldRowsDecodeWithoutC4Fields() async throws {
        let url = try createV2()
        let h = reopen()
        XCTAssertEqual(statusOf(h, G), ["x1:sent#1", "x2:sent#2"])
        XCTAssertTrue(h.bySeq(G, 2).isDeleted)
        XCTAssertFalse(h.bySeq(G, 2).isRecalled)
        XCTAssertEqual(h.convOf(G).name, "老群")
        XCTAssertNil(h.convOf(G).mentionUnread)
        // modVer unchanged: no re-sync (the baseline stayed); only the catch-up for seq 3.
        let c = await h.online("alice", [conv(G, maxSeq: 3, readSeq: 2, unread: 1, modVer: 4)])
        await settle()
        XCTAssertEqual(c.frames("sync").count, 1)
        c.ack("sync", ["messages": [m(G, 2, "bob", "ZXQ-DEL-OLD"), m(G, 3)], "hasMore": false])
        await settle()
        XCTAssertTrue(h.bySeq(G, 2).isDeleted)
        c.receive(recalledEvent(G, 1, by: "bob"))
        h.im.close()
        XCTAssertEqual(try rows(url, "PRAGMA user_version"), ["3"])
        XCTAssertEqual(Set(try rows(url, "SELECT DISTINCT kind FROM deleted_refs")), ["id", "seq", "recalled"])
        XCTAssertEqual(try rows(url, "SELECT count(*) FROM outbox"), ["0"])
        clean("ZXQ-DEL-OLD")
        clean("老消息")
        let h2 = reopen()
        XCTAssertEqual(h2.im.messages(G).map { "\($0.isDeleted):\($0.isRecalled)" }, ["true:true", "true:false", "false:false"])
    }

    func testDatabaseVersion1UpgradesInPlaceTo3() async throws {
        let url = dir.appendingPathComponent(LocalDatabase.fileName(userId: "alice"))
        let state = #"{"view":{"convId":"group:g1","type":"group","name":"v1 群","maxSeq":1,"readSeq":1,"minSeq":1,"unread":0,"updatedAt":5},"readBase":1}"#
        try execRaw(
            url,
            """
            CREATE TABLE conversations (conv_id TEXT PRIMARY KEY, state TEXT NOT NULL);
            CREATE TABLE messages (conv_id TEXT NOT NULL, seq INTEGER NOT NULL, message TEXT NOT NULL, PRIMARY KEY (conv_id, seq));
            CREATE TABLE social_meta (id INTEGER PRIMARY KEY CHECK (id = 1), social_ver INTEGER NOT NULL,
              request_seen_ver INTEGER NOT NULL, settings TEXT NOT NULL, official INTEGER NOT NULL, loaded INTEGER NOT NULL);
            CREATE TABLE friends (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            CREATE TABLE friend_requests (user_id TEXT NOT NULL, direction TEXT NOT NULL, item TEXT NOT NULL,
              PRIMARY KEY (user_id, direction));
            CREATE TABLE blocks (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            INSERT INTO conversations VALUES ('group:g1', '\(state)');
            PRAGMA user_version=1;
            """)
        let h = reopen()
        XCTAssertEqual(h.convOf(G).name, "v1 群")
        h.im.close()
        XCTAssertEqual(try rows(url, "PRAGMA user_version"), ["3"])
        XCTAssertEqual(try rows(url, "SELECT count(*) FROM deleted_refs"), ["0"])
        XCTAssertEqual(try rows(url, "SELECT count(*) FROM outbox"), ["0"])
    }

    func testDatabaseVersionNewerThan3IsRebuiltAsACache() async throws {
        let url = try createV2(version: 4)
        let h = reopen()
        XCTAssertEqual(h.im.conversations(), [])
        h.im.close()
        XCTAssertEqual(try rows(url, "PRAGMA user_version"), ["3"])
        clean("老消息")
    }
}
