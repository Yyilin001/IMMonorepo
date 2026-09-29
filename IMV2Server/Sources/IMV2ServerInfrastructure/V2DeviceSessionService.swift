import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import FluentKit
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit


/// 已签发但尚未持久化的设备吊销凭据。
struct V2IssuedDeviceRevocationCapability: Sendable {
    /// 吊销凭据。
    let credential: V2DeviceRevocationCredential
    /// 凭据到期时刻。
    let expiresAt: Date
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
        // 为绑定和宽限期保留设备的精确 SQL 时间戳。
        // 即使是普通日期，Date 往返也可能损失微秒。
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
            // 查找目标时不取得行锁：所有写入方都先取得账号锁，
            // 再取得任何设备行锁。
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
            // 等锁后再读取时间。普通认证、账号禁用和令牌密钥轮换
            // 与此处无关。
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
            try deviceSessionCursorString(deviceID: $0.deviceID, timestamp: $0.cursorTimestamp)
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

private enum SessionOperationKind: String { case revokeDevice = "revoke_device" }
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
    let deviceID: UUID
    let lastActiveAtMicroseconds: Int64
}

private func deviceSessionCursor(_ value: String) throws -> (lastActiveAt: DeviceSessionCursorTimestamp, deviceID: UUID) {
    guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(DeviceSessionCursor.self, from: data),
          v2PostgresTimestampMicrosecondsCanEncode(cursor.lastActiveAtMicroseconds) else {
        throw V2DeviceSessionServiceError.invalidRequest
    }
    return (.init(microseconds: cursor.lastActiveAtMicroseconds), cursor.deviceID)
}

