import Fluent
import Vapor

struct ConversationCommonFeatureCommandService {
    let app: Application

    func favoriteMessage(userID: UUID, conversationID: UUID, messageID: UUID) async throws -> IMMessageResponse {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        return try await db.transaction { database in
            let message = try await IMCommonFeatureService(db: database).favoriteMessage(
                conversationID: conversationID,
                messageID: messageID,
                userID: userID
            )
            try await ConversationOutboxService(db: database).enqueue(
                type: .messageFavoriteChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .messageFavoriteChanged(messageID: messageID, isFavorited: true, ownerUserID: userID),
                on: database
            )
            return message
        }
    }

    func unfavoriteMessage(userID: UUID, conversationID: UUID, messageID: UUID) async throws {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await db.transaction { database in
            try await IMCommonFeatureService(db: database).unfavoriteMessage(messageID: messageID, userID: userID)
            try await ConversationOutboxService(db: database).enqueue(
                type: .messageFavoriteChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .messageFavoriteChanged(messageID: messageID, isFavorited: false, ownerUserID: userID),
                on: database
            )
        }
    }

    func hideMessages(userID: UUID, conversationID: UUID, messageIDs: [UUID]) async throws {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await db.transaction { database in
            try await IMCommonFeatureService(db: database).hideMessages(
                conversationID: conversationID,
                messageIDs: messageIDs,
                userID: userID
            )
            try await ConversationOutboxService(db: database).enqueue(
                type: .messageVisibilityChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .messageVisibilityChanged(
                    messageIDs: messageIDs,
                    action: .messageHidden,
                    affectedUserID: userID
                ),
                on: database
            )
        }
        app.invalidateTimelineSinceHotCache(conversationID: conversationID)
    }

    func clearConversation(userID: UUID, conversationID: UUID, deleteFromList: Bool) async throws {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await db.transaction { database in
            try await IMCommonFeatureService(db: database).clearConversation(
                conversationID: conversationID,
                userID: userID,
                deleteFromList: deleteFromList
            )
            try await ConversationOutboxService(db: database).enqueue(
                type: deleteFromList ? .conversationRemovedForUser : .conversationVisibilityChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: deleteFromList
                    ? .conversationRemovedForSelf(ownerUserID: userID)
                    : .conversationVisibilityChanged(action: .conversationCleared, ownerUserID: userID, messageIDs: []),
                on: database
            )
        }
        app.invalidateTimelineSinceHotCache(conversationID: conversationID)
    }

    func forwardMessages(
        userID: UUID,
        sourceConversationID: UUID,
        messageIDs: [UUID],
        targetConversationIDs: [UUID]
    ) async throws -> [IMMessageResponse] {
        let sourceDB = try await app.conversationShardRouter.strongReadDatabase(forConversationID: sourceConversationID)
        let sourceFeatureService = IMCommonFeatureService(db: sourceDB)
        var sourceMessages: [ConversationMessage] = []
        for messageID in messageIDs {
            let message = try await sourceFeatureService.requireVisibleMessage(
                conversationID: sourceConversationID,
                messageID: messageID,
                userID: userID
            )
            sourceMessages.append(message)
        }
        guard !sourceMessages.isEmpty, !targetConversationIDs.isEmpty else {
            throw Abort(.badRequest, reason: "转发目标或消息不能为空。")
        }

        var responses: [IMMessageResponse] = []
        for targetConversationID in Array(Set(targetConversationIDs)) {
            let targetDB = try await app.conversationShardRouter.commandDatabase(forConversationID: targetConversationID)
            _ = try await ConversationMembershipService(db: targetDB).requireMembershipRecord(
                conversationID: targetConversationID,
                userID: userID
            )
            for sourceMessage in sourceMessages {
                let response = try await targetDB.transaction { database in
                    let now = Date()
                    let sequence = try await ConversationSequenceAllocator(db: database).allocateNextServerSequence(
                        conversationID: targetConversationID,
                        updatedAt: now
                    )
                    let forwarded = try ConversationMessage(
                        conversationID: targetConversationID,
                        senderUserID: userID,
                        serverSequence: sequence,
                        timelineSequence: sequence,
                        content: sourceMessage.decodedContent(),
                        derivedState: sourceMessage.decodedDerivedState()
                    )
                    try await forwarded.create(on: database)
                    let forwardedID = try forwarded.requireID()
                    let recipientUserIDs = try await ConversationMember.query(on: database)
                        .filter(\.$conversation.$id == targetConversationID)
                        .all()
                        .map(\.$user.id)
                    let shouldInlineRecipients = app.messageCreatedRecipientInlineConfiguration.shouldInlineRecipients(
                        recipientCount: recipientUserIDs.count
                    )
                    try await ConversationOutboxService(
                        db: database,
                        domainEventMetrics: app.conversationDomainEventMetrics
                    ).enqueue(
                        type: .messageCreated,
                        conversationID: targetConversationID,
                        actorUserID: userID,
                        payload: .messageCreated(
                            messageID: forwardedID,
                            recipientUserIDs: shouldInlineRecipients ? recipientUserIDs : [],
                            preview: try ConversationMessageCreatedPreview(
                                senderUserID: forwarded.$sender.id,
                                serverSequence: imPositiveUInt64Sequence(forwarded.serverSequence, field: "server_sequence"),
                                timelineSequence: imPositiveUInt64Sequence(forwarded.timelineSequence, field: "timeline_sequence"),
                                previewText: forwarded.decodedContent().previewText,
                                createdAt: forwarded.createdAt
                            )
                        ),
                        recipientSnapshotUserIDs: shouldInlineRecipients ? nil : recipientUserIDs,
                        recipientSnapshotDeduplicationThreshold: app
                            .domainEventRecipientSnapshotConfiguration
                            .deduplicationThreshold,
                        on: database
                    )
                    return try ConversationMessageService(db: database).messageResponse(
                        from: forwarded,
                        conversationID: targetConversationID
                    )
                }
                app.invalidateTimelineSinceHotCache(conversationID: targetConversationID)
                responses.append(response)
            }
        }
        return responses
    }

