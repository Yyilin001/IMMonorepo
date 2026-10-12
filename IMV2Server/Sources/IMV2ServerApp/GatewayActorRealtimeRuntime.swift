import Foundation
import Logging
import Synchronization
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerGateway
import IMV2ServerInfrastructure
import IMV2Server

/// The composition root owns this whole routing lifecycle. No public listener
/// may open until registration, ingress and local consumers are ready.
final class GatewayActorRealtimeRuntime: V2ActorRealtimeMetricsSource, Sendable {
    // Shared by generic fanout, room delivery and journal callbacks. Together
    // with the shard sender's control4/publish12 lanes this bounds RPCs at 32.
    private static let maximumCallbackCalls = 16
    let metrics: V2ActorRealtimeMetrics
    let publisher: V2ActorRealtimePublisher
    let userSyncWakeStores: [any V2UserSyncWakeStore]
    private let userInterests: V2SharedGroupEventWakeInterests
    private let coordinator: V2RealtimeInterestCoordinator
    private let fanout: V2RealtimeFanoutDispatcher
    private let ingress: V2GatewayRealtimeIngress
    private let stopTransport: @Sendable () async -> Bool
    private let snapshot: @Sendable () async -> V2ActorRealtimeMetricsSnapshot
    private let refresh: Task<Void, Never>
    private let journal: GatewayJournalRuntime

    private init(publisher: V2ActorRealtimePublisher, metrics: V2ActorRealtimeMetrics, userSyncWakeStores: [any V2UserSyncWakeStore],
                 userInterests: V2SharedGroupEventWakeInterests,
                 coordinator: V2RealtimeInterestCoordinator, fanout: V2RealtimeFanoutDispatcher,
                 ingress: V2GatewayRealtimeIngress, stopTransport: @escaping @Sendable () async -> Bool,
                 refresh: Task<Void, Never>, journal: GatewayJournalRuntime,
                 snapshot: @escaping @Sendable () async -> V2ActorRealtimeMetricsSnapshot) {
        self.journal = journal
        self.snapshot = snapshot
        self.publisher = publisher; self.metrics = metrics; self.userSyncWakeStores = userSyncWakeStores
        self.userInterests = userInterests; self.coordinator = coordinator
        self.fanout = fanout; self.ingress = ingress; self.stopTransport = stopTransport; self.refresh = refresh
    }

