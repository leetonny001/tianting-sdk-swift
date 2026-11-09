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
/// place and keeps its rows. Any other version is dropped and refilled from the server.
final class LocalDatabase {
    static let schemaVersion: Int32 = 2

    let url: URL
    private var db: OpaquePointer?
    private var secureDelete = false

    /// Test hook: makes the next `apply` fail as a full disk would.
    var failNextWrite = false

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
        if version == 1 {
            try inTransaction {
                try exec(LocalDatabase.outboxSchema)
                try exec("PRAGMA user_version=2")
            }
            version = 2
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
            PRAGMA user_version=\(LocalDatabase.schemaVersion);
            """)
    }

    /// Unsent images and files (C2): the message and its source (sandbox file names, never URLs).
    static let outboxSchema =
        "CREATE TABLE outbox (client_msg_id TEXT PRIMARY KEY, conv_id TEXT NOT NULL, message TEXT NOT NULL, source TEXT);"

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
        try inTransaction {
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
        }
        let wiped =
            !c.clearMessages.isEmpty || !c.deleteConvs.isEmpty
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
