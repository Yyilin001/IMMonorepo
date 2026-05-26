import Vapor

struct AIStreamEventPublisher {
    let app: Application

    func publishStarted(
        initial: AIMessageStreamStartEnvelope,
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async {
        await publish(
            eventType: .messageStreamStarted,
            conversationID: conversationID,
            recipientUserIDs: initial.recipientUserIDs,
            message: initial.response.message,
            stream: initial.response.stream,
            actorUserID: userID
        )
        app.logger.info(
            "AI stream started",
            metadata: streamLogMetadata(
                streamID: streamID,
                messageID: initial.response.message.id,
                conversationID: conversationID,
                userID: userID
            )
        )
    }

    func publishChunk(
        context: ActiveAIMessageStreamContext,
        chunkIndex: Int,
        delta: String,
        partialLength: Int
    ) async {
        await publish(
            eventType: .messageStreamChunk,
            conversationID: context.conversationID,
            recipientUserIDs: context.recipientUserIDs,
            message: nil,
            stream: AIMessageStreamMutationBuilder.streamPayload(
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

    func publishFinalized(
        envelope: AIMessageStreamPublishEnvelope,
        streamID: String,
        conversationID: UUID,
        userID: UUID,
        state: MessageStreamLifecycleState
    ) async {
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
                messageID: envelope.response.message.id,
                conversationID: conversationID,
                userID: userID
            )
        )
    }

    private func publish(
        eventType: IMTCPChatDomainEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        message: IMMessageResponse?,
        stream: IMTCPMessageStreamPayload,
        actorUserID: UUID?
    ) async {
        let eventID = UUID()
        for recipientUserID in Array(Set(recipientUserIDs)).sorted(by: { $0.uuidString < $1.uuidString }) {
            let conversation = try? await ConversationStrongReadService(app: app).conversationSummary(
                conversationID: conversationID,
                for: recipientUserID
            )
            await app.gatewaySessionService.sendDomainEvent(
                IMTCPChatDomainEventPayload(
                    eventID: eventID,
                    eventType: eventType,
                    aggregateType: "conversation",
                    aggregateID: conversationID,
                    aggregateSequence: UInt64(message?.serverSequence ?? stream.chunkIndex),
                    occurredAt: stream.serverTimestamp,
                    actorUserID: actorUserID,
                    conversation: conversation,
                    body: .messageStream(stream, message: message)
                ),
                toUserIDs: [recipientUserID],
                requestID: eventID
            )
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
