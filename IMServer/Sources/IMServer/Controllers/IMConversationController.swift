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
        protected.get("conversations", ":conversationID", "members", use: members)
        protected.post("conversations", ":conversationID", "members", use: addMembers)
        protected.get("conversations", ":conversationID", "messages", use: messages)
        protected.get("conversations", ":conversationID", "messages", "since", use: messagesSince)
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
        return response
    }

    func conversations(req: Request) async throws -> [IMConversationResponse] {
        let user = try req.auth.require(User.self)
        return try await IMConversationService(db: req.db)
            .listConversations(for: try user.requireID())
    }

    func members(req: Request) async throws -> [UserResponse] {
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
        return .ok
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
}

struct IMMessageHistoryQuery: Content {
    let beforeSequence: Int?
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

struct IMConversationResponse: Content, Equatable {
    let id: UUID
    let title: String?
    let kind: String
    let memberCount: Int
    let memberUserIDs: [UUID]
    let lastMessage: IMMessagePreviewResponse?
    let lastReadSequence: Int
    let unreadCount: Int
    let createdAt: Date?
    let updatedAt: Date

    init(
        id: UUID,
        title: String?,
        kind: String = IMConversationKind.group.rawValue,
        memberCount: Int? = nil,
        memberUserIDs: [UUID],
        lastMessage: IMMessagePreviewResponse?,
        lastReadSequence: Int = 0,
        unreadCount: Int = 0,
        createdAt: Date?,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.memberCount = memberCount ?? memberUserIDs.count
        self.memberUserIDs = memberUserIDs
        self.lastMessage = lastMessage
        self.lastReadSequence = lastReadSequence
        self.unreadCount = unreadCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    let kind: String
    let body: [String: String]
    let createdAt: Date?
}

struct IMMessageResponse: Content, Equatable {
    let id: UUID
    let conversationID: UUID
    let senderUserID: UUID
    let clientMessageID: String?
    let serverSequence: Int
    let kind: String
    let body: [String: String]
    let createdAt: Date?
}

struct IMMessageSinceResponse: Content, Equatable {
    let messages: [IMMessageResponse]
    let hasMore: Bool
    let nextAfterSequence: Int?
}
