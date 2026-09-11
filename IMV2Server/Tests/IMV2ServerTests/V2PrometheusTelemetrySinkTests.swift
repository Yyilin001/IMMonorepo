import Foundation
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 Prometheus telemetry exporter")
struct V2PrometheusTelemetrySinkTests {
    @Test("command diagnostic logging keeps an exact bounded burst per result key")
    func boundsCommandDiagnosticLogging() {
        let now = Mutex<UInt64>(1_000_000_000)
        let limiter = V2CommandDiagnosticLogLimiter(
            maximumPerSecond: 2,
            nowNanoseconds: { now.withLock { $0 } }
        )

        #expect(limiter.admit(
            command: .sendMessage,
            outcome: .rejected,
            rejection: .serverBusy
        ))
        #expect(limiter.admit(
            command: .sendMessage,
            outcome: .rejected,
            rejection: .serverBusy
        ))
        #expect(!limiter.admit(
            command: .sendMessage,
            outcome: .rejected,
            rejection: .serverBusy
        ))
        #expect(limiter.admit(
            command: .sendMessage,
            outcome: .rejected,
            rejection: .rateLimited
        ))

        now.withLock { $0 = 2_000_000_000 }
        #expect(limiter.admit(
            command: .sendMessage,
            outcome: .rejected,
            rejection: .serverBusy
        ))
    }

    @Test("command diagnostic logging remains bounded under concurrent callers")
    func serializesConcurrentCommandDiagnosticLogging() async {
        let limiter = V2CommandDiagnosticLogLimiter(
            maximumPerSecond: 20,
            nowNanoseconds: { 1_000_000_000 }
        )
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    limiter.admit(
                        command: .sendMessage,
                        outcome: .rejected,
                        rejection: .serverBusy
                    )
                }
            }
            var count = 0
            for await result in group where result {
                count += 1
            }
            return count
        }

        #expect(admitted == 20)
    }

    @Test("exporter aggregates only closed labels and never renders trace IDs")
    func aggregatesPrivacySafeMetrics() async throws {
        let sink = V2PrometheusTelemetrySink()
        let trace = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
        await sink.record(.gatewayCommand(
            traceID: trace,
            command: .sendMessage,
            outcome: .rejected,
            rejection: .rateLimited,
            elapsedMilliseconds: 12
        ))
        await sink.record(.fanoutProgress(
            traceID: trace,
            claimedOutboxRows: 2,
            publishedOutboxRows: 1,
            releasedOutboxRows: -1,
            pausedOutboxRows: 2,
            claimedDeliveries: 4,
            committedDeliveries: 3,
            staleDeliveries: 1,
            staleRouteDeliveries: 1,
            releasedDeliveries: 2,
            pausedDeliveries: 3,
            relayElapsedMilliseconds: 3,
            deliveryElapsedMilliseconds: 5,
            elapsedMilliseconds: 8
        ))
        await sink.record(.fanoutFailure(traceID: trace, stage: .delivery, elapsedMilliseconds: 1))

        let metrics = await sink.renderPrometheus()

        #expect(metrics.contains("im_v2_gateway_commands_total{command=\"send_message\",outcome=\"rejected\",rejection=\"RATE_LIMITED\"} 1"))
        #expect(metrics.contains("im_v2_gateway_command_duration_milliseconds_sum{command=\"send_message\",outcome=\"rejected\",rejection=\"RATE_LIMITED\"} 12"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"claimed\"} 2"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"released\"} 0"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"paused\"} 2"))
        #expect(metrics.contains("im_v2_fanout_deliveries_total{state=\"stale_route\"} 1"))
        #expect(metrics.contains("im_v2_fanout_deliveries_total{state=\"paused\"} 3"))
        #expect(metrics.contains("im_v2_fanout_relay_duration_milliseconds_sum 3"))
        #expect(metrics.contains("im_v2_fanout_delivery_duration_milliseconds_sum 5"))
        #expect(metrics.contains("im_v2_fanout_failures_total{stage=\"delivery\"} 1"))
        #expect(!metrics.contains(trace.uuidString))
        #expect(!metrics.contains("room_id"))
        #expect(!metrics.contains("user_id"))
    }

    @Test("exporter keeps exact counters under concurrent gateway recording")
    func aggregatesConcurrentGatewayCommandsExactly() async {
        let sink = V2PrometheusTelemetrySink()
        let taskCount = 100
        let recordsPerTask = 100

        await withTaskGroup(of: Void.self) { group in
            for task in 0..<taskCount {
                group.addTask {
                    for record in 0..<recordsPerTask {
                        await sink.record(.gatewayCommand(
                            traceID: UUID(
                                uuidString: String(
                                    format: "00000000-0000-0000-%04X-%012X",
                                    task,
                                    record
                                )
                            )!,
                            command: .sendMessage,
                            outcome: .accepted,
                            rejection: nil,
                            elapsedMilliseconds: 1
                        ))
                    }
                }
            }
        }

        let metrics = await sink.renderPrometheus()
        let expected = taskCount * recordsPerTask
        #expect(metrics.contains(
            "im_v2_gateway_commands_total{command=\"send_message\",outcome=\"accepted\",rejection=\"none\"} \(expected)"
        ))
        #expect(metrics.contains(
            "im_v2_gateway_command_duration_milliseconds_sum{command=\"send_message\",outcome=\"accepted\",rejection=\"none\"} \(expected)"
        ))
    }

    @Test("transport metrics retain only aggregate queue pressure and closed closure reasons")
    func rendersTransportMetrics() async {
        let metrics = V2GatewayTransportMetrics()
        metrics.connectionOpened()
        metrics.connectionOpened()
        metrics.observeQueuedInboundBytes(1_024)
        metrics.observeQueuedInboundBytes(-1)
        metrics.foregroundFrameSubmitted(
            bytes: 120,
            recoveryQueued: false,
            recoveryReplaced: false,
            queuedBytes: 120
        )
        metrics.foregroundFrameSubmitted(
            bytes: 140,
            recoveryQueued: true,
            recoveryReplaced: true,
            queuedBytes: 260
        )
        metrics.foregroundWriteBatch(frames: 2, bytes: 260)
        metrics.foregroundWriteDeferredForWritability()
        metrics.foregroundGroupEventSubmitted(
            duplicateSuppressed: false,
            outOfOrder: true,
            lateAfterPublication: false,
            degradedToWake: false
        )
        metrics.foregroundGroupEventSubmitted(
            duplicateSuppressed: true,
            outOfOrder: false,
            lateAfterPublication: true,
            degradedToWake: true
        )
        metrics.foregroundGroupEventBatchPublished(eventCount: 7)
        metrics.foregroundGroupInboundNotificationDropped()
        metrics.foregroundGroupCoveredWakeSuppressed()
        metrics.foregroundGroupWakeDeferred()
        metrics.foregroundGroupDeferredWakeDelivered()
        metrics.connectionClosed(reason: .idleTimeout)
        metrics.connectionRejected(reason: .connectionLimit)

        let snapshot = metrics.gatewayTransportMetricsSnapshot()
        #expect(snapshot.activeConnections == 1)
        #expect(snapshot.peakQueuedInboundBytes == 1_024)
        #expect(snapshot.closureCount(for: .idleTimeout) == 1)
        #expect(snapshot.closureCount(for: .connectionLimit) == 1)
        #expect(snapshot.closureCount(for: .frameLimitViolation) == 0)
        #expect(snapshot.closureCount(for: .requestFailure) == 0)
        #expect(snapshot.foregroundFramesSubmitted == 2)
        #expect(snapshot.foregroundBytesSubmitted == 260)
        #expect(snapshot.foregroundRecoveryFramesQueued == 1)
        #expect(snapshot.foregroundRecoveryFramesReplaced == 1)
        #expect(snapshot.foregroundFramesWritten == 2)
        #expect(snapshot.foregroundBytesWritten == 260)
        #expect(snapshot.foregroundWriteBatches == 1)
        #expect(snapshot.foregroundNonWritableDeferrals == 1)
        #expect(snapshot.peakQueuedForegroundBytes == 260)
        #expect(snapshot.foregroundGroupEventsSubmitted == 2)
        #expect(snapshot.foregroundGroupEventsPublished == 7)
        #expect(snapshot.foregroundGroupEventBatchesPublished == 1)
        #expect(snapshot.foregroundGroupEventDuplicatesSuppressed == 1)
        #expect(snapshot.foregroundGroupEventOutOfOrderArrivals == 1)
        #expect(snapshot.foregroundGroupEventLateArrivals == 1)
        #expect(snapshot.foregroundGroupEventBatchDegradations == 1)
        #expect(snapshot.foregroundGroupInboundNotificationsDropped == 1)
        #expect(snapshot.foregroundGroupCoveredWakesSuppressed == 1)
        #expect(snapshot.foregroundGroupWakesDeferred == 1)
        #expect(snapshot.foregroundGroupDeferredWakesDelivered == 1)

        let rendered = v2RenderPrometheusGatewayTransportMetrics(snapshot)
        #expect(rendered.contains("im_v2_gateway_transport_active_connections 1"))
        #expect(rendered.contains("im_v2_gateway_inbound_queue_peak_bytes 1024"))
        #expect(rendered.contains("im_v2_gateway_foreground_frames_submitted_total 2"))
        #expect(rendered.contains("im_v2_gateway_foreground_recovery_frames_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_frames_written_total 2"))
        #expect(rendered.contains("im_v2_gateway_foreground_write_batches_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_queue_peak_bytes 260"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_events_submitted_total 2"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_events_published_total 7"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_event_batches_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_event_out_of_order_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_event_late_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_event_degradations_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_inbound_notifications_dropped_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_covered_wakes_suppressed_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_wakes_deferred_total 1"))
        #expect(rendered.contains("im_v2_gateway_foreground_group_deferred_wakes_delivered_total 1"))
        #expect(rendered.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 1"))
        #expect(!rendered.contains("user_id"))
        #expect(!rendered.contains("device_id"))
    }

    @Test("transport metrics remain exact under concurrent gateway callbacks")
    func serializesConcurrentTransportMetricUpdates() async {
        let metrics = V2GatewayTransportMetrics()
        let workers = 12
        let iterations = 400

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    for value in 0..<iterations {
                        metrics.connectionOpened()
                        metrics.observeQueuedInboundBytes(value)
                        metrics.connectionClosed(reason: .requestFailure)
                    }
                }
            }
        }

        let snapshot = metrics.gatewayTransportMetricsSnapshot()
        #expect(snapshot.activeConnections == 0)
        #expect(snapshot.peakQueuedInboundBytes == iterations - 1)
        #expect(snapshot.closureCount(for: .requestFailure) == UInt64(workers * iterations))
    }

    @Test("durable-work metrics use fixed aggregate labels and advertise a failed scrape")
    func rendersDurableWorkMetrics() {
        let snapshot = V2DurableWorkMetricsSnapshot(
            isAvailable: false,
            servedFromLastKnownGood: true,
            lastSuccessfulRefreshAgeSeconds: 77,
            readyRoomOutboxRows: -1,
            leasedRoomOutboxRows: 2,
            scheduledRoomOutboxRows: 3,
            pausedRoomOutboxRows: 4,
            oldestUnfinishedRoomOutboxAgeSeconds: 120,
            readyDirectProfileUpdates: 15,
            leasedDirectProfileUpdates: 16,
            readyReadReceiptPreferencePropagations: 29,
            leasedReadReceiptPreferencePropagations: 30,
            scheduledReadReceiptPreferencePropagations: 31,
            pausedReadReceiptPreferencePropagations: 32,
            openFanoutPlans: 5,
            readyFanoutDeliveries: 6,
            leasedFanoutDeliveries: 7,
            scheduledFanoutDeliveries: 8,
            pausedFanoutDeliveries: 9,
            oldestUnfinishedFanoutDeliveryAgeSeconds: 240,
            terminalFanoutCompletionUnits: 10,
            oldestTerminalFanoutCompletionAgeSeconds: 11,
            readyContentReviews: 17,
            leasedContentReviews: 18,
            scheduledContentReviews: 19,
            pausedContentReviews: 20,
            readyMediaScans: 21,
            leasedMediaScans: 22,
            scheduledMediaScans: 23,
            pausedMediaScans: 24,
            readyMediaPurges: 25,
            leasedMediaPurges: 26,
            scheduledMediaPurges: 27,
            pausedMediaPurges: 28,
            userSyncLogEstimatedRows: 34,
            userSyncLogRelationBytes: 35,
            readyUserProjections: 36,
            scheduledUserProjections: 37,
            pausedUserProjections: 38,
            maximumUserProjectionLag: 39,
            buildingSnapshotArtifacts: 40,
            failedSnapshotArtifacts: 41,
            oldestBuildingSnapshotAgeSeconds: 42,
            projectionVersionGCBacklogEstimatedRows: 43,
            messageProjectionStatesEstimatedRows: 45,
            messageProjectionStatesRelationBytes: 46,
            messageProjectionReferenceEstimatedRows: 47,
            messageProjectionBackfillEstimatedRows: 48,
            messageProjectionInlinePayloadEstimatedRows: 49,
            uncompactedProjectedRecords: 44,
            pendingSyncRecordsAcrossDevices: 10,
            resetPendingDevices: 11,
            readyPushWakes: 12,
            leasedPushWakes: 13,
            suppressedPushWakes: 14
        )

        let rendered = v2RenderPrometheusDurableWorkMetrics(snapshot)

        #expect(rendered.contains("im_v2_durable_work_metrics_available 0"))
        #expect(rendered.contains("im_v2_durable_work_metrics_last_known_good 1"))
        #expect(rendered.contains("im_v2_durable_work_metrics_last_success_age_seconds 77"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"ready\"} 0"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"leased\"} 2"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"scheduled\"} 3"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"paused\"} 4"))
        #expect(rendered.contains("im_v2_room_outbox_oldest_unfinished_age_seconds 120"))
        #expect(rendered.contains("im_v2_direct_profile_update_backlog{state=\"ready\"} 15"))
        #expect(rendered.contains("im_v2_direct_profile_update_backlog{state=\"leased\"} 16"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"ready\"} 29"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"leased\"} 30"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"scheduled\"} 31"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"paused\"} 32"))
        #expect(rendered.contains("im_v2_fanout_plans_open 5"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"ready\"} 6"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"leased\"} 7"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"scheduled\"} 8"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"paused\"} 9"))
        #expect(rendered.contains("im_v2_fanout_delivery_oldest_unfinished_age_seconds 240"))
        #expect(rendered.contains("im_v2_fanout_completion_release_backlog 10"))
        #expect(rendered.contains("im_v2_fanout_completion_release_oldest_age_seconds 11"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"ready\"} 17"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"leased\"} 18"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"scheduled\"} 19"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"paused\"} 20"))
        #expect(rendered.contains("im_v2_media_scan_backlog{state=\"ready\"} 21"))
        #expect(rendered.contains("im_v2_media_scan_backlog{state=\"paused\"} 24"))
        #expect(rendered.contains("im_v2_media_purge_backlog{state=\"ready\"} 25"))
        #expect(rendered.contains("im_v2_media_purge_backlog{state=\"paused\"} 28"))
        #expect(rendered.contains("im_v2_user_sync_log_estimated_rows 34"))
        #expect(rendered.contains("im_v2_user_sync_log_relation_bytes 35"))
        #expect(rendered.contains("im_v2_user_projection_effects_estimated_rows 0"))
        #expect(rendered.contains("im_v2_user_projection_effects_relation_bytes 0"))
        #expect(rendered.contains("im_v2_user_projection_backlog{state=\"paused\"} 38"))
        #expect(rendered.contains("im_v2_user_projection_maximum_lag_records 39"))
        #expect(rendered.contains("im_v2_snapshot_artifacts{state=\"building\"} 40"))
        #expect(rendered.contains("im_v2_snapshot_oldest_building_age_seconds 42"))
        #expect(rendered.contains("im_v2_projection_version_gc_backlog_estimated_rows 43"))
        #expect(rendered.contains("im_v2_message_projection_states_estimated_rows 45"))
        #expect(rendered.contains("im_v2_message_projection_states_relation_bytes 46"))
        #expect(rendered.contains("im_v2_message_projection_references_estimated_rows 47"))
        #expect(rendered.contains("im_v2_message_projection_backfill_estimated_rows 48"))
        #expect(rendered.contains("im_v2_message_projection_inline_payload_estimated_rows 49"))
        #expect(rendered.contains("im_v2_sync_uncompacted_projected_records 44"))
        #expect(rendered.contains("im_v2_sync_pending_records_across_devices 10"))
        #expect(rendered.contains("im_v2_sync_reset_pending_devices 11"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"ready\"} 12"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"leased\"} 13"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"suppressed\"} 14"))
        #expect(!rendered.contains("room_id"))
        #expect(!rendered.contains("user_id"))
        #expect(!rendered.contains("bucket="))
    }
}
