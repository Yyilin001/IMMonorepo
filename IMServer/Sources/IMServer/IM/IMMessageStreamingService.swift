import Fluent
import Vapor

struct AIStreamingRequest: Sendable {
    let conversationID: UUID
    let prompt: String
    let userID: UUID
}

protocol AIStreamingProvider: Sendable {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error>
}

struct MockAIStreamingProvider: AIStreamingProvider {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = "AI: \(request.prompt)"
                    let chunks = output.split(separator: " ", omittingEmptySubsequences: false)
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        if index > 0 {
                            continuation.yield(" ")
                        }
                        continuation.yield(String(chunk))
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

struct ActiveAIMessageStreamContext: Sendable, Equatable {
    let streamID: String
    let conversationID: UUID
    let messageID: UUID
    let userID: UUID
    let recipientUserIDs: [UUID]
}

actor ActiveAIMessageStreamRegistry {
    private struct ActiveStream: Sendable {
        let context: ActiveAIMessageStreamContext
        var task: Task<Void, Never>?
    }

    private var streams: [String: ActiveStream] = [:]

    func register(context: ActiveAIMessageStreamContext) {
        streams[context.streamID] = ActiveStream(context: context, task: nil)
    }

    func attach(task: Task<Void, Never>, streamID: String) {
        guard var stream = streams[streamID] else {
            task.cancel()
            return
        }
        stream.task = task
        streams[streamID] = stream
    }

    func cancel(streamID: String) -> Task<Void, Never>? {
        streams.removeValue(forKey: streamID)?.task
    }

    func finish(streamID: String) {
        streams.removeValue(forKey: streamID)
    }

    func context(streamID: String) -> ActiveAIMessageStreamContext? {
        streams[streamID]?.context
    }
}

private struct StreamPublishEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipients: [UUID]
    let eventType: IMTCPConversationEventType
    let actorUserID: UUID
    let shouldPublish: Bool
}

private struct StreamStartEnvelope: Sendable {
    let response: IMMessageStreamResponse
    let recipientUserIDs: [UUID]
}

struct IMMessageStreamingService {
    private static let snapshotCharacterThreshold = 512
    private static let snapshotIntervalSeconds: TimeInterval = 1
    private static let maxFinalTextLength = 16_384
    private static let timeoutSeconds: UInt64 = 120
    private static let leaseHeartbeatIntervalSeconds: TimeInterval = 5
    private static let finalizeRetryDelaysNanoseconds: [UInt64] = [
        100_000_000,
        300_000_000,
        900_000_000
    ]

    let app: Application

    func startAIMessageStream(
        conversationID: UUID,
        userID: UUID,
        prompt rawPrompt: String
    ) async throws -> IMMessageStreamResponse {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw Abort(.badRequest, reason: "Prompt cannot be empty.")
        }

        let streamID = UUID().uuidString
        do {
            try await app.aiStreamLeaseStore.reserve(streamID: streamID, conversationID: conversationID, userID: userID)
            await app.aiStreamMetrics.recordLeaseReservation()
        } catch {
            await app.aiStreamMetrics.recordLeaseRejection()
            throw error
        }

