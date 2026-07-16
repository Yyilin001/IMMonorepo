import Foundation
import IMClientKit
import OSLog

struct IMGapSyncCatchUpRateLimiter {
    private let minimumInterval: TimeInterval
    private let initialJitterNanoseconds: UInt64
    private var dirtyConversationIDs: Set<String> = []
    private var catchUpNotBeforeByConversationID: [String: Date] = [:]
    private var lastCatchUpCompletedAtByConversationID: [String: Date] = [:]

    init(
        minimumIntervalNanoseconds: UInt64,
        initialJitterNanoseconds: UInt64 = 0
    ) {
        minimumInterval = TimeInterval(minimumIntervalNanoseconds) / 1_000_000_000
        self.initialJitterNanoseconds = initialJitterNanoseconds
    }

    mutating func markDirty(_ conversationID: String) {
        dirtyConversationIDs.insert(conversationID)
    }

    mutating func consumeDirty(_ conversationID: String) -> Bool {
        dirtyConversationIDs.remove(conversationID) != nil
    }

    mutating func applyRateLimitIfNeeded(for conversationID: String, now: Date = Date()) {
        guard let lastCompletedAt = lastCatchUpCompletedAtByConversationID[conversationID] else {
            return
        }
        let notBefore = lastCompletedAt.addingTimeInterval(minimumInterval)
        if notBefore > now {
            storeNotBefore(notBefore, for: conversationID)
        }
    }

    mutating func applyInitialJitterIfNeeded(
        for conversationID: String,
        stableKey: String,
        now: Date = Date()
    ) {
        guard initialJitterNanoseconds > 0,
              lastCatchUpCompletedAtByConversationID[conversationID] == nil,
              delayUntil(for: conversationID, now: now) == nil
        else {
            return
        }
        let jitterNanoseconds = stableJitterNanoseconds(for: stableKey)
        guard jitterNanoseconds > 0 else {
            return
        }
        storeNotBefore(
            now.addingTimeInterval(TimeInterval(jitterNanoseconds) / 1_000_000_000),
            for: conversationID
        )
    }

    mutating func delayUntil(for conversationID: String, now: Date = Date()) -> Date? {
        guard let notBefore = catchUpNotBeforeByConversationID[conversationID] else {
            return nil
        }
        guard notBefore > now else {
            catchUpNotBeforeByConversationID.removeValue(forKey: conversationID)
            return nil
        }
        return notBefore
    }

    mutating func recordCompleted(for conversationID: String, now: Date = Date()) {
        lastCatchUpCompletedAtByConversationID[conversationID] = now
        catchUpNotBeforeByConversationID.removeValue(forKey: conversationID)
    }

    mutating func deferNextRun(for conversationID: String, now: Date = Date()) {
        storeNotBefore(now.addingTimeInterval(minimumInterval), for: conversationID)
    }

    mutating func clearDelay(for conversationID: String) {
        catchUpNotBeforeByConversationID.removeValue(forKey: conversationID)
    }

    mutating func reset() {
        dirtyConversationIDs = []
        catchUpNotBeforeByConversationID = [:]
        lastCatchUpCompletedAtByConversationID = [:]
    }

    private mutating func storeNotBefore(_ notBefore: Date, for conversationID: String) {
        if let existing = catchUpNotBeforeByConversationID[conversationID],
           existing > notBefore {
            return
        }
        catchUpNotBeforeByConversationID[conversationID] = notBefore
    }

    private func stableJitterNanoseconds(for key: String) -> UInt64 {
        guard initialJitterNanoseconds > 0 else {
            return 0
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash % initialJitterNanoseconds
    }
}

@MainActor
final class IMGapSyncCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private let timelineCatchUpConfiguration: ConversationRuntimeController.TimelineCatchUpConfiguration
    private var catchUpTask: Task<Void, Never>?
    private var queue: [String] = []
    private var activeConversationID: String?
    private var targetTimelineSequenceByConversationID: [String: UInt64] = [:]
    private var gapSyncProgressByConversationID: [String: UInt64] = [:]
    private var bypassRateLimitConversationIDs: Set<String> = []
    private var selectedHintMicroBatchTask: Task<Void, Never>?
    private var selectedHintMicroBatchConversationID: String?
    private var catchUpRateLimiter: IMGapSyncCatchUpRateLimiter

    init(runtime: ConversationRuntimeController) {
        self.runtime = runtime
        timelineCatchUpConfiguration = runtime.timelineCatchUpConfiguration
        catchUpRateLimiter = IMGapSyncCatchUpRateLimiter(
            minimumIntervalNanoseconds: timelineCatchUpConfiguration.selectedHintMinimumIntervalNanoseconds,
            initialJitterNanoseconds: timelineCatchUpConfiguration.selectedHintInitialJitterNanoseconds
        )
    }

