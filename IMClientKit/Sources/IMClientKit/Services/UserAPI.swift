import Foundation

public struct ContactCreateRequestBody: Encodable, Sendable {
    public let email: String
    public let remark: String?
}

public struct ContactUpdateRequestBody: Encodable, Sendable {
    public let remark: String?
}

public enum ContactRequestStatus: String, Codable, Sendable {
    case pending
    case accepted
    case declined
    case cancelled
}

public enum ContactRequestBox: String, Sendable {
    case incoming
    case outgoing
    case all
}

public struct ContactRequestCreateRequestBody: Codable, Sendable {
    public let email: String
    public let message: String?
    public let remark: String?
}

public struct ContactRequestAcceptRequestBody: Codable, Sendable {
    public let remark: String?
}

public struct ContactResponseBody: Codable, Identifiable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let email: String
    public let profileDisplayName: String?
    public let avatarPreset: UserAvatarPreset?
    public let remark: String?
    public let createdAt: Date?

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        remark: String?,
        createdAt: Date?
    ) {
        self.id = id
        self.email = email
        self.profileDisplayName = displayName
        self.avatarPreset = avatarPreset
        self.remark = remark
        self.createdAt = createdAt
    }

    public var displayName: String {
        let normalizedUserDisplayName = profileDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemark = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedRemark, !normalizedRemark.isEmpty else {
            guard let normalizedUserDisplayName, !normalizedUserDisplayName.isEmpty else {
                return email
            }
            return normalizedUserDisplayName
        }
        return normalizedRemark
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case profileDisplayName = "displayName"
        case avatarPreset
        case remark
        case createdAt
    }
}

public struct UserProfileUpdateRequestBody: Encodable, Sendable {
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?

    public init(displayName: String? = nil, avatarPreset: UserAvatarPreset? = nil) {
        self.displayName = displayName
        self.avatarPreset = avatarPreset
    }
}

public struct UserBlockCreateRequestBody: Codable, Sendable {
    public let reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct UserBlockResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let blockedUserID: UUID
    public let reason: String?
    public let createdAt: Date
}

public struct ReportCreateRequestBody: Codable, Sendable {
    public let targetType: String
    public let targetID: String
    public let conversationID: UUID?
    public let messageID: UUID?
    public let reason: String
    public let detail: String?

    public init(
        targetType: String,
        targetID: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        reason: String,
        detail: String? = nil
    ) {
        self.targetType = targetType
        self.targetID = targetID
        self.conversationID = conversationID
        self.messageID = messageID
        self.reason = reason
        self.detail = detail
    }
}

public struct ReportResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let targetType: String
    public let targetID: String
    public let reporterUserID: UUID?
    public let conversationID: UUID?
    public let messageID: UUID?
    public let reason: String
    public let detail: String?
    public let status: String
    public let handledNote: String?
    public let messageSnapshotJSON: String?
    public let createdAt: Date
}

public struct ReportPageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let items: [ReportResponseBody]
    public let nextCursor: String?
    public let hasMore: Bool
}

public struct ReportUpdateRequestBody: Codable, Sendable {
    public let status: String
    public let handledNote: String?

    public init(status: String, handledNote: String? = nil) {
        self.status = status
        self.handledNote = handledNote
    }
}

public struct PushDeviceTokenRegisterRequestBody: Codable, Sendable {
    public let platform: String
    public let token: String

    public init(platform: String = "ios", token: String) {
        self.platform = platform
        self.token = token
    }
}

public struct PushDeviceTokenResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: String
    public let platform: String
    public let token: String
    public let isActive: Bool
    public let updatedAt: Date
}

