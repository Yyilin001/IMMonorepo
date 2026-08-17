import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Server
import IMV2ServerHTTP
import NIOPosix
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum IMV2ServerApp {
    static func main() async throws {
        let configuration = try V2GatewayRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let applicationEventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let app: Application
        do {
            app = try await Application.make(.production, .shared(applicationEventLoops))
        } catch {
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
        V2RedactedHTTPMiddlewareConfiguration.install(on: app)
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        do {
            app.databases.use(
                try postgresDatabaseConfiguration(
                    url: configuration.databaseURL,
                    policy: configuration.databasePolicy
                ),
                as: .psql
            )
            let database = app.db(.psql)
            // The control plane remains authoritative even when every user
            // bucket is routed to a different physical database. Verify its
            // session policy and schema independently of the shard loop.
            try await V2PostgresSessionReadiness.verify(
                database: database,
                policy: configuration.databasePolicy
            )
            try await V2SchemaReadiness.verify(database: database)
            var shardDatabasesByURL: [String: any Database] = [
                configuration.databaseURL: database
            ]
            var shardLocations: [V2UserShardStorageLocation] = []
            for storage in configuration.userShardStorage {
                let shardDatabase: any Database
                if let existing = shardDatabasesByURL[storage.databaseURL] {
                    shardDatabase = existing
                } else {
                    // One physical URL owns one Fluent pool even when several
                    // logical buckets use distinct schemas in that database.
                    // This keeps actual pool multiplication identical to the
                    // startup resource-budget calculation.
                    let identifier = DatabaseID(string: "user-shard-pool-\(shardDatabasesByURL.count)")
                    app.databases.use(
                        try postgresDatabaseConfiguration(
                            url: storage.databaseURL,
                            policy: configuration.databasePolicy
                        ),
                        as: identifier
                    )
                    shardDatabase = app.db(identifier)
                    shardDatabasesByURL[storage.databaseURL] = shardDatabase
                }
                try await V2PostgresSessionReadiness.verify(
                    database: shardDatabase,
                    policy: configuration.databasePolicy
                )
                try await V2SchemaReadiness.verify(database: shardDatabase, schema: storage.schema)
                shardLocations.append(try .init(bucket: storage.bucket, database: shardDatabase, schema: storage.schema))
            }
            let userShardStorage = try V2StaticUserShardStorageRegistry(locations: shardLocations)
            let coLocatedControlBuckets = Set(configuration.userShardStorage.compactMap { storage in
                storage.databaseURL == configuration.databaseURL && storage.schema == "im_v2" ? storage.bucket : nil
            })
            var seenSyncStores: Set<String> = []
            var snapshotArtifactBuilders: [PostgresV2SnapshotArtifactBuilder] = []
            var userProjectionWorkers: [PostgresV2UserProjectionWorker] = []
            var projectionVersionGCWorkers: [PostgresV2ProjectionVersionGCWorker] = []
            var syncLogCompactionWorkers: [PostgresV2UserSyncLogCompactionWorker] = []
            var userShardMetricsSources: [any V2DurableWorkMetricsSource] = []
            let syncHousekeepingWorkers: [V2SyncHousekeepingWorker] = zip(configuration.userShardStorage, shardLocations).compactMap { storage, location in
                let key = storage.databaseURL + "\u{0}" + storage.schema
                guard seenSyncStores.insert(key).inserted else { return nil }
                snapshotArtifactBuilders.append(.init(database: location.database, schema: location.schema))
                userProjectionWorkers.append(.init(
                    database: location.database, schema: location.schema,
                    batchSize: configuration.workerBatchSize,
                    retryPolicy: configuration.durableRetryPolicy
                ))
                projectionVersionGCWorkers.append(.init(database: location.database, schema: location.schema))
                syncLogCompactionWorkers.append(.init(
                    database: location.database, schema: location.schema
                ))
                userShardMetricsSources.append(
                    PostgresV2UserShardDurableWorkMetricsSource(
                        database: location.database, schema: location.schema
                    )
                )
                return V2SyncHousekeepingWorker(
                    store: PostgresV2SyncHousekeepingStore(database: location.database, schema: location.schema),
                    projectionEffectRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
                )
            }

            // Metrics intentionally use a distinct loopback-only HTTP
            // listener. The native TLS gateway and public media edge must
            // never expose operational metrics.
            app.http.server.configuration.hostname = configuration.metrics.host
            app.http.server.configuration.port = configuration.metrics.port
            let authenticator = V2PostgresGatewayAuthenticator(database: database, tokenKey: configuration.accessTokenKey)
            let commandRateLimiter = V2AuthenticatedGatewayCommandRateLimiter(
                policy: configuration.commandRateLimitPolicy
            )
            let connectionRegistry = V2DeviceConnectionRegistry(
                connectionAdmissionPolicy: configuration.authenticatedConnectionAdmissionPolicy
            )
            let prometheusTelemetry = V2PrometheusTelemetrySink()
            let transportMetrics = V2GatewayTransportMetrics()
            let durableWorkMetrics = V2CachedDurableWorkMetricsSource(
                source: V2AggregateDurableWorkMetricsSource(sources: [
                    PostgresV2DurableWorkMetricsSource(
                        database: database,
                        gatewayNodeID: configuration.gatewayNodeID,
                        includesUserShardMetrics: false
                    )
                ] + userShardMetricsSources),
                minimumRefreshInterval: TimeInterval(
                    configuration.metricsMinimumRefreshIntervalMilliseconds
                ) / 1_000,
                maximumRefreshDuration: TimeInterval(
                    configuration.metricsRefreshTimeoutMilliseconds
                ) / 1_000
            )
            V2VaporMetricsRoutes.register(
                on: app,
                telemetry: prometheusTelemetry,
                connectionMetrics: connectionRegistry,
                transportMetrics: transportMetrics,
                durableWorkMetrics: durableWorkMetrics
            )
            let telemetry = V2CompositeTelemetrySink([
                V2ApplicationTelemetrySink(logger: app.logger),
                prometheusTelemetry,
            ])
            let userShardRouter = V2PostgresUserShardRouter(database: database)
            try await userShardRouter.bootstrap(defaultRoute: configuration.userShardRoute)
            let userShardMigrations = PostgresV2UserShardMigrationStore(database: database)
            let userShardShadowForwarder = V2PostgresUserShardProjectionShadowForwarder(
                registry: userShardStorage,
                routeFence: userShardRouter,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
            let sendMessage = V2SendMessageService(
                store: PostgresV2RoomWriteStore(
                    database: database,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    shadowForwarder: userShardShadowForwarder,
                    contentReviewMode: configuration.contentReviewMode
                ),
                capacityProfile: configuration.capacityProfile,
                limits: configuration.messageLimits
            )
            let membership = V2RoomMembershipService(
                store: PostgresV2RoomMembershipStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let withdrawal = V2MessageWithdrawalService(
                store: PostgresV2MessageWithdrawalStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let reaction = V2MessageReactionService(
                store: PostgresV2MessageReactionStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let edit = V2MessageEditService(
                store: PostgresV2MessageEditStore(database: database, contentReviewMode: configuration.contentReviewMode),
                capacityProfile: configuration.capacityProfile,
                maximumTextUTF8Bytes: configuration.messageLimits.maxUTF8Bytes
            )
            let readReceipt = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: database, shadowForwarder: userShardShadowForwarder))
            let directMessaging = try V2DirectMessagingService(
                store: PostgresV2DirectMessagingStore(database: database, shadowForwarder: userShardShadowForwarder),
                capacityProfile: configuration.capacityProfile,
                roomShardID: configuration.directRoomShardID
            )
            let groupMessaging = try V2GroupMessagingService(
                store: PostgresV2GroupMessagingStore(database: database),
                capacityProfile: configuration.capacityProfile,
                roomShardID: configuration.groupRoomShardID
            )
            let groupAudienceImports = V2GroupAudienceImportService(
                store: PostgresV2GroupAudienceImportStore(database: database),
                groupMessaging: groupMessaging
            )
            let groupEventLog = V2GroupEventLogService(
                store: PostgresV2GroupEventLogStore(database: database)
            )
            // Foreground availability is intentionally a best-effort hint.
            // The same broker adapter also serves the durable Hybrid wake
            // outbox, but the two contracts remain distinct at the command
            // handler boundary.
            let groupEventWakePublisher: any V2GroupEventWakePublishing
            let foregroundGroupEventHintPublisher: any V2ForegroundGroupEventHintPublishing
            switch configuration.groupEventWake {
            case .localOnly:
                let publisher = V2LocalGroupEventWakePublisher(registry: connectionRegistry)
                groupEventWakePublisher = publisher
                foregroundGroupEventHintPublisher = publisher
            case .nats(let nats):
                let broker = V2NATSGroupEventWakeBroker(
                    configuration: nats,
                    receiveWake: { [weak connectionRegistry] wake in
                        await connectionRegistry?.notifyForegroundGroupAvailable(
                            roomID: wake.roomID,
                            highWatermark: wake.highWatermark
                        )
                    }
                )
                natsGroupWakeBroker = broker
                await connectionRegistry.configureForegroundGroupInterestManager(broker)
                let liveActivityBroker = V2NATSLiveActivityBroker(
                    configuration: nats,
                    receivePresence: { [weak connectionRegistry] userID, isOnline, expiresAt in
                        await connectionRegistry?.receivePresence(
                            targetUserID: userID,
                            isOnline: isOnline,
                            expiresAt: expiresAt
                        )
                    },
                    receiveTyping: { [weak connectionRegistry] state in
                        await connectionRegistry?.receiveTyping(state)
                    }
                )
                natsLiveActivityBroker = liveActivityBroker
                await connectionRegistry.configureLiveActivityBroker(liveActivityBroker)
                groupEventWakePublisher = broker
                foregroundGroupEventHintPublisher = broker
            }
            let foregroundGroupEventHints = V2ForegroundGroupEventHintDispatcher(
                publisher: foregroundGroupEventHintPublisher
            )
            let membershipDirectory = V2RoomMembershipDirectoryService(
                store: PostgresV2RoomMembershipDirectoryStore(database: database)
            )
            let socialRelationships = V2SocialRelationshipService(
                store: PostgresV2SocialRelationshipStore(database: database, shadowForwarder: userShardShadowForwarder)
            )
            let moderation = V2ModerationService(
                store: PostgresV2ModerationStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let contentReviewWorker: V2ContentReviewWorker?
            if configuration.contentReviewMode == .enabled,
               let safetyActor = configuration.contentReviewSafetyActorUserID {
                contentReviewWorker = try V2ContentReviewWorker(
                    store: PostgresV2ContentReviewStore(database: database),
                    reviewer: V2ConfiguredContentReviewer(
                        violatingTerms: configuration.contentReviewViolationTerms,
                        reviewTerms: configuration.contentReviewEscalationTerms
                    ),
                    moderation: .init(
                        store: PostgresV2ModerationStore(database: database),
                        safetyActorUserID: safetyActor,
                        capacityProfile: configuration.capacityProfile
                    ),
                    retryPolicy: configuration.durableRetryPolicy
                )
            } else {
                contentReviewWorker = nil
            }
            let conversationCapabilities = V2ConversationCapabilitiesService(
                store: PostgresV2ConversationCapabilitiesStore(database: database, shadowForwarder: userShardShadowForwarder)
            )
            let groupCapabilities = V2GroupCapabilitiesService(
                store: PostgresV2GroupCapabilitiesStore(database: database),
                capacityProfile: configuration.capacityProfile
            )
            let forwardMessages = V2ForwardMessagesService(
                database: database,
                writeStore: PostgresV2RoomWriteStore(
                    database: database,
                    strangerMessagePolicy: configuration.strangerMessagePolicy,
                    shadowForwarder: userShardShadowForwarder,
                    contentReviewMode: configuration.contentReviewMode
                ),
                capacityProfile: configuration.capacityProfile,
                limits: configuration.messageLimits
            )
            let liveActivityStore = PostgresV2LiveActivityStore(database: database)
            let liveActivity = V2LiveActivityService(store: liveActivityStore)
            await connectionRegistry.configureLivePresenceLeases(liveActivityStore)
            await connectionRegistry.configureLiveActivityObservationAuthorizer(liveActivity)
            let handler = V2GatewayDomainCommandHandler(
                sendMessage: sendMessage,
                membership: membership,
                withdrawal: withdrawal,
                reaction: reaction,
                edit: edit,
                readReceipt: readReceipt,
                liveActivity: liveActivity,
                directMessaging: directMessaging,
                groupAudienceImports: groupAudienceImports,
                groupEventLog: groupEventLog,
                foregroundGroupEventHints: foregroundGroupEventHints,
                membershipDirectory: membershipDirectory,
                socialRelationships: socialRelationships,
                moderation: moderation,
                conversationCapabilities: conversationCapabilities,
                groupCapabilities: groupCapabilities,
                forwardMessages: forwardMessages,
                sync: .init(store: V2RoutedSyncStore(
                    registry: userShardStorage, routeFence: userShardRouter,
                    coLocatedControlBuckets: coLocatedControlBuckets,
                    capabilityProfile: configuration.capabilityProfile
                )),
                telemetry: telemetry
            )
            let fanoutDeliveryControlStore = PostgresV2FanoutDeliveryStore(database: database)
            let fanoutCompletionReleaseWorker = V2FanoutCompletionReleaseWorker(
                store: fanoutDeliveryControlStore
            )
            let durableFanoutPublisher = V2LocalFanoutPlanPublisher(
                planner: .init(
                    store: PostgresV2FanoutPlanStore(database: database),
                    pageSize: configuration.capacityProfile.limits.maxEnumerationPageSize
                )
            )
            let fanoutPublisher: any V2FanoutPlanPublisher
            switch configuration.fanoutHint {
            case .durablePollingOnly: fanoutPublisher = durableFanoutPublisher
            case .nats(let nats):
                fanoutPublisher = V2BestEffortFanoutPlanHintPublisher(
                    durablePublisher: durableFanoutPublisher,
                    hintPublisher: V2NATSFanoutPlanHintPublisher(configuration: nats)
                )
            }
            let fanoutPipeline = V2FanoutPipeline(
                relay: .init(
                    store: PostgresV2RoomOutboxStore(database: database),
                    publisher: fanoutPublisher,
                    retryPolicy: configuration.durableRetryPolicy
                ),
                deliveryWorkers: configuration.userShardStorage
                    .map(\.bucket)
                    .sorted()
                    .map { bucket in
                        let isCoLocated = coLocatedControlBuckets.contains(bucket)
                        return V2FanoutDeliveryWorker(
                            store: V2CrossStoreFanoutDeliveryStore(
                                control: fanoutDeliveryControlStore, registry: userShardStorage,
                                migrations: userShardMigrations,
                                coLocatedControlBucket: isCoLocated ? bucket : nil
                            ),
                            bucket: bucket,
                            liveNotifier: connectionRegistry,
                            router: userShardRouter,
                            retryPolicy: configuration.durableRetryPolicy,
                            claimScheduler: .init(freshBurstPasses: configuration.fanoutFreshBurstPasses),
                            commitBatchSize: isCoLocated
                                ? configuration.fanoutDeliveryCommitBatchSize
                                : configuration.crossStoreFanoutDeliveryCommitBatchSize,
                            maximumConcurrentCommitBatches: isCoLocated
                                ? 1
                                : configuration.crossStoreFanoutDeliveryCommitConcurrency
                        )
                    },
                telemetry: telemetry
            )
            // The wake relay is not a delivery dependency: a failed or
            // duplicated publication only changes foreground latency because
            // Hybrid clients always cursor-pull the room event log.
            let groupEventWakeRelay = V2GroupEventWakeRelay(
                store: PostgresV2GroupEventWakeStore(database: database),
                publisher: groupEventWakePublisher
            )
            let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
                database: database,
                shadowForwarder: userShardShadowForwarder,
                liveNotifier: connectionRegistry
            )
            let readReceiptPreferencePropagationWorker = V2ReadReceiptPreferencePropagationWorker(
                database: database,
                shadowForwarder: userShardShadowForwarder,
                liveNotifier: connectionRegistry
            )
            let deviceRevocationWorker = V2DeviceRevocationWorker(
                store: V2PostgresDeviceRevocationEventStore(database: database),
                registry: connectionRegistry,
                nodeID: configuration.gatewayNodeID
            )
            let revokedDeviceProjectionCleanupWorker = V2RevokedDeviceProjectionCleanupWorker(
                store: V2PostgresDeviceRevocationEventStore.projectionCleanup(
                    database: database
                ),
                cleaner: V2RoutedRevokedDeviceProjectionCleaner(
                    routeFence: V2PostgresUserShardRouter(database: database),
                    registry: userShardStorage,
                    coLocatedControlBuckets: coLocatedControlBuckets
                )
            )
            let moderationAuditRetentionWorker = V2ModerationAuditRetentionWorker(
                store: PostgresV2ModerationAuditRetentionStore(database: database)
            )
            let mediaRetentionWorker = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: database),
                withdrawnRetention: TimeInterval(configuration.mediaWithdrawnRetentionSeconds)
            )
            let controlPlaneHousekeepingWorker = V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: database),
                idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
            )
            let userShardMigrationRetentionWorker = V2UserShardMigrationRetentionWorker(
                store: PostgresV2UserShardMigrationStore(database: database),
                cleaner: V2UserShardProjectionSourceCleaner(registry: userShardStorage)
            )
            let pushWakeWorker: V2PushWakeWorker?
            switch configuration.push {
            case .disabled:
                pushWakeWorker = nil
            case .apns(let pushConfiguration):
                let authorizer = try V2APNSJWTAuthorizer(
                    teamID: pushConfiguration.teamID,
                    keyID: pushConfiguration.keyID,
                    privateKeyRawBase64: pushConfiguration.privateKeyRawBase64
                )
                let provider = try V2APNSPushWakeProvider(
                    endpointStore: PostgresV2PushDeviceEndpointStore(
                        database: database,
                        envelopeKey: pushConfiguration.endpointEnvelopeKey
                    ),
                    httpClient: V2URLSessionPushHTTPClient(),
                    authorizer: authorizer,
                    topic: pushConfiguration.topic
                )
                pushWakeWorker = .init(
                    store: PostgresV2PushWakeStore(database: database),
                    provider: provider
                )
            }
            let factory = V2GatewayConnectionFactory {
                let session = V2GatewaySession(
                    limits: configuration.connectionLimits,
                    authenticator: authenticator,
                    capabilityProfile: configuration.capabilityProfile,
                    maximumProtobufMessageDepth: configuration.maximumProtobufMessageDepth,
                    commandAdmission: commandRateLimiter
                )
                return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry)
            }
            let server = try V2TLSGatewayServer(
                configuration: configuration.tls,
                connectionFactory: factory,
                maximumConnections: configuration.maximumConnections,
                maximumQueuedInboundBytes: configuration.maximumQueuedInboundBytes,
                maximumQueuedInboundChunks: configuration.maximumQueuedInboundChunks,
                authenticationTimeoutMilliseconds: configuration.authenticationTimeoutMilliseconds,
                idleTimeoutMilliseconds: configuration.idleTimeoutMilliseconds,
                transportMetrics: transportMetrics
            )
            // A newly named replica has no live sockets yet. Record its
            // current revocation watermark before any client can authenticate
            // so it never rescans the append-only history on scale-out. An
            // existing cursor is deliberately preserved for crash recovery.
            try await deviceRevocationWorker.initializeForStartup()
            // Storage cleanup has a separate cluster-global cursor and starts
            // at zero on first deployment. This closes the outage window in
            // which no gateway existed to observe a historical revocation.
            try await revokedDeviceProjectionCleanupWorker.initializeForStartup()
            try await server.bind()
            app.logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])
            do {
                try await app.startup()
            } catch {
                try? await server.shutdown()
                throw error
            }
            app.logger.notice("IM V2 metrics listener bound", metadata: ["host": "\(configuration.metrics.host)", "port": "\(configuration.metrics.port)"])
            let logger = app.logger
            let maintenanceCadence = try V2MaintenanceCadence(
                intervalMilliseconds: configuration.maintenancePollIntervalMilliseconds
            )
            // Foreground metadata publication is deliberately owned outside
            // the command handler. An optional broker or socket stall can
            // therefore never extend the committed-message response path.
            let foregroundGroupEventHintTask = Task {
                await foregroundGroupEventHints.run()
            }
            // Each physical user store owns an independent projection loop.
            // A slow/unavailable shard therefore consumes only its configured
            // pool budget and cannot delay another shard or fan-out planning.
            let userProjectionTasks = zip(
                userProjectionWorkers,
                snapshotArtifactBuilders
            ).map { worker, builder in
                Task {
                    var cadence = V2AdaptiveWorkerCadence(
                        minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                    )
                    while !Task.isCancelled {
                        var didWork = false
                        do {
                            let report = try await worker.runOnce()
                            didWork = report.claimed
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 user snapshot projection failed; retrying")
                        }
                        do {
                            let report = try await builder.runOnce()
                            didWork = didWork || report.claimed
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 snapshot artifact build failed; retrying")
                        }
                        do {
                            try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                        } catch {
                            break
                        }
                    }
                }
            }
            // Planning stays on its own cadence. A delivery pass may hold a
            // large, lease-fenced batch while it commits several bounded
            // transactions; serially placing planning behind it would add the
            // entire drain duration to a newly committed room event.
            let fanoutPlanningTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        // An idle planner lane publishes each claimed outbox
                        // item sequentially. Probe with one item so a burst
                        // cannot strand a full batch at idle concurrency; the
                        // next pass immediately restores both the configured
                        // batch and planner concurrency.
                        let report = try await fanoutPipeline.runRelayAndPlanOnce(
                            limit: cadence.claimLimit(configuredLimit: configuration.workerBatchSize),
                            concurrency: cadence.isIdle ? 1 : configuration.capacityProfile.limits.maxPlannerConcurrency
                        )
                        didWork = report.claimedCount > 0 || report.publishedCount > 0 ||
                            report.releasedCount > 0 || report.pausedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out relay and planner failed; retrying")
                    }
                    do {
                        // Hybrid wake publication is a latency hint and is
                        // independent from fan-out delivery correctness; keep
                        // it beside the short planning pass rather than after
                        // a potentially long user-projection drain.
                        let report = try await groupEventWakeRelay.runOnce(limit: configuration.workerBatchSize)
                        didWork = didWork || report.claimed > 0 || report.published > 0 || report.retryScheduled > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 group-event wake relay failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Delivery owns its own cadence. It must not wait behind Push,
            // revocation, profile propagation, or retention work: those
            // workers have independent durable retry semantics, while a
            // delayed delivery pass directly increases a standard group's
            // recipient-visible convergence age.
            let fanoutDeliveryTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await fanoutPipeline.runDeliveryOnce(
                            claimLimit: cadence.claimLimit(
                                configuredLimit: configuration.fanoutDeliveryClaimBatchSize
                            ),
                            concurrency: cadence.isIdle ? 1 : configuration.capacityProfile.limits.maxDeliveryConcurrency
                        )
                        didWork = report.claimedCount > 0 || report.committedCount > 0 ||
                            report.staleCount > 0 || report.staleRouteCount > 0 ||
                            report.releasedCount > 0 || report.pausedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out delivery failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Projection completion and admission-capacity release are two
            // durable phases with disjoint lock sets. This independent polling
            // worker is the crash-recovery path for units committed immediately
            // before a process exit; an in-process wake is never required for
            // correctness.
            let fanoutCompletionReleaseTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await fanoutCompletionReleaseWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out completion release failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Review is intentionally separate from fan-out and maintenance.
            // A slow external/OCR adapter must never increase the accepted
            // message's recipient delivery latency or delay media retention.
            let contentReviewTask = Task {
                guard let contentReviewWorker else { return }
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await contentReviewWorker.runOnce(limit: configuration.workerBatchSize)
                        didWork = report.claimedCount > 0 || report.resolvedCount > 0 ||
                            report.redactedCount > 0 || report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        // No message text, identifiers, or provider response
                        // is included in this log line.
                        logger.error("IM V2 content-review worker failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Push owns external-network latency and retry policy. It must not
            // serialize revocation, propagation, or database housekeeping.
            let pushWakeTask = Task {
                guard let pushWakeWorker else { return }
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await pushWakeWorker.runOnce(limit: configuration.workerBatchSize)
                        didWork = report.admittedCount > 0 || report.sentCount > 0 || report.releasedCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        // Provider and endpoint detail must never reach logs.
                        logger.error("IM V2 Push wake worker failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            // Projection cleanup can cross a remote shard boundary. Give it
            // an independent retry cadence so one unavailable shard cannot
            // delay live-socket revocation or unrelated control-plane work.
            let revokedDeviceProjectionCleanupTask = Task {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        didWork = try await revokedDeviceProjectionCleanupWorker.runOnce(
                            limit: configuration.workerBatchSize
                        ) > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 revoked-device projection cleanup failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            let maintenanceTask = Task {
                var nextMaintenanceAt: Date?
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        // Profile changes are a distinct direct-contact
                        // graph from room-event fan-out. Its work budget is
                        // per recipient, so one very connected account never
                        // turns a maintenance tick into an unbounded loop.
                        let report = try await directRoomProfilePropagationWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = report.claimedUpdateCount > 0 || report.projectedRecipientCount > 0 ||
                            report.completedUpdateCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 direct-profile propagation failed; retrying")
                    }
                    do {
                        let report = try await readReceiptPreferencePropagationWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                        didWork = didWork || report.claimedOperationCount > 0 ||
                            report.projectedRoomCount > 0 || report.completedOperationCount > 0 ||
                            report.releasedOperationCount > 0 || report.pausedOperationCount > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 read-receipt preference propagation failed; retrying")
                    }
                    do {
                        didWork = try await deviceRevocationWorker.runOnce(limit: configuration.workerBatchSize) > 0 || didWork
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 device revocation worker failed; retrying")
                    }
                    let maintenanceNow = Date()
                    if maintenanceCadence.isDue(now: maintenanceNow, nextScheduledAt: nextMaintenanceAt) {
                        do {
                            _ = try await moderationAuditRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 moderation-audit retention worker failed; retrying")
                        }
                        do {
                            // Staged creation drafts own potentially large
                            // temporary audiences. Reclaim them on the same
                            // bounded maintenance cadence as other retention
                            // work; cancellation and actor-local admission
                            // also perform immediate targeted cleanup.
                            _ = try await groupAudienceImports.purgeExpired(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            logger.error("IM V2 group creation draft cleanup failed; retrying")
                        }
                        do {
                            let report = try await groupAudienceImports.recoverFinalizing(limit: configuration.workerBatchSize)
                            if report.failedCount > 0 {
                                logger.warning("IM V2 group creation finalization recovery left retryable drafts")
                            }
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 group creation finalization recovery failed; retrying")
                        }
                        do {
                            _ = try await mediaRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 media retention worker failed; retrying")
                        }
                        do {
                            _ = try await controlPlaneHousekeepingWorker.runOnce(
                                limit: configuration.workerBatchSize
                            )
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 control-plane housekeeping failed; retrying")
                        }
                        for worker in syncHousekeepingWorkers {
                            do {
                                _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 sync capability housekeeping failed; retrying")
                            }
                        }
                        for worker in projectionVersionGCWorkers {
                            do {
                                _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 snapshot projection history cleanup failed; retrying")
                            }
                        }
                        for worker in syncLogCompactionWorkers {
                            do {
                                _ = try await worker.runOnce(
                                    userLimit: min(8, configuration.workerBatchSize),
                                    rowLimit: configuration.workerBatchSize
                                )
                            } catch is CancellationError {
                                return
                            } catch {
                                logger.error("IM V2 user sync-log compaction failed; retrying")
                            }
                        }
                        do {
                            _ = try await userShardMigrationRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            // The cleaner is idempotent and retains a fenced
                            // claim through expiry on failure; never include
                            // source/target details in process logs.
                            logger.error("IM V2 user-shard retention worker failed; retrying")
                        }
                        nextMaintenanceAt = maintenanceCadence.nextScheduledAt(after: maintenanceNow)
                    }
                    do {
                        try await Task.sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            await TerminationSignal.wait()
            userProjectionTasks.forEach { $0.cancel() }
            fanoutPlanningTask.cancel()
            fanoutDeliveryTask.cancel()
            fanoutCompletionReleaseTask.cancel()
            contentReviewTask.cancel()
            pushWakeTask.cancel()
            revokedDeviceProjectionCleanupTask.cancel()
            maintenanceTask.cancel()
            foregroundGroupEventHintTask.cancel()
            await foregroundGroupEventHints.finish()
            for task in userProjectionTasks { await task.value }
            await fanoutPlanningTask.value
            await fanoutDeliveryTask.value
            await fanoutCompletionReleaseTask.value
            await contentReviewTask.value
            await pushWakeTask.value
            await revokedDeviceProjectionCleanupTask.value
            await maintenanceTask.value
            await foregroundGroupEventHintTask.value
            await connectionRegistry.detachForegroundGroupInterestManager()
            await connectionRegistry.detachLiveActivityBroker()
            await natsLiveActivityBroker?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            try await server.shutdown()
            try await app.asyncShutdown()
            try await applicationEventLoops.shutdownGracefully()
        } catch {
            await natsLiveActivityBroker?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            try? await app.asyncShutdown()
            try? await applicationEventLoops.shutdownGracefully()
            throw error
        }
    }
}

private func postgresDatabaseConfiguration(
    url: String,
    policy: V2PostgresRuntimePolicy
) throws -> DatabaseConfigurationFactory {
    var configuration = try SQLPostgresConfiguration(url: url)
    configuration.coreConfiguration.options.connectTimeout = .milliseconds(
        Int64(policy.connectTimeoutMilliseconds)
    )
    configuration.coreConfiguration.options.additionalStartupParameters.append(
        contentsOf: policy.startupParameters
    )
    return .postgres(
        configuration: configuration,
        maxConnectionsPerEventLoop: policy.maximumConnectionsPerEventLoop,
        connectionPoolTimeout: .milliseconds(Int64(policy.poolTimeoutMilliseconds))
    )
}

private struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}

/// Production log adapter for the library telemetry boundary. These are
/// structured operational events, not high-cardinality metric labels: they do
/// not include room/user/message IDs, payloads, URLs, tokens or credentials.
private struct V2ApplicationTelemetrySink: V2TelemetrySink {
    let logger: Logger

    func record(_ event: V2TelemetryEvent) async {
        switch event {
        case .gatewayCommand(let traceID, let command, let outcome, let rejection, let elapsedMilliseconds):
            logger.info("im_v2.gateway.command", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "command": "\(command.rawValue)",
                "outcome": "\(outcome.rawValue)",
                "rejection": "\(rejection?.rawValue ?? "none")",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        case .fanoutProgress(let traceID, let claimedOutboxRows, let publishedOutboxRows, let releasedOutboxRows, let pausedOutboxRows, let claimedDeliveries, let committedDeliveries, let staleDeliveries, let staleRouteDeliveries, let releasedDeliveries, let pausedDeliveries, let relayElapsedMilliseconds, let deliveryElapsedMilliseconds, let elapsedMilliseconds):
            logger.info("im_v2.fanout.progress", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "claimed_outbox_rows": "\(claimedOutboxRows)",
                "published_outbox_rows": "\(publishedOutboxRows)",
                "released_outbox_rows": "\(releasedOutboxRows)",
                "paused_outbox_rows": "\(pausedOutboxRows)",
                "claimed_deliveries": "\(claimedDeliveries)",
                "committed_deliveries": "\(committedDeliveries)",
                "stale_deliveries": "\(staleDeliveries)",
                "stale_route_deliveries": "\(staleRouteDeliveries)",
                "released_deliveries": "\(releasedDeliveries)",
                "paused_deliveries": "\(pausedDeliveries)",
                "relay_elapsed_ms": "\(relayElapsedMilliseconds)",
                "delivery_elapsed_ms": "\(deliveryElapsedMilliseconds)",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        case .fanoutFailure(let traceID, let stage, let elapsedMilliseconds):
            logger.error("im_v2.fanout.failure", metadata: [
                "trace_id": "\(traceID.uuidString)",
                "stage": "\(stage.rawValue)",
                "elapsed_ms": "\(elapsedMilliseconds)",
            ])
        }
    }
}

private enum TerminationSignal {
    static func wait() async {
        await withCheckedContinuation { continuation in
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}
