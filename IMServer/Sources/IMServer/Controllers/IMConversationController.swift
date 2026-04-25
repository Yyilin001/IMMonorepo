import Vapor

struct IMConversationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped("api", "im")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
            )

        protected.post("conversations", use: createConversation)
        protected.get("conversations", use: conversations)
        protected.get("conversations", "changes", use: conversationChanges)
        protected.get("conversations", ":conversationID", "members", use: members)
        protected.post("conversations", ":conversationID", "members", use: addMembers)
        protected.post("conversations", ":conversationID", "members", ":memberUserID", "remove", use: removeMember)
        protected.post("conversations", ":conversationID", "members", ":memberUserID", "role", use: updateMemberRole)
        protected.post("conversations", ":conversationID", "title", use: updateTitle)
        protected.patch("conversations", ":conversationID", "preferences", use: updatePreferences)
        protected.patch("conversations", ":conversationID", "metadata", use: updateMetadata)
        protected.get("conversations", ":conversationID", "messages", use: messages)
        protected.get("conversations", ":conversationID", "messages", "since", use: messagesSince)
        protected.post("conversations", ":conversationID", "messages", ":messageID", "recall", use: recallMessage)
        protected.post("conversations", ":conversationID", "read", use: markRead)
        protected.post("conversations", ":conversationID", "leave", use: leaveConversation)
    }

    func createConversation(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(IMConversationCreateRequest.self)
        let creatorUserID = try user.requireID()

        let response = try await IMConversationService(db: req.db).createConversation(
            kind: body.kind,
            title: body.title,
            memberEmails: body.memberEmails,
            creatorUserID: creatorUserID
        )
        await IMConversationEventService(app: req.application, db: req.db).publish(
            eventType: IMTCPConversationEventType.conversationCreated,
            conversationID: response.id,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: creatorUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: response.id,
            recipientUserIDs: response.memberUserIDs,
            using: req.application
        )
        return response
    }

    func conversations(req: Request) async throws -> IMConversationPageResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMConversationPageQuery.self)
        return try await IMConversationService(db: req.db)
            .listConversations(
                for: try user.requireID(),
                cursor: query.cursor,
                limit: query.limit
            )
    }

    func conversationChanges(req: Request) async throws -> IMConversationChangesResponse {
        let user = try req.auth.require(User.self)
        let query = try req.query.decode(IMConversationChangesQuery.self)
        return try await IMConversationService(db: req.db)
            .listConversationChanges(
                for: try user.requireID(),
                afterToken: query.afterToken,
                cursor: query.cursor,
                limit: query.limit
            )
    }

    func members(req: Request) async throws -> [IMConversationMemberResponse] {
        let user = try req.auth.require(User.self)
        guard
            let rawConversationID = req.parameters.get("conversationID"),
            let conversationID = UUID(uuidString: rawConversationID)
        else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }

        return try await IMConversationService(db: req.db)
            .listMembers(in: conversationID, for: try user.requireID())
    }

    func messages(req: Request) async throws -> [IMMessageResponse] {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let query = try req.query.decode(IMMessageHistoryQuery.self)

        return try await IMConversationService(db: req.db)
            .listMessages(
                in: conversationID,
                for: try user.requireID(),
                beforeSequence: query.beforeSequence,
                limit: query.limit
            )
    }

    func addMembers(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationMemberUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let service = IMConversationService(db: req.db)
        let previousMembers = try await service.listMembers(in: conversationID, for: requesterUserID)
        let previousUserIDs = Set(previousMembers.map(\.id))

        let response = try await service.addMembers(
            in: conversationID,
            memberEmails: body.memberEmails,
            requesterUserID: requesterUserID
        )
        let updatedUserIDs = Set(response.memberUserIDs)
        let addedUserIDs = Array(updatedUserIDs.subtracting(previousUserIDs))
            .sorted { $0.uuidString < $1.uuidString }
        let existingUserIDs = Array(previousUserIDs).sorted { $0.uuidString < $1.uuidString }
        let eventService = IMConversationEventService(app: req.application, db: req.db)

        await eventService.publish(
            eventType: IMTCPConversationEventType.membersAdded,
            conversationID: conversationID,
            recipientUserIDs: existingUserIDs,
            actorUserID: requesterUserID
        )
        await eventService.publish(
            eventType: IMTCPConversationEventType.conversationCreated,
            conversationID: conversationID,
            recipientUserIDs: addedUserIDs,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs,
            using: req.application
        )
        return response
    }

    func removeMember(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let memberUserID = try memberUserID(from: req)
        let requesterUserID = try user.requireID()
        let service = IMConversationService(db: req.db)
        let result = try await service.removeMember(
            in: conversationID,
            memberUserID: memberUserID,
            requesterUserID: requesterUserID
        )
        let eventService = IMConversationEventService(app: req.application, db: req.db)

        await eventService.publish(
            eventType: .membersUpdated,
            conversationID: conversationID,
            recipientUserIDs: result.remainingUserIDs,
            actorUserID: requesterUserID
        )
        await eventService.publishRemovedForSelf(
            conversation: result.removedConversation,
            recipientUserID: memberUserID,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: result.remainingUserIDs,
            using: req.application
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
        let service = IMConversationService(db: req.db)
        let response = try await service.updateMemberRole(
            in: conversationID,
            memberUserID: memberUserID,
            role: role,
            requesterUserID: requesterUserID
        )

        await IMConversationEventService(app: req.application, db: req.db).publish(
            eventType: .membersUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs,
            using: req.application
        )
        return response
    }

    func updateTitle(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationTitleUpdateRequest.self)
        let requesterUserID = try user.requireID()
        let response = try await IMConversationService(db: req.db).updateConversationTitle(
            in: conversationID,
            title: body.title,
            requesterUserID: requesterUserID
        )

        await IMConversationEventService(app: req.application, db: req.db).publish(
            eventType: .summaryUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs,
            using: req.application
        )
        return response
    }

    func updatePreferences(req: Request) async throws -> IMConversationResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationPreferencesUpdateRequest.self)
        let requesterUserID = try user.requireID()

        let response = try await IMConversationService(db: req.db).updateConversationPreferences(
            in: conversationID,
            isPinned: body.isPinned,
            isMuted: body.isMuted,
            requesterUserID: requesterUserID
        )

        await IMConversationEventService(app: req.application, db: req.db).publish(
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
        let response = try await IMConversationService(db: req.db).updateConversationMetadata(
            in: conversationID,
            title: body.title,
            notice: body.notice,
            avatarPreset: body.avatarPreset,
            requesterUserID: requesterUserID
        )

        await IMConversationEventService(app: req.application, db: req.db).publish(
            eventType: .summaryUpdated,
            conversationID: conversationID,
            recipientUserIDs: response.memberUserIDs,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: response.memberUserIDs,
            using: req.application
        )
        return response
    }

    func messagesSince(req: Request) async throws -> IMMessageSinceResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let query = try req.query.decode(IMMessageSinceQuery.self)

        return try await IMConversationService(db: req.db)
            .listMessagesSince(
                in: conversationID,
                for: try user.requireID(),
                afterSequence: query.afterSequence,
                limit: query.limit
            )
    }

    func markRead(req: Request) async throws -> IMConversationReadResponse {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let body = try req.content.decode(IMConversationReadRequest.self)
        let userID = try user.requireID()

        let response = try await IMConversationService(db: req.db).markConversationRead(
            in: conversationID,
            for: userID,
            readSequence: body.readSequence
        )
        await IMConversationEventService(app: req.application, db: req.db).publish(
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
        let service = IMConversationService(db: req.db)
        let message = try await service.recallMessage(
            in: conversationID,
            messageID: messageID,
            requesterUserID: userID
        )
        let conversation = try await service.conversationSummary(
            conversationID: conversationID,
            for: userID
        )
        let recipientUserIDs = conversation.memberUserIDs

        await IMConversationEventService(app: req.application, db: req.db).publish(
            eventType: .messageRecalled,
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs,
            message: message,
            actorUserID: userID
        )
        return message
    }

    func leaveConversation(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let conversationID = try conversationID(from: req)
        let requesterUserID = try user.requireID()
        let service = IMConversationService(db: req.db)
        let removedConversation = try await service.conversationSummary(
            conversationID: conversationID,
            for: requesterUserID
        )
        let remainingUserIDs = removedConversation.memberUserIDs
            .filter { $0 != requesterUserID }

        try await service.leaveConversation(
            in: conversationID,
            requesterUserID: requesterUserID
        )
        let eventService = IMConversationEventService(app: req.application, db: req.db)
        await eventService.publish(
            eventType: IMTCPConversationEventType.memberLeft,
            conversationID: conversationID,
            recipientUserIDs: remainingUserIDs,
            actorUserID: requesterUserID
        )
        await eventService.publishRemovedForSelf(
            conversation: removedConversation,
            recipientUserID: requesterUserID,
            actorUserID: requesterUserID
        )
        await sendLatestSystemMessageIfNeeded(
            in: conversationID,
            recipientUserIDs: remainingUserIDs,
            using: req.application
        )
        return .ok
    }

    private func sendLatestSystemMessageIfNeeded(
        in conversationID: UUID,
        recipientUserIDs: [UUID],
        using app: Application
    ) async {
        guard !recipientUserIDs.isEmpty else {
            return
        }

        do {
            guard let latestMessage = try await IMConversationService(db: app.db).latestMessage(in: conversationID) else {
                return
            }

            guard case .system = latestMessage.content else {
                return
            }

            await app.imConnectionRegistry.sendMessage(
                IMTCPMessagePayload(
                    clientMessageID: latestMessage.clientMessageID,
                    messageID: latestMessage.id.uuidString,
                    conversationID: conversationID.uuidString,
                    senderUserID: latestMessage.senderUserID,
                    serverSequence: UInt64(latestMessage.serverSequence),
                    serverTimestamp: latestMessage.createdAt,
                    content: latestMessage.content
                ),
                toUserIDs: recipientUserIDs
            )
        } catch {
            app.logger.warning(
                "Failed to send latest IM system message",
                metadata: [
                    "conversationID": .string(conversationID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func conversationID(from req: Request) throws -> UUID {
        guard
            let rawConversationID = req.parameters.get("conversationID"),
            let conversationID = UUID(uuidString: rawConversationID)
        else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }

        return conversationID
    }

    private func memberUserID(from req: Request) throws -> UUID {
        guard
            let rawMemberUserID = req.parameters.get("memberUserID"),
            let memberUserID = UUID(uuidString: rawMemberUserID)
        else {
            throw Abort(.badRequest, reason: "成员 ID 无效。")
        }

        return memberUserID
    }
}

struct IMMessageHistoryQuery: Content {
    let beforeSequence: Int?
    let limit: Int?
}

struct IMConversationPageQuery: Content {
    let cursor: String?
    let limit: Int?
}

struct IMConversationChangesQuery: Content {
    let afterToken: String
    let cursor: String?
    let limit: Int?
}

struct IMMessageSinceQuery: Content {
    let afterSequence: Int
    let limit: Int?
}

struct IMConversationCreateRequest: Content {
    let kind: String?
    let title: String?
    let memberEmails: [String]
}

struct IMConversationReadRequest: Content {
    let readSequence: Int
}

struct IMConversationMemberUpdateRequest: Content {
    let memberEmails: [String]
}

struct IMConversationMemberRoleUpdateRequest: Content {
    let role: String

    func normalizedRole() throws -> IMConversationMemberRole {
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalizedRole = IMConversationMemberRole(rawValue: trimmedRole) else {
            throw Abort(.badRequest, reason: "成员角色无效。")
        }
        return normalizedRole
    }
}

struct IMConversationTitleUpdateRequest: Content {
    let title: String
}

struct IMConversationPreferencesUpdateRequest: Content {
    let isPinned: Bool?
    let isMuted: Bool?
}

struct IMConversationMetadataUpdateRequest: Content {
    let title: String?
    let notice: String?
    let avatarPreset: IMConversationAvatarPreset?
}

struct IMConversationMemberResponse: Content, Equatable {
    let id: UUID
    let email: String
    let role: String
}

struct IMConversationResponse: Content, Equatable {
    let id: UUID
    let title: String?
    let kind: String
    let directMessagingState: String?
    let directPeer: IMDirectPeerResponse?
    let notice: String?
    let avatarPreset: IMConversationAvatarPreset?
    let memberCount: Int
    let memberUserIDs: [UUID]
    let lastMessage: IMMessagePreviewResponse?
    let lastReadSequence: Int
    let unreadCount: Int
    let isPinned: Bool
    let pinnedAt: Date?
    let isMuted: Bool
    let createdAt: Date?
    let updatedAt: Date

    init(
        id: UUID,
        title: String?,
        kind: String = IMConversationKind.group.rawValue,
        directMessagingState: String? = nil,
        directPeer: IMDirectPeerResponse? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        memberCount: Int? = nil,
        memberUserIDs: [UUID],
        lastMessage: IMMessagePreviewResponse?,
        lastReadSequence: Int = 0,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isMuted: Bool = false,
        createdAt: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.directMessagingState = directMessagingState
        self.directPeer = directPeer
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.memberCount = memberCount ?? memberUserIDs.count
        self.memberUserIDs = memberUserIDs
        self.lastMessage = lastMessage
        self.lastReadSequence = lastReadSequence
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isMuted = isMuted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct IMConversationPageResponse: Content, Equatable {
    let items: [IMConversationResponse]
    let nextCursor: String?
    let hasMore: Bool
    let snapshotToken: String
}

struct IMConversationChangesResponse: Content, Equatable {
    let upserts: [IMConversationResponse]
    let removedConversationIDs: [UUID]
    let nextCursor: String?
    let hasMore: Bool
    let targetToken: String
}

struct IMDirectPeerResponse: Content, Equatable, Sendable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarPreset: UserAvatarPreset?

    init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
    }
}

struct IMConversationReadResponse: Content, Equatable {
    let conversationID: UUID
    let lastReadSequence: Int
    let unreadCount: Int
}

struct IMMessagePreviewResponse: Content, Equatable {
    let id: UUID
    let senderUserID: UUID
    let serverSequence: Int
    let content: IMMessageContent
    let createdAt: Date?
}

struct IMMessageResponse: Content, Equatable {
    let id: UUID
    let conversationID: UUID
    let senderUserID: UUID
    let clientMessageID: String?
    let serverSequence: Int
    let content: IMMessageContent
    let createdAt: Date?
}

struct IMMessageSinceResponse: Content, Equatable {
    let messages: [IMMessageResponse]
    let hasMore: Bool
    let nextAfterSequence: Int?
}
