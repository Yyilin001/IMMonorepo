import Fluent
import Foundation
import SQLKit
import Vapor

/// Performs the final route switch from the source Cell after a completed
/// copy. This intentionally keeps the source data intact: the source write
/// fence remains blocked after success so stale route users fail closed
/// instead of creating a split-brain timeline.
struct ConversationShardMigrationCutoverCoordinator {
    private static let leaseDuration: TimeInterval = 900

    let app: Application

    func cutover(conversationID: UUID, pageSize requestedPageSize: Int = 500) async throws -> ConversationShardMigration {
        let pageSize = min(max(requestedPageSize, 1), 1_000)
        let lease = try await claimLease(conversationID: conversationID)
        if lease.alreadyCutOver {
            guard let migration = try await ConversationShardMigration.find(conversationID, on: app.db) else {
                throw Abort(.notFound, reason: "Conversation shard migration disappeared after cutover.")
            }
            return migration
        }

        guard let migration = try await ConversationShardMigration.find(conversationID, on: app.db) else {
            throw Abort(.notFound, reason: "No prepared conversation shard migration exists for \(conversationID.uuidString).")
        }
        guard migration.sourceCellID == app.imRealtimeCellID else {
            throw Abort(.serviceUnavailable, reason: "Migration source belongs to Cell \(migration.sourceCellID); run cutover from that Cell.")
        }
        let sourceRoute = ConversationRoute(
            cellID: migration.sourceCellID,
            shardID: migration.sourceShardID,
            version: migration.sourceRouteVersion
        )
        let sourceDatabase = app.conversationShardRouter.commandDatabase(forShardID: migration.sourceShardID)

        do {
            try await ConversationWriteFenceService.blockWrites(
                conversationID: conversationID,
                on: sourceDatabase
            )

            let verification = try await ConversationShardMigrationCopyCoordinator(app: app)
                .verifyCanonicalState(migration: migration, pageSize: pageSize)
            guard verification.sourceFingerprint == migration.sourceFingerprint,
                  verification.targetFingerprint == migration.targetFingerprint
            else {
                throw Abort(.conflict, reason: "The frozen source/target fingerprint differs from the approved verification; copy and verify again before cutover.")
            }

            try await rebuildTargetSearchIndex(
                migration: migration,
                pageSize: pageSize
            )

            let newRoute = try await app.conversationDirectory.cutoverConversation(
                conversationID: conversationID,
                expectedRoute: sourceRoute,
                targetCellID: migration.targetCellID,
                targetShardID: migration.targetShardID
            )
            let completed = try await finishLease(
                conversationID: conversationID,
                token: lease.token,
                expectedTargetRoute: newRoute
            )
            await ConversationRecipientSetExistenceCache.shared.invalidateConversation(conversationID)
            return completed
        } catch {
            // A route update is the point of no return. Before it happens,
            // release the source fence and lease so normal traffic can resume.
            if let route = try? await app.conversationDirectory.route(for: conversationID), route == sourceRoute {
                try? await ConversationWriteFenceService.unblockWrites(
                    conversationID: conversationID,
                    on: sourceDatabase
                )
                try? await releaseLease(conversationID: conversationID, token: lease.token)
            }
            throw error
        }
    }

    private struct CutoverLease: Sendable {
        let token: String
        let alreadyCutOver: Bool
    }

    private func claimLease(conversationID: UUID) async throws -> CutoverLease {
        try await app.db.transaction { database in
            try await lockMigration(conversationID: conversationID, on: database)
            guard let migration = try await ConversationShardMigration.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "No prepared conversation shard migration exists for \(conversationID.uuidString).")
            }
            if migration.statusEnum == .cutover {
                return CutoverLease(token: migration.cutoverLeaseToken ?? "completed", alreadyCutOver: true)
            }
            guard migration.statusEnum == .readyToCutover else {
                throw Abort(.conflict, reason: "Migration \(conversationID.uuidString) is \(migration.status) and cannot enter cutover.")
            }
            guard let sourceFingerprint = migration.sourceFingerprint,
                  !sourceFingerprint.isEmpty,
                  let targetFingerprint = migration.targetFingerprint,
                  sourceFingerprint == targetFingerprint
            else {
                throw Abort(.conflict, reason: "Migration requires a successful canonical fingerprint verification before cutover.")
            }

