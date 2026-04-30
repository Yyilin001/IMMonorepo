import Fluent
import SQLKit

struct AddConversationMemberRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw("""
                ALTER TABLE IF EXISTS \(unsafeRaw: ConversationMember.schema)
                ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member'
                """).run()
        } else {
            try await database.schema(ConversationMember.schema)
                .field(
                    "role",
                    .string,
                    .required,
                    .sql(.default(SQLLiteral.string(IMConversationMemberRole.member.rawValue)))
                )
                .update()
        }

        guard let roleFieldExists = try await conversationMemberRoleFieldExists(on: database), roleFieldExists else {
            return
        }

        let conversations = try await Conversation.query(on: database)
            .filter(\.$kind == IMConversationKind.group.rawValue)
            .all()

        for conversation in conversations {
            let conversationID = try conversation.requireID()
            let memberships = try await ConversationMember.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .all()
                .sorted(by: membershipOrder)

            guard let ownerMembership = memberships.first else {
                continue
            }

            for membership in memberships {
                membership.memberRoleEnum = membership.id == ownerMembership.id ? .owner : .member
                try await membership.update(on: database)
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema)
            .deleteField("role")
            .update()
    }

    private func conversationMemberRoleFieldExists(on database: any Database) async throws -> Bool? {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            return true
        }

        struct ColumnCheckRow: Decodable {
            let exists: Bool
        }

        let rows = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_name = \(bind: ConversationMember.schema)
                  AND column_name = 'role'
            ) AS exists
            """).all(decoding: ColumnCheckRow.self)
        return rows.first?.exists
    }

    private func membershipOrder(lhs: ConversationMember, rhs: ConversationMember) -> Bool {
        let lhsJoinedAt = lhs.joinedAt ?? .distantFuture
        let rhsJoinedAt = rhs.joinedAt ?? .distantFuture
        if lhsJoinedAt != rhsJoinedAt {
            return lhsJoinedAt < rhsJoinedAt
        }

        let lhsID = lhs.id?.uuidString ?? ""
        let rhsID = rhs.id?.uuidString ?? ""
        return lhsID < rhsID
    }
}
