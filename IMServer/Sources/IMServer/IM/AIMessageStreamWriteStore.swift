import Fluent
import Vapor

// The only writer for message stream derivedState/content and
// im_ai_message_streams. All mutations stay in the conversation write
// coordinator transaction so clients never observe split-brain stream state.
struct AIMessageStreamWriteStore {
    let app: Application

    func createInitialStreamingMessage(
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> AIMessageStreamStartEnvelope {
        let envelope = try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
            let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            let now = Date()
            return try await db.transaction { database in
                let realtimeService = IMRealtimeMessageService(app: app)
                let membership = try await realtimeService.requireConversationMembershipContext(
                    conversationID: conversationID,
                    senderUserID: userID,
                    on: database
                )
                let sequence = try await realtimeService.allocateNextServerSequence(
                    conversationID: conversationID,
                    updatedAt: now,
                    on: database
                )
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: userID,
                    serverSequence: sequence,
                    content: .text(""),
                    derivedState: AIMessageStreamMutationBuilder.initialDerivedState(
                        streamID: streamID,
                        updatedAt: now
                    )
                )
                try await message.create(on: database)
                let messageID = try message.requireID()
                try await AIMessageStreamIndex(
                    streamID: streamID,
                    messageID: messageID,
                    conversationID: conversationID,
                    userID: userID,
                    state: .streaming,
                    createdAt: now,
                    updatedAt: now
                ).create(on: database)
                try await realtimeService.advanceReadSequence(
                    conversationID: conversationID,
                    userID: userID,
                    readSequence: sequence,
                    on: database
                )
                try await ConversationOutboxService(db: database).enqueue(
                    type: .messageCreated,
                    conversationID: conversationID,
                    payload: ConversationDomainEventPayload(
                        recipientUserIDs: membership.memberUserIDs,
                        messageID: messageID
                    ),
                    on: database
                )
                let response = try ConversationMessageService(db: database).messageResponse(
                    from: message,
                    conversationID: conversationID
                )
                return AIMessageStreamPublishEnvelope(
                    response: AIMessageStreamMutationBuilder.streamResponse(
                        message: response,
                        streamID: streamID,
                        messageID: messageID,
                        conversationID: conversationID,
                        chunkIndex: 0,
                        partialTextLength: 0,
                        state: .streaming,
                        serverTimestamp: now
                    ),
                    recipients: membership.memberUserIDs,
                    eventType: .messageStreamStarted,
                    actorUserID: userID,
                    shouldPublish: true
                )
            }
        }

