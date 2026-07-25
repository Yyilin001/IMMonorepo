import SQLKit
import Vapor

enum IMSchemaValidator {
    static func validateIMSchema(_ app: Application) async throws {
        // The default database owns user/auth/admin directory data. In a
        // sharded deployment `imWriteDB` is a conversation shard, so using it
        // here would incorrectly require primary tables on every shard.
        guard let writeSQL = app.db as? any SQLDatabase else {
            return
        }

        try await validateIMSchema(
            on: writeSQL,
            role: "primary",
            environment: app.environment,
            logger: app.logger,
            resetAllowed: app.environment == .development || app.environment == .testing,
            tableRequirements: imSchemaRequirements,
            indexRequirements: imIndexRequirements
        )

        if app.imReplicaDatabaseEnabled,
           let readSQL = app.db(.imReplica) as? any SQLDatabase {
            try await validateIMSchema(
                on: readSQL,
                role: "replica",
                environment: app.environment,
                logger: app.logger,
                resetAllowed: false,
                tableRequirements: imSchemaRequirements,
                indexRequirements: imIndexRequirements
            )
        }

        try await validateSummaryShardSchemas(app)
        try await validateConversationShardSchemas(app)
    }

    private static func validateSummaryShardSchemas(_ app: Application) async throws {
        var databasesByShardID = app.summaryShardDatabaseIDs
        if app.imSummaryDatabaseEnabled,
           databasesByShardID.values.contains(.imSummary) == false {
            databasesByShardID["summary"] = .imSummary
        }

        for (shardID, databaseID) in databasesByShardID {
            guard let summarySQL = app.db(databaseID) as? any SQLDatabase else {
                continue
            }
            try await validateIMSchema(
                on: summarySQL,
                role: "summary-shard:\(shardID)",
                environment: app.environment,
                logger: app.logger,
                resetAllowed: app.environment == .development || app.environment == .testing,
                tableRequirements: imSummaryReadModelSchemaRequirements,
                indexRequirements: imSummaryReadModelIndexRequirements
            )
        }
    }

    private static func validateConversationShardSchemas(_ app: Application) async throws {
        let router = app.conversationShardRouter
        for shard in router.allCommandDatabases() {
            guard let conversationSQL = shard.database as? any SQLDatabase else {
                continue
            }
            try await validateIMSchema(
                on: conversationSQL,
                role: "conversation-shard:\(shard.shardID)",
                environment: app.environment,
                logger: app.logger,
                resetAllowed: app.environment == .development || app.environment == .testing,
                tableRequirements: imConversationShardSchemaRequirements,
                indexRequirements: imConversationShardIndexRequirements
            )
        }
    }

