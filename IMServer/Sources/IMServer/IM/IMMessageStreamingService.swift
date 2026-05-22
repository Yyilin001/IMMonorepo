import Vapor

// Orchestrates policy, lease, provider execution, and fanout. Persistent stream
// state always goes through AIMessageStreamStateStore.
struct IMMessageStreamingService {
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
        let policyDecision = try await AIStreamProviderPolicyService(app: app).authorizeStart(
            prompt: prompt,
            conversationID: conversationID,
            userID: userID
        )

        let streamID = UUID().uuidString
        do {
            try await app.aiStreamLeaseStore.reserve(streamID: streamID, conversationID: conversationID, userID: userID)
            await app.aiStreamMetrics.recordLeaseReservation()
        } catch {
            await app.aiStreamCostLedger.release(policyDecision.costReservationID)
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
                await AIStreamProviderRunner(
                    app: app,
                    context: context,
                    prompt: prompt,
                    modelID: policyDecision.modelID,
                    estimatedCostUnits: policyDecision.estimatedCostUnits
                ).run()
            }
            await app.activeAIMessageStreamRegistry.attach(task: task, streamID: streamID)
            return initial.response
        } catch {
            await app.activeAIMessageStreamRegistry.finish(streamID: streamID)
            try? await app.aiStreamLeaseStore.finish(streamID: streamID, conversationID: conversationID, userID: userID)
            await app.aiStreamCostLedger.release(policyDecision.costReservationID)
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
        return try await AIStreamFinalizer(app: app).finalize(
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
        try await AIMessageStreamStateStore(app: app).snapshot(
            conversationID: conversationID,
            messageID: messageID,
            userID: userID
        )
    }

    private func createInitialStreamingMessage(
        streamID: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> AIMessageStreamStartEnvelope {
        let initial = try await AIMessageStreamStateStore(app: app).createInitialStreamingMessage(
            streamID: streamID,
            conversationID: conversationID,
            userID: userID
        )
        try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
        await AIStreamEventPublisher(app: app).publishStarted(
            initial: initial,
            streamID: streamID,
            conversationID: conversationID,
            userID: userID
        )
        return initial
    }
}