public struct ContactRequestResponseBody: Codable, Identifiable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let requester: AuthUser
    public let addressee: AuthUser
    public let status: ContactRequestStatus
    public let message: String?
    public let requesterRemark: String?
    public let addresseeRemark: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let respondedAt: Date?

    public init(
        id: UUID,
        requester: AuthUser,
        addressee: AuthUser,
        status: ContactRequestStatus,
        message: String?,
        requesterRemark: String?,
        addresseeRemark: String?,
        createdAt: Date?,
        updatedAt: Date?,
        respondedAt: Date?
    ) {
        self.id = id
        self.requester = requester
        self.addressee = addressee
        self.status = status
        self.message = message
        self.requesterRemark = requesterRemark
        self.addresseeRemark = addresseeRemark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.respondedAt = respondedAt
    }

    public func peerUser(for currentUserID: UUID?) -> AuthUser {
        guard let currentUserID else {
            return requester
        }

        if requester.id == currentUserID {
            return addressee
        }

        return requester
    }

    public func peerDisplayName(for currentUserID: UUID?) -> String {
        peerUser(for: currentUserID).preferredDisplayName
    }

    public func peerAvatarPreset(for currentUserID: UUID?) -> UserAvatarPreset? {
        peerUser(for: currentUserID).avatarPreset
    }
}

enum UserRequest {
    public struct Me: AuthorizedEndpoint {
        public typealias Response = AuthUser

        let baseRequestSpec = HTTPRequestSpec(path: "api/me")
    }

    public struct Contacts: AuthorizedEndpoint {
        public typealias Response = [ContactResponseBody]

        let baseRequestSpec = HTTPRequestSpec(path: "api/contacts")
    }

    public struct UpdateProfile: AuthorizedEndpoint {
        public typealias Response = AuthUser

        let payload: UserProfileUpdateRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/me/profile", method: .patch)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct AddContact: AuthorizedEndpoint {
        public typealias Response = ContactResponseBody

        let payload: ContactCreateRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/contacts", method: .post)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UpdateContact: AuthorizedEndpoint {
        public typealias Response = ContactResponseBody

