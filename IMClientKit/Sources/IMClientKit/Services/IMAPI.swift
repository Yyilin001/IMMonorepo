import Foundation

public enum IMDirectMessagingState: String, Codable, Equatable, Sendable {
    case active
    case frozenAfterUnfriend = "frozen_after_unfriend"
}

public struct IMDirectPeerResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?

    public init(
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

public struct IMConversationCreateRequestBody: Codable, Sendable {
    public let kind: String
    public let title: String?
    public let memberEmails: [String]
}

public struct IMConversationMemberUpdateRequestBody: Codable, Sendable {
    public let memberEmails: [String]
}

public struct IMConversationMemberRoleUpdateRequestBody: Codable, Sendable {
    public let role: IMConversationMemberRole
}

public struct IMConversationTitleUpdateRequestBody: Codable, Sendable {
    public let title: String
}

public struct IMConversationPreferencesUpdateRequestBody: Codable, Sendable {
    public let isPinned: Bool?
    public let isMuted: Bool?

    public init(isPinned: Bool? = nil, isMuted: Bool? = nil) {
        self.isPinned = isPinned
        self.isMuted = isMuted
    }
}

public struct IMConversationMetadataUpdateRequestBody: Codable, Sendable {
    public let title: String?
    public let notice: String?
    public let avatarPreset: IMConversationAvatarPreset?
    public let muteAll: Bool?

    public init(
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool? = nil
    ) {
        self.title = title
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.muteAll = muteAll
    }
}

public struct IMConversationMemberSelfUpdateRequestBody: Codable, Sendable {
    public let memberNickname: String?
}

public struct IMConversationReadRequestBody: Codable, Sendable {
    public let readSequence: UInt64
}

public struct IMMessageForwardRequestBody: Codable, Sendable {
    public let messageIDs: [UUID]
    public let targetConversationIDs: [UUID]

    public init(messageIDs: [UUID], targetConversationIDs: [UUID]) {
        self.messageIDs = messageIDs
        self.targetConversationIDs = targetConversationIDs
    }
}

public struct IMMessageDeleteRequestBody: Codable, Sendable {
    public let messageIDs: [UUID]

    public init(messageIDs: [UUID]) {
        self.messageIDs = messageIDs
    }
}

public struct IMFavoritePageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let items: [IMConversationMessageResponseBody]
    public let nextCursor: String?
    public let hasMore: Bool
}

public struct IMConversationReceiptSummaryResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let conversationID: UUID
    public let deliveredThroughSequence: Int
    public let readThroughSequence: Int
    public let readableMemberCount: Int
}

public struct IMGroupInviteCreateRequestBody: Codable, Sendable {
    public let expiresInSeconds: Int?

    public init(expiresInSeconds: Int? = nil) {
        self.expiresInSeconds = expiresInSeconds
    }
}

public struct IMGroupInviteResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let token: String
    public let conversationID: UUID
    public let inviteURL: String
    public let expiresAt: Date
    public let revokedAt: Date?
    public let useCount: Int
}

public struct IMConversationMessageEditRequestBody: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct IMConversationMessageReactionRequestBody: Codable, Sendable {
    public let emoji: String

    public init(emoji: String) {
        self.emoji = emoji
    }
}

public struct IMConversationMessageRecallResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let conversationID: UUID
    public let senderUserID: UUID
    public let clientMessageID: String?
    public let serverSequence: Int
    public let content: IMMessageContent
    public let derivedState: IMMessageDerivedState
    public let createdAt: Date?

    public init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String? = nil,
        serverSequence: Int,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        createdAt: Date?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.serverSequence = serverSequence
        self.content = content
        self.derivedState = derivedState
        self.createdAt = createdAt
    }
}

public struct IMConversationMemberResponseBody: Codable, Equatable, Sendable, APIResponseBody, Identifiable {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?
    public let role: IMConversationMemberRole
    public let memberNickname: String?
    public let displayTitle: String

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        role: IMConversationMemberRole = .member,
        memberNickname: String? = nil,
        displayTitle: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
        self.role = role
        self.memberNickname = memberNickname
        self.displayTitle = displayTitle ?? memberNickname ?? displayName ?? email
    }
}

