import Fluent
import SQLKit

struct AddUserContactRemark: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: UserContact.schema)
                ADD COLUMN IF NOT EXISTS remark TEXT
                """).run()
            return
        }

        try await database.schema(UserContact.schema)
            .field("remark", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserContact.schema)
            .deleteField("remark")
            .update()
    }
}

