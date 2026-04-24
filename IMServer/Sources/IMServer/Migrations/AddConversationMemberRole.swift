import Fluent
import SQLKit

struct AddConversationMemberRole: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ConversationMember.schema)
            .field(
                "role",
                .string,
                .required,
                .sql(.default(SQLLiteral.string(IMConversationMemberRole.member.rawValue)))
            )
            .update()

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
