import Fluent
import Vapor

struct ConversationMembershipService {
    let db: any Database

    func requireMembershipRecord(
        conversationID: UUID,
        userID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationMember {
        let database = database ?? db
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        return membership
    }

    func requireConversationAndMembership(
        conversationID: UUID,
        userID: UUID,
        on database: (any Database)? = nil
    ) async throws -> Conversation {
        let database = database ?? db
        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        _ = try await requireMembershipRecord(
            conversationID: conversationID,
            userID: userID,
            on: database
        )
        return conversation
    }

    func listMemberResponses(
        in conversationID: UUID,
        for userID: UUID
    ) async throws -> [IMConversationMemberResponse] {
        _ = try await requireMembershipRecord(conversationID: conversationID, userID: userID)

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()

        return try memberships
            .map { membership -> IMConversationMemberResponse in
                guard let user = membership.$user.value else {
                    throw Abort(.internalServerError, reason: "会话成员数据不完整。")
                }
                return IMConversationMemberResponse(
                    id: try user.requireID(),
                    email: user.email,
                    role: membership.memberRoleEnum.rawValue
                )
            }
            .sorted(by: sortConversationMembers)
    }

    private func sortConversationMembers(
        lhs: IMConversationMemberResponse,
        rhs: IMConversationMemberResponse
    ) -> Bool {
        let lhsRole = IMConversationMemberRole(rawValue: lhs.role) ?? .member
        let rhsRole = IMConversationMemberRole(rawValue: rhs.role) ?? .member
        let lhsPriority = memberRolePriority(lhsRole)
        let rhsPriority = memberRolePriority(rhsRole)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.email < rhs.email
    }

    private func memberRolePriority(_ role: IMConversationMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }
}
