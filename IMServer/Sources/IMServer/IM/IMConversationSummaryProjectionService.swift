import Fluent
import Foundation
import Vapor

struct IMConversationSummaryProjectionService {
    private struct PageCursor: Codable {
        let isPinned: Bool
        let pinnedAt: Date?
        let lastActivityAt: Date
        let recordID: String
    }

    private struct ChangeToken: Codable {
        let updatedAt: Date
        let recordID: String
    }

    let db: any Database

    func refreshConversationSummaries(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        let updatedAt = Date()

        for recipientUserID in uniqueUserIDs {
            guard let membership = memberships.first(where: { $0.$user.id == recipientUserID }) else {
                continue
            }

            let summary = try await findOrCreateSummary(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                on: database
            )
            summary.ownerUserID = recipientUserID
            summary.conversationID = conversationID
            summary.title = conversation.title
            summary.kind = conversation.kind
            summary.directMessagingState = conversation.conversationKind == .direct ? conversation.directMessagingState : nil
            let directPeer = directPeer(from: memberships, currentUserID: recipientUserID)
            summary.directPeerUserID = directPeer?.id
            summary.directPeerEmail = directPeer?.email
            summary.notice = conversation.notice
            summary.avatarPresetEnum = conversation.avatarPresetEnum
            summary.memberUserIDs = memberUserIDs
            let lastVisibleMessage = try await ConversationMessage.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= membership.visibleFromSequence)
                .sort(\.$serverSequence, .descending)
                .first()
            let preview = try lastVisibleMessage.map(makePreview)
            let latestVisibleSequence = max(
                lastVisibleMessage?.serverSequence ?? 0,
                max(0, membership.visibleFromSequence - 1)
            )
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            summary.lastMessage = preview
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            summary.lastActivityAt = preview?.createdAt ?? conversation.updatedAt
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            try await save(summary, on: database)
        }
    }

    func markConversationRemoved(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let summary = try await findOrCreateSummary(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            on: database
        )
        summary.ownerUserID = recipientUserID
        summary.conversationID = conversationID
        summary.isRemoved = true
        summary.updatedAt = Date()
        try await save(summary, on: database)
    }

    func rebuildSummaries(for userID: UUID) async throws {
        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        let activeConversationIDs = memberships.map(\.$conversation.id)

        for conversationID in activeConversationIDs {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [userID],
                on: db
            )
        }

        let existing = try await ConversationUserSummary.query(on: db)
            .filter(\.$ownerUserID == userID)
            .all()
        let activeSet = Set(activeConversationIDs)
        for summary in existing where !activeSet.contains(summary.conversationID) && !summary.isRemoved {
            summary.isRemoved = true
            summary.updatedAt = Date()
            try await save(summary, on: db)
        }
    }

    func rebuildAllSummaries() async throws -> Int {
        let membershipOwnerUserIDs = try await ConversationMember.query(on: db)
            .all()
            .map(\.$user.id)
        let summaryOwnerUserIDs = try await ConversationUserSummary.query(on: db)
            .all()
            .map(\.ownerUserID)
        let ownerUserIDs = Array(Set(membershipOwnerUserIDs + summaryOwnerUserIDs))
            .sorted { $0.uuidString < $1.uuidString }

        for ownerUserID in ownerUserIDs {
            try await rebuildSummaries(for: ownerUserID)
        }

        return ownerUserIDs.count
    }

    func listConversations(
        for userID: UUID,
        cursor rawCursor: String?,
        limit requestedLimit: Int?
    ) async throws -> IMConversationPageResponse {
        let limit = normalizedPageLimit(requestedLimit)
        let cursor = try rawCursor.map(Self.decodePageCursor)
        let query = ConversationUserSummary.query(on: db)
            .filter(\.$ownerUserID == userID)
            .filter(\.$isRemoved == false)
            .sort(\.$isPinned, .descending)
            .sort(\.$pinnedAt, .descending)
            .sort(\.$lastActivityAt, .descending)
            .sort(\.$id, .descending)

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

    func listConversationChanges(
        for userID: UUID,
        afterToken rawAfterToken: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int?
    ) async throws -> IMConversationChangesResponse {
        let afterToken = try Self.decodeChangeToken(rawAfterToken)
        let pageCursor = try rawCursor.map(Self.decodeChangeToken)
        let limit = normalizedPageLimit(requestedLimit)

        let query = ConversationUserSummary.query(on: db)
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
        let upserts = pageRows
            .filter { !$0.isRemoved }
            .map(makeConversationResponse)
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

    private func findOrCreateSummary(
        ownerUserID: UUID,
        conversationID: UUID,
        on database: any Database
    ) async throws -> ConversationUserSummary {
        let recordID = ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        if let existing = try await ConversationUserSummary.find(recordID, on: database) {
            return existing
        }

        return try ConversationUserSummary(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            title: nil,
            kind: IMConversationKind.group.rawValue,
            directMessagingState: nil,
            directPeerUserID: nil,
            directPeerEmail: nil,
            notice: nil,
            avatarPreset: nil,
            memberUserIDs: [],
            lastMessage: nil,
            lastReadSequence: 0,
            unreadCount: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            lastActivityAt: .distantPast,
            updatedAt: .distantPast,
            isRemoved: false
        )
    }

    private func save(_ summary: ConversationUserSummary, on database: any Database) async throws {
        if try await ConversationUserSummary.find(summary.id, on: database) == nil {
            try await summary.create(on: database)
        } else {
            try await summary.update(on: database)
        }
    }

    private func latestToken(for userID: UUID) async throws -> String? {
        guard let latest = try await ConversationUserSummary.query(on: db)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .sort(\.$id, .descending)
            .first()
        else {
            return nil
        }

        return Self.encodeChangeToken(
            ChangeToken(
                updatedAt: latest.updatedAt,
                recordID: latest.id ?? ""
            )
        )
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
                    email: row.directPeerEmail ?? ""
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

    private func directPeer(
        from memberships: [ConversationMember],
        currentUserID: UUID
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peer = peerMembership.$user.value
        else {
            return nil
        }

        return IMDirectPeerResponse(id: peerMembership.$user.id, email: peer.email)
    }

    private func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            content: try message.decodedContent(),
            createdAt: message.createdAt
        )
    }

    private static func encodePageCursor(_ cursor: PageCursor) -> String {
        encode(cursor)
    }

    private static func decodePageCursor(_ value: String) throws -> PageCursor {
        try decode(PageCursor.self, from: value)
    }

    private static func encodeChangeToken(_ token: ChangeToken) -> String {
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
