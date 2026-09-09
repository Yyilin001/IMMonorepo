import Crypto
import Fluent
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

/// A safe-to-display description of an active account session. The opaque
/// device ID is returned only to its owning account and is never logged.
public struct V2DeviceSession: Equatable, Sendable {
    public let deviceID: DeviceID
    public let displayName: String
    public let platform: String
    public let createdAt: Date
    public let lastActiveAt: Date

    public init(deviceID: DeviceID, displayName: String, platform: String, createdAt: Date, lastActiveAt: Date) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

public struct V2DeviceSessionPage: Equatable, Sendable {
    public let sessions: [V2DeviceSession]
    public let nextCursor: String?

    public init(sessions: [V2DeviceSession], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

public enum V2DeviceSessionMutationOutcome: Equatable, Sendable {
    case applied
    case idempotent
    case targetUnavailable
}

public enum V2DeviceSessionServiceError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedPersistence
    case unavailable
}

public enum V2DeviceRevocationCapabilityOutcome: Equatable, Sendable {
    case applied
    case idempotent
    case invalidCredential
    case expired
    case operationConflict
}

public protocol V2DeviceRevocationCapabilityRedeeming: Sendable {
    func redeem(_ credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationCapabilityOutcome
}

struct V2IssuedDeviceRevocationCapability: Sendable {
    let credential: V2DeviceRevocationCredential
    let expiresAt: Date
}

/// Account-edge session management. Mutations hold the same account advisory
/// lock as credential issue/refresh, revoke all device credentials in one
/// transaction, and append a durable revocation event for every gateway.
public protocol V2DeviceSessionManaging: Sendable {
    func sessions(for userID: UserID, cursor: String?, pageSize: Int) async throws -> V2DeviceSessionPage
    func revokeDevice(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        targetDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome
    func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) async throws -> V2DeviceSessionMutationOutcome
    func revokeOtherDevices(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome
}

public struct V2PostgresDeviceSessionService: V2DeviceSessionManaging, V2DeviceRevocationCapabilityRedeeming, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// Called within the credential issuer's transaction. Reacquiring the same
    /// transaction-scoped account lock preserves the shared writer lock order.
    /// Only the digest is retained here. The caller must persist the plaintext
    /// with the bounded encrypted registration replay before committing.
    static func issueRevocationCapability(
        on sql: any SQLDatabase, userID: UserID, deviceID: DeviceID, at now: Date
    ) async throws -> V2IssuedDeviceRevocationCapability {
        let userUUID = try deviceSessionUUID(userID), deviceUUID = try deviceSessionUUID(deviceID)
        guard v2PostgresTimestampCanEncode(now) else { throw V2DeviceSessionServiceError.unavailable }
        try await Self.lockAccountState(sql, userID: userUUID)
        guard let device = try await sql.raw("SELECT created_at AS session_created_at, session_expires_at FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID) AND revoked_at IS NULL AND session_expires_at > \(bind: now) FOR UPDATE").first(decoding: CapabilitySessionRow.self)
        else { throw V2DeviceSessionServiceError.invalidRequest }
        guard v2PostgresTimestampCanEncode(device.sessionCreatedAt),
              v2PostgresTimestampCanEncode(device.sessionExpiresAt) else { throw V2DeviceSessionServiceError.malformedPersistence }
        guard v2PostgresFutureTimestamp(now: device.sessionExpiresAt, interval: 600) != nil else {
            throw V2DeviceSessionServiceError.unavailable
        }
        let credential = V2DeviceRevocationCredential.generate()
        // Preserve the device's exact SQL timestamps for the binding and grace
        // period. Date round trips can lose microseconds even at ordinary dates.
        guard let issued = try await sql.raw("""
            INSERT INTO im_v2.device_revocation_capabilities
                (user_id, device_id, credential_digest, session_created_at, session_expires_at, expires_at)
            SELECT user_id, device_id, \(bind: revocationDigest(credential)),
                   created_at, session_expires_at, session_expires_at + interval '10 minutes'
            FROM im_v2.auth_devices WHERE user_id=\(bind: userUUID) AND device_id=\(bind: deviceUUID)
            RETURNING expires_at
            """).first(decoding: CapabilityExpiryRow.self),
              v2PostgresTimestampCanEncode(issued.expiresAt) else { throw V2DeviceSessionServiceError.malformedPersistence }
        return .init(credential: credential, expiresAt: issued.expiresAt)
    }

