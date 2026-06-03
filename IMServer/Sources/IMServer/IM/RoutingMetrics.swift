actor RoutingMetrics {
    struct Snapshot: Sendable {
        var currentTCPConnectionCount: Int = 0
        var currentTCPChannelCount: Int = 0
        var tcpChannelActiveCount: Int = 0
        var tcpChannelInactiveCount: Int = 0
        var tcpAuthReceivedCount: Int = 0
        var tcpAuthOKCount: Int = 0
        var tcpAuthErrorCount: Int = 0
        var tcpKickCount: Int = 0
        var tcpIdleTimeoutCount: Int = 0
        var tcpErrorCaughtCount: Int = 0
        var tcpCloseAuthTimeoutCount: Int = 0
        var tcpCloseIdleTimeoutCount: Int = 0
        var tcpCloseAuthErrorCount: Int = 0
        var tcpCloseKickCount: Int = 0
        var tcpCloseErrorCount: Int = 0
        var tcpClosePeerOrUnknownCount: Int = 0
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
        var realtimeDeliveryMissingRowCount: Int = 0
        var invalidRealtimeDeliveryPayloadCount: Int = 0
    }

    private var snapshot = Snapshot()

    func recordPresenceRegistration() {
        snapshot.redisRouteRegistrations += 1
    }

    func recordCurrentTCPConnectionCount(_ count: Int) {
        snapshot.currentTCPConnectionCount = count
    }

    func recordTCPChannelActive() {
        snapshot.currentTCPChannelCount += 1
        snapshot.tcpChannelActiveCount += 1
    }

    func recordTCPChannelInactive(closeReason: String?) {
        snapshot.currentTCPChannelCount = max(0, snapshot.currentTCPChannelCount - 1)
        snapshot.tcpChannelInactiveCount += 1

        switch closeReason {
        case "auth_timeout":
            snapshot.tcpCloseAuthTimeoutCount += 1
        case "idle_timeout":
            snapshot.tcpCloseIdleTimeoutCount += 1
        case "auth_error":
            snapshot.tcpCloseAuthErrorCount += 1
        case let reason? where reason.hasPrefix("kick"):
            snapshot.tcpCloseKickCount += 1
        case let reason? where reason.hasPrefix("error"):
            snapshot.tcpCloseErrorCount += 1
        default:
            snapshot.tcpClosePeerOrUnknownCount += 1
        }
    }

    func recordTCPAuthReceived() {
        snapshot.tcpAuthReceivedCount += 1
    }

    func recordTCPAuthOKSent() {
        snapshot.tcpAuthOKCount += 1
    }

    func recordTCPAuthErrorSent() {
        snapshot.tcpAuthErrorCount += 1
    }

    func recordTCPKickSent() {
        snapshot.tcpKickCount += 1
    }

    func recordTCPIdleTimeout() {
        snapshot.tcpIdleTimeoutCount += 1
    }

    func recordTCPErrorCaught() {
        snapshot.tcpErrorCaughtCount += 1
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

    func recordRealtimeDeliveryMissingRow() {
        snapshot.realtimeDeliveryMissingRowCount += 1
    }

    func recordInvalidRealtimeDeliveryPayload() {
        snapshot.invalidRealtimeDeliveryPayloadCount += 1
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
