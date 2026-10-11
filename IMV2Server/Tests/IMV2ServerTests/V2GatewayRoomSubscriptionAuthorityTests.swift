import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerGateway

@Suite("Gateway local room subscription socket authority")
struct V2GatewayRoomSubscriptionAuthorityTests {
    @Test("replay fingerprint covers event fields, canonical sets and ordered controls")
    func fingerprintEventFields() throws {
        let f = Fixture(), other = UserID(uuid: UUID()), source = EventID(uuid: UUID())
        let recipients: Set<UserID> = [f.user, other]
        func event(change: Int = -1, recipients value: Set<UserID>? = nil) -> V2RealtimeRoomEvent {
            .init(roomID: change == 0 ? RoomID(uuid: UUID()) : f.room,
                highWatermark: change == 1 ? 13 : 12,
                sourceEventID: change == 2 ? EventID(uuid: UUID()) : source,
                roomSequence: change == 3 ? 13 : 12,
                projectionKind: change == 4 ? "edited" : "message",
                payload: change == 5 ? Data([2]) : Data([1]),
                recipientUserIDs: value ?? (change == 6 ? [other] : recipients),
                groupMembershipRevision: change == 7 ? 0 : nil,
                acceptedMembershipRevision: change == 8 ? 0 : nil,
                excludedConnectionID: change == 9 ? UUID() : nil)
        }
        let members = [f.member, V2RoomSubscriptionMember(userID: other, memberRevision: 2)]
        func digest(_ value: V2RealtimeRoomEvent, members list: [V2RoomSubscriptionMember]? = nil) -> Data {
            V2RoomSubscriptionDeliveryFingerprint.digest(f.delivery(2, .event(value, members: list ?? members)))
        }
        let original = digest(event())
        #expect(digest(event(recipients: Set([other, f.user]))) == original)
        for field in 0..<10 { #expect(digest(event(change: field)) != original) }
        #expect(digest(event(), members: Array(members.reversed())) != original)
        #expect(digest(event(), members: [f.member]) != original)
        let changedRevision = [f.member, V2RoomSubscriptionMember(userID: other, memberRevision: 3)]
        #expect(digest(event(), members: changedRevision) != original)
        #expect(V2RoomSubscriptionDeliveryFingerprint.digest(f.delivery(2, .broadcast(event()))) != original)
    }

    @Test("replay fingerprint binds the entire activation, fence and delivery ordering")
    func fingerprintFenceFields() throws {
        let f = Fixture(), fence = f.fence(), token = fence.activation
        let original = V2RoomSubscriptionDeliveryFingerprint.digest(f.delivery(2, .head(highWatermark: 12)))
        for field in 0..<11 {
            let host = V2ActorHostIdentity(hostID: field == 4 ? try .init("other-host") : token.host.hostID,
                incarnationID: field == 5 ? UUID() : token.host.incarnationID)
            let changed = V2RoomActivationToken(roomID: field == 0 ? RoomID(uuid: UUID()) : token.roomID,
                owner: try .init(shardID: field == 1 ? "other-shard" : token.owner.shardID,
                                 epoch: field == 2 ? token.owner.epoch + 1 : token.owner.epoch),
                activationEpoch: field == 3 ? try .init(token.activationEpoch.rawValue + 1) : token.activationEpoch,
                host: host)
            let changedFence = V2RoomSubscriptionFence(activation: changed,
                subscriptionID: field == 6 ? UUID() : fence.subscriptionID,
                generation: field == 7 ? fence.generation + 1 : fence.generation,
                baselineSequence: field == 8 ? fence.baselineSequence + 1 : fence.baselineSequence)
            let delivery = V2RoomSubscriptionDelivery(fence: changedFence,
                deliverySequence: field == 9 ? 3 : 2, authorizationSequence: field == 10 ? 2 : 1,
                payload: .head(highWatermark: 12))
            #expect(V2RoomSubscriptionDeliveryFingerprint.digest(delivery) != original)
        }
    }

    @Test("evicting retired history requires a trusted reset for every unknown installation")
    func retiredHistoryRequiresFreshProof() async throws {
        let f = Fixture(), authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 1, maximumRetiredRooms: 1)
        for _ in 0..<3 {
            let room = RoomID(uuid: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: f.fence().activation.owner,
                activationEpoch: f.fence().activation.activationEpoch, host: f.fence().activation.host)
            let old = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10)
            let needsReset = await authority.requiresBaseline(fence: old)
            if needsReset {
                #expect(!(await authority.install(fence: old, serviceID: "owner", deadline: .now + .seconds(20))))
            }
            let installed = needsReset ? V2RoomSubscriptionFence(activation: token,
                subscriptionID: UUID(), generation: 2, baselineSequence: 10) : old
            try #require(await authority.install(fence: installed, serviceID: "owner", deadline: .now + .seconds(20),
                afterAuthoritativeReset: needsReset))
            #expect(await authority.retire(fence: installed))
            // Eviction may already remove this tombstone. A repeated cleanup
            // must neither decrement active capacity nor recreate history.
            _ = await authority.retire(fence: installed)
        }
        #expect(await authority.requiresBaseline(fence: f.fence()))
        #expect(!(await authority.install(fence: f.fence(), serviceID: "owner", deadline: .now + .seconds(20))))
    }

    @Test("replacement incarnation cold baseline cannot revive revoked membership from old controls or writes")
    func replacementRejectsLateRevokedMembership() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let oldWrite = try #require(await f.event(authority, control: 2).first)
        #expect(await authority.apply(f.delivery(3, authorization: 2,
            .revoke(userID: f.user, memberRevision: 1)), authenticatedServiceID: "owner") == .applied(permits: []))
        let replacement = V2RoomSubscriptionFence(activation: f.activation(activationEpoch: 2,
            hostIncarnation: UUID()), subscriptionID: UUID(), generation: 1, baselineSequence: 11)
        try #require(await authority.install(fence: replacement, serviceID: "owner", deadline: .now + .seconds(100)))
        #expect(await authority.apply(.init(fence: replacement, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [])), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(f.delivery(4, authorization: 3,
            .grant(member: f.member, baselineSequence: 11)), authenticatedServiceID: "owner") == .stale)
        #expect(await authority.apply(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner") == .stale)
        let oldAccepted = await authority.enqueueFixtureIfCurrent(oldWrite, enqueue: {})
        #expect(!oldAccepted)
        #expect(await authority.captureOnlinePermits(roomID: f.room).isEmpty)
        let member = V2RoomSubscriptionMember(userID: f.user, memberRevision: 2)
        #expect(await authority.apply(.init(fence: replacement, deliverySequence: 2, authorizationSequence: 2,
            payload: .grant(member: member, baselineSequence: 11)), authenticatedServiceID: "owner") == .applied(permits: []))
        let body = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 12, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 12, projectionKind: "message", payload: Data([1]), recipientUserIDs: [f.user])
        guard case .applied(let permits) = await authority.apply(.init(fence: replacement, deliverySequence: 3,
            authorizationSequence: 2, payload: .event(body, members: [member])), authenticatedServiceID: "owner") else {
            Issue.record("replacement body rejected"); return
        }
        let fresh = try #require(permits.first)
        #expect(fresh.fence.activation == replacement.activation)
        let freshAccepted = await authority.enqueueFixtureIfCurrent(fresh, enqueue: {})
        #expect(freshAccepted)
    }

    @Test("baseline gaps and repeated members never authorize a device", arguments: [false, true])
    func malformedBaselinePage(gap: Bool) async throws {
        let f = Fixture(), authority = f.authority()
        try #require(await authority.registerFixtureConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: .now + .seconds(100)))
        let first = [f.member] + (1..<512).map { _ in V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 1) }
        #expect(await authority.apply(f.delivery(1, .baselinePage(index: 0, totalMembers: 1_025, members: first)),
            authenticatedServiceID: "owner") == .applied(permits: []))
        let broken = gap ? f.delivery(3, .baselinePage(index: 2, totalMembers: 1_025, members: [f.member]))
            : f.delivery(2, .baselinePage(index: 1, totalMembers: 1_025, members: first))
        #expect(await authority.apply(broken, authenticatedServiceID: "owner") == .snapshotRequired)
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user, reports: [(f.room, 10)])
        }
    }
    @Test("segmented group authorization stays closed until the final page", arguments: [513, 5_000, 100_000])
    func segmentedBaseline(total: Int) async throws {
        let f = Fixture(), authority = f.authority()
        try #require(await authority.registerFixtureConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: .now + .seconds(100)))
        let members = [f.member] + (1..<total).map { _ in V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 1) }
        let size = V2RoomSubscriptionPayload.maximumBaselinePageMembers
        for offset in stride(from: 0, to: total, by: size) {
            let index = offset / size
            let delivery = f.delivery(UInt64(index + 1), .baselinePage(index: index, totalMembers: total,
                members: Array(members[offset..<min(offset + size, total)])))
            try delivery.validate()
            #expect(try JSONEncoder().encode(delivery).count < 100_000)
            #expect(await authority.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
            #expect(await authority.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
            if offset + size < total {
                await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
                    try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user, reports: [(f.room, 10)])
                }
            }
        }
        #expect(try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user,
            reports: [(f.room, 10)]).first?.appliedThrough == 10)
        #expect(await f.event(authority, control: UInt64((total + size - 1) / size + 1),
            authorization: UInt64((total + size - 1) / size)).map(\.connectionID) == [f.connection])
    }

    @Test("authorized room bodies reach every online device without a foreground interest")
    func onlineMemberDevicesReceiveWithoutOpeningRoom() async throws {
        let f = Fixture(), authority = f.authority()
        let sibling = UUID(), siblingLifecycle = UUID(), outsider = UUID()
        try #require(await authority.registerFixtureConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
        try #require(await authority.registerFixtureConnection(sibling, userID: f.user, lifecycle: siblingLifecycle))
        try #require(await authority.registerFixtureConnection(outsider, userID: .init(uuid: UUID()), lifecycle: UUID()))
        try await f.baseline(authority)
        let permits = await f.event(authority, control: 2)
        #expect(Set(permits.map(\.connectionID)) == [f.connection, sibling])
        #expect(try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user,
            reports: [(f.room, 11)]).first?.appliedThrough == 11)
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user, reports: [(f.room, 12)])
        }
        for permit in permits {
            let accepted = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
            #expect(accepted)
        }
        authority.removeConnection(sibling, lifecycle: siblingLifecycle)
        await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
            try await authority.validateDeviceProgress(connectionID: sibling, userID: f.user, reports: [(f.room, 11)])
        }
        let siblingPermit = try #require(permits.first { $0.connectionID == sibling })
        let disconnectedAccepted = await authority.enqueueFixtureIfCurrent(siblingPermit, enqueue: {})
        #expect(!disconnectedAccepted)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 1)),
            authenticatedServiceID: "owner") == .applied(permits: []))
        await #expect(throws: V2RoomRecoveryReadError.invalidCursor) {
            try await authority.validateDeviceProgress(connectionID: f.connection, userID: f.user, reports: [(f.room, 11)])
        }
        let firstPermit = try #require(permits.first { $0.connectionID == f.connection })
        let revokedAccepted = await authority.enqueueFixtureIfCurrent(firstPermit, enqueue: {})
        #expect(!revokedAccepted)
    }

    @Test("captured account head permits cannot survive revocation, disconnect, expiry or retirement", arguments: [0, 1, 2, 3])
    func accountHeadPermitFences(reason: Int) async throws {
        let f = Fixture(), clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        try #require(await authority.registerFixtureConnection(f.connection, userID: f.user, lifecycle: f.lifecycle))
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: clock.withLock { $0 } + .seconds(5)))
        #expect(await authority.apply(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.capturePermits(roomID: f.room).isEmpty)
        let permit = try #require(await authority.captureOnlinePermits(roomID: f.room).first)
        switch reason {
        case 0:
            #expect(await authority.apply(f.delivery(2, .revoke(userID: f.user, memberRevision: 1)),
                authenticatedServiceID: "owner") == .applied(permits: []))
        case 1: authority.removeConnection(f.connection, lifecycle: f.lifecycle)
        case 2: clock.withLock { $0 += .seconds(5) }
        default: await authority.retire(fence: f.fence())
        }
        #expect(await authority.captureOnlinePermits(roomID: f.room).isEmpty)
        let writes = Mutex(0)
        let direct = await authority.enqueueFixtureIfCurrent(permit) { writes.withLock { $0 += 1 } }
        #expect(!direct)
        #expect(writes.withLock { $0 } == 0)
    }

    @Test("missing data preserves the grant; permission renewal cannot revive an expired fence")
    func renewalRequiresLiveContinuousGrant() async throws {
        let f = Fixture(), initial = ContinuousClock.now
        let clock = Mutex(initial)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: initial + .seconds(5)))
        #expect(await authority.apply(f.delivery(1, .baseline(members: [.init(userID: f.user, memberRevision: 1)])),
            authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.renewalCheckpoint(fence: f.fence(), serviceID: "owner") == 1)
        #expect(await authority.renew(fence: f.fence(), serviceID: "owner", appliedControlSequence: 1, deadline: initial + .seconds(10)))
        #expect(!(await authority.renew(fence: f.fence(), serviceID: "imposter", appliedControlSequence: 1, deadline: initial + .seconds(20))))
        #expect(!(await authority.renew(fence: f.fence(), serviceID: "owner", appliedControlSequence: 2, deadline: initial + .seconds(20))))
        #expect(await authority.apply(f.delivery(3, .head(highWatermark: 50)), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.renewalCheckpoint(fence: f.fence(), serviceID: "owner") == 1)
        #expect(await authority.renew(fence: f.fence(), serviceID: "owner", appliedControlSequence: 1, deadline: initial + .seconds(20)))
        let replacement = V2RoomSubscriptionFence(activation: f.fence().activation, subscriptionID: UUID(),
            generation: f.fence().generation + 1, baselineSequence: f.fence().baselineSequence)
        try #require(await authority.install(fence: replacement, serviceID: "owner", deadline: initial + .seconds(15)))
        #expect(await authority.apply(.init(fence: replacement, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [.init(userID: f.user, memberRevision: 1)])), authenticatedServiceID: "owner") == .applied(permits: []))
        clock.withLock { $0 = initial + .seconds(16) }
        #expect(!(await authority.renew(fence: replacement, serviceID: "owner", appliedControlSequence: 1, deadline: initial + .seconds(30))))
    }

    @Test("progress publication is independent of permission renewal and preserves Ready baseline")
    func progressPublicationIsIndependentOfRenewal() async throws {
        let f = Fixture(), authority = f.authority()
        let heads = Mutex<[UInt64]>([])
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority,
            offerEvent: { _, _ in }, offerHead: { _, head in heads.withLock { $0.append(head) } })
        try #require(await ingress.install(fence: f.fence(), sourceShardID: "rooms", serviceID: "owner",
            deadline: .now + .seconds(30)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        heads.withLock { $0.removeAll() }
        // The initial offer had no interested device. A later exact scope must
        // recover the committed head even without another room event.
        await f.connect(authority)
        try #require(await ingress.renew(fence: f.fence(), sourceShardID: "rooms", serviceID: "owner",
            appliedControlSequence: 1, deadline: .now + .seconds(40)))
        try #require(await ingress.renew(fence: f.fence(), sourceShardID: "rooms", serviceID: "owner",
            appliedControlSequence: 1, deadline: .now + .seconds(40)))
        #expect(heads.withLock { $0 }.isEmpty)
        try #require(await ingress.refreshProgress(fence: f.fence(), sourceShardID: "rooms", serviceID: "owner", highWatermark: 12))
        try #require(await ingress.refreshProgress(fence: f.fence(), sourceShardID: "rooms", serviceID: "owner", highWatermark: 12))
        #expect(heads.withLock { $0 } == [12, 12])
        #expect(await authority.capturePermits(roomID: f.room).first?.baselineSequence == 10)
        #expect(await authority.renewalCheckpoint(fence: f.fence(), serviceID: "owner") == 1)
        #expect(!(await ingress.renew(fence: f.fence(), sourceShardID: "rooms", serviceID: "imposter",
            appliedControlSequence: 1, deadline: .now + .seconds(40))))
        #expect(heads.withLock { $0 } == [12, 12])
    }

    @Test("permission recovery retains committed H but never revives expired socket authority")
    func permissionRecoveryPreservesIndependentMessageProgress() async throws {
        let f = Fixture(), initial = ContinuousClock.now, clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        await f.connect(authority)
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: initial + .seconds(1)))
        try await f.baseline(authority)
        clock.withLock { $0 = initial + .seconds(101) }
        #expect(await authority.recordCommittedHead(fence: f.fence(), serviceID: "owner", highWatermark: 40))
        #expect(await authority.progressSnapshot(connectionID: f.connection) == nil)
        #expect(await authority.capturePermits(roomID: f.room).isEmpty)
        let fresh = f.fence(generation: 2)
        try #require(await authority.install(fence: fresh, serviceID: "owner", deadline: initial + .seconds(130)))
        #expect(await authority.apply(.init(fence: fresh, deliverySequence: 1, authorizationSequence: 1,
            payload: .baseline(members: [f.member])), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.progressSnapshot(connectionID: f.connection)?.highWatermark == 40)
        #expect(await authority.renewalCheckpoint(fence: fresh, serviceID: "owner") == 1)
    }

    @Test("Authority retains H after publication; pending worker capacity is reusable")
    func headWorkerRetainsLatestHint() async throws {
        let f = Fixture(), other = RoomID(uuid: UUID())
        let authority = V2GatewayRoomSubscriptionAuthority()
        try #require(await authority.install(fence: f.fence(), serviceID: "owner", deadline: .now + .seconds(30)))
        #expect(await authority.recordCommittedHead(fence: f.fence(), serviceID: "owner", highWatermark: 12))
        let output = AsyncStream<(RoomID, UInt64)>.makeStream()
        let worker = V2GatewayRoomSubscriptionHeadWorker(maximumRooms: 1) { room, head in
            output.continuation.yield((room, max(head, await authority.recoveryHighWatermark(roomID: room) ?? 0)))
        }
        worker.start()
        var delivered = output.stream.makeAsyncIterator()
        #expect(worker.offer(roomID: f.room, highWatermark: 12))
        #expect(await delivered.next()?.1 == 12)
        #expect(worker.offer(roomID: other, highWatermark: 1))
        #expect(await delivered.next()?.0 == other)
        #expect(worker.offer(roomID: f.room, highWatermark: 11))
        #expect(await delivered.next()?.1 == 12)
        await worker.shutdown()
        output.continuation.finish()
        #expect(!worker.offer(roomID: f.room, highWatermark: 13))
    }

    @Test("an exact terminal receipt remains possible after pause, expiry or local retirement", arguments: [0, 1, 2])
    func terminalReceiptAfterLocalAuthorityEnds(ending: Int) async throws {
        let f = Fixture(), clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        await f.connect(authority); try await f.baseline(authority)
        let permit = try #require(await authority.capturePermits(roomID: f.room).first)
        switch ending {
        case 0: #expect(await authority.pause(fence: f.fence()))
        case 1: clock.withLock { $0 += .seconds(101) }
        default: #expect(await authority.retire(fence: f.fence()))
        }
        let terminal = f.delivery(2, .authorizationInvalidated)
        #expect(await authority.apply(terminal, authenticatedServiceID: "imposter") == .stale)
        #expect(await authority.apply(terminal, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(terminal, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.captureOnlinePermits(roomID: f.room).isEmpty)
        let submitted = await authority.enqueueFixtureIfCurrent(permit, enqueue: { Issue.record("terminal restored a permit") })
        #expect(!submitted)
        #expect(!(await authority.renew(fence: f.fence(), serviceID: "owner", appliedControlSequence: 2,
            deadline: clock.withLock { $0 } + .seconds(100))))
        #expect(await authority.apply(f.delivery(3, .grant(member: f.member, baselineSequence: 10)),
            authenticatedServiceID: "owner") != .applied(permits: []))
        let replacement = f.fence(generation: 2)
        #expect(await authority.install(fence: replacement, serviceID: "owner",
            deadline: clock.withLock { $0 } + .seconds(100), afterAuthoritativeReset: true))
        #expect(await authority.apply(terminal, authenticatedServiceID: "owner") == .stale)
    }

    @Test("same-H terminal control retires permit socket authority and remains ACK-idempotent")
    func terminalInvalidationIsImmediate() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let permit = try #require(await authority.capturePermits(roomID: f.room).first)
        let terminal = f.delivery(2, .authorizationInvalidated)
        #expect(await authority.apply(terminal, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.recoveryHighWatermark(roomID: f.room) == 10)
        #expect(await authority.capturePermits(roomID: f.room).isEmpty)
        #expect(await authority.progressSnapshot(connectionID: f.connection) == nil)
        #expect(await authority.requiresBaseline(fence: f.fence()))
        #expect(await authority.renewalCheckpoint(fence: f.fence(), serviceID: "owner") == nil)
        let committed = await authority.enqueueFixtureIfCurrent(permit, enqueue: { Issue.record("retired payload submitted") })
        #expect(!committed)
        let submitted = await authority.enqueueFixtureIfCurrent(permit, enqueue: { Issue.record("retired permit submitted") })
        #expect(!submitted)
        #expect(await authority.apply(terminal, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(f.delivery(2, .head(highWatermark: 10)), authenticatedServiceID: "owner") == .stale)
        #expect(await authority.apply(f.delivery(3, .head(highWatermark: 10)), authenticatedServiceID: "owner") == .snapshotRequired)
        #expect(!(await authority.renew(fence: f.fence(), serviceID: "owner", appliedControlSequence: 2, deadline: .now + .seconds(100))))
    }

    @Test("adding devices and users preserves existing room/user permits")
    func localChangesRemainLocal() async throws {
        let f = Fixture()
        let authority = f.authority()
        await f.connect(authority)
        try await f.baseline(authority)
        let old = try #require(await f.event(authority, control: 2).first)
        let secondDevice = UUID()
        let secondLifecycle = UUID()
        await authority.registerFixtureConnection(secondDevice, userID: f.user, lifecycle: secondLifecycle)
        #expect(await authority.registerRoomInterest(connectionID: secondDevice, lifecycle: secondLifecycle, roomID: f.room, scopeGeneration: 1))
        let other = UserID(uuid: UUID())
        #expect(await authority.apply(f.delivery(3, authorization: 2, .grant(member: .init(userID: other, memberRevision: 1), baselineSequence: 10)), authenticatedServiceID: "owner") == .applied(permits: []))
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(oldSubmitted)
        let current = await f.event(authority, control: 4, authorization: 2, roomSequence: 12)
        #expect(current.count == 2)
        #expect(Set(current.map(\.connectionID)) == [f.connection, secondDevice])
    }

    @Test("detail changes invalidate detail permits while preserving account delivery", arguments: [false, true])
    func detailChangesPreserveAccountPermit(switchRoom: Bool) async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority)
        try await f.baseline(authority)
        let accountPermit = try #require(await f.event(authority, control: 2).first)
        let detailPermit = try #require(await authority.capturePermits(roomID: f.room).first)
        if switchRoom {
            #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle,
                roomID: RoomID(uuid: UUID()), scopeGeneration: 2))
        } else {
            await authority.removeRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle, roomID: f.room)
        }
        let detailCommitted = await authority.enqueueFixtureIfCurrent(detailPermit, enqueue: { Issue.record("retired detail submitted") })
        let accountCommitted = await authority.enqueueFixtureIfCurrent(accountPermit, enqueue: {})
        #expect(!detailCommitted)
        #expect(accountCommitted)
    }

    @Test("account permits retained after detail cancellation are invalidated by member or connection retirement", arguments: [false, true])
    func retainedAccountPermitRetires(revokeMember: Bool) async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority)
        try await f.baseline(authority)
        let permit = try #require(await f.event(authority, control: 2).first)
        await authority.removeRoomInterest(connectionID: f.connection, lifecycle: f.lifecycle, roomID: f.room)
        if revokeMember {
            #expect(await authority.apply(f.delivery(3, authorization: 2,
                .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .applied(permits: []))
        } else {
            authority.removeConnection(f.connection, lifecycle: f.lifecycle)
        }
        let submitted = await authority.enqueueFixtureIfCurrent(permit, enqueue: { Issue.record("retired account permit submitted") })
        #expect(!submitted)
    }

    @Test("revocation rejects captured permits across every device for that user only")
    func revokeRejectsCapturedPermits() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority)
        let other = UserID(uuid: UUID()), otherConnection = UUID()
        let otherLifecycle = UUID()
        await authority.registerFixtureConnection(otherConnection, userID: other, lifecycle: otherLifecycle)
        #expect(await authority.registerRoomInterest(connectionID: otherConnection, lifecycle: otherLifecycle, roomID: f.room, scopeGeneration: 1))
        try await f.baseline(authority, extra: [.init(userID: other, memberRevision: 1)])
        let permits = await f.event(authority, control: 2, extra: [other])
        let old = try #require(permits.first { $0.userID == f.user })
        let unrelated = try #require(permits.first { $0.userID == other })
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .applied(permits: []))
        let pendingCommitted = await authority.enqueueFixtureIfCurrent(old, enqueue: { Issue.record("revoked bytes submitted") })
        #expect(!pendingCommitted)
        let survivingCommitted = await authority.enqueueFixtureIfCurrent(unrelated, enqueue: {})
        #expect(survivingCommitted)
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!oldSubmitted)
        #expect(await authority.apply(f.delivery(4, authorization: 3, .grant(member: .init(userID: f.user, memberRevision: 1), baselineSequence: 10)), authenticatedServiceID: "owner") == .invalid)
    }

    @Test("a control gap pauses the room and requires a fresh fenced baseline")
    func controlGap() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let old = try #require(await f.event(authority, control: 2).first)
        #expect(await authority.apply(f.delivery(4, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .snapshotRequired)
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!oldSubmitted)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .grant(member: .init(userID: f.user, memberRevision: 3), baselineSequence: 10)), authenticatedServiceID: "owner") == .snapshotRequired)
        let fresh = f.fence(generation: 2)
        #expect(await authority.install(fence: fresh, serviceID: "owner", deadline: .now + .seconds(100)))
        #expect(await authority.apply(.init(fence: fresh, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [f.member])), authenticatedServiceID: "owner") == .applied(permits: []))
        // A delayed last-reference cleanup belongs to the old installation.
        #expect(!(await authority.pause(fence: f.fence())))
        #expect(!(await authority.retire(fence: f.fence())))
        #expect(await authority.renewalCheckpoint(fence: fresh, serviceID: "owner") == 1)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 3)), authenticatedServiceID: "owner") == .stale)
    }

    @Test("expiry and connection replacement fail closed at actual submission")
    func expirationAndLifecycle() async throws {
        let f = Fixture(), clock = Mutex(ContinuousClock.now)
        let initial = clock.withLock { $0 }
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        await f.connect(authority)
        #expect(await authority.install(fence: f.fence(), serviceID: "owner", deadline: initial + .seconds(10)))
        #expect(await authority.apply(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner") == .applied(permits: []))
        let old = try #require(await f.event(authority, control: 2).first)
        let replacement = UUID()
        await authority.registerFixtureConnection(f.connection, userID: f.user, lifecycle: replacement)
        #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: replacement, roomID: f.room, scopeGeneration: 1))
        authority.removeConnection(f.connection, lifecycle: f.lifecycle)
        let pendingCommitted = await authority.enqueueFixtureIfCurrent(old, enqueue: { })
        #expect(!pendingCommitted)
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!oldSubmitted)
        let fresh = try #require(await f.event(authority, control: 3, roomSequence: 12).first)
        #expect(fresh.lifecycle == replacement)
        clock.withLock { $0 = initial + .seconds(10) }
        let freshSubmitted = await authority.enqueueFixtureIfCurrent(fresh, enqueue: {})
        #expect(!freshSubmitted)
        #expect(!(await authority.install(fence: f.fence(), serviceID: "owner", deadline: initial + .seconds(20))))
    }

    @Test("old owner and out-of-order control cannot mutate current authority")
    func ownerAndOrdering() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let permit = try #require(await f.event(authority, control: 2).first)
        #expect(await authority.apply(f.delivery(2, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .stale)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "imposter") == .stale)
        let permitSubmitted = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(permitSubmitted)
        let moved = f.fence(ownerEpoch: 2, generation: 1)
        #expect(await authority.install(fence: moved, serviceID: "new-owner", deadline: .now + .seconds(100)))
        #expect(!(await authority.install(fence: f.fence(generation: 100), serviceID: "owner", deadline: .now + .seconds(100))))
        let permitSubmitted2 = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(!permitSubmitted2)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .stale)
    }

    @Test("same revision resubscribe creates a new authority while membership floors reject older incarnations")
    func resubscribeCurrentIncarnation() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let old = try #require(await f.event(authority, control: 2).first)
        #expect(await authority.apply(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 1)), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(f.delivery(4, authorization: 3, .grant(member: f.member, baselineSequence: 11)), authenticatedServiceID: "owner") == .applied(permits: []))
        let fresh = try #require(await f.event(authority, control: 5, authorization: 3, roomSequence: 12).first)
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!oldSubmitted)
        let freshSubmitted = await authority.enqueueFixtureIfCurrent(fresh, enqueue: {})
        #expect(freshSubmitted)
        #expect(await authority.apply(f.delivery(6, authorization: 4, .revoke(userID: f.user, memberRevision: 2)), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(f.delivery(7, authorization: 5, .grant(member: f.member, baselineSequence: 12)), authenticatedServiceID: "owner") == .invalid)
        #expect(await authority.apply(f.delivery(7, authorization: 5, .grant(member: .init(userID: f.user, memberRevision: 2), baselineSequence: 12)), authenticatedServiceID: "owner") == .applied(permits: []))
        let freshSubmitted2 = await authority.enqueueFixtureIfCurrent(fresh, enqueue: {})
        #expect(!freshSubmitted2)
    }

    @Test("group delivery uses trusted members with current revisions and excludes the source connection")
    func groupRecipients() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority)
        let second = UUID(), secondLifecycle = UUID(), unrelated = UserID(uuid: UUID())
        #expect(await authority.registerFixtureConnection(second, userID: f.user, lifecycle: secondLifecycle))
        #expect(await authority.registerRoomInterest(connectionID: second, lifecycle: secondLifecycle, roomID: f.room, scopeGeneration: 1))
        let unrelatedConnection = UUID(), unrelatedLifecycle = UUID()
        #expect(await authority.registerFixtureConnection(unrelatedConnection, userID: unrelated, lifecycle: unrelatedLifecycle))
        #expect(await authority.registerRoomInterest(connectionID: unrelatedConnection, lifecycle: unrelatedLifecycle, roomID: f.room, scopeGeneration: 1))
        try await f.baseline(authority, extra: [.init(userID: unrelated, memberRevision: 2)])
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 11, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 11, projectionKind: "message", payload: Data([1]), recipientUserIDs: [],
            groupMembershipRevision: 8, excludedConnectionID: f.connection)
        let delivery = f.delivery(2, .event(event, members: [f.member, .init(userID: unrelated, memberRevision: 1)]))
        guard case .applied(let permits) = await authority.apply(delivery, authenticatedServiceID: "owner") else {
            Issue.record("group event rejected"); return
        }
        #expect(permits.count == 1)
        #expect(permits.first?.connectionID == second)
        #expect(permits.first?.userID == f.user)
    }

    @Test("exact last delivery retry ACKs without repeating fanout; conflicting duplicate is rejected")
    func lostAcknowledgement() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let baseline = f.delivery(1, .baseline(members: [f.member]))
        #expect(await authority.apply(baseline, authenticatedServiceID: "owner") == .applied(permits: []))
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 11, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 11, projectionKind: "message", payload: Data([1]), recipientUserIDs: [f.user])
        let delivery = f.delivery(2, .event(event, members: [f.member]))
        guard case .applied(let permits) = await authority.apply(delivery, authenticatedServiceID: "owner") else {
            Issue.record("event rejected"); return
        }
        #expect(permits.count == 1)
        #expect(await authority.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(f.delivery(2, .revoke(userID: f.user, memberRevision: 1)), authenticatedServiceID: "owner") == .stale)
        #expect(await authority.apply(baseline, authenticatedServiceID: "owner") == .applied(permits: []))
        let permit = try #require(permits.first)
        let permitSubmitted = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(permitSubmitted)
    }

    @Test("targeted queue indexes maintain byte accounting through lifecycle and room retirement")
    func indexedPendingAccounting() async throws {
        let f = Fixture(), authority = V2GatewayRoomSubscriptionAuthority()
        await f.connect(authority)
        let other = UserID(uuid: UUID()), otherConnection = UUID()
        let otherLifecycle = UUID()
        #expect(await authority.registerFixtureConnection(otherConnection, userID: other, lifecycle: otherLifecycle))
        #expect(await authority.registerRoomInterest(connectionID: otherConnection, lifecycle: otherLifecycle, roomID: f.room, scopeGeneration: 1))
        try await f.baseline(authority, extra: [.init(userID: other, memberRevision: 1)])
        let permits = await f.event(authority, control: 2, extra: [other])
        let first = try #require(permits.first { $0.userID == f.user })
        let second = try #require(permits.first { $0.userID == other })
        // Moving the connection replaces its identity without changing a sibling permit.
        let replacementLifecycle = UUID()
        #expect(await authority.registerFixtureConnection(f.connection, userID: other, lifecycle: replacementLifecycle))
        #expect(await authority.registerRoomInterest(connectionID: f.connection, lifecycle: replacementLifecycle, roomID: f.room, scopeGeneration: 1))
        let replacedAccepted = await authority.enqueueFixtureIfCurrent(first, enqueue: {})
        #expect(!replacedAccepted)
        let routed = await f.event(authority, control: 3, roomSequence: 12, extra: [other])
        #expect(routed.count == 2)
        #expect(routed.allSatisfy { $0.userID == other })
        let secondPendingCommitted = await authority.enqueueFixtureIfCurrent(second, enqueue: { })
        #expect(secondPendingCommitted)
        let routedPermit = try #require(routed.first)
        await authority.retire(fence: f.fence())
        let retiredAccepted = await authority.enqueueFixtureIfCurrent(routedPermit, enqueue: {})
        #expect(!retiredAccepted)
    }

    @Test("room, connection and member history admission has explicit bounds")
    func boundedAuthorityState() async throws {
        let f = Fixture(), authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 1, maximumConnections: 1, maximumMembersPerRoom: 1)
        await f.connect(authority); try await f.baseline(authority)
        #expect(!(await authority.registerFixtureConnection(UUID(), userID: f.user, lifecycle: UUID())))
        let otherRoom = V2RoomSubscriptionFence(activation: f.activation(roomID: RoomID(uuid: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        #expect(!(await authority.install(fence: otherRoom, serviceID: "owner", deadline: .now + .seconds(100))))
        let other = V2RoomSubscriptionMember(userID: UserID(uuid: UUID()), memberRevision: 1)
        #expect(await authority.apply(f.delivery(2, .grant(member: other, baselineSequence: 10)), authenticatedServiceID: "owner") == .invalid)
        #expect(await authority.apply(f.delivery(2, .revoke(userID: f.user, memberRevision: 1)), authenticatedServiceID: "owner") == .applied(permits: []))
        // Retained floors remain bounded; admission requires a fresh generation
        // to replace the complete bounded membership baseline.
        #expect(await authority.apply(f.delivery(3, authorization: 3, .grant(member: other, baselineSequence: 10)), authenticatedServiceID: "owner") == .invalid)
        let fresh = f.fence(generation: 2)
        #expect(await authority.install(fence: fresh, serviceID: "owner", deadline: .now + .seconds(100)))
        #expect(await authority.apply(.init(fence: fresh, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [other])), authenticatedServiceID: "owner") == .applied(permits: []))
    }

    @Test("H-only control cannot create membership or body permits")
    func headIsAdvisory() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let head = f.delivery(2, .head(highWatermark: 30))
        #expect(await authority.apply(head, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(head, authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.recoveryHighWatermark(roomID: f.room) == 30)
        #expect(await f.event(authority, control: 3, roomSequence: 11).count == 1)
        #expect(await authority.recoveryHighWatermark(roomID: f.room) == 30)
    }


    @Test("initial owner epoch and membership revision zero remain valid through unsubscribe and resubscribe")
    func zeroEpochAndMembershipRevision() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority)
        let fence = f.fence(ownerEpoch: 0)
        let member = V2RoomSubscriptionMember(userID: f.user, memberRevision: 0)
        #expect(await authority.install(fence: fence, serviceID: "owner", deadline: .now + .seconds(100)))
        let baseline = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [member]))
        #expect(await authority.apply(baseline, authenticatedServiceID: "owner") == .applied(permits: []))
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 11, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 11, projectionKind: "message", payload: Data([1]), recipientUserIDs: [f.user])
        let eventDelivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 2, authorizationSequence: 1, payload: .event(event, members: [member]))
        guard case .applied(let permits) = await authority.apply(eventDelivery, authenticatedServiceID: "owner") else {
            Issue.record("zero revision event rejected"); return
        }
        let permit = try #require(permits.first)
        let accepted = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(accepted)
        #expect(await authority.apply(.init(fence: fence, deliverySequence: 3, authorizationSequence: 2, payload: .revoke(userID: f.user, memberRevision: 0)), authenticatedServiceID: "owner") == .applied(permits: []))
        let revoked = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(!revoked)
        #expect(await authority.apply(.init(fence: fence, deliverySequence: 4, authorizationSequence: 3, payload: .grant(member: member, baselineSequence: 11)), authenticatedServiceID: "owner") == .applied(permits: []))
        let resurrected = await authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(!resurrected)
        // A new user at revision zero has no existing floor or incarnation.
        let newMember = V2RoomSubscriptionMember(userID: UserID(uuid: UUID()), memberRevision: 0)
        #expect(await authority.apply(.init(fence: fence, deliverySequence: 5, authorizationSequence: 4, payload: .grant(member: newMember, baselineSequence: 11)), authenticatedServiceID: "owner") == .applied(permits: []))
    }


    @Test("higher room activation accepts generation one, while old activation and equal-epoch host conflicts fail closed")
    func actualActivationFencesRestoration() async throws {
        let f = Fixture(), authority = f.authority()
        await f.connect(authority); try await f.baseline(authority)
        let oldPermit = try #require(await f.event(authority, control: 2).first)
        let newerActivation = f.activation(activationEpoch: 2,
            hostIncarnation: UUID(uuidString: "00000000-0000-0000-0000-00000000ac02")!)
        let restored = V2RoomSubscriptionFence(activation: newerActivation, subscriptionID: UUID(), generation: 1, baselineSequence: 11)
        #expect(await authority.install(fence: restored, serviceID: "owner", deadline: .now + .seconds(100)))
        let oldSubmitted = await authority.enqueueFixtureIfCurrent(oldPermit, enqueue: {})
        #expect(!oldSubmitted)
        #expect(await authority.apply(.init(fence: restored, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [f.member])), authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(!(await authority.install(fence: f.fence(generation: 100), serviceID: "owner", deadline: .now + .seconds(100))))
        #expect(await authority.apply(f.delivery(3, .head(highWatermark: 50)), authenticatedServiceID: "owner") == .stale)
        let conflict = V2RoomSubscriptionFence(activation: f.activation(activationEpoch: 2,
            hostIncarnation: UUID(uuidString: "00000000-0000-0000-0000-00000000ac03")!),
            subscriptionID: UUID(), generation: 100, baselineSequence: 11)
        #expect(!(await authority.install(fence: conflict, serviceID: "owner", deadline: .now + .seconds(100))))
        #expect(await authority.capturePermits(roomID: f.room).allSatisfy { $0.fence.activation == newerActivation })
    }

}

