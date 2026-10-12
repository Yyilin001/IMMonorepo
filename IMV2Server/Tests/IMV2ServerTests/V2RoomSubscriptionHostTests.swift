import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerInfrastructure
@testable import IMV2Server

struct V2RoomSubscriptionHostTests {
    private enum HeadRepairTimeout: Error { case expired }
    @Test func independentRenewalUsesOnlyAnExistingActivatedOwner() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { _, _, _, _ in
                .init(changes: [], nextCursor: nil)
            })
            activations.own(host)
            try await host.configure(sendBatch: { batch, _, _ in
                .init(receipts: Array(Set(batch.deliveries.map(\.fence))).map { fence in
                    .init(fence: fence, result: .appliedThrough(batch.deliveries.last { $0.fence == fence }!.deliverySequence))
                })
            }, maximumCalls: 1)
            let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [user])
            let peer = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID()),
                endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
            let grant = try await owner.subscribe(gateway: peer.identity, userID: user, token: token, deadline: .now + .seconds(30))
            let command = V2RoomSubscriptionRenewCommand(roomID: room, actorUserID: user, gatewayDescriptor: peer,
                expectedFence: grant.fence, appliedControlSequence: 1)
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renew(command: command, token: token, activationValidUntil: .now + .seconds(30), deadline: .now + .seconds(30))
            }
            try await host.register(owner, token: token, lifetime: lifetime)
            await host.checkChanges()
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renew(command: command, token: token, activationValidUntil: .now + .seconds(30), deadline: .now + .seconds(30))
            }
            let pump = try #require(await host.currentPump())
            #expect(try await owner.activate(to: pump, descriptor: peer, userID: user, fence: grant.fence,
                token: token, deadline: .now + .seconds(30)))
            let snapshots = await source.snapshotCount, reads = await source.readCount
            var result: V2RoomSubscriptionRenewal?
            for _ in 0..<100 {
                do {
                    result = try await host.renew(command: command, token: token,
                        activationValidUntil: .now + .seconds(30), deadline: .now + .seconds(30))
                    break
                } catch V2RoomSubscriptionOwnerError.catchUpRequired { try await Task.sleep(for: .milliseconds(1)) }
            }
            let renewed = try #require(result)
            #expect(renewed.fence == grant.fence && renewed.appliedControlSequence == 1)
            #expect(renewed.remainingLeaseMilliseconds > 0 && renewed.remainingLeaseMilliseconds <= 15_000)
            #expect(await source.snapshotCount == snapshots)
            #expect(await source.readCount == reads)
            await host.close()
        }
    }
    @Test(arguments: [Int64(0), Int64(1)])
    func committedHeadLagDoesNotInvalidateAnUnchangedPermissionCut(controlVersion: Int64) async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("renewal-head-lag"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            // The durable change feed has observed H=5; the online reader is still
            // at 0. Renewal must distinguish this from a new permission version.
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { _, _, _, _ in
                .init(changes: [.init(activation: token, highWatermark: 5, revision: 1,
                    roomControlVersion: controlVersion)], nextCursor: nil)
            })
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in .init(receipts: []) }, maximumCalls: 1)
            let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [])
            try await host.register(owner, token: token, lifetime: lifetime)
            await host.checkChanges()
            if controlVersion == 0 {
                let proof = try await host.renewalProof(token: token, activationValidUntil: .now + .seconds(30),
                    deadline: .now + .seconds(30))
                #expect(proof.committedRoomSequence == 5 && proof.roomControlVersion == 0)
            } else {
                await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                    try await host.renewalProof(token: token, activationValidUntil: .now + .seconds(30),
                        deadline: .now + .seconds(30))
                }
            }
            await host.close()
        }
    }
    @Test func renewalUsesLocalAuthorityAndCannotOutliveControlFeedOrActivation() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("local-renewal"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let clock = Mutex(ContinuousClock.now), calls = Mutex(0), failFeed = Mutex(false)
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), controlFreshness: .seconds(15),
                now: { clock.withLock { $0 } }, dirtyChanges: { _, _, _, _ in
                    calls.withLock { $0 += 1 }
                    if failFeed.withLock({ $0 }) { throw HeadRepairTimeout.expired }
                    return .init(changes: [], nextCursor: nil)
                })
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in .init(receipts: []) }, maximumCalls: 1)
            let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [])
            try await host.register(owner, token: token, lifetime: lifetime)
            let validUntil = clock.withLock { $0 + .seconds(30) }
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renewalProof(token: token, activationValidUntil: validUntil, deadline: .now + .seconds(30))
            }
            await host.checkChanges()
            for _ in 0..<100 {
                let proof = try await host.renewalProof(token: token, activationValidUntil: validUntil, deadline: .now + .seconds(30))
                #expect(proof.remainingLeaseMilliseconds == 15_000 && proof.committedRoomSequence == 0)
            }
            #expect(calls.withLock { $0 } == 1)
            #expect(await source.readCount == 0)
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renewalProof(token: token, activationValidUntil: clock.withLock { $0 - .seconds(1) }, deadline: .now + .seconds(30))
            }
            failFeed.withLock { $0 = true }
            clock.withLock { $0 += .seconds(16) }
            await host.checkChanges()
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renewalProof(token: token, activationValidUntil: validUntil, deadline: .now + .seconds(30))
            }
            #expect(calls.withLock { $0 } == 2)
            await host.close()
        }
    }

    @Test func aPartialControlFeedCycleDoesNotGrantFreshAuthority() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let calls = Mutex(0)
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { _, _, _, _ in
                calls.withLock { $0 += 1 }
                return .init(changes: [], nextCursor: .init(partitionID: 0, roomID: UUID()))
            })
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in .init(receipts: []) }, maximumCalls: 1)
            let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [])
            try await host.register(owner, token: token, lifetime: lifetime)
            await host.checkChanges()
            #expect(calls.withLock { $0 } == 64)
            await #expect(throws: V2RoomSubscriptionOwnerError.catchUpRequired) {
                try await host.renewalProof(token: token, activationValidUntil: .now + .seconds(30), deadline: .now + .seconds(30))
            }
            await host.close()
        }
    }

    @Test func durableChangesDriveRepairAndStationaryLeaseChecksDoNotRepeatReads() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("dirty-room"), user = try UserID("dirty-user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let changes = HostDirtyReceipts()
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { tokens, _, _, _ in await changes.pending(tokens) }, dirtyAcknowledge: { receipts, _ in await changes.acknowledge(receipts) })
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in throw HeadRepairTimeout.expired }, maximumCalls: 1)
            do {
                let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                    activation: token, deadline: .now + .seconds(30), trackedUserIDs: [], notifyChanged: { _ in })
                try await host.register(service, token: token, lifetime: lifetime)
                await source.setHead(1)
                await changes.offer(.init(activation: token, highWatermark: 1, revision: 1, roomControlVersion: 0))
                await host.checkChanges()
                let deadline = ContinuousClock.now + .seconds(2)
                while await changes.acknowledged == 0 {
                    guard .now < deadline else { throw HeadRepairTimeout.expired }
                    try await Task.sleep(for: .milliseconds(1))
                }
                #expect(await service.consumedSequence() == 1)
                #expect(await source.readCount == 1)
                await host.checkChanges(); await host.checkChanges()
                #expect(await source.readCount == 1)
                await host.close()
            } catch { await host.close(); throw error }
        }
    }

    @Test func stationaryRoomsUseOneHostFeedReadAndZeroRoomProbes() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let user = try UserID("user")
            let queries = Mutex(0)
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { _, _, _, _ in
                queries.withLock { $0 += 1 }
                return .init(changes: [], nextCursor: nil)
            })
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in .init(receipts: []) }, maximumCalls: 1)
            var sources: [HostCheckSource] = []
            for index in 0..<256 {
                let room = try RoomID("room-\(index)")
                let (token, lifetime) = try await activations.activate(room)
                let source = HostCheckSource(room: room, owner: token.owner, user: user)
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                    activation: token, deadline: .now + .seconds(30), trackedUserIDs: [])
                try await host.register(owner, token: token, lifetime: lifetime); sources.append(source)
            }
            await host.checkChanges()
            #expect(queries.withLock { $0 } == 1)
            for source in sources { #expect(await source.readCount == 0) }
            await host.close()
        }
    }

    @Test func continuousCommittedFactsUseNoSourceRead() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("room"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let changes = HostDirtyReceipts()
            let host = V2RoomSubscriptionHost(checkInterval: .seconds(3600), dirtyChanges: { tokens, _, _, _ in await changes.pending(tokens) })
            let feed = V2RoomCommittedFactsFeed(notify: { host.signal(room: $0) })
            host.install(feed: feed)
            let deliveries = AsyncStream<V2RoomSubscriptionDelivery>.makeStream(bufferingPolicy: .bufferingNewest(8))
            activations.own(host)
            try await host.configure(sendBatch: { batch, _, _ in
                for delivery in batch.deliveries { deliveries.continuation.yield(delivery) }
                return .init(receipts: [.init(fence: batch.deliveries[0].fence, result: .appliedThrough(batch.deliveries.last!.deliverySequence))])
            }, maximumCalls: 1)
            let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [], notifyChanged: { host.signal(gateway: .init(roomID: room, gateway: $0)) })
            try await host.register(service, token: token, lifetime: lifetime)
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let grant = try await service.subscribe(gateway: gateway, userID: user, token: token, deadline: .now + .seconds(30))
            let pump = try #require(await host.currentPump())
            #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 8443),
                userID: user, fence: grant.fence, token: token, deadline: .now + .seconds(30)))
            _ = try await nextHostDelivery(deliveries.stream)
            let accepted = V2AcceptedMessage(messageID: try MessageID("message"), roomID: room, roomSequence: 1,
                senderUserID: user, clientMessageID: try ClientMessageID("client"), text: "committed plain text", mediaPresentations: [],
                sourceEventID: try EventID("event-1"), acceptedMembershipRevision: 0, createdAt: Date(timeIntervalSince1970: 1))
            await source.setHead(1)
            feed.observeCommittedMessages([.accepted(accepted)], activation: token)
            let body = try #require(try await nextHostDelivery(deliveries.stream))
            if case .broadcast(let event) = body.payload {
                let payload = try #require(try JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
                #expect(payload["text"] as? String == "committed plain text")
                #expect(event.roomSequence == 1)
            } else { Issue.record("committed body must be an ordered broadcast") }
            #expect(await source.readCount == 0)
            let consumptionDeadline = ContinuousClock.now + .seconds(2)
            while feed.take(activation: token) != nil {
                guard .now < consumptionDeadline else { throw HeadRepairTimeout.expired }
                await Task.yield()
            }
            // Simulate a final socket body/head not reaching its viewer even though
            // the Gateway RPC acknowledged it. Source cursor is already caught up.
            let deadline = ContinuousClock.now + .seconds(2)
            while await pump.snapshot().actualCalls != 0 {
                guard .now < deadline else { throw HeadRepairTimeout.expired }
                try await Task.sleep(for: .milliseconds(1))
            }
            let heldProof = HeldHeadRefreshProof()
            let renewing = Task {
                try await service.renew(gateway: gateway, userID: user, expectedFence: grant.fence,
                    appliedControlSequence: body.authorizationSequence, token: token, deadline: .now + .seconds(30),
                    leaseProof: { token, _ in await heldProof.proof(token: token) })
            }
            await heldProof.waitUntilStarted()
            await changes.offer(.init(activation: token, highWatermark: 1, revision: 1, roomControlVersion: 0))
            await host.checkChanges()
            // Permission proof is still held: committed progress must arrive without
            // waiting for that independent renewal lifecycle to finish.
            let repaired = try #require(try await nextHostDelivery(deliveries.stream))
            await heldProof.release()
            _ = try await renewing.value
            #expect(repaired.payload == .head(highWatermark: 1) && repaired.fence == grant.fence)
            #expect(await source.readCount == 0)
            await host.close(); deliveries.continuation.finish()
        }
    }

    @Test(arguments: [0, 1, 2])
    func periodicHeadCheckRecoversMissingFinalNotificationAndTransientReadFailure(acknowledgementFailure: Int) async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("room"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let changes = HostDirtyReceipts()
            let acknowledgementAttempts = Mutex(0)
            let host = V2RoomSubscriptionHost(checkInterval: .milliseconds(20), dirtyChanges: { tokens, _, _, _ in await changes.pending(tokens) },
                dirtyAcknowledge: { receipts, _ in
                    let attempt = acknowledgementAttempts.withLock { value in value += 1; return value }
                    if acknowledgementFailure == 1 && attempt == 1 { throw HeadRepairTimeout.expired }
                    await changes.acknowledge(receipts)
                    // The durable effect happened, but the caller did not observe success.
                    if acknowledgementFailure == 2 && attempt == 1 { throw HeadRepairTimeout.expired }
                })
            let deliveries = AsyncStream<V2RoomSubscriptionDelivery>.makeStream(bufferingPolicy: .bufferingNewest(8))
            activations.own(host)
            try await host.configure(sendBatch: { batch, _, _ in
                for delivery in batch.deliveries { deliveries.continuation.yield(delivery) }
                return .init(receipts: [.init(fence: batch.deliveries[0].fence,
                    result: .appliedThrough(batch.deliveries.last!.deliverySequence))])
            }, maximumCalls: 1)
            let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [],
                notifyChanged: { host.signal(gateway: .init(roomID: room, gateway: $0)) })
            try await host.register(service, token: token, lifetime: lifetime)
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let grant = try await service.subscribe(gateway: gateway, userID: user, token: token, deadline: .now + .seconds(30))
            let pump = try #require(await host.currentPump())
            #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
                address: "127.0.0.1", port: 8443), userID: user, fence: grant.fence, token: token, deadline: .now + .seconds(30)))
            _ = try await nextHostDelivery(deliveries.stream) // initial baseline
            await source.commitWithoutNotificationAndFailFirstRead()
            await changes.offer(.init(activation: token, highWatermark: 1, revision: 1, roomControlVersion: 0))
            let body = try #require(try await nextHostDelivery(deliveries.stream))
            if case .broadcast(let event) = body.payload {
                #expect(event.roomSequence == 1)
            } else { Issue.record("expected committed body after periodic head recovery") }
            #expect(await source.failures == 1)
            let acknowledgementDeadline = ContinuousClock.now + .seconds(2)
            let expectedAcknowledgementAttempts = acknowledgementFailure == 0 ? 1 : 2
            while acknowledgementAttempts.withLock({ $0 }) < expectedAcknowledgementAttempts,
                  ContinuousClock.now < acknowledgementDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await changes.acknowledged == 1)
            #expect(acknowledgementAttempts.withLock { $0 } == expectedAcknowledgementAttempts)
            #expect(await service.consumedSequence() == 1)
            let readsAfterRecovery = await source.readCount
            await host.checkChanges()
            await host.checkChanges()
            #expect(await source.readCount == readsAfterRecovery)
            #expect(await changes.acknowledged == 1)
            await host.close()
            #expect(await host.currentPump() == nil)
            deliveries.continuation.finish()
        }
    }
}