    func createInvite(userID: UUID, conversationID: UUID, expiresInSeconds: Int?) async throws -> IMGroupInviteResponse {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        let invite = try await db.transaction { database in
            let conversation = try await ConversationMembershipService(db: database)
                .requireConversationAndMembership(conversationID: conversationID, userID: userID)
            try ConversationMembershipGuard.requireGroup(conversation, reason: "只有群聊支持邀请链接。")
            let membership = try await ConversationMembershipService(db: database).requireMembershipRecord(
                conversationID: conversationID,
                userID: userID
            )
            try ConversationMembershipGuard.requireOwnerOrAdmin(membership.memberRoleEnum, reason: "只有群主或管理员可以创建邀请链接。")

            let expiresIn = min(max(expiresInSeconds ?? 7 * 24 * 60 * 60, 60), 30 * 24 * 60 * 60)
            let invite = GroupInvite(
                token: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                conversationID: conversationID,
                creatorUserID: userID,
                expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
            )
            try await invite.create(on: app.imWriteDB)
            let recipientUserIDs = try await ConversationMember.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .all()
                .map(\.$user.id)
            try await ConversationOutboxService(db: database).enqueue(
                type: .inviteChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .inviteChanged(recipientUserIDs: recipientUserIDs),
                on: database
            )
            return invite
        }
        guard let token = invite.id else {
            throw Abort(.internalServerError, reason: "邀请链接缺少 token。")
        }
        return IMGroupInviteResponse(
            token: token,
            conversationID: conversationID,
            inviteURL: "imapp://group-invites/\(token)",
            expiresAt: invite.expiresAt,
            useCount: invite.useCount,
            revokedAt: invite.revokedAt
        )
    }

    func revokeInvite(userID: UUID, conversationID: UUID, token: String) async throws {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await db.transaction { database in
            let conversation = try await ConversationMembershipService(db: database)
                .requireConversationAndMembership(conversationID: conversationID, userID: userID)
            try ConversationMembershipGuard.requireGroup(conversation, reason: "只有群聊支持邀请链接。")
            let membership = try await ConversationMembershipService(db: database).requireMembershipRecord(
                conversationID: conversationID,
                userID: userID
            )
            try ConversationMembershipGuard.requireOwnerOrAdmin(membership.memberRoleEnum, reason: "只有群主或管理员可以撤销邀请链接。")
            guard let invite = try await GroupInvite.find(token, on: app.imWriteDB),
                  invite.conversationID == conversationID
            else {
                throw Abort(.notFound, reason: "邀请链接不存在。")
            }
            invite.revokedAt = invite.revokedAt ?? Date()
            try await invite.update(on: app.imWriteDB)
            let recipientUserIDs = try await ConversationMember.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .all()
                .map(\.$user.id)
            try await ConversationOutboxService(db: database).enqueue(
                type: .inviteChanged,
                conversationID: conversationID,
                actorUserID: userID,
                payload: .inviteChanged(recipientUserIDs: recipientUserIDs),
                on: database
            )
        }
    }
}
