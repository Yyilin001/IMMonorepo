import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerApplication

struct V2RoomSubscriptionOwnerTests {
    @Test("fresh authorization joins the predecessor delivery before replacing its pump binding", arguments: [false, true])
    func resetActivationJoinsPreviousDelivery(rejectOldReceipt: Bool) async throws {
        let room = RoomID(uuid: UUID()), alice = UserID(uuid: UUID()), bob = UserID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let token = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: token, deadline: .now + .seconds(5), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let descriptor = V2GatewayRealtimeDescriptor(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 8443)
        let held = HeldActivationDelivery(rejectFirst: rejectOldReceipt)
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in await held.send(delivery) })
        let settled = Mutex(false)
        var replacement: Task<Bool, any Error>?
        await pump.start()
        do {
            let first = try await service.subscribe(gateway: gateway, userID: alice, token: token, deadline: .now + .seconds(5))
            #expect(try await service.activate(to: pump, descriptor: descriptor, userID: alice, fence: first.fence,
                token: token, deadline: .now + .seconds(5)))
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await held.started), ContinuousClock.now < deadline { await Task.yield() }
            try #require(await held.started)
            let next = try await service.resetGrant(gateway: gateway, userID: alice, expectedFence: first.fence,
                token: token, deadline: deadline)
            #expect(next.fence != first.fence)
            let task = Task {
                defer { settled.withLock { $0 = true } }
                return try await service.activate(to: pump, descriptor: descriptor, userID: alice, fence: next.fence,
                    token: token, deadline: deadline)
            }
            replacement = task
            // The predecessor RPC is explicitly held; no replacement may
            // complete until that actual call settles.
            try await Task.sleep(for: .milliseconds(50))
            #expect(!settled.withLock { $0 })
            #expect(await pump.snapshot().actualCalls == 1)
            await held.release()
            #expect(try await task.value)
            while !(await held.fences.contains(next.fence)), ContinuousClock.now < deadline { await Task.yield() }
            #expect(await held.fences.contains(next.fence))
            try await service.close(); await pump.close()
        } catch {
            await held.release()
            _ = await replacement?.result
            try? await service.close(); await pump.close()
            throw error
        }
    }

    @Test("repeated activation retains its in-flight delivery binding and still checks the authorization cut")
    func repeatedActivationWhileDeliveryIsInFlight() async throws {
        let room = RoomID(uuid: UUID()), alice = UserID(uuid: UUID()), bob = UserID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: activation, deadline: .now + .seconds(3), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let descriptor = V2GatewayRealtimeDescriptor(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443)
        let grant = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(3))
        let held = HeldActivationDelivery()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            await held.send(delivery)
        })
        await pump.start()
        do {
            #expect(try await service.activate(to: pump, descriptor: descriptor, userID: alice,
                fence: grant.fence, token: activation, deadline: .now + .seconds(3)))
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await held.started), ContinuousClock.now < deadline { await Task.yield() }
            try #require(await held.started)
            let before = await source.snapshotCount
            #expect(try await service.activate(to: pump, descriptor: descriptor, userID: alice,
                fence: grant.fence, token: activation, deadline: .now + .seconds(3)))
            #expect(await source.snapshotCount == before + 1)
            #expect(await pump.snapshot().actualCalls == 1)
            await source.setControlVersion(1)
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await service.activate(to: pump, descriptor: descriptor, userID: alice,
                    fence: grant.fence, token: activation, deadline: .now + .seconds(3))
            }
            await held.release()
            try await service.close(); await pump.close()
        } catch {
            await held.release()
            try? await service.close(); await pump.close()
            throw error
        }
    }
    private actor HeldActivationDelivery {
        var started = false
        var fences: [V2RoomSubscriptionFence] = []
        private var rejectFirst: Bool
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        init(rejectFirst: Bool = false) { self.rejectFirst = rejectFirst }
        func send(_ delivery: V2RoomSubscriptionDelivery) async -> V2RoomSubscriptionDeliveryResult {
            let reject = rejectFirst; rejectFirst = false
            fences.append(delivery.fence)
            started = true
            if !released { await withCheckedContinuation { waiter = $0 } }
            return reject ? .stale : .appliedThrough(delivery.deliverySequence)
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test("replacement Owner advertises committed head even when the old Owner never consumed its commit notification")
    func lostCommitNotificationRestoresFromDurableHead() async throws {
        let room = RoomID(uuid: UUID()), alice = UserID(uuid: UUID()), bob = UserID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let original = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let old = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: original, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        // Persistence advances, but no consumeCommittedMessages/drain reaches
        // the old Owner before its activation ends.
        await source.setHead(5)
        try await old.close()
        let replacement = V2RoomActivationToken(roomID: room, owner: owner, activationEpoch: try .init(2), host: original.host)
        let restored = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: replacement, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let grant = try await restored.subscribe(gateway: gateway, userID: alice, token: replacement, deadline: .now + .seconds(30))
        #expect(grant.baselineSequence == 5 && grant.fence.activation == replacement)
        try await restored.close()
    }
    @Test("subscribe rebuilds a retired authorization only after its terminal receipt")
    func subscribeAfterTerminalReceipt() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: activation, deadline: .now + .seconds(3), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let first = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(3))
        let allowTerminal = Mutex(false)
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            if case .authorizationInvalidated = delivery.payload, !allowTerminal.withLock({ $0 }) {
                throw V2RoomSubscriptionOwnerError.busy
            }
            return .appliedThrough(delivery.deliverySequence)
        })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443), userID: alice, fence: first.fence,
            token: activation, deadline: .now + .seconds(3)))
        await source.setControlVersion(1)
        try await service.withPermissionMutation(token: activation, deadline: .now + .seconds(3)) { users, version in
            #expect(version == 0)
            let snapshot = try await source.snapshot(roomID: room, owner: owner, trackedUserIDs: users)
            return .init(result: (), effect: .init(activation: activation, snapshot: snapshot))
        }
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(3))
        }
        allowTerminal.withLock { $0 = true }
        await service.signalDelivery()
        let deadline = ContinuousClock.now + .seconds(3)
        var replacement: V2RoomSubscriptionOwner.Grant?
        while replacement == nil, ContinuousClock.now < deadline {
            do {
                replacement = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: deadline)
            } catch V2RoomSubscriptionOwnerError.catchUpRequired {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let restored = try #require(replacement)
        #expect(restored.fence.generation == first.fence.generation + 1)
        #expect(restored.fence.subscriptionID != first.fence.subscriptionID)
        #expect(restored.memberRevision == first.memberRevision)
        try await service.close(); await pump.close()
    }




    @Test func newUserJoinsAtExactSnapshotCutWithoutResettingExistingFence() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let signals = Mutex(Set<V2GatewayRealtimeIdentity>())
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
            owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice], notifyChanged: { gateway in
                signals.withLock { _ = $0.insert(gateway) }
            })
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let first = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        #expect(first.memberRevision == 0 && first.baselineSequence == 0)
        // The new user's snapshot sees S=1. A commit arrives before the old
        // tracked stream is read, so read returns through 2; attachment must
        // truncate to 1 before expanding the tracked set.
        await source.jumpSnapshot(cut: 1, subsequentHead: 2)
        let joined = try await service.subscribe(gateway: gateway, userID: bob, token: activation, deadline: .now + .seconds(30))
        #expect(joined.fence == first.fence)
        #expect(joined.memberRevision == 1 && joined.baselineSequence == 1)
        let firstRead = try #require(await source.reads.first)
        #expect(firstRead.after == 0 && firstRead.users == [alice])
        let drained = try await service.drain(token: activation, deadline: .now + .seconds(30))
        #expect(drained.consumedThrough == 2 && !drained.hasMore)
        let lastRead = try #require(await source.reads.last)
        #expect(lastRead.after == 1 && lastRead.users == [alice, bob])
        try await service.unsubscribe(gateway: gateway, userID: bob, memberRevision: 1, token: activation, deadline: .now + .seconds(30))
        let rejoined = try await service.subscribe(gateway: gateway, userID: bob, token: activation, deadline: .now + .seconds(30))
        #expect(rejoined.fence == first.fence && rejoined.memberRevision == 1)
        let replacement = try await service.reset(gateway: gateway, token: activation, deadline: .now + .seconds(30))
        #expect(replacement.generation == 2 && replacement.baselineSequence == 2)
        #expect(replacement.subscriptionID != first.fence.subscriptionID)
        #expect(signals.withLock { $0 } == [gateway])
    }

    @Test func suspendedReadRejectsConcurrentMutationAndGapClosesOwner() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
            owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        _ = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        await source.pauseRead()
        let draining = Task { try await service.drain(token: activation, deadline: .now + .seconds(30)) }
        await source.waitUntilReadStarts()
        await #expect(throws: V2RoomSubscriptionOwnerError.busy) {
            try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        }
        await source.releaseRead()
        _ = try await draining.value
        await source.failReads()
        await #expect(throws: V2RoomSubscriptionSourceError.snapshotRequired) { try await service.drain(token: activation, deadline: .now + .seconds(30)) }
        await #expect(throws: V2RoomSubscriptionOwnerError.closed) {
            try await service.reset(gateway: gateway, token: activation, deadline: .now + .seconds(30))
        }
    }

    @Test func catchupIsBoundedAndRetryKeepsCommitProgress() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
            owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice], pageSize: 1, maximumDrainPages: 1)
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        await source.setHead(3)
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        }
        #expect(try await service.drain(token: activation, deadline: .now + .seconds(30)).consumedThrough == 2)
        let grant = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        #expect(grant.baselineSequence == 3)
    }

    @Test func acknowledgedRetirementSupportsChurnBeyondUserAndGatewayBounds() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let signals = AsyncStream<V2GatewayRealtimeIdentity>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pump = V2RoomSubscriptionDeliveryPump(maximumEntries: 1, maximumCalls: 1,
            send: { delivery, _, _ in .appliedThrough(delivery.deliverySequence) })
        let forwarding = Task {
            for await gateway in signals.stream { await pump.signal(.init(roomID: room, gateway: gateway)) }
        }
        defer { signals.continuation.finish(); forwarding.cancel() }
        await pump.start()
        do {
            let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
                owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [], maximumTrackedUsers: 1, maximumGateways: 1,
                notifyChanged: { signals.continuation.yield($0) })
            var previousGeneration: UInt64 = 0
            for index in 0..<12 {
                let user = try UserID("user-\(index)")
                let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
                var grant: V2RoomSubscriptionOwner.Grant?
                // A final revoke's actual ACK is the retirement boundary.
                // Temporary overload retains responsibility rather than
                // silently deleting a still-authorized remote stream.
                for _ in 0..<10_000 {
                    do { grant = try await service.subscribe(gateway: gateway, userID: user, token: activation, deadline: .now + .seconds(30)); break }
                    catch V2RoomSubscriptionOwnerError.overloaded { await Task.yield() }
                }
                let accepted = try #require(grant)
                #expect(accepted.fence.generation > previousGeneration)
                previousGeneration = accepted.fence.generation
                #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway,
                    endpointReference: Data([1]), address: "127.0.0.1", port: 8443), userID: user, fence: accepted.fence, token: activation, deadline: .now + .seconds(30)))
                try await service.unsubscribe(gateway: gateway, userID: user, memberRevision: accepted.memberRevision, token: activation, deadline: .now + .seconds(30))
            }
            try await service.close()
            await pump.close()
        } catch { await pump.close(); throw error }
    }

    @Test func closeStopsAdmissionAndJoinsSuspendedDatabaseOwner() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
            owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        await source.pauseRead()
        let draining = Task { try await service.drain(token: activation, deadline: .now + .seconds(30)) }
        await source.waitUntilReadStarts()
        let completed = Mutex(false)
        let closing = Task { try await service.close(); completed.withLock { $0 = true } }
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        var admissionClosed = false
        for _ in 0..<10_000 {
            do { _ = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30)) }
            catch V2RoomSubscriptionOwnerError.closed { admissionClosed = true; break }
            catch V2RoomSubscriptionOwnerError.busy { await Task.yield() }
        }
        #expect(admissionClosed)
        #expect(!completed.withLock { $0 })
        await source.releaseRead()
        await #expect(throws: V2RoomSubscriptionOwnerError.closed) { try await draining.value }
        try await closing.value
        #expect(completed.withLock { $0 })
    }
    @Test func bodyPressurePreservesFenceAndEverySharedUser() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let first = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        await source.setHead(1)
        let joined = try await service.subscribe(gateway: gateway, userID: bob, token: activation, deadline: .now + .seconds(30))
        #expect(joined.fence == first.fence)
        let normal = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        #expect(normal.fence == first.fence)
        // Body pressure must preserve the independently installed authority cut.
        await source.setHead(300)
        #expect(try await service.drain(token: activation, deadline: .now + .seconds(30)).consumedThrough == 300)
        let recovered = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        #expect(recovered.fence == first.fence && recovered.baselineSequence == 300)
        let unchanged = try await service.subscribe(gateway: gateway, userID: bob, token: activation, deadline: .now + .seconds(30))
        #expect(unchanged.fence == recovered.fence)
        let controls = Mutex<[V2RoomSubscriptionDelivery]>([])
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            if delivery.payload.isAuthorizationControl { controls.withLock { $0.append(delivery) } }
            return .appliedThrough(delivery.deliverySequence)
        })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443), userID: alice, fence: recovered.fence, token: activation, deadline: .now + .seconds(30)))
        // Message and authorization lanes run independently. Inspect the
        // authorization cut without assuming a cross-lane arrival order.
        let deadline = ContinuousClock.now + .seconds(3)
        while !controls.withLock({ $0.contains { delivery in
            if case .grant(let member, _) = delivery.payload { return member.userID == bob }
            return false
        } }) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let applied = controls.withLock { $0 }
        let baseline = try #require(applied.first)
        if case .baseline(let members) = baseline.payload { #expect(Set(members.map(\.userID)) == [alice]) }
        else { Issue.record("expected the original authorization baseline") }
        #expect(applied.allSatisfy { $0.fence == first.fence })
        try await service.close(); await pump.close()
    }



}

