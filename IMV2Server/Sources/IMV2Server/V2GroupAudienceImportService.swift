import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 建群受众的有界持久化导入。
///
/// 每份草稿由唯一的「发起者 + 操作标识」组合持有；`freeze` 会先固定受众，
/// 之后才交给既有的原子房间引导事务处理。
public struct V2GroupAudienceImport: Equatable, Sendable {
    /// 单次追加允许携带的最大成员数。
    public static let maximumMembersPerAppend = 512

    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let memberUserIDs: [UserID]
    public let stagedMemberCount: Int
    public let hasMaterializedMembers: Bool

    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, memberUserIDs: [UserID]) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !memberUserIDs.contains(actorUserID),
              Set(memberUserIDs).count == memberUserIDs.count
        else { throw V2GroupAudienceImportError.invalidInput }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = normalizedTitle
        self.memberUserIDs = memberUserIDs.sorted()
        stagedMemberCount = memberUserIDs.count
        hasMaterializedMembers = true
    }

    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, stagedMemberCount: Int) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              stagedMemberCount >= 0
        else { throw V2GroupAudienceImportError.invalidInput }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = normalizedTitle
        memberUserIDs = []
        self.stagedMemberCount = stagedMemberCount
        hasMaterializedMembers = false
    }
}

public enum V2GroupAudienceImportError: Error, Equatable, Sendable {
    case invalidInput
    case missingDraft
    case draftFrozen
    case memberLimitReached
    case activeDraftLimitReached
    case idempotencyConflict
    case corruptPersistenceState
}

/// 分阶段建群的准入与保留策略。
///
/// 显式声明策略使资源上限可被测试，也避免网关校验与后台回收器之间出现无意间的偏差。
public struct V2GroupAudienceImportPolicy: Equatable, Sendable {
    /// 单发起者允许的活跃草稿上限。
    public let maximumActiveDraftsPerActor: Int
    /// 单发起者允许的分阶段成员总数上限。
    public let maximumStagedMembersPerActor: Int
    /// 草稿的暂存存活时长。
    public let stagingLifetime: TimeInterval
    /// 已完成记录的保留时长。
    public let completedRetention: TimeInterval
    public let finalizingRecoveryInterval: TimeInterval

    public init(
        maximumActiveDraftsPerActor: Int = 3,
        maximumStagedMembersPerActor: Int,
        stagingLifetime: TimeInterval = 24 * 60 * 60,
        completedRetention: TimeInterval = 60 * 60,
        finalizingRecoveryInterval: TimeInterval = 30
    ) {
        precondition(maximumActiveDraftsPerActor > 0)
        precondition(maximumStagedMembersPerActor > 0)
        precondition(stagingLifetime > 0)
        precondition(completedRetention > 0)
        precondition(finalizingRecoveryInterval > 0)
        self.maximumActiveDraftsPerActor = maximumActiveDraftsPerActor
        self.maximumStagedMembersPerActor = maximumStagedMembersPerActor
        self.stagingLifetime = stagingLifetime
        self.completedRetention = completedRetention
        self.finalizingRecoveryInterval = finalizingRecoveryInterval
    }
}

public struct V2GroupAudienceDraft: Equatable, Sendable {
    public let operationID: GroupRoomOperationID
    public let title: String
    public let stagedMemberCount: Int
}

public struct V2GroupAudienceRecoveryCandidate: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
}

/// 一次有界冻结受众恢复的结果。
///
/// 单个建群瞬时失败被刻意与其他已认领草稿隔离，
/// 使部分依赖不可用时维护流程仍能继续推进。
public struct V2GroupAudienceRecoveryReport: Equatable, Sendable {
    /// 本轮认领的草稿数量。
    public let claimedCount: Int
    /// 本轮恢复成功的数量。
    public let recoveredCount: Int
    /// 本轮失败的数量。
    public let failedCount: Int

    public init(claimedCount: Int, recoveredCount: Int, failedCount: Int) {
        precondition(claimedCount >= 0 && recoveredCount >= 0 && failedCount >= 0)
        precondition(recoveredCount + failedCount == claimedCount)
        self.claimedCount = claimedCount
        self.recoveredCount = recoveredCount
        self.failedCount = failedCount
    }
}

