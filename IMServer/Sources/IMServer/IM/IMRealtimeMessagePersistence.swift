import Fluent
import Vapor

extension IMRealtimeMessageService {
    func persistIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }

        if let forwardedResult = try await forwardToOwnerIfNeeded(
            payload,
            senderUserID: senderUserID,
            conversationID: conversationID
        ) {
            return forwardedResult
        }

        if let app, app.messageWriteBatchConfiguration.isEnabled {
            let prepared = try await prepareIncomingMessage(
                payload,
                senderUserID: senderUserID,
                conversationID: conversationID
            )
            return try await app.messageWriteBatcher.enqueue(
                .init(message: prepared),
                conversationID: conversationID,
                app: app,
                configuration: app.messageWriteBatchConfiguration
            )
        }

        if let app {
            return try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
                try await persistOwnedIncomingMessage(payload, senderUserID: senderUserID)
            }
        }

        return try await persistOwnedIncomingMessage(payload, senderUserID: senderUserID)
    }

    func persistOwnedIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID
    ) async throws -> IMRealtimeMessagePersistenceResult {
        let normalizedConversationID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = UUID(uuidString: normalizedConversationID) else {
            throw IMRealtimeMessageError.invalidConversationID
        }
        let prepared = try await prepareIncomingMessage(
            payload,
            senderUserID: senderUserID,
            conversationID: conversationID
        )
        guard let result = try await persistOwnedIncomingMessagesBatch([prepared], conversationID: conversationID).first else {
            throw IMRealtimeMessageError.conversationUnavailable
        }
        return result
    }

    func persistOwnedIncomingMessagesBatch(
        _ preparedMessages: [IMPreparedIncomingMessage],
        conversationID: UUID
    ) async throws -> [IMRealtimeMessagePersistenceResult] {
        try await IMMessagePersistencePipeline(
            service: self,
            conversationID: conversationID,
            preparedMessages: preparedMessages
        ).run()
    }

    func prepareIncomingMessage(
        _ payload: IMTCPMessagePayload,
        senderUserID: UUID,
        conversationID: UUID
    ) async throws -> IMPreparedIncomingMessage {
        try await reserveHotConversationCapacityIfNeeded(conversationID: conversationID)
        try await rejectBlockedDirectMessageIfNeeded(conversationID: conversationID, senderUserID: senderUserID)
        try await rejectMutedGroupMessageIfNeeded(conversationID: conversationID, senderUserID: senderUserID)
        let normalizedContent = try normalizedContent(from: payload.content)
        let trimmedClientMessageID = payload.clientMessageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IMPreparedIncomingMessage(
            payload: payload,
            senderUserID: senderUserID,
            conversationID: conversationID,
            normalizedContent: normalizedContent,
            normalizedClientMessageID: trimmedClientMessageID?.isEmpty == false ? trimmedClientMessageID : nil,
            serverTimestamp: Date()
        )
    }

    func rejectMutedGroupMessageIfNeeded(conversationID: UUID, senderUserID: UUID) async throws {
        let db = try await database(forConversationID: conversationID)
        guard let conversation = try await Conversation.find(conversationID, on: db),
              conversation.conversationKind == .group,
              conversation.muteAll
        else {
            return
        }
        let membership = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: senderUserID
        )
        switch membership.memberRoleEnum {
        case .owner, .admin:
            return
        case .member:
            throw Abort(.forbidden, reason: "群聊已开启全员禁言。")
        }
    }

    func rejectBlockedDirectMessageIfNeeded(conversationID: UUID, senderUserID: UUID) async throws {
        let db = try await database(forConversationID: conversationID)
        guard let conversation = try await Conversation.find(conversationID, on: db),
              conversation.conversationKind == .direct
        else {
            return
        }
        let memberships = try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard memberships.count == 2,
              let peerUserID = memberships.map(\.$user.id).first(where: { $0 != senderUserID })
        else {
            return
        }
        let senderBlocked = try await UserBlock.find(UserBlock.recordID(ownerUserID: senderUserID, blockedUserID: peerUserID), on: db) != nil
        let peerBlocked = try await UserBlock.find(UserBlock.recordID(ownerUserID: peerUserID, blockedUserID: senderUserID), on: db) != nil
        if senderBlocked || peerBlocked {
            throw Abort(.forbidden, reason: "当前无法发送私聊消息。")
        }
    }

    func database(forConversationID conversationID: UUID) async throws -> any Database {
        if let fixedDatabase {
            return fixedDatabase
        }
        guard let app else {
            throw Abort(.internalServerError, reason: "IMRealtimeMessageService missing both app and database.")
        }
        return try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
    }

    func reserveHotConversationCapacityIfNeeded(conversationID: UUID) async throws {
        guard let app else {
            return
        }
        let configuration = app.hotConversationConfiguration
        guard configuration.isEnabled else {
            return
        }

        do {
            try await app.hotConversationLimiter.reserve(
                conversationID: conversationID,
                limit: configuration.messagesPerSecondLimit
            )
        } catch HotConversationLimiterError.rateLimited {
            await app.hotConversationMetrics.recordTrackedWindows(
                await app.hotConversationLimiter.trackedWindowCount()
            )
            await app.hotConversationMetrics.recordRejectedMessage()
            throw IMRealtimeMessageError.hotConversationRateLimited
        }
        await app.hotConversationMetrics.recordTrackedWindows(
            await app.hotConversationLimiter.trackedWindowCount()
        )
    }

    func existingMessage(
        conversationID: UUID,
        senderUserID: UUID,
        clientMessageID: String?,
        on database: any Database
    ) async throws -> ConversationMessage? {
        guard let clientMessageID else {
            return nil
        }

        return try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$sender.$id == senderUserID)
            .filter(\.$clientMessageID == clientMessageID)
            .first()
    }

    func makePersistenceResult(
        conversationID: UUID,
        message: ConversationMessage,
        recipientUserIDs: [UUID],
        didCreateMessage: Bool,
        fallbackTimestamp: Date = Date()
    ) throws -> IMRealtimeMessagePersistenceResult {
        let messageID = try message.requireID().uuidString
        let content = try message.decodedContent()

        return IMRealtimeMessagePersistenceResult(
            conversationID: conversationID,
            acknowledgement: IMTCPAckPayload(
                messageID: messageID,
                conversationID: conversationID.uuidString,
                status: "accepted"
            ),
            message: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID,
                messageID: messageID,
                conversationID: conversationID.uuidString,
                senderUserID: message.$sender.id,
                serverSequence: UInt64(message.serverSequence),
                serverTimestamp: message.createdAt ?? fallbackTimestamp,
                content: content,
                derivedState: content.aggregate.derivedState
            ),
            recipientUserIDs: recipientUserIDs,
            didCreateMessage: didCreateMessage
        )
    }

    func advanceReadSequence(
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
            throw IMRealtimeMessageError.conversationUnavailable
        }

        guard membership.lastReadSequence < readSequence else {
            return
        }

        membership.lastReadSequence = readSequence
        try await membership.update(on: database)
    }
}
