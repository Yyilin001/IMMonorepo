import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 私聊房间与陌生人偏好的 PostgreSQL 边界。
///
/// 以用户对为范围的咨询锁使「尚不存在私聊对」的场景可串行化：
/// 两个调用方并发发起同一会话时，不会凭空产生一个无人引用的孤立房间。
public struct PostgresV2DirectMessagingStore: Sendable {
    private let database: any Database
    private let identityReader: any V2DirectRoomIdentityReading
    private let projectionDelivery: any V2UserShardProjectionDelivering

    /// 组合数据库与当前用户分片投影投递器。
    ///
    /// - Parameters:
    ///   - database: 存放私聊房间、操作记录与偏好设置的数据库。
    ///   - projectionDelivery: 用于把控制面投影投递到当前用户分片的实现。
    public init(database: any Database, identityReader: any V2DirectRoomIdentityReading, projectionDelivery: any V2UserShardProjectionDelivering) {
        self.database = database
        self.identityReader = identityReader
        self.projectionDelivery = projectionDelivery
    }

    /// 打开或复用一对用户的私聊房间。
    ///
    /// 操作标识按发起者维度串行化，先取出锁再比对目标，使并发重试能看到已提交的房间与时间戳；
    /// 随后按用户对加锁、校验或创建房间，并把创建结果写入操作记录。
    ///
    /// - Parameters:
    ///   - command: 打开私聊房间命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 打开结果。
    /// - Throws: 标识非法、操作标识与目标不一致、准入不足或持久化失败时抛出。
    func applyOpen(command: V2OpenDirectRoomCommand, capacityProfile: V2CapacityProfile,
                   roomShardID: String, roomID: RoomID, identitySnapshot: V2DirectRoomIdentitySnapshot, transaction: any Database, now: Date) async throws -> V2OpenDirectRoomOutcome {
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let actorID = try directUUID(command.actorUserID)
            let targetID = try directUUID(command.targetUserID)
            let operationID = try directUUID(command.operationID)
            // 操作只限定于操作者，与目标关系无关。取得关系锁前先串行化查询，
            // 使并发重试能够看到已提交的房间和时间戳。
            let operationLockKey = "v2-direct-room-operation:" + actorID.uuidString.lowercased() + ":" + operationID.uuidString.lowercased()
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()

            guard v2PostgresTimestampCanEncode(now) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let pair = directPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            guard identitySnapshot.actorUserID == command.actorUserID, identitySnapshot.targetUserID == command.targetUserID else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            guard identitySnapshot.actorIsActive, identitySnapshot.targetIsActive else { return .unavailable }
            if let existingPair = try await sql.raw("SELECT pair.room_id, pair.created_at, room.capacity_profile_id FROM im_v2.direct_room_pairs AS pair INNER JOIN im_v2.rooms AS room ON room.room_id = pair.room_id WHERE pair.lower_user_id = \(bind: pair.lower) AND pair.higher_user_id = \(bind: pair.higher) FOR SHARE OF room").first(decoding: DirectPairRow.self) {
                // 私聊关系在全局唯一，其房间保留创建时选定的不可变容量配置。
                // 不能返回当前部署随后无法写入的房间；调用方可在新的部署配置
                // 恢复预期容量配置后重试。
                guard existingPair.capacityProfileID == capacityProfile.id else {
                    return .unavailable
                }
                guard v2PostgresTimestampCanEncode(existingPair.createdAt) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                return .opened(try existingPair.directRoom(actor: command.actorUserID, target: command.targetUserID))
            }

            let createdRoomID = try directUUID(roomID)
            guard let profile = identitySnapshot.targetProfile, profile.userID == command.targetUserID,
                  let revision = identitySnapshot.targetRevision, let storedRevision = Int64(exactly: revision),
                  let updatedAt = identitySnapshot.targetUpdatedAt, v2PostgresTimestampCanEncode(updatedAt) else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            let targetProfile = DirectPublicProfileRow(userID: targetID, publicHandle: profile.handle.rawValue,
                displayName: profile.displayName, accountKind: profile.accountKind.rawValue, revision: storedRevision, updatedAt: updatedAt)
            // 房间创建只检查不可变的租约围栏，不修改分片池。
            // 共享行锁允许独立关系并发创建房间，同时仍能阻止需要独占行锁的租约替换。
            guard let lease = try await sql.raw("SELECT lease_id, generation, valid_until FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: roomShardID) AND capacity_profile_id = \(bind: capacityProfile.id) FOR SHARE").first(decoding: DirectShardLeaseRow.self), lease.validUntil > now else {
                return .unavailable
            }
            try await sql.raw("INSERT INTO im_v2.rooms (room_id, room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, created_at) VALUES (\(bind: createdRoomID), 'direct', \(bind: roomShardID), 0, 1, \(bind: capacityProfile.id), \(bind: now))").run()
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: createdRoomID), \(bind: roomShardID), 0, \(bind: now), \(bind: now))
                """).run()
            // 打开房间时会立即向操作者投影目标的资料。将该生产端事实与关系一同
            // 持久化，后续发送便无须扫描已压缩和未压缩的同步历史重新发现它。
            // 投影与标记共用此事务，因此两者不会单独存活。
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_pairs
                    (lower_user_id, higher_user_id, room_id, created_at,
                     lower_profile_visible_to_higher, higher_profile_visible_to_lower)
                VALUES
                    (\(bind: pair.lower), \(bind: pair.higher), \(bind: createdRoomID), \(bind: now),
                     \(bind: actorID == pair.higher), \(bind: actorID == pair.lower))
                """).run()
            // Structural rows for the co-located SQL preflight only. Split
            // sends still require their current control authorization grants;
            // these zero defaults are never copied policy authority.
            try await sql.raw("INSERT INTO im_v2.user_direct_send_policy_versions (user_id) VALUES (\(bind: actorID)), (\(bind: targetID)) ON CONFLICT (user_id) DO NOTHING").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision) VALUES (\(bind: createdRoomID), \(bind: actorID), 'member', 1), (\(bind: createdRoomID), \(bind: targetID), 'member', 1)").run()
            // 私聊房间的 room_sequence 从零开始，因此首个事件出现前此调用无效果。
            // 保留该调用，使双方成员遵循与其他加入路径相同的水位规则。
            try await v2InitializeNewRoomReadWatermarks(
                roomID: createdRoomID, now: now, sql: sql
            )
            try await sql.raw("INSERT INTO im_v2.room_admission (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation) VALUES (\(bind: createdRoomID), 2, \(bind: capacityProfile.limits.maxCommandsPerWindow), \(bind: lease.leaseID), \(bind: lease.generation))").run()
            try await appendDirectRoomProfileProjection(recipientID: actorID, roomID: createdRoomID, profile: targetProfile, sourceEventID: operationID, createdAt: now, sql: sql)
            return .opened(.init(roomID:roomID,actorUserID:command.actorUserID,targetUserID:command.targetUserID,createdAt:now))
    }

    /// 设置被添加好友权限。
    ///
    /// - Parameters:
    ///   - command: 权限变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func applyUserAddPermission(command:V2SetUserAddPermissionCommand,transaction:any Database,now:Date) async throws -> V2SetUserAddPermissionOutcome {
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let actorID = try directUUID(command.actorUserID)
            let operationID = try directUUID(command.operationID)
            let requested = command.permission == .allow
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: userAddPreferenceLockKey(actorID)), 0))").run()
            guard v2PostgresTimestampCanEncode(now) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.user_add_preferences (user_id, allows_being_added, updated_at) VALUES (\(bind: actorID), \(bind: requested), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_being_added = EXCLUDED.allows_being_added, updated_at = EXCLUDED.updated_at").run()
            guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: actorID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max) RETURNING next_sequence").first(decoding: DirectSyncSequenceRow.self) else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actorID), \(bind: sequence.nextSequence), \(bind: operationID), 'user_add_permission', jsonb_build_object('allows_being_added', \(bind: requested), 'updated_at_ms', \(bind: try v2GatewayMilliseconds(now))), \(bind: now))").run()
            return .updated(permission: command.permission, updatedAt: now)
    }

    private func appendDirectRoomProfileProjection(recipientID: UUID, roomID: UUID, profile: DirectPublicProfileRow, sourceEventID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        guard profile.revision > 0, v2PostgresTimestampCanEncode(profile.updatedAt) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        // 所有房间事件载荷均使用 Foundation 的规范 UUID 字符串形式。
        // 不能让 PostgreSQL 的 UUID 转文本结果，使同一房间的私聊资料记录
        // 与消息在字符串形式上不一致。
        let wireRoomID = roomID.uuidString
        let wireTargetUserID = profile.userID.uuidString
        try await sql.raw("INSERT INTO im_v2.user_state_event_outbox (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id) VALUES (\(bind: recipientID), \(bind: sourceEventID), 'direct_room_profile', jsonb_build_object('room_id', \(bind: wireRoomID), 'target_user_id', \(bind: wireTargetUserID), 'public_handle', \(bind: profile.publicHandle), 'display_name', \(bind: profile.displayName), 'account_kind', \(bind: profile.accountKind), 'revision', \(bind: profile.revision), 'room_created_at_ms', (SELECT floor(extract(epoch FROM created_at) * 1000)::bigint FROM im_v2.rooms WHERE room_id = \(bind: roomID)), 'updated_at_ms', \(bind: Int64(profile.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: createdAt), \(bind: createdAt), \(bind: roomID))").run()
    }
}