    static func matchingRevocationCapability(on sql: any SQLDatabase, userID: UserID, deviceID: DeviceID,
        credential: V2DeviceRevocationCredential) async throws -> V2IssuedDeviceRevocationCapability? {
        guard let row = try await sql.raw("""
            SELECT capability.expires_at
            FROM im_v2.device_revocation_capabilities AS capability
            JOIN im_v2.auth_devices AS device USING (user_id, device_id)
            WHERE capability.user_id = \(bind: deviceSessionUUID(userID))
              AND capability.device_id = \(bind: deviceSessionUUID(deviceID))
              AND capability.credential_digest = \(bind: revocationDigest(credential))
              AND capability.session_created_at = device.created_at
              AND capability.session_expires_at = device.session_expires_at
            """).first(decoding: CapabilityExpiryRow.self) else { return nil }
        guard v2PostgresTimestampCanEncode(row.expiresAt) else { throw V2DeviceSessionServiceError.malformedPersistence }
        return .init(credential: credential, expiresAt: row.expiresAt)
    }

    public func redeem(_ credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationCapabilityOutcome {
        let digest = Self.revocationDigest(credential)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            // Find the target without taking a row lock: all writers acquire
            // the account lock before any device row lock.
            guard let target = try await sql.raw("SELECT user_id, device_id FROM im_v2.device_revocation_capabilities WHERE credential_digest = \(bind: digest)").first(decoding: CapabilityTargetRow.self)
            else { return .invalidCredential }
            try await Self.lockAccountState(sql, userID: target.userID)
            guard let row = try await sql.raw("""
                SELECT capability.expires_at
                FROM im_v2.device_revocation_capabilities AS capability
                JOIN im_v2.auth_devices AS device USING (user_id, device_id)
                WHERE capability.credential_digest = \(bind: digest)
                  AND capability.user_id = \(bind: target.userID)
                  AND capability.device_id = \(bind: target.deviceID)
                  AND capability.session_created_at = device.created_at
                  AND capability.session_expires_at = device.session_expires_at
                FOR UPDATE OF device, capability
                """).first(decoding: CapabilityExpiryRow.self)
            else { return .invalidCredential }
            // Observe time after waiting for locks. Ordinary authentication,
            // account disablement and token-key rotation are irrelevant here.
            let occurredAt = now()
            guard v2PostgresTimestampCanEncode(occurredAt) else { throw V2DeviceSessionServiceError.unavailable }
            guard v2PostgresTimestampCanEncode(row.expiresAt) else { throw V2DeviceSessionServiceError.malformedPersistence }
            guard row.expiresAt > occurredAt else { return .expired }
            if let prior = try await operation(sql, actorUserID: target.userID, operationID: operationID) {
                guard prior.kind == SessionOperationKind.revokeDevice.rawValue,
                      prior.targetDeviceID == target.deviceID else { return .operationConflict }
                return .idempotent
            }
            try await Self.revokeSession(sql, userID: target.userID, deviceID: target.deviceID, at: occurredAt)
            try await insertOperation(sql, actorUserID: target.userID, operationID: operationID, kind: .revokeDevice, targetDeviceID: target.deviceID, at: occurredAt)
            return .applied
        }
    }

