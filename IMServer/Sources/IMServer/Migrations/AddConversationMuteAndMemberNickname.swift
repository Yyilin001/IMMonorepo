import Fluent
import SQLKit

struct AddConversationMuteAndMemberNickname: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: Conversation.schema)
                ADD COLUMN IF NOT EXISTS mute_all BOOLEAN NOT NULL DEFAULT FALSE
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMember.schema)
                ADD COLUMN IF NOT EXISTS member_nickname TEXT
                """).run()
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationUserSummary.schema)
                ADD COLUMN IF NOT EXISTS mute_all BOOLEAN NOT NULL DEFAULT FALSE
                """).run()
            return
        }
        if let sql = database as? any SQLDatabase, sql.dialect.name == "sqlite" {
            return
        }

        try await database.schema(Conversation.schema)
            .field("mute_all", .bool, .required, .sql(.default(false)))
            .update()
        try await database.schema(ConversationMember.schema)
            .field("member_nickname", .string)
            .update()
        try await database.schema(ConversationUserSummary.schema)
            .field("mute_all", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationUserSummary.schema)
            .deleteField("mute_all")
            .update()
        try await database.schema(ConversationMember.schema)
            .deleteField("member_nickname")
            .update()
        try await database.schema(Conversation.schema)
            .deleteField("mute_all")
            .update()
    }
}
