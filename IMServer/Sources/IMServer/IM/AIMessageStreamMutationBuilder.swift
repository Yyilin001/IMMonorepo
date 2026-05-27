import Vapor

enum AIMessageStreamMutationBuilder {
    static func initialDerivedState(streamID: String, updatedAt: Date) -> MessageDerivedState {
        MessageDerivedState(
            streamState: MessageStreamState(
                streamID: streamID,
                state: .streaming,
                updatedAt: updatedAt
            )
        )
    }

    static func updatedStreamState(
        streamID: String,
        state: MessageStreamLifecycleState,
        chunkIndex: Int,
        partialText: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date
    ) -> MessageStreamState {
        MessageStreamState(
            streamID: streamID,
            state: state,
            lastChunkIndex: chunkIndex,
            partialText: partialText,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    static func terminalStreamState(
        streamID: String,
        state: MessageStreamLifecycleState,
        finalText: String,
        errorCode: String?,
        errorMessage: String?,
        updatedAt: Date
    ) -> MessageStreamState {
        updatedStreamState(
            streamID: streamID,
            state: state,
            chunkIndex: Int(Int32.max),
            partialText: finalText,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    static func failedRepairStreamState(
        from currentStream: MessageStreamState,
        reason: AIStreamRepairReason,
        updatedAt: Date
    ) -> MessageStreamState {
        updatedStreamState(
            streamID: currentStream.streamID,
            state: .failed,
            chunkIndex: currentStream.lastChunkIndex,
            partialText: currentStream.partialText,
            errorCode: reason.errorCode,
            errorMessage: reason.errorMessage,
            updatedAt: updatedAt
        )
    }

    static func streamPayload(
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

    static func streamResponse(
        message: IMMessageResponse,
        streamID: String,
        messageID: UUID,
        conversationID: UUID,
        chunkIndex: Int,
        partialTextLength: Int,
        state: MessageStreamLifecycleState,
        deltaText: String? = nil,
        serverTimestamp: Date = Date()
    ) -> IMMessageStreamResponse {
        IMMessageStreamResponse(
            message: message,
            stream: streamPayload(
                streamID: streamID,
                messageID: messageID,
                conversationID: conversationID,
                chunkIndex: chunkIndex,
                deltaText: deltaText,
                partialTextLength: partialTextLength,
                state: state,
                serverTimestamp: serverTimestamp
            )
        )
    }

    static func eventType(for state: MessageStreamLifecycleState) throws -> IMTCPChatDomainEventType {
        switch state {
        case .completed:
            .messageStreamCompleted
        case .failed:
            .messageStreamFailed
        case .cancelled:
            .messageStreamCancelled
        case .streaming:
            throw Abort(.internalServerError, reason: "Streaming chunks are transient TCP stream signals, not durable domain events.")
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