        return AIMessageStreamStartEnvelope(
            response: envelope.response,
            recipientUserIDs: envelope.recipients
        )
    }

    @discardableResult
    func updateSnapshot(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        partialText: String,
        chunkIndex: Int,
        state: MessageStreamLifecycleState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async throws -> IMMessageResponse {
        try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
            let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            return try await db.transaction { database in
                guard let message = try await ConversationMessage.query(on: database)
                    .filter(\.$id == messageID)
                    .filter(\.$conversation.$id == conversationID)
                    .first()
                else {
                    throw Abort(.notFound, reason: "Message not found.")
                }
                let derivedState = try message.decodedDerivedState()
                guard let existing = derivedState.streamState,
                      existing.streamID == streamID
                else {
                    throw Abort(.notFound, reason: "Message stream not found.")
                }
                guard existing.state == .streaming else {
                    await app.aiStreamMetrics.recordTerminalCASConflict()
                    return try ConversationMessageService(db: database).messageResponse(
                        from: message,
                        conversationID: conversationID
                    )
                }
                guard chunkIndex >= existing.lastChunkIndex else {
                    return try ConversationMessageService(db: database).messageResponse(
                        from: message,
                        conversationID: conversationID
                    )
                }

                let now = Date()
                try message.replaceContent(.text(partialText))
                try message.replaceDerivedState(
                    derivedState.withStreamState(
                        AIMessageStreamMutationBuilder.updatedStreamState(
                            streamID: streamID,
                            state: state,
                            chunkIndex: chunkIndex,
                            partialText: partialText,
                            errorCode: errorCode,
                            errorMessage: errorMessage,
                            updatedAt: now
                        )
                    )
                )
                try await message.update(on: database)
                if let index = try await AIMessageStreamIndex.find(streamID, on: database) {
                    index.lifecycleState = state
                    index.lastChunkIndex = chunkIndex
                    index.updatedAt = now
                    index.errorCode = errorCode
                    if state != .streaming {
                        index.terminalAt = now
                    }
                    try await index.update(on: database)
                }
                return try ConversationMessageService(db: database).messageResponse(
                    from: message,
                    conversationID: conversationID
                )
            }
        }
    }

    @discardableResult
    func finalize(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        userID: UUID,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> AIMessageStreamPublishEnvelope {
        try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
            let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            return try await db.transaction { database in
                guard let message = try await ConversationMessage.query(on: database)
                    .filter(\.$id == messageID)
                    .filter(\.$conversation.$id == conversationID)
                    .first()
                else {
                    throw Abort(.notFound, reason: "Message not found.")
                }
                _ = try await ConversationMembershipService(db: database).requireMembershipRecord(
                    conversationID: conversationID,
                    userID: userID
                )
                let derivedState = try message.decodedDerivedState()
                guard let existing = derivedState.streamState,
                      existing.streamID == streamID
                else {
                    throw Abort(.notFound, reason: "Message stream not found.")
                }

                if existing.state != .streaming {
                    await app.aiStreamMetrics.recordTerminalCASConflict()
                    let response = try ConversationMessageService(db: database).messageResponse(
                        from: message,
                        conversationID: conversationID
                    )
                    return AIMessageStreamPublishEnvelope(
                        response: AIMessageStreamMutationBuilder.streamResponse(
                            message: response,
                            streamID: existing.streamID,
                            messageID: messageID,
                            conversationID: conversationID,
                            chunkIndex: existing.lastChunkIndex,
                            partialTextLength: existing.partialText.count,
                            state: existing.state
                        ),
                        recipients: [],
                        eventType: AIMessageStreamMutationBuilder.eventType(for: existing.state),
                        actorUserID: userID,
                        shouldPublish: false
                    )
                }

                let now = Date()
                let terminalState = AIMessageStreamMutationBuilder.terminalStreamState(
                    streamID: streamID,
                    state: state,
                    finalText: finalText,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    updatedAt: now
                )
                try message.replaceContent(.text(finalText))
                try message.replaceDerivedState(derivedState.withStreamState(terminalState))
                try await message.update(on: database)
                if let index = try await AIMessageStreamIndex.find(streamID, on: database) {
                    index.lifecycleState = state
                    index.lastChunkIndex = terminalState.lastChunkIndex
                    index.updatedAt = now
                    index.terminalAt = now
                    index.errorCode = errorCode
                    try await index.update(on: database)
                }
                let recipients = try await memberUserIDs(conversationID: conversationID, on: database)
                try await ConversationOutboxService(db: database).enqueue(
                    type: .messageUpdated,
                    conversationID: conversationID,
                    payload: ConversationDomainEventPayload(
                        recipientUserIDs: recipients,
                        messageID: messageID
                    ),
                    on: database
                )
                let response = try ConversationMessageService(db: database).messageResponse(
                    from: message,
                    conversationID: conversationID
                )
                return AIMessageStreamPublishEnvelope(
                    response: AIMessageStreamMutationBuilder.streamResponse(
                        message: response,
                        streamID: streamID,
                        messageID: messageID,
                        conversationID: conversationID,
                        chunkIndex: terminalState.lastChunkIndex,
                        partialTextLength: finalText.count,
                        state: state
                    ),
                    recipients: recipients,
                    eventType: AIMessageStreamMutationBuilder.eventType(for: state),
                    actorUserID: userID,
                    shouldPublish: true
                )
            }
        }
    }

    @discardableResult
    func repair(index: AIMessageStreamIndex, reason: AIStreamRepairReason, now: Date) async throws -> Bool {
        let streamID = index.streamID
        let conversationID = index.conversationID
        let messageID = index.messageID
        return try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
            let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            return try await db.transaction { database -> Bool in
                guard let lockedIndex = try await AIMessageStreamIndex.find(streamID, on: database),
                      lockedIndex.lifecycleState == .streaming,
                      let lockedMessage = try await ConversationMessage.query(on: database)
                        .filter(\.$id == messageID)
                        .filter(\.$conversation.$id == conversationID)
                        .first()
                else {
                    return false
                }
                let currentState = try lockedMessage.decodedDerivedState()
                guard let currentStream = currentState.streamState,
                      currentStream.streamID == streamID,
                      currentStream.state == .streaming
                else {
                    lockedIndex.lifecycleState = .failed
                    lockedIndex.updatedAt = now
                    lockedIndex.terminalAt = now
                    lockedIndex.errorCode = reason.errorCode
                    try await lockedIndex.update(on: database)
                    return false
                }
                let failedState = AIMessageStreamMutationBuilder.failedRepairStreamState(
                    from: currentStream,
                    reason: reason,
                    updatedAt: now
                )
                try lockedMessage.replaceContent(.text(currentStream.partialText))
                try lockedMessage.replaceDerivedState(currentState.withStreamState(failedState))
                try await lockedMessage.update(on: database)
                lockedIndex.lifecycleState = .failed
                lockedIndex.lastChunkIndex = currentStream.lastChunkIndex
                lockedIndex.updatedAt = now
                lockedIndex.terminalAt = now
                lockedIndex.errorCode = reason.errorCode
                try await lockedIndex.update(on: database)
                let recipients = try await memberUserIDs(conversationID: conversationID, on: database)
                try await ConversationOutboxService(db: database).enqueue(
                    type: .messageUpdated,
                    conversationID: conversationID,
                    payload: ConversationDomainEventPayload(
                        recipientUserIDs: recipients,
                        messageID: messageID
                    ),
                    on: database
                )
                return true
            }
        }
    }

    private func memberUserIDs(conversationID: UUID, on db: any Database) async throws -> [UUID] {
        try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
    }
}
