import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationMemberRemovalResult {
    let requesterConversation: IMConversationResponse
    let removedConversation: IMConversationResponse
    let remainingUserIDs: [UUID]
}

enum ConversationCommandNormalizationSupport {
    static func normalizedConversationTitle(_ title: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    static func normalizedConversationKind(
        _ kind: String?,
        normalizedTitle: String?,
        memberUserIDs: [UUID]
    ) throws -> IMConversationKind {
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestedKind: IMConversationKind
        if let normalizedKind, !normalizedKind.isEmpty {
            guard let parsedKind = IMConversationKind(rawValue: normalizedKind) else {
                throw Abort(.badRequest, reason: "会话类型无效。")
            }
            requestedKind = parsedKind
        } else {
            requestedKind = (normalizedTitle == nil && memberUserIDs.count == 2) ? .direct : .group
        }

        if requestedKind == .direct && memberUserIDs.count != 2 {
            throw Abort(.badRequest, reason: "私聊只能选择 1 个其他成员。")
        }

        return requestedKind
    }
}

struct ConversationUserLookupSupport {
    let db: any Database

    func requireUser(id userID: UUID) async throws -> User {
        guard let user = try await User.find(userID, on: db) else {
            throw Abort(.notFound, reason: "用户不存在。")
        }
        return user
    }
}

struct ConversationDirectReuseSupport {
    let db: any Database

    func existingDirectConversationID(for memberUserIDs: [UUID]) async throws -> UUID? {
        let expectedMemberIDs = Set(memberUserIDs)
        guard expectedMemberIDs.count == 2 else {
            return nil
        }

        if let indexedConversationID = try await DatabaseDirectConversationIndex(db: db)
            .conversationID(forMemberUserIDs: memberUserIDs) {
            return indexedConversationID
        }

        let sharedMemberships = try await ConversationMember.query(on: db)
            .filter(\.$user.$id ~~ Array(expectedMemberIDs))
            .all()
        let sharedConversationIDs = Dictionary(grouping: sharedMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !sharedConversationIDs.isEmpty else {
            return nil
        }

        let allMemberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id ~~ sharedConversationIDs)
            .all()
        let exactOneToOneConversationIDs = Dictionary(grouping: allMemberships, by: \.$conversation.id)
            .compactMap { conversationID, memberships -> UUID? in
                let actualMemberIDs = Set(memberships.map(\.$user.id))
                return actualMemberIDs == expectedMemberIDs ? conversationID : nil
            }

        guard !exactOneToOneConversationIDs.isEmpty else {
            return nil
        }

        let conversations = try await Conversation.query(on: db)
            .filter(\.$id ~~ exactOneToOneConversationIDs)
            .filter(\.$kind == IMConversationKind.direct.rawValue)
            .all()
        let existingConversationID = try conversations.sorted { lhs, rhs in
            let lhsDate = lhs.createdAt ?? .distantPast
            let rhsDate = rhs.createdAt ?? .distantPast
            if lhsDate == rhsDate {
                let lhsID = (try? lhs.requireID().uuidString) ?? ""
                let rhsID = (try? rhs.requireID().uuidString) ?? ""
                return lhsID < rhsID
            }
            return lhsDate < rhsDate
        }.first?.requireID()

        if let existingConversationID {
            try await DatabaseDirectConversationIndex(db: db).registerDirectConversation(
                conversationID: existingConversationID,
                memberUserIDs: memberUserIDs,
                shardID: SingleShardConversationShardRouter.defaultShardID
            )
        }

        return existingConversationID
    }

    func normalizeExistingDirectConversation(conversationID: UUID) async throws {
        guard let conversation = try await Conversation.find(conversationID, on: db) else {
            return
        }

        var shouldUpdate = false
        if conversation.title != nil {
            conversation.title = nil
            shouldUpdate = true
        }

        if shouldUpdate {
            conversation.updatedAt = Date()
            try await conversation.update(on: db)
        }
    }
}

struct ConversationSequenceAllocator {
    let db: any Database

