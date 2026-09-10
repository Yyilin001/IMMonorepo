import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 一次运维授权的重置请求。
///
/// 操作 UUID 同时是不可变产物标识，因此请求重试会收敛到同一次持久化构建，
/// 不会产生多份互不相同的快照产物。
public struct V2DeviceSnapshotResetCommand: Sendable {
    /// 本次重置的幂等操作标识。
    public let operationID: UUID
    /// 目标用户。
    public let userID: UserID
    /// 目标设备。
    public let deviceID: DeviceID

    /// 保存重置请求。
    ///
    /// - Parameters:
    ///   - operationID: 幂等操作标识。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    public init(operationID: UUID, userID: UserID, deviceID: DeviceID) {
        self.operationID = operationID
        self.userID = userID
        self.deviceID = deviceID
    }
}

/// 设备快照重置的构建状态。
public enum V2DeviceSnapshotResetBuildState: String, Codable, Equatable, Sendable {
    /// 产物仍在构建中。
    case preparing
    /// 产物已可被设备拉取。
    case ready
}

/// 设备快照重置结果。
public struct V2DeviceSnapshotResetResult: Equatable, Sendable {
    /// 重置后的同步代次。
    public let generation: UInt64
    /// 产物当前构建状态。
    public let state: V2DeviceSnapshotResetBuildState
    /// 本次调用是否命中既有结果。
    public let wasIdempotent: Bool

    /// 保存重置结果。
    ///
    /// - Parameters:
    ///   - generation: 同步代次。
    ///   - state: 构建状态。
    ///   - wasIdempotent: 是否命中既有结果。
    public init(generation: UInt64, state: V2DeviceSnapshotResetBuildState, wasIdempotent: Bool) {
        self.generation = generation; self.state = state; self.wasIdempotent = wasIdempotent
    }
}

/// 设备快照重置错误。
public enum V2DeviceSnapshotResetError: Error, Equatable, Sendable {
    /// 目标设备当前不可用。
    case deviceUnavailable
    /// 该设备已有待处理的重置。
    case resetAlreadyPending
    /// 持久化状态与预期结构不符。
    case malformedPersistence
    /// 依赖当前不可用。
    case unavailable
}

/// 设备快照重置的暂存能力。
public protocol V2DeviceSnapshotResetting: Sendable {
    /// 暂存一次设备快照重置。
    ///
    /// - Parameter command: 重置请求。
    /// - Returns: 重置结果。
    /// - Throws: 设备不可用、已有待处理重置或持久化失败时抛出。
    func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult
}

/// 设备可用性检查能力。
///
/// 设备凭据属于控制面权威，绝不能从用户投影分片推断；独立的用户分片库刻意不复制
/// `auth_devices`，因此该检查必须走控制面。
public protocol V2DeviceAvailabilityChecking: Sendable {
    /// 判断指定设备当前是否可用。
    ///
    /// - Parameters:
    ///   - userID: 设备归属用户。
    ///   - deviceID: 目标设备。
    /// - Returns: 设备未吊销且会话有效时为 `true`。
    /// - Throws: 存储不可用时抛出。
    func isAvailable(userID: UserID, deviceID: DeviceID) async throws -> Bool
}

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
            WHERE user_id = \(bind: snapshotResetUUID(userID))
              AND device_id = \(bind: snapshotResetUUID(deviceID))
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
        let userUUID = try snapshotResetUUID(command.userID)
        let deviceUUID = try snapshotResetUUID(command.deviceID)
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
            // Recheck only after serializing on the device cursor so
            // concurrent retries for the same operation ID are idempotent
            // rather than reported as a second pending reset.
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
            // Failed/expired builds deliberately have no live assignment, but
            // the immutable artifact still reserves the operation ID.
            if try await artifactExists(
                operationID: command.operationID, schema: location.schema, sql: sql
            ) {
                throw V2DeviceSnapshotResetError.unavailable
            }
            guard cursor.state == "ready" else {
                throw V2DeviceSnapshotResetError.resetAlreadyPending
            }
            // Replaying an existing assignment only reports durable state.
            // Require a usable clock and a new deadline when creating one.
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
            // A user with no sync events still needs a checkpoint row; the
            // builder intentionally uses that row as its bounded claim/fence.
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
                // The background projector will catch up; a later retry with
                // the same operation ID remains safe because nothing has
                // been staged yet.
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
private func snapshotResetUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return value
}
private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return UInt64(value)
}
