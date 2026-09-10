import Crypto
import Fluent
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

/// 可安全展示的活跃账号会话描述。
///
/// 不透明的设备标识只返回给其所属账号，且绝不写入日志。
public struct V2DeviceSession: Equatable, Sendable {
    /// 设备标识。
    public let deviceID: DeviceID
    /// 设备展示名称。
    public let displayName: String
    /// 设备平台。
    public let platform: String
    /// 会话创建时刻。
    public let createdAt: Date
    /// 最近活跃时刻。
    public let lastActiveAt: Date

    /// 保存会话描述。
    ///
    /// - Parameters:
    ///   - deviceID: 设备标识。
    ///   - displayName: 展示名称。
    ///   - platform: 设备平台。
    ///   - createdAt: 会话创建时刻。
    ///   - lastActiveAt: 最近活跃时刻。
    public init(deviceID: DeviceID, displayName: String, platform: String, createdAt: Date, lastActiveAt: Date) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

/// 会话列表分页。
public struct V2DeviceSessionPage: Equatable, Sendable {
    /// 本页会话。
    public let sessions: [V2DeviceSession]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: String?

    /// 保存会话分页。
    ///
    /// - Parameters:
    ///   - sessions: 本页会话。
    ///   - nextCursor: 下一页游标。
    public init(sessions: [V2DeviceSession], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// 会话变更结果。
public enum V2DeviceSessionMutationOutcome: Equatable, Sendable {
    /// 本次调用实际执行了变更。
    case applied
    /// 同一操作此前已执行。
    case idempotent
    /// 目标设备不存在或不属于该账号。
    case targetUnavailable
}

/// 设备会话服务错误。
public enum V2DeviceSessionServiceError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case malformedPersistence
    /// 存储或时刻当前不可用。
    case unavailable
}

/// 设备吊销凭据兑换结果。
public enum V2DeviceRevocationCapabilityOutcome: Equatable, Sendable {
    /// 本次调用实际完成了兑换。
    case applied
    /// 同一操作此前已兑换。
    case idempotent
    /// 凭据不合法。
    case invalidCredential
    /// 凭据已过期。
    case expired
    /// 同一操作标识已被不同载荷占用。
    case operationConflict
}

/// 设备吊销凭据兑换能力。
public protocol V2DeviceRevocationCapabilityRedeeming: Sendable {
    /// 兑换一份设备吊销凭据。
    ///
    /// - Parameters:
    ///   - credential: 待兑换的吊销凭据。
    ///   - operationID: 本次兑换的幂等操作标识。
    /// - Returns: 兑换结果。
    /// - Throws: 凭据非法或持久化失败时抛出。
    func redeem(_ credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationCapabilityOutcome
}

/// 已签发但尚未持久化的设备吊销凭据。
struct V2IssuedDeviceRevocationCapability: Sendable {
    /// 吊销凭据。
    let credential: V2DeviceRevocationCredential
    /// 凭据到期时刻。
    let expiresAt: Date
}

/// 账号边缘的会话管理能力。
///
/// 变更会持有与凭据签发/刷新相同的账号咨询锁，在单个事务内吊销该设备的全部凭据，
/// 并为每个网关追加一条持久化吊销事件。
public protocol V2DeviceSessionManaging: Sendable {
    /// 分页读取账号的活跃会话。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 会话分页。
    /// - Throws: 无权限或持久化失败时抛出。
    func sessions(for userID: UserID, cursor: String?, pageSize: Int) async throws -> V2DeviceSessionPage

