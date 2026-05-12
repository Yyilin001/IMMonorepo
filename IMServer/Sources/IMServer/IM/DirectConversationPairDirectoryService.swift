import Fluent
import Vapor

struct DirectConversationPairDirectoryService {
    let db: any Database

    func conversationIDsBetween(_ lhs: UUID, _ rhs: UUID) async throws -> [UUID] {
        guard let pair = DirectConversationPairDirectory.normalizedPair(lhs, rhs) else {
            return []
        }
        return try await DirectConversationPairDirectory.query(on: db)
            .filter(\.$lowerUserID == pair.lower)
            .filter(\.$higherUserID == pair.higher)
            .all()
            .map(\.conversationID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func upsert(
        lhs: UUID,
        rhs: UUID,
        conversationID: UUID,
        directMessagingState: IMDirectMessagingState?
    ) async throws {
        guard let pair = DirectConversationPairDirectory.normalizedPair(lhs, rhs) else {
            return
        }
        let recordID = DirectConversationPairDirectory.recordID(
            lowerUserID: pair.lower,
            higherUserID: pair.higher,
            conversationID: conversationID
        )
        let now = Date()
        if let existing = try await DirectConversationPairDirectory.find(recordID, on: db) {
            existing.lowerUserID = pair.lower
            existing.higherUserID = pair.higher
            existing.conversationID = conversationID
            existing.directMessagingState = directMessagingState?.rawValue
            existing.updatedAt = now
            try await existing.update(on: db)
            return
        }

        try await DirectConversationPairDirectory(
            lowerUserID: pair.lower,
            higherUserID: pair.higher,
            conversationID: conversationID,
            directMessagingState: directMessagingState,
            updatedAt: now
        ).create(on: db)
    }

    func sync(conversationID: UUID) async throws {
        guard let conversation = try await Conversation.find(conversationID, on: db),
              conversation.conversationKind == .direct
        else {
            try await delete(conversationID: conversationID)
            return
        }

        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        guard memberUserIDs.count == 2 else {
            try await delete(conversationID: conversationID)
            return
        }

        try await upsert(
            lhs: memberUserIDs[0],
            rhs: memberUserIDs[1],
            conversationID: conversationID,
            directMessagingState: conversation.directMessagingStateEnum
        )
    }

    func delete(conversationID: UUID) async throws {
        let entries = try await DirectConversationPairDirectory.query(on: db)
            .filter(\.$conversationID == conversationID)
            .all()
        for entry in entries {
            try await entry.delete(on: db)
        }
    }
}
