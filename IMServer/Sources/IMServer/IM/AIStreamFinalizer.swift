import Vapor

struct AIStreamFinalizer {
    private static let retryDelaysNanoseconds: [UInt64] = [
        100_000_000,
        300_000_000,
        900_000_000
    ]

    let app: Application

    @discardableResult
    func finalizeWithRetry(
        context: ActiveAIMessageStreamContext,
        finalText: String,
        state: MessageStreamLifecycleState,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> IMMessageStreamResponse {
        var lastError: (any Error)?
        for attempt in 0...Self.retryDelaysNanoseconds.count {
            do {
                return try await finalize(
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
                guard attempt < Self.retryDelaysNanoseconds.count else {
                    break
                }
                await app.aiStreamMetrics.recordFinalizeRetry()
                try await Task.sleep(nanoseconds: Self.retryDelaysNanoseconds[attempt])
            }
        }
        await app.aiStreamMetrics.recordFinalizeFailure()
        throw lastError ?? Abort(.internalServerError, reason: "AI stream finalization failed.")
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
    ) async throws -> IMMessageStreamResponse {
        let envelope = try await AIMessageStreamStateStore(app: app).finalize(
            streamID: streamID,
            conversationID: conversationID,
            messageID: messageID,
            userID: userID,
            finalText: finalText,
            state: state,
            errorCode: errorCode,
            errorMessage: errorMessage
        )

        if envelope.shouldPublish {
            try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
            await AIStreamEventPublisher(app: app).publishFinalized(
                envelope: envelope,
                streamID: streamID,
                conversationID: conversationID,
                userID: userID,
                state: state
            )
        }
        return envelope.response
    }
}
