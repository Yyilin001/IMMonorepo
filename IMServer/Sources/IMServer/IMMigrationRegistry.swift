import Fluent
import SQLKit
import Vapor

enum IMMigrationRegistry {
    static func registerMigrations(_ app: Application) {
        // 认证链路依赖 users + auth_sessions 两张表，以及后续的索引/约束迁移。
        app.migrations.add(CreateUser())
        app.migrations.add(AddUserProfileFields())
        app.migrations.add(EnsureUserProfileRevision())
        app.migrations.add(CreateUserContact())
        app.migrations.add(AddUserContactRemark())
        app.migrations.add(CreateFriendRequest())
        app.migrations.add(CreateContactChangesLog())
        app.migrations.add(CreateAuthSession())
        app.migrations.add(AddAuthSecuritySchema())
        app.migrations.add(AddAuthIndexes())
        app.migrations.add(EnforceSingleActiveDeviceSession())
        app.migrations.add(CreateConversation())
        app.migrations.add(AddConversationMembershipRevision())
        app.migrations.add(AddConversationLastMessageSequence())
        app.migrations.add(CreateConversationMember())
        app.migrations.add(AddConversationMemberLastReadSequence())
        app.migrations.add(AddConversationKind())
        app.migrations.add(AddConversationDirectMessagingState())
        app.migrations.add(AddConversationMemberRole())
        app.migrations.add(AddConversationMetadataAndPreferences())
        app.migrations.add(AddConversationMuteAndMemberNickname())
        app.migrations.add(CreateConversationMessage())
        app.migrations.add(AddConversationMessageDerivedState())
        app.migrations.add(AddConversationMessageClientMessageID())
        app.migrations.add(AddConversationMessageClientMessageIDUniqueIndex())
        app.migrations.add(AddConversationMessageTimelineIndexes())
        app.migrations.add(CreateConversationDomainEvent())
        app.migrations.add(AddConversationDomainEventRetryCount())
        app.migrations.add(AddConversationDomainEventStreamPublicationFields())
        app.migrations.add(AddConversationDomainEventStreamClaimFields())
        app.migrations.add(AddConversationDomainEventIndexes())
        app.migrations.add(AddConversationDomainEventActor())
        app.migrations.add(AddConversationDomainEventSideEffectKey())
        app.migrations.add(CreateContactDomainEvent())
        app.migrations.add(CreateOwnerDomainEventDelivery())
        app.migrations.add(CreateDomainEventSequencesAndTimelineNotices())
        app.migrations.add(CreateConversationRoutingDirectories())
        app.migrations.add(CreateDirectConversationPairDirectory())
        app.migrations.add(CreateConversationMessageSearchIndex())
        app.migrations.add(AddConversationMessageSearchResultFields())
        app.migrations.add(AddConversationMessageSearchIndexIndexes())
        app.migrations.add(CreateConversationMediaAssetReference())
        app.migrations.add(CreateConversationMediaAssetReferenceDirectory())
        app.migrations.add(CreateConversationUserSummary())
        app.migrations.add(AddConversationUserSummaryMembershipRevision())
        app.migrations.add(AddConversationUserSummaryDirectPeerProfileFields())
        app.migrations.add(AddConversationUserSummaryIndexes())
        app.migrations.add(AddConversationUserSummaryListOrderIndex())
        app.migrations.add(CreateConversationSummaryReadModelTables())
        app.migrations.add(AddConversationSummaryReadModelIndexes())
        app.migrations.add(CreateConversationEventAuxiliaryReadModelTables())
        app.migrations.add(AddConversationEventAuxiliaryReadModelIndexes())
        app.migrations.add(CreateConversationDomainEventRecipientSet())
        app.migrations.add(CreateConversationDomainEventRecipientSetMembers())
        app.migrations.add(CreateConversationDomainEventRecipientSnapshot())
        app.migrations.add(AddConversationDomainEventRecipientSnapshotHash())
        app.migrations.add(AddConversationSearchIndexLowerTrigramIndex())
        app.migrations.add(CreateIMCommonFeatureTables())
        app.migrations.add(AddIMCommonFeatureVisibilityIndexes())
        app.migrations.add(AddReportSnapshotFields())
        app.migrations.add(CreateAIMessageStreamIndex())
        app.migrations.add(EnforceV8SequenceInvariants())
        app.migrations.add(CreateConversationActivitySummaryReadModel())
        app.migrations.add(AddLargeGroupSummaryReadPathIndexes())
        app.migrations.add(AddTimelineReadPathIndexes())
        registerSummaryReadModelMigrations(app)
    }

