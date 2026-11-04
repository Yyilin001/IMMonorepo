import Dispatch
import Foundation
import GRDB
import IMV2Core
import MessageSubstringSearch

struct V2DamagedSearchIndex: Error {
    let generation: Int64
}

actor V2MessageSearchReader {
    private let queue = DispatchSerialQueue(label: "IMV2.messageSearch.reader", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let primaryStatePool: DatabasePool
    private let searchPool: DatabasePool?
    private let lifetime: V2SearchLifetime
    private let storageIncarnation: UUID?
    private let instance = UUID()

    init(primary: DatabasePool, search: DatabasePool?, lifetime: V2SearchLifetime, storageIncarnation: UUID?) {
        self.storageIncarnation = storageIncarnation
        primaryStatePool = primary
        searchPool = search
        self.lifetime = lifetime
    }

    /// 执行一次消息搜索。
    ///
    /// 全文索引只给出候选；每个候选在成为命中之前都会与权威数据库的当前修订比对，
    /// 因此滞后或崩溃过的索引最多漏掉近期文本，绝不会暴露已被编辑、撤回或重置的消息。
    ///
    /// - Parameter request: 搜索请求。
    /// - Returns: 搜索结果分页。
    /// - Throws: 文本与筛选条件均为空、条数越界、索引不可用或游标与范围不匹配时抛出
    ///   ``V2MessageSearchError``；其余失败来自存储。
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        try lifetime.check()
        guard searchPool != nil else { throw V2MessageSearchError.indexUnavailable(.building) }
        guard (1 ... 100).contains(request.limit) else { throw V2MessageSearchError.invalidPageSize }
        let query = try SubstringSearchText(request.query)
        let hasSenderFilter: Bool
        switch request.scope {
        case .sender: hasSenderFilter = true
        case .allMessages, .room: hasSenderFilter = request.senderUserID != nil
        }
        guard !query.isEmpty || request.contentFilter != .all || hasSenderFilter else {
            throw V2MessageSearchError.emptyQuery
        }
        let primaryState = try await primaryStatePool.read { db in
            (try GRDBV2LocalSyncStore.readMessageSearchIndexState(db: db), try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: db))
        }
        guard primaryState.0 == .ready else { throw V2MessageSearchError.indexUnavailable(primaryState.0) }
        return try await page(request, query: query, generation: primaryState.1)
    }

    private struct IndexedCandidate {
        let messageID: MessageID
        let roomID: RoomID
        let roomSequence: UInt64
        let createdAt: Date
        let revision: Int64
    }

    private func page(_ request: V2MessageSearchRequest, query: SubstringSearchText, generation: Int64) async throws -> V2MessageSearchPage {
        guard let searchPool else { throw V2MessageSearchError.indexUnavailable(.building) }
        let match = Self.messageSearchMatch(scope: request.scope, query: query)
        let context = V2MessageSearchCursor.Context(storageIncarnation: storageIncarnation, instance: instance, generation: generation, scope: request.scope,
                                                   content: request.contentFilter, sender: request.senderUserID, tokens: query.encodedPhrase)
        var cursor = request.cursor
        if let cursor, cursor.context != context { throw V2MessageSearchError.cursorDoesNotMatchScope }
        var watermark = cursor?.watermark
        var hits: [V2MessageSearchHit] = []
        let batchSize = max(128, request.limit * 2)
        let budget = max(512, min(2000, request.limit * 20))
        var scanned = 0
        while scanned < budget {
            try lifetime.check()
            let limit = min(batchSize, budget - scanned)
            let previous = cursor, firstWatermark = watermark
            let batch: (Int64, [IndexedCandidate])
            do {
                batch = try await searchPool.read { db in
                    guard let state = try Row.fetchOne(db, sql: "SELECT generation, commit_sequence FROM v2_search_publication WHERE singleton = 1"),
                          try GRDBV2LocalSyncStore.searchInteger(state, "generation") == generation else {
                        throw V2DamagedSearchIndex(generation: generation)
                    }
                    let raw: DatabaseValue = state["commit_sequence"]
                    guard case .int64(let sequence) = raw.storage, sequence >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
                    let bound = firstWatermark ?? sequence
                    guard bound >= 0, bound <= sequence else { throw V2MessageSearchError.cursorDoesNotMatchScope }
                    let rows = try Self.searchCandidateRows(match: match, request: request, generation: generation,
                        cursor: previous, watermark: bound, limit: limit, db: db)
                    return (bound, try rows.map(Self.searchCandidate))
                }
            } catch let error as DatabaseError {
                if error.resultCode == .SQLITE_ERROR,
                   (try? await searchPool.read { try GRDBV2LocalSyncStore.isCurrentSearchSchema($0) }) == false {
                    throw V2DamagedSearchIndex(generation: generation)
                }
                if error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                    throw V2DamagedSearchIndex(generation: generation)
                }
                throw error
            }
            watermark = batch.0
            let candidates = batch.1
            let messages = try await Self.currentMessages(candidates, generation: generation, primary: primaryStatePool)
            scanned += candidates.count
            for (i, candidate) in candidates.enumerated() {
                try lifetime.check()
                cursor = Self.searchCursor(for: candidate, watermark: batch.0, context: context)
                guard var hit = messages[candidate.messageID.rawValue] else { continue }
                if !query.isEmpty {
                    hit.matchRanges = try request.previewHighlights
                        ? query.previewRanges(in: hit.text, characterCount: V2MessageSearchRequest.previewCharacterCount)
                        : query.matchingRanges(in: hit.text)
                    guard !hit.matchRanges.isEmpty else { continue }
                }
                hits.append(hit)
                if hits.count == request.limit {
                    try lifetime.check()
                    return .init(hits: hits, nextCursor: i + 1 < candidates.count || candidates.count == limit ? cursor : nil)
                }
            }
            if candidates.count < limit { break }
        }
        try lifetime.check()
        return .init(hits: hits, nextCursor: scanned == budget ? cursor : nil)
    }

    private static func currentMessages(_ candidates: [IndexedCandidate], generation: Int64, primary: DatabasePool) async throws -> [String: V2MessageSearchHit] {
        try await primary.read { db in
            guard try GRDBV2LocalSyncStore.readMessageSearchIndexState(db: db) == .ready,
                  try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: db) == generation else {
                throw V2MessageSearchError.indexUnavailable(.building)
            }
            guard !candidates.isEmpty else { return [:] }
            let expected = Dictionary(uniqueKeysWithValues: candidates.map { ($0.messageID.rawValue, $0) })
            let ids = Array(expected.keys)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT message_id,message_revision,room_id,room_sequence,sender_user_id,server_created_at,text_body FROM v2_message_projections WHERE is_withdrawn=0 AND message_id IN (\(placeholders))", arguments: StatementArguments(ids))
            var result: [String: V2MessageSearchHit] = [:]
            for row in rows {
                let id: String = row["message_id"]
                guard let item = expected[id], try GRDBV2LocalSyncStore.searchInteger(row, "message_revision") == item.revision,
                      row["room_id"] as String == item.roomID.rawValue,
                      UInt64(try GRDBV2LocalSyncStore.searchInteger(row, "room_sequence")) == item.roomSequence,
                      Date(timeIntervalSince1970: row["server_created_at"]) == item.createdAt else { continue }
                result[id] = try V2MessageSearchHit(messageID: item.messageID, roomID: item.roomID, roomSequence: item.roomSequence,
                    senderUserID: .init(row["sender_user_id"] as String), text: row["text_body"] as String? ?? "", createdAt: item.createdAt)
            }
            return result
        }
    }

    private static func messageSearchMatch(scope: V2MessageSearchScope, query: SubstringSearchText) -> String? {
        var clauses: [String] = []
        switch scope {
        case .room(let roomID): clauses.append("room_scope : " + v2SearchToken(prefix: "r", text: roomID.rawValue))
        case .allMessages: break
        case .sender(let userID): clauses.append("sender_scope : " + v2SearchToken(prefix: "s", text: userID.rawValue))
        }
        if query.isEmpty { return nil }
        clauses.append("tokens : \"\(query.encodedPhrase)\"")
        return clauses.joined(separator: " AND ")
    }

    private static func searchCandidateRows(match: String?, request: V2MessageSearchRequest, generation: Int64, cursor: V2MessageSearchCursor?, watermark: Int64, limit: Int, db: Database) throws -> [Row] {
        var clauses = ["d.generation = ?", "d.indexed_commit <= ?"]
        var arguments: [DatabaseValueConvertible] = [generation, watermark]
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
        let base = "SELECT d.message_id, d.room_id, d.room_sequence, d.message_revision, d.server_created_at FROM \(from) WHERE \(clauses.joined(separator: " AND "))"
        switch (request.scope, cursor?.storage) {
        case (.room, nil):
            arguments.append(limit)
            return try Row.fetchAll(db, sql: base + " ORDER BY d.room_sequence DESC, d.message_id DESC LIMIT ?", arguments: StatementArguments(arguments))
        case (.room, .room(_, let sequence, let messageID)):
            arguments += [try GRDBV2LocalSyncStore.storageInteger(sequence), try GRDBV2LocalSyncStore.storageInteger(sequence), messageID.rawValue, limit]
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

    private static func searchCandidate(_ row: Row) throws -> IndexedCandidate {
        guard let sequence = UInt64(exactly: try GRDBV2LocalSyncStore.searchInteger(row, "room_sequence")), sequence > 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try IndexedCandidate(messageID: .init(row["message_id"] as String), roomID: .init(row["room_id"] as String),
            roomSequence: sequence, createdAt: Date(timeIntervalSince1970: row["server_created_at"]),
            revision: GRDBV2LocalSyncStore.searchInteger(row, "message_revision"))
    }

    private static func searchCursor(for candidate: IndexedCandidate, watermark: Int64,
                                     context: V2MessageSearchCursor.Context) -> V2MessageSearchCursor {
        let storage: V2MessageSearchCursor.Storage = switch context.scope {
        case .room: .room(roomID: candidate.roomID, roomSequence: candidate.roomSequence, messageID: candidate.messageID)
        case .allMessages, .sender: .global(createdAt: candidate.createdAt, messageID: candidate.messageID)
        }
        return .init(storage: storage, context: context, watermark: watermark)
    }
}
