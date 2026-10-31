import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 安全失效的有界持久传播。
///
/// 账号服务原子提交停用事实与安全失效记录；该工作器枚举已有私聊对端，
/// 群成员关系刻意不在这条路径上。
public struct V2ProfileSecurityInvalidationReport: Equatable, Sendable {
    /// 本轮认领的更新数量。
    public let claimedUpdateCount: Int
    /// 已投影的接收者数量。
    public let projectedRecipientCount: Int
    /// 已完成的更新数量。
    public let completedUpdateCount: Int

    /// 保存传播统计。
    ///
    /// - Parameters:
    ///   - claimedUpdateCount: 认领数量。
    ///   - projectedRecipientCount: 投影接收者数量。
    ///   - completedUpdateCount: 完成数量。
    public init(claimedUpdateCount: Int, projectedRecipientCount: Int, completedUpdateCount: Int) {
        self.claimedUpdateCount = claimedUpdateCount
        self.projectedRecipientCount = projectedRecipientCount
        self.completedUpdateCount = completedUpdateCount
    }
}

/// 只投递停用、隐藏或删除的资料失效；普通资料变化由可见作者通道分发。
///
/// 只有当整页投影都已抵达存活用户分片之后，持久化检查点才会推进。
/// 检查点之前的崩溃会重放同一页，而 `(接收者, 来源事件, 类型)` 三元组让这次重放保持幂等。
/// 这样既避免了控制面与用户分片之间的分布式事务，也不会接受一次被丢弃的资料更新。
public struct V2ProfileSecurityInvalidationWorker: Sendable {
    private let database: any Database
    private let projectionDelivery: any V2UserShardProjectionDelivering
    private let liveNotifier: (any V2LiveSyncNotifier)?
    private let leaseDuration: TimeInterval
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合数据库、当前分片投影投递器与租约参数。
    ///
    /// - Parameters:
    ///   - database: 存放资料传播操作与检查点的数据库。
    ///   - projectionDelivery: 把控制面投影投递到当前用户分片的实现。
    ///   - liveNotifier: 同步变更通知器，可选。
    ///   - leaseDuration: 认领租约秒数，需大于零，默认 30 秒。
    ///   - makeUUID: 标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        database: any Database,
        projectionDelivery: any V2UserShardProjectionDelivering,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        leaseDuration: TimeInterval = 30,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.database = database
        self.projectionDelivery = projectionDelivery
        self.liveNotifier = liveNotifier
        self.leaseDuration = leaseDuration
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 执行一轮有界资料传播。
    ///
    /// `limit` 是按接收者计的工作预算，而不是无界的来源更新数量；
    /// 因此即使某个资料拥有非常大的私聊联系人图，单次调用仍然是安全的。
    ///
    /// - Parameter limit: 本轮按接收者计的预算，需大于零且小于 `Int.max`。
    /// - Returns: 本轮传播统计。
    /// - Throws: 预算越界时抛出
    ///   ``V2ProfileSecurityInvalidationError/invalidLimit``；持久化状态异常时抛出
    ///   ``V2ProfileSecurityInvalidationError/corruptPersistenceState``。
    public func runOnce(limit: Int) async throws -> V2ProfileSecurityInvalidationReport {
        guard limit > 0, limit < Int.max else {
            throw V2ProfileSecurityInvalidationError.invalidLimit
        }
        var remaining = limit
        var claimed = 0
        var projected = 0
        var completed = 0

        while remaining > 0, let lease = try await claimNext(now: now()) {
            claimed += 1
            // 预读一条尚未投递的记录。它不消耗接收方工作预算，
            // 却能让刚好装满的页面立即判定完成，
            // 无须之后再进行一次只为发现关系图尾部的空轮询。
            let candidates = try await directTargets(for: lease, limit: remaining + 1)
            let targets = Array(candidates.prefix(remaining))
            let isComplete = candidates.count <= remaining
            for target in targets {
                _ = try await appendControlProjections(target: target, lease: lease)
                let eventID = try EventID(lease.sourceEventID.uuidString)
                guard let liveSequence = try await projectionDelivery.deliverToCurrentShard(
                    userID: try .init(target.userID.uuidString), sourceEventID: eventID,
                    projectionKinds: ["profile_invalidation"]
                ) else {
                    throw V2ProfileSecurityInvalidationError.missingControlProjection
                }
                await liveNotifier?.notifySyncAvailable(
                    userID: try .init(target.userID.uuidString), eventID: liveSequence, highWatermark: liveSequence
                )
                projected += 1
            }

            // 即使联系人关系图为空，也消耗一次源更新，
            // 防止并发资料变更让本轮处理无界增长。
            remaining -= max(1, targets.count)
            try await advance(lease: lease, lastTargetUserID: targets.last?.userID, completed: isComplete, now: now())
            if isComplete { completed += 1 }
        }
        return .init(claimedUpdateCount: claimed, projectedRecipientCount: projected, completedUpdateCount: completed)
    }

