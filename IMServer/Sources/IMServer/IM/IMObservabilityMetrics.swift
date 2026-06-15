import Vapor

actor IMHTTPMetrics {
    struct Snapshot: Sendable {
        var requestCount: Int = 0
        var failedRequestCount: Int = 0
        var totalLatencyMillis: Int = 0
        var maxLatencyMillis: Int = 0
        var lastPath: String?
        var lastStatusCode: Int?

        var averageLatencyMillis: Int {
            guard requestCount > 0 else {
                return 0
            }
            return totalLatencyMillis / requestCount
        }
    }

    private var snapshot = Snapshot()

    func record(path: String, statusCode: Int, durationMillis: Int, didFail: Bool) {
        snapshot.requestCount += 1
        if didFail || statusCode >= 500 {
            snapshot.failedRequestCount += 1
        }
        snapshot.totalLatencyMillis += max(0, durationMillis)
        snapshot.maxLatencyMillis = max(snapshot.maxLatencyMillis, durationMillis)
        snapshot.lastPath = path
        snapshot.lastStatusCode = statusCode
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

actor IMDatabaseMetrics {
    struct Snapshot: Sendable {
        var operationCount: Int = 0
        var failedOperationCount: Int = 0
        var totalLatencyMillis: Int = 0
        var maxLatencyMillis: Int = 0
        var lastOperation: String?
        var invalidSequenceCount: Int = 0
        var staleSearchHitCount: Int = 0

        var averageLatencyMillis: Int {
            guard operationCount > 0 else {
                return 0
            }
            return totalLatencyMillis / operationCount
        }
    }

    private var snapshot = Snapshot()

    func record(operation: String, durationMillis: Int, didFail: Bool = false) {
        snapshot.operationCount += 1
        if didFail {
            snapshot.failedOperationCount += 1
        }
        snapshot.totalLatencyMillis += max(0, durationMillis)
        snapshot.maxLatencyMillis = max(snapshot.maxLatencyMillis, durationMillis)
        snapshot.lastOperation = operation
    }

    func recordInvalidSequence() {
        snapshot.invalidSequenceCount += 1
    }

    func recordStaleSearchHit() {
        snapshot.staleSearchHitCount += 1
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

actor IMStreamMetrics {
    struct Snapshot: Sendable {
        var consumedEvents: Int = 0
        var duplicateEvents: Int = 0
        var failedEvents: Int = 0
        var deadLetterPublishedEvents: Int = 0
        var processedRuns: Int = 0
        var messageCreatedRuns: Int = 0
        var messageCreatedRunEventCount: Int = 0
        var maxMessageCreatedRunEventCount: Int = 0
        var runEventCount: Int = 0
        var maxRunEventCount: Int = 0
        var totalRunProcessingMillis: Int = 0
        var maxRunProcessingMillis: Int = 0
        var totalRunEventLagMillis: Int = 0
        var maxRunEventLagMillis: Int = 0
        var slowProcessingRuns: Int = 0
        var laggedRuns: Int = 0
        var processingBatches: Int = 0
        var processingBatchEventCount: Int = 0
        var maxProcessingBatchEventCount: Int = 0
        var batchFillWaits: Int = 0
        var batchFillWaitMillis: Int = 0
        var batchFillEventCount: Int = 0
        var batchFillSkippedBatches: Int = 0
        var queueProducerWaits: Int = 0
        var queueCurrentDepth: Int = 0
        var queueMaxDepth: Int = 0
        var queueDepthRevision: Int = 0
        var lastConsumerGroupID: String?

        var averageRunProcessingMillis: Int {
            guard processedRuns > 0 else {
                return 0
            }
            return totalRunProcessingMillis / processedRuns
        }

        var averageRunEventLagMillis: Int {
            guard processedRuns > 0 else {
                return 0
            }
            return totalRunEventLagMillis / processedRuns
        }

        var averageMessageCreatedRunEventCount: Int {
            guard messageCreatedRuns > 0 else {
                return 0
            }
            return messageCreatedRunEventCount / messageCreatedRuns
        }

        var averageProcessingBatchEventCount: Int {
            guard processingBatches > 0 else {
                return 0
            }
            return processingBatchEventCount / processingBatches
        }

        var averageBatchFillWaitMillis: Int {
            guard batchFillWaits > 0 else {
                return 0
            }
            return batchFillWaitMillis / batchFillWaits
        }
    }

    private var snapshot = Snapshot()
    private var snapshotsByGroupID: [String: Snapshot] = [:]

    func recordConsumed(groupID: String) {
        snapshot.consumedEvents += 1
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.consumedEvents += 1
            group.lastConsumerGroupID = groupID
        }
    }

    func recordDuplicate(groupID: String) {
        snapshot.duplicateEvents += 1
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.duplicateEvents += 1
            group.lastConsumerGroupID = groupID
        }
    }

    func recordFailed(groupID: String) {
        snapshot.failedEvents += 1
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.failedEvents += 1
            group.lastConsumerGroupID = groupID
        }
    }

    func recordDeadLetterPublished(groupID: String) {
        snapshot.deadLetterPublishedEvents += 1
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.deadLetterPublishedEvents += 1
            group.lastConsumerGroupID = groupID
        }
    }

    func recordRun(
        groupID: String,
        eventCount: Int,
        isMessageCreatedRun: Bool,
        durationMillis: Int,
        eventLagMillis: Int = 0,
        slowThresholdMillis: Int = 0
    ) {
        snapshot.processedRuns += 1
        let safeEventCount = max(0, eventCount)
        let safeDurationMillis = max(0, durationMillis)
        let safeEventLagMillis = max(0, eventLagMillis)
        let safeSlowThresholdMillis = max(0, slowThresholdMillis)
        if isMessageCreatedRun {
            snapshot.messageCreatedRuns += 1
            snapshot.messageCreatedRunEventCount += safeEventCount
            snapshot.maxMessageCreatedRunEventCount = max(snapshot.maxMessageCreatedRunEventCount, safeEventCount)
        }
        snapshot.runEventCount += safeEventCount
        snapshot.maxRunEventCount = max(snapshot.maxRunEventCount, safeEventCount)
        snapshot.totalRunProcessingMillis += safeDurationMillis
        snapshot.maxRunProcessingMillis = max(snapshot.maxRunProcessingMillis, safeDurationMillis)
        snapshot.totalRunEventLagMillis += safeEventLagMillis
        snapshot.maxRunEventLagMillis = max(snapshot.maxRunEventLagMillis, safeEventLagMillis)
        if safeSlowThresholdMillis > 0, safeDurationMillis >= safeSlowThresholdMillis {
            snapshot.slowProcessingRuns += 1
        }
        if safeSlowThresholdMillis > 0, safeEventLagMillis >= safeSlowThresholdMillis {
            snapshot.laggedRuns += 1
        }
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.processedRuns += 1
            if isMessageCreatedRun {
                group.messageCreatedRuns += 1
                group.messageCreatedRunEventCount += safeEventCount
                group.maxMessageCreatedRunEventCount = max(group.maxMessageCreatedRunEventCount, safeEventCount)
            }
            group.runEventCount += safeEventCount
            group.maxRunEventCount = max(group.maxRunEventCount, safeEventCount)
            group.totalRunProcessingMillis += safeDurationMillis
            group.maxRunProcessingMillis = max(group.maxRunProcessingMillis, safeDurationMillis)
            group.totalRunEventLagMillis += safeEventLagMillis
            group.maxRunEventLagMillis = max(group.maxRunEventLagMillis, safeEventLagMillis)
            if safeSlowThresholdMillis > 0, safeDurationMillis >= safeSlowThresholdMillis {
                group.slowProcessingRuns += 1
            }
            if safeSlowThresholdMillis > 0, safeEventLagMillis >= safeSlowThresholdMillis {
                group.laggedRuns += 1
            }
            group.lastConsumerGroupID = groupID
        }
    }

    func recordQueueProducerWait(groupID: String) {
        snapshot.queueProducerWaits += 1
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.queueProducerWaits += 1
            group.lastConsumerGroupID = groupID
        }
    }

    func recordProcessingBatch(
        groupID: String,
        eventCount: Int,
        batchFillWaitMillis: Int = 0,
        batchFillEventCount: Int = 0,
        batchFillSkipped: Bool = false
    ) {
        let safeEventCount = max(0, eventCount)
        let safeBatchFillWaitMillis = max(0, batchFillWaitMillis)
        let safeBatchFillEventCount = max(0, batchFillEventCount)
        snapshot.processingBatches += 1
        snapshot.processingBatchEventCount += safeEventCount
        snapshot.maxProcessingBatchEventCount = max(snapshot.maxProcessingBatchEventCount, safeEventCount)
        if safeBatchFillWaitMillis > 0 {
            snapshot.batchFillWaits += 1
            snapshot.batchFillWaitMillis += safeBatchFillWaitMillis
        }
        snapshot.batchFillEventCount += safeBatchFillEventCount
        if batchFillSkipped {
            snapshot.batchFillSkippedBatches += 1
        }
        snapshot.lastConsumerGroupID = groupID
        updateGroup(groupID) { group in
            group.processingBatches += 1
            group.processingBatchEventCount += safeEventCount
            group.maxProcessingBatchEventCount = max(group.maxProcessingBatchEventCount, safeEventCount)
            if safeBatchFillWaitMillis > 0 {
                group.batchFillWaits += 1
                group.batchFillWaitMillis += safeBatchFillWaitMillis
            }
            group.batchFillEventCount += safeBatchFillEventCount
            if batchFillSkipped {
                group.batchFillSkippedBatches += 1
            }
            group.lastConsumerGroupID = groupID
        }
    }

    func recordQueueDepth(groupID: String, depth: Int, revision: Int? = nil) {
        var didUpdateGroup = false
        updateGroup(groupID) { group in
            if let revision, revision < group.queueDepthRevision {
                return
            }
            let safeDepth = max(0, depth)
            group.queueCurrentDepth = safeDepth
            group.queueMaxDepth = max(group.queueMaxDepth, safeDepth)
            if let revision {
                group.queueDepthRevision = revision
            }
            group.lastConsumerGroupID = groupID
            didUpdateGroup = true
        }
        guard didUpdateGroup else {
            return
        }
        snapshot.queueCurrentDepth = snapshotsByGroupID.values.reduce(0) { $0 + $1.queueCurrentDepth }
        snapshot.queueMaxDepth = max(snapshot.queueMaxDepth, snapshot.queueCurrentDepth)
        snapshot.queueDepthRevision = max(snapshot.queueDepthRevision, revision ?? snapshot.queueDepthRevision)
        snapshot.lastConsumerGroupID = groupID
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }

    func currentGroupSnapshots() -> [(groupID: String, snapshot: Snapshot)] {
        snapshotsByGroupID
            .map { (groupID: $0.key, snapshot: $0.value) }
            .sorted { $0.groupID < $1.groupID }
    }

    private func updateGroup(_ groupID: String, _ update: (inout Snapshot) -> Void) {
        var group = snapshotsByGroupID[groupID] ?? Snapshot()
        update(&group)
        snapshotsByGroupID[groupID] = group
    }
}

