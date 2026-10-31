import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 单轮控制面维护统计。
public struct V2ControlPlaneHousekeepingReport: Equatable, Sendable {
    /// 删除的终态簿记行数。
    public let deletedRows: Int
    /// 清理的幂等记录行数。
    public let purgedIdempotencyRows: Int
    /// 清理的过期凭据重放记录行数。
    public let purgedExpiredCredentialReplayRows: Int
    /// 清理的过期刷新历史行数。
    public let purgedExpiredRefreshHistoryRows: Int
    /// 清理的过期连接租约行数。
    public let purgedExpiredConnectionLeaseRows: Int
    /// 已关闭的过期通知；其终态记录随后按保留期删除。
    public let expiredPushWakeRows: Int

    /// 保存维护统计；各项计数为负时按零处理。
    ///
    /// - Parameters:
    ///   - deletedRows: 删除行数。
    ///   - purgedIdempotencyRows: 幂等记录行数。
    ///   - purgedExpiredCredentialReplayRows: 凭据重放记录行数。
    ///   - purgedExpiredRefreshHistoryRows: 刷新历史行数。
    ///   - purgedExpiredConnectionLeaseRows: 过期连接租约行数。
    ///   - expiredPushWakeRows: 已关闭的过期通知数。
    public init(
        deletedRows: Int,
        purgedIdempotencyRows: Int = 0,
        purgedExpiredCredentialReplayRows: Int = 0,
        purgedExpiredRefreshHistoryRows: Int = 0,
        purgedExpiredConnectionLeaseRows: Int = 0,
        expiredPushWakeRows: Int = 0
    ) {
        self.deletedRows = max(0, deletedRows)
        self.purgedIdempotencyRows = max(0, purgedIdempotencyRows)
        self.purgedExpiredCredentialReplayRows = max(0, purgedExpiredCredentialReplayRows)
        self.purgedExpiredRefreshHistoryRows = max(0, purgedExpiredRefreshHistoryRows)
        self.purgedExpiredConnectionLeaseRows = max(0, purgedExpiredConnectionLeaseRows)
        self.expiredPushWakeRows = max(0, expiredPushWakeRows)
    }
    /// 本轮是否删除了终态簿记或关闭了过期通知。
    public var didWork: Bool { deletedRows > 0 || expiredPushWakeRows > 0 }
}

/// 控制面维护的持久化能力。
public protocol V2ControlPlaneHousekeepingStore: Sendable {
    /// 清理止于终态的簿记数据。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - retention: 终态簿记的保留时长。
    ///   - idempotencyRetention: 幂等记录的最短保留时长。
    ///   - limit: 本轮最多处理的数量。
    /// - Returns: 本轮维护统计。
    /// - Throws: 持久化失败时抛出。
    func purgeTerminal(
        now: Date,
        retention: TimeInterval,
        idempotencyRetention: TimeInterval,
        limit: Int
    ) async throws -> V2ControlPlaneHousekeepingReport
}

/// 控制面维护工作器。
public struct V2ControlPlaneHousekeepingWorker: Sendable {
    private let store: any V2ControlPlaneHousekeepingStore
    private let retention: TimeInterval
    private let idempotencyRetention: TimeInterval
    private let now: @Sendable () -> Date

    /// 组合维护存储与保留策略。
    ///
    /// - Parameters:
    ///   - store: 执行清理的持久化存储。
    ///   - retention: 终态簿记保留秒数，需为正的有限值，默认 7 天。
    ///   - idempotencyRetention: 幂等记录保留秒数，需不短于幂等策略下限。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 保留时长越界或幂等保留期过短时直接失败，避免误删仍可能被重放依赖的记录。
    public init(
        store: any V2ControlPlaneHousekeepingStore,
        retention: TimeInterval = 7 * 86_400,
        idempotencyRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(retention.isFinite && retention > 0)
        precondition(
            idempotencyRetention.isFinite &&
                idempotencyRetention >= V2IdempotencyPolicy.minimumServerRetention
        )
        self.store = store
        self.retention = retention
        self.idempotencyRetention = idempotencyRetention
        self.now = now
    }

    /// 执行一轮有界控制面维护。
    ///
    /// - Parameter limit: 本轮最多处理的数量，需大于零。
    /// - Returns: 本轮维护统计。
    /// - Throws: 上限非正时抛出
    ///   ``V2ControlPlaneHousekeepingError/invalidLimit``；其余错误来自存储实现。
    public func runOnce(limit: Int) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0 else { throw V2ControlPlaneHousekeepingError.invalidLimit }
        return try await store.purgeTerminal(
            now: now(),
            retention: retention,
            idempotencyRetention: idempotencyRetention,
            limit: limit
        )
    }
}

