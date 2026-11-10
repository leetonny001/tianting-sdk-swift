import Foundation
import SQLite3

/// What the SDK needs from a stored social snapshot.
struct StoredSocial {
    var ver: Int64
    var requestSeenVer: Int64
    var settings: SocialSettings
    var official: Bool
    var loaded: Bool
    var friends: [FriendItem]
    var requests: [RequestItem]
    var blocks: [BlockItem]
}

struct LocalDatabaseError: Error, CustomStringConvertible {
    let description: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The local cache: one SQLite file per user, holding conversations, confirmed messages and social state.
///
/// Deleted text must be unrecoverable from the files on disk (AC-ADM-31-4), which drives the configuration:
/// - `secure_delete=ON` zeroes freed cells and pages, so an UPDATE that drops a body leaves no text in the file.
/// - `journal_mode=DELETE`, not WAL: a WAL file keeps old page images (text included) next to the database until a
///   checkpoint succeeds, and that checkpoint can be blocked. A rollback journal is gone at commit, so one file
///   holds everything at rest. A crash mid-transaction rolls back through the hot journal and removes it.
/// - `temp_store=MEMORY`: no temporary files.
/// When SQLite refuses `secure_delete`, wipes fall back to VACUUM.
///
/// The token is never stored. Unsent text stays in memory; unsent images and files live in `outbox` with the names of
/// their sandbox copies (F-FILE-07 rules 2, 3). Presigned URLs are never stored.
///
/// Version 2 (C2) adds `outbox`; message and conversation JSON gained optional fields only, so version 1 is upgraded in
/// place and keeps its rows. Version 3 (C4) adds `deleted_refs`: deleted msgIds and seqs and known recalls, including
/// messages never loaded, so a late old sync after a cold start cannot bring their text back (F-RCL-03 rule 2a); the
/// recalled, quote and mentions fields of messages and the mention counts of conversations live in the JSON columns, so
/// versions 1 and 2 are upgraded in place too. The version goes up anyway: an older SDK opening a version 3 file rebuilds
/// it instead of keeping rows it does not understand. Version 4 (C5) adds `pending_purges`: before stored messages below a
/// conversation's minSeq are deleted (a deletion of the conversation, F-CVS-03 rule 6 ②) the purge is recorded there,
/// and it is removed only after the rows, the free pages and the cached files are gone, so a purge that fails or is cut
/// short runs again on the next start (F-CVS-03 "本地清除失败：下次启动再清"). Pinned and notifications off live in the
/// conversation JSON. Versions 1 to 3 are upgraded in place. Any other version is dropped and refilled from the server.
final class LocalDatabase {
    static let schemaVersion: Int32 = 4

    let url: URL
    private var db: OpaquePointer?
    private var secureDelete = false

    /// Test hook: makes the next `apply` fail as a full disk would.
    var failNextWrite = false
    /// Test hook: the next purge stops right after recording itself as pending, as if the process were killed there.
    var interruptNextPurge = false

    /// `refuseSecureDelete` simulates an SQLite build without the pragma, to exercise the VACUUM fallback.
    init(url: URL, refuseSecureDelete: Bool = false) throws {
        self.url = url
        self.refuseSecureDelete = refuseSecureDelete
        try openAndConfigure()
    }

    private let refuseSecureDelete: Bool

    deinit {
        close()
    }

    /// The file name for a user: hex of the id, since case-insensitive file systems would merge "alice" and "Alice".
    static func fileName(userId: String) -> String {
        "tianting-" + userId.utf8.map { String(format: "%02x", $0) }.joined() + ".sqlite"
    }

