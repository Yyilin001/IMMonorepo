import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationSummaryVerificationResult: Equatable, Sendable {
    var ownerUserCount: Int = 0
    var tombstoneSummaryCount: Int = 0
    var missingSummaryCount: Int = 0
    var staleActiveSummaryCount: Int = 0
    var latestVisibleMessageMismatchCount: Int = 0
    var unreadMismatchCount: Int = 0

    mutating func accumulate(_ other: ConversationSummaryVerificationResult) {
        ownerUserCount += other.ownerUserCount
        tombstoneSummaryCount += other.tombstoneSummaryCount
        missingSummaryCount += other.missingSummaryCount
        staleActiveSummaryCount += other.staleActiveSummaryCount
        latestVisibleMessageMismatchCount += other.latestVisibleMessageMismatchCount
        unreadMismatchCount += other.unreadMismatchCount
    }
}

private struct LatestActivityTokenRow: Decodable {
    let updatedAt: Date
    let recordID: String

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case recordID = "record_id"
    }
}

struct IMConversationSummaryProjectionService {
    struct PageCursor: Codable {
        let isPinned: Bool
        let pinnedAt: Date?
        let lastActivityAt: Date
        let recordID: String
    }

    struct ChangeToken: Codable {
        let updatedAt: Date
        let recordID: String
    }

    let sourceDB: any Database
    let readModelDB: any Database
    let userDirectoryDB: any Database
    let streamConsumerConfiguration: IMStreamConsumerConfiguration
    let domainEventMetrics: ConversationDomainEventMetrics?
    let summaryReadMetrics: IMSummaryReadMetrics?
    let activitySummaryCoalescer: ConversationActivitySummaryCoalescer?
    let responseMemberUserIDsLimit: Int
    let storedMemberUserIDsLimit: Int

    init(
        db: any Database,
        userDirectoryDB: (any Database)? = nil,
        streamConsumerConfiguration: IMStreamConsumerConfiguration = .load(from: .testing),
        domainEventMetrics: ConversationDomainEventMetrics? = nil,
        summaryReadMetrics: IMSummaryReadMetrics? = nil,
        activitySummaryCoalescer: ConversationActivitySummaryCoalescer? = nil,
        responseMemberUserIDsLimit: Int = 0,
        storedMemberUserIDsLimit: Int? = nil
    ) {
        self.init(
            sourceDB: db,
            readModelDB: db,
            userDirectoryDB: userDirectoryDB,
            streamConsumerConfiguration: streamConsumerConfiguration,
            domainEventMetrics: domainEventMetrics,
            summaryReadMetrics: summaryReadMetrics,
            activitySummaryCoalescer: activitySummaryCoalescer,
            responseMemberUserIDsLimit: responseMemberUserIDsLimit,
            storedMemberUserIDsLimit: storedMemberUserIDsLimit
        )
    }

    init(
        sourceDB: any Database,
        readModelDB: any Database,
        userDirectoryDB: (any Database)? = nil,
        streamConsumerConfiguration: IMStreamConsumerConfiguration = .load(from: .testing),
        domainEventMetrics: ConversationDomainEventMetrics? = nil,
        summaryReadMetrics: IMSummaryReadMetrics? = nil,
        activitySummaryCoalescer: ConversationActivitySummaryCoalescer? = nil,
        responseMemberUserIDsLimit: Int = 0,
        storedMemberUserIDsLimit: Int? = nil
    ) {
        self.sourceDB = sourceDB
        self.readModelDB = readModelDB
        self.userDirectoryDB = userDirectoryDB ?? sourceDB
        self.streamConsumerConfiguration = streamConsumerConfiguration
        self.domainEventMetrics = domainEventMetrics
        self.summaryReadMetrics = summaryReadMetrics
        self.activitySummaryCoalescer = activitySummaryCoalescer
        let environmentResponseLimit = Environment.get("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")
            .flatMap(Int.init(_:)) ?? 0
        self.responseMemberUserIDsLimit = max(0, max(responseMemberUserIDsLimit, environmentResponseLimit))
        let environmentStorageLimit = Environment.get("IM_SUMMARY_STORED_MEMBER_USER_IDS_LIMIT")
            .flatMap(Int.init(_:))
        self.storedMemberUserIDsLimit = max(
            0,
            storedMemberUserIDsLimit ?? environmentStorageLimit ?? self.responseMemberUserIDsLimit
        )
    }