    private func claimNext(now: Date) async throws -> ProfileUpdateLease? {
        guard let sql = database as? any SQLDatabase else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
        guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2ProfileSecurityInvalidationError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await sql.raw("""
            WITH candidate AS (
                SELECT source_event_id
                FROM im_v2.profile_security_invalidation_outbox
                WHERE state = 'pending'
                   OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                ORDER BY created_at, source_event_id
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.profile_security_invalidation_outbox AS outbox
            SET state = 'claimed', claim_token = \(bind: token),
                lease_expires_at = \(bind: expiresAt),
                retry_count = CASE WHEN outbox.state = 'claimed' AND outbox.retry_count < 9223372036854775807
                    THEN outbox.retry_count + 1 ELSE outbox.retry_count END
            FROM candidate
            WHERE outbox.source_event_id = candidate.source_event_id
            RETURNING outbox.source_event_id, outbox.source_user_id, outbox.profile_state,
                      outbox.revision, outbox.profile_updated_at,
                      outbox.enumeration_checkpoint, outbox.claim_token
            """).first(decoding: ProfileUpdateLeaseRow.self).map(ProfileUpdateLease.init)
    }

    private func directTargets(for lease: ProfileUpdateLease, limit: Int) async throws -> [DirectProfileTarget] {
        guard let sql = database as? any SQLDatabase else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
        return try await sql.raw("""
            SELECT CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                        THEN pair.higher_user_id ELSE pair.lower_user_id END AS target_user_id
            FROM im_v2.direct_room_pairs AS pair
            INNER JOIN im_v2.room_memberships AS source_membership
                ON source_membership.room_id = pair.room_id
               AND source_membership.user_id = \(bind: lease.sourceUserID)
               AND source_membership.left_revision IS NULL
            INNER JOIN im_v2.room_memberships AS target_membership
                ON target_membership.room_id = pair.room_id
               AND target_membership.user_id = CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                    THEN pair.higher_user_id ELSE pair.lower_user_id END
               AND target_membership.left_revision IS NULL
            WHERE (pair.lower_user_id = \(bind: lease.sourceUserID) OR pair.higher_user_id = \(bind: lease.sourceUserID))
              AND EXISTS (SELECT 1 FROM im_v2.messages WHERE room_id = pair.room_id)
              AND (\(bind: lease.enumerationCheckpoint) IS NULL OR
                   CASE WHEN pair.lower_user_id = \(bind: lease.sourceUserID)
                        THEN pair.higher_user_id ELSE pair.lower_user_id END > \(bind: lease.enumerationCheckpoint))
            ORDER BY target_user_id
            LIMIT \(bind: limit)
            """).all(decoding: DirectProfileTarget.self)
    }

