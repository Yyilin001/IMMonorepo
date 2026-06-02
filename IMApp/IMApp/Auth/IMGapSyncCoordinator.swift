import Foundation
import IMClientKit
import OSLog

@MainActor
final class IMGapSyncCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private var catchUpTask: Task<Void, Never>?
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
              runtime.imConversationStore.containsConversation(id: trimmedConversationID)
        else {
            IMAppLog.imRuntime.debug(
                "Gap sync skipped: conversation unavailable conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return .completed
        }

        guard let latestLoadedSequence = runtime.imConversationStore.latestLoadedTimelineSequence(for: trimmedConversationID) else {
            IMAppLog.imRuntime.debug(
                "Gap sync skipped: no loaded timeline cursor conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return .completed
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0
            IMAppLog.imRuntime.debug(
                "Gap sync started conversationID=\(trimmedConversationID, privacy: .public) afterSequence=\(afterSequence, privacy: .public)"
            )

            while iterations < ConversationRuntimeController.HistoryConfig.gapSyncMaxIterations {
                let response = try await runtime.sessionClient.fetchIMTimelineSince(
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
                let itemCount = response.items.count
                let messageCount = response.items.compactMap(\.message).count
                let noticeCount = response.items.compactMap(\.notice).count
                let nextAfterSequence = response.nextAfterSequence.map(String.init) ?? "nil"
                IMAppLog.imRuntime.debug(
                    "Gap sync fetched conversationID=\(trimmedConversationID, privacy: .public) afterSequence=\(afterSequence, privacy: .public) items=\(itemCount, privacy: .public) messages=\(messageCount, privacy: .public) notices=\(noticeCount, privacy: .public) hasMore=\(response.hasMore, privacy: .public) nextAfterSequence=\(nextAfterSequence, privacy: .public)"
                )
                runtime.imConversationStore.appendTimelinePage(
                    in: trimmedConversationID,
                    response: response,
                    currentUserID: currentUserID
                )
                runtime.scheduleConversationCachePersist()
                let conversation = runtime.imConversationStore.conversations.first {
                    $0.id == trimmedConversationID
                }
                let pendingAfter = conversation?.pendingMessages.count ?? -1
                let messagesAfter = conversation?.messages.count ?? -1
                let timelineAfter = conversation?.timelineItems.count ?? -1
                IMAppLog.imRuntime.debug(
                    "Gap sync applied conversationID=\(trimmedConversationID, privacy: .public) pending=\(pendingAfter, privacy: .public) messages=\(messagesAfter, privacy: .public) timeline=\(timelineAfter, privacy: .public)"
                )

                guard response.hasMore else {
                    IMAppLog.imRuntime.debug(
                        "Gap sync completed conversationID=\(trimmedConversationID, privacy: .public)"
                    )
                    return .completed
                }

                guard let nextSequence = response.nextAfterSequence,
                      nextSequence > afterSequence
                else {
                    throw APIError.server(statusCode: 500, message: "IM 增量补洞响应无效。")
                }

                afterSequence = UInt64(nextSequence)
                iterations += 1
            }
            IMAppLog.imRuntime.debug(
                "Gap sync incomplete conversationID=\(trimmedConversationID, privacy: .public) iterations=\(iterations, privacy: .public)"
            )
            return .incomplete
        } catch is CancellationError {
            IMAppLog.imRuntime.debug(
                "Gap sync cancelled conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return .failed
        } catch {
            IMAppLog.imRuntime.error(
                "Gap sync failed conversationID=\(trimmedConversationID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
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
                enqueueCatchUp(for: conversationID)
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .failed:
                cancelCatchUp()
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

    func enqueueCatchUp(
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

        startCatchUpIfNeeded()
    }

    func startCatchUpIfNeeded() {
        guard let runtime,
              let currentUserID = runtime.currentUserProvider()?.id,
              runtime.imConnection != nil,
              catchUpTask == nil,
              !queue.isEmpty
        else {
            return
        }

        let generation = runtime.imConnectionGeneration
        catchUpTask = Task { [weak self] in
            await self?.runCatchUpLoop(
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    func cancelCatchUp() {
        catchUpTask?.cancel()
        clearCatchUpState()
    }

    private func runCatchUpLoop(
        currentUserID: UUID,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            guard let runtime,
                  generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  runtime.imConnection != nil
            else {
                clearCatchUpState()
                return
            }

            guard let conversationID = dequeueNextConversationID() else {
                catchUpTask = nil
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
                clearCatchUpState()
                return
            }

            switch result {
            case .completed:
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                enqueueCatchUp(for: conversationID)
            case .failed:
                clearCatchUpState()
                return
            }

            activeConversationID = nil
            await Task.yield()
        }

        catchUpTask = nil
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

    private func clearCatchUpState() {
        catchUpTask = nil
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

    func enqueueConversationGapSyncCatchUp(
        for conversationID: String,
        prioritize: Bool = false
    ) {
        gapSyncCoordinator.enqueueCatchUp(for: conversationID, prioritize: prioritize)
    }

    func startConversationGapSyncCatchUpIfNeeded() {
        gapSyncCoordinator.startCatchUpIfNeeded()
    }

    func cancelConversationGapSyncCatchUp() {
        gapSyncCoordinator.cancelCatchUp()
    }

    func syncDomainEventsAfterConnection() async {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        var cursor = imConversationStore.domainEventSyncCursor
        var iterations = 0
        do {
            while iterations < HistoryConfig.gapSyncMaxIterations {
                let response = try await sessionClient.fetchIMDomainEvents(
                    after: cursor,
                    limit: HistoryConfig.gapSyncLimit
                )
                guard currentUserProvider()?.id == currentUserID else {
                    return
                }
                markServerOnline()
                let events = response.envelopes.map(\.payload)
                for event in events {
                    if case .contactChanged = event.body {
                        applyContactDomainEvent(event)
                    }
                }
                let outcome = imConversationStore.applyDomainEvents(
                    response.envelopes,
                    nextCursor: response.nextCursor,
                    currentUserID: currentUserID
                )
                if let conversationID = outcome.shouldReloadMembersForConversationID {
                    await loadConversationMembers(for: conversationID)
                }
                scheduleConversationCachePersist()
                await reportClientHealthIfNeeded(
                    reason: outcome.shouldFetchDomainEvents
                        ? "domain-event-catch-up-needed"
                        : "domain-event-sync"
                )

                guard response.hasMore, response.nextCursor > cursor else {
                    return
                }
                cursor = response.nextCursor
                iterations += 1
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            return
        } catch {
            await handleIMDataRequestError(error)
        }
    }
}