actor IMAIStreamMetrics {
    struct Snapshot: Sendable {
        var activeStreams: Int = 0
        var startedStreams: Int = 0
        var cancelledStreams: Int = 0
        var completedStreams: Int = 0
        var failedStreams: Int = 0
        var publishedChunks: Int = 0
        var snapshotWrites: Int = 0
        var terminalCASConflicts: Int = 0
        var startupStaleRepairs: Int = 0
        var startupRepairPages: Int = 0
        var runtimeStaleRepairs: Int = 0
        var leaseReservations: Int = 0
        var leaseRejections: Int = 0
        var leaseHeartbeats: Int = 0
        var leaseCancellationRequests: Int = 0
        var chunkDatabaseBypasses: Int = 0
        var finalizeRetries: Int = 0
        var finalizeFailures: Int = 0
    }

    private var snapshot = Snapshot()

    func recordStarted() {
        snapshot.activeStreams += 1
        snapshot.startedStreams += 1
    }

    func recordFinished(state: MessageStreamLifecycleState) {
        snapshot.activeStreams = max(0, snapshot.activeStreams - 1)
        switch state {
        case .completed:
            snapshot.completedStreams += 1
        case .failed:
            snapshot.failedStreams += 1
        case .cancelled:
            snapshot.cancelledStreams += 1
        case .streaming:
            break
        }
    }

    func recordChunkPublished() {
        snapshot.publishedChunks += 1
    }

    func recordSnapshotWrite() {
        snapshot.snapshotWrites += 1
    }

    func recordTerminalCASConflict() {
        snapshot.terminalCASConflicts += 1
    }

    func recordStartupStaleRepair(count: Int) {
        snapshot.startupStaleRepairs += max(0, count)
    }

    func recordStartupRepairPage() {
        snapshot.startupRepairPages += 1
    }

    func recordRuntimeStaleRepair(count: Int) {
        snapshot.runtimeStaleRepairs += max(0, count)
    }

    func recordLeaseReservation() {
        snapshot.leaseReservations += 1
    }

    func recordLeaseRejection() {
        snapshot.leaseRejections += 1
    }

    func recordLeaseHeartbeat() {
        snapshot.leaseHeartbeats += 1
    }

    func recordLeaseCancellationRequest() {
        snapshot.leaseCancellationRequests += 1
    }

    func recordChunkDatabaseBypass() {
        snapshot.chunkDatabaseBypasses += 1
    }

    func recordFinalizeRetry() {
        snapshot.finalizeRetries += 1
    }

    func recordFinalizeFailure() {
        snapshot.finalizeFailures += 1
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

actor IMClientHealthMetrics {
    struct Snapshot: Sendable {
        var reports: Int = 0
        var activeReportingUsers: Int = 0
        var usersWithDeferredDomainEvents: Int = 0
        var totalDeferredDomainEvents: Int = 0
        var maxDeferredDomainEvents: Int = 0
        var maxFullRefreshConversations: Int = 0
        var maxDomainEventCursor: UInt64 = 0
        var catchUpCursorGaps: Int = 0
        var catchUpStoppedBeforeCursorAdvance: Int = 0
        var deferredStored: Int = 0
        var deferredReplayApplied: Int = 0
        var deferredExpired: Int = 0
        var deferredFullRefreshRequested: Int = 0
        var invalidDomainEvents: Int = 0
        var invalidProjectionDTOs: Int = 0
        var invalidCanonicalMessageDTOs: Int = 0
        var cacheDroppedCanonicalMessages: Int = 0
        var cacheDroppedTimelineNotices: Int = 0
        var timelineCatchUpHintQueued: Int = 0
        var timelineCatchUpSkippedAlreadyLoaded: Int = 0
        var timelineCatchUpDeferred: Int = 0
        var timelineCatchUpSinceRequests: Int = 0
        var timelineCatchUpSinceSuccesses: Int = 0
        var timelineCatchUpSinceFailures: Int = 0
        var timelineCatchUpAppliedPages: Int = 0
        var timelineCatchUpAppliedItems: Int = 0
        var maxTimelineCatchUpHintToRequestMillis: Int = 0
        var maxTimelineCatchUpRequestMillis: Int = 0
        var maxTimelineCatchUpHintToApplyMillis: Int = 0
        var averageTimelineCatchUpHintToRequestMillis: Int = 0
        var averageTimelineCatchUpRequestMillis: Int = 0
        var averageTimelineCatchUpHintToApplyMillis: Int = 0
        var maxTimelineCatchUpSelectedHintInitialJitterMillis: Int = 0
        var maxTimelineCatchUpSelectedHintMinimumIntervalMillis: Int = 0
        var maxTimelineCatchUpSelectedHintMicroBatchMillis: Int = 0
        var averageTimelineCatchUpSelectedHintInitialJitterMillis: Int = 0
        var averageTimelineCatchUpSelectedHintMinimumIntervalMillis: Int = 0
        var averageTimelineCatchUpSelectedHintMicroBatchMillis: Int = 0
        var lastReason: String?
        var lastReportedAt: Date?
    }

    private var snapshot = Snapshot()
    private var lastReportsByUserID: [UUID: IMClientHealthReportRequest] = [:]

    func record(userID: UUID, report: IMClientHealthReportRequest) {
        let previous = lastReportsByUserID[userID]
        lastReportsByUserID[userID] = report

        snapshot.reports += 1
        snapshot.activeReportingUsers = lastReportsByUserID.count
        snapshot.lastReason = report.reason
        snapshot.lastReportedAt = report.reportedAt

        let metrics = report.snapshot.domainEventMetrics
        let previousMetrics = previous?.snapshot.domainEventMetrics
        snapshot.catchUpCursorGaps += positiveDelta(metrics.catchUpCursorGap, previousMetrics?.catchUpCursorGap)
        snapshot.catchUpStoppedBeforeCursorAdvance += positiveDelta(
            metrics.catchUpStoppedBeforeCursorAdvance,
            previousMetrics?.catchUpStoppedBeforeCursorAdvance
        )
        snapshot.deferredStored += positiveDelta(metrics.deferredStored, previousMetrics?.deferredStored)
        snapshot.deferredReplayApplied += positiveDelta(
            metrics.deferredReplayApplied,
            previousMetrics?.deferredReplayApplied
        )
        snapshot.deferredExpired += positiveDelta(metrics.deferredExpired, previousMetrics?.deferredExpired)
        snapshot.deferredFullRefreshRequested += positiveDelta(
            metrics.deferredFullRefreshRequested,
            previousMetrics?.deferredFullRefreshRequested
        )
        snapshot.invalidDomainEvents += positiveDelta(
            metrics.invalidDomainEventMetadata,
            previousMetrics?.invalidDomainEventMetadata
        )
        snapshot.invalidProjectionDTOs += positiveDelta(
            metrics.invalidProjectionDTOs,
            previousMetrics?.invalidProjectionDTOs
        )
        snapshot.invalidCanonicalMessageDTOs += positiveDelta(
            metrics.invalidCanonicalMessageDTOs,
            previousMetrics?.invalidCanonicalMessageDTOs
        )
        snapshot.cacheDroppedCanonicalMessages += positiveDelta(
            metrics.cacheDroppedCanonicalMessages,
            previousMetrics?.cacheDroppedCanonicalMessages
        )
        snapshot.cacheDroppedTimelineNotices += positiveDelta(
            metrics.cacheDroppedTimelineNotices,
            previousMetrics?.cacheDroppedTimelineNotices
        )

        let timelineDiagnostics = report.snapshot.timelineCatchUpDiagnostics
        let previousTimelineDiagnostics = previous?.snapshot.timelineCatchUpDiagnostics
        snapshot.timelineCatchUpHintQueued += positiveDelta(
            timelineDiagnostics?.hintQueuedCount ?? 0,
            previousTimelineDiagnostics?.hintQueuedCount
        )
        snapshot.timelineCatchUpSkippedAlreadyLoaded += positiveDelta(
            timelineDiagnostics?.hintSkippedAlreadyLoadedCount ?? 0,
            previousTimelineDiagnostics?.hintSkippedAlreadyLoadedCount
        )
        snapshot.timelineCatchUpDeferred += positiveDelta(
            timelineDiagnostics?.deferredCount ?? 0,
            previousTimelineDiagnostics?.deferredCount
        )
        snapshot.timelineCatchUpSinceRequests += positiveDelta(
            timelineDiagnostics?.sinceRequestCount ?? 0,
            previousTimelineDiagnostics?.sinceRequestCount
        )
        snapshot.timelineCatchUpSinceSuccesses += positiveDelta(
            timelineDiagnostics?.sinceSuccessCount ?? 0,
            previousTimelineDiagnostics?.sinceSuccessCount
        )
        snapshot.timelineCatchUpSinceFailures += positiveDelta(
            timelineDiagnostics?.sinceFailureCount ?? 0,
            previousTimelineDiagnostics?.sinceFailureCount
        )
        snapshot.timelineCatchUpAppliedPages += positiveDelta(
            timelineDiagnostics?.appliedPageCount ?? 0,
            previousTimelineDiagnostics?.appliedPageCount
        )
        snapshot.timelineCatchUpAppliedItems += positiveDelta(
            timelineDiagnostics?.appliedItemCount ?? 0,
            previousTimelineDiagnostics?.appliedItemCount
        )

        recalculateCurrentGauges()
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }

    private func positiveDelta(_ current: Int, _ previous: Int?) -> Int {
        max(0, current - (previous ?? 0))
    }

    private func recalculateCurrentGauges() {
        let reports = Array(lastReportsByUserID.values)
        snapshot.usersWithDeferredDomainEvents = reports.filter { $0.snapshot.deferredDomainEventCount > 0 }.count
        snapshot.totalDeferredDomainEvents = reports.reduce(0) {
            $0 + max(0, $1.snapshot.deferredDomainEventCount)
        }
        snapshot.maxDeferredDomainEvents = reports.map {
            max(0, $0.snapshot.deferredDomainEventCount)
        }.max() ?? 0
        snapshot.maxFullRefreshConversations = reports.map {
            max(0, $0.snapshot.fullRefreshConversationCount)
        }.max() ?? 0
        snapshot.maxDomainEventCursor = reports.map(\.snapshot.domainEventCursor).max() ?? 0
        snapshot.maxTimelineCatchUpHintToRequestMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpDiagnostics?.lastHintToRequestMilliseconds.map { max(0, $0) }
        }.max() ?? 0
        snapshot.maxTimelineCatchUpRequestMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpDiagnostics?.lastRequestMilliseconds.map { max(0, $0) }
        }.max() ?? 0
        snapshot.maxTimelineCatchUpHintToApplyMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpDiagnostics?.lastHintToApplyMilliseconds.map { max(0, $0) }
        }.max() ?? 0
        snapshot.averageTimelineCatchUpHintToRequestMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpDiagnostics?.lastHintToRequestMilliseconds.map { max(0, $0) }
            }
        )
        snapshot.averageTimelineCatchUpRequestMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpDiagnostics?.lastRequestMilliseconds.map { max(0, $0) }
            }
        )
        snapshot.averageTimelineCatchUpHintToApplyMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpDiagnostics?.lastHintToApplyMilliseconds.map { max(0, $0) }
            }
        )
        snapshot.maxTimelineCatchUpSelectedHintInitialJitterMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpConfiguration?.selectedHintInitialJitterMilliseconds
        }.map { max(0, $0) }.max() ?? 0
        snapshot.maxTimelineCatchUpSelectedHintMinimumIntervalMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpConfiguration?.selectedHintMinimumIntervalMilliseconds
        }.map { max(0, $0) }.max() ?? 0
        snapshot.maxTimelineCatchUpSelectedHintMicroBatchMillis = reports.compactMap {
            $0.snapshot.timelineCatchUpConfiguration?.selectedHintMicroBatchMilliseconds
        }.map { max(0, $0) }.max() ?? 0
        snapshot.averageTimelineCatchUpSelectedHintInitialJitterMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpConfiguration?.selectedHintInitialJitterMilliseconds
            }.map { max(0, $0) }
        )
        snapshot.averageTimelineCatchUpSelectedHintMinimumIntervalMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpConfiguration?.selectedHintMinimumIntervalMilliseconds
            }.map { max(0, $0) }
        )
        snapshot.averageTimelineCatchUpSelectedHintMicroBatchMillis = average(
            reports.compactMap {
                $0.snapshot.timelineCatchUpConfiguration?.selectedHintMicroBatchMilliseconds
            }.map { max(0, $0) }
        )
    }

    private func average(_ values: [Int]) -> Int {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / values.count
    }
}

