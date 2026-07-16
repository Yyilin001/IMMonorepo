import Fluent
import SQLKit
import Vapor

/// Makes sequence columns on an independently deployed conversation shard safe
/// for long-lived, high-volume timelines without requiring owner/user tables.
struct EnforceConversationShardSequenceInvariants: AsyncMigration {
    private struct SequenceColumn {
        let table: String
        let column: String
    }

    private struct Constraint {
        let table: String
        let column: String
        let comparator: String
        let value: Int
        let name: String

        static func positive(table: String, column: String, name: String) -> Self {
            .init(table: table, column: column, comparator: "<=", value: 0, name: name)
        }

        static func nonNegative(table: String, column: String, name: String) -> Self {
            .init(table: table, column: column, comparator: "<", value: 0, name: name)
        }

        var validComparator: String {
            comparator == "<=" ? ">" : ">="
        }
    }

    private struct CountRow: Decodable {
        let count: Int
    }

    private static let int64Columns: [SequenceColumn] = [
        .init(table: Conversation.schema, column: "last_message_sequence"),
        .init(table: ConversationMember.schema, column: "visible_from_sequence"),
        .init(table: ConversationMember.schema, column: "last_read_sequence"),
        .init(table: ConversationMessage.schema, column: "server_sequence"),
        .init(table: ConversationMessage.schema, column: "timeline_sequence"),
        .init(table: ConversationDomainEvent.schema, column: "aggregate_sequence"),
        .init(table: ConversationDomainEventSequence.schema, column: "last_sequence"),
        .init(table: ConversationTimelineNotice.schema, column: "timeline_sequence"),
        .init(table: ConversationMessageSearchIndex.schema, column: "server_sequence"),
        .init(table: ConversationMediaAssetReference.schema, column: "server_sequence"),
        .init(table: AIMessageStreamIndex.schema, column: "last_chunk_index")
    ]

    private static let constraints: [Constraint] = [
        .positive(table: ConversationMessage.schema, column: "server_sequence", name: "im_messages_server_sequence_positive"),
        .positive(table: ConversationMessage.schema, column: "timeline_sequence", name: "im_messages_timeline_sequence_positive"),
        .positive(table: ConversationDomainEvent.schema, column: "aggregate_sequence", name: "conversation_events_sequence_positive"),
        .positive(table: ConversationTimelineNotice.schema, column: "timeline_sequence", name: "timeline_notices_sequence_positive"),
        .nonNegative(table: Conversation.schema, column: "last_message_sequence", name: "im_conversations_last_sequence_nonnegative"),
        .nonNegative(table: ConversationMember.schema, column: "visible_from_sequence", name: "im_members_visible_sequence_nonnegative"),
        .nonNegative(table: ConversationMember.schema, column: "last_read_sequence", name: "im_members_read_sequence_nonnegative"),
        .nonNegative(table: ConversationDomainEventSequence.schema, column: "last_sequence", name: "conversation_event_sequences_nonnegative")
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Conversation shard sequence migration requires an SQL database.")
        }

        if sql.dialect.name == "postgresql" {
            for sequenceColumn in Self.int64Columns {
                try await sql.raw("""
                    ALTER TABLE \(ident: sequenceColumn.table)
                    ALTER COLUMN \(ident: sequenceColumn.column) TYPE BIGINT
                    USING \(ident: sequenceColumn.column)::BIGINT
                    """).run()
            }
        }

        for constraint in Self.constraints {
            let invalidRows = try await sql.raw("""
                SELECT COUNT(*) AS count
                FROM \(ident: constraint.table)
                WHERE \(ident: constraint.column) IS NOT NULL
                  AND \(ident: constraint.column) \(unsafeRaw: constraint.comparator) \(unsafeRaw: String(constraint.value))
                """).all(decoding: CountRow.self)
            guard (invalidRows.first?.count ?? 0) == 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "\(constraint.table).\(constraint.column) contains invalid conversation shard sequence values."
                )
            }
        }

        guard sql.dialect.name == "postgresql" else {
            return
        }

        for constraint in Self.constraints {
            let expression = "\(constraint.column) IS NULL OR \(constraint.column) \(constraint.validComparator) \(constraint.value)"
            try await sql.raw("""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1
                        FROM pg_constraint
                        WHERE conname = '\(unsafeRaw: constraint.name)'
                    ) THEN
                        ALTER TABLE \(ident: constraint.table)
                        ADD CONSTRAINT \(ident: constraint.name)
                        CHECK (\(unsafeRaw: expression));
                    END IF;
                END $$;
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql"
        else {
            return
        }

        for constraint in Self.constraints {
            try await sql.raw("""
                ALTER TABLE \(ident: constraint.table)
                DROP CONSTRAINT IF EXISTS \(ident: constraint.name)
                """).run()
        }
    }
}
