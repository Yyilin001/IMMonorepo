import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 基于 PostgreSQL 的设备可用性检查实现。
public struct V2PostgresDeviceAvailabilityChecker: V2DeviceAvailabilityChecking {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    /// 查询设备是否仍然有效。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    /// - Returns: 设备未吊销、会话未过期且账号未停用时为 `true`。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2DeviceSnapshotResetError/malformedPersistence``。
    public func isAvailable(userID: UserID, deviceID: DeviceID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw V2DeviceSnapshotResetError.unavailable
        }
        return try await sql.raw("""
            SELECT 1
            FROM im_v2.auth_devices
            WHERE user_id = \(bind: v2PersistenceUUID(userID, invalid: V2DeviceSnapshotResetError.malformedPersistence))
              AND device_id = \(bind: v2PersistenceUUID(deviceID, invalid: V2DeviceSnapshotResetError.malformedPersistence))
              AND revoked_at IS NULL AND session_expires_at > clock_timestamp()
            """).first() != nil
    }
}

/// 只创建持久化构建与分配状态的设备快照重置服务。
///
/// 分页物化由 `PostgresV2SnapshotArtifactBuilder` 负责，因此该运维请求的调用栈与 HTTP 响应
/// 生命周期内都不会持有用户的完整当前投影。
public struct V2PostgresDeviceSnapshotResetService: V2DeviceSnapshotResetting, Sendable {
    private let registry: any V2UserShardStorageResolving
    private let deviceAvailability: any V2DeviceAvailabilityChecking
    private let routeFence: any V2UserShardRouteFencing
    private let coLocatedControlBuckets: Set<String>
    private let capabilityProfile: String
    private let capabilityLifetime: TimeInterval
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        registry: any V2UserShardStorageResolving,
        deviceAvailability: any V2DeviceAvailabilityChecking,
        routeFence: any V2UserShardRouteFencing,
        coLocatedControlBuckets: Set<String> = [],
        capabilityProfile: String,
        capabilityLifetime: TimeInterval = 86_400,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let normalized = capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, capabilityLifetime > 0 else { throw V2DeviceSnapshotResetError.unavailable }
        self.registry = registry
        self.deviceAvailability = deviceAvailability; self.routeFence = routeFence
        self.coLocatedControlBuckets = coLocatedControlBuckets; self.capabilityProfile = normalized
        self.capabilityLifetime = capabilityLifetime; self.makeUUID = makeUUID; self.now = now
    }

    /// 暂存一次设备快照重置。
    ///
    /// 先确认设备可用且不存在待处理重置，再写入构建与分配状态；
    /// 同一操作标识重试会命中既有产物并返回其当前状态。
    ///
    /// - Parameter command: 重置请求。
    /// - Returns: 重置结果。
    /// - Throws: 设备不可用时抛出 ``V2DeviceSnapshotResetError/deviceUnavailable``；
    ///   已有待处理重置时抛出 ``V2DeviceSnapshotResetError/resetAlreadyPending``；
    ///   持久化异常时抛出 ``V2DeviceSnapshotResetError/malformedPersistence``。
    public func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult {
        guard try await deviceAvailability.isAvailable(
            userID: command.userID,
            deviceID: command.deviceID
        ) else {
            throw V2DeviceSnapshotResetError.deviceUnavailable
        }
        return try await routeFence.withCurrentRoute(for: command.userID) { route, fencedDatabase in
            var location = try registry.location(for: route.bucket)
            if coLocatedControlBuckets.contains(route.bucket) {
                location = try .init(bucket: location.bucket, database: fencedDatabase, schema: location.schema)
            }
            return try await stage(command, at: location)
        }
    }

    private func stage(_ command: V2DeviceSnapshotResetCommand, at location: V2UserShardStorageLocation) async throws -> V2DeviceSnapshotResetResult {
        let userUUID = try v2PersistenceUUID(command.userID, invalid: V2DeviceSnapshotResetError.malformedPersistence)
        let deviceUUID = try v2PersistenceUUID(command.deviceID, invalid: V2DeviceSnapshotResetError.malformedPersistence)
        let currentTime = now()
        return try await location.database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSnapshotResetError.unavailable }
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(hashtextextended(
                    CONCAT(\(bind: userUUID), ':', \(bind: deviceUUID)), 684927
                ))
                """).run()
            guard try await sql.raw("""
                SELECT 1
                FROM \(unsafeRaw: location.schema).revoked_device_projection_tombstones
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).first() == nil else {
                throw V2DeviceSnapshotResetError.deviceUnavailable
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).device_sync_cursors
                    (user_id, device_id, state, reset_generation)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), 'ready', 1)
                ON CONFLICT (user_id, device_id) DO NOTHING
                """).run()
            guard let cursor = try await sql.raw("""
                SELECT state, reset_generation
                FROM \(unsafeRaw: location.schema).device_sync_cursors
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                FOR UPDATE
                """).first(decoding: ResetCursorRow.self) else {
                throw V2DeviceSnapshotResetError.malformedPersistence
            }
            // 只有在设备游标上完成串行化后才复查，
            // 使同一操作 ID 的并发重试保持幂等，
            // 而非被报告为第二次待处理重置。
            if let existing = try await existing(
                operationID: command.operationID, userID: userUUID,
                deviceID: deviceUUID, schema: location.schema, sql: sql
            ) {
                switch existing.state {
                case "preparing":
                    return .init(generation: try unsigned(existing.generation), state: .preparing, wasIdempotent: true)
                case "ready", "acknowledged":
                    return .init(generation: try unsigned(existing.generation), state: .ready, wasIdempotent: true)
                default:
                    throw V2DeviceSnapshotResetError.unavailable
                }
            }
            // 构建失败或过期时有意不保留有效分配，
            // 但不可变产物仍占用操作 ID。
            if try await artifactExists(
                operationID: command.operationID, schema: location.schema, sql: sql
            ) {
                throw V2DeviceSnapshotResetError.unavailable
            }
            guard cursor.state == "ready" else {
                throw V2DeviceSnapshotResetError.resetAlreadyPending
            }
            // 重放既有分配只报告持久化状态。
            // 创建新分配时须有可用时钟和新的截止时间。
            guard let expiresAt = v2PostgresFutureTimestamp(now: currentTime, interval: capabilityLifetime) else {
                throw V2DeviceSnapshotResetError.unavailable
            }
            let watermark = try await sql.raw("""
                SELECT COALESCE(next_sequence, 0) AS value
                FROM \(unsafeRaw: location.schema).user_sync_sequences
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: ResetWatermarkRow.self)?.value ?? 0
            guard watermark >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
            let (generation, overflow) = cursor.generation.addingReportingOverflow(1)
            guard !overflow, generation > 1 else {
                throw V2DeviceSnapshotResetError.malformedPersistence
            }
            // 没有同步事件的用户仍需要检查点记录；
            // 构建器有意将该记录用作有界认领和围栏。
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).user_projection_checkpoints
                    (user_id, projected_sequence, updated_at)
                VALUES (\(bind: userUUID), 0, \(bind: currentTime))
                ON CONFLICT (user_id) DO NOTHING
                """).run()
            let projectedSequence = try await sql.raw("""
                SELECT projected_sequence AS value
                FROM \(unsafeRaw: location.schema).user_projection_checkpoints
                WHERE user_id = \(bind: userUUID)
                FOR UPDATE
                """).first(decoding: ResetWatermarkRow.self)?.value ?? 0
            guard projectedSequence >= watermark else {
                // 后台投影器会追上进度；尚未暂存任何内容，
                // 因此之后沿用同一操作 ID 重试仍安全。
                throw V2DeviceSnapshotResetError.unavailable
            }
            let initialDigest = V2SnapshotV3Digest.initial(baseSequence: UInt64(watermark), capabilityProfile: capabilityProfile)
            let nextToken = makeUUID().uuidString
            let receipt = makeUUID().uuidString
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence, schema_version,
                     capability_profile, state, rolling_digest, expires_at, created_at)
                VALUES (\(bind: command.operationID), \(bind: userUUID), \(bind: watermark), \(bind: projectedSequence),
                        \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion)),
                        \(bind: capabilityProfile), 'building', \(bind: initialDigest),
                        \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: generation),
                        \(bind: command.operationID), 'preparing', \(bind: nextToken),
                        \(bind: receipt), \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).sync_tokens
                    (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES (\(bind: nextToken), \(bind: userUUID), \(bind: deviceUUID),
                        \(bind: generation), \(bind: watermark), \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: location.schema).device_sync_cursors
                SET state = 'reset_preparing', reset_generation = \(bind: generation),
                    pending_snapshot_id = \(bind: command.operationID),
                    pending_base_sequence = \(bind: watermark),
                    pending_snapshot_expires_at = \(bind: expiresAt)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
            return .init(generation: try unsigned(generation), state: .preparing, wasIdempotent: false)
        }
    }

    private func existing(operationID: UUID, userID: UUID, deviceID: UUID, schema: String, sql: any SQLDatabase) async throws -> ExistingResetRow? {
        try await sql.raw("""
            SELECT reset.reset_generation, reset.state
            FROM \(unsafeRaw: schema).device_snapshot_resets AS reset
            WHERE reset.snapshot_id = \(bind: operationID) AND reset.user_id = \(bind: userID)
              AND reset.device_id = \(bind: deviceID)
            """).first(decoding: ExistingResetRow.self)
    }

    private func artifactExists(operationID: UUID, schema: String, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM \(unsafeRaw: schema).sync_snapshot_artifacts
            WHERE snapshot_id = \(bind: operationID)
            """).first() != nil
    }
}

private struct ExistingResetRow: Decodable {
    let generation: Int64; let state: String
    enum CodingKeys: String, CodingKey { case generation = "reset_generation", state }
}
private struct ResetCursorRow: Decodable {
    let state: String; let generation: Int64
    enum CodingKeys: String, CodingKey { case state, generation = "reset_generation" }
}
private struct ResetWatermarkRow: Decodable { let value: Int64 }

private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return UInt64(value)
}
