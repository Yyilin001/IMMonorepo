import Fluent
import Vapor

struct ConversationReadState: Equatable, Sendable {
    let lastReadSequence: Int
    let unreadCount: Int
}

struct ConversationSummaryPreferences: Equatable, Sendable {
    let isPinned: Bool
    let pinnedAt: Date?
    let isMuted: Bool
}

struct ConversationReadStateService {
    let db: any Database

    func conversationReadState(
        conversationID: UUID,
        userID: UUID,
        on database: any Database
    ) async throws -> ConversationReadState {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let effectiveLastReadSequence = max(
            membership.lastReadSequence,
            max(0, membership.visibleFromSequence - 1)
        )
        let latestSequence = try await latestVisibleConversationSequence(
            conversationID: conversationID,
            visibleFromSequence: membership.visibleFromSequence,
            on: database
        )
        return ConversationReadState(
            lastReadSequence: effectiveLastReadSequence,
            unreadCount: max(0, latestSequence - effectiveLastReadSequence)
        )
    }

    func latestVisibleConversationSequence(
        conversationID: UUID,
        visibleFromSequence: Int,
        on database: any Database
    ) async throws -> Int {
        let latestMessageSequence = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$serverSequence >= visibleFromSequence)
            .sort(\.$serverSequence, .descending)
            .first()?
            .serverSequence ?? 0

        return max(latestMessageSequence, max(0, visibleFromSequence - 1))
    }

    func advanceConversationRead(
        conversationID: UUID,
        userID: UUID,
        requestedReadSequence: Int,
        on database: any Database
    ) async throws {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let targetSequence = try await latestVisibleConversationSequence(
            conversationID: conversationID,
            visibleFromSequence: membership.visibleFromSequence,
            on: database
        )
        let effectiveReadSequence = min(requestedReadSequence, targetSequence)
        guard membership.lastReadSequence < effectiveReadSequence else {
            return
        }

        membership.lastReadSequence = effectiveReadSequence
        try await membership.update(on: database)
    }

    func advanceReadSequenceIfMember(
        conversationID: UUID,
        userID: UUID,
        readSequence: Int,
        on database: any Database
    ) async throws {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            return
        }

        guard membership.lastReadSequence < readSequence else {
            return
        }

        membership.lastReadSequence = max(readSequence, max(0, membership.visibleFromSequence - 1))
        try await membership.update(on: database)
    }

    func membershipSummaryPreferences(
        conversationID: UUID,
        userID: UUID,
        on database: any Database
    ) async throws -> ConversationSummaryPreferences {
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        return ConversationSummaryPreferences(
            isPinned: membership.isPinned,
            pinnedAt: membership.pinnedAt,
            isMuted: membership.isMuted
        )
    }
}
