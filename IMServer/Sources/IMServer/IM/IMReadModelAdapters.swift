import Fluent
import Foundation
import Vapor

protocol SummaryReadModelStore: Sendable {
    func conversationSummary(conversationID: UUID, for userID: UUID) async throws -> IMConversationResponse
    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse
    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse
}

protocol ConversationSearchAdapter: Sendable {
    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse
}

struct DatabaseSummaryReadModelStore: SummaryReadModelStore {
    let summaryDB: any Database

    private var summaryProjectionService: IMConversationSummaryProjectionService {
        IMConversationSummaryProjectionService(db: summaryDB)
    }

    func conversationSummary(conversationID: UUID, for userID: UUID) async throws -> IMConversationResponse {
        let recordID = ConversationUserSummary.recordID(ownerUserID: userID, conversationID: conversationID)
        guard let summary = try await ConversationUserSummary.find(recordID, on: summaryDB) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        guard !summary.isRemoved else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        return makeConversationResponse(from: summary)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await summaryProjectionService.listConversations(for: userID, cursor: cursor, limit: limit)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryProjectionService.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    private func makeConversationResponse(from row: ConversationUserSummary) -> IMConversationResponse {
        IMConversationResponse(
            id: row.conversationID,
            title: row.title,
            kind: row.kind,
            directMessagingState: row.directMessagingState,
            directPeer: row.directPeerUserID.map { directPeerUserID in
                IMDirectPeerResponse(
                    id: directPeerUserID,
                    email: row.directPeerEmail ?? "",
                    displayName: row.directPeerDisplayName,
                    avatarPreset: row.directPeerAvatarPresetEnum
                )
            },
            notice: row.notice,
            avatarPreset: row.avatarPresetEnum,
            memberCount: row.memberCount,
            memberUserIDs: row.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: row.lastMessage,
            lastReadSequence: row.lastReadSequence,
            unreadCount: row.unreadCount,
            isPinned: row.isPinned,
            pinnedAt: row.pinnedAt,
            isMuted: row.isMuted,
            createdAt: nil,
            updatedAt: row.lastActivityAt
        )
    }
}

struct OwnerShardedSummaryReadModelStore: SummaryReadModelStore {
    let app: Application
    let router: any SummaryShardRouter

    func conversationSummary(conversationID: UUID, for userID: UUID) async throws -> IMConversationResponse {
        try await store(for: userID).conversationSummary(conversationID: conversationID, for: userID)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await store(for: userID).listConversations(for: userID, cursor: cursor, limit: limit)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await store(for: userID).listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    private func store(for userID: UUID) -> DatabaseSummaryReadModelStore {
        DatabaseSummaryReadModelStore(summaryDB: router.database(forOwnerUserID: userID))
    }
}

struct DatabaseConversationSearchAdapter: ConversationSearchAdapter {
    let app: Application?
    let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await ConversationSearchReadSupport(db: database(forConversationID: conversationID)).searchMessages(
            in: conversationID,
            for: userID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    private func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            fatalError("DatabaseConversationSearchAdapter missing both app and database.")
        }
        return try await app.conversationShardRouter.eventualReadDatabase(forConversationID: conversationID)
    }
}

struct OpenSearchConversationSearchAdapter: ConversationSearchAdapter {
    private struct SearchRequestBody: Content {
        struct QueryBody: Content {
            struct BoolBody: Content {
                let filter: [FilterBody]
                let must: [MultiMatchBody]
            }

            struct FilterBody: Content {
                let term: [String: String]?
                let range: [String: [String: Int]]?
            }

            struct MultiMatchBody: Content {
                let query: String
                let fields: [String]
            }

            let bool: BoolBody
        }

        struct SortBody: Content {
            let serverSequence: [String: String]

            enum CodingKeys: String, CodingKey {
                case serverSequence = "serverSequence"
            }
        }

        let size: Int
        let query: QueryBody
        let searchAfter: [Int]?

        enum CodingKeys: String, CodingKey {
            case size
            case query
            case searchAfter = "search_after"
        }
    }

    private struct SearchResponseBody: Content {
        struct HitsBody: Content {
            struct HitBody: Content {
                struct SourceBody: Content {
                    let messageID: UUID
                    let serverSequence: Int

                    enum CodingKeys: String, CodingKey {
                        case messageID = "messageID"
                        case serverSequence = "serverSequence"
                    }
                }

                let source: SourceBody
                let sort: [Int]?

                enum CodingKeys: String, CodingKey {
                    case source = "_source"
                    case sort
                }
            }

            let hits: [HitBody]
        }

        let hits: HitsBody
    }

    let app: Application
    let endpoint: String
    let indexName: String
    let fallback: DatabaseConversationSearchAdapter?

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        let conversationReadDB = try await app.conversationShardRouter.eventualReadDatabase(forConversationID: conversationID)
        let membership = try await ConversationMembershipService(db: conversationReadDB)
            .requireMembershipRecord(conversationID: conversationID, userID: userID)