    func allocateNextServerSequence(
        conversationID: UUID,
        updatedAt: Date
    ) async throws -> Int {
        guard let sequence = try await reserve(
            count: 1,
            conversationID: conversationID,
            updatedAt: updatedAt
        ).first else {
            throw Abort(.notFound, reason: "会话不存在。")
        }
        return sequence
    }

    func reserve(
        count: Int,
        conversationID: UUID,
        updatedAt: Date
    ) async throws -> [Int] {
        guard count > 0 else {
            return []
        }

        if let sql = db as? any SQLDatabase,
           sql.dialect.name == "postgresql",
           let end = try await sql.update(Conversation.schema)
            .set(
                "last_message_sequence",
                to: SQLQueryString(
                    "\(ident: "last_message_sequence") + \(bind: count)"
                )
            )
            .set("updated_at", to: updatedAt)
            .where("id", .equal, conversationID)
            .returning("last_message_sequence")
            .first(decodingColumn: "last_message_sequence", as: Int.self)
        {
            return Array((end - count + 1)...end)
        }

        guard let conversation = try await Conversation.find(conversationID, on: db) else {
            throw Abort(.notFound, reason: "会话不存在。")
        }

        let latestPersistedMessageSequence = try await ConversationMessage.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .sort(\.$serverSequence, .descending)
            .first()?
            .serverSequence ?? 0
        conversation.lastMessageSequence = max(
            conversation.lastMessageSequence,
            latestPersistedMessageSequence
        ) + count
        conversation.updatedAt = updatedAt
        try await conversation.update(on: db)
        let end = conversation.lastMessageSequence
        return Array((end - count + 1)...end)
    }
}

struct ConversationOutboxEnqueuer {
    let db: any Database

    private var eventBus: any ConversationEventBus {
        DatabaseOutboxConversationEventBus(db: db)
    }

    func enqueueSummaryRefreshEvent(
        type: ConversationDomainEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID]
    ) async throws {
        try await eventBus.publish(
            type: type,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(recipientUserIDs: recipientUserIDs),
            on: db
        )
    }

    func enqueueConversationRemovedEvent(
        conversationID: UUID,
        affectedUserID: UUID
    ) async throws {
        try await eventBus.publish(
            type: .conversationRemovedForUser,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: [],
                affectedUserID: affectedUserID
            ),
            on: db
        )
    }

    func enqueueMessageEvent(
        type: ConversationDomainEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        messageID: UUID
    ) async throws {
        try await eventBus.publish(
            type: type,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: recipientUserIDs,
                messageID: messageID
            ),
            on: db
        )
    }
}

enum ConversationReadPaginationSupport {
    private enum HistoryPage {
        static let defaultLimit = 50
        static let maxLimit = 100
    }

    private enum IncrementalPage {
        static let defaultLimit = 100
        static let maxLimit = 500
    }

    static func normalizedHistoryLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return HistoryPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, HistoryPage.maxLimit)
    }

    static func normalizedIncrementalLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else {
            return IncrementalPage.defaultLimit
        }

        guard requestedLimit > 0 else {
            throw Abort(.badRequest, reason: "分页条数无效。")
        }

        return min(requestedLimit, IncrementalPage.maxLimit)
    }
}

enum ConversationPresentationSupport {
    static func directMessagingState(for conversation: Conversation) -> String? {
        guard conversation.conversationKind == .direct else {
            return nil
        }

        return conversation.directMessagingState
    }

    static func directPeer(
        from memberships: [ConversationMember],
        currentUserID: UUID
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peerUser = peerMembership.$user.value
        else {
            return nil
        }

        return IMDirectPeerResponse(
            id: peerMembership.$user.id,
            email: peerUser.email,
            displayName: peerUser.displayName,
            avatarPreset: peerUser.avatarPresetEnum
        )
    }
}

struct ConversationSystemMessageAppender {
    let db: any Database

