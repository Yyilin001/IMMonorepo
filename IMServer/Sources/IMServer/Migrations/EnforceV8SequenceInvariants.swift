import Fluent
import SQLKit
import Vapor

struct EnforceV8SequenceInvariants: AsyncMigration {
    private struct SequenceColumn {
        let table: String
        let column: String
    }

    private struct SequenceConstraint {
        let table: String
        let column: String
        let comparator: String
        let value: Int
        let name: String

        static func positive(table: String, column: String) -> Self {
            .init(
                table: table,
                column: column,
                comparator: "<=",
                value: 0,
                name: "\(table)_\(column)_v8_positive".imV8ConstraintName
            )
        }

        static func nonNegative(table: String, column: String) -> Self {
            .init(
                table: table,
                column: column,
                comparator: "<",
                value: 0,
                name: "\(table)_\(column)_v8_nonnegative".imV8ConstraintName
            )
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
        .init(table: ContactDomainEvent.schema, column: "owner_sequence"),
        .init(table: OwnerDomainEventDelivery.schema, column: "owner_cursor"),
        .init(table: OwnerDomainEventDelivery.schema, column: "owner_aggregate_sequence"),
        .init(table: ConversationDomainEventSequence.schema, column: "last_sequence"),
        .init(table: OwnerContactEventSequence.schema, column: "last_sequence"),
        .init(table: OwnerDomainEventDeliveryCursor.schema, column: "last_cursor"),
        .init(table: OwnerDomainEventAggregateSequence.schema, column: "last_sequence"),
        .init(table: ConversationTimelineNotice.schema, column: "timeline_sequence"),
        .init(table: ConversationReplayRecord.schema, column: "aggregate_sequence"),
        .init(table: ConversationMessageSearchIndex.schema, column: "server_sequence"),
        .init(table: ConversationMediaAssetReference.schema, column: "server_sequence"),
        .init(table: ConversationMediaAssetReferenceDirectory.schema, column: "server_sequence"),
        .init(table: MessageFavorite.schema, column: "server_sequence"),
        .init(table: MessageVisibilityOverride.schema, column: "server_sequence"),
        .init(table: ConversationVisibilityOverride.schema, column: "hidden_before_sequence"),
        .init(table: ConversationUserSummary.schema, column: "last_read_sequence")
    ]

    private static let constraints: [SequenceConstraint] = [
        .positive(table: ConversationMessage.schema, column: "server_sequence"),
        .positive(table: ConversationMessage.schema, column: "timeline_sequence"),
        .positive(table: ConversationDomainEvent.schema, column: "aggregate_sequence"),
        .positive(table: ContactDomainEvent.schema, column: "owner_sequence"),
        .positive(table: OwnerDomainEventDelivery.schema, column: "owner_cursor"),
        .positive(table: OwnerDomainEventDelivery.schema, column: "owner_aggregate_sequence"),
        .positive(table: ConversationTimelineNotice.schema, column: "timeline_sequence"),
        .positive(table: ConversationReplayRecord.schema, column: "aggregate_sequence"),
        .positive(table: ConversationMessageSearchIndex.schema, column: "server_sequence"),
        .positive(table: ConversationMediaAssetReference.schema, column: "server_sequence"),
        .positive(table: ConversationMediaAssetReferenceDirectory.schema, column: "server_sequence"),
        .positive(table: MessageFavorite.schema, column: "server_sequence"),
        .positive(table: MessageVisibilityOverride.schema, column: "server_sequence"),
        .nonNegative(table: Conversation.schema, column: "last_message_sequence"),
        .nonNegative(table: ConversationMember.schema, column: "visible_from_sequence"),
        .nonNegative(table: ConversationMember.schema, column: "last_read_sequence"),
        .nonNegative(table: ConversationDomainEventSequence.schema, column: "last_sequence"),
        .nonNegative(table: OwnerContactEventSequence.schema, column: "last_sequence"),
        .nonNegative(table: OwnerDomainEventDeliveryCursor.schema, column: "last_cursor"),
        .nonNegative(table: OwnerDomainEventAggregateSequence.schema, column: "last_sequence"),
        .nonNegative(table: ConversationVisibilityOverride.schema, column: "hidden_before_sequence"),
        .nonNegative(table: ConversationUserSummary.schema, column: "last_read_sequence")
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "TCP v8 sequence invariant migration requires SQL database.")
        }

        switch sql.dialect.name {
        case "postgresql":
            try await ensureLegacyPostgresColumns(on: sql)
            try await alterPostgresColumns(on: sql)
            try await validateConstraints(on: sql)
            try await addPostgresConstraints(on: sql)
        case "sqlite":
            try await validateConstraints(on: sql)
        default:
            throw Abort(.internalServerError, reason: "TCP v8 sequence invariant migration only supports PostgreSQL and SQLite.")
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
                ALTER TABLE IF EXISTS \(unsafeRaw: constraint.table)
                DROP CONSTRAINT IF EXISTS \(unsafeRaw: constraint.name)
                """).run()
        }
    }

    private func ensureLegacyPostgresColumns(on sql: any SQLDatabase) async throws {
        try await sql.raw("""
            ALTER TABLE IF EXISTS \(unsafeRaw: ConversationReplayRecord.schema)
            ADD COLUMN IF NOT EXISTS aggregate_sequence BIGINT NOT NULL DEFAULT 1
            """).run()
    }

    private func alterPostgresColumns(on sql: any SQLDatabase) async throws {
        for column in Self.int64Columns {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: column.table)
                ALTER COLUMN \(unsafeRaw: column.column) TYPE BIGINT
                USING \(unsafeRaw: column.column)::BIGINT
                """).run()
        }
    }

    private func validateConstraints(on sql: any SQLDatabase) async throws {
        for constraint in Self.constraints {
            let rows = try await sql.raw("""
                SELECT COUNT(*) AS count
                FROM \(unsafeRaw: constraint.table)
                WHERE \(unsafeRaw: constraint.column) IS NOT NULL
                  AND \(unsafeRaw: constraint.column) \(unsafeRaw: constraint.comparator) \(unsafeRaw: String(constraint.value))
                """).all(decoding: CountRow.self)
            if (rows.first?.count ?? 0) > 0 {
                throw Abort(
                    .internalServerError,
                    reason: "\(constraint.table).\(constraint.column) contains invalid v8 sequence values."
                )
            }
        }
    }

    private func addPostgresConstraints(on sql: any SQLDatabase) async throws {
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
                        ALTER TABLE \(unsafeRaw: constraint.table)
                        ADD CONSTRAINT \(unsafeRaw: constraint.name)
                        CHECK (\(unsafeRaw: expression));
                    END IF;
                END $$;
                """).run()
        }
    }
}

private extension String {
    var imV8ConstraintName: String {
        if count <= 63 {
            return self
        }
        return String(prefix(55)) + "_v8chk"
    }
}
