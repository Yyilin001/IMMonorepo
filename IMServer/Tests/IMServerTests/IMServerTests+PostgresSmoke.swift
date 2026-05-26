@testable import IMServer
import Fluent
import FluentPostgresDriver
import SQLKit
import Vapor
import Testing

extension IMServerTests {
    @Test("Postgres smoke covers migrations and production SQL hot paths")
    func postgresSmokeCoversMigrationsAndProductionSQLHotPaths() async throws {
        guard let databaseURL = Environment.get("IM_POSTGRES_SMOKE_DATABASE_URL"),
              !databaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        try await withPostgresSmokeApp(databaseURL: databaseURL) { app in
            try await assertPostgresSmokeIndexesExist(on: app.db)
            try await assertPostgresSequenceRepairAndAllocation(on: app)
            try await assertPostgresMediaReferenceBatchUpsert(on: app)
            try await assertPostgresSearchLagAntiJoin(on: app)
            try assertPostgresGroupMemberLimitBoundary()
        }
    }

    private func withPostgresSmokeApp(
        databaseURL: String,
        _ body: (Application) async throws -> Void
    ) async throws {
        let schema = "im_smoke_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"
        let bootstrap = try await Application.make(.testing)
        bootstrap.databases.use(
            try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
            as: .psql
        )
        guard let bootstrapSQL = bootstrap.db(.psql) as? any SQLDatabase else {
            try? await bootstrap.asyncShutdown()
            throw Abort(.internalServerError, reason: "Postgres smoke database did not expose SQLDatabase.")
        }
        try await bootstrapSQL.raw("CREATE SCHEMA \(ident: schema)").run()
        try await bootstrap.asyncShutdown()

        let app = try await Application.make(.testing)
        var configuration = try SQLPostgresConfiguration(url: databaseURL)
        configuration.searchPath = [schema]
        app.databases.use(
            .postgres(configuration: configuration, maxConnectionsPerEventLoop: 1),
            as: .psql,
            isDefault: true
        )
        app.databases.default(to: .psql)
        app.imRuntimeRole = .ops
        app.imSummaryDatabaseEnabled = false
        IMMigrationRegistry.registerMigrations(app)

        do {
            try await app.autoMigrate()
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            try await dropPostgresSmokeSchema(databaseURL: databaseURL, schema: schema)
            throw error
        }

        try await app.asyncShutdown()
        try await dropPostgresSmokeSchema(databaseURL: databaseURL, schema: schema)
    }