private struct DirectPairRow: Decodable {
    let roomID: UUID; let createdAt: Date; let capacityProfileID: String
    enum CodingKeys: String, CodingKey { case roomID = "room_id", createdAt = "created_at", capacityProfileID = "capacity_profile_id" }
    func directRoom(actor: UserID, target: UserID) throws -> V2DirectRoom { .init(roomID: try .init(roomID.uuidString), actorUserID: actor, targetUserID: target, createdAt: createdAt) }
}
private struct DirectShardLeaseRow: Decodable {
    let leaseID: UUID; let generation: Int64; let validUntil: Date
    enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until" }
}
private func userAddPreferenceLockKey(_ userID: UUID) -> String { "v2-user-add-preference:\(userID.uuidString.lowercased())" }
private struct DirectPublicProfileRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
        case updatedAt = "updated_at"
    }
}
private struct DirectSyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private func directUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let result = UUID(uuidString: identifier.rawValue) else { throw V2DirectMessagingStoreError.corruptPersistenceState }; return result }
private func directPair(_ lhs: UUID, _ rhs: UUID) -> (lower: UUID, higher: UUID, lockKey: String) { let left = lhs.uuidString.lowercased(); let right = rhs.uuidString.lowercased(); return left < right ? (lhs, rhs, "\(left)|\(right)") : (rhs, lhs, "\(right)|\(left)") }

