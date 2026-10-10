@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import HTTPTypes
import Foundation
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor metrics routes")
struct V2VaporMetricsRoutesTests {
    @Test("metrics route exposes only aggregate Prometheus text with no-store semantics")
    func rendersAggregateMetrics() async throws {
        var realtime = V2ActorRealtimeMetricsSnapshot()
        realtime.transport = .init(cacheHits: 0, cacheMisses: 0, cacheInvalidations: 0,
            discoveryPasses: 0, discoveryActive: 0, cachedPartitions: 0, reachableNodes: 0,
            controlStarted: 0, controlSettled: 0, controlActive: 0,
            publishStarted: 0, publishSettled: 0, publishActive: 0, rpcRejected: 0, pendingHandshakes: 0,
            backgroundReceptionistLookups: 13, foregroundReceptionistLookups: 2)
        realtime.skew.partitionRetainedBindingsMax = 19
        realtime.skew.partitionRetainedBindingsPeakLifetime = 23
        realtime.skew.recipientSets[.roomEvents, default: .init()].sets = 2
        realtime.skew.recipientSets[.roomEvents, default: .init()].membersMaxLifetime = 7
        realtime.skew.deliveryTargets[.roomEvents, default: .init()].completed = 3
        realtime.skew.deliveryTargets[.roomEvents, default: .init()].totalMilliseconds = 12
        realtime.skew.deliveryTargets[.roomEvents, default: .init()].maxMillisecondsLifetime = 9
        let realtimeText = v2RenderPrometheusActorRealtimeMetrics(realtime)
        #expect(realtimeText.contains("im_v2_actor_realtime_partition_retained_bindings_max 19\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_partition_retained_bindings_peak_lifetime 23\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_publication_recipient_members_max_lifetime{kind=\"room_events\"} 7\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_delivery_target_duration_milliseconds_count{kind=\"room_events\"} 3\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_delivery_target_duration_milliseconds_sum{kind=\"room_events\"} 12.0\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_delivery_target_duration_milliseconds_max_lifetime{kind=\"room_events\"} 9.0\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_delivery_target_active{kind=\"user_presence\"} 0\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_publication_recipient_empty_sets_total{kind=\"room_typing\"} 0\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_skew_observation_ownership_violations_total 0\n"))
        #expect(!realtimeText.contains("partition_id="))
        #expect(realtimeText.contains("im_v2_actor_realtime_receptionist_lookups_total{source=\"background_discovery\"} 13\n"))
        #expect(realtimeText.contains("im_v2_actor_realtime_receptionist_lookups_total{source=\"foreground_resolve\"} 2\n"))
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        await telemetry.record(.gatewayCommand(
            traceID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            command: .sendMessage,
            outcome: .accepted,
            rejection: nil,
            elapsedMilliseconds: 12
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry)

        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics")
            #expect(response.status == .ok)
            let contentType = try #require(response.headers[.contentType])
            #expect(contentType.contains("text/plain"))
            #expect(contentType.contains("version=0.0.4"))
            #expect(contentType.contains("charset=utf-8"))
            #expect(response.headers[.cacheControl] == "no-store, no-cache")
            let body = (try await response.body.string() ?? "")
            #expect(body.contains("im_v2_gateway_commands_total{command=\"send_message\",outcome=\"accepted\",rejection=\"none\"} 1"))
            #expect(!body.contains("im_v2_database_loan_"))
            #expect(!body.contains("00000000-0000-0000-0000-000000000901"))
        }
    }

