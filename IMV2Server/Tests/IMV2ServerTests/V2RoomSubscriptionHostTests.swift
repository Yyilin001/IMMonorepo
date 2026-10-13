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






    @Test func durableChangesDriveRepairAndStationaryLeaseChecksDoNotRepeatReads() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("dirty-room"), user = try UserID("dirty-user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let changes = HostDirtyReceipts()
            let host = V2RoomSubscriptionHost(dirtyChanges: { tokens, _, _, _ in await changes.pending(tokens) }, dirtyAcknowledge: { receipts, _ in await changes.acknowledge(receipts) })
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
            let host = V2RoomSubscriptionHost(dirtyChanges: { _, _, _, _ in
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



    @Test(arguments: [0, 1, 2])
    func explicitRecoveryRetainsReadAndAcknowledgementRetries(acknowledgementFailure: Int) async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("room"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let changes = HostDirtyReceipts()
            let acknowledgementAttempts = Mutex(0)
            let host = V2RoomSubscriptionHost(dirtyChanges: { tokens, _, _, _ in await changes.pending(tokens) },
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
            await host.checkChanges()
            let body = try #require(try await nextHostDelivery(deliveries.stream))
            if case .broadcast(let event) = body.payload {
                #expect(event.roomSequence == 1)
            } else { Issue.record("expected committed body after explicit recovery") }
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
        return .init(roomID: room, owner: self.owner, highWatermark: head,
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
