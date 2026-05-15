import Fluent
import Foundation

final class DirectConversationPairDirectory: Model, @unchecked Sendable {
    static let schema = "direct_conversation_pair_directory"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "lower_user_id")
    var lowerUserID: UUID

    @Field(key: "higher_user_id")
    var higherUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @OptionalField(key: "direct_messaging_state")
    var directMessagingState: String?

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        lowerUserID: UUID,
        higherUserID: UUID,
        conversationID: UUID,
        directMessagingState: IMDirectMessagingState?,
        updatedAt: Date
    ) {
        id = Self.recordID(lowerUserID: lowerUserID, higherUserID: higherUserID, conversationID: conversationID)
        self.lowerUserID = lowerUserID
        self.higherUserID = higherUserID
        self.conversationID = conversationID
        self.directMessagingState = directMessagingState?.rawValue
        self.updatedAt = updatedAt
    }

    static func normalizedPair(_ lhs: UUID, _ rhs: UUID) -> (lower: UUID, higher: UUID)? {
        guard lhs != rhs else {
            return nil
        }
        let sorted = [lhs, rhs].sorted { $0.uuidString < $1.uuidString }
        return (sorted[0], sorted[1])
    }

    static func recordID(lowerUserID: UUID, higherUserID: UUID, conversationID: UUID) -> String {
        "\(lowerUserID.uuidString.lowercased()):\(higherUserID.uuidString.lowercased()):\(conversationID.uuidString.lowercased())"
    }
}
