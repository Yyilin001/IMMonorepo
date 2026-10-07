import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerApplication

struct V2RoomSubscriptionOwnerTests {
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
        }, requestBaseline: { _, _ in })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443), userID: alice, fence: first.fence,
            token: activation, deadline: .now + .seconds(3)))
        await source.setControlVersion(1)
        try await service.observePermissionVersion(1, token: activation)
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(3))
        }
        allowTerminal.withLock { $0 = true }
        await service.signalDelivery()
        let deadline = ContinuousClock.now + .seconds(3)
        var complete = false
        while !complete, ContinuousClock.now < deadline {
            complete = try await service.processControlCut(expectedVersion: 1, token: activation, deadline: deadline)
            if !complete { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(complete)
        let replacement = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: deadline)
        #expect(replacement.fence.generation == first.fence.generation + 1)
        #expect(replacement.fence.subscriptionID != first.fence.subscriptionID)
        #expect(replacement.memberRevision == first.memberRevision)
        try await service.close(); await pump.close()
    }
    @Test func lightweightRenewalRequiresActivatedContinuousAuthorityWithoutMemberReads() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
            owner: owner, activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let grant = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        let proofCalls = Mutex(0)
        let proof: @Sendable (V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionLeaseProof = { token, _ in
            proofCalls.withLock { $0 += 1 }
            return .init(activation: token, committedRoomSequence: 0, remainingLeaseMilliseconds: 10_000)
        }
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: proof)
        }
        #expect(proofCalls.withLock { $0 } == 0)
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            .appliedThrough(delivery.deliverySequence)
        }, requestBaseline: { _, _ in })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway,
            endpointReference: Data([1]), address: "127.0.0.1", port: 8443), userID: alice,
            fence: grant.fence, token: activation, deadline: .now + .seconds(30)))
        let snapshots = await source.snapshotCount, reads = await source.reads.count
        var renewed: V2RoomSubscriptionRenewal?
        for _ in 0..<100 {
            do {
                renewed = try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                    appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: proof)
                break
            } catch V2RoomSubscriptionOwnerError.catchUpRequired { try await Task.sleep(for: .milliseconds(1)) }
        }
        let result = try #require(renewed)
        #expect(result.fence == grant.fence && result.committedRoomSequence == 0 && result.remainingLeaseMilliseconds > 0 && result.remainingLeaseMilliseconds <= 10_000)
        let ahead = try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: { token, _ in
                    .init(activation: token, committedRoomSequence: 1, remainingLeaseMilliseconds: 10_000)
                })
        #expect(ahead.committedRoomSequence == 1)
        #expect(await service.consumedSequence() == 0)
        // Same H cannot renew a grant across an unprocessed authorization cut.
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: { token, _ in
                    .init(activation: token, committedRoomSequence: 0, roomControlVersion: 1, remainingLeaseMilliseconds: 10_000)
                })
        }
        #expect(await source.snapshotCount == snapshots)
        #expect(await source.reads.count == reads)
        try await service.unsubscribe(gateway: gateway, userID: alice, memberRevision: 0, token: activation, deadline: .now + .seconds(30))
        #expect(await source.snapshotCount == snapshots)
        #expect(await source.reads.count == reads)
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: proof)
        }
        try await service.close(); await pump.close()
    }

    @Test func permissionRenewalDoesNotWaitForHeldMessageDatabaseRead() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [alice])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let grant = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        let terminalReceived = Mutex(false)
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1,
            send: { delivery, _, _ in
                if case .authorizationInvalidated = delivery.payload { terminalReceived.withLock { $0 = true } }
                return .appliedThrough(delivery.deliverySequence)
            }, requestBaseline: { _, _ in })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443), userID: alice, fence: grant.fence, token: activation, deadline: .now + .seconds(30)))
        await source.pauseRead()
        let drain = Task { try await service.drain(token: activation, deadline: .now + .seconds(30)) }
        await source.waitUntilReadStarts()
        let reads = await source.reads.count, snapshots = await source.snapshotCount
        var failure: (any Error)?
        do {
            let renewal = try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(1), leaseProof: { token, _ in
                    .init(activation: token, committedRoomSequence: 0, remainingLeaseMilliseconds: 10_000)
                })
            #expect(renewal.fence == grant.fence)
            #expect(await source.reads.count == reads)
            #expect(await source.snapshotCount == snapshots)
            try await service.observePermissionVersion(1, token: activation)
            for _ in 0..<100 {
                if terminalReceived.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(terminalReceived.withLock { $0 })
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await service.renew(gateway: gateway, userID: alice, expectedFence: grant.fence,
                    appliedControlSequence: 1, token: activation, deadline: .now + .seconds(1), leaseProof: { token, _ in
                        Issue.record("A retired permission cannot reach its proof provider")
                        return .init(activation: token, committedRoomSequence: 0, remainingLeaseMilliseconds: 10_000)
                    })
            }
            #expect(await source.snapshotCount == snapshots)
        } catch { failure = error }
        await source.releaseRead()
        _ = try await drain.value
        try await service.close(); await pump.close()
        if let failure { throw failure }
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
            send: { delivery, _, _ in .appliedThrough(delivery.deliverySequence) }, requestBaseline: { _, _ in })
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
        let received = AsyncStream<V2RoomSubscriptionDelivery>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            received.continuation.yield(delivery); return .appliedThrough(delivery.deliverySequence)
        }, requestBaseline: { _, _ in })
        await pump.start()
        #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
            address: "127.0.0.1", port: 8443), userID: alice, fence: recovered.fence, token: activation, deadline: .now + .seconds(30)))
        var iterator = received.stream.makeAsyncIterator()
        let baseline = try #require(await iterator.next())
        if case .baseline(let members) = baseline.payload { #expect(Set(members.map(\.userID)) == [alice]) }
        else { Issue.record("reset renewal must preserve the full shared-user baseline") }
        try await service.close(); await pump.close(); received.continuation.finish()
    }

    @Test func grantNeedsExactTokenAndSecondPhaseActivationAndResetRetryIsStable() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let activation = try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0)
        let source = SubscriptionOwnerSource(room: room, owner: owner, alice: alice, bob: bob)
        let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: owner,
            activation: activation, deadline: .now + .seconds(30), trackedUserIDs: [])
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
        let descriptor = V2GatewayRealtimeDescriptor(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 8443)
        let sent = Mutex([V2RoomSubscriptionDelivery]())
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1, send: { delivery, _, _ in
            sent.withLock { $0.append(delivery) }; return .appliedThrough(delivery.deliverySequence)
        }, requestBaseline: { _, _ in })
        await pump.start()
        let grant = try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now + .seconds(30))
        #expect(grant.remainingLeaseMilliseconds > 0 && grant.remainingLeaseMilliseconds <= 60_000)
        await service.signalDelivery()
        #expect(sent.withLock { $0.isEmpty })
        await #expect(throws: V2RoomSubscriptionOwnerError.stale) {
            try await service.activate(to: pump, descriptor: descriptor, userID: alice, fence: grant.fence,
                token: try roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0), deadline: .now + .seconds(30))
        }
        await #expect(throws: V2RoomSubscriptionOwnerError.deadlineExceeded) {
            try await service.subscribe(gateway: gateway, userID: alice, token: activation, deadline: .now - .seconds(1))
        }
        let reset = try await service.resetGrant(gateway: gateway, userID: alice, expectedFence: grant.fence,
            token: activation, deadline: .now + .seconds(30))
        let repeated = try await service.resetGrant(gateway: gateway, userID: alice, expectedFence: grant.fence,
            token: activation, deadline: .now + .seconds(30))
        #expect(reset.fence == repeated.fence && reset.fence.generation == grant.fence.generation + 1)
        await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
            try await service.renew(gateway: gateway, userID: alice, expectedFence: repeated.fence,
                appliedControlSequence: 1, token: activation, deadline: .now + .seconds(30), leaseProof: { token, _ in
                    .init(activation: token, committedRoomSequence: 0, remainingLeaseMilliseconds: 10_000)
                })
        }
        #expect(try await service.activate(to: pump, descriptor: descriptor, userID: alice, fence: repeated.fence,
            token: activation, deadline: .now + .seconds(30)))
        for _ in 0..<10_000 { if !sent.withLock({ $0.isEmpty }) { break }; await Task.yield() }
        #expect(sent.withLock { $0.first?.fence == repeated.fence })
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
        return .init(roomID: room, owner: self.owner, highWatermark: cut, membershipRevision: cut > 0 ? 1 : 0, roomControlVersion: controlVersion, remainingLeaseMilliseconds: 60_000, members: members(trackedUserIDs, at: cut))
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
