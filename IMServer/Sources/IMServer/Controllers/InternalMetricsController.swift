import Vapor
import Fluent
import SQLKit

struct InternalMetricsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal").get("metrics", use: metrics)
    }

    func metrics(req: Request) async throws -> Response {
        let configuration = req.application.metricsConfiguration
        guard configuration.isEnabled else {
            throw Abort(.notFound)
        }
        guard configuration.allows(req: req) else {
            throw Abort(.unauthorized, reason: "Invalid internal metrics secret.")
        }

        let routing = await req.application.routingMetrics.currentSnapshot()
        let conversationShardRouting = await req.application.conversationShardRoutingMetrics.currentSnapshot()
        let conversationShardMigration = await req.application.conversationShardMigrationMetrics.currentSnapshot()
        let outbox = await req.application.outboxMetrics.currentSnapshot()
        let hotConversations = await req.application.hotConversationMetrics.currentSnapshot()
        let http = await req.application.httpMetrics.currentSnapshot()
        let database = await req.application.databaseMetrics.currentSnapshot()
        let stream = await req.application.streamMetrics.currentSnapshot()
        let streamGroups = await req.application.streamMetrics.currentGroupSnapshots()
        let aiStream = await req.application.aiStreamMetrics.currentSnapshot()
        let messageWrite = await req.application.messageWriteMetrics.currentSnapshot()
        let domainEvent = await req.application.conversationDomainEventMetrics.currentSnapshot()
        let summaryRead = await req.application.summaryReadMetrics.currentSnapshot()
        let timelineRead = await req.application.timelineReadMetrics.currentSnapshot()
        let authSessionCache = await req.application.authSessionCacheMetrics.currentSnapshot()
        let clientHealth = await req.application.clientHealthMetrics.currentSnapshot()
        let fanoutConfiguration = req.application.gatewayLocalFanoutConfiguration
        let streamConsumerConfiguration = req.application.streamConsumerConfiguration
        let nodeDispatchConfiguration = req.application.nodeDispatchConfiguration
        let tcpConfiguration = req.application.imTCPConfiguration
        let tcpAdmissionStatus = req.application.imTCPAdmissionController.status()
        let liveTCPConnectionCount = await req.application.imConnectionRegistry.totalConnectionCount()
        let liveLag = await collectLiveLagSnapshot(app: req.application)

        var lines: [String] = []
        appendCounter("im_http_requests_total", value: http.requestCount, to: &lines)
        appendCounter("im_http_request_failures_total", value: http.failedRequestCount, to: &lines)
        appendGauge("im_http_request_latency_avg_millis", value: http.averageLatencyMillis, to: &lines)
        appendGauge("im_http_request_latency_max_millis", value: http.maxLatencyMillis, to: &lines)
        appendGauge("im_tcp_connections", value: liveTCPConnectionCount, to: &lines)
        appendGauge("im_tcp_channels", value: routing.currentTCPChannelCount, to: &lines)
        appendGauge("im_gateway_draining", value: tcpAdmissionStatus.isDraining ? 1 : 0, to: &lines)
        appendGauge("im_tcp_admission_active_channels", value: tcpAdmissionStatus.activeConnectionCount, to: &lines)
        appendGauge(
            "im_tcp_configured_connection_limit",
            value: tcpConfiguration.maximumConnectionCount,
            to: &lines
        )
        appendGauge(
            "im_tcp_configured_new_connections_per_second_limit",
            value: tcpConfiguration.maximumNewConnectionsPerSecond,
            to: &lines
        )
        appendCounter("im_tcp_channel_active_total", value: routing.tcpChannelActiveCount, to: &lines)
        appendCounter("im_tcp_channel_inactive_total", value: routing.tcpChannelInactiveCount, to: &lines)
        appendCounter("im_tcp_admission_rejections_total", value: routing.tcpAdmissionRejectedCount, to: &lines)
        appendCounter("im_tcp_admission_rate_limited_total", value: routing.tcpAdmissionRateLimitedCount, to: &lines)
        appendCounter("im_tcp_admission_draining_rejected_total", value: routing.tcpAdmissionDrainingRejectedCount, to: &lines)
        appendCounter("im_tcp_auth_received_total", value: routing.tcpAuthReceivedCount, to: &lines)
        appendCounter("im_tcp_auth_ok_total", value: routing.tcpAuthOKCount, to: &lines)
        appendCounter("im_tcp_auth_error_total", value: routing.tcpAuthErrorCount, to: &lines)
        appendCounter("im_tcp_kick_total", value: routing.tcpKickCount, to: &lines)
        appendCounter("im_tcp_idle_timeout_total", value: routing.tcpIdleTimeoutCount, to: &lines)
        appendCounter("im_tcp_error_caught_total", value: routing.tcpErrorCaughtCount, to: &lines)
        appendCounter("im_tcp_close_auth_timeout_total", value: routing.tcpCloseAuthTimeoutCount, to: &lines)
        appendCounter("im_tcp_close_idle_timeout_total", value: routing.tcpCloseIdleTimeoutCount, to: &lines)
        appendCounter("im_tcp_close_auth_error_total", value: routing.tcpCloseAuthErrorCount, to: &lines)
        appendCounter("im_tcp_close_kick_total", value: routing.tcpCloseKickCount, to: &lines)
        appendCounter("im_tcp_close_error_total", value: routing.tcpCloseErrorCount, to: &lines)
        appendCounter("im_tcp_close_input_closed_total", value: routing.tcpCloseInputClosedCount, to: &lines)
        appendCounter("im_tcp_close_reset_by_peer_total", value: routing.tcpCloseResetByPeerCount, to: &lines)
        appendCounter("im_tcp_close_slow_write_total", value: routing.tcpCloseSlowWriteCount, to: &lines)
        appendCounter(
            "im_tcp_close_realtime_backpressure_total",
            value: routing.tcpCloseRealtimeBackpressureCount,
            to: &lines
        )
        appendCounter("im_tcp_close_connection_limit_total", value: routing.tcpCloseConnectionLimitCount, to: &lines)
        appendCounter("im_tcp_close_connection_rate_limit_total", value: routing.tcpCloseConnectionRateLimitCount, to: &lines)
        appendCounter("im_tcp_close_gateway_draining_total", value: routing.tcpCloseGatewayDrainingCount, to: &lines)
        appendCounter("im_tcp_close_peer_waiting_for_auth_total", value: routing.tcpClosePeerWaitingForAuthCount, to: &lines)
        appendCounter("im_tcp_close_peer_authenticating_total", value: routing.tcpClosePeerAuthenticatingCount, to: &lines)
        appendCounter("im_tcp_close_peer_authenticated_total", value: routing.tcpClosePeerAuthenticatedCount, to: &lines)
        appendCounter("im_tcp_close_peer_or_unknown_total", value: routing.tcpClosePeerOrUnknownCount, to: &lines)
        appendCounter("im_tcp_write_completions_total", value: routing.tcpWriteCompletionCount, to: &lines)
        appendCounter("im_tcp_write_failures_total", value: routing.tcpWriteFailureCount, to: &lines)
        appendCounter("im_tcp_write_backpressure_total", value: routing.tcpWriteBackpressureCount, to: &lines)
        appendCounter(
            "im_tcp_write_dropped_backpressure_total",
            value: routing.tcpWriteDroppedBackpressureCount,
            to: &lines
        )
        appendCounter("im_tcp_write_slow_total", value: routing.tcpWriteSlowCount, to: &lines)
        appendGauge(
            "im_tcp_write_latency_avg_millis",
            value: average(total: routing.tcpWriteTotalLatencyMillis, count: routing.tcpWriteCompletionCount + routing.tcpWriteFailureCount),
            to: &lines
        )
        appendGauge("im_tcp_write_latency_max_millis", value: routing.tcpWriteMaxLatencyMillis, to: &lines)
        appendGauge(
            "im_tcp_write_slow_latency_avg_millis",
            value: average(total: routing.tcpWriteSlowTotalLatencyMillis, count: routing.tcpWriteSlowCount),
            to: &lines
        )
        appendGauge("im_tcp_write_slow_latency_max_millis", value: routing.tcpWriteSlowMaxLatencyMillis, to: &lines)
        appendCounter(
            "im_tcp_write_slow_connection_closes_total",
            value: routing.tcpWriteSlowConnectionClosedCount,
            to: &lines
        )
        appendCounter("im_user_fanout_total", value: routing.userFanoutCount, to: &lines)
        appendCounter("im_session_kick_total", value: routing.sessionKickCount, to: &lines)
        appendCounter("im_session_count_query_failures_total", value: routing.sessionCountQueryFailureCount, to: &lines)
        appendCounter("im_auth_session_cache_hits_total", value: authSessionCache.hits, to: &lines)
        appendCounter("im_auth_session_cache_misses_total", value: authSessionCache.misses, to: &lines)
        appendCounter("im_auth_session_cache_stores_total", value: authSessionCache.stores, to: &lines)
        appendCounter("im_auth_session_cache_invalidations_total", value: authSessionCache.invalidations, to: &lines)
        appendCounter("im_auth_session_cache_redis_errors_total", value: authSessionCache.redisErrors, to: &lines)
        appendCounter("im_auth_session_cache_database_fallbacks_total", value: authSessionCache.databaseFallbacks, to: &lines)
        appendCounter("im_redis_route_registrations_total", value: routing.redisRouteRegistrations, to: &lines)
        appendCounter("im_conversation_shard_directory_cache_hits_total", value: conversationShardRouting.cacheHitCount, to: &lines)
        appendCounter("im_conversation_shard_directory_cache_misses_total", value: conversationShardRouting.cacheMissCount, to: &lines)
        appendCounter("im_conversation_shard_directory_cache_stores_total", value: conversationShardRouting.cacheStoreCount, to: &lines)
        appendCounter("im_conversation_shard_directory_cache_evictions_total", value: conversationShardRouting.cacheEvictionCount, to: &lines)
        appendCounter("im_conversation_shard_directory_lookups_total", value: conversationShardRouting.directoryLookupCount, to: &lines)
        appendCounter("im_conversation_shard_directory_lookup_failures_total", value: conversationShardRouting.directoryLookupFailureCount, to: &lines)
        appendCounter("im_conversation_shard_remote_cell_rejections_total", value: conversationShardRouting.remoteCellRouteRejectedCount, to: &lines)
        appendCounter("im_conversation_shard_remote_cell_forward_attempts_total", value: conversationShardRouting.remoteCellForwardAttemptCount, to: &lines)
        appendCounter("im_conversation_shard_remote_cell_forward_successes_total", value: conversationShardRouting.remoteCellForwardSuccessCount, to: &lines)
        appendCounter("im_conversation_shard_remote_cell_forward_failures_total", value: conversationShardRouting.remoteCellForwardFailureCount, to: &lines)
        appendCounter("im_conversation_shard_migration_copy_attempts_total", value: conversationShardMigration.copyAttemptCount, to: &lines)
        appendCounter("im_conversation_shard_migration_copy_successes_total", value: conversationShardMigration.copySuccessCount, to: &lines)
        appendCounter("im_conversation_shard_migration_copy_failures_total", value: conversationShardMigration.copyFailureCount, to: &lines)
        appendCounter("im_conversation_shard_migration_verify_attempts_total", value: conversationShardMigration.verifyAttemptCount, to: &lines)
        appendCounter("im_conversation_shard_migration_verify_successes_total", value: conversationShardMigration.verifySuccessCount, to: &lines)
        appendCounter("im_conversation_shard_migration_verify_failures_total", value: conversationShardMigration.verifyFailureCount, to: &lines)
        appendCounter("im_conversation_shard_migration_remote_pages_total", value: conversationShardMigration.remotePageAttemptCount, to: &lines)
        appendCounter("im_conversation_shard_migration_remote_page_successes_total", value: conversationShardMigration.remotePageSuccessCount, to: &lines)
        appendCounter("im_conversation_shard_migration_remote_page_failures_total", value: conversationShardMigration.remotePageFailureCount, to: &lines)
        appendCounter("im_conversation_shard_migration_remote_page_records_total", value: conversationShardMigration.remotePageRecordCount, to: &lines)
        appendCounter("im_conversation_shard_migration_remote_page_bytes_total", value: conversationShardMigration.remotePageByteCount, to: &lines)
        appendGauge(
            "im_conversation_shard_migration_remote_page_latency_avg_millis",
            value: average(
                total: conversationShardMigration.remotePageTotalMillis,
                count: conversationShardMigration.remotePageSuccessCount + conversationShardMigration.remotePageFailureCount
            ),
            to: &lines
        )
        appendGauge(
            "im_conversation_shard_migration_remote_page_latency_max_millis",
            value: conversationShardMigration.remotePageMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_conversation_shard_remote_cell_forward_latency_avg_millis",
            value: average(
                total: conversationShardRouting.remoteCellForwardTotalMillis,
                count: conversationShardRouting.remoteCellForwardLatencyCount
            ),
            to: &lines
        )
        appendGauge(
            "im_conversation_shard_remote_cell_forward_latency_max_millis",
            value: conversationShardRouting.remoteCellForwardMaxMillis,
            to: &lines
        )
        appendGauge("im_conversation_shard_directory_lookup_latency_avg_millis", value: average(total: conversationShardRouting.directoryLookupTotalMillis, count: conversationShardRouting.directoryLookupCount + conversationShardRouting.directoryLookupFailureCount), to: &lines)
        appendGauge("im_conversation_shard_directory_lookup_latency_max_millis", value: conversationShardRouting.directoryLookupMaxMillis, to: &lines)
        appendGauge("im_conversation_shard_directory_cache_entries", value: conversationShardRouting.cacheEntryCount, to: &lines)
        appendGauge("im_conversation_shard_directory_cache_max_entries", value: conversationShardRouting.cacheMaxEntries, to: &lines)
        appendCounter("im_redis_presence_route_cache_hits_total", value: routing.redisPresenceRouteCacheHits, to: &lines)
        appendCounter("im_redis_presence_route_cache_misses_total", value: routing.redisPresenceRouteCacheMisses, to: &lines)
        appendCounter("im_redis_presence_pipeline_lookups_total", value: routing.redisPresencePipelineLookupCount, to: &lines)
        appendCounter("im_redis_presence_pipeline_lookup_users_total", value: routing.redisPresencePipelineLookupUserCount, to: &lines)
        appendCounter(
            "im_redis_presence_active_conversation_node_index_lookups_total",
            value: routing.redisPresenceActiveConversationNodeIndexLookupCount,
            to: &lines
        )
        appendCounter(
            "im_redis_presence_active_conversation_node_index_lookup_nodes_total",
            value: routing.redisPresenceActiveConversationNodeIndexLookupNodeCount,
            to: &lines
        )
        appendCounter("im_redis_presence_stale_cleanup_total", value: routing.redisPresenceStaleCleanupCount, to: &lines)
        appendCounter("im_realtime_delivery_missing_row_total", value: routing.realtimeDeliveryMissingRowCount, to: &lines)
        appendCounter("im_realtime_delivery_invalid_payload_total", value: routing.invalidRealtimeDeliveryPayloadCount, to: &lines)
        appendCounter("im_cross_node_dispatch_total", value: routing.crossNodeDispatchCount, to: &lines)
        appendCounter("im_cross_node_dispatch_failures_total", value: routing.crossNodeDispatchFailureCount, to: &lines)
        appendCounter("im_cross_node_dispatch_attempts_total", value: routing.crossNodeDispatchAttemptCount, to: &lines)
        appendCounter("im_cross_node_dispatch_targets_total", value: routing.crossNodeDispatchTargetCount, to: &lines)
        appendCounter("im_durable_node_dispatch_enqueued_total", value: routing.durableNodeDispatchEnqueuedCount, to: &lines)
        appendCounter("im_durable_node_dispatch_acknowledged_total", value: routing.durableNodeDispatchAcknowledgedCount, to: &lines)
        appendCounter("im_durable_node_dispatch_retries_total", value: routing.durableNodeDispatchRetryCount, to: &lines)
        lines.append("im_node_dispatch_transport{transport=\"\(nodeDispatchConfiguration.mode.rawValue)\"} 1")
        appendGauge(
            "im_cross_node_dispatch_max_targets_per_packet",
            value: routing.crossNodeDispatchMaxTargetsPerPacket,
            to: &lines
        )
        appendGauge(
            "im_cross_node_dispatch_latency_avg_millis",
            value: average(
                total: routing.crossNodeDispatchTotalLatencyMillis,
                count: routing.crossNodeDispatchCount + routing.crossNodeDispatchFailureCount
            ),
            to: &lines
        )
        appendGauge(
            "im_cross_node_dispatch_latency_max_millis",
            value: routing.crossNodeDispatchMaxLatencyMillis,
            to: &lines
        )
        appendCounter("im_cross_cell_dispatch_attempts_total", value: routing.crossCellDispatchAttemptCount, to: &lines)
        appendCounter("im_cross_cell_dispatch_successes_total", value: routing.crossCellDispatchSuccessCount, to: &lines)
        appendCounter("im_cross_cell_dispatch_failures_total", value: routing.crossCellDispatchFailureCount, to: &lines)
        appendCounter("im_cross_cell_dispatch_recipients_total", value: routing.crossCellDispatchRecipientCount, to: &lines)
        appendGauge(
            "im_cross_cell_dispatch_latency_avg_millis",
            value: average(
                total: routing.crossCellDispatchTotalLatencyMillis,
                count: routing.crossCellDispatchSuccessCount + routing.crossCellDispatchFailureCount
            ),
            to: &lines
        )
        appendGauge(
            "im_cross_cell_dispatch_latency_max_millis",
            value: routing.crossCellDispatchMaxLatencyMillis,
            to: &lines
        )
        appendCounter(
            "im_cross_cell_dispatch_outbox_enqueued_total",
            value: routing.crossCellDispatchOutboxEnqueuedCount,
            to: &lines
        )
        appendCounter(
            "im_cross_cell_dispatch_outbox_deduplicated_total",
            value: routing.crossCellDispatchOutboxDeduplicatedCount,
            to: &lines
        )
        appendCounter(
            "im_cross_cell_dispatch_outbox_delivered_total",
            value: routing.crossCellDispatchOutboxDeliveredCount,
            to: &lines
        )
        appendCounter(
            "im_cross_cell_dispatch_outbox_retries_total",
            value: routing.crossCellDispatchOutboxRetryCount,
            to: &lines
        )
        appendGauge(
            "im_cross_cell_dispatch_outbox_backlog",
            value: routing.crossCellDispatchOutboxBacklogCount,
            to: &lines
        )
        appendGauge(
            "im_cross_cell_dispatch_outbox_oldest_pending_age_millis",
            value: routing.crossCellDispatchOutboxOldestPendingAgeMillis,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_dispatch_config_user_batch_size",
            value: streamConsumerConfiguration.realtimeRemoteDispatchUserBatchSize,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_dispatch_config_max_in_flight",
            value: streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight,
            to: &lines
        )
        appendCounter(
            "im_remote_domain_event_encoded_packets_total",
            value: routing.remoteDomainEventEncodedPacketCount,
            to: &lines
        )
        appendCounter(
            "im_remote_domain_event_encode_cache_hits_total",
            value: routing.remoteDomainEventEncodeCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_remote_domain_event_encoded_packet_bytes_total",
            value: routing.remoteDomainEventEncodedPacketBytes,
            to: &lines
        )
        appendGauge(
            "im_remote_domain_event_max_encoded_packet_bytes",
            value: routing.remoteDomainEventMaxEncodedPacketBytes,
            to: &lines
        )
        appendCounter("im_gateway_http_relay_work_items_total", value: routing.gatewayHTTPRelayWorkItemCount, to: &lines)
        appendCounter(
            "im_gateway_http_relay_payload_batches_total",
            value: routing.gatewayHTTPRelayPayloadBatchCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_recipients_total",
            value: routing.gatewayHTTPRelayRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_skipped_recipients_total",
            value: routing.gatewayHTTPRelaySkippedRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_encoded_payload_bytes_total",
            value: routing.gatewayHTTPRelayEncodedPayloadBytes,
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_max_recipients_per_work_item",
            value: routing.gatewayHTTPRelayMaxRecipientsPerWorkItem,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_request_attempts_total",
            value: routing.gatewayHTTPRelayRequestAttemptCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_request_successes_total",
            value: routing.gatewayHTTPRelayRequestSuccessCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_request_failures_total",
            value: routing.gatewayHTTPRelayRequestFailureCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_request_latency_millis_total",
            value: routing.gatewayHTTPRelayRequestTotalLatencyMillis,
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_request_latency_avg_millis",
            value: average(
                total: routing.gatewayHTTPRelayRequestTotalLatencyMillis,
                count: routing.gatewayHTTPRelayRequestAttemptCount
            ),
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_request_latency_max_millis",
            value: routing.gatewayHTTPRelayRequestMaxLatencyMillis,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_request_body_bytes_total",
            value: routing.gatewayHTTPRelayRequestBodyBytes,
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_request_max_body_bytes",
            value: routing.gatewayHTTPRelayRequestMaxBodyBytes,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_binary_fallbacks_total",
            value: routing.gatewayHTTPRelayBinaryFallbackCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_inbound_requests_total",
            value: routing.gatewayHTTPRelayInboundRequestCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_inbound_successes_total",
            value: routing.gatewayHTTPRelayInboundSuccessCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_inbound_failures_total",
            value: routing.gatewayHTTPRelayInboundFailureCount,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_inbound_latency_millis_total",
            value: routing.gatewayHTTPRelayInboundTotalLatencyMillis,
            to: &lines
        )
        appendCounter(
            "im_gateway_http_relay_inbound_body_bytes_total",
            value: routing.gatewayHTTPRelayInboundBodyBytes,
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_inbound_max_body_bytes",
            value: routing.gatewayHTTPRelayInboundMaxBodyBytes,
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_inbound_latency_avg_millis",
            value: average(
                total: routing.gatewayHTTPRelayInboundTotalLatencyMillis,
                count: routing.gatewayHTTPRelayInboundRequestCount
            ),
            to: &lines
        )
        appendGauge(
            "im_gateway_http_relay_inbound_latency_max_millis",
            value: routing.gatewayHTTPRelayInboundMaxLatencyMillis,
            to: &lines
        )
        appendCounter(
            "im_realtime_payloads_built_total",
            value: routing.realtimePayloadBuiltCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_payload_recipient_deliveries_total",
            value: routing.realtimePayloadRecipientDeliveryCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_payloads_with_conversation_summary_total",
            value: routing.realtimePayloadWithConversationSummaryCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_payload_summary_member_ids_omitted_total",
            value: routing.realtimePayloadConversationSummaryMemberIDsOmittedCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_payload_summary_member_ids_omitted_members_total",
            value: routing.realtimePayloadConversationSummaryMemberIDsOmittedTotalMembers,
            to: &lines
        )
        appendCounter(
            "im_realtime_payload_summary_member_ids_emitted_total",
            value: routing.realtimePayloadConversationSummaryMemberIDsEmittedCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_payload_summary_member_ids_emitted_members_total",
            value: routing.realtimePayloadConversationSummaryMemberIDsEmittedTotalMembers,
            to: &lines
        )
        appendCounter("im_local_fanout_packets_total", value: routing.localFanoutPacketCount, to: &lines)
        appendCounter(
            "im_local_fanout_target_connections_total",
            value: routing.localFanoutTargetConnectionCount,
            to: &lines
        )
        appendGauge(
            "im_local_fanout_max_target_connections_per_packet",
            value: routing.localFanoutMaxTargetConnectionsPerPacket,
            to: &lines
        )
        appendGauge("im_local_fanout_batch_size", value: routing.localFanoutBatchSize, to: &lines)
        appendCounter("im_local_fanout_chunks_total", value: routing.localFanoutChunkCount, to: &lines)
        appendGauge(
            "im_local_fanout_max_chunks_per_event_loop_job",
            value: routing.localFanoutMaxChunksPerEventLoopJob,
            to: &lines
        )
        appendCounter(
            "im_local_fanout_encoded_packets_total",
            value: routing.localFanoutEncodedPacketCount,
            to: &lines
        )
        appendCounter(
            "im_local_fanout_encode_cache_hits_total",
            value: routing.localFanoutEncodeCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_local_fanout_encoded_packet_bytes_total",
            value: routing.localFanoutEncodedPacketBytes,
            to: &lines
        )
        appendGauge(
            "im_local_fanout_max_encoded_packet_bytes",
            value: routing.localFanoutMaxEncodedPacketBytes,
            to: &lines
        )
        appendCounter(
            "im_local_fanout_estimated_outbound_bytes_total",
            value: routing.localFanoutEstimatedOutboundBytes,
            to: &lines
        )
        appendGauge(
            "im_local_fanout_max_estimated_outbound_bytes_per_packet",
            value: routing.localFanoutMaxEstimatedOutboundBytesPerPacket,
            to: &lines
        )
        appendGauge("im_gateway_local_fanout_config_batch_size", value: fanoutConfiguration.batchSize, to: &lines)
        appendCounter(
            "im_local_fanout_event_loop_jobs_started_total",
            value: routing.localFanoutEventLoopJobStartedCount,
            to: &lines
        )
        appendGauge(
            "im_local_fanout_event_loop_job_start_lag_avg_millis",
            value: average(
                total: routing.localFanoutEventLoopJobStartLagTotalMillis,
                count: routing.localFanoutEventLoopJobStartedCount
            ),
            to: &lines
        )
        appendGauge(
            "im_local_fanout_event_loop_job_start_lag_max_millis",
            value: routing.localFanoutEventLoopJobStartLagMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_gateway_local_fanout_config_event_loop_yield_chunks",
            value: fanoutConfiguration.eventLoopYieldChunkCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_config_enabled",
            value: fanoutConfiguration.activeConversationFanoutEnabled ? 1 : 0,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_config_recipient_threshold",
            value: fanoutConfiguration.activeConversationFanoutRecipientThreshold,
            to: &lines
        )
        appendCounter("im_local_fanout_event_loop_jobs_total", value: routing.localFanoutEventLoopJobCount, to: &lines)
        appendCounter("im_local_fanout_encode_failures_total", value: routing.localFanoutEncodeFailureCount, to: &lines)
        appendCounter(
            "im_realtime_active_conversation_fanout_splits_total",
            value: routing.realtimeActiveConversationFanoutSplitCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_active_recipients_total",
            value: routing.realtimeActiveConversationFanoutActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_compact_active_recipients_total",
            value: routing.realtimeActiveConversationFanoutCompactActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_inactive_hint_recipients_total",
            value: routing.realtimeActiveConversationFanoutInactiveHintRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_downgraded_active_recipients_total",
            value: routing.realtimeActiveConversationFanoutDowngradedActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_backpressure_downgraded_active_recipients_total",
            value: routing.realtimeActiveConversationFanoutBackpressureDowngradedRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_route_split_drops_total",
            value: routing.realtimeActiveConversationFanoutRouteSplitDropCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_route_split_drop_recipients_total",
            value: routing.realtimeActiveConversationFanoutRouteSplitDropRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_route_lookup_failures_total",
            value: routing.realtimeActiveConversationFanoutRouteLookupFailureCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_fanout_route_lookup_failure_recipients_total",
            value: routing.realtimeActiveConversationFanoutRouteLookupFailureRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_max_active_recipients_per_split",
            value: routing.realtimeActiveConversationFanoutMaxActiveRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_max_compact_active_recipients_per_split",
            value: routing.realtimeActiveConversationFanoutMaxCompactActiveRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_max_inactive_hint_recipients_per_split",
            value: routing.realtimeActiveConversationFanoutMaxInactiveHintRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_active_conversation_fanout_max_downgraded_active_recipients_per_split",
            value: routing.realtimeActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_hits_total",
            value: routing.realtimeActiveConversationRouteCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_partial_hits_total",
            value: routing.realtimeActiveConversationRouteCachePartialHitCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_misses_total",
            value: routing.realtimeActiveConversationRouteCacheMissCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_cached_users_total",
            value: routing.realtimeActiveConversationRouteCacheCachedUserCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_missed_users_total",
            value: routing.realtimeActiveConversationRouteCacheMissedUserCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_active_conversation_route_cache_joined_in_flight_total",
            value: routing.realtimeActiveConversationRouteCacheJoinedInFlightCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_splits_total",
            value: routing.realtimeRemoteActiveConversationFanoutSplitCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_full_recipients_total",
            value: routing.realtimeRemoteActiveConversationFanoutFullRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_compact_recipients_total",
            value: routing.realtimeRemoteActiveConversationFanoutCompactRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_inactive_hint_recipients_total",
            value: routing.realtimeRemoteActiveConversationFanoutInactiveHintRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_downgraded_active_recipients_total",
            value: routing.realtimeRemoteActiveConversationFanoutDowngradedActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_route_split_drops_total",
            value: routing.realtimeRemoteActiveConversationFanoutRouteSplitDropCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_remote_active_conversation_fanout_route_split_drop_recipients_total",
            value: routing.realtimeRemoteActiveConversationFanoutRouteSplitDropRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_active_conversation_fanout_max_full_recipients_per_split",
            value: routing.realtimeRemoteActiveConversationFanoutMaxFullRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_active_conversation_fanout_max_compact_recipients_per_split",
            value: routing.realtimeRemoteActiveConversationFanoutMaxCompactRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_active_conversation_fanout_max_inactive_hint_recipients_per_split",
            value: routing.realtimeRemoteActiveConversationFanoutMaxInactiveHintRecipientsPerSplit,
            to: &lines
        )
        appendGauge(
            "im_realtime_remote_active_conversation_fanout_max_downgraded_active_recipients_per_split",
            value: routing.realtimeRemoteActiveConversationFanoutMaxDowngradedActiveRecipientsPerSplit,
            to: &lines
        )
        appendCounter(
            "im_realtime_inactive_conversation_hint_flushes_total",
            value: routing.realtimeInactiveConversationHintFlushCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_inactive_conversation_hint_payload_batches_total",
            value: routing.realtimeInactiveConversationHintPayloadBatchCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_inactive_conversation_hint_recipients_total",
            value: routing.realtimeInactiveConversationHintRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_inactive_conversation_hint_suppressed_recipients_total",
            value: routing.realtimeInactiveConversationHintSuppressedRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_delivery_consumer_inactive_hint_relay_payload_batches_total",
            value: routing.realtimeDeliveryConsumerInactiveHintRelayPayloadBatchCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_delivery_consumer_inactive_hint_relay_recipients_total",
            value: routing.realtimeDeliveryConsumerInactiveHintRelayRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_delivery_consumer_inactive_hint_suppressed_recipients_total",
            value: routing.realtimeDeliveryConsumerInactiveHintSuppressedRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_total",
            value: routing.domainRelayAfterRecordPreSplitCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_active_recipients_total",
            value: routing.domainRelayAfterRecordPreSplitActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_compact_active_recipients_total",
            value: routing.domainRelayAfterRecordPreSplitCompactActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_inactive_hint_recipients_total",
            value: routing.domainRelayAfterRecordPreSplitInactiveHintRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_downgraded_active_recipients_total",
            value: routing.domainRelayAfterRecordPreSplitDowngradedActiveRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_route_drops_total",
            value: routing.domainRelayAfterRecordPreSplitRouteDropCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_pre_split_route_lookup_failures_total",
            value: routing.domainRelayAfterRecordPreSplitRouteLookupFailureCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_inactive_hint_suppressed_recipients_total",
            value: routing.domainRelayAfterRecordInactiveHintSuppressedRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_hits_total",
            value: routing.domainRelayAfterRecordActiveRouteCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_partial_hits_total",
            value: routing.domainRelayAfterRecordActiveRouteCachePartialHitCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_misses_total",
            value: routing.domainRelayAfterRecordActiveRouteCacheMissCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_cached_users_total",
            value: routing.domainRelayAfterRecordActiveRouteCacheCachedUserCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_missed_users_total",
            value: routing.domainRelayAfterRecordActiveRouteCacheMissedUserCount,
            to: &lines
        )
        appendCounter(
            "im_domain_relay_after_record_active_route_cache_joined_in_flight_total",
            value: routing.domainRelayAfterRecordActiveRouteCacheJoinedInFlightCount,
            to: &lines
        )
        appendGauge(
            "im_domain_relay_after_record_pre_split_max_active_recipients",
            value: routing.domainRelayAfterRecordPreSplitMaxActiveRecipients,
            to: &lines
        )
        appendGauge(
            "im_domain_relay_after_record_pre_split_max_compact_active_recipients",
            value: routing.domainRelayAfterRecordPreSplitMaxCompactActiveRecipients,
            to: &lines
        )
        appendGauge(
            "im_domain_relay_after_record_pre_split_max_inactive_hint_recipients",
            value: routing.domainRelayAfterRecordPreSplitMaxInactiveHintRecipients,
            to: &lines
        )
        appendGauge(
            "im_domain_relay_after_record_pre_split_max_downgraded_active_recipients",
            value: routing.domainRelayAfterRecordPreSplitMaxDowngradedActiveRecipients,
            to: &lines
        )
        appendCounter(
            "im_realtime_coalesced_dispatch_replacements_total",
            value: routing.realtimeCoalescedDispatchReplacementCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_coalesced_dropped_payload_batches_total",
            value: routing.realtimeCoalescedDroppedPayloadBatchCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_coalesced_dropped_recipient_deliveries_total",
            value: routing.realtimeCoalescedDroppedRecipientDeliveryCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_dropped_dispatches_total",
            value: routing.realtimeAsyncRelayDroppedDispatchCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_dropped_payload_batches_total",
            value: routing.realtimeAsyncRelayDroppedPayloadBatchCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_dropped_recipient_deliveries_total",
            value: routing.realtimeAsyncRelayDroppedRecipientDeliveryCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_queue_saturation_total",
            value: routing.realtimeAsyncRelayQueueSaturationCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_queued_waiters",
            value: routing.realtimeAsyncRelayQueuedWaiterCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_max_queued_waiters",
            value: routing.realtimeAsyncRelayMaxQueuedWaiters,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_tasks_started_total",
            value: routing.realtimeAsyncRelayTaskStartedCount,
            to: &lines
        )
        appendCounter(
            "im_realtime_async_relay_tasks_completed_total",
            value: routing.realtimeAsyncRelayTaskCompletedCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_in_flight",
            value: routing.realtimeAsyncRelayCurrentInFlightCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_max_in_flight",
            value: routing.realtimeAsyncRelayMaxInFlightCount,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_task_start_lag_avg_millis",
            value: average(
                total: routing.realtimeAsyncRelayTaskStartLagTotalMillis,
                count: routing.realtimeAsyncRelayTaskStartedCount
            ),
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_task_start_lag_max_millis",
            value: routing.realtimeAsyncRelayTaskStartLagMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_latency_avg_millis",
            value: average(
                total: routing.realtimeAsyncRelayLatencyTotalMillis,
                count: routing.realtimeAsyncRelayTaskCompletedCount
            ),
            to: &lines
        )
        appendGauge(
            "im_realtime_async_relay_latency_max_millis",
            value: routing.realtimeAsyncRelayLatencyMaxMillis,
            to: &lines
        )
        appendCounter("im_outbox_processed_events_total", value: outbox.processedEvents, to: &lines)
        appendCounter("im_outbox_failed_events_total", value: outbox.failedEvents, to: &lines)
        appendGauge("im_outbox_backlog_events", value: outbox.backlogCount, to: &lines)
        appendGauge("im_outbox_oldest_pending_age_millis", value: outbox.oldestPendingAgeMillis, to: &lines)
        appendCounter("im_hot_conversation_rejections_total", value: hotConversations.rejectedMessages, to: &lines)
        appendCounter("im_hot_conversation_limiter_errors_total", value: hotConversations.backendErrors, to: &lines)
        appendGauge("im_hot_conversation_tracked_windows", value: hotConversations.trackedWindows, to: &lines)
        appendCounter("im_db_operations_total", value: database.operationCount, to: &lines)
        appendCounter("im_db_operation_failures_total", value: database.failedOperationCount, to: &lines)
        appendCounter("im_invalid_sequence_total", value: database.invalidSequenceCount, to: &lines)
        appendCounter("im_search_stale_hits_total", value: database.staleSearchHitCount, to: &lines)
        appendGauge("im_db_operation_latency_avg_millis", value: database.averageLatencyMillis, to: &lines)
        appendGauge("im_db_operation_latency_max_millis", value: database.maxLatencyMillis, to: &lines)
        appendCounter("im_stream_consumed_events_total", value: stream.consumedEvents, to: &lines)
        appendCounter("im_stream_duplicate_events_total", value: stream.duplicateEvents, to: &lines)
        appendCounter("im_stream_failed_events_total", value: stream.failedEvents, to: &lines)
        appendCounter("im_stream_dead_letter_published_events_total", value: stream.deadLetterPublishedEvents, to: &lines)
        appendCounter("im_stream_processed_runs_total", value: stream.processedRuns, to: &lines)
        appendCounter("im_stream_message_created_runs_total", value: stream.messageCreatedRuns, to: &lines)
        appendCounter(
            "im_stream_message_created_run_events_total",
            value: stream.messageCreatedRunEventCount,
            to: &lines
        )
        appendGauge(
            "im_stream_message_created_run_events_avg",
            value: stream.averageMessageCreatedRunEventCount,
            to: &lines
        )
        appendGauge(
            "im_stream_message_created_run_max_events",
            value: stream.maxMessageCreatedRunEventCount,
            to: &lines
        )
        appendCounter("im_stream_slow_processing_runs_total", value: stream.slowProcessingRuns, to: &lines)
        appendCounter("im_stream_lagged_runs_total", value: stream.laggedRuns, to: &lines)
        appendCounter("im_stream_processing_batches_total", value: stream.processingBatches, to: &lines)
        appendCounter("im_stream_processing_batch_events_total", value: stream.processingBatchEventCount, to: &lines)
        appendGauge(
            "im_stream_processing_batch_events_avg",
            value: stream.averageProcessingBatchEventCount,
            to: &lines
        )
        appendGauge("im_stream_processing_batch_max_events", value: stream.maxProcessingBatchEventCount, to: &lines)
        appendCounter("im_stream_batch_fill_waits_total", value: stream.batchFillWaits, to: &lines)
        appendCounter("im_stream_batch_fill_wait_millis_total", value: stream.batchFillWaitMillis, to: &lines)
        appendGauge("im_stream_batch_fill_wait_avg_millis", value: stream.averageBatchFillWaitMillis, to: &lines)
        appendCounter("im_stream_batch_fill_events_total", value: stream.batchFillEventCount, to: &lines)
        appendCounter("im_stream_batch_fill_skipped_batches_total", value: stream.batchFillSkippedBatches, to: &lines)
        appendCounter("im_stream_queue_producer_waits_total", value: stream.queueProducerWaits, to: &lines)
        appendGauge("im_stream_queue_depth", value: stream.queueCurrentDepth, to: &lines)
        appendGauge("im_stream_queue_max_depth", value: stream.queueMaxDepth, to: &lines)
        appendCounter("im_stream_run_events_total", value: stream.runEventCount, to: &lines)
        appendGauge("im_stream_run_max_events", value: stream.maxRunEventCount, to: &lines)
        appendGauge(
            "im_stream_run_processing_latency_avg_millis",
            value: stream.averageRunProcessingMillis,
            to: &lines
        )
        appendGauge(
            "im_stream_run_processing_latency_max_millis",
            value: stream.maxRunProcessingMillis,
            to: &lines
        )
        appendGauge(
            "im_stream_run_event_lag_avg_millis",
            value: stream.averageRunEventLagMillis,
            to: &lines
        )
        appendGauge(
            "im_stream_run_event_lag_max_millis",
            value: stream.maxRunEventLagMillis,
            to: &lines
        )
        appendStreamGroupMetrics(streamGroups, to: &lines)
        appendGauge("im_ai_stream_active", value: aiStream.activeStreams, to: &lines)
        appendCounter("im_ai_stream_started_total", value: aiStream.startedStreams, to: &lines)
        appendCounter("im_ai_stream_completed_total", value: aiStream.completedStreams, to: &lines)
        appendCounter("im_ai_stream_cancelled_total", value: aiStream.cancelledStreams, to: &lines)
        appendCounter("im_ai_stream_failed_total", value: aiStream.failedStreams, to: &lines)
        appendCounter("im_ai_stream_chunks_published_total", value: aiStream.publishedChunks, to: &lines)
        appendCounter("im_ai_stream_snapshot_writes_total", value: aiStream.snapshotWrites, to: &lines)
        appendCounter("im_ai_stream_terminal_cas_conflicts_total", value: aiStream.terminalCASConflicts, to: &lines)
        appendCounter("im_ai_stream_startup_stale_repairs_total", value: aiStream.startupStaleRepairs, to: &lines)
        appendCounter("im_ai_stream_startup_repair_pages_total", value: aiStream.startupRepairPages, to: &lines)
        appendCounter("im_ai_stream_runtime_stale_repairs_total", value: aiStream.runtimeStaleRepairs, to: &lines)
        appendCounter("im_ai_stream_lease_reservations_total", value: aiStream.leaseReservations, to: &lines)
        appendCounter("im_ai_stream_lease_rejections_total", value: aiStream.leaseRejections, to: &lines)
        appendCounter("im_ai_stream_lease_heartbeats_total", value: aiStream.leaseHeartbeats, to: &lines)
        appendCounter("im_ai_stream_lease_cancellations_total", value: aiStream.leaseCancellationRequests, to: &lines)
        appendCounter("im_ai_stream_chunk_db_bypasses_total", value: aiStream.chunkDatabaseBypasses, to: &lines)
        appendCounter("im_ai_stream_finalize_retries_total", value: aiStream.finalizeRetries, to: &lines)
        appendCounter("im_ai_stream_finalize_failures_total", value: aiStream.finalizeFailures, to: &lines)
        appendCounter("im_sequence_blocks_reserved_total", value: messageWrite.sequenceBlocksReserved, to: &lines)
        appendCounter("im_sequence_block_reserve_failures_total", value: messageWrite.sequenceBlockReserveFailures, to: &lines)
        appendGauge("im_sequence_block_remaining", value: messageWrite.sequenceBlockRemaining, to: &lines)
        appendCounter("im_conversation_owner_forward_total", value: messageWrite.ownerForwardCount, to: &lines)
        appendCounter("im_conversation_owner_forward_failures_total", value: messageWrite.ownerForwardFailureCount, to: &lines)
        appendGauge("im_conversation_write_queue_depth", value: messageWrite.writeQueueDepth, to: &lines)
        appendCounter("im_conversation_member_cache_hit_total", value: messageWrite.memberCacheHits, to: &lines)
        appendCounter("im_conversation_member_cache_miss_total", value: messageWrite.memberCacheMisses, to: &lines)
        appendCounter("im_message_write_batches_total", value: messageWrite.messageWriteBatches, to: &lines)
        appendCounter("im_message_write_batch_messages_total", value: messageWrite.messageWriteBatchMessages, to: &lines)
        appendCounter("im_message_write_queue_rejected_total", value: messageWrite.writeQueueRejected, to: &lines)
        appendCounter("im_message_write_command_requests_total", value: messageWrite.commandSendRequests, to: &lines)
        appendCounter("im_message_write_command_failures_total", value: messageWrite.commandSendFailures, to: &lines)
        appendCounter("im_message_write_command_full_responses_total", value: messageWrite.commandSendFullResponses, to: &lines)
        appendCounter("im_message_write_command_compact_responses_total", value: messageWrite.commandSendCompactResponses, to: &lines)
        appendCounter("im_message_write_command_duration_millis_total", value: messageWrite.commandSendTotalMillis, to: &lines)
        appendGauge("im_message_write_command_duration_millis_max", value: messageWrite.commandSendMaxMillis, to: &lines)
        appendCounter("im_message_write_command_decode_millis_total", value: messageWrite.commandSendDecodeMillis, to: &lines)
        appendGauge("im_message_write_command_decode_millis_max", value: messageWrite.commandSendDecodeMaxMillis, to: &lines)
        appendCounter("im_message_write_command_persist_millis_total", value: messageWrite.commandSendPersistMillis, to: &lines)
        appendGauge("im_message_write_command_persist_millis_max", value: messageWrite.commandSendPersistMaxMillis, to: &lines)
        appendCounter("im_message_write_command_response_encode_millis_total", value: messageWrite.commandSendResponseEncodeMillis, to: &lines)
        appendGauge("im_message_write_command_response_encode_millis_max", value: messageWrite.commandSendResponseEncodeMaxMillis, to: &lines)
        appendCounter("im_message_write_prepare_messages_total", value: messageWrite.prepareMessages, to: &lines)
        appendCounter("im_message_write_prepare_duration_millis_total", value: messageWrite.prepareTotalMillis, to: &lines)
        appendGauge("im_message_write_prepare_duration_millis_max", value: messageWrite.prepareMaxMillis, to: &lines)
        appendCounter("im_message_write_batch_queue_wait_messages_total", value: messageWrite.batchQueueWaitMessages, to: &lines)
        appendCounter("im_message_write_batch_queue_wait_millis_total", value: messageWrite.batchQueueWaitTotalMillis, to: &lines)
        appendGauge("im_message_write_batch_queue_wait_millis_max", value: messageWrite.batchQueueWaitMaxMillis, to: &lines)
        appendCounter("im_message_write_pipeline_batches_total", value: messageWrite.persistencePipelineBatches, to: &lines)
        appendCounter("im_message_write_pipeline_messages_total", value: messageWrite.persistencePipelineMessages, to: &lines)
        appendCounter("im_message_write_pipeline_duration_millis_total", value: messageWrite.persistencePipelineTotalMillis, to: &lines)
        appendGauge("im_message_write_pipeline_duration_millis_max", value: messageWrite.persistencePipelineMaxMillis, to: &lines)
        appendGauge("im_message_write_pipeline_recipients_max", value: messageWrite.persistencePipelineMaxRecipients, to: &lines)
        appendMessageWriteStageMetrics(messageWrite.persistenceStages, to: &lines)
        appendCounter(
            "im_domain_event_recipient_resolve_total",
            value: domainEvent.recipientResolveCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_inline_total",
            value: domainEvent.recipientResolveInlineCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_event_snapshot_total",
            value: domainEvent.recipientResolveEventSnapshotCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_membership_expansion_total",
            value: domainEvent.recipientResolveMembershipExpansionCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_affected_user_total",
            value: domainEvent.recipientResolveAffectedUserCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_empty_total",
            value: domainEvent.recipientResolveEmptyCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_errors_total",
            value: domainEvent.recipientResolveErrorCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_missing_snapshot_total",
            value: domainEvent.recipientResolveMissingSnapshotCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_resolve_users_total",
            value: domainEvent.recipientResolveUserCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_resolve_latency_avg_millis",
            value: average(
                total: domainEvent.recipientResolveTotalMillis,
                count: domainEvent.recipientResolveCount
            ),
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_resolve_latency_max_millis",
            value: domainEvent.recipientResolveMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_resolve_max_users",
            value: domainEvent.recipientResolveMaxUserCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_inline_stores_total",
            value: domainEvent.recipientSnapshotInlineStoreCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_inline_store_recipients_total",
            value: domainEvent.recipientSnapshotInlineStoreRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_deduplicated_stores_total",
            value: domainEvent.recipientSnapshotDeduplicatedStoreCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_deduplicated_store_recipients_total",
            value: domainEvent.recipientSnapshotDeduplicatedStoreRecipientCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_resolve_inline_total",
            value: domainEvent.recipientSnapshotResolveInlineCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_resolve_shared_set_hits_total",
            value: domainEvent.recipientSnapshotResolveSharedSetHitCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_resolve_shared_set_missing_total",
            value: domainEvent.recipientSnapshotResolveSharedSetMissingCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_snapshot_resolve_recipients_total",
            value: domainEvent.recipientSnapshotResolveRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_snapshot_resolve_latency_avg_millis",
            value: average(
                total: domainEvent.recipientSnapshotResolveTotalMillis,
                count: domainEvent.recipientSnapshotResolveInlineCount
                    + domainEvent.recipientSnapshotResolveSharedSetHitCount
                    + domainEvent.recipientSnapshotResolveSharedSetMissingCount
            ),
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_snapshot_resolve_latency_max_millis",
            value: domainEvent.recipientSnapshotResolveMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_snapshot_resolve_max_recipients",
            value: domainEvent.recipientSnapshotResolveMaxRecipients,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_set_cleanup_runs_total",
            value: domainEvent.recipientSetCleanupRunCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_set_cleanup_scanned_total",
            value: domainEvent.recipientSetCleanupScannedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_recipient_set_cleanup_deleted_total",
            value: domainEvent.recipientSetCleanupDeletedCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_recipient_set_cleanup_max_deleted",
            value: domainEvent.recipientSetCleanupMaxDeletedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_owner_delivery_skipped_total",
            value: domainEvent.messageCreatedOwnerDeliverySkippedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_owner_delivery_skipped_recipients_total",
            value: domainEvent.messageCreatedOwnerDeliverySkippedRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_message_created_owner_delivery_skipped_max_recipients",
            value: domainEvent.messageCreatedOwnerDeliverySkippedMaxRecipients,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_timeline_pull_delivery_total",
            value: domainEvent.messageCreatedTimelinePullDeliveryCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_timeline_pull_delivery_recipients_total",
            value: domainEvent.messageCreatedTimelinePullDeliveryRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_message_created_timeline_pull_delivery_max_recipients",
            value: domainEvent.messageCreatedTimelinePullDeliveryMaxRecipients,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_owner_notification_skipped_total",
            value: domainEvent.messageCreatedOwnerNotificationSkippedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_owner_notification_skipped_recipients_total",
            value: domainEvent.messageCreatedOwnerNotificationSkippedRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_message_created_owner_notification_skipped_max_recipients",
            value: domainEvent.messageCreatedOwnerNotificationSkippedMaxRecipients,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_summary_activity_only_total",
            value: domainEvent.messageCreatedSummaryActivityOnlyCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_summary_activity_only_recipients_total",
            value: domainEvent.messageCreatedSummaryActivityOnlyRecipientCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_message_created_summary_activity_only_max_recipients",
            value: domainEvent.messageCreatedSummaryActivityOnlyMaxRecipients,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_preview_embedded_total",
            value: domainEvent.messageCreatedPreviewEmbeddedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_preview_message_lookup_total",
            value: domainEvent.messageCreatedPreviewMessageLookupCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_message_created_preview_missing_total",
            value: domainEvent.messageCreatedPreviewMissingCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_summary_activity_coalesced_replacements_total",
            value: domainEvent.summaryActivityCoalescedReplacementCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_summary_activity_coalesced_flushes_total",
            value: domainEvent.summaryActivityCoalescedFlushCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_summary_activity_coalesced_flush_requests_total",
            value: domainEvent.summaryActivityCoalescedFlushRequestCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_summary_activity_coalesced_flush_failures_total",
            value: domainEvent.summaryActivityCoalescedFlushFailureCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_summary_activity_coalesced_flush_failure_requests_total",
            value: domainEvent.summaryActivityCoalescedFlushFailureRequestCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_summary_activity_coalesced_flush_latency_avg_millis",
            value: average(
                total: domainEvent.summaryActivityCoalescedFlushTotalMillis,
                count: domainEvent.summaryActivityCoalescedFlushCount + domainEvent.summaryActivityCoalescedFlushFailureCount
            ),
            to: &lines
        )
        appendGauge(
            "im_domain_event_summary_activity_coalesced_flush_latency_max_millis",
            value: domainEvent.summaryActivityCoalescedFlushMaxMillis,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_writes_total",
            value: domainEvent.ownerDeliveryBatchWriteCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_requests_total",
            value: domainEvent.ownerDeliveryBatchWriteRequestCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_inserted_rows_total",
            value: domainEvent.ownerDeliveryBatchWriteInsertedRowCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_returned_rows_total",
            value: domainEvent.ownerDeliveryBatchWriteReturnedRowCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_fallbacks_total",
            value: domainEvent.ownerDeliveryBatchWriteFallbackCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_canonical_fast_paths_total",
            value: domainEvent.ownerDeliveryBatchWriteCanonicalFastPathCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_materialized_fast_paths_total",
            value: domainEvent.ownerDeliveryBatchWriteMaterializedFastPathCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_chunked_total",
            value: domainEvent.ownerDeliveryBatchWriteChunkedCount,
            to: &lines
        )
        appendCounter(
            "im_domain_event_owner_delivery_batch_write_chunks_total",
            value: domainEvent.ownerDeliveryBatchWriteChunkCount,
            to: &lines
        )
        appendGauge(
            "im_domain_event_owner_delivery_batch_write_chunked_max_requests",
            value: domainEvent.ownerDeliveryBatchWriteChunkedMaxRequests,
            to: &lines
        )
        appendGauge(
            "im_domain_event_owner_delivery_batch_write_latency_avg_millis",
            value: average(
                total: domainEvent.ownerDeliveryBatchWriteTotalMillis,
                count: domainEvent.ownerDeliveryBatchWriteCount
            ),
            to: &lines
        )
        appendGauge(
            "im_domain_event_owner_delivery_batch_write_latency_max_millis",
            value: domainEvent.ownerDeliveryBatchWriteMaxMillis,
            to: &lines
        )
        appendGauge(
            "im_domain_event_owner_delivery_batch_write_max_requests",
            value: domainEvent.ownerDeliveryBatchWriteMaxRequests,
            to: &lines
        )
        appendCounter("im_summary_read_summary_total", value: summaryRead.summaryReadCount, to: &lines)
        appendCounter("im_summary_read_summary_errors_total", value: summaryRead.summaryReadErrorCount, to: &lines)
        appendGauge(
            "im_summary_read_summary_latency_avg_millis",
            value: average(
                total: summaryRead.summaryReadTotalMillis,
                count: summaryRead.summaryReadCount + summaryRead.summaryReadErrorCount
            ),
            to: &lines
        )
        appendGauge("im_summary_read_summary_latency_max_millis", value: summaryRead.summaryReadMaxMillis, to: &lines)
        appendCounter("im_summary_read_list_total", value: summaryRead.listReadCount, to: &lines)
        appendCounter("im_summary_read_list_errors_total", value: summaryRead.listReadErrorCount, to: &lines)
        appendCounter("im_summary_read_list_joined_total", value: summaryRead.listReadJoinedCount, to: &lines)
        appendCounter("im_summary_read_list_fluent_total", value: summaryRead.listReadFluentCount, to: &lines)
        appendCounter("im_summary_read_list_fallbacks_total", value: summaryRead.listReadFallbackCount, to: &lines)
        appendCounter("im_summary_read_list_items_total", value: summaryRead.listReadItemCount, to: &lines)
        appendGauge("im_summary_read_list_max_items", value: summaryRead.listReadMaxItems, to: &lines)
        appendGauge(
            "im_summary_read_list_latency_avg_millis",
            value: average(
                total: summaryRead.listReadTotalMillis,
                count: summaryRead.listReadCount + summaryRead.listReadErrorCount
            ),
            to: &lines
        )
        appendGauge("im_summary_read_list_latency_max_millis", value: summaryRead.listReadMaxMillis, to: &lines)
        appendCounter("im_summary_read_changes_total", value: summaryRead.changesReadCount, to: &lines)
        appendCounter("im_summary_read_changes_errors_total", value: summaryRead.changesReadErrorCount, to: &lines)
        appendCounter("im_summary_read_changes_joined_total", value: summaryRead.changesReadJoinedCount, to: &lines)
        appendCounter("im_summary_read_changes_fluent_total", value: summaryRead.changesReadFluentCount, to: &lines)
        appendCounter("im_summary_read_changes_fallbacks_total", value: summaryRead.changesReadFallbackCount, to: &lines)
        appendCounter("im_summary_read_changes_upserts_total", value: summaryRead.changesReadUpsertCount, to: &lines)
        appendCounter("im_summary_read_changes_removed_total", value: summaryRead.changesReadRemovedCount, to: &lines)
        appendGauge("im_summary_read_changes_max_items", value: summaryRead.changesReadMaxItems, to: &lines)
        appendGauge(
            "im_summary_read_changes_latency_avg_millis",
            value: average(
                total: summaryRead.changesReadTotalMillis,
                count: summaryRead.changesReadCount + summaryRead.changesReadErrorCount
            ),
            to: &lines
        )
        appendGauge("im_summary_read_changes_latency_max_millis", value: summaryRead.changesReadMaxMillis, to: &lines)
        appendCounter("im_timeline_read_history_total", value: timelineRead.historyReadCount, to: &lines)
        appendCounter("im_timeline_read_since_total", value: timelineRead.sinceReadCount, to: &lines)
        appendCounter("im_timeline_read_errors_total", value: timelineRead.errorCount, to: &lines)
        appendCounter(
            "im_timeline_read_visibility_scan_limit_exceeded_total",
            value: timelineRead.scanLimitExceededCount,
            to: &lines
        )
        appendCounter("im_timeline_read_items_total", value: timelineRead.itemCount, to: &lines)
        appendGauge("im_timeline_read_max_items", value: timelineRead.maxItems, to: &lines)
        appendCounter("im_timeline_read_visibility_scan_rows_total", value: timelineRead.scanRowCount, to: &lines)
        appendGauge("im_timeline_read_visibility_scan_max_rows", value: timelineRead.maxScanRows, to: &lines)
        appendCounter("im_timeline_read_visibility_scan_pages_total", value: timelineRead.scanPageCount, to: &lines)
        appendGauge("im_timeline_read_visibility_scan_max_pages", value: timelineRead.maxScanPages, to: &lines)
        appendCounter("im_timeline_since_hot_cache_hits_total", value: timelineRead.sinceHotCacheHitCount, to: &lines)
        appendCounter("im_timeline_since_hot_cache_misses_total", value: timelineRead.sinceHotCacheMissCount, to: &lines)
        appendCounter(
            "im_timeline_since_hot_cache_unsafe_bypasses_total",
            value: timelineRead.sinceHotCacheUnsafeBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_hot_cache_target_sequence_bypasses_total",
            value: timelineRead.sinceHotCacheTargetSequenceBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_hot_cache_invalidations_total",
            value: timelineRead.sinceHotCacheInvalidationCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_hot_cache_invalidated_entries_total",
            value: timelineRead.sinceHotCacheInvalidatedEntryCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_hits_total",
            value: timelineRead.sinceRecentCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_misses_total",
            value: timelineRead.sinceRecentCacheMissCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_target_sequence_bypasses_total",
            value: timelineRead.sinceRecentCacheTargetSequenceBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_stores_total",
            value: timelineRead.sinceRecentCacheStoreCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_invalidations_total",
            value: timelineRead.sinceRecentCacheInvalidationCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_recent_cache_invalidated_entries_total",
            value: timelineRead.sinceRecentCacheInvalidatedEntryCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_visibility_safety_cache_hits_total",
            value: timelineRead.sinceVisibilitySafetyCacheHitCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_visibility_safety_cache_misses_total",
            value: timelineRead.sinceVisibilitySafetyCacheMissCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_visibility_safety_cache_joined_inflight_total",
            value: timelineRead.sinceVisibilitySafetyCacheJoinedInFlightCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_visibility_hidden_override_bypasses_total",
            value: timelineRead.sinceVisibilitySafetyHiddenOverrideBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_visibility_notice_bypasses_total",
            value: timelineRead.sinceVisibilitySafetyNoticeBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_response_singleflight_joined_total",
            value: timelineRead.sinceResponseSingleflightJoinedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_response_singleflight_notice_bypasses_total",
            value: timelineRead.sinceResponseSingleflightNoticeBypassCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_distributed_invalidations_published_total",
            value: timelineRead.sinceDistributedInvalidationPublishedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_distributed_invalidations_received_total",
            value: timelineRead.sinceDistributedInvalidationReceivedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_distributed_invalidation_errors_total",
            value: timelineRead.sinceDistributedInvalidationErrorCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_requests_total",
            value: timelineRead.sinceTargetSequenceRequestCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_eventual_satisfied_total",
            value: timelineRead.sinceTargetSequenceEventualSatisfiedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_strong_fallbacks_total",
            value: timelineRead.sinceTargetSequenceStrongFallbackCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_strong_satisfied_total",
            value: timelineRead.sinceTargetSequenceStrongSatisfiedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_strong_misses_total",
            value: timelineRead.sinceTargetSequenceStrongMissCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_errors_total",
            value: timelineRead.sinceTargetSequenceErrorCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_singleflight_joined_total",
            value: timelineRead.sinceTargetSequenceSingleflightJoinedCount,
            to: &lines
        )
        appendCounter(
            "im_timeline_since_target_sequence_window_joined_total",
            value: timelineRead.sinceTargetSequenceWindowJoinedCount,
            to: &lines
        )
        lines.append("# TYPE im_timeline_read_latency_millis histogram")
        appendHistogramSamples(
            "im_timeline_read_latency_millis",
            histogram: timelineRead.historyLatencyHistogram,
            labels: ["kind": "history"],
            to: &lines
        )
        appendHistogramSamples(
            "im_timeline_read_latency_millis",
            histogram: timelineRead.sinceLatencyHistogram,
            labels: ["kind": "since"],
            to: &lines
        )
        appendGauge(
            "im_timeline_read_latency_avg_millis",
            value: average(
                total: timelineRead.totalMillis,
                count: timelineRead.historyReadCount + timelineRead.sinceReadCount + timelineRead.errorCount
            ),
            to: &lines
        )
        appendGauge("im_timeline_read_latency_max_millis", value: timelineRead.maxMillis, to: &lines)
        appendCounter("im_client_health_reports_total", value: clientHealth.reports, to: &lines)
        appendGauge("im_client_health_reporting_users", value: clientHealth.activeReportingUsers, to: &lines)
        appendGauge(
            "im_client_health_users_with_deferred_domain_events",
            value: clientHealth.usersWithDeferredDomainEvents,
            to: &lines
        )
        appendGauge("im_client_deferred_domain_events", value: clientHealth.totalDeferredDomainEvents, to: &lines)
        appendGauge("im_client_deferred_domain_events_max", value: clientHealth.maxDeferredDomainEvents, to: &lines)
        appendGauge("im_client_full_refresh_conversations_max", value: clientHealth.maxFullRefreshConversations, to: &lines)
        appendGauge("im_client_domain_event_cursor_max", value: clientHealth.maxDomainEventCursor, to: &lines)
        appendCounter("im_client_domain_event_cursor_gap_total", value: clientHealth.catchUpCursorGaps, to: &lines)
        appendCounter(
            "im_client_domain_event_sync_stopped_total",
            value: clientHealth.catchUpStoppedBeforeCursorAdvance,
            to: &lines
        )
        appendCounter("im_client_deferred_domain_events_stored_total", value: clientHealth.deferredStored, to: &lines)
        appendCounter(
            "im_client_deferred_domain_events_replayed_total",
            value: clientHealth.deferredReplayApplied,
            to: &lines
        )
        appendCounter("im_client_deferred_domain_events_expired_total", value: clientHealth.deferredExpired, to: &lines)
        appendCounter(
            "im_client_deferred_full_refresh_requested_total",
            value: clientHealth.deferredFullRefreshRequested,
            to: &lines
        )
        appendCounter("im_client_invalid_domain_events_total", value: clientHealth.invalidDomainEvents, to: &lines)
        appendCounter("im_client_invalid_projection_dtos_total", value: clientHealth.invalidProjectionDTOs, to: &lines)
        appendCounter(
            "im_client_invalid_canonical_message_dtos_total",
            value: clientHealth.invalidCanonicalMessageDTOs,
            to: &lines
        )
        appendCounter(
            "im_client_cache_dropped_canonical_messages_total",
            value: clientHealth.cacheDroppedCanonicalMessages,
            to: &lines
        )
        appendCounter(
            "im_client_cache_dropped_timeline_notices_total",
            value: clientHealth.cacheDroppedTimelineNotices,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_hint_queued_total",
            value: clientHealth.timelineCatchUpHintQueued,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_skipped_already_loaded_total",
            value: clientHealth.timelineCatchUpSkippedAlreadyLoaded,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_deferred_total",
            value: clientHealth.timelineCatchUpDeferred,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_since_requests_total",
            value: clientHealth.timelineCatchUpSinceRequests,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_since_successes_total",
            value: clientHealth.timelineCatchUpSinceSuccesses,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_since_failures_total",
            value: clientHealth.timelineCatchUpSinceFailures,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_applied_pages_total",
            value: clientHealth.timelineCatchUpAppliedPages,
            to: &lines
        )
        appendCounter(
            "im_client_timeline_catch_up_applied_items_total",
            value: clientHealth.timelineCatchUpAppliedItems,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_hint_to_request_max_millis",
            value: clientHealth.maxTimelineCatchUpHintToRequestMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_hint_to_request_avg_millis",
            value: clientHealth.averageTimelineCatchUpHintToRequestMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_request_max_millis",
            value: clientHealth.maxTimelineCatchUpRequestMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_request_avg_millis",
            value: clientHealth.averageTimelineCatchUpRequestMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_hint_to_apply_max_millis",
            value: clientHealth.maxTimelineCatchUpHintToApplyMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_hint_to_apply_avg_millis",
            value: clientHealth.averageTimelineCatchUpHintToApplyMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_initial_jitter_max_millis",
            value: clientHealth.maxTimelineCatchUpSelectedHintInitialJitterMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_initial_jitter_avg_millis",
            value: clientHealth.averageTimelineCatchUpSelectedHintInitialJitterMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_min_interval_max_millis",
            value: clientHealth.maxTimelineCatchUpSelectedHintMinimumIntervalMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_min_interval_avg_millis",
            value: clientHealth.averageTimelineCatchUpSelectedHintMinimumIntervalMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_micro_batch_max_millis",
            value: clientHealth.maxTimelineCatchUpSelectedHintMicroBatchMillis,
            to: &lines
        )
        appendGauge(
            "im_client_timeline_catch_up_config_selected_hint_micro_batch_avg_millis",
            value: clientHealth.averageTimelineCatchUpSelectedHintMicroBatchMillis,
            to: &lines
        )
        appendGauge("im_projection_lag_millis", value: liveLag.projectionLagMillis, to: &lines)
        appendGauge("im_search_lag_millis", value: liveLag.searchLagMillis, to: &lines)
        appendGauge("im_replay_pending_events", value: liveLag.replayPendingEvents, to: &lines)
        appendGauge("im_replay_failed_events", value: liveLag.replayFailedEvents, to: &lines)

        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "text", subType: "plain", parameters: ["version": "0.0.4"])
        return Response(status: .ok, headers: headers, body: .init(string: lines.joined(separator: "\n") + "\n"))
    }

    private func appendGauge(_ name: String, value: Int, to lines: inout [String]) {
        lines.append("# TYPE \(name) gauge")
        lines.append("\(name) \(value)")
    }

    private func appendGauge(_ name: String, value: UInt64, to lines: inout [String]) {
        lines.append("# TYPE \(name) gauge")
        lines.append("\(name) \(value)")
    }

    private func appendCounter(_ name: String, value: Int, to lines: inout [String]) {
        lines.append("# TYPE \(name) counter")
        lines.append("\(name) \(value)")
    }

    private func appendCounterSample(
        _ name: String,
        value: Int,
        labels: [String: String],
        to lines: inout [String]
    ) {
        lines.append("\(name)\(labelString(labels)) \(value)")
    }

    private func appendGaugeSample(
        _ name: String,
        value: Int,
        labels: [String: String],
        to lines: inout [String]
    ) {
        lines.append("\(name)\(labelString(labels)) \(value)")
    }

    private func appendHistogramSamples(
        _ name: String,
        histogram: IMTimelineReadMetrics.LatencyHistogram,
        labels: [String: String],
        to lines: inout [String]
    ) {
        for (index, upperBound) in histogram.bucketUpperBoundsMilliseconds.enumerated() {
            var bucketLabels = labels
            bucketLabels["le"] = String(upperBound)
            lines.append("\(name)_bucket\(labelString(bucketLabels)) \(histogram.bucketCounts[index])")
        }
        var infiniteBucketLabels = labels
        infiniteBucketLabels["le"] = "+Inf"
        lines.append("\(name)_bucket\(labelString(infiniteBucketLabels)) \(histogram.count)")
        lines.append("\(name)_sum\(labelString(labels)) \(histogram.sumMilliseconds)")
        lines.append("\(name)_count\(labelString(labels)) \(histogram.count)")
    }

    private func appendMessageWriteStageMetrics(
        _ stages: [String: IMMessageWriteMetrics.StageSnapshot],
        to lines: inout [String]
    ) {
        guard !stages.isEmpty else {
            return
        }
        lines.append("# TYPE im_message_write_pipeline_stage_count_total counter")
        lines.append("# TYPE im_message_write_pipeline_stage_duration_millis_total counter")
        lines.append("# TYPE im_message_write_pipeline_stage_duration_millis_max gauge")
        lines.append("# TYPE im_message_write_pipeline_stage_duration_millis_avg gauge")
        for (stageName, stage) in stages.sorted(by: { $0.key < $1.key }) {
            let labels = ["stage": stageName]
            appendCounterSample(
                "im_message_write_pipeline_stage_count_total",
                value: stage.count,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_message_write_pipeline_stage_duration_millis_total",
                value: stage.totalMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_message_write_pipeline_stage_duration_millis_max",
                value: stage.maxMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_message_write_pipeline_stage_duration_millis_avg",
                value: stage.averageMillis,
                labels: labels,
                to: &lines
            )
        }
    }

    private func appendStreamGroupMetrics(
        _ groups: [(groupID: String, snapshot: IMStreamMetrics.Snapshot)],
        to lines: inout [String]
    ) {
        for group in groups {
            let labels = ["consumer_group": group.groupID]
            let stream = group.snapshot
            appendCounterSample("im_stream_consumed_events_total", value: stream.consumedEvents, labels: labels, to: &lines)
            appendCounterSample("im_stream_duplicate_events_total", value: stream.duplicateEvents, labels: labels, to: &lines)
            appendCounterSample("im_stream_failed_events_total", value: stream.failedEvents, labels: labels, to: &lines)
            appendCounterSample(
                "im_stream_dead_letter_published_events_total",
                value: stream.deadLetterPublishedEvents,
                labels: labels,
                to: &lines
            )
            appendCounterSample("im_stream_processed_runs_total", value: stream.processedRuns, labels: labels, to: &lines)
            appendCounterSample(
                "im_stream_message_created_runs_total",
                value: stream.messageCreatedRuns,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_message_created_run_events_total",
                value: stream.messageCreatedRunEventCount,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_message_created_run_events_avg",
                value: stream.averageMessageCreatedRunEventCount,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_message_created_run_max_events",
                value: stream.maxMessageCreatedRunEventCount,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_slow_processing_runs_total",
                value: stream.slowProcessingRuns,
                labels: labels,
                to: &lines
            )
            appendCounterSample("im_stream_lagged_runs_total", value: stream.laggedRuns, labels: labels, to: &lines)
            appendCounterSample(
                "im_stream_processing_batches_total",
                value: stream.processingBatches,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_processing_batch_events_total",
                value: stream.processingBatchEventCount,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_processing_batch_events_avg",
                value: stream.averageProcessingBatchEventCount,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_processing_batch_max_events",
                value: stream.maxProcessingBatchEventCount,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_batch_fill_waits_total",
                value: stream.batchFillWaits,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_batch_fill_wait_millis_total",
                value: stream.batchFillWaitMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_batch_fill_wait_avg_millis",
                value: stream.averageBatchFillWaitMillis,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_batch_fill_events_total",
                value: stream.batchFillEventCount,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_batch_fill_skipped_batches_total",
                value: stream.batchFillSkippedBatches,
                labels: labels,
                to: &lines
            )
            appendCounterSample(
                "im_stream_queue_producer_waits_total",
                value: stream.queueProducerWaits,
                labels: labels,
                to: &lines
            )
            appendGaugeSample("im_stream_queue_depth", value: stream.queueCurrentDepth, labels: labels, to: &lines)
            appendGaugeSample("im_stream_queue_max_depth", value: stream.queueMaxDepth, labels: labels, to: &lines)
            appendCounterSample("im_stream_run_events_total", value: stream.runEventCount, labels: labels, to: &lines)
            appendGaugeSample("im_stream_run_max_events", value: stream.maxRunEventCount, labels: labels, to: &lines)
            appendGaugeSample(
                "im_stream_run_processing_latency_avg_millis",
                value: stream.averageRunProcessingMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_run_processing_latency_max_millis",
                value: stream.maxRunProcessingMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_run_event_lag_avg_millis",
                value: stream.averageRunEventLagMillis,
                labels: labels,
                to: &lines
            )
            appendGaugeSample(
                "im_stream_run_event_lag_max_millis",
                value: stream.maxRunEventLagMillis,
                labels: labels,
                to: &lines
            )
        }
    }

    private func labelString(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else {
            return ""
        }
        let body = labels
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\(escapeLabelValue($0.value))\"" }
            .joined(separator: ",")
        return "{\(body)}"
    }

    private func escapeLabelValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func average(total: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return total / count
    }

    private func collectLiveLagSnapshot(app: Application) async -> LiveLagSnapshot {
        do {
            let projectionLagMillis = try await oldestUnprocessedOutboxAgeMillis(app: app)
            let searchLagMillis = try await oldestSearchLagMillis(app: app)
            let replayPendingEvents = try await ConversationReplayRecord.query(on: app.imWriteDB)
                .filter(\.$status == ConversationReplayStatus.pending.rawValue)
                .count()
            let replayFailedEvents = try await ConversationReplayRecord.query(on: app.imWriteDB)
                .filter(\.$status == ConversationReplayStatus.failed.rawValue)
                .count()
            return LiveLagSnapshot(
                projectionLagMillis: projectionLagMillis,
                searchLagMillis: searchLagMillis,
                replayPendingEvents: replayPendingEvents,
                replayFailedEvents: replayFailedEvents
            )
        } catch {
            app.logger.debug(
                "Internal metrics live lag collection failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return LiveLagSnapshot()
        }
    }

    private func oldestUnprocessedOutboxAgeMillis(app: Application) async throws -> Int {
        var oldestCreatedAt: Date?
        for shard in app.conversationShardRouter.allCommandDatabases() {
            let event = try await ConversationDomainEvent.query(on: shard.database)
                .group(.or) { group in
                    group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                    group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
                }
                .sort(\.$createdAt, .ascending)
                .first()
            if let createdAt = event?.createdAt, oldestCreatedAt.map({ createdAt < $0 }) ?? true {
                oldestCreatedAt = createdAt
            }
        }
        return oldestCreatedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
    }

    private func oldestSearchLagMillis(app: Application) async throws -> Int {
        var oldestMissingCreatedAt: Date?
        for shard in app.conversationShardRouter.allCommandDatabases() {
            if let createdAt = try await ConversationSearchLagReader(database: shard.database)
                .oldestMissingOrStaleIndexCreatedAt(recentMessageLimit: 1_000),
               oldestMissingCreatedAt.map({ createdAt < $0 }) ?? true {
                oldestMissingCreatedAt = createdAt
            }
        }
        return oldestMissingCreatedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
    }
}