    func append(
        in conversationID: UUID,
        senderUserID: UUID,
        event: IMSystemEvent,
        serverSequence: Int? = nil,
        updatedAt: Date = Date()
    ) async throws -> Int {
        let sequence = if let serverSequence {
            serverSequence
        } else {
            try await ConversationSequenceAllocator(db: db)
                .allocateNextServerSequence(conversationID: conversationID, updatedAt: updatedAt)
        }
        let systemMessage = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: senderUserID,
            serverSequence: sequence,
            content: .system(event)
        )
        try await systemMessage.create(on: db)
        return sequence
    }
}

struct ConversationReadAdvanceSupport {
    let db: any Database

    private var readStateService: ConversationReadStateService {
        ConversationReadStateService(db: db)
    }

    func advanceConversationRead(
        conversationID: UUID,
        userID: UUID,
        requestedReadSequence: Int
    ) async throws {
        try await readStateService.advanceConversationRead(
            conversationID: conversationID,
            userID: userID,
            requestedReadSequence: requestedReadSequence,
            on: db
        )
    }

    func advanceReadSequenceIfMember(
        conversationID: UUID,
        userID: UUID,
        readSequence: Int
    ) async throws {
        try await readStateService.advanceReadSequenceIfMember(
            conversationID: conversationID,
            userID: userID,
            readSequence: readSequence,
            on: db
        )
    }

    func conversationReadState(
        conversationID: UUID,
        userID: UUID
    ) async throws -> ConversationReadState {
        try await readStateService.conversationReadState(
            conversationID: conversationID,
            userID: userID,
            on: db
        )
    }
}

struct ConversationSummaryRefreshPublisher {
    let db: any Database

    private var outboxEnqueuer: ConversationOutboxEnqueuer {
        ConversationOutboxEnqueuer(db: db)
    }

    func publish(
        _ type: ConversationDomainEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID]
    ) async throws {
        try await outboxEnqueuer.enqueueSummaryRefreshEvent(
            type: type,
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs
        )
    }

    func publishConversationRemoved(
        conversationID: UUID,
        affectedUserID: UUID
    ) async throws {
        try await outboxEnqueuer.enqueueConversationRemovedEvent(
            conversationID: conversationID,
            affectedUserID: affectedUserID
        )
    }
}

struct ConversationMessageEventPublisher {
    let db: any Database

    private var membershipService: ConversationMembershipService {
        ConversationMembershipService(db: db)
    }

    private var outboxEnqueuer: ConversationOutboxEnqueuer {
        ConversationOutboxEnqueuer(db: db)
    }

    func publish(
        _ type: ConversationDomainEventType,
        conversationID: UUID,
        requesterUserID: UUID,
        messageID: UUID
    ) async throws {
        let recipientUserIDs = try await membershipService.listMemberResponses(
            in: conversationID,
            for: requesterUserID
        ).map(\.id)
        try await outboxEnqueuer.enqueueMessageEvent(
            type: type,
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs,
            messageID: messageID
        )
    }
}

enum ConversationMembershipGuard {
    static func requireGroup(
        _ conversation: Conversation,
        reason: String
    ) throws {
        guard conversation.conversationKind == .group else {
            throw Abort(.badRequest, reason: reason)
        }
    }

    static func requireOwnerOrAdmin(
        _ role: IMConversationMemberRole,
        reason: String
    ) throws {
        guard role == .owner || role == .admin else {
            throw Abort(.forbidden, reason: reason)
        }
    }

    static func requireOwner(
        _ role: IMConversationMemberRole,
        reason: String
    ) throws {
        guard role == .owner else {
            throw Abort(.forbidden, reason: reason)
        }
    }

    static func requireNotSelf(
        targetUserID: UUID,
        requesterUserID: UUID,
        reason: String
    ) throws {
        guard targetUserID != requesterUserID else {
            throw Abort(.badRequest, reason: reason)
        }
    }

    static func requireNonOwner(
        _ role: IMConversationMemberRole,
        reason: String
    ) throws {
        guard role != .owner else {
            throw Abort(.badRequest, reason: reason)
        }
    }
}
