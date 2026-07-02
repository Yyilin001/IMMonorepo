import Fluent
import Vapor

final class AdminAuditEvent: Model, Content, @unchecked Sendable {
    static let schema = "admin_audit_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "actor")
    var actor: String

    @Field(key: "action")
    var action: String

    @OptionalField(key: "target_type")
    var targetType: String?

    @OptionalField(key: "target_id")
    var targetID: String?

    @OptionalField(key: "request_id")
    var requestID: String?

    @OptionalField(key: "ip_address")
    var ipAddress: String?

    @OptionalField(key: "metadata_json")
    var metadataJSON: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        actor: String,
        action: String,
        targetType: String? = nil,
        targetID: String? = nil,
        requestID: String? = nil,
        ipAddress: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.actor = actor
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.requestID = requestID
        self.ipAddress = ipAddress
        self.metadataJSON = metadataJSON
    }
}
