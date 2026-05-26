import Fluent
import Vapor

extension IMConversationController {
    func favoriteMessage(req: Request) async throws -> IMMessageResponse {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let messageID = try messageID(from: req)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        let message = try await IMCommonFeatureService(db: db).favoriteMessage(
            conversationID: conversationID,
            messageID: messageID,
            userID: userID
        )
        try await ConversationOutboxService(db: db).enqueue(
            type: .messageFavoriteChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [userID],
                messageID: messageID,
                favoriteChangedMessageID: messageID,
                isFavorited: true
            )
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return message
    }

    func unfavoriteMessage(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let messageID = try messageID(from: req)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await IMCommonFeatureService(db: db).unfavoriteMessage(messageID: messageID, userID: userID)
        try await ConversationOutboxService(db: db).enqueue(
            type: .messageFavoriteChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [userID],
                messageID: messageID,
                favoriteChangedMessageID: messageID,
                isFavorited: false
            )
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return .ok
    }

    func favorites(req: Request) async throws -> IMFavoritePageResponse {
        let userID = try req.auth.require(User.self).requireID()
        let query = try req.query.decode(IMFavoritePageQuery.self)
        let db = query.conversationID == nil
            ? req.application.imWriteDB
            : try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: query.conversationID!)
        return try await IMCommonFeatureService(db: db).listFavorites(
            userID: userID,
            conversationID: query.conversationID,
            cursor: query.cursor,
            limit: query.limit
        )
    }

    func deleteMessagesForSelf(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMMessageDeleteRequest.self)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await IMCommonFeatureService(db: db).hideMessages(
            conversationID: conversationID,
            messageIDs: body.messageIDs,
            userID: userID
        )
        try await ConversationOutboxService(db: db).enqueue(
            type: .messageVisibilityChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [userID],
                messageIDs: body.messageIDs,
                visibilityAction: .messageHidden
            )
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return .ok
    }

    func clearConversationForSelf(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await IMCommonFeatureService(db: db).clearConversation(
            conversationID: conversationID,
            userID: userID,
            deleteFromList: false
        )
        try await ConversationOutboxService(db: db).enqueue(
            type: .conversationVisibilityChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [userID],
                visibilityAction: .conversationCleared
            )
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return .ok
    }

    func deleteConversationForSelf(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        try await IMCommonFeatureService(db: db).clearConversation(
            conversationID: conversationID,
            userID: userID,
            deleteFromList: true
        )
        try await ConversationOutboxService(db: db).enqueue(
            type: .conversationRemovedForUser,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [userID],
                affectedUserID: userID,
                visibilityAction: .conversationDeleted
            )
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return .ok
    }

    func forwardMessages(req: Request) async throws -> [IMMessageResponse] {
        let userID = try req.auth.require(User.self).requireID()
        let sourceConversationID = try conversationID(from: req)
        let body = try req.content.decode(IMMessageForwardRequest.self)
        let sourceDB = try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: sourceConversationID)
        let sourceFeatureService = IMCommonFeatureService(db: sourceDB)
        let sourceMessages = try await body.messageIDs.asyncMap {
            try await sourceFeatureService.requireVisibleMessage(
                conversationID: sourceConversationID,
                messageID: $0,
                userID: userID
            )
        }
        guard !sourceMessages.isEmpty, !body.targetConversationIDs.isEmpty else {
            throw Abort(.badRequest, reason: "转发目标或消息不能为空。")
        }

        var responses: [IMMessageResponse] = []
        for targetConversationID in Array(Set(body.targetConversationIDs)) {
            let targetDB = try await req.application.conversationShardRouter.commandDatabase(forConversationID: targetConversationID)
            _ = try await ConversationMembershipService(db: targetDB).requireMembershipRecord(
                conversationID: targetConversationID,
                userID: userID
            )
            for sourceMessage in sourceMessages {
                let now = Date()
                let sequence = try await ConversationSequenceAllocator(db: targetDB).allocateNextServerSequence(
                    conversationID: targetConversationID,
                    updatedAt: now
                )
                let forwarded = try ConversationMessage(
                    conversationID: targetConversationID,
                    senderUserID: userID,
                    serverSequence: sequence,
                    content: sourceMessage.decodedContent(),
                    derivedState: sourceMessage.decodedDerivedState()
                )
                try await forwarded.create(on: targetDB)
                responses.append(try ConversationMessageService(db: targetDB).messageResponse(
                    from: forwarded,
                    conversationID: targetConversationID
                ))
            }
            try await ConversationOutboxService(db: targetDB).enqueue(
                type: .messageCreated,
                conversationID: targetConversationID,
                payload: ConversationDomainEventPayload(recipientUserIDs: [])
            )
        }
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return responses
    }

    func receiptSummary(req: Request) async throws -> IMConversationReceiptSummaryResponse {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let db = try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
        _ = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        let members = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let lastSequence = try await Conversation.find(conversationID, on: db)?.lastMessageSequence ?? 0
        let readThrough = members.map(\.lastReadSequence).min() ?? 0
        return IMConversationReceiptSummaryResponse(
            conversationID: conversationID,
            deliveredThroughSequence: members.count > 1 ? lastSequence : 0,
            readThroughSequence: readThrough,
            readableMemberCount: members.count
        )
    }

    func createInvite(req: Request) async throws -> IMGroupInviteResponse {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let body = try? req.content.decode(IMGroupInviteCreateRequest.self)
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        let conversation = try await ConversationMembershipService(db: db)
            .requireConversationAndMembership(conversationID: conversationID, userID: userID)
        try ConversationMembershipGuard.requireGroup(conversation, reason: "只有群聊支持邀请链接。")
        let membership = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(membership.memberRoleEnum, reason: "只有群主或管理员可以创建邀请链接。")

        let expiresIn = min(max(body?.expiresInSeconds ?? 7 * 24 * 60 * 60, 60), 30 * 24 * 60 * 60)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let invite = GroupInvite(
            token: token,
            conversationID: conversationID,
            creatorUserID: userID,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
        try await invite.create(on: req.application.imWriteDB)
        let recipientUserIDs = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
        try await ConversationOutboxService(db: db).enqueue(
            type: .inviteChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(recipientUserIDs: recipientUserIDs)
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return IMGroupInviteResponse(
            token: token,
            conversationID: conversationID,
            inviteURL: "imapp://group-invites/\(token)",
            expiresAt: invite.expiresAt,
            useCount: invite.useCount,
            revokedAt: invite.revokedAt
        )
    }

    func listInvites(req: Request) async throws -> [IMGroupInviteResponse] {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        let db = try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
        let conversation = try await ConversationMembershipService(db: db)
            .requireConversationAndMembership(conversationID: conversationID, userID: userID)
        try ConversationMembershipGuard.requireGroup(conversation, reason: "只有群聊支持邀请链接。")
        let membership = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(membership.memberRoleEnum, reason: "只有群主或管理员可以查看邀请链接。")

        let rows = try await GroupInvite.query(on: req.application.imWriteDB)
            .filter(\.$conversationID == conversationID)
            .sort(\.$createdAt, .descending)
            .all()
        return rows.compactMap { invite in
            guard let token = invite.id else { return nil }
            return IMGroupInviteResponse(
                token: token,
                conversationID: invite.conversationID,
                inviteURL: "imapp://group-invites/\(token)",
                expiresAt: invite.expiresAt,
                useCount: invite.useCount,
                revokedAt: invite.revokedAt
            )
        }
    }

    func revokeInvite(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let conversationID = try conversationID(from: req)
        guard let token = req.parameters.get("token"), !token.isEmpty else {
            throw Abort(.badRequest, reason: "邀请 token 无效。")
        }
        let db = try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
        let conversation = try await ConversationMembershipService(db: db)
            .requireConversationAndMembership(conversationID: conversationID, userID: userID)
        try ConversationMembershipGuard.requireGroup(conversation, reason: "只有群聊支持邀请链接。")
        let membership = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        try ConversationMembershipGuard.requireOwnerOrAdmin(membership.memberRoleEnum, reason: "只有群主或管理员可以撤销邀请链接。")
        guard let invite = try await GroupInvite.find(token, on: req.application.imWriteDB),
              invite.conversationID == conversationID
        else {
            throw Abort(.notFound, reason: "邀请链接不存在。")
        }
        invite.revokedAt = invite.revokedAt ?? Date()
        try await invite.update(on: req.application.imWriteDB)
        let recipients = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
        try await ConversationOutboxService(db: db).enqueue(
            type: .inviteChanged,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(recipientUserIDs: recipients)
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return .ok
    }

    func joinInvite(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let token = req.parameters.get("token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw Abort(.badRequest, reason: "邀请链接无效。")
        }
        guard let invite = try await GroupInvite.find(token, on: req.application.imWriteDB) else {
            throw Abort(.notFound, reason: "邀请链接不存在。")
        }
        guard invite.revokedAt == nil, invite.expiresAt > Date() else {
            throw Abort(.badRequest, reason: "邀请链接已失效。")
        }
        let db = try await req.application.conversationShardRouter.commandDatabase(forConversationID: invite.conversationID)
        let existing = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == invite.conversationID)
            .filter(\.$user.$id == userID)
            .first()
        if existing == nil {
            _ = try await ConversationCommandSupport(db: db).addMembers(
                in: invite.conversationID,
                memberEmails: [user.email],
                requesterUserID: invite.creatorUserID
            )
            invite.useCount += 1
            try await invite.update(on: req.application.imWriteDB)
        }
        return try await ConversationSummaryReadSupport(db: db).conversationSummary(
            conversationID: invite.conversationID,
            for: userID
        )
    }

    private func messageID(from req: Request) throws -> UUID {
        guard let rawMessageID = req.parameters.get("messageID"),
              let messageID = UUID(uuidString: rawMessageID)
        else {
            throw Abort(.badRequest, reason: "消息 ID 无效。")
        }
        return messageID
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