    private static func registerSummaryReadModelMigrations(_ app: Application) {
        var databaseIDs: Set<DatabaseID> = []
        if app.imSummaryDatabaseEnabled {
            databaseIDs.insert(.imSummary)
        }
        for databaseID in app.summaryShardDatabaseIDs.values {
            databaseIDs.insert(databaseID)
        }

        for databaseID in databaseIDs {
            app.migrations.add([
                CreateConversationUserSummary(),
                AddConversationUserSummaryMembershipRevision(),
                AddConversationUserSummaryDirectPeerProfileFields(),
                AddConversationUserSummaryIndexes(),
                AddConversationUserSummaryListOrderIndex(),
                CreateConversationSummaryReadModelTables(),
                AddConversationSummaryReadModelIndexes(),
                CreateConversationActivitySummaryReadModel(),
                AddLargeGroupSummaryReadPathIndexes()
            ], to: databaseID)
        }
    }

    static func resetIMSchemaIfRequested(_ app: Application) async throws {
        guard app.shouldResetIMSchema else {
            return
        }

        guard app.environment == .development || app.environment == .testing else {
            throw Abort(.forbidden, reason: "--reset-im-schema is only available in development or testing.")
        }

        guard let sql = app.imWriteDB as? any SQLDatabase else {
            throw Abort(.badRequest, reason: "--reset-im-schema requires an SQL database.")
        }

        app.logger.notice("Resetting IM schema before auto-migrate")

        let tablesToDrop = [
            DirectConversationIndexEntry.schema,
            DirectConversationPairDirectory.schema,
            ConversationDirectoryEntry.schema,
            ConversationReadModelToken.schema,
            ConversationChangesLogEntry.schema,
            ConversationActivitySummary.schema,
            ConversationReplayRecord.schema,
            ConversationDomainEventRecipientSnapshot.schema,
            ConversationDomainEventRecipientSetMember.schema,
            ConversationDomainEventRecipientSet.schema,
            ConversationNotificationEntry.schema,
            MessageReceipt.schema,
            AIMessageStreamIndex.schema,
            PushDeviceToken.schema,
            GroupInvite.schema,
            UserReport.schema,
            UserBlock.schema,
            ContactChangeLogEntry.schema,
            ContactDomainEvent.schema,
            OwnerDomainEventDelivery.schema,
            ConversationDomainEventSideEffect.schema,
            OwnerDomainEventAggregateSequence.schema,
            OwnerDomainEventDeliveryCursor.schema,
            OwnerContactEventSequence.schema,
            ConversationDomainEventSequence.schema,
            ConversationTimelineNotice.schema,
            ConversationVisibilityOverride.schema,
            MessageVisibilityOverride.schema,
            MessageFavorite.schema,
            ConversationUserSummary.schema,
            ConversationMediaAssetReferenceDirectory.schema,
            ConversationMediaAssetReference.schema,
            ConversationMessageSearchIndex.schema,
            ConversationDomainEvent.schema,
            ConversationMessage.schema,
            ConversationMember.schema,
            Conversation.schema
        ]
        let dropSuffix = sql.dialect.name == "postgresql" ? " CASCADE" : ""

        for table in tablesToDrop {
            try await sql.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)\(unsafeRaw: dropSuffix)").run()
        }

