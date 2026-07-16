import Fluent
import Vapor

struct IMOpsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "relay-conversation-outbox", help: "Relay pending conversation outbox events to the configured event stream.")
        var relayConversationOutbox: Bool

        @Flag(name: "replay-conversation-dead-letter-events", help: "Replay pending conversation dead-letter events back to the primary Kafka topic.")
        var replayConversationDeadLetterEvents: Bool

        @Flag(name: "requeue-conversation-dead-letter-events", help: "Move failed conversation dead-letter replay records back to pending.")
        var requeueConversationDeadLetterEvents: Bool

        @Flag(name: "inspect-conversation-outbox", help: "Print pending, claimed, failed, and oldest pending outbox counts.")
        var inspectConversationOutbox: Bool

        @Flag(name: "verify-summary-shards", help: "Verify sharded conversation summary read models.")
        var verifySummaryShards: Bool

        @Flag(name: "verify-search-lag", help: "Print database search index lag for the configured conversation shards.")
        var verifySearchLag: Bool

        @Flag(name: "repair-search-lag", help: "Reindex missing or stale database search rows for recent messages.")
        var repairSearchLag: Bool

        @Flag(name: "process-admin-governance-commands", help: "Apply pending admin conversation governance commands through their target conversation shards.")
        var processAdminGovernanceCommands: Bool

        @Flag(name: "reconcile-pending-conversation-routes", help: "Verify stale pending conversation routes against their target shards and activate or abandon them.")
        var reconcilePendingConversationRoutes: Bool

        @Flag(name: "inspect-conversation-shard-migration", help: "Read-only preflight for moving one conversation to an empty physical shard.")
        var inspectConversationShardMigration: Bool

        @Flag(name: "prepare-conversation-shard-migration", help: "Persist a checked shard migration intent without copying data or changing the active route.")
        var prepareConversationShardMigration: Bool

        @Flag(name: "copy-conversation-shard-migration", help: "Resume the idempotent canonical copy for a prepared conversation migration. Does not change the active route.")
        var copyConversationShardMigration: Bool

        @Flag(name: "verify-conversation-shard-migration", help: "Verify source and target canonical counts and fingerprints after a completed conversation copy. Does not change the active route.")
        var verifyConversationShardMigration: Bool

        @Flag(name: "cutover-conversation-shard-migration", help: "Freeze source writes, reverify canonical state, and atomically switch one verified source-Cell conversation route to its target shard.")
        var cutoverConversationShardMigration: Bool

        @Flag(name: "renew-conversation-shard-migration-transfer-token", help: "Rotate the expiring capability for an active remote conversation migration without changing copy progress.")
        var renewConversationShardMigrationTransferToken: Bool

        @Flag(name: "inspect-conversation-shard-migration-retention", help: "Read-only check that a cut-over source copy has passed its retention window and remains safely fenced for a later manual purge.")
        var inspectConversationShardMigrationRetention: Bool

        @Flag(name: "upsert-cell-ingress", help: "Create or update one role-specific Cell ingress record in the primary Cell registry.")
        var upsertCellIngress: Bool

        @Option(name: "shard", help: "Conversation shard ID for shard-scoped operations.")
        var shard: String?

        @Option(name: "limit", short: "l", help: "Maximum number of conversation outbox events to relay.")
        var limit: Int?

        @Option(name: "pending-route-min-age-seconds", help: "Only reconcile pending routes older than this age. Defaults to 300 seconds.")
        var pendingRouteMinimumAgeSeconds: Int?

        @Option(name: "conversation-id", help: "Conversation ID for a conversation-scoped maintenance operation.")
        var conversationID: UUID?

        @Option(name: "target-shard", help: "Destination conversation shard ID for migration preflight.")
        var targetShardID: String?

        @Option(name: "target-cell", help: "Destination Cell ID for migration preflight and prepare. Omit for the local Cell.")
        var targetCellID: String?

        @Option(name: "page-size", help: "Page size for resumable conversation migration copy and verification. Defaults to 200 for copy and 500 for verification.")
        var pageSize: Int?

        @Option(name: "retention-min-age-seconds", help: "Minimum completed-cutover retention age required by the source-copy retention inspector. Defaults to 30 days.")
        var retentionMinimumAgeSeconds: Int?

        @Option(name: "cell-id", help: "Cell ID for Cell registry maintenance.")
        var cellID: String?

        @Option(name: "cell-status", help: "Cell registry status: active, draining, or disabled. Defaults to active.")
        var cellStatus: String?

        @Option(name: "cell-command-endpoint", help: "HTTPS command-api ingress endpoint for the Cell registry record.")
        var cellCommandEndpoint: String?

        @Option(name: "cell-query-endpoint", help: "HTTPS query-api ingress endpoint for the Cell registry record.")
        var cellQueryEndpoint: String?

        @Option(name: "cell-realtime-endpoint", help: "HTTPS Gateway realtime ingress endpoint for the Cell registry record.")
        var cellRealtimeEndpoint: String?
    }

    let help = "Runs IM maintenance operations without starting HTTP or TCP runtimes."

    func run(using context: CommandContext, signature: Signature) async throws {
        if signature.relayConversationOutbox {
            let relayedCount = try await ConversationOutboxRelay(app: context.application)
                .relayPendingEvents(limit: max(1, signature.limit ?? 200))
            context.console.print("Relayed \(relayedCount) conversation outbox events.")
            return
        }

        if signature.replayConversationDeadLetterEvents {
            let replayedCount = try await ConversationReplayService(app: context.application)
                .replayPendingEvents(limit: max(1, signature.limit ?? 200))
            context.console.print("Replayed \(replayedCount) conversation dead-letter events.")
            return
        }

        if signature.requeueConversationDeadLetterEvents {
            let requeuedCount = try await ConversationReplayService(app: context.application)
                .requeueFailedEvents(limit: max(1, signature.limit ?? 200))
            context.console.print("Requeued \(requeuedCount) failed conversation dead-letter replay records.")
            return
        }

        if signature.inspectConversationOutbox {
            let snapshots = try await ConversationOutboxInspector(app: context.application)
                .inspect(shardID: signature.shard)
            for snapshot in snapshots {
                context.console.print(
                    "shard=\(snapshot.shardID) pending=\(snapshot.pendingCount) claimed=\(snapshot.claimedCount) failed=\(snapshot.failedCount) oldest_pending_age_ms=\(snapshot.oldestPendingAgeMillis)"
                )
            }
            return
        }

        if signature.verifySummaryShards {
            let result = try await IMSummaryReadModelRepairService(app: context.application).verifyAllSummaries()
            context.console.print(
                "summary_shards owner_users=\(result.ownerUserCount) missing=\(result.missingSummaryCount) stale=\(result.staleActiveSummaryCount) latest_message_mismatch=\(result.latestVisibleMessageMismatchCount) unread_mismatch=\(result.unreadMismatchCount)"
            )
            return
        }

        if signature.verifySearchLag {
            let snapshots = try await ConversationSearchLagInspector(app: context.application)
                .inspect(shardID: signature.shard)
            for snapshot in snapshots {
                context.console.print(
                    "shard=\(snapshot.shardID) missing_index_rows=\(snapshot.missingIndexRows) stale_index_rows=\(snapshot.staleIndexRows)"
                )
            }
            return
        }

        if signature.repairSearchLag {
            let snapshots = try await ConversationSearchLagInspector(app: context.application)
                .repair(shardID: signature.shard, limit: max(1, signature.limit ?? 1_000))
            for snapshot in snapshots {
                context.console.print(
                    "shard=\(snapshot.shardID) reindexed_rows=\(snapshot.reindexedRows) missing_index_rows_before=\(snapshot.missingIndexRows) stale_index_rows_before=\(snapshot.staleIndexRows)"
                )
            }
            return
        }

        if signature.processAdminGovernanceCommands {
            let commands = try await AdminConversationGovernanceCommandProcessor(app: context.application)
                .processPending(limit: max(1, signature.limit ?? 200))
            let appliedCount = commands.filter { $0.statusEnum == .applied }.count
            let failedCount = commands.filter { $0.statusEnum == .failed }.count
            context.console.print(
                "Processed \(commands.count) admin governance commands: applied=\(appliedCount) failed=\(failedCount)."
            )
            return
        }

        if signature.reconcilePendingConversationRoutes {
            let minimumAgeSeconds = max(0, signature.pendingRouteMinimumAgeSeconds ?? 300)
            let result = try await ConversationRouteLifecycleReconciler(app: context.application)
                .reconcilePendingRoutes(
                    olderThan: Date().addingTimeInterval(-TimeInterval(minimumAgeSeconds)),
                    limit: max(1, signature.limit ?? 200)
                )
            context.console.print(
                "Reconciled pending conversation routes: activated=\(result.activatedCount) abandoned=\(result.abandonedCount) skipped=\(result.skippedCount)."
            )
            return
        }

        if signature.inspectConversationShardMigration {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required for migration preflight.")
            }
            guard let targetShardID = signature.targetShardID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetShardID.isEmpty
            else {
                throw Abort(.badRequest, reason: "--target-shard is required for migration preflight.")
            }
            let result = try await ConversationShardMigrationPreflight(app: context.application).inspect(
                conversationID: conversationID,
                targetShardID: targetShardID,
                targetCellID: signature.targetCellID
            )
            context.console.print(
                "conversation_shard_migration_preflight conversation_id=\(result.conversationID.uuidString) source_cell=\(result.sourceRoute.cellID) source_shard=\(result.sourceRoute.shardID) source_route_version=\(result.sourceRoute.version) target_cell=\(signature.targetCellID ?? context.application.imRealtimeCellID) target_shard=\(result.targetShardID) ready=\(result.isReadyToCopy) source_conversation=\(result.source.conversationCount) source_members=\(result.source.memberCount) source_messages=\(result.source.messageCount) source_events=\(result.source.domainEventCount) source_event_sequences=\(result.source.domainEventSequenceCount) source_recipient_snapshots=\(result.source.recipientSnapshotCount) source_timeline_notices=\(result.source.timelineNoticeCount) source_media_references=\(result.source.mediaReferenceCount) target_rows=\(result.target.totalCount) blockers=\(result.blockers.joined(separator: ","))"
            )
            return
        }

        if signature.prepareConversationShardMigration {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to prepare a shard migration.")
            }
            guard let targetShardID = signature.targetShardID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetShardID.isEmpty
            else {
                throw Abort(.badRequest, reason: "--target-shard is required to prepare a shard migration.")
            }
            let migration = try await ConversationShardMigrationCoordinator(app: context.application).prepare(
                conversationID: conversationID,
                targetShardID: targetShardID,
                targetCellID: signature.targetCellID
            )
            context.console.print(
                "conversation_shard_migration_prepared conversation_id=\(conversationID.uuidString) source_cell=\(migration.sourceCellID) source_shard=\(migration.sourceShardID) source_route_version=\(migration.sourceRouteVersion) target_cell=\(migration.targetCellID) target_shard=\(migration.targetShardID) status=\(migration.status)"
            )
            return
        }

        if signature.copyConversationShardMigration {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to copy a shard migration.")
            }
            let migration = try await ConversationShardMigrationCopyCoordinator(app: context.application).copy(
                conversationID: conversationID,
                pageSize: signature.pageSize ?? 200
            )
            context.console.print(
                "conversation_shard_migration_copied conversation_id=\(conversationID.uuidString) status=\(migration.status) conversation_watermark=\(migration.copyConversationWatermark) member_watermark=\(migration.copyMemberWatermark) message_watermark=\(migration.copyMessageWatermark) event_watermark=\(migration.copyDomainEventWatermark) sequence_watermark=\(migration.copyDomainEventSequenceWatermark) recipient_snapshot_watermark=\(migration.copyRecipientSnapshotWatermark) notice_watermark=\(migration.copyTimelineNoticeWatermark) media_watermark=\(migration.copyMediaReferenceWatermark)"
            )
            return
        }

        if signature.renewConversationShardMigrationTransferToken {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to renew a migration transfer capability.")
            }
            let migration = try await ConversationShardMigrationCoordinator(app: context.application)
                .renewTransferCapability(conversationID: conversationID)
            let expiresAt = migration.transferTokenExpiresAt?.description ?? ""
            context.console.print(
                "conversation_shard_migration_transfer_capability_renewed conversation_id=\(conversationID.uuidString) target_cell=\(migration.targetCellID) expires_at=\(expiresAt)"
            )
            return
        }

        if signature.inspectConversationShardMigrationRetention {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to inspect migration retention.")
            }
            let result = try await ConversationShardMigrationRetentionInspector(app: context.application).inspect(
                conversationID: conversationID,
                minimumRetentionSeconds: max(0, signature.retentionMinimumAgeSeconds ?? 30 * 24 * 60 * 60)
            )
            context.console.print(
                "conversation_shard_migration_retention conversation_id=\(result.conversationID.uuidString) source_cell=\(result.sourceCellID) source_shard=\(result.sourceShardID) target_cell=\(result.targetCellID) target_shard=\(result.targetShardID) retained_for_seconds=\(result.retainedForSeconds) eligible_for_manual_purge=\(result.isEligibleForManualPurge) source_rows=\(result.source.totalCount) blockers=\(result.blockers.joined(separator: ","))"
            )
            return
        }

        if signature.verifyConversationShardMigration {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to verify a shard migration.")
            }
            let migration = try await ConversationShardMigrationCopyCoordinator(app: context.application).verify(
                conversationID: conversationID,
                pageSize: signature.pageSize ?? 500
            )
            context.console.print(
                "conversation_shard_migration_verified conversation_id=\(conversationID.uuidString) status=\(migration.status) source_fingerprint=\(migration.sourceFingerprint ?? "") target_fingerprint=\(migration.targetFingerprint ?? "")"
            )
            return
        }

        if signature.cutoverConversationShardMigration {
            guard let conversationID = signature.conversationID else {
                throw Abort(.badRequest, reason: "--conversation-id is required to cut over a shard migration.")
            }
            let migration = try await ConversationShardMigrationCutoverCoordinator(app: context.application).cutover(
                conversationID: conversationID,
                pageSize: signature.pageSize ?? 500
            )
            let cutoverAt = migration.cutoverAt?.description ?? ""
            context.console.print(
                "conversation_shard_migration_cutover conversation_id=\(conversationID.uuidString) status=\(migration.status) target_cell=\(migration.targetCellID) target_shard=\(migration.targetShardID) cutover_at=\(cutoverAt)"
            )
            return
        }

        if signature.upsertCellIngress {
            guard let cellID = signature.cellID else {
                throw Abort(.badRequest, reason: "--cell-id is required for Cell registry maintenance.")
            }
            guard let commandEndpoint = signature.cellCommandEndpoint,
                  let queryEndpoint = signature.cellQueryEndpoint,
                  let realtimeEndpoint = signature.cellRealtimeEndpoint
            else {
                throw Abort(.badRequest, reason: "--cell-command-endpoint, --cell-query-endpoint, and --cell-realtime-endpoint are required.")
            }
            let status = IMRealtimeCellRegistryStatus(
                rawValue: signature.cellStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "active"
            )
            guard let status else {
                throw Abort(.badRequest, reason: "--cell-status must be active, draining, or disabled.")
            }
            let entry = try await IMCellIngressRegistryService(app: context.application).upsert(
                cellID: cellID,
                status: status,
                commandEndpoint: commandEndpoint,
                queryEndpoint: queryEndpoint,
                realtimeEndpoint: realtimeEndpoint
            )
            context.console.print(
                "cell_ingress_upserted cell_id=\(try entry.requireID()) status=\(entry.status) command_endpoint=\(entry.commandEndpoint) query_endpoint=\(entry.queryEndpoint) realtime_endpoint=\(entry.realtimeEndpoint)"
            )
            return
        }

        context.console.print("IM ops role initialized.")
    }
}

