import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 通用推送唤醒准入契约的 PostgreSQL 实现。
///
/// 在提供方接触任何设备相关推送材料之前，活动、精确预算窗口与发件箱行会被一同加锁。
/// 预算数据缺失时按失败关闭处理，仅抑制该条唤醒。准入一旦提交，
/// 后续的提供方重试与被重新认领的租约都会复用它，而不会再次消耗设备密钥工作额度。
public struct PostgresV2PushWakeStore: V2PushWakeStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与标识生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放推送发件箱与预算窗口的数据库。
    ///   - makeUUID: 认领令牌生成方式。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 认领一批已准入的推送唤醒。
    ///
    /// 每批先统一抑制处于禁言状态的工作，避免逐行重复执行同一条全局更新；
    /// 随后选取候选并在同一事务内逐条完成预算准入，预算不足或其他准入条件不满足的条目不进入结果。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，非正时返回空结果。
    ///   - limit: 本批最多认领的数量，非正时返回空结果。
    /// - Returns: 本批唤醒租约。
    /// - Throws: 租约到期时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func claimAdmitted(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2PushWakeLease] {
        guard limit > 0, leaseDuration > 0 else { return [] }
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // 每批次在消耗任何预算前只清除一次静音工作。
            // 旧的逐行事务每轮最多重复执行 `limit` 次全局 UPDATE。
            try await suppressMutedWakes(now: now, on: sql)

            let candidates = try await claimCandidates(now: now, limit: limit, on: sql)
            var leases: [V2PushWakeLease] = []
            leases.reserveCapacity(candidates.count)
            for candidate in candidates {
                if let lease = try await admit(candidate, now: now, expiry: expiry, on: sql) {
                    leases.append(lease)
                }
            }
            return leases
        }
    }

    /// 标记推送已发送。
    ///
    /// 只有仍持有相同认领令牌且处于已认领状态的行才会被更新。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - now: 完成时刻。
    /// - Throws: 时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func markSent(_ lease: V2PushWakeLease, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now),
              let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'sent', sent_at = \(bind: now), claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    /// 记录终态抑制。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - reason: 抑制原因。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func suppress(_ lease: V2PushWakeLease, reason: V2PushSuppressionReason) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'suppressed', suppression_reason = \(bind: suppressionCode(reason)),
                claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    /// 释放租约以便后续重试。
    ///
    /// - Parameter lease: 本次唤醒租约。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func release(_ lease: V2PushWakeLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: lease.wake.dispatchID)
              AND state = 'claimed'
              AND claim_token = \(bind: lease.claimToken)
            """).run()
    }

    private func claimCandidates(
        now: Date,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [PendingPushWakeRow] {
        try await sql.raw("""
                SELECT dispatch_id, target_device_id, campaign_id, budget_window_started_at,
                       requires_new_key_operation, admitted_at
                FROM im_v2.push_wake_outbox
                WHERE state = 'pending'
                   OR (state = 'claimed' AND lease_expires_at <= \(bind: now))
                ORDER BY created_at, dispatch_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: PendingPushWakeRow.self)
    }

    private func admit(
        _ pending: PendingPushWakeRow,
        now: Date,
        expiry: Date,
        on sql: any SQLDatabase
    ) async throws -> V2PushWakeLease? {
        let token = makeUUID()
        guard let campaign = try await sql.raw("""
                SELECT state FROM im_v2.push_campaigns WHERE campaign_id = \(bind: pending.campaignID) FOR UPDATE
                """).first(decoding: PushCampaignRow.self), campaign.state == "enabled" else {
            try await suppress(pending.dispatchID, reason: .campaignDisabled, on: sql)
            return nil
        }
        if pending.admittedAt == nil {
            guard let budget = try await sql.raw("""
                    SELECT max_work_units, used_work_units, max_new_key_operations, used_new_key_operations
                    FROM im_v2.push_device_budgets
                    WHERE device_id = \(bind: pending.deviceID)
                      AND campaign_id = \(bind: pending.campaignID)
                      AND window_started_at = \(bind: pending.budgetWindowStartedAt)
                    FOR UPDATE
                    """).first(decoding: PushBudgetRow.self) else {
                try await suppress(pending.dispatchID, reason: .deviceBudgetUnavailable, on: sql)
                return nil
            }
            let request = try V2PushAdmissionRequest(campaignID: .init(rawValue: pending.campaignID), requiresNewKeyOperation: pending.requiresNewKeyOperation)
            let current = try V2PushDeviceBudget(
                maxWorkUnits: budget.maxWorkUnits,
                usedWorkUnits: budget.usedWorkUnits,
                maxNewKeyOperations: budget.maxNewKeyOperations,
                usedNewKeyOperations: budget.usedNewKeyOperations
            )
            switch try V2PushAdmissionEvaluator.evaluate(campaignEnabled: true, request: request, budget: current) {
            case .suppressed(let reason):
                try await suppress(pending.dispatchID, reason: reason, on: sql)
                return nil
            case .allowed(let next):
                try await sql.raw("""
                        UPDATE im_v2.push_device_budgets
                        SET used_work_units = \(bind: next.usedWorkUnits),
                            used_new_key_operations = \(bind: next.usedNewKeyOperations)
                        WHERE device_id = \(bind: pending.deviceID)
                          AND campaign_id = \(bind: pending.campaignID)
                          AND window_started_at = \(bind: pending.budgetWindowStartedAt)
                        """).run()
            }
        }
        try await sql.raw("""
                UPDATE im_v2.push_wake_outbox
                SET state = 'claimed', claim_token = \(bind: token), lease_expires_at = \(bind: expiry),
                    retry_count = CASE WHEN retry_count = 9223372036854775807
                        THEN retry_count ELSE retry_count + 1 END,
                    admitted_at = COALESCE(admitted_at, \(bind: now))
                WHERE dispatch_id = \(bind: pending.dispatchID) AND state IN ('pending', 'claimed')
                """).run()
        return try .init(
                wake: .init(dispatchID: pending.dispatchID, deviceID: .init(pending.deviceID.uuidString), campaignID: .init(rawValue: pending.campaignID)),
                claimToken: token
            )
    }

    private func suppressMutedWakes(now: Date, on sql: any SQLDatabase) async throws {
        // 推送只携带通用唤醒提示，因此抑制它不会影响持久化用户同步正确性。
        // 已过期租约也纳入处理，因为对应的提供方工作已不再活动，可被回收。
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox AS wake
            SET state = 'suppressed', suppression_reason = 'conversation_muted',
                claim_token = NULL, lease_expires_at = NULL
            FROM im_v2.room_events AS event,
                 im_v2.user_room_preferences AS preference
            WHERE wake.source_event_id = event.event_id
              AND preference.user_id = wake.target_user_id
              AND preference.room_id = event.room_id
              AND preference.mute_until > \(bind: now)
              AND (
                wake.state = 'pending'
                OR (wake.state = 'claimed' AND wake.lease_expires_at <= \(bind: now))
              )
            """).run()
    }

    private func suppress(_ dispatchID: UUID, reason: V2PushSuppressionReason, on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE im_v2.push_wake_outbox
            SET state = 'suppressed', suppression_reason = \(bind: suppressionCode(reason)), claim_token = NULL, lease_expires_at = NULL
            WHERE dispatch_id = \(bind: dispatchID) AND state IN ('pending', 'claimed')
            """).run()
    }

    private func suppressionCode(_ reason: V2PushSuppressionReason) -> String {
        switch reason {
        case .campaignDisabled: return "campaign_disabled"
        case .conversationMuted: return "conversation_muted"
        case .deviceBudgetUnavailable: return "device_budget_unavailable"
        case .deviceWorkBudgetExhausted: return "device_work_budget_exhausted"
        case .deviceNewKeyBudgetExhausted: return "device_new_key_budget_exhausted"
        case .endpointUnavailable: return "endpoint_unavailable"
        case .endpointRejected: return "endpoint_rejected"
        }
    }
}

private struct PendingPushWakeRow: Decodable {
    let dispatchID: UUID
    let deviceID: UUID
    let campaignID: String
    // 此时间戳是预算键的一部分；保留其精确的已存值。
    let budgetWindowStartedAt: V2PostgresTimestamp
    let requiresNewKeyOperation: Bool
    let admittedAt: Date?
    enum CodingKeys: String, CodingKey {
        case dispatchID = "dispatch_id"
        case deviceID = "target_device_id"
        case campaignID = "campaign_id"
        case budgetWindowStartedAt = "budget_window_started_at"
        case requiresNewKeyOperation = "requires_new_key_operation"
        case admittedAt = "admitted_at"
    }
}

private struct PushCampaignRow: Decodable { let state: String }

private struct PushBudgetRow: Decodable {
    let maxWorkUnits: Int
    let usedWorkUnits: Int
    let maxNewKeyOperations: Int
    let usedNewKeyOperations: Int
    enum CodingKeys: String, CodingKey {
        case maxWorkUnits = "max_work_units"
        case usedWorkUnits = "used_work_units"
        case maxNewKeyOperations = "max_new_key_operations"
        case usedNewKeyOperations = "used_new_key_operations"
    }
}