    private static func revocationDigest(_ credential: V2DeviceRevocationCredential) -> String {
        SHA256.hash(data: Data(credential.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func sessions(for userID: UserID, cursor: String?, pageSize: Int) async throws -> V2DeviceSessionPage {
        guard (1 ... 100).contains(pageSize) else { throw V2DeviceSessionServiceError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
        let userUUID = try deviceSessionUUID(userID)
        let cursorValue = try cursor.map(deviceSessionCursor)
        let observedAt = now()
        guard v2PostgresTimestampCanEncode(observedAt) else { throw V2DeviceSessionServiceError.unavailable }
        let rows: [DeviceSessionRow]
        if let cursorValue {
            rows = try await sql.raw("SELECT device_id, display_name, platform, created_at, last_active_at, last_active_at AS cursor_timestamp FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) AND revoked_at IS NULL AND session_expires_at > \(bind: observedAt) AND (last_active_at < \(bind: cursorValue.lastActiveAt) OR (last_active_at = \(bind: cursorValue.lastActiveAt) AND device_id > \(bind: cursorValue.deviceID))) ORDER BY last_active_at DESC, device_id LIMIT \(bind: pageSize + 1)").all(decoding: DeviceSessionRow.self)
        } else {
            rows = try await sql.raw("SELECT device_id, display_name, platform, created_at, last_active_at, last_active_at AS cursor_timestamp FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) AND revoked_at IS NULL AND session_expires_at > \(bind: observedAt) ORDER BY last_active_at DESC, device_id LIMIT \(bind: pageSize + 1)").all(decoding: DeviceSessionRow.self)
        }
        let pageRows = Array(rows.prefix(pageSize))
        let sessions: [V2DeviceSession] = try pageRows.map { row in
            guard v2PostgresTimestampCanEncode(row.createdAt), v2PostgresTimestampCanEncode(row.lastActiveAt) else {
                throw V2DeviceSessionServiceError.malformedPersistence
            }
            return try V2DeviceSession(
                deviceID: .init(row.deviceID.uuidString),
                displayName: row.displayName,
                platform: row.platform,
                createdAt: row.createdAt,
                lastActiveAt: row.lastActiveAt
            )
        }
        let nextCursor = rows.count > pageSize ? try pageRows.last.map {
            try deviceSessionCursorString(lastActiveAt: $0.lastActiveAt, deviceID: $0.deviceID, timestamp: $0.cursorTimestamp)
        } : nil
        return .init(sessions: sessions, nextCursor: nextCursor)
    }

    public func revokeDevice(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        targetDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome {
        guard targetDeviceID != currentDeviceID else { return .targetUnavailable }
        return try await mutate(
            actorUserID: actorUserID,
            currentDeviceID: currentDeviceID,
            targetDeviceID: targetDeviceID,
            operationID: operationID,
            kind: .revokeDevice
        )
    }

    /// Current-device logout shares the credential-issue/refresh account lock.
    /// Device IDs are never revived: a later login needs a new device ID.
    /// The HTTP boundary requires a live credential; this journal supports
    /// requests authenticated concurrently before the first commit, not an
    /// unauthenticated or offline revocation capability.
    public func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) async throws -> V2DeviceSessionMutationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            let userUUID = try deviceSessionUUID(actorUserID)
            let deviceUUID = try deviceSessionUUID(currentDeviceID)
            try await Self.lockAccountState(sql, userID: userUUID)
            if let prior = try await operation(sql, actorUserID: userUUID, operationID: operationID) {
                guard prior.kind == SessionOperationKind.revokeDevice.rawValue, prior.targetDeviceID == deviceUUID else { return .targetUnavailable }
                return .idempotent
            }
            guard try await isCurrentDeviceActive(sql, userID: userUUID, deviceID: deviceUUID) else { return .targetUnavailable }
            let occurredAt = now()
            try await Self.revokeSession(sql, userID: userUUID, deviceID: deviceUUID, at: occurredAt)
            try await insertOperation(sql, actorUserID: userUUID, operationID: operationID, kind: .revokeDevice, targetDeviceID: deviceUUID, at: occurredAt)
            return .applied
        }
    }

    public func revokeOtherDevices(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            let userUUID = try deviceSessionUUID(actorUserID)
            let currentUUID = try deviceSessionUUID(currentDeviceID)
            try await Self.lockAccountState(sql, userID: userUUID)
            guard try await isCurrentDeviceActive(sql, userID: userUUID, deviceID: currentUUID) else { return .targetUnavailable }
            if let existing = try await operation(sql, actorUserID: userUUID, operationID: operationID) {
                guard existing.kind == SessionOperationKind.revokeOtherDevices.rawValue, existing.targetDeviceID == nil else {
                    return .targetUnavailable
                }
                return .idempotent
            }
            let occurredAt = now()
            try await revokeOtherDevices(sql, userID: userUUID, currentDeviceID: currentUUID, at: occurredAt)
            try await insertOperation(sql, actorUserID: userUUID, operationID: operationID, kind: .revokeOtherDevices, targetDeviceID: nil, at: occurredAt)
            return .applied
        }
    }

    private func mutate(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        targetDeviceID: DeviceID,
        operationID: UUID,
        kind: SessionOperationKind
    ) async throws -> V2DeviceSessionMutationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            let userUUID = try deviceSessionUUID(actorUserID)
            let currentUUID = try deviceSessionUUID(currentDeviceID)
            let targetUUID = try deviceSessionUUID(targetDeviceID)
            try await Self.lockAccountState(sql, userID: userUUID)
            guard try await isCurrentDeviceActive(sql, userID: userUUID, deviceID: currentUUID) else { return .targetUnavailable }
            if let existing = try await operation(sql, actorUserID: userUUID, operationID: operationID) {
                guard existing.kind == kind.rawValue, existing.targetDeviceID == targetUUID else { return .targetUnavailable }
                return .idempotent
            }
            guard try await isTargetActive(sql, userID: userUUID, deviceID: targetUUID) else { return .targetUnavailable }
            let occurredAt = now()
            try await Self.revokeSession(sql, userID: userUUID, deviceID: targetUUID, at: occurredAt)
            try await insertOperation(sql, actorUserID: userUUID, operationID: operationID, kind: kind, targetDeviceID: targetUUID, at: occurredAt)
            return .applied
        }
    }