    /// Append one durable denial per recipient. Replays reuse the exact source
    /// event and cannot recreate a mutable direct-room profile.
    private func appendControlProjections(target: DirectProfileTarget, lease: ProfileUpdateLease) async throws -> UInt64 {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
            let existingInvalidation = try await sql.raw("""
                SELECT user_sync_sequence, payload->>'user_id' AS user_id,
                       (payload->>'minimum_profile_revision')::bigint AS minimum_profile_revision,
                       payload->>'profile_state' AS profile_state
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: target.userID) AND source_event_id = \(bind: lease.sourceEventID)
                  AND projection_kind = 'profile_invalidation'
                """).first(decoding: ExistingProfileInvalidationRow.self)
            if let existingInvalidation, !existingInvalidation.matches(lease: lease) {
                throw V2ProfileSecurityInvalidationError.corruptPersistenceState
            }
            if let existingInvalidation {
                return try directProfileUnsigned(existingInvalidation.sequence)
            }
            let sequence = try await allocateSequence(userID: target.userID, sql: sql)
            try await appendInvalidation(target: target, lease: lease, sequence: sequence, sql: sql)
            return try directProfileUnsigned(sequence)
        }
    }

    private func allocateSequence(userID: UUID, sql: any SQLDatabase) async throws -> Int64 {
        guard let sequence = try await sql.raw("""
            INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
            VALUES (\(bind: userID), 1)
            ON CONFLICT (user_id) DO UPDATE
            SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1
            WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max)
            RETURNING next_sequence AS user_sync_sequence
            """).first(decoding: DirectProfileSequenceRow.self) else {
            throw V2ProfileSecurityInvalidationError.corruptPersistenceState
        }
        return sequence.sequence
    }

    private func appendInvalidation(
        target: DirectProfileTarget,
        lease: ProfileUpdateLease,
        sequence: Int64,
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO im_v2.user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
            VALUES (\(bind: target.userID), \(bind: sequence), \(bind: lease.sourceEventID), 'profile_invalidation',
                    jsonb_build_object('user_id', \(bind: lease.sourceUserID.uuidString),
                                       'minimum_profile_revision', \(bind: lease.revision),
                                       'profile_state', \(bind: lease.profileState)),
                    \(bind: lease.profileUpdatedAt))
            """).run()
    }

    private func advance(lease: ProfileUpdateLease, lastTargetUserID: UUID?, completed: Bool, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
        if completed {
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2ProfileSecurityInvalidationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.profile_security_invalidation_outbox
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    completed_at = \(bind: now)
                WHERE source_event_id = \(bind: lease.sourceEventID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken)
                """).run()
        } else {
            guard let lastTargetUserID else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.profile_security_invalidation_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    enumeration_checkpoint = \(bind: lastTargetUserID)
                WHERE source_event_id = \(bind: lease.sourceEventID) AND state = 'claimed'
                  AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

/// 资料安全失效传播错误。
public enum V2ProfileSecurityInvalidationError: Error, Equatable, Sendable {
    /// 单轮预算为非正或超出可处理范围。
    case invalidLimit
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
    /// 控制面缺少必要的投影记录。
    case missingControlProjection
}

private struct ProfileUpdateLease: Sendable {
    let sourceEventID: UUID
    let sourceUserID: UUID
    let profileState: String
    let revision: Int64
    let profileUpdatedAt: V2PersistenceTimestamp
    let enumerationCheckpoint: UUID?
    let claimToken: UUID

}

private struct ProfileUpdateLeaseRow: Decodable {
    let sourceEventID: UUID
    let sourceUserID: UUID
    let profileState: String
    let revision: Int64
    let profileUpdatedAt: V2PersistenceTimestamp
    let enumerationCheckpoint: UUID?
    let claimToken: UUID

    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case sourceUserID = "source_user_id"
        case profileState = "profile_state"
        case revision
        case profileUpdatedAt = "profile_updated_at"
        case enumerationCheckpoint = "enumeration_checkpoint"
        case claimToken = "claim_token"
    }
}

private extension ProfileUpdateLease {
    init(_ row: ProfileUpdateLeaseRow) throws {
        guard (try? v2GatewayMilliseconds(row.profileUpdatedAt.date)) != nil,
              ["deleted", "suspended", "hidden"].contains(row.profileState), row.revision > 0 else {
            throw V2ProfileSecurityInvalidationError.corruptPersistenceState
        }
        sourceEventID = row.sourceEventID
        sourceUserID = row.sourceUserID
        profileState = row.profileState
        revision = row.revision
        profileUpdatedAt = row.profileUpdatedAt
        enumerationCheckpoint = row.enumerationCheckpoint
        claimToken = row.claimToken
    }
}

private struct DirectProfileTarget: Decodable {
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "target_user_id"
    }
}

private struct DirectProfileSequenceRow: Decodable {
    let sequence: Int64
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence" }
}

private struct ExistingProfileInvalidationRow: Decodable {
    let sequence: Int64
    let userID: String
    let minimumProfileRevision: Int64
    let profileState: String

    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case userID = "user_id"
        case minimumProfileRevision = "minimum_profile_revision"
        case profileState = "profile_state"
    }

    func matches(lease: ProfileUpdateLease) -> Bool {
        userID == lease.sourceUserID.uuidString && minimumProfileRevision == lease.revision &&
            profileState == lease.profileState
    }
}

private func directProfileUnsigned(_ value: Int64) throws -> UInt64 {
    guard value > 0 else { throw V2ProfileSecurityInvalidationError.corruptPersistenceState }
    return UInt64(value)
}
