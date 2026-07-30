import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Bounded, durable import for a group's creation audience.  A draft is owned
/// by one actor/operation pair; `freeze` makes its audience immutable before
/// delegating to the existing atomic room-bootstrap transaction.
public struct V2GroupAudienceImport: Equatable, Sendable {
    public static let maximumMembersPerAppend = 512

    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let memberUserIDs: [UserID]

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

/// Admission and retention policy for staged group creation. Keeping it
/// explicit makes the resource bounds testable and prevents accidental drift
/// between gateway validation and the background reclaimer.
public struct V2GroupAudienceImportPolicy: Equatable, Sendable {
    public let maximumActiveDraftsPerActor: Int
    public let maximumStagedMembersPerActor: Int
    public let stagingLifetime: TimeInterval
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

/// Outcome of one bounded frozen-audience recovery pass. A single transient
/// group-create failure is deliberately isolated from the other claimed
/// drafts, so maintenance retains forward progress under partial outage.
public struct V2GroupAudienceRecoveryReport: Equatable, Sendable {
    public let claimedCount: Int
    public let recoveredCount: Int
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

/// Service boundary for the staged protocol.  `finalize` can safely be
/// retried after a lost response: the draft remains frozen and the underlying
/// group operation has its own actor/operation idempotency ledger.
public struct V2GroupAudienceImportService: Sendable {
    private let store: any V2GroupAudienceImportStore
    private let groupMessaging: V2GroupMessagingService
    private let deliveryPolicy: V2GroupDeliveryPolicy
    private let policy: V2GroupAudienceImportPolicy
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupAudienceImportStore,
        groupMessaging: V2GroupMessagingService,
        deliveryPolicy: V2GroupDeliveryPolicy = .init(),
        policy: V2GroupAudienceImportPolicy? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.groupMessaging = groupMessaging
        self.deliveryPolicy = deliveryPolicy
        self.policy = policy ?? .init(maximumStagedMembersPerActor: deliveryPolicy.maximumMembers(for: .largeGroupHybrid) - 1)
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
            maximumMembers: deliveryPolicy.maximumMembers(for: .largeGroupHybrid) - 1,
            policy: policy,
            now: now()
        )
    }

    public func finalize(actorUserID: UserID, operationID: GroupRoomOperationID) async throws -> V2CreateGroupRoomOutcome {
        let frozen = try await store.freeze(actorUserID: actorUserID, operationID: operationID, policy: policy, now: now())
        let outcome = try await groupMessaging.create(
            actorUserID: actorUserID,
            operationID: operationID,
            title: frozen.title,
            initialMemberUserIDs: frozen.memberUserIDs
        )
        switch outcome {
        case .created(let room), .idempotent(let room):
            try await store.complete(actorUserID: actorUserID, operationID: operationID, roomID: room.roomID, policy: policy, now: now())
        case .idempotencyConflict, .memberLimitReached:
            // The underlying operation is terminal and no room was returned;
            // this frozen audience must not consume the actor's permanent
            // draft quota. Transient outcomes retain it for exact retry.
            try await store.discardFrozen(actorUserID: actorUserID, operationID: operationID, now: now())
        case .rateLimited, .unavailable:
            break
        }
        return outcome
    }

    /// Cancellation is idempotent for an absent/expired draft. Once freeze has
    /// started, the immutable audience cannot be cancelled because finalizing
    /// may already be committing the same operation to the room ledger.
    public func cancel(actorUserID: UserID, operationID: GroupRoomOperationID) async throws {
        try await store.cancel(actorUserID: actorUserID, operationID: operationID, now: now())
    }

    @discardableResult
    public func purgeExpired(limit: Int) async throws -> Int {
        guard limit > 0 else { return 0 }
        return try await store.purgeExpired(now: now(), limit: limit)
    }

    /// Finalizing audiences are immutable and must never be TTL-deleted. A
    /// bounded worker instead replays their same operation ID after a quiet
    /// interval; the group-operation ledger remains the single commit fence.
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

    public func begin(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft {
        try await database.transaction { transaction in
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
            let activeDraftCount = try await activeDraftCount(actorID: actorID, now: now, sql: sql)
            guard activeDraftCount < Int64(policy.maximumActiveDraftsPerActor) else {
                throw V2GroupAudienceImportError.activeDraftLimitReached
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_drafts
                    (actor_user_id, operation_id, title, state, created_at, updated_at, expires_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: title), 'staging', \(bind: now), \(bind: now), \(bind: now.addingTimeInterval(policy.stagingLifetime)))
                """).run()
            return .init(operationID: try .init(operationID.uuidString), title: title, stagedMemberCount: 0)
        }
    }

    public func append(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID], maximumMembers: Int, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceDraft {
        try await database.transaction { transaction in
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
                SET updated_at = \(bind: now), expires_at = \(bind: now.addingTimeInterval(policy.stagingLifetime))
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).run()
            return .init(operationID: try .init(operationID.uuidString), title: row.title, stagedMemberCount: Int(count.memberCount))
        }
    }

    public func freeze(actorUserID: UserID, operationID: GroupRoomOperationID, policy: V2GroupAudienceImportPolicy, now: Date) async throws -> V2GroupAudienceImport {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await deleteExpiredDrafts(actorID: actorID, now: now, sql: sql)
            try await audienceLock(actorID: actorID, operationID: operationID, sql: sql)
            guard let row = try await draft(actorID: actorID, operationID: operationID, sql: sql) else { throw V2GroupAudienceImportError.missingDraft }
            if row.state == "staging" {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_drafts
                    SET state = 'finalizing', updated_at = \(bind: now), expires_at = \(bind: now.addingTimeInterval(policy.stagingLifetime))
                    WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                    """).run()
            } else if row.state == "finalizing" {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_drafts
                    SET updated_at = \(bind: now)
                    WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                    """).run()
            }
            let memberRows = try await sql.raw("""
                SELECT user_id FROM im_v2.group_room_creation_draft_members
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                ORDER BY user_id
                """).all(decoding: AudienceMemberRow.self)
            return try .init(
                actorUserID: actorUserID,
                operationID: .init(operationID.uuidString),
                title: row.title,
                memberUserIDs: memberRows.map { try .init($0.userID.uuidString) }
            )
        }
    }

    public func complete(actorUserID: UserID, operationID: GroupRoomOperationID, roomID: RoomID, policy: V2GroupAudienceImportPolicy, now: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupAudienceImportError.corruptPersistenceState }
            let actorID = try audienceUUID(actorUserID)
            let operationID = try audienceUUID(operationID)
            let roomID = try audienceUUID(roomID)
            try await audienceActorLock(actorID: actorID, sql: sql)
            try await sql.raw("""
                UPDATE im_v2.group_room_creation_drafts
                SET state = 'completed', room_id = \(bind: roomID), updated_at = \(bind: now),
                    expires_at = \(bind: now.addingTimeInterval(policy.completedRetention))
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                  AND state IN ('finalizing', 'completed')
                """).run()
        }
    }

    public func cancel(actorUserID: UserID, operationID: GroupRoomOperationID, now: Date) async throws {
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
        // Claim by advancing `updated_at` inside the same statement. The
        // recovery worker can then safely run on multiple processes: a crash
        // after this claim simply makes the frozen draft eligible again after
        // the next interval, while concurrent workers skip the fresh claim.
        let rows = try await sql.raw("""
            WITH candidates AS (
                SELECT ctid
                FROM im_v2.group_room_creation_drafts
                WHERE state = 'finalizing' AND updated_at <= \(bind: now.addingTimeInterval(-staleAfter))
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
