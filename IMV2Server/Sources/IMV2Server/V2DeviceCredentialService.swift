import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// The plaintext pair returned only to the separately trusted account/device
/// boundary. It must never enter logs, telemetry, or gateway responses.
public struct V2IssuedDeviceCredentials: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshCredential: String

    public init(userID: UserID, deviceID: DeviceID, accessToken: String, accessTokenExpiresAt: Date, refreshCredential: String) throws {
        guard !accessToken.isEmpty, !refreshCredential.isEmpty,
              accessTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite
        else { throw V2DeviceCredentialServiceError.malformedPersistence }
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
    }
}

/// A trusted identity system authenticates the human/account before it calls
/// this boundary. V2 intentionally does not prescribe password, SMS, SSO, or
/// third-party identity policy here.
public struct V2TrustedDeviceRegistration: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let operationID: UUID
    public let metadata: V2DeviceRegistrationMetadata

    public init(
        userID: UserID,
        deviceID: DeviceID,
        operationID: UUID,
        metadata: V2DeviceRegistrationMetadata = .unknown
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.operationID = operationID
        self.metadata = metadata
    }
}

/// Client-supplied, non-security-sensitive information used only to make a
/// signed-in device recognisable to its account owner. It deliberately does
/// not contain an advertising ID, IP address, or OS version.
public struct V2DeviceRegistrationMetadata: Equatable, Sendable {
    public let displayName: String
    public let platform: String

    public init(displayName: String, platform: String) {
        self.displayName = displayName
        self.platform = platform
    }

    public static let unknown = Self(displayName: "This device", platform: "Unknown")
}

public struct V2DeviceCredentialRefresh: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let refreshCredential: String
    public let operationID: UUID

    public init(userID: UserID, deviceID: DeviceID, refreshCredential: String, operationID: UUID) throws {
        guard !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.invalidRefreshCredential }
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
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
    /// The refresh value was invalid, expired, or reused with a different
    /// operation. The device family has been revoked atomically.
    case terminalRejection
}

public enum V2DeviceCredentialServiceError: Error, Equatable, Sendable {
    case invalidRefreshCredential
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

/// Stable boundary used by a separately deployed account-assertion adapter.
/// The issuer implementation owns credential persistence; HTTP and identity
/// adapters only translate their trusted input into this domain request.
public protocol V2DeviceCredentialIssuing: Sendable {
    func register(_ request: V2TrustedDeviceRegistration) async throws -> V2DeviceRegistrationOutcome
    func refresh(_ request: V2DeviceCredentialRefresh) async throws -> V2DeviceCredentialRefreshOutcome
}

/// Envelope key for the bounded replay result. The database only receives
/// authenticated ciphertext; this key is deployment-secret material and must
/// be supplied separately from the token HMAC key.
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

/// PostgreSQL-backed Auth service. Every successful registration or rotation
/// atomically stores the active token digest, refresh-family state, and an
/// encrypted replay result before returning plaintext to the trusted caller.
public struct V2PostgresDeviceCredentialService: V2DeviceCredentialIssuing, Sendable {
    private let database: any Database
    private let tokenHMACKey: V2AccessTokenHMACKey
    private let replayEnvelopeKey: V2CredentialReplayEnvelopeKey
    private let tokenGenerator: V2OpaqueCredentialGenerator
    private let now: @Sendable () -> Date
    private let accessTokenLifetime: TimeInterval
    private let refreshCredentialLifetime: TimeInterval
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
        registrationPolicy: V2DeviceRegistrationPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard accessTokenLifetime > 0, refreshCredentialLifetime > 0, replayWindow > 0,
              accessTokenLifetime.isFinite, refreshCredentialLifetime.isFinite, replayWindow.isFinite
        else { throw V2DeviceCredentialServiceError.invalidConfiguration }
        self.database = database
        self.tokenHMACKey = tokenHMACKey
        self.replayEnvelopeKey = replayEnvelopeKey
        self.tokenGenerator = tokenGenerator
        self.accessTokenLifetime = accessTokenLifetime
        self.refreshCredentialLifetime = refreshCredentialLifetime
        self.replayWindow = replayWindow
        self.registrationPolicy = registrationPolicy
        self.now = now
    }