    private static func validateIMSchema(
        on sql: any SQLDatabase,
        role: String,
        environment: Environment,
        logger: Logger,
        resetAllowed: Bool,
        tableRequirements: [IMTableSchemaRequirement],
        indexRequirements: [IMTableIndexRequirement]
    ) async throws {
        for requirement in tableRequirements {
            let existingColumns = try await fetchColumnNames(
                in: requirement.table,
                on: sql
            )
            let missingColumns = requirement.requiredColumns.subtracting(existingColumns)
            guard missingColumns.isEmpty else {
                let missing = missingColumns.sorted().joined(separator: ", ")
                let reason: String
                if resetAllowed {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. Reset the IM schema with --reset-im-schema to rebuild the IM tables from current migrations."
                } else {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. The database schema does not match the current IM server build."
                }

                logger.critical(.init(stringLiteral: reason))
                throw Abort(.internalServerError, reason: reason)
            }
        }

        for requirement in indexRequirements {
            let existingIndexes = try await fetchIndexNames(
                in: requirement.table,
                on: sql
            )
            let missingIndexes = requirement.requiredIndexes.subtracting(existingIndexes)
            guard missingIndexes.isEmpty else {
                let missing = missingIndexes.sorted().joined(separator: ", ")
                let reason: String
                if resetAllowed {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing indexes [\(missing)]. Reset the IM schema with --reset-im-schema to rebuild the IM tables from current migrations."
                } else {
                    reason = "IM schema validation failed on \(role): table \(requirement.table) is missing indexes [\(missing)]. Run the current IM migrations before starting this role."
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

    private static func fetchIndexNames(
        in table: String,
        on sql: any SQLDatabase
    ) async throws -> Set<String> {
        switch sql.dialect.name {
        case "postgresql":
            struct PostgresIndexRow: Decodable {
                let indexname: String
            }

            let rows = try await sql.raw(
                """
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = \(bind: table)
                """
            ).all(decoding: PostgresIndexRow.self)
            return Set(rows.map(\.indexname))

        case "sqlite":
            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw(
                "PRAGMA index_list(\(unsafeRaw: table));"
            ).all(decoding: SQLiteIndexRow.self)
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

private struct IMTableIndexRequirement {
    let table: String
    let requiredIndexes: Set<String>
}

private let imSchemaRequirements: [IMTableSchemaRequirement] = [
    IMTableSchemaRequirement(
        table: User.schema,
        requiredColumns: [
            "id",
            "email",
            "password_hash",
            "status",
            "display_name",
            "avatar_preset",
            "profile_revision",
            "email_verified_at",
            "admin_role",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: AdminAuditEvent.schema,
        requiredColumns: [
            "id",
            "actor",
            "action",
            "target_type",
            "target_id",
            "request_id",
            "ip_address",
            "metadata_json",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: AdminConversationGovernanceCommand.schema,
        requiredColumns: [
            "id",
            "action",
            "conversation_id",
            "target_shard_id",
            "target_cell_id",
            "target_route_version",
            "actor",
            "actor_user_id",
            "actor_role",
            "authentication_method",
            "idempotency_key",
            "request_digest",
            "requested_mute_all",
            "requested_group_lifecycle_state",
            "target_member_user_id",
            "destructive_confirmed",
            "reason",
            "status",
            "attempt_count",
            "last_error_code",
            "processing_token",
            "processing_started_at",
            "accepted_at",
            "applied_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ReportModerationDecision.schema,
        requiredColumns: [
            "id",
            "report_id",
            "reviewer_actor",
            "reviewer_user_id",
            "reviewer_role",
            "authentication_method",
            "previous_status",
            "status",
            "resolution_category",
            "handled_note",
            "request_id",
            "idempotency_key",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: UserReport.schema,
        requiredColumns: [
            "id",
            "reporter_user_id",
            "target_type",
            "target_id",
            "conversation_id",
            "message_id",
            "reason",
            "detail",
            "message_snapshot_json",
            "handled_note",
            "assigned_reviewer_user_id",
            "assigned_reviewer_actor",
            "assigned_at",
            "status",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ReportModerationEvidence.schema,
        requiredColumns: [
            "id",
            "report_id",
            "evidence_url",
            "label",
            "submitted_by_actor",
            "submitted_by_user_id",
            "submitter_role",
            "authentication_method",
            "request_id",
            "idempotency_key",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: Conversation.schema,
        requiredColumns: [
            "id",
            "title",
            "notice",
            "kind",
            "avatar_preset",
            "direct_messaging_state",
            "group_lifecycle_state",
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
            "is_pinned",
            "pinned_at",
            "is_muted",
            "joined_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationDirectoryEntry.schema,
        requiredColumns: [
            "conversation_id",
            "shard_id",
            "cell_id",
            "route_state",
            "route_version",
            "created_at",
            "updated_at",
            "activated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: IMRealtimeCellRegistryEntry.schema,
        requiredColumns: [
            "cell_id",
            "status",
            "command_endpoint",
            "query_endpoint",
            "realtime_endpoint",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: CrossCellRealtimeDispatch.schema,
        requiredColumns: [
            "id",
            "origin_cell_id",
            "target_cell_id",
            "dedupe_key",
            "envelope_json",
            "status",
            "retry_count",
            "next_attempt_at",
            "processing_started_at",
            "delivered_at",
            "error_message",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: AIStreamLease.schema,
        requiredColumns: [
            "stream_id", "conversation_id", "user_id", "node_id", "state",
            "cancel_requested", "expires_at", "created_at", "updated_at"
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
            "group_lifecycle_state",
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
    ),
    IMTableSchemaRequirement(
        table: ConversationDomainEventRecipientSet.schema,
        requiredColumns: [
            "recipient_hash",
            "recipient_user_ids_json",
            "recipient_count",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationDomainEventRecipientSetMember.schema,
        requiredColumns: [
            "id",
            "recipient_hash",
            "user_id",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationDomainEventRecipientSnapshot.schema,
        requiredColumns: [
            "event_id",
            "conversation_id",
            "recipient_user_ids_json",
            "recipient_count",
            "recipient_hash",
            "created_at"
        ]
    )
]

private let imIndexRequirements: [IMTableIndexRequirement] = [
    IMTableIndexRequirement(
        table: IMRealtimeCellRegistryEntry.schema,
        requiredIndexes: [
            "im_realtime_cell_registry_status_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: CrossCellRealtimeDispatch.schema,
        requiredIndexes: [
            "cross_cell_realtime_dispatch_ready_idx",
            "cross_cell_realtime_dispatch_dedupe_uidx"
        ]
    ),
    IMTableIndexRequirement(
        table: AIStreamLease.schema,
        requiredIndexes: [
            "im_ai_stream_leases_user_expires_idx",
            "im_ai_stream_leases_conversation_expires_idx",
            "im_ai_stream_leases_expires_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationMessage.schema,
        requiredIndexes: [
            "im_messages_conversation_timeline_sequence_idx",
            "im_messages_conversation_timeline_server_sequence_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationUserSummary.schema,
        requiredIndexes: [
            "im_conversation_user_summaries_list_order_idx",
            "im_conversation_user_summaries_kind_list_order_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationChangesLogEntry.schema,
        requiredIndexes: [
            "conversation_changes_log_owner_updated_idx",
            "conversation_changes_log_owner_conversation_updated_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationReadModelToken.schema,
        requiredIndexes: [
            "conversation_read_model_tokens_owner_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationActivitySummary.schema,
        requiredIndexes: [
            "conversation_activity_summaries_updated_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationDomainEventRecipientSetMember.schema,
        requiredIndexes: [
            "conversation_domain_event_recipient_set_members_hash_user_idx",
            "conversation_domain_event_recipient_set_members_user_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: AdminAuditEvent.schema,
        requiredIndexes: [
            "admin_audit_events_created_idx",
            "admin_audit_events_action_created_idx",
            "admin_audit_events_actor_created_idx",
            "admin_audit_events_target_created_idx",
            "admin_audit_events_request_id_created_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: AdminWriteIdempotencyRecord.schema,
        requiredIndexes: [
            "admin_write_idempotency_scope_key_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: AdminConversationGovernanceCommand.schema,
        requiredIndexes: [
            "admin_governance_command_actor_action_key_idx",
            "admin_governance_command_status_updated_idx",
            "admin_governance_command_recovery_idx",
            "admin_governance_command_target_member_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ReportModerationDecision.schema,
        requiredIndexes: [
            "report_moderation_decisions_report_created_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: UserReport.schema,
        requiredIndexes: [
            "reports_assigned_reviewer_status_created_idx",
            "reports_status_created_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ReportModerationEvidence.schema,
        requiredIndexes: [
            "report_moderation_evidence_report_created_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ReportModerationDecision.schema,
        requiredIndexes: [
            "report_moderation_decisions_report_idempotency_key_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ReportModerationEvidence.schema,
        requiredIndexes: [
            "report_moderation_evidence_report_idempotency_key_idx"
        ]
    )
]

private let imSummaryReadModelSchemaRequirements: [IMTableSchemaRequirement] = imSchemaRequirements.filter {
    [
        ConversationUserSummary.schema,
        ConversationChangesLogEntry.schema,
        ConversationReadModelToken.schema,
        ConversationActivitySummary.schema
    ].contains($0.table)
}

private let imSummaryReadModelIndexRequirements: [IMTableIndexRequirement] = imIndexRequirements.filter {
    [
        ConversationUserSummary.schema,
        ConversationChangesLogEntry.schema,
        ConversationReadModelToken.schema,
        ConversationActivitySummary.schema
    ].contains($0.table)
}

private let imConversationShardSchemaRequirements: [IMTableSchemaRequirement] = imSchemaRequirements.filter {
    [
        Conversation.schema,
        ConversationMember.schema,
        ConversationMessage.schema,
        ConversationDomainEvent.schema,
        ConversationMessageSearchIndex.schema,
        ConversationMediaAssetReference.schema,
        ConversationReplayRecord.schema,
        ConversationDomainEventRecipientSet.schema,
        ConversationDomainEventRecipientSetMember.schema,
        ConversationDomainEventRecipientSnapshot.schema
    ].contains($0.table)
} + [
    IMTableSchemaRequirement(
        table: ConversationDomainEventSequence.schema,
        requiredColumns: ["conversation_id", "last_sequence"]
    ),
    IMTableSchemaRequirement(
        table: ConversationTimelineNotice.schema,
        requiredColumns: [
            "event_id", "conversation_id", "timeline_sequence", "event_type",
            "target_user_ids_json", "notice_kind", "params_json", "fallback_text", "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: AIMessageStreamIndex.schema,
        requiredColumns: [
            "stream_id", "message_id", "conversation_id", "user_id", "state",
            "last_chunk_index", "created_at", "updated_at"
        ]
    )
]

private let imConversationShardIndexRequirements: [IMTableIndexRequirement] = imIndexRequirements.filter {
    [
        ConversationMessage.schema,
        ConversationDomainEventRecipientSetMember.schema
    ].contains($0.table)
} + [
    IMTableIndexRequirement(
        table: ConversationDomainEvent.schema,
        requiredIndexes: [
            "conversation_domain_events_status_created_idx",
            "conversation_domain_events_conversation_created_idx",
            "conversation_domain_events_conversation_sequence_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationTimelineNotice.schema,
        requiredIndexes: ["conversation_timeline_notices_conversation_sequence_idx"]
    ),
    IMTableIndexRequirement(
        table: ConversationMessageSearchIndex.schema,
        requiredIndexes: [
            "conversation_message_search_index_lookup_idx",
            "conversation_message_search_index_message_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: ConversationReplayRecord.schema,
        requiredIndexes: [
            "conversation_event_replay_records_status_updated_idx",
            "conversation_event_replay_records_group_event_idx"
        ]
    ),
    IMTableIndexRequirement(
        table: AIMessageStreamIndex.schema,
        requiredIndexes: [
            "im_ai_message_streams_state_updated_idx",
            "im_ai_message_streams_user_state_idx",
            "im_ai_message_streams_conversation_state_idx"
        ]
    )
]
