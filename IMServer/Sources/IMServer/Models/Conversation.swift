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

    var avatarPresetEnum: IMConversationAvatarPreset? {
        get { avatarPreset.flatMap(IMConversationAvatarPreset.init(rawValue:)) }
        set { avatarPreset = newValue?.rawValue }
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
        memberNickname: String? = nil
    ) {
        self.id = id
        self.$conversation.id = conversationID
        self.$user.id = userID
        self.role = role.rawValue
        self.lastReadSequence = lastReadSequence
        self.visibleFromSequence = visibleFromSequence
        self.memberNickname = memberNickname
    }

    var memberRoleEnum: IMConversationMemberRole {
        get { IMConversationMemberRole(rawValue: role) ?? .member }
        set { role = newValue.rawValue }
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
        clientMessageID: String? = nil,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState? = nil
    ) throws {
        self.id = id
        self.$conversation.id = conversationID
        self.$sender.id = senderUserID
        self.serverSequence = serverSequence
        self.clientMessageID = clientMessageID
        self.kind = content.type.rawValue
        self.bodyJSON = try Self.encodeContent(content)
        self.derivedStateJSON = try Self.encodeDerivedState(derivedState ?? content.derivedState)
    }

    func decodedContent() throws -> IMMessageContent {
        guard let data = bodyJSON.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "消息内容编码无效。")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(IMMessageContent.self, from: data)
    }

    func replaceContent(_ content: IMMessageContent) throws {
        kind = content.type.rawValue
        bodyJSON = try Self.encodeContent(content)
    }

    func decodedDerivedState() throws -> IMMessageDerivedState {
        guard let derivedStateJSON, let data = derivedStateJSON.data(using: .utf8) else {
            return try decodedContent().derivedState
        }

        let decoder = JSONDecoder()
        return try decoder.decode(IMMessageDerivedState.self, from: data)
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
        let encoder = JSONEncoder()
        let data = try encoder.encode(content)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "消息内容编码失败。")
        }
        return json
    }

    static func encodeDerivedState(_ derivedState: IMMessageDerivedState) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(derivedState)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "消息派生状态编码失败。")
        }
        return json
    }
}