        let requestedLimit = limit ?? 20
        let normalizedLimit = max(1, min(requestedLimit, 50))
        let searchAfter = cursor.flatMap(Int.init(_:))
        let body = SearchRequestBody(
            size: normalizedLimit + 1,
            query: .init(
                bool: .init(
                    filter: [
                        .init(term: ["conversationID": conversationID.uuidString], range: nil),
                        .init(term: nil, range: ["serverSequence": ["gte": membership.visibleFromSequence]])
                    ],
                    must: [
                        .init(query: query, fields: ["searchableText"])
                    ]
                )
            ),
            searchAfter: searchAfter.map { [$0] }
        )

        do {
            let response = try await app.client.post(
                URI(string: "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(indexName)/_search")
            ) { request in
                try request.content.encode(body)
            }

            guard response.status == .ok else {
                throw Abort(.badGateway, reason: "OpenSearch query failed.")
            }

            let decoded = try response.content.decode(SearchResponseBody.self)
            let hitSources = decoded.hits.hits
            if hitSources.isEmpty {
                return IMConversationMessageSearchPageResponse(items: [], nextCursor: nil, hasMore: false)
            }

            let pageHits = Array(hitSources.prefix(normalizedLimit))
            let hasMore = hitSources.count > normalizedLimit
            let messageIDs = pageHits.map(\.source.messageID)
            let messages = try await ConversationMessage.query(on: conversationReadDB)
                .filter(\.$id ~~ messageIDs)
                .all()
            let byID = Dictionary(uniqueKeysWithValues: try messages.map { (try $0.requireID(), $0) })
            let searchService = ConversationSearchService(db: conversationReadDB, allowLegacyFallback: false)

            let items = try pageHits.compactMap { hit -> IMConversationMessageSearchHitResponse? in
                guard let message = byID[hit.source.messageID] else {
                    return nil
                }
                let aggregate = try message.decodedAggregate()
                let content = try message.decodedContent()
                return IMConversationMessageSearchHitResponse(
                    messageID: hit.source.messageID,
                    senderUserID: message.$sender.id,
                    serverSequence: message.serverSequence,
                    content: content,
                    derivedState: aggregate.derivedState,
                    snippet: searchService.searchSnippet(for: query, aggregate: aggregate) ?? "",
                    createdAt: message.createdAt
                )
            }

            return IMConversationMessageSearchPageResponse(
                items: items,
                nextCursor: hasMore ? String(pageHits.last?.source.serverSequence ?? 0) : nil,
                hasMore: hasMore
            )
        } catch {
            guard let fallback else {
                throw error
            }
            app.logger.warning(
                "OpenSearch adapter failed; falling back to database search",
                metadata: ["error": .string(String(describing: error))]
            )
            return try await fallback.searchMessages(
                in: conversationID,
                for: userID,
                query: query,
                cursor: cursor,
                limit: limit
            )
        }
    }
}

private struct SummaryReadModelStoreStorageKey: StorageKey {
    typealias Value = any SummaryReadModelStore
}

private struct ConversationSearchAdapterStorageKey: StorageKey {
    typealias Value = any ConversationSearchAdapter
}

extension Application {
    var summaryReadModelStore: any SummaryReadModelStore {
        get {
            if let store = storage[SummaryReadModelStoreStorageKey.self] {
                return store
            }
            let store: any SummaryReadModelStore
            if environment == .production {
                store = OwnerShardedSummaryReadModelStore(
                    app: self,
                    router: summaryShardRouter
                )
            } else {
                switch summaryReadModelConfiguration.queryReadSource {
                case .legacy:
                    store = DatabaseSummaryReadModelStore(summaryDB: imSummaryDB)
                case .sharded:
                    store = OwnerShardedSummaryReadModelStore(
                        app: self,
                        router: summaryShardRouter
                    )
                }
            }
            storage[SummaryReadModelStoreStorageKey.self] = store
            return store
        }
        set { storage[SummaryReadModelStoreStorageKey.self] = newValue }
    }

    var conversationSearchAdapter: any ConversationSearchAdapter {
        get {
            if let adapter = storage[ConversationSearchAdapterStorageKey.self] {
                return adapter
            }

            let adapter: any ConversationSearchAdapter
            if environment == .production {
                let endpoint = searchIndexConfiguration.endpoint ?? ""
                adapter = OpenSearchConversationSearchAdapter(
                    app: self,
                    endpoint: endpoint,
                    indexName: searchIndexConfiguration.indexName,
                    fallback: nil
                )
            } else {
                switch searchIndexConfiguration.driver {
                case .database:
                    adapter = DatabaseConversationSearchAdapter(app: self)
                case .openSearch:
                    if let endpoint = searchIndexConfiguration.endpoint, !endpoint.isEmpty {
                        adapter = OpenSearchConversationSearchAdapter(
                            app: self,
                            endpoint: endpoint,
                            indexName: searchIndexConfiguration.indexName,
                            fallback: DatabaseConversationSearchAdapter(app: self)
                        )
                    } else {
                        adapter = DatabaseConversationSearchAdapter(app: self)
                    }
                }
            }

            storage[ConversationSearchAdapterStorageKey.self] = adapter
            return adapter
        }
        set { storage[ConversationSearchAdapterStorageKey.self] = newValue }
    }
}
