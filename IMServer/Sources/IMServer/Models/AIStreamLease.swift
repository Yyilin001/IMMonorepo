import Fluent
import Foundation

/// Global admission lease for an active AI stream. Unlike the stream index,
/// this record lives on the primary database so user-level quotas remain
/// correct when conversations are distributed across independent shards.
final class AIStreamLease: Model, @unchecked Sendable {
    static let schema = "im_ai_stream_leases"

    @ID(custom: "stream_id", generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "node_id")
    var nodeID: String

    @Field(key: "state")
    var state: String

    @Field(key: "cancel_requested")
    var cancelRequested: Bool

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        streamID: String,
        conversationID: UUID,
        userID: UUID,
        nodeID: String,
        expiresAt: Date,
        now: Date = Date()
    ) {
        self.id = streamID
        self.conversationID = conversationID
        self.userID = userID
        self.nodeID = nodeID
        self.state = "reserved"
        self.cancelRequested = false
        self.expiresAt = expiresAt
        self.createdAt = now
        self.updatedAt = now
    }

    var streamID: String {
        id ?? ""
    }
}
