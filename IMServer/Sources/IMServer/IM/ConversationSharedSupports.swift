import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationCommandReceipt: Equatable, Sendable {
    let conversationID: UUID
    let eventID: UUID?
    let eventType: ConversationDomainEventType
    let acceptedAt: Date
    let membershipRevision: Date?
    let didMutate: Bool

    var projectionPending: Bool {
        eventID != nil
    }
}

struct ConversationCreateCommandResult: Sendable {
    let receipt: ConversationCommandReceipt
    let kind: IMConversationKind
    let memberUserIDs: [UUID]
}

struct ConversationMemberRemovalResult {
    let receipt: ConversationCommandReceipt
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

struct ConversationUserDirectory {
    let db: any Database

    func usersByID(_ userIDs: [UUID]) async throws -> [UUID: User] {
        let uniqueUserIDs = Array(Set(userIDs))
        guard !uniqueUserIDs.isEmpty else {
            return [:]
        }
        let users = try await User.query(on: db)
            .filter(\.$id ~~ uniqueUserIDs)
            .all()
        return Dictionary(uniqueKeysWithValues: try users.map { user in
            (try user.requireID(), user)
        })
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
        return nil
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
    let domainEventMetrics: ConversationDomainEventMetrics?

    init(db: any Database, domainEventMetrics: ConversationDomainEventMetrics? = nil) {
        self.db = db
        self.domainEventMetrics = domainEventMetrics
    }

    private var eventBus: any ConversationEventBus {
        DatabaseOutboxConversationEventBus(db: db, domainEventMetrics: domainEventMetrics)
    }

    @discardableResult
    func enqueueSummaryRefreshEvent(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID?,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        try await eventBus.publish(
            type: type,
            conversationID: conversationID,
            actorUserID: actorUserID,
            payload: summaryRefreshPayload(type: type, recipientUserIDs: recipientUserIDs, actorUserID: actorUserID),
            recipientSnapshotUserIDs: nil,
            recipientSnapshotDeduplicationThreshold: 0,
            on: database ?? db
        )
    }

    @discardableResult
    func enqueueConversationRemovedEvent(
        conversationID: UUID,
        actorUserID: UUID?,
        affectedUserID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        try await eventBus.publish(
            type: .conversationRemovedForUser,
            conversationID: conversationID,
            actorUserID: actorUserID,
            payload: .conversationRemovedForSelf(ownerUserID: affectedUserID),
            recipientSnapshotUserIDs: nil,
            recipientSnapshotDeduplicationThreshold: 0,
            on: database ?? db
        )
    }

    func enqueueMessageEvent(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID,
        recipientUserIDs: [UUID],
        messageID: UUID,
        messageCreatedPreview: ConversationMessageCreatedPreview? = nil,
        messageCreatedRecipientInlineThreshold: Int = 0,
        recipientSnapshotDeduplicationThreshold: Int = 0,
        on database: (any Database)? = nil
    ) async throws {
        let payload = try messagePayload(
            type: type,
            messageID: messageID,
            recipientUserIDs: recipientUserIDs,
            messageCreatedPreview: messageCreatedPreview,
            messageCreatedRecipientInlineThreshold: messageCreatedRecipientInlineThreshold
        )
        let recipientSnapshotUserIDs = type == .messageCreated && payload.recipientUserIDs.isEmpty
            ? recipientUserIDs
            : nil
        _ = try await eventBus.publish(
            type: type,
            conversationID: conversationID,
            actorUserID: actorUserID,
            payload: payload,
            recipientSnapshotUserIDs: recipientSnapshotUserIDs,
            recipientSnapshotDeduplicationThreshold: recipientSnapshotDeduplicationThreshold,
            on: database ?? db
        )
    }

    private func summaryRefreshPayload(
        type: ConversationDomainEventType,
        recipientUserIDs: [UUID],
        actorUserID: UUID?
    ) throws -> ConversationDomainEventPayload {
        switch type {
        case .metadataUpdated:
            return .metadataUpdated(recipientUserIDs: recipientUserIDs)
        case .directPeerUpdated:
            return .directPeerUpdated(recipientUserIDs: recipientUserIDs)
        case .conversationSettingsChanged:
            guard let actorUserID else {
                throw Abort(.internalServerError, reason: "会话设置事件缺少 actor。")
            }
            return .settingsChanged(ownerUserID: actorUserID)
        case .inviteChanged:
            return .inviteChanged(recipientUserIDs: recipientUserIDs)
        case .readAdvanced:
            guard let actorUserID else {
                throw Abort(.internalServerError, reason: "已读事件缺少 actor。")
            }
            return .readAdvanced(ownerUserID: actorUserID)
        case .membershipAdded:
            return .memberAdded(memberUserIDs: recipientUserIDs, recipientUserIDs: recipientUserIDs)
        case .membershipRemoved:
            return .memberRemoved(memberUserIDs: recipientUserIDs, recipientUserIDs: recipientUserIDs)
        case .membershipRoleUpdated:
            guard let actorUserID else {
                throw Abort(.internalServerError, reason: "成员角色事件缺少 actor。")
            }
            return .memberRoleUpdated(memberUserID: actorUserID, recipientUserIDs: recipientUserIDs)
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .conversationRemovedForUser,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .conversationVisibilityChanged:
            throw Abort(.internalServerError, reason: "事件类型不能使用 summary refresh payload。")
        }
    }

    private func messagePayload(
        type: ConversationDomainEventType,
        messageID: UUID,
        recipientUserIDs: [UUID],
        messageCreatedPreview: ConversationMessageCreatedPreview?,
        messageCreatedRecipientInlineThreshold: Int
    ) throws -> ConversationDomainEventPayload {
        switch type {
        case .messageCreated:
            let shouldInlineRecipients = messageCreatedRecipientInlineThreshold == 0
                || recipientUserIDs.count < messageCreatedRecipientInlineThreshold
            return .messageCreated(
                messageID: messageID,
                recipientUserIDs: shouldInlineRecipients ? recipientUserIDs : [],
                preview: messageCreatedPreview
            )
        case .messageUpdated:
            return .messageUpdated(messageID: messageID, recipientUserIDs: recipientUserIDs)
        case .messageRecalled:
            return .messageRecalled(messageID: messageID, recipientUserIDs: recipientUserIDs)
        default:
            throw Abort(.internalServerError, reason: "事件类型不能使用 message payload。")
        }
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
        currentUserID: UUID,
        usersByID: [UUID: User]
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peerUser = usersByID[peerMembership.$user.id]
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

    @discardableResult
    func publish(
        _ type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID?,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        try await outboxEnqueuer.enqueueSummaryRefreshEvent(
            type: type,
            conversationID: conversationID,
            actorUserID: actorUserID,
            recipientUserIDs: recipientUserIDs,
            on: database
        )
    }

    @discardableResult
    func publishConversationRemoved(
        conversationID: UUID,
        actorUserID: UUID?,
        affectedUserID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        try await outboxEnqueuer.enqueueConversationRemovedEvent(
            conversationID: conversationID,
            actorUserID: actorUserID,
            affectedUserID: affectedUserID,
            on: database
        )
    }
}

struct ConversationMessageEventPublisher {
    let db: any Database

    private var outboxEnqueuer: ConversationOutboxEnqueuer {
        ConversationOutboxEnqueuer(db: db)
    }

    func publish(
        _ type: ConversationDomainEventType,
        conversationID: UUID,
        requesterUserID: UUID,
        messageID: UUID
    ) async throws {
        let recipientUserIDs = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
        try await outboxEnqueuer.enqueueMessageEvent(
            type: type,
            conversationID: conversationID,
            actorUserID: requesterUserID,
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
