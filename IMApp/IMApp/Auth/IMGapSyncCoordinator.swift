import Foundation
import IMClientKit

@MainActor
extension ConversationRuntimeController {
    func syncConversationGap(
        for conversationID: String,
        currentUserID: UUID
    ) async -> ConversationGapSyncResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.containsConversation(id: trimmedConversationID),
              let latestLoadedSequence = imConversationStore.latestLoadedServerSequence(for: trimmedConversationID)
        else {
            return .completed
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0

            while iterations < HistoryConfig.gapSyncMaxIterations {
                let response = try await sessionClient.fetchIMMessagesSince(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    limit: HistoryConfig.gapSyncLimit
                )
                guard currentUserProvider()?.id == currentUserID else {
                    return .failed
                }
                guard imConversationStore.containsConversation(id: trimmedConversationID) else {
                    return .completed
                }

                markServerOnline()
                imConversationStore.appendMessages(
                    in: trimmedConversationID,
                    messages: response.messages,
                    currentUserID: currentUserID
                )
                scheduleConversationCachePersist()

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
            await handleIMDataRequestError(error)
            return .failed
        }
    }

    func syncConversationGapsAfterConnection() async {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        guard await fetchAndApplyConversationSummaries(force: false) else {
            return
        }

        let gapSyncTargets = prioritizedGapSyncTargets(
            imConversationStore.gapSyncTargets(from: latestConversationSummariesProvider())
        )

        for conversationID in gapSyncTargets {
            switch await syncConversationGap(for: conversationID, currentUserID: currentUserID) {
            case .completed:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                enqueueConversationGapSyncBackfill(for: conversationID)
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .failed:
                cancelConversationGapSyncBackfill()
                return
            }
        }
        syncActiveMessageStreamSnapshots()
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
        guard let selectedConversationID = imConversationStore.selectedConversationID,
              conversationIDs.contains(selectedConversationID)
        else {
            return conversationIDs
        }

        return [selectedConversationID] + conversationIDs.filter { $0 != selectedConversationID }
    }

    func enqueueConversationGapSyncBackfill(
        for conversationID: String,
        prioritize: Bool = false
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationGapSyncQueue.removeAll { $0 == trimmedConversationID }
        let shouldPrioritize = prioritize || trimmedConversationID == imConversationStore.selectedConversationID
        if shouldPrioritize {
            imConversationGapSyncQueue.insert(trimmedConversationID, at: 0)
        } else {
            imConversationGapSyncQueue.append(trimmedConversationID)
        }

        startConversationGapSyncBackfillIfNeeded()
    }

    func startConversationGapSyncBackfillIfNeeded() {
        guard let currentUserID = currentUserProvider()?.id,
              imConnection != nil,
              imConversationGapSyncBackfillTask == nil,
              !imConversationGapSyncQueue.isEmpty
        else {
            return
        }

        let generation = imConnectionGeneration
        imConversationGapSyncBackfillTask = Task { [weak self] in
            await self?.runConversationGapSyncBackfillLoop(
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    func runConversationGapSyncBackfillLoop(
        currentUserID: UUID,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil
            else {
                clearConversationGapSyncBackfillState()
                return
            }

            guard let conversationID = dequeueNextConversationGapSyncBackfillConversationID() else {
                imConversationGapSyncBackfillTask = nil
                imConversationGapSyncActiveConversationID = nil
                return
            }

            imConversationGapSyncActiveConversationID = conversationID
            let result = await syncConversationGap(for: conversationID, currentUserID: currentUserID)

            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil,
                  !Task.isCancelled
            else {
                clearConversationGapSyncBackfillState()
                return
            }

            switch result {
            case .completed:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                enqueueConversationGapSyncBackfill(for: conversationID)
            case .failed:
                clearConversationGapSyncBackfillState()
                return
            }

            imConversationGapSyncActiveConversationID = nil
            await Task.yield()
        }

        imConversationGapSyncBackfillTask = nil
        imConversationGapSyncActiveConversationID = nil
    }

    func dequeueNextConversationGapSyncBackfillConversationID() -> String? {
        if let selectedConversationID = imConversationStore.selectedConversationID,
           let selectedIndex = imConversationGapSyncQueue.firstIndex(of: selectedConversationID) {
            return imConversationGapSyncQueue.remove(at: selectedIndex)
        }

        guard !imConversationGapSyncQueue.isEmpty else {
            return nil
        }

        return imConversationGapSyncQueue.removeFirst()
    }

    func cancelConversationGapSyncBackfill() {
        imConversationGapSyncBackfillTask?.cancel()
        clearConversationGapSyncBackfillState()
    }

    func clearConversationGapSyncBackfillState() {
        imConversationGapSyncBackfillTask = nil
        imConversationGapSyncQueue = []
        imConversationGapSyncActiveConversationID = nil
    }
}
