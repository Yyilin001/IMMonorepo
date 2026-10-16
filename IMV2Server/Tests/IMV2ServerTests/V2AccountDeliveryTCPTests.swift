import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerInfrastructure
import SQLKit
@testable import IMV2Server
@testable import IMV2ServerGateway
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import Testing

@Suite("Account delivery over loopback TCP", .timeLimit(.minutes(1)))
struct V2AccountDeliveryTCPTests {
    @Test("PostgreSQL Owner drains a post-Ready commit through its pump to both TCP devices",
        .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func postgresOwnerAutomaticCoverage() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,owner_epoch,membership_revision) VALUES(\(bind: room.uuidValue!),'tcp-rooms','standard',1,1)").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),1)").run()
            let dataOwner = try V2RoomDataOwner(shardID: "tcp-rooms", epoch: 1)
            try await withRoomActivationLifetime(database: database, roomID: room, shardID: "tcp-rooms", epoch: 1) { token, lifetime in
                let source = try PostgresV2RoomSubscriptionSource(database: database, activation: token, lifetime: lifetime, schema: schema)
                let recovery = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
                let topology = try PostgresV2RoomRecoveryTopology(database: database, schema: schema,
                    stores: [recovery], orderedStoreIdentities: [schema], atomicStores: [:])
                let directory = V2UserRoomDirectoryService(snapshotSource: topology,
                    cursorCodec: try .init(key: Data(repeating: 7, count: 32)))
                let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 71, count: 32))
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: dataOwner,
                    activation: token, deadline: .now + .seconds(5), trackedUserIDs: [user])
                do {
                    try await exercise(store: PostgresV2DeviceRoomProgressStore(database: database, schema: schema),
                        user: user, rooms: [room], actorRouting: true, automaticAccountCoverage: true, automaticOwner: (owner, token, lifetime),
                        directoryPage: { user, cursor in
                            try await directory.list(actorUserID: user, cursor: cursor, pageSize: 100)
                        },
                        commitOnline: { _ in
                            try await database.transaction { db in
                                let transaction = try #require(db as? any SQLDatabase)
                                try await transaction.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=1 WHERE room_id=\(bind: room.uuidValue!)").run()
                                try await transaction.raw("INSERT INTO \(unsafeRaw: schema).room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at) VALUES(\(bind: UUID()),\(bind: room.uuidValue!),1,'message.accepted',jsonb_build_object('event_type','message.accepted','room_id',\(bind: room.rawValue),'room_sequence',1),1,clock_timestamp())").run()
                            }
                            let page = try await source.read(roomID: room, owner: dataOwner, afterRoomSequence: 0,
                                trackedUserIDs: [user], limit: 64)
                            let record = try #require(page.records.first)
                            try #require(record.hasOnlineBody)
                            return record.event
                        }, authenticator: try V2PostgresGatewayAuthenticator(database: database, tokenKey: key, schema: schema),
                        credentials: { device in
                            let token = UUID().uuidString, issued = Date(), expires = issued.addingTimeInterval(3_600)
                            try await sql.raw("INSERT INTO \(unsafeRaw: schema).auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at) VALUES(\(bind: user.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: issued),\(bind: expires))").run()
                            try await sql.raw("INSERT INTO \(unsafeRaw: schema).device_access_tokens(token_hmac,user_id,device_id,issued_at,expires_at) VALUES(\(bind: key.digest(token)),\(bind: user.uuidValue!),\(bind: device.uuidValue!),\(bind: issued),\(bind: expires))").run()
                            return token
                        })
                    try await owner.close()
                } catch {
                    try? await owner.close()
                    throw error
                }
            }
        }
    }

    @Test("signed remote membership projections retain the target room on both Gateway nodes")
    func signedMembershipTargetsAcrossGateways() async throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let registries = (0..<2).map { _ in V2DeviceConnectionRegistry(foregroundFrameLimits: limits) }
        var ingresses: [V2GatewayRoomSubscriptionIngress] = []
        for registry in registries {
            try await registry.installDeviceRoomProgressStore(TCPDeviceProgressStore())
            ingresses.append(try await registry.configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority()))
        }
        let handlers = [TCPMembershipProjectionProbe(), TCPMembershipProjectionProbe()]
        let router = try await TCPAccountClusterRouter.start(ingresses: ingresses, journalHandlers: handlers)
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        do {
            for index in handlers.indices {
                #expect(try await router.sendMembership(user: user, room: room, gateway: index) == .snapshotRequired)
                #expect(handlers[index].entries.withLock { $0 } == [
                    .init(sequence: 1, change: .userControlInvalidation(userID: user, controlVersion: 1,
                        deviceID: nil, membershipRoomID: room))])
            }
        } catch {
            await router.stop()
            for registry in registries { await registry.shutdownRealtimeRecovery() }
            throw error
        }
        await router.stop()
        for registry in registries { await registry.shutdownRealtimeRecovery() }
    }

    @Test("TCP account startup establishes shared room coverage before Ready without per-room client requests")
    func automaticAccountCoverageOverTCP() async throws {
        try await exercise(store: TCPDeviceProgressStore(), automaticAccountCoverage: true)
    }

    @Test("two TLS devices rebuild account coverage without authenticating again", arguments: [false, true])
    func coverageRecoveryOverTLS(separateGateways: Bool) async throws {
        let tls = try makeGatewayTestTLSContexts()
        try await exercise(store: TCPDeviceProgressStore(), separateGateways: separateGateways, actorRouting: separateGateways,
            automaticAccountCoverage: true, tls: tls, rebuildCoverage: true)
    }

    @Test("two online devices receive two unopened rooms and confirm independently")
    func unopenedRoomsAcrossDevices() async throws {
        try await exercise(store: TCPDeviceProgressStore())
    }

    @Test("devices on separate Gateway registries receive all unopened rooms")
    func unopenedRoomsAcrossGateways() async throws {
        try await exercise(store: TCPDeviceProgressStore(), separateGateways: true)
    }

    @Test("remote distributed callbacks deliver unopened rooms to two Gateway TCP nodes")
    func unopenedRoomsAcrossActorGateways() async throws {
        try await exercise(store: TCPDeviceProgressStore(), separateGateways: true, actorRouting: true)
    }

    @Test("remote Actor delivery rejects an old activation fence while new events reach both Gateway devices")
    func oldActivationRejectedAcrossActorGateways() async throws {
        try await exercise(store: TCPDeviceProgressStore(), separateGateways: true,
            actorRouting: true, automaticAccountCoverage: true, injectOldActivation: true)
    }

    @Test("TCP device confirmations persist through the production PostgreSQL store",
        .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func postgresDeviceConfirmations() async throws {
        try await withUserEventDatabase { database, _, schema in
            try await exercise(store: PostgresV2DeviceRoomProgressStore(database: database, schema: schema))
        }
    }

    func exercise(store: any V2DeviceRoomProgressStoring, user: UserID = .init(uuid: UUID()),
                  rooms: [RoomID] = [.init(uuid: UUID()), .init(uuid: UUID())],
                  committed: (activation: V2RoomActivationToken, event: V2RealtimeRoomEvent,
                              member: V2RoomSubscriptionMember)? = nil,
                  separateGateways: Bool = false, actorRouting: Bool = false, automaticAccountCoverage: Bool = false,
                  injectOldActivation: Bool = false, retiredActivation: V2RoomActivationToken? = nil,
                  automaticOwner: (owner: V2RoomSubscriptionOwner, activation: V2RoomActivationToken, lifetime: V2RoomActivationLifetime)? = nil,
                  automaticHost: V2RoomSubscriptionHost? = nil,
                  directoryPage: (@Sendable (UserID, String?) async throws -> V2UserRoomDirectoryPage)? = nil,
                  messageCommands: V2GatewayMessageCommands? = nil,
                  commitOnline: (@Sendable (Int) async throws -> V2RealtimeRoomEvent)? = nil,
                  authenticator: (any V2GatewayAuthenticator)? = nil,
                  tls: (server: NIOSSLContext, client: NIOSSLContext)? = nil, rebuildCoverage: Bool = false,
                  credentials: @escaping @Sendable (DeviceID) async throws -> String = { _ in "tcp-test" }) async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let authenticator = authenticator ?? TCPAccountAuthenticator(user: user)
        let registries = (0..<(separateGateways ? 2 : 1)).map { _ in V2DeviceConnectionRegistry(foregroundFrameLimits: limits) }
        var ingresses: [V2GatewayRoomSubscriptionIngress] = []
        for registry in registries {
            try await registry.installDeviceRoomProgressStore(store)
            ingresses.append(try await registry.configureRoomSubscriptionIngress(authority: V2GatewayRoomSubscriptionAuthority()))
        }
        let scans = Mutex(0), subscriptions = Mutex(0)
        let scannedAccounts = Mutex([UserID]()), subscribedAccounts = Mutex([UserID]())
        let installedFences = Mutex<[String: V2RoomSubscriptionFence]>([:])
        var ownerPumps: [V2RoomSubscriptionDeliveryPump] = []
        var router: TCPAccountClusterRouter?
        let automaticFences = try Dictionary(uniqueKeysWithValues: (automaticAccountCoverage ? rooms : []).map { room in
            let activation = try automaticOwner?.activation ?? V2RoomActivationToken(roomID: room, owner: .init(shardID: "tcp-rooms", epoch: 1),
                activationEpoch: try .init(1), host: .init(hostID: try .init("tcp-owner"), incarnationID: UUID()))
            return (room, V2RoomSubscriptionFence(activation: activation, subscriptionID: UUID(), generation: 1, baselineSequence: 0))
        })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var clients: [any Channel] = []
        var listeners: [any Channel] = []
        do {
        if automaticAccountCoverage {
            precondition(committed == nil && (automaticOwner == nil || !separateGateways))
            if actorRouting { router = try await TCPAccountClusterRouter.start(ingresses: ingresses) }
            let deliveryRouter = router
            for gatewayIndex in registries.indices {
            let registry = registries[gatewayIndex], ingress = ingresses[gatewayIndex]
            let gateway = await deliveryRouter?.descriptor(gateway: gatewayIndex) ?? V2GatewayRealtimeDescriptor(identity: .init(nodeID: "tcp-gateway-\(gatewayIndex)", serviceID: "tcp-gateway-\(gatewayIndex)", incarnationID: UUID()),
                endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
            let sendDelivery: V2RoomSubscriptionDeliveryPump.Send = { delivery, shard, _ in
                let result: V2RoomSubscriptionDeliveryResult
                if let deliveryRouter { result = try await deliveryRouter.send(delivery, gateway: gatewayIndex) }
                else { result = await ingress.applyRoomSubscription(delivery, authenticatedServiceID: "owner", sourceShardID: shard) }
                #expect(result != .stale)
                return result
            }
            let pump: V2RoomSubscriptionDeliveryPump
            if let automaticHost {
                try await automaticHost.configure(sendBatch: { batch, shard, target in
                    var receipts: [V2RoomSubscriptionBatchReceipt] = []
                    for delivery in batch.deliveries {
                        receipts.append(.init(fence: delivery.fence,
                            result: try await sendDelivery(delivery, shard, target)))
                    }
                    return .init(receipts: receipts)
                }, maximumCalls: 1)
                pump = try #require(await automaticHost.currentPump())
                let automaticOwner = try #require(automaticOwner)
                try await automaticHost.register(automaticOwner.owner, token: automaticOwner.activation, lifetime: automaticOwner.lifetime)
            } else {
                pump = V2RoomSubscriptionDeliveryPump(send: sendDelivery)
                await pump.start()
            }
            ownerPumps.append(pump)
            try await registry.configureRoomSubscriptionPorts(.init(gateway: gateway,
                resolve: { room, _ in .init(activation: automaticFences[room]!.activation, authenticatedServiceID: "owner") },
                subscribe: { command, token, deadline in
                    subscriptions.withLock { $0 += 1 }
                    subscribedAccounts.withLock { $0.append(command.actorUserID) }
                    if let automaticOwner {
                        let grant = try await automaticOwner.owner.subscribe(gateway: gateway.identity, userID: user,
                            token: token, deadline: deadline)
                        installedFences.withLock { $0["\(gatewayIndex):\(command.roomID.rawValue)"] = grant.fence }
                        return .granted(.init(fence: grant.fence, memberRevision: grant.memberRevision,
                            userBaselineSequence: grant.baselineSequence, deliverySession: testDeliverySession(fence: grant.fence, gateway: gateway.identity, authority: ingress.authority)))
                    }
                    let key = "\(gatewayIndex):\(command.roomID.rawValue)"
                    let generation = installedFences.withLock { ($0[key]?.generation ?? 0) + 1 }
                    let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: generation, baselineSequence: 0)
                    installedFences.withLock { $0["\(gatewayIndex):\(command.roomID.rawValue)"] = fence }
                    return .granted(.init(fence: fence, memberRevision: 1,
                        userBaselineSequence: 0, deliverySession: testDeliverySession(fence: fence, gateway: gateway.identity, authority: ingress.authority)))
                }, reset: { _, _, _ in .failure(.unavailable) },
                activate: { command, token, deadline in
                    if let automaticOwner {
                        try #require(try await automaticOwner.owner.activate(to: pump, descriptor: gateway, userID: user,
                            fence: command.fence, token: token, deadline: deadline))
                        return .activated
                    }
                    let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                        authorizationSequence: 1, payload: .baseline(members: [.init(userID: user, memberRevision: 1)])),
                        authenticatedServiceID: "owner", sourceShardID: "tcp-rooms")
                    #expect(result == .appliedThrough(1))
                    return .activated
                }, unsubscribe: { _, _, _ in .unsubscribed }), ingress: ingress)
            let entries = try rooms.map { try V2UserRoomDirectoryEntry(roomID: $0, roomKind: .group, viewerMembershipRevision: 1, ownerEpoch: 1) }
            let service = try V2AccountRoomChangeService(states: TCPAccountUnusedStates(),
                directoryPage: { user, cursor in
                    scans.withLock { $0 += 1 }
                    scannedAccounts.withLock { $0.append(user) }
                    if let directoryPage { return try await directoryPage(user, cursor) }
                    return .init(rooms: entries, nextCursor: nil, topologyGeneration: "tcp-auto")
                }, onlineDelivery: .init(activate: { [weak registry] user, room, reference in
                    guard let registry else { throw V2AccountRoomChangeService.Failure.closed }
                    try await registry.acquireAccountRoomDelivery(userID: user, roomID: room, reference: reference)
                }, deactivate: { [weak registry] reference in await registry?.releaseAccountRoomDelivery(reference: reference) }))
            await registry.configureAccountRoomChanges(service)
            }
        }
            if actorRouting && router == nil { router = try await TCPAccountClusterRouter.start(ingresses: ingresses) }
            for registry in registries {
                let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    do {
                        let connectionID = UUID()
                        let stream = V2GatewayByteStream(frameLimits: limits,
                            session: .init(limits: try .init(maximumInFlightRequests: 4),
                                authenticator: authenticator, capabilityProfile: "base",
                                commandAdmission: V2AllowingGatewayCommandAdmission()),
                            handler: TCPAccountCommands(registry: registry, connectionID: connectionID, messages: messageCommands), connectionID: connectionID, registry: registry)
                        if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server)) }
                        try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(stream: stream,
                            maximumQueuedInboundBytes: 16_384, maximumQueuedInboundChunks: 16,
                            authenticationTimeoutMilliseconds: 30_000, idleTimeoutMilliseconds: 30_000,
                            transportMetrics: V2GatewayTransportMetrics()))
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: "127.0.0.1", port: 0).get()
                listeners.append(listener)
            }
            var receivers: [AsyncThrowingStream<IMV2Envelope, Error>.Iterator] = []
            var devices: [DeviceID] = []
            var coverageEpochs: [String] = []
            for index in 0..<2 {
                let port = try #require(listeners[index % listeners.count].localAddress?.port)
                let output = AsyncThrowingStream<IMV2Envelope, Error>.makeStream()
                let client = try await ClientBootstrap(group: group).channelInitializer { channel in
                    do {
                        if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls.client, serverHostname: "localhost")) }
                        try channel.pipeline.syncOperations.addHandler(TCPAccountFrameReader(limits: limits, output: output.continuation))
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.connect(host: "127.0.0.1", port: port).get()
                clients.append(client)
                let device = DeviceID(uuid: UUID()); devices.append(device)
                var reader = output.stream.makeAsyncIterator()
                var hello = IMV2Envelope(); hello.requestID = 1
                hello.clientHello.deviceID = device.rawValue
                hello.clientHello.supportedProtocolVersions = [UInt32(version)]
                hello.clientHello.supportedCapabilityProfiles = ["base"]
                try await send(hello, version: 0, limits: limits, channel: client)
                guard case .serverHello? = try await reader.next()?.body else { throw V2RoomRecoveryReadError.corruptPersistence }
                var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
                auth.authenticate.accessToken = try await credentials(device); auth.authenticate.deviceID = device.rawValue
                try await send(auth, version: version, limits: limits, channel: client)
                guard case .authenticated? = try await reader.next()?.body else { throw V2RoomRecoveryReadError.corruptPersistence }
                if automaticAccountCoverage {
                    var start = IMV2Envelope(); start.requestID = 10; start.protocolVersion = UInt32(version)
                    start.accountRoomChangesStart = .init()
                    var ready = false
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !ready, ContinuousClock.now < deadline {
                        try await send(start, version: version, limits: limits, channel: client)
                        while let response = try await reader.next() {
                            if case .accountRoomChangesReady(let grant) = response.body { coverageEpochs.append(grant.connectionEpoch); ready = true; break }
                            if case .error = response.body {
                                try #require(response.error.code == "UNAVAILABLE" && response.error.retryable)
                                break
                            }
                            guard case .realtimeCoverage = response.body else { throw V2RoomRecoveryReadError.corruptPersistence }
                        }
                        start.requestID += 1
                        await Task.yield()
                    }
                    try #require(ready)
                }
                receivers.append(reader)
            }
            if automaticAccountCoverage {
                #expect(scans.withLock { $0 } == registries.count, "scanned accounts: \(scannedAccounts.withLock { $0 })")
                #expect(subscriptions.withLock { $0 } == rooms.count * registries.count, "subscribed accounts: \(subscribedAccounts.withLock { $0 })")
            }
            if rebuildCoverage {
                for registry in registries { await registry.invalidateAccountRoomCoverage() }
                for index in clients.indices {
                    var resetReceived = false
                    while let frame = try await receivers[index].next() {
                        if case .accountRoomResyncRequired(let reset) = frame.body {
                            #expect(reset.connectionEpoch == coverageEpochs[index])
                            resetReceived = true; break
                        }
                        guard case .realtimeCoverage = frame.body else { throw V2RoomRecoveryReadError.corruptPersistence }
                    }
                    try #require(resetReceived)
                    var start = IMV2Envelope(); start.protocolVersion = UInt32(version); start.requestID = 100
                    start.accountRoomChangesStart = .init()
                    var ready = false
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !ready, ContinuousClock.now < deadline {
                        try await send(start, version: version, limits: limits, channel: clients[index])
                        while let response = try await receivers[index].next() {
                            if case .accountRoomChangesReady(let grant) = response.body {
                                #expect(grant.connectionEpoch != coverageEpochs[index])
                                ready = true; break
                            }
                            if case .error(let error) = response.body {
                                try #require(error.code == "UNAVAILABLE" && error.retryable); break
                            }
                            guard case .realtimeCoverage = response.body else { throw V2RoomRecoveryReadError.corruptPersistence }
                        }
                        start.requestID += 1
                        await Task.yield()
                    }
                    try #require(ready)
                    #expect(clients[index].isActive)
                }
                #expect(scans.withLock { $0 } == registries.count * 2)
                #expect(subscriptions.withLock { $0 } == rooms.count * registries.count * 2)
            }
            let committedOnline = try await commitOnline?(try #require(listeners.first?.localAddress?.port))
            if let automaticOwner, automaticHost == nil {
                let report = try await automaticOwner.owner.drain(token: automaticOwner.activation, deadline: .now + .seconds(5))
                try #require(report.consumedThrough == 1)
                try #require(report.observedHighWatermark == 1)
                await automaticOwner.owner.signalDelivery()
            }
            var fences: [V2RoomSubscriptionFence] = []
            var oldFences: [Int: V2RoomSubscriptionFence] = [:]
            for room in rooms {
                let activation = try automaticFences[room]?.activation ?? committed?.activation ?? V2RoomActivationToken(roomID: room, owner: .init(shardID: "tcp-rooms", epoch: 1),
                    activationEpoch: try .init(1), host: .init(hostID: try .init("tcp-owner"), incarnationID: UUID()))
                let shard = activation.owner.shardID
                #expect(activation.roomID == room)
                for (index, ingress) in ingresses.enumerated() {
                    var fence = automaticAccountCoverage ? (installedFences.withLock { $0["\(index):\(room.rawValue)"] } ?? automaticFences[room]!) : V2RoomSubscriptionFence(activation: activation, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
                    if !automaticAccountCoverage {
                        #expect(await ingress.installTestSession(fence: fence, sourceShardID: shard, serviceID: "owner"))
                        let member = committed?.member ?? V2RoomSubscriptionMember(userID: user, memberRevision: 1)
                        let baseline = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1,
                            authorizationSequence: 1, payload: .baseline(members: [member]))
                        if let router { #expect(try await router.send(baseline, gateway: index) == .appliedThrough(1)) }
                        else { #expect(await ingress.applyRoomSubscription(baseline,
                            authenticatedServiceID: "owner", sourceShardID: shard) == .appliedThrough(1)) }
                    }
                    let member = committed?.member ?? V2RoomSubscriptionMember(userID: user, memberRevision: 1)
                    if injectOldActivation || retiredActivation != nil {
                        let remote = try #require(router)
                        let oldFence = retiredActivation.map { V2RoomSubscriptionFence(activation: $0,
                            subscriptionID: UUID(), generation: 1, baselineSequence: 0) } ?? fence
                        if room == rooms[0] { oldFences[index] = oldFence }
                        if retiredActivation == nil {
                            let replacement = V2RoomSubscriptionFence(activation: .init(roomID: room,
                                owner: oldFence.activation.owner, activationEpoch: try .init(2),
                                host: .init(hostID: oldFence.activation.host.hostID, incarnationID: UUID())),
                                subscriptionID: UUID(), generation: 1, baselineSequence: 0)
                            try #require(await ingress.installTestSession(fence: replacement, sourceShardID: shard,
                                serviceID: "owner"))
                            let baseline = V2RoomSubscriptionDelivery(fence: replacement, deliverySequence: 1,
                                authorizationSequence: 1, payload: .baseline(members: [member]))
                            #expect(try await remote.send(baseline, gateway: index) == .appliedThrough(1))
                            fence = replacement
                        } else {
                            #expect(oldFence.activation != fence.activation)
                            #expect(oldFence.activation.activationEpoch < fence.activation.activationEpoch)
                        }
                        let staleEvent = V2RealtimeRoomEvent(roomID: room, highWatermark: 99,
                            sourceEventID: .init(uuid: UUID()), roomSequence: 99,
                            projectionKind: "message", payload: Data([9]), recipientUserIDs: [user])
                        let late = V2RoomSubscriptionDelivery(fence: oldFence, deliverySequence: 2,
                            authorizationSequence: 1, payload: .event(staleEvent, members: [member]))
                        #expect(try await remote.send(late, gateway: index) == .stale)
                    }
                    fences.append(fence)
                    let event = committedOnline ?? committed?.event ?? V2RealtimeRoomEvent(roomID: room, highWatermark: 1, sourceEventID: .init(uuid: UUID()),
                        roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [user])
                    let delivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 2,
                        authorizationSequence: 1, payload: .event(event, members: [member]))
                    if automaticOwner == nil {
                    if let router { #expect(try await router.send(delivery, gateway: index) == .appliedThrough(2)) }
                    else { #expect(await ingress.applyRoomSubscription(delivery,
                        authenticatedServiceID: "owner", sourceShardID: shard) == .appliedThrough(2)) }
                    }
                }
                for index in receivers.indices {
                    var delivered = try await receivers[index].next()
                    while let body = delivered?.body {
                        switch body {
                        case .groupEventAvailable(let hint) where hint.eventPayload.isEmpty:
                            #expect(rooms.contains(where: { $0.rawValue == hint.roomID }) && hint.highWatermark == 1)
                            delivered = try await receivers[index].next()
                            continue
                        case .realtimeCoverage: delivered = try await receivers[index].next()
                        default: break
                        }
                        if case .groupEventAvailable? = delivered?.body { break }
                        if case .realtimeCoverage? = delivered?.body { continue }
                        break
                    }
                    guard case .groupEventAvailable(let hint)? = delivered?.body else {
                        throw V2RoomRecoveryReadError.corruptPersistence
                    }
                    #expect(hint.roomID == room.rawValue && hint.highWatermark == 1)
                    let expectedPayload = committedOnline?.payload ?? committed?.event.payload ?? Data([1])
                    if automaticHost != nil {
                        let deliveredBody = try #require(JSONSerialization.jsonObject(with: hint.eventPayload) as? NSDictionary)
                        let persistedBody = try #require(JSONSerialization.jsonObject(with: expectedPayload) as? NSDictionary)
                        #expect(deliveredBody == persistedBody)
                    } else { #expect(hint.eventPayload == expectedPayload) }
                }
            }
            for index in clients.indices {
                var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(version)
                request.deviceRoomProgressReport = .init()
                request.deviceRoomProgressReport.rooms = rooms.map { room in
                    var cursor = IMV2DeviceRoomCursor(); cursor.roomID = room.rawValue
                    cursor.appliedThrough = index == 0 ? 1 : 0; return cursor
                }
                try await send(request, version: version, limits: limits, channel: clients[index])
                guard case .deviceRoomProgressRecorded(let confirmed) = try await nextCommandResponse(
                    &receivers[index], requestID: 3, rooms: rooms).body else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                #expect(confirmed.rooms == request.deviceRoomProgressReport.rooms)
                #expect(try await store.load(userID: user, deviceID: devices[index], roomIDs: rooms) ==
                    Dictionary(uniqueKeysWithValues: rooms.map { ($0, index == 0 ? UInt64(1) : UInt64(0)) }))
            }
            if automaticOwner == nil {
            for (index, ingress) in ingresses.enumerated() {
                let revoke = V2RoomSubscriptionDelivery(fence: fences[index], deliverySequence: 3,
                    authorizationSequence: 2, payload: .revoke(userID: user, memberRevision: committed?.member.memberRevision ?? 1))
                if let router { #expect(try await router.send(revoke, gateway: index) == .appliedThrough(3)) }
                else { #expect(await ingress.applyRoomSubscription(revoke,
                    authenticatedServiceID: "owner", sourceShardID: fences[0].activation.owner.shardID) == .appliedThrough(3)) }
            }
            if let router {
                for (index, oldFence) in oldFences {
                    let oldMember = V2RoomSubscriptionMember(userID: user, memberRevision: committed?.member.memberRevision ?? 1)
                    let lateGrant = V2RoomSubscriptionDelivery(fence: oldFence, deliverySequence: 3,
                        authorizationSequence: 2, payload: .grant(member: oldMember, baselineSequence: 0))
                    #expect(try await router.send(lateGrant, gateway: index) == .stale)
                    let lateBaseline = V2RoomSubscriptionDelivery(fence: oldFence, deliverySequence: 1,
                        authorizationSequence: 1, payload: .baseline(members: [oldMember]))
                    #expect(try await router.send(lateBaseline, gateway: index) == .stale)
                    #expect(await ingresses[index].authority.captureOnlinePermits(roomID: rooms[0]).isEmpty)
                }
            }
            for index in clients.indices {
                var revoked = IMV2Envelope(); revoked.requestID = 4; revoked.protocolVersion = UInt32(version)
                revoked.deviceRoomProgressReport = .init()
                var cursor = IMV2DeviceRoomCursor(); cursor.roomID = rooms[0].rawValue; cursor.appliedThrough = 1
                revoked.deviceRoomProgressReport.rooms = [cursor]
                try await send(revoked, version: version, limits: limits, channel: clients[index])
                guard case .error(let denial) = try await nextCommandResponse(&receivers[index], requestID: 4, rooms: rooms).body else { throw V2RoomRecoveryReadError.corruptPersistence }
                #expect(denial.code == "FORBIDDEN" && !denial.retryable)
                var heartbeat = IMV2Envelope(); heartbeat.requestID = 5; heartbeat.protocolVersion = UInt32(version); heartbeat.heartbeat = .init()
                try await send(heartbeat, version: version, limits: limits, channel: clients[index])
                guard case .heartbeatAck = try await nextCommandResponse(&receivers[index], requestID: 5, rooms: rooms).body else { throw V2RoomRecoveryReadError.corruptPersistence }
            }
            }
            for pump in ownerPumps { await pump.close() }
            for client in clients { try await client.close().get() }
            for listener in listeners { try await listener.close().get() }
            for registry in registries { await registry.shutdownRealtimeRecovery() }
            await router?.stop()
            try await group.shutdownGracefully()
        } catch {
            for pump in ownerPumps { await pump.close() }
            for client in clients { try? await client.close().get() }
            for listener in listeners { try? await listener.close().get() }
            for registry in registries { await registry.shutdownRealtimeRecovery() }
            await router?.stop()
            try? await group.shutdownGracefully()
            throw error
        }
    }
    private func nextCommandResponse(_ reader: inout AsyncThrowingStream<IMV2Envelope, Error>.Iterator,
        requestID: UInt64, rooms: [RoomID]) async throws -> IMV2Envelope {
        while let envelope = try await reader.next() {
            if envelope.requestID == requestID { return envelope }
            guard case .groupEventAvailable(let hint) = envelope.body,
                  rooms.contains(where: { $0.rawValue == hint.roomID }),
                  hint.highWatermark == 1, hint.eventPayload.isEmpty else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
        }
        throw V2RoomRecoveryReadError.corruptPersistence
    }

    private func send(_ envelope: IMV2Envelope, version: UInt8, limits: V2FrameLimits, channel: any Channel) async throws {
        let bytes = try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), limits: limits)
        var buffer = channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    func sendOperationOverTCP(port: Int, token: String, device: DeviceID,
                              command: V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var client: (any Channel)?
        do {
            let output = AsyncThrowingStream<IMV2Envelope, Error>.makeStream()
            let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(TCPAccountFrameReader(limits: limits, output: output.continuation))
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(host: "127.0.0.1", port: port).get()
            client = channel
            var reader = output.stream.makeAsyncIterator()
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.supportsMessageSendOperations = true
            try await send(hello, version: 0, limits: limits, channel: channel)
            guard case .serverHello? = try await reader.next()?.body else { throw V2RoomRecoveryReadError.corruptPersistence }
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.deviceID = device.rawValue; auth.authenticate.accessToken = token
            try await send(auth, version: version, limits: limits, channel: channel)
            guard case .authenticated? = try await reader.next()?.body else { throw V2RoomRecoveryReadError.corruptPersistence }
            var request = IMV2Envelope(); request.requestID = 3; request.protocolVersion = UInt32(version)
            request.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: command)
            try await send(request, version: version, limits: limits, channel: channel)
            guard case .messageSendOperationResult(let wire)? = try await reader.next()?.body else { throw V2RoomRecoveryReadError.corruptPersistence }
            let result = try V2MessageSendOperationWireCodec.decode(result: wire)
            try await channel.close().get()
            try await group.shutdownGracefully()
            return result
        } catch {
            try? await client?.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class TCPMembershipProjectionProbe: V2RealtimeJournalProjectionHandler, Sendable {
    let entries = Mutex<[V2RealtimeJournalProjectionEntry]>([])
    func applyJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                authenticatedServiceID: String) -> V2RealtimeJournalProjectionResult {
        #expect(authenticatedServiceID == "owner")
        guard case .changes(_, _, let incoming) = batch.payload else { return .invalid }
        entries.withLock { $0.append(contentsOf: incoming) }
        return .snapshotRequired
    }
}
private struct TCPAccountAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication { .init(userID: user, expiresAt: nil) }
}
private struct TCPAccountCommands: V2GatewayCommandHandler {
    let registry: V2DeviceConnectionRegistry
    let connectionID: UUID
    let messages: V2GatewayMessageCommands?
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        if case .messageSendOperation(let wire) = envelope.body, let messages {
            return try await messages.send(wire, identity: identity)
        }
        guard case .accountRoomChangesStart = envelope.body else { throw V2RoomRecoveryReadError.invalidRequest }
        var response = IMV2Envelope()
        do {
            response.accountRoomChangesReady.connectionEpoch = try await registry.startAccountRoomChanges(connectionID: connectionID, userID: identity.userID)
        } catch V2AccountRoomChangeService.Failure.closed, V2AccountRoomChangeService.Failure.staleConnection {
            response.error.code = "UNAVAILABLE"; response.error.retryable = true
        } catch V2RealtimePublicationBackpressure.receiverQueue {
            response.error.code = "UNAVAILABLE"; response.error.retryable = true
        } catch let error as V2GatewayRoomSubscriptionCoordinationError {
            Issue.record("account startup coordinator failed: \(error)")
            throw error
        }
        return response
    }
}
private final class TCPAccountFrameReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var decoder: V2FrameDecoder
    let output: AsyncThrowingStream<IMV2Envelope, Error>.Continuation
    init(limits: V2FrameLimits, output: AsyncThrowingStream<IMV2Envelope, Error>.Continuation) { decoder = .init(limits: limits); self.output = output }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        do { for frame in try decoder.append(Data(buffer.readableBytesView)) { output.yield(try V2ServerProtobufFrameCodec.decode(frame)) } }
        catch { output.finish(throwing: error); context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { output.finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { output.finish(throwing: error); context.close(promise: nil) }
}
private actor TCPDeviceProgressStore: V2DeviceRoomProgressStoring {
    private var devices: [DeviceID: [RoomID: UInt64]] = [:]
    func record(userID: UserID, deviceID: DeviceID, progress: [V2DeviceRoomProgress]) async throws {
        for item in progress { devices[deviceID, default: [:]][item.roomID] = max(devices[deviceID]?[item.roomID] ?? 0, item.appliedThrough) }
    }
    func load(userID: UserID, deviceID: DeviceID, roomIDs: [RoomID]) async throws -> [RoomID: UInt64] { devices[deviceID, default: [:]].filter { roomIDs.contains($0.key) } }
}

private struct TCPAccountUnusedStates: V2RoomStateReading {
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        throw V2RoomRecoveryReadError.invalidRequest
    }
}
