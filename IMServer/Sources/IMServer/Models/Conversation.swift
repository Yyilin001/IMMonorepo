import Fluent
import Vapor

enum IMConversationKind: String, Codable, Content, Sendable {
    case direct
    case group
}

enum IMDirectMessagingState: String, Codable, Content, Sendable {
    case active
    case frozenAfterUnfriend = "frozen_after_unfriend"
}

enum IMGroupLifecycleState: String, Codable, Content, Sendable {
    case active
    case frozen
    // Reserved for the separately designed, irreversible dissolution flow.
    case dissolved
}

enum IMConversationMemberRole: String, Codable, Content, Sendable {
    case owner
    case admin
    case member
}

final class Conversation: Model, Content, @unchecked Sendable {
    static let schema = "im_conversations"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "title")
    var title: String?

    @OptionalField(key: "notice")
    var notice: String?

    @OptionalField(key: "avatar_preset")
    var avatarPreset: String?

    @Field(key: "kind")
    var kind: String

    @Field(key: "direct_messaging_state")
    var directMessagingState: String

    @Field(key: "group_lifecycle_state")
    var groupLifecycleState: String

    @Field(key: "mute_all")
    var muteAll: Bool

    @Field(key: "updated_at")
    var updatedAt: Date

    @Field(key: "last_message_sequence")
    var lastMessageSequence: Int

    @OptionalField(key: "membership_revision")
    var membershipRevision: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$conversation)
    var members: [ConversationMember]

    @Children(for: \.$conversation)
    var messages: [ConversationMessage]

    init() { }

    init(
        id: UUID? = nil,
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        kind: IMConversationKind = .group,
        directMessagingState: IMDirectMessagingState = .active,
        groupLifecycleState: IMGroupLifecycleState = .active,
        muteAll: Bool = false,
        updatedAt: Date = Date(),
        lastMessageSequence: Int = 0,
        membershipRevision: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notice = notice
        self.avatarPreset = avatarPreset?.rawValue
        self.kind = kind.rawValue
        self.directMessagingState = directMessagingState.rawValue
        self.groupLifecycleState = groupLifecycleState.rawValue
        self.muteAll = muteAll
        self.updatedAt = updatedAt
        self.lastMessageSequence = lastMessageSequence
        self.membershipRevision = membershipRevision ?? updatedAt
    }

    var conversationKind: IMConversationKind {
        get { IMConversationKind(rawValue: kind) ?? .group }
        set { kind = newValue.rawValue }
    }

    var directMessagingStateEnum: IMDirectMessagingState {
        get { IMDirectMessagingState(rawValue: directMessagingState) ?? .active }
        set { directMessagingState = newValue.rawValue }
    }

    var groupLifecycleStateEnum: IMGroupLifecycleState {
        get { IMGroupLifecycleState(rawValue: groupLifecycleState) ?? .active }
        set { groupLifecycleState = newValue.rawValue }
    }

    var groupLifecycleStateForPresentation: String? {
        conversationKind == .group ? groupLifecycleStateEnum.rawValue : nil
    }

    var avatarPresetEnum: IMConversationAvatarPreset? {
        get { avatarPreset.flatMap(IMConversationAvatarPreset.init(rawValue:)) }
        set { avatarPreset = newValue?.rawValue }
    }

    /// Copies every persisted canonical field without invoking timestamp defaults.
    /// Physical shard migration uses this rather than domain constructors so the
    /// destination timeline remains byte-for-byte equivalent to the source.
    func migrationCopy() -> Conversation {
        let copy = Conversation()
        copy.id = id
        copy.title = title
        copy.notice = notice
        copy.avatarPreset = avatarPreset
        copy.kind = kind
        copy.directMessagingState = directMessagingState
        copy.groupLifecycleState = groupLifecycleState
        copy.muteAll = muteAll
        copy.updatedAt = updatedAt
        copy.lastMessageSequence = lastMessageSequence
        copy.membershipRevision = membershipRevision
        copy.createdAt = createdAt
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [
            id?.uuidString,
            title,
            notice,
            avatarPreset,
            kind,
            directMessagingState,
            groupLifecycleState,
            String(muteAll),
            String(updatedAt.timeIntervalSince1970),
            String(lastMessageSequence),
            membershipRevision.map { String($0.timeIntervalSince1970) },
            createdAt.map { String($0.timeIntervalSince1970) }
        ]
    }
}

final class ConversationMember: Model, Content, @unchecked Sendable {
    static let schema = "im_conversation_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "conversation_id")
    var conversation: Conversation

    @Parent(key: "user_id")
    var user: User

    @Field(key: "role")
    var role: String

    @Field(key: "last_read_sequence")
    var lastReadSequence: Int

    @Field(key: "visible_from_sequence")
    var visibleFromSequence: Int

    @OptionalField(key: "member_nickname")
    var memberNickname: String?

    // Per-member preferences are canonical conversation-shard state. Summary
    // rows mirror these fields for list/query performance.
    @Field(key: "is_pinned")
    var isPinned: Bool

    @OptionalField(key: "pinned_at")
    var pinnedAt: Date?

