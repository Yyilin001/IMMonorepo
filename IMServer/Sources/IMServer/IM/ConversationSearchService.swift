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
        let sender_user_id: UUID?
        let server_sequence: Int
        let content_json: String?
        let derived_state_json: String?
        let searchable_text: String
        let created_at: Date
    }

    let db: any Database

    init(db: any Database) {
        self.db = db
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
            throw Abort(.serviceUnavailable, reason: "搜索索引不可用。")
        }

        let limit = try normalizedSearchLimit(requestedLimit)
        let cursor = try normalizedSearchCursor(rawCursor)
        let normalizedPattern = "%\(query)%"
        let searchPredicate: SQLQueryString
        if sql.dialect.name == "postgresql" {
            searchPredicate = "\(ident: "searchable_text") ILIKE \(bind: normalizedPattern)"
        } else {
            searchPredicate = "LOWER(\(ident: "searchable_text")) LIKE LOWER(\(bind: normalizedPattern))"
        }

        let queryString: SQLQueryString
        if let cursor {
            queryString = """
                SELECT message_id, sender_user_id, server_sequence, content_json, derived_state_json, searchable_text, created_at
                FROM \(ident: ConversationMessageSearchIndex.schema)
                WHERE conversation_id = \(bind: conversationID)
                  AND server_sequence >= \(bind: membership.visibleFromSequence)
                  AND \(searchPredicate)
                  AND server_sequence < \(bind: cursor)
                ORDER BY server_sequence DESC
                LIMIT \(bind: limit + 1)
                """
        } else {
            queryString = """
                SELECT message_id, sender_user_id, server_sequence, content_json, derived_state_json, searchable_text, created_at
                FROM \(ident: ConversationMessageSearchIndex.schema)
                WHERE conversation_id = \(bind: conversationID)
                  AND server_sequence >= \(bind: membership.visibleFromSequence)
                  AND \(searchPredicate)
                ORDER BY server_sequence DESC
                LIMIT \(bind: limit + 1)
                """
        }

        let indexedRows = try await sql.raw(queryString).all(decoding: SearchIndexRow.self)
        let pageRows = Array(indexedRows.prefix(limit))
        let hasMore = indexedRows.count > limit
        let messageIDs = pageRows.map(\.message_id)

        guard !messageIDs.isEmpty else {
            return IMConversationMessageSearchPageResponse(items: [], nextCursor: nil, hasMore: false)
        }

        if let indexedItems = try directSearchItems(from: pageRows, query: query) {
            return IMConversationMessageSearchPageResponse(
                items: indexedItems,
                nextCursor: hasMore ? String(pageRows.last?.server_sequence ?? 0) : nil,
                hasMore: hasMore
            )
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
                serverSequence: try imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
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

    private func directSearchItems(
        from rows: [SearchIndexRow],
        query: String
    ) throws -> [IMConversationMessageSearchHitResponse]? {
        var items: [IMConversationMessageSearchHitResponse] = []
        items.reserveCapacity(rows.count)

        for row in rows {
            guard let senderUserID = row.sender_user_id,
                  let contentJSON = row.content_json,
                  let derivedStateJSON = row.derived_state_json,
                  let contentData = Data(base64Encoded: contentJSON),
                  let derivedStateData = Data(base64Encoded: derivedStateJSON)
            else {
                return nil
            }

            let content = try IMRTMessageContent(serializedBytes: contentData).domainValue()
            let derivedState = try IMRTMessageDerivedState(serializedBytes: derivedStateData).domainValue()
            items.append(
                IMConversationMessageSearchHitResponse(
                    messageID: row.message_id,
                    senderUserID: senderUserID,
                    serverSequence: try imPositiveUInt64Sequence(row.server_sequence, field: "server_sequence"),
                    content: content,
                    derivedState: derivedState,
                    snippet: searchSnippet(for: query, searchableText: row.searchable_text),
                    createdAt: row.created_at
                )
            )
        }

        return items
    }

    private func searchSnippet(for rawQuery: String, searchableText: String) -> String {
        let normalizedQuery = rawQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        for line in searchableText.split(separator: "\n", omittingEmptySubsequences: true) {
            let candidate = String(line)
            let normalizedCandidate = candidate.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if normalizedCandidate.contains(normalizedQuery) {
                return candidate
            }
        }
        return searchableText
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
