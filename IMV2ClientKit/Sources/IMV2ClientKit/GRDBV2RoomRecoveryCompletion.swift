import Foundation
import GRDB
import IMV2Core

public struct V2RoomRecoveryProgress: Equatable, Sendable {
    public let directoryComplete: Bool
    public let pendingRoomCount: Int
    public let nextAttemptAt: Date?
}

/// Capture before the final personal-stream pull. A snapshot generation change
/// or restarted directory invalidates the candidate even if both look ready again.
public struct V2RoomRecoveryCompletionCandidate: Equatable, Sendable {
    public let scope: V2RoomRecoveryScope
    public let personalGeneration: UInt64
    let directoryRound: String
    let minimumPersonalSequence: UInt64
}

extension GRDBV2LocalSyncStore {
    public func roomRecoveryProgress(scope: V2RoomRecoveryScope) async throws -> V2RoomRecoveryProgress {
        try await databasePool.read { db in
            let scan = try Self.requireRoomRecoveryScope(scope, db: db)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") ?? 0
            var nextAttempt: Date?
            if count > 0 {
                // SQLite orders text/blob after numbers. Checking both indexed
                // extremes detects non-numeric and non-finite retry times even
                // when a healthy earlier row would hide them from MIN alone.
                guard let bounds = try Row.fetchOne(db, sql: """
                    SELECT (SELECT MIN(next_attempt_at) FROM v2_room_recovery_work) AS earliest,
                           (SELECT MAX(next_attempt_at) FROM v2_room_recovery_work) AS latest
                    """) else { throw V2RoomRecoveryPersistenceError.invalidWork }
                let earliest = try Self.recoveryTimestamp(bounds, "earliest")
                _ = try Self.recoveryTimestamp(bounds, "latest")
                nextAttempt = Date(timeIntervalSince1970: earliest)
            }
            return .init(directoryComplete: scan["directory_complete"], pendingRoomCount: count,
                nextAttemptAt: nextAttempt)
        }
    }

    public func roomRecoveryCompletionCandidate(scope: V2RoomRecoveryScope) async throws -> V2RoomRecoveryCompletionCandidate? {
        try await databasePool.read { db in
            let scan = try Self.requireRoomRecoveryScope(scope, db: db)
            guard scan["directory_complete"] as Bool,
                  try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM v2_room_recovery_work)") == true,
                  let cursor = try Self.readCursor(db), cursor.state == .ready else { return nil }
            return .init(scope: scope, personalGeneration: cursor.generation, directoryRound: scan["directory_round"],
                minimumPersonalSequence: cursor.appliedSequence)
        }
    }

    /// Call only with the result of synchronizeIncludingResets performed after
    /// capturing this candidate. Verify the durable checkpoint in one snapshot.
    public func verifyRoomRecoveryCompletion(_ candidate: V2RoomRecoveryCompletionCandidate,
                                               personalAppliedThrough: UInt64) async throws -> Bool {
        try await databasePool.read { db in
            let scan = try Self.requireRoomRecoveryScope(candidate.scope, db: db)
            guard scan["directory_complete"] as Bool,
                  (scan["directory_round"] as String) == candidate.directoryRound,
                  try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM v2_room_recovery_work)") == true,
                  let cursor = try Self.readCursor(db), cursor.state == .ready,
                  cursor.generation == candidate.personalGeneration,
                  cursor.appliedSequence == personalAppliedThrough,
                  cursor.appliedSequence >= candidate.minimumPersonalSequence,
                  cursor.serverAcknowledgedSequence == cursor.appliedSequence,
                  cursor.pendingAcknowledgementReceipt == nil else { return false }
            return true
        }
    }
}
