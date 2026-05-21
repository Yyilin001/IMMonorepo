import Vapor

struct AIStreamProviderRunner {
    private static let snapshotCharacterThreshold = 512
    private static let snapshotIntervalSeconds: TimeInterval = 1
    static let maxFinalTextLength = 16_384
    private static let timeoutSeconds: UInt64 = 120
    private static let leaseHeartbeatIntervalSeconds: TimeInterval = 5

    let app: Application
    let context: ActiveAIMessageStreamContext
    let prompt: String
    let modelID: String
    let estimatedCostUnits: Int

    func run() async {
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
                for: AIStreamingRequest(
                    conversationID: context.conversationID,
                    prompt: prompt,
                    userID: context.userID,
                    modelID: modelID,
                    estimatedCostUnits: estimatedCostUnits
                )
            ) {
                try Task.checkCancellation()
                try await ensureLeaseActive(lastHeartbeatAt: &lastLeaseHeartbeatAt)
                if Date().timeIntervalSince(startedAt) > TimeInterval(Self.timeoutSeconds) {
                    throw Abort(.requestTimeout, reason: "AI stream timed out.")
                }
                chunkIndex += 1
                partial += delta
                if partial.count > Self.maxFinalTextLength {
                    throw Abort(.payloadTooLarge, reason: "AI stream output is too large.")
                }
                await AIStreamEventPublisher(app: app).publishChunk(
                    context: context,
                    chunkIndex: chunkIndex,
                    delta: delta,
                    partialLength: partial.count
                )
                if partial.count - lastSnapshotLength >= Self.snapshotCharacterThreshold ||
                    Date().timeIntervalSince(lastSnapshotAt) >= Self.snapshotIntervalSeconds {
                    try await updateSnapshot(
                        partialText: partial,
                        chunkIndex: chunkIndex,
                        state: .streaming
                    )
                    lastSnapshotAt = Date()
                    lastSnapshotLength = partial.count
                }
            }
            _ = try await AIStreamFinalizer(app: app).finalizeWithRetry(
                context: context,
                finalText: partial,
                state: .completed,
                errorCode: nil,
                errorMessage: nil
            )
        } catch is CancellationError {
            _ = try? await AIStreamFinalizer(app: app).finalizeWithRetry(
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
            _ = try? await AIStreamFinalizer(app: app).finalizeWithRetry(
                context: context,
                finalText: partial,
                state: .failed,
                errorCode: code,
                errorMessage: String(describing: error)
            )
        }
    }

    private func ensureLeaseActive(lastHeartbeatAt: inout Date) async throws {
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
    private func updateSnapshot(
        partialText: String,
        chunkIndex: Int,
        state: MessageStreamLifecycleState,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async throws -> IMMessageResponse {
        let response = try await AIMessageStreamStateStore(app: app).updateSnapshot(
            streamID: context.streamID,
            conversationID: context.conversationID,
            messageID: context.messageID,
            partialText: partialText,
            chunkIndex: chunkIndex,
            state: state,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
        await app.aiStreamMetrics.recordSnapshotWrite()
        app.logger.debug(
            "AI stream snapshot saved",
            metadata: [
                "streamID": .string(context.streamID),
                "messageID": .string(context.messageID.uuidString),
                "conversationID": .string(context.conversationID.uuidString),
                "nodeID": .string(app.imNodeID)
            ]
        )
        return response
    }
}
