import Foundation
import GRDB
import IMV2Core

/// 搜索索引是 `V2Search.sqlite` 中的可替换本地投影。
///
/// 持久化任务由主 V2 数据库持有，使搜索写入在进程崩溃后可安全重放，
/// 同时把全文检索工作从同步写入路径上移开。
extension GRDBV2LocalSyncStore {
    public nonisolated func messageSearchIndexUpdates() -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        guard let row = try Row.fetchOne(db, sql: "SELECT state, generation, index_version FROM v2_message_search_state WHERE singleton = 1"),
                              let state = V2MessageSearchIndexState(storageValue: row["state"]),
                              let generation = UInt64(exactly: try Self.searchInteger(row, "generation")), generation > 0
                        else { throw V2ClientProjectionError.invalidMessagePayload }
                        guard let version = Int(exactly: try Self.searchInteger(row, "index_version")) else { throw V2ClientProjectionError.invalidMessagePayload }
                        return V2MessageSearchIndexSnapshot(
                            state: version == V2CharacterGramTokenizer.version ? state : .building,
                            generation: generation, indexVersion: version
                        )
                    }.removeDuplicates()
                    for try await snapshot in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func messageSearchIndexProgress() throws -> V2MessageSearchIndexProgress {
        try databasePool.read { db in
            let state = try Self.readMessageSearchIndexState(db: db)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_message_search_jobs") ?? 0
            return .init(state: state, pendingJobCount: count)
        }
    }

    /// 仅重建派生数据库。
    ///
    /// 主库上的消息投影读取都是短时分页读事务；所有昂贵的全文检索删除与插入
    /// 都发生在独立的搜索数据库中。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；主库写入被栅栏限制或索引操作失败时抛出。
    public func rebuildMessageSearchIndex() async throws {
        while !Task.isCancelled {
            let generation = try await databasePool.write { db in
                try Self.requireProjectionWritesUnfenced(db: db)
                return try Self.beginMessageSearchIndexRebuild(db: db)
            }
            try await messageSearchDatabasePool.write { db in
                try db.execute(sql: "DELETE FROM v2_message_char_fts")
                try db.execute(sql: "DELETE FROM v2_search_documents")
            }

            var lastRowID: Int64 = 0
            var mustRestart = false
            while !Task.isCancelled {
                let pageStart = lastRowID
                let documents = try await databasePool.read { db in
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
                try await messageSearchDatabasePool.write { db in
                    for document in documents {
                        try Self.writeMessageSearchDocument(document, db: db)
                    }
                }
                let currentGeneration = try await databasePool.read { db in try Self.messageSearchIndexGeneration(db: db) }
                guard currentGeneration == generation else {
                    mustRestart = true
                    break
                }
                await Task.yield()
            }
            if mustRestart { continue }
            try Task.checkCancellation()
            // Changes accepted while the page scan ran have coalesced jobs;
            // drain them before exposing this generation as ready.
            while try await processPendingMessageSearchIndexJobs(limit: 64) > 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            let finished = try await databasePool.write { db -> Bool in
                guard try Self.messageSearchIndexGeneration(db: db) == generation else { return false }
                guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_message_search_jobs WHERE generation = ?", arguments: [generation]) ?? 0) == 0 else { return false }
                try Self.finishMessageSearchIndexRebuild(generation: generation, db: db)
                return true
            }
            if finished { return }
        }
        throw CancellationError()
    }

    /// 让既有索引上线，然后应用一个有界批次。
    ///
    /// 调用方可以反复以低优先级维护方式调用
    /// ``processPendingMessageSearchIndexJobs(limit:)``，而不会拖慢同步应用。
    ///
    /// - Throws: 索引重建或批次处理失败时抛出。
    public func prepareMessageSearchIndex() async throws {
        if try messageSearchIndexState() != .ready {
            try await rebuildMessageSearchIndex()
        }
        _ = try await processPendingMessageSearchIndexJobs(limit: 64)
    }

    /// 仅由前台运行的认证运行时持有的低优先级维护循环。
    ///
    /// 它刻意在细小批次之间让出执行权，对主库的访问不会超过一次任务读取与确认事务。
    ///
    /// - Throws: 任务取消时抛出 `CancellationError`；索引操作失败时抛出。
    public func runMessageSearchIndexer() async throws {
        while !Task.isCancelled {
            if try messageSearchIndexState() != .ready {
                try await rebuildMessageSearchIndex()
                continue
            }
            if try await processPendingMessageSearchIndexJobs(limit: 32) == 0 {
                try await Task.sleep(for: .seconds(1))
            } else {
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
    public func processPendingMessageSearchIndexJobs(limit: Int = 64) async throws -> Int {
        guard (1 ... 256).contains(limit) else { throw V2MessageSearchError.invalidPageSize }
        let jobs = try await databasePool.read { db in
            let currentGeneration = try Self.messageSearchIndexGeneration(db: db)
            return try Row.fetchAll(
                db,
                sql: """
                SELECT j.message_id, j.expected_message_revision, j.generation,
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
        try await messageSearchDatabasePool.write { db in
            for job in jobs {
                guard let document = job.document else {
                    try Self.deleteMessageSearchDocument(messageID: job.messageID, db: db)
                    continue
                }
                try Self.writeMessageSearchDocument(document, db: db)
            }
        }
        try await databasePool.write { db in
            for job in jobs {
                try db.execute(
                    sql: "DELETE FROM v2_message_search_jobs WHERE message_id = ? AND expected_message_revision = ? AND generation = ?",
                    arguments: [job.messageID, job.expectedRevision, job.generation]
                )
            }
        }
        return jobs.count
    }

    /// 在废弃派生全文索引文件之前先提交状态。
    ///
    /// 这样进程重启不会把刚刚清空的搜索数据库误认为此前已就绪的索引。
    ///
    /// - Throws: 数据库写入失败时抛出。
    public func requireMessageSearchIndexRebuild() throws {
        try databasePool.write { db in
            try db.execute(sql: "UPDATE v2_message_search_state SET state = 'building' WHERE singleton = 1")
        }
    }

    /// 读取当前搜索索引状态。
    ///
    /// - Returns: 索引状态。
    /// - Throws: 数据库读取失败时抛出。
    public func messageSearchIndexState() throws -> V2MessageSearchIndexState {
        try databasePool.read { db in try Self.readMessageSearchIndexState(db: db) }
    }

    /// 执行一次消息搜索。
    ///
    /// 全文索引只给出候选；每个候选在成为命中之前都会与权威数据库的当前修订比对，
    /// 因此滞后或崩溃过的索引最多漏掉近期文本，绝不会暴露已被编辑、撤回或重置的消息。
    ///
    /// - Parameter request: 搜索请求。
    /// - Returns: 搜索结果分页。
    /// - Throws: 查询为空、条数越界、索引不可用或游标与范围不匹配时抛出
    ///   ``V2MessageSearchError``；其余失败来自存储。
    public func searchMessages(_ request: V2MessageSearchRequest) throws -> V2MessageSearchPage {
        guard (1 ... 100).contains(request.limit) else { throw V2MessageSearchError.invalidPageSize }
        let tokenizer = V2CharacterGramTokenizer()
        let query = tokenizer.tokenize(request.query)
        guard !query.unigrams.isEmpty || request.contentFilter != .all else {
            throw V2MessageSearchError.emptyQuery
        }
        let primaryState = try databasePool.read { db in
            (try Self.readMessageSearchIndexState(db: db), try Self.messageSearchIndexGeneration(db: db))
        }
        guard primaryState.0 == .ready else { throw V2MessageSearchError.indexUnavailable(primaryState.0) }
        return try messageSearchDatabasePool.read { db in
            try Self.searchMessages(request, query: query, generation: primaryState.1, primaryDatabasePool: databasePool, db: db)
        }
    }

    static func readMessageSearchIndexState(db: Database) throws -> V2MessageSearchIndexState {
        guard let row = try Row.fetchOne(db, sql: "SELECT index_version, state FROM v2_message_search_state WHERE singleton = 1"),
              let version = Int(exactly: try searchInteger(row, "index_version")),
              let raw: String = row["state"],
              let state = V2MessageSearchIndexState(storageValue: raw)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return version == V2CharacterGramTokenizer.version ? state : .building
    }

    static func messageSearchIndexGeneration(db: Database) throws -> Int64 {
        guard let row = try Row.fetchOne(db, sql: "SELECT generation FROM v2_message_search_state WHERE singleton = 1")
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return try searchInteger(row, "generation")
    }

    @discardableResult
    private static func beginMessageSearchIndexRebuild(db: Database) throws -> Int64 {
        let generation = try messageSearchIndexGeneration(db: db)
        guard generation < Int64.max else { throw V2ClientProjectionError.invalidMessagePayload }
        let nextGeneration = generation + 1
        try db.execute(sql: "DELETE FROM v2_message_search_jobs")
        try db.execute(
            sql: "UPDATE v2_message_search_state SET index_version = ?, state = 'building', generation = ? WHERE singleton = 1",
            arguments: [V2CharacterGramTokenizer.version, nextGeneration]
        )
        return nextGeneration
    }

    static func resetMessageSearchIndex(db: Database) throws {
        _ = try beginMessageSearchIndexRebuild(db: db)
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
            INSERT INTO v2_message_search_jobs (message_id, expected_message_revision, generation, enqueued_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                expected_message_revision = excluded.expected_message_revision,
                generation = excluded.generation,
                enqueued_at = excluded.enqueued_at
            """,
            arguments: [messageID.rawValue, revision, try messageSearchIndexGeneration(db: db), Date().timeIntervalSince1970]
        )
    }

    static func enqueueMessageSearchDeletionJob(messageID: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO v2_message_search_jobs (message_id, expected_message_revision, generation, enqueued_at)
            VALUES (?, 1, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                expected_message_revision = 1,
                generation = excluded.generation,
                enqueued_at = excluded.enqueued_at
            """,
            arguments: [messageID, try messageSearchIndexGeneration(db: db), Date().timeIntervalSince1970]
        )
    }

    private struct MessageSearchDocument: Sendable {
        let primaryRowID: Int64
        let messageID: String
        let revision: Int64
        let generation: Int64
        let roomID: String
        let roomSequence: Int64
        let senderUserID: String
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
            text = row["text_body"]
            mediaPresentations = row["media_presentations"]
            createdAt = row["server_created_at"]
        }
    }

    private struct MessageSearchIndexJob: Sendable {
        let messageID: String
        let expectedRevision: Int64
        let generation: Int64
        let document: MessageSearchDocument?

        init(row: Row) throws {
            messageID = row["message_id"]
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

    private static func writeMessageSearchDocument(_ document: MessageSearchDocument, db: Database) throws {
        try deleteMessageSearchDocument(messageID: document.messageID, db: db)
        try db.execute(
            sql: """
            INSERT INTO v2_search_documents
                (message_id, message_revision, generation, room_id, room_sequence, sender_user_id, text_body, media_presentations, server_created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [document.messageID, document.revision, document.generation, document.roomID, document.roomSequence, document.senderUserID, document.text, document.mediaPresentations, document.createdAt]
        )
        guard !document.text.isEmpty else { return }
        let tokens = V2CharacterGramTokenizer().tokenize(document.text)
        guard !tokens.unigrams.isEmpty else { return }
        guard let rowID: Int64 = try Row.fetchOne(db, sql: "SELECT rowid FROM v2_search_documents WHERE message_id = ?", arguments: [document.messageID])?["rowid"]
        else { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(
            sql: "INSERT INTO v2_message_char_fts (rowid, room_scope, sender_scope, unigrams, bigrams) VALUES (?, ?, ?, ?, ?)",
            arguments: [rowID, V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: document.roomID), V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: document.senderUserID), tokens.unigrams.joined(separator: " "), tokens.bigrams.joined(separator: " ")]
        )
    }

    private static func deleteMessageSearchDocument(messageID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM v2_message_char_fts WHERE rowid IN (SELECT rowid FROM v2_search_documents WHERE message_id = ?)", arguments: [messageID])
        try db.execute(sql: "DELETE FROM v2_search_documents WHERE message_id = ?", arguments: [messageID])
    }

    private struct IndexedCandidate: Sendable {
        let hit: V2MessageSearchHit
        let revision: Int64
        let generation: Int64
    }

    private static func searchMessages(_ request: V2MessageSearchRequest, query: V2CharacterGramTokenizer.Tokens, generation: Int64, primaryDatabasePool: DatabasePool, db: Database) throws -> V2MessageSearchPage {
        let match = messageSearchMatch(scope: request.scope, query: query)
        let filterFingerprint = searchFilterFingerprint(request, generation: generation)
        var cursor = try validatedSearchCursor(request.cursor, for: request.scope, filterFingerprint: filterFingerprint)
        var scanCursor = cursor
        var hits: [V2MessageSearchHit] = []
        let batchSize = max(128, request.limit * 2)
        // A very stale derived index or a one-character query can have a low
        // acceptance ratio. Bound one synchronous call and return the scan
        // cursor so the UI can continue without monopolizing its executor.
        let scanBudget = max(512, min(2_000, request.limit * 20))
        var scannedCount = 0
        while scannedCount < scanBudget {
            let remainingBudget = scanBudget - scannedCount
            let fetchLimit = min(batchSize, remainingBudget)
            let rows = try searchCandidateRows(
                match: match,
                request: request,
                generation: generation,
                cursor: scanCursor,
                limit: fetchLimit,
                db: db
            )
            guard !rows.isEmpty else { return .init(hits: hits, nextCursor: nil) }
            scannedCount += rows.count
            let candidates = try rows.map(searchCandidate)
            let exactCandidates = candidates.filter { candidate in
                query.characterCount == 0 ||
                    V2CharacterGramTokenizer.normalize(candidate.hit.text).range(of: query.normalized) != nil
            }
            let currentMessageIDs = try currentSearchCandidateIDs(
                exactCandidates,
                generation: generation,
                primaryDatabasePool: primaryDatabasePool
            )
            for (candidateIndex, candidate) in candidates.enumerated() {
                let candidateCursor = searchCursor(for: candidate.hit, scope: request.scope, filterFingerprint: filterFingerprint)
                scanCursor = candidateCursor
                guard query.characterCount == 0 || V2CharacterGramTokenizer.normalize(candidate.hit.text).range(of: query.normalized) != nil else { continue }
                guard currentMessageIDs.contains(candidate.hit.messageID.rawValue) else { continue }
                hits.append(candidate.hit)
                cursor = candidateCursor
                if hits.count == request.limit {
                    let mayHaveMore = candidateIndex < candidates.count - 1 || rows.count == fetchLimit
                    return .init(hits: hits, nextCursor: mayHaveMore ? cursor : nil)
                }
            }
            if rows.count < batchSize { return .init(hits: hits, nextCursor: nil) }
        }
        return .init(hits: hits, nextCursor: scanCursor)
    }

    /// 以一次主库读取校验整批全文检索候选。
    ///
    /// 这样既保持了可替换索引的隐私安全，又避免了每个命中一次查询的 N+1 问题。
    ///
    /// - Parameters:
    ///   - candidates: 全文索引给出的候选。
    ///   - generation: 索引代次。
    ///   - db: 主库只读连接。
    /// - Returns: 在当前代次下仍然有效的候选标识。
    /// - Throws: 查询失败时抛出。
    private static func currentSearchCandidateIDs(
        _ candidates: [IndexedCandidate],
        generation: Int64,
        primaryDatabasePool: DatabasePool
    ) throws -> Set<String> {
        let expected = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            candidate.generation == generation
                ? (candidate.hit.messageID.rawValue, candidate.revision)
                : nil
        })
        guard !expected.isEmpty else { return [] }
        return try primaryDatabasePool.read { db in
            let identifiers = Array(expected.keys)
            let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT message_id, message_revision, is_withdrawn FROM v2_message_projections WHERE message_id IN (\(placeholders))",
                arguments: StatementArguments(identifiers)
            )
            return Set(try rows.compactMap { row -> String? in
                let messageID: String = row["message_id"]
                let revision = try searchInteger(row, "message_revision")
                let isWithdrawn: Bool = row["is_withdrawn"]
                return !isWithdrawn && expected[messageID] == revision ? messageID : nil
            })
        }
    }

    private static func messageSearchMatch(scope: V2MessageSearchScope, query: V2CharacterGramTokenizer.Tokens) -> String? {
        var clauses: [String] = []
        switch scope {
        case .room(let roomID): clauses.append("room_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "r", identifier: roomID.rawValue))
        case .allMessages: break
        case .sender(let userID): clauses.append("sender_scope : " + V2CharacterGramTokenizer.scopeToken(prefix: "s", identifier: userID.rawValue))
        }
        if query.characterCount == 0 { return nil }
        if query.characterCount == 1 { clauses.append("unigrams : " + query.unigrams[0]) }
        else { clauses.append("bigrams : \"" + query.bigrams.joined(separator: " ") + "\"") }
        return clauses.joined(separator: " AND ")
    }

    private static func validatedSearchCursor(_ cursor: V2MessageSearchCursor?, for scope: V2MessageSearchScope, filterFingerprint: String) throws -> V2MessageSearchCursor? {
        guard let cursor else { return nil }
        guard cursor.filterFingerprint == filterFingerprint else { throw V2MessageSearchError.cursorDoesNotMatchScope }
        switch (scope, cursor.storage) {
        case (.room(let scopeRoomID), .room(let cursorRoomID, _, _)) where scopeRoomID == cursorRoomID: return cursor
        case (.room, _), (.allMessages, .room), (.sender, .room): throw V2MessageSearchError.cursorDoesNotMatchScope
        case (.allMessages, .global), (.sender, .global): return cursor
        }
    }

    private static func searchCandidateRows(match: String?, request: V2MessageSearchRequest, generation: Int64, cursor: V2MessageSearchCursor?, limit: Int, db: Database) throws -> [Row] {
        var clauses = ["d.generation = ?"]
        var arguments: [DatabaseValueConvertible] = [generation]
        let from: String
        if let match {
            from = "v2_message_char_fts JOIN v2_search_documents d ON d.rowid = v2_message_char_fts.rowid"
            clauses.append("v2_message_char_fts MATCH ?")
            arguments.append(match)
        } else { from = "v2_search_documents d" }
        switch request.scope {
        case .room(let roomID): clauses.append("d.room_id = ?"); arguments.append(roomID.rawValue)
        case .allMessages: break
        case .sender(let userID): clauses.append("d.sender_user_id = ?"); arguments.append(userID.rawValue)
        }
        if let senderUserID = request.senderUserID { clauses.append("d.sender_user_id = ?"); arguments.append(senderUserID.rawValue) }
        switch request.contentFilter {
        case .all: break
        case .media: clauses.append("json_array_length(d.media_presentations) > 0")
        case .image, .video, .file, .audio:
            clauses.append("EXISTS (SELECT 1 FROM json_each(d.media_presentations) WHERE json_extract(json_each.value, '$.kind') = ?)")
            arguments.append(request.contentFilter.rawValue)
        }
        let base = "SELECT d.message_id, d.room_id, d.room_sequence, d.message_revision, d.generation, d.sender_user_id, d.text_body, d.server_created_at FROM \(from) WHERE \(clauses.joined(separator: " AND "))"
        switch (request.scope, cursor?.storage) {
        case (.room, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY d.room_sequence DESC, d.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.room, .room(_, let sequence, let messageID)):
            arguments += [try storageInteger(sequence), try storageInteger(sequence), messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (d.room_sequence < ? OR (d.room_sequence = ? AND d.message_id < ?)) ORDER BY d.room_sequence DESC, d.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, nil), (.sender, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY d.server_created_at DESC, d.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.allMessages, .global(let createdAt, let messageID)), (.sender, .global(let createdAt, let messageID)):
            arguments += [createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, messageID.rawValue, limit]
            return try Row.fetchAll(db, sql: base + " AND (d.server_created_at < ? OR (d.server_created_at = ? AND d.message_id < ?)) ORDER BY d.server_created_at DESC, d.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        default: throw V2MessageSearchError.cursorDoesNotMatchScope
        }
    }

    private static func searchInteger(_ row: Row, _ column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer > 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return integer
    }

    private static func searchCandidate(_ row: Row) throws -> IndexedCandidate {
        guard let sequence = UInt64(exactly: try searchInteger(row, "room_sequence")), sequence > 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let hit = try V2MessageSearchHit(messageID: .init(row["message_id"] as String), roomID: .init(row["room_id"] as String), roomSequence: sequence, senderUserID: .init(row["sender_user_id"] as String), text: row["text_body"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
        return try .init(hit: hit, revision: searchInteger(row, "message_revision"), generation: searchInteger(row, "generation"))
    }

    private static func searchCursor(for hit: V2MessageSearchHit, scope: V2MessageSearchScope, filterFingerprint: String) -> V2MessageSearchCursor {
        switch scope {
        case .room: .init(storage: .room(roomID: hit.roomID, roomSequence: hit.roomSequence, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        case .allMessages, .sender: .init(storage: .global(createdAt: hit.createdAt, messageID: hit.messageID), filterFingerprint: filterFingerprint)
        }
    }

    private static func searchFilterFingerprint(_ request: V2MessageSearchRequest, generation: Int64) -> String {
        let scope: String = switch request.scope {
        case .room(let roomID): "room:\(roomID.rawValue)"
        case .allMessages: "all"
        case .sender(let userID): "sender:\(userID.rawValue)"
        }
        let query = Data(V2CharacterGramTokenizer.normalize(request.query).utf8).base64EncodedString()
        return "v\(V2CharacterGramTokenizer.version)|g\(generation)|\(scope)|\(request.contentFilter.rawValue)|\(request.senderUserID?.rawValue ?? "")|\(query)"
    }
}