/// 控制面维护错误。
public enum V2ControlPlaneHousekeepingError: Error, Equatable, Sendable {
    /// 单轮上限为非正值。
    case invalidLimit
    /// 持久化状态损坏。
    case corruptPersistenceState
}

/// 控制面维护的 PostgreSQL 实现。
///
/// 它保留权威房间事件与消息，只删除有界的终态工作器簿记。
/// 终态工作行按外键依赖顺序删除，不绕过仍在进行的投递。
/// 房间自有的操作台账与审核任务不在此处删除，而是由持有激活租约的房间
/// 维护回合（``PostgresV2RoomBookkeepingStore``）清理，每类删除只有一个物理归属。
public struct PostgresV2ControlPlaneHousekeepingStore: V2ControlPlaneHousekeepingStore {
    private let database: any Database

    // 供启动就绪检查与事务执行共用。
    private static let categoryCount = 13
    static var housekeepingRotationPeriod: Int64 { Int64(categoryCount * idempotencyTables.count) }

    /// 组合数据库。
    ///
    /// - Parameters:
    ///   - database: 存放终态簿记与控制面状态的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 清理止于终态的簿记数据。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - retention: 终态簿记保留时长。
    ///   - idempotencyRetention: 幂等记录最短保留时长。
    ///   - limit: 本轮最多处理的数量。
    /// - Returns: 本轮维护统计。
    /// - Throws: 持久化失败时抛出。
    public func purgeTerminal(
        now: Date,
        retention: TimeInterval,
        idempotencyRetention: TimeInterval,
        limit: Int
    ) async throws -> V2ControlPlaneHousekeepingReport {
        guard limit > 0, retention.isFinite, retention > 0,
              idempotencyRetention.isFinite,
              idempotencyRetention >= V2IdempotencyPolicy.minimumServerRetention
        else {
            throw V2ControlPlaneHousekeepingError.invalidLimit
        }
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: retention),
              let notificationCutoff = v2PostgresPastTimestamp(now: now, interval: max(retention, 7 * 86_400)),
              let notificationExpiry = v2PostgresPastTimestamp(now: now, interval: V2MentionPushWakeLimits.lifetime),
              let idempotencyCutoff = v2PostgresPastTimestamp(now: now, interval: idempotencyRetention) else {
            throw V2ControlPlaneHousekeepingError.corruptPersistenceState
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ControlPlaneHousekeepingError.corruptPersistenceState
            }
            // 持久化事务槽位避免时钟与执行节奏产生周期重合，
            // 并串行化并发维护者。清理失败时会回滚该槽位。
            guard let slot = try await sql.raw("""
                SELECT rotation AS value FROM im_v2.control_housekeeping_cursor
                WHERE singleton = TRUE FOR UPDATE
                """).first(decoding: ControlHousekeepingRotationRow.self),
                slot.value >= 0, slot.value < Self.housekeepingRotationPeriod else {
                throw V2ControlPlaneHousekeepingError.corruptPersistenceState
            }
            let rotation = UInt(slot.value)
            let next = slot.value == Self.housekeepingRotationPeriod - 1 ? 0 : slot.value + 1
            try await sql.raw("""
                UPDATE im_v2.control_housekeeping_cursor SET rotation = \(bind: next)
                WHERE singleton = TRUE
                """).run()
            // `limit` 是整个事务的行数预算，而非每张表各用一次的乘数。
            // 将其公平分配给各清理类别，使单轮锁与 WAL 开销可预测；
            // 预算足以覆盖全部类别时，冷表也不会被持续繁忙的工作表饿死。
            var budget = ControlHousekeepingDeletionBudget(
                total: limit,
                categoryCount: Self.categoryCount,
                rotation: rotation
            )
            var count = 0
            count += try await deleteSimple(
                sql: sql, table: "media_scan_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "media_purge_outbox", identity: "media_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, media_id",
                cutoff: cutoff, limit: budget.take()
            )
            // Publication logs expire independently of durable security delivery.
            // Readers detect retention gaps and refresh their bounded visible set.
            count += try await deleteSimple(
                sql: sql, table: "author_presentation_control_changes", identity: "publication_sequence",
                where: "created_at <= ", order: "created_at, publication_sequence",
                cutoff: notificationCutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "profile_security_invalidation_outbox", identity: "source_event_id",
                where: "state = 'completed' AND completed_at <= ", order: "completed_at, source_event_id",
                cutoff: cutoff, limit: budget.take()
            )
            count += try await deleteSimple(
                sql: sql, table: "public_profile_update_outbox", identity: "publication_sequence",
                where: "created_at <= ", order: "created_at, publication_sequence",
                cutoff: notificationCutoff, limit: budget.take()
            )
            let readReceiptPropagationLimit = budget.take()
            count += try await sql.raw("""
                WITH candidates AS (
                    SELECT actor_user_id, operation_id
                    FROM im_v2.read_receipt_preference_propagation_outbox
                    WHERE state = 'completed' AND completed_at <= \(bind: cutoff)
                    ORDER BY completed_at, actor_user_id, operation_id
                    LIMIT \(bind: readReceiptPropagationLimit)
                    FOR UPDATE SKIP LOCKED
                )
                DELETE FROM im_v2.read_receipt_preference_propagation_outbox AS outbox
                USING candidates
                WHERE outbox.actor_user_id = candidates.actor_user_id
                  AND outbox.operation_id = candidates.operation_id
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count
            let pushLimit = budget.take()
            let expiredPushWakes = try await sql.raw("""
                WITH candidates AS (
                    SELECT ctid FROM im_v2.push_wake_outbox
                    WHERE source_room_id IS NOT NULL AND created_at <= \(bind: notificationExpiry)
                      AND (state = 'pending' OR (state = 'claimed' AND lease_expires_at <= \(bind: now)))
                    ORDER BY created_at, dispatch_id LIMIT \(bind: pushLimit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.push_wake_outbox AS wake
                SET state = 'suppressed', suppression_reason = 'endpoint_unavailable',
                    claim_token = NULL, lease_expires_at = NULL
                FROM candidates WHERE wake.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count
            count += try await deleteSimple(
                sql: sql, table: "push_wake_outbox", identity: "dispatch_id",
                where: "state IN ('sent', 'suppressed') AND created_at <= ", order: "created_at, dispatch_id",
                cutoff: cutoff, limit: pushLimit - expiredPushWakes
            )

            // 认证重放记录包含加密的持有者凭据材料；
            // 删除边界由记录自身的重放过期时间决定，
            // 与更长的命令幂等窗口无关。
            let credentialReplays = try await deleteSimple(
                sql: sql, table: "device_credential_operations", identity: "ctid",
                where: "replay_expires_at <= ", order: "replay_expires_at, ctid",
                cutoff: now, limit: budget.take()
            )
            let refreshHistory = try await deleteSimple(
                sql: sql, table: "device_refresh_token_history", identity: "ctid",
                where: "expires_at <= ", order: "expires_at, device_id, family_generation",
                cutoff: now, limit: budget.take()
            )
            let connectionLeases = try await deleteSimple(
                sql: sql, table: "user_live_presence_leases", identity: "connection_id",
                where: "expires_at <= ", order: "expires_at, connection_id",
                cutoff: now, limit: budget.take()
            )
            let remoteBaselines = try await deleteSimple(
                sql: sql, table: "remote_device_revocation_baselines", identity: "baseline_id",
                where: "expires_at <= ", order: "expires_at, baseline_id",
                cutoff: now, limit: budget.take()
            )
            let idempotencyRows = try await purgeIdempotencyResults(
                sql: sql,
                cutoff: idempotencyCutoff,
                // 使用子类别预算时，每个外层周期只推进一次内部表轮转，
                // 避免取模产生周期重合。
                rotation: limit < Self.categoryCount ? rotation / UInt(Self.categoryCount) : rotation,
                limit: budget.take()
            )
            // Owner intents expire after 24 hours; retain control receipts longer so
            // a lost acknowledgement cannot admit the same notification twice.
            count += try await deleteSimple(
                sql: sql, table: "mention_push_wake_receipts", identity: "ctid",
                where: "recorded_at <= ", order: "recorded_at, ctid",
                cutoff: notificationCutoff, limit: budget.take()
            )
            count += credentialReplays + refreshHistory + connectionLeases + remoteBaselines + idempotencyRows
            return .init(
                deletedRows: count,
                purgedIdempotencyRows: idempotencyRows,
                purgedExpiredCredentialReplayRows: credentialReplays,
                purgedExpiredRefreshHistoryRows: refreshHistory,
                purgedExpiredConnectionLeaseRows: connectionLeases,
                expiredPushWakeRows: expiredPushWakes
            )
        }
    }

    /// 普通用户命令台账属于重放结果，而不是权威领域历史。
    ///
    /// 当配置的批量小于表数量时，选取一个轮转子集并把批量分摊到该子集上，
    /// 因此单次维护推进不会把 `limit` 按表数量成倍放大。
    private func purgeIdempotencyResults(
        sql: any SQLDatabase,
        cutoff: Date,
        rotation: UInt,
        limit: Int
    ) async throws -> Int {
        let tables = Self.idempotencyTables.filter { !$0.roomOwned }
        let selectedCount = min(limit, tables.count)
        guard selectedCount > 0 else { return 0 }
        let start = Int(rotation % UInt(tables.count))
        let perTableLimit = max(1, limit / selectedCount)
        var deleted = 0
        for offset in 0 ..< selectedCount {
            let descriptor = tables[(start + offset) % tables.count]
            deleted += try await sql.raw("""
                WITH candidates AS (
                    SELECT target.ctid
                    FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                    WHERE target.\(unsafeRaw: descriptor.timestamp) <= \(bind: cutoff)
                      \(unsafeRaw: descriptor.additionalPredicate)
                    ORDER BY target.\(unsafeRaw: descriptor.timestamp), target.ctid
                    LIMIT \(bind: perTableLimit)
                    FOR UPDATE OF target SKIP LOCKED
                )
                DELETE FROM im_v2.\(unsafeRaw: descriptor.table) AS target
                USING candidates
                WHERE target.ctid = candidates.ctid
                RETURNING 1 AS value
                """).all(decoding: ControlHousekeepingDeletedRow.self).count
        }
        return deleted
    }

    private func deleteSimple(
        sql: any SQLDatabase,
        table: String,
        identity: String,
        where predicate: String,
        order: String,
        cutoff: Date,
        limit: Int
    ) async throws -> Int {
        try await sql.raw("""
            WITH candidates AS (
                SELECT \(unsafeRaw: identity)
                FROM im_v2.\(unsafeRaw: table) AS target
                WHERE \(unsafeRaw: predicate)\(bind: cutoff)
                ORDER BY \(unsafeRaw: order)
                LIMIT \(bind: limit)
                FOR UPDATE OF target SKIP LOCKED
            )
            DELETE FROM im_v2.\(unsafeRaw: table) AS target
            USING candidates
            WHERE target.\(unsafeRaw: identity) = candidates.\(unsafeRaw: identity)
            RETURNING 1 AS value
            """).all(decoding: ControlHousekeepingDeletedRow.self).count
    }

    struct IdempotencyTable: Sendable {
        let table: String
        let timestamp: String
        let additionalPredicate: String
        let roomOwned: Bool

        init(table: String, timestamp: String, additionalPredicate: String, roomOwned: Bool = false) {
            self.table = table
            self.timestamp = timestamp
            self.additionalPredicate = additionalPredicate
            self.roomOwned = roomOwned
        }
    }

    // 不要在此加入 message_send_completions：发送没有服务端强制的过期围栏，
    // 源可见性还取决于接受时不可变的成员关系修订号。通用最短保留期
    // 既不能证明重放已过期，也不能证明该授权依赖已结束。
    // message_forward_operations 还持有稳定的目标客户端 ID。
    // 若没有服务端强制的转发过期时间，删除它会让旧转发生成新的发送标识，
    // 绕过已保留的发送完成记录。
    static let idempotencyTables: [IdempotencyTable] = [
        // 即使申请人离开，审批决定仍保留精确的成员关系结果。
        // 匹配操作标识，避免绑定不一致时误删证据。
        .init(table: "room_membership_operations", timestamp: "created_at", additionalPredicate: "AND NOT EXISTS (SELECT 1 FROM im_v2.group_join_requests AS request WHERE request.decided_by_user_id = target.actor_user_id AND request.decision_operation_id = target.operation_id)", roomOwned: true),
        .init(table: "moderation_operations", timestamp: "created_at", additionalPredicate: "AND NOT EXISTS (SELECT 1 FROM im_v2.moderation_audit_entries AS audit WHERE audit.actor_user_id = target.actor_user_id AND audit.operation_id = target.operation_id)", roomOwned: true),
        .init(table: "read_receipt_operations", timestamp: "recorded_at", additionalPredicate: "", roomOwned: true),
        .init(table: "device_session_operations", timestamp: "created_at", additionalPredicate: ""),
        .init(table: "special_account_message_operations", timestamp: "created_at", additionalPredicate: "", roomOwned: true),
    ]
}

private struct ControlHousekeepingRotationRow: Decodable { let value: Int64 }
private struct ControlHousekeepingDeletedRow: Decodable { let value: Int }

/// 分配行数预算时避免在接近 Int.max 的位置进行乘加运算。
/// 小预算会在各类别间轮转，而非总是先服务前面的类别。
struct ControlHousekeepingDeletionBudget {
    private let base: Int
    private let extra: Int
    private let categoryCount: Int
    private let start: Int
    private var index = 0

    init(total: Int, categoryCount: Int, rotation: UInt) {
        precondition(total > 0 && categoryCount > 0)
        self.categoryCount = categoryCount
        base = total / categoryCount
        extra = total % categoryCount
        start = Int(rotation % UInt(categoryCount))
    }

    mutating func take() -> Int {
        guard index < categoryCount else { return 0 }
        let distance = index >= start ? index - start : categoryCount - (start - index)
        index += 1
        return base + (distance < extra ? 1 : 0)
    }
}
