import Fluent
import Vapor

final class MessageFavorite: Model, Content, @unchecked Sendable {
    static let schema = "message_favorites"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "server_sequence")
    var serverSequence: Int

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(ownerUserID: UUID, conversationID: UUID, messageID: UUID, serverSequence: Int, createdAt: Date = Date()) {
        self.id = Self.recordID(ownerUserID: ownerUserID, messageID: messageID)
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.messageID = messageID
        self.serverSequence = serverSequence
        self.createdAt = createdAt
    }

    static func recordID(ownerUserID: UUID, messageID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(messageID.uuidString.lowercased())"
    }
}

final class MessageVisibilityOverride: Model, @unchecked Sendable {
    static let schema = "message_visibility_overrides"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "server_sequence")
    var serverSequence: Int

    @Field(key: "is_hidden")
    var isHidden: Bool

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(ownerUserID: UUID, conversationID: UUID, messageID: UUID, serverSequence: Int, isHidden: Bool = true, createdAt: Date = Date()) {
        self.id = Self.recordID(ownerUserID: ownerUserID, messageID: messageID)
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.messageID = messageID
        self.serverSequence = serverSequence
        self.isHidden = isHidden
        self.createdAt = createdAt
    }

    static func recordID(ownerUserID: UUID, messageID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(messageID.uuidString.lowercased())"
    }
}

final class ConversationVisibilityOverride: Model, @unchecked Sendable {
    static let schema = "conversation_visibility_overrides"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @OptionalField(key: "hidden_before_sequence")
    var hiddenBeforeSequence: Int?

    @Field(key: "is_deleted")
    var isDeleted: Bool

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(ownerUserID: UUID, conversationID: UUID, hiddenBeforeSequence: Int?, isDeleted: Bool, updatedAt: Date = Date()) {
        self.id = Self.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.hiddenBeforeSequence = hiddenBeforeSequence
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    static func recordID(ownerUserID: UUID, conversationID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(conversationID.uuidString.lowercased())"
    }
}

final class UserBlock: Model, Content, @unchecked Sendable {
    static let schema = "user_blocks"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "blocked_user_id")
    var blockedUserID: UUID

    @OptionalField(key: "reason")
    var reason: String?

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(ownerUserID: UUID, blockedUserID: UUID, reason: String? = nil, createdAt: Date = Date()) {
        self.id = Self.recordID(ownerUserID: ownerUserID, blockedUserID: blockedUserID)
        self.ownerUserID = ownerUserID
        self.blockedUserID = blockedUserID
        self.reason = reason
        self.createdAt = createdAt
    }

    static func recordID(ownerUserID: UUID, blockedUserID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(blockedUserID.uuidString.lowercased())"
    }
}

final class UserReport: Model, Content, @unchecked Sendable {
    static let schema = "reports"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "reporter_user_id")
    var reporterUserID: UUID

    @Field(key: "target_type")
    var targetType: String

    @Field(key: "target_id")
    var targetID: String

    @OptionalField(key: "conversation_id")
    var conversationID: UUID?

    @OptionalField(key: "message_id")
    var messageID: UUID?

    @Field(key: "reason")
    var reason: String

    @OptionalField(key: "detail")
    var detail: String?

    @OptionalField(key: "message_snapshot_json")
    var messageSnapshotJSON: String?

    @OptionalField(key: "handled_note")
    var handledNote: String?

    @OptionalField(key: "assigned_reviewer_user_id")
    var assignedReviewerUserID: UUID?

    @OptionalField(key: "assigned_reviewer_actor")
    var assignedReviewerActor: String?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    @Field(key: "status")
    var status: String

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(reporterUserID: UUID, targetType: String, targetID: String, conversationID: UUID?, messageID: UUID?, reason: String, detail: String?, messageSnapshotJSON: String? = nil, status: String = "pending", assignedReviewerUserID: UUID? = nil, assignedReviewerActor: String? = nil, assignedAt: Date? = nil, createdAt: Date = Date()) {
        self.reporterUserID = reporterUserID
        self.targetType = targetType
        self.targetID = targetID
        self.conversationID = conversationID
        self.messageID = messageID
        self.reason = reason
        self.detail = detail
        self.messageSnapshotJSON = messageSnapshotJSON
        self.status = status
        self.assignedReviewerUserID = assignedReviewerUserID
        self.assignedReviewerActor = assignedReviewerActor
        self.assignedAt = assignedAt
        self.createdAt = createdAt
    }
}

final class ReportModerationDecision: Model, Content, @unchecked Sendable {
    static let schema = "report_moderation_decisions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "report_id")
    var report: UserReport

