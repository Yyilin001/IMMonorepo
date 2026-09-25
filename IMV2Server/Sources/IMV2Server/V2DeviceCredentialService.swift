import Crypto
import FluentKit
import Foundation
import IMV2Core
import SQLKit

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

public enum V2DeviceCredentialServiceError: Error, Equatable, Sendable {
    case invalidRefreshCredential
    case invalidMetadata
    case invalidConfiguration
    case malformedPersistence
    case unavailable
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

/// 有界重放结果使用的信封密钥。
///
/// 数据库只会收到经过认证的密文；该密钥属于部署机密材料，
/// 必须与令牌 HMAC 密钥分开提供。
public struct V2CredentialReplayEnvelopeKey: Sendable {
    private let rawBytes: Data

    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw V2DeviceCredentialServiceError.invalidConfiguration }
        self.rawBytes = rawBytes
    }

    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value) else { throw V2DeviceCredentialServiceError.invalidConfiguration }
        try self.init(rawBytes: bytes)
    }

    fileprivate func seal(_ plaintext: String, authenticating context: Data) throws -> String {
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: SymmetricKey(data: rawBytes), authenticating: context)
        return box.combined.base64EncodedString()
    }

    fileprivate func open(_ ciphertext: String, authenticating context: Data) throws -> String {
        guard let combined = Data(base64Encoded: ciphertext) else { throw V2DeviceCredentialServiceError.malformedPersistence }
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: rawBytes), authenticating: context)
        guard let result = String(data: plaintext, encoding: .utf8), !result.isEmpty else {
            throw V2DeviceCredentialServiceError.malformedPersistence
        }
        return result
    }
}

public struct V2OpaqueCredentialGenerator: Sendable {
    private let makeToken: @Sendable () -> String

    public init() {
        self.makeToken = Self.secureToken
    }

    public init(makeToken: @escaping @Sendable () -> String) {
        self.makeToken = makeToken
    }

    fileprivate func next() -> String { makeToken() }

    private static func secureToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 基于 PostgreSQL 的设备认证服务。
///
/// 每次成功注册或轮换都会在向受信调用方返回明文之前，
/// 原子地保存生效令牌摘要、刷新设备族状态与加密后的重放结果。
public struct V2PostgresDeviceCredentialService: V2DeviceCredentialIssuing, Sendable {
    private let database: any Database
    private let tokenHMACKey: V2AccessTokenHMACKey
    private let replayEnvelopeKey: V2CredentialReplayEnvelopeKey
    private let tokenGenerator: V2OpaqueCredentialGenerator
    private let now: @Sendable () -> Date
    private let accessTokenLifetime: TimeInterval
    private let refreshCredentialLifetime: TimeInterval
    private let maximumSessionLifetime: TimeInterval
    private let replayWindow: TimeInterval
    private let registrationPolicy: V2DeviceRegistrationPolicy

    public init(
        database: any Database,
        tokenHMACKey: V2AccessTokenHMACKey,
        replayEnvelopeKey: V2CredentialReplayEnvelopeKey,
        tokenGenerator: V2OpaqueCredentialGenerator = .init(),
        accessTokenLifetime: TimeInterval = 15 * 60,
        refreshCredentialLifetime: TimeInterval = 30 * 24 * 60 * 60,
        replayWindow: TimeInterval = 10 * 60,
        maximumSessionLifetime: TimeInterval = 30 * 24 * 60 * 60,
        registrationPolicy: V2DeviceRegistrationPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard accessTokenLifetime > 0, refreshCredentialLifetime > 0, replayWindow > 0,
              accessTokenLifetime.isFinite, refreshCredentialLifetime.isFinite, replayWindow.isFinite,
              maximumSessionLifetime.isFinite, maximumSessionLifetime >= 1, maximumSessionLifetime <= 366 * 86_400
        else { throw V2DeviceCredentialServiceError.invalidConfiguration }
        self.database = database
        self.tokenHMACKey = tokenHMACKey
        self.replayEnvelopeKey = replayEnvelopeKey
        self.tokenGenerator = tokenGenerator
        self.accessTokenLifetime = accessTokenLifetime
        self.refreshCredentialLifetime = refreshCredentialLifetime
        self.maximumSessionLifetime = maximumSessionLifetime
        self.replayWindow = replayWindow
        self.registrationPolicy = registrationPolicy
        self.now = now
    }

