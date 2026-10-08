import Crypto
import Distributed
@testable import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerGateway
import IMV2ServerContracts
import IMV2ServerApplication
import NIOCore
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Room subscription real Cluster transport", .serialized)
struct V2RoomSubscriptionNetworkTests {
    @Test("all callback types share global sixteen and per-peer two admission")
    func sharedCallbackAdmission() async throws {
        let system = await makeSystem(name: "callback-budget", port: Int.random(in: 30_000...44_999))
        let keys = try Keys()
        let sender = V2RealtimeClusterSender(system: system, signer: keys.publisher,
            trust: keys.trust, limits: .init(maximumConcurrentCalls: 16))
        let peers = (0..<9).map { V2GatewayRealtimeIdentity(nodeID: "peer-\($0)",
            serviceID: "gateway", incarnationID: UUID()) }
        for peer in peers.prefix(8) {
            try await sender.acquireCallback(to: peer)
            try await sender.acquireCallback(to: peer)
        }
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await sender.acquireCallback(to: peers[8])
        }
        await sender.releaseCallback(to: peers[0])
        try await sender.acquireCallback(to: peers[8])
        // Leave global capacity available so this rejection proves the peer cap.
        await sender.releaseCallback(to: peers[8])
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await sender.acquireCallback(to: peers[1])
        }
        // A shutdown deadline does not settle outstanding ownership. The
        // sender stays closed until those invocation owners release it.
        #expect(await sender.stop(deadline: .now) == false)
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await sender.acquireCallback(to: peers[8])
        }
        await sender.releaseCallback(to: peers[0])
        for peer in peers[1..<8] {
            await sender.releaseCallback(to: peer)
            await sender.releaseCallback(to: peer)
        }
        #expect(await sender.stop(deadline: .now + .seconds(1)))
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await sender.acquireCallback(to: peers[0])
        }
        try await system.shutdown().wait()
    }

    @Test("signed room callbacks commit actual gateway authority over TCP and reject retired node identity", arguments: [false, true])
    func remoteRoomSubscriptionAuthority(binary: Bool) async throws {
        let callerPort = Int.random(in: 30_000...44_999), peerPort = Int.random(in: 45_000...60_000)
        let keys = try Keys()
        let callerSystem = await makeSystem(name: "room-subscription-caller", port: callerPort, binary: binary)
        var peerSystem = await makeSystem(name: "room-subscription-peer", port: peerPort)
        var callerHandle: V2RealtimeTransportHandle?
        var peerHandle: V2RealtimeTransportHandle?
        var failure: (any Error)?
        do {
            let caller = try buildRealtimeTransport(system: callerSystem,
                identity: .init(nodeID: "publisher", serviceID: "publisher", incarnationID: UUID()),
                address: "127.0.0.1", port: callerPort, signer: keys.publisher, trust: keys.trust,
                ingress: RejectingIngress(), serviceOwnerAccess: [keys.publisher.serviceID: ["rooms"]],
                limits: .init(callTimeout: .seconds(5)))
            callerHandle = caller
            let first = try makePeer(system: peerSystem, port: peerPort, keys: keys)
            peerHandle = first
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let dataOwner = try V2RoomDataOwner(shardID: "rooms", epoch: 0)
            let ownerHost = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            let activation = V2RoomActivationToken(roomID: room, owner: dataOwner,
                activationEpoch: try .init(1), host: ownerHost)
            let fence = V2RoomSubscriptionFence(activation: activation, subscriptionID: UUID(),
                generation: 1, baselineSequence: 0)
            let authority = V2GatewayRoomSubscriptionAuthority()
            let connection = UUID(), lifecycle = UUID()
            #expect(authority.registerConnection(connection, userID: user, lifecycle: lifecycle))
            #expect(await authority.registerRoomInterest(connectionID: connection, lifecycle: lifecycle,
                roomID: room, scopeGeneration: 1))
            let offered = Mutex<[V2GatewayRoomSubscriptionAuthority.Permit]>([])
            let ingress = V2GatewayRoomSubscriptionIngress(authority: authority,
                offerEvent: { _, permits in offered.withLock { $0.append(contentsOf: permits) } }, offerHead: { _, _ in })
            #expect(await ingress.install(fence: fence, sourceShardID: "rooms", serviceID: "publisher", deadline: .now + .seconds(60)))
            try await first.configureRoomSubscription(ingress)
            let targetID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: first.descriptor.endpointReference)
            let remote = try V2GatewayRealtimeEndpoint.resolve(id: targetID, using: callerSystem)
            #expect(__isRemoteActor(remote))
            #expect(targetID.node != callerSystem.cluster.node)
            callerSystem.cluster.join(host: "127.0.0.1", port: peerPort)
            let member = V2RoomSubscriptionMember(userID: user, memberRevision: 1)
            let baseline = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [member]))
            #expect(try await caller.sendRoomSubscription(baseline, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(1))
            let association = try #require(callerSystem._cluster?.getSpecificExistingAssociation(with: targetID.node))
            let channel = try #require(association.lock.withLock { () -> (any Channel)? in
                if case .associated(let channel) = association.state { return channel }; return nil
            })
            #expect(channel.isActive)
            #expect(channel.remoteAddress?.port == peerPort)
            let event = V2RealtimeRoomEvent(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
                roomSequence: 1, projectionKind: "message", payload: Data("remote".utf8), recipientUserIDs: [user])
            let delivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 2, authorizationSequence: 1, payload: .event(event, members: [member]))
            #expect(try await caller.sendRoomSubscription(delivery, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(2))
            #expect(offered.withLock { $0.count } == 1)
            // A second room installs a large grant over real signed remote calls.
            // No foreground room interest is registered for this room.
            let largeRoom = RoomID(uuid: UUID())
            let largeActivation = V2RoomActivationToken(roomID: largeRoom, owner: dataOwner,
                activationEpoch: try .init(1), host: ownerHost)
            let largeFence = V2RoomSubscriptionFence(activation: largeActivation, subscriptionID: UUID(),
                generation: 1, baselineSequence: 0)
            try #require(await ingress.install(fence: largeFence, sourceShardID: "rooms", serviceID: "publisher", deadline: .now + .seconds(60)))
            let largeMembers = [member] + (1..<513).map { _ in V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 1) }
            let firstPage = V2RoomSubscriptionDelivery(fence: largeFence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baselinePage(index: 0, totalMembers: 513, members: Array(largeMembers.prefix(512))))
            #expect(try await caller.sendRoomSubscription(firstPage, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(1))
            await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
                try await authority.validateDeviceProgress(connectionID: connection, userID: user, reports: [(largeRoom, 0)])
            }
            let lastPage = V2RoomSubscriptionDelivery(fence: largeFence, deliverySequence: 2, authorizationSequence: 2,
                payload: .baselinePage(index: 1, totalMembers: 513, members: [largeMembers[512]]))
            #expect(try await caller.sendRoomSubscription(lastPage, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(2))
            #expect(try await authority.validateDeviceProgress(connectionID: connection, userID: user,
                reports: [(largeRoom, 0)]).count == 1)
            let permit = try #require(offered.withLock { $0.first })
            #expect(permit.connectionID == connection && permit.lifecycle == lifecycle)
            let initiallyAuthorized = authority.enqueueIfCurrent(permit, enqueue: {})
            #expect(initiallyAuthorized)
            // New signed attempt after a lost ACK returns the actual checkpoint
            // without offering the body again.
            #expect(try await caller.sendRoomSubscription(delivery, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(2))
            #expect(offered.withLock { $0.count } == 1)
            await #expect(throws: V2ActorAuthenticationError.invalidRequest) {
                try await caller.sendRoomSubscription(delivery, sourceShardID: "other", to: first.descriptor)
            }
            let revoke = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 3, authorizationSequence: 2,
                payload: .revoke(userID: user, memberRevision: 2))
            #expect(try await caller.sendRoomSubscription(revoke, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(3))
            let authorizedAfterRevoke = authority.enqueueIfCurrent(permit, enqueue: {})
            #expect(!authorizedAfterRevoke)

            // The business lease moves while the data owner remains epoch 0.
            // A fresh room activation starts its subscription generation at 1.
            let nextHost = V2ActorHostIdentity(hostID: ownerHost.hostID, incarnationID: UUID())
            let nextActivation = V2RoomActivationToken(roomID: room, owner: dataOwner,
                activationEpoch: try .init(2), host: nextHost)
            let nextFence = V2RoomSubscriptionFence(activation: nextActivation, subscriptionID: UUID(),
                generation: 1, baselineSequence: 1)
            #expect(await ingress.install(fence: nextFence, sourceShardID: "rooms", serviceID: "publisher", deadline: .now + .seconds(60)))
            let nextBaseline = V2RoomSubscriptionDelivery(fence: nextFence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [member]))
            #expect(try await caller.sendRoomSubscription(nextBaseline, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(1))
            let nextEvent = V2RealtimeRoomEvent(roomID: room, highWatermark: 2, sourceEventID: EventID(uuid: UUID()),
                roomSequence: 2, projectionKind: "message", payload: Data("new-activation".utf8), recipientUserIDs: [user])
            let nextDelivery = V2RoomSubscriptionDelivery(fence: nextFence, deliverySequence: 2, authorizationSequence: 1,
                payload: .event(nextEvent, members: [member]))
            #expect(try await caller.sendRoomSubscription(nextDelivery, sourceShardID: "rooms", to: first.descriptor) == .appliedThrough(2))
            #expect(offered.withLock { $0.count } == 2)
            #expect(try await caller.sendRoomSubscription(delivery, sourceShardID: "rooms", to: first.descriptor) == .stale)
            let conflictingActivation = V2RoomActivationToken(roomID: room, owner: dataOwner,
                activationEpoch: try .init(2), host: .init(hostID: nextHost.hostID, incarnationID: UUID()))
            let conflictingFence = V2RoomSubscriptionFence(activation: conflictingActivation, subscriptionID: UUID(),
                generation: 2, baselineSequence: 1)
            #expect(!(await ingress.install(fence: conflictingFence, sourceShardID: "rooms", serviceID: "publisher", deadline: .now + .seconds(60))))
            #expect(try await caller.sendRoomSubscription(.init(fence: conflictingFence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [member])), sourceShardID: "rooms", to: first.descriptor) == .stale)
            #expect(offered.withLock { $0.count } == 2)

            let batchDeliveries = (3...4).map { sequence -> V2RoomSubscriptionDelivery in
                let value = UInt64(sequence)
                let event = V2RealtimeRoomEvent(roomID: room, highWatermark: value, sourceEventID: EventID(uuid: UUID()),
                    roomSequence: value, projectionKind: "message", payload: Data("batch-\(sequence)".utf8), recipientUserIDs: [user])
                return .init(fence: nextFence, deliverySequence: value, authorizationSequence: 1, payload: .event(event, members: [member]))
            }
            let batch = V2RoomSubscriptionDeliveryBatch(deliveries: batchDeliveries)
            let batchResult = try await caller.sendRoomSubscriptionBatch(batch, sourceShardID: "rooms", to: first.descriptor)
            #expect(batchResult.receipts == [.init(fence: nextFence, result: .appliedThrough(4))])
            #expect(offered.withLock { $0.count } == 4)
            // A lost batch ACK retries every exact control; the cumulative
            // receipt must not repeat either body publication.
            let retriedBatch = try await caller.sendRoomSubscriptionBatch(batch, sourceShardID: "rooms", to: first.descriptor)
            #expect(retriedBatch == batchResult)
            #expect(offered.withLock { $0.count } == 4)

            let oldDescriptor = first.descriptor
            #expect(await first.stop(deadline: .now + .seconds(2)))
            peerHandle = nil
            try await peerSystem.shutdown().wait()
            peerSystem = await makeSystem(name: "room-subscription-peer", port: peerPort)
            let replacement = try makePeer(system: peerSystem, port: peerPort, keys: keys)
            peerHandle = replacement
            let newID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: replacement.descriptor.endpointReference)
            #expect(newID.node != targetID.node)
            #expect(replacement.descriptor.identity.incarnationID != oldDescriptor.identity.incarnationID)
            let replacementAuthority = V2GatewayRoomSubscriptionAuthority()
            let replacementIngress = V2GatewayRoomSubscriptionIngress(authority: replacementAuthority,
                offerEvent: { _, _ in }, offerHead: { _, _ in })
            #expect(await replacementIngress.install(fence: nextFence, sourceShardID: "rooms", serviceID: "publisher", deadline: .now + .seconds(60)))
            try await replacement.configureRoomSubscription(replacementIngress)
            // Resolution and handshake use the replacement's real node UID and
            // endpoint bytes; cached old-incarnation sessions cannot substitute.
            #expect(try await caller.sendRoomSubscription(nextBaseline, sourceShardID: "rooms", to: replacement.descriptor) == .appliedThrough(1))
            let retiredIdentity = V2GatewayRealtimeDescriptor(identity: oldDescriptor.identity,
                endpointReference: replacement.descriptor.endpointReference, address: "127.0.0.1", port: peerPort)
            await #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
                try await caller.sendRoomSubscription(nextBaseline, sourceShardID: "rooms", to: retiredIdentity)
            }
            #expect(try await caller.sendRoomSubscription(nextBaseline, sourceShardID: "rooms", to: replacement.descriptor) == .appliedThrough(1))
        } catch { failure = error }
        if let peerHandle { #expect(await peerHandle.stop(deadline: .now + .seconds(2))) }
        if let callerHandle { #expect(await callerHandle.stop(deadline: .now + .seconds(2))) }
        try await peerSystem.shutdown().wait()
        try await callerSystem.shutdown().wait()
        if let failure { throw failure }
    }

    @Test("retired history resets a real Owner and installs its baseline over signed TCP")
    func retiredHistoryRealOwnerReset() async throws {
        let callerPort = Int.random(in: 30_000...44_999), peerPort = Int.random(in: 45_000...60_000)
        let keys = try Keys(), user = UserID(uuid: UUID())
        let callerSystem = await makeSystem(name: "retired-owner", port: callerPort)
        let peerSystem = await makeSystem(name: "retired-gateway", port: peerPort)
        let caller = try buildRealtimeTransport(system: callerSystem,
            identity: .init(nodeID: "publisher", serviceID: "publisher", incarnationID: UUID()),
            address: "127.0.0.1", port: callerPort, signer: keys.publisher, trust: keys.trust,
            ingress: RejectingIngress(), serviceOwnerAccess: [keys.publisher.serviceID: ["rooms"]],
            limits: .init(callTimeout: .seconds(5)))
        let peer = try makePeer(system: peerSystem, port: peerPort, keys: keys)
        let authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 1, maximumRetiredRooms: 1)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, maximumRooms: 1,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let signals = AsyncStream<(RoomID, V2GatewayRealtimeIdentity)>.makeStream()
        let pump = V2RoomSubscriptionDeliveryPump(maximumEntries: 3, maximumCalls: 1,
            send: { delivery, shard, target in
                try await caller.sendRoomSubscription(delivery, sourceShardID: shard, to: target)
            }, requestBaseline: { _, _ in })
        let forwarding = Task {
            for await (room, gateway) in signals.stream { await pump.signal(.init(roomID: room, gateway: gateway)) }
        }
        var owners: [RoomID: V2RoomSubscriptionOwner] = [:]
        var coordinator: V2GatewayRoomSubscriptionCoordinator?
        var failure: (any Error)?
        do {
            try await peer.configureRoomSubscription(ingress)
            let endpointID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: peer.descriptor.endpointReference)
            let remote = try V2GatewayRealtimeEndpoint.resolve(id: endpointID, using: callerSystem)
            #expect(__isRemoteActor(remote))
            #expect(endpointID.node != callerSystem.cluster.node)
            callerSystem.cluster.join(host: "127.0.0.1", port: peerPort)
            #expect(authority.registerConnection(UUID(), userID: user, lifecycle: UUID()))
            let owner = try V2RoomDataOwner(shardID: "rooms", epoch: 0)
            let rooms = (0..<3).map { _ in RoomID(uuid: UUID()) }
            let tokens = try Dictionary(uniqueKeysWithValues: rooms.map { room in
                (room, V2RoomActivationToken(roomID: room, owner: owner, activationEpoch: try .init(1),
                    host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID())))
            })
            for room in rooms {
                owners[room] = try await V2RoomSubscriptionOwner.restore(
                    source: EmptySubscriptionSource(room: room, owner: owner), roomID: room,
                    owner: owner, activation: tokens[room]!, deadline: .now + .seconds(10), trackedUserIDs: [],
                    notifyChanged: { signals.continuation.yield((room, $0)) })
            }
            let services = owners, resets = Mutex(0), ordinary = Mutex<[RoomID: V2RoomSubscriptionFence]>([:])
            let ports = V2GatewayRoomSubscriptionPorts(gateway: peer.descriptor,
                resolve: { room, _ in .init(activation: tokens[room]!, authenticatedServiceID: "publisher") },
                subscribe: { command, token, deadline in
                    let grant = try await services[command.roomID]!.subscribe(gateway: peer.descriptor.identity,
                        userID: user, token: token, deadline: deadline)
                    ordinary.withLock { $0[command.roomID] = grant.fence }
                    return .granted(.init(fence: grant.fence, memberRevision: grant.memberRevision,
                        userBaselineSequence: grant.baselineSequence, remainingLeaseMilliseconds: grant.remainingLeaseMilliseconds))
                }, reset: { command, token, deadline in
                    resets.withLock { $0 += 1 }
                    let grant = try await services[command.roomID]!.resetGrant(gateway: peer.descriptor.identity,
                        userID: user, expectedFence: command.expectedFence, token: token, deadline: deadline)
                    return .granted(.init(fence: grant.fence, memberRevision: grant.memberRevision,
                        userBaselineSequence: grant.baselineSequence, remainingLeaseMilliseconds: grant.remainingLeaseMilliseconds))
                }, renewBatch: { _, _, _ in [] }, activate: { command, token, deadline in
                    let activated = try await services[command.roomID]!.activate(to: pump,
                        descriptor: peer.descriptor, userID: user, fence: command.fence, token: token, deadline: deadline)
                    return activated ? .activated : .failure(.stale)
                }, unsubscribe: { command, token, deadline in
                    try await services[command.roomID]!.unsubscribe(gateway: peer.descriptor.identity,
                        userID: user, memberRevision: command.memberRevision, token: token, deadline: deadline)
                    return .unsubscribed
                })
            coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress, maximumRelations: 1)
            await pump.start()
            for (index, room) in rooms.enumerated() {
                let reference = UUID()
                let grant = try await coordinator!.acquire(roomID: room, userID: user, reference: reference)
                let end = ContinuousClock.now + .seconds(5)
                while await authority.captureOnlinePermits(roomID: room).isEmpty && ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(await authority.captureOnlinePermits(roomID: room).count == 1)
                if index == 0 {
                    let association = try #require(callerSystem._cluster?.getSpecificExistingAssociation(with: endpointID.node))
                    let channel = try #require(association.lock.withLock { () -> (any Channel)? in
                        if case .associated(let channel) = association.state { return channel }; return nil
                    })
                    #expect(channel.isActive)
                    #expect(channel.remoteAddress?.port == peerPort)
                }
                if index == 2 {
                    #expect(resets.withLock { $0 } == 1)
                    let old = try #require(ordinary.withLock { $0[room] })
                    #expect(grant.fence.generation > old.generation)
                    #expect(try await caller.sendRoomSubscription(.init(fence: old, deliverySequence: 1,
                        authorizationSequence: 1, payload: .baseline(members: [.init(userID: user, memberRevision: 0)])),
                        sourceShardID: "rooms", to: peer.descriptor) == .stale)
                }
                await coordinator!.release(reference: reference)
            }
        } catch { failure = error }
        await coordinator?.shutdown()
        for service in owners.values { try? await service.close() }
        signals.continuation.finish(); await forwarding.value
        await pump.close()
        #expect(await peer.stop(deadline: .now + .seconds(2)))
        #expect(await caller.stop(deadline: .now + .seconds(2)))
        try await peerSystem.shutdown().wait(); try await callerSystem.shutdown().wait()
        if let failure { throw failure }
    }

    private func makeSystem(name: String, port: Int, binary: Bool = false) async -> ClusterSystem {
        var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        settings.serialization.binaryDistributedInvocations = binary
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        return await ClusterSystem(name, settings: settings)
    }
    private func makePeer(system: ClusterSystem, port: Int, keys: Keys) throws -> V2RealtimeTransportHandle {
        try buildRealtimeTransport(system: system,
            identity: .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID()),
            address: "127.0.0.1", port: port, signer: keys.gateway, trust: keys.trust,
            ingress: RejectingIngress(), serviceOwnerAccess: [keys.publisher.serviceID: ["rooms"]],
            limits: .init(callTimeout: .seconds(5)))
    }
    private struct Keys {
        let publisher: V2ActorSigningIdentity
        let gateway: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        init() throws {
            let p = Curve25519.Signing.PrivateKey(), g = Curve25519.Signing.PrivateKey()
            publisher = try .init(serviceID: .init("publisher"), privateKey: p.rawRepresentation)
            gateway = try .init(serviceID: .init("gateway"), privateKey: g.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: publisher.serviceID, publicKey: p.publicKey.rawRepresentation,
                      permissions: [.realtimePublish, .realtimeReceive]),
                .init(serviceID: gateway.serviceID, publicKey: g.publicKey.rawRepresentation, permissions: [.realtimeReceive])
            ])
        }
    }
    private struct RejectingIngress: V2RealtimeIngress {
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance { .stale }
    }
}

private struct EmptySubscriptionSource: V2RoomSubscriptionSource {
    let room: RoomID
    let owner: V2RoomDataOwner
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        .init(roomID: room, owner: self.owner, highWatermark: 0, membershipRevision: 0,
            roomControlVersion: 0, remainingLeaseMilliseconds: 60_000,
            members: trackedUserIDs.map { .init(userID: $0, memberRevision: 0, authorized: true) })
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
        trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        .init(roomID: room, owner: self.owner, afterRoomSequence: afterRoomSequence, highWatermark: 0, records: [])
    }
}