private struct Fixture {
    let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
    let subscription = UUID(), connection = UUID(), lifecycle = UUID()
    var member: V2RoomSubscriptionMember { .init(userID: user, memberRevision: 1) }
    func activation(roomID: RoomID? = nil, ownerEpoch: Int64 = 1, activationEpoch: Int64 = 1,
                    hostIncarnation: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000ac01")!) -> V2RoomActivationToken {
        .init(roomID: roomID ?? room, owner: try! .init(shardID: "rooms", epoch: ownerEpoch),
            activationEpoch: try! .init(activationEpoch),
            host: .init(hostID: try! .init("authority-test-owner"), incarnationID: hostIncarnation))
    }
    func fence(ownerEpoch: Int64 = 1, generation: UInt64 = 1) -> V2RoomSubscriptionFence {
        .init(activation: activation(ownerEpoch: ownerEpoch), subscriptionID: subscription,
            generation: generation, baselineSequence: 10)
    }
    func authority() -> V2GatewayRoomSubscriptionAuthority { .init() }
    func connect(_ authority: V2GatewayRoomSubscriptionAuthority) async {
        await authority.registerFixtureConnection(connection, userID: user, lifecycle: lifecycle)
        #expect(await authority.registerRoomInterest(connectionID: connection, lifecycle: lifecycle, roomID: room, scopeGeneration: 1))
    }
    func delivery(_ control: UInt64, authorization: UInt64? = nil, _ payload: V2RoomSubscriptionPayload) -> V2RoomSubscriptionDelivery {
        .init(fence: fence(), deliverySequence: control, authorizationSequence: authorization ?? (payload.isAuthorizationControl ? control : 1), payload: payload)
    }
    func baseline(_ authority: V2GatewayRoomSubscriptionAuthority, extra: [V2RoomSubscriptionMember] = []) async throws {
        #expect(await authority.install(fence: fence(), serviceID: "owner", deadline: .now + .seconds(100)))
        #expect(await authority.apply(delivery(1, .baseline(members: [member] + extra)), authenticatedServiceID: "owner") == .applied(permits: []))
    }
    func event(_ authority: V2GatewayRoomSubscriptionAuthority, control: UInt64, authorization: UInt64 = 1, roomSequence: UInt64 = 11,
               extra: Set<UserID> = []) async -> [V2GatewayRoomSubscriptionAuthority.Permit] {
        let event = V2RealtimeRoomEvent(roomID: room, highWatermark: roomSequence, sourceEventID: EventID(uuid: UUID()),
            roomSequence: roomSequence, projectionKind: "message", payload: Data([1]), recipientUserIDs: extra.union([user]))
        let members = [member] + extra.map { V2RoomSubscriptionMember(userID: $0, memberRevision: 1) }
        guard case .applied(let permits) = await authority.apply(delivery(control, authorization: authorization, .event(event, members: members)), authenticatedServiceID: "owner") else {
            Issue.record("event not applied"); return []
        }
        return permits
    }
}
