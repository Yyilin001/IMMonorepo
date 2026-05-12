import Fluent
import Vapor

struct IMCommonFeatureService {
    let db: any Database

    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var messageService: ConversationMessageService { ConversationMessageService(db: db) }

    func requireVisibleMessage(conversationID: UUID, messageID: UUID, userID: UUID) async throws -> ConversationMessage {
        _ = try await membershipService.requireMembershipRecord(conversationID: conversationID, userID: userID)
        guard let message = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$id == messageID)
            .first()
        else {
            throw Abort(.notFound, reason: "消息不存在。")
        }

        if try await isHidden(message: message, for: userID) {
            throw Abort(.notFound, reason: "消息不存在。")
        }
        return message
    }

    func isHidden(message: ConversationMessage, for userID: UUID) async throws -> Bool {
        let conversationID = message.$conversation.id
        if let override = try await ConversationVisibilityOverride.find(
            ConversationVisibilityOverride.recordID(ownerUserID: userID, conversationID: conversationID),
            on: db
        ) {
            if override.isDeleted {
                return true
            }
            if let hiddenBeforeSequence = override.hiddenBeforeSequence,
               message.serverSequence <= hiddenBeforeSequence {
                return true
            }
        }

        if let messageID = message.id,
           let row = try await MessageVisibilityOverride.find(
            MessageVisibilityOverride.recordID(ownerUserID: userID, messageID: messageID),
            on: db
           ) {
            return row.isHidden
        }
        return false
    }

    func filterVisible(_ messages: [ConversationMessage], for userID: UUID) async throws -> [ConversationMessage] {
        var visible: [ConversationMessage] = []
        for message in messages {
            if try await !isHidden(message: message, for: userID) {
                visible.append(message)
            }
        }
        return visible
    }

    func favoriteMessage(conversationID: UUID, messageID: UUID, userID: UUID) async throws -> IMMessageResponse {
        let message = try await requireVisibleMessage(conversationID: conversationID, messageID: messageID, userID: userID)
        let favorite = MessageFavorite(
            ownerUserID: userID,
            conversationID: conversationID,
            messageID: try message.requireID(),
            serverSequence: message.serverSequence
        )
        if let existing = try await MessageFavorite.find(favorite.id, on: db) {
            existing.serverSequence = message.serverSequence
            try await existing.update(on: db)
        } else {
            try await favorite.create(on: db)
        }
        return try messageService.messageResponse(from: message, conversationID: conversationID)
    }

    func unfavoriteMessage(messageID: UUID, userID: UUID) async throws {
        if let favorite = try await MessageFavorite.find(
            MessageFavorite.recordID(ownerUserID: userID, messageID: messageID),
            on: db
        ) {
            try await favorite.delete(on: db)
        }
    }

    func listFavorites(userID: UUID, conversationID: UUID?, cursor: String?, limit requestedLimit: Int?) async throws -> IMFavoritePageResponse {
        let limit = min(max(requestedLimit ?? 30, 1), 100)
        let beforeDate = cursor.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let query = MessageFavorite.query(on: db)
            .filter(\.$ownerUserID == userID)
        if let conversationID {
            query.filter(\.$conversationID == conversationID)
        }
        if let beforeDate {
            query.filter(\.$createdAt < beforeDate)
        }

        var rows = try await query
            .sort(\.$createdAt, .descending)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        if hasMore {
            rows.removeLast()
        }

        var items: [IMMessageResponse] = []
        for favorite in rows {
            guard let message = try await ConversationMessage.find(favorite.messageID, on: db),
                  try await !isHidden(message: message, for: userID)
            else {
                continue
            }
            items.append(try messageService.messageResponse(from: message, conversationID: favorite.conversationID))
        }

        return IMFavoritePageResponse(
            items: items,
            nextCursor: hasMore ? rows.last.map { String($0.createdAt.timeIntervalSince1970) } : nil,
            hasMore: hasMore
        )
    }

    func hideMessages(conversationID: UUID, messageIDs: [UUID], userID: UUID) async throws {
        _ = try await membershipService.requireMembershipRecord(conversationID: conversationID, userID: userID)
        let uniqueIDs = Array(Set(messageIDs))
        guard !uniqueIDs.isEmpty else {
            throw Abort(.badRequest, reason: "至少需要选择一条消息。")
        }
        let messages = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$id ~~ uniqueIDs)
            .all()
        guard messages.count == uniqueIDs.count else {
            throw Abort(.notFound, reason: "部分消息不存在。")
        }
        for message in messages {
            let row = MessageVisibilityOverride(
                ownerUserID: userID,
                conversationID: conversationID,
                messageID: try message.requireID(),
                serverSequence: message.serverSequence
            )
            if let existing = try await MessageVisibilityOverride.find(row.id, on: db) {
                existing.isHidden = true
                try await existing.update(on: db)
            } else {
                try await row.create(on: db)
            }
        }
    }

    func clearConversation(conversationID: UUID, userID: UUID, deleteFromList: Bool) async throws {
        _ = try await membershipService.requireMembershipRecord(conversationID: conversationID, userID: userID)
        let lastSequence = try await Conversation.find(conversationID, on: db)?.lastMessageSequence ?? 0
        let id = ConversationVisibilityOverride.recordID(ownerUserID: userID, conversationID: conversationID)
        if let existing = try await ConversationVisibilityOverride.find(id, on: db) {
            existing.hiddenBeforeSequence = max(existing.hiddenBeforeSequence ?? 0, lastSequence)
            existing.isDeleted = deleteFromList
            existing.updatedAt = Date()
            try await existing.update(on: db)
        } else {
            try await ConversationVisibilityOverride(
                ownerUserID: userID,
                conversationID: conversationID,
                hiddenBeforeSequence: lastSequence,
                isDeleted: deleteFromList
            ).create(on: db)
        }
        if deleteFromList,
           let summary = try await ConversationUserSummary.find(
            ConversationUserSummary.recordID(ownerUserID: userID, conversationID: conversationID),
            on: db
           ) {
            summary.isRemoved = true
            summary.updatedAt = Date()
            try await summary.update(on: db)
        }
    }
}
