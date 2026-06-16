import Vapor

actor IMMessageWriteBatcher {
    struct Item: Sendable {
        let message: IMPreparedIncomingMessage
    }

    private struct QueuedItem {
        let item: Item
        let continuation: CheckedContinuation<IMRealtimeMessagePersistenceResult, any Error>
        let enqueuedAt: Date
    }

    private var queues: [UUID: [QueuedItem]] = [:]
    private var scheduledConversationIDs: Set<UUID> = []
    private var processingConversationIDs: Set<UUID> = []

    func enqueue(
        _ item: Item,
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) async throws -> IMRealtimeMessagePersistenceResult {
        try await withCheckedThrowingContinuation { continuation in
            let currentDepth = queues[conversationID]?.count ?? 0
            guard currentDepth < configuration.maxQueueDepthPerConversation else {
                continuation.resume(throwing: IMRealtimeMessageError.messageWriteQueueFull)
                Task {
                    await app.messageWriteMetrics.recordWriteQueueRejected()
                    await app.messageWriteMetrics.recordWriteQueueDepth(currentDepth)
                }
                return
            }

            queues[conversationID, default: []].append(
                QueuedItem(item: item, continuation: continuation, enqueuedAt: Date())
            )
            let depth = queues[conversationID]?.count ?? 0
            Task {
                await app.messageWriteMetrics.recordWriteQueueDepth(depth)
            }

            if queues[conversationID, default: []].count >= configuration.maxSize {
                Task {
                    await flush(conversationID: conversationID, app: app, configuration: configuration)
                }
            } else {
                scheduleFlushIfNeeded(conversationID: conversationID, app: app, configuration: configuration)
            }
        }
    }

    private func scheduleFlushIfNeeded(
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) {
        guard !scheduledConversationIDs.contains(conversationID),
              !processingConversationIDs.contains(conversationID)
        else {
            return
        }

        scheduledConversationIDs.insert(conversationID)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(configuration.maxDelayMillis) * 1_000_000)
            await flush(conversationID: conversationID, app: app, configuration: configuration)
        }
    }

    private func flush(
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) async {
        guard !processingConversationIDs.contains(conversationID) else {
            return
        }
        scheduledConversationIDs.remove(conversationID)
        guard var queue = queues[conversationID], !queue.isEmpty else {
            return
        }

        processingConversationIDs.insert(conversationID)
        let batch = Array(queue.prefix(configuration.maxSize))
        queue.removeFirst(batch.count)
        queues[conversationID] = queue.isEmpty ? nil : queue
        await app.messageWriteMetrics.recordWriteQueueDepth(queue.count)
        if let oldestEnqueuedAt = batch.map(\.enqueuedAt).min() {
            await app.messageWriteMetrics.recordBatchQueueWait(
                durationMillis: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: oldestEnqueuedAt),
                messageCount: batch.count
            )
        }

        do {
            let results = try await IMRealtimeMessageService(app: app)
                .persistOwnedIncomingMessagesBatch(
                    batch.map(\.item.message),
                    conversationID: conversationID
                )
            for (queued, result) in zip(batch, results) {
                queued.continuation.resume(returning: result)
            }
            await app.messageWriteMetrics.recordMessageWriteBatch(messageCount: batch.count)
        } catch {
            for queued in batch {
                queued.continuation.resume(throwing: error)
            }
        }

        processingConversationIDs.remove(conversationID)
        if queues[conversationID]?.isEmpty == false {
            scheduleFlushIfNeeded(conversationID: conversationID, app: app, configuration: configuration)
        }
    }

}