struct ConversationOutboxInspector {
    struct Snapshot {
        let shardID: String
        let pendingCount: Int
        let claimedCount: Int
        let failedCount: Int
        let oldestPendingAgeMillis: Int
    }

    let app: Application

    func inspect(shardID requestedShardID: String?) async throws -> [Snapshot] {
        try await routedDatabases(shardID: requestedShardID).asyncMap { shard in
            let unpublishedPendingEvents = try await ConversationDomainEvent.query(on: shard.database)
                .filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                .filter(\.$streamPublishedAt == nil)
                .all()
            let pendingCount = unpublishedPendingEvents.filter { $0.streamPublishStartedAt == nil }.count
            let claimedCount = unpublishedPendingEvents.filter { $0.streamPublishStartedAt != nil }.count
            let failedCount = try await ConversationDomainEvent.query(on: shard.database)
                .filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
                .count()
            let oldestPending = unpublishedPendingEvents.map(\.createdAt).min()
            return Snapshot(
                shardID: shard.shardID,
                pendingCount: pendingCount,
                claimedCount: claimedCount,
                failedCount: failedCount,
                oldestPendingAgeMillis: oldestPending.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
            )
        }
    }

    private func routedDatabases(shardID requestedShardID: String?) throws -> [RoutedShardDatabase] {
        let shards = app.conversationShardRouter.allCommandDatabases()
        guard let requestedShardID else {
            return shards
        }
        let filtered = shards.filter { $0.shardID == requestedShardID }
        guard !filtered.isEmpty else {
            throw Abort(.badRequest, reason: "Unknown conversation shard: \(requestedShardID)")
        }
        return filtered
    }
}

