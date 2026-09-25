import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 群邀请目录与创建恢复的 PostgreSQL 持久化实现。
///
/// 创建邀请分为「预写意向」与「完成」两步：先以操作标识落库并登记恢复任务，
/// 再由工作进程按租约推进到完成，使进程崩溃后的创建可以继续或安全重试。
public struct PostgresV2GroupInviteDirectory: V2GroupInviteDirectory, V2GroupInviteCreationRecoveryStoring {
    private let database: any Database

    /// 创建群邀请目录存储。
    ///
    /// - Parameter database: 控制面数据库连接。
    public init(database: any Database) { self.database = database }

    /// 预写一条群邀请创建意向。
    ///
    /// 所有唯一性冲突都被显式处理，包括两次不同操作提出相同令牌或邀请标识的情形：
    /// 此时按操作标识读取既有行，若载荷不一致则判定为冲突。
    /// 仅当行仍处于 `prepared` 状态时才会登记创建恢复任务。
    ///
    /// - Parameter request: 群邀请创建持久化请求。
    /// - Returns: 可继续推进的创建意向。
    /// - Throws: 请求字段非法或与既有记录冲突时抛出。
    public func prepare(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2GroupInviteCreationIntent {
        guard let actor = request.actorUserID.uuidValue,
              let operation = request.operationID.uuidValue,
              let room = request.roomID.uuidValue,
              let invite = request.inviteID.uuidValue,
              request.tokenDigest.count == 32,
              request.requestedLifetimeSeconds > 0,
              request.maximumApprovedUses > 0,
              request.maximumActiveInvitesPerRoom > 0,
              let timestamps = request.persistedTimestamps,
              timestamps.createdAt.microseconds < timestamps.expiresAt.microseconds,
              let recoveryAt = v2PostgresFutureTimestamp(now: request.evaluatedAt, interval: 30)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        return try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            // 明确处理所有唯一约束冲突，包括两个不同操作提出
            // 相同令牌或邀请 ID 的情况。
            try await sql.raw("""
                INSERT INTO im_v2.group_invite_directory
                    (actor_user_id, operation_id, invite_id, room_id, token_digest,
                     requested_lifetime_seconds, maximum_approved_uses, created_at, expires_at, state)
                VALUES (\(bind: actor), \(bind: operation), \(bind: invite), \(bind: room),
                        \(bind: request.tokenDigest), \(bind: request.requestedLifetimeSeconds),
                        \(bind: request.maximumApprovedUses), \(bind: timestamps.createdAt),
                        \(bind: timestamps.expiresAt), 'prepared')
                ON CONFLICT DO NOTHING
                """).run()
            guard let row = try await sql.raw("""
                SELECT * FROM im_v2.group_invite_directory
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
                FOR UPDATE
                """).first(decoding: DirectoryRow.self),
                  row.roomID == room, row.tokenDigest == request.tokenDigest,
                  row.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                  row.maximumApprovedUses == request.maximumApprovedUses
            else { throw V2GroupInviteDirectoryError.conflict }
            if row.state == "prepared" {
                try await sql.raw("""
                    INSERT INTO im_v2.group_invite_creation_recovery
                        (actor_user_id, operation_id, state, attempt_count, next_attempt_at, updated_at)
                    VALUES (\(bind: actor), \(bind: operation), 'pending', 0,
                            \(bind: recoveryAt), \(bind: request.evaluatedAt))
                    ON CONFLICT DO NOTHING
                    """).run()
            }
            return try row.intent(maximumActiveInvitesPerRoom: request.maximumActiveInvitesPerRoom, evaluatedAt: request.evaluatedAt)
        }
    }

