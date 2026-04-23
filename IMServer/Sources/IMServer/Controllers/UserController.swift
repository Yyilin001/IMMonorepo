import Fluent
import Vapor

struct UserController: RouteCollection {
    private let friendRequestService = FriendRequestService()

    func boot(routes: any RoutesBuilder) throws {
        // /api/me 走最小化的受保护路由，用来验证 access token 是否仍可用。
        let protected = routes.grouped("api")
            .grouped(
                AccessTokenAuthenticator(),
                User.guardMiddleware(throwing: Abort(.unauthorized, reason: "用户未登录。"))
        )

        protected.get("me", use: me)
        protected.get("contacts", use: contacts)
        protected.post("contacts", use: addContact)
        protected.patch("contacts", ":contactUserID", use: updateContact)
        protected.delete("contacts", ":contactUserID", use: deleteContact)
        protected.get("contact-requests", use: contactRequests)
        protected.post("contact-requests", use: sendContactRequest)
        protected.post("contact-requests", ":requestID", "accept", use: acceptContactRequest)
        protected.post("contact-requests", ":requestID", "decline", use: declineContactRequest)
        protected.post("contact-requests", ":requestID", "cancel", use: cancelContactRequest)
    }

    func me(req: Request) async throws -> UserResponse {
        try req.auth.require(User.self).asResponse()
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
        return try ContactResponse(contact: contact)
    }

    func deleteContact(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let ownerUserID = try user.requireID()
        let contactUserID = try contactUserID(from: req)

        guard let contact = try await UserContact.query(on: req.db)
            .filter(\.$owner.$id == ownerUserID)
            .filter(\.$contact.$id == contactUserID)
            .first()
        else {
            throw Abort(.notFound, reason: "联系人不存在。")
        }

        try await contact.delete(on: req.db)
        if let reverseContact = try await UserContact.query(on: req.db)
            .filter(\.$owner.$id == contactUserID)
            .filter(\.$contact.$id == ownerUserID)
            .first()
        {
            try await reverseContact.delete(on: req.db)
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
        return try await friendRequestService.sendRequest(
            from: user,
            email: body.email,
            message: body.message,
            remark: body.remark,
            on: req.db
        )
    }

    func acceptContactRequest(req: Request) async throws -> ContactResponse {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(ContactRequestAcceptRequest.self)
        return try await friendRequestService.acceptRequest(
            id: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            remark: body.remark,
            on: req.db
        )
    }

    func declineContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        return try await friendRequestService.declineRequest(
            id: contactRequestID(from: req),
            addresseeUserID: try user.requireID(),
            on: req.db
        )
    }

    func cancelContactRequest(req: Request) async throws -> FriendRequestResponse {
        let user = try req.auth.require(User.self)
        return try await friendRequestService.cancelRequest(
            id: contactRequestID(from: req),
            requesterUserID: try user.requireID(),
            on: req.db
        )
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
}

struct ContactCreateRequest: Content {
    let email: String
    let remark: String?
}

struct ContactUpdateRequest: Content {
    let remark: String?
}

struct ContactResponse: Content, Equatable {
    let id: UUID
    let email: String
    let remark: String?
    let createdAt: Date?

    init(contact: UserContact) throws {
        self.id = try contact.contact.requireID()
        self.email = contact.contact.email
        self.remark = contact.remark
        self.createdAt = contact.createdAt
    }
}