    static func build(configuration: V2GatewayRuntimeConfiguration, prepared: GatewayPreparedAssembly,
                      roomServices: GatewayRoomServicesAssembly, actors: V2RoomActorApplication,
                      actorFactory: V2RoomServerActivationFactory?) async throws -> GatewayActorRealtimeRuntime {
        let metrics = V2ActorRealtimeMetrics()
        let actor = prepared.roomOwners.actorConfiguration
        guard let serviceQualification = actors.serviceQualification else {
            throw V2ActorContractError.invalidConfiguration("missing Gateway service qualification")
        }
        let registry = prepared.frontdoor.connectionRegistry
        let identity = V2GatewayRealtimeIdentity(nodeID: configuration.gatewayNodeID,
            serviceID: actor.signer.serviceID.rawValue, incarnationID: actors.callerIncarnation)
        // Deployment snapshots describe the business source, never recipients.
        // Durable data-owner checks remain in transactions; Actor lifetime governs execution.
        let userRouter = try await V2DatabaseLoanObservationContext.$source.withValue(.realtimeOwnerSnapshot) {
            try await V2StaticUserShardRouter.load(database: prepared.topology.database)
        }
        let roomRouter = try await V2DatabaseLoanObservationContext.$source.withValue(.realtimeOwnerSnapshot) {
            try await V2DeploymentRoomShardRouter.load(database: prepared.topology.database)
        }
        var roomHeads: [String: PostgresV2RealtimeRoomHeadReader] = [:]
        var registrationKeys: [String: String] = [:]
        for location in configuration.roomShardStorage {
            guard let db = prepared.topology.databaseForRole(for: .delivery, url: location.databaseURL) else {
                throw V2RealtimeDirectoryError.wrongOwner
            }
            let key = location.databaseURL + "\u{0}" + location.schema
            registrationKeys[location.shardID] = key
            roomHeads[key] = try .init(database: db, schema: location.schema)
        }
        var userHeads: [String: PostgresV2UserSyncWakeStore] = [:]
        var userKeys: [String: String] = [:]
        var userWakeStores: [any V2UserSyncWakeStore] = []
        var userLocations: Set<String> = []
        for location in configuration.userShardStorage {
            let storage = try prepared.topology.deliveryUserShardStorage.location(for: location.bucket)
            let store = try PostgresV2UserSyncWakeStore(database: storage.database, schema: storage.schema)
            let key = location.databaseURL + "\u{0}" + location.schema
            userKeys[location.bucket] = key
            userHeads[key] = store
            if userLocations.insert(location.databaseURL + "\u{0}" + location.schema).inserted { userWakeStores.append(store) }
        }
        // Group physical aliases before loading persistent journal identities.
        // Authentication authority belongs only to the configured control DB.
        var journalAliases: [String: Set<String>] = [:]
        var journalRegistrations: [String: GatewayJournalSourceCatalog.Registration] = [:]
        for location in configuration.roomShardStorage {
            let key = location.databaseURL + "\u{0}" + location.schema
            guard let db = prepared.topology.databaseForRole(for: .maintenance, url: location.databaseURL) else {
                throw V2RealtimeDirectoryError.wrongOwner
            }
            journalAliases[key, default: []].insert(location.shardID)
            journalRegistrations[key] = .init(logicalAliases: [], database: db, schema: location.schema,
                isAuthenticationSource: location.databaseURL == configuration.databaseURL && location.schema == "im_v2")
        }
        for location in configuration.userShardStorage {
            let key = location.databaseURL + "\u{0}" + location.schema
            guard let db = prepared.topology.databaseForRole(for: .maintenance, url: location.databaseURL) else {
                throw V2RealtimeDirectoryError.wrongOwner
            }
            journalAliases[key, default: []].insert("user:" + location.bucket)
            journalRegistrations[key] = .init(logicalAliases: [], database: db, schema: location.schema,
                isAuthenticationSource: location.databaseURL == configuration.databaseURL && location.schema == "im_v2")
        }
        let controlKey = configuration.databaseURL + "\u{0}im_v2"
        guard let controlDatabase = prepared.topology.databaseForRole(for: .maintenance, url: configuration.databaseURL) else {
            throw V2RealtimeDirectoryError.wrongOwner
        }
        journalAliases[controlKey, default: []].insert("control")
        journalRegistrations[controlKey] = .init(logicalAliases: [], database: controlDatabase, isAuthenticationSource: true)
        let catalog: GatewayJournalSourceCatalog
        do {
            catalog = try await GatewayJournalSourceCatalog.load(registrations: journalRegistrations.map { key, value in
                .init(logicalAliases: journalAliases[key] ?? [], database: value.database, schema: value.schema,
                    isAuthenticationSource: value.isAuthenticationSource)
            })
        } catch { await roomRouter.shutdown(); throw error }
        let heads = RecoveryHeads(userRouter: userRouter,
            roomKeys: registrationKeys, userKeys: userKeys, rooms: roomHeads, users: userHeads, metrics: metrics)
        let topic: V2ActorRealtimePublisher.TopicResolver = { kind, id in
            switch kind {
            case .roomEvents, .roomTyping:
                let route = try await roomRouter.route(for: RoomID(id))
                return try .init(kind: kind, id: id, owner: .init(shardID: route.shardID, epoch: route.epoch))
            case .userPresence, .userSync:
                let routes = try await userRouter.routes(for: [UserID(id)])
                guard let route = routes.first, routes.count == 1 else { throw V2RealtimeDirectoryError.wrongOwner }
                return try .init(kind: kind, id: id, owner: .init(shardID: "user:" + route.bucket, epoch: route.observedRouterEpoch))
            }
        }
        let ingress = V2GatewayRealtimeIngress(identity: identity, registry: registry, metrics: metrics)
        let handle = try await actors.makeRealtimeTransport(identity: identity, ingress: ingress,
            serviceOwnerAccess: actor.realtimeServiceOwnerAccess,
            limits: .init(maximumConcurrentCalls: maximumCallbackCalls))
        do {
            try await actorFactory?.configureRoomSubscriptionDelivery(sendBatch: { batch, shard, target in
                try await handle.sendRoomSubscriptionBatch(batch, sourceShardID: shard, to: target)
            }, maximumCalls: maximumCallbackCalls)
            let roomIngress = try await registry.configureRoomSubscriptionIngress(
                authority: V2GatewayRoomSubscriptionAuthority(maximumRooms: configuration.onlineDeliveryMaximumRooms,
                    maximumConnections: configuration.maximumConnections),
                maximumRooms: configuration.onlineDeliveryMaximumRooms)
            try await handle.configureRoomSubscription(roomIngress)
            let ports = V2GatewayRoomSubscriptionPorts(gateway: handle.descriptor,
                resolve: { room, deadline in
                    let route = try await actors.resolveRoomSubscription(room, deadline: deadline)
                    return .init(activation: route.activation, authenticatedServiceID: route.authenticatedServiceID)
                }, subscribe: { command, token, deadline in
                    try await actors.subscribeRoom(command, token: token, deadline: deadline)
                }, reset: { command, token, deadline in
                    try await actors.resetRoomSubscription(command, token: token, deadline: deadline)
                }, renewBatch: { peer, requests, deadline in
                    let outcomes = try await actors.renewRoomSubscriptions(on: peer, items: requests.map {
                        .init(token: $0.activation, command: $0.command)
                    }, deadline: deadline)
                    return outcomes.map { value in
                        let result: V2GatewayRoomSubscriptionPorts.RenewalOutcome.Result
                        switch value.outcome {
                        case .result(let reply): result = .result(reply)
                        case .failure(let failure): result = .failure(failure)
                        }
                        return .init(activation: value.token, result: result)
                    }
                }, activate: { command, token, deadline in
                    try await actors.activateRoomSubscription(command, token: token, deadline: deadline)
                }, unsubscribe: { command, token, deadline in
                    try await actors.unsubscribeRoom(command, token: token, deadline: deadline)
                })
            try await registry.configureRoomSubscriptionPorts(ports, ingress: roomIngress,
                maximumRelations: configuration.onlineDeliveryMaximumRelations, maximumConcurrentCalls: 32)
        } catch {
            await actorFactory?.shutdownRoomSubscriptionDelivery()
            _ = await handle.stop(deadline: .now + .seconds(60))
            await roomRouter.shutdown()
            throw error
        }
        let service = V2RealtimeShardService(qualification: serviceQualification, metrics: metrics,
            send: { target, batch in try await handle.send(batch, to: target) })
        let shardHandle = try await {
            do {
                return try await actors.makeRealtimeShardTransport(identity: identity, serving: service,
                    serviceOwnerAccess: actor.realtimeServiceOwnerAccess, discoveryPeers: actor.realtimePeers,
                    serviceQualification: serviceQualification)
            } catch {
                await service.shutdown()
                _ = await handle.stop(deadline: .now + .seconds(60))
                await roomRouter.shutdown()
                throw error
            }
        }()
        await shardHandle.setQualificationObserver { await actors.qualificationDidChange() }
        let journalInstallation = Mutex<GatewayJournalRuntime?>(nil)
        let installer = PartitionInstallation(service: service, journal: { values in
            guard let journal = journalInstallation.withLock({ $0 }) else { throw V2RealtimeDirectoryError.invalidInput }
            try await journal.install(values)
        }, advertise: { try await shardHandle.installPartitions($0) })
        let shutdownLogger = Logger(label: "imv2.gateway.realtime_shutdown")
        let stopTransports: @Sendable () async -> Bool = {
            // Sequential transport drains share one deadline, including startup failure.
            let deadline = ContinuousClock.now + .seconds(60)
            shutdownLogger.notice("Actor transport drain started", metadata: ["stage": "shard"])
            let shardStopped = await shardHandle.stop(deadline: deadline)
            shutdownLogger.notice("Actor transport drain finished", metadata: ["stage": "shard", "drained": .string(String(shardStopped))])
            shutdownLogger.notice("Actor transport drain started", metadata: ["stage": "gateway"])
            let gatewayStopped = await handle.stop(deadline: deadline)
            shutdownLogger.notice("Actor transport drain finished", metadata: ["stage": "gateway", "drained": .string(String(gatewayStopped))])
            return shardStopped && gatewayStopped
        }
        let control = try await {
            do {
                guard let database = prepared.topology.maintenanceDatabase as? V2EventLoopBalancedDatabase else {
                    throw V2RealtimeDirectoryError.invalidInput
                }
                return try GatewayRealtimePartitionControl(identity: identity,
                    roster: Set(actor.realtimePeers.map(\.nodeID)).union([identity.nodeID]),
                    store: GatewayObservedRealtimeLeaseStore(
                        underlying: try PostgresV2RealtimePartitionLeaseStore(database: database.usingLoanClass(.renewal)), metrics: metrics),
                    qualification: serviceQualification,
                    availableHosts: { await shardHandle.reachableNodeIDs() },
                    rotatePartitions: { await service.partitionsNeedingRollover() },
                    install: { try await installer.install($0) })
            } catch {
                await service.shutdown()
                _ = await stopTransports()
                await roomRouter.shutdown()
                throw error
            }
        }()
        await shardHandle.setQualificationObserver {
            await actors.qualificationDidChange()
            await control.qualificationDidChange()
        }
        // Filled exactly once before subscriptions/listeners start. Clearing it
        // during drain breaks the owned callback cycle.
        let confirmation = Mutex<V2RealtimeInterestCoordinator?>(nil)
        let coordinator = V2RealtimeInterestCoordinator(descriptor: handle.descriptor, transport: shardHandle, metrics: metrics,
            readHeads: { topics in
                try await V2DatabaseLoanObservationContext.$source.withValue(.realtimeRecoveryHead) {
                    try await heads.read(topics)
                }
            }, recovered: { values in
                try await registry.arrangeRealtimeRecoveryHeads(values)
            }, coverageReady: { values in
                guard let current = confirmation.withLock({ $0 }) else { return }
                await registry.realtimeCoverageReady(confirmations: values, confirms: { topic, value in
                    return current.confirms(topic: topic, confirmation: value)
                })
            }, coverageLost: { [weak registry] topics, cutoff in
                await registry?.invalidateRealtimeCoverage(topics: topics, registeredThrough: cutoff)
            })
        confirmation.withLock { $0 = coordinator }
        let journal: GatewayJournalRuntime
        do {
            journal = try await GatewayJournalRuntime.build(catalog: catalog, handle: handle, service: service,
                coordinator: coordinator, registry: registry, identity: identity)
        } catch {
            await service.shutdown(); _ = await stopTransports()
            await roomRouter.shutdown()
            throw error
        }
        journalInstallation.withLock { $0 = journal }
        ingress.start(coordinator: coordinator)
        let fanout = V2RealtimeFanoutDispatcher(transport: shardHandle, metrics: metrics)
        let publisher = V2ActorRealtimePublisher(interests: coordinator, fanout: fanout, topic: topic)
        let userInterests = V2SharedGroupEventWakeInterests(underlying: UserInterests(publisher: publisher))
        let stop: @Sendable () async -> Bool = {
            var success = true
            shutdownLogger.notice("Realtime component drain started", metadata: ["stage": "room_delivery"])
            await actorFactory?.shutdownRoomSubscriptionDelivery()
            shutdownLogger.notice("Realtime component drain finished", metadata: ["stage": "room_delivery"])
            shutdownLogger.notice("Realtime component drain started", metadata: ["stage": "partition_control"])
            do { try await control.shutdown() } catch { success = false }
            shutdownLogger.notice("Realtime component drain finished", metadata: ["stage": "partition_control", "drained": .string(String(success))])
            shutdownLogger.notice("Realtime component drain started", metadata: ["stage": "journal"])
            await journal.close()
            journalInstallation.withLock { $0 = nil }
            shutdownLogger.notice("Realtime component drain finished", metadata: ["stage": "journal"])
            shutdownLogger.notice("Realtime component drain started", metadata: ["stage": "shard_service"])
            await service.shutdown()
            shutdownLogger.notice("Realtime component drain finished", metadata: ["stage": "shard_service"])
            let transportsStopped = await stopTransports()
            shutdownLogger.notice("Realtime component drain started", metadata: ["stage": "room_router"])
            await roomRouter.shutdown()
            shutdownLogger.notice("Realtime component drain finished", metadata: ["stage": "room_router"])
            confirmation.withLock { $0 = nil }
            metrics.registrations(0)
            return success && transportsStopped
        }
        do {
            await journal.start()
            try await control.start()
            try await coordinator.start()
        } catch {
            await userInterests.shutdown(); await coordinator.shutdown()
            await fanout.shutdown(); await ingress.shutdown()
            _ = await stop()
            throw error
        }
        await registry.configureRealtimeCoverageValidation(current: { kind, id in
            coordinator.currentConfirmation(kind: kind, id: id)
        }, confirms: { kind, id, value in
            coordinator.confirmsCurrent(kind: kind, id: id, confirmation: value)
        })
        await registry.configureUserSyncInterests(userInterests)
        await registry.configureLiveActivityBroker(publisher, routesLocalActivity: true)
        let refresh = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                await registry.refreshAllObservedPresence()
            }
        }
        metrics.registrations(1)
        return GatewayActorRealtimeRuntime(publisher: publisher, metrics: metrics, userSyncWakeStores: userWakeStores,
            userInterests: userInterests, coordinator: coordinator, fanout: fanout,
            ingress: ingress, stopTransport: stop, refresh: refresh, journal: journal, snapshot: {
                var value = await metrics.actorRealtimeMetricsSnapshot()
                value.transport = await shardHandle.metricsSnapshot()
                let pressure = await coordinator.pressureSnapshot()
                value.subscriptionControlActive = pressure.controlInFlight
                value.subscriptionControlQueued = pressure.controlQueued
                value.recoveryActive = pressure.recoveryInFlight
                value.recoveryQueued = pressure.recoveryQueued
                value.activationWaiters = pressure.activationWaiters
                value.desiredPartitions = pressure.partitions
                let leases = await control.pressureSnapshot()
                value.installedPartitions = leases.installed
                value.partitionControlFailedTicks = leases.failedTicks
                if let proof = serviceQualification.snapshot() {
                    let remaining = ContinuousClock.now.duration(to: proof.validUntil).components
                    value.serviceQualified = 1
                    value.serviceQualificationRemainingSeconds = max(0,
                        Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                }
                return value
            })
    }

    func actorRealtimeMetricsSnapshot() async -> V2ActorRealtimeMetricsSnapshot { await snapshot() }

    func shutdown() async -> Bool {
        refresh.cancel(); await refresh.value
        await userInterests.shutdown()
        await coordinator.shutdown(); await fanout.shutdown(); await ingress.shutdown()
        return await stopTransport()
    }

    private actor PartitionInstallation {
        let service: V2RealtimeShardService
        let advertise: @Sendable ([V2RealtimeShardLeaseAdvertisement]) async throws -> Void
        let journal: @Sendable ([GatewayRealtimePartitionControl.Installed]) async throws -> Void
        var tokens: [Int: V2RealtimeShardToken] = [:]
        init(service: V2RealtimeShardService, journal: @escaping @Sendable ([GatewayRealtimePartitionControl.Installed]) async throws -> Void,
             advertise: @escaping @Sendable ([V2RealtimeShardLeaseAdvertisement]) async throws -> Void) {
            self.service = service; self.advertise = advertise; self.journal = journal
        }
        func install(_ values: [GatewayRealtimePartitionControl.Installed]) async throws {
            let current = Dictionary(uniqueKeysWithValues: values.map { ($0.lease.partitionID, $0.token) })
            for (id, token) in tokens where current[id] != token { await service.retire(token: token) }
            tokens = current
            for value in values {
                await service.install(token: value.token, deadline: value.deadline,
                    qualificationGeneration: value.qualificationGeneration)
            }
            // Sample after service installation; advertising must never extend
            // the service's conservative deadline.
            let now = ContinuousClock.now
            let advertisements = values.compactMap { value -> V2RealtimeShardLeaseAdvertisement? in
                let duration = now.duration(to: value.deadline).components
                let ms = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
                guard ms > 0 else { return nil }
                return .init(token: value.token, remainingLeaseMilliseconds: ms)
            }
            try await advertise(advertisements)
            try await journal(values)
        }
    }

    private struct RecoveryHeads: Sendable {
        let userRouter: V2StaticUserShardRouter
        let roomKeys: [String: String]
        let userKeys: [String: String]
        let rooms: [String: PostgresV2RealtimeRoomHeadReader]
        let users: [String: PostgresV2UserSyncWakeStore]
        let metrics: V2ActorRealtimeMetrics
        func read(_ topics: [V2RealtimeTopic]) async throws -> [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] {
            guard topics.count <= 128 else { throw V2RealtimeDirectoryError.invalidInput }
            var result: [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] = [:]
            for (wireKind, metricKind) in [(V2RealtimeTopicKind.roomEvents, V2ActorRealtimeRouteQueryKind.roomEvents),
                (.userSync, .userSync), (.userPresence, .userPresence), (.roomTyping, .roomTyping)] {
                let selected = Array(Set(topics.filter { $0.kind == wireKind }))
                guard !selected.isEmpty else { continue }
                let start = ContinuousClock.now
                let values = await readKind(selected)
                // This completion is the whole actual per-kind read, including
                // physical-group failures. Count every topic separately too.
                var outcome: V2ActorRealtimeHeadReadResult = .success
                for value in values.values {
                    if case .unavailable(let reason) = value {
                        if reason == .dependency { outcome = .dependency }
                        else if outcome != .dependency && reason == .wrongOwner { outcome = .wrongOwner }
                        else if outcome == .success { outcome = .invalid }
                    }
                }
                metrics.headRead(kind: metricKind, result: outcome, topics: selected.count,
                    outcomes: Array(values.values), elapsed: start.duration(to: .now))
                result.merge(values) { _, next in next }
            }
            guard Set(result.keys) == Set(topics) else { throw V2RealtimeDirectoryError.corruptPersistenceState }
            return result
        }
        private func readKind(_ topics: [V2RealtimeTopic]) async -> [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] {
            var result: [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] = [:]
            var valid: [V2RealtimeTopic] = []
            for topic in topics {
                guard UUID(uuidString: topic.id) != nil else { result[topic] = .unavailable(.invalid); continue }
                valid.append(topic)
            }
            let durableRooms = valid.filter { $0.kind == .roomEvents }
            var roomGroups: [String: [V2RealtimeTopic]] = [:]
            for topic in durableRooms {
                guard let key = roomKeys[topic.owner.shardID], rooms[key] != nil else {
                    result[topic] = .unavailable(.wrongOwner); continue
                }
                roomGroups[key, default: []].append(topic)
            }
            for owner in roomGroups.keys.sorted() {
                guard let store = rooms[owner], let values = roomGroups[owner] else { continue }
                do {
                    let heads = try await store.heads(topics: values)
                    guard Set(heads.keys) == Set(values) else { throw V2RealtimeDirectoryError.corruptPersistenceState }
                    result.merge(heads) { _, next in next }
                } catch {
                    // One actual shared query failed. Do not launch scalar
                    // retries or prevent another physical group from reading.
                    for topic in values { result[topic] = .unavailable(.dependency) }
                }
            }
            let userTopics = valid.filter { $0.kind == .userSync }
            let ids = userTopics.map { UserID(uuid: UUID(uuidString: $0.id)!) }
            var grouped: [String: [V2RealtimeTopic]] = [:]
            do {
                let routes = try await userRouter.routes(for: ids)
                guard routes.count == userTopics.count else { throw V2RealtimeDirectoryError.corruptPersistenceState }
                for (topic, route) in zip(userTopics, routes) {
                    guard topic.owner.shardID == "user:" + route.bucket, topic.owner.epoch == route.observedRouterEpoch,
                          let key = userKeys[route.bucket], users[key] != nil else {
                        result[topic] = .unavailable(.wrongOwner); continue
                    }
                    grouped[key, default: []].append(topic)
                }
            } catch {
                for topic in userTopics { result[topic] = .unavailable(.dependency) }
            }
            for bucket in grouped.keys.sorted() {
                guard let store = users[bucket], let values = grouped[bucket] else { continue }
                do {
                    let heads = try await store.highWatermarks(userIDs: values.map { UserID(uuid: UUID(uuidString: $0.id)!) })
                    for topic in values {
                        if let head = heads[UserID(uuid: UUID(uuidString: topic.id)!)] { result[topic] = .available(head) }
                        else { result[topic] = .unavailable(.dependency) }
                    }
                } catch {
                    for topic in values { result[topic] = .unavailable(.dependency) }
                }
            }
            for topic in valid where topic.kind == .userPresence || topic.kind == .roomTyping { result[topic] = .available(0) }
            return result
        }
    }

    private struct UserInterests: V2GroupEventWakeInterestManaging {
        let publisher: V2ActorRealtimePublisher
        func activate(roomID: RoomID) async throws { try await publisher.activateUser(userID: UserID(roomID.rawValue)) }
        func deactivate(roomID: RoomID) async {
            if let user = try? UserID(roomID.rawValue) { await publisher.deactivateUser(userID: user) }
        }
    }
}
