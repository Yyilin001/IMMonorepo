import Fluent
import Foundation

final class ConversationUserSummary: Model, @unchecked Sendable {
    static let schema = "im_conversation_user_summaries"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @OptionalField(key: "title")
    var title: String?

    @Field(key: "kind")
    var kind: String

    @OptionalField(key: "direct_messaging_state")
    var directMessagingState: String?

    @OptionalField(key: "direct_peer_user_id")
    var directPeerUserID: UUID?

    @OptionalField(key: "direct_peer_email")
    var directPeerEmail: String?

    @OptionalField(key: "direct_peer_display_name")
    var directPeerDisplayName: String?

    @OptionalField(key: "direct_peer_avatar_preset")
    var directPeerAvatarPreset: String?

    @OptionalField(key: "notice")
    var notice: String?

    @OptionalField(key: "avatar_preset")
    var avatarPreset: String?

    @Field(key: "mute_all")
    var muteAll: Bool

    @Field(key: "member_count")
    var memberCount: Int

    @OptionalField(key: "membership_revision")
    var membershipRevision: Date?

    @Field(key: "member_user_ids_json")
    private var memberUserIDsJSON: String

    @OptionalField(key: "last_message_json")
    private var lastMessageJSON: String?

    @Field(key: "last_read_sequence")
    var lastReadSequence: Int

    @Field(key: "unread_count")
    var unreadCount: Int

    @Field(key: "is_pinned")
    var isPinned: Bool

    @OptionalField(key: "pinned_at")
    var pinnedAt: Date?

    @Field(key: "is_muted")
    var isMuted: Bool

    @Field(key: "last_activity_at")
    var lastActivityAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    @Field(key: "is_removed")
    var isRemoved: Bool

    init() { }

    init(
        ownerUserID: UUID,
        conversationID: UUID,
        title: String?,
        kind: String,
        directMessagingState: String?,
        directPeerUserID: UUID?,
        directPeerEmail: String?,
        directPeerDisplayName: String? = nil,
        directPeerAvatarPreset: UserAvatarPreset? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool = false,
        memberUserIDs: [UUID],
        lastMessage: IMMessagePreviewResponse?,
        lastReadSequence: Int,
        unreadCount: Int,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        isMuted: Bool = false,
        lastActivityAt: Date,
        updatedAt: Date,
        isRemoved: Bool,
        membershipRevision: Date? = nil
    ) throws {
        id = Self.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.title = title
        self.kind = kind
        self.directMessagingState = directMessagingState
        self.directPeerUserID = directPeerUserID
        self.directPeerEmail = directPeerEmail
        self.directPeerDisplayName = directPeerDisplayName
        self.directPeerAvatarPreset = directPeerAvatarPreset?.rawValue
        self.notice = notice
        self.avatarPreset = avatarPreset?.rawValue
        self.muteAll = muteAll
        memberCount = memberUserIDs.count
        self.membershipRevision = membershipRevision
        memberUserIDsJSON = try Self.encodeUUIDs(memberUserIDs)
        lastMessageJSON = try lastMessage.map(Self.encodeLastMessage)
        self.lastReadSequence = lastReadSequence
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.isMuted = isMuted
        self.lastActivityAt = lastActivityAt
        self.updatedAt = updatedAt
        self.isRemoved = isRemoved
    }

    var memberUserIDs: [UUID] {
        get { (try? Self.decodeUUIDs(memberUserIDsJSON)) ?? [] }
        set {
            memberUserIDsJSON = (try? Self.encodeUUIDs(newValue)) ?? "[]"
            memberCount = newValue.count
        }
    }

    var lastMessage: IMMessagePreviewResponse? {
        get {
            guard let lastMessageJSON else {
                return nil
            }
            return try? Self.decodeLastMessage(lastMessageJSON)
        }
        set {
            lastMessageJSON = try? newValue.map(Self.encodeLastMessage)
        }
    }

    var avatarPresetEnum: IMConversationAvatarPreset? {
        get { avatarPreset.flatMap(IMConversationAvatarPreset.init(rawValue:)) }
        set { avatarPreset = newValue?.rawValue }
    }

    var directPeerAvatarPresetEnum: UserAvatarPreset? {
        get { directPeerAvatarPreset.flatMap(UserAvatarPreset.init(rawValue:)) }
        set { directPeerAvatarPreset = newValue?.rawValue }
    }

    static func recordID(ownerUserID: UUID, conversationID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(conversationID.uuidString.lowercased())"
    }

    static func encodeMemberUserIDsForStorage(_ value: [UUID]) throws -> String {
        try encodeUUIDs(value)
    }

    static func encodeLastMessageForStorage(_ value: IMMessagePreviewResponse?) throws -> String? {
        try value.map(encodeLastMessage)
    }

    private static func encodeUUIDs(_ value: [UUID]) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }

    private static func decodeUUIDs(_ json: String) throws -> [UUID] {
        guard let data = json.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return try JSONDecoder().decode([UUID].self, from: data)
    }

    private static func encodeLastMessage(_ value: IMMessagePreviewResponse) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }

    private static func decodeLastMessage(_ json: String) throws -> IMMessagePreviewResponse {
        guard let data = json.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IMMessagePreviewResponse.self, from: data)
    }
}

enum ConversationProjectionCodingError: Error {
    case invalidJSON
}

final class ConversationChangesLogEntry: Model, @unchecked Sendable {
    static let schema = "conversation_changes_log"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "summary_record_id")
    var summaryRecordID: String

    @Field(key: "updated_at")
    var updatedAt: Date

    @Field(key: "is_removed")
    var isRemoved: Bool

    init() {}

    init(
        ownerUserID: UUID,
        conversationID: UUID,
        summaryRecordID: String,
        updatedAt: Date,
        isRemoved: Bool
    ) {
        self.id = Self.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        self.ownerUserID = ownerUserID
        self.conversationID = conversationID
        self.summaryRecordID = summaryRecordID
        self.updatedAt = updatedAt
        self.isRemoved = isRemoved
    }

    static func recordID(ownerUserID: UUID, conversationID: UUID) -> String {
        ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
    }
}

final class ConversationReadModelToken: Model, @unchecked Sendable {
    static let schema = "conversation_read_model_tokens"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "target_token")
    var targetToken: String

    @Field(key: "updated_at")
    var updatedAt: Date

    init() {}

    init(ownerUserID: UUID, targetToken: String, updatedAt: Date) {
        self.id = Self.recordID(ownerUserID: ownerUserID)
        self.ownerUserID = ownerUserID
        self.targetToken = targetToken
        self.updatedAt = updatedAt
    }

    static func recordID(ownerUserID: UUID) -> String {
        ownerUserID.uuidString.lowercased()
    }
}
