import Fluent
import SQLKit

struct AddConversationShardMigrationCopyState: AsyncMigration {
    private let integerColumns = [
        "copy_conversation_watermark",
        "copy_member_watermark",
        "copy_message_watermark",
        "copy_domain_event_watermark",
        "copy_domain_event_sequence_watermark",
        "copy_timeline_notice_watermark",
        "copy_media_reference_watermark",
        "copy_recipient_snapshot_watermark"
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(ConversationShardMigration.schema)
                .field("copy_conversation_watermark", .int, .required, .sql(.default(0)))
                .field("copy_member_watermark", .int, .required, .sql(.default(0)))
                .field("copy_message_watermark", .int, .required, .sql(.default(0)))
                .field("copy_domain_event_watermark", .int, .required, .sql(.default(0)))
                .field("copy_domain_event_sequence_watermark", .int, .required, .sql(.default(0)))
                .field("copy_timeline_notice_watermark", .int, .required, .sql(.default(0)))
                .field("copy_media_reference_watermark", .int, .required, .sql(.default(0)))
                .field("copy_recipient_snapshot_watermark", .int, .required, .sql(.default(0)))
                .field("source_recipient_snapshot_count", .int, .required, .sql(.default(0)))
                .field("source_fingerprint", .string)
                .field("target_fingerprint", .string)
                .field("copy_started_at", .datetime)
                .update()
            return
        }

        switch sql.dialect.name {
        case "postgresql":
            for column in integerColumns {
                try await sql.raw("""
                    ALTER TABLE IF EXISTS \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN IF NOT EXISTS \(unsafeRaw: column) INTEGER NOT NULL DEFAULT 0
                    """).run()
            }
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationShardMigration.schema)
                ADD COLUMN IF NOT EXISTS source_fingerprint TEXT,
                ADD COLUMN IF NOT EXISTS target_fingerprint TEXT,
                ADD COLUMN IF NOT EXISTS copy_started_at TIMESTAMP
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationShardMigration.schema)
                ADD COLUMN IF NOT EXISTS source_recipient_snapshot_count INTEGER NOT NULL DEFAULT 0
                """).run()
        case "sqlite":
            struct SQLiteColumnRow: Decodable { let name: String }
            let existing = Set(
                try await sql.raw("PRAGMA table_info(\(unsafeRaw: ConversationShardMigration.schema))")
                    .all(decoding: SQLiteColumnRow.self)
                    .map(\.name)
            )
            for column in integerColumns where !existing.contains(column) {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN \(unsafeRaw: column) INTEGER NOT NULL DEFAULT 0
                    """).run()
            }
            if !existing.contains("source_recipient_snapshot_count") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN source_recipient_snapshot_count INTEGER NOT NULL DEFAULT 0
                    """).run()
            }
            if !existing.contains("source_fingerprint") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN source_fingerprint TEXT
                    """).run()
            }
            if !existing.contains("target_fingerprint") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN target_fingerprint TEXT
                    """).run()
            }
            if !existing.contains("copy_started_at") {
                try await sql.raw("""
                    ALTER TABLE \(unsafeRaw: ConversationShardMigration.schema)
                    ADD COLUMN copy_started_at DATETIME
                    """).run()
            }
        default:
            try await database.schema(ConversationShardMigration.schema)
                .field("copy_conversation_watermark", .int, .required, .sql(.default(0)))
                .field("copy_member_watermark", .int, .required, .sql(.default(0)))
                .field("copy_message_watermark", .int, .required, .sql(.default(0)))
                .field("copy_domain_event_watermark", .int, .required, .sql(.default(0)))
                .field("copy_domain_event_sequence_watermark", .int, .required, .sql(.default(0)))
                .field("copy_timeline_notice_watermark", .int, .required, .sql(.default(0)))
                .field("copy_media_reference_watermark", .int, .required, .sql(.default(0)))
                .field("copy_recipient_snapshot_watermark", .int, .required, .sql(.default(0)))
                .field("source_recipient_snapshot_count", .int, .required, .sql(.default(0)))
                .field("source_fingerprint", .string)
                .field("target_fingerprint", .string)
                .field("copy_started_at", .datetime)
                .update()
        }
    }

    func revert(on database: any Database) async throws {
        // Production rollbacks keep progress records auditable. PostgreSQL can
        // drop these columns manually after all active migrations have ended.
    }
}
