import Dispatch
import Foundation
import GRDB
import MessageSubstringSearch

/// GRDB 的事务观察局限于单个连接池。把各池的已提交索引变更按主库路径汇合，
/// 使通过另一个本地 store 接收的消息也能唤醒前台维护者。
final class V2SearchCommitObserver: TransactionObserver {
    static func notification(for path: String) -> Notification.Name {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return Notification.Name("IMV2.search.commit." + file.path)
    }

    private let notification: Notification.Name
    private var changed = false

    init(path: String) { notification = Self.notification(for: path) }

    func observes(eventsOfKind kind: DatabaseEventKind) -> Bool {
        switch kind.tableName {
        case "v2_message_search_jobs", "v2_message_search_state", "v2_snapshot_import": true
        default: false
        }
    }

    func databaseDidChange(with event: DatabaseEvent) {
        changed = true
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        guard changed else { return }
        changed = false
        NotificationCenter.default.post(name: notification, object: nil)
    }

    func databaseDidRollback(_ db: Database) { changed = false }
}

/// 每个可写账号实例的唯一写入者。整批读取、发布与确认在该执行器上连续执行。
actor V2MessageSearchWriter {
    private let queue = DispatchSerialQueue(label: "IMV2.messageSearch.writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let databasePool: DatabasePool
    private let messageSearchDatabasePool: DatabasePool
    private let lifetime: V2SearchLifetime
    private let fileNumber: UInt64

    init(primary: DatabasePool, search: DatabasePool, lifetime: V2SearchLifetime) throws {
        fileNumber = try Self.fileNumber(at: search.path)
        databasePool = primary
        messageSearchDatabasePool = search
        self.lifetime = lifetime
    }

    private static func fileNumber(at path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber else { throw V2MessageSearchError.closed }
        return inode.uint64Value
    }

    /// 不同 store 也可能指向同一文件。只在实际维护时独占，等待不占用执行器。
    /// 持锁期间没有挂起点，覆盖读取任务、派生提交与主库条件确认。
    private func withWriteLease<T>(_ work: () throws -> T) async throws -> T {
        while true {
            try lifetime.check()
            let lease: SearchIndexWriteLease
            do { lease = try SearchIndexWriteLease(path: messageSearchDatabasePool.path) }
            catch SearchIndexError.alreadyOpen {
                try await Task.sleep(for: .milliseconds(25))
                continue
            }
            return try withExtendedLifetime(lease) {
                guard try Self.fileNumber(at: messageSearchDatabasePool.path) == fileNumber else { throw V2MessageSearchError.closed }
                return try work()
            }
        }
    }

    func invalidate(generation: Int64) throws {
        try lifetime.check()
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_message_search_state SET state='building' WHERE singleton=1 AND generation=? AND state='ready'", arguments: [generation])
        }
    }

    func markFailed() {
        guard (try? lifetime.check()) != nil else { return }
        try? databasePool.write { try $0.execute(sql: "UPDATE v2_message_search_state SET state='failed' WHERE singleton=1") }
    }

    private func messageSearchIndexState() throws -> V2MessageSearchIndexState {
        try databasePool.read { try GRDBV2LocalSyncStore.readMessageSearchIndexState(db: $0) }
    }

    private static func nextCommit(_ db: Database) throws -> Int64 {
        guard let sequence = try Int64.fetchOne(db, sql: """
            UPDATE v2_search_publication SET commit_sequence=commit_sequence+1
            WHERE singleton=1 AND commit_sequence < 9223372036854775807 RETURNING commit_sequence
            """) else { throw V2ClientProjectionError.invalidMessagePayload }
        return sequence
    }

    /// 仅重建派生数据库。
    ///
    /// 主库上的消息投影读取都是短时分页读事务；所有昂贵的全文检索删除与插入
    /// 都发生在独立的搜索数据库中。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；主库写入被栅栏限制或索引操作失败时抛出。
    func rebuildMessageSearchIndex() async throws {
        try await withWriteLease { try rebuild() }
    }

    private func rebuild() throws {
        while !Task.isCancelled {
            try lifetime.check()
            let generation = try databasePool.write { db in
                try GRDBV2LocalSyncStore.requireProjectionWritesUnfenced(db: db)
                return try GRDBV2LocalSyncStore.beginMessageSearchIndexRebuild(db: db)
            }
            try messageSearchDatabasePool.write { db in
                if try GRDBV2LocalSyncStore.isCurrentSearchSchema(db) {
                    try db.execute(sql: "DELETE FROM v2_search_documents")
                    try db.execute(sql: "DROP TABLE v2_message_char_fts")
                    try db.execute(sql: GRDBV2LocalSyncStore.messageFTSSchema)
                } else {
                    try db.execute(sql: "DROP TABLE IF EXISTS v2_message_char_fts")
                    try db.execute(sql: "DROP TABLE IF EXISTS v2_search_documents")
                    try db.execute(sql: "DROP TABLE IF EXISTS v2_search_publication")
                    try db.execute(sql: GRDBV2LocalSyncStore.searchDatabaseSchema)
                }
                try db.execute(sql: "INSERT OR REPLACE INTO v2_search_publication(singleton,generation,commit_sequence) VALUES (1,?,0)", arguments: [generation])
            }

            var lastRowID: Int64 = 0
            var mustRestart = false
            while !Task.isCancelled {
                try lifetime.check()
                let pageStart = lastRowID
                let documents = try databasePool.read { db in
                    try Row.fetchAll(
                        db,
                        sql: """
                        SELECT rowid AS primary_rowid, message_id, room_id, room_sequence, message_revision,
                               sender_user_id, text_body, media_presentations,
                               server_created_at, is_withdrawn
                        FROM v2_message_projections
                        WHERE rowid > ?
                        ORDER BY rowid
                        LIMIT 250
                        """,
                        arguments: [pageStart]
                    ).map { try MessageSearchDocument(row: $0, generation: generation) }
                }
                guard let last = documents.last else { break }
                lastRowID = last.primaryRowID
                let prepared = try documents.filter { !$0.withdrawn }.map { try PreparedDocument($0) }
                try messageSearchDatabasePool.write { db in
                    let sequence = try Self.nextCommit(db)
                    for document in prepared {
                        try Self.writeMessageSearchDocument(document, sequence: sequence, jobID: nil, db: db)
                    }
                }
                let currentGeneration = try databasePool.read { db in try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: db) }
                guard currentGeneration == generation else {
                    mustRestart = true
                    break
                }
            }
            if mustRestart { continue }
            try Task.checkCancellation()
            // 检查空队列和发布 ready 共用主库写事务。提交窗口内到达的新任务继续追平。
            while try databasePool.read({ try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) }) == generation {
                try lifetime.check()
                if try applyPending(limit: 64) > 0 { continue }
                let finished = try databasePool.write { db in
                    guard try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: db) == generation,
                          try Int.fetchOne(db, sql: "SELECT 1 FROM v2_message_search_jobs WHERE generation=? LIMIT 1",
                                           arguments: [generation]) == nil else { return false }
                    try GRDBV2LocalSyncStore.finishMessageSearchIndexRebuild(generation: generation, db: db)
                    return true
                }
                if finished { return }
            }
        }
        throw CancellationError()
    }

    /// 让既有索引上线，然后应用一个有界批次。
    ///
    /// 调用方可以反复以低优先级维护方式调用
    /// ``processPendingMessageSearchIndexJobs(limit:)``，而不会拖慢同步应用。
    ///
    /// - Throws: 索引重建或批次处理失败时抛出。
    func prepareMessageSearchIndex() async throws {
        try await withWriteLease {
            if try messageSearchIndexState() != .ready { try rebuild() }
            _ = try applyPending(limit: 64)
        }
    }

    /// 仅由前台运行的认证运行时持有的低优先级维护循环。
    ///
    /// 它刻意在细小批次之间让出执行权，对主库的访问不会超过一次任务读取与确认事务。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；索引操作失败时抛出。
    func runMessageSearchIndexer() async throws {
        let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(forName: V2SearchCommitObserver.notification(for: databasePool.path),
                                                              object: nil, queue: nil) { _ in signal.yield(()) }
        defer {
            NotificationCenter.default.removeObserver(observer)
            signal.finish()
        }
        // 先订阅再扫描，覆盖启动积压，以及排空最后一批与开始等待之间的提交。
        signal.yield(())
        for await _ in changes {
            while true {
                try Task.checkCancellation()
                do {
                    let count = try await withWriteLease {
                        if try messageSearchIndexState() != .ready { try rebuild() }
                        return try applyPending(limit: 32)
                    }
                    if count == 0 { break }
                } catch V2ClientSyncError.resetPending {
                    break // 快照激活解除栅栏后再唤醒。
                }
                await Task.yield()
            }
        }
        throw CancellationError()
    }

    /// 应用至多 `limit` 个已合并的工作项。
    ///
    /// 若在搜索库提交之后、主库确认之前失败，只会重放同一份文档；
    /// 该重放按消息标识、修订与代次是幂等的。
    ///
    /// - Parameter limit: 本次最多处理的工作项数，需落在 `1...256`。
    /// - Returns: 实际处理的工作项数。
    /// - Throws: 条数越界时抛出 ``V2MessageSearchError/invalidPageSize``；其余失败来自存储。
    @discardableResult
    func processPendingMessageSearchIndexJobs(limit: Int = 64) async throws -> Int {
        try await withWriteLease { try applyPending(limit: limit) }
    }

    private func applyPending(limit: Int) throws -> Int {
        try lifetime.check()
        guard (1 ... 256).contains(limit) else { throw V2MessageSearchError.invalidPageSize }
        let jobs = try databasePool.read { db in
            guard let state = try Row.fetchOne(db, sql: "SELECT generation, index_version FROM v2_message_search_state WHERE singleton = 1") else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            guard try GRDBV2LocalSyncStore.searchInteger(state, "index_version") == GRDBV2LocalSyncStore.messageSearchIndexVersion else {
                throw V2MessageSearchError.indexUnavailable(.building)
            }
            let currentGeneration = try GRDBV2LocalSyncStore.searchInteger(state, "generation")
            return try Row.fetchAll(
                db,
                sql: """
                SELECT j.message_id, j.expected_message_revision, j.generation, j.job_id,
                       p.rowid AS primary_rowid,
                       p.room_id, p.room_sequence, p.message_revision,
                       p.sender_user_id, p.text_body, p.media_presentations,
                       p.server_created_at, p.is_withdrawn
                FROM v2_message_search_jobs j
                LEFT JOIN v2_message_projections p ON p.message_id = j.message_id
                WHERE j.generation = ?
                ORDER BY j.enqueued_at, j.message_id
                LIMIT ?
                """,
                arguments: [currentGeneration, limit]
            ).map { try MessageSearchIndexJob(row: $0) }
        }
        guard !jobs.isEmpty else { return 0 }
        let prepared = try jobs.map { try $0.document.map(PreparedDocument.init) }
        try messageSearchDatabasePool.write { db in
            let sequence = try Self.nextCommit(db)
            for (job, document) in zip(jobs, prepared) {
                guard let document else {
                    try Self.deleteMessageSearchDocument(messageID: job.messageID, db: db)
                    continue
                }
                let previous = try String.fetchOne(db, sql: "SELECT job_id FROM v2_search_documents WHERE message_id=?", arguments: [job.messageID])
                if previous != job.jobID {
                    try Self.writeMessageSearchDocument(document, sequence: sequence, jobID: job.jobID, db: db)
                }
            }
        }
        try databasePool.write { db in
            for job in jobs {
                try db.execute(
                    sql: "DELETE FROM v2_message_search_jobs WHERE message_id = ? AND expected_message_revision = ? AND generation = ? AND job_id = ?",
                    arguments: [job.messageID, job.expectedRevision, job.generation, job.jobID]
                )
            }
        }
        return jobs.count
    }

    private struct MessageSearchDocument: Sendable {
        let primaryRowID: Int64
        let messageID: String
        let revision: Int64
        let generation: Int64
        let roomID: String
        let roomSequence: Int64
        let senderUserID: String
        let withdrawn: Bool
        let text: String
        let mediaPresentations: String
        let createdAt: Double

        init(row: Row, generation: Int64) throws {
            primaryRowID = row["primary_rowid"]
            messageID = row["message_id"]
            revision = try GRDBV2LocalSyncStore.searchInteger(row, "message_revision")
            self.generation = generation
            roomID = row["room_id"]
            roomSequence = try GRDBV2LocalSyncStore.searchInteger(row, "room_sequence")
            senderUserID = row["sender_user_id"]
            text = row["text_body"] as String? ?? ""
            withdrawn = row["is_withdrawn"]
            mediaPresentations = row["media_presentations"]
            createdAt = row["server_created_at"]
        }
    }

    private struct PreparedDocument {
        let source: MessageSearchDocument
        let tokens: String

        init(_ source: MessageSearchDocument) throws {
            self.source = source
            tokens = try SubstringSearchText.encodeForIndex(source.text)
        }
    }

    private struct MessageSearchIndexJob: Sendable {
        let messageID: String
        let jobID: String
        let expectedRevision: Int64
        let generation: Int64
        let document: MessageSearchDocument?

        init(row: Row) throws {
            messageID = row["message_id"]
            jobID = row["job_id"]
            expectedRevision = try GRDBV2LocalSyncStore.searchInteger(row, "expected_message_revision")
            generation = try GRDBV2LocalSyncStore.searchInteger(row, "generation")
            let storedRevision: DatabaseValue = row["message_revision"]
            let actualRevision: Int64? = try storedRevision.isNull ? nil : GRDBV2LocalSyncStore.searchInteger(row, "message_revision")
            let withdrawn: Bool? = row["is_withdrawn"]
            if actualRevision == expectedRevision, withdrawn == false {
                document = try .init(row: row, generation: generation)
            } else {
                document = nil
            }
        }
    }

    private static func writeMessageSearchDocument(_ prepared: PreparedDocument, sequence: Int64, jobID: String?, db: Database) throws {
        let document = prepared.source
        try deleteMessageSearchDocument(messageID: document.messageID, db: db)
        try db.execute(
            sql: """
            INSERT INTO v2_search_documents
                (message_id, message_revision, generation, room_id, room_sequence, sender_user_id, indexed_commit, job_id, media_presentations, server_created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [document.messageID, document.revision, document.generation, document.roomID, document.roomSequence, document.senderUserID, sequence, jobID, document.mediaPresentations, document.createdAt]
        )
        guard !prepared.tokens.isEmpty else { return }
        guard let rowID: Int64 = try Row.fetchOne(db, sql: "SELECT rowid FROM v2_search_documents WHERE message_id = ?", arguments: [document.messageID])?["rowid"]
        else { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(
            sql: "INSERT INTO v2_message_char_fts (rowid, room_scope, sender_scope, tokens) VALUES (?, ?, ?, ?)",
            arguments: [rowID, v2SearchToken(prefix: "r", text: document.roomID), v2SearchToken(prefix: "s", text: document.senderUserID), prepared.tokens]
        )
    }

    private static func deleteMessageSearchDocument(messageID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM v2_message_char_fts WHERE rowid IN (SELECT rowid FROM v2_search_documents WHERE message_id = ?)", arguments: [messageID])
        try db.execute(sql: "DELETE FROM v2_search_documents WHERE message_id = ?", arguments: [messageID])
    }

}
