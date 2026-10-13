import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerGateway
@testable import IMV2ServerApplication

struct V2RoomDeliverySessionTests {
    private func fixture() throws -> (V2RoomActivationToken, V2GatewayRealtimeDescriptor, UserID) {
        let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: try .init(shardID: "rooms", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: try .init("host"), incarnationID: UUID()))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID()),
            endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        return (token, gateway, .init(uuid: UUID()))
    }
    @Test("new heartbeat cannot revive expired generation or automatically authorize its old rooms")
    func expiredGenerationRequiresNewRoomBaseline() async throws {
        let (token, gateway, user) = try fixture(), clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let session = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 1)
        #expect(authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner") == .accepted)
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await authority.install(fence: fence, serviceID: "owner", session: session))
        #expect(await authority.apply(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: user, memberRevision: 0)])), authenticatedServiceID: "owner") == .applied(permits: []))
        clock.withLock { $0 += .seconds(11) }
        #expect(authority.applyDeliverySession(.init(session: session, kind: .heartbeat, sequence: 2), serviceID: "owner") == .resetRequired)
        #expect(authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 3), serviceID: "owner") == .resetRequired)
        let successor = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 2)
        #expect(authority.applyDeliverySession(.init(session: successor, kind: .open, sequence: 1), serviceID: "owner") == .accepted)
        #expect(await authority.requiresBaseline(fence: fence))
        #expect(!(await authority.install(fence: fence, serviceID: "owner", session: successor)))
        let fresh = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 2, baselineSequence: 0)
        #expect(await authority.install(fence: fresh, serviceID: "owner", session: successor, afterAuthoritativeReset: true))
        #expect(authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 4), serviceID: "owner") == .stale)
        #expect(authority.sessionGate(successor, serviceID: "owner")?.isReady(at: clock.withLock { $0 }) == true)
        await authority.shutdown()
    }
    @Test("retiring the shared session rejects permits already handed to an EventLoop")
    func sessionRetirementRejectsDelayedSocketWrite() async throws {
        let (token, gateway, user) = try fixture()
        let authority = V2GatewayRoomSubscriptionAuthority()
        let session = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 1)
        _ = authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await authority.install(fence: fence, serviceID: "owner", session: session))
        let connection = UUID(), lifecycle = UUID()
        try #require(await authority.registerFixtureConnection(connection, userID: user, lifecycle: lifecycle))
        _ = await authority.apply(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: user, memberRevision: 0)])), authenticatedServiceID: "owner")
        let permit = try #require(await authority.captureOnlinePermits(roomID: token.roomID).first)
        #expect(await authority.enqueueFixtureIfCurrent(permit) {})
        #expect(authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 2), serviceID: "owner") == .accepted)
        #expect(!(await authority.enqueueFixtureIfCurrent(permit) {}))
        await authority.shutdown()
    }
    @Test("many rooms share one session opening and one heartbeat per peer")
    func roomCountDoesNotMultiplyHeartbeats() async throws {
        let (token, gateway, _) = try fixture(), pulses = Mutex<[V2RoomDeliverySessionPulse]>([])
        let host = V2RoomDeliverySessionHost()
        await host.configure(send: { pulse, _, _ in pulses.withLock { $0.append(pulse) }; return .accepted }, hostReady: { true })
        let tokens = (0..<100).map { _ in V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: token.owner,
            activationEpoch: token.activationEpoch, host: token.host) }
        let sessions = try await withThrowingTaskGroup(of: V2RoomDeliverySession.self) { group in
            for token in tokens { group.addTask { try await host.retain(activation: token, gateway: gateway) } }
            var values: [V2RoomDeliverySession] = []; for try await value in group { values.append(value) }; return values
        }
        #expect(Set(sessions).count == 1)
        #expect(pulses.withLock { $0.filter { $0.kind == .open }.count } == 1)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0.filter { $0.kind == .heartbeat }.count } == 1)
        for token in tokens { await host.release(activation: token, gateway: gateway.identity) }
        #expect(pulses.withLock { $0.filter { $0.kind == .retire }.count } == 1)
        await host.close()
        let count = pulses.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pulses.withLock { $0.count } == count)
    }
    @Test("control transport failure retires the session and rebuilds a successor generation")
    func failedControlCannotBeMaskedByHeartbeats() async throws {
        let (token, gateway, _) = try fixture(), pulses = Mutex<[V2RoomDeliverySessionPulse]>([])
        let host = V2RoomDeliverySessionHost()
        await host.configure(send: { pulse, _, _ in pulses.withLock { $0.append(pulse) }; return .accepted }, hostReady: { true })
        let old = try await host.retain(activation: token, gateway: gateway)
        await host.controlFailed(host: token.host, gateway: gateway.identity)
        let fresh = try await host.retain(activation: token, gateway: gateway)
        #expect(fresh.generation > old.generation)
        #expect(pulses.withLock { $0.contains { $0.kind == .retire && $0.session == old } })
        #expect(!pulses.withLock { $0.contains { $0.kind == .heartbeat && $0.session == old } })
        await host.close()
    }

    @Test("queued authorization blocks healthy pulses before any delivery RPC; application ACK restores progress")
    func queuedControlIsPartOfSessionHealth() async throws {
        let (token, gateway, user) = try fixture()
        let clock = Mutex(ContinuousClock.now), pulses = Mutex<[V2RoomDeliverySessionPulse]>([])
        let host = V2RoomDeliverySessionHost(now: { clock.withLock { $0 } })
        await host.configure(send: { pulse, _, _ in pulses.withLock { $0.append(pulse) }; return .accepted }, hostReady: { true })
        _ = try await host.retain(activation: token, gateway: gateway)
        let relay = try V2RoomSubscriptionRelay(activation: token, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)],
            observeAuthorization: { host.observeAuthorization($0, gateway: $1) })
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1, operation: .subscribe(gateway: gateway.identity,
            userID: user, memberRevision: 0, subscriptionID: UUID(), generation: 1)))
        // No pump is running: the control has only entered its bounded outbox.
        clock.withLock { $0 += .seconds(3) }
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0.filter { $0.kind == .heartbeat }.isEmpty })
        let control = try #require(await relay.pending(for: gateway.identity, lane: .authorization).first)
        try await relay.acknowledge(gateway: gateway.identity, fence: control.fence,
            through: control.deliverySequence, lane: .authorization)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0.filter { $0.kind == .heartbeat }.count } == 1)
        await host.close()
    }

    @Test("a permanently queued control retires the peer generation and cannot be hidden by duplicate progress")
    func queuedControlEventuallyRetiresSession() async throws {
        let (token, gateway, user) = try fixture()
        let clock = Mutex(ContinuousClock.now), pulses = Mutex<[V2RoomDeliverySessionPulse]>([])
        let host = V2RoomDeliverySessionHost(now: { clock.withLock { $0 } })
        await host.configure(send: { pulse, _, _ in pulses.withLock { $0.append(pulse) }; return .accepted }, hostReady: { true })
        let old = try await host.retain(activation: token, gateway: gateway)
        let relay = try V2RoomSubscriptionRelay(activation: token, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)],
            observeAuthorization: { host.observeAuthorization($0, gateway: $1) })
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1, operation: .subscribe(gateway: gateway.identity,
            userID: user, memberRevision: 0, subscriptionID: UUID(), generation: 1)))
        let control = try #require(await relay.pending(for: gateway.identity, lane: .authorization).first)
        clock.withLock { $0 += .seconds(9) }
        host.observeAuthorization(.init(fence: control.fence, issued: 1, applied: 0, invalidated: false), gateway: gateway.identity)
        clock.withLock { $0 += .seconds(2) }
        try await Task.sleep(for: .milliseconds(2200))
        #expect(pulses.withLock { $0.contains { $0.kind == .retire && $0.session == old } })
        let fresh = try await host.retain(activation: token, gateway: gateway)
        #expect(fresh.generation > old.generation)
        #expect(!pulses.withLock { $0.contains { $0.kind == .heartbeat && $0.session == old } })
        await host.close()
    }

    @Test("the last subscriber keeps its session until revoke ACK, then releases it without another SQL read")
    func lastSubscriberReleasesSessionAfterACK() async throws {
        let (token, gateway, user) = try fixture()
        let pulses = Mutex<[V2RoomDeliverySessionPulse]>([]), empty = Mutex(false), gate = RoomSessionRetirementGate()
        let sessions = V2RoomDeliverySessionHost()
        await sessions.configure(send: { pulse, _, _ in pulses.withLock { $0.append(pulse) }; return .accepted }, hostReady: { true })
        let session = try await sessions.retain(activation: token, gateway: gateway)
        let source = CommittedPermissionSource(token: token, user: user)
        let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: token.roomID, owner: token.owner,
            activation: token, deadline: .now + .seconds(5), trackedUserIDs: [],
            observeAuthorization: { progress, identity in
                sessions.observeAuthorization(progress, gateway: identity)
                if progress.isUnreferenced { empty.withLock { $0 = true } }
            }, notifyRetired: { identity in await sessions.release(activation: token, gateway: identity) })
        let grant = try await owner.subscribe(gateway: gateway.identity, userID: user, token: token, deadline: .now + .seconds(5))
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            if case .revoke = delivery.payload { await gate.hold() }
            return .appliedThrough(delivery.deliverySequence)
        }, requestBaseline: { _, _ in })
        await pump.start()
        try #require(try await owner.activate(to: pump, descriptor: gateway, userID: user, fence: grant.fence,
            token: token, deadline: .now + .seconds(5)))
        try await owner.unsubscribe(gateway: gateway.identity, userID: user, memberRevision: grant.memberRevision,
            token: token, deadline: .now + .seconds(5))
        await owner.signalDelivery()
        await gate.waitUntilEntered()
        #expect(await owner.hasGateway(gateway.identity))
        #expect(!pulses.withLock { $0.contains { $0.kind == .retire && $0.session == session } })
        let snapshots = await source.snapshotCount
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while !empty.withLock({ $0 }) {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(1))
        }
        await owner.signalDelivery()
        #expect(!(await owner.hasGateway(gateway.identity)))
        #expect(pulses.withLock { $0.contains { $0.kind == .retire && $0.session == session } })
        #expect(await source.snapshotCount == snapshots)
        try await owner.close(); await pump.close(); await sessions.close()
    }
}