    private func isCurrentDeviceActive(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        try await isTargetActive(sql, userID: userID, deviceID: deviceID)
    }

    private func isTargetActive(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        let observedAt = now()
        guard v2PostgresTimestampCanEncode(observedAt) else { throw V2DeviceSessionServiceError.unavailable }
        return try await sql.raw("SELECT 1 FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID) AND revoked_at IS NULL AND session_expires_at > \(bind: observedAt) FOR UPDATE").first() != nil
    }

    private func operation(_ sql: any SQLDatabase, actorUserID: UUID, operationID: UUID) async throws -> DeviceSessionOperationRow? {
        try await sql.raw("SELECT operation_kind, target_device_id FROM im_v2.device_session_operations WHERE actor_user_id = \(bind: actorUserID) AND operation_id = \(bind: operationID)").first(decoding: DeviceSessionOperationRow.self)
    }

    private func insertOperation(_ sql: any SQLDatabase, actorUserID: UUID, operationID: UUID, kind: SessionOperationKind, targetDeviceID: UUID?, at: Date) async throws {
        guard v2PostgresTimestampCanEncode(at) else { throw V2DeviceSessionServiceError.unavailable }
        try await sql.raw("INSERT INTO im_v2.device_session_operations (actor_user_id, operation_id, operation_kind, target_device_id, created_at) VALUES (\(bind: actorUserID), \(bind: operationID), \(bind: kind.rawValue), \(bind: targetDeviceID), \(bind: at))").run()
    }

