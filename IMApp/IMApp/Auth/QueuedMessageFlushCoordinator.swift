import Foundation
import IMClientKit

@MainActor
extension ConversationRuntimeController {
    func flushQueuedTextMessagesAfterConnection(limit: Int) async {
        guard !hasQueuedFlushInProgress,
              hasQueuedTextMessages()
        else {
            return
        }

        setQueuedFlushActive(true)

        switch await flushQueuedTextMessages(limit: limit) {
        case .drained:
            finishQueuedTextMessageFlush()
        case .hasMore:
            startQueuedTextMessageFlushIfNeeded(limit: limit)
        case .failed:
            finishQueuedTextMessageFlush()
        }
    }

    func startQueuedTextMessageFlushIfNeeded(limit: Int) {
        guard currentUserProvider() != nil,
              imConnection != nil,
              queuedIMTextMessageFlushTask == nil,
              hasQueuedTextMessages()
        else {
            return
        }

        setQueuedFlushActive(true)
        let generation = imConnectionGeneration
        let currentUserID = currentUserProvider()?.id
        queuedIMTextMessageFlushTask = Task { [weak self] in
            guard let self, let currentUserID else {
                return
            }
            await self.runQueuedTextMessageFlushLoop(
                currentUserID: currentUserID,
                generation: generation,
                limit: limit
            )
        }
    }

    var hasQueuedFlushInProgress: Bool {
        queuedIMTextMessageFlushTask != nil
    }

    func runQueuedTextMessageFlushLoop(
        currentUserID: UUID,
        generation: UInt64,
        limit: Int
    ) async {
        while !Task.isCancelled {
            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil
            else {
                finishQueuedTextMessageFlush()
                return
            }

            guard hasQueuedTextMessages() else {
                finishQueuedTextMessageFlush()
                return
            }

            let result = await flushQueuedTextMessages(limit: limit)

            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil,
                  !Task.isCancelled
            else {
                finishQueuedTextMessageFlush()
                return
            }

            switch result {
            case .drained:
                finishQueuedTextMessageFlush()
                return
            case .hasMore:
                await Task.yield()
            case .failed:
                finishQueuedTextMessageFlush()
                return
            }
        }

        finishQueuedTextMessageFlush()
    }

    func flushQueuedTextMessages(limit: Int) async -> QueuedTextMessageFlushBatchResult {
        guard let connection = imConnection else {
            return .failed
        }

        let requests = imConversationStore.queuedOutgoingMessageRequests(limit: limit)
        guard !requests.isEmpty else {
            return .drained
        }

        scheduleConversationCachePersist()
        let generation = imConnectionGeneration

        for (index, request) in requests.enumerated() {
            do {
                try await connection.sendMessage(request.payload, requestID: request.requestID)
            } catch {
                for unsentRequest in requests.dropFirst(index + 1) {
                    imConversationStore.markOutgoingQueued(
                        requestID: unsentRequest.requestID,
                        message: "等待 IM 长连接恢复后发送。"
                    )
                }

                scheduleConversationCachePersist()
                await handleIMConnectionFailure(error, generation: generation)
                return .failed
            }
        }

        scheduleConversationCachePersist()
        return hasQueuedTextMessages() ? .hasMore : .drained
    }

    func hasQueuedTextMessages() -> Bool {
        imConversationStore.conversations.contains { conversation in
            conversation.messages.contains { message in
                guard message.direction == .outgoing, message.content.isUserComposable else {
                    return false
                }

                if case .queued = message.deliveryState {
                    return true
                }
                return false
            }
        }
    }

    func cancelQueuedTextMessageFlush() {
        queuedIMTextMessageFlushTask?.cancel()
        finishQueuedTextMessageFlush()
    }

    func finishQueuedTextMessageFlush() {
        queuedIMTextMessageFlushTask = nil
        setQueuedFlushActive(false)
    }
}
