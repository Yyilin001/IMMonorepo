import SQLKit
import Vapor

enum IMSchemaValidator {
    static func validateIMSchema(_ app: Application) async throws {
        guard let writeSQL = app.imWriteDB as? any SQLDatabase else {
            return
        }

        try await validateIMSchema(
            on: writeSQL,
            role: "primary",
            environment: app.environment,
            logger: app.logger,
            resetAllowed: app.environment == .development || app.environment == .testing
        )

        if app.imReplicaDatabaseEnabled,
           let readSQL = app.imReadDB as? any SQLDatabase {
            try await validateIMSchema(
                on: readSQL,
                role: "replica",
                environment: app.environment,
                logger: app.logger,
                resetAllowed: false
            )
        }
    }

    private static func validateIMSchema(
        on sql: any SQLDatabase,
        role: String,
        environment: Environment,
        logger: Logger,
        resetAllowed: Bool
    ) async throws {
        for requirement in imSchemaRequirements {
            let existingColumns = try await fetchColumnNames(
                in: requirement.table,
                on: sql
            )
            let missingColumns = requirement.requiredColumns.subtracting(existingColumns)
            guard missingColumns.isEmpty else {
                let missing = missingColumns.sorted().joined(separator: ", ")
                let reason: String
                if resetAllowed {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. This database is from an older incompatible IM schema. Restart with --reset-im-schema to rebuild the IM tables from current migrations."
                } else {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. The database schema does not match the current IM server build."
                }

                logger.critical(.init(stringLiteral: reason))
                throw Abort(.internalServerError, reason: reason)
            }
        }
    }

    private static func fetchColumnNames(
        in table: String,
        on sql: any SQLDatabase
    ) async throws -> Set<String> {
        switch sql.dialect.name {
        case "postgresql":
            struct PostgresColumnRow: Decodable {
                let column_name: String
            }

            let rows = try await sql.raw(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = \(bind: table)
                """
            ).all(decoding: PostgresColumnRow.self)
            return Set(rows.map(\.column_name))

        case "sqlite":
            struct SQLiteColumnRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw(
                "PRAGMA table_info(\(unsafeRaw: table));"
            ).all(decoding: SQLiteColumnRow.self)
            return Set(rows.map(\.name))

        default:
            return []
        }
    }
}

private struct IMTableSchemaRequirement {
    let table: String
    let requiredColumns: Set<String>
}

private let imSchemaRequirements: [IMTableSchemaRequirement] = [
    IMTableSchemaRequirement(
        table: Conversation.schema,
        requiredColumns: [
            "id",
            "title",
            "notice",
            "kind",
            "avatar_preset",
            "direct_messaging_state",
            "last_message_sequence",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMember.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "user_id",
            "visible_from_sequence",
            "last_read_sequence",
            "role",
            "joined_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMessage.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "sender_user_id",
            "kind",
            "body_json",
            "client_message_id",
            "server_sequence",
            "derived_state_json",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationDomainEvent.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "event_type",
            "payload_json",
            "status",
            "retry_count",
            "processing_started_at",
            "processed_at",
            "error_message",
            "stream_published_at",
            "stream_publish_error",
            "stream_publish_started_at",
            "stream_publish_claimed_by",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMessageSearchIndex.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "message_id",
            "server_sequence",
            "searchable_text",
            "message_type",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMediaAssetReference.schema,
        requiredColumns: [
            "id",
            "asset_id",
            "owner_user_id",
            "conversation_id",
            "message_id",
            "server_sequence",
            "kind",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationUserSummary.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "conversation_id",
            "title",
            "notice",
            "avatar_preset",
            "kind",
            "direct_messaging_state",
            "direct_peer_user_id",
            "direct_peer_email",
            "direct_peer_display_name",
            "direct_peer_avatar_preset",
            "member_count",
            "member_user_ids_json",
            "last_message_json",
            "last_read_sequence",
            "unread_count",
            "last_activity_at",
            "is_removed",
            "is_pinned",
            "is_muted",
            "pinned_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationChangesLogEntry.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "conversation_id",
            "summary_record_id",
            "updated_at",
            "is_removed"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationReadModelToken.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "target_token",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationNotificationEntry.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "event_id",
            "conversation_id",
            "event_type",
            "payload_json",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationReplayRecord.schema,
        requiredColumns: [
            "id",
            "event_id",
            "consumer_group_id",
            "source_topic",
            "conversation_id",
            "event_type",
            "producer_shard",
            "payload_json",
            "status",
            "last_error",
            "receive_count",
            "replayed_at",
            "created_at",
            "updated_at"
        ]
    )
]