    static func revokeSession(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID, at: Date) async throws {
        guard v2PostgresTimestampCanEncode(at) else { throw V2DeviceSessionServiceError.unavailable }
        try await sql.raw("""
            WITH revoked_device AS MATERIALIZED (
                UPDATE im_v2.auth_devices
                SET revoked_at = COALESCE(revoked_at, \(bind: at))
                WHERE user_id = \(bind: userID)
                  AND device_id = \(bind: deviceID)
                RETURNING device_id
            ), revoked_refresh_sessions AS (
                UPDATE im_v2.device_refresh_sessions AS session
                SET revoked_at = COALESCE(session.revoked_at, \(bind: at))
                FROM revoked_device
                WHERE session.device_id = revoked_device.device_id
                RETURNING session.device_id
            ), revoked_access_tokens AS (
                UPDATE im_v2.device_access_tokens AS token
                SET revoked_at = COALESCE(token.revoked_at, \(bind: at))
                FROM revoked_device
                WHERE token.user_id = \(bind: userID)
                  AND token.device_id = revoked_device.device_id
                RETURNING token.device_id
            ), disabled_push_endpoints AS (
                UPDATE im_v2.push_device_endpoints AS endpoint
                SET disabled_at = COALESCE(endpoint.disabled_at, \(bind: at))
                FROM revoked_device
                WHERE endpoint.device_id = revoked_device.device_id
                RETURNING endpoint.device_id
            ), appended_revocation AS (
                INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
                SELECT \(bind: userID), device_id, \(bind: at)
                FROM revoked_device
                ON CONFLICT (device_id) DO NOTHING
                RETURNING device_id
            )
            SELECT
                (SELECT COUNT(*) FROM revoked_device) AS revoked_device_count,
                (SELECT COUNT(*) FROM revoked_refresh_sessions) AS revoked_refresh_count,
                (SELECT COUNT(*) FROM revoked_access_tokens) AS revoked_access_count,
                (SELECT COUNT(*) FROM disabled_push_endpoints) AS disabled_push_count,
                (SELECT COUNT(*) FROM appended_revocation) AS appended_revocation_count
            """).run()
    }

    private func revokeOtherDevices(_ sql: any SQLDatabase, userID: UUID, currentDeviceID: UUID, at: Date) async throws {
        guard v2PostgresTimestampCanEncode(at) else { throw V2DeviceSessionServiceError.unavailable }
        // Every data-modifying CTE consumes the same bounded set returned by
        // the auth-device update. This avoids materializing device IDs in the
        // application and turns N×5 serial database round trips into one.
        try await sql.raw("""
        WITH revoked_devices AS MATERIALIZED (
            UPDATE im_v2.auth_devices
            SET revoked_at = \(bind: at)
            WHERE user_id = \(bind: userID)
              AND device_id <> \(bind: currentDeviceID)
              AND revoked_at IS NULL
            RETURNING device_id
        ), revoked_refresh_sessions AS (
            UPDATE im_v2.device_refresh_sessions AS session
            SET revoked_at = COALESCE(session.revoked_at, \(bind: at))
            FROM revoked_devices
            WHERE session.device_id = revoked_devices.device_id
            RETURNING session.device_id
        ), revoked_access_tokens AS (
            UPDATE im_v2.device_access_tokens AS token
            SET revoked_at = COALESCE(token.revoked_at, \(bind: at))
            FROM revoked_devices
            WHERE token.user_id = \(bind: userID)
              AND token.device_id = revoked_devices.device_id
            RETURNING token.device_id
        ), disabled_push_endpoints AS (
            UPDATE im_v2.push_device_endpoints AS endpoint
            SET disabled_at = COALESCE(endpoint.disabled_at, \(bind: at))
            FROM revoked_devices
            WHERE endpoint.device_id = revoked_devices.device_id
            RETURNING endpoint.device_id
        ), appended_revocations AS (
            INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
            SELECT \(bind: userID), device_id, \(bind: at)
            FROM revoked_devices
            ON CONFLICT (device_id) DO NOTHING
            RETURNING device_id
        )
        SELECT
            (SELECT COUNT(*) FROM revoked_devices) AS revoked_device_count,
            (SELECT COUNT(*) FROM revoked_refresh_sessions) AS revoked_refresh_count,
            (SELECT COUNT(*) FROM revoked_access_tokens) AS revoked_access_count,
            (SELECT COUNT(*) FROM disabled_push_endpoints) AS disabled_push_count,
            (SELECT COUNT(*) FROM appended_revocations) AS appended_revocation_count
        """).run()
    }

