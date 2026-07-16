import Fluent
import Foundation
import Vapor

final class ConversationMediaAssetReference: Model, Content, @unchecked Sendable {
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

    func migrationCopy() -> ConversationMediaAssetReference {
        let copy = ConversationMediaAssetReference()
        copy.id = id
        copy.assetID = assetID
        copy.ownerUserID = ownerUserID
        copy.conversationID = conversationID
        copy.messageID = messageID
        copy.serverSequence = serverSequence
        copy.kind = kind
        copy.createdAt = createdAt
        copy.updatedAt = updatedAt
        return copy
    }

    var migrationFingerprintFields: [String?] {
        [
            id,
            assetID,
            ownerUserID.uuidString,
            conversationID.uuidString,
            messageID.uuidString,
            String(serverSequence),
            kind,
            String(createdAt.timeIntervalSince1970),
            String(updatedAt.timeIntervalSince1970)
        ]
    }
}