    func listConversations(
        for userID: UUID,
        cursor rawCursor: String?,
        limit requestedLimit: Int?,
        kind rawKind: String? = nil
    ) async throws -> IMConversationPageResponse {
        let startedAt = Date()
        let limit = normalizedPageLimit(requestedLimit)
        do {
            let cursor = try rawCursor.map(Self.decodePageCursor)
            let kind = try normalizedConversationKind(rawKind)
            if let sql = readModelDB as? any SQLDatabase {
                let page = try await ConversationListJoinedReader(database: sql)
                    .listConversations(
                        for: userID,
                        cursor: cursor,
                        limit: limit,
                        kind: kind,
                        memberUserIDsLimit: responseMemberUserIDsLimit
                    )
                let items = page.rows.compactMap(\.response)
                guard items.count == page.rows.count else {
                    let response = try await listConversationsWithFluent(
                        for: userID,
                        cursor: cursor,
                        limit: limit,
                        kind: kind
                    )
                    await summaryReadMetrics?.recordListRead(
                        path: .fluent,
                        itemCount: response.items.count,
                        elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                        usedFallback: true
                    )
                    return response
                }
                let nextCursor = page.rows.last.map { Self.encodePageCursor($0.pageCursor) }
                let snapshotToken = try await latestToken(for: userID) ?? Self.encodeChangeToken(
                    ChangeToken(updatedAt: .distantPast, recordID: "")
                )
                let response = IMConversationPageResponse(
                    items: items,
                    nextCursor: page.hasMore ? nextCursor : nil,
                    hasMore: page.hasMore,
                    snapshotToken: snapshotToken
                )
                await summaryReadMetrics?.recordListRead(
                    path: .joined,
                    itemCount: response.items.count,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    usedFallback: false
                )
                return response
            }

            let response = try await listConversationsWithFluent(
                for: userID,
                cursor: cursor,
                limit: limit,
                kind: kind
            )
            await summaryReadMetrics?.recordListRead(
                path: .fluent,
                itemCount: response.items.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                usedFallback: false
            )
            return response
        } catch {
            await summaryReadMetrics?.recordListReadError(
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    private func elapsedMilliseconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private func listConversationsWithFluent(
        for userID: UUID,
        cursor: PageCursor?,
        limit: Int,
        kind: IMConversationKind?
    ) async throws -> IMConversationPageResponse {
        let query = ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .filter(\.$isRemoved == false)
            .sort(\.$isPinned, .descending)
            .sort(\.$pinnedAt, .descending)
            .sort(\.$lastActivityAt, .descending)
            .sort(\.$id, .descending)

        if let kind {
            query.filter(\.$kind == kind.rawValue)
        }

        if let cursor {
            query.group(.or) { group in
                if cursor.isPinned {
                    group.group(.and) { pinnedBefore in
                        pinnedBefore.filter(\.$isPinned == true)
                        pinnedBefore.filter(\.$pinnedAt < (cursor.pinnedAt ?? cursor.lastActivityAt))
                    }
                    group.group(.and) { pinnedTieBreaker in
                        pinnedTieBreaker.filter(\.$isPinned == true)
                        pinnedTieBreaker.filter(\.$pinnedAt == (cursor.pinnedAt ?? cursor.lastActivityAt))
                        pinnedTieBreaker.filter(\.$id < cursor.recordID)
                    }
                    group.filter(\.$isPinned == false)
                } else {
                    group.group(.and) { unpinnedBefore in
                        unpinnedBefore.filter(\.$isPinned == false)
                        unpinnedBefore.filter(\.$lastActivityAt < cursor.lastActivityAt)
                    }
                    group.group(.and) { unpinnedTieBreaker in
                        unpinnedTieBreaker.filter(\.$isPinned == false)
                        unpinnedTieBreaker.filter(\.$lastActivityAt == cursor.lastActivityAt)
                        unpinnedTieBreaker.filter(\.$id < cursor.recordID)
                    }
                }
            }
        }

        let rows = try await query
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let items = try await conversationResponsesWithActivityOverlay(from: pageRows)
        let nextCursor = pageRows.last.map {
            Self.encodePageCursor(PageCursor(
                isPinned: $0.isPinned,
                pinnedAt: $0.pinnedAt,
                lastActivityAt: $0.lastActivityAt,
                recordID: $0.id ?? ConversationUserSummary.recordID(
                    ownerUserID: userID,
                    conversationID: $0.conversationID
                )
            ))
        }

        let snapshotToken = try await latestToken(for: userID) ?? Self.encodeChangeToken(
            ChangeToken(updatedAt: .distantPast, recordID: "")
        )

        return IMConversationPageResponse(
            items: items,
            nextCursor: hasMore ? nextCursor : nil,
            hasMore: hasMore,
            snapshotToken: snapshotToken
        )
    }

    private func normalizedConversationKind(_ rawKind: String?) throws -> IMConversationKind? {
        guard let rawKind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKind.isEmpty
        else {
            return nil
        }

        guard let kind = IMConversationKind(rawValue: rawKind) else {
            throw Abort(.badRequest, reason: "会话类型无效。")
        }

        return kind
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken rawAfterToken: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int?
    ) async throws -> IMConversationChangesResponse {
        let startedAt = Date()
        let limit = normalizedPageLimit(requestedLimit)
        do {
            let afterToken = try Self.decodeChangeToken(rawAfterToken)
            let pageCursor = try rawCursor.map(Self.decodeChangeToken)

            if let sql = readModelDB as? any SQLDatabase {
                let page = try await ConversationChangesJoinedReader(database: sql)
                    .listConversationChanges(
                        for: userID,
                        afterToken: afterToken,
                        pageCursor: pageCursor,
                        limit: limit,
                        memberUserIDsLimit: responseMemberUserIDsLimit
                    )
                let joinedResponses = page.rows.map { row -> IMConversationResponse? in
                    row.response
                }
                guard !zip(page.rows, joinedResponses).contains(where: { row, response in
                    !row.changeIsRemoved && response == nil
                }) else {
                    let response = try await listConversationChangesWithFluent(
                        for: userID,
                        afterToken: afterToken,
                        rawAfterToken: rawAfterToken,
                        pageCursor: pageCursor,
                        limit: limit
                    )
                    await summaryReadMetrics?.recordChangesRead(
                        path: .fluent,
                        upsertCount: response.upserts.count,
                        removedCount: response.removedConversationIDs.count,
                        elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                        usedFallback: true
                    )
                    return response
                }
                let upserts = joinedResponses.compactMap { $0 }
                let removedConversationIDs = page.rows
                    .filter(\.changeIsRemoved)
                    .map(\.changeConversationID)
                let nextCursor = page.rows.last.map {
                    Self.encodeChangeToken(ChangeToken(updatedAt: $0.changeUpdatedAt, recordID: $0.changeID))
                }
                let targetToken = try await latestToken(for: userID) ?? rawAfterToken

                let response = IMConversationChangesResponse(
                    upserts: upserts,
                    removedConversationIDs: removedConversationIDs,
                    nextCursor: page.hasMore ? nextCursor : nil,
                    hasMore: page.hasMore,
                    targetToken: targetToken
                )
                await summaryReadMetrics?.recordChangesRead(
                    path: .joined,
                    upsertCount: response.upserts.count,
                    removedCount: response.removedConversationIDs.count,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                    usedFallback: false
                )
                return response
            }

            let response = try await listConversationChangesWithFluent(
                for: userID,
                afterToken: afterToken,
                rawAfterToken: rawAfterToken,
                pageCursor: pageCursor,
                limit: limit
            )
            await summaryReadMetrics?.recordChangesRead(
                path: .fluent,
                upsertCount: response.upserts.count,
                removedCount: response.removedConversationIDs.count,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
                usedFallback: false
            )
            return response
        } catch {
            await summaryReadMetrics?.recordChangesReadError(
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    private func listConversationChangesWithFluent(
        for userID: UUID,
        afterToken: ChangeToken,
        rawAfterToken: String,
        pageCursor: ChangeToken?,
        limit: Int
    ) async throws -> IMConversationChangesResponse {
        let query = ConversationChangesLogEntry.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .ascending)
            .sort(\.$id, .ascending)

        query.group(.or) { group in
            group.filter(\.$updatedAt > afterToken.updatedAt)
            group.group(.and) { tieBreaker in
                tieBreaker.filter(\.$updatedAt == afterToken.updatedAt)
                tieBreaker.filter(\.$id > afterToken.recordID)
            }
        }

        if let pageCursor {
            query.group(.or) { group in
                group.filter(\.$updatedAt > pageCursor.updatedAt)
                group.group(.and) { tieBreaker in
                    tieBreaker.filter(\.$updatedAt == pageCursor.updatedAt)
                    tieBreaker.filter(\.$id > pageCursor.recordID)
                }
            }
        }

        let rows = try await query
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let summaryRecordIDs = pageRows
            .filter { !$0.isRemoved }
            .map(\.summaryRecordID)
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let summariesByRecordID: [String: ConversationUserSummary] = Dictionary(uniqueKeysWithValues: summaries.compactMap { summary in
            guard let recordID = summary.id else {
                return nil
            }
            return (recordID, summary)
        })
        let overlaidResponses = try await conversationResponsesWithActivityOverlay(from: summaries)
        let responsesByRecordID: [String: IMConversationResponse] = Dictionary(uniqueKeysWithValues: zip(summaries, overlaidResponses).compactMap { summary, response in
            guard let recordID = summary.id else {
                return nil
            }
            return (recordID, response)
        })
        let upserts = pageRows.compactMap { row -> IMConversationResponse? in
            guard !row.isRemoved, summariesByRecordID[row.summaryRecordID] != nil else {
                return nil
            }
            return responsesByRecordID[row.summaryRecordID]
        }
        let removedConversationIDs = pageRows
            .filter(\.isRemoved)
            .map(\.conversationID)
        let nextCursor = pageRows.last.map {
            Self.encodeChangeToken(ChangeToken(updatedAt: $0.updatedAt, recordID: $0.id ?? ""))
        }

        let targetToken = try await latestToken(for: userID) ?? rawAfterToken

        return IMConversationChangesResponse(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs,
            nextCursor: hasMore ? nextCursor : nil,
            hasMore: hasMore,
            targetToken: targetToken
        )
    }

    private func latestToken(for userID: UUID) async throws -> String? {
        var candidates: [ChangeToken] = []
        if let token = try await ConversationReadModelToken.find(
            ConversationReadModelToken.recordID(ownerUserID: userID),
            on: readModelDB
        ) {
            if let decoded = try? Self.decodeChangeToken(token.targetToken) {
                candidates.append(decoded)
            }
        }

        if let latest = try await ConversationChangesLogEntry.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .sort(\.$id, .descending)
            .first()
        {
            candidates.append(ChangeToken(updatedAt: latest.updatedAt, recordID: latest.id ?? ""))
        }

        if let activityToken = try await latestActivityToken(for: userID) {
            candidates.append(activityToken)
        }

        guard let latest = candidates.max(by: { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.recordID < rhs.recordID
            }
            return lhs.updatedAt < rhs.updatedAt
        }) else {
            return nil
        }

        return Self.encodeChangeToken(latest)
    }

    private func latestActivityToken(for userID: UUID) async throws -> ChangeToken? {
        guard let sql = readModelDB as? any SQLDatabase else {
            return nil
        }

        let rows = try await sql.raw("""
            SELECT
                \(ident: "activity").\(ident: "updated_at") AS \(ident: "updated_at"),
                (\(bind: "activity:") || \(ident: "summary").\(ident: "id")) AS \(ident: "record_id")
            FROM \(ident: ConversationUserSummary.schema) AS \(ident: "summary")
            INNER JOIN \(ident: ConversationActivitySummary.schema) AS \(ident: "activity")
                ON \(ident: "activity").\(ident: "conversation_id") = \(ident: "summary").\(ident: "conversation_id")
            WHERE \(ident: "summary").\(ident: "owner_user_id") = \(bind: userID)
                AND \(ident: "summary").\(ident: "is_removed") = \(bind: false)
                AND NOT EXISTS (
                    SELECT 1
                    FROM \(ident: ConversationChangesLogEntry.schema) AS \(ident: "existing_log")
                    WHERE \(ident: "existing_log").\(ident: "owner_user_id") = \(ident: "summary").\(ident: "owner_user_id")
                        AND \(ident: "existing_log").\(ident: "conversation_id") = \(ident: "summary").\(ident: "conversation_id")
                        AND \(ident: "existing_log").\(ident: "updated_at") >= \(ident: "activity").\(ident: "updated_at")
                )
            ORDER BY \(ident: "activity").\(ident: "updated_at") DESC, \(ident: "record_id") DESC
            LIMIT 1
            """).all(decoding: LatestActivityTokenRow.self)

        guard let row = rows.first else {
            return nil
        }
        return ChangeToken(updatedAt: row.updatedAt, recordID: row.recordID)
    }

    private func normalizedPageLimit(_ requestedLimit: Int?) -> Int {
        let requested = requestedLimit ?? 50
        return max(1, min(requested, 100))
    }

    private func conversationResponsesWithActivityOverlay(
        from summaries: [ConversationUserSummary]
    ) async throws -> [IMConversationResponse] {
        guard !summaries.isEmpty else {
            return []
        }
        let conversationIDs = summaries.map(\.conversationID)
        let activities = try await ConversationActivitySummary.query(on: readModelDB)
            .filter(\.$id ~~ conversationIDs)
            .all()
        let activitiesByConversationID = Dictionary(uniqueKeysWithValues: activities.map {
            ($0.conversationID, $0)
        })
        return summaries.map {
            ConversationSummaryResponseOverlay.response(
                from: $0,
                activity: activitiesByConversationID[$0.conversationID],
                memberUserIDsLimit: responseMemberUserIDsLimit
            )
        }
    }

    private static func encodePageCursor(_ cursor: PageCursor) -> String {
        encode(cursor)
    }

    private static func decodePageCursor(_ value: String) throws -> PageCursor {
        try decode(PageCursor.self, from: value)
    }

    static func encodeChangeToken(_ token: ChangeToken) -> String {
        encode(token)
    }

    private static func decodeChangeToken(_ value: String) throws -> ChangeToken {
        try decode(ChangeToken.self, from: value)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = Data(base64Encoded: value) else {
            throw Abort(.badRequest, reason: "分页游标无效。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