    public func register(_ request: V2TrustedDeviceRegistration) async throws -> V2DeviceRegistrationOutcome {
        let issuedAt = now()
        let accessToken = tokenGenerator.next()
        let refreshCredential = tokenGenerator.next()
        guard !accessToken.isEmpty, !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceCredentialServiceError.unavailable }
            let userUUID = try credentialUUID(request.userID)
            let deviceUUID = try credentialUUID(request.deviceID)
            let metadata = try normalizedMetadata(request.metadata)
            try await lockAccountState(sql, userID: userUUID)
            guard !(try await isAccountDisabled(sql, userID: userUUID)) else { return .deviceUnavailable }
            // Special accounts are operated only through the trusted service
            // boundary. Never mint a client/device credential that could make
            // one available to the public gateway.
            guard !(try await isSpecialAccount(sql, userID: userUUID)) else { return .deviceUnavailable }
            try await lock(sql, key: "register:" + deviceUUID.uuidString)

            if let prior = try await credentialOperation(sql, deviceID: deviceUUID, operationID: request.operationID) {
                guard prior.operationKind == "registration", prior.userID == userUUID, prior.requestRefreshHMAC == nil else {
                    return .idempotencyConflict
                }
                guard prior.replayExpiresAt > issuedAt else { return .idempotencyConflict }
                return .idempotent(try credentials(from: prior, request: request))
            }

            let isNewDevice: Bool
            if let existing = try await sql.raw("SELECT user_id, revoked_at FROM im_v2.auth_devices WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: DeviceRow.self) {
                guard existing.userID == userUUID, existing.revokedAt == nil else { return .deviceUnavailable }
                guard try await sql.raw("SELECT 1 FROM im_v2.device_refresh_sessions WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first() == nil else {
                    return .idempotencyConflict
                }
                try await sql.raw("UPDATE im_v2.auth_devices SET display_name = \(bind: metadata.displayName), platform = \(bind: metadata.platform), last_active_at = GREATEST(last_active_at, \(bind: issuedAt)) WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)").run()
                isNewDevice = false
            } else {
                guard try await activeDeviceCount(sql, userID: userUUID) < registrationPolicy.maximumActiveDevices else {
                    return .activeDeviceLimitReached
                }
                if let retryAfter = try await newDeviceRegistrationRetryAfter(sql, userID: userUUID, now: issuedAt) {
                    return .rateLimited(retryAfterSeconds: retryAfter)
                }
                try await sql.raw("INSERT INTO im_v2.auth_devices (user_id, device_id, display_name, platform, last_active_at, created_at) VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: metadata.displayName), \(bind: metadata.platform), \(bind: issuedAt), \(bind: issuedAt))").run()
                isNewDevice = true
            }

