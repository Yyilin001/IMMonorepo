import Fluent
import SQLKit
import Vapor

struct ConversationSearchService {
    private enum SearchPage {
        static let defaultLimit = 20
        static let maxLimit = 50
    }

    private struct SearchIndexRow: Decodable {
        let message_id: UUID
        let server_sequence: Int
        let searchable_text: String
    }

    let db: any Database
    let allowLegacyFallback: Bool

    init(db: any Database, allowLegacyFallback: Bool = false) {
        self.db = db
        self.allowLegacyFallback = allowLegacyFallback
    }

    func searchMessages(
        in conversationID: UUID,
        membership: ConversationMember,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw Abort(.badRequest, reason: "搜索关键字不能为空。")
        }

        guard let sql = db as? any SQLDatabase else {
            return try await legacySearchMessages(
                in: conversationID,
                membership: membership,
                query: query,
                cursor: rawCursor,
                limit: requestedLimit
            )
        }

        let limit = try normalizedSearchLimit(requestedLimit)
        let cursor = try normalizedSearchCursor(rawCursor)
        let normalizedPattern = "%\(query)%"

        let queryString: SQLQueryString
        if let cursor {
            queryString = """
                SELECT message_id, server_sequence, searchable_text
                FROM \(ident: ConversationMessageSearchIndex.schema)
                WHERE conversation_id = \(bind: conversationID)
                  AND server_sequence >= \(bind: membership.visibleFromSequence)
                  AND LOWER(searchable_text) LIKE LOWER(\(bind: normalizedPattern))
                  AND server_sequence < \(bind: cursor)
                ORDER BY server_sequence DESC
                LIMIT \(bind: limit + 1)
                """
        } else {
            queryString = """
                SELECT message_id, server_sequence, searchable_text
                FROM \(ident: ConversationMessageSearchIndex.schema)
                WHERE conversation_id = \(bind: conversationID)
                  AND server_sequence >= \(bind: membership.visibleFromSequence)
                  AND LOWER(searchable_text) LIKE LOWER(\(bind: normalizedPattern))
                ORDER BY server_sequence DESC
                LIMIT \(bind: limit + 1)
                """
        }

        let indexedRows = try await sql.raw(queryString).all(decoding: SearchIndexRow.self)
        if indexedRows.isEmpty, allowLegacyFallback {
            return try await legacySearchMessages(
                in: conversationID,
                membership: membership,
                query: query,
                cursor: rawCursor,
                limit: requestedLimit
            )
        }
        let pageRows = Array(indexedRows.prefix(limit))
        let hasMore = indexedRows.count > limit
        let messageIDs = pageRows.map(\.message_id)

        guard !messageIDs.isEmpty else {
            return IMConversationMessageSearchPageResponse(items: [], nextCursor: nil, hasMore: false)
        }

        let messages = try await ConversationMessage.query(on: db)
            .filter(\.$id ~~ messageIDs)
            .all()
        let messagesByID = Dictionary(uniqueKeysWithValues: try messages.map { (try $0.requireID(), $0) })

        let items = try pageRows.compactMap { row -> IMConversationMessageSearchHitResponse? in
            guard let message = messagesByID[row.message_id] else {
                return nil
            }
            let aggregate = try message.decodedAggregate()
            let content = try message.decodedContent()
            let snippet = searchSnippet(for: query, aggregate: aggregate) ?? row.searchable_text
            return IMConversationMessageSearchHitResponse(
                messageID: row.message_id,
                senderUserID: message.$sender.id,
                serverSequence: message.serverSequence,
                content: content,
                derivedState: aggregate.derivedState,
                snippet: snippet,
                createdAt: message.createdAt
            )
        }

        return IMConversationMessageSearchPageResponse(
            items: items,
            nextCursor: hasMore ? String(pageRows.last?.server_sequence ?? 0) : nil,
            hasMore: hasMore
        )
    }

    func searchSnippet(for rawQuery: String, aggregate: IMMessageAggregate) -> String? {
        let normalizedQuery = rawQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        for candidate in MessagePresentation(aggregate: aggregate).searchableTexts {
            let normalizedCandidate = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard normalizedCandidate.contains(normalizedQuery) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func legacySearchMessages(
        in conversationID: UUID,
        membership: ConversationMember,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        let limit = try normalizedSearchLimit(requestedLimit)
        let cursor = try normalizedSearchCursor(rawCursor)
        let chunkLimit = max(limit + 1, limit * 4)
        var searchBeforeSequence = cursor
        var hits: [IMConversationMessageSearchHitResponse] = []
        var hasMore = false

        while hits.count < limit + 1 {
            let builder = ConversationMessage.query(on: db)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= membership.visibleFromSequence)
            if let searchBeforeSequence {
                builder.filter(\.$serverSequence < searchBeforeSequence)
            }

            let rows = try await builder
                .sort(\.$serverSequence, .descending)
                .limit(chunkLimit)
                .all()

            if rows.isEmpty {
                break
            }

            for row in rows {
                let aggregate = try row.decodedAggregate()
                let content = try row.decodedContent()
                guard let snippet = searchSnippet(for: rawQuery, aggregate: aggregate) else {
                    continue
                }

                hits.append(
                    IMConversationMessageSearchHitResponse(
                        messageID: try row.requireID(),
                        senderUserID: row.$sender.id,
                        serverSequence: row.serverSequence,
                        content: content,
                        derivedState: aggregate.derivedState,
                        snippet: snippet,
                        createdAt: row.createdAt
                    )
                )
                if hits.count > limit {
                    hasMore = true
                    break
                }
            }

            if rows.count < chunkLimit {
                break
            }
            searchBeforeSequence = rows.last?.serverSequence
            if hits.count > limit {
                break
            }
        }

        let pageItems = Array(hits.prefix(limit))
        let nextCursor = hasMore ? String(pageItems.last?.serverSequence ?? 0) : nil
        return IMConversationMessageSearchPageResponse(
            items: pageItems,
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    private func normalizedSearchLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return SearchPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, SearchPage.maxLimit)
    }

    private func normalizedSearchCursor(_ rawCursor: String?) throws -> Int? {
        guard let rawCursor else {
            return nil
        }

        let trimmedCursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCursor.isEmpty else {
            return nil
        }
        guard let cursor = Int(trimmedCursor), cursor > 0 else {
            throw Abort(.badRequest, reason: "搜索游标无效。")
        }
        return cursor
    }
}
