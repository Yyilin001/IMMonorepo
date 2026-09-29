import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 单轮已读回执偏好传播统计。
public struct V2ReadReceiptPreferencePropagationReport: Equatable, Sendable {
    /// 本轮认领的操作数量。
    public let claimedOperationCount: Int
    /// 本轮投影到房间的数量。
    public let projectedRoomCount: Int
    /// 完成的操作数量。
    public let completedOperationCount: Int
    /// 安排重试的操作数量。
    public let releasedOperationCount: Int
    /// 暂停等待运维处理的操作数量。
    public let pausedOperationCount: Int

    /// 保存传播统计。
    ///
    /// - Parameters:
    ///   - claimedOperationCount: 认领数量。
    ///   - projectedRoomCount: 投影房间数量。
    ///   - completedOperationCount: 完成数量。
    ///   - releasedOperationCount: 安排重试数量，默认零。
    ///   - pausedOperationCount: 暂停数量，默认零。
    public init(
        claimedOperationCount: Int,
        projectedRoomCount: Int,
        completedOperationCount: Int,
        releasedOperationCount: Int = 0,
        pausedOperationCount: Int = 0
    ) {
        self.claimedOperationCount = claimedOperationCount
        self.projectedRoomCount = projectedRoomCount
        self.completedOperationCount = completedOperationCount
        self.releasedOperationCount = releasedOperationCount
        self.pausedOperationCount = pausedOperationCount
    }
}

/// 传播账号关闭私聊已读回执时产生的对向缓存墓碑。
///
/// `limit` 是按房间计的预算，因此命令事务与单轮工作器处理的规模都不会随该账号的联系人图增长。
public struct V2ReadReceiptPreferencePropagationWorker: Sendable {
    private let database: any Database
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合控制数据库与重试策略。
    ///
    /// - Parameters:
    ///   - database: 存放偏好传播操作的数据库。
    ///   - leaseDuration: 认领租约秒数，需大于零，默认 30 秒。
    ///   - retryPolicy: 失败退避策略。
    ///   - makeUUID: 标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        database: any Database,
        leaseDuration: TimeInterval = 30,
        retryPolicy: V2DurableRetryPolicy = .standard,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.database = database
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 执行一轮有界偏好传播。
    ///
    /// 逐条认领操作、投影到相关房间并在成功后终结；剩余预算用尽或无可认领操作时结束本轮。
    ///
    /// - Parameter limit: 本轮按房间计的预算，需大于零且小于 `Int.max`。
    /// - Returns: 本轮传播统计。
    /// - Throws: 预算越界时抛出
    ///   ``V2ReadReceiptPreferencePropagationError/invalidLimit``；
    ///   持久化状态异常时抛出
    ///   ``V2ReadReceiptPreferencePropagationError/corruptPersistenceState``。
    public func runOnce(limit: Int) async throws -> V2ReadReceiptPreferencePropagationReport {
        guard limit > 0, limit < Int.max else {
            throw V2ReadReceiptPreferencePropagationError.invalidLimit
        }
        var remaining = limit
        var claimed = 0
        var projected = 0
        var completed = 0
        var released = 0
        var paused = 0

        while remaining > 0, let lease = try await claimNext(at: now()) {
            try Task.checkCancellation()
            claimed += 1
            var consumedBudget = 0
            do {
                let candidates = try await directTargets(for: lease, limit: remaining + 1)
                let targets = Array(candidates.prefix(remaining))
                let isComplete = candidates.count <= remaining

                for target in targets {
                    try Task.checkCancellation()
                    try await enqueuePolicyCandidates(target: target, lease: lease)
                    projected += 1
                    consumedBudget += 1
                }

                try await advance(
                    lease: lease,
                    lastRoomID: targets.last?.roomID,
                    completed: isComplete,
                    at: now()
                )
                if isComplete { completed += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failureTime = now()
                let disposition = retryPolicy.disposition(
                    attempt: lease.attempt,
                    claimToken: lease.claimToken,
                    now: failureTime,
                    kind: v2DurableWorkFailureKind(for: error)
                )
                try await scheduleRetry(lease: lease, disposition: disposition, at: failureTime)
                if case .pause = disposition { paused += 1 } else { released += 1 }
            }
            remaining -= max(1, consumedBudget)
        }

        return .init(
            claimedOperationCount: claimed,
            projectedRoomCount: projected,
            completedOperationCount: completed,
            releasedOperationCount: released,
            pausedOperationCount: paused
        )
    }

    private func claimNext(at currentTime: Date) async throws -> ReadReceiptPreferencePropagationLease? {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
        }
        guard let expiresAt = v2PostgresFutureTimestamp(now: currentTime, interval: leaseDuration) else {
            throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
        }
        let claimToken = makeUUID()
        return try await sql.raw("""
            WITH candidate AS (
                SELECT actor_user_id, operation_id
                FROM im_v2.read_receipt_preference_propagation_outbox
                WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: currentTime)))
                   OR (state = 'claimed' AND lease_expires_at <= \(bind: currentTime))
                ORDER BY created_at, actor_user_id, operation_id
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE im_v2.read_receipt_preference_propagation_outbox AS outbox
            SET state = 'claimed', claim_token = \(bind: claimToken),
                lease_expires_at = \(bind: expiresAt),
                next_attempt_at = NULL
            FROM candidate
            WHERE outbox.actor_user_id = candidate.actor_user_id
              AND outbox.operation_id = candidate.operation_id
            RETURNING outbox.actor_user_id, outbox.operation_id, outbox.recorded_at,
                      outbox.enumeration_checkpoint, outbox.claim_token,
                      CASE WHEN outbox.retry_count = 9223372036854775807
                          THEN outbox.retry_count ELSE outbox.retry_count + 1 END AS attempt
            """).first(decoding: ReadReceiptPreferencePropagationLease.self)
    }

