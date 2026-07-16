import Fluent
import Vapor

struct ConversationMessageCommandSupport {
    let db: any Database

    private var membershipService: ConversationMembershipService { ConversationMembershipService(db: db) }
    private var messageService: ConversationMessageService { ConversationMessageService(db: db) }
    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        let conversation = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        try ConversationGovernanceService().requireUserMutationAllowed(in: conversation)

        let recalledMessage = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let message = try await ConversationMessageService(db: database).recallMessage(
                in: conversationID,
                messageID: messageID,
                requesterUserID: requesterUserID,
                on: database
            )
            try await publishMessageEvent(
                .messageRecalled,
                conversationID: conversationID,
                requesterUserID: requesterUserID,
                messageID: try message.requireID(),
                on: database
            )
            return message
        }

        return try messageService.messageResponse(from: recalledMessage, conversationID: conversationID)
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        body: IMRichTextContent,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        let conversation = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        try ConversationGovernanceService().requireUserMutationAllowed(in: conversation)

        let editedMessage = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let message = try await ConversationMessageService(db: database).editMessage(
                in: conversationID,
                messageID: messageID,
                body: body,
                requesterUserID: requesterUserID,
                on: database
            )
            try await publishMessageEvent(
                .messageUpdated,
                conversationID: conversationID,
                requesterUserID: requesterUserID,
                messageID: try message.requireID(),
                on: database
            )
            return message
        }

        return try messageService.messageResponse(from: editedMessage, conversationID: conversationID)
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        let conversation = try await requireConversationAndMembership(conversationID: conversationID, userID: requesterUserID)
        try ConversationGovernanceService().requireUserMutationAllowed(in: conversation)

        let updatedMessage = try await db.transaction { database in
            try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
            let message = try await ConversationMessageService(db: database).toggleReaction(
                in: conversationID,
                messageID: messageID,
                emoji: emoji,
                requesterUserID: requesterUserID,
                on: database
            )
            try await publishMessageEvent(
                .messageUpdated,
                conversationID: conversationID,
                requesterUserID: requesterUserID,
                messageID: try message.requireID(),
                on: database
            )
            return message
        }

        return try messageService.messageResponse(from: updatedMessage, conversationID: conversationID)
    }

    private func publishMessageEvent(
        _ type: ConversationDomainEventType,
        conversationID: UUID,
        requesterUserID: UUID,
        messageID: UUID,
        on database: any Database
    ) async throws {
        let recipientUserIDs = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
        try await ConversationOutboxEnqueuer(db: database).enqueueMessageEvent(
            type: type,
            conversationID: conversationID,
            actorUserID: requesterUserID,
            recipientUserIDs: recipientUserIDs,
            messageID: messageID,
            on: database
        )
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
