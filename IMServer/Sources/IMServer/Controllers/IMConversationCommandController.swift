import Vapor

extension IMConversationController {
    func createConversation(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(IMConversationCreateRequest.self)
        let creatorUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let result = try await commandService.createConversation(
            kind: body.kind,
            title: body.title,
            memberEmails: body.memberEmails,
            creatorUserID: creatorUserID
        )
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(result.receipt)
        }

        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: result.receipt,
            for: creatorUserID
        )
    }

    func addMembers(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMemberUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let receipt = try await commandService.addMembers(
            in: conversationID,
            memberEmails: body.memberEmails,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
    }

    func removeMember(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
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
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(result.receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: result.receipt,
            for: requesterUserID
        )
    }

    func updateMemberRole(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let memberUserID = try memberUserID(from: req)
        let body = try req.content.decode(IMConversationMemberRoleUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let role = try body.normalizedRole()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let receipt = try await commandService.updateMemberRole(
            in: conversationID,
            memberUserID: memberUserID,
            role: role,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
    }

    func updateTitle(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationTitleUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let receipt = try await commandService.updateConversationTitle(
            in: conversationID,
            title: body.title,
            requesterUserID: requesterUserID
        )
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
    }

    func updatePreferences(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationPreferencesUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let receipt = try await commandService.updateConversationPreferences(
            in: conversationID,
            isPinned: body.isPinned,
            isMuted: body.isMuted,
            requesterUserID: requesterUserID
        )
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
    }

    func updateMetadata(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMetadataUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let receipt = try await commandService.updateConversationMetadata(
            in: conversationID,
            title: body.title,
            notice: body.notice,
            avatarPreset: body.avatarPreset,
            muteAll: body.muteAll,
            requesterUserID: requesterUserID
        )
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
    }

    func updateMyMemberProfile(req: Request) async throws -> Response {
        try requireCommandReceiptWhenSummaryReadModelIsSeparate(req)
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMemberSelfUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let receipt = try await commandService.updateMemberNickname(
            in: conversationID,
            requesterUserID: requesterUserID,
            memberNickname: body.memberNickname
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return try await legacyConversationSummaryResponse(
            app: req.application,
            receipt: receipt,
            for: requesterUserID
        )
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
            readSequence: try imIntSequence(body.readSequence, field: "readSequence")
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
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
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
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
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.editMessage(
            in: conversationID,
            messageID: messageID,
            body: body.body,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
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
        let sideEffects = IMConversationCommandSideEffects(app: req.application)
        let message = try await commandService.toggleReaction(
            in: conversationID,
            messageID: messageID,
            emoji: body.emoji,
            requesterUserID: userID
        )
        try await sideEffects.projectInlineOutboxIfAllowed()
        return message
    }

    func leaveConversation(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let requesterUserID = try user.requireID()
        let commandService = IMConversationService.command(app: req.application)
        let sideEffects = IMConversationCommandSideEffects(app: req.application)

        let receipt = try await commandService.leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
        await sideEffects.invalidateMemberCacheEverywhere(conversationID: conversationID)
        if acceptsCommandReceipt(req) {
            return try commandReceiptResponse(receipt)
        }
        try await sideEffects.projectInlineOutboxIfAllowed()
        return Response(status: .ok)
    }
}
