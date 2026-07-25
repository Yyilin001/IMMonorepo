import Fluent
import Foundation
import Vapor

/// Read-only safety gate for the old source copy after a completed migration.
/// It intentionally does not delete rows: recipient sets and several read-side
/// records can be shared outside one canonical conversation. A future purge
/// command must consume this proof rather than treating cutover as deletion
/// permission by itself.
struct ConversationShardMigrationRetentionInspector {
    struct Result: Sendable {
        let conversationID: UUID
        let sourceCellID: String
        let sourceShardID: String
        let targetCellID: String
        let targetShardID: String
        let retainedForSeconds: Int
        let source: ConversationShardMigrationPreflight.CanonicalDataSnapshot
        let blockers: [String]

        var isEligibleForManualPurge: Bool { blockers.isEmpty }
    }

    let app: Application

    func inspect(
        conversationID: UUID,
        minimumRetentionSeconds: Int,
        now: Date = Date()
    ) async throws -> Result {
        guard let migration = try await ConversationShardMigration.find(conversationID, on: app.db) else {
            throw Abort(.notFound, reason: "No conversation shard migration exists for \(conversationID.uuidString).")
        }
        guard migration.sourceCellID == app.imRealtimeCellID else {
            throw Abort(.serviceUnavailable, reason: "Migration source belongs to Cell \(migration.sourceCellID); inspect retention from that source Cell.")
        }

        let sourceDatabase = app.conversationShardRouter.commandDatabase(forShardID: migration.sourceShardID)
        let source = try await ConversationShardMigrationPreflight(app: app).snapshot(
            conversationID: conversationID,
            database: sourceDatabase
        )
        let sequenceProgress = try await ConversationShardMigrationSequenceProgressStore.load(
            conversationID: conversationID,
            on: app.db
        )
        var blockers: [String] = []

        guard migration.statusEnum == .cutover, let cutoverAt = migration.cutoverAt else {
            blockers.append("migration_not_cut_over")
            return Result(
                conversationID: conversationID,
                sourceCellID: migration.sourceCellID,
                sourceShardID: migration.sourceShardID,
                targetCellID: migration.targetCellID,
                targetShardID: migration.targetShardID,
                retainedForSeconds: 0,
                source: source,
                blockers: blockers
            )
        }

        let retainedForSeconds = max(0, Int(now.timeIntervalSince(cutoverAt)))
        if retainedForSeconds < max(0, minimumRetentionSeconds) {
            blockers.append("retention_window_not_elapsed")
        }

        let route = try await app.conversationDirectory.route(for: conversationID)
        if route.cellID != migration.targetCellID
            || route.shardID != migration.targetShardID
            || route.version <= migration.sourceRouteVersion
        {
            blockers.append("directory_not_on_expected_target")
        }

        guard let fence = try await ConversationWriteFence.find(conversationID, on: sourceDatabase),
              fence.stateEnum == .blocked
        else {
            blockers.append("source_write_fence_not_blocked")
            return Result(
                conversationID: conversationID,
                sourceCellID: migration.sourceCellID,
                sourceShardID: migration.sourceShardID,
                targetCellID: migration.targetCellID,
                targetShardID: migration.targetShardID,
                retainedForSeconds: retainedForSeconds,
                source: source,
                blockers: blockers
            )
        }

        let expected = ConversationShardMigrationPreflight.CanonicalDataSnapshot(
            conversationCount: 1,
            memberCount: migration.sourceMemberCount,
            messageCount: migration.sourceMessageCount,
            domainEventCount: migration.sourceDomainEventCount,
            domainEventSequenceCount: sequenceProgress.sourceCount,
            timelineNoticeCount: migration.sourceTimelineNoticeCount,
            mediaReferenceCount: migration.sourceMediaReferenceCount,
            recipientSnapshotCount: migration.sourceRecipientSnapshotCount
        )
        if source != expected {
            blockers.append("source_snapshot_changed_after_cutover")
        }

        guard let sourceFingerprint = migration.sourceFingerprint,
              let targetFingerprint = migration.targetFingerprint,
              sourceFingerprint == targetFingerprint
        else {
            blockers.append("missing_or_mismatched_cutover_fingerprint")
            return Result(
                conversationID: conversationID,
                sourceCellID: migration.sourceCellID,
                sourceShardID: migration.sourceShardID,
                targetCellID: migration.targetCellID,
                targetShardID: migration.targetShardID,
                retainedForSeconds: retainedForSeconds,
                source: source,
                blockers: blockers
            )
        }
        let currentFingerprint = try await ConversationShardMigrationFingerprint.compute(
            conversationID: conversationID,
            database: sourceDatabase,
            pageSize: 500
        )
        if currentFingerprint != sourceFingerprint {
            blockers.append("source_fingerprint_changed_after_cutover")
        }

        let unfinishedEventCount = try await ConversationDomainEvent.query(on: sourceDatabase)
            .filter(\.$conversationID == conversationID)
            .filter(\.$status != ConversationDomainEventStatus.processed.rawValue)
            .count()
        if unfinishedEventCount > 0 {
            blockers.append("source_has_unfinished_domain_events=\(unfinishedEventCount)")
        }

        return Result(
            conversationID: conversationID,
            sourceCellID: migration.sourceCellID,
            sourceShardID: migration.sourceShardID,
            targetCellID: migration.targetCellID,
            targetShardID: migration.targetShardID,
            retainedForSeconds: retainedForSeconds,
            source: source,
            blockers: blockers
        )
    }
}