private actor HeldHeadRefreshProof {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startedWaiter = $0 } }
    }
    func proof(token: V2RoomActivationToken) async -> V2RoomSubscriptionLeaseProof {
        started = true; startedWaiter?.resume(); startedWaiter = nil
        await withCheckedContinuation { held = $0 }
        return .init(activation: token, committedRoomSequence: 1, remainingLeaseMilliseconds: 10_000)
    }
    func release() { held?.resume(); held = nil }
}

private actor HostCheckSource: V2RoomSubscriptionSource {
    private enum Transient: Error { case unavailable }
    let room: RoomID; let owner: V2RoomDataOwner; let user: UserID
    private var head: UInt64 = 0
    private var failNext = false
    private(set) var failures = 0
    private(set) var readCount = 0
    private(set) var snapshotCount = 0
    init(room: RoomID, owner: V2RoomDataOwner, user: UserID) { self.room = room; self.owner = owner; self.user = user }
    func currentHead() -> UInt64 { head }
    func setHead(_ value: UInt64) { head = value }
    func commitWithoutNotificationAndFailFirstRead() { head = 1; failNext = true }
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        snapshotCount += 1
        return .init(roomID: room, owner: self.owner, highWatermark: head, remainingLeaseMilliseconds: 60_000,
            members: trackedUserIDs.map { .init(userID: $0, memberRevision: 0, authorized: true) })
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64, trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        readCount += 1
        if failNext { failNext = false; failures += 1; throw Transient.unavailable }
        let records: [V2RoomSubscriptionSourceRecord] = afterRoomSequence == 0 && head == 1 ? [
            .init(event: .init(roomID: room, highWatermark: 1, sourceEventID: try EventID("event"), roomSequence: 1,
                projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 0),
                hasOnlineBody: true, membershipControl: nil, recipientPolicy: .currentAuthorized)
        ] : []
        return .init(roomID: room, owner: self.owner, afterRoomSequence: afterRoomSequence, highWatermark: head, records: records)
    }
}

private actor HostDirtyReceipts {
    private var receipt: V2RoomSubscriptionDirtyHead?
    private(set) var acknowledged = 0
    func offer(_ value: V2RoomSubscriptionDirtyHead) { receipt = value }
    func pending(_ tokens: [V2RoomActivationToken]) -> V2RoomSubscriptionDirtyPage {
        .init(changes: receipt.map { tokens.contains($0.activation) ? [$0] : [] } ?? [], nextCursor: nil)
    }
    func acknowledge(_ values: [V2RoomSubscriptionDirtyHead]) {
        if let receipt, values.contains(receipt) { self.receipt = nil; acknowledged += 1 }
    }
}

private func nextHostDelivery(_ stream: AsyncStream<V2RoomSubscriptionDelivery>) async throws -> V2RoomSubscriptionDelivery? {
    try await withThrowingTaskGroup(of: V2RoomSubscriptionDelivery?.self) { group in
        group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw HostDeliveryTimeout.expired
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}
private enum HostDeliveryTimeout: Error { case expired }
