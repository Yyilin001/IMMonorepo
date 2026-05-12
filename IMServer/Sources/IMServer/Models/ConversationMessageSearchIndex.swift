import Fluent
import Foundation

final class ConversationMessageSearchIndex: Model, @unchecked Sendable {
    static let schema = "conversation_message_search_index"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "server_sequence")
    var serverSequence: Int

    @Field(key: "message_type")
    var messageType: String

    @OptionalField(key: "sender_user_id")
    var senderUserID: UUID?

    @Field(key: "searchable_text")
    var searchableText: String

    @OptionalField(key: "content_json")
    var contentJSON: String?

    @OptionalField(key: "derived_state_json")
    var derivedStateJSON: String?

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        messageID: UUID,
        conversationID: UUID,
        serverSequence: Int,
        messageType: String,
        senderUserID: UUID? = nil,
        searchableText: String,
        contentJSON: String? = nil,
        derivedStateJSON: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        id = Self.recordID(messageID: messageID)
        self.messageID = messageID
        self.conversationID = conversationID
        self.serverSequence = serverSequence
        self.messageType = messageType
        self.senderUserID = senderUserID
        self.searchableText = searchableText
        self.contentJSON = contentJSON
        self.derivedStateJSON = derivedStateJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func recordID(messageID: UUID) -> String {
        messageID.uuidString.lowercased()
    }
}
