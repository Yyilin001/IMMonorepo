import Fluent
import Foundation
import Vapor

/// Read-only safety gate for a future physical conversation-shard migration.
///
/// A directory update alone is never a migration: it would route traffic to a
/// shard that may not have the canonical timeline state. This inspector proves
/// that a source route is active and reports whether a target shard is clean
/// before a copy worker is allowed to start. It deliberately does not mutate
/// either shard or the conversation directory.
struct ConversationShardMigrationPreflight {
    struct CanonicalDataSnapshot: Content, Sendable, Equatable {
        let conversationCount: Int
        let memberCount: Int
        let messageCount: Int
        let domainEventCount: Int
        let domainEventSequenceCount: Int
        let timelineNoticeCount: Int
        let mediaReferenceCount: Int
        let recipientSnapshotCount: Int

        var totalCount: Int {
            conversationCount
                + memberCount
                + messageCount
                + domainEventCount
                + domainEventSequenceCount
                + timelineNoticeCount
                + mediaReferenceCount
                + recipientSnapshotCount
        }

        var isEmpty: Bool { totalCount == 0 }
    }

    struct Result: Sendable, Equatable {
        let conversationID: UUID
        let sourceRoute: ConversationRoute
        let targetShardID: String
        let source: CanonicalDataSnapshot
        let target: CanonicalDataSnapshot
        let blockers: [String]

        var isReadyToCopy: Bool { blockers.isEmpty }
    }

    let app: Application

    func inspect(
        conversationID: UUID,
        targetShardID: String,
        targetCellID requestedTargetCellID: String? = nil
    ) async throws -> Result {
        let targetCellID = requestedTargetCellID ?? app.imRealtimeCellID
        let sourceRoute = try await app.conversationDirectory.route(for: conversationID)
        guard sourceRoute.cellID == app.imRealtimeCellID else {
            throw Abort(
                .serviceUnavailable,
                reason: "Conversation \(conversationID.uuidString) belongs to remote Cell \(sourceRoute.cellID); run shard migration preflight in that Cell."
            )
        }
        try Self.validateTarget(
            sourceRoute: sourceRoute,
            targetCellID: targetCellID,
            targetShardID: targetShardID
        )
        guard targetCellID != app.imRealtimeCellID || app.conversationShardRouter.shardIDs.contains(targetShardID) else {
            throw Abort(.badRequest, reason: "Unknown conversation target shard: \(targetShardID)")
        }

        let source = try await snapshot(
            conversationID: conversationID,
            database: app.conversationShardRouter.commandDatabase(forShardID: sourceRoute.shardID)
        )
        let target: CanonicalDataSnapshot
        if targetCellID == app.imRealtimeCellID {
            target = try await snapshot(
                conversationID: conversationID,
                database: app.conversationShardRouter.commandDatabase(forShardID: targetShardID)
            )
        } else {
            target = try await remoteTargetSnapshot(
                conversationID: conversationID,
                targetCellID: targetCellID,
                targetShardID: targetShardID
            )
        }

        var blockers: [String] = []
        if source.conversationCount != 1 {
            blockers.append("source_conversation_count=\(source.conversationCount), expected=1")
        }
        if !target.isEmpty {
            blockers.append("target_contains_existing_conversation_data")
        }
        let unfinishedEventCount = try await ConversationDomainEvent.query(
            on: app.conversationShardRouter.commandDatabase(forShardID: sourceRoute.shardID)
        )
        .filter(\.$conversationID == conversationID)
        .filter(\.$status != ConversationDomainEventStatus.processed.rawValue)
        .count()
        if unfinishedEventCount > 0 {
            blockers.append("source_has_unfinished_domain_events=\(unfinishedEventCount)")
        }
        let activeAIStreamCount = try await AIMessageStreamIndex.query(
            on: app.conversationShardRouter.commandDatabase(forShardID: sourceRoute.shardID)
        )
        .filter(\.$conversationID == conversationID)
        .filter(\.$state == MessageStreamLifecycleState.streaming.rawValue)
        .count()
        if activeAIStreamCount > 0 {
            blockers.append("source_has_active_ai_streams=\(activeAIStreamCount)")
        }

        return Result(
            conversationID: conversationID,
            sourceRoute: sourceRoute,
            targetShardID: targetShardID,
            source: source,
            target: target,
            blockers: blockers
        )
    }

