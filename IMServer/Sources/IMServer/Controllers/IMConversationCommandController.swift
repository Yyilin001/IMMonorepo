import Vapor

extension IMConversationController {
    func createConversation(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(IMConversationCreateRequest.self)
        let creatorUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let response = try await commandService.createConversation(
            kind: body.kind,
            title: body.title,
            memberEmails: body.memberEmails,
            creatorUserID: creatorUserID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        await sideEffects.publish(
            eventType: IMTCPConversationEventType.conversationCreated,
            conversationID: response.id,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: creatorUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: response.id,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func addMembers(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMemberUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let readService = QueryReadModelFacade(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let previousMembers = try await readService.listMembers(in: conversationID, for: requesterUserID)
        let previousUserIDs = Set(previousMembers.map(\.id))

        let response = try await commandService.addMembers(
            in: conversationID,
            memberEmails: body.memberEmails,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        try await sideEffects.projectInlineOutboxIfAllowed()
        let updatedUserIDs = Set(response.memberUserIDs)
        let addedUserIDs = Array(updatedUserIDs.subtracting(previousUserIDs))
            .sorted { $0.uuidString < $1.uuidString }
        let existingUserIDs = Array(previousUserIDs).sorted { $0.uuidString < $1.uuidString }

        await sideEffects.publish(
            eventType: IMTCPConversationEventType.membersAdded,
            conversationID: conversationID,
            recipientUserIDs: existingUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.publish(
            eventType: IMTCPConversationEventType.conversationCreated,
            conversationID: conversationID,
            recipientUserIDs: addedUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func removeMember(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let memberUserID = try memberUserID(from: req)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let result = try await commandService.removeMember(
            in: conversationID,
            memberUserID: memberUserID,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        try await sideEffects.projectInlineOutboxIfAllowed()

        await sideEffects.publish(
            eventType: .membersUpdated,
            conversationID: conversationID,
            recipientUserIDs: result.remainingUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.publishRemovedForSelf(
            conversation: result.removedConversation,
            recipientUserID: memberUserID,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: result.remainingUserIDs
        )
        return result.requesterConversation
    }

    func updateMemberRole(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let memberUserID = try memberUserID(from: req)
        let body = try req.content.decode(IMConversationMemberRoleUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let role = try body.normalizedRole()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let response = try await commandService.updateMemberRole(
            in: conversationID,
            memberUserID: memberUserID,
            role: role,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        try await sideEffects.projectInlineOutboxIfAllowed()

        await sideEffects.publish(
            eventType: .membersUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateTitle(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationTitleUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let response = try await commandService.updateConversationTitle(
            in: conversationID,
            title: body.title,
            requesterUserID: requesterUserID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()

        await sideEffects.publish(
            eventType: .summaryUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updatePreferences(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationPreferencesUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let response = try await commandService.updateConversationPreferences(
            in: conversationID,
            isPinned: body.isPinned,
            isMuted: body.isMuted,
            requesterUserID: requesterUserID
        )

        await sideEffects.publish(
            eventType: .summaryUpdated,
            conversationID: conversationID,
            recipientUserIDs: [requesterUserID],
            actorUserID: requesterUserID
        )
        return response
    }

    func updateMetadata(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMetadataUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let response = try await commandService.updateConversationMetadata(
            in: conversationID,
            title: body.title,
            notice: body.notice,
            avatarPreset: body.avatarPreset,
            muteAll: body.muteAll,
            requesterUserID: requesterUserID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()

        await sideEffects.publish(
            eventType: .conversationSettingsChanged,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs
        )
        return response
    }

    func updateMyMemberProfile(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMemberSelfUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let response = try await commandService.updateMemberNickname(
            in: conversationID,
            requesterUserID: requesterUserID,
            memberNickname: body.memberNickname
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        try await sideEffects.projectInlineOutboxIfAllowed()
        await sideEffects.publish(
            eventType: .conversationSettingsChanged,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        return response
    }

    func markRead(req: Request) async throws -> IMConversationReadResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationReadRequest.self)
        let userID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let response = try await commandService.markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: body.readSequence
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        await sideEffects.publish(
            eventType: IMTCPConversationEventType.summaryUpdated,
            conversationID: conversationID,
            recipientUserIDs: [userID],
            actorUserID: userID
        )
        return response
    }

    func recallMessage(req: Request) async throws -> IMMessageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        guard
            let rawMessageID = req.parameters.get("messageID"),
            let messageID = UUID(uuidString: rawMessageID)
        else {
            throw Abort(.badRequest, reason: "消息 ID 无效。")
        }

        let userID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let strongReadService = QueryReadModelFacade(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        let conversation = try await strongReadService.conversationSummary(
            conversationID: conversationID,
            for: userID
        )

        await sideEffects.publish(
            eventType: .messageRecalled,
            conversationID: conversationID,
            recipientUserIDs: conversation.memberUserIDs,
            message: message,
            actorUserID: userID
        )
        return message
    }

    func editMessage(req: Request) async throws -> IMMessageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        guard
            let rawMessageID = req.parameters.get("messageID"),
            let messageID = UUID(uuidString: rawMessageID)
        else {
            throw Abort(.badRequest, reason: "消息 ID 无效。")
        }

        let body = try req.content.decode(IMConversationMessageEditRequest.self)
        let userID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let strongReadService = QueryReadModelFacade(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.editMessage(
            in: conversationID,
            messageID: messageID,
            text: body.text,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        let conversation = try await strongReadService.conversationSummary(
            conversationID: conversationID,
            for: userID
        )

        await sideEffects.publish(
            eventType: .messageUpdated,
            conversationID: conversationID,
            recipientUserIDs: conversation.memberUserIDs,
            message: message,
            actorUserID: userID
        )
        return message
    }

    func toggleReaction(req: Request) async throws -> IMMessageResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        guard
            let rawMessageID = req.parameters.get("messageID"),
            let messageID = UUID(uuidString: rawMessageID)
        else {
            throw Abort(.badRequest, reason: "消息 ID 无效。")
        }

        let body = try req.content.decode(IMConversationMessageReactionRequest.self)
        let userID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let strongReadService = QueryReadModelFacade(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: body.emoji,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        let conversation = try await strongReadService.conversationSummary(
            conversationID: conversationID,
            for: userID
        )

        await sideEffects.publish(
            eventType: .messageUpdated,
            conversationID: conversationID,
            recipientUserIDs: conversation.memberUserIDs,
            message: message,
            actorUserID: userID
        )
        return message
    }

    func leaveConversation(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let strongReadService = QueryReadModelFacade(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let removedConversation = try await strongReadService.conversationSummary(
            conversationID: conversationID,
            for: requesterUserID
        )
        let remainingUserIDs = removedConversation.memberUserIDs
            .filter { $0 != requesterUserID }

        try await commandService.leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        try await sideEffects.projectInlineOutboxIfAllowed()
        await sideEffects.publish(
            eventType: IMTCPConversationEventType.memberLeft,
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs,
            actorUserID: requesterUserID
        )
        await sideEffects.publishRemovedForSelf(
            conversation: removedConversation,
            recipientUserID: requesterUserID,
            actorUserID: requesterUserID
        )
        await sideEffects.sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: remainingUserIDs
        )
        return .ok
    }
}
