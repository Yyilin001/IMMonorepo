import Vapor

actor ConversationDomainEventMetrics {
    struct Snapshot: Sendable {
        var recipientResolveCount: Int = 0
        var recipientResolveInlineCount: Int = 0
        var recipientResolveEventSnapshotCount: Int = 0
        var recipientResolveMembershipExpansionCount: Int = 0
        var recipientResolveAffectedUserCount: Int = 0
        var recipientResolveEmptyCount: Int = 0
        var recipientResolveErrorCount: Int = 0
        var recipientResolveMissingSnapshotCount: Int = 0
        var recipientResolveTotalMillis: Int = 0
        var recipientResolveMaxMillis: Int = 0
        var recipientResolveUserCount: Int = 0
        var recipientResolveMaxUserCount: Int = 0
        var recipientSnapshotInlineStoreCount: Int = 0
        var recipientSnapshotInlineStoreRecipientCount: Int = 0
        var recipientSnapshotDeduplicatedStoreCount: Int = 0
        var recipientSnapshotDeduplicatedStoreRecipientCount: Int = 0
        var recipientSnapshotResolveInlineCount: Int = 0
        var recipientSnapshotResolveSharedSetHitCount: Int = 0
        var recipientSnapshotResolveSharedSetMissingCount: Int = 0
        var recipientSnapshotResolveTotalMillis: Int = 0
        var recipientSnapshotResolveMaxMillis: Int = 0
        var recipientSnapshotResolveRecipientCount: Int = 0
        var recipientSnapshotResolveMaxRecipients: Int = 0
        var recipientSetCleanupRunCount: Int = 0
        var recipientSetCleanupScannedCount: Int = 0
        var recipientSetCleanupDeletedCount: Int = 0
        var recipientSetCleanupMaxDeletedCount: Int = 0
        var messageCreatedOwnerDeliverySkippedCount: Int = 0
        var messageCreatedOwnerDeliverySkippedRecipientCount: Int = 0
        var messageCreatedOwnerDeliverySkippedMaxRecipients: Int = 0
        var messageCreatedTimelinePullDeliveryCount: Int = 0
        var messageCreatedTimelinePullDeliveryRecipientCount: Int = 0
        var messageCreatedTimelinePullDeliveryMaxRecipients: Int = 0
        var messageCreatedOwnerNotificationSkippedCount: Int = 0
        var messageCreatedOwnerNotificationSkippedRecipientCount: Int = 0
        var messageCreatedOwnerNotificationSkippedMaxRecipients: Int = 0
        var messageCreatedSummaryActivityOnlyCount: Int = 0
        var messageCreatedSummaryActivityOnlyRecipientCount: Int = 0
        var messageCreatedSummaryActivityOnlyMaxRecipients: Int = 0
        var messageCreatedPreviewEmbeddedCount: Int = 0
        var messageCreatedPreviewMessageLookupCount: Int = 0
        var messageCreatedPreviewMissingCount: Int = 0
        var summaryActivityCoalescedReplacementCount: Int = 0
        var summaryActivityCoalescedFlushCount: Int = 0
        var summaryActivityCoalescedFlushRequestCount: Int = 0
        var summaryActivityCoalescedFlushFailureCount: Int = 0
        var summaryActivityCoalescedFlushFailureRequestCount: Int = 0
        var summaryActivityCoalescedFlushTotalMillis: Int = 0
        var summaryActivityCoalescedFlushMaxMillis: Int = 0
        var ownerDeliveryBatchWriteCount: Int = 0
        var ownerDeliveryBatchWriteRequestCount: Int = 0
        var ownerDeliveryBatchWriteInsertedRowCount: Int = 0
        var ownerDeliveryBatchWriteReturnedRowCount: Int = 0
        var ownerDeliveryBatchWriteFallbackCount: Int = 0
        var ownerDeliveryBatchWriteCanonicalFastPathCount: Int = 0
        var ownerDeliveryBatchWriteMaterializedFastPathCount: Int = 0
        var ownerDeliveryBatchWriteChunkedCount: Int = 0
        var ownerDeliveryBatchWriteChunkCount: Int = 0
        var ownerDeliveryBatchWriteChunkedMaxRequests: Int = 0
        var ownerDeliveryBatchWriteTotalMillis: Int = 0
        var ownerDeliveryBatchWriteMaxMillis: Int = 0
        var ownerDeliveryBatchWriteMaxRequests: Int = 0
    }

    private var snapshot = Snapshot()

    func recordRecipientResolution(
        source: ConversationDomainEventResolvedRecipients.Source,
        recipientCount: Int,
        elapsedMilliseconds: Int
    ) {
        snapshot.recipientResolveCount += 1
        snapshot.recipientResolveTotalMillis += elapsedMilliseconds
        snapshot.recipientResolveMaxMillis = max(snapshot.recipientResolveMaxMillis, elapsedMilliseconds)
        snapshot.recipientResolveUserCount += recipientCount
        snapshot.recipientResolveMaxUserCount = max(snapshot.recipientResolveMaxUserCount, recipientCount)
        if recipientCount == 0 {
            snapshot.recipientResolveEmptyCount += 1
        }
        switch source {
        case .inline:
            snapshot.recipientResolveInlineCount += 1
        case .eventSnapshot:
            snapshot.recipientResolveEventSnapshotCount += 1
        case .membershipExpansion:
            snapshot.recipientResolveMembershipExpansionCount += 1
        case .affectedUser:
            snapshot.recipientResolveAffectedUserCount += 1
        }
    }

    func recordRecipientResolutionError() {
        snapshot.recipientResolveErrorCount += 1
    }

    func recordRecipientResolutionMissingSnapshot() {
        snapshot.recipientResolveMissingSnapshotCount += 1
    }

    func recordRecipientSnapshotStored(recipientCount: Int, deduplicated: Bool) {
        if deduplicated {
            snapshot.recipientSnapshotDeduplicatedStoreCount += 1
            snapshot.recipientSnapshotDeduplicatedStoreRecipientCount += max(0, recipientCount)
        } else {
            snapshot.recipientSnapshotInlineStoreCount += 1
            snapshot.recipientSnapshotInlineStoreRecipientCount += max(0, recipientCount)
        }
    }

    func recordRecipientSnapshotResolved(
        usedSharedSet: Bool,
        recipientCount: Int,
        elapsedMilliseconds: Int
    ) {
        if usedSharedSet {
            snapshot.recipientSnapshotResolveSharedSetHitCount += 1
        } else {
            snapshot.recipientSnapshotResolveInlineCount += 1
        }
        snapshot.recipientSnapshotResolveRecipientCount += max(0, recipientCount)
        snapshot.recipientSnapshotResolveMaxRecipients = max(
            snapshot.recipientSnapshotResolveMaxRecipients,
            recipientCount
        )
        snapshot.recipientSnapshotResolveTotalMillis += max(0, elapsedMilliseconds)
        snapshot.recipientSnapshotResolveMaxMillis = max(
            snapshot.recipientSnapshotResolveMaxMillis,
            elapsedMilliseconds
        )
    }

    func recordRecipientSnapshotSharedSetMissing(elapsedMilliseconds: Int) {
        snapshot.recipientSnapshotResolveSharedSetMissingCount += 1
        snapshot.recipientSnapshotResolveTotalMillis += max(0, elapsedMilliseconds)
        snapshot.recipientSnapshotResolveMaxMillis = max(
            snapshot.recipientSnapshotResolveMaxMillis,
            elapsedMilliseconds
        )
    }

    func recordRecipientSetCleanup(scannedCount: Int, deletedCount: Int) {
        let safeDeletedCount = max(0, deletedCount)
        snapshot.recipientSetCleanupRunCount += 1
        snapshot.recipientSetCleanupScannedCount += max(0, scannedCount)
        snapshot.recipientSetCleanupDeletedCount += safeDeletedCount
        snapshot.recipientSetCleanupMaxDeletedCount = max(
            snapshot.recipientSetCleanupMaxDeletedCount,
            safeDeletedCount
        )
    }

    func recordMessageCreatedOwnerDeliverySkipped(recipientCount: Int) {
        snapshot.messageCreatedOwnerDeliverySkippedCount += 1
        snapshot.messageCreatedOwnerDeliverySkippedRecipientCount += max(0, recipientCount)
        snapshot.messageCreatedOwnerDeliverySkippedMaxRecipients = max(
            snapshot.messageCreatedOwnerDeliverySkippedMaxRecipients,
            recipientCount
        )
    }

    func recordMessageCreatedTimelinePullDelivery(recipientCount: Int) {
        snapshot.messageCreatedTimelinePullDeliveryCount += 1
        snapshot.messageCreatedTimelinePullDeliveryRecipientCount += max(0, recipientCount)
        snapshot.messageCreatedTimelinePullDeliveryMaxRecipients = max(
            snapshot.messageCreatedTimelinePullDeliveryMaxRecipients,
            recipientCount
        )
    }

    func recordMessageCreatedOwnerNotificationSkipped(recipientCount: Int) {
        snapshot.messageCreatedOwnerNotificationSkippedCount += 1
        snapshot.messageCreatedOwnerNotificationSkippedRecipientCount += max(0, recipientCount)
        snapshot.messageCreatedOwnerNotificationSkippedMaxRecipients = max(
            snapshot.messageCreatedOwnerNotificationSkippedMaxRecipients,
            recipientCount
        )
    }

    func recordMessageCreatedSummaryActivityOnly(recipientCount: Int) {
        snapshot.messageCreatedSummaryActivityOnlyCount += 1
        snapshot.messageCreatedSummaryActivityOnlyRecipientCount += max(0, recipientCount)
        snapshot.messageCreatedSummaryActivityOnlyMaxRecipients = max(
            snapshot.messageCreatedSummaryActivityOnlyMaxRecipients,
            recipientCount
        )
    }

    func recordMessageCreatedEmbeddedPreviewUsed() {
        snapshot.messageCreatedPreviewEmbeddedCount += 1
    }

    func recordMessageCreatedPreviewMessageLookup() {
        snapshot.messageCreatedPreviewMessageLookupCount += 1
    }

    func recordMessageCreatedPreviewMissing() {
        snapshot.messageCreatedPreviewMissingCount += 1
    }

    func recordSummaryActivityCoalescedReplacement() {
        snapshot.summaryActivityCoalescedReplacementCount += 1
    }

    func recordSummaryActivityCoalescedFlush(
        requestCount: Int,
        elapsedMilliseconds: Int
    ) {
        snapshot.summaryActivityCoalescedFlushCount += 1
        snapshot.summaryActivityCoalescedFlushRequestCount += max(0, requestCount)
        snapshot.summaryActivityCoalescedFlushTotalMillis += max(0, elapsedMilliseconds)
        snapshot.summaryActivityCoalescedFlushMaxMillis = max(
            snapshot.summaryActivityCoalescedFlushMaxMillis,
            elapsedMilliseconds
        )
    }

    func recordSummaryActivityCoalescedFlushFailure(
        requestCount: Int,
        elapsedMilliseconds: Int
    ) {
        snapshot.summaryActivityCoalescedFlushFailureCount += 1
        snapshot.summaryActivityCoalescedFlushFailureRequestCount += max(0, requestCount)
        snapshot.summaryActivityCoalescedFlushTotalMillis += max(0, elapsedMilliseconds)
        snapshot.summaryActivityCoalescedFlushMaxMillis = max(
            snapshot.summaryActivityCoalescedFlushMaxMillis,
            elapsedMilliseconds
        )
    }

    func recordOwnerDeliveryBatchWrite(
        requestCount: Int,
        insertedRowCount: Int,
        returnedRowCount: Int,
        elapsedMilliseconds: Int,
        usedFallback: Bool,
        usedCanonicalFastPath: Bool = false,
        usedMaterializedFastPath: Bool = false
    ) {
        let safeRequestCount = max(0, requestCount)
        snapshot.ownerDeliveryBatchWriteCount += 1
        snapshot.ownerDeliveryBatchWriteRequestCount += safeRequestCount
        snapshot.ownerDeliveryBatchWriteInsertedRowCount += max(0, insertedRowCount)
        snapshot.ownerDeliveryBatchWriteReturnedRowCount += max(0, returnedRowCount)
        snapshot.ownerDeliveryBatchWriteTotalMillis += max(0, elapsedMilliseconds)
        snapshot.ownerDeliveryBatchWriteMaxMillis = max(
            snapshot.ownerDeliveryBatchWriteMaxMillis,
            elapsedMilliseconds
        )
        snapshot.ownerDeliveryBatchWriteMaxRequests = max(
            snapshot.ownerDeliveryBatchWriteMaxRequests,
            safeRequestCount
        )
        if usedFallback {
            snapshot.ownerDeliveryBatchWriteFallbackCount += 1
        }
        if usedCanonicalFastPath {
            snapshot.ownerDeliveryBatchWriteCanonicalFastPathCount += 1
        }
        if usedMaterializedFastPath {
            snapshot.ownerDeliveryBatchWriteMaterializedFastPathCount += 1
        }
    }

    func recordOwnerDeliveryBatchWriteChunking(
        requestCount: Int,
        chunkCount: Int
    ) {
        snapshot.ownerDeliveryBatchWriteChunkedCount += 1
        snapshot.ownerDeliveryBatchWriteChunkCount += max(0, chunkCount)
        snapshot.ownerDeliveryBatchWriteChunkedMaxRequests = max(
            snapshot.ownerDeliveryBatchWriteChunkedMaxRequests,
            max(0, requestCount)
        )
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

private struct ConversationDomainEventMetricsStorageKey: StorageKey {
    typealias Value = ConversationDomainEventMetrics
}

extension Application {
    var conversationDomainEventMetrics: ConversationDomainEventMetrics {
        get {
            if let metrics = storage[ConversationDomainEventMetricsStorageKey.self] {
                return metrics
            }
            let metrics = ConversationDomainEventMetrics()
            storage[ConversationDomainEventMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[ConversationDomainEventMetricsStorageKey.self] = newValue
        }
    }
}