private actor SubscriptionOwnerSource: V2RoomSubscriptionSource {
    struct Read: Sendable { let after: UInt64; let users: Set<UserID> }
    let room: RoomID; let owner: V2RoomDataOwner; let alice: UserID; let bob: UserID
    private var head: UInt64 = 0
    private var controlVersion: Int64 = 0
    private var jump: (UInt64, UInt64)?
    private var shouldPause = false
    private var started = false
    private var paused: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var failing = false
    private(set) var snapshotCount = 0
    private(set) var reads: [Read] = []
    init(room: RoomID, owner: V2RoomDataOwner, alice: UserID, bob: UserID) {
        self.room = room; self.owner = owner; self.alice = alice; self.bob = bob
    }
    func jumpSnapshot(cut: UInt64, subsequentHead: UInt64) { jump = (cut, subsequentHead) }
    func setHead(_ value: UInt64) { head = value }
    func setControlVersion(_ value: Int64) { controlVersion = value }
    func pauseRead() { shouldPause = true; started = false }
    func waitUntilReadStarts() async {
        if started { return }; await withCheckedContinuation { startedWaiter = $0 }
    }
    func releaseRead() { paused?.resume(); paused = nil }
    func failReads() { failing = true }
    private func members(_ users: Set<UserID>, at cut: UInt64) -> [V2RoomSubscriptionSourceMember] {
        users.sorted().map { .init(userID: $0, memberRevision: $0 == bob && cut > 0 ? 1 : 0,
                                   authorized: $0 != bob || cut > 0) }
    }
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        snapshotCount += 1
        let cut: UInt64
        if let next = jump { cut = next.0; head = next.1; jump = nil } else { cut = head }
        return .init(roomID: room, owner: self.owner, highWatermark: cut, membershipRevision: cut > 0 ? 1 : 0, roomControlVersion: controlVersion, members: members(trackedUserIDs, at: cut))
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64,
              trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        reads.append(.init(after: afterRoomSequence, users: trackedUserIDs))
        if shouldPause {
            shouldPause = false; started = true; startedWaiter?.resume(); startedWaiter = nil
            await withCheckedContinuation { paused = $0 }
        }
        if failing { throw V2RoomSubscriptionSourceError.snapshotRequired }
        let end = min(head, afterRoomSequence + UInt64(limit))
        var records: [V2RoomSubscriptionSourceRecord] = []
        if end > afterRoomSequence {
            for sequence in (afterRoomSequence + 1)...end {
                let state = members(trackedUserIDs, at: sequence)
                records.append(.init(event: .init(roomID: room, highWatermark: head,
                    sourceEventID: try EventID("event-\(sequence)"), roomSequence: sequence,
                    projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 1),
                    hasOnlineBody: true, membershipControl: sequence == 1 ? .init(revisionBefore: 0, revisionAfter: 1, members: state) : nil,
                    recipientPolicy: .currentAuthorized))
            }
        }
        return .init(roomID: room, owner: self.owner, afterRoomSequence: afterRoomSequence,
                     highWatermark: head, records: records)
    }
}