extension PostgresV2DirectMessagingStore {
    /// The proof and room facts commit in one owner transaction. Recovery never
    /// mistakes the current pair or current permission for the original outcome.
    public func submitDirectRoomOperation(_ command: V2DirectRoomOperationCommand,
        roomID: RoomID, roomShardID: String, capacityProfile: V2CapacityProfile,
        now: Date) async throws -> V2DirectRoomOperationResult {
        let identity = try command.identity; let fingerprint = try command.fingerprint
        let started = ContinuousClock.now
        guard let proofSQL = database as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        if let prior = try await directProof(identity, sql: proofSQL) {
            return prior.fingerprint == fingerprint ? .receipt(prior) : .fingerprintConflict
        }
        return try await v2WithPostgresTransactionRetry(database: database) { tx in
            guard let sql = tx as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            try await directProofLock(identity, sql: sql)
            if let receipt = try await directProof(identity, sql: sql) {
                return receipt.identity == identity && receipt.fingerprint == fingerprint ? .receipt(receipt) : .fingerprintConflict
            }
            // Obtain the domain pair lock before the deadline check. Waiting for
            // another pair operation does not extend the user's confirmation.
            let pair = directPair(command.actorUserID.uuidValue!, command.targetUserID.uuidValue!)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey),0))").run()
            // Read the current authority only after both owner locks are held.
            // The reader runs one plain control query; it never holds a control
            // transaction across an owner call. Every transaction retry reads
            // afresh, and its waiting time remains in the original deadline.
            let snapshot = try await identityReader.read(actorUserID: command.actorUserID, targetUserID: command.targetUserID)
            guard snapshot.actorUserID == command.actorUserID, snapshot.targetUserID == command.targetUserID else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            let elapsed = started.duration(to: .now).components
            let current = now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            let ms = try directProofMilliseconds(current)
            let normalized = Date(timeIntervalSince1970: Double(ms) / 1000)
            let outcome: V2DirectRoomOperationTerminalOutcome
            if command.firstSubmissionDeadlineMilliseconds <= ms { outcome = .rejected(.firstSubmissionExpired) }
            else if command.firstSubmissionDeadlineMilliseconds - ms > 600_000 { outcome = .rejected(.invalidDeadline) }
            else if !snapshot.actorIsActive || !snapshot.targetIsActive { outcome = .rejected(.permissionDenied) }
            else {
                let domain = try V2OpenDirectRoomCommand(actorUserID: command.actorUserID,
                    operationID: command.operationID, targetUserID: command.targetUserID)
                switch try await applyOpen(command: domain, capacityProfile: capacityProfile,
                    roomShardID: roomShardID, roomID: roomID, identitySnapshot: snapshot, transaction: tx, now: normalized) {
                case .opened(let room), .idempotent(let room):
                    // Both projection and proof use the authority's room timestamp.
                    guard let authoritative = try await sql.raw("SELECT floor(extract(epoch FROM created_at)*1000)::bigint AS value FROM im_v2.rooms WHERE room_id=\(bind: room.roomID.uuidValue!)").first(decoding:DirectCreatedMilliseconds.self),authoritative.value>0 else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                    outcome = .opened(roomID: room.roomID, createdAtMilliseconds: UInt64(authoritative.value))
                case .unavailable:
                    // Capacity/admission outages are temporary, not a permanent
                    // denial of the original operation.
                    return .unresolved
                case .idempotencyConflict: throw V2DirectMessagingStoreError.corruptPersistenceState
                }
            }
            let receipt = try V2DirectRoomOperationReceipt(identity: identity, fingerprint: fingerprint,
                outcome: outcome, resolvedAtMilliseconds: ms)
            try await insertDirectProof(receipt, sql: sql)
            return .receipt(receipt)
        }
    }
    public func recoverDirectRoomOperation(_ request: V2DirectRoomOperationRecoveryRequest,
        now: Date) async throws -> V2DirectRoomOperationResult {
        try await database.transaction { tx in
            guard let sql = tx as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            try await directProofLock(request.identity, sql: sql)
            if let receipt = try await directProof(request.identity, sql: sql) {
                return receipt.identity == request.identity && receipt.fingerprint == request.fingerprint ? .receipt(receipt) : .fingerprintConflict
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            let receipt = try V2DirectRoomOperationReceipt(identity: request.identity, fingerprint: request.fingerprint,
                outcome: .closed, resolvedAtMilliseconds: try directProofMilliseconds(now))
            try await insertDirectProof(receipt, sql: sql)
            return .receipt(receipt)
        }
    }
}
private struct DirectProofJSON: Decodable { let payload: String }
private func directProofLock(_ identity: V2OperationIdentity, sql: any SQLDatabase) async throws {
    let key = "v2-direct-room-proof:" + identity.accountID.rawValue + ":" + identity.operation.rawOperationID
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key),0))").run()
}
private func directProof(_ identity: V2OperationIdentity, sql: any SQLDatabase) async throws -> V2DirectRoomOperationReceipt? {
    guard let row = try await sql.raw("SELECT receipt::text AS payload FROM im_v2.direct_room_owner_receipts WHERE actor_user_id=\(bind: identity.accountID.uuidValue!) AND operation_id=\(bind: UUID(uuidString: identity.operation.rawOperationID)!)").first(decoding: DirectProofJSON.self) else { return nil }
    let receipt = try JSONDecoder().decode(V2DirectRoomOperationReceipt.self, from: Data(row.payload.utf8))
    guard receipt.identity.accountID == identity.accountID,receipt.identity.operation.rawOperationID == identity.operation.rawOperationID else { throw V2DirectMessagingStoreError.corruptPersistenceState }
    return receipt
}
private func insertDirectProof(_ receipt: V2DirectRoomOperationReceipt, sql: any SQLDatabase) async throws {
    let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    try await sql.raw("INSERT INTO im_v2.direct_room_owner_receipts(actor_user_id,operation_id,receipt) VALUES (\(bind: receipt.identity.accountID.uuidValue!),\(bind: UUID(uuidString: receipt.identity.operation.rawOperationID)!),\(bind: json)::jsonb)").run()
}

private struct DirectCreatedMilliseconds: Decodable { let value: Int64 }

/// New proofs require a positive, database-representable clock. Historical
/// receipts are returned before this conversion and remain recoverable.
private func directProofMilliseconds(_ date: Date) throws -> UInt64 {
    guard v2PostgresTimestampCanEncode(date),
          let signed = try? v2GatewayMilliseconds(date), signed > 0,
          let value = UInt64(exactly: signed)
    else { throw V2DirectMessagingStoreError.corruptPersistenceState }
    return value
}