    public func register(_ request: V2TrustedDeviceRegistration) async throws -> V2DeviceRegistrationOutcome {
        try await register(request, cancellation: nil)
    }

    public func register(_ request: V2CancellableDeviceRegistration) async throws -> V2DeviceRegistrationOutcome {
        try await register(request.registration, cancellation: request.cancellation)
    }

    private func register(_ request: V2TrustedDeviceRegistration, cancellation: V2DeviceRegistrationCancellation?) async throws -> V2DeviceRegistrationOutcome {
        guard v2PostgresTimestampCanEncode(now()) else { throw V2DeviceCredentialServiceError.unavailable }
        let accessToken = tokenGenerator.next()
        let refreshCredential = tokenGenerator.next()
        guard !accessToken.isEmpty, !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceCredentialServiceError.unavailable }
            let userUUID = try credentialUUID(request.userID)
            let deviceUUID = try credentialUUID(request.deviceID)
            let metadata = try normalizedMetadata(request.metadata)
            if let cancellation { try await V2PostgresDeviceRegistrationCancellationService.lock(sql, request: cancellation) }
            try await lockAccountState(sql, userID: userUUID)
            if let revision = request.credentialRevision {
                guard try await sql.raw("SELECT 1 FROM im_v2.account_password_credentials WHERE user_id = \(bind: userUUID) AND credential_revision = \(bind: revision)").first() != nil else { return .deviceUnavailable }
            }
            guard !(try await isAccountDisabled(sql, userID: userUUID)) else { return .deviceUnavailable }
            // 特殊账号只可通过可信服务边界操作。
            // 绝不能签发可让它通过公共网关使用的客户端或设备凭据。
            guard !(try await isSpecialAccount(sql, userID: userUUID)) else { return .deviceUnavailable }
            try await lock(sql, key: "register:" + deviceUUID.uuidString)