    func syncGap(
        for conversationID: String,
        currentUserID: UUID,
        targetTimelineSequence: UInt64? = nil
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

        let latestLoadedSequence = latestKnownTimelineSequence(
            for: trimmedConversationID,
            runtime: runtime
        )
        guard let latestLoadedSequence else {
            if let targetTimelineSequence {
                runtime.imConversationStore.recordTimelineCatchUpDeferred(
                    conversationID: trimmedConversationID,
                    targetTimelineSequence: targetTimelineSequence,
                    reason: "missing_loaded_timeline_cursor"
                )
                IMAppLog.imRuntime.debug(
                    "Gap sync deferred: no loaded timeline cursor conversationID=\(trimmedConversationID, privacy: .public) targetTimelineSequence=\(targetTimelineSequence, privacy: .public)"
                )
                return .deferred
            }
            IMAppLog.imRuntime.debug(
                "Gap sync skipped: no loaded timeline cursor conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return .completed
        }

        if let targetTimelineSequence,
           latestLoadedSequence >= targetTimelineSequence {
            runtime.imConversationStore.recordTimelineCatchUpSkippedAlreadyLoaded(
                conversationID: trimmedConversationID,
                targetTimelineSequence: targetTimelineSequence
            )
            IMAppLog.imRuntime.debug(
                "Gap sync skipped: target already loaded conversationID=\(trimmedConversationID, privacy: .public) latestLoadedSequence=\(latestLoadedSequence, privacy: .public) targetTimelineSequence=\(targetTimelineSequence, privacy: .public)"
            )
            return .completed
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0
            IMAppLog.imRuntime.debug(
                "Gap sync started conversationID=\(trimmedConversationID, privacy: .public) afterSequence=\(afterSequence, privacy: .public) targetTimelineSequence=\(targetTimelineSequence ?? 0, privacy: .public)"
            )

            while iterations < ConversationRuntimeController.HistoryConfig.gapSyncMaxIterations {
                let requestStartedAt = Date()
                runtime.imConversationStore.recordTimelineCatchUpSinceRequestStarted(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    targetTimelineSequence: targetTimelineSequence,
                    startedAt: requestStartedAt
                )
                let response = try await runtime.sessionClient.fetchIMTimelineSince(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    targetSequence: targetTimelineSequence,
                    limit: ConversationRuntimeController.HistoryConfig.gapSyncLimit
                )
                runtime.imConversationStore.recordTimelineCatchUpSinceRequestFinished(
                    conversationID: trimmedConversationID,
                    success: true,
                    finishedAt: Date()
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
                runtime.imConversationStore.recordTimelineCatchUpPageApplied(
                    conversationID: trimmedConversationID,
                    itemCount: itemCount,
                    latestTimelineSequence: latestKnownTimelineSequence(
                        for: trimmedConversationID,
                        runtime: runtime
                    )
                )
                if let nextSequence = response.nextAfterSequence,
                   nextSequence > afterSequence {
                    recordGapSyncProgress(nextSequence, for: trimmedConversationID)
                }
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

                if let targetTimelineSequence,
                   let latestAfterAppend = latestKnownTimelineSequence(
                       for: trimmedConversationID,
                       runtime: runtime
                   ),
                   latestAfterAppend >= targetTimelineSequence {
                    IMAppLog.imRuntime.debug(
                        "Gap sync reached target conversationID=\(trimmedConversationID, privacy: .public) latestLoadedSequence=\(latestAfterAppend, privacy: .public) targetTimelineSequence=\(targetTimelineSequence, privacy: .public)"
                    )
                    return .completed
                }

                guard let nextSequence = response.nextAfterSequence,
                      nextSequence > afterSequence
                else {
                    if targetTimelineSequence != nil {
                        runtime.imConversationStore.recordTimelineCatchUpDeferred(
                            conversationID: trimmedConversationID,
                            targetTimelineSequence: targetTimelineSequence,
                            reason: "target_not_reached"
                        )
                        IMAppLog.imRuntime.debug(
                            "Gap sync deferred: target not reached and cursor did not advance conversationID=\(trimmedConversationID, privacy: .public) afterSequence=\(afterSequence, privacy: .public) targetTimelineSequence=\(targetTimelineSequence ?? 0, privacy: .public)"
                        )
                        return .deferred
                    }
                    guard response.hasMore else {
                        IMAppLog.imRuntime.debug(
                            "Gap sync completed conversationID=\(trimmedConversationID, privacy: .public)"
                        )
                        return .completed
                    }
                    throw APIError.server(statusCode: 500, message: "IM 增量补洞响应无效。")
                }

                guard response.hasMore || targetTimelineSequence != nil else {
                    IMAppLog.imRuntime.debug(
                        "Gap sync completed conversationID=\(trimmedConversationID, privacy: .public)"
                    )
                    return .completed
                }

                afterSequence = UInt64(nextSequence)
                iterations += 1
            }
            IMAppLog.imRuntime.debug(
                "Gap sync incomplete conversationID=\(trimmedConversationID, privacy: .public) iterations=\(iterations, privacy: .public)"
            )
            runtime.imConversationStore.recordTimelineCatchUpDeferred(
                conversationID: trimmedConversationID,
                targetTimelineSequence: targetTimelineSequence,
                reason: "max_iterations"
            )
            return .incomplete
        } catch is CancellationError {
            IMAppLog.imRuntime.debug(
                "Gap sync cancelled conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return .failed
        } catch {
            runtime.imConversationStore.recordTimelineCatchUpSinceRequestFinished(
                conversationID: trimmedConversationID,
                success: false,
                finishedAt: Date(),
                failureReason: String(describing: error)
            )
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
            case .deferred:
                enqueueCatchUp(
                    for: conversationID,
                    prioritize: conversationID == runtime.imConversationStore.selectedConversationID
                )
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
        prioritize: Bool = false,
        targetTimelineSequence: UInt64? = nil,
        bypassRateLimit: Bool = false,
        spreadInitialRun: Bool = false,
        microBatchSelectedHint: Bool = true
    ) {
        guard let runtime else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        mergeTargetTimelineSequence(
            targetTimelineSequence,
            for: trimmedConversationID
        )
        if bypassRateLimit {
            bypassRateLimitConversationIDs.insert(trimmedConversationID)
            catchUpRateLimiter.clearDelay(for: trimmedConversationID)
        }

        if let targetTimelineSequence,
           let latestLoadedSequence = runtime.imConversationStore.latestLoadedTimelineSequence(
               for: trimmedConversationID
           ),
           latestLoadedSequence >= targetTimelineSequence {
            runtime.imConversationStore.recordTimelineCatchUpSkippedAlreadyLoaded(
                conversationID: trimmedConversationID,
                targetTimelineSequence: targetTimelineSequence
            )
            clearReachedTargetIfNeeded(for: trimmedConversationID)
            bypassRateLimitConversationIDs.remove(trimmedConversationID)
            IMAppLog.imRuntime.debug(
                "Gap sync catch-up skipped enqueue: target already loaded conversationID=\(trimmedConversationID, privacy: .public) latestLoadedSequence=\(latestLoadedSequence, privacy: .public) targetTimelineSequence=\(targetTimelineSequence, privacy: .public)"
            )
            return
        }

        if microBatchSelectedHint,
           bypassRateLimit,
           targetTimelineSequence != nil,
           activeConversationID != trimmedConversationID,
           trimmedConversationID == runtime.imConversationStore.selectedConversationID {
            scheduleSelectedHintMicroBatch(for: trimmedConversationID)
            return
        }

        if activeConversationID == trimmedConversationID {
            catchUpRateLimiter.markDirty(trimmedConversationID)
            IMAppLog.imRuntime.debug(
                "Gap sync catch-up coalesced while active conversationID=\(trimmedConversationID, privacy: .public) bypassRateLimit=\(bypassRateLimit, privacy: .public)"
            )
            return
        }

        if bypassRateLimitConversationIDs.contains(trimmedConversationID) {
            catchUpRateLimiter.clearDelay(for: trimmedConversationID)
        } else {
            if spreadInitialRun,
               let userID = runtime.currentUserProvider()?.id {
                catchUpRateLimiter.applyInitialJitterIfNeeded(
                    for: trimmedConversationID,
                    stableKey: "\(userID.uuidString):\(trimmedConversationID)"
                )
            }
            catchUpRateLimiter.applyRateLimitIfNeeded(for: trimmedConversationID)
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
                  runtime.currentUserProvider()?.id == currentUserID
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
            let targetTimelineSequence = targetTimelineSequenceByConversationID[conversationID]
            let bypassRateLimit = bypassRateLimitConversationIDs.contains(conversationID)
            if !bypassRateLimit,
               await delayIfRateLimited(conversationID: conversationID) {
                guard !Task.isCancelled else {
                    clearCatchUpState()
                    return
                }
                activeConversationID = nil
                queue.removeAll { $0 == conversationID }
                queue.insert(conversationID, at: 0)
                continue
            }

            let result = await syncGap(
                for: conversationID,
                currentUserID: currentUserID,
                targetTimelineSequence: targetTimelineSequence
            )

            guard generation == runtime.imConnectionGeneration,
                  runtime.currentUserProvider()?.id == currentUserID,
                  !Task.isCancelled
            else {
                clearCatchUpState()
                return
            }

            switch result {
            case .completed:
                recordCatchUpCompleted(for: conversationID)
                clearReachedTargetIfNeeded(for: conversationID)
                if targetTimelineSequenceByConversationID[conversationID] == nil {
                    bypassRateLimitConversationIDs.remove(conversationID)
                }
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                await runtime.reportTimelineCatchUpSlowHealthIfNeeded(
                    reason: "timeline-catch-up-slow"
                )
            case .incomplete:
                recordCatchUpCompleted(for: conversationID)
                await runtime.markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                await runtime.reportTimelineCatchUpHealthIfNeeded(
                    reason: "timeline-catch-up-incomplete"
                )
                enqueueCatchUp(
                    for: conversationID,
                    targetTimelineSequence: targetTimelineSequenceByConversationID[conversationID],
                    bypassRateLimit: bypassRateLimitConversationIDs.contains(conversationID)
                )
            case .deferred:
                catchUpRateLimiter.markDirty(conversationID)
                await runtime.reportTimelineCatchUpHealthIfNeeded(
                    reason: "timeline-catch-up-deferred"
                )
            case .failed:
                await runtime.reportTimelineCatchUpHealthIfNeeded(
                    reason: "timeline-catch-up-failed"
                )
                clearCatchUpState()
                return
            }

            let shouldRunAgain = catchUpRateLimiter.consumeDirty(conversationID)
            activeConversationID = nil
            if shouldRunAgain {
                let shouldBypassRateLimit = bypassRateLimitConversationIDs.contains(conversationID)
                    && result != .deferred
                if shouldBypassRateLimit {
                    catchUpRateLimiter.clearDelay(for: conversationID)
                } else {
                    bypassRateLimitConversationIDs.remove(conversationID)
                    catchUpRateLimiter.deferNextRun(for: conversationID)
                }
                enqueueCatchUp(
                    for: conversationID,
                    prioritize: conversationID == runtime.imConversationStore.selectedConversationID,
                    targetTimelineSequence: targetTimelineSequenceByConversationID[conversationID],
                    bypassRateLimit: shouldBypassRateLimit
                )
            }
            await Task.yield()
        }

        catchUpTask = nil
        activeConversationID = nil
    }

    private func delayIfRateLimited(conversationID: String) async -> Bool {
        guard let notBefore = catchUpRateLimiter.delayUntil(for: conversationID) else { return false }
        let delay = notBefore.timeIntervalSinceNow
        guard delay > 0 else {
            return false
        }
        let delayNanoseconds = UInt64((delay * 1_000_000_000).rounded(.up))
        IMAppLog.imRuntime.debug(
            "Gap sync catch-up delayed conversationID=\(conversationID, privacy: .public) delayMs=\(Int(delay * 1000), privacy: .public)"
        )
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return true
    }

    private func recordCatchUpCompleted(for conversationID: String) {
        catchUpRateLimiter.recordCompleted(for: conversationID)
    }

    private func scheduleSelectedHintMicroBatch(for conversationID: String) {
        queue.removeAll { $0 == conversationID }
        selectedHintMicroBatchConversationID = conversationID
        guard selectedHintMicroBatchTask == nil else {
            return
        }

        let microBatchNanoseconds = timelineCatchUpConfiguration.selectedHintMicroBatchNanoseconds
        selectedHintMicroBatchTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: microBatchNanoseconds
                )
            } catch {
                return
            }
            await self?.flushSelectedHintMicroBatch()
        }
    }

    private func flushSelectedHintMicroBatch() {
        selectedHintMicroBatchTask = nil
        guard let conversationID = selectedHintMicroBatchConversationID else {
            return
        }
        selectedHintMicroBatchConversationID = nil
        enqueueCatchUp(
            for: conversationID,
            prioritize: true,
            targetTimelineSequence: targetTimelineSequenceByConversationID[conversationID],
            bypassRateLimit: true,
            microBatchSelectedHint: false
        )
    }

    private func mergeTargetTimelineSequence(_ sequence: UInt64?, for conversationID: String) {
        guard let sequence,
              sequence > 0
        else {
            return
        }
        targetTimelineSequenceByConversationID[conversationID] = max(
            targetTimelineSequenceByConversationID[conversationID] ?? 0,
            sequence
        )
    }

    private func clearReachedTargetIfNeeded(for conversationID: String) {
        guard let targetTimelineSequence = targetTimelineSequenceByConversationID[conversationID],
              let runtime,
              let latestLoadedSequence = latestKnownTimelineSequence(for: conversationID, runtime: runtime),
              latestLoadedSequence >= targetTimelineSequence
        else {
            return
        }

        targetTimelineSequenceByConversationID.removeValue(forKey: conversationID)
    }

    private func latestKnownTimelineSequence(
        for conversationID: String,
        runtime: ConversationRuntimeController
    ) -> UInt64? {
        let loadedSequence = runtime.imConversationStore.latestLoadedTimelineSequence(for: conversationID)
        let progressSequence = gapSyncProgressByConversationID[conversationID]
        switch (loadedSequence, progressSequence) {
        case let (loaded?, progress?):
            return max(loaded, progress)
        case let (loaded?, nil):
            return loaded
        case let (nil, progress?):
            return progress
        case (nil, nil):
            return nil
        }
    }

    private func recordGapSyncProgress(_ sequence: UInt64, for conversationID: String) {
        gapSyncProgressByConversationID[conversationID] = max(
            gapSyncProgressByConversationID[conversationID] ?? 0,
            sequence
        )
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
        selectedHintMicroBatchTask?.cancel()
        selectedHintMicroBatchTask = nil
        selectedHintMicroBatchConversationID = nil
        catchUpTask = nil
        queue = []
        activeConversationID = nil
        targetTimelineSequenceByConversationID = [:]
        gapSyncProgressByConversationID = [:]
        bypassRateLimitConversationIDs = []
        catchUpRateLimiter.reset()
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
        prioritize: Bool = false,
        targetTimelineSequence: UInt64? = nil,
        bypassRateLimit: Bool = false,
        spreadInitialRun: Bool = false
    ) {
        gapSyncCoordinator.enqueueCatchUp(
            for: conversationID,
            prioritize: prioritize,
            targetTimelineSequence: targetTimelineSequence,
            bypassRateLimit: bypassRateLimit,
            spreadInitialRun: spreadInitialRun
        )
    }

    func syncSelectedConversationTimelineCatchUp(
        reason: String,
        bypassRateLimit: Bool = false,
        forceProbe: Bool = false
    ) {
        guard currentUserProvider() != nil,
              let selectedConversationID = imConversationStore.selectedConversationID
        else {
            return
        }

        let trimmedConversationID = selectedConversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let targetTimelineSequence = latestConversationSummariesProvider()
            .first { $0.id.uuidString == trimmedConversationID }?
            .lastMessage?
            .timelineSequence
        if !forceProbe, targetTimelineSequence == nil {
            IMAppLog.imRuntime.debug(
                "Selected conversation timeline catch-up skipped: no target summary reason=\(reason, privacy: .public) conversationID=\(trimmedConversationID, privacy: .public)"
            )
            return
        }

        IMAppLog.imRuntime.debug(
            "Selected conversation timeline catch-up enqueued reason=\(reason, privacy: .public) conversationID=\(trimmedConversationID, privacy: .public) targetTimelineSequence=\(targetTimelineSequence ?? 0, privacy: .public) bypassRateLimit=\(bypassRateLimit, privacy: .public) forceProbe=\(forceProbe, privacy: .public)"
        )
        enqueueConversationGapSyncCatchUp(
            for: trimmedConversationID,
            prioritize: true,
            targetTimelineSequence: targetTimelineSequence,
            bypassRateLimit: bypassRateLimit
        )
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
                let outcome = await imConversationStore.applyDomainEventsAsync(
                    response.envelopes,
                    nextCursor: response.nextCursor,
                    currentUserID: currentUserID
                )
                if let conversationID = outcome.shouldReloadMembersForConversationID {
                    await loadConversationMembers(for: conversationID)
                }
                if outcome.shouldRefreshConversationSummaries {
                    scheduleLightweightConversationSummaryReadModelCorrection()
                }
                if let conversationID = outcome.shouldSyncTimelineForConversationID {
                    let isSelectedConversation = conversationID == imConversationStore.selectedConversationID
                    imConversationStore.recordTimelineCatchUpHintQueued(
                        conversationID: conversationID,
                        targetTimelineSequence: outcome.timelineSyncTargetSequence
                    )
                    enqueueConversationGapSyncCatchUp(
                        for: conversationID,
                        prioritize: isSelectedConversation,
                        targetTimelineSequence: outcome.timelineSyncTargetSequence,
                        bypassRateLimit: isSelectedConversation
                    )
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
