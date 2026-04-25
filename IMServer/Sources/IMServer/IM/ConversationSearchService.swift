import Fluent
import Vapor

struct ConversationSearchService {
    private enum SearchPage {
        static let defaultLimit = 20
        static let maxLimit = 50
        static let fetchMultiplier = 4
    }

    let db: any Database

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

        let limit = try normalizedSearchLimit(requestedLimit)
        let cursor = try normalizedSearchCursor(rawCursor)
        let chunkLimit = max(limit + 1, limit * SearchPage.fetchMultiplier)
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
                let content = try row.decodedContent()
                guard let snippet = searchSnippet(for: query, content: content) else {
                    continue
                }

                hits.append(
                    IMConversationMessageSearchHitResponse(
                        messageID: try row.requireID(),
                        senderUserID: row.$sender.id,
                        serverSequence: row.serverSequence,
                        content: content,
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

    func searchSnippet(for rawQuery: String, content: IMMessageContent) -> String? {
        let normalizedQuery = rawQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        for candidate in content.presentation.searchableTexts {
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
