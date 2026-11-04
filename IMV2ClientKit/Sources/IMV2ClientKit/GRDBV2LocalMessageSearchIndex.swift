import Foundation
import GRDB
import IMV2Core
import MessageSubstringSearch

/// 搜索索引是 `V2Search.sqlite` 中的可替换本地投影。
///
/// 持久化任务由主 V2 数据库持有，使搜索写入在进程崩溃后可安全重放，
/// 同时把全文检索工作从同步写入路径上移开。
extension GRDBV2LocalSyncStore {
    static let messageSearchIndexVersion = 4

    static func isCurrentSearchSchema(_ db: Database) throws -> Bool {
        guard try db.tableExists("v2_search_publication"), try db.tableExists("v2_message_char_fts"),
              try db.tableExists("v2_search_documents") else { return false }
        let publication = try Set(db.columns(in: "v2_search_publication").map(\.name))
        let documents = try Set(db.columns(in: "v2_search_documents").map(\.name))
        let fts = try Set(db.columns(in: "v2_message_char_fts").map(\.name))
        return publication.isSuperset(of: ["singleton", "generation", "commit_sequence"])
            && documents.isSuperset(of: ["message_id", "message_revision", "generation", "room_id", "room_sequence",
                                        "sender_user_id", "indexed_commit", "job_id", "media_presentations", "server_created_at"])
            && fts.isSuperset(of: ["room_scope", "sender_scope", "tokens"])
    }

    static func invalidateSearch(_ db: Database) throws {
        try db.execute(sql: "UPDATE v2_message_search_state SET state='building' WHERE singleton=1")
    }

    static func searchPublicationMatches(_ db: Database, generation: Int64) throws -> Bool {
        guard try isCurrentSearchSchema(db) else { return false }
        return try Int64.fetchOne(db, sql: "SELECT generation FROM v2_search_publication WHERE singleton=1") == generation
    }

    /// 只清理派生文件。权限、空间不足和忙锁必须交给调用方处理。
    static func openSearchDatabase(url: URL, primary: DatabasePool, configuration: Configuration) throws -> DatabasePool {
        func openCurrent() throws -> DatabasePool? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let (generation, failed) = try primary.read { db in
                (try messageSearchIndexGeneration(db: db), try readMessageSearchIndexState(db: db) == .failed)
            }
            guard !failed else { return nil }
            do {
                let pool = try DatabasePool(path: url.path, configuration: configuration)
                guard try pool.read({ try isCurrentSearchSchema($0) }) else {
                    try pool.close()
                    return nil
                }
                if try !pool.read({ try searchPublicationMatches($0, generation: generation) }) {
                    try primary.write { db in
                        try db.execute(sql: "UPDATE v2_message_search_state SET state='building' WHERE singleton=1 AND generation=? AND state='ready'", arguments: [generation])
                    }
                }
                return pool
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                return nil
            }
        }

        if let pool = try openCurrent() { return pool }
        let lease = try SearchIndexWriteLease(path: url.path)
        defer { withExtendedLifetime(lease) {} }
        if let pool = try openCurrent() { return pool }
        try primary.write { try invalidateSearch($0) }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        do { try messageSearchMigrator.migrate(pool); return pool }
        catch { try pool.close(); throw error }
    }

    static let messageFTSSchema = """
        CREATE VIRTUAL TABLE v2_message_char_fts USING fts5(
            room_scope, sender_scope, tokens, tokenize = 'ascii', detail = full, columnsize = 0
        )
        """

    static func readMessageSearchIndexState(db: Database) throws -> V2MessageSearchIndexState {
        guard let row = try Row.fetchOne(db, sql: "SELECT index_version, state FROM v2_message_search_state WHERE singleton = 1"),
              let version = Int(exactly: try searchInteger(row, "index_version")),
              let raw: String = row["state"],
              let state = V2MessageSearchIndexState(storageValue: raw)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return version == Self.messageSearchIndexVersion ? state : .building
    }

    static func messageSearchIndexGeneration(db: Database) throws -> Int64 {
        guard let row = try Row.fetchOne(db, sql: "SELECT generation FROM v2_message_search_state WHERE singleton = 1")
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return try searchInteger(row, "generation")
    }

    @discardableResult
    static func beginMessageSearchIndexRebuild(db: Database) throws -> Int64 {
        let generation = try messageSearchIndexGeneration(db: db)
        guard generation < Int64.max else { throw V2ClientProjectionError.invalidMessagePayload }
        let nextGeneration = generation + 1
        try db.execute(sql: "DELETE FROM v2_message_search_jobs")
        try db.execute(
            sql: "UPDATE v2_message_search_state SET index_version = ?, state = 'building', generation = ? WHERE singleton = 1",
            arguments: [Self.messageSearchIndexVersion, nextGeneration]
        )
        return nextGeneration
    }

    static func finishMessageSearchIndexRebuild(generation: Int64, db: Database) throws {
        guard try messageSearchIndexGeneration(db: db) == generation else { return }
        try db.execute(sql: "UPDATE v2_message_search_state SET state = 'ready' WHERE singleton = 1")
    }

    static func enqueueMessageSearchIndexJob(messageID: MessageID, db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT message_revision FROM v2_message_projections WHERE message_id = ?",
            arguments: [messageID.rawValue]
        ) else { return }
        let revision = try searchInteger(row, "message_revision")
        try db.execute(
            sql: """
            INSERT INTO v2_message_search_jobs (message_id, expected_message_revision, generation, enqueued_at, job_id)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                expected_message_revision = excluded.expected_message_revision,
                generation = excluded.generation,
                enqueued_at = excluded.enqueued_at, job_id = excluded.job_id
            """,
            arguments: [messageID.rawValue, revision, try messageSearchIndexGeneration(db: db), Date().timeIntervalSince1970, UUID().uuidString]
        )
    }

    static func enqueueMessageSearchDeletionJob(messageID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO v2_message_search_jobs (message_id, expected_message_revision, generation, enqueued_at, job_id)
            VALUES (?, 1, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                expected_message_revision = 1,
                generation = excluded.generation,
                enqueued_at = excluded.enqueued_at, job_id = excluded.job_id
            """,
            arguments: [messageID, try messageSearchIndexGeneration(db: db), Date().timeIntervalSince1970, UUID().uuidString]
        )
    }

    static func searchInteger(_ row: Row, _ column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer > 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return integer
    }

}
