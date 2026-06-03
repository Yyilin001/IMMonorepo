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
        let outbox = await req.application.outboxMetrics.currentSnapshot()
        let hotConversations = await req.application.hotConversationMetrics.currentSnapshot()
        let http = await req.application.httpMetrics.currentSnapshot()
        let database = await req.application.databaseMetrics.currentSnapshot()
        let stream = await req.application.streamMetrics.currentSnapshot()
        let aiStream = await req.application.aiStreamMetrics.currentSnapshot()
        let messageWrite = await req.application.messageWriteMetrics.currentSnapshot()
        let authSessionCache = await req.application.authSessionCacheMetrics.currentSnapshot()
        let clientHealth = await req.application.clientHealthMetrics.currentSnapshot()
        let liveLag = await collectLiveLagSnapshot(app: req.application)

        var lines: [String] = []
        appendCounter("im_http_requests_total", value: http.requestCount, to: &lines)
        appendCounter("im_http_request_failures_total", value: http.failedRequestCount, to: &lines)
        appendGauge("im_http_request_latency_avg_millis", value: http.averageLatencyMillis, to: &lines)
        appendGauge("im_http_request_latency_max_millis", value: http.maxLatencyMillis, to: &lines)
        appendGauge("im_tcp_connections", value: routing.currentTCPConnectionCount, to: &lines)
        appendGauge("im_tcp_channels", value: routing.currentTCPChannelCount, to: &lines)
        appendCounter("im_tcp_channel_active_total", value: routing.tcpChannelActiveCount, to: &lines)
        appendCounter("im_tcp_channel_inactive_total", value: routing.tcpChannelInactiveCount, to: &lines)
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
        appendCounter("im_tcp_close_peer_or_unknown_total", value: routing.tcpClosePeerOrUnknownCount, to: &lines)
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
        appendCounter("im_redis_presence_route_cache_hits_total", value: routing.redisPresenceRouteCacheHits, to: &lines)
        appendCounter("im_redis_presence_route_cache_misses_total", value: routing.redisPresenceRouteCacheMisses, to: &lines)
        appendCounter("im_redis_presence_pipeline_lookups_total", value: routing.redisPresencePipelineLookupCount, to: &lines)
        appendCounter("im_redis_presence_pipeline_lookup_users_total", value: routing.redisPresencePipelineLookupUserCount, to: &lines)
        appendCounter("im_redis_presence_stale_cleanup_total", value: routing.redisPresenceStaleCleanupCount, to: &lines)
        appendCounter("im_realtime_delivery_missing_row_total", value: routing.realtimeDeliveryMissingRowCount, to: &lines)
        appendCounter("im_realtime_delivery_invalid_payload_total", value: routing.invalidRealtimeDeliveryPayloadCount, to: &lines)
        appendCounter("im_cross_node_dispatch_total", value: routing.crossNodeDispatchCount, to: &lines)
        appendCounter("im_cross_node_dispatch_failures_total", value: routing.crossNodeDispatchFailureCount, to: &lines)
        appendCounter("im_outbox_processed_events_total", value: outbox.processedEvents, to: &lines)
        appendCounter("im_outbox_failed_events_total", value: outbox.failedEvents, to: &lines)
        appendGauge("im_outbox_backlog_events", value: outbox.backlogCount, to: &lines)
        appendGauge("im_outbox_oldest_pending_age_millis", value: outbox.oldestPendingAgeMillis, to: &lines)
        appendCounter("im_hot_conversation_rejections_total", value: hotConversations.rejectedMessages, to: &lines)
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