            let existingDevice = try await sql.raw("SELECT user_id, revoked_at, session_expires_at FROM im_v2.auth_devices WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: DeviceRow.self)
            // 等锁期间可能发生时钟校正。以此次新观测为权威，
            // 并在绑定前校验它。
            let issuedAt = now()
            guard v2PostgresTimestampCanEncode(issuedAt) else { throw V2DeviceCredentialServiceError.unavailable }
            if let cancellation, try await !V2PostgresDeviceRegistrationCancellationService.permitsIssuance(sql, request: cancellation, at: issuedAt) {
                return .deviceUnavailable
            }
            if let prior = try await credentialOperation(sql, deviceID: deviceUUID, operationID: request.operationID) {
                guard prior.operationKind == "registration", prior.userID == userUUID, prior.requestRefreshHMAC == nil else {
                    return .idempotencyConflict
                }
                guard let existingDevice, existingDevice.userID == userUUID, existingDevice.revokedAt == nil, existingDevice.sessionExpiresAt > issuedAt else { return .deviceUnavailable }
                guard prior.replayExpiresAt > issuedAt else { return .idempotencyConflict }
                if let cancellation, try await !V2PostgresDeviceRegistrationCancellationService.ownsReplay(sql, request: cancellation, userID: userUUID) {
                    return .idempotencyConflict
                }
                return .idempotent(try credentials(from: prior, request: request))
            }

            let isNewDevice: Bool
            let sessionExpiresAt: Date
            if let existing = existingDevice {
                guard existing.userID == userUUID, existing.revokedAt == nil, existing.sessionExpiresAt > issuedAt else { return .deviceUnavailable }
                guard try await sql.raw("SELECT 1 FROM im_v2.device_refresh_sessions WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first() == nil else {
                    return .idempotencyConflict
                }
                sessionExpiresAt = min(existing.sessionExpiresAt, issuedAt.addingTimeInterval(maximumSessionLifetime))
                isNewDevice = false
            } else {
                guard try await activeDeviceCount(sql, userID: userUUID, at: issuedAt) < registrationPolicy.maximumActiveDevices else {
                    return .activeDeviceLimitReached
                }
                if let retryAfter = try await newDeviceRegistrationRetryAfter(sql, userID: userUUID, now: issuedAt) {
                    return .rateLimited(retryAfterSeconds: retryAfter)
                }
                sessionExpiresAt = issuedAt.addingTimeInterval(maximumSessionLifetime)
                isNewDevice = true
            }

            let deadlines = try credentialDeadlines(issuedAt: issuedAt, sessionExpiresAt: sessionExpiresAt)
            if isNewDevice {
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, display_name, platform, last_active_at, created_at, session_expires_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: metadata.displayName), \(bind: metadata.platform), \(bind: issuedAt), \(bind: issuedAt), \(bind: sessionExpiresAt))").run()
            } else {
                let maximumDeadline = issuedAt.addingTimeInterval(maximumSessionLifetime)
                // PostgreSQL 的 LEAST 会忽略 NULL。若未使用的上界超出其范围，
                // 则保留现有的原生会话限制。
                let sessionLimit = v2PostgresTimestampCanEncode(maximumDeadline) ? maximumDeadline : nil
                try await sql.raw("UPDATE im_v2.auth_devices SET display_name = \(bind: metadata.displayName), platform = \(bind: metadata.platform), last_active_at = GREATEST(last_active_at, \(bind: issuedAt)), session_expires_at = LEAST(session_expires_at, \(bind: sessionLimit)::timestamptz) WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)").run()
            }