struct ConversationSearchLagReader {
    let database: any Database

    func oldestMissingOrStaleIndexCreatedAt(recentMessageLimit: Int) async throws -> Date? {
        guard let sql = database as? any SQLDatabase else {
            return try await oldestMissingOrStaleIndexCreatedAtWithFluent(recentMessageLimit: recentMessageLimit)
        }

        struct SearchLagRow: Decodable {
            let createdAt: Date?

            enum CodingKeys: String, CodingKey {
                case createdAt = "created_at"
            }
        }

        let indexIDExpression: SQLQueryString
        if sql.dialect.name == "postgresql" {
            indexIDExpression = "LOWER(CAST(\(ident: "recent").\(ident: "id") AS TEXT))"
        } else {
            indexIDExpression = "LOWER(CAST(\(ident: "recent").\(ident: "id") AS TEXT))"
        }

        let row = try await sql.raw("""
            WITH \(ident: "recent") AS (
                SELECT
                    \(ident: "id"),
                    \(ident: "server_sequence"),
                    \(ident: "created_at")
                FROM \(ident: ConversationMessage.schema)
                ORDER BY \(ident: "created_at") DESC
                LIMIT \(bind: recentMessageLimit)
            )
            SELECT \(ident: "recent").\(ident: "created_at")
            FROM \(ident: "recent")
            LEFT JOIN \(ident: ConversationMessageSearchIndex.schema) AS \(ident: "search_index")
              ON \(ident: "search_index").\(ident: "id") = \(indexIDExpression)
            WHERE \(ident: "search_index").\(ident: "id") IS NULL
               OR \(ident: "search_index").\(ident: "server_sequence") != \(ident: "recent").\(ident: "server_sequence")
            ORDER BY \(ident: "recent").\(ident: "created_at") ASC
            LIMIT 1
            """).first(decoding: SearchLagRow.self)
        return row?.createdAt
    }

