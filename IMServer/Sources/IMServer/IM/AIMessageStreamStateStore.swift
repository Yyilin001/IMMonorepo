import Fluent
import Vapor

struct AIMessageStreamPublishEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipients: [UUID]
    let eventType: IMTCPConversationEventType
    let actorUserID: UUID
    let shouldPublish: Bool
}

struct AIMessageStreamStartEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipientUserIDs: [UUID]
}

enum AIStreamRepairReason: Equatable, Sendable {
    case serverRestarted
    case streamLost

    var errorCode: String {
        switch self {
        case .serverRestarted:
            "server_restarted"
        case .streamLost:
            "stream_lost"
        }
    }

    var errorMessage: String {
        switch self {
        case .serverRestarted:
            "AI stream was interrupted by server restart."
        case .streamLost:
            "AI stream was interrupted before a terminal state was persisted."
        }
    }
}

struct AIMessageStreamConsistencyIssue: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case missingIndex
        case missingMessage
        case missingDerivedState
        case stateMismatch
        case chunkIndexRegressed
        case missingTerminalAt
    }

    let kind: Kind
    let streamID: String
    let messageID: UUID?
    let conversationID: UUID?
}

struct AIMessageStreamStateStore {
    private static let pageSize = 100

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
                let state = MessageDerivedState(
                    streamState: MessageStreamState(
                        streamID: streamID,
                        state: .streaming,
                        updatedAt: now
                    )
                )
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: userID,
                    serverSequence: sequence,
                    content: .text(""),
                    derivedState: state
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
                let stream = streamPayload(
                    streamID: streamID,
                    messageID: messageID,
                    conversationID: conversationID,
                    chunkIndex: 0,
                    deltaText: nil,
                    partialTextLength: 0,
                    state: .streaming,
                    serverTimestamp: now
                )
                return AIMessageStreamPublishEnvelope(
                    response: IMMessageStreamResponse(message: response, stream: stream),
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

    func snapshot(
        conversationID: UUID,
        messageID: UUID,
        userID: UUID
    ) async throws -> IMMessageStreamResponse {
        let db = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
        _ = try await ConversationMembershipService(db: db).requireMembershipRecord(
            conversationID: conversationID,
            userID: userID
        )
        guard let message = try await ConversationMessage.find(messageID, on: db),
              message.$conversation.id == conversationID
        else {
            throw Abort(.notFound, reason: "Message not found.")
        }

        let response = try ConversationMessageService(db: db).messageResponse(
            from: message,
            conversationID: conversationID
        )
        guard let streamState = response.derivedState.streamState else {
            throw Abort(.notFound, reason: "Message stream not found.")
        }
        return IMMessageStreamResponse(
            message: response,
            stream: streamPayload(
                streamID: streamState.streamID,
                messageID: messageID,
                conversationID: conversationID,
                chunkIndex: streamState.lastChunkIndex,
                deltaText: nil,
                partialTextLength: streamState.partialText.count,
                state: streamState.state
            )
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
                        MessageStreamState(
                            streamID: streamID,
                            state: state,
                            lastChunkIndex: chunkIndex,
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
                        response: IMMessageStreamResponse(
                            message: response,
                            stream: streamPayload(
                                streamID: existing.streamID,
                                messageID: messageID,
                                conversationID: conversationID,
                                chunkIndex: existing.lastChunkIndex,
                                deltaText: nil,
                                partialTextLength: existing.partialText.count,
                                state: existing.state
                            )
                        ),
                        recipients: [],
                        eventType: eventType(for: existing.state),
                        actorUserID: userID,
                        shouldPublish: false
                    )
                }

                let now = Date()
                let terminalState = MessageStreamState(
                    streamID: streamID,
                    state: state,
                    lastChunkIndex: Int.max,
                    partialText: finalText,
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
                    response: IMMessageStreamResponse(
                        message: response,
                        stream: streamPayload(
                            streamID: streamID,
                            messageID: messageID,
                            conversationID: conversationID,
                            chunkIndex: terminalState.lastChunkIndex,
                            deltaText: nil,
                            partialTextLength: finalText.count,
                            state: state
                        )
                    ),
                    recipients: recipients,
                    eventType: eventType(for: state),
                    actorUserID: userID,
                    shouldPublish: true
                )
            }
        }
    }

    @discardableResult
    func backfillMissingStreamIndexes(now: Date = Date()) async throws -> Int {
        var backfilledCount = 0
        for shard in app.conversationShardRouter.allCommandDatabases() {
            var offset = 0
            while true {
                let messages = try await ConversationMessage.query(on: shard.database)
                    .filter(\.$kind == IMMessageContentType.text.rawValue)
                    .sort(\.$createdAt)
                    .range(offset..<(offset + Self.pageSize))
                    .all()
                guard !messages.isEmpty else {
                    break
                }

                for message in messages {
                    guard let messageID = message.id,
                          let streamState = try message.decodedDerivedState().streamState,
                          try await AIMessageStreamIndex.find(streamState.streamID, on: shard.database) == nil
                    else {
                        continue
                    }

                    let index = AIMessageStreamIndex(
                        streamID: streamState.streamID,
                        messageID: messageID,
                        conversationID: message.$conversation.id,
                        userID: message.$sender.id,
                        state: streamState.state,
                        lastChunkIndex: streamState.lastChunkIndex,
                        createdAt: message.createdAt ?? streamState.updatedAt,
                        updatedAt: streamState.updatedAt,
                        terminalAt: streamState.state == .streaming ? nil : streamState.updatedAt,
                        errorCode: streamState.errorCode
                    )
                    try await index.create(on: shard.database)
                    backfilledCount += 1
                }

                guard messages.count == Self.pageSize else {
                    break
                }
                offset += Self.pageSize
            }
        }

        return backfilledCount
    }

    func auditConsistency() async throws -> [AIMessageStreamConsistencyIssue] {
        var issues: [AIMessageStreamConsistencyIssue] = []
        for shard in app.conversationShardRouter.allCommandDatabases() {
            let indexes = try await AIMessageStreamIndex.query(on: shard.database).all()
            for index in indexes {
                guard let message = try await ConversationMessage.query(on: shard.database)
                    .filter(\.$id == index.messageID)
                    .filter(\.$conversation.$id == index.conversationID)
                    .first()
                else {
                    issues.append(.init(kind: .missingMessage, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                    continue
                }
                guard let streamState = try message.decodedDerivedState().streamState,
                      streamState.streamID == index.streamID
                else {
                    issues.append(.init(kind: .missingDerivedState, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                    continue
                }
                if streamState.state != index.lifecycleState {
                    issues.append(.init(kind: .stateMismatch, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                }
                if index.lastChunkIndex < streamState.lastChunkIndex {
                    issues.append(.init(kind: .chunkIndexRegressed, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                }
                if index.lifecycleState != .streaming, index.terminalAt == nil {
                    issues.append(.init(kind: .missingTerminalAt, streamID: index.streamID, messageID: index.messageID, conversationID: index.conversationID))
                }
            }

            var offset = 0
            while true {
                let messages = try await ConversationMessage.query(on: shard.database)
                    .filter(\.$kind == IMMessageContentType.text.rawValue)
                    .sort(\.$createdAt)
                    .range(offset..<(offset + Self.pageSize))
                    .all()
                guard !messages.isEmpty else {
                    break
                }
                for message in messages {
                    guard let messageID = message.id,
                          let streamState = try message.decodedDerivedState().streamState,
                          try await AIMessageStreamIndex.find(streamState.streamID, on: shard.database) == nil
                    else {
                        continue
                    }
                    issues.append(.init(
                        kind: .missingIndex,
                        streamID: streamState.streamID,
                        messageID: messageID,
                        conversationID: message.$conversation.id
                    ))
                }
                guard messages.count == Self.pageSize else {
                    break
                }
                offset += Self.pageSize
            }
        }
        return issues
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
                let failedState = MessageStreamState(
                    streamID: currentStream.streamID,
                    state: .failed,
                    lastChunkIndex: currentStream.lastChunkIndex,
                    partialText: currentStream.partialText,
                    errorCode: reason.errorCode,
                    errorMessage: reason.errorMessage,
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

    private func streamPayload(
        streamID: String,
        messageID: UUID,
        conversationID: UUID,
        chunkIndex: Int,
        deltaText: String?,
        partialTextLength: Int,
        state: MessageStreamLifecycleState,
        serverTimestamp: Date = Date()
    ) -> IMTCPMessageStreamPayload {
        IMTCPMessageStreamPayload(
            streamID: streamID,
            messageID: messageID.uuidString,
            conversationID: conversationID.uuidString,
            chunkIndex: chunkIndex,
            deltaText: deltaText,
            partialTextLength: partialTextLength,
            state: state,
            serverTimestamp: serverTimestamp
        )
    }

    private func eventType(for state: MessageStreamLifecycleState) -> IMTCPConversationEventType {
        switch state {
        case .completed:
            .messageStreamCompleted
        case .failed:
            .messageStreamFailed
        case .cancelled:
            .messageStreamCancelled
        case .streaming:
            .messageStreamChunk
        }
    }
}

extension MessageDerivedState {
    func withStreamState(_ streamState: MessageStreamState) -> MessageDerivedState {
        MessageDerivedState(
            recallState: recallState,
            edits: edits,
            reactions: reactions,
            streamState: streamState
        )
    }
}