    @Field(key: "is_muted")
    var isMuted: Bool

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        userID: UUID,
        role: IMConversationMemberRole = .member,
        lastReadSequence: Int = 0,
        visibleFromSequence: Int = 0,
        memberNickname: String? = nil,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isMuted: Bool = false
    ) {
        self.id = id
        self.$conversation.id = conversationID
        self.$user.id = userID
        self.role = role.rawValue
        self.lastReadSequence = lastReadSequence
        self.visibleFromSequence = visibleFromSequence
        self.memberNickname = memberNickname
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isMuted = isMuted
    }

    var memberRoleEnum: IMConversationMemberRole {
        get { IMConversationMemberRole(rawValue: role) ?? .member }
        set { role = newValue.rawValue }
    }

    func migrationCopy() -> ConversationMember {
        let copy = ConversationMember()
        copy.id = id
        copy.$conversation.id = $conversation.id
        copy.$user.id = $user.id
        copy.role = role
        copy.lastReadSequence = lastReadSequence
        copy.visibleFromSequence = visibleFromSequence
        copy.memberNickname = memberNickname
        copy.isPinned = isPinned
        copy.pinnedAt = pinnedAt
        copy.isMuted = isMuted
        copy.joinedAt = joinedAt
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [
            id?.uuidString,
            $conversation.id.uuidString,
            $user.id.uuidString,
            role,
            String(lastReadSequence),
            String(visibleFromSequence),
            memberNickname,
            String(isPinned),
            pinnedAt.map { String($0.timeIntervalSince1970) },
            String(isMuted),
            joinedAt.map { String($0.timeIntervalSince1970) }
        ]
    }
}

final class ConversationMessage: Model, Content, @unchecked Sendable {
    static let schema = "im_messages"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "conversation_id")
    var conversation: Conversation

    @Parent(key: "sender_user_id")
    var sender: User

    @Field(key: "server_sequence")
    var serverSequence: Int

    @Field(key: "timeline_sequence")
    var timelineSequence: Int

    @Field(key: "kind")
    var kind: String

    @Field(key: "body_json")
    private var bodyJSON: String

    @OptionalField(key: "derived_state_json")
    private var derivedStateJSON: String?

    @OptionalField(key: "client_message_id")
    var clientMessageID: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        senderUserID: UUID,
        serverSequence: Int,
        timelineSequence: Int,
        clientMessageID: String? = nil,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState? = nil
    ) throws {
        guard serverSequence > 0, timelineSequence > 0 else {
            throw Abort(.internalServerError, reason: "server_sequence 和 timeline_sequence 必须是正数。")
        }
        self.id = id
        self.$conversation.id = conversationID
        self.$sender.id = senderUserID
        self.serverSequence = serverSequence
        self.timelineSequence = timelineSequence
        self.clientMessageID = clientMessageID
        self.kind = content.type.rawValue
        self.bodyJSON = try Self.encodeContent(content)
        self.derivedStateJSON = try Self.encodeDerivedState(derivedState ?? content.derivedState)
    }

    func decodedContent() throws -> IMMessageContent {
        guard let data = Data(base64Encoded: bodyJSON) else {
            throw Abort(.internalServerError, reason: "消息内容编码无效。")
        }

        return try IMRTMessageContent(serializedBytes: data).domainValue()
    }

    func replaceContent(_ content: IMMessageContent) throws {
        kind = content.type.rawValue
        bodyJSON = try Self.encodeContent(content)
    }

    func decodedDerivedState() throws -> IMMessageDerivedState {
        guard let derivedStateJSON, let data = Data(base64Encoded: derivedStateJSON) else {
            return try decodedContent().derivedState
        }

        return try IMRTMessageDerivedState(serializedBytes: data).domainValue()
    }

    func replaceDerivedState(_ derivedState: IMMessageDerivedState) throws {
        derivedStateJSON = try Self.encodeDerivedState(derivedState)
    }

    func decodedAggregate() throws -> IMMessageAggregate {
        let content = try decodedContent()
        let derivedState = try decodedDerivedState()
        return content.aggregate(derivedState: derivedState)
    }

    static func encodeContent(_ content: IMMessageContent) throws -> String {
        try content.protobuf.serializedData().base64EncodedString()
    }

    static func encodeDerivedState(_ derivedState: IMMessageDerivedState) throws -> String {
        try derivedState.protobuf.serializedData().base64EncodedString()
    }

    func migrationCopy() -> ConversationMessage {
        let copy = ConversationMessage()
        copy.id = id
        copy.$conversation.id = $conversation.id
        copy.$sender.id = $sender.id
        copy.serverSequence = serverSequence
        copy.timelineSequence = timelineSequence
        copy.kind = kind
        copy.bodyJSON = bodyJSON
        copy.derivedStateJSON = derivedStateJSON
        copy.clientMessageID = clientMessageID
        copy.createdAt = createdAt
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [
            id?.uuidString,
            $conversation.id.uuidString,
            $sender.id.uuidString,
            String(serverSequence),
            String(timelineSequence),
            kind,
            bodyJSON,
            derivedStateJSON,
            clientMessageID,
            createdAt.map { String($0.timeIntervalSince1970) }
        ]
    }
}
