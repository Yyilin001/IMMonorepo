import Fluent
import Vapor

struct IMConversationService {
    let db: any Database
    typealias MemberRemovalResult = ConversationMemberRemovalResult

    func createConversation(
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).createConversation(
            kind: kind,
            title: title,
            memberEmails: memberEmails,
            creatorUserID: creatorUserID
        )
    }

    func addMembers(
        in conversationID: UUID,
        memberEmails: [String],
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).addMembers(
            in: conversationID,
            memberEmails: memberEmails,
            requesterUserID: requesterUserID
        )
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws {
        try await ConversationCommandService(db: db).leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> MemberRemovalResult {
        try await ConversationCommandService(db: db).removeMember(
            in: conversationID,
            memberUserID: memberUserID,
            requesterUserID: requesterUserID
        )
    }

    func updateMemberRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).updateMemberRole(
            in: conversationID,
            memberUserID: memberUserID,
            role: role,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationTitle(
        in conversationID: UUID,
        title: String,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).updateConversationTitle(
            in: conversationID,
            title: title,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationMetadata(
        in conversationID: UUID,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).updateConversationMetadata(
            in: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            requesterUserID: requesterUserID
        )
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationCommandService(db: db).updateConversationPreferences(
            in: conversationID,
            isPinned: isPinned,
            isMuted: isMuted,
            requesterUserID: requesterUserID
        )
    }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await ConversationCommandService(db: db).recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: requesterUserID
        )
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        text: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await ConversationCommandService(db: db).editMessage(
            in: conversationID,
            messageID: messageID,
            text: text,
            requesterUserID: requesterUserID
        )
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await ConversationCommandService(db: db).toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: emoji,
            requesterUserID: requesterUserID
        )
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await ConversationStrongReadService(db: db).latestMessage(in: conversationID)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?,
        kind: String? = nil
    ) async throws -> IMConversationPageResponse {
        try await ConversationEventualReadService(db: db).listConversations(
            for: userID,
            cursor: cursor,
            limit: limit,
            kind: kind
        )
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await ConversationEventualReadService(db: db).listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await ConversationEventualReadService(db: db).listMembers(in: conversationID, for: userID)
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int? = nil,
        limit requestedLimit: Int? = nil
    ) async throws -> [IMMessageResponse] {
        try await ConversationEventualReadService(db: db).listMessages(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: requestedLimit
        )
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit requestedLimit: Int? = nil
    ) async throws -> IMMessageSinceResponse {
        try await ConversationEventualReadService(db: db).listMessagesSince(
            in: conversationID,
            for: userID,
            afterSequence: afterSequence,
            limit: requestedLimit
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query rawQuery: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await ConversationEventualReadService(db: db).searchMessages(
            in: conversationID,
            for: userID,
            query: rawQuery,
            cursor: rawCursor,
            limit: requestedLimit
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        try await ConversationCommandService(db: db).markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: requestedReadSequence
        )
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await ConversationStrongReadService(db: db).conversationSummary(
            conversationID: conversationID,
            for: userID
        )
    }
}
