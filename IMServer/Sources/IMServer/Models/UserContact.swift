import Fluent
import Vapor

final class UserContact: Model, Content, @unchecked Sendable {
    static let schema = "user_contacts"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "owner_user_id")
    var owner: User

    @Parent(key: "contact_user_id")
    var contact: User

    @OptionalField(key: "remark")
    var remark: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, ownerUserID: UUID, contactUserID: UUID, remark: String? = nil) {
        self.id = id
        self.$owner.id = ownerUserID
        self.$contact.id = contactUserID
        self.remark = remark
    }
}