            let capability = try await V2PostgresDeviceSessionService.issueRevocationCapability(on: sql, userID: request.userID, deviceID: request.deviceID, at: issuedAt)
            let credentials = try makeCredentials(userID: request.userID, deviceID: request.deviceID, accessToken: accessToken, refreshCredential: refreshCredential, deadlines: deadlines, capability: capability)
            try await insertNewSession(sql, credentials: credentials, issuedAt: issuedAt, refreshExpiresAt: deadlines.refreshExpiresAt)
            try await insertOperation(sql, kind: "registration", requestRefreshHMAC: nil, operationID: request.operationID, credentials: credentials, issuedAt: issuedAt, replayExpiresAt: deadlines.replayExpiresAt)
            if let cancellation {
                try await V2PostgresDeviceRegistrationCancellationService.bindIssuedSession(sql, request: cancellation, userID: userUUID, at: issuedAt)
            }
            if isNewDevice {
                try await recordSuccessfulNewDeviceRegistration(sql, userID: userUUID, now: issuedAt)
            }
            return .issued(credentials)
        }
    }

    public func refresh(_ request: V2DeviceCredentialRefresh) async throws -> V2DeviceCredentialRefreshOutcome {
        guard v2PostgresTimestampCanEncode(now()) else { throw V2DeviceCredentialServiceError.unavailable }
        let accessToken = tokenGenerator.next()
        let refreshCredential = tokenGenerator.next()
        guard !accessToken.isEmpty, !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceCredentialServiceError.unavailable }
            let userUUID = try credentialUUID(request.userID)
            let deviceUUID = try credentialUUID(request.deviceID)
            let incomingRefreshHMAC = tokenHMACKey.digest(request.refreshCredential)
            try await lockAccountState(sql, userID: userUUID)
            var issuedAt = now()
            guard v2PostgresTimestampCanEncode(issuedAt) else { throw V2DeviceCredentialServiceError.unavailable }
            guard !(try await isAccountDisabled(sql, userID: userUUID)) else {
                try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                return .terminalRejection
            }
            guard !(try await isSpecialAccount(sql, userID: userUUID)) else {
                try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                return .terminalRejection
            }
            try await lock(sql, key: "refresh:" + deviceUUID.uuidString)
            let device = try await sql.raw("SELECT user_id, revoked_at, session_expires_at FROM im_v2.auth_devices WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: DeviceRow.self)
            // 每取得一把可能延迟过期判断的锁后，都重新读取时间；
            // 响应和所有轮换写入使用同一新观测值。
            issuedAt = now()
            guard v2PostgresTimestampCanEncode(issuedAt) else { throw V2DeviceCredentialServiceError.unavailable }
            guard let device,
                  device.userID == userUUID, device.revokedAt == nil, device.sessionExpiresAt > issuedAt
            else { return .terminalRejection }

            guard let capability = try await V2PostgresDeviceSessionService.matchingRevocationCapability(
                on: sql, userID: request.userID, deviceID: request.deviceID, credential: request.revocationCredential
            ) else { return .terminalRejection }

            if let prior = try await credentialOperation(sql, deviceID: deviceUUID, operationID: request.operationID) {
                guard prior.operationKind == "refresh",
                      prior.userID == userUUID,
                      prior.requestRefreshHMAC == incomingRefreshHMAC
                else {
                    // 操作 ID 冲突本身不能证明凭据持有或重复使用。
                    // 单独保留的已消耗摘要仍可能证明该值属于同一凭据族。
                    if try await isConsumedRefreshCredential(
                        sql,
                        userID: userUUID,
                        deviceID: deviceUUID,
                        refreshHMAC: incomingRefreshHMAC
                    ) {
                        try await revokeDevice(
                            sql,
                            userID: userUUID,
                            deviceID: deviceUUID,
                            at: issuedAt
                        )
                    }
                    return .terminalRejection
                }
                guard prior.replayExpiresAt > issuedAt else {
                    // 已知此摘要触发过该凭据族的轮换，
                    // 但有界加密响应已无法重放。
                    try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                    return .terminalRejection
                }
                return .idempotent(try credentials(from: prior, request: request))
            }

            guard let session = try await sql.raw("SELECT family_generation, refresh_hmac, expires_at, revoked_at FROM im_v2.device_refresh_sessions WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: RefreshSessionRow.self),
                  session.revokedAt == nil,
                  session.expiresAt > issuedAt
            else { return .terminalRejection }

            guard session.refreshHMAC == incomingRefreshHMAC else {
                if try await isConsumedRefreshCredential(
                    sql,
                    userID: userUUID,
                    deviceID: deviceUUID,
                    refreshHMAC: incomingRefreshHMAC
                ) {
                    // 判定请求重复使用刷新令牌，需要轮换历史作为证据。
                    // 未知随机值仍统一拒绝，且不改变状态。
                    try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                }
                return .terminalRejection
            }

            guard session.familyGeneration > 0 else { throw V2DeviceCredentialServiceError.malformedPersistence }
            let (nextGeneration, generationOverflow) = session.familyGeneration.addingReportingOverflow(1)
            guard !generationOverflow else { throw V2DeviceCredentialServiceError.unavailable }
            let deadlines = try credentialDeadlines(issuedAt: issuedAt, sessionExpiresAt: device.sessionExpiresAt)
            let credentials = try makeCredentials(userID: request.userID, deviceID: request.deviceID, accessToken: accessToken, refreshCredential: refreshCredential, deadlines: deadlines, capability: capability)
            try await sql.raw("INSERT INTO im_v2.device_refresh_token_history (user_id, device_id, family_generation, refresh_hmac, consumed_at, expires_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: session.familyGeneration), \(bind: session.refreshHMAC), \(bind: issuedAt), \(bind: session.expiresAt))").run()
            try await sql.raw("UPDATE im_v2.device_refresh_sessions SET refresh_hmac = \(bind: tokenHMACKey.digest(refreshCredential)), family_generation = \(bind: nextGeneration), issued_at = \(bind: issuedAt), expires_at = \(bind: deadlines.refreshExpiresAt) WHERE device_id = \(bind: deviceUUID)").run()
            try await insertAccessToken(sql, credentials: credentials, issuedAt: issuedAt)
            try await insertOperation(sql, kind: "refresh", requestRefreshHMAC: incomingRefreshHMAC, operationID: request.operationID, credentials: credentials, issuedAt: issuedAt, replayExpiresAt: deadlines.replayExpiresAt)
            return .rotated(credentials)
        }
    }

    private func credentialDeadlines(issuedAt: Date, sessionExpiresAt: Date) throws -> V2DeviceCredentialDeadlines {
        try .init(issuedAt: issuedAt, sessionExpiresAt: sessionExpiresAt,
                  accessLifetime: accessTokenLifetime, refreshLifetime: refreshCredentialLifetime,
                  replayWindow: replayWindow)
    }

    private func makeCredentials(userID: UserID, deviceID: DeviceID, accessToken: String, refreshCredential: String, deadlines: V2DeviceCredentialDeadlines, capability: V2IssuedDeviceRevocationCapability) throws -> V2IssuedDeviceCredentials {
        try .init(userID: userID, deviceID: deviceID, accessToken: accessToken, accessTokenExpiresAt: deadlines.accessExpiresAt, refreshCredential: refreshCredential, revocationCredential: capability.credential, revocationCredentialExpiresAt: capability.expiresAt)
    }

    private func insertNewSession(_ sql: any SQLDatabase, credentials: V2IssuedDeviceCredentials, issuedAt: Date, refreshExpiresAt: Date) async throws {
        let userID = try credentialUUID(credentials.userID), deviceID = try credentialUUID(credentials.deviceID)
        try await sql.raw("INSERT INTO im_v2.device_refresh_sessions (user_id, device_id, refresh_hmac, issued_at, expires_at) VALUES (\(bind: userID), \(bind: deviceID), \(bind: tokenHMACKey.digest(credentials.refreshCredential)), \(bind: issuedAt), \(bind: refreshExpiresAt))").run()
        try await insertAccessToken(sql, credentials: credentials, issuedAt: issuedAt)
    }

    private func insertAccessToken(_ sql: any SQLDatabase, credentials: V2IssuedDeviceCredentials, issuedAt: Date) async throws {
        try await sql.raw("INSERT INTO im_v2.device_access_tokens (token_hmac, user_id, device_id, issued_at, expires_at) VALUES (\(bind: tokenHMACKey.digest(credentials.accessToken)), \(bind: credentialUUID(credentials.userID)), \(bind: credentialUUID(credentials.deviceID)), \(bind: issuedAt), \(bind: credentials.accessTokenExpiresAt))").run()
    }

    private func insertOperation(_ sql: any SQLDatabase, kind: String, requestRefreshHMAC: String?, operationID: UUID, credentials: V2IssuedDeviceCredentials, issuedAt: Date, replayExpiresAt: Date) async throws {
        let context = replayContext(userID: credentials.userID, deviceID: credentials.deviceID, operationID: operationID)
        try await sql.raw("INSERT INTO im_v2.device_credential_operations (device_id, operation_id, operation_kind, user_id, request_refresh_hmac, resulting_access_token_hmac, encrypted_access_token, encrypted_refresh_credential, encrypted_revocation_credential, revocation_credential_expires_at, access_token_expires_at, replay_expires_at, created_at) VALUES (\(bind: credentialUUID(credentials.deviceID)), \(bind: operationID), \(bind: kind), \(bind: credentialUUID(credentials.userID)), \(bind: requestRefreshHMAC), \(bind: tokenHMACKey.digest(credentials.accessToken)), \(bind: try replayEnvelopeKey.seal(credentials.accessToken, authenticating: context)), \(bind: try replayEnvelopeKey.seal(credentials.refreshCredential, authenticating: context)), \(bind: try replayEnvelopeKey.seal(credentials.revocationCredential.rawValue, authenticating: context)), \(bind: credentials.revocationCredentialExpiresAt), \(bind: credentials.accessTokenExpiresAt), \(bind: replayExpiresAt), \(bind: issuedAt))").run()
    }

    private func credentials(from operation: CredentialOperationRow, request: V2TrustedDeviceRegistration) throws -> V2IssuedDeviceCredentials {
        let userID = try UserID(operation.userID.uuidString), deviceID = try DeviceID(operation.deviceID.uuidString)
        let context = replayContext(userID: userID, deviceID: deviceID, operationID: request.operationID)
        return try .init(userID: userID, deviceID: deviceID, accessToken: replayEnvelopeKey.open(operation.encryptedAccessToken, authenticating: context), accessTokenExpiresAt: operation.accessTokenExpiresAt, refreshCredential: replayEnvelopeKey.open(operation.encryptedRefreshCredential, authenticating: context), revocationCredential: .init(rawValue: replayEnvelopeKey.open(operation.encryptedRevocationCredential, authenticating: context)), revocationCredentialExpiresAt: operation.revocationCredentialExpiresAt)
    }

    private func credentials(from operation: CredentialOperationRow, request: V2DeviceCredentialRefresh) throws -> V2IssuedDeviceCredentials {
        let userID = try UserID(operation.userID.uuidString), deviceID = try DeviceID(operation.deviceID.uuidString)
        let context = replayContext(userID: userID, deviceID: deviceID, operationID: request.operationID)
        return try .init(userID: userID, deviceID: deviceID, accessToken: replayEnvelopeKey.open(operation.encryptedAccessToken, authenticating: context), accessTokenExpiresAt: operation.accessTokenExpiresAt, refreshCredential: replayEnvelopeKey.open(operation.encryptedRefreshCredential, authenticating: context), revocationCredential: .init(rawValue: replayEnvelopeKey.open(operation.encryptedRevocationCredential, authenticating: context)), revocationCredentialExpiresAt: operation.revocationCredentialExpiresAt)
    }

    private func credentialOperation(_ sql: any SQLDatabase, deviceID: UUID, operationID: UUID) async throws -> CredentialOperationRow? {
        try await sql.raw("SELECT device_id, operation_id, operation_kind, user_id, request_refresh_hmac, encrypted_access_token, encrypted_refresh_credential, encrypted_revocation_credential, revocation_credential_expires_at, access_token_expires_at, replay_expires_at FROM im_v2.device_credential_operations WHERE device_id = \(bind: deviceID) AND operation_id = \(bind: operationID)").first(decoding: CredentialOperationRow.self)
    }

    private func isConsumedRefreshCredential(
        _ sql: any SQLDatabase,
        userID: UUID,
        deviceID: UUID,
        refreshHMAC: String
    ) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.device_refresh_token_history WHERE device_id = \(bind: deviceID) AND user_id = \(bind: userID) AND refresh_hmac = \(bind: refreshHMAC) LIMIT 1").first() != nil
    }

    private func revokeDevice(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID, at now: Date) async throws {
        // 每次修改都必须锚定权威的用户与设备记录。设备未知或不匹配时，
        // 须以终态无操作结束：为其插入撤销事件会违反事件外键；
        // 若请求携带错误的用户 ID，仅凭设备 ID 撤销刷新会话
        // 还可能影响其他账号。
        try await sql.raw("""
            WITH revoked_device AS MATERIALIZED (
                UPDATE im_v2.auth_devices
                SET revoked_at = COALESCE(revoked_at, \(bind: now))
                WHERE user_id = \(bind: userID)
                  AND device_id = \(bind: deviceID)
                RETURNING user_id, device_id
            ), revoked_refresh_session AS (
                UPDATE im_v2.device_refresh_sessions AS session
                SET revoked_at = COALESCE(session.revoked_at, \(bind: now))
                FROM revoked_device AS device
                WHERE session.device_id = device.device_id
                RETURNING session.device_id
            ), revoked_access_tokens AS (
                UPDATE im_v2.device_access_tokens AS token
                SET revoked_at = COALESCE(token.revoked_at, \(bind: now))
                FROM revoked_device AS device
                WHERE token.user_id = device.user_id
                  AND token.device_id = device.device_id
                RETURNING token.device_id
            )
            INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
            SELECT user_id, device_id, \(bind: now)
            FROM revoked_device
            ON CONFLICT (device_id) DO NOTHING
            """).run()
    }

    private func lock(_ sql: any SQLDatabase, key: String) async throws {
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    private func lockAccountState(_ sql: any SQLDatabase, userID: UUID) async throws {
        try await lock(sql, key: "account-state:" + userID.uuidString)
    }

    private func isAccountDisabled(_ sql: any SQLDatabase, userID: UUID) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: userID)").first() != nil
    }

    private func isSpecialAccount(_ sql: any SQLDatabase, userID: UUID) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.special_accounts WHERE account_user_id = \(bind: userID) AND status = 'active'").first() != nil
    }

    private func activeDeviceCount(_ sql: any SQLDatabase, userID: UUID, at observedAt: Date) async throws -> Int {
        try await sql.raw("SELECT COUNT(*)::integer AS count FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND revoked_at IS NULL AND session_expires_at > \(bind: observedAt)")
            .first(decoding: DeviceCountRow.self)?.count ?? 0
    }

    private func newDeviceRegistrationRetryAfter(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws -> Int? {
        try await PostgresV2DeviceRegistrationBudget(policy: registrationPolicy)
            .retryAfter(sql, userID: userID, now: now)
    }

    private func recordSuccessfulNewDeviceRegistration(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws {
        try await PostgresV2DeviceRegistrationBudget(policy: registrationPolicy)
            .recordSuccess(sql, userID: userID, now: now)
    }

    private func normalizedMetadata(_ metadata: V2DeviceRegistrationMetadata) throws -> (displayName: String, platform: String) {
        let validated = try V2DeviceRegistrationMetadata.validated(
            displayName: metadata.displayName,
            platform: metadata.platform
        )
        return (validated.displayName, validated.platform)
    }

    private func replayContext(userID: UserID, deviceID: DeviceID, operationID: UUID) -> Data {
        Data("v2-credential-replay|\(userID.rawValue)|\(deviceID.rawValue)|\(operationID.uuidString)".utf8)
    }
}

private struct DeviceRow: Decodable {
    let userID: UUID
    let revokedAt: Date?
    let sessionExpiresAt: Date
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case revokedAt = "revoked_at"; case sessionExpiresAt = "session_expires_at" }
}

