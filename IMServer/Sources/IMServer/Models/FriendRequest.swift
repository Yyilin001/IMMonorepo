import Fluent
import Vapor

enum FriendRequestStatus: String, Codable {
    case pending
    case accepted
    case declined
    case cancelled
}

final class FriendRequest: Model, Content, @unchecked Sendable {
    static let schema = "friend_requests"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "requester_user_id")
    var requester: User

    @Parent(key: "addressee_user_id")
    var addressee: User

    @Field(key: "status")
    var status: String

    @OptionalField(key: "message")
    var message: String?

    @OptionalField(key: "requester_remark")
    var requesterRemark: String?

    @OptionalField(key: "addressee_remark")
    var addresseeRemark: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @OptionalField(key: "responded_at")
    var respondedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        requesterUserID: UUID,
        addresseeUserID: UUID,
        status: FriendRequestStatus = .pending,
        message: String? = nil,
        requesterRemark: String? = nil,
        addresseeRemark: String? = nil,
        respondedAt: Date? = nil
    ) {
        self.id = id
        self.$requester.id = requesterUserID
        self.$addressee.id = addresseeUserID
        self.status = status.rawValue
        self.message = message
        self.requesterRemark = requesterRemark
        self.addresseeRemark = addresseeRemark
        self.respondedAt = respondedAt
    }

    var statusEnum: FriendRequestStatus {
        FriendRequestStatus(rawValue: status) ?? .pending
    }
}
