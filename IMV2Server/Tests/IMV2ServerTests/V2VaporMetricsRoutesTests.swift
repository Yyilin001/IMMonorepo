import Foundation
@testable import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor metrics routes")
struct V2VaporMetricsRoutesTests {
    @Test("metrics route exposes only aggregate Prometheus text with no-store semantics")
    func rendersAggregateMetrics() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        await telemetry.record(.gatewayCommand(
            traceID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            command: .sendMessage,
            outcome: .accepted,
            rejection: nil,
            elapsedMilliseconds: 12
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry)

        try await app.testing().test(.GET, "metrics") { response async throws in
            #expect(response.status == .ok)
            let contentType = try #require(response.headers.first(name: .contentType))
            #expect(contentType.contains("text/plain"))
            #expect(contentType.contains("version=0.0.4"))
            #expect(contentType.contains("charset=utf-8"))
            #expect(response.headers.first(name: .cacheControl) == "no-store, no-cache")
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_commands_total{command=\"send_message\",outcome=\"accepted\",rejection=\"none\"} 1"))
            #expect(!body.contains("00000000-0000-0000-0000-000000000901"))
        }
    }

    @Test("metrics route includes only aggregate live connection gauges when configured")
    func rendersConnectionGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let connectionMetrics = ConnectionMetricsProbe(snapshot: .init(activeDevices: 2, activeConnections: 3))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, connectionMetrics: connectionMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            #expect(response.status == .ok)
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_active_devices 2"))
            #expect(body.contains("im_v2_gateway_active_connections 3"))
            #expect(!body.contains("user_id"))
            #expect(!body.contains("device_id"))
        }
    }

    @Test("metrics route includes aggregate transport gauges when configured")
    func rendersTransportGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let transportMetrics = TransportMetricsProbe(snapshot: .init(
            activeConnections: 4,
            peakQueuedInboundBytes: 512,
            closures: [.idleTimeout: 2]
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, transportMetrics: transportMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_transport_active_connections 4"))
            #expect(body.contains("im_v2_gateway_inbound_queue_peak_bytes 512"))
            #expect(body.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 2"))
        }
    }

    @Test("metrics route includes bounded runtime-pressure gauges and counters")
    func rendersRuntimePressureMetrics() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let source = RuntimePressureMetricsProbe(snapshot: .init(
            databaseWork: .init(
                foregroundWrite: .init(
                    inFlight: 4, queued: 3, admittedRequests: 20,
                    queueFullRejections: 2, timeoutRejections: 3,
                    cancelledRequests: 1,
                    queueWait: .init(
                        samples: 5,
                        sumMilliseconds: 75,
                        cumulativeBuckets: [.milliseconds25: 4, .milliseconds50: 5]
                    )
                ),
                interactiveRead: .init(
                    inFlight: 1, queued: 2, admittedRequests: 12,
                    queueFullRejections: 4, timeoutRejections: 0,
                    cancelledRequests: 0
                ),
                sync: .init(
                    inFlight: 2, queued: 1, admittedRequests: 10,
                    queueFullRejections: 0, timeoutRejections: 1,
                    cancelledRequests: 0
                )
            ),
            databasePools: .init(pools: [
                .init(poolClass: .shared, eventLoopHandles: 4, connectionCeiling: 64)
            ]),
            syncWake: .init(
                pendingUsers: 6, inFlightUsers: 2,
                coalescedNotifications: 7, deliveredNotifications: 9,
                droppedNotifications: 8
            ),
            shardAdmissionCommandCredits: .init(
                activeCredits: 12, inFlightCredits: 3,
                batchReservations: 4, databaseCreditsReserved: 64,
                committedCredits: 51, returnedCredits: 2,
                expiredCreditsDiscarded: 1, capacityRejections: 5
            ),
            roomAdmissionCommandCredits: .init(
                activeCredits: 6, inFlightCredits: 2,
                batchReservations: 8, databaseCreditsReserved: 96,
                committedCredits: 81, returnedCredits: 3,
                expiredCreditsDiscarded: 4, capacityRejections: 7,
                promotedHotRooms: 5
            ),
            directRoomLogAppendBatching: .init(
                pendingRequests: 7,
                inFlightBatches: 3,
                activeRooms: 5,
                dequeuedRequests: 151,
                queueWaitMillisecondsTotal: 701,
                queueWaitMillisecondsMax: 19,
                completedBatches: 17,
                batchExecutionMillisecondsTotal: 901,
                batchExecutionMillisecondsMax: 73,
                stagingQueueFullRejections: 2,
                cancelledPendingRequests: 1,
                baseDelayFlushes: 11,
                highActivityDelayFlushes: 13,
                highActivityDelayScheduled: true,
                atomicBatchAttempts: 17,
                atomicBatchCommitted: 12,
                atomicBatchFallbacks: 4,
                atomicBatchCommittedRequests: 141,
                atomicBatchFallbackRequests: 29,
                atomicBatchFallbackReasons: [
                    .requestShape: 3,
                    .preflightMismatch: 1,
                ],
                sameRoomDeferredRequests: 23,
                atomicPreclassifiedIndividualRequests: 37,
                singletonDispatches: 6
            ),
            readReceiptBatching: .init(
                pendingRequests: 5,
                inFlightBatches: 2,
                completedBatches: 43,
                completedRequests: 517,
                maximumObservedBatchSize: 24,
                queueFullRejections: 3,
                cancelledPendingRequests: 1
            ),
            directRoomLogAppendStages: .init(histograms: [
                .transaction: .init(
                    samples: 3,
                    sumMilliseconds: 77,
                    maximumMilliseconds: 51,
                    cumulativeBuckets: [.milliseconds32: 2, .milliseconds64: 3]
                )
            ]),
            gatewayEventLoopLag: .init(
                samples: 4,
                sumMilliseconds: 19,
                maximumMilliseconds: 11,
                cumulativeBuckets: [.milliseconds8: 3, .milliseconds16: 4]
            ),
            directSendPolicy: .init(
                entries: 49_999, hits: 211, misses: 31,
                insertions: 61_000, evictions: 11_001, expirations: 7
            ),
            directRoomLogFastAppend: .init(
                entries: 17, lookupHits: 101, lookupMisses: 9,
                attemptedAppends: 83, committedAppends: 79,
                fallbackAppends: 4, insertions: 93,
                evictions: 12, expirations: 3
            ),
            directRoomLogEventCache: .init(
                cachedEvents: 31, cachedRooms: 7, cachedBytes: 4096,
                hits: 101, misses: 9, bypassedIneligibleEvents: 3,
                pendingWrites: 5, droppedWrites: 2
            ),
            preparedGroupEventPageCache: .init(
                entries: 23, bytes: 8192, hits: 401,
                misses: 17, evictions: 4
            ),
            livePresenceRenewals: .init(
                pendingConnections: 4, submittedRequests: 1_001,
                executedBatches: 42, failedBatches: 1, largestBatch: 64
            )
        ))
        V2VaporMetricsRoutes.register(
            on: app, telemetry: telemetry, runtimePressureMetrics: source
        )

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_database_work_in_flight{class=\"foreground_write\"} 4"))
            #expect(body.contains("im_v2_database_work_in_flight{class=\"foreground_control_write\"} 0"))
            #expect(body.contains("im_v2_database_work_queued{class=\"interactive_read\"} 2"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_lanes 1"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_pending_requests 7"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_busiest_lane_pending_requests 7"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_busiest_lane_in_flight 3"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_dequeued_requests_total 151"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total 701"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_execution_milliseconds_max 73"))
            #expect(body.contains("im_v2_direct_send_policy_cache_entries 49999"))
            #expect(body.contains("im_v2_direct_send_policy_cache_lookups_total{outcome=\"hit\"} 211"))
            #expect(body.contains("im_v2_direct_send_policy_cache_removals_total{reason=\"capacity\"} 11001"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_delayed_flushes_total{mode=\"high_activity\"} 13"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_batches_total{outcome=\"committed\"} 12"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_batches_total{outcome=\"shape_fallback\"} 4"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_requests_total{outcome=\"committed\"} 141"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_requests_total{outcome=\"preclassified_individual\"} 37"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_requests_total{outcome=\"singleton_dispatch\"} 6"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_fallback_reasons_total{reason=\"request_shape\"} 3"))
            #expect(body.contains("im_v2_direct_room_log_append_atomic_fallback_reasons_total{reason=\"preflight_mismatch\"} 1"))
            #expect(body.contains("im_v2_direct_room_log_append_same_room_deferred_requests_total 23"))
            #expect(body.contains("im_v2_direct_room_log_append_batch_rejections_total{reason=\"queue_full\"} 2"))
            #expect(body.contains("im_v2_read_receipt_batch_pending_requests 5"))
            #expect(body.contains("im_v2_read_receipt_batch_in_flight 2"))
            #expect(body.contains("im_v2_read_receipt_batches_completed_total 43"))
            #expect(body.contains("im_v2_read_receipt_requests_completed_total 517"))
            #expect(body.contains("im_v2_read_receipt_batch_maximum_observed_size 24"))
            #expect(body.contains("im_v2_read_receipt_batch_rejections_total{reason=\"queue_full\"} 3"))
            #expect(body.contains("im_v2_read_receipt_batch_cancellations_total 1"))
            #expect(body.contains("im_v2_direct_room_log_append_stage_milliseconds_bucket{stage=\"transaction\",le=\"32\"} 2"))
            #expect(body.contains("im_v2_direct_room_log_append_stage_milliseconds_count{stage=\"transaction\"} 3"))
            #expect(body.contains("im_v2_direct_room_log_append_stage_milliseconds_max{stage=\"transaction\"} 51"))
            #expect(body.contains("im_v2_gateway_event_loop_lag_milliseconds_bucket{le=\"8\"} 3"))
            #expect(body.contains("im_v2_gateway_event_loop_lag_milliseconds_count 4"))
            #expect(body.contains("im_v2_gateway_event_loop_lag_milliseconds_max 11"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_entries 17"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_lookups_total{outcome=\"hit\"} 101"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_requests_total{outcome=\"committed\"} 79"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_requests_total{outcome=\"fallback\"} 4"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_insertions_total 93"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_removals_total{reason=\"capacity\"} 12"))
            #expect(body.contains("im_v2_direct_room_log_fast_append_removals_total{reason=\"expired\"} 3"))
            #expect(body.contains("im_v2_direct_room_log_event_cache_entries 31"))
            #expect(body.contains("im_v2_direct_room_log_event_cache_lookups_total{outcome=\"hit\"} 101"))
            #expect(body.contains("im_v2_direct_room_log_event_cache_lookups_total{outcome=\"miss\"} 9"))
            #expect(body.contains("im_v2_direct_room_log_event_cache_pending_writes 5"))
            #expect(body.contains("im_v2_direct_room_log_event_cache_dropped_writes_total 2"))
            #expect(body.contains("im_v2_prepared_group_event_page_cache_entries 23"))
            #expect(body.contains("im_v2_prepared_group_event_page_cache_bytes 8192"))
            #expect(body.contains("im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"hit\"} 401"))
            #expect(body.contains("im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"miss\"} 17"))
            #expect(body.contains("im_v2_prepared_group_event_page_cache_evictions_total 4"))
            #expect(body.contains("im_v2_live_presence_renewal_pending_connections 4"))
            #expect(body.contains("im_v2_live_presence_renewal_requests_total 1001"))
            #expect(body.contains("im_v2_live_presence_renewal_batches_total{outcome=\"executed\"} 42"))
            #expect(body.contains("im_v2_live_presence_renewal_largest_batch 64"))
            #expect(body.contains("im_v2_database_work_queued{class=\"sync\"} 1"))
            #expect(body.contains("im_v2_database_work_rejections_total{class=\"foreground_write\",reason=\"timeout\"} 3"))
            #expect(body.contains("im_v2_database_work_queue_wait_milliseconds_bucket{class=\"foreground_write\",le=\"25\"} 4"))
            #expect(body.contains("im_v2_database_work_queue_wait_milliseconds_bucket{class=\"foreground_write\",le=\"+Inf\"} 5"))
            #expect(body.contains("im_v2_database_work_queue_wait_milliseconds_sum{class=\"foreground_write\"} 75"))
            #expect(body.contains("im_v2_database_pool_event_loop_handles{pool=\"shared\"} 4"))
            #expect(body.contains("im_v2_sync_wake_delivered_total 9"))
            #expect(body.contains("im_v2_database_pool_connection_ceiling{pool=\"shared\"} 64"))
            #expect(body.contains("im_v2_sync_wake_pending_users 6"))
            #expect(body.contains("im_v2_sync_wake_in_flight_users 2"))
            #expect(body.contains("im_v2_sync_wake_coalesced_total 7"))
            #expect(body.contains("im_v2_sync_wake_dropped_total 8"))
            #expect(body.contains("im_v2_shard_admission_command_credits{state=\"available\"} 12"))
            #expect(body.contains("im_v2_shard_admission_command_credits{state=\"in_flight\"} 3"))
            #expect(body.contains("im_v2_shard_admission_command_credit_reservations_total 4"))
            #expect(body.contains("im_v2_shard_admission_command_credits_reserved_total 64"))
            #expect(body.contains("im_v2_shard_admission_command_credits_committed_total 51"))
            #expect(body.contains("im_v2_shard_admission_command_credit_rejections_total 5"))
            #expect(body.contains("im_v2_room_admission_command_credits{state=\"available\"} 6"))
            #expect(body.contains("im_v2_room_admission_command_credits{state=\"in_flight\"} 2"))
            #expect(body.contains("im_v2_room_admission_command_credit_hot_rooms 5"))
            #expect(body.contains("im_v2_room_admission_command_credit_reservations_total 8"))
            #expect(body.contains("im_v2_room_admission_command_credits_reserved_total 96"))
            #expect(body.contains("im_v2_room_admission_command_credits_committed_total 81"))
            #expect(body.contains("im_v2_room_admission_command_credit_rejections_total 7"))
        }
    }

    @Test("metrics route includes durable-work aggregates without accepting a shard label")
    func rendersDurableWorkGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let durableWorkMetrics = DurableWorkMetricsProbe(snapshot: .init(
            isAvailable: true,
            readyUserStateEventRows: 2,
            leasedUserStateEventRows: 1,
            scheduledUserStateEventRows: 6,
            pausedUserStateEventRows: 7,
            readyDirectProfileUpdates: 15,
            leasedDirectProfileUpdates: 16,
            readyReadReceiptPreferencePropagations: 30,
            leasedReadReceiptPreferencePropagations: 31,
            scheduledReadReceiptPreferencePropagations: 32,
            pausedReadReceiptPreferencePropagations: 33,
            readyContentReviews: 18,
            leasedContentReviews: 19,
            scheduledContentReviews: 20,
            pausedContentReviews: 21,
            readyMediaScans: 22,
            leasedMediaScans: 23,
            scheduledMediaScans: 24,
            pausedMediaScans: 25,
            readyMediaPurges: 26,
            leasedMediaPurges: 27,
            scheduledMediaPurges: 28,
            pausedMediaPurges: 29,
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
            uncompactedProjectedRecords: 44,
            pendingSyncRecordsAcrossDevices: 10,
            resetPendingDevices: 11,
            readyPushWakes: 12,
            leasedPushWakes: 13,
            suppressedPushWakes: 14,
            pendingDeviceRevocationEvents: 17,
            pendingRevokedDeviceProjectionCleanupEvents: 18
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, durableWorkMetrics: durableWorkMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_durable_work_metrics_available 1"))
            #expect(body.contains("im_v2_user_state_event_backlog{state=\"ready\"} 2"))
            #expect(body.contains("im_v2_user_state_event_backlog{state=\"scheduled\"} 6"))
            #expect(body.contains("im_v2_user_state_event_backlog{state=\"paused\"} 7"))
            #expect(body.contains("im_v2_direct_profile_update_backlog{state=\"ready\"} 15"))
            #expect(body.contains("im_v2_direct_profile_update_backlog{state=\"leased\"} 16"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"ready\"} 30"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"leased\"} 31"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"scheduled\"} 32"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"paused\"} 33"))
            #expect(body.contains("im_v2_user_sync_log_estimated_rows 34"))
            #expect(body.contains("im_v2_user_sync_log_relation_bytes 35"))
            #expect(body.contains("im_v2_user_projection_backlog{state=\"paused\"} 38"))
            #expect(body.contains("im_v2_user_projection_maximum_lag_records 39"))
            #expect(body.contains("im_v2_snapshot_artifacts{state=\"failed\"} 41"))
            #expect(body.contains("im_v2_projection_version_gc_backlog_estimated_rows 43"))
            #expect(body.contains("im_v2_message_projection_states_estimated_rows 45"))
            #expect(body.contains("im_v2_message_projection_states_relation_bytes 46"))
            #expect(body.contains("im_v2_sync_uncompacted_projected_records 44"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"ready\"} 18"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"leased\"} 19"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"scheduled\"} 20"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"paused\"} 21"))
            #expect(body.contains("im_v2_media_scan_backlog{state=\"scheduled\"} 24"))
            #expect(body.contains("im_v2_media_scan_backlog{state=\"paused\"} 25"))
            #expect(body.contains("im_v2_media_purge_backlog{state=\"scheduled\"} 28"))
            #expect(body.contains("im_v2_media_purge_backlog{state=\"paused\"} 29"))
            #expect(body.contains("im_v2_sync_pending_records_across_devices 10"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"ready\"} 12"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"leased\"} 13"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"suppressed\"} 14"))
            #expect(body.contains("im_v2_device_revocation_events_pending 17"))
            #expect(body.contains("im_v2_revoked_device_projection_cleanup_events_pending 18"))
            #expect(!body.contains("im_v2_device_revocation_events_pending{"))
            #expect(!body.contains("target_shard_bucket"))
        }
    }
}

private struct ConnectionMetricsProbe: V2ConnectionMetricsSource {
    let snapshot: V2ConnectionMetricsSnapshot

    func connectionMetricsSnapshot() async -> V2ConnectionMetricsSnapshot { snapshot }
}

private struct TransportMetricsProbe: V2GatewayTransportMetricsSource {
    let snapshot: V2GatewayTransportMetricsSnapshot

    func gatewayTransportMetricsSnapshot() async -> V2GatewayTransportMetricsSnapshot { snapshot }
}

private struct DurableWorkMetricsProbe: V2DurableWorkMetricsSource {
    let snapshot: V2DurableWorkMetricsSnapshot

    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot { snapshot }
}

private struct RuntimePressureMetricsProbe: V2RuntimePressureMetricsSource {
    let snapshot: V2RuntimePressureMetricsSnapshot

    func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot {
        snapshot
    }
}
