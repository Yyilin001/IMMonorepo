import Vapor

struct IMMessageHistoryQuery: Content {
    let beforeSequence: UInt64?
    let limit: Int?
}

struct IMMessageSearchQuery: Content {
    let q: String
    let cursor: String?
    let limit: Int?
}

struct IMConversationPageQuery: Content {
    let cursor: String?
    let limit: Int?
    let kind: String?
}

struct IMConversationChangesQuery: Content {
    let afterToken: String
    let cursor: String?
    let limit: Int?
}

struct IMDomainEventChangesQuery: Content {
    let after: UInt64?
    let limit: Int?
}

struct IMTimelineSinceQuery: Content {
    let afterSequence: UInt64
    let limit: Int?
}

struct IMConversationMessageEditRequest: Content {
    let body: IMRichTextContent

    init(body: IMRichTextContent) {
        self.body = body
    }
}

struct IMConversationMessageReactionRequest: Content {
    let emoji: String
}

struct IMAIMessageStreamStartRequest: Content {
    let prompt: String
}

struct IMMessageStreamResponse: Content, Equatable {
    let message: IMMessageResponse
    let stream: IMTCPMessageStreamPayload
}

struct IMConversationCreateRequest: Content {
    let kind: String?
    let title: String?
    let memberEmails: [String]
}

struct IMConversationReadRequest: Content {
    let readSequence: UInt64
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
    let muteAll: Bool?

    init(
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool? = nil
    ) {
        self.title = title
        self.notice = notice
        self.avatarPreset = avatarPreset
        self.muteAll = muteAll
    }
}

struct IMMessageForwardRequest: Content {
    let messageIDs: [UUID]
    let targetConversationIDs: [UUID]
}

struct IMMessageDeleteRequest: Content {
    let messageIDs: [UUID]
}

struct IMFavoritePageQuery: Content {
    let conversationID: UUID?
    let cursor: String?
    let limit: Int?
}

struct IMFavoritePageResponse: Content, Equatable {
    let items: [IMMessageResponse]
    let nextCursor: String?
    let hasMore: Bool
}

struct IMConversationReceiptSummaryResponse: Content, Equatable {
    let conversationID: UUID
    let deliveredThroughSequence: UInt64
    let readThroughSequence: UInt64
    let readableMemberCount: Int
}

struct IMGroupInviteCreateRequest: Content {
    let expiresInSeconds: Int?
}

struct IMGroupInviteResponse: Content, Equatable {
    let token: String
    let conversationID: UUID
    let inviteURL: String
    let expiresAt: Date
    let useCount: Int
    let revokedAt: Date?

    init(token: String, conversationID: UUID, inviteURL: String, expiresAt: Date, useCount: Int, revokedAt: Date? = nil) {
        self.token = token
        self.conversationID = conversationID
        self.inviteURL = inviteURL
        self.expiresAt = expiresAt
        self.useCount = useCount
        self.revokedAt = revokedAt
    }
}

struct IMConversationMemberResponse: Content, Equatable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarPreset: UserAvatarPreset?
    let role: String
    let memberNickname: String?
    let displayTitle: String
}

struct IMConversationMemberPageQuery: Content {
    let cursor: String?
    let limit: Int?
    let q: String?
}

struct IMConversationMemberPageResponse: Content, Equatable {
    let items: [IMConversationMemberResponse]
    let nextCursor: String?
    let total: Int
    let limit: Int
}

struct IMConversationMemberSelfUpdateRequest: Content {
    let memberNickname: String?
}

struct IMConversationResponse: Content, Equatable {
    let id: UUID
    let title: String?
    let kind: String
    let directMessagingState: String?
    let directPeer: IMDirectPeerResponse?
    let notice: String?
    let avatarPreset: IMConversationAvatarPreset?
    let muteAll: Bool
    let memberCount: Int
    let memberUserIDs: [UUID]
    let lastMessage: IMMessagePreviewResponse?
    let lastReadSequence: UInt64
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
        muteAll: Bool = false,
        memberCount: Int? = nil,
        memberUserIDs: [UUID],
        lastMessage: IMMessagePreviewResponse?,
        lastReadSequence: UInt64 = 0,
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
        self.muteAll = muteAll
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
    let lastReadSequence: UInt64
    let unreadCount: Int
}

struct IMMessagePreviewResponse: Content, Equatable {
    let id: UUID
    let senderUserID: UUID
    let serverSequence: UInt64
    let timelineSequence: UInt64
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState
    let createdAt: Date?

    init(
        id: UUID,
        senderUserID: UUID,
        serverSequence: UInt64,
        timelineSequence: UInt64,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        createdAt: Date?
    ) {
        self.id = id
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.timelineSequence = timelineSequence
        self.content = content
        self.derivedState = derivedState
        self.createdAt = createdAt
    }
}

struct IMMessageResponse: Content, Equatable {
    let id: UUID
    let conversationID: UUID
    let senderUserID: UUID
    let clientMessageID: String?
    let serverSequence: UInt64
    let timelineSequence: UInt64
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState
    let createdAt: Date?

    init(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String? = nil,
        serverSequence: UInt64,
        timelineSequence: UInt64,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState(),
        createdAt: Date?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.serverSequence = serverSequence
        self.timelineSequence = timelineSequence
        self.content = content
        self.derivedState = derivedState
        self.createdAt = createdAt
    }
}

struct IMTimelineNoticeResponse: Content, Equatable {
    let id: UUID
    let conversationID: UUID
    let timelineSequence: UInt64
    let eventType: String
    let actorUserID: UUID?
    let targetUserIDs: [UUID]
    let noticeKind: String
    let params: [String: String]
    let fallbackText: String
    let createdAt: Date
}

enum IMTimelineItemKind: String, Content, Equatable {
    case message
    case notice
}

struct IMTimelineItemResponse: Content, Equatable {
    let type: IMTimelineItemKind
    let timelineSequence: UInt64
    let message: IMMessageResponse?
    let notice: IMTimelineNoticeResponse?
}

struct IMTimelinePageResponse: Content, Equatable {
    let items: [IMTimelineItemResponse]
    let hasMore: Bool
    let nextAfterSequence: UInt64?
}

struct IMConversationMessageSearchHitResponse: Content, Equatable {
    let messageID: UUID
    let senderUserID: UUID
    let serverSequence: UInt64
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState
    let snippet: String
    let createdAt: Date?
}

struct IMConversationMessageSearchPageResponse: Content, Equatable {
    let items: [IMConversationMessageSearchHitResponse]
    let nextCursor: String?
    let hasMore: Bool
}