    private func dropPostgresSmokeSchema(databaseURL: String, schema: String) async throws {
        let cleanup = try await Application.make(.testing)
        cleanup.databases.use(
            try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 1),
            as: .psql
        )
        if let sql = cleanup.db(.psql) as? any SQLDatabase {
            try await sql.raw("DROP SCHEMA IF EXISTS \(ident: schema) CASCADE").run()
        }
        try await cleanup.asyncShutdown()
    }

    private func assertPostgresSmokeIndexesExist(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Postgres smoke index check requires SQLDatabase.")
        }

        let indexNames = try await sql.raw("""
            SELECT \(ident: "indexname")
            FROM \(ident: "pg_indexes")
            WHERE \(ident: "schemaname") = current_schema()
              AND \(ident: "indexname") IN (
                \(bind: "im_messages_conversation_sequence_desc_idx"),
                \(bind: "conversation_media_asset_references_asset_idx"),
                \(bind: "conversation_media_asset_reference_directory_asset_idx")
              )
            """).all(decoding: PostgresIndexRow.self).map(\.indexname)
        let found = Set(indexNames)
        #expect(found.contains("im_messages_conversation_sequence_desc_idx"))
        #expect(found.contains("conversation_media_asset_references_asset_idx"))
        #expect(found.contains("conversation_media_asset_reference_directory_asset_idx"))
    }

    private func assertPostgresSequenceRepairAndAllocation(on app: Application) async throws {
        let sender = try await makeUser(email: "postgres-sequence@example.com", on: app)
        let senderID = try sender.requireID()
        let conversation = Conversation(
            title: "Postgres Sequence",
            kind: .group,
            updatedAt: Date(timeIntervalSince1970: 1_710_500_000),
            lastMessageSequence: 0
        )
        try await conversation.create(on: app.db)
        let conversationID = try conversation.requireID()
        try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner)
            .create(on: app.db)
        let existingMessage = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 7,
            content: .richText(.plain("existing"))
        )
        try await existingMessage.create(on: app.db)

        try await ConversationSequenceCounterRepairService(db: app.db).reconcileLastMessageSequences()
        let reserved = try await ConversationSequenceAllocator(db: app.db).reserve(
            count: 3,
            conversationID: conversationID,
            updatedAt: Date(timeIntervalSince1970: 1_710_500_010)
        )
        #expect(reserved == [8, 9, 10])

        let reloaded = try #require(try await Conversation.find(conversationID, on: app.db))
        #expect(reloaded.lastMessageSequence == 10)
    }

    private func assertPostgresMediaReferenceBatchUpsert(on app: Application) async throws {
        let sender = try await makeUser(email: "postgres-media-sender@example.com", on: app)
        let peer = try await makeUser(email: "postgres-media-peer@example.com", on: app)
        let senderID = try sender.requireID()
        let peerID = try peer.requireID()
        let conversation = Conversation(
            title: "Postgres Media",
            kind: .group,
            updatedAt: Date(timeIntervalSince1970: 1_710_600_000)
        )
        try await conversation.create(on: app.db)
        let conversationID = try conversation.requireID()
        try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner)
            .create(on: app.db)
        try await ConversationMember(conversationID: conversationID, userID: peerID)
            .create(on: app.db)

        let asset = IMMediaAsset(
            assetID: "postgres-smoke-asset",
            kind: .file,
            mimeType: "application/pdf",
            byteSize: 1024,
            filename: "smoke.pdf",
            width: nil,
            height: nil,
            durationMillis: nil,
            previewAssetID: nil
        )
        let mediaMessage = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 1,
            content: .file(asset)
        )
        try await mediaMessage.create(on: app.db)
        let textMessage = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 2,
            content: .richText(.plain("not media"))
        )
        try await textMessage.create(on: app.db)
        let mediaMessageID = try mediaMessage.requireID()
        let textMessageID = try textMessage.requireID()

        let references = try await ConversationMediaAssetReferenceService(db: app.db).syncMessageReferences(
            conversationID: conversationID,
            messageIDs: [mediaMessageID, textMessageID],
            on: app.db
        )
        try await ConversationMediaAssetReferenceDirectoryService(db: app.db).sync(
            referencesByMessageID: references,
            shardID: SingleShardConversationShardRouter.defaultShardID,
            on: app.db
        )

        let reference = try #require(
            try await ConversationMediaAssetReference.find(
                ConversationMediaAssetReference.recordID(messageID: mediaMessageID),
                on: app.db
            )
        )
        #expect(reference.assetID == asset.assetID)
        let directory = try #require(
            try await ConversationMediaAssetReferenceDirectory.find(
                ConversationMediaAssetReferenceDirectory.recordID(messageID: mediaMessageID),
                on: app.db
            )
        )
        #expect(directory.assetID == asset.assetID)
        #expect(directory.shardID == SingleShardConversationShardRouter.defaultShardID)

        try mediaMessage.replaceDerivedState(.init(recallState: .recalled))
        try await mediaMessage.update(on: app.db)
        let removedReferences = try await ConversationMediaAssetReferenceService(db: app.db).syncMessageReferences(
            conversationID: conversationID,
            messageIDs: [mediaMessageID],
            on: app.db
        )
        try await ConversationMediaAssetReferenceDirectoryService(db: app.db).sync(
            referencesByMessageID: removedReferences,
            shardID: SingleShardConversationShardRouter.defaultShardID,
            on: app.db
        )
        #expect(try await ConversationMediaAssetReference.find(
            ConversationMediaAssetReference.recordID(messageID: mediaMessageID),
            on: app.db
        ) == nil)
        #expect(try await ConversationMediaAssetReferenceDirectory.find(
            ConversationMediaAssetReferenceDirectory.recordID(messageID: mediaMessageID),
            on: app.db
        ) == nil)
    }

    private func assertPostgresSearchLagAntiJoin(on app: Application) async throws {
        let sender = try await makeUser(email: "postgres-search@example.com", on: app)
        let senderID = try sender.requireID()
        let conversation = Conversation(
            title: "Postgres Search",
            kind: .group,
            updatedAt: Date(timeIntervalSince1970: 1_710_700_000)
        )
        try await conversation.create(on: app.db)
        let conversationID = try conversation.requireID()
        try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner)
            .create(on: app.db)
        let indexed = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 1,
            content: .richText(.plain("indexed"))
        )
        try await indexed.create(on: app.db)
        let stale = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 2,
            content: .richText(.plain("stale"))
        )
        try await stale.create(on: app.db)
        let missing = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderID,
            serverSequence: 3,
            content: .richText(.plain("missing"))
        )
        try await missing.create(on: app.db)

        let indexedID = try indexed.requireID()
        let staleID = try stale.requireID()
        try await ConversationMessageSearchIndex(
            messageID: indexedID,
            conversationID: conversationID,
            serverSequence: indexed.serverSequence,
            messageType: indexed.kind,
            senderUserID: senderID,
            searchableText: "indexed",
            createdAt: indexed.createdAt ?? Date(),
            updatedAt: Date()
        ).create(on: app.db)
        try await ConversationMessageSearchIndex(
            messageID: staleID,
            conversationID: conversationID,
            serverSequence: stale.serverSequence - 1,
            messageType: stale.kind,
            senderUserID: senderID,
            searchableText: "stale",
            createdAt: stale.createdAt ?? Date(),
            updatedAt: Date()
        ).create(on: app.db)

        let lagCreatedAt = try await ConversationSearchLagReader(database: app.db)
            .oldestMissingOrStaleIndexCreatedAt(recentMessageLimit: 100)
        #expect(lagCreatedAt != nil)
    }

    private func assertPostgresGroupMemberLimitBoundary() throws {
        let configuration = IMGroupMemberLimitConfiguration(limit: 500)
        try IMGroupMemberLimitGuard.validateGroupMemberCount(500, configuration: configuration)
        do {
            try IMGroupMemberLimitGuard.validateGroupMemberCount(501, configuration: configuration)
            Issue.record("Expected Postgres smoke group member boundary to reject 501 members")
        } catch let abort as any AbortError {
            #expect(abort.status == .badRequest)
        } catch {
            Issue.record("Unexpected group member limit error: \(error)")
        }
    }
}

private struct PostgresIndexRow: Decodable {
    let indexname: String
}
