import Fluent
import Foundation
import Vapor

/// Repairs reservations left behind when a command process exits between the
/// primary route reservation and the conversation-shard transaction result.
/// It deliberately verifies canonical state on the target shard before it
/// changes directory state, so a transient command failure cannot make a
/// route appear active.
struct ConversationRouteLifecycleReconciler {
    struct Result: Sendable, Equatable {
        var activatedCount = 0
        var abandonedCount = 0
        var skippedCount = 0
    }

    let app: Application

    func reconcilePendingRoutes(
        olderThan cutoff: Date,
        limit: Int
    ) async throws -> Result {
        let pendingEntries = try await ConversationDirectoryEntry.query(on: app.db)
            .filter(\.$routeState == ConversationRouteLifecycleState.pending.rawValue)
            .filter(\.$createdAt < cutoff)
            .sort(\.$createdAt, .ascending)
            .limit(max(1, limit))
            .all()

        var result = Result()
        for entry in pendingEntries {
            guard let conversationID = entry.id else {
                result.skippedCount += 1
                continue
            }

            let router = app.conversationShardRouter
            guard router.shardIDs.contains(entry.shardID) else {
                result.skippedCount += 1
                app.logger.warning(
                    "Pending conversation route reconciliation skipped unknown shard",
                    metadata: [
                        "conversation_id": .string(conversationID.uuidString),
                        "shard_id": .string(entry.shardID)
                    ]
                )
                continue
            }
            let commandDatabase = router.commandDatabase(forShardID: entry.shardID)

            if try await Conversation.find(conversationID, on: commandDatabase) != nil {
                entry.lifecycleState = .active
                entry.activatedAt = Date()
                try await entry.update(on: app.db)
                result.activatedCount += 1
            } else {
                entry.lifecycleState = .abandoned
                try await entry.update(on: app.db)
                result.abandonedCount += 1
            }
        }
        return result
    }
}
