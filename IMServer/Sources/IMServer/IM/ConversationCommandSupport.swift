import Fluent
import Vapor

struct ConversationCommandSupport {
    let db: any Database
    let userDirectoryDB: any Database
    let usesLocalConversationDirectoryTables: Bool

    init(
        db: any Database,
        userDirectoryDB: (any Database)? = nil,
        usesLocalConversationDirectoryTables: Bool = true
    ) {
        self.db = db
        self.userDirectoryDB = userDirectoryDB ?? db
        self.usesLocalConversationDirectoryTables = usesLocalConversationDirectoryTables
    }

    private var membershipMutateSupport: ConversationMembershipCommandSupport {
        ConversationMembershipCommandSupport(
            db: db,
            userDirectoryDB: userDirectoryDB,
            usesLocalConversationDirectoryTables: usesLocalConversationDirectoryTables
        )
    }

    private var governanceMutateSupport: ConversationGovernanceCommandSupport {
        ConversationGovernanceCommandSupport(db: db, userDirectoryDB: userDirectoryDB)
    }

    private var messageMutateSupport: ConversationMessageCommandSupport {
        ConversationMessageCommandSupport(db: db)
    }

    private var readStateMutateSupport: ConversationReadStateCommandSupport {
        ConversationReadStateCommandSupport(db: db)
    }

    func createConversation(
        conversationID: UUID,
        assignedShardID: String,
        kind: String?,
        title: String?,
        memberEmails: [String],
        creatorUserID: UUID
    ) async throws -> ConversationCreateCommandResult {
        try await membershipMutateSupport.createConversation(
            conversationID: conversationID,
            assignedShardID: assignedShardID,
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
    ) async throws -> ConversationCommandReceipt {
        try await membershipMutateSupport.addMembers(
            in: conversationID,
            memberEmails: memberEmails,
            requesterUserID: requesterUserID
        )
    }

    func removeMember(
        in conversationID: UUID,
        memberUserID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationMemberRemovalResult {
        try await membershipMutateSupport.removeMember(
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
    ) async throws -> ConversationCommandReceipt {
        try await membershipMutateSupport.updateMemberRole(
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
    ) async throws -> ConversationCommandReceipt {
        try await governanceMutateSupport.updateConversationTitle(
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
        muteAll: Bool? = nil,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await governanceMutateSupport.updateConversationMetadata(
            in: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            muteAll: muteAll,
            requesterUserID: requesterUserID
        )
    }

    func updateMemberNickname(
        in conversationID: UUID,
        requesterUserID: UUID,
        memberNickname: String?
    ) async throws -> ConversationCommandReceipt {
        try await governanceMutateSupport.updateMemberNickname(
            in: conversationID,
            requesterUserID: requesterUserID,
            memberNickname: memberNickname
        )
    }

    func updateConversationPreferences(
        in conversationID: UUID,
        isPinned: Bool?,
        isMuted: Bool?,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await governanceMutateSupport.updateConversationPreferences(
            in: conversationID,
            isPinned: isPinned,
            isMuted: isMuted,
            requesterUserID: requesterUserID
        )
    }

    func markConversationRead(
        in conversationID: UUID,
        for userID: UUID,
        readSequence requestedReadSequence: Int
    ) async throws -> IMConversationReadResponse {
        try await readStateMutateSupport.markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: requestedReadSequence
        )
    }

    func recallMessage(
        in conversationID: UUID,
        messageID: UUID,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: requesterUserID
        )
    }

    func editMessage(
        in conversationID: UUID,
        messageID: UUID,
        body: IMRichTextContent,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.editMessage(
            in: conversationID,
            messageID: messageID,
            body: body,
            requesterUserID: requesterUserID
        )
    }

    func toggleReaction(
        in conversationID: UUID,
        messageID: UUID,
        emoji: String,
        requesterUserID: UUID
    ) async throws -> IMMessageResponse {
        try await messageMutateSupport.toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: emoji,
            requesterUserID: requesterUserID
        )
    }

    func leaveConversation(
        in conversationID: UUID,
        requesterUserID: UUID
    ) async throws -> ConversationCommandReceipt {
        try await membershipMutateSupport.leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
    }
}