    /// 吊销指定设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 发起操作的当前设备。
    ///   - targetDeviceID: 待吊销设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 目标不可用或持久化失败时抛出。
    func revokeDevice(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        targetDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome
    /// 吊销当前设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 当前设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) async throws -> V2DeviceSessionMutationOutcome

    /// 吊销除当前设备外的全部设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 保留的当前设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func revokeOtherDevices(
        actorUserID: UserID,
        currentDeviceID: DeviceID,
        operationID: UUID
    ) async throws -> V2DeviceSessionMutationOutcome
}

/// 基于 PostgreSQL 的账号会话服务。
public struct V2PostgresDeviceSessionService: V2DeviceSessionManaging, V2DeviceRevocationCapabilityRedeeming, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    /// 组合数据库与授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放设备、会话与吊销记录的数据库。
    ///   - now: 可注入的当前时刻读取函数。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// 在凭据签发者的事务内签发一份吊销凭据。
    ///
    /// 重新获取同一事务级账号锁可保持共享写入者的加锁顺序。此处只保存摘要；
    /// 调用方必须在提交之前把明文与有界的加密注册重放一并持久化。
    ///
    /// - Parameters:
    ///   - sql: 调用方事务使用的数据库连接。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    ///   - now: 签发时刻。
    /// - Returns: 已签发但尚未持久化的吊销凭据。
    /// - Throws: 标识非法或时刻不可编码时抛出
    ///   ``V2DeviceSessionServiceError/unavailable``。
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

    /// 按用户与设备查找该设备当前有效的吊销凭据。
    ///
    /// - Parameters:
    ///   - sql: 调用方事务使用的数据库连接。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    /// - Returns: 匹配的设备绑定凭据；不存在时返回 `nil`。
    /// - Throws: 时刻不可编码或标识非法时抛出
    ///   ``V2DeviceSessionServiceError/malformedPersistence``。
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

    /// 兑换一份设备吊销凭据。
    ///
    /// 事务先以摘要定位目标（不加行锁），再按「先账号锁、后设备行锁」的统一顺序加锁，
    /// 从而避免与签发、刷新路径形成反向等待。
    ///
    /// - Parameters:
    ///   - credential: 待兑换的吊销凭据。
    ///   - operationID: 本次兑换的幂等操作标识。
    /// - Returns: 兑换结果。
    /// - Throws: 连接不支持 SQL、时刻不可编码或持久化异常时抛出
    ///   ``V2DeviceSessionServiceError/unavailable``。
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

    /// 计算吊销凭据的持久化摘要。
    ///
    /// - Parameter credential: 待摘要的凭据。
    /// - Returns: 十六进制摘要字符串。
    private static func revocationDigest(_ credential: V2DeviceRevocationCredential) -> String {
        SHA256.hash(data: Data(credential.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 分页读取账号的活跃设备会话。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数，需落在允许范围内。
    /// - Returns: 会话分页；游标非法时按请求错误处理。
    /// - Throws: 参数越界时抛出 ``V2DeviceSessionServiceError/invalidRequest``；
    ///   持久化异常时抛出 ``V2DeviceSessionServiceError/malformedPersistence``。
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

    /// 吊销指定设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 发起操作的当前设备。
    ///   - targetDeviceID: 待吊销设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 目标不可用或持久化失败时抛出。
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

    /// 吊销当前设备。
    ///
    /// 当前设备登出与凭据签发/刷新共用同一账号锁。设备 ID 绝不会被复活：
    /// 之后的登录必须使用新的设备 ID。HTTP 边界要求有效凭据；
    /// 该日志服务于在首次提交前并发完成认证的请求，
    /// 而不是一种无需认证或可离线发起的吊销能力。
    ///
    /// 当前设备登出会与凭据签发/刷新共用账号锁；设备标识不会被重新启用，
    /// 之后的登录必须使用新的设备标识。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 当前设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
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

    /// 吊销除当前设备外的全部设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 保留的当前设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
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

    /// 在给定事务内吊销一个设备会话。
    ///
    /// - Parameters:
    ///   - sql: 调用方事务使用的数据库连接。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    ///   - at: 吊销时刻。
    /// - Throws: 时刻不可编码或持久化失败时抛出。
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

    /// 取得账号级咨询锁。
    ///
    /// - Parameters:
    ///   - sql: 调用方事务使用的数据库连接。
    ///   - userID: 目标用户。
    /// - Throws: 加锁失败时抛出。
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

/// 分页必须保留数据库的精确比较键。
///
/// 把时间戳经由 `Date` 传递会在某些纪元丢失微秒，从而可能跳过并列项。
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
