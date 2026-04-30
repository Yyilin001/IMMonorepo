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

    @Field(key: "searchable_text")
    var searchableText: String

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
        searchableText: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        id = Self.recordID(messageID: messageID)
        self.messageID = messageID
        self.conversationID = conversationID
        self.serverSequence = serverSequence
        self.messageType = messageType
        self.searchableText = searchableText
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func recordID(messageID: UUID) -> String {
        messageID.uuidString.lowercased()
    }
}