    /// 完成一条群邀请创建意向。
    ///
    /// 同时把对应的恢复任务标记为已完成，避免后续工作进程再次认领。
    ///
    /// - Parameters:
    ///   - intent: 待完成的创建意向。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 请求非法、状态冲突或持久化失败时抛出。
    public func finalize(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        let request = intent.request
        guard let actor = request.actorUserID.uuidValue,
              let operation = request.operationID.uuidValue,
              v2PostgresTimestampCanEncode(now)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            guard let row = try await sql.raw("""
                SELECT * FROM im_v2.group_invite_directory
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) FOR UPDATE
                """).first(decoding: DirectoryRow.self),
                  row.inviteID == request.inviteID.uuidValue,
                  row.roomID == request.roomID.uuidValue,
                  row.tokenDigest == request.tokenDigest,
                  row.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                  row.maximumApprovedUses == request.maximumApprovedUses,
                  row.createdAt == request.persistedTimestamps?.createdAt,
                  row.expiresAt == request.persistedTimestamps?.expiresAt
            else { throw V2GroupInviteDirectoryError.conflict }
            guard row.state == "prepared" || row.state == "ready" else {
                throw V2GroupInviteDirectoryError.corruptPersistenceState
            }
            if row.state == "prepared" {
                try await sql.raw("""
                    UPDATE im_v2.group_invite_directory SET state = 'ready', ready_at = \(bind: now)
                    WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
                    """).run()
            }
            try await sql.raw("""
                UPDATE im_v2.group_invite_creation_recovery
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    last_error_code = NULL, completed_at = \(bind: now), updated_at = \(bind: now)
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND state <> 'completed'
                """).run()
        }
    }

    /// 认领一批待恢复的群邀请创建任务。
    ///
    /// 先按 `lease_expires_at` 回收已死亡的 `claimed` 任务，再按 `next_attempt_at` 取待处理任务，
    /// 各分支分别走自己的到期时间局部索引，避免对整个积压做宽泛 OR 扫描或全表排序。
    /// 认领使用 `SKIP LOCKED`，重试计数上限为 1000。
    ///
    /// - Parameters:
    ///   - limit: 本次最多认领数，必须落在 1…100 之间。
    ///   - now: 当前时间。
    ///   - lease: 本次租约时长，必须为正且不超过 300 秒。
    ///   - maximumActiveInvitesPerRoom: 每个房间允许的最大有效邀请数，必须为正。
    /// - Returns: 已认领的创建恢复任务列表。
    /// - Throws: 参数越界或持久化失败时抛出。
    public func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim] {
        guard (1...100).contains(limit), lease > 0, lease <= 300,
              maximumActiveInvitesPerRoom > 0,
              let expiresAt = v2PostgresFutureTimestamp(now: now, interval: lease)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        return try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            var result: [V2GroupInviteCreationRecoveryClaim] = []
            // 每个分支使用各自按到期时间建立的部分索引。先回收失活进程；
            // 不进行宽泛的 OR 扫描，也不对全部积压任务排序。
            for (state, dateColumn) in [("claimed", "lease_expires_at"), ("pending", "next_attempt_at")] {
                let remaining = limit - result.count
                if remaining == 0 { break }
                let rows = try await sql.raw("""
                    WITH picked AS (
                        SELECT actor_user_id, operation_id FROM im_v2.group_invite_creation_recovery
                        WHERE state = \(unsafeRaw: state == "claimed" ? "'claimed'" : "'pending'") AND \(unsafeRaw: dateColumn) <= \(bind: now)
                        ORDER BY \(unsafeRaw: dateColumn), actor_user_id, operation_id
                        LIMIT \(bind: remaining) FOR UPDATE SKIP LOCKED
                    ), claimed AS (
                        UPDATE im_v2.group_invite_creation_recovery job
                        SET state = 'claimed', claim_token = gen_random_uuid(),
                            lease_expires_at = \(bind: expiresAt),
                            attempt_count = LEAST(job.attempt_count + 1, 1000), updated_at = \(bind: now)
                        FROM picked WHERE job.actor_user_id = picked.actor_user_id AND job.operation_id = picked.operation_id
                        RETURNING job.actor_user_id, job.operation_id, job.claim_token, job.attempt_count
                    )
                    SELECT directory.*, claimed.claim_token, claimed.attempt_count
                    FROM claimed JOIN im_v2.group_invite_directory directory USING (actor_user_id, operation_id)
                    """).all(decoding: InviteRecoveryClaimRow.self)
                result += try rows.map { row in
                    .init(intent: try row.directory.intent(maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom, evaluatedAt: now), claimToken: row.claimToken, attemptCount: row.attemptCount)
                }
            }
            return result
        }
    }

    /// 把一条已认领的创建任务标记为失败或暂停。
    ///
    /// 只有租约仍有效且认领令牌匹配时才会更新，从而避免过期工作进程覆盖新认领者的状态。
    ///
    /// - Parameters:
    ///   - claim: 本次处理持有的创建恢复任务。
    ///   - reason: 失败原因。
    ///   - retryAt: 下次重试时间；传 `nil` 表示暂停而非重试。
    ///   - now: 当前时间。
    /// - Returns: 是否确实更新了任务状态。
    /// - Throws: 时间戳非法或持久化失败时抛出。
    public func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now), retryAt.map({ v2PostgresTimestampPrecedes(now, $0) }) ?? true,
              let actor = claim.intent.request.actorUserID.uuidValue, let operation = claim.intent.request.operationID.uuidValue
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        let sql = try directorySQL(database)
        let row = try await sql.raw("""
            UPDATE im_v2.group_invite_creation_recovery
            SET state = \(bind: retryAt == nil ? "paused" : "pending"), claim_token = NULL, lease_expires_at = NULL,
                last_error_code = \(bind: reason.rawValue), next_attempt_at = \(bind: retryAt ?? now), updated_at = \(bind: now)
            WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
              AND state = 'claimed' AND claim_token = \(bind: claim.claimToken) AND lease_expires_at > \(bind: now)
            RETURNING actor_user_id
            """).first()
        return row != nil
    }

    /// 筛选出某一房间中已就绪的邀请。
    ///
    /// - Parameters:
    ///   - roomID: 目标群组房间。
    ///   - inviteIDs: 待筛选的邀请标识集合，最多 100 个。
    /// - Returns: 处于就绪状态的邀请标识子集。
    /// - Throws: 参数越界或持久化失败时抛出。
    public func readyInvites(roomID: RoomID, inviteIDs: Set<GroupInviteID>) async throws -> Set<GroupInviteID> {
        guard let room = roomID.uuidValue, inviteIDs.count <= 100 else { throw V2GroupInviteDirectoryError.invalidRequest }
        if inviteIDs.isEmpty { return [] }
        let ids = try inviteIDs.map { id -> UUID in
            guard let uuid = id.uuidValue else { throw V2GroupInviteDirectoryError.invalidRequest }
            return uuid
        }
        let sql = try directorySQL(database)
        let rows = try await sql.raw("""
            SELECT invite_id, room_id FROM im_v2.group_invite_directory
            WHERE room_id = \(bind: room) AND invite_id = ANY(\(bind: ids)::uuid[]) AND state = 'ready'
            """).all(decoding: LocationRow.self)
        return Set(rows.map { .init(uuid: $0.inviteID) })
    }

    /// 按邀请令牌摘要解析其所属群组位置。
    ///
    /// - Parameter tokenDigest: 邀请令牌的摘要。
    /// - Returns: 邀请所在群组的位置；未找到时为 `nil`。
    /// - Throws: 查询失败时抛出。
    public func resolve(tokenDigest: Data) async throws -> V2GroupInviteLocation? {
        guard tokenDigest.count == 32 else { throw V2GroupInviteDirectoryError.invalidRequest }
        let sql = try directorySQL(database)
        guard let row = try await sql.raw("""
            SELECT invite_id, room_id FROM im_v2.group_invite_directory
            WHERE token_digest = \(bind: tokenDigest) AND state = 'ready'
            """).first(decoding: LocationRow.self) else { return nil }
        return .init(inviteID: .init(uuid: row.inviteID), roomID: .init(uuid: row.roomID))
    }
}

