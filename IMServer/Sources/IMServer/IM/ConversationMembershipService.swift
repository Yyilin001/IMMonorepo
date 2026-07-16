import Fluent
import Vapor

struct ConversationMembershipService {
    let db: any Database
    let userDirectoryDB: any Database

    init(db: any Database, userDirectoryDB: (any Database)? = nil) {
        self.db = db
        self.userDirectoryDB = userDirectoryDB ?? db
    }

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
        let page = try await listMemberPageResponses(
            in: conversationID,
            for: userID,
            cursor: nil,
            limit: nil,
            query: nil
        )
        return page.items
    }

    func listMemberPageResponses(
        in conversationID: UUID,
        for userID: UUID,
        cursor: String?,
        limit requestedLimit: Int?,
        query: String?
    ) async throws -> IMConversationMemberPageResponse {
        _ = try await requireMembershipRecord(conversationID: conversationID, userID: userID)
        let limit = max(1, min(requestedLimit ?? 50, 100))
        let offset = max(0, cursor.flatMap(Int.init) ?? 0)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let usersByID = try await ConversationUserDirectory(db: userDirectoryDB)
            .usersByID(memberships.map(\.$user.id))

        let allItems = try memberships
            .map { membership -> IMConversationMemberResponse in
                guard let user = usersByID[membership.$user.id] else {
                    throw Abort(.internalServerError, reason: "会话成员缺少主库用户目录记录。")
                }
                let displayTitle = membership.memberNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? user.email
                return IMConversationMemberResponse(
                    id: try user.requireID(),
                    email: user.email,
                    displayName: user.displayName,
                    avatarPreset: user.avatarPresetEnum,
                    role: membership.memberRoleEnum.rawValue,
                    memberNickname: membership.memberNickname,
                    displayTitle: displayTitle.isEmpty ? user.email : displayTitle
                )
            }
            .filter { item in
                guard let normalizedQuery, !normalizedQuery.isEmpty else {
                    return true
                }
                return item.email.lowercased().contains(normalizedQuery)
                    || (item.displayName?.lowercased().contains(normalizedQuery) ?? false)
                    || (item.memberNickname?.lowercased().contains(normalizedQuery) ?? false)
            }
            .sorted(by: sortConversationMembers)
        let pageItems = Array(allItems.dropFirst(offset).prefix(limit))
        let nextOffset = offset + pageItems.count
        return IMConversationMemberPageResponse(
            items: pageItems,
            nextCursor: nextOffset < allItems.count ? "\(nextOffset)" : nil,
            total: allItems.count,
            limit: limit
        )
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
