import Fluent
import Foundation
import Vapor

enum ContactChangeEntityType: String, Content {
    case contact
    case request
}

final class ContactChangeLogEntry: Model, @unchecked Sendable {
    static let schema = "contact_changes_log"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "entity_type")
    var entityType: String

    @Field(key: "entity_id")
    var entityID: UUID

    @Field(key: "updated_at")
    var updatedAt: Date

    @Field(key: "is_removed")
    var isRemoved: Bool

    init() {}

    init(
        ownerUserID: UUID,
        entityType: ContactChangeEntityType,
        entityID: UUID,
        updatedAt: Date,
        isRemoved: Bool
    ) {
        self.id = Self.recordID(ownerUserID: ownerUserID, entityType: entityType, entityID: entityID)
        self.ownerUserID = ownerUserID
        self.entityType = entityType.rawValue
        self.entityID = entityID
        self.updatedAt = updatedAt
        self.isRemoved = isRemoved
    }

    static func recordID(ownerUserID: UUID, entityType: ContactChangeEntityType, entityID: UUID) -> String {
        [
            ownerUserID.uuidString.lowercased(),
            entityType.rawValue,
            entityID.uuidString.lowercased()
        ].joined(separator: ":")
    }
}