public protocol V2GroupAudienceImportStore: Sendable {
    func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft
    func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft
    func freeze(actorUserID: UserID, operationID: GroupRoomOperationID, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceImport
    func complete(actorUserID: UserID, operationID: GroupRoomOperationID, roomID: RoomID, policy: V2GroupAudienceImportPolicy, now: Date) async throws
    func discardFrozen(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws
    func cancel(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws
    func purgeExpired(now: Date, limit: Int) async throws -> Int
    func recoverableFinalizing(now: Date, staleAfter: TimeInterval, limit: Int) async throws -> [V2GroupAudienceRecoveryCandidate]
}

/// 分阶段协议的服务边界。
///
/// 响应丢失后可以安全重试 `finalize`：草稿保持冻结状态，
/// 底层建群操作本身也有按发起者与操作标识建立的幂等台账。
public struct V2GroupAudienceImportService: Sendable {
    private let store: any V2GroupAudienceImportStore
    private let groupMessaging: V2GroupMessagingService
    private let deliveryPolicy: V2GroupCapacityPolicy
    private let policy: V2GroupAudienceImportPolicy
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupAudienceImportStore,
        groupMessaging: V2GroupMessagingService,
        deliveryPolicy: V2GroupCapacityPolicy = .init(),
        policy: V2GroupAudienceImportPolicy? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.groupMessaging = groupMessaging
        self.deliveryPolicy = deliveryPolicy
        self.policy = policy ?? .init(maximumStagedMembersPerActor: deliveryPolicy.maximumMembers(for: .large) - 1)
        self.now = now
    }

    public func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String) async throws -> V2GroupAudienceDraft {
        let input = try V2GroupAudienceImport(actorUserID: actorUserID, operationID: operationID, title: title, memberUserIDs: [])
        return try await store.begin(actorUserID: actorUserID, operationID: operationID, title: input.title, policy: policy, now: now())
    }

    public func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2GroupAudienceDraft {
        guard !memberUserIDs.isEmpty, memberUserIDs.count <= V2GroupAudienceImport.maximumMembersPerAppend else {
            throw V2GroupAudienceImportError.invalidInput
        }
        _ = try V2GroupAudienceImport(actorUserID: actorUserID, operationID: operationID, title: "validated", memberUserIDs: memberUserIDs)
        return try await store.append(
            actorUserID: actorUserID,
            operationID: operationID,
            memberUserIDs: memberUserIDs,
            maximumMembers: deliveryPolicy.maximumMembers(for: .large) - 1,
            policy: policy,
            now: now()
        )
    }

    public func finalize(actorUserID: UserID, operationID: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome {
        let frozen = try await store.freeze(actorUserID: actorUserID, operationID: operationID, policy: policy, now: now())
        let outcome = if frozen.hasMaterializedMembers {
            try await groupMessaging.create(
                actorUserID: actorUserID,
                operationID: operationID,
                title: frozen.title,
                initialMemberUserIDs: frozen.memberUserIDs
            )
        } else {
            try await groupMessaging.createStaged(
                actorUserID: actorUserID,
                operationID: operationID,
                title: frozen.title,
                stagedMemberCount: frozen.stagedMemberCount
            )
        }
        switch outcome {
        case .created(let room), .idempotent(let room):
            try await store.complete(actorUserID: actorUserID, operationID: operationID, roomID: room.roomID, policy: policy, now: now())
        case .idempotencyConflict, .invalidMembers, .memberLimitReached:
            // The underlying operation is terminal and no room was returned;
            // this frozen audience must not consume the actor's permanent
            // draft quota. Transient outcomes retain it for exact retry.
            try await store.discardFrozen(actorUserID: actorUserID, operationID: operationID, now: now())
        case .rateLimited, .unavailable:
            break
        }
        return outcome
    }

    /// 取消一份草稿。
    ///
    /// 对不存在或已过期的草稿，取消是幂等的。一旦冻结已经开始，
    /// 不可变受众就不允许再取消：此时收尾流程可能已经把同一操作提交进房间台账。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    /// - Throws: 存储不可用或状态不允许取消时抛出。
    public func cancel(actorUserID: UserID, operationID: GroupRoomOperationID) async throws {
        try await store.cancel(actorUserID: actorUserID, operationID: operationID, now: now())
    }

    /// 清理已过期的草稿。
    ///
    /// - Parameter limit: 本轮最多清理的数量。
    /// - Returns: 实际清理的数量；上限非正时返回零。
    /// - Throws: 存储不可用时抛出。
    @discardableResult
    public func purgeExpired(limit: Int) async throws -> Int {
        guard limit > 0 else { return 0 }
        return try await store.purgeExpired(now: now(), limit: limit)
    }

    /// 恢复处于收尾状态的受众。
    ///
    /// 正在收尾的受众不可变，绝不允许按存活时间删除。这里由有界工作器在静默一段时间之后
    /// 重放同一操作标识，建群操作台账仍是唯一的提交栅栏。
    ///
    /// - Parameter limit: 本轮最多处理的草稿数量。
    /// - Returns: 本轮恢复报告；上限非正时返回全零报告。
    /// - Throws: 存储不可用时抛出。
    @discardableResult
    public func recoverFinalizing(limit: Int) async throws -> V2GroupAudienceRecoveryReport {
        guard limit > 0 else { return .init(claimedCount: 0, recoveredCount: 0, failedCount: 0) }
        let candidates = try await store.recoverableFinalizing(
            now: now(), staleAfter: policy.finalizingRecoveryInterval, limit: limit
        )
        var recoveredCount = 0
        var failedCount = 0
        for candidate in candidates {
            do {
                _ = try await finalize(actorUserID: candidate.actorUserID, operationID: candidate.operationID)
                recoveredCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The claim's timestamp provides a bounded retry delay. Do
                // not let this one draft prevent later claimed work from
                // advancing in the same maintenance pass.
                failedCount += 1
            }
        }
        return .init(claimedCount: candidates.count, recoveredCount: recoveredCount, failedCount: failedCount)
    }
}

public struct PostgresV2GroupAudienceImportStore: V2GroupAudienceImportStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    private func validatedExpiry(now: Date, duration: TimeInterval) throws -> Date {
        let expiry = now.addingTimeInterval(duration)
        guard duration.isFinite, duration > 0,
              v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(expiry) else {
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        guard (expiry.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
                > (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else {
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        return expiry
    }

    public func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft {
        let expiry = try validatedExpiry(now: now, duration: policy.stagingLifetime)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await deleteExpiredDrafts(actorID: actorID, now: now, sql: sql)
            try await audienceLock(actorID: actorID, operationID: operationID, sql: sql)
            if let row = try await draft(actorID: actorID, operationID: operationID, sql: sql) {
                guard row.title == title else { throw V2GroupAudienceImportError.idempotencyConflict }
                return try row.value(operationID: .init(operationID.uuidString))
            }
            guard try await audienceUserIsActive(userID: actorID, sql: sql) else {
                throw V2GroupAudienceImportError.invalidInput
            }
            let activeDraftCount = try await activeDraftCount(actorID: actorID, now: now, sql: sql)
            guard activeDraftCount < Int64(policy.maximumActiveDraftsPerActor) else {
                throw V2GroupAudienceImportError.activeDraftLimitReached
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at, updated_at, expires_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: title), 'staging', \(bind: now), \(bind: now), \(bind: expiry))
                """).run()
            return .init(operationID: try .init(operationID.uuidString), title: title, stagedMemberCount: 0)
        }
    }

    public func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft {
        let expiry = try validatedExpiry(now: now, duration: policy.stagingLifetime)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await deleteExpiredDrafts(actorID: actorID, now: now, sql: sql)
            try await audienceLock(actorID: actorID, operationID: operationID, sql: sql)
            guard let row = try await draft(actorID: actorID, operationID: operationID, sql: sql) else {
                throw V2GroupAudienceImportError.missingDraft
            }
            guard row.state == "staging" else { throw V2GroupAudienceImportError.draftFrozen }
            let members = try memberUserIDs.map(audienceUUID)
            guard !members.contains(actorID), Set(members).count == members.count else { throw V2GroupAudienceImportError.invalidInput }
            guard let encoded = String(data: try JSONEncoder().encode(members.map(\.uuidString)), encoding: .utf8) else {
                throw V2GroupAudienceImportError.corruptPersistenceState
            }
            guard try await audienceUserIsActive(userID: actorID, sql: sql) else {
                throw V2GroupAudienceImportError.invalidInput
            }
            let activeRequestedCount = try await sql.raw("""
                WITH requested AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                )
                SELECT COUNT(*)::bigint AS member_count
                FROM requested
                INNER JOIN im_v2.public_user_profiles AS profile
                    ON profile.user_id = requested.user_id AND profile.state = 'active'
                LEFT JOIN im_v2.account_disables AS disabled ON disabled.user_id = requested.user_id
                WHERE disabled.user_id IS NULL
                """).first(decoding: AudienceCountRow.self)?.memberCount ?? -1
            guard activeRequestedCount == Int64(members.count) else {
                throw V2GroupAudienceImportError.invalidInput
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_draft_members
                    (actor_user_id, operation_id, user_id)
                SELECT \(bind: actorID), \(bind: operationID), value::uuid
                FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                ON CONFLICT DO NOTHING
                """).run()
            guard let count = try await sql.raw("""
                SELECT COUNT(*)::bigint AS member_count
                FROM im_v2.group_room_creation_draft_members
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: AudienceCountRow.self) else { throw V2GroupAudienceImportError.corruptPersistenceState }
            guard count.memberCount <= Int64(maximumMembers) else { throw V2GroupAudienceImportError.memberLimitReached }
            let actorMemberCount = try await activeMemberCount(actorID: actorID, now: now, sql: sql)
            guard actorMemberCount <= Int64(policy.maximumStagedMembersPerActor) else {
                throw V2GroupAudienceImportError.memberLimitReached
            }
            try await sql.raw("""
                UPDATE im_v2.group_room_creation_drafts
                SET updated_at = \(bind: now), expires_at = \(bind: expiry)
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).run()
            return .init(operationID: try .init(operationID.uuidString), title: row.title, stagedMemberCount: Int(count.memberCount))
        }
    }

    public func freeze(actorUserID: UserID, operationID: GroupRoomOperationID, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceImport {
        let expiry = try validatedExpiry(now: now, duration: policy.stagingLifetime)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await deleteExpiredDrafts(actorID: actorID, now: now, sql: sql)
            try await audienceLock(actorID: actorID, operationID: operationID, sql: sql)
            guard let row = try await draft(actorID: actorID, operationID: operationID, sql: sql) else { throw V2GroupAudienceImportError.missingDraft }
            guard try await audienceUserIsActive(userID: actorID, sql: sql) else {
                throw V2GroupAudienceImportError.invalidInput
            }
            let invalidMemberExists = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1
                    FROM im_v2.group_room_creation_draft_members AS member
                    LEFT JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = member.user_id AND profile.state = 'active'
                    LEFT JOIN im_v2.account_disables AS disabled ON disabled.user_id = member.user_id
                    WHERE member.actor_user_id = \(bind: actorID)
                      AND member.operation_id = \(bind: operationID)
                      AND (profile.user_id IS NULL OR disabled.user_id IS NOT NULL)
                ) AS value
                """).first(decoding: AudienceBooleanRow.self)?.value ?? true
            guard !invalidMemberExists else { throw V2GroupAudienceImportError.invalidInput }
            if row.state == "staging" {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_drafts
                    SET state = 'finalizing', updated_at = \(bind: now), expires_at = \(bind: expiry)
                    WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                    """).run()
            } else if row.state == "finalizing" {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_drafts
                    SET updated_at = \(bind: now)
                    WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                    """).run()
            }
            return try .init(
                actorUserID: actorUserID,
                operationID: .init(operationID.uuidString),
                title: row.title,
                stagedMemberCount: Int(row.memberCount)
            )
        }
    }

    public func complete(actorUserID: UserID, operationID: GroupRoomOperationID, roomID: RoomID, policy: V2GroupAudienceImportPolicy, now: Date) async throws {
        let expiry = try validatedExpiry(now: now, duration: policy.completedRetention)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            let roomID = try audienceUUID(roomID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await sql.raw("""
                UPDATE im_v2.group_room_creation_drafts
                SET state = 'completed', room_id = \(bind: roomID), updated_at = \(bind: now),
                    expires_at = \(bind: expiry)
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                  AND state IN ('finalizing', 'completed')
                """).run()
        }
    }

    public func cancel(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupAudienceImportError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await deleteExpiredDrafts(actorID: actorID, now: now, sql: sql)
            if let row = try await draft(actorID: actorID, operationID: operationID, sql: sql), row.state != "staging" {
                throw V2GroupAudienceImportError.draftFrozen
            }
            try await sql.raw("""
                DELETE FROM im_v2.group_room_creation_drafts
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID) AND state = 'staging'
                """).run()
        }
    }

    public func discardFrozen(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await sql.raw("""
                DELETE FROM im_v2.group_room_creation_drafts
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID) AND state = 'finalizing'
                """).run()
        }
    }

    public func purgeExpired(now: Date, limit: Int) async throws -> Int {
        guard limit > 0, let sql = database as? any SQLDatabase else {
            if limit <= 0 { return 0 }
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupAudienceImportError.corruptPersistenceState }
        let rows = try await sql.raw("""
            WITH expired AS (
                SELECT actor_user_id, operation_id
                FROM im_v2.group_room_creation_drafts
                WHERE state IN ('staging', 'completed') AND expires_at <= \(bind: now)
                ORDER BY expires_at
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            ), deleted AS (
                DELETE FROM im_v2.group_room_creation_drafts AS draft
                USING expired
                WHERE draft.actor_user_id = expired.actor_user_id
                  AND draft.operation_id = expired.operation_id
                RETURNING 1
            ) SELECT COUNT(*)::bigint AS member_count FROM deleted
            """).first(decoding: AudienceCountRow.self)
        return Int(rows?.memberCount ?? 0)
    }

    public func recoverableFinalizing(now: Date, staleAfter: TimeInterval, limit: Int) async throws -> [V2GroupAudienceRecoveryCandidate] {
        guard staleAfter > 0, limit > 0, let sql = database as? any SQLDatabase else {
            if staleAfter > 0, limit <= 0 { return [] }
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        let cutoff = now.addingTimeInterval(-staleAfter)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(cutoff) else {
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        // A positive interval can disappear at Date or PostgreSQL precision.
        // The claimed timestamp must be newer than the encoded cutoff, or a
        // second worker can immediately claim the same draft again.
        let epoch = Date(timeIntervalSince1970: 946_684_800)
        guard (cutoff.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
                < (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else {
            throw V2GroupAudienceImportError.corruptPersistenceState
        }
        // Claim by advancing `updated_at` inside the same statement. The
        // recovery worker can then safely run on multiple processes: a crash
        // after this claim simply makes the frozen draft eligible again after
        // the next interval, while concurrent workers skip the fresh claim.
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT ctid
                FROM im_v2.group_room_creation_drafts
                WHERE state = 'finalizing' AND updated_at <= \(bind: cutoff)
                ORDER BY updated_at
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            ), claimed AS (
                UPDATE im_v2.group_room_creation_drafts AS draft
                SET updated_at = \(bind: now)
                FROM candidates
                WHERE draft.ctid = candidates.ctid
                RETURNING draft.actor_user_id, draft.operation_id
            )
            SELECT actor_user_id, operation_id FROM claimed
            """).all(decoding: AudienceRecoveryRow.self)
        return try rows.map { row in
            try .init(actorUserID: .init(row.actorUserID.uuidString), operationID: .init(row.operationID.uuidString))
        }
    }

    private func draft(actorID: UUID, operationID: UUID, sql: any SQLDatabase) async throws -> AudienceDraftRow? {
        try await sql.raw("""
            SELECT draft.title, draft.state, COUNT(member.user_id)::bigint AS member_count
            FROM im_v2.group_room_creation_drafts AS draft
            LEFT JOIN im_v2.group_room_creation_draft_members AS member
              ON member.actor_user_id = draft.actor_user_id AND member.operation_id = draft.operation_id
            WHERE draft.actor_user_id = \(bind: actorID) AND draft.operation_id = \(bind: operationID)
            GROUP BY draft.title, draft.state
            """).first(decoding: AudienceDraftRow.self)
    }
}

