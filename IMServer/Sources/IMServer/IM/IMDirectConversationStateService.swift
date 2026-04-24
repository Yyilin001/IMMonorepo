import Fluent
import Foundation

struct IMDirectConversationStateService {
    func updateExistingDirectConversations(
        between lhs: UUID,
        and rhs: UUID,
        to state: IMDirectMessagingState,
        on database: any Database
    ) async throws -> [UUID] {
        let conversationIDs = try await exactDirectConversationIDs(between: lhs, and: rhs, on: database)
        guard !conversationIDs.isEmpty else {
            return []
        }

        let conversations = try await Conversation.query(on: database)
            .filter(\.$id ~~ conversationIDs)
            .all()

        for conversation in conversations where conversation.directMessagingStateEnum != state {
            conversation.directMessagingStateEnum = state
            try await conversation.update(on: database)
        }

        return conversationIDs
    }

    private func exactDirectConversationIDs(
        between lhs: UUID,
        and rhs: UUID,
        on database: any Database
    ) async throws -> [UUID] {
        let expectedMemberIDs: Set<UUID> = [lhs, rhs]
        guard expectedMemberIDs.count == 2 else {
            return []
        }

        let sharedMemberships = try await ConversationMember.query(on: database)
            .filter(\.$user.$id ~~ Array(expectedMemberIDs))
            .all()
        let candidateConversationIDs = Swift.Dictionary(grouping: sharedMemberships, by: { $0.$conversation.id })
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map { $0.$user.id })
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !candidateConversationIDs.isEmpty else {
            return []
        }

        let allMemberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id ~~ candidateConversationIDs)
            .all()
        let exactOneToOneConversationIDs = Swift.Dictionary(grouping: allMemberships, by: { $0.$conversation.id })
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map { $0.$user.id })
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !exactOneToOneConversationIDs.isEmpty else {
            return []
        }

        let directConversations = try await Conversation.query(on: database)
            .filter(\.$id ~~ exactOneToOneConversationIDs)
            .filter(\.$kind == IMConversationKind.direct.rawValue)
            .all()

        return try directConversations
            .map { try $0.requireID() }
            .sorted { $0.uuidString < $1.uuidString }
    }
}