private struct DeviceCountRow: Decodable { let count: Int }

private struct RefreshSessionRow: Decodable {
    let familyGeneration: Int64
    let refreshHMAC: String
    let expiresAt: Date
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey {
        case familyGeneration = "family_generation"
        case refreshHMAC = "refresh_hmac"
        case expiresAt = "expires_at"
        case revokedAt = "revoked_at"
    }
}

private struct CredentialOperationRow: Decodable {
    let deviceID: UUID
    let operationID: UUID
    let operationKind: String
    let userID: UUID
    let requestRefreshHMAC: String?
    let encryptedAccessToken: String
    let encryptedRefreshCredential: String
    let encryptedRevocationCredential: String
    let revocationCredentialExpiresAt: Date
    let accessTokenExpiresAt: Date
    let replayExpiresAt: Date
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"; case operationID = "operation_id"; case operationKind = "operation_kind"
        case userID = "user_id"; case requestRefreshHMAC = "request_refresh_hmac"
        case encryptedAccessToken = "encrypted_access_token"; case encryptedRefreshCredential = "encrypted_refresh_credential"
        case encryptedRevocationCredential = "encrypted_revocation_credential"; case revocationCredentialExpiresAt = "revocation_credential_expires_at"
        case accessTokenExpiresAt = "access_token_expires_at"; case replayExpiresAt = "replay_expires_at"
    }
}

private func credentialUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceCredentialServiceError.malformedPersistence }
    return value
}