        if try await fluentMigrationTableExists(on: sql) {
            for migrationName in imMigrationNames {
                try await sql.raw(
                    """
                    DELETE FROM \(unsafeRaw: "_fluent_migrations")
                    WHERE \(unsafeRaw: "name") = \(bind: migrationName)
                       OR \(unsafeRaw: "name") LIKE \(bind: "%.\(migrationName)")
                    """
                ).run()
            }
        }
    }

    private static func fluentMigrationTableExists(on sql: any SQLDatabase) async throws -> Bool {
        switch sql.dialect.name {
        case "postgresql":
            struct PostgresFluentMigrationTableRow: Decodable {
                let exists: String?
            }

            let row = try await sql.raw(
                "SELECT to_regclass('public._fluent_migrations') AS exists"
            ).first(decoding: PostgresFluentMigrationTableRow.self)
            return row?.exists != nil

        case "sqlite":
            struct SQLiteFluentMigrationTableRow: Decodable {
                let name: String?
            }

            let row = try await sql.raw(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '_fluent_migrations' LIMIT 1"
            ).first(decoding: SQLiteFluentMigrationTableRow.self)
            return row?.name != nil

        default:
            return false
        }
    }
}

private let imMigrationNames: [String] = [
    "CreateConversation",
    "AddConversationMembershipRevision",
    "AddConversationLastMessageSequence",
    "CreateConversationMember",
    "AddConversationMemberLastReadSequence",
    "AddConversationKind",
    "AddConversationDirectMessagingState",
    "AddConversationMemberRole",
    "AddConversationMetadataAndPreferences",
    "AddConversationMuteAndMemberNickname",
    "CreateConversationMessage",
    "AddConversationMessageDerivedState",
    "AddConversationMessageClientMessageID",
    "AddConversationMessageClientMessageIDUniqueIndex",
    "AddConversationMessageTimelineIndexes",
    "CreateConversationDomainEvent",
    "AddConversationDomainEventRetryCount",
    "AddConversationDomainEventStreamPublicationFields",
    "AddConversationDomainEventStreamClaimFields",
    "AddConversationDomainEventIndexes",
    "AddConversationDomainEventActor",
    "AddConversationDomainEventSideEffectKey",
    "CreateContactDomainEvent",
    "CreateOwnerDomainEventDelivery",
    "CreateDomainEventSequencesAndTimelineNotices",
    "CreateConversationRoutingDirectories",
    "CreateDirectConversationPairDirectory",
    "CreateConversationMessageSearchIndex",
    "AddConversationMessageSearchResultFields",
    "AddConversationMessageSearchIndexIndexes",
    "CreateConversationMediaAssetReference",
    "CreateConversationMediaAssetReferenceDirectory",
    "CreateConversationUserSummary",
    "AddConversationUserSummaryMembershipRevision",
    "AddConversationUserSummaryDirectPeerProfileFields",
    "AddConversationUserSummaryIndexes",
    "AddConversationUserSummaryListOrderIndex",
    "CreateConversationSummaryReadModelTables",
    "AddConversationSummaryReadModelIndexes",
    "CreateConversationEventAuxiliaryReadModelTables",
    "AddConversationEventAuxiliaryReadModelIndexes",
    "CreateConversationDomainEventRecipientSet",
    "CreateConversationDomainEventRecipientSetMembers",
    "CreateConversationDomainEventRecipientSnapshot",
    "AddConversationDomainEventRecipientSnapshotHash",
    "AddConversationSearchIndexLowerTrigramIndex",
    "CreateIMCommonFeatureTables",
    "AddIMCommonFeatureVisibilityIndexes",
    "AddReportSnapshotFields",
    "CreateAIMessageStreamIndex",
    "EnforceV8SequenceInvariants",
    "CreateContactChangesLog",
    "CreateConversationActivitySummaryReadModel",
    "AddLargeGroupSummaryReadPathIndexes",
    "AddTimelineReadPathIndexes"
]

private struct ResetIMSchemaStorageKey: StorageKey {
    typealias Value = Bool
}

extension Application {
    var shouldResetIMSchema: Bool {
        get { storage[ResetIMSchemaStorageKey.self] ?? false }
        set { storage[ResetIMSchemaStorageKey.self] = newValue }
    }
}