    private func oldestMissingOrStaleIndexCreatedAtWithFluent(recentMessageLimit: Int) async throws -> Date? {
        let messages = try await ConversationMessage.query(on: database)
            .sort(\.$createdAt, .descending)
            .limit(recentMessageLimit)
            .all()
        var oldestMissingCreatedAt: Date?
        for message in messages {
            let messageID = try message.requireID()
            guard let index = try await ConversationMessageSearchIndex.find(
                ConversationMessageSearchIndex.recordID(messageID: messageID),
                on: database
            ), index.serverSequence == message.serverSequence else {
                let createdAt = message.createdAt ?? Date()
                if oldestMissingCreatedAt.map({ createdAt < $0 }) ?? true {
                    oldestMissingCreatedAt = createdAt
                }
                continue
            }
        }
        return oldestMissingCreatedAt
    }
}

private struct LiveLagSnapshot {
    var projectionLagMillis: Int = 0
    var searchLagMillis: Int = 0
    var replayPendingEvents: Int = 0
    var replayFailedEvents: Int = 0
}

struct IMMetricsConfiguration: Sendable {
    let isEnabled: Bool
    let internalSecret: String?

    static func load(from environment: Environment) -> IMMetricsConfiguration {
        IMMetricsConfiguration(
            isEnabled: parseBooleanEnvironment("IM_METRICS_ENABLED", defaultValue: environment == .production),
            internalSecret: Self.internalSecret()
        )
    }

    func validateStartup(environment: Environment) throws {
        guard environment == .production, isEnabled, internalSecret == nil else {
            return
        }

        throw Abort(
            .internalServerError,
            reason: "Production metrics require IM_METRICS_INTERNAL_SECRET or IM_INTERNAL_SHARED_SECRET."
        )
    }

    func allows(req: Request) -> Bool {
        guard let internalSecret else {
            return false
        }
        return req.headers.first(name: "X-IM-Metrics-Secret") == internalSecret
            || req.headers.first(name: "X-IM-Internal-Secret") == internalSecret
    }

    private static func internalSecret() -> String? {
        let rawSecret = Environment.get("IM_METRICS_INTERNAL_SECRET")
            ?? Environment.get("IM_INTERNAL_SHARED_SECRET")
        let secret = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret?.isEmpty == false ? secret : nil
    }
}

private struct IMMetricsConfigurationStorageKey: StorageKey {
    typealias Value = IMMetricsConfiguration
}

extension Application {
    var metricsConfiguration: IMMetricsConfiguration {
        get {
            if let configuration = storage[IMMetricsConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMMetricsConfiguration.load(from: environment)
            storage[IMMetricsConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMMetricsConfigurationStorageKey.self] = newValue }
    }
}
