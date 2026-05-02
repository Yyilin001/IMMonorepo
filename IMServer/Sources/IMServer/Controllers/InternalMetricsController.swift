import Vapor
import Fluent

struct InternalMetricsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("internal").get("metrics", use: metrics)
    }

    func metrics(req: Request) async throws -> Response {
        guard req.application.metricsConfiguration.isEnabled else {
            throw Abort(.notFound)
        }

        let routing = await req.application.routingMetrics.currentSnapshot()
        let outbox = await req.application.outboxMetrics.currentSnapshot()
        let hotConversations = await req.application.hotConversationMetrics.currentSnapshot()
        let http = await req.application.httpMetrics.currentSnapshot()
        let database = await req.application.databaseMetrics.currentSnapshot()
        let stream = await req.application.streamMetrics.currentSnapshot()
        let messageWrite = await req.application.messageWriteMetrics.currentSnapshot()
        let liveLag = await collectLiveLagSnapshot(app: req.application)

        var lines: [String] = []
        appendCounter("im_http_requests_total", value: http.requestCount, to: &lines)
        appendCounter("im_http_request_failures_total", value: http.failedRequestCount, to: &lines)
        appendGauge("im_http_request_latency_avg_millis", value: http.averageLatencyMillis, to: &lines)
        appendGauge("im_http_request_latency_max_millis", value: http.maxLatencyMillis, to: &lines)
        appendGauge("im_tcp_connections", value: routing.currentTCPConnectionCount, to: &lines)
        appendCounter("im_redis_route_registrations_total", value: routing.redisRouteRegistrations, to: &lines)
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
        appendGauge("im_db_operation_latency_avg_millis", value: database.averageLatencyMillis, to: &lines)
        appendGauge("im_db_operation_latency_max_millis", value: database.maxLatencyMillis, to: &lines)
        appendCounter("im_stream_consumed_events_total", value: stream.consumedEvents, to: &lines)
        appendCounter("im_stream_duplicate_events_total", value: stream.duplicateEvents, to: &lines)
        appendCounter("im_stream_failed_events_total", value: stream.failedEvents, to: &lines)
        appendCounter("im_stream_dead_letter_published_events_total", value: stream.deadLetterPublishedEvents, to: &lines)
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
            let messages = try await ConversationMessage.query(on: shard.database)
                .sort(\.$createdAt, .descending)
                .limit(1_000)
                .all()
            for message in messages {
                let messageID = try message.requireID()
                guard let index = try await ConversationMessageSearchIndex.find(
                    ConversationMessageSearchIndex.recordID(messageID: messageID),
                    on: shard.database
                ), index.serverSequence == message.serverSequence else {
                    let createdAt = message.createdAt ?? Date()
                    if oldestMissingCreatedAt.map({ createdAt < $0 }) ?? true {
                        oldestMissingCreatedAt = createdAt
                    }
                    continue
                }
            }
        }
        return oldestMissingCreatedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
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

    static func load(from environment: Environment) -> IMMetricsConfiguration {
        IMMetricsConfiguration(
            isEnabled: parseBooleanEnvironment("IM_METRICS_ENABLED", defaultValue: environment == .production)
        )
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
