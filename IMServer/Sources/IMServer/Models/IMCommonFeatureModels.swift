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

    @Field(key: "status")
    var status: String

    @Field(key: "created_at")
    var createdAt: Date

    init() {}

    init(reporterUserID: UUID, targetType: String, targetID: String, conversationID: UUID?, messageID: UUID?, reason: String, detail: String?, messageSnapshotJSON: String? = nil, status: String = "pending", createdAt: Date = Date()) {
        self.reporterUserID = reporterUserID
        self.targetType = targetType
        self.targetID = targetID
        self.conversationID = conversationID
        self.messageID = messageID
        self.reason = reason
        self.detail = detail
        self.messageSnapshotJSON = messageSnapshotJSON
        self.status = status
        self.createdAt = createdAt
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