private actor RoomSessionRetirementGate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        if !released { await withCheckedContinuation { blocked = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}

extension V2RoomDeliverySessionTests {
    @Test("confirmed native restarts release obsolete session catalogs without reviving old projections")
    func nativeRestartReleasesSessionCatalogs() async throws {
        let (original, gateway, _) = try fixture()
        let authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 2)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let first = V2RoomDeliverySession(host: original.host, gateway: gateway.identity, generation: 1)
        try #require(authority.applyDeliverySession(.init(session: first, kind: .open, sequence: 1), serviceID: "owner") == .accepted)
        let oldGate = try #require(authority.sessionGate(first, serviceID: "owner"))
        var previous = first
        // Greater than the registry's peer limit: each confirmed restart must
        // release its predecessor instead of exhausting all future openings.
        for index in 1...130 {
            let host = V2ActorHostIdentity(hostID: original.host.hostID, incarnationID: UUID())
            let token = V2RoomActivationToken(roomID: original.roomID, owner: original.owner,
                activationEpoch: try .init(Int64(index + 1)), host: host)
            let session = V2RoomDeliverySession(host: host, gateway: gateway.identity, generation: 1)
            try #require(authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner") == .accepted)
            let fence = V2RoomSubscriptionFence(activation: token,
                subscriptionID: UUID(), generation: 1, baselineSequence: 0)
            try #require(await ingress.install(fence: fence, sourceShardID: token.owner.shardID,
                serviceID: "owner", session: session))
            #expect(authority.sessionGate(previous, serviceID: "owner") == nil)
            previous = session
        }
        #expect(!oldGate.isReady(at: .now))
        // A delayed authenticated pulse can create no ready room grant. It
        // cannot revive the retired gate referenced by old socket permits.
        _ = authority.applyDeliverySession(.init(session: first, kind: .open, sequence: 2), serviceID: "owner")
        #expect(!oldGate.isReady(at: .now))
        await authority.shutdown()
    }

    @Test("authorization gaps actively request a room baseline even before initial activation", arguments: [false, true])
    func gapSchedulesRoomRecovery(hasBaseline: Bool) async throws {
        let (token, gateway, user) = try fixture()
        let authority = V2GatewayRoomSubscriptionAuthority()
        let session = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 1)
        _ = authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await authority.install(fence: fence, serviceID: "owner", session: session))
        let requests = Mutex<[RoomID]>([])
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        ingress.configureBaselineRequired { room in requests.withLock { $0.append(room) } }
        if hasBaseline {
            _ = await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [.init(userID: user, memberRevision: 0)])),
                authenticatedServiceID: "owner", sourceShardID: token.owner.shardID)
        }
        let result = await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 3, authorizationSequence: 3,
            payload: .revoke(userID: user, memberRevision: 1)), authenticatedServiceID: "owner", sourceShardID: token.owner.shardID)
        #expect(result == .snapshotRequired)
        #expect(requests.withLock { $0 } == [token.roomID])
        #expect(await authority.requiresBaseline(fence: fence))
        #expect(await authority.authorizedMemberRevision(roomID: token.roomID, userID: user) == nil)
        #expect(authority.sessionGate(session, serviceID: "owner")?.isReady(at: .now) == true)
        await authority.shutdown()
    }

    @Test("conflicting authenticated replay closes permission before requesting recovery")
    func conflictingReplayInvalidatesCapturedPermit() async throws {
        let (token, gateway, user) = try fixture()
        let authority = V2GatewayRoomSubscriptionAuthority()
        let session = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 1)
        _ = authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        try #require(await authority.install(fence: fence, serviceID: "owner", session: session))
        try #require(await authority.registerFixtureConnection(UUID(), userID: user, lifecycle: UUID()))
        _ = await authority.apply(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: user, memberRevision: 0)])), authenticatedServiceID: "owner")
        let permit = try #require(await authority.captureOnlinePermits(roomID: token.roomID).first)
        let requests = Mutex(0)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        ingress.configureBaselineRequired { _ in requests.withLock { $0 += 1 } }
        #expect(await ingress.applyRoomSubscription(.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [])), authenticatedServiceID: "owner", sourceShardID: token.owner.shardID) == .snapshotRequired)
        #expect(requests.withLock { $0 } == 1)
        #expect(!(await authority.enqueueFixtureIfCurrent(permit) {}))
        await authority.shutdown()
    }

    @Test("heartbeat fanout respects the transport's reserved capacity")
    func heartbeatFanoutIsBounded() async throws {
        let (token, gateway, _) = try fixture()
        struct Calls { var active = 0; var peak = 0; var peers: Set<V2GatewayRealtimeIdentity> = [] }
        let calls = Mutex(Calls()), host = V2RoomDeliverySessionHost()
        await host.configure(send: { pulse, _, _ in
            guard pulse.kind == .heartbeat else { return .accepted }
            calls.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { calls.withLock { $0.active -= 1; $0.peers.insert(pulse.session.gateway) } }
            try await Task.sleep(for: .milliseconds(200))
            return .accepted
        }, hostReady: { true })
        for index in 0..<13 {
            let peer = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway-\(index)", serviceID: gateway.identity.serviceID,
                incarnationID: UUID()), endpointReference: gateway.endpointReference, address: gateway.address, port: gateway.port)
            _ = try await host.retain(activation: token, gateway: peer)
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while calls.withLock({ $0.peers.count }) < 13 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.withLock { $0.peak } == 8)
        await host.close()
        #expect(calls.withLock { $0.active } == 0)
    }

    @Test("committed permission cut reaches Gateway before the next dependent operation")
    func committedPermissionCutRetiresOldAuthorization() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let token = V2RoomActivationToken(roomID: room, owner: try .init(shardID: "rooms", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: try .init("host"), incarnationID: UUID()))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID()),
            endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let source = CommittedPermissionSource(token: token, user: user)
        let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
            activation: token, deadline: .now + .seconds(5), trackedUserIDs: [])
        let grant = try await owner.subscribe(gateway: gateway.identity, userID: user, token: token, deadline: .now + .seconds(5))
        let authority = V2GatewayRoomSubscriptionAuthority()
        let session = V2RoomDeliverySession(host: token.host, gateway: gateway.identity, generation: 1)
        _ = authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
        try #require(await authority.install(fence: grant.fence, serviceID: "owner", session: session))
        let controls = Mutex<[V2RoomSubscriptionPayload]>([])
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            let result = await authority.apply(delivery, authenticatedServiceID: "owner")
            guard case .applied = result else { return .stale }
            controls.withLock { $0.append(delivery.payload) }
            return .appliedThrough(delivery.deliverySequence)
        }, requestBaseline: { _, _ in })
        await pump.start()
        try #require(try await owner.activate(to: pump, descriptor: gateway, userID: user, fence: grant.fence,
            token: token, deadline: .now + .seconds(5)))
        let timeout = ContinuousClock.now + .seconds(3)
        while controls.withLock({ $0.isEmpty }) {
            try #require(ContinuousClock.now < timeout); try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await authority.authorizedMemberRevision(roomID: room, userID: user) == 0)
        await source.revoke()
        try await owner.withPermissionMutation(token: token, deadline: .now + .seconds(5)) { _, _ in
            .init(result: (), effect: .init(activation: token, snapshot: .init(roomID: room, owner: token.owner,
                highWatermark: 0, membershipRevision: 1, roomControlVersion: 1,
                members: [.init(userID: user, memberRevision: 1, authorized: false)])))
        }
        await owner.signalDelivery()
        while !controls.withLock({ $0.contains(.authorizationInvalidated) }) {
            try #require(ContinuousClock.now < timeout); try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await authority.authorizedMemberRevision(roomID: room, userID: user) == nil)
        while try await !owner.processControlCut(expectedVersion: 1, token: token, deadline: .now + .seconds(5)) {
            try #require(ContinuousClock.now < timeout); try await Task.sleep(for: .milliseconds(1))
        }
        await #expect(throws: V2RoomSubscriptionOwnerError.unauthorized) {
            try await owner.subscribe(gateway: gateway.identity, userID: user, token: token, deadline: .now + .seconds(5))
        }
        #expect(await source.snapshotCount == 4) // initialize, subscribe, activate, rejected subscribe; no postcommit read
        try await owner.close(); await pump.close(); await authority.shutdown()
    }
    @Test("send-only policy cuts preserve receive grants and do not skip unconsumed room events")
    func sendOnlyCutPreservesReceivers() async throws {
        let (token, gateway, user) = try fixture()
        let relay = try V2RoomSubscriptionRelay(activation: token, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        try await relay.offer(.init(ownerEpoch: token.owner.epoch, inputSequence: 1,
            operation: .subscribe(gateway: gateway.identity, userID: user, memberRevision: 0,
                subscriptionID: UUID(), generation: 1)))
        let before = await relay.pending(for: gateway.identity, lane: .authorization)
        let cut = V2RoomSubscriptionSourceSnapshot(roomID: token.roomID, owner: token.owner,
            highWatermark: 1, membershipRevision: 0, roomControlVersion: 1,
            members: [.init(userID: user, memberRevision: 0, authorized: true)])
        #expect(try await !relay.reconcileControlCut(cut))
        #expect(await relay.committedSequence() == 0)
        #expect(await relay.pending(for: gateway.identity, lane: .authorization) == before)
        #expect(await !relay.controlInvalidationPending())
    }

    @Test("a suspended permission transaction reserves the Owner cut before any SQL or reentrant read")
    func permissionTransactionBlocksReentrantReads() async throws {
        let (token, gateway, user) = try fixture()
        let source = CommittedPermissionSource(token: token, user: user)
        let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: token.roomID,
            owner: token.owner, activation: token, deadline: .now + .seconds(5), trackedUserIDs: [])
        let gate = RoomSessionRetirementGate()
        let mutation = Task {
            try await owner.withPermissionMutation(token: token, deadline: .now + .seconds(5)) { _, _ in
                await gate.hold()
                return .init(result: (), effect: nil)
            }
        }
        await gate.waitUntilEntered()
        await #expect(throws: V2RoomSubscriptionOwnerError.busy) {
            try await owner.subscribe(gateway: gateway.identity, userID: user,
                token: token, deadline: .now + .seconds(5))
        }
        await #expect(throws: V2RoomSubscriptionOwnerError.busy) {
            try await owner.drain(token: token, deadline: .now + .seconds(5))
        }
        #expect(await source.snapshotCount == 1)
        await gate.release(); try await mutation.value
        try await owner.close()
    }

    @Test("control overflow retains its prefix and terminal denial until exact application ACK")
    func controlOverflowHasRetainedTerminal() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let token = V2RoomActivationToken(roomID: room, owner: try .init(shardID: "rooms", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: try .init("host"), incarnationID: UUID()))
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
        let relay = try V2RoomSubscriptionRelay(activation: token, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)], maximumPendingDeliveries: 1)
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1, operation: .subscribe(gateway: gateway,
            userID: user, memberRevision: 0, subscriptionID: UUID(), generation: 1)))
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2, operation: .unsubscribe(gateway: gateway, userID: user, memberRevision: 0)))
        let pending = await relay.pending(for: gateway, lane: .authorization)
        try #require(pending.count == 2)
        #expect(pending[0].authorizationSequence == 1 && pending[1].authorizationSequence == 2)
        #expect(pending[1].payload == .authorizationInvalidated)
        #expect(await relay.controlInvalidationPending(gateway: gateway))
        try await relay.acknowledge(gateway: gateway, fence: pending[0].fence, through: pending[0].deliverySequence, lane: .authorization)
        #expect(await relay.controlInvalidationPending(gateway: gateway))
        try await relay.acknowledge(gateway: gateway, fence: pending[1].fence, through: pending[1].deliverySequence, lane: .authorization)
        #expect(await relay.status(for: gateway)?.needsBaseline == true)
    }
}
private actor CommittedPermissionSource: V2RoomSubscriptionSource {
    let token: V2RoomActivationToken
    let user: UserID
    var allowed = true
    private(set) var snapshotCount = 0
    init(token: V2RoomActivationToken, user: UserID) { self.token = token; self.user = user }
    func revoke() { allowed = false }
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        snapshotCount += 1
        return .init(roomID: roomID, owner: owner, highWatermark: 0, membershipRevision: allowed ? 0 : 1,
            roomControlVersion: allowed ? 0 : 1, members: trackedUserIDs.map { .init(userID: $0, memberRevision: allowed ? 0 : 1, authorized: allowed) })
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
              trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        .init(roomID: roomID, owner: owner, afterRoomSequence: afterRoomSequence, highWatermark: 0, records: [])
    }
}
