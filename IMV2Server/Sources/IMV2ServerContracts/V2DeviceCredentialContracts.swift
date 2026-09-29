import Foundation
import IMV2Core

/// 仅返回给单独受信的账号与设备边界的明文凭据对。
///
/// 它绝不能进入日志、遥测或网关响应。
public struct V2IssuedDeviceCredentials: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshCredential: String
    public let revocationCredential: V2DeviceRevocationCredential
    public let revocationCredentialExpiresAt: Date

    public init(userID: UserID, deviceID: DeviceID, accessToken: String, accessTokenExpiresAt: Date, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, revocationCredentialExpiresAt: Date) throws {
        guard !accessToken.isEmpty, !refreshCredential.isEmpty,
              accessTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite, revocationCredentialExpiresAt.timeIntervalSinceReferenceDate.isFinite
        else { throw V2DeviceCredentialServiceError.malformedPersistence }
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.revocationCredentialExpiresAt = revocationCredentialExpiresAt
    }
}

/// 受信身份系统在调用该边界之前已完成自然人/账号的认证。
///
/// V2 在此刻意不规定密码、短信、SSO 或第三方身份策略。
public struct V2TrustedDeviceRegistration: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let operationID: UUID
    public let metadata: V2DeviceRegistrationMetadata
    public let credentialRevision: Int64?

    public init(
        userID: UserID,
        deviceID: DeviceID,
        operationID: UUID,
        metadata: V2DeviceRegistrationMetadata = .unknown,
        credentialRevision: Int64? = nil
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.operationID = operationID
        self.metadata = metadata
        self.credentialRevision = credentialRevision
    }
}

/// 由客户端提供的非安全敏感信息，仅用于让账号所有者能识别已登录设备。
///
/// 它刻意不包含广告标识、IP 地址或系统版本。
public struct V2DeviceRegistrationMetadata: Equatable, Sendable {
    public let displayName: String
    public let platform: String

    public init(displayName: String, platform: String) {
        self.displayName = displayName
        self.platform = platform
    }

    public static let unknown = Self(displayName: "This device", platform: "Unknown")

    public static func validated(
        displayName: String?,
        platform: String?
    ) throws -> Self {
        func normalize(_ value: String?, fallback: String) -> String {
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? fallback : normalized
        }
        let displayName = normalize(displayName, fallback: unknown.displayName)
        let platform = normalize(platform, fallback: unknown.platform)
        guard displayName.utf8.count <= 128,
              platform.utf8.count <= 64,
              !displayName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !platform.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2DeviceCredentialServiceError.invalidMetadata }
        return .init(displayName: displayName, platform: platform)
    }
}

public struct V2DeviceCredentialRefresh: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let refreshCredential: String
    public let revocationCredential: V2DeviceRevocationCredential
    public let operationID: UUID

    public init(userID: UserID, deviceID: DeviceID, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) throws {
        guard !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.invalidRefreshCredential }
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.operationID = operationID
    }
}

public enum V2DeviceRegistrationOutcome: Equatable, Sendable {
    case issued(V2IssuedDeviceCredentials)
    case idempotent(V2IssuedDeviceCredentials)
    case idempotencyConflict
    case deviceUnavailable
    case activeDeviceLimitReached
    case rateLimited(retryAfterSeconds: Int)
}

public enum V2DeviceCredentialRefreshOutcome: Equatable, Sendable {
    case rotated(V2IssuedDeviceCredentials)
    case idempotent(V2IssuedDeviceCredentials)
    /// 刷新值无效或已过期。
    ///
    /// 只有当提交的摘要能证明复用了此前已消费的刷新凭据时，才会吊销整个设备族；
    /// 任意的摘要不匹配只是保持状态的拒绝，不能被用来把另一台安装登出。
    case terminalRejection
}

public struct V2DeviceRegistrationPolicy: Equatable, Sendable {
    public let maximumActiveDevices: Int
    public let maximumNewDevicesPerWindow: Int
    public let window: TimeInterval

    public init(
        maximumActiveDevices: Int,
        maximumNewDevicesPerWindow: Int,
        window: TimeInterval
    ) throws {
        guard maximumActiveDevices > 0,
              maximumActiveDevices <= 1_024,
              maximumNewDevicesPerWindow > 0,
              maximumNewDevicesPerWindow <= 100_000,
              window.isFinite,
              window >= 60,
              window <= 366 * 86_400
        else { throw V2DeviceCredentialServiceError.invalidConfiguration }
        self.maximumActiveDevices = maximumActiveDevices
        self.maximumNewDevicesPerWindow = maximumNewDevicesPerWindow
        self.window = window
    }

    public static let standard = Self(
        validatedMaximumActiveDevices: 8,
        maximumNewDevicesPerWindow: 16,
        window: 30 * 86_400
    )

    private init(
        validatedMaximumActiveDevices: Int,
        maximumNewDevicesPerWindow: Int,
        window: TimeInterval
    ) {
        maximumActiveDevices = validatedMaximumActiveDevices
        self.maximumNewDevicesPerWindow = maximumNewDevicesPerWindow
        self.window = window
    }
}

/// 由单独部署的账号断言适配器使用的稳定边界。
///
/// 凭据持久化由签发实现负责；HTTP 与身份适配器只把自己的受信输入转换为该领域请求。
public protocol V2DeviceCredentialIssuing: Sendable {
    func register(_ request: V2CancellableDeviceRegistration) async throws -> V2DeviceRegistrationOutcome
    func refresh(_ request: V2DeviceCredentialRefresh) async throws -> V2DeviceCredentialRefreshOutcome
}