    @Field(key: "reviewer_actor")
    var reviewerActor: String

    @OptionalField(key: "reviewer_user_id")
    var reviewerUserID: UUID?

    @Field(key: "reviewer_role")
    var reviewerRole: String

    @Field(key: "authentication_method")
    var authenticationMethod: String

    @Field(key: "previous_status")
    var previousStatus: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "resolution_category")
    var resolutionCategory: String?

    @OptionalField(key: "handled_note")
    var handledNote: String?

    @OptionalField(key: "request_id")
    var requestID: String?

    @OptionalField(key: "idempotency_key")
    var idempotencyKey: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        reportID: UUID,
        reviewerActor: String,
        reviewerUserID: UUID?,
        reviewerRole: String,
        authenticationMethod: String,
        previousStatus: String,
        status: String,
        resolutionCategory: String?,
        handledNote: String?,
        requestID: String?,
        idempotencyKey: String?
    ) {
        self.$report.id = reportID
        self.reviewerActor = reviewerActor
        self.reviewerUserID = reviewerUserID
        self.reviewerRole = reviewerRole
        self.authenticationMethod = authenticationMethod
        self.previousStatus = previousStatus
        self.status = status
        self.resolutionCategory = resolutionCategory
        self.handledNote = handledNote
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
    }
}

final class ReportModerationEvidence: Model, Content, @unchecked Sendable {
    static let schema = "report_moderation_evidence"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "report_id")
    var report: UserReport

    @Field(key: "evidence_url")
    var evidenceURL: String

    @OptionalField(key: "label")
    var label: String?

    @Field(key: "submitted_by_actor")
    var submittedByActor: String

    @OptionalField(key: "submitted_by_user_id")
    var submittedByUserID: UUID?

    @Field(key: "submitter_role")
    var submitterRole: String

    @Field(key: "authentication_method")
    var authenticationMethod: String

    @OptionalField(key: "request_id")
    var requestID: String?

    @OptionalField(key: "idempotency_key")
    var idempotencyKey: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        reportID: UUID,
        evidenceURL: String,
        label: String?,
        submittedByActor: String,
        submittedByUserID: UUID?,
        submitterRole: String,
        authenticationMethod: String,
        requestID: String?,
        idempotencyKey: String?
    ) {
        self.$report.id = reportID
        self.evidenceURL = evidenceURL
        self.label = label
        self.submittedByActor = submittedByActor
        self.submittedByUserID = submittedByUserID
        self.submitterRole = submitterRole
        self.authenticationMethod = authenticationMethod
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
    }
}

final class GroupInvite: Model, Content, @unchecked Sendable {
    static let schema = "group_invites"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "creator_user_id")
    var creatorUserID: UUID

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Field(key: "use_count")
    var useCount: Int

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(token: String, conversationID: UUID, creatorUserID: UUID, expiresAt: Date, createdAt: Date = Date()) {
        self.id = token
        self.conversationID = conversationID
        self.creatorUserID = creatorUserID
        self.expiresAt = expiresAt
        self.useCount = 0
        self.createdAt = createdAt
    }
}

final class PushDeviceToken: Model, Content, @unchecked Sendable {
    static let schema = "push_device_tokens"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @OptionalField(key: "session_id")
    var sessionID: UUID?

    @Field(key: "platform")
    var platform: String

    @Field(key: "token")
    var token: String

    @Field(key: "is_active")
    var isActive: Bool

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(ownerUserID: UUID, sessionID: UUID?, platform: String, token: String, isActive: Bool = true, date: Date = Date()) {
        self.id = Self.recordID(ownerUserID: ownerUserID, platform: platform, token: token)
        self.ownerUserID = ownerUserID
        self.sessionID = sessionID
        self.platform = platform
        self.token = token
        self.isActive = isActive
        self.createdAt = date
        self.updatedAt = date
    }

    static func recordID(ownerUserID: UUID, platform: String, token: String) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(platform.lowercased()):\(token)"
    }
}

final class MessageReceipt: Model, @unchecked Sendable {
    static let schema = "message_receipts"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "message_id")
    var messageID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "status")
    var status: String

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(conversationID: UUID, messageID: UUID, userID: UUID, status: String, updatedAt: Date = Date()) {
        self.id = Self.recordID(messageID: messageID, userID: userID)
        self.conversationID = conversationID
        self.messageID = messageID
        self.userID = userID
        self.status = status
        self.updatedAt = updatedAt
    }

    static func recordID(messageID: UUID, userID: UUID) -> String {
        "\(messageID.uuidString.lowercased()):\(userID.uuidString.lowercased())"
    }
}
