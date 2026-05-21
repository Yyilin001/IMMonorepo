import Foundation
import IMClientKit

@MainActor
final class IMGapSyncCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private var backfillTask: Task<Void, Never>?
    private var queue: [String] = []
    private var activeConversationID: String?

    init(runtime: ConversationRuntimeController) {
        self.runtime = runtime
    }

    func syncGap(
        for conversationID: String,
        currentUserID: UUID
    ) async -> ConversationRuntimeController.ConversationGapSyncResult {
        guard let runtime else {
            return .failed
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              runtime.imConversationStore.containsConversation(id: trimmedConversationID),
              let latestLoadedSequence = runtime.imConversationStore.latestLoadedServerSequence(for: trimmedConversationID)
        else {
            return .completed
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0

            while iterations < ConversationRuntimeController.HistoryConfig.gapSyncMaxIterations {
                let response = try await runtime.sessionClient.fetchIMMessagesSince(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    limit: ConversationRuntimeController.HistoryConfig.gapSyncLimit
                )
                guard runtime.currentUserProvider()?.id == currentUserID else {
                    return .failed
                }
                guard runtime.imConversationStore.containsConversation(id: trimmedConversationID) else {
                    return .completed
                }

                runtime.markServerOnline()
                runtime.imConversationStore.appendMessages(
                    in: trimmedConversationID,
                    messages: response.messages,
                    currentUserID: currentUserID
                )
                runtime.scheduleConversationCachePersist()

                guard response.hasMore else {
                    return .completed
                }

                guard let nextAfterSequence = response.nextAfterSequence,
                      nextAfterSequence > afterSequence
                else {
                    throw APIError.server(statusCode: 500, message: "IM 增量补洞响应无效。")
                }

                afterSequence = UInt64(nextAfterSequence)
                iterations += 1
            }
            return .incomplete
        } catch is CancellationError {
            return .failed
        } catch {
            await runtime.handleIMDataRequestError(error)
            return .failed
        }
    }

    func syncAfterConnection() async {
        guard let runtime,
              let currentUserID = runtime.currentUserProvider()?.id
        else {
            return
        }

        guard await runtime.fetchAndApplyConversationSummaries(force: false) else {
            return
        }

        let gapSyncTargets = prioritizedTargets(
            runtime.imConversationStore.gapSyncTargets(from: runtime.latestConversationSummariesProvider())
        )

        for conversationID in gapSyncTargets {
            switch await syncGap(for: conversationID, currentUserID: currentUserID) {
            case .completed:
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                enqueueBackfill(for: conversationID)
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .failed:
                cancelBackfill()
                return
            }
        }
        runtime.syncActiveMessageStreamSnapshots()
    }

    func prioritizedTargets(_ conversationIDs: [String]) -> [String] {
        guard let selectedConversationID = runtime?.imConversationStore.selectedConversationID,
              conversationIDs.contains(selectedConversationID)
        else {
            return conversationIDs
        }

        return [selectedConversationID] + conversationIDs.filter { $0 != selectedConversationID }
    }

    func enqueueBackfill(
        for conversationID: String,
        prioritize: Bool = false
    ) {
        guard let runtime else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        queue.removeAll { $0 == trimmedConversationID }
        let shouldPrioritize = prioritize || trimmedConversationID == runtime.imConversationStore.selectedConversationID
        if shouldPrioritize {
            queue.insert(trimmedConversationID, at: 0)
        } else {
            queue.append(trimmedConversationID)
        }

        startBackfillIfNeeded()
    }

    func startBackfillIfNeeded() {
        guard let runtime,
              let currentUserID = runtime.currentUserProvider()?.id,
              runtime.imConnection != nil,
              backfillTask == nil,
              !queue.isEmpty
        else {
            return
        }

        let generation = runtime.imConnectionGeneration
        backfillTask = Task { [weak self] in
            await self?.runBackfillLoop(
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    func cancelBackfill() {
        backfillTask?.cancel()
        clearBackfillState()
    }

    private func runBackfillLoop(
        currentUserID: UUID,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            guard let runtime,
                  generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  runtime.imConnection != nil
            else {
                clearBackfillState()
                return
            }

            guard let conversationID = dequeueNextConversationID() else {
                backfillTask = nil
                activeConversationID = nil
                return
            }

            activeConversationID = conversationID
            let result = await syncGap(for: conversationID, currentUserID: currentUserID)

            guard generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  runtime.imConnection != nil,
                  !Task.isCancelled
            else {
                clearBackfillState()
                return
            }

            switch result {
            case .completed:
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                enqueueBackfill(for: conversationID)
            case .failed:
                clearBackfillState()
                return
            }

            activeConversationID = nil
            await Task.yield()
        }

        backfillTask = nil
        activeConversationID = nil
    }

    private func dequeueNextConversationID() -> String? {
        if let selectedConversationID = runtime?.imConversationStore.selectedConversationID,
           let selectedIndex = queue.firstIndex(of: selectedConversationID) {
            return queue.remove(at: selectedIndex)
        }

        guard !queue.isEmpty else {
            return nil
        }

        return queue.removeFirst()
    }

    private func clearBackfillState() {
        backfillTask = nil
        queue = []
        activeConversationID = nil
    }
}

@MainActor
extension ConversationRuntimeController {
    func syncConversationGap(
        for conversationID: String,
        currentUserID: UUID
    ) async -> ConversationGapSyncResult {
        await gapSyncCoordinator.syncGap(for: conversationID, currentUserID: currentUserID)
    }

    func syncConversationGapsAfterConnection() async {
        await gapSyncCoordinator.syncAfterConnection()
    }

    func syncActiveMessageStreamSnapshots() {
        messageStreamSnapshotRecoveryQueue.syncActiveMessageStreamSnapshots()
    }

    func syncPendingMessageStreamSnapshotsIfNeeded() {
        messageStreamSnapshotRecoveryQueue.syncPendingMessageStreamSnapshotsIfNeeded()
    }

    func cancelMessageStreamSnapshotSync() {
        messageStreamSnapshotRecoveryQueue.cancel()
    }

    func prioritizedGapSyncTargets(_ conversationIDs: [String]) -> [String] {
        gapSyncCoordinator.prioritizedTargets(conversationIDs)
    }

    func enqueueConversationGapSyncBackfill(
        for conversationID: String,
        prioritize: Bool = false
    ) {
        gapSyncCoordinator.enqueueBackfill(for: conversationID, prioritize: prioritize)
    }

    func startConversationGapSyncBackfillIfNeeded() {
        gapSyncCoordinator.startBackfillIfNeeded()
    }

    func cancelConversationGapSyncBackfill() {
        gapSyncCoordinator.cancelBackfill()
    }
}