public struct IMConversationMemberPageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let items: [IMConversationMemberResponseBody]
    public let nextCursor: String?
    public let total: Int
    public let limit: Int
}

public struct IMMessagePreviewResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let senderUserID: UUID
    public let serverSequence: Int
    public let content: IMMessageContent
    public let derivedState: IMMessageDerivedState
    public let createdAt: Date?

    public init(
        id: UUID,
        senderUserID: UUID,
        serverSequence: Int,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        createdAt: Date?
    ) {
        self.id = id
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.content = content
        self.derivedState = derivedState
        self.createdAt = createdAt
    }

    public var textValue: String? {
        content.presentation(derivedState: derivedState).textValue
    }

    public var previewText: String {
        content.presentation(derivedState: derivedState).previewText
    }
}

public struct IMConversationSummaryResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let title: String?
    public let kind: String
    public let directMessagingState: String?
    public let directPeer: IMDirectPeerResponseBody?
    public let memberCount: Int
    public let memberUserIDs: [UUID]
    public let notice: String?
    public let avatarPreset: IMConversationAvatarPreset?
    public let muteAll: Bool
    public let lastMessage: IMMessagePreviewResponseBody?
    public let lastReadSequence: Int
    public let unreadCount: Int
    public let isPinned: Bool
    public let pinnedAt: Date?
    public let isMuted: Bool
    public let createdAt: Date?
    public let updatedAt: Date

    init(
        id: UUID,
        title: String?,
        kind: String = IMConversationKind.group.rawValue,
        directMessagingState: String? = nil,
        directPeer: IMDirectPeerResponseBody? = nil,
        memberCount: Int? = nil,
        memberUserIDs: [UUID],
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool = false,
        lastMessage: IMMessagePreviewResponseBody?,
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
        self.memberCount = memberCount ?? memberUserIDs.count
        self.memberUserIDs = memberUserIDs
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.muteAll = muteAll
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

public struct IMConversationSummaryPageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let items: [IMConversationSummaryResponseBody]
    public let nextCursor: String?
    public let hasMore: Bool
    public let snapshotToken: String
}

public struct IMConversationSummaryChangesResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let upserts: [IMConversationSummaryResponseBody]
    public let removedConversationIDs: [UUID]
    public let nextCursor: String?
    public let hasMore: Bool
    public let targetToken: String
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
    public let content: IMMessageContent
    public let derivedState: IMMessageDerivedState
    public let createdAt: Date?

    public var textValue: String? {
        content.presentation(derivedState: derivedState).textValue
    }

    public var previewText: String {
        content.presentation(derivedState: derivedState).previewText
    }

    init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String? = nil,
        serverSequence: Int,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        createdAt: Date?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.serverSequence = serverSequence
        self.content = content
        self.derivedState = derivedState
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

public struct IMConversationMessageSearchHitResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let messageID: UUID
    public let senderUserID: UUID
    public let serverSequence: Int
    public let content: IMMessageContent
    public let derivedState: IMMessageDerivedState
    public let snippet: String
    public let createdAt: Date?

    public var previewText: String {
        content.presentation(derivedState: derivedState).previewText
    }

    public init(
        messageID: UUID,
        senderUserID: UUID,
        serverSequence: Int,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        snippet: String,
        createdAt: Date?
    ) {
        self.messageID = messageID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.content = content
        self.derivedState = derivedState
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

public struct IMConversationMessageSearchPageResponseBody: Codable, Equatable, Sendable, APIResponseBody {
    public let items: [IMConversationMessageSearchHitResponseBody]
    public let nextCursor: String?
    public let hasMore: Bool
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
        public typealias Response = IMConversationSummaryPageResponseBody

        let cursor: String?
        let limit: Int?
        let kind: IMConversationKind?

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations",
                queryItems: queryItems
            )
        }

        private var queryItems: [URLQueryItem] {
            var items: [URLQueryItem] = []

            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }

            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }

            if let kind {
                items.append(URLQueryItem(name: "kind", value: kind.rawValue))
            }

            return items
        }
    }

    public struct ConversationChanges: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryChangesResponseBody

        let afterToken: String
        let cursor: String?
        let limit: Int?

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/changes",
                queryItems: queryItems
            )
        }

        private var queryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "afterToken", value: afterToken)]

            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }

            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }

            return items
        }
    }

    public struct Members: AuthorizedEndpoint {
        public typealias Response = IMConversationMemberPageResponseBody

        let conversationID: String
        let cursor: String?
        let limit: Int?
        let query: String?

        var baseRequestSpec: HTTPRequestSpec {
            var items: [URLQueryItem] = []
            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }
            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }
            if let query {
                items.append(URLQueryItem(name: "q", value: query))
            }
            return .init(path: "api/im/conversations/\(conversationID)/members", queryItems: items)
        }
    }

    public struct UpdateMyMemberProfile: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody
        let conversationID: String
        let payload: IMConversationMemberSelfUpdateRequestBody
        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/members/me", method: .patch)
        }
        var requestContentType: String? { "application/json" }
        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
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

    public struct RemoveMember: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let memberUserID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/members/\(memberUserID)/remove",
                method: .post
            )
        }
    }

    public struct UpdateMemberRole: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let memberUserID: String
        let payload: IMConversationMemberRoleUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/members/\(memberUserID)/role",
                method: .post
            )
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UpdateTitle: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let payload: IMConversationTitleUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/title",
                method: .post
            )
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UpdatePreferences: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let payload: IMConversationPreferencesUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/preferences",
                method: .patch
            )
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct UpdateMetadata: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let conversationID: String
        let payload: IMConversationMetadataUpdateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/metadata",
                method: .patch
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

    public struct ForwardMessages: AuthorizedEndpoint {
        public typealias Response = [IMConversationMessageResponseBody]

        let conversationID: String
        let payload: IMMessageForwardRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/messages/forward", method: .post)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct DeleteMessagesForSelf: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String
        let payload: IMMessageDeleteRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/messages/delete", method: .post)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct FavoriteMessage: AuthorizedEndpoint {
        public typealias Response = IMConversationMessageResponseBody

        let conversationID: String
        let messageID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/messages/\(messageID)/favorite", method: .post)
        }
    }

    public struct UnfavoriteMessage: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String
        let messageID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/messages/\(messageID)/favorite", method: .delete)
        }
    }

    public struct Favorites: AuthorizedEndpoint {
        public typealias Response = IMFavoritePageResponseBody

        let conversationID: UUID?
        let cursor: String?
        let limit: Int?

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/favorites", queryItems: queryItems)
        }

        private var queryItems: [URLQueryItem] {
            var items: [URLQueryItem] = []
            if let conversationID {
                items.append(URLQueryItem(name: "conversationID", value: conversationID.uuidString))
            }
            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }
            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }
            return items
        }
    }

    public struct ClearConversationForSelf: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/clear", method: .post)
        }
    }

    public struct DeleteConversationForSelf: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)", method: .delete)
        }
    }

    public struct ReceiptSummary: AuthorizedEndpoint {
        public typealias Response = IMConversationReceiptSummaryResponseBody

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/receipts/summary")
        }
    }

    public struct CreateInvite: AuthorizedEndpoint {
        public typealias Response = IMGroupInviteResponseBody

        let conversationID: String
        let payload: IMGroupInviteCreateRequestBody

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/invites", method: .post)
        }

        var requestContentType: String? { "application/json" }

        public func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try encoder.encode(payload)
        }
    }

    public struct ListInvites: AuthorizedEndpoint {
        public typealias Response = [IMGroupInviteResponseBody]

        let conversationID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/invites")
        }
    }

    public struct RevokeInvite: AuthorizedEndpoint {
        public typealias Response = EmptyResponse

        let conversationID: String
        let token: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/conversations/\(conversationID)/invites/\(token)", method: .delete)
        }
    }

    public struct JoinInvite: AuthorizedEndpoint {
        public typealias Response = IMConversationSummaryResponseBody

        let token: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(path: "api/im/invites/\(token)/join", method: .post)
        }
    }

    public struct SearchMessages: AuthorizedEndpoint {
        public typealias Response = IMConversationMessageSearchPageResponseBody

        let conversationID: String
        let query: String
        let cursor: String?
        let limit: Int?

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/search",
                queryItems: queryItems
            )
        }

        private var queryItems: [URLQueryItem] {
            var items = [URLQueryItem(name: "q", value: query)]
            if let cursor {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }
            if let limit {
                items.append(URLQueryItem(name: "limit", value: String(limit)))
            }
            return items
        }
    }

    public struct RecallMessage: AuthorizedEndpoint {
        public typealias Response = IMConversationMessageRecallResponseBody

        let conversationID: String
        let messageID: String

        var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/messages/\(messageID)/recall",
                method: .post
            )
        }
    }

    public struct EditMessage: AuthorizedEndpoint {
        public typealias RequestBody = IMConversationMessageEditRequestBody
        public typealias Response = IMConversationMessageResponseBody

        let conversationID: String
        let messageID: String
        let payload: IMConversationMessageEditRequestBody

        public var body: IMConversationMessageEditRequestBody? { payload }

        public var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/messages/\(messageID)/edit",
                method: .post
            )
        }
    }

    public struct ToggleMessageReaction: AuthorizedEndpoint {
        public typealias RequestBody = IMConversationMessageReactionRequestBody
        public typealias Response = IMConversationMessageResponseBody

        let conversationID: String
        let messageID: String
        let payload: IMConversationMessageReactionRequestBody

        public var body: IMConversationMessageReactionRequestBody? { payload }

        public var baseRequestSpec: HTTPRequestSpec {
            .init(
                path: "api/im/conversations/\(conversationID)/messages/\(messageID)/reactions",
                method: .post
            )
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

    public static func conversations(
        cursor: String? = nil,
        limit: Int? = nil,
        kind: IMConversationKind? = nil
    ) -> Conversations {
        Conversations(cursor: cursor, limit: limit, kind: kind)
    }

    public static func conversationChanges(
        afterToken: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> ConversationChanges {
        ConversationChanges(afterToken: afterToken, cursor: cursor, limit: limit)
    }

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

    public static func members(
        conversationID: String,
        cursor: String? = nil,
        limit: Int? = nil,
        query: String? = nil
    ) -> Members {
        Members(conversationID: conversationID, cursor: cursor, limit: limit, query: query)
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

    public static func removeMember(
        conversationID: String,
        memberUserID: String
    ) -> RemoveMember {
        RemoveMember(conversationID: conversationID, memberUserID: memberUserID)
    }

    public static func updateMemberRole(
        conversationID: String,
        memberUserID: String,
        role: IMConversationMemberRole
    ) -> UpdateMemberRole {
        UpdateMemberRole(
            conversationID: conversationID,
            memberUserID: memberUserID,
            payload: IMConversationMemberRoleUpdateRequestBody(role: role)
        )
    }

    public static func updateTitle(
        conversationID: String,
        title: String
    ) -> UpdateTitle {
        UpdateTitle(
            conversationID: conversationID,
            payload: IMConversationTitleUpdateRequestBody(title: title)
        )
    }

    public static func updatePreferences(
        conversationID: String,
        isPinned: Bool? = nil,
        isMuted: Bool? = nil
    ) -> UpdatePreferences {
        UpdatePreferences(
            conversationID: conversationID,
            payload: IMConversationPreferencesUpdateRequestBody(
                isPinned: isPinned,
                isMuted: isMuted
            )
        )
    }

    public static func updateMetadata(
        conversationID: String,
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool? = nil
    ) -> UpdateMetadata {
        UpdateMetadata(
            conversationID: conversationID,
            payload: IMConversationMetadataUpdateRequestBody(
                title: title,
                notice: notice,
                avatarPreset: avatarPreset,
                muteAll: muteAll
            )
        )
    }

    public static func updateMyMemberProfile(
        conversationID: String,
        memberNickname: String?
    ) -> UpdateMyMemberProfile {
        UpdateMyMemberProfile(
            conversationID: conversationID,
            payload: IMConversationMemberSelfUpdateRequestBody(memberNickname: memberNickname)
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

    public static func forwardMessages(
        conversationID: String,
        messageIDs: [UUID],
        targetConversationIDs: [UUID]
    ) -> ForwardMessages {
        ForwardMessages(
            conversationID: conversationID,
            payload: IMMessageForwardRequestBody(
                messageIDs: messageIDs,
                targetConversationIDs: targetConversationIDs
            )
        )
    }

    public static func deleteMessagesForSelf(
        conversationID: String,
        messageIDs: [UUID]
    ) -> DeleteMessagesForSelf {
        DeleteMessagesForSelf(
            conversationID: conversationID,
            payload: IMMessageDeleteRequestBody(messageIDs: messageIDs)
        )
    }

    public static func favoriteMessage(conversationID: String, messageID: String) -> FavoriteMessage {
        FavoriteMessage(conversationID: conversationID, messageID: messageID)
    }

    public static func unfavoriteMessage(conversationID: String, messageID: String) -> UnfavoriteMessage {
        UnfavoriteMessage(conversationID: conversationID, messageID: messageID)
    }

    public static func favorites(
        conversationID: UUID? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> Favorites {
        Favorites(conversationID: conversationID, cursor: cursor, limit: limit)
    }

    public static func clearConversationForSelf(conversationID: String) -> ClearConversationForSelf {
        ClearConversationForSelf(conversationID: conversationID)
    }

    public static func deleteConversationForSelf(conversationID: String) -> DeleteConversationForSelf {
        DeleteConversationForSelf(conversationID: conversationID)
    }

    public static func receiptSummary(conversationID: String) -> ReceiptSummary {
        ReceiptSummary(conversationID: conversationID)
    }

    public static func createInvite(
        conversationID: String,
        expiresInSeconds: Int? = nil
    ) -> CreateInvite {
        CreateInvite(
            conversationID: conversationID,
            payload: IMGroupInviteCreateRequestBody(expiresInSeconds: expiresInSeconds)
        )
    }

    public static func listInvites(conversationID: String) -> ListInvites {
        ListInvites(conversationID: conversationID)
    }

    public static func revokeInvite(conversationID: String, token: String) -> RevokeInvite {
        RevokeInvite(conversationID: conversationID, token: token)
    }

    public static func joinInvite(token: String) -> JoinInvite {
        JoinInvite(token: token)
    }

    public static func searchMessages(
        conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) -> SearchMessages {
        SearchMessages(
            conversationID: conversationID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    public static func leaveConversation(conversationID: String) -> LeaveConversation {
        LeaveConversation(conversationID: conversationID)
    }

    public static func recallMessage(
        conversationID: String,
        messageID: String
    ) -> RecallMessage {
        RecallMessage(conversationID: conversationID, messageID: messageID)
    }

    public static func editMessage(
        conversationID: String,
        messageID: String,
        text: String
    ) -> EditMessage {
        EditMessage(
            conversationID: conversationID,
            messageID: messageID,
            payload: IMConversationMessageEditRequestBody(text: text)
        )
    }

    public static func toggleMessageReaction(
        conversationID: String,
        messageID: String,
        emoji: String
    ) -> ToggleMessageReaction {
        ToggleMessageReaction(
            conversationID: conversationID,
            messageID: messageID,
            payload: IMConversationMessageReactionRequestBody(emoji: emoji)
        )
    }
}
