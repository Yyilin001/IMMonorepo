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

struct IMConversationSummaryProjectionService {
    private struct PageCursor: Codable {
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

    init(db: any Database) {
        self.init(sourceDB: db, readModelDB: db)
    }

    init(sourceDB: any Database, readModelDB: any Database) {
        self.sourceDB = sourceDB
        self.readModelDB = readModelDB
    }

    func listConversations(
        for userID: UUID,
        cursor rawCursor: String?,
        limit requestedLimit: Int?,
        kind rawKind: String? = nil
    ) async throws -> IMConversationPageResponse {
        let limit = normalizedPageLimit(requestedLimit)
        let cursor = try rawCursor.map(Self.decodePageCursor)
        let kind = try normalizedConversationKind(rawKind)
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
        let items = pageRows.map(makeConversationResponse)
        let nextCursor = pageRows.last.map {
            Self.encodePageCursor(PageCursor(
                isPinned: $0.isPinned,
                pinnedAt: $0.pinnedAt,
                lastActivityAt: $0.lastActivityAt,
                recordID: $0.id ?? ConversationUserSummary.recordID(
                    ownerUserID: $0.ownerUserID,
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
        let afterToken = try Self.decodeChangeToken(rawAfterToken)
        let pageCursor = try rawCursor.map(Self.decodeChangeToken)
        let limit = normalizedPageLimit(requestedLimit)

        if let sql = readModelDB as? any SQLDatabase {
            let page = try await ConversationChangesJoinedReader(database: sql)
                .listConversationChanges(
                    for: userID,
                    afterToken: afterToken,
                    pageCursor: pageCursor,
                    limit: limit
                )
            let joinedResponses = page.rows.map { row -> IMConversationResponse? in
                row.response
            }
            guard !zip(page.rows, joinedResponses).contains(where: { row, response in
                !row.changeIsRemoved && response == nil
            }) else {
                return try await listConversationChangesWithFluent(
                    for: userID,
                    afterToken: afterToken,
                    rawAfterToken: rawAfterToken,
                    pageCursor: pageCursor,
                    limit: limit
                )
            }
            let upserts = joinedResponses.compactMap { $0 }
            let removedConversationIDs = page.rows
                .filter(\.changeIsRemoved)
                .map(\.changeConversationID)
            let nextCursor = page.rows.last.map {
                Self.encodeChangeToken(ChangeToken(updatedAt: $0.changeUpdatedAt, recordID: $0.changeID))
            }
            let targetToken = try await latestToken(for: userID) ?? rawAfterToken

            return IMConversationChangesResponse(
                upserts: upserts,
                removedConversationIDs: removedConversationIDs,
                nextCursor: page.hasMore ? nextCursor : nil,
                hasMore: page.hasMore,
                targetToken: targetToken
            )
        }

        return try await listConversationChangesWithFluent(
            for: userID,
            afterToken: afterToken,
            rawAfterToken: rawAfterToken,
            pageCursor: pageCursor,
            limit: limit
        )
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
        let upserts = pageRows.compactMap { row -> IMConversationResponse? in
            guard !row.isRemoved, let summary = summariesByRecordID[row.summaryRecordID] else {
                return nil
            }
            return makeConversationResponse(from: summary)
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
        if let token = try await ConversationReadModelToken.find(
            ConversationReadModelToken.recordID(ownerUserID: userID),
            on: readModelDB
        ) {
            return token.targetToken
        }

        guard let latest = try await ConversationChangesLogEntry.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .sort(\.$id, .descending)
            .first()
        else {
            return nil
        }

        return Self.encodeChangeToken(ChangeToken(updatedAt: latest.updatedAt, recordID: latest.id ?? ""))
    }

    private func normalizedPageLimit(_ requestedLimit: Int?) -> Int {
        let requested = requestedLimit ?? 50
        return max(1, min(requested, 100))
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
            muteAll: row.muteAll,
            memberCount: row.memberCount,
            memberUserIDs: row.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: row.lastMessage,
            lastReadSequence: UInt64(row.lastReadSequence),
            unreadCount: row.unreadCount,
            isPinned: row.isPinned,
            pinnedAt: row.pinnedAt,
            isMuted: row.isMuted,
            createdAt: nil,
            updatedAt: row.lastActivityAt
        )
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
