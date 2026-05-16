actor RoutingMetrics {
    struct Snapshot: Sendable {
        var currentTCPConnectionCount: Int = 0
        var userFanoutCount: Int = 0
        var sessionKickCount: Int = 0
        var sessionCountQueryFailureCount: Int = 0
        var redisRouteRegistrations: Int = 0
        var crossNodeDispatchCount: Int = 0
        var crossNodeDispatchFailureCount: Int = 0
        var redisPresenceRouteCacheHits: Int = 0
        var redisPresenceRouteCacheMisses: Int = 0
        var redisPresencePipelineLookupCount: Int = 0
        var redisPresencePipelineLookupUserCount: Int = 0
        var redisPresenceStaleCleanupCount: Int = 0
    }

    private var snapshot = Snapshot()

    func recordPresenceRegistration() {
        snapshot.redisRouteRegistrations += 1
    }

    func recordCurrentTCPConnectionCount(_ count: Int) {
        snapshot.currentTCPConnectionCount = count
    }

    func recordUserFanout(targetUserCount: Int) {
        snapshot.userFanoutCount += targetUserCount
    }

    func recordSessionKick(targetSessionCount: Int) {
        snapshot.sessionKickCount += targetSessionCount
    }

    func recordSessionCountQueryFailed() {
        snapshot.sessionCountQueryFailureCount += 1
    }

    func recordCrossNodeDispatchSucceeded() {
        snapshot.crossNodeDispatchCount += 1
    }

    func recordCrossNodeDispatchFailed() {
        snapshot.crossNodeDispatchFailureCount += 1
    }

    func recordRedisPresenceRouteCacheHit() {
        snapshot.redisPresenceRouteCacheHits += 1
    }

    func recordRedisPresenceRouteCacheMiss() {
        snapshot.redisPresenceRouteCacheMisses += 1
    }

    func recordRedisPresencePipelineLookup(size: Int) {
        snapshot.redisPresencePipelineLookupCount += 1
        snapshot.redisPresencePipelineLookupUserCount += size
    }

    func recordRedisPresenceStaleCleanup(count: Int) {
        snapshot.redisPresenceStaleCleanupCount += count
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}
