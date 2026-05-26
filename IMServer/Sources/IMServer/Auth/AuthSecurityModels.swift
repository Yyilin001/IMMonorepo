import Fluent
import Vapor

enum AuthChallengeKind: String, Codable, Sendable {
    case emailVerification = "email_verification"
    case passwordReset = "password_reset"
}

enum AuthSessionRevocationReason: String, Codable, Sendable {
    case logoutCurrent = "logout_current"
    case logoutAll = "logout_all"
    case sessionRevoked = "session_revoked"
    case duplicateDeviceLogin = "duplicate_device_login"
    case refreshTokenReuse = "refresh_token_reuse"
    case passwordReset = "password_reset"
}

final class AuthEmailVerificationChallenge: Model, Content, @unchecked Sendable {
    static let schema = "auth_email_verification_challenges"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "email")
    var email: String

    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "attempt_count")
    var attemptCount: Int

    @OptionalField(key: "consumed_at")
    var consumedAt: Date?

    @OptionalField(key: "created_ip")
    var createdIP: String?

    @OptionalField(key: "created_user_agent")
    var createdUserAgent: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        userID: UUID,
        email: String,
        codeHash: String,
        expiresAt: Date,
        createdIP: String?,
        createdUserAgent: String?
    ) {
        self.$user.id = userID
        self.email = email
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.attemptCount = 0
        self.createdIP = createdIP
        self.createdUserAgent = createdUserAgent
    }
}

final class AuthPasswordResetChallenge: Model, Content, @unchecked Sendable {
    static let schema = "auth_password_reset_challenges"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "email")
    var email: String

    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "attempt_count")
    var attemptCount: Int

    @OptionalField(key: "consumed_at")
    var consumedAt: Date?

    @OptionalField(key: "created_ip")
    var createdIP: String?

    @OptionalField(key: "created_user_agent")
    var createdUserAgent: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        userID: UUID,
        email: String,
        codeHash: String,
        expiresAt: Date,
        createdIP: String?,
        createdUserAgent: String?
    ) {
        self.$user.id = userID
        self.email = email
        self.codeHash = codeHash
        self.expiresAt = expiresAt
        self.attemptCount = 0
        self.createdIP = createdIP
        self.createdUserAgent = createdUserAgent
    }
}

final class AuthSecurityEvent: Model, Content, @unchecked Sendable {
    static let schema = "auth_security_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "event_type")
    var eventType: String

    @OptionalField(key: "user_id")
    var userID: UUID?

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "session_id")
    var sessionID: UUID?

    @OptionalField(key: "device_id")
    var deviceID: String?

    @OptionalField(key: "ip_address")
    var ipAddress: String?

    @Field(key: "succeeded")
    var succeeded: Bool

    @OptionalField(key: "failure_reason")
    var failureReason: String?

    @OptionalField(key: "metadata")
    var metadata: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        eventType: String,
        userID: UUID?,
        email: String?,
        sessionID: UUID?,
        deviceID: String?,
        ipAddress: String?,
        succeeded: Bool,
        failureReason: String?,
        metadata: String? = nil
    ) {
        self.eventType = eventType
        self.userID = userID
        self.email = email
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.ipAddress = ipAddress
        self.succeeded = succeeded
        self.failureReason = failureReason
        self.metadata = metadata
    }
}
