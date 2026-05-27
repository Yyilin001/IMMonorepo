import Fluent
import Vapor

struct UserController: RouteCollection {
    private let friendRequestService = FriendRequestService()
    private let contactChangesService = ContactChangesService()
    private let contactCommandService = ContactCommandService()

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
        let body = try req.content.decode(UserProfileUpdateRequest.self)

        let response = try await UserProfileCommandService(app: req.application)
            .updateProfile(user: user, displayName: body.displayName, avatarPreset: body.avatarPreset)
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()

        return response
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

        let response = try await contactCommandService.updateContact(
            ownerUserID: ownerUserID,
            contactUserID: contactUserID,
            remark: body.remark,
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return response
    }

    func deleteContact(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let ownerUserID = try user.requireID()
        let contactUserID = try contactUserID(from: req)
        try await contactCommandService.deleteContact(
            ownerUserID: ownerUserID,
            contactUserID: contactUserID,
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
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
        let response = try await contactCommandService.sendContactRequest(
            from: user,
            body: body,
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return response
    }

    func acceptContactRequest(req: Request) async throws -> ContactResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(ContactRequestAcceptRequest.self)
        let response = try await contactCommandService.acceptContactRequest(
            requestID: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            remark: body.remark,
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return response
    }

    func declineContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        let response = try await contactCommandService.declineContactRequest(
            requestID: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
        return response
    }

    func cancelContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        let response = try await contactCommandService.cancelContactRequest(
            requestID: contactRequestID(from: req),
            requesterUserID: try user.requireID(),
            on: req.db
        )
        try await InlineOutboxProjectionRuntime(app: req.application).flushIfAllowed()
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

    private func normalizedDisplayName(_ displayName: String?) -> String? {
        let normalized = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(40))
    }

    private func summaryReadModelDatabases(for app: Application) -> [any Database] {
        app.summaryShardRouter.shardIDs.map { app.summaryShardRouter.database(forShardID: $0) }
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
