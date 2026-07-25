import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Server
import IMV2ServerHTTP
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
        let app = try await Application.make(.production)
        do {
            app.databases.use(try .postgres(url: configuration.databaseURL), as: .psql)
            let database = app.db(.psql)
            var shardLocations: [V2UserShardStorageLocation] = []
            for storage in configuration.userShardStorage {
                let shardDatabase: any Database
                if storage.databaseURL == configuration.databaseURL {
                    shardDatabase = database
                } else {
                    let identifier = DatabaseID(string: "user-shard-\(storage.bucket)")
                    app.databases.use(try .postgres(url: storage.databaseURL), as: identifier)
                    shardDatabase = app.db(identifier)
                }
                try await V2SchemaReadiness.verify(database: shardDatabase, schema: storage.schema)
                shardLocations.append(try .init(bucket: storage.bucket, database: shardDatabase, schema: storage.schema))
            }
            let userShardStorage = try V2StaticUserShardStorageRegistry(locations: shardLocations)

            // Metrics intentionally use a distinct loopback-only HTTP
            // listener. The native TLS gateway and public media edge must
            // never expose operational metrics.
            app.http.server.configuration.hostname = configuration.metrics.host
            app.http.server.configuration.port = configuration.metrics.port
            let authenticator = V2PostgresGatewayAuthenticator(database: database, tokenKey: configuration.accessTokenKey)
            let connectionRegistry = V2DeviceConnectionRegistry()
            let prometheusTelemetry = V2PrometheusTelemetrySink()
            let transportMetrics = V2GatewayTransportMetrics()
            let durableWorkMetrics = PostgresV2DurableWorkMetricsSource(
                database: database,
                gatewayNodeID: configuration.gatewayNodeID
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
                control: database, router: userShardRouter, migrations: userShardMigrations, registry: userShardStorage
            )
            let sendMessage = V2SendMessageService(
                store: PostgresV2RoomWriteStore(database: database, strangerMessagePolicy: configuration.strangerMessagePolicy),
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
                store: PostgresV2MessageEditStore(database: database),
                capacityProfile: configuration.capacityProfile,
                maximumTextUTF8Bytes: configuration.messageLimits.maxUTF8Bytes
            )
            let readReceipt = V2ReadReceiptService(store: PostgresV2ReadReceiptStore(database: database))
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
            let handler = V2GatewayDomainCommandHandler(
                sendMessage: sendMessage,
                membership: membership,
                withdrawal: withdrawal,
                reaction: reaction,
                edit: edit,
                readReceipt: readReceipt,
                directMessaging: directMessaging,
                groupMessaging: groupMessaging,
                membershipDirectory: membershipDirectory,
                socialRelationships: socialRelationships,
                moderation: moderation,
                sync: .init(store: V2RoutedSyncStore(router: userShardRouter, registry: userShardStorage)),
                telemetry: telemetry
            )
            let fanoutDeliveryControlStore = PostgresV2FanoutDeliveryStore(database: database)
            let durableFanoutPublisher = V2LocalFanoutPlanPublisher(
                planner: .init(
                    store: PostgresV2FanoutPlanStore(database: database, router: userShardRouter),
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
                        V2FanoutDeliveryWorker(
                            store: V2CrossStoreFanoutDeliveryStore(
                                control: fanoutDeliveryControlStore, registry: userShardStorage,
                                migrations: userShardMigrations
                            ),
                            bucket: bucket,
                            liveNotifier: connectionRegistry,
                            router: userShardRouter,
                            retryPolicy: configuration.durableRetryPolicy
                        )
                    },
                telemetry: telemetry
            )
            let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
                database: database,
                shadowForwarder: userShardShadowForwarder,
                liveNotifier: connectionRegistry
            )
            let deviceRevocationWorker = V2DeviceRevocationWorker(
                store: V2PostgresDeviceRevocationEventStore(database: database),
                registry: connectionRegistry,
                nodeID: configuration.gatewayNodeID
            )
            let moderationAuditRetentionWorker = V2ModerationAuditRetentionWorker(
                store: PostgresV2ModerationAuditRetentionStore(database: database)
            )
            let mediaRetentionWorker = try V2MediaRetentionWorker(
                store: PostgresV2MediaRetentionStore(database: database),
                withdrawnRetention: TimeInterval(configuration.mediaWithdrawnRetentionSeconds)
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
                    maximumProtobufMessageDepth: configuration.maximumProtobufMessageDepth
                )
                return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry)
            }
            let server = try V2TLSGatewayServer(
                configuration: configuration.tls,
                connectionFactory: factory,
                maximumQueuedInboundBytes: configuration.maximumQueuedInboundBytes,
                idleTimeoutMilliseconds: configuration.idleTimeoutMilliseconds,
                transportMetrics: transportMetrics
            )
            // A newly named replica has no live sockets yet. Record its
            // current revocation watermark before any client can authenticate
            // so it never rescans the append-only history on scale-out. An
            // existing cursor is deliberately preserved for crash recovery.
            try await deviceRevocationWorker.initializeForStartup()
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
            let workerTask = Task {
                var nextMaintenanceAt: Date?
                while !Task.isCancelled {
                    do {
                        _ = try await fanoutPipeline.runOnce(
                            limit: configuration.workerBatchSize,
                            plannerConcurrency: configuration.capacityProfile.limits.maxPlannerConcurrency,
                            deliveryConcurrency: configuration.capacityProfile.limits.maxDeliveryConcurrency
                        )
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 fan-out pipeline failed; retrying")
                    }
                    do {
                        // Profile changes are a distinct direct-contact
                        // graph from room-event fan-out. Its work budget is
                        // per recipient, so one very connected account never
                        // turns a maintenance tick into an unbounded loop.
                        _ = try await directRoomProfilePropagationWorker.runOnce(
                            limit: configuration.workerBatchSize
                        )
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 direct-profile propagation failed; retrying")
                    }
                    do {
                        _ = try await deviceRevocationWorker.runOnce(limit: configuration.workerBatchSize)
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("IM V2 device revocation worker failed; retrying")
                    }
                    if let pushWakeWorker {
                        do {
                            _ = try await pushWakeWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            // Provider and endpoint detail must never reach a
                            // log line. The durable worker releases only Push
                            // work and cannot delay sync/fan-out.
                            logger.error("IM V2 Push wake worker failed; retrying")
                        }
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
                            _ = try await mediaRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            break
                        } catch {
                            logger.error("IM V2 media retention worker failed; retrying")
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
                        try await Task.sleep(for: .milliseconds(configuration.workerPollIntervalMilliseconds))
                    } catch is CancellationError {
                        break
                    } catch {
                        break
                    }
                }
            }
            await TerminationSignal.wait()
            workerTask.cancel()
            await workerTask.value
            try await server.shutdown()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
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
        case .fanoutProgress(let traceID, let claimedOutboxRows, let publishedOutboxRows, let releasedOutboxRows, let pausedOutboxRows, let claimedDeliveries, let committedDeliveries, let staleDeliveries, let staleRouteDeliveries, let releasedDeliveries, let pausedDeliveries, let elapsedMilliseconds):
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