    private func directTargets(
        for lease: ReadReceiptPreferencePropagationLease,
        limit: Int
    ) async throws -> [ReadReceiptPreferencePropagationTarget] {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
        }
        return try await sql.raw("""
            SELECT pair.room_id,
                   CASE WHEN pair.lower_user_id = \(bind: lease.actorUserID)
                        THEN pair.higher_user_id ELSE pair.lower_user_id END AS peer_user_id
            FROM im_v2.direct_room_owner_routes AS pair
            WHERE (pair.lower_user_id = \(bind: lease.actorUserID)
                OR pair.higher_user_id = \(bind: lease.actorUserID))
              AND (\(bind: lease.enumerationCheckpoint) IS NULL
                OR pair.room_id > \(bind: lease.enumerationCheckpoint))
            ORDER BY pair.room_id
            LIMIT \(bind: limit)
            """).all(decoding: ReadReceiptPreferencePropagationTarget.self)
    }

    private func enqueuePolicyCandidates(
        target: ReadReceiptPreferencePropagationTarget,
        lease: ReadReceiptPreferencePropagationLease
    ) async throws {
        let milliseconds = try v2GatewayMilliseconds(lease.recordedAt.date)
        let source = receiptTombstoneSourceEventID(operationID: lease.operationID, roomID: target.roomID)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            let outbox = try PostgresV2UserStateEventOutbox(database: transaction)
            for (viewer, reader) in [(target.peerUserID, lease.actorUserID), (lease.actorUserID, target.peerUserID)] {
                let candidate = try V2UserStateEvent(sourceEventID: .init(uuid: source), userID: .init(uuid: viewer),
                    kind: .directReadReceipt, payload: JSONSerialization.data(withJSONObject: [
                        "room_id": target.roomID.uuidString, "reader_user_id": reader.uuidString,
                        "read_through_room_sequence": 0, "recorded_at_ms": milliseconds,
                    ]), createdAt: lease.recordedAt)
                try await outbox.enqueue(candidate, in: sql)
            }
        }
    }

    private func advance(
        lease: ReadReceiptPreferencePropagationLease,
        lastRoomID: UUID?,
        completed: Bool,
        at currentTime: Date
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
        }
        if completed {
            guard v2PostgresTimestampCanEncode(currentTime) else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.read_receipt_preference_propagation_outbox
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    completed_at = \(bind: currentTime), next_attempt_at = NULL,
                    paused_at = NULL, last_failure_code = NULL
                WHERE actor_user_id = \(bind: lease.actorUserID)
                  AND operation_id = \(bind: lease.operationID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        } else {
            guard let lastRoomID else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.read_receipt_preference_propagation_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    enumeration_checkpoint = \(bind: lastRoomID), retry_count = 0,
                    next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
                WHERE actor_user_id = \(bind: lease.actorUserID)
                  AND operation_id = \(bind: lease.operationID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    private func scheduleRetry(
        lease: ReadReceiptPreferencePropagationLease,
        disposition: V2DurableRetryDisposition,
        at currentTime: Date
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
        }
        switch disposition {
        case .retry(let nextAttemptAt):
            guard v2PostgresFutureTimestamp(
                now: currentTime, interval: nextAttemptAt.timeIntervalSince(currentTime)
            ) != nil else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.read_receipt_preference_propagation_outbox
                SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                    retry_count = \(bind: lease.attempt), next_attempt_at = \(bind: nextAttemptAt),
                    paused_at = NULL, last_failure_code = 'propagation_failed'
                WHERE actor_user_id = \(bind: lease.actorUserID)
                  AND operation_id = \(bind: lease.operationID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            guard v2PostgresTimestampCanEncode(currentTime) else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.read_receipt_preference_propagation_outbox
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    retry_count = \(bind: lease.attempt), next_attempt_at = NULL,
                    paused_at = \(bind: currentTime), last_failure_code = 'propagation_failed'
                WHERE actor_user_id = \(bind: lease.actorUserID)
                  AND operation_id = \(bind: lease.operationID)
                  AND state = 'claimed' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }
}

/// 已读回执偏好传播错误。
public enum V2ReadReceiptPreferencePropagationError: Error, Equatable, Sendable {
    /// 单轮预算为非正或超出可处理范围。
    case invalidLimit
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
    /// 控制面缺少必要的投影记录。
    case missingControlProjection
}

private struct ReadReceiptPreferencePropagationLease: Decodable, Sendable {
    let actorUserID: UUID
    let operationID: UUID
    let recordedAt: V2PersistenceTimestamp
    let enumerationCheckpoint: UUID?
    let claimToken: UUID
    let attempt: Int

    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case recordedAt = "recorded_at"
        case enumerationCheckpoint = "enumeration_checkpoint"
        case claimToken = "claim_token"
        case attempt
    }
}

private struct ReadReceiptPreferencePropagationTarget: Decodable, Sendable {
    let roomID: UUID
    let peerUserID: UUID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case peerUserID = "peer_user_id"
    }
}
