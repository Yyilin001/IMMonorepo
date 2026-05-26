import Fluent
import Vapor

struct UserController: RouteCollection {
    private let friendRequestService = FriendRequestService()
    private let contactChangesService = ContactChangesService()

    func boot(routes: any RoutesBuilder) throws {
        // /api/me 走最小化的受保护路由，用来验证 access token 是否仍可用。
        let protected = routes.grouped("api")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
        )

        protected.get("me", use: me)
        protected.patch("me", "profile", use: updateProfile)
        protected.get("contacts", use: contacts)
        protected.get("contacts", "changes", use: contactChanges)
        protected.post("contacts", use: addContact)
        protected.patch("contacts", ":contactUserID", use: updateContact)
        protected.delete("contacts", ":contactUserID", use: deleteContact)
        protected.get("contact-requests", use: contactRequests)
        protected.post("contact-requests", use: sendContactRequest)
        protected.post("contact-requests", ":requestID", "accept", use: acceptContactRequest)
        protected.post("contact-requests", ":requestID", "decline", use: declineContactRequest)
        protected.post("contact-requests", ":requestID", "cancel", use: cancelContactRequest)
        protected.get("blocks", use: blocks)
        protected.post("users", ":userID", "block", use: blockUser)
        protected.delete("users", ":userID", "block", use: unblockUser)
        protected.post("reports", use: createReport)
        protected.post("push", "device-tokens", use: registerPushDeviceToken)
        protected.delete("push", "device-tokens", ":tokenID", use: deletePushDeviceToken)
    }

    func me(req: Request) async throws -> UserResponse {
        try req.auth.require(User.self).asResponse()
    }

    func updateProfile(req: Request) async throws -> UserResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let body = try req.content.decode(UserProfileUpdateRequest.self)

        user.displayName = normalizedDisplayName(body.displayName)
        user.avatarPresetEnum = body.avatarPreset
        try await user.update(on: req.db)

        var affectedConversationRecipientUserIDs: [UUID: [UUID]] = [:]
        for readModelDB in summaryReadModelDatabases(for: req.application) {
            let refreshed = try await IMConversationSummaryProjectionService(
                sourceDB: req.application.imWriteDB,
                readModelDB: readModelDB
            ).refreshDirectPeerProfiles(for: userID)
            mergeRecipientUserIDs(refreshed, into: &affectedConversationRecipientUserIDs)
        }

        let conversationEventService = IMConversationEventService(app: req.application)
        for (conversationID, recipientUserIDs) in affectedConversationRecipientUserIDs {
            await conversationEventService.publish(
                eventType: .summaryUpdated,
                conversationID: conversationID,
                recipientUserIDs: recipientUserIDs,
                actorUserID: userID
            )
        }

        return try user.asResponse()
    }

    func contacts(req: Request) async throws -> [ContactResponse] {
        let user = try req.auth.require(User.self)
        let ownerUserID = try user.requireID()
        let contacts = try await UserContact.query(on: req.db)
            .filter(\.$owner.$id == ownerUserID)
            .with(\.$contact)
            .all()

        return try contacts
            .map { try ContactResponse(contact: $0) }
            .sorted { $0.email < $1.email }
    }

    func contactChanges(req: Request) async throws -> ContactChangesResponse {
        let user = try req.auth.require(User.self)
        return try await contactChangesService.listChanges(
            for: try user.requireID(),
            afterToken: req.query[String.self, at: "afterToken"],
            cursor: req.query[String.self, at: "cursor"],
            limit: req.query[Int.self, at: "limit"],
            on: req.db
        )
    }

    func addContact(req: Request) async throws -> ContactResponse {
        throw Abort(.badRequest, reason: "请通过好友申请添加联系人。")
    }

    func updateContact(req: Request) async throws -> ContactResponse {
        let user = try req.auth.require(User.self)
        let ownerUserID = try user.requireID()
        let contactUserID = try contactUserID(from: req)
        let body = try req.content.decode(ContactUpdateRequest.self)

        guard let contact = try await UserContact.query(on: req.db)
            .filter(\.$owner.$id == ownerUserID)
            .filter(\.$contact.$id == contactUserID)
            .with(\.$contact)
            .first()
        else {
            throw Abort(.notFound, reason: "联系人不存在。")
        }

        contact.remark = normalizedContactRemark(body.remark)
        try await contact.update(on: req.db)
        try await contactChangesService.recordContactUpsert(
            ownerUserID: ownerUserID,
            contactUserID: contactUserID,
            on: req.db
        )
        return try ContactResponse(contact: contact)
    }

    func deleteContact(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let ownerUserID = try user.requireID()
        let contactUserID = try contactUserID(from: req)
        let affectedDirectConversationIDs = try await req.db.transaction { database in
            guard let contact = try await UserContact.query(on: database)
                .filter(\.$owner.$id == ownerUserID)
                .filter(\.$contact.$id == contactUserID)
                .first()
            else {
                throw Abort(.notFound, reason: "联系人不存在。")
            }

            try await contact.delete(on: database)
            if let reverseContact = try await UserContact.query(on: database)
                .filter(\.$owner.$id == contactUserID)
                .filter(\.$contact.$id == ownerUserID)
                .first()
            {
                try await reverseContact.delete(on: database)
            }

            return try await IMDirectConversationStateService().updateExistingDirectConversations(
                between: ownerUserID,
                and: contactUserID,
                to: .frozenAfterUnfriend,
                on: database
            )
        }
        try await contactChangesService.recordContactRemoval(
            ownerUserID: ownerUserID,
            contactUserID: contactUserID,
            on: req.db
        )
        try await contactChangesService.recordContactRemoval(
            ownerUserID: contactUserID,
            contactUserID: ownerUserID,
            on: req.db
        )

        let eventService = IMContactEventService(app: req.application)
        await eventService.publishContactRemoved(
            recipientUserID: ownerUserID,
            contactUserID: contactUserID,
            actorUserID: ownerUserID
        )
        await eventService.publishContactRemoved(
            recipientUserID: contactUserID,
            contactUserID: ownerUserID,
            actorUserID: ownerUserID
        )
        let conversationEventService = IMConversationEventService(app: req.application)
        for conversationID in affectedDirectConversationIDs {
            let conversationDB = try await req.application.conversationShardRouter.commandDatabase(
                forConversationID: conversationID
            )
            try await ConversationOutboxService(db: conversationDB).enqueue(
                type: .directPeerUpdated,
                conversationID: conversationID,
                payload: ConversationDomainEventPayload(recipientUserIDs: [ownerUserID, contactUserID])
            )
            try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
            await conversationEventService.publish(
                eventType: .summaryUpdated,
                conversationID: conversationID,
                recipientUserIDs: [ownerUserID, contactUserID],
                actorUserID: ownerUserID
            )
        }
        return .ok
    }

    func contactRequests(req: Request) async throws -> [FriendRequestResponse] {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let box = req.query[String.self, at: "box"]
            .flatMap(ContactRequestBox.init(rawValue:)) ?? .all

        return try await friendRequestService.listRequests(
            for: userID,
            box: box,
            on: req.db
        )
    }

    func sendContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(ContactRequestCreateRequest.self)
        let requesterUserID = try user.requireID()
        let normalizedEmail = User.normalize(body.email)
        if let addressee = try await User.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .first(),
           try await hasBlockBetween(requesterUserID, and: addressee.requireID(), on: req.db)
        {
            throw Abort(.forbidden, reason: "当前无法发送好友申请。")
        }
        let response = try await friendRequestService.sendRequest(
            from: user,
            email: body.email,
            message: body.message,
            remark: body.remark,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.requester.id,
            requestID: response.id,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.addressee.id,
            requestID: response.id,
            on: req.db
        )
        await IMContactEventService(app: req.application).publishRequestEvent(
            eventType: .friendRequestCreated,
            request: response,
            recipientUserIDs: [response.requester.id, response.addressee.id],
            actorUserID: response.requester.id
        )
        return response
    }

    func acceptContactRequest(req: Request) async throws -> ContactResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(ContactRequestAcceptRequest.self)
        let result = try await friendRequestService.acceptRequest(
            id: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            remark: body.remark,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: result.request.requester.id,
            requestID: result.request.id,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: result.request.addressee.id,
            requestID: result.request.id,
            on: req.db
        )
        try await contactChangesService.recordContactUpsert(
            ownerUserID: result.request.requester.id,
            contactUserID: result.request.addressee.id,
            on: req.db
        )
        try await contactChangesService.recordContactUpsert(
            ownerUserID: result.request.addressee.id,
            contactUserID: result.request.requester.id,
            on: req.db
        )
        await IMContactEventService(app: req.application).publishAccepted(
            request: result.request,
            contactByRecipientUserID: [
                result.request.requester.id: result.requesterContact,
                result.request.addressee.id: result.addresseeContact
            ],
            actorUserID: result.request.addressee.id
        )
        let conversationEventService = IMConversationEventService(app: req.application)
        for conversationID in result.affectedDirectConversationIDs {
            let conversationDB = try await req.application.conversationShardRouter.commandDatabase(
                forConversationID: conversationID
            )
            try await ConversationOutboxService(db: conversationDB).enqueue(
                type: .directPeerUpdated,
                conversationID: conversationID,
                payload: ConversationDomainEventPayload(
                    recipientUserIDs: [result.request.requester.id, result.request.addressee.id]
                )
            )
            try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
            await conversationEventService.publish(
                eventType: .summaryUpdated,
                conversationID: conversationID,
                recipientUserIDs: [result.request.requester.id, result.request.addressee.id],
                actorUserID: result.request.addressee.id
            )
        }
        return result.addresseeContact
    }

    func declineContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        let response = try await friendRequestService.declineRequest(
            id: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.requester.id,
            requestID: response.id,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.addressee.id,
            requestID: response.id,
            on: req.db
        )
        await IMContactEventService(app: req.application).publishRequestEvent(
            eventType: .friendRequestDeclined,
            request: response,
            recipientUserIDs: [response.requester.id, response.addressee.id],
            actorUserID: response.addressee.id
        )
        return response
    }

    func cancelContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        let response = try await friendRequestService.cancelRequest(
            id: contactRequestID(from: req),
            requesterUserID: try user.requireID(),
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.requester.id,
            requestID: response.id,
            on: req.db
        )
        try await contactChangesService.recordRequestUpsert(
            ownerUserID: response.addressee.id,
            requestID: response.id,
            on: req.db
        )
        await IMContactEventService(app: req.application).publishRequestEvent(
            eventType: .friendRequestCancelled,
            request: response,
            recipientUserIDs: [response.requester.id, response.addressee.id],
            actorUserID: response.requester.id
        )
        return response
    }

    private func contactUserID(from req: Request) throws -> UUID {
        guard
            let rawContactUserID = req.parameters.get("contactUserID"),
            let contactUserID = UUID(uuidString: rawContactUserID)
        else {
            throw Abort(.badRequest, reason: "联系人 ID 无效。")
        }

        return contactUserID
    }

    private func contactRequestID(from req: Request) throws -> UUID {
        guard
            let rawRequestID = req.parameters.get("requestID"),
            let requestID = UUID(uuidString: rawRequestID)
        else {
            throw Abort(.badRequest, reason: "好友申请 ID 无效。")
        }

        return requestID
    }

    private func normalizedContactRemark(_ remark: String?) -> String? {
        let normalized = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(64))
    }

    private func normalizedDisplayName(_ displayName: String?) -> String? {
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(40))
    }

    private func summaryReadModelDatabases(for app: Application) -> [any Database] {
        switch app.summaryReadModelConfiguration.projectionWriteMode {
        case .legacy:
            return [app.imSummaryDB]
        case .sharded:
            return app.summaryShardRouter.shardIDs.map { app.summaryShardRouter.database(forShardID: $0) }
        case .dualWrite:
            return [app.imSummaryDB] + app.summaryShardRouter.shardIDs.map {
                app.summaryShardRouter.database(forShardID: $0)
            }
        }
    }

    private func mergeRecipientUserIDs(
        _ source: [UUID: [UUID]],
        into destination: inout [UUID: [UUID]]
    ) {
        for (conversationID, userIDs) in source {
            destination[conversationID, default: []].append(contentsOf: userIDs)
            destination[conversationID] = Array(Set(destination[conversationID] ?? []))
                .sorted { $0.uuidString < $1.uuidString }
        }
    }

    private func hasBlockBetween(_ lhs: UUID, and rhs: UUID, on db: any Database) async throws -> Bool {
        let lhsBlocked = try await UserBlock.find(
            UserBlock.recordID(ownerUserID: lhs, blockedUserID: rhs),
            on: db
        ) != nil
        let rhsBlocked = try await UserBlock.find(
            UserBlock.recordID(ownerUserID: rhs, blockedUserID: lhs),
            on: db
        ) != nil
        return lhsBlocked || rhsBlocked
    }
}

struct ContactCreateRequest: Content {
    let email: String
    let remark: String?
}

struct ContactUpdateRequest: Content {
    let remark: String?
}

struct UserProfileUpdateRequest: Content {
    let displayName: String?
    let avatarPreset: UserAvatarPreset?
}

struct ContactResponse: Content, Equatable, Sendable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarPreset: UserAvatarPreset?
    let remark: String?
    let createdAt: Date?

    init(
        id: UUID,
        email: String,
        displayName: String?,
        avatarPreset: UserAvatarPreset?,
        remark: String?,
        createdAt: Date?
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
        self.remark = remark
        self.createdAt = createdAt
    }

    init(contact: UserContact) throws {
        self.id = try contact.contact.requireID()
        self.email = contact.contact.email
        self.displayName = contact.contact.displayName
        self.avatarPreset = contact.contact.avatarPresetEnum
        self.remark = contact.remark
        self.createdAt = contact.createdAt
    }
}
