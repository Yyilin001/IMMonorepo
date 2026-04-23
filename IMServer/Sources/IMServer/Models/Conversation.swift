import Fluent
import Vapor

enum IMConversationKind: String, Codable, Content, Sendable {
    case direct
    case group
}

final class Conversation: Model, Content, @unchecked Sendable {
    static let schema = "im_conversations"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "title")
    var title: String?

    @Field(key: "kind")
    var kind: String

    @Field(key: "updated_at")
    var updatedAt: Date

    @Field(key: "last_message_sequence")
    var lastMessageSequence: Int

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
        kind: IMConversationKind = .group,
        updatedAt: Date = Date(),
        lastMessageSequence: Int = 0
    ) {
        self.id = id
        self.title = title
        self.kind = kind.rawValue
        self.updatedAt = updatedAt
        self.lastMessageSequence = lastMessageSequence
    }

    var conversationKind: IMConversationKind {
        get { IMConversationKind(rawValue: kind) ?? .group }
        set { kind = newValue.rawValue }
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

    @Field(key: "last_read_sequence")
    var lastReadSequence: Int

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        userID: UUID,
        lastReadSequence: Int = 0
    ) {
        self.id = id
        self.$conversation.id = conversationID
        self.$user.id = userID
        self.lastReadSequence = lastReadSequence
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
        kind: String,
        body: [String: String]
    ) throws {
        self.id = id
        self.$conversation.id = conversationID
        self.$sender.id = senderUserID
        self.serverSequence = serverSequence
        self.clientMessageID = clientMessageID
        self.kind = kind
        self.bodyJSON = try Self.encodeBody(body)
    }

    func decodedBody() throws -> [String: String] {
        guard let data = bodyJSON.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "消息内容编码无效。")
        }

        return try JSONDecoder().decode([String: String].self, from: data)
    }

    static func encodeBody(_ body: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(body)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "消息内容编码失败。")
        }
        return json
    }
}