            let credentials = try makeCredentials(userID: request.userID, deviceID: request.deviceID, accessToken: accessToken, refreshCredential: refreshCredential, issuedAt: issuedAt)
            try await insertNewSession(sql, credentials: credentials, issuedAt: issuedAt)
            try await insertOperation(sql, kind: "registration", requestRefreshHMAC: nil, operationID: request.operationID, credentials: credentials, issuedAt: issuedAt)
            if isNewDevice {
                try await recordSuccessfulNewDeviceRegistration(sql, userID: userUUID, now: issuedAt)
            }
            return .issued(credentials)
        }
    }

    public func refresh(_ request: V2DeviceCredentialRefresh) async throws -> V2DeviceCredentialRefreshOutcome {
        let issuedAt = now()
        let accessToken = tokenGenerator.next()
        let refreshCredential = tokenGenerator.next()
        guard !accessToken.isEmpty, !refreshCredential.isEmpty else { throw V2DeviceCredentialServiceError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceCredentialServiceError.unavailable }
            let userUUID = try credentialUUID(request.userID)
            let deviceUUID = try credentialUUID(request.deviceID)
            let incomingRefreshHMAC = tokenHMACKey.digest(request.refreshCredential)
            try await lockAccountState(sql, userID: userUUID)
            guard !(try await isAccountDisabled(sql, userID: userUUID)) else {
                try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                return .terminalRejection
            }
            guard !(try await isSpecialAccount(sql, userID: userUUID)) else {
                try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                return .terminalRejection
            }
            try await lock(sql, key: "refresh:" + deviceUUID.uuidString)

            if let prior = try await credentialOperation(sql, deviceID: deviceUUID, operationID: request.operationID) {
                guard prior.operationKind == "refresh", prior.userID == userUUID, prior.requestRefreshHMAC == incomingRefreshHMAC,
                      prior.replayExpiresAt > issuedAt
                else {
                    try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                    return .terminalRejection
                }
                return .idempotent(try credentials(from: prior, request: request))
            }

            guard let device = try await sql.raw("SELECT user_id, revoked_at FROM im_v2.auth_devices WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: DeviceRow.self),
                  device.userID == userUUID, device.revokedAt == nil,
                  let session = try await sql.raw("SELECT refresh_hmac, expires_at, revoked_at FROM im_v2.device_refresh_sessions WHERE device_id = \(bind: deviceUUID) FOR UPDATE").first(decoding: RefreshSessionRow.self),
                  session.revokedAt == nil, session.expiresAt > issuedAt,
                  session.refreshHMAC == incomingRefreshHMAC
            else {
                try await revokeDevice(sql, userID: userUUID, deviceID: deviceUUID, at: issuedAt)
                return .terminalRejection
            }

            let credentials = try makeCredentials(userID: request.userID, deviceID: request.deviceID, accessToken: accessToken, refreshCredential: refreshCredential, issuedAt: issuedAt)
            try await sql.raw("UPDATE im_v2.device_refresh_sessions SET refresh_hmac = \(bind: tokenHMACKey.digest(refreshCredential)), family_generation = family_generation + 1, issued_at = \(bind: issuedAt), expires_at = \(bind: issuedAt.addingTimeInterval(refreshCredentialLifetime)) WHERE device_id = \(bind: deviceUUID)").run()
            try await insertAccessToken(sql, credentials: credentials, issuedAt: issuedAt)
            try await insertOperation(sql, kind: "refresh", requestRefreshHMAC: incomingRefreshHMAC, operationID: request.operationID, credentials: credentials, issuedAt: issuedAt)
            return .rotated(credentials)
        }
    }

    private func makeCredentials(userID: UserID, deviceID: DeviceID, accessToken: String, refreshCredential: String, issuedAt: Date) throws -> V2IssuedDeviceCredentials {
        try .init(userID: userID, deviceID: deviceID, accessToken: accessToken, accessTokenExpiresAt: issuedAt.addingTimeInterval(accessTokenLifetime), refreshCredential: refreshCredential)
    }

    private func insertNewSession(_ sql: any SQLDatabase, credentials: V2IssuedDeviceCredentials, issuedAt: Date) async throws {
        let userID = try credentialUUID(credentials.userID), deviceID = try credentialUUID(credentials.deviceID)
        try await sql.raw("INSERT INTO im_v2.device_refresh_sessions (user_id, device_id, refresh_hmac, issued_at, expires_at) VALUES (\(bind: userID), \(bind: deviceID), \(bind: tokenHMACKey.digest(credentials.refreshCredential)), \(bind: issuedAt), \(bind: issuedAt.addingTimeInterval(refreshCredentialLifetime)))").run()
        try await insertAccessToken(sql, credentials: credentials, issuedAt: issuedAt)
    }

    private func insertAccessToken(_ sql: any SQLDatabase, credentials: V2IssuedDeviceCredentials, issuedAt: Date) async throws {
        try await sql.raw("INSERT INTO im_v2.device_access_tokens (token_hmac, user_id, device_id, issued_at, expires_at) VALUES (\(bind: tokenHMACKey.digest(credentials.accessToken)), \(bind: credentialUUID(credentials.userID)), \(bind: credentialUUID(credentials.deviceID)), \(bind: issuedAt), \(bind: credentials.accessTokenExpiresAt))").run()
    }

    private func insertOperation(_ sql: any SQLDatabase, kind: String, requestRefreshHMAC: String?, operationID: UUID, credentials: V2IssuedDeviceCredentials, issuedAt: Date) async throws {
        let context = replayContext(userID: credentials.userID, deviceID: credentials.deviceID, operationID: operationID)
        try await sql.raw("INSERT INTO im_v2.device_credential_operations (device_id, operation_id, operation_kind, user_id, request_refresh_hmac, resulting_access_token_hmac, encrypted_access_token, encrypted_refresh_credential, access_token_expires_at, replay_expires_at, created_at) VALUES (\(bind: credentialUUID(credentials.deviceID)), \(bind: operationID), \(bind: kind), \(bind: credentialUUID(credentials.userID)), \(bind: requestRefreshHMAC), \(bind: tokenHMACKey.digest(credentials.accessToken)), \(bind: try replayEnvelopeKey.seal(credentials.accessToken, authenticating: context)), \(bind: try replayEnvelopeKey.seal(credentials.refreshCredential, authenticating: context)), \(bind: credentials.accessTokenExpiresAt), \(bind: issuedAt.addingTimeInterval(replayWindow)), \(bind: issuedAt))").run()
    }

    private func credentials(from operation: CredentialOperationRow, request: V2TrustedDeviceRegistration) throws -> V2IssuedDeviceCredentials {
        let userID = try UserID(operation.userID.uuidString), deviceID = try DeviceID(operation.deviceID.uuidString)
        let context = replayContext(userID: userID, deviceID: deviceID, operationID: request.operationID)
        return try .init(userID: userID, deviceID: deviceID, accessToken: replayEnvelopeKey.open(operation.encryptedAccessToken, authenticating: context), accessTokenExpiresAt: operation.accessTokenExpiresAt, refreshCredential: replayEnvelopeKey.open(operation.encryptedRefreshCredential, authenticating: context))
    }

    private func credentials(from operation: CredentialOperationRow, request: V2DeviceCredentialRefresh) throws -> V2IssuedDeviceCredentials {
        let userID = try UserID(operation.userID.uuidString), deviceID = try DeviceID(operation.deviceID.uuidString)
        let context = replayContext(userID: userID, deviceID: deviceID, operationID: request.operationID)
        return try .init(userID: userID, deviceID: deviceID, accessToken: replayEnvelopeKey.open(operation.encryptedAccessToken, authenticating: context), accessTokenExpiresAt: operation.accessTokenExpiresAt, refreshCredential: replayEnvelopeKey.open(operation.encryptedRefreshCredential, authenticating: context))
    }

    private func credentialOperation(_ sql: any SQLDatabase, deviceID: UUID, operationID: UUID) async throws -> CredentialOperationRow? {
        try await sql.raw("SELECT device_id, operation_id, operation_kind, user_id, request_refresh_hmac, encrypted_access_token, encrypted_refresh_credential, access_token_expires_at, replay_expires_at FROM im_v2.device_credential_operations WHERE device_id = \(bind: deviceID) AND operation_id = \(bind: operationID)").first(decoding: CredentialOperationRow.self)
    }

    private func revokeDevice(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID, at now: Date) async throws {
        try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, \(bind: now)) WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)").run()
        try await sql.raw("UPDATE im_v2.device_refresh_sessions SET revoked_at = COALESCE(revoked_at, \(bind: now)) WHERE device_id = \(bind: deviceID)").run()
        try await sql.raw("UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, \(bind: now)) WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)").run()
        try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) VALUES (\(bind: userID), \(bind: deviceID), \(bind: now)) ON CONFLICT (device_id) DO NOTHING").run()
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

    private func activeDeviceCount(_ sql: any SQLDatabase, userID: UUID) async throws -> Int {
        try await sql.raw("SELECT COUNT(*)::integer AS count FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND revoked_at IS NULL")
            .first(decoding: DeviceCountRow.self)?.count ?? 0
    }

    private func newDeviceRegistrationRetryAfter(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws -> Int? {
        guard let row = try await sql.raw("SELECT window_started_at, successful_registrations FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: userID) FOR UPDATE")
            .first(decoding: DeviceRegistrationRateLimitRow.self)
        else { return nil }
        let elapsed = max(0, now.timeIntervalSince(row.windowStartedAt))
        guard elapsed < registrationPolicy.window,
              row.successfulRegistrations >= registrationPolicy.maximumNewDevicesPerWindow
        else { return nil }
        return max(1, Int(ceil(registrationPolicy.window - elapsed)))
    }

    private func recordSuccessfulNewDeviceRegistration(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws {
        let windowSeconds = Int64(registrationPolicy.window.rounded(.towardZero))
        try await sql.raw("""
            INSERT INTO im_v2.device_registration_rate_limits
                (user_id, window_started_at, successful_registrations, updated_at)
            VALUES (\(bind: userID), \(bind: now), 1, \(bind: now))
            ON CONFLICT (user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at
                           + \(bind: windowSeconds) * INTERVAL '1 second' <= \(bind: now)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.device_registration_rate_limits.window_started_at
                END,
                successful_registrations = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at
                           + \(bind: windowSeconds) * INTERVAL '1 second' <= \(bind: now)
                    THEN 1
                    ELSE im_v2.device_registration_rate_limits.successful_registrations + 1
                END,
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    private func normalizedMetadata(_ metadata: V2DeviceRegistrationMetadata) throws -> (displayName: String, platform: String) {
        func normalize(_ value: String, fallback: String) -> String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? fallback : normalized
        }
        let displayName = normalize(metadata.displayName, fallback: V2DeviceRegistrationMetadata.unknown.displayName)
        let platform = normalize(metadata.platform, fallback: V2DeviceRegistrationMetadata.unknown.platform)
        guard displayName.utf8.count <= 128, platform.utf8.count <= 64,
              !displayName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !platform.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2DeviceCredentialServiceError.malformedPersistence }
        return (displayName, platform)
    }

    private func replayContext(userID: UserID, deviceID: DeviceID, operationID: UUID) -> Data {
        Data("v2-credential-replay|\(userID.rawValue)|\(deviceID.rawValue)|\(operationID.uuidString)".utf8)
    }
}

private struct DeviceRow: Decodable {
    let userID: UUID
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case revokedAt = "revoked_at" }
}

private struct DeviceCountRow: Decodable { let count: Int }

private struct DeviceRegistrationRateLimitRow: Decodable {
    let windowStartedAt: Date
    let successfulRegistrations: Int
    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case successfulRegistrations = "successful_registrations"
    }
}

private struct RefreshSessionRow: Decodable {
    let refreshHMAC: String
    let expiresAt: Date
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case refreshHMAC = "refresh_hmac"; case expiresAt = "expires_at"; case revokedAt = "revoked_at" }
}

private struct CredentialOperationRow: Decodable {
    let deviceID: UUID
    let operationID: UUID
    let operationKind: String
    let userID: UUID
    let requestRefreshHMAC: String?
    let encryptedAccessToken: String
    let encryptedRefreshCredential: String
    let accessTokenExpiresAt: Date
    let replayExpiresAt: Date
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"; case operationID = "operation_id"; case operationKind = "operation_kind"
        case userID = "user_id"; case requestRefreshHMAC = "request_refresh_hmac"
        case encryptedAccessToken = "encrypted_access_token"; case encryptedRefreshCredential = "encrypted_refresh_credential"
        case accessTokenExpiresAt = "access_token_expires_at"; case replayExpiresAt = "replay_expires_at"
    }
}

private func credentialUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceCredentialServiceError.malformedPersistence }
    return value
}
