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

        @Option(name: "shard", help: "Conversation shard ID for shard-scoped operations.")
        var shard: String?

        @Option(name: "limit", short: "l", help: "Maximum number of conversation outbox events to relay.")
        var limit: Int?
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
