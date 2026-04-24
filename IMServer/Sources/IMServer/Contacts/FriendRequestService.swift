import Fluent
import Vapor

struct FriendRequestService {
    func listRequests(
        for userID: UUID,
        box: ContactRequestBox,
        on database: any Database
    ) async throws -> [FriendRequestResponse] {
        let query = FriendRequest.query(on: database)
            .with(\.$requester)
            .with(\.$addressee)

        switch box {
        case .incoming:
            query.filter(\.$addressee.$id == userID)
        case .outgoing:
            query.filter(\.$requester.$id == userID)
        case .all:
            query.group(.or) { group in
                group.filter(\.$requester.$id == userID)
                group.filter(\.$addressee.$id == userID)
            }
        }

        let requests = try await query
            .sort(\.$createdAt, .descending)
            .all()

        return try requests.map { try FriendRequestResponse(request: $0) }
    }

    func sendRequest(
        from requester: User,
        email: String,
        message: String?,
        remark: String?,
        on database: any Database
    ) async throws -> FriendRequestResponse {
        let requesterUserID = try requester.requireID()
        let normalizedEmail = User.normalize(email)

        guard !normalizedEmail.isEmpty else {
            throw Abort(.badRequest, reason: "好友邮箱不能为空。")
        }

        guard normalizedEmail != requester.email else {
            throw Abort(.badRequest, reason: "不能向自己发送好友申请。")
        }

        guard let addressee = try await User.query(on: database)
            .filter(\.$email == normalizedEmail)
            .first()
        else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        let addresseeUserID = try addressee.requireID()

        if try await areFriends(requesterUserID, addresseeUserID, on: database) {
            throw Abort(.badRequest, reason: "你们已经是好友。")
        }

        if try await hasPendingRequestBetween(requesterUserID, addresseeUserID, on: database) {
            throw Abort(.badRequest, reason: "已存在待处理的好友申请。")
        }

        let request = FriendRequest(
            requesterUserID: requesterUserID,
            addresseeUserID: addresseeUserID,
            message: normalizedOptionalText(message, maxLength: 120),
            requesterRemark: normalizedOptionalText(remark, maxLength: 64)
        )
        try await request.create(on: database)
        request.$requester.value = requester
        request.$addressee.value = addressee

        return try FriendRequestResponse(request: request)
    }

    func acceptRequest(
        id requestID: UUID,
        addresseeUserID: UUID,
        remark: String?,
        on database: any Database
    ) async throws -> FriendRequestAcceptanceResult {
        try await database.transaction { transaction in
            let request = try await requirePendingRequest(
                id: requestID,
                requiredUserID: addresseeUserID,
                role: .addressee,
                on: transaction
            )
            let requesterUserID = request.$requester.id
            let addresseeRemark = normalizedOptionalText(remark, maxLength: 64)

            request.status = FriendRequestStatus.accepted.rawValue
            request.addresseeRemark = addresseeRemark
            request.respondedAt = Date()
            try await request.update(on: transaction)

            let requesterContact = try await ensureContact(
                ownerUserID: requesterUserID,
                contactUserID: addresseeUserID,
                remark: request.requesterRemark,
                on: transaction
            )
            let acceptedContact = try await ensureContact(
                ownerUserID: addresseeUserID,
                contactUserID: requesterUserID,
                remark: addresseeRemark,
                on: transaction
            )
            let affectedDirectConversationIDs = try await IMDirectConversationStateService().updateExistingDirectConversations(
                between: requesterUserID,
                and: addresseeUserID,
                to: .active,
                on: transaction
            )
            try await request.$requester.load(on: transaction)
            try await request.$addressee.load(on: transaction)

            return try FriendRequestAcceptanceResult(
                request: FriendRequestResponse(request: request),
                requesterContact: ContactResponse(contact: requesterContact),
                addresseeContact: ContactResponse(contact: acceptedContact),
                affectedDirectConversationIDs: affectedDirectConversationIDs
            )
        }
    }

    func declineRequest(
        id requestID: UUID,
        addresseeUserID: UUID,
        on database: any Database
    ) async throws -> FriendRequestResponse {
        let request = try await requirePendingRequest(
            id: requestID,
            requiredUserID: addresseeUserID,
            role: .addressee,
            on: database
        )
        request.status = FriendRequestStatus.declined.rawValue
        request.respondedAt = Date()
        try await request.update(on: database)
        try await request.$requester.load(on: database)
        try await request.$addressee.load(on: database)
        return try FriendRequestResponse(request: request)
    }