        let contactUserID: UUID
        let payload: ContactUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/contacts/\(contactUserID.uuidString)", method: .patch)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct DeleteContact: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let contactUserID: UUID

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/contacts/\(contactUserID.uuidString)", method: .delete)
        }
    }

    public struct ContactRequests: AuthorizedEndpoint {
        public typealias Response = [ContactRequestResponseBody]

        let box: ContactRequestBox

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/contact-requests",
                queryItems: [URLQueryItem(name: "box", value: box.rawValue)]
            )
        }
    }

    public struct SendContactRequest: AuthorizedEndpoint {
        public typealias Response = ContactRequestResponseBody

        let payload: ContactRequestCreateRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/contact-requests", method: .post)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct AcceptContactRequest: AuthorizedEndpoint {
        public typealias Response = ContactResponseBody

        let requestID: UUID
        let payload: ContactRequestAcceptRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/contact-requests/\(requestID.uuidString)/accept", method: .post)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct DeclineContactRequest: AuthorizedEndpoint {
        public typealias Response = ContactRequestResponseBody

        let requestID: UUID

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/contact-requests/\(requestID.uuidString)/decline", method: .post)
        }
    }

    public struct CancelContactRequest: AuthorizedEndpoint {
        public typealias Response = ContactRequestResponseBody

        let requestID: UUID

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/contact-requests/\(requestID.uuidString)/cancel", method: .post)
        }
    }

    public struct Blocks: AuthorizedEndpoint {
        public typealias Response = [UserBlockResponseBody]

        let baseRequestSpec = HTTPRequestSpec(path: "api/blocks")
    }

    public struct BlockUser: AuthorizedEndpoint {
        public typealias Response = UserBlockResponseBody

        let userID: UUID
        let payload: UserBlockCreateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/users/\(userID.uuidString)/block", method: .post)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UnblockUser: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let userID: UUID

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/users/\(userID.uuidString)/block", method: .delete)
        }
    }

    public struct CreateReport: AuthorizedEndpoint {
        public typealias Response = ReportResponseBody

        let payload: ReportCreateRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/reports", method: .post)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct InternalReports: Endpoint {
        public typealias Response = ReportPageResponseBody

        let secret: String
        let status: String?
        let targetType: String?
        let cursor: String?
        let limit: Int?

        public var requestSpec: HTTPRequestSpec {
            .init(
                path: "internal/reports",
                headers: ["X-Internal-Secret": secret],
                queryItems: [
                    status.map { URLQueryItem(name: "status", value: $0) },
                    targetType.map { URLQueryItem(name: "targetType", value: $0) },
                    cursor.map { URLQueryItem(name: "cursor", value: $0) },
                    limit.map { URLQueryItem(name: "limit", value: String($0)) }
                ].compactMap { $0 }
            )
        }
    }

    public struct UpdateInternalReport: Endpoint {
        public typealias Response = ReportResponseBody

        let secret: String
        let reportID: UUID
        let payload: ReportUpdateRequestBody

        public var requestSpec: HTTPRequestSpec {
            .init(
                path: "internal/reports/\(reportID.uuidString)",
                method: .patch,
                headers: ["X-Internal-Secret": secret]
            )
        }

        public var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct RegisterPushDeviceToken: AuthorizedEndpoint {
        public typealias Response = PushDeviceTokenResponseBody

        let payload: PushDeviceTokenRegisterRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/push/device-tokens", method: .post)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct DeletePushDeviceToken: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let tokenID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/push/device-tokens/\(tokenID)", method: .delete)
        }
    }

    public static let me = Me()
    public static let contacts = Contacts()
    public static let blocks = Blocks()

    public static func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) -> UpdateProfile {
        UpdateProfile(
            payload: UserProfileUpdateRequestBody(
                displayName: displayName,
                avatarPreset: avatarPreset
            )
        )
    }

    public static func addContact(email: String, remark: String? = nil) -> AddContact {
        AddContact(payload: ContactCreateRequestBody(email: email, remark: remark))
    }

    public static func updateContact(contactUserID: UUID, remark: String?) -> UpdateContact {
        UpdateContact(
            contactUserID: contactUserID,
            payload: ContactUpdateRequestBody(remark: remark)
        )
    }

    public static func deleteContact(contactUserID: UUID) -> DeleteContact {
        DeleteContact(contactUserID: contactUserID)
    }

    public static func contactRequests(box: ContactRequestBox = .all) -> ContactRequests {
        ContactRequests(box: box)
    }

    public static func sendContactRequest(
        email: String,
        message: String? = nil,
        remark: String? = nil
    ) -> SendContactRequest {
        SendContactRequest(
            payload: ContactRequestCreateRequestBody(
                email: email,
                message: message,
                remark: remark
            )
        )
    }

    public static func acceptContactRequest(
        id requestID: UUID,
        remark: String? = nil
    ) -> AcceptContactRequest {
        AcceptContactRequest(
            requestID: requestID,
            payload: ContactRequestAcceptRequestBody(remark: remark)
        )
    }

    public static func declineContactRequest(id requestID: UUID) -> DeclineContactRequest {
        DeclineContactRequest(requestID: requestID)
    }

    public static func cancelContactRequest(id requestID: UUID) -> CancelContactRequest {
        CancelContactRequest(requestID: requestID)
    }

    public static func blockUser(userID: UUID, reason: String? = nil) -> BlockUser {
        BlockUser(userID: userID, payload: UserBlockCreateRequestBody(reason: reason))
    }

    public static func unblockUser(userID: UUID) -> UnblockUser {
        UnblockUser(userID: userID)
    }

    public static func createReport(
        targetType: String,
        targetID: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        reason: String,
        detail: String? = nil
    ) -> CreateReport {
        CreateReport(
            payload: ReportCreateRequestBody(
                targetType: targetType,
                targetID: targetID,
                conversationID: conversationID,
                messageID: messageID,
                reason: reason,
                detail: detail
            )
        )
    }

    public static func internalReports(
        secret: String,
        status: String? = nil,
        targetType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> InternalReports {
        InternalReports(secret: secret, status: status, targetType: targetType, cursor: cursor, limit: limit)
    }

    public static func updateInternalReport(
        secret: String,
        reportID: UUID,
        status: String,
        handledNote: String? = nil
    ) -> UpdateInternalReport {
        UpdateInternalReport(
            secret: secret,
            reportID: reportID,
            payload: ReportUpdateRequestBody(status: status, handledNote: handledNote)
        )
    }

    public static func registerPushDeviceToken(platform: String = "ios", token: String) -> RegisterPushDeviceToken {
        RegisterPushDeviceToken(payload: PushDeviceTokenRegisterRequestBody(platform: platform, token: token))
    }

    public static func deletePushDeviceToken(tokenID: String) -> DeletePushDeviceToken {
        DeletePushDeviceToken(tokenID: tokenID)
    }
}
