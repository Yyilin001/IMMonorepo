import Fluent
import Vapor

// AuthSession 对应“某个用户在某台设备上的一次登录会话”。
// refresh token rotation 的状态全部挂在这里，而不是直接信任客户端持有的 token。
final class AuthSession: Model, Content, @unchecked Sendable {
    static let schema = "auth_sessions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "current_nonce")
    var currentNonce: String

    // previous nonce + previousValidUntil 用于 rotation 的短暂重试窗口。
    @OptionalField(key: "previous_nonce")
    var previousNonce: String?

    @OptionalField(key: "previous_valid_until")
    var previousValidUntil: Date?

    @Field(key: "refresh_expires_at")
    var refreshExpiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @OptionalField(key: "device_id")
    var deviceID: String?

    @OptionalField(key: "device_name")
    var deviceName: String?

    @OptionalField(key: "platform")
    var platform: String?

    @OptionalField(key: "app_version")
    var appVersion: String?

    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        currentNonce: String,
        refreshExpiresAt: Date,
        deviceID: String?,
        deviceName: String?,
        platform: String?,
        appVersion: String?,
        lastSeenAt: Date?
    ) {
        self.id = id
        self.$user.id = userID
        self.currentNonce = currentNonce
        self.refreshExpiresAt = refreshExpiresAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
    }
}
