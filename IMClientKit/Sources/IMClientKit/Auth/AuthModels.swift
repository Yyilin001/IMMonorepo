import Foundation

public struct AuthUser: Codable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
    }

    public var preferredDisplayName: String {
        let normalizedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedDisplayName, !normalizedDisplayName.isEmpty else {
            return email
        }
        return normalizedDisplayName
    }
}

public struct DeviceMetadataPayload: Encodable, Sendable {
    public let deviceID: String?
    public let deviceName: String?
    public let platform: String?
    public let appVersion: String?

    public init(deviceID: String?, deviceName: String?, platform: String?, appVersion: String?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct CredentialsRequestBody: Encodable, Sendable {
    public let email: String
    public let password: String
    public let device: DeviceMetadataPayload?
}

typealias LoginRequestBody = CredentialsRequestBody
typealias RegisterRequestBody = CredentialsRequestBody

public struct RefreshRequestBody: Encodable, Sendable {
    public let refreshToken: String
}

public struct AuthResponseBody: Codable, Sendable, APIResponseBody {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String
    public let refreshExpiresIn: Int
    public let user: AuthUser
}

public struct SessionSnapshot: Decodable, Identifiable, Equatable, Sendable, APIResponseBody {
    public let id: UUID
    public let deviceID: String?
    public let deviceName: String?
    public let platform: String?
    public let appVersion: String?
    public let lastSeenAt: Date?
    public let createdAt: Date?
    public let refreshExpiresAt: Date
    public let isCurrent: Bool
    public let isOnline: Bool?
    public let activeConnectionCount: Int?
}

public struct LogoutAllResponseBody: Decodable, Sendable, APIResponseBody {
    public let revokedSessions: Int
}

public struct EmptyRequestBody: Encodable, Sendable { }