        do {
            let initial = try await createInitialStreamingMessage(
                streamID: streamID,
                conversationID: conversationID,
                userID: userID
            )
            let context = ActiveAIMessageStreamContext(
                streamID: streamID,
                conversationID: conversationID,
                messageID: initial.response.message.id,
                userID: userID,
                recipientUserIDs: initial.recipientUserIDs
            )
            await app.activeAIMessageStreamRegistry.register(context: context)
            try await app.aiStreamLeaseStore.attach(streamID: streamID)
            await app.aiStreamMetrics.recordStarted()
            let task = Task {
                await runProviderStream(
                    context: context,
                    prompt: prompt
                )
            }
            await app.activeAIMessageStreamRegistry.attach(task: task, streamID: streamID)
            return initial.response
        } catch {
            await app.activeAIMessageStreamRegistry.finish(streamID: streamID)
            try? await app.aiStreamLeaseStore.finish(streamID: streamID, conversationID: conversationID, userID: userID)
            throw error
        }
    }

    func cancelMessageStream(
        conversationID: UUID,
        messageID: UUID,
        userID: UUID
    ) async throws -> IMMessageStreamResponse {
        let current = try await snapshot(conversationID: conversationID, messageID: messageID, userID: userID)
        guard current.stream.state == .streaming else {
            await app.aiStreamMetrics.recordTerminalCASConflict()
            return current
        }
        try await app.aiStreamLeaseStore.requestCancel(streamID: current.stream.streamID)
        await app.aiStreamMetrics.recordLeaseCancellationRequest()
        let task = await app.activeAIMessageStreamRegistry.cancel(streamID: current.stream.streamID)
        task?.cancel()
        return try await finalizeStream(
            streamID: current.stream.streamID,
            conversationID: conversationID,
            messageID: messageID,
            userID: userID,
            finalText: current.message.content.previewText,
            state: .cancelled,
            errorCode: nil,
            errorMessage: nil
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

    private func createInitialStreamingMessage(
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> StreamStartEnvelope {
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
                try await AIMessageStreamIndex(
                    streamID: streamID,
                    messageID: try message.requireID(),
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
                        messageID: try message.requireID()
                    ),
                    on: database
                )
                let response = try ConversationMessageService(db: database).messageResponse(
                    from: message,
                    conversationID: conversationID
                )
                let stream = streamPayload(
                    streamID: streamID,
                    messageID: try message.requireID(),
                    conversationID: conversationID,
                    chunkIndex: 0,
                    deltaText: nil,
                    partialTextLength: 0,
                    state: .streaming,
                    serverTimestamp: now
                )
                return StreamPublishEnvelope(
                    response: IMMessageStreamResponse(
                        message: response,
                        stream: stream
                    ),
                    recipients: membership.memberUserIDs,
                    eventType: .messageStreamStarted,
                    actorUserID: userID,
                    shouldPublish: true
                )
            }
        }

        try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
        await publish(
            eventType: envelope.eventType,
            conversationID: conversationID,
            recipientUserIDs: envelope.recipients,
            message: envelope.response.message,
            stream: envelope.response.stream,
            actorUserID: envelope.actorUserID
        )
        app.logger.info(
            "AI stream started",
            metadata: streamLogMetadata(
                streamID: streamID,
                messageID: envelope.response.message.id,
                conversationID: conversationID,
                userID: userID
            )
        )
        return StreamStartEnvelope(
            response: envelope.response,
            recipientUserIDs: envelope.recipients
        )
    }

    private func runProviderStream(
        context: ActiveAIMessageStreamContext,
        prompt: String
    ) async {
        var partial = ""
        var chunkIndex = 0
        var lastSnapshotAt = Date()
        var lastSnapshotLength = 0
        var lastLeaseHeartbeatAt = Date.distantPast
        let startedAt = Date()

        defer {
            Task {
                await app.activeAIMessageStreamRegistry.finish(streamID: context.streamID)
                try? await app.aiStreamLeaseStore.finish(
                    streamID: context.streamID,
                    conversationID: context.conversationID,
                    userID: context.userID
                )
            }
        }

        do {
            for try await delta in app.aiStreamingProvider.streamText(
                for: AIStreamingRequest(conversationID: context.conversationID, prompt: prompt, userID: context.userID)
            ) {
                try Task.checkCancellation()
                try await ensureLeaseActive(context: context, lastHeartbeatAt: &lastLeaseHeartbeatAt)
                if Date().timeIntervalSince(startedAt) > TimeInterval(Self.timeoutSeconds) {
                    throw Abort(.requestTimeout, reason: "AI stream timed out.")
                }
                chunkIndex += 1
                partial += delta
                if partial.count > Self.maxFinalTextLength {
                    throw Abort(.payloadTooLarge, reason: "AI stream output is too large.")
                }
                try await publishChunk(
                    context: context,
                    chunkIndex: chunkIndex,
                    delta: delta,
                    partialLength: partial.count
                )
                if partial.count - lastSnapshotLength >= Self.snapshotCharacterThreshold ||
                    Date().timeIntervalSince(lastSnapshotAt) >= Self.snapshotIntervalSeconds {
                    try await updateStreamSnapshot(
                        streamID: context.streamID,
                        conversationID: context.conversationID,
                        messageID: context.messageID,
                        partialText: partial,
                        chunkIndex: chunkIndex,
                        state: .streaming
                    )
                    lastSnapshotAt = Date()
                    lastSnapshotLength = partial.count
                }
            }
            _ = try await finalizeWithRetry(
                context: context,
                finalText: partial,
                state: .completed,
                errorCode: nil,
                errorMessage: nil
            )
        } catch is CancellationError {
            _ = try? await finalizeWithRetry(
                context: context,
                finalText: partial,
                state: .cancelled,
                errorCode: nil,
                errorMessage: nil
            )
        } catch {
            let code: String
            if let abort = error as? any AbortError, abort.status == .payloadTooLarge {
                code = "max_length_exceeded"
            } else if let abort = error as? any AbortError, abort.status == .requestTimeout {
                code = "stream_timeout"
            } else {
                code = "provider_error"
            }
            _ = try? await finalizeWithRetry(
                context: context,
                finalText: partial,
                state: .failed,
                errorCode: code,
                errorMessage: String(describing: error)
            )
        }
    }

    private func ensureLeaseActive(
        context: ActiveAIMessageStreamContext,
        lastHeartbeatAt: inout Date
    ) async throws {
        if try await app.aiStreamLeaseStore.cancelRequested(streamID: context.streamID) {
            throw CancellationError()
        }

        guard Date().timeIntervalSince(lastHeartbeatAt) >= Self.leaseHeartbeatIntervalSeconds else {
            return
        }

        let isActive = try await app.aiStreamLeaseStore.heartbeat(
            streamID: context.streamID,
            conversationID: context.conversationID,
            userID: context.userID
        )
        await app.aiStreamMetrics.recordLeaseHeartbeat()
        guard isActive else {
            throw CancellationError()
        }
        lastHeartbeatAt = Date()
    }

    @discardableResult
    private func finalizeWithRetry(
        context: ActiveAIMessageStreamContext,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> IMMessageStreamResponse {
        var lastError: (any Error)?
        for attempt in 0...Self.finalizeRetryDelaysNanoseconds.count {
            do {
                return try await finalizeStream(
                    streamID: context.streamID,
                    conversationID: context.conversationID,
                    messageID: context.messageID,
                    userID: context.userID,
                    finalText: finalText,
                    state: state,
                    errorCode: errorCode,
                    errorMessage: errorMessage
                )
            } catch {
                lastError = error
                guard attempt < Self.finalizeRetryDelaysNanoseconds.count else {
                    break
                }
                await app.aiStreamMetrics.recordFinalizeRetry()
                try await Task.sleep(nanoseconds: Self.finalizeRetryDelaysNanoseconds[attempt])
            }
        }
        await app.aiStreamMetrics.recordFinalizeFailure()
        throw lastError ?? Abort(.internalServerError, reason: "AI stream finalization failed.")
    }

    private func publishChunk(
        context: ActiveAIMessageStreamContext,
        chunkIndex: Int,
        delta: String,
        partialLength: Int
    ) async throws {
        await publish(
            eventType: .messageStreamChunk,
            conversationID: context.conversationID,
            recipientUserIDs: context.recipientUserIDs,
            message: nil,
            stream: streamPayload(
                streamID: context.streamID,
                messageID: context.messageID,
                conversationID: context.conversationID,
                chunkIndex: chunkIndex,
                deltaText: delta,
                partialTextLength: partialLength,
                state: .streaming
            ),
            actorUserID: context.userID
        )
        await app.aiStreamMetrics.recordChunkPublished()
        await app.aiStreamMetrics.recordChunkDatabaseBypass()
        app.logger.debug(
            "AI stream chunk published",
            metadata: streamLogMetadata(
                streamID: context.streamID,
                messageID: context.messageID,
                conversationID: context.conversationID,
                userID: context.userID
            )
        )
    }

    @discardableResult
    private func updateStreamSnapshot(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        partialText: String,
        chunkIndex: Int,
        state: MessageStreamLifecycleState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async throws -> IMMessageResponse {
        let response = try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
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
        await app.aiStreamMetrics.recordSnapshotWrite()
        app.logger.debug(
            "AI stream snapshot saved",
            metadata: streamLogMetadata(
                streamID: streamID,
                messageID: messageID,
                conversationID: conversationID,
                userID: nil
            )
        )
        return response
    }

    @discardableResult
    private func finalizeStream(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        userID: UUID,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> IMMessageStreamResponse {
        let envelope = try await app.conversationWriteCoordinator.run(conversationID: conversationID, app: app) {
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
                    return StreamPublishEnvelope(
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
                        eventType: Self.eventType(for: existing.state),
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
                return StreamPublishEnvelope(
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
                    eventType: Self.eventType(for: state),
                    actorUserID: userID,
                    shouldPublish: true
                )
            }
        }

        if envelope.shouldPublish {
            try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
            await publish(
                eventType: envelope.eventType,
                conversationID: conversationID,
                recipientUserIDs: envelope.recipients,
                message: envelope.response.message,
                stream: envelope.response.stream,
                actorUserID: envelope.actorUserID
            )
            await app.aiStreamMetrics.recordFinished(state: state)
            app.logger.info(
                "AI stream finalized",
                metadata: streamLogMetadata(
                    streamID: streamID,
                    messageID: messageID,
                    conversationID: conversationID,
                    userID: userID
                )
            )
        }
        return envelope.response
    }

    private func memberUserIDs(conversationID: UUID, on db: any Database) async throws -> [UUID] {
        try await ConversationMember.query(on: db)
            .filter(\.$conversation.$id == conversationID)
            .all()
            .map(\.$user.id)
    }

    private func currentStreamState(
        streamID: String,
        conversationID: UUID,
        messageID: UUID,
        on db: any Database
    ) async throws -> MessageStreamState {
        guard let message = try await ConversationMessage.query(on: db)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            throw Abort(.notFound, reason: "Message not found.")
        }
        let derivedState = try message.decodedDerivedState()
        guard let streamState = derivedState.streamState,
              streamState.streamID == streamID
        else {
            throw Abort(.notFound, reason: "Message stream not found.")
        }
        return streamState
    }

    private func publish(
        eventType: IMTCPConversationEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        message: IMMessageResponse?,
        stream: IMTCPMessageStreamPayload,
        actorUserID: UUID?
    ) async {
        await IMConversationEventService(app: app).publish(
            eventType: eventType,
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs,
            message: message,
            stream: stream,
            actorUserID: actorUserID
        )
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

    private static func eventType(for state: MessageStreamLifecycleState) -> IMTCPConversationEventType {
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

    private func streamLogMetadata(
        streamID: String,
        messageID: UUID,
        conversationID: UUID,
        userID: UUID?
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "streamID": .string(streamID),
            "messageID": .string(messageID.uuidString),
            "conversationID": .string(conversationID.uuidString),
            "nodeID": .string(app.imNodeID)
        ]
        if let userID {
            metadata["userID"] = .string(userID.uuidString)
        }
        return metadata
    }
}

private extension MessageDerivedState {
    func withStreamState(_ streamState: MessageStreamState) -> MessageDerivedState {
        MessageDerivedState(
            recallState: recallState,
            edits: edits,
            reactions: reactions,
            streamState: streamState
        )
    }
}

final class IMAIStreamRepairLifecycle: LifecycleHandler, @unchecked Sendable {
    private var sweeperTask: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        guard application.imRuntimeRole.servesGateway || application.imRuntimeRole.servesCommandAPI else {
            return
        }
        do {
            try await IMAIStreamRepairService(app: application).repairStaleStreamingMessages(
                reason: .serverRestarted
            )
        } catch {
            application.logger.warning(
                "AI stream startup repair failed",
                metadata: ["error": .string(String(describing: error))]
            )
        }

        sweeperTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    try Task.checkCancellation()
                    try await IMAIStreamRepairService(app: application).repairStaleStreamingMessages(
                        reason: .streamLost,
                        updatedBefore: Date().addingTimeInterval(-240),
                        skipActiveLeases: true
                    )
                } catch is CancellationError {
                    return
                } catch {
                    application.logger.warning(
                        "AI stream runtime stale repair failed",
                        metadata: ["error": .string(String(describing: error))]
                    )
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        sweeperTask?.cancel()
        sweeperTask = nil
    }
}

struct IMAIStreamRepairService {
    enum RepairReason: Sendable {
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

    private static let pageSize = 100

    let app: Application

    @discardableResult
    func repairStaleStreamingMessages(
        reason: RepairReason = .serverRestarted,
        now: Date = Date(),
        updatedBefore: Date? = nil,
        skipActiveLeases: Bool = false
    ) async throws -> Int {
        var repairedCount = 0
        for shard in app.conversationShardRouter.allCommandDatabases() {
            var offset = 0
            while true {
                var query = AIMessageStreamIndex.query(on: shard.database)
                    .filter(\.$state == MessageStreamLifecycleState.streaming.rawValue)
                    .sort(\.$updatedAt)
                    .range(offset..<(offset + Self.pageSize))
                if let updatedBefore {
                    query = query.filter(\.$updatedAt < updatedBefore)
                }
                let candidates = try await query.all()
                guard !candidates.isEmpty else {
                    break
                }
                await app.aiStreamMetrics.recordStartupRepairPage()
                for index in candidates {
                    if skipActiveLeases, try await app.aiStreamLeaseStore.isActive(streamID: index.streamID) {
                        continue
                    }
                    let didRepair = try await repair(index: index, reason: reason, now: now)
                    if didRepair {
                        repairedCount += 1
                    }
                }
                guard candidates.count == Self.pageSize else {
                    break
                }
                if skipActiveLeases {
                    offset += Self.pageSize
                }
            }
        }
        if repairedCount > 0 {
            switch reason {
            case .serverRestarted:
                await app.aiStreamMetrics.recordStartupStaleRepair(count: repairedCount)
            case .streamLost:
                await app.aiStreamMetrics.recordRuntimeStaleRepair(count: repairedCount)
            }
            app.logger.warning(
                "AI stream startup repair marked stale streams failed",
                metadata: [
                    "count": .stringConvertible(repairedCount),
                    "reason": .string(reason.errorCode)
                ]
            )
            try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
        }
        return repairedCount
    }

    private func repair(index: AIMessageStreamIndex, reason: RepairReason, now: Date) async throws -> Bool {
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
                let recipients = try await ConversationMember.query(on: database)
                    .filter(\.$conversation.$id == conversationID)
                    .all()
                    .map(\.$user.id)
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
}

private struct AIStreamingProviderStorageKey: StorageKey {
    typealias Value = any AIStreamingProvider
}

private struct ActiveAIMessageStreamRegistryStorageKey: StorageKey {
    typealias Value = ActiveAIMessageStreamRegistry
}

extension Application {
    var aiStreamingProvider: any AIStreamingProvider {
        get {
            if let provider = storage[AIStreamingProviderStorageKey.self] {
                return provider
            }
            let provider = MockAIStreamingProvider()
            storage[AIStreamingProviderStorageKey.self] = provider
            return provider
        }
        set { storage[AIStreamingProviderStorageKey.self] = newValue }
    }

    var activeAIMessageStreamRegistry: ActiveAIMessageStreamRegistry {
        get {
            if let registry = storage[ActiveAIMessageStreamRegistryStorageKey.self] {
                return registry
            }
            let registry = ActiveAIMessageStreamRegistry()
            storage[ActiveAIMessageStreamRegistryStorageKey.self] = registry
            return registry
        }
        set { storage[ActiveAIMessageStreamRegistryStorageKey.self] = newValue }
    }
}
