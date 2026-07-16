import Fluent
import Foundation

enum AdminConversationGovernanceAction: String, Codable, Sendable {
    case groupMuteAllSet = "group.mute_all.set"
    case groupLifecycleSet = "group.lifecycle.set"
    case groupMemberRemove = "group.member.remove"
}

enum AdminConversationGovernanceCommandStatus: String, Codable, Sendable {
    case pending
    case applying
    case applied
    case failed
}

final class AdminConversationGovernanceCommand: Model, @unchecked Sendable {
    static let schema = "admin_conversation_governance_commands"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "action")
    var action: String

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "target_shard_id")
    var targetShardID: String

    @Field(key: "target_cell_id")
    var targetCellID: String

    @Field(key: "target_route_version")
    var targetRouteVersion: Int

    @Field(key: "actor")
    var actor: String

    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    @Field(key: "actor_role")
    var actorRole: String

    @Field(key: "authentication_method")
    var authenticationMethod: String

    @Field(key: "idempotency_key")
    var idempotencyKey: String

    @Field(key: "request_digest")
    var requestDigest: String

    @Field(key: "requested_mute_all")
    var requestedMuteAll: Bool

    @Field(key: "requested_group_lifecycle_state")
    var requestedGroupLifecycleState: String

    @OptionalField(key: "target_member_user_id")
    var targetMemberUserID: UUID?

    @Field(key: "destructive_confirmed")
    var destructiveConfirmed: Bool

    @Field(key: "reason")
    var reason: String

    @Field(key: "status")
    var status: String

    @Field(key: "attempt_count")
    var attemptCount: Int

    @OptionalField(key: "last_error_code")
    var lastErrorCode: String?

    @OptionalField(key: "processing_token")
    var processingToken: String?

    @OptionalField(key: "processing_started_at")
    var processingStartedAt: Date?

    @Field(key: "accepted_at")
    var acceptedAt: Date

    @OptionalField(key: "applied_at")
    var appliedAt: Date?

    @Field(key: "updated_at")
    var updatedAt: Date

    init() { }

    init(
        action: AdminConversationGovernanceAction,
        conversationID: UUID,
        targetShardID: String,
        targetCellID: String,
        targetRouteVersion: Int,
        actor: String,
        actorUserID: UUID?,
        actorRole: AdminRole,
        authenticationMethod: AdminAccessContext.AuthenticationMethod,
        idempotencyKey: String,
        requestDigest: String,
        requestedMuteAll: Bool,
        requestedGroupLifecycleState: IMGroupLifecycleState = .active,
        targetMemberUserID: UUID? = nil,
        destructiveConfirmed: Bool = false,
        reason: String,
        now: Date = Date()
    ) {
        self.action = action.rawValue
        self.conversationID = conversationID
        self.targetShardID = targetShardID
        self.targetCellID = targetCellID
        self.targetRouteVersion = targetRouteVersion
        self.actor = actor
        self.actorUserID = actorUserID
        self.actorRole = actorRole.rawValue
        self.authenticationMethod = authenticationMethod.rawValue
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.requestedMuteAll = requestedMuteAll
        self.requestedGroupLifecycleState = requestedGroupLifecycleState.rawValue
        self.targetMemberUserID = targetMemberUserID
        self.destructiveConfirmed = destructiveConfirmed
        self.reason = reason
        self.status = AdminConversationGovernanceCommandStatus.pending.rawValue
        self.attemptCount = 0
        self.acceptedAt = now
        self.updatedAt = now
    }

    var actionEnum: AdminConversationGovernanceAction? {
        AdminConversationGovernanceAction(rawValue: action)
    }

    var statusEnum: AdminConversationGovernanceCommandStatus {
        get { AdminConversationGovernanceCommandStatus(rawValue: status) ?? .failed }
        set { status = newValue.rawValue }
    }

    var requestedGroupLifecycleStateEnum: IMGroupLifecycleState {
        IMGroupLifecycleState(rawValue: requestedGroupLifecycleState) ?? .active
    }
}
