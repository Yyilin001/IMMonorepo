import Fluent
import Vapor

struct ConversationMessageCommandSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var messageService: ConversationMessageService { ConversationMessageService(db: db) }
    private var messageEventPublisher: ConversationMessageEventPublisher { ConversationMessageEventPublisher(db: db) }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let recalledMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).recallMessage(
                in: conversationID,
                messageID: messageID,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageRecalled,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try recalledMessage.requireID()
        )
        return try messageService.messageResponse(from: recalledMessage, conversationID: conversationID)
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        text: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let editedMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).editMessage(
                in: conversationID,
                messageID: messageID,
                text: text,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageUpdated,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try editedMessage.requireID()
        )
        return try messageService.messageResponse(from: editedMessage, conversationID: conversationID)
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        _ = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)

        let updatedMessage = try await db.transaction { database in
            try await ConversationMessageService(db: database).toggleReaction(
                in: conversationID,
                messageID: messageID,
                emoji: emoji,
                requesterUserID: requesterUserID,
                on: database
            )
        }

        try await messageEventPublisher.publish(
            .messageUpdated,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            messageID: try updatedMessage.requireID()
        )

        return try messageService.messageResponse(from: updatedMessage, conversationID: conversationID)
    }

    private func requireConversationAndMembership(
        conversationID: UUID,
        userID: UUID
    ) async throws -> Conversation {
        try await membershipService.requireConversationAndMembership(
            conversationID: conversationID,
            userID: userID
        )
    }
}
