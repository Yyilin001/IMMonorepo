import Fluent
import Foundation
import IMV2Core
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
    func revokeOtherDevices(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome
}

public struct V2PostgresDeviceSessionService: V2DeviceSessionManaging, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    public func sessions(for userID: UserID, cursor: String?, pageSize: Int) async throws -> V2DeviceSessionPage {
        guard (1 ... 100).contains(pageSize) else { throw V2DeviceSessionServiceError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
        let userUUID = try deviceSessionUUID(userID)
        let cursorValue = try cursor.map(deviceSessionCursor)
        let rows: [DeviceSessionRow]
        if let cursorValue {
            rows = try await sql.raw("SELECT device_id, display_name, platform, created_at, last_active_at FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) AND revoked_at IS NULL AND (last_active_at < \(bind: cursorValue.lastActiveAt) OR (last_active_at = \(bind: cursorValue.lastActiveAt) AND device_id > \(bind: cursorValue.deviceID))) ORDER BY last_active_at DESC, device_id LIMIT \(bind: pageSize + 1)").all(decoding: DeviceSessionRow.self)
        } else {
            rows = try await sql.raw("SELECT device_id, display_name, platform, created_at, last_active_at FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) AND revoked_at IS NULL ORDER BY last_active_at DESC, device_id LIMIT \(bind: pageSize + 1)").all(decoding: DeviceSessionRow.self)
        }
        let pageRows = Array(rows.prefix(pageSize))
        let sessions: [V2DeviceSession] = try pageRows.map { row in
            try V2DeviceSession(
                deviceID: .init(row.deviceID.uuidString),
                displayName: row.displayName,
                platform: row.platform,
                createdAt: row.createdAt,
                lastActiveAt: row.lastActiveAt
            )
        }
        let nextCursor = rows.count > pageSize ? try pageRows.last.map {
            try deviceSessionCursorString(lastActiveAt: $0.lastActiveAt, deviceID: $0.deviceID)
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

    public func revokeOtherDevices(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSessionServiceError.unavailable }
            let userUUID = try deviceSessionUUID(actorUserID)
            let currentUUID = try deviceSessionUUID(currentDeviceID)
            try await lockAccountState(sql, userID: userUUID)
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
            try await lockAccountState(sql, userID: userUUID)
            guard try await isCurrentDeviceActive(sql, userID: userUUID, deviceID: currentUUID) else { return .targetUnavailable }
            if let existing = try await operation(sql, actorUserID: userUUID, operationID: operationID) {
                guard existing.kind == kind.rawValue, existing.targetDeviceID == targetUUID else { return .targetUnavailable }
                return .idempotent
            }
            guard try await isTargetActive(sql, userID: userUUID, deviceID: targetUUID) else { return .targetUnavailable }
            let occurredAt = now()
            try await revoke(sql, userID: userUUID, deviceID: targetUUID, at: occurredAt)
            try await insertOperation(sql, actorUserID: userUUID, operationID: operationID, kind: kind, targetDeviceID: targetUUID, at: occurredAt)
            return .applied
        }
    }

    private func isCurrentDeviceActive(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        try await isTargetActive(sql, userID: userID, deviceID: deviceID)
    }

    private func isTargetActive(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.auth_devices WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID) AND revoked_at IS NULL FOR UPDATE").first() != nil
    }

    private func operation(_ sql: any SQLDatabase, actorUserID: UUID, operationID: UUID) async throws -> DeviceSessionOperationRow? {
        try await sql.raw("SELECT operation_kind, target_device_id FROM im_v2.device_session_operations WHERE actor_user_id = \(bind: actorUserID) AND operation_id = \(bind: operationID)").first(decoding: DeviceSessionOperationRow.self)
    }

    private func insertOperation(_ sql: any SQLDatabase, actorUserID: UUID, operationID: UUID, kind: SessionOperationKind, targetDeviceID: UUID?, at: Date) async throws {
        try await sql.raw("INSERT INTO im_v2.device_session_operations (actor_user_id, operation_id, operation_kind, target_device_id, created_at) VALUES (\(bind: actorUserID), \(bind: operationID), \(bind: kind.rawValue), \(bind: targetDeviceID), \(bind: at))").run()
    }

    private func revoke(_ sql: any SQLDatabase, userID: UUID, deviceID: UUID, at: Date) async throws {
        try await sql.raw("""
            WITH revoked_device AS MATERIALIZED (
                UPDATE im_v2.auth_devices
                SET revoked_at = \(bind: at)
                WHERE user_id = \(bind: userID)
                  AND device_id = \(bind: deviceID)
                  AND revoked_at IS NULL
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

    private func lockAccountState(_ sql: any SQLDatabase, userID: UUID) async throws {
        let key = "account-state:" + userID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
}

private enum SessionOperationKind: String { case revokeDevice = "revoke_device"; case revokeOtherDevices = "revoke_other_devices" }
private struct DeviceSessionRow: Decodable { let deviceID: UUID; let displayName: String; let platform: String; let createdAt: Date; let lastActiveAt: Date; enum CodingKeys: String, CodingKey { case deviceID = "device_id"; case displayName = "display_name"; case platform; case createdAt = "created_at"; case lastActiveAt = "last_active_at" } }
private struct DeviceSessionOperationRow: Decodable { let kind: String; let targetDeviceID: UUID?; enum CodingKeys: String, CodingKey { case kind = "operation_kind"; case targetDeviceID = "target_device_id" } }
private struct DeviceSessionCursor: Codable { let lastActiveAt: Date; let deviceID: UUID }

private func deviceSessionCursor(_ value: String) throws -> DeviceSessionCursor {
    guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(DeviceSessionCursor.self, from: data) else {
        throw V2DeviceSessionServiceError.invalidRequest
    }
    return cursor
}

private func deviceSessionCursorString(lastActiveAt: Date, deviceID: UUID) throws -> String {
    try JSONEncoder().encode(DeviceSessionCursor(lastActiveAt: lastActiveAt, deviceID: deviceID)).base64EncodedString()
}

private func deviceSessionUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceSessionServiceError.malformedPersistence }
    return value
}