    private static func lockAccountState(_ sql: any SQLDatabase, userID: UUID) async throws {
        let key = "account-state:" + userID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
}

private enum SessionOperationKind: String { case revokeDevice = "revoke_device"; case revokeOtherDevices = "revoke_other_devices" }
private struct DeviceSessionRow: Decodable { let deviceID: UUID; let displayName: String; let platform: String; let createdAt: Date; let lastActiveAt: Date; let cursorTimestamp: DeviceSessionCursorTimestamp; enum CodingKeys: String, CodingKey { case deviceID = "device_id"; case displayName = "display_name"; case platform; case createdAt = "created_at"; case lastActiveAt = "last_active_at"; case cursorTimestamp = "cursor_timestamp" } }
private struct DeviceSessionOperationRow: Decodable { let kind: String; let targetDeviceID: UUID?; enum CodingKeys: String, CodingKey { case kind = "operation_kind"; case targetDeviceID = "target_device_id" } }
private struct CapabilitySessionRow: Decodable {
    let sessionCreatedAt: Date
    let sessionExpiresAt: Date
    enum CodingKeys: String, CodingKey { case sessionCreatedAt = "session_created_at"; case sessionExpiresAt = "session_expires_at" }
}
private struct CapabilityTargetRow: Decodable {
    let userID: UUID
    let deviceID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case deviceID = "device_id" }
}
private struct CapabilityExpiryRow: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
private struct DeviceSessionCursor: Codable {
    let lastActiveAt: Date
    let deviceID: UUID
    let lastActiveAtMicroseconds: Int64?
}

private func deviceSessionCursor(_ value: String) throws -> (lastActiveAt: DeviceSessionCursorTimestamp, deviceID: UUID) {
    guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(DeviceSessionCursor.self, from: data),
          v2PostgresTimestampCanEncode(cursor.lastActiveAt) else {
        throw V2DeviceSessionServiceError.invalidRequest
    }
    // Legacy cursors stored a Date. Round its approximation to the closest
    // database microsecond instead of truncating a value such as 0.999999.
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard let microseconds = cursor.lastActiveAtMicroseconds ?? Int64(exactly: (cursor.lastActiveAt.timeIntervalSince(epoch) * 1_000_000).rounded()),
          v2PostgresTimestampMicrosecondsCanEncode(microseconds) else {
        throw V2DeviceSessionServiceError.invalidRequest
    }
    return (.init(microseconds: microseconds), cursor.deviceID)
}

private func deviceSessionCursorString(lastActiveAt: Date, deviceID: UUID, timestamp: DeviceSessionCursorTimestamp) throws -> String {
    try JSONEncoder().encode(DeviceSessionCursor(lastActiveAt: lastActiveAt, deviceID: deviceID, lastActiveAtMicroseconds: timestamp.microseconds)).base64EncodedString()
}

/// Pagination must preserve the database's exact comparison key. Passing a
/// timestamp through Date loses microseconds at some epochs and can skip ties.
private struct DeviceSessionCursorTimestamp: Codable, PostgresNonThrowingEncodable, PostgresDecodable {
    let microseconds: Int64
    static var psqlType: PostgresDataType { .timestamptz }
    static var psqlFormat: PostgresFormat { .binary }

    init(microseconds: Int64) { self.microseconds = microseconds }

    init<Decoder: PostgresJSONDecoder>(from buffer: inout ByteBuffer, type: PostgresDataType, format: PostgresFormat, context: PostgresDecodingContext<Decoder>) throws {
        guard type == .timestamptz, format == .binary,
              buffer.readableBytes == 8, let value = buffer.readInteger(as: Int64.self) else {
            throw PostgresDecodingError.Code.failure
        }
        microseconds = value
    }

    func encode<Encoder: PostgresJSONEncoder>(into buffer: inout ByteBuffer, context: PostgresEncodingContext<Encoder>) {
        buffer.writeInteger(microseconds)
    }
}

private func deviceSessionUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceSessionServiceError.malformedPersistence }
    return value
}