    func cancelRequest(
        id requestID: UUID,
        requesterUserID: UUID,
        on database: any Database
    ) async throws -> FriendRequestResponse {
        let request = try await requirePendingRequest(
            id: requestID,
            requiredUserID: requesterUserID,
            role: .requester,
            on: database
        )
        request.status = FriendRequestStatus.cancelled.rawValue
        request.respondedAt = Date()
        try await request.update(on: database)
        try await request.$requester.load(on: database)
        try await request.$addressee.load(on: database)
        return try FriendRequestResponse(request: request)
    }

    private enum RequestRole {
        case requester
        case addressee
    }

    private func requirePendingRequest(
        id requestID: UUID,
        requiredUserID: UUID,
        role: RequestRole,
        on database: any Database
    ) async throws -> FriendRequest {
        guard let request = try await FriendRequest.query(on: database)
            .filter(\.$id == requestID)
            .first()
        else {
            throw Abort(.notFound, reason: "好友申请不存在。")
        }

        switch role {
        case .requester:
            guard request.$requester.id == requiredUserID else {
                throw Abort(.notFound, reason: "好友申请不存在。")
            }
        case .addressee:
            guard request.$addressee.id == requiredUserID else {
                throw Abort(.notFound, reason: "好友申请不存在。")
            }
        }

        guard request.statusEnum == .pending else {
            throw Abort(.badRequest, reason: "好友申请已处理。")
        }

        return request
    }

    private func areFriends(_ lhs: UUID, _ rhs: UUID, on database: any Database) async throws -> Bool {
        try await UserContact.query(on: database)
            .filter(\.$owner.$id == lhs)
            .filter(\.$contact.$id == rhs)
            .first() != nil
    }

    private func hasPendingRequestBetween(_ lhs: UUID, _ rhs: UUID, on database: any Database) async throws -> Bool {
        try await FriendRequest.query(on: database)
            .filter(\.$status == FriendRequestStatus.pending.rawValue)
            .group(.or) { group in
                group.group(.and) { pair in
                    pair.filter(\.$requester.$id == lhs)
                    pair.filter(\.$addressee.$id == rhs)
                }
                group.group(.and) { pair in
                    pair.filter(\.$requester.$id == rhs)
                    pair.filter(\.$addressee.$id == lhs)
                }
            }
            .first() != nil
    }

    private func ensureContact(
        ownerUserID: UUID,
        contactUserID: UUID,
        remark: String?,
        on database: any Database
    ) async throws -> UserContact {
        if let existing = try await UserContact.query(on: database)
            .filter(\.$owner.$id == ownerUserID)
            .filter(\.$contact.$id == contactUserID)
            .with(\.$contact)
            .first()
        {
            existing.remark = remark
            try await existing.update(on: database)
            return existing
        }

        guard let contactUser = try await User.find(contactUserID, on: database) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }

        let contact = UserContact(
            ownerUserID: ownerUserID,
            contactUserID: contactUserID,
            remark: remark
        )
        try await contact.create(on: database)
        contact.$contact.value = contactUser
        return contact
    }

    private func normalizedOptionalText(_ value: String?, maxLength: Int) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(maxLength))
    }
}

struct FriendRequestAcceptanceResult {
    let request: FriendRequestResponse
    let requesterContact: ContactResponse
    let addresseeContact: ContactResponse
    let affectedDirectConversationIDs: [UUID]
}

enum ContactRequestBox: String, Content {
    case incoming
    case outgoing
    case all
}

struct ContactRequestCreateRequest: Content {
    let email: String
    let message: String?
    let remark: String?
}

struct ContactRequestAcceptRequest: Content {
    let remark: String?
}

struct FriendRequestResponse: Content, Equatable, Sendable {
    let id: UUID
    let requester: UserResponse
    let addressee: UserResponse
    let status: String
    let message: String?
    let requesterRemark: String?
    let addresseeRemark: String?
    let createdAt: Date?
    let updatedAt: Date?
    let respondedAt: Date?

    init(request: FriendRequest) throws {
        self.id = try request.requireID()
        self.requester = try request.requester.asResponse()
        self.addressee = try request.addressee.asResponse()
        self.status = request.status
        self.message = request.message
        self.requesterRemark = request.requesterRemark
        self.addresseeRemark = request.addresseeRemark
        self.createdAt = request.createdAt
        self.updatedAt = request.updatedAt
        self.respondedAt = request.respondedAt
    }
}