private func deleteExpiredDrafts(actorID: UUID, now: Date, sql: any SQLDatabase) async throws {
    try await sql.raw("""
        DELETE FROM im_v2.group_room_creation_drafts
        WHERE actor_user_id = \(bind: actorID)
          AND state IN ('staging', 'completed') AND expires_at <= \(bind: now)
        """).run()
}

private func activeDraftCount(actorID: UUID, now: Date, sql: any SQLDatabase) async throws -> Int64 {
    try await sql.raw("""
        SELECT COUNT(*)::bigint AS member_count
        FROM im_v2.group_room_creation_drafts
        WHERE actor_user_id = \(bind: actorID)
          AND (state = 'finalizing' OR (state = 'staging' AND expires_at > \(bind: now)))
        """).first(decoding: AudienceCountRow.self)?.memberCount ?? 0
}

private func activeMemberCount(actorID: UUID, now: Date, sql: any SQLDatabase) async throws -> Int64 {
    try await sql.raw("""
        SELECT COUNT(member.user_id)::bigint AS member_count
        FROM im_v2.group_room_creation_drafts AS draft
        LEFT JOIN im_v2.group_room_creation_draft_members AS member
          ON member.actor_user_id = draft.actor_user_id AND member.operation_id = draft.operation_id
        WHERE draft.actor_user_id = \(bind: actorID)
          AND (draft.state = 'finalizing' OR (draft.state = 'staging' AND draft.expires_at > \(bind: now)))
        """).first(decoding: AudienceCountRow.self)?.memberCount ?? 0
}

