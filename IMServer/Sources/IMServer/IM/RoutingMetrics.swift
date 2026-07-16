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
        var tcpCloseInputClosedCount: Int = 0
        var tcpCloseResetByPeerCount: Int = 0
        var tcpCloseSlowWriteCount: Int = 0
        var tcpCloseConnectionLimitCount: Int = 0
        var tcpCloseConnectionRateLimitCount: Int = 0
        var tcpCloseGatewayDrainingCount: Int = 0
        var tcpClosePeerWaitingForAuthCount: Int = 0
        var tcpClosePeerAuthenticatingCount: Int = 0
        var tcpClosePeerAuthenticatedCount: Int = 0
        var tcpClosePeerOrUnknownCount: Int = 0
        var tcpWriteCompletionCount: Int = 0
        var tcpWriteFailureCount: Int = 0
        var tcpWriteBackpressureCount: Int = 0
        var tcpWriteDroppedBackpressureCount: Int = 0
        var tcpWriteSlowCount: Int = 0
        var tcpWriteSlowTotalLatencyMillis: Int = 0
        var tcpWriteSlowMaxLatencyMillis: Int = 0
        var tcpWriteSlowConnectionClosedCount: Int = 0
        var tcpAdmissionRejectedCount: Int = 0
        var tcpAdmissionRateLimitedCount: Int = 0
        var tcpAdmissionDrainingRejectedCount: Int = 0
        var tcpWriteTotalLatencyMillis: Int = 0
        var tcpWriteMaxLatencyMillis: Int = 0
        var userFanoutCount: Int = 0
        var sessionKickCount: Int = 0
        var sessionCountQueryFailureCount: Int = 0
        var redisRouteRegistrations: Int = 0
        var crossNodeDispatchCount: Int = 0
        var crossNodeDispatchFailureCount: Int = 0
        var crossNodeDispatchAttemptCount: Int = 0
        var crossNodeDispatchTargetCount: Int = 0
        var crossNodeDispatchMaxTargetsPerPacket: Int = 0
        var crossNodeDispatchTotalLatencyMillis: Int = 0
        var crossNodeDispatchMaxLatencyMillis: Int = 0
        var crossCellDispatchAttemptCount: Int = 0
        var crossCellDispatchSuccessCount: Int = 0
        var crossCellDispatchFailureCount: Int = 0
        var crossCellDispatchRecipientCount: Int = 0
        var crossCellDispatchTotalLatencyMillis: Int = 0
        var crossCellDispatchMaxLatencyMillis: Int = 0
        var remoteDomainEventEncodedPacketCount: Int = 0
        var remoteDomainEventEncodeCacheHitCount: Int = 0
        var remoteDomainEventEncodedPacketBytes: Int = 0
        var remoteDomainEventMaxEncodedPacketBytes: Int = 0
        var gatewayHTTPRelayWorkItemCount: Int = 0
        var gatewayHTTPRelayPayloadBatchCount: Int = 0
        var gatewayHTTPRelayRecipientCount: Int = 0
        var gatewayHTTPRelaySkippedRecipientCount: Int = 0
        var gatewayHTTPRelayEncodedPayloadBytes: Int = 0
        var gatewayHTTPRelayMaxRecipientsPerWorkItem: Int = 0
        var gatewayHTTPRelayRequestAttemptCount: Int = 0
        var gatewayHTTPRelayRequestSuccessCount: Int = 0
        var gatewayHTTPRelayRequestFailureCount: Int = 0
        var gatewayHTTPRelayRequestTotalLatencyMillis: Int = 0
        var gatewayHTTPRelayRequestMaxLatencyMillis: Int = 0
        var gatewayHTTPRelayRequestBodyBytes: Int = 0
        var gatewayHTTPRelayRequestMaxBodyBytes: Int = 0
        var gatewayHTTPRelayBinaryFallbackCount: Int = 0
        var gatewayHTTPRelayInboundRequestCount: Int = 0
        var gatewayHTTPRelayInboundSuccessCount: Int = 0
        var gatewayHTTPRelayInboundFailureCount: Int = 0
        var gatewayHTTPRelayInboundBodyBytes: Int = 0
        var gatewayHTTPRelayInboundMaxBodyBytes: Int = 0
        var gatewayHTTPRelayInboundTotalLatencyMillis: Int = 0
        var gatewayHTTPRelayInboundMaxLatencyMillis: Int = 0
        var realtimePayloadBuiltCount: Int = 0
        var realtimePayloadRecipientDeliveryCount: Int = 0
        var realtimePayloadWithConversationSummaryCount: Int = 0
        var realtimePayloadConversationSummaryMemberIDsOmittedCount: Int = 0
        var realtimePayloadConversationSummaryMemberIDsOmittedTotalMembers: Int = 0
        var realtimePayloadConversationSummaryMemberIDsEmittedCount: Int = 0
        var realtimePayloadConversationSummaryMemberIDsEmittedTotalMembers: Int = 0
        var localFanoutPacketCount: Int = 0
        var localFanoutTargetConnectionCount: Int = 0
        var localFanoutMaxTargetConnectionsPerPacket: Int = 0
        var localFanoutEventLoopJobCount: Int = 0
        var localFanoutChunkCount: Int = 0
        var localFanoutMaxChunksPerEventLoopJob: Int = 0
        var localFanoutEncodedPacketCount: Int = 0
        var localFanoutEncodeCacheHitCount: Int = 0
        var localFanoutEncodeFailureCount: Int = 0
        var localFanoutEncodedPacketBytes: Int = 0
        var localFanoutMaxEncodedPacketBytes: Int = 0
        var localFanoutEstimatedOutboundBytes: Int = 0
        var localFanoutMaxEstimatedOutboundBytesPerPacket: Int = 0
        var localFanoutEventLoopJobStartedCount: Int = 0
        var localFanoutEventLoopJobStartLagTotalMillis: Int = 0
        var localFanoutEventLoopJobStartLagMaxMillis: Int = 0
        var localFanoutBatchSize: Int = 0
        var realtimeActiveConversationFanoutSplitCount: Int = 0
        var realtimeActiveConversationFanoutActiveRecipientCount: Int = 0
        var realtimeActiveConversationFanoutCompactActiveRecipientCount: Int = 0
        var realtimeActiveConversationFanoutInactiveHintRecipientCount: Int = 0
        var realtimeActiveConversationFanoutDowngradedActiveRecipientCount: Int = 0
        var realtimeActiveConversationFanoutBackpressureDowngradedRecipientCount: Int = 0
        var realtimeActiveConversationFanoutRouteSplitDropCount: Int = 0
        var realtimeActiveConversationFanoutRouteSplitDropRecipientCount: Int = 0
        var realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit: Int = 0
        var realtimeActiveConversationFanoutMaxCompactActiveRecipientsPerSplit: Int = 0
        var realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit: Int = 0
        var realtimeActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit: Int = 0
        var realtimeActiveConversationRouteCacheHitCount: Int = 0
        var realtimeActiveConversationRouteCachePartialHitCount: Int = 0
        var realtimeActiveConversationRouteCacheMissCount: Int = 0
        var realtimeActiveConversationRouteCacheCachedUserCount: Int = 0
        var realtimeActiveConversationRouteCacheMissedUserCount: Int = 0
        var realtimeActiveConversationRouteCacheJoinedInFlightCount: Int = 0
        var realtimeRemoteActiveConversationFanoutSplitCount: Int = 0
        var realtimeRemoteActiveConversationFanoutFullRecipientCount: Int = 0
        var realtimeRemoteActiveConversationFanoutCompactRecipientCount: Int = 0
        var realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount: Int = 0
        var realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount: Int = 0
        var realtimeRemoteActiveConversationFanoutRouteSplitDropCount: Int = 0
        var realtimeRemoteActiveConversationFanoutRouteSplitDropRecipientCount: Int = 0
        var realtimeRemoteActiveConversationFanoutMaxFullRecipientsPerSplit: Int = 0
        var realtimeRemoteActiveConversationFanoutMaxCompactRecipientsPerSplit: Int = 0
        var realtimeRemoteActiveConversationFanoutMaxInactiveHintRecipientsPerSplit: Int = 0
        var realtimeRemoteActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit: Int = 0
        var realtimeInactiveConversationHintFlushCount: Int = 0
        var realtimeInactiveConversationHintPayloadBatchCount: Int = 0
        var realtimeInactiveConversationHintRecipientCount: Int = 0
        var realtimeInactiveConversationHintSuppressedRecipientCount: Int = 0
        var realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount: Int = 0
        var realtimeDeliveryConsumerInactiveHintRelayRecipientCount: Int = 0
        var realtimeDeliveryConsumerInactiveHintSuppressedRecipientCount: Int = 0
        var domainRelayAfterRecordPreSplitCount: Int = 0
        var domainRelayAfterRecordPreSplitActiveRecipientCount: Int = 0
        var domainRelayAfterRecordPreSplitCompactActiveRecipientCount: Int = 0
        var domainRelayAfterRecordPreSplitInactiveHintRecipientCount: Int = 0
        var domainRelayAfterRecordPreSplitDowngradedActiveRecipientCount: Int = 0
        var domainRelayAfterRecordPreSplitRouteDropCount: Int = 0
        var domainRelayAfterRecordInactiveHintSuppressedRecipientCount: Int = 0
        var domainRelayAfterRecordActiveRouteCacheHitCount: Int = 0
        var domainRelayAfterRecordActiveRouteCachePartialHitCount: Int = 0
        var domainRelayAfterRecordActiveRouteCacheMissCount: Int = 0
        var domainRelayAfterRecordActiveRouteCacheCachedUserCount: Int = 0
        var domainRelayAfterRecordActiveRouteCacheMissedUserCount: Int = 0
        var domainRelayAfterRecordActiveRouteCacheJoinedInFlightCount: Int = 0
        var domainRelayAfterRecordPreSplitMaxActiveRecipients: Int = 0
        var domainRelayAfterRecordPreSplitMaxCompactActiveRecipients: Int = 0
        var domainRelayAfterRecordPreSplitMaxInactiveHintRecipients: Int = 0
        var domainRelayAfterRecordPreSplitMaxDowngradedActiveRecipients: Int = 0
        var realtimeCoalescedDispatchReplacementCount: Int = 0
        var realtimeCoalescedDroppedPayloadBatchCount: Int = 0
        var realtimeCoalescedDroppedRecipientDeliveryCount: Int = 0
        var realtimeAsyncRelayDroppedDispatchCount: Int = 0
        var realtimeAsyncRelayDroppedPayloadBatchCount: Int = 0
        var realtimeAsyncRelayDroppedRecipientDeliveryCount: Int = 0
        var realtimeAsyncRelayQueueSaturationCount: Int = 0
        var realtimeAsyncRelayQueuedWaiterCount: Int = 0
        var realtimeAsyncRelayMaxQueuedWaiters: Int = 0
        var realtimeAsyncRelayTaskStartedCount: Int = 0
        var realtimeAsyncRelayTaskCompletedCount: Int = 0
        var realtimeAsyncRelayCurrentInFlightCount: Int = 0
        var realtimeAsyncRelayMaxInFlightCount: Int = 0
        var realtimeAsyncRelayTaskStartLagTotalMillis: Int = 0
        var realtimeAsyncRelayTaskStartLagMaxMillis: Int = 0
        var realtimeAsyncRelayLatencyTotalMillis: Int = 0
        var realtimeAsyncRelayLatencyMaxMillis: Int = 0
        var redisPresenceRouteCacheHits: Int = 0
        var redisPresenceRouteCacheMisses: Int = 0
        var redisPresencePipelineLookupCount: Int = 0
        var redisPresencePipelineLookupUserCount: Int = 0
        var redisPresenceActiveConversationNodeIndexLookupCount: Int = 0
        var redisPresenceActiveConversationNodeIndexLookupNodeCount: Int = 0
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

    func recordTCPChannelInactive(closeReason: String?, state: String) {
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
        case let reason? where reason == "peer_input_closed":
            snapshot.tcpCloseInputClosedCount += 1
            recordPeerCloseState(state)
        case let reason? where reason == "error:connection_reset":
            snapshot.tcpCloseResetByPeerCount += 1
            snapshot.tcpCloseErrorCount += 1
        case let reason? where reason == "slow_write":
            snapshot.tcpCloseSlowWriteCount += 1
        case let reason? where reason == "connection_limit":
            snapshot.tcpCloseConnectionLimitCount += 1
        case let reason? where reason == "connection_rate_limit":
            snapshot.tcpCloseConnectionRateLimitCount += 1
        case let reason? where reason == "gateway_draining":
            snapshot.tcpCloseGatewayDrainingCount += 1
        case let reason? where reason.hasPrefix("error"):
            snapshot.tcpCloseErrorCount += 1
        default:
            recordPeerCloseState(state)
            snapshot.tcpClosePeerOrUnknownCount += 1
        }
    }

    private func recordPeerCloseState(_ state: String) {
        switch state {
        case "waitingForAuth":
            snapshot.tcpClosePeerWaitingForAuthCount += 1
        case "authenticating":
            snapshot.tcpClosePeerAuthenticatingCount += 1
        case "authenticated":
            snapshot.tcpClosePeerAuthenticatedCount += 1
        default:
            break
        }
    }

    func recordTCPAuthReceived() {
        snapshot.tcpAuthReceivedCount += 1
    }

    func recordTCPAdmissionRejected(reason: IMTCPAdmissionController.RejectionReason) {
        snapshot.tcpAdmissionRejectedCount += 1
        if reason == .connectionRateLimit {
            snapshot.tcpAdmissionRateLimitedCount += 1
        }
        if reason == .gatewayDraining {
            snapshot.tcpAdmissionDrainingRejectedCount += 1
        }
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

    func recordTCPWriteCompleted(latencyMilliseconds: Int) {
        let latency = max(0, latencyMilliseconds)
        snapshot.tcpWriteCompletionCount += 1
        snapshot.tcpWriteTotalLatencyMillis += latency
        snapshot.tcpWriteMaxLatencyMillis = max(snapshot.tcpWriteMaxLatencyMillis, latency)
    }

    func recordTCPWriteFailed(latencyMilliseconds: Int) {
        let latency = max(0, latencyMilliseconds)
        snapshot.tcpWriteFailureCount += 1
        snapshot.tcpWriteTotalLatencyMillis += latency
        snapshot.tcpWriteMaxLatencyMillis = max(snapshot.tcpWriteMaxLatencyMillis, latency)
    }

    func recordTCPWriteBackpressure() {
        snapshot.tcpWriteBackpressureCount += 1
    }

    func recordTCPWriteDroppedBackpressure() {
        snapshot.tcpWriteDroppedBackpressureCount += 1
    }

    func recordTCPWriteSlow(latencyMilliseconds: Int) {
        let latency = max(0, latencyMilliseconds)
        snapshot.tcpWriteSlowCount += 1
        snapshot.tcpWriteSlowTotalLatencyMillis += latency
        snapshot.tcpWriteSlowMaxLatencyMillis = max(snapshot.tcpWriteSlowMaxLatencyMillis, latency)
    }

    func recordTCPWriteSlowConnectionClosed() {
        snapshot.tcpWriteSlowConnectionClosedCount += 1
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

    func recordCrossNodeDispatchSucceeded(latencyMilliseconds: Int = 0) {
        snapshot.crossNodeDispatchCount += 1
        recordCrossNodeDispatchLatency(latencyMilliseconds)
    }

    func recordCrossNodeDispatchFailed(latencyMilliseconds: Int = 0) {
        snapshot.crossNodeDispatchFailureCount += 1
        recordCrossNodeDispatchLatency(latencyMilliseconds)
    }

    func recordCrossNodeDispatchAttempt(targetCount: Int) {
        let count = max(0, targetCount)
        snapshot.crossNodeDispatchAttemptCount += 1
        snapshot.crossNodeDispatchTargetCount += count
        snapshot.crossNodeDispatchMaxTargetsPerPacket = max(
            snapshot.crossNodeDispatchMaxTargetsPerPacket,
            count
        )
    }

    private func recordCrossNodeDispatchLatency(_ latencyMilliseconds: Int) {
        let latency = max(0, latencyMilliseconds)
        snapshot.crossNodeDispatchTotalLatencyMillis += latency
        snapshot.crossNodeDispatchMaxLatencyMillis = max(snapshot.crossNodeDispatchMaxLatencyMillis, latency)
    }

    func recordCrossCellDispatchAttempt(recipientCount: Int) {
        snapshot.crossCellDispatchAttemptCount += 1
        snapshot.crossCellDispatchRecipientCount += max(0, recipientCount)
    }

    func recordCrossCellDispatchSucceeded(latencyMilliseconds: Int) {
        snapshot.crossCellDispatchSuccessCount += 1
        recordCrossCellDispatchLatency(latencyMilliseconds)
    }

    func recordCrossCellDispatchFailed(latencyMilliseconds: Int) {
        snapshot.crossCellDispatchFailureCount += 1
        recordCrossCellDispatchLatency(latencyMilliseconds)
    }

    private func recordCrossCellDispatchLatency(_ latencyMilliseconds: Int) {
        let latency = max(0, latencyMilliseconds)
        snapshot.crossCellDispatchTotalLatencyMillis += latency
        snapshot.crossCellDispatchMaxLatencyMillis = max(snapshot.crossCellDispatchMaxLatencyMillis, latency)
    }

    func recordRemoteDomainEventPacketEncoding(
        encodedPacketCount: Int,
        encodeCacheHitCount: Int,
        encodedPacketBytes: Int = 0,
        maxEncodedPacketBytes: Int = 0
    ) {
        snapshot.remoteDomainEventEncodedPacketCount += max(0, encodedPacketCount)
        snapshot.remoteDomainEventEncodeCacheHitCount += max(0, encodeCacheHitCount)
        snapshot.remoteDomainEventEncodedPacketBytes += max(0, encodedPacketBytes)
        snapshot.remoteDomainEventMaxEncodedPacketBytes = max(
            snapshot.remoteDomainEventMaxEncodedPacketBytes,
            max(0, maxEncodedPacketBytes)
        )
    }

    func recordGatewayHTTPRelay(
        workItemCount: Int,
        payloadBatchCount: Int,
        recipientCount: Int,
        skippedRecipientCount: Int,
        encodedPayloadBytes: Int,
        maxRecipientsPerWorkItem: Int
    ) {
        snapshot.gatewayHTTPRelayWorkItemCount += max(0, workItemCount)
        snapshot.gatewayHTTPRelayPayloadBatchCount += max(0, payloadBatchCount)
        snapshot.gatewayHTTPRelayRecipientCount += max(0, recipientCount)
        snapshot.gatewayHTTPRelaySkippedRecipientCount += max(0, skippedRecipientCount)
        snapshot.gatewayHTTPRelayEncodedPayloadBytes += max(0, encodedPayloadBytes)
        snapshot.gatewayHTTPRelayMaxRecipientsPerWorkItem = max(
            snapshot.gatewayHTTPRelayMaxRecipientsPerWorkItem,
            max(0, maxRecipientsPerWorkItem)
        )
    }

    func recordGatewayHTTPRelayRequest(
        didSucceed: Bool,
        latencyMilliseconds: Int,
        bodyBytes: Int = 0
    ) {
        let latency = max(0, latencyMilliseconds)
        let safeBodyBytes = max(0, bodyBytes)
        snapshot.gatewayHTTPRelayRequestAttemptCount += 1
        if didSucceed {
            snapshot.gatewayHTTPRelayRequestSuccessCount += 1
        } else {
            snapshot.gatewayHTTPRelayRequestFailureCount += 1
        }
        snapshot.gatewayHTTPRelayRequestTotalLatencyMillis += latency
        snapshot.gatewayHTTPRelayRequestMaxLatencyMillis = max(
            snapshot.gatewayHTTPRelayRequestMaxLatencyMillis,
            latency
        )
        snapshot.gatewayHTTPRelayRequestBodyBytes += safeBodyBytes
        snapshot.gatewayHTTPRelayRequestMaxBodyBytes = max(
            snapshot.gatewayHTTPRelayRequestMaxBodyBytes,
            safeBodyBytes
        )
    }

    func recordGatewayHTTPRelayBinaryFallback() {
        snapshot.gatewayHTTPRelayBinaryFallbackCount += 1
    }

    func recordGatewayHTTPRelayInboundRequest(
        statusCode: Int,
        durationMilliseconds: Int,
        bodyBytes: Int
    ) {
        let safeBodyBytes = max(0, bodyBytes)
        let safeDuration = max(0, durationMilliseconds)
        snapshot.gatewayHTTPRelayInboundRequestCount += 1
        if statusCode >= 200 && statusCode < 400 {
            snapshot.gatewayHTTPRelayInboundSuccessCount += 1
        } else {
            snapshot.gatewayHTTPRelayInboundFailureCount += 1
        }
        snapshot.gatewayHTTPRelayInboundBodyBytes += safeBodyBytes
        snapshot.gatewayHTTPRelayInboundMaxBodyBytes = max(
            snapshot.gatewayHTTPRelayInboundMaxBodyBytes,
            safeBodyBytes
        )
        snapshot.gatewayHTTPRelayInboundTotalLatencyMillis += safeDuration
        snapshot.gatewayHTTPRelayInboundMaxLatencyMillis = max(
            snapshot.gatewayHTTPRelayInboundMaxLatencyMillis,
            safeDuration
        )
    }

    func recordRealtimePayloadBuilt(
        payloadCount: Int,
        recipientDeliveryCount: Int,
        conversationSummaryCount: Int,
        omittedSummaryMemberIDPayloadCount: Int,
        omittedSummaryMemberIDTotalMembers: Int,
        emittedSummaryMemberIDPayloadCount: Int,
        emittedSummaryMemberIDTotalMembers: Int
    ) {
        snapshot.realtimePayloadBuiltCount += max(0, payloadCount)
        snapshot.realtimePayloadRecipientDeliveryCount += max(0, recipientDeliveryCount)
        snapshot.realtimePayloadWithConversationSummaryCount += max(0, conversationSummaryCount)
        snapshot.realtimePayloadConversationSummaryMemberIDsOmittedCount += max(0, omittedSummaryMemberIDPayloadCount)
        snapshot.realtimePayloadConversationSummaryMemberIDsOmittedTotalMembers += max(
            0,
            omittedSummaryMemberIDTotalMembers
        )
        snapshot.realtimePayloadConversationSummaryMemberIDsEmittedCount += max(0, emittedSummaryMemberIDPayloadCount)
        snapshot.realtimePayloadConversationSummaryMemberIDsEmittedTotalMembers += max(
            0,
            emittedSummaryMemberIDTotalMembers
        )
    }

    func recordLocalFanout(
        packetCount: Int,
        targetConnectionCount: Int,
        maxTargetConnectionsPerPacket: Int,
        eventLoopJobCount: Int,
        chunkCount: Int = 0,
        maxChunksPerEventLoopJob: Int = 0,
        batchSize: Int,
        encodedPacketCount: Int = 0,
        encodeCacheHitCount: Int = 0,
        encodedPacketBytes: Int = 0,
        maxEncodedPacketBytes: Int = 0,
        estimatedOutboundBytes: Int = 0,
        maxEstimatedOutboundBytesPerPacket: Int = 0
    ) {
        snapshot.localFanoutPacketCount += max(0, packetCount)
        snapshot.localFanoutTargetConnectionCount += max(0, targetConnectionCount)
        snapshot.localFanoutMaxTargetConnectionsPerPacket = max(
            snapshot.localFanoutMaxTargetConnectionsPerPacket,
            max(0, maxTargetConnectionsPerPacket)
        )
        snapshot.localFanoutEventLoopJobCount += max(0, eventLoopJobCount)
        snapshot.localFanoutChunkCount += max(0, chunkCount)
        snapshot.localFanoutMaxChunksPerEventLoopJob = max(
            snapshot.localFanoutMaxChunksPerEventLoopJob,
            max(0, maxChunksPerEventLoopJob)
        )
        snapshot.localFanoutEncodedPacketCount += max(0, encodedPacketCount)
        snapshot.localFanoutEncodeCacheHitCount += max(0, encodeCacheHitCount)
        snapshot.localFanoutEncodedPacketBytes += max(0, encodedPacketBytes)
        snapshot.localFanoutMaxEncodedPacketBytes = max(
            snapshot.localFanoutMaxEncodedPacketBytes,
            max(0, maxEncodedPacketBytes)
        )
        snapshot.localFanoutEstimatedOutboundBytes += max(0, estimatedOutboundBytes)
        snapshot.localFanoutMaxEstimatedOutboundBytesPerPacket = max(
            snapshot.localFanoutMaxEstimatedOutboundBytesPerPacket,
            max(0, maxEstimatedOutboundBytesPerPacket)
        )
        snapshot.localFanoutBatchSize = max(0, batchSize)
    }

    func recordLocalFanoutEncodeFailure(count: Int = 1) {
        snapshot.localFanoutEncodeFailureCount += max(0, count)
    }

    func recordLocalFanoutEventLoopJobStarted(startLagMilliseconds: Int) {
        let safeLag = max(0, startLagMilliseconds)
        snapshot.localFanoutEventLoopJobStartedCount += 1
        snapshot.localFanoutEventLoopJobStartLagTotalMillis += safeLag
        snapshot.localFanoutEventLoopJobStartLagMaxMillis = max(
            snapshot.localFanoutEventLoopJobStartLagMaxMillis,
            safeLag
        )
    }

    func recordActiveConversationFanoutSplit(
        activeRecipientCount: Int,
        compactActiveRecipientCount: Int = 0,
        inactiveHintRecipientCount: Int,
        downgradedActiveRecipientCount: Int = 0,
        backpressureDowngradedActiveRecipientCount: Int = 0
    ) {
        let activeCount = max(0, activeRecipientCount)
        let compactActiveCount = max(0, compactActiveRecipientCount)
        let inactiveCount = max(0, inactiveHintRecipientCount)
        let downgradedCount = max(0, downgradedActiveRecipientCount)
        let backpressureDowngradedCount = max(0, backpressureDowngradedActiveRecipientCount)
        snapshot.realtimeActiveConversationFanoutSplitCount += 1
        snapshot.realtimeActiveConversationFanoutActiveRecipientCount += activeCount
        snapshot.realtimeActiveConversationFanoutCompactActiveRecipientCount += compactActiveCount
        snapshot.realtimeActiveConversationFanoutInactiveHintRecipientCount += inactiveCount
        snapshot.realtimeActiveConversationFanoutDowngradedActiveRecipientCount += downgradedCount
        snapshot.realtimeActiveConversationFanoutBackpressureDowngradedRecipientCount += backpressureDowngradedCount
        snapshot.realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit = max(
            snapshot.realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit,
            activeCount
        )
        snapshot.realtimeActiveConversationFanoutMaxCompactActiveRecipientsPerSplit = max(
            snapshot.realtimeActiveConversationFanoutMaxCompactActiveRecipientsPerSplit,
            compactActiveCount
        )
        snapshot.realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit = max(
            snapshot.realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit,
            inactiveCount
        )
        snapshot.realtimeActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit = max(
            snapshot.realtimeActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit,
            downgradedCount
        )
    }

    func recordActiveConversationFanoutRouteSplitDrop(recipientCount: Int) {
        snapshot.realtimeActiveConversationFanoutRouteSplitDropCount += 1
        snapshot.realtimeActiveConversationFanoutRouteSplitDropRecipientCount += max(0, recipientCount)
    }

    func recordRemoteActiveConversationFanoutSplit(
        fullRecipientCount: Int,
        compactRecipientCount: Int = 0,
        inactiveHintRecipientCount: Int,
        downgradedActiveRecipientCount: Int
    ) {
        let fullCount = max(0, fullRecipientCount)
        let compactCount = max(0, compactRecipientCount)
        let inactiveCount = max(0, inactiveHintRecipientCount)
        let downgradedCount = max(0, downgradedActiveRecipientCount)
        snapshot.realtimeRemoteActiveConversationFanoutSplitCount += 1
        snapshot.realtimeRemoteActiveConversationFanoutFullRecipientCount += fullCount
        snapshot.realtimeRemoteActiveConversationFanoutCompactRecipientCount += compactCount
        snapshot.realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount += inactiveCount
        snapshot.realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount += downgradedCount
        snapshot.realtimeRemoteActiveConversationFanoutMaxFullRecipientsPerSplit = max(
            snapshot.realtimeRemoteActiveConversationFanoutMaxFullRecipientsPerSplit,
            fullCount
        )
        snapshot.realtimeRemoteActiveConversationFanoutMaxCompactRecipientsPerSplit = max(
            snapshot.realtimeRemoteActiveConversationFanoutMaxCompactRecipientsPerSplit,
            compactCount
        )
        snapshot.realtimeRemoteActiveConversationFanoutMaxInactiveHintRecipientsPerSplit = max(
            snapshot.realtimeRemoteActiveConversationFanoutMaxInactiveHintRecipientsPerSplit,
            inactiveCount
        )
        snapshot.realtimeRemoteActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit = max(
            snapshot.realtimeRemoteActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit,
            downgradedCount
        )
    }

    func recordRemoteActiveConversationFanoutRouteSplitDrop(recipientCount: Int) {
        snapshot.realtimeRemoteActiveConversationFanoutRouteSplitDropCount += 1
        snapshot.realtimeRemoteActiveConversationFanoutRouteSplitDropRecipientCount += max(0, recipientCount)
    }

    func recordInactiveConversationHintFlush(
        payloadBatchCount: Int,
        recipientCount: Int
    ) {
        snapshot.realtimeInactiveConversationHintFlushCount += 1
        snapshot.realtimeInactiveConversationHintPayloadBatchCount += max(0, payloadBatchCount)
        snapshot.realtimeInactiveConversationHintRecipientCount += max(0, recipientCount)
    }

    func recordInactiveConversationHintSuppressed(recipientCount: Int) {
        snapshot.realtimeInactiveConversationHintSuppressedRecipientCount += max(0, recipientCount)
    }

    func recordRealtimeDeliveryConsumerInactiveHintRelay(
        payloadBatchCount: Int,
        recipientCount: Int,
        suppressedRecipientCount: Int
    ) {
        snapshot.realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount += max(0, payloadBatchCount)
        snapshot.realtimeDeliveryConsumerInactiveHintRelayRecipientCount += max(0, recipientCount)
        snapshot.realtimeDeliveryConsumerInactiveHintSuppressedRecipientCount += max(0, suppressedRecipientCount)
    }

    func recordDomainRelayAfterRecordPreSplit(
        activeRecipientCount: Int,
        compactActiveRecipientCount: Int = 0,
        inactiveHintRecipientCount: Int,
        downgradedActiveRecipientCount: Int
    ) {
        let activeCount = max(0, activeRecipientCount)
        let compactActiveCount = max(0, compactActiveRecipientCount)
        let inactiveCount = max(0, inactiveHintRecipientCount)
        let downgradedCount = max(0, downgradedActiveRecipientCount)
        snapshot.domainRelayAfterRecordPreSplitCount += 1
        snapshot.domainRelayAfterRecordPreSplitActiveRecipientCount += activeCount
        snapshot.domainRelayAfterRecordPreSplitCompactActiveRecipientCount += compactActiveCount
        snapshot.domainRelayAfterRecordPreSplitInactiveHintRecipientCount += inactiveCount
        snapshot.domainRelayAfterRecordPreSplitDowngradedActiveRecipientCount += downgradedCount
        snapshot.domainRelayAfterRecordPreSplitMaxActiveRecipients = max(
            snapshot.domainRelayAfterRecordPreSplitMaxActiveRecipients,
            activeCount
        )
        snapshot.domainRelayAfterRecordPreSplitMaxCompactActiveRecipients = max(
            snapshot.domainRelayAfterRecordPreSplitMaxCompactActiveRecipients,
            compactActiveCount
        )
        snapshot.domainRelayAfterRecordPreSplitMaxInactiveHintRecipients = max(
            snapshot.domainRelayAfterRecordPreSplitMaxInactiveHintRecipients,
            inactiveCount
        )
        snapshot.domainRelayAfterRecordPreSplitMaxDowngradedActiveRecipients = max(
            snapshot.domainRelayAfterRecordPreSplitMaxDowngradedActiveRecipients,
            downgradedCount
        )
    }

    func recordDomainRelayAfterRecordPreSplitRouteDrop() {
        snapshot.domainRelayAfterRecordPreSplitRouteDropCount += 1
    }

    func recordDomainRelayAfterRecordInactiveHintCoalescing(suppressedRecipientCount: Int) {
        snapshot.domainRelayAfterRecordInactiveHintSuppressedRecipientCount += max(0, suppressedRecipientCount)
    }

    func recordDomainRelayAfterRecordActiveRouteCache(
        hit: Bool,
        partialHit: Bool = false,
        cachedUserCount: Int = 0,
        missedUserCount: Int = 0,
        joinedInFlight: Bool = false
    ) {
        if hit {
            snapshot.domainRelayAfterRecordActiveRouteCacheHitCount += 1
        } else if partialHit {
            snapshot.domainRelayAfterRecordActiveRouteCachePartialHitCount += 1
        } else {
            snapshot.domainRelayAfterRecordActiveRouteCacheMissCount += 1
        }
        snapshot.domainRelayAfterRecordActiveRouteCacheCachedUserCount += max(0, cachedUserCount)
        snapshot.domainRelayAfterRecordActiveRouteCacheMissedUserCount += max(0, missedUserCount)
        if joinedInFlight {
            snapshot.domainRelayAfterRecordActiveRouteCacheJoinedInFlightCount += 1
        }
    }

    func recordRealtimeActiveConversationRouteCache(
        hit: Bool,
        partialHit: Bool = false,
        cachedUserCount: Int = 0,
        missedUserCount: Int = 0,
        joinedInFlight: Bool = false
    ) {
        if hit {
            snapshot.realtimeActiveConversationRouteCacheHitCount += 1
        } else if partialHit {
            snapshot.realtimeActiveConversationRouteCachePartialHitCount += 1
        } else {
            snapshot.realtimeActiveConversationRouteCacheMissCount += 1
        }
        snapshot.realtimeActiveConversationRouteCacheCachedUserCount += max(0, cachedUserCount)
        snapshot.realtimeActiveConversationRouteCacheMissedUserCount += max(0, missedUserCount)
        if joinedInFlight {
            snapshot.realtimeActiveConversationRouteCacheJoinedInFlightCount += 1
        }
    }

    func recordRealtimeCoalescedDispatchReplacement(
        droppedPayloadBatchCount: Int,
        droppedRecipientDeliveryCount: Int
    ) {
        snapshot.realtimeCoalescedDispatchReplacementCount += 1
        snapshot.realtimeCoalescedDroppedPayloadBatchCount += max(0, droppedPayloadBatchCount)
        snapshot.realtimeCoalescedDroppedRecipientDeliveryCount += max(0, droppedRecipientDeliveryCount)
    }

    func recordRealtimeAsyncRelayDropped(
        payloadBatchCount: Int,
        recipientDeliveryCount: Int
    ) {
        snapshot.realtimeAsyncRelayDroppedDispatchCount += 1
        snapshot.realtimeAsyncRelayDroppedPayloadBatchCount += max(0, payloadBatchCount)
        snapshot.realtimeAsyncRelayDroppedRecipientDeliveryCount += max(0, recipientDeliveryCount)
        snapshot.realtimeAsyncRelayQueueSaturationCount += 1
    }

    func recordRealtimeAsyncRelayQueuedWaiters(_ count: Int) {
        let queueDepth = max(0, count)
        snapshot.realtimeAsyncRelayQueuedWaiterCount = queueDepth
        snapshot.realtimeAsyncRelayMaxQueuedWaiters = max(
            snapshot.realtimeAsyncRelayMaxQueuedWaiters,
            queueDepth
        )
    }

    func recordRealtimeAsyncRelayTaskStarted(taskStartLagMilliseconds: Int, inFlight: Int) {
        let taskStartLag = max(0, taskStartLagMilliseconds)
        let inFlightCount = max(0, inFlight)
        snapshot.realtimeAsyncRelayTaskStartedCount += 1
        snapshot.realtimeAsyncRelayCurrentInFlightCount = inFlightCount
        snapshot.realtimeAsyncRelayMaxInFlightCount = max(
            snapshot.realtimeAsyncRelayMaxInFlightCount,
            inFlightCount
        )
        snapshot.realtimeAsyncRelayTaskStartLagTotalMillis += taskStartLag
        snapshot.realtimeAsyncRelayTaskStartLagMaxMillis = max(
            snapshot.realtimeAsyncRelayTaskStartLagMaxMillis,
            taskStartLag
        )
    }

    func recordRealtimeAsyncRelayTaskCompleted(relayMilliseconds: Int, inFlight: Int) {
        let relayDuration = max(0, relayMilliseconds)
        let inFlightCount = max(0, inFlight)
        snapshot.realtimeAsyncRelayTaskCompletedCount += 1
        snapshot.realtimeAsyncRelayCurrentInFlightCount = inFlightCount
        snapshot.realtimeAsyncRelayLatencyTotalMillis += relayDuration
        snapshot.realtimeAsyncRelayLatencyMaxMillis = max(
            snapshot.realtimeAsyncRelayLatencyMaxMillis,
            relayDuration
        )
    }

    func recordRealtimeDeliveryMissingRow() {
        snapshot.realtimeDeliveryMissingRowCount += 1
    }

    func recordInvalidRealtimeDeliveryPayload() {
        snapshot.invalidRealtimeDeliveryPayloadCount += 1
    }

    func recordRedisPresenceRouteCacheHit(count: Int = 1) {
        snapshot.redisPresenceRouteCacheHits += max(0, count)
    }

    func recordRedisPresenceRouteCacheMiss(count: Int = 1) {
        snapshot.redisPresenceRouteCacheMisses += max(0, count)
    }

    func recordRedisPresencePipelineLookup(size: Int) {
        snapshot.redisPresencePipelineLookupCount += 1
        snapshot.redisPresencePipelineLookupUserCount += size
    }

    func recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: Int) {
        snapshot.redisPresenceActiveConversationNodeIndexLookupCount += 1
        snapshot.redisPresenceActiveConversationNodeIndexLookupNodeCount += max(0, nodeCount)
    }

    func recordRedisPresenceStaleCleanup(count: Int) {
        snapshot.redisPresenceStaleCleanupCount += count
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}