private struct LocationRow: Decodable {
    let inviteID: UUID, roomID: UUID
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id" }
}

private struct DirectoryRow: Decodable {
    let actorUserID: UUID, operationID: UUID, inviteID: UUID, roomID: UUID
    let tokenDigest: Data
    let requestedLifetimeSeconds: Int, maximumApprovedUses: Int
    let createdAt: V2PostgresTimestamp, expiresAt: V2PostgresTimestamp
    let state: String
    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id", operationID = "operation_id", inviteID = "invite_id", roomID = "room_id"
        case tokenDigest = "token_digest", requestedLifetimeSeconds = "requested_lifetime_seconds"
        case maximumApprovedUses = "maximum_approved_uses", createdAt = "created_at", expiresAt = "expires_at", state
    }
    func intent(maximumActiveInvitesPerRoom: Int, evaluatedAt: Date) throws -> V2GroupInviteCreationIntent {
        guard state == "prepared" || state == "ready" else {
            throw V2GroupInviteDirectoryError.corruptPersistenceState
        }
        return .init(request: .init(
            inviteID: .init(uuid: inviteID), roomID: .init(uuid: roomID),
            actorUserID: .init(uuid: actorUserID), operationID: .init(uuid: operationID),
            tokenDigest: tokenDigest, requestedLifetimeSeconds: requestedLifetimeSeconds,
            expiresAt: expiresAt.date, maximumApprovedUses: maximumApprovedUses,
            maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom, createdAt: createdAt.date, evaluatedAt: evaluatedAt
        ).preservingTimestamps(.init(createdAt: createdAt, expiresAt: expiresAt)), isReady: state == "ready")
    }
}

private func directorySQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupInviteDirectoryError.corruptPersistenceState }
    return sql
}

private struct InviteRecoveryClaimRow: Decodable {
    let directory: DirectoryRow
    let claimToken: UUID
    let attemptCount: Int
    enum CodingKeys: String, CodingKey { case claimToken = "claim_token", attemptCount = "attempt_count" }
    init(from decoder: any Decoder) throws {
        directory = try DirectoryRow(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claimToken = try container.decode(UUID.self, forKey: .claimToken)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
    }
}
