import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2ReadReceiptPreferencePropagationReport: Equatable, Sendable {
    public let claimedOperationCount: Int
    public let projectedRoomCount: Int
    public let completedOperationCount: Int
    public let releasedOperationCount: Int
    public let pausedOperationCount: Int

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

/// Propagates the reciprocal cache tombstones created when an account turns
/// off direct read receipts. `limit` is a room budget, so neither the command
/// transaction nor one worker pass grows with the account's contact graph.
public struct V2ReadReceiptPreferencePropagationWorker: Sendable {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing
    private let liveNotifier: (any V2LiveSyncNotifier)?
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        shadowForwarder: any V2UserShardProjectionShadowing,
        liveNotifier: (any V2LiveSyncNotifier)? = nil,
        leaseDuration: TimeInterval = 30,
        retryPolicy: V2DurableRetryPolicy = .standard,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0)
        self.database = database
        self.shadowForwarder = shadowForwarder
        self.liveNotifier = liveNotifier
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.makeUUID = makeUUID
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2ReadReceiptPreferencePropagationReport {
        precondition(limit > 0)
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
                    try await appendControlTombstones(target: target, lease: lease)
                    let eventID = try EventID(receiptTombstoneSourceEventID(
                        operationID: lease.operationID,
                        roomID: target.roomID
                    ).uuidString)
                    for userID in [lease.actorUserID, target.peerUserID] {
                        guard let sequence = try await shadowForwarder.shadowIfForwarding(
                            userID: try .init(userID.uuidString),
                            sourceEventID: eventID,
                            projectionKinds: ["direct_read_receipt"]
                        ) else {
                            throw V2ReadReceiptPreferencePropagationError.missingControlProjection
                        }
                        await liveNotifier?.notifySyncAvailable(
                            userID: try .init(userID.uuidString),
                            eventID: sequence,
                            highWatermark: sequence
                        )
                    }
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
                    now: failureTime
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
                lease_expires_at = \(bind: currentTime.addingTimeInterval(leaseDuration)),
                next_attempt_at = NULL
            FROM candidate
            WHERE outbox.actor_user_id = candidate.actor_user_id
              AND outbox.operation_id = candidate.operation_id
            RETURNING outbox.actor_user_id, outbox.operation_id, outbox.recorded_at,
                      outbox.enumeration_checkpoint, outbox.claim_token,
                      outbox.retry_count + 1 AS attempt
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
            FROM im_v2.direct_room_pairs AS pair
            WHERE (pair.lower_user_id = \(bind: lease.actorUserID)
                OR pair.higher_user_id = \(bind: lease.actorUserID))
              AND (\(bind: lease.enumerationCheckpoint) IS NULL
                OR pair.room_id > \(bind: lease.enumerationCheckpoint))
            ORDER BY pair.room_id
            LIMIT \(bind: limit)
            """).all(decoding: ReadReceiptPreferencePropagationTarget.self)
    }

    private func appendControlTombstones(
        target: ReadReceiptPreferencePropagationTarget,
        lease: ReadReceiptPreferencePropagationLease
    ) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState
            }
            let sourceEventID = receiptTombstoneSourceEventID(
                operationID: lease.operationID,
                roomID: target.roomID
            )
            let existing = try await sql.raw("""
                SELECT user_id, payload->>'room_id' AS room_id,
                       payload->>'reader_user_id' AS reader_user_id,
                       (payload->>'read_through_room_sequence')::bigint AS read_through_room_sequence,
                       (payload->>'recorded_at_ms')::bigint AS recorded_at_ms,
                       (payload->>'is_visible')::boolean AS is_visible
                FROM im_v2.user_projection_effects
                WHERE source_event_id = \(bind: sourceEventID)
                  AND projection_kind = 'direct_read_receipt'
                  AND user_id IN (\(bind: lease.actorUserID), \(bind: target.peerUserID))
                """).all(decoding: ExistingReadReceiptTombstone.self)
            if !existing.isEmpty {
                guard existing.count == 2,
                      existing.allSatisfy({ $0.matches(target: target, lease: lease) })
                else { throw V2ReadReceiptPreferencePropagationError.corruptPersistenceState }
                return
            }

            let recordedAtMilliseconds = Int64(lease.recordedAt.timeIntervalSince1970 * 1_000)
            try await sql.raw("""
                WITH recipients(user_id, reader_user_id) AS (
                    VALUES
                        (\(bind: target.peerUserID), \(bind: lease.actorUserID)),
                        (\(bind: lease.actorUserID), \(bind: target.peerUserID))
                ), allocated AS (
                    INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                    SELECT user_id, 1 FROM recipients ORDER BY user_id
                    ON CONFLICT (user_id) DO UPDATE
                    SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1
                    RETURNING user_id, next_sequence
                )
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT allocated.user_id, allocated.next_sequence, \(bind: sourceEventID),
                       'direct_read_receipt',
                       jsonb_build_object(
                           'room_id', \(bind: target.roomID.uuidString),
                           'reader_user_id', recipients.reader_user_id::text,
                           'read_through_room_sequence', 1,
                           'recorded_at_ms', \(bind: recordedAtMilliseconds),
                           'is_visible', FALSE
                       ),
                       \(bind: lease.recordedAt)
                FROM allocated
                INNER JOIN recipients USING (user_id)
                """).run()
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

public enum V2ReadReceiptPreferencePropagationError: Error, Equatable, Sendable {
    case corruptPersistenceState
    case missingControlProjection
}

private struct ReadReceiptPreferencePropagationLease: Decodable, Sendable {
    let actorUserID: UUID
    let operationID: UUID
    let recordedAt: Date
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

private struct ExistingReadReceiptTombstone: Decodable {
    let userID: UUID
    let roomID: String
    let readerUserID: String
    let readThroughRoomSequence: Int64
    let recordedAtMilliseconds: Int64
    let isVisible: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case roomID = "room_id"
        case readerUserID = "reader_user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
        case recordedAtMilliseconds = "recorded_at_ms"
        case isVisible = "is_visible"
    }

    func matches(
        target: ReadReceiptPreferencePropagationTarget,
        lease: ReadReceiptPreferencePropagationLease
    ) -> Bool {
        let expectedReader = userID == lease.actorUserID ? target.peerUserID : lease.actorUserID
        return (userID == lease.actorUserID || userID == target.peerUserID)
            && roomID == target.roomID.uuidString
            && readerUserID == expectedReader.uuidString
            && readThroughRoomSequence == 1
            && recordedAtMilliseconds == Int64(lease.recordedAt.timeIntervalSince1970 * 1_000)
            && !isVisible
    }
}