    @Test("metrics route includes only aggregate live connection gauges when configured")
    func rendersConnectionGauges() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let connectionMetrics = ConnectionMetricsProbe(snapshot: .init(activeDevices: 2, activeConnections: 3))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, connectionMetrics: connectionMetrics)

        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics")
            #expect(response.status == .ok)
            let body = (try await response.body.string() ?? "")
            #expect(body.contains("im_v2_gateway_active_devices 2"))
            #expect(body.contains("im_v2_gateway_active_connections 3"))
            #expect(!body.contains("user_id"))
            #expect(!body.contains("device_id"))
        }
    }

    @Test("metrics route includes aggregate transport gauges when configured")
    func rendersTransportGauges() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let transportMetrics = TransportMetricsProbe(snapshot: .init(
            activeConnections: 4,
            peakQueuedInboundBytes: 512,
            closures: [.idleTimeout: 2]
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, transportMetrics: transportMetrics)

        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics")
            let body = (try await response.body.string() ?? "")
            #expect(body.contains("im_v2_gateway_transport_active_connections 4"))
            #expect(body.contains("im_v2_gateway_inbound_queue_peak_bytes 512"))
            #expect(body.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 2"))
        }
    }

    @Test("metrics route includes bounded runtime-pressure gauges and counters")
    func rendersRuntimePressureMetrics() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let operations = V2SendOperationBatchMetrics()
        operations.recordSQLResultSettled(source: .lifecycleLeases)
        operations.recordSQLTaskResumed(source: .lifecycleLeases, duration: .milliseconds(2))
        operations.recordSQLNextDispatch(source: .lifecycleLeases, duration: .milliseconds(3))
        operations.recordSQLResultSettled(source: .lifecycleLeases)
        operations.recordSQLTaskResumed(source: .lifecycleLeases, duration: .milliseconds(4))
        operations.recordSQLNoNextDispatch(source: .lifecycleLeases)
        operations.recordSQLResultSettled(source: .lifecycleLeases)
        operations.recordSQLResultSettled(source: .durableFenceRooms)
        operations.recordSQLTaskResumed(source: .durableFenceRooms, duration: .milliseconds(5))
        operations.recordOwnerAdmissionHandoff(path: .multiGroup,
            resultReadyToValidated: .milliseconds(2), validatedToCommitDispatch: .milliseconds(3))
        operations.recordOwnerCohortStarted(handleCount: 2, commandCount: 3)
        operations.recordOwnerCohortCommitted(acceptedCommandCount: 2, replayedCommandCount: 1)
        operations.recordOwnerScalarFallback(handleCount: 1, commandCount: 2, reason: .multiCommand)
        operations.recordOwnerCohortIsolation()
        operations.begin(commandCount: 3)
        operations.finish(commandCount: 3, outcome: .committed, duration: .milliseconds(12))
        let bodyStage = operations.startStage(.ownerBody)
        bodyStage.finish()
        let commitStage = operations.startStage(.ownerCommit)
        defer { commitStage.finish() }
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
                ),
                interactiveReadPurposes: [
                    .ordinary: .init(inFlight: 1, queued: 1, admittedRequests: 8,
                        queueFullRejections: 3, timeoutRejections: 0, cancelledRequests: 0),
                    .coverageAuthorization: .init(inFlight: 0, queued: 1, admittedRequests: 4,
                        queueFullRejections: 1, timeoutRejections: 0, cancelledRequests: 0)
                ]
            ),
            databasePools: .init(pools: [
                .init(poolClass: .shared, eventLoopHandles: 4, connectionCeiling: 64)
            ]),
            syncWake: .init(
                pendingUsers: 6, inFlightUsers: 2,
                coalescedNotifications: 7, deliveredNotifications: 9,
                droppedNotifications: 8
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
            ),
            roomActors: .init(host: nil, commands: nil, cachedLocations: 0,
                pendingResolutions: 0, activeResolutions: 1, resolutionWaiters: 0,
                directoryCalls: .init(recoveryStages: [.actualResolution: .init(
                    active: 1, oldestMilliseconds: 21, started: 2, completed: 1)]),
                transportCalls: .init(recoveryStages: [.actualDispatch: .init(
                    active: 2, started: 3, completed: 1, oldestMilliseconds: 29)])),
            sendOperationBatching: operations.sendOperationBatchMetricsSnapshot(),
            sendOperationOwnerBatching: {
                var value = V2SendOperationOwnerMetricsSnapshot()
                value.retainedItems = 11
                value.retainedBytes = 4096
                value.queuedTurns = 3
                value.inFlightBatches = 2
                value.stages = [.acquiringConnection: 1, .executing: 1]
                value.batchesStarted = 19
                value.batchesCompleted = 17
                value.commandsSubmitted = 211
                value.largestBatch = 32
                value.largestRoomCount = 16
                return value
            }(),
            databaseLoans: .init(ordinary: .init(inFlight: 7, queued: 4, granted: 27, rejected: 3),
                                 activation: .init(inFlight: 2, queued: 9, granted: 33, rejected: 5),
                                 renewal: .init(), sync: .init(inFlight: 3, queued: 2, granted: 19, rejected: 1), observations: {
                                     var stage = V2DatabaseLoanObservationStageMetric()
                                     stage.active = 2; stage.oldestMilliseconds = 17
                                     stage.count = 3; stage.totalMilliseconds = 23; stage.maxMilliseconds = 11
                                     var source = V2DatabaseLoanObservationSourceMetric()
                                     source.stages[.betweenSQL] = stage
                                     var sql = V2DatabaseLoanObservationSQLMetric()
                                     sql.count = 7; sql.totalMilliseconds = 39; sql.maxMilliseconds = 13
                                     source.sqlPhases[.readBody] = sql
                                     source.actualHeldCount = 5
                                     source.actualHeldTotalMilliseconds = 77
                                     source.actualHeldMaxMilliseconds = 31
                                     return [.groupEventPull: source]
                                 }()),
            gatewayMessageSend: .init(inFlightRequests: 2, reservedBytes: 777,
                peakInFlightRequests: 4, peakReservedBytes: 1_024,
                rejections: [.connectionCount: 3]),
            registryRecovery: .init(stages: [.room: [.actual: .init(count: 2, oldestMilliseconds: 17),
                    .actualScopes: .init(count: 2, oldestMilliseconds: 17)]],
                reasons: [.room: [.newHead: 3]], duplicateRetained: [.account: 11],
                presenceObservationStages: [.actualQueries: .init(count: 1, oldestMilliseconds: 13),
                    .resultTickets: .init(count: 5, oldestMilliseconds: 21)],
                recoveryAttemptStages: [.queryRoot: .init(count: 3, oldestMilliseconds: 19),
                    .authorizationQuery: .init(count: 1, oldestMilliseconds: 11)],
                retiredRecoveryWriterStages: [.retainedStreams: .init(count: 2, oldestMilliseconds: 29),
                    .actualDrains: .init(count: 1, oldestMilliseconds: 17)],
                positionLedger: .init(stages: [
                    .queued: .init(count: 2, oldestMilliseconds: 17),
                    .authorizationReturns: .init(count: 3, oldestMilliseconds: 23),
                    .selectedHandoff: .init(count: 1, oldestMilliseconds: 19),
                    .outbound: .init(count: 4, oldestMilliseconds: 29)]),
                schedulingTelemetry: .init(timings: [
                    .pumpPass: .init(count: 2, totalMilliseconds: 4, maxMilliseconds: 3),
                    .shortOffer: .init(count: 3, totalMilliseconds: 27, maxMilliseconds: 24),
                    .controlCohort: .init(count: 1, totalMilliseconds: 50, maxMilliseconds: 50)],
                    scans: [.desired: 10_000, .queued: 128],
                    readyRejections: [.coverageChanged: 4])),
            roomRecoveryBatches: .init(purposes: [.scalar: .init(
                inFlight: 4, items: 8, oldestMilliseconds: 31, started: 5, completed: 1),
                .statesCohort: .init(busyBeforeAcquire: 7)])
        ))
        let configured = source.snapshot
        let missingSendSource = V2RuntimePressureMetricsSnapshot(
            databaseWork: configured.databaseWork, databasePools: configured.databasePools,
            syncWake: configured.syncWake)
        #expect(!v2RenderPrometheusRuntimePressureMetrics(missingSendSource)
            .contains("im_v2_database_loan_observation_"))
        #expect(!v2RenderPrometheusRuntimePressureMetrics(missingSendSource)
            .contains("im_v2_gateway_message_send_"))
        #expect(!v2RenderPrometheusRuntimePressureMetrics(missingSendSource)
            .contains("im_v2_gateway_registry_recovery_"))
        #expect(!v2RenderPrometheusRuntimePressureMetrics(missingSendSource)
            .contains("im_v2_room_recovery_batch_"))
        let zeroSendSource = V2RuntimePressureMetricsSnapshot(
            databaseWork: configured.databaseWork, databasePools: configured.databasePools,
            syncWake: configured.syncWake, gatewayMessageSend: .init())
        let zeroSendText = v2RenderPrometheusRuntimePressureMetrics(zeroSendSource)
        #expect(zeroSendText.contains("im_v2_gateway_message_send_reserved_bytes 0"))
        for reason in V2GatewayMessageSendRejectionReason.allCases {
            #expect(zeroSendText.contains("im_v2_gateway_message_send_rejected_total{reason=\"\(reason.rawValue)\"} 0"))
        }
        let zeroRecoveryText = v2RenderPrometheusRuntimePressureMetrics(.init(
            databaseWork: configured.databaseWork, databasePools: configured.databasePools,
            syncWake: configured.syncWake, registryRecovery: .init()))
        #expect(zeroRecoveryText.contains("im_v2_gateway_recovery_positions_occupied 0"))
        for stage in V2RecoveryPositionStage.allCases {
            #expect(zeroRecoveryText.contains("im_v2_gateway_recovery_positions{stage=\"\(stage.rawValue)\"} 0"))
        }
        V2VaporMetricsRoutes.register(
            on: app, telemetry: telemetry, runtimePressureMetrics: source
        )

        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics")
            let body = (try await response.body.string() ?? "")
            #expect(body.contains("im_v2_room_directory_recovery_active{stage=\"actual_resolution\"} 1"))
            #expect(body.contains("im_v2_room_directory_recovery_oldest_milliseconds{stage=\"actual_resolution\"} 21.0"))
            #expect(body.contains("im_v2_room_directory_recovery_active{stage=\"cold_caller_wait\"} 0"))
            #expect(body.contains("im_v2_room_transport_recovery_active{stage=\"actual_dispatch\"} 2"))
            #expect(body.contains("im_v2_room_transport_recovery_completed_total{stage=\"actual_dispatch\"} 1"))
            #expect(body.contains("im_v2_room_recovery_batch_in_flight{purpose=\"scalar\"} 4"))
            #expect(body.contains("im_v2_room_recovery_batch_completed_total{purpose=\"scalar\"} 1"))
            #expect(body.contains("im_v2_room_recovery_batch_busy_before_acquire_total{purpose=\"states_cohort\"} 7"))
            #expect(body.contains("im_v2_database_work_in_flight{class=\"foreground_write\"} 4"))
            #expect(body.contains("im_v2_gateway_registry_recovery_scopes{kind=\"room\",stage=\"actual\"} 2"))
            #expect(body.contains("im_v2_gateway_recovery_positions_occupied 10"))
            #expect(body.contains("im_v2_gateway_recovery_positions_capacity 1024"))
            #expect(body.contains("im_v2_gateway_recovery_positions{stage=\"queued\"} 2"))
            #expect(body.contains("im_v2_gateway_recovery_positions{stage=\"authorization_returns\"} 3"))
            #expect(body.contains("im_v2_gateway_recovery_positions{stage=\"selected_handoff\"} 1"))
            #expect(body.contains("im_v2_gateway_recovery_positions{stage=\"outbound\"} 4"))
            #expect(body.contains("im_v2_gateway_recovery_position_oldest_milliseconds{stage=\"all\"} 29.0"))
            #expect(body.contains("im_v2_gateway_recovery_position_oldest_milliseconds{stage=\"authorization_returns\"} 23.0"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_observations_total{phase=\"pump_pass\"} 2"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_duration_milliseconds_total{phase=\"short_offer\"} 27.0"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_duration_milliseconds_max{phase=\"short_offer\"} 24.0"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_duration_milliseconds_total{phase=\"control_cohort\"} 50.0"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_observations_total{phase=\"query_provider\"} 0"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_scan_entries_total{source=\"desired\"} 10000"))
            #expect(body.contains("im_v2_gateway_recovery_scheduling_scan_entries_total{source=\"queued\"} 128"))
            #expect(body.contains("im_v2_gateway_recovery_ready_rejections_total{reason=\"coverage_changed\"} 4"))
            #expect(body.contains("im_v2_gateway_recovery_attempts{stage=\"query_root\",unit=\"root_tasks\"} 3"))
            #expect(body.contains("im_v2_gateway_recovery_attempts{stage=\"authorization_query\",unit=\"query_attempts\"} 1"))
            #expect(body.contains("im_v2_gateway_retired_recovery_writer_work{stage=\"retained_streams\",unit=\"streams\"} 2"))
            #expect(body.contains("im_v2_gateway_retired_recovery_writer_oldest_milliseconds{stage=\"actual_drains\",unit=\"worker_tasks\"} 17.0"))
            #expect(body.contains("im_v2_gateway_presence_observation_work{stage=\"actual_queries\",unit=\"query_batches\"} 1"))
            #expect(body.contains("im_v2_gateway_presence_observation_work{stage=\"result_tickets\",unit=\"target_tickets\"} 5"))
            #expect(body.contains("im_v2_gateway_presence_observation_oldest_milliseconds{stage=\"result_tickets\",unit=\"target_tickets\"} 21.0"))
            #expect(body.contains("im_v2_gateway_registry_recovery_oldest_milliseconds{kind=\"room\",stage=\"actual\"} 17.0"))
            #expect(body.contains("im_v2_gateway_registry_recovery_scopes{kind=\"presence\",stage=\"queued\"} 0"))
            #expect(body.contains("im_v2_gateway_registry_recovery_scopes{kind=\"room\",stage=\"interest_activation\"} 0"))
            #expect(body.contains("im_v2_gateway_registry_recovery_scopes{kind=\"room\",stage=\"inline_retention\"} 0"))
            #expect(body.contains("im_v2_gateway_registry_recovery_scopes{kind=\"room\",stage=\"actual_scopes\"} 2"))
            #expect(body.contains("im_v2_gateway_registry_recovery_demands{kind=\"room\",reason=\"new_head\"} 3"))
            #expect(body.contains("im_v2_gateway_registry_recovery_duplicate_retained_total{kind=\"account\"} 11"))
            #expect(body.contains("im_v2_database_loan_observation_active{source=\"group_event_pull\",stage=\"between_sql\"} 2"))
            #expect(body.contains("im_v2_database_loan_observation_oldest_ms{source=\"group_event_pull\",stage=\"between_sql\"} 17.0"))
            #expect(body.contains("im_v2_database_loan_observation_stage_duration_sum{source=\"group_event_pull\",stage=\"between_sql\"} 23.0"))
            #expect(body.contains("im_v2_database_loan_observation_stage_duration_count{source=\"group_event_pull\",stage=\"between_sql\"} 3"))
            #expect(body.contains("im_v2_database_loan_observation_stage_duration_max{source=\"group_event_pull\",stage=\"between_sql\"} 11.0"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_count{source=\"group_event_pull\",phase=\"read_body\"} 7"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_sum{source=\"group_event_pull\",phase=\"read_body\"} 39.0"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_max{source=\"group_event_pull\",phase=\"read_body\"} 13.0"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_count{source=\"group_event_pull\",phase=\"fence\"} 0"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_sum{source=\"group_event_pull\",phase=\"fence\"} 0.0"))
            #expect(body.contains("im_v2_database_loan_observation_sql_duration_max{source=\"group_event_pull\",phase=\"fence\"} 0.0"))
            #expect(body.contains("im_v2_database_loan_observation_held_duration_count{source=\"group_event_pull\"} 5"))
            #expect(body.contains("im_v2_database_loan_observation_held_duration_sum{source=\"group_event_pull\"} 77.0"))
            #expect(body.contains("im_v2_database_loan_observation_held_duration_max{source=\"group_event_pull\"} 31.0"))
            #expect(body.contains("im_v2_database_loan_observation_active{source=\"sync\",stage=\"sql\"} 0"))
            #expect(!body.contains("im_v2_database_loan_observation_active{source=\"group_event_pull\",stage=\"settled\"}"))
            #expect(body.contains("im_v2_database_loan_in_flight{class=\"ordinary\"} 7"))
            #expect(body.contains("im_v2_database_loan_queued{class=\"ordinary\"} 4"))
            #expect(body.contains("im_v2_database_loan_granted_total{class=\"ordinary\"} 27"))
            #expect(body.contains("im_v2_database_loan_rejected_total{class=\"ordinary\"} 3"))
            #expect(body.contains("im_v2_database_loan_in_flight{class=\"activation\"} 2"))
            #expect(body.contains("im_v2_database_loan_queued{class=\"activation\"} 9"))
            #expect(body.contains("im_v2_database_loan_granted_total{class=\"activation\"} 33"))
            #expect(body.contains("im_v2_database_loan_rejected_total{class=\"activation\"} 5"))
            #expect(body.contains("im_v2_database_loan_in_flight{class=\"sync\"} 3"))
            #expect(body.contains("im_v2_database_loan_queued{class=\"sync\"} 2"))
            #expect(body.contains("im_v2_database_loan_granted_total{class=\"sync\"} 19"))
            #expect(body.contains("im_v2_database_loan_rejected_total{class=\"sync\"} 1"))
            #expect(body.contains("im_v2_database_loan_in_flight{class=\"renewal\"} 0"))
            #expect(body.contains("im_v2_database_loan_queued{class=\"renewal\"} 0"))
            #expect(body.contains("im_v2_database_loan_granted_total{class=\"renewal\"} 0"))
            #expect(body.contains("im_v2_database_loan_rejected_total{class=\"renewal\"} 0"))
            #expect(body.contains("im_v2_send_operation_batches_total{outcome=\"committed\"} 1"))
            #expect(body.contains("im_v2_send_operation_commands_total{outcome=\"committed\"} 3"))
            #expect(body.contains("im_v2_send_operation_largest_batch 3"))
            #expect(body.contains("im_v2_send_operation_store_cohort_attempts_total 1"))
            #expect(body.contains("im_v2_send_operation_store_cohort_handles_total 2"))
            #expect(body.contains("im_v2_send_operation_store_cohort_commands_total 3"))
            #expect(body.contains("im_v2_send_operation_store_cohort_commits_total 1"))
            #expect(body.contains("im_v2_send_operation_store_cohort_accepted_commands_total 2"))
            #expect(body.contains("im_v2_send_operation_store_cohort_replayed_commands_total 1"))
            #expect(body.contains("im_v2_send_operation_store_cohort_isolations_total 1"))
            #expect(body.contains("im_v2_send_operation_store_scalar_fallback_handles_total{reason=\"multi_command\"} 1"))
            #expect(body.contains("im_v2_send_operation_store_scalar_fallback_commands_total{reason=\"multi_command\"} 2"))
            #expect(body.contains("im_v2_send_operation_store_scalar_fallback_commands_total{reason=\"complex_payload\"} 0"))
            #expect(body.components(separatedBy: "\n").filter { $0.hasPrefix("im_v2_send_operation_store_scalar_fallback_handles_total{") }.count == 4)
            #expect(body.contains("im_v2_send_operation_stage_completed_total{stage=\"owner_body\"} 1"))
            #expect(body.contains("im_v2_send_operation_stage_in_flight{stage=\"owner_commit\"} 1"))
            #expect(body.contains("im_v2_send_operation_stage_started_total{stage=\"owner_commit\"} 1"))
            #expect(body.contains("im_v2_send_operation_stage_completed_total{stage=\"receipt_preflight\"} 0"))
            #expect(body.contains("im_v2_send_operation_stage_duration_milliseconds_sum{stage=\"owner_rollback\"} 0.0"))
            #expect(body.components(separatedBy: "\n").filter { $0.hasPrefix("im_v2_send_operation_stage_in_flight{") }.count == V2SendOperationStage.allCases.count)
            #expect(body.contains("im_v2_database_work_in_flight{class=\"foreground_control_write\"} 0"))
            #expect(body.contains("im_v2_database_work_queued{class=\"interactive_read\"} 2"))
            #expect(body.contains("im_v2_database_work_interactive_read_queued{purpose=\"coverage_authorization\"} 1"))
            #expect(body.contains("im_v2_database_work_interactive_read_admissions_total{purpose=\"coverage_authorization\"} 4"))
            #expect(body.contains("im_v2_database_work_interactive_read_in_flight{purpose=\"coverage_authorization\"} 0"))
            #expect(body.contains("im_v2_database_work_interactive_read_admissions_total{purpose=\"ordinary\"} 8"))
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
            for source in V2RoomSQLContinuationSource.allCases {
                let label = "{source=\"\(source.rawValue)\"}"
                let settledPending = source == .lifecycleLeases ? 1 : 0
                let resumedPending = source == .durableFenceRooms ? 1 : 0
                let noNext = source == .lifecycleLeases ? 1 : 0
                #expect(body.contains("im_v2_send_operation_sql_continuation_settled_not_resumed\(label) \(settledPending)"))
                #expect(body.contains("im_v2_send_operation_sql_continuation_resumed_not_dispatched\(label) \(resumedPending)"))
                #expect(body.contains("im_v2_send_operation_sql_continuation_no_next_dispatch_total\(label) \(noNext)"))
                for part in ["settled_to_resumed", "resumed_to_dispatch"] {
                    let labels = "{source=\"\(source.rawValue)\",part=\"\(part)\"}"
                    let firstPart = part == "settled_to_resumed"
                    let count = source == .lifecycleLeases ? (firstPart ? 2 : 1)
                        : source == .durableFenceRooms && firstPart ? 1 : 0
                    let sum: Double = source == .lifecycleLeases ? (firstPart ? 6 : 3)
                        : source == .durableFenceRooms && firstPart ? 5 : 0
                    let maximum: Double = source == .lifecycleLeases ? (firstPart ? 4 : 3)
                        : source == .durableFenceRooms && firstPart ? 5 : 0
                    #expect(body.contains("im_v2_send_operation_sql_continuation_duration_milliseconds_count\(labels) \(count)"))
                    #expect(body.contains("im_v2_send_operation_sql_continuation_duration_milliseconds_sum\(labels) \(sum)"))
                    #expect(body.contains("im_v2_send_operation_sql_continuation_duration_milliseconds_max\(labels) \(maximum)"))
                }
            }
            for path in V2SendOperationAdmissionPath.allCases {
                for part in ["result_ready_to_validated", "validated_to_commit_dispatch"] {
                    let labels = "{path=\"\(path.rawValue)\",part=\"\(part)\"}"
                    let count = path == .multiGroup ? 1 : 0
                    let duration: Double = path == .multiGroup ? (part == "result_ready_to_validated" ? 2 : 3) : 0
                    #expect(body.contains("im_v2_send_operation_admission_handoff_duration_milliseconds_count\(labels) \(count)"))
                    #expect(body.contains("im_v2_send_operation_admission_handoff_duration_milliseconds_sum\(labels) \(duration)"))
                    #expect(body.contains("im_v2_send_operation_admission_handoff_duration_milliseconds_max\(labels) \(duration)"))
                }
            }
            #expect(body.contains("im_v2_gateway_message_send_in_flight_requests 2"))
            #expect(body.contains("im_v2_gateway_message_send_reserved_bytes 777"))
            #expect(body.contains("im_v2_gateway_message_send_peak_in_flight_requests_lifetime 4"))
            #expect(body.contains("im_v2_gateway_message_send_peak_reserved_bytes_lifetime 1024"))
            #expect(body.contains("im_v2_gateway_message_send_rejected_total{reason=\"connection_count\"} 3"))
            #expect(body.contains("im_v2_gateway_message_send_rejected_total{reason=\"connection_bytes\"} 0"))
            #expect(body.contains("im_v2_gateway_message_send_rejected_total{reason=\"process_bytes\"} 0"))
            #expect(body.contains("im_v2_gateway_event_loop_lag_milliseconds_max 11"))
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
            #expect(body.contains("im_v2_send_operation_owner_retained_items 11"))
            #expect(body.contains("im_v2_send_operation_owner_retained_bytes 4096"))
            #expect(body.contains("im_v2_send_operation_owner_queued_turns 3"))
            #expect(body.contains("im_v2_send_operation_owner_in_flight_batches 2"))
            #expect(body.contains("im_v2_send_operation_owner_batch_roots{stage=\"acquiring_connection\"} 1"))
            #expect(body.contains("im_v2_send_operation_owner_batch_roots{stage=\"executing\"} 1"))
            #expect(!body.contains("im_v2_send_operation_preparation_owner_batch_roots"))
            #expect(body.contains("im_v2_send_operation_owner_batches_started_total 19"))
            #expect(body.contains("im_v2_send_operation_owner_batches_completed_total 17"))
            #expect(body.contains("im_v2_send_operation_owner_commands_submitted_total 211"))
            #expect(body.contains("im_v2_send_operation_owner_largest_batch 32"))
            #expect(body.contains("im_v2_send_operation_owner_largest_room_count 16"))
            #expect(!body.contains("im_v2_send_operation_owner_retained_items{"))
            #expect(!body.contains("im_v2_send_operation_preparation_owner_"))
            #expect(!body.contains("im_v2_policy_state_requests_"))
            #expect(!body.contains("im_v2_send_operation_preparation_owner_retained_items{"))
            #expect(body.contains("im_v2_sync_wake_dropped_total 8"))
        }
    }

    @Test("metrics route includes durable-work aggregates without accepting a shard label")
    func rendersDurableWorkGauges() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
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

        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics")
            let body = (try await response.body.string() ?? "")
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
