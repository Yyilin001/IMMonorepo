import Vapor

struct AIStreamEventPublisher {
    let app: Application

    func publishChunk(
        context: ActiveAIMessageStreamContext,
        chunkIndex: Int,
        delta: String,
        partialLength: Int
    ) async {
        let signal = IMTCPMessageStreamSignalPayload(
            stream: AIMessageStreamMutationBuilder.streamPayload(
                streamID: context.streamID,
                messageID: context.messageID,
                conversationID: context.conversationID,
                chunkIndex: chunkIndex,
                deltaText: delta,
                partialTextLength: partialLength,
                state: .streaming
            ),
            message: nil
        )
        await app.gatewaySessionService.sendStreamSignal(
            signal,
            toUserIDs: Array(Set(context.recipientUserIDs)),
            requestID: UUID()
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
