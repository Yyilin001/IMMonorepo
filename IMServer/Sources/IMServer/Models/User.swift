import Fluent
import Vapor

enum UserStatus: String, Codable {
    case active
    case disabled
}

// User 只保存账号本身信息；具体设备登录态都落在 AuthSession 表里。
final class User: Model, Content, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "avatar_preset")
    var avatarPreset: String?

    @OptionalField(key: "email_verified_at")
    var emailVerifiedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    @Children(for: \.$user)
    var sessions: [AuthSession]

    init() { }

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String,
        status: UserStatus,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        emailVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.status = status.rawValue
        self.displayName = displayName
        self.avatarPreset = avatarPreset?.rawValue
        self.emailVerifiedAt = emailVerifiedAt
    }

    var statusEnum: UserStatus {
        UserStatus(rawValue: status) ?? .disabled
    }

    func asResponse() throws -> UserResponse {
        UserResponse(
            id: try requireID(),
            email: email,
            displayName: displayName,
            avatarPreset: avatarPresetEnum
        )
    }

    var avatarPresetEnum: UserAvatarPreset? {
        get { avatarPreset.flatMap(UserAvatarPreset.init(rawValue:)) }
        set { avatarPreset = newValue?.rawValue }
    }

    static func normalize(_ email: String) -> String {
        // 登录和注册都使用统一的邮箱归一化规则，避免大小写导致重复账号。
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct UserResponse: Content, Equatable, Sendable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarPreset: UserAvatarPreset?
}