private func deviceSessionCursorString(deviceID: UUID, timestamp: DeviceSessionCursorTimestamp) throws -> String {
    try JSONEncoder().encode(DeviceSessionCursor(deviceID: deviceID, lastActiveAtMicroseconds: timestamp.microseconds)).base64EncodedString()
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


extension V2PostgresDeviceSessionService: V2RemoteDeviceRevocationManaging {
    public func remoteRevocationBaseline(actorUserID:UserID,currentDeviceID:DeviceID) async throws -> V2RemoteDeviceRevocationBaseline {
        try await database.transaction { tx in
            guard let sql=tx as? any SQLDatabase else {throw V2DeviceSessionServiceError.unavailable}
            let actor=try deviceSessionUUID(actorUserID),current=try deviceSessionUUID(currentDeviceID)
            try await Self.lockAccountState(sql,userID:actor)
            guard try await isCurrentDeviceActive(sql,userID:actor,deviceID:current) else {throw V2DeviceSessionServiceError.authorizationDenied}
            let issued=now()
            guard v2PostgresTimestampCanEncode(issued), try v2GatewayMilliseconds(issued) > 0,
                  v2PostgresTimestampCanEncode(issued.addingTimeInterval(120)) else { throw V2DeviceSessionServiceError.unavailable }
            // Admission owns bounded eager cleanup; the control-plane GC also
            // removes expired baselines. Permanent receipts are never included.
            try await sql.raw("DELETE FROM im_v2.remote_device_revocation_baselines WHERE baseline_id IN (SELECT baseline_id FROM im_v2.remote_device_revocation_baselines WHERE actor_user_id = \(bind:actor) AND expires_at <= \(bind:issued) ORDER BY expires_at LIMIT 256)").run()
            let activeBaselines=try await sql.raw("SELECT baseline::text AS value FROM im_v2.remote_device_revocation_baselines WHERE actor_user_id = \(bind:actor) AND expires_at > \(bind:issued) LIMIT 32").all(decoding:RemoteDeviceJSONRow.self)
            guard activeBaselines.count < 32 else {throw V2DeviceSessionServiceError.unavailable}
            let rows=try await sql.raw("SELECT device_id FROM im_v2.auth_devices WHERE user_id = \(bind:actor) AND device_id <> \(bind:current) AND revoked_at IS NULL AND session_expires_at > \(bind:issued) ORDER BY device_id LIMIT 257").all(decoding:RemoteDeviceTargetRow.self)
            guard rows.count<=V2RemoteDeviceRevocationBaseline.maximumTargets else {throw V2DeviceSessionServiceError.invalidRequest}
            guard let milliseconds=UInt64(exactly:try v2GatewayMilliseconds(issued)),
                  milliseconds<=UInt64(Int64.max)-120_000 else {throw V2DeviceSessionServiceError.invalidRequest}
            let value=try V2RemoteDeviceRevocationBaseline(id:UUID(),actorUserID:actorUserID,currentDeviceID:currentDeviceID,
                targetDeviceIDs:rows.map {DeviceID(uuid:$0.deviceID)}.sorted {$0.rawValue<$1.rawValue},issuedAtMilliseconds:milliseconds,expiresAtMilliseconds:milliseconds+120_000)
            let text=String(decoding:try JSONEncoder().encode(value),as:UTF8.self)
            try await sql.raw("INSERT INTO im_v2.remote_device_revocation_baselines(baseline_id,actor_user_id,current_device_id,baseline,expires_at) VALUES (\(bind:value.id),\(bind:actor),\(bind:current),\(bind:text)::jsonb,\(bind:issued.addingTimeInterval(120)))").run()
            return value
        }
    }
    public func submitRemoteRevocation(_ command:V2RemoteDeviceRevocationCommand) async throws -> V2RemoteDeviceRevocationResult {
        try await remoteRevocationTransaction(command) {sql,issued in
            let milliseconds=try v2GatewayMilliseconds(issued)
            guard milliseconds<command.firstSubmissionDeadlineMilliseconds else {return try await saveRemoteProof(command,outcome:.rejected(.deadlineExpired),now:issued,sql:sql)}
            guard let row=try await sql.raw("SELECT baseline::text AS value FROM im_v2.remote_device_revocation_baselines WHERE baseline_id = \(bind:command.baseline.id) AND actor_user_id = \(bind:command.baseline.actorUserID.uuidValue!) AND current_device_id = \(bind:command.baseline.currentDeviceID.uuidValue!) AND expires_at > \(bind:issued)").first(decoding:RemoteDeviceJSONRow.self),
                  try JSONDecoder().decode(V2RemoteDeviceRevocationBaseline.self,from:Data(row.value.utf8))==command.baseline else {return try await saveRemoteProof(command,outcome:.rejected(.baselineUnavailable),now:issued,sql:sql)}
            guard try await isCurrentDeviceActive(sql,userID:command.baseline.actorUserID.uuidValue!,deviceID:command.baseline.currentDeviceID.uuidValue!) else {return try await saveRemoteProof(command,outcome:.rejected(.authorizationDenied),now:issued,sql:sql)}
            // Immutable device IDs are never revived. Do not select a fresh 'others' set here.
            for target in command.targetDeviceIDs {try await Self.revokeSession(sql,userID:command.baseline.actorUserID.uuidValue!,deviceID:target.uuidValue!,at:issued)}
            return try await saveRemoteProof(command,outcome:.revoked,now:issued,sql:sql)
        }
    }
    public func recoverRemoteRevocation(_ request:V2RemoteDeviceRevocationRecoveryRequest) async throws -> V2RemoteDeviceRevocationResult {
        try await remoteRevocationTransaction(request.command) {sql,issued in
            request.action == .query ? .unresolved : try await saveRemoteProof(request.command,outcome:.closed,now:issued,sql:sql)
        }
    }
    private func remoteRevocationTransaction(_ command:V2RemoteDeviceRevocationCommand,operation:@escaping @Sendable(any SQLDatabase,Date) async throws -> V2RemoteDeviceRevocationResult) async throws -> V2RemoteDeviceRevocationResult {
        try await database.transaction {tx in
            guard let sql=tx as? any SQLDatabase else {throw V2DeviceSessionServiceError.unavailable}
            try await Self.lockAccountState(sql,userID:command.baseline.actorUserID.uuidValue!)
            if let row=try await sql.raw("SELECT receipt::text AS value FROM im_v2.remote_device_revocation_receipts WHERE actor_user_id = \(bind:command.baseline.actorUserID.uuidValue!) AND operation_id = \(bind:command.operationID)").first(decoding:RemoteDeviceJSONRow.self) {
                let receipt=try JSONDecoder().decode(V2RemoteDeviceRevocationReceipt.self,from:Data(row.value.utf8))
                return receipt.validates(command) ? .receipt(receipt):.fingerprintConflict
            }
            let issued = now()
            guard v2PostgresTimestampCanEncode(issued), try v2GatewayMilliseconds(issued) > 0 else { throw V2DeviceSessionServiceError.unavailable }
            return try await operation(sql,issued)
        }
    }
    private func saveRemoteProof(_ command:V2RemoteDeviceRevocationCommand,outcome:V2RemoteDeviceRevocationReceipt.Outcome,now:Date,sql:any SQLDatabase) async throws -> V2RemoteDeviceRevocationResult {
        guard let milliseconds=UInt64(exactly:try v2GatewayMilliseconds(now)) else {throw V2DeviceSessionServiceError.invalidRequest}
        let receipt=try V2RemoteDeviceRevocationReceipt(command:command,outcome:outcome,resolvedAtMilliseconds:milliseconds)
        let text=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("INSERT INTO im_v2.remote_device_revocation_receipts(actor_user_id,operation_id,current_device_id,receipt) VALUES (\(bind:command.baseline.actorUserID.uuidValue!),\(bind:command.operationID),\(bind:command.baseline.currentDeviceID.uuidValue!),\(bind:text)::jsonb)").run()
        return .receipt(receipt)
    }
}
private struct RemoteDeviceTargetRow:Decodable {let deviceID:UUID;enum CodingKeys:String,CodingKey {case deviceID="device_id"}}
private struct RemoteDeviceJSONRow:Decodable {let value:String}