struct IMHTTPMetricsMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let start = Date()
        do {
            let response = try await next.respond(to: request)
            await request.application.httpMetrics.record(
                path: request.url.path,
                statusCode: Int(response.status.code),
                durationMillis: Self.elapsedMillis(since: start),
                didFail: false
            )
            return response
        } catch {
            await request.application.httpMetrics.record(
                path: request.url.path,
                statusCode: 500,
                durationMillis: Self.elapsedMillis(since: start),
                didFail: true
            )
            throw error
        }
    }

    private static func elapsedMillis(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

private struct IMHTTPMetricsStorageKey: StorageKey {
    typealias Value = IMHTTPMetrics
}

private struct IMDatabaseMetricsStorageKey: StorageKey {
    typealias Value = IMDatabaseMetrics
}

private struct IMStreamMetricsStorageKey: StorageKey {
    typealias Value = IMStreamMetrics
}

private struct IMAIStreamMetricsStorageKey: StorageKey {
    typealias Value = IMAIStreamMetrics
}

private struct IMClientHealthMetricsStorageKey: StorageKey {
    typealias Value = IMClientHealthMetrics
}

extension Application {
    var httpMetrics: IMHTTPMetrics {
        get {
            if let metrics = storage[IMHTTPMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMHTTPMetrics()
            storage[IMHTTPMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMHTTPMetricsStorageKey.self] = newValue }
    }

    var databaseMetrics: IMDatabaseMetrics {
        get {
            if let metrics = storage[IMDatabaseMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMDatabaseMetrics()
            storage[IMDatabaseMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMDatabaseMetricsStorageKey.self] = newValue }
    }

    var streamMetrics: IMStreamMetrics {
        get {
            if let metrics = storage[IMStreamMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMStreamMetrics()
            storage[IMStreamMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMStreamMetricsStorageKey.self] = newValue }
    }

    var aiStreamMetrics: IMAIStreamMetrics {
        get {
            if let metrics = storage[IMAIStreamMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMAIStreamMetrics()
            storage[IMAIStreamMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMAIStreamMetricsStorageKey.self] = newValue }
    }

    var clientHealthMetrics: IMClientHealthMetrics {
        get {
            if let metrics = storage[IMClientHealthMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMClientHealthMetrics()
            storage[IMClientHealthMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMClientHealthMetricsStorageKey.self] = newValue }
    }
}
