import Foundation

public struct IMConversationCreateRequestBody: Codable, Sendable {
    public let kind: String
    public let title: String?
    public let memberEmails: [String]
}

public struct IMConversationMemberUpdateRequestBody: Codable, Sendable {
    public let memberEmails: [String]
}

public struct IMConversationReadRequestBody: Codable, Sendable {
    public let readSequence: UInt64
}

public struct IMConversationMemberResponseBody: Codable, Equatable, Sendable, APIResponseBody, Identifiable {
    public let id: UUID
    public let email: String
}

public struct IMMessagePreviewResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let senderUserID: UUID
    public let serverSequence: Int
    public let kind: String
    public let body: [String: String]
    public let createdAt: Date?
}

public struct IMConversationSummaryResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let title: String?
    public let kind: String
    public let memberCount: Int
    public let memberUserIDs: [UUID]
    public let lastMessage: IMMessagePreviewResponseBody?
    public let lastReadSequence: Int
    public let unreadCount: Int
    public let createdAt: Date?
    public let updatedAt: Date

    init(
        id: UUID,
        title: String?,
        kind: String = IMConversationKind.group.rawValue,
        memberCount: Int? = nil,
        memberUserIDs: [UUID],
        lastMessage: IMMessagePreviewResponseBody?,
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

public struct IMConversationReadResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let conversationID: UUID
    public let lastReadSequence: Int
    public let unreadCount: Int
}

public struct IMConversationMessageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let conversationID: UUID
    public let senderUserID: UUID
    public let clientMessageID: String?
    public let serverSequence: Int
    public let kind: String
    public let body: [String: String]
    public let createdAt: Date?

    init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String? = nil,
        serverSequence: Int,
        kind: String,
        body: [String: String],
        createdAt: Date?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.serverSequence = serverSequence
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
    }
}

public struct IMConversationMessagesSinceResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let messages: [IMConversationMessageResponseBody]
    public let hasMore: Bool
    public let nextAfterSequence: Int?

    init(
        messages: [IMConversationMessageResponseBody],
        hasMore: Bool,
        nextAfterSequence: Int?
    ) {
        self.messages = messages
        self.hasMore = hasMore
        self.nextAfterSequence = nextAfterSequence
    }
}

enum IMRequest {
    public struct CreateConversation: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let payload: IMConversationCreateRequestBody

        let baseRequestSpec = HTTPRequestSpec(path: "api/im/conversations", method: .post)

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct Conversations: AuthorizedEndpoint {
        public typealias Response = [IMConversationSummaryResponseBody]

        let baseRequestSpec = HTTPRequestSpec(path: "api/im/conversations")
    }

    public struct Members: AuthorizedEndpoint {
        public typealias Response = [IMConversationMemberResponseBody]

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/members")
        }
    }

    public struct AddMembers: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let payload: IMConversationMemberUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/members",
                method: .post
            )
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct Messages: AuthorizedEndpoint {
        public typealias Response = [IMConversationMessageResponseBody]

        let conversationID: String
        let beforeSequence: UInt64?
        let limit: Int?

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/messages",
                queryItems: queryItems
            )
        }

        private var queryItems: [URLQueryItem] {
            var items: [URLQueryItem] = []

            if let beforeSequence {
                items.append(URLQueryItem(name: "beforeSequence", value: String(beforeSequence)))
            }

            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }

            return items
        }
    }

    public struct MessagesSince: AuthorizedEndpoint {
        public typealias Response = IMConversationMessagesSinceResponseBody

        let conversationID: String
        let afterSequence: UInt64
        let limit: Int?

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/messages/since",
                queryItems: queryItems
            )
        }

        private var queryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "afterSequence", value: String(afterSequence))]

            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }

            return items
        }
    }

    public struct MarkRead: AuthorizedEndpoint {
        public typealias Response = IMConversationReadResponseBody

        let conversationID: String
        let payload: IMConversationReadRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/read",
                method: .post
            )
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct LeaveConversation: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/leave",
                method: .post
            )
        }
    }

    public static let conversations = Conversations()

    public static func createConversation(
        kind: IMConversationKind,
        title: String?,
        memberEmails: [String]
    ) -> CreateConversation {
        CreateConversation(
            payload: IMConversationCreateRequestBody(
                kind: kind.rawValue,
                title: title,
                memberEmails: memberEmails
            )
        )
    }

    public static func members(conversationID: String) -> Members {
        Members(conversationID: conversationID)
    }

    public static func addMembers(
        conversationID: String,
        memberEmails: [String]
    ) -> AddMembers {
        AddMembers(
            conversationID: conversationID,
            payload: IMConversationMemberUpdateRequestBody(memberEmails: memberEmails)
        )
    }

    public static func messages(
        conversationID: String,
        beforeSequence: UInt64? = nil,
        limit: Int? = nil
    ) -> Messages {
        Messages(
            conversationID: conversationID,
            beforeSequence: beforeSequence,
            limit: limit
        )
    }

    public static func messagesSince(
        conversationID: String,
        afterSequence: UInt64,
        limit: Int? = nil
    ) -> MessagesSince {
        MessagesSince(
            conversationID: conversationID,
            afterSequence: afterSequence,
            limit: limit
        )
    }

    public static func markRead(
        conversationID: String,
        readSequence: UInt64
    ) -> MarkRead {
        MarkRead(
            conversationID: conversationID,
            payload: IMConversationReadRequestBody(readSequence: readSequence)
        )
    }

    public static func leaveConversation(conversationID: String) -> LeaveConversation {
        LeaveConversation(conversationID: conversationID)
    }
}
