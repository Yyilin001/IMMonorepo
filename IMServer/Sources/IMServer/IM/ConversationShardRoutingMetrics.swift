import Vapor

actor ConversationShardRoutingMetrics {
    struct Snapshot: Sendable {
        var cacheHitCount: Int = 0
        var cacheMissCount: Int = 0
        var cacheStoreCount: Int = 0
        var cacheEvictionCount: Int = 0
        var directoryLookupCount: Int = 0
        var directoryLookupFailureCount: Int = 0
        var directoryLookupTotalMillis: Int = 0
        var directoryLookupMaxMillis: Int = 0
        var remoteCellRouteRejectedCount: Int = 0
        var remoteCellForwardAttemptCount: Int = 0
        var remoteCellForwardSuccessCount: Int = 0
        var remoteCellForwardFailureCount: Int = 0
        var remoteCellForwardLatencyCount: Int = 0
        var remoteCellForwardTotalMillis: Int = 0
        var remoteCellForwardMaxMillis: Int = 0
        var cacheEntryCount: Int = 0
        var cacheMaxEntries: Int = 0
    }

    private var snapshot = Snapshot()

    func recordCacheHit() {
        snapshot.cacheHitCount += 1
    }

    func recordCacheMiss() {
        snapshot.cacheMissCount += 1
    }

    func recordCacheStore(entryCount: Int, evictedCount: Int, maxEntries: Int) {
        snapshot.cacheStoreCount += 1
        snapshot.cacheEvictionCount += max(0, evictedCount)
        snapshot.cacheEntryCount = max(0, entryCount)
        snapshot.cacheMaxEntries = max(0, maxEntries)
    }

    func recordDirectoryLookup(elapsedMilliseconds: Int) {
        snapshot.directoryLookupCount += 1
        snapshot.directoryLookupTotalMillis += max(0, elapsedMilliseconds)
        snapshot.directoryLookupMaxMillis = max(snapshot.directoryLookupMaxMillis, elapsedMilliseconds)
    }

    func recordDirectoryLookupFailure(elapsedMilliseconds: Int) {
        snapshot.directoryLookupFailureCount += 1
        snapshot.directoryLookupTotalMillis += max(0, elapsedMilliseconds)
        snapshot.directoryLookupMaxMillis = max(snapshot.directoryLookupMaxMillis, elapsedMilliseconds)
    }

    func recordRemoteCellRouteRejected() {
        snapshot.remoteCellRouteRejectedCount += 1
    }

    func recordRemoteCellForwardAttempt() {
        snapshot.remoteCellForwardAttemptCount += 1
    }

    func recordRemoteCellForwardSuccess(elapsedMilliseconds: Int) {
        snapshot.remoteCellForwardSuccessCount += 1
        recordRemoteCellForwardLatency(elapsedMilliseconds)
    }

    func recordRemoteCellForwardFailure(elapsedMilliseconds: Int? = nil) {
        snapshot.remoteCellForwardFailureCount += 1
        if let elapsedMilliseconds {
            recordRemoteCellForwardLatency(elapsedMilliseconds)
        }
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }

    private func recordRemoteCellForwardLatency(_ elapsedMilliseconds: Int) {
        let safeElapsed = max(0, elapsedMilliseconds)
        snapshot.remoteCellForwardLatencyCount += 1
        snapshot.remoteCellForwardTotalMillis += safeElapsed
        snapshot.remoteCellForwardMaxMillis = max(snapshot.remoteCellForwardMaxMillis, safeElapsed)
    }
}

private struct ConversationShardRoutingMetricsStorageKey: StorageKey {
    typealias Value = ConversationShardRoutingMetrics
}

extension Application {
    var conversationShardRoutingMetrics: ConversationShardRoutingMetrics {
        get {
            if let metrics = storage[ConversationShardRoutingMetricsStorageKey.self] {
                return metrics
            }
            let metrics = ConversationShardRoutingMetrics()
            storage[ConversationShardRoutingMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[ConversationShardRoutingMetricsStorageKey.self] = newValue
        }
    }
}
