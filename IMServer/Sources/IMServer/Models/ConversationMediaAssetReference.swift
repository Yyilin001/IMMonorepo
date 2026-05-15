import Fluent
import Foundation

final class ConversationMediaAssetReference: Model, @unchecked Sendable {
    static let schema = "conversation_media_asset_references"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "asset_id")
    var assetID: String

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "server_sequence")
    var serverSequence: Int

    @Field(key: "kind")
    var kind: String

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        messageID: UUID,
        assetID: String,
        ownerUserID: UUID,
        conversationID: UUID,
        serverSequence: Int,
        kind: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        id = Self.recordID(messageID: messageID)
        self.assetID = assetID
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.messageID = messageID
        self.serverSequence = serverSequence
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func recordID(messageID: UUID) -> String {
        messageID.uuidString.lowercased()
    }
}