struct ConversationSearchLagInspector {
    struct Snapshot {
        let shardID: String
        let missingIndexRows: Int
        let staleIndexRows: Int
        let reindexedRows: Int
    }

    let app: Application

    func inspect(shardID requestedShardID: String?) async throws -> [Snapshot] {
        try await routedDatabases(shardID: requestedShardID).asyncMap { shard in
            var missing = 0
            var stale = 0
            let messages = try await ConversationMessage.query(on: shard.database)
                .sort(\.$createdAt, .descending)
                .limit(1_000)
                .all()
            for message in messages {
                let messageID = try message.requireID()
                guard let index = try await ConversationMessageSearchIndex.find(
                    ConversationMessageSearchIndex.recordID(messageID: messageID),
                    on: shard.database
                ) else {
                    missing += 1
                    continue
                }
                if index.serverSequence != message.serverSequence {
                    stale += 1
                }
            }
            return Snapshot(shardID: shard.shardID, missingIndexRows: missing, staleIndexRows: stale, reindexedRows: 0)
        }
    }

    func repair(shardID requestedShardID: String?, limit: Int) async throws -> [Snapshot] {
        try await routedDatabases(shardID: requestedShardID).asyncMap { shard in
            var missing = 0
            var stale = 0
            var reindexed = 0
            let messages = try await ConversationMessage.query(on: shard.database)
                .sort(\.$createdAt, .descending)
                .limit(limit)
                .all()
            let worker = ConversationSearchIndexWorker(db: shard.database)
            for message in messages {
                let messageID = try message.requireID()
                let index = try await ConversationMessageSearchIndex.find(
                    ConversationMessageSearchIndex.recordID(messageID: messageID),
                    on: shard.database
                )
                if index == nil {
                    missing += 1
                    try await worker.reindexMessage(messageID: messageID, on: shard.database)
                    reindexed += 1
                } else if index?.serverSequence != message.serverSequence {
                    stale += 1
                    try await worker.reindexMessage(messageID: messageID, on: shard.database)
                    reindexed += 1
                }
            }
            return Snapshot(
                shardID: shard.shardID,
                missingIndexRows: missing,
                staleIndexRows: stale,
                reindexedRows: reindexed
            )
        }
    }

    private func routedDatabases(shardID requestedShardID: String?) throws -> [RoutedShardDatabase] {
        let shards = app.conversationShardRouter.allCommandDatabases()
        guard let requestedShardID else {
            return shards
        }
        let filtered = shards.filter { $0.shardID == requestedShardID }
        guard !filtered.isEmpty else {
            throw Abort(.badRequest, reason: "Unknown conversation shard: \(requestedShardID)")
        }
        return filtered
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            result.append(value)
        }
        return result
    }
}
