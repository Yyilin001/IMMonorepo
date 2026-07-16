import Fluent
import Foundation

final class AdminWriteIdempotencyRecord: Model, @unchecked Sendable {
    static let schema = "admin_write_idempotency_records"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "scope")
    var scope: String

    @Field(key: "actor")
    var actor: String

    @Field(key: "idempotency_key")
    var idempotencyKey: String

    @Field(key: "target_id")
    var targetID: String

    @Field(key: "request_digest")
    var requestDigest: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(scope: String, actor: String, idempotencyKey: String, targetID: String, requestDigest: String) {
        self.scope = scope
        self.actor = actor
        self.idempotencyKey = idempotencyKey
        self.targetID = targetID
        self.requestDigest = requestDigest
    }
}