private func audienceUserIsActive(userID: UUID, sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.public_user_profiles AS profile WHERE profile.user_id = \(bind: userID) AND profile.state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id)) AS value").first(decoding: AudienceBooleanRow.self)?.value ?? false
}

private struct AudienceDraftRow: Decodable {
    let title: String
    let state: String
    let memberCount: Int64
    enum CodingKeys: String, CodingKey { case title, state, memberCount = "member_count" }
    func value(operationID: GroupRoomOperationID) throws -> V2GroupAudienceDraft {
        guard memberCount >= 0, (state == "staging" || state == "finalizing" || state == "completed") else { throw V2GroupAudienceImportError.corruptPersistenceState }
        return .init(operationID: operationID, title: title, stagedMemberCount: Int(memberCount))
    }
}

private struct AudienceCountRow: Decodable { let memberCount: Int64; enum CodingKeys: String, CodingKey { case memberCount = "member_count" } }
private struct AudienceBooleanRow: Decodable { let value: Bool }
private struct AudienceMemberRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }
private struct AudienceRecoveryRow: Decodable { let actorUserID: UUID; let operationID: UUID; enum CodingKeys: String, CodingKey { case actorUserID = "actor_user_id"; case operationID = "operation_id" } }

private func audienceUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: value.rawValue) else { throw V2GroupAudienceImportError.corruptPersistenceState }
    return value
}

private func audienceLock(actorID: UUID, operationID: UUID, sql: any SQLDatabase) async throws {
    let lockKey = actorID.uuidString + ":" + operationID.uuidString
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
}

private func audienceActorLock(actorID: UUID, sql: any SQLDatabase) async throws {
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actorID.uuidString), 0))").run()
}
