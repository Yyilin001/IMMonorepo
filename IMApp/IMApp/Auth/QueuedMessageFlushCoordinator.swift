import Foundation
import IMClientKit

@MainActor
final class QueuedMessageFlushCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private var flushTask: Task<Void, Never>?

    init(runtime: ConversationRuntimeController) {
        self.runtime = runtime
    }

    var isInProgress: Bool {
        flushTask != nil
    }

    func flushAfterConnection(limit: Int) async {
        guard !isInProgress,
              hasQueuedTextMessages()
        else {
            return
        }

        runtime?.setQueuedFlushActive(true)

        switch await flushBatch(limit: limit) {
        case .drained:
            finish()
        case .hasMore:
            startIfNeeded(limit: limit)
        case .failed:
            finish()
        }
    }

    func startIfNeeded(limit: Int) {
        guard let runtime,
              runtime.currentUserProvider() != nil,
              runtime.imConnection != nil,
              flushTask == nil,
              hasQueuedTextMessages()
        else {
            return
        }

        runtime.setQueuedFlushActive(true)
        let generation = runtime.imConnectionGeneration
        let currentUserID = runtime.currentUserProvider()?.id
        flushTask = Task { [weak self] in
            guard let self, let currentUserID else {
                return
            }
            await self.runLoop(
                currentUserID: currentUserID,
                generation: generation,
                limit: limit
            )
        }
    }

    func cancel() {
        flushTask?.cancel()
        finish()
    }

    private func runLoop(
        currentUserID: UUID,
        generation: UInt64,
        limit: Int
    ) async {
        while !Task.isCancelled {
            guard let runtime,
                  generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  runtime.imConnection != nil
            else {
                finish()
                return
            }

            guard hasQueuedTextMessages() else {
                finish()
                return
            }

            let result = await flushBatch(limit: limit)

            guard generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  runtime.imConnection != nil,
                  !Task.isCancelled
            else {
                finish()
                return
            }

            switch result {
            case .drained:
                finish()
                return
            case .hasMore:
                await Task.yield()
            case .failed:
                finish()
                return
            }
        }

        finish()
    }

    private func flushBatch(limit: Int) async -> ConversationRuntimeController.QueuedTextMessageFlushBatchResult {
        guard let runtime,
              let connection = runtime.imConnection
        else {
            return .failed
        }

        let requests = await runtime.imConversationStore.queuedOutgoingMessageRequestsAsync(limit: limit)
        guard !requests.isEmpty else {
            return .drained
        }

        runtime.scheduleConversationCachePersist()
        let generation = runtime.imConnectionGeneration

        for (index, request) in requests.enumerated() {
            do {
                try await connection.sendMessage(request.payload, requestID: request.requestID)
            } catch {
                for unsentRequest in requests.dropFirst(index + 1) {
                    await runtime.imConversationStore.markOutgoingQueuedAsync(
                        requestID: unsentRequest.requestID,
                        message: "等待 IM 长连接恢复后发送。"
                    )
                }

                runtime.scheduleConversationCachePersist()
                await runtime.handleIMConnectionFailure(error, generation: generation)
                return .failed
            }
        }

        runtime.scheduleConversationCachePersist()
        return hasQueuedTextMessages() ? .hasMore : .drained
    }

    private func hasQueuedTextMessages() -> Bool {
        guard let runtime else {
            return false
        }

        return runtime.imConversationStore.conversations.contains { conversation in
            conversation.pendingMessages.contains { message in
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

    private func finish() {
        flushTask = nil
        runtime?.setQueuedFlushActive(false)
    }
}

@MainActor
extension ConversationRuntimeController {
    func flushQueuedTextMessagesAfterConnection(limit: Int) async {
        await queuedMessageFlushCoordinator.flushAfterConnection(limit: limit)
    }

    func startQueuedTextMessageFlushIfNeeded(limit: Int) {
        queuedMessageFlushCoordinator.startIfNeeded(limit: limit)
    }

    var hasQueuedFlushInProgress: Bool {
        queuedMessageFlushCoordinator.isInProgress
    }

    func cancelQueuedTextMessageFlush() {
        queuedMessageFlushCoordinator.cancel()
    }
}
