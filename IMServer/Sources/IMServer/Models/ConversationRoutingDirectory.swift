import Fluent
import Foundation

final class ConversationDirectoryEntry: Model, @unchecked Sendable {
    static let schema = "conversation_directory"

    @ID(custom: "conversation_id", generatedBy: .user)
    var id: UUID?

    @Field(key: "shard_id")
    var shardID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(conversationID: UUID, shardID: String) {
        self.id = conversationID
        self.shardID = shardID
    }
}

final class DirectConversationIndexEntry: Model, @unchecked Sendable {
    static let schema = "direct_conversation_index"

    @ID(custom: "pair_hash", generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "shard_id")
    var shardID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(pairHash: String, conversationID: UUID, shardID: String) {
        self.id = pairHash
        self.conversationID = conversationID
        self.shardID = shardID
    }
}