    private func openAndConfigure() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = errorMessage()
            close()
            throw LocalDatabaseError(description: "open failed: \(message)")
        }
        sqlite3_busy_timeout(db, 1000)
        secureDelete = try pragmaInt(refuseSecureDelete ? "PRAGMA secure_delete=OFF" : "PRAGMA secure_delete=ON") == 1
        guard try pragmaText("PRAGMA journal_mode=DELETE").lowercased() == "delete" else {
            throw LocalDatabaseError(description: "journal_mode=DELETE refused")
        }
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA temp_store=MEMORY")
        var version = try pragmaInt("PRAGMA user_version")
        if (1...3).contains(version) {
            let from = version
            try inTransaction {
                if from == 1 { try exec(LocalDatabase.outboxSchema) }
                if from <= 2 { try exec(LocalDatabase.refsSchema) }
                try exec(LocalDatabase.purgesSchema)
                try exec("PRAGMA user_version=\(LocalDatabase.schemaVersion)")
            }
            version = Int64(LocalDatabase.schemaVersion)
        }
        if version != Int64(LocalDatabase.schemaVersion) {
            // A cache: anything older is simply dropped and refilled from the server.
            try exec(
                """
                DROP TABLE IF EXISTS conversations;
                DROP TABLE IF EXISTS messages;
                DROP TABLE IF EXISTS social_meta;
                DROP TABLE IF EXISTS friends;
                DROP TABLE IF EXISTS friend_requests;
                DROP TABLE IF EXISTS blocks;
                DROP TABLE IF EXISTS outbox;
                DROP TABLE IF EXISTS deleted_refs;
                DROP TABLE IF EXISTS pending_purges;
                """)
            try createSchema()
        }
        // Backups must not keep a copy of cached chats, or of text deleted later.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private func createSchema() throws {
        try exec(
            """
            CREATE TABLE conversations (conv_id TEXT PRIMARY KEY, state TEXT NOT NULL);
            CREATE TABLE messages (
              conv_id TEXT NOT NULL,
              seq INTEGER NOT NULL,
              message TEXT NOT NULL,
              PRIMARY KEY (conv_id, seq)
            );
            CREATE TABLE social_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              social_ver INTEGER NOT NULL,
              request_seen_ver INTEGER NOT NULL,
              settings TEXT NOT NULL,
              official INTEGER NOT NULL,
              loaded INTEGER NOT NULL
            );
            CREATE TABLE friends (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            CREATE TABLE friend_requests (user_id TEXT NOT NULL, direction TEXT NOT NULL, item TEXT NOT NULL,
              PRIMARY KEY (user_id, direction));
            CREATE TABLE blocks (user_id TEXT PRIMARY KEY, item TEXT NOT NULL);
            \(LocalDatabase.outboxSchema)
            \(LocalDatabase.refsSchema)
            \(LocalDatabase.purgesSchema)
            PRAGMA user_version=\(LocalDatabase.schemaVersion);
            """)
    }

    /// Unsent images and files (C2): the message and its source (sandbox file names, never URLs).
    static let outboxSchema =
        "CREATE TABLE outbox (client_msg_id TEXT PRIMARY KEY, conv_id TEXT NOT NULL, message TEXT NOT NULL, source TEXT);"

    /// Deleted and recalled references (C4): kind "id" (msgId), "seq", "recalled" (JSON, see `RecalledRef`). No text.
    static let refsSchema =
        "CREATE TABLE deleted_refs (conv_id TEXT NOT NULL, kind TEXT NOT NULL, ref TEXT NOT NULL, PRIMARY KEY (conv_id, kind, ref));"

    /// Purges not finished yet (C5): stored messages of `conv_id` below `min_seq` must go. No text.
    static let purgesSchema = "CREATE TABLE pending_purges (conv_id TEXT PRIMARY KEY, min_seq INTEGER NOT NULL);"

    // MARK: Purges (F-CVS-03 rule 6 ②)

    /// Runs the purges an earlier run left unfinished (the startup half of "本地清除失败：下次启动再清"). Returns the file ids
    /// of the deleted rows, whose cached downloads the caller removes before calling `finishPurges`.
    func runPendingPurges() throws -> [String] {
        var pending: [(String, Int64)] = []
        try query("SELECT conv_id, min_seq FROM pending_purges", []) { stmt in
            if let c = sqlite3_column_text(stmt, 0) { pending.append((String(cString: c), sqlite3_column_int64(stmt, 1))) }
        }
        guard !pending.isEmpty else { return [] }
        var files: [String] = []
        try inTransaction {
            for (convId, minSeq) in pending {
                try query("SELECT message FROM messages WHERE conv_id = ? AND seq < ?", [.text(convId), .int(minSeq)]) {
                    if let id = decodeColumn(Message.self, $0, 0)?.body.fileId, !files.contains(id) { files.append(id) }
                }
                try run("DELETE FROM messages WHERE conv_id = ? AND seq < ?", [.text(convId), .int(minSeq)])
            }
        }
        if !secureDelete { try exec("VACUUM") }
        return files
    }

    /// Whether purges are recorded and not finished.
    func hasPendingPurges() throws -> Bool {
        try pragmaInt("SELECT count(*) FROM pending_purges") > 0
    }

    /// The rows, free pages and cached files of every recorded purge are gone: forget them.
    func finishPurges() throws {
        try run("DELETE FROM pending_purges", [])
    }

    // MARK: Outbox

    /// Writes the outbox changes in one transaction.
    func saveOutbox(upsert: [(Message, AttachmentSource?)], delete: [String]) throws {
        guard !upsert.isEmpty || !delete.isEmpty else { return }
        try inTransaction {
            for id in delete {
                try run("DELETE FROM outbox WHERE client_msg_id = ?", [.text(id)])
            }
            for (m, src) in upsert {
                let source: Bind = try src.map { .text(try encode($0)) } ?? .null
                try run(
                    "INSERT OR REPLACE INTO outbox (client_msg_id, conv_id, message, source) VALUES (?, ?, ?, ?)",
                    [.text(m.clientMsgId), .text(m.convId), .text(try encode(m)), source])
            }
        }
    }

    func loadOutbox() throws -> [(Message, AttachmentSource?)] {
        var out: [(Message, AttachmentSource?)] = []
        try query("SELECT message, source FROM outbox ORDER BY rowid", []) { stmt in
            if let m = decodeColumn(Message.self, stmt, 0) { out.append((m, decodeColumn(AttachmentSource.self, stmt, 1))) }
        }
        return out
    }

    func close() {
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    /// Closes and removes the file (logout, kicked: FE-141).
    func destroy() {
        close()
        LocalDatabase.removeFiles(at: url)
    }

    static func removeFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    // MARK: Writes

    /// Writes one batch of conversation and message changes in a single transaction.
    func apply(_ c: LocalChanges) throws {
        guard !c.isEmpty else { return }
        if !c.purges.isEmpty {
            // Recorded first, in its own transaction: if what follows fails or is cut short, the next start purges again.
            try inTransaction {
                for p in c.purges {
                    try run(
                        """
                        INSERT INTO pending_purges (conv_id, min_seq) VALUES (?, ?)
                          ON CONFLICT(conv_id) DO UPDATE SET min_seq = max(min_seq, excluded.min_seq)
                        """,
                        [.text(p.convId), .int(p.minSeq)])
                }
            }
            if interruptNextPurge {
                interruptNextPurge = false
                throw LocalDatabaseError(description: "injected interruption after the purge record")
            }
        }
        try inTransaction {
            for p in c.purges {
                try run("DELETE FROM messages WHERE conv_id = ? AND seq < ?", [.text(p.convId), .int(p.minSeq)])
            }
            for id in c.clearMessages {
                try run("DELETE FROM messages WHERE conv_id = ?", [.text(id)])
            }
            for id in c.deleteConvs {
                try run("DELETE FROM conversations WHERE conv_id = ?", [.text(id)])
            }
            for s in c.upsertConvs {
                try run(
                    "INSERT OR REPLACE INTO conversations (conv_id, state) VALUES (?, ?)",
                    [.text(s.view.convId), .text(try encode(s))])
            }
            for m in c.upsertMessages {
                guard let seq = m.seq else { continue }
                try run(
                    "INSERT OR REPLACE INTO messages (conv_id, seq, message) VALUES (?, ?, ?)",
                    [.text(m.convId), .int(seq), .text(try encode(m))])
            }
            for r in c.refs {
                try run(
                    "INSERT OR IGNORE INTO deleted_refs (conv_id, kind, ref) VALUES (?, ?, ?)",
                    [.text(r.convId), .text(r.kind), .text(r.ref)])
            }
        }
        // Recalls and cleared quotes scrub the file like deletions (with secure_delete the freed cells are zeroed).
        let wiped =
            c.wiped || !c.clearMessages.isEmpty || !c.deleteConvs.isEmpty || !c.purges.isEmpty
            || c.upsertMessages.contains { $0.deleted == true }
            || c.upsertConvs.contains { $0.view.lastMsg?.deleted == true }
        if !secureDelete, wiped { try exec("VACUUM") }
    }

    /// Writes social rows and social meta in one transaction, so `socialVer` can never get ahead of its data (10.2).
    func saveSocial(
        replaceAll: Bool,
        friends: [FriendItem],
        requests: [RequestItem],
        blocks: [BlockItem],
        removedRequests: [RequestKey] = [],
        meta: StoredSocial?
    ) throws {
        try inTransaction {
            if replaceAll {
                try run("DELETE FROM friends", [])
                try run("DELETE FROM friend_requests", [])
                try run("DELETE FROM blocks", [])
            }
            for f in friends {
                try run(
                    "INSERT OR REPLACE INTO friends (user_id, item) VALUES (?, ?)",
                    [.text(f.userId), .text(try encode(f))])
            }
            for r in requests {
                try run(
                    "INSERT OR REPLACE INTO friend_requests (user_id, direction, item) VALUES (?, ?, ?)",
                    [.text(r.userId), .text(r.direction.rawValue), .text(try encode(r))])
            }
            for k in removedRequests {
                try run(
                    "DELETE FROM friend_requests WHERE user_id = ? AND direction = ?",
                    [.text(k.userId), .text(k.direction.rawValue)])
            }
            for b in blocks {
                try run(
                    "INSERT OR REPLACE INTO blocks (user_id, item) VALUES (?, ?)",
                    [.text(b.userId), .text(try encode(b))])
            }
            if let meta {
                try run(
                    """
                    INSERT OR REPLACE INTO social_meta
                      (id, social_ver, request_seen_ver, settings, official, loaded) VALUES (1, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int(meta.ver), .int(meta.requestSeenVer), .text(try encode(meta.settings)),
                        .int(meta.official ? 1 : 0), .int(meta.loaded ? 1 : 0),
                    ])
            }
        }
    }

    // MARK: Reads

    /// Loads conversations and each conversation's newest `maxMessagesPerConversation` messages, deleting older rows.
    func loadChat(maxMessagesPerConversation: Int) throws -> (conversations: [ConvState], messages: [Message]) {
        try run(
            """
            DELETE FROM messages WHERE rowid IN (
              SELECT rowid FROM (
                SELECT rowid, ROW_NUMBER() OVER (PARTITION BY conv_id ORDER BY seq DESC) AS n FROM messages
              ) WHERE n > ?
            )
            """,
            [.int(Int64(maxMessagesPerConversation))])
        if !secureDelete { try exec("VACUUM") }
        var convs: [ConvState] = []
        try query("SELECT state FROM conversations", []) { stmt in
            if let s = decodeColumn(ConvState.self, stmt, 0) { convs.append(s) }
        }
        var msgs: [Message] = []
        try query("SELECT message FROM messages ORDER BY conv_id, seq", []) { stmt in
            if let m = decodeColumn(Message.self, stmt, 0) { msgs.append(m) }
        }
        return (convs, msgs)
    }

    /// The `deleted_refs` rows by conversation.
    func loadRefs() throws -> [String: StoredRefs] {
        var out: [String: StoredRefs] = [:]
        try query("SELECT conv_id, kind, ref FROM deleted_refs", []) { stmt in
            guard let c = sqlite3_column_text(stmt, 0), let k = sqlite3_column_text(stmt, 1),
                let r = sqlite3_column_text(stmt, 2)
            else { return }
            let convId = String(cString: c)
            let ref = String(cString: r)
            var e = out[convId] ?? StoredRefs()
            switch String(cString: k) {
            case "id": e.ids.insert(ref)
            case "seq": if let s = Int64(ref) { e.seqs.insert(s) }
            case "recalled":
                guard let x = try? JSONCoding.decoder.decode(RecalledRef.self, from: Data(ref.utf8)) else { return }
                let info = RecallInfo(by: x.by, at: x.at)
                // Recalled more than once (a local estimate, then the server's): keep the one with an operator.
                let pick: (RecallInfo, RecallInfo) -> RecallInfo = { a, b in a.by.isEmpty ? b : a }
                if x.k == "id" {
                    e.recalledIds[x.v] = e.recalledIds[x.v].map { pick($0, info) } ?? info
                } else if x.k == "seq", let s = Int64(x.v) {
                    e.recalledSeqs[s] = e.recalledSeqs[s].map { pick($0, info) } ?? info
                }
            default: break
            }
            out[convId] = e
        }
        return out
    }

    func loadSocial() throws -> StoredSocial? {
        var meta: StoredSocial?
        try query(
            "SELECT social_ver, request_seen_ver, settings, official, loaded FROM social_meta WHERE id = 1", []
        ) { stmt in
            guard let settings = decodeColumn(SocialSettings.self, stmt, 2) else { return }
            meta = StoredSocial(
                ver: sqlite3_column_int64(stmt, 0),
                requestSeenVer: sqlite3_column_int64(stmt, 1),
                settings: settings,
                official: sqlite3_column_int(stmt, 3) != 0,
                loaded: sqlite3_column_int(stmt, 4) != 0,
                friends: [], requests: [], blocks: [])
        }
        guard var m = meta else { return nil }
        try query("SELECT item FROM friends", []) { stmt in
            if let f = decodeColumn(FriendItem.self, stmt, 0) { m.friends.append(f) }
        }
        try query("SELECT item FROM friend_requests", []) { stmt in
            if let r = decodeColumn(RequestItem.self, stmt, 0) { m.requests.append(r) }
        }
        try query("SELECT item FROM blocks", []) { stmt in
            if let b = decodeColumn(BlockItem.self, stmt, 0) { m.blocks.append(b) }
        }
        return m
    }

    // MARK: SQLite plumbing

    private enum Bind {
        case text(String)
        case int(Int64)
        case null
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    }

    private func decodeColumn<T: Decodable>(_ type: T.Type, _ stmt: OpaquePointer, _ col: Int32) -> T? {
        guard let text = sqlite3_column_text(stmt, col) else { return nil }
        return try? JSONCoding.decoder.decode(T.self, from: Data(String(cString: text).utf8))
    }

    private func errorMessage() -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "no database"
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw LocalDatabaseError(description: "closed") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalDatabaseError(description: errorMessage())
        }
    }

    private func pragmaInt(_ sql: String) throws -> Int64 {
        var out: Int64 = 0
        try query(sql, []) { out = sqlite3_column_int64($0, 0) }
        return out
    }

    private func pragmaText(_ sql: String) throws -> String {
        var out = ""
        try query(sql, []) { stmt in
            if let t = sqlite3_column_text(stmt, 0) { out = String(cString: t) }
        }
        return out
    }

    private func prepare(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        guard let db else { throw LocalDatabaseError(description: "closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalDatabaseError(description: errorMessage())
        }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, sqliteTransient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Bind]) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalDatabaseError(description: errorMessage())
        }
    }

    private func query(_ sql: String, _ binds: [Bind], row: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                row(stmt)
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw LocalDatabaseError(description: errorMessage())
            }
        }
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        if failNextWrite {
            failNextWrite = false
            throw LocalDatabaseError(description: "injected failure")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