    private func remoteTargetSnapshot(
        conversationID: UUID,
        targetCellID: String,
        targetShardID: String
    ) async throws -> CanonicalDataSnapshot {
        guard let endpoint = try await app.cellIngressEndpointResolver.endpoint(
            for: targetCellID,
            purpose: .command
        ) else {
            throw Abort(.serviceUnavailable, reason: "No command ingress endpoint is configured for target Cell \(targetCellID).")
        }
        guard let sharedSecret = app.cellIngressConfiguration.sharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "Cross-Cell migration preflight requires IM_CELL_INGRESS_SHARED_SECRET.")
        }
        let response = try await app.client.post(
            URI(string: "\(endpoint)/internal/im/migrations/target-preflight")
        ) { request in
            request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
            try request.content.encode(
                IMCellShardMigrationTargetPreflightRequest(
                    conversationID: conversationID,
                    originCellID: app.imRealtimeCellID,
                    targetCellID: targetCellID,
                    targetShardID: targetShardID
                )
            )
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "Target Cell \(targetCellID) rejected migration preflight with HTTP \(response.status.code).")
        }
        return try response.content.decode(ConversationShardMigrationPreflight.CanonicalDataSnapshot.self)
    }

    func snapshot(
        conversationID: UUID,
        database: any Database
    ) async throws -> CanonicalDataSnapshot {
        async let conversationCount = Conversation.query(on: database)
            .filter(\.$id == conversationID)
            .count()
        async let memberCount = ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .count()
        async let messageCount = ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .count()
        async let domainEventCount = ConversationDomainEvent.query(on: database)
            .filter(\.$conversationID == conversationID)
            .count()
        async let domainEventSequenceCount = ConversationDomainEventSequence.query(on: database)
            .filter(\.$id == conversationID)
            .count()
        async let timelineNoticeCount = ConversationTimelineNotice.query(on: database)
            .filter(\.$conversationID == conversationID)
            .count()
        async let mediaReferenceCount = ConversationMediaAssetReference.query(on: database)
            .filter(\.$conversationID == conversationID)
            .count()
        async let recipientSnapshotCount = ConversationDomainEventRecipientSnapshot.query(on: database)
            .filter(\.$conversationID == conversationID)
            .count()

        return try await CanonicalDataSnapshot(
            conversationCount: conversationCount,
            memberCount: memberCount,
            messageCount: messageCount,
            domainEventCount: domainEventCount,
            domainEventSequenceCount: domainEventSequenceCount,
            timelineNoticeCount: timelineNoticeCount,
            mediaReferenceCount: mediaReferenceCount,
            recipientSnapshotCount: recipientSnapshotCount
        )
    }

    static func validateTarget(
        sourceRoute: ConversationRoute,
        targetCellID: String,
        targetShardID: String
    ) throws {
        guard targetCellID != sourceRoute.cellID || sourceRoute.shardID != targetShardID else {
            throw Abort(.badRequest, reason: "A same-Cell migration target must differ from source shard \(sourceRoute.shardID).")
        }
    }
}

/// Creates an immutable migration intent after the read-only preflight has
/// passed. For a remote destination, the control record carries a short-lived
/// transfer capability; the actual target write remains an explicit,
/// checksummed page protocol rather than a directory-only route change.
struct ConversationShardMigrationCoordinator {
    private static let transferCapabilityLifetime: TimeInterval = 24 * 60 * 60

    let app: Application

    func prepare(
        conversationID: UUID,
        targetShardID: String,
        targetCellID requestedTargetCellID: String? = nil
    ) async throws -> ConversationShardMigration {
        let targetCellID = requestedTargetCellID ?? app.imRealtimeCellID
        let preflight = try await ConversationShardMigrationPreflight(app: app).inspect(
            conversationID: conversationID,
            targetShardID: targetShardID,
            targetCellID: targetCellID
        )
        guard preflight.isReadyToCopy else {
            throw Abort(
                .conflict,
                reason: "Conversation shard migration preflight failed: \(preflight.blockers.joined(separator: ", "))."
            )
        }

        if let existing = try await ConversationShardMigration.find(conversationID, on: app.db) {
            guard existing.sourceCellID == preflight.sourceRoute.cellID,
                  existing.sourceShardID == preflight.sourceRoute.shardID,
                  existing.sourceRouteVersion == preflight.sourceRoute.version,
                  existing.targetShardID == targetShardID,
                  existing.targetCellID == targetCellID,
                  existing.statusEnum == .prepared
            else {
                throw Abort(
                    .conflict,
                    reason: "Conversation \(conversationID.uuidString) already has migration state \(existing.status)."
                )
            }
            return existing
        }

        let migration = ConversationShardMigration(
            conversationID: conversationID,
            sourceRoute: preflight.sourceRoute,
            targetCellID: targetCellID,
            targetShardID: targetShardID,
            source: preflight.source
        )
        do {
            // Create the source-shard fence before publishing the migration
            // intent. Future canonical write paths lock this row, allowing a
            // later cutover phase to drain them without a timing window.
            try await ConversationWriteFenceService.ensureWritableFence(
                conversationID: conversationID,
                on: app.conversationShardRouter.commandDatabase(forShardID: preflight.sourceRoute.shardID)
            )
            try await migration.create(on: app.db)
            return migration
        } catch {
            // The primary key is the conversation ID. A concurrent identical
            // prepare is idempotent; a conflicting one is rejected explicitly.
            if let existing = try await ConversationShardMigration.find(conversationID, on: app.db),
               existing.sourceCellID == preflight.sourceRoute.cellID,
               existing.sourceShardID == preflight.sourceRoute.shardID,
               existing.sourceRouteVersion == preflight.sourceRoute.version,
               existing.targetShardID == targetShardID,
               existing.targetCellID == targetCellID,
               existing.statusEnum == .prepared {
                return existing
            }
            throw error
        }
    }

    /// Rotates an expiring remote-transfer capability without changing the
    /// prepared source route, target binding, or copy watermarks.
    func renewTransferCapability(conversationID: UUID) async throws -> ConversationShardMigration {
        guard let migration = try await ConversationShardMigration.find(conversationID, on: app.db) else {
            throw Abort(.notFound, reason: "No conversation shard migration exists for \(conversationID.uuidString).")
        }
        guard migration.sourceCellID == app.imRealtimeCellID,
              migration.targetCellID != app.imRealtimeCellID,
              [.prepared, .copying, .copied, .verifying, .readyToCutover].contains(migration.statusEnum)
        else {
            throw Abort(.conflict, reason: "Only an active remote migration source can renew its transfer capability.")
        }
        migration.transferToken = UUID().uuidString.lowercased()
        migration.transferTokenExpiresAt = Date().addingTimeInterval(Self.transferCapabilityLifetime)
        migration.updatedAt = Date()
        try await migration.update(on: app.db)
        return migration
    }
}
