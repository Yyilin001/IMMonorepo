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
    public let remark: String?
    public let createdAt: Date?

    public init(id: UUID, email: String, remark: String?, createdAt: Date?) {
        self.id = id
        self.email = email
        self.remark = remark
        self.createdAt = createdAt
    }

    public var displayName: String {
        let normalizedRemark = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedRemark, !normalizedRemark.isEmpty else {
            return email
        }
        return normalizedRemark
    }
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

    public func peerDisplayName(for currentUserID: UUID?) -> String {
        guard let currentUserID else {
            return requester.email
        }

        if requester.id == currentUserID {
            return addressee.email
        }

        return requester.email
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

    public static let me = Me()
    public static let contacts = Contacts()

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
}