            let token = UUID().uuidString.lowercased()
            migration.statusEnum = .cutoverPreparing
            migration.cutoverLeaseToken = token
            migration.cutoverLeaseExpiresAt = Date().addingTimeInterval(Self.leaseDuration)
            migration.updatedAt = Date()
            try await migration.update(on: database)
            return CutoverLease(token: token, alreadyCutOver: false)
        }
    }

    private func finishLease(
        conversationID: UUID,
        token: String,
        expectedTargetRoute: ConversationRoute
    ) async throws -> ConversationShardMigration {
        try await app.db.transaction { database in
            try await lockMigration(conversationID: conversationID, on: database)
            guard let migration = try await ConversationShardMigration.find(conversationID, on: database) else {
                throw Abort(.notFound, reason: "Conversation shard migration disappeared during cutover.")
            }
            guard migration.statusEnum == .cutoverPreparing,
                  migration.cutoverLeaseToken == token
            else {
                throw Abort(.conflict, reason: "Conversation shard migration cutover lease is no longer owned by this operation.")
            }
            guard expectedTargetRoute.cellID == migration.targetCellID,
                  expectedTargetRoute.shardID == migration.targetShardID,
                  expectedTargetRoute.version > migration.sourceRouteVersion
            else {
                throw Abort(.conflict, reason: "Directory route did not match the expected cutover target.")
            }
            migration.statusEnum = .cutover
            migration.cutoverAt = Date()
            migration.cutoverLeaseToken = nil
            migration.cutoverLeaseExpiresAt = nil
            migration.transferToken = nil
            migration.transferTokenExpiresAt = nil
            migration.lastErrorCode = nil
            migration.updatedAt = migration.cutoverAt ?? Date()
            try await migration.update(on: database)
            return migration
        }
    }

    private func releaseLease(conversationID: UUID, token: String) async throws {
        try await app.db.transaction { database in
            try await lockMigration(conversationID: conversationID, on: database)
            guard let migration = try await ConversationShardMigration.find(conversationID, on: database),
                  migration.statusEnum == .cutoverPreparing,
                  migration.cutoverLeaseToken == token
            else {
                return
            }
            migration.statusEnum = .readyToCutover
            migration.cutoverLeaseToken = nil
            migration.cutoverLeaseExpiresAt = nil
            migration.updatedAt = Date()
            try await migration.update(on: database)
        }
    }

    private func rebuildTargetSearchIndex(
        migration: ConversationShardMigration,
        pageSize: Int
    ) async throws {
        let conversationID = try migration.requireID()
        if migration.targetCellID == app.imRealtimeCellID {
            try await ConversationShardMigrationSearchIndexRebuilder.rebuild(
                app: app,
                conversationID: conversationID,
                database: app.conversationShardRouter.commandDatabase(forShardID: migration.targetShardID),
                pageSize: pageSize
            )
        } else {
            guard let leaseToken = migration.cutoverLeaseToken else {
                throw Abort(.conflict, reason: "Remote migration finalization requires the active cutover lease.")
            }
            try await ConversationShardMigrationRemoteTransfer(app: app, migration: migration)
                .finalizeSearchIndex(cutoverLeaseToken: leaseToken, pageSize: pageSize)
        }
    }

    private func lockMigration(conversationID: UUID, on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }
        try await sql.raw("""
            SELECT conversation_id
            FROM conversation_shard_migrations
            WHERE conversation_id = \(bind: conversationID)
            FOR UPDATE
            """).run()
    }
}
