import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

public enum V2RoomSubscriptionOwnerError: Error, Equatable, Sendable {
    case busy, closed, unauthorized, catchUpRequired, overloaded, invalidInput, stale, deadlineExceeded
}

/// Trusted room-owner composition authenticates requests and its business lease
/// before entering this service. A database snapshot is a committed cut, never
/// proof of a live distributed owner lease. Mutation admission is explicit: a
/// suspended database call does not permit another mutation to enter the room.
public actor V2RoomSubscriptionOwner {
    public struct Grant: Equatable, Sendable {
        public let fence: V2RoomSubscriptionFence
        public let memberRevision: UInt64
        /// This user's cut, which can be newer than the shared fence baseline.
        public let baselineSequence: UInt64
        public let remainingLeaseMilliseconds: Int64
    }
    public struct DrainReport: Equatable, Sendable {
        public let consumedThrough: UInt64
        public let observedHighWatermark: UInt64
        public var hasMore: Bool { consumedThrough < observedHighWatermark }
    }
    private struct Gateway: Sendable {
        let subscriptionID: UUID
        let generation: UInt64
        var users: [UserID: UInt64]
        var resetPredecessor: V2RoomSubscriptionFence? = nil
    }
    private let source: any V2RoomSubscriptionSource
    private let roomID: RoomID
    private let owner: V2RoomDataOwner
    private let activation: V2RoomActivationToken
    private let relay: V2RoomSubscriptionRelay
    private let maximumTrackedUsers: Int
    private let maximumGateways: Int
    private let pageSize: Int
    private let maximumDrainPages: Int
    /// Must perform bounded synchronous enqueue/coalescing, never socket work.
    private let notifyChanged: @Sendable (V2GatewayRealtimeIdentity) -> Void
    private var appliedRoomControlVersion: Int64
    private var appliedMembershipRevision: UInt64
    private var trackedUserIDs: Set<UserID>
    private var gateways: [V2GatewayRealtimeIdentity: Gateway] = [:]
    private var activatedFences: [V2GatewayRealtimeIdentity: V2RoomSubscriptionFence] = [:]
    private var deliveryBindings: [V2GatewayRealtimeIdentity: V2RoomSubscriptionDeliveryPump] = [:]
    private var nextInput: UInt64 = 1
    private var nextSubscriptionGeneration: UInt64 = 1
    private var busy = false
    private var activePermissionOperations = 0
    private var requiredControlVersion: Int64
    private var activeDeadline: ContinuousClock.Instant?
    private var closed = false
    private var changed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    private init(source: any V2RoomSubscriptionSource, snapshot: V2RoomSubscriptionSourceSnapshot,
                 relay: V2RoomSubscriptionRelay, activation: V2RoomActivationToken, maximumTrackedUsers: Int, maximumGateways: Int,
                 pageSize: Int, maximumDrainPages: Int,
                 notifyChanged: @escaping @Sendable (V2GatewayRealtimeIdentity) -> Void) {
        self.activation = activation; self.source = source; self.roomID = snapshot.roomID; self.owner = snapshot.owner; self.relay = relay
        self.appliedRoomControlVersion = snapshot.roomControlVersion
        self.requiredControlVersion = snapshot.roomControlVersion
        self.appliedMembershipRevision = snapshot.membershipRevision
        self.trackedUserIDs = Set(snapshot.members.map(\.userID)); self.maximumTrackedUsers = maximumTrackedUsers
        self.maximumGateways = maximumGateways; self.pageSize = pageSize; self.maximumDrainPages = maximumDrainPages
        self.notifyChanged = notifyChanged
    }

    public static func restore(source: any V2RoomSubscriptionSource, roomID: RoomID, owner: V2RoomDataOwner, activation: V2RoomActivationToken, deadline: ContinuousClock.Instant,
                               trackedUserIDs: Set<UserID>, maximumTrackedUsers: Int = V2GroupCapacityPolicy.largeMaximumMembers,
                               maximumGateways: Int = 64, pageSize: Int = 64, maximumDrainPages: Int = 16,
                               notifyChanged: @escaping @Sendable (V2GatewayRealtimeIdentity) -> Void = { _ in }) async throws -> V2RoomSubscriptionOwner {
        guard activation.roomID == roomID, activation.owner == owner, maximumTrackedUsers > 0, maximumGateways > 0, trackedUserIDs.count <= maximumTrackedUsers,
              (1...64).contains(pageSize), maximumDrainPages > 0 else { throw V2RoomSubscriptionOwnerError.invalidInput }
        guard deadline > .now else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
        let snapshot = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs)
        guard deadline > .now, snapshot.roomID == roomID, snapshot.owner == owner,
              Set(snapshot.members.map(\.userID)) == trackedUserIDs else { throw V2RoomSubscriptionOwnerError.stale }
        let relay = try V2RoomSubscriptionRelay.restored(from: snapshot, activation: activation, maximumMembers: maximumTrackedUsers,
                                                       maximumGateways: maximumGateways)
        return .init(source: source, snapshot: snapshot, relay: relay, activation: activation, maximumTrackedUsers: maximumTrackedUsers,
                     maximumGateways: maximumGateways, pageSize: pageSize, maximumDrainPages: maximumDrainPages,
                     notifyChanged: notifyChanged)
    }

    package func consumedSequence() async -> UInt64 { await relay.committedSequence() }

    public func drain(token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> DrainReport {
        try enter(token: token, deadline: deadline); defer { leave() }
        await prune()
        do { return try await advance(through: nil) }
        catch V2RoomSubscriptionSourceError.snapshotRequired {
            return try await reconcileMissingControl()
        }
        catch { await failClosedIfNeeded(error); throw error }
    }

    /// Committed facts are an acceleration of the same continuous event stream.
    /// Missing controls/sequence or unsupported bodies request durable repair;
    /// they never borrow a current membership snapshot for an older event.
    public func consumeCommittedMessages(_ batch: V2RoomCommittedFactsBatch, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> DrainReport {
        try enter(token: token, deadline: deadline); defer { leave() }
        guard batch.activation == activation else { throw V2RoomSubscriptionOwnerError.stale }
        var cursor = await relay.committedSequence()
        let head = max(batch.dirtyHighWatermark ?? cursor, batch.messages.map(\.roomSequence).max() ?? cursor)
        guard batch.messages.count <= 64 else { throw V2RoomSubscriptionOwnerError.overloaded }
        var records: [V2RoomSubscriptionSourceRecord] = []
        for message in batch.messages {
            guard message.roomID == roomID else { throw V2RoomSubscriptionOwnerError.stale }
            if message.roomSequence <= cursor { continue }
            guard message.roomSequence == cursor + 1, let eventID = message.sourceEventID,
                  let revision = message.acceptedMembershipRevision, revision <= UInt64(Int64.max),
                  message.media.isEmpty, message.mediaPresentations.isEmpty, message.mentions.isEmpty,
                  message.entities.isEmpty, message.replyTo == nil,
                  let bytes = V2DirectRoomLogPayloadCodec.encode(message) else { break }
            let hasBody = bytes.count <= 262_144
            records.append(.init(event: .init(roomID: roomID, highWatermark: head, sourceEventID: eventID,
                roomSequence: message.roomSequence, projectionKind: "message", payload: hasBody ? bytes : Data(),
                recipientUserIDs: [], groupMembershipRevision: revision, acceptedMembershipRevision: revision),
                hasOnlineBody: hasBody, membershipControl: nil, recipientPolicy: .currentAuthorized))
            cursor = message.roomSequence
        }
        do {
            try checkDeadline()
            let before = await relay.committedSequence()
            if !records.isEmpty {
                try await relay.ingest(.init(roomID: roomID, owner: owner, afterRoomSequence: before, highWatermark: head, records: records))
                changed = true
            }
            return .init(consumedThrough: await relay.committedSequence(), observedHighWatermark: head)
        } catch V2RoomSubscriptionSourceError.snapshotRequired {
            return try await reconcileMissingControl()
        } catch { await failClosedIfNeeded(error); throw error }
    }

    // Called inside the existing serialized Owner turn. A missing historical
    // permission control may not leave the old Gateway grant usable or infer
    // audience for the skipped body. Replace it with a complete trusted cut
    // and an ordered terminal invalidation; ordinary delivery waits for reset.
    private func reconcileMissingControl() async throws -> DrainReport {
        let cut = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs)
        guard cut.roomControlVersion > appliedRoomControlVersion else {
            // A persistence gap without a new authorization cut remains a
            // fatal log defect; a current member snapshot cannot repair it.
            await failClosedIfNeeded(V2RoomSubscriptionSourceError.snapshotRequired)
            throw V2RoomSubscriptionSourceError.snapshotRequired
        }
        if try await relay.reconcileControlCut(cut, requireTerminal: true) { activatedFences.removeAll(); changed = true }
        appliedRoomControlVersion = cut.roomControlVersion
        appliedMembershipRevision = cut.membershipRevision
        return .init(consumedThrough: await relay.committedSequence(), observedHighWatermark: cut.highWatermark)
    }

    public func subscribe(gateway identity: V2GatewayRealtimeIdentity, userID: UserID, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Grant {
        try enter(token: token, deadline: deadline); defer { leave() }
        // Preserve the old terminal until its actual Gateway receipt. Once
        // drained, the needsBaseline branch below must admit a fresh fence.
        guard !(await relay.controlInvalidationPending(gateway: identity)) else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
        await prune()
        guard !identity.nodeID.isEmpty, identity.nodeID.utf8.count <= 128,
              !identity.serviceID.isEmpty, identity.serviceID.utf8.count <= 128,
              trackedUserIDs.contains(userID) || trackedUserIDs.count < maximumTrackedUsers,
              gateways[identity] != nil || gateways.count < maximumGateways else {
            throw V2RoomSubscriptionOwnerError.overloaded
        }
        do {
            let proofStarted = ContinuousClock.now
            let cut = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: [userID])
            guard cut.roomID == roomID, cut.owner == owner else { throw V2RoomSubscriptionSourceError.wrongOwner }
            guard cut.roomControlVersion == appliedRoomControlVersion, cut.roomControlVersion >= requiredControlVersion else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            guard cut.members.count == 1,
                  let member = cut.members.first, member.userID == userID else { throw V2RoomSubscriptionOwnerError.stale }
            let progress = try await advance(through: cut.highWatermark)
            guard progress.consumedThrough == cut.highWatermark else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            guard member.authorized else { throw V2RoomSubscriptionOwnerError.unauthorized }
            try await relay.seedAuthorizations(from: cut)
            trackedUserIDs.insert(userID)
            var gateway: Gateway
            if let existing = gateways[identity] {
                gateway = existing
                if await relay.status(for: identity)?.needsBaseline == true {
                    gateway = Gateway(subscriptionID: UUID(), generation: try allocateGeneration(), users: existing.users)
                    gateway.resetPredecessor = try requireStatus(await relay.status(for: identity)).fence
                    activatedFences.removeValue(forKey: identity)
                    try await control(.reset(gateway: identity, subscriptionID: gateway.subscriptionID, generation: gateway.generation))
                    let restoredMembers = await relay.subscriptionMembers(for: identity)
                    gateway.users = Dictionary(uniqueKeysWithValues: restoredMembers.map { ($0.userID, $0.memberRevision) })
                }
            }
            else { gateway = Gateway(subscriptionID: UUID(), generation: try allocateGeneration(), users: [:]) }
            try await control(.subscribe(gateway: identity, userID: userID, memberRevision: member.memberRevision,
                subscriptionID: gateway.subscriptionID, generation: gateway.generation))
            gateway.users[userID] = member.memberRevision; gateways[identity] = gateway; changed = true
            let status = try requireStatus(await relay.status(for: identity))
            try checkDeadline()
            let remaining = remainingLease(cut.remainingLeaseMilliseconds, since: proofStarted)
            guard remaining > 0 else { throw V2RoomActivationLeaseError.leaseExpired }
            return .init(fence: status.fence, memberRevision: member.memberRevision, baselineSequence: cut.highWatermark, remainingLeaseMilliseconds: remaining)
        } catch { await failClosedIfNeeded(error); throw error }
    }

    /// Trusted composition obtains the proof inside this admission boundary.
    /// Renew never reads members, advances the log, subscribes, or activates.
    /// Reads the current cut without reserving the message consumption turn.
    public func renewalCheckpoint() async -> (sequence: UInt64, controlVersion: Int64) {
        (await relay.committedSequence(), appliedRoomControlVersion)
    }

    public func renew(gateway identity: V2GatewayRealtimeIdentity, userID: UserID,
                      expectedFence: V2RoomSubscriptionFence, appliedControlSequence: UInt64,
                      token: V2RoomActivationToken, deadline: ContinuousClock.Instant,
                      leaseProof: @Sendable (V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionLeaseProof) async throws -> V2RoomSubscriptionRenewal {
        guard !closed else { throw V2RoomSubscriptionOwnerError.closed }
        guard token == activation else { throw V2RoomSubscriptionOwnerError.stale }
        guard deadline > .now, !Task.isCancelled else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
        guard expectedFence.activation == activation, activatedFences[identity] == expectedFence, deliveryBindings[identity] != nil,
              gateways[identity]?.users[userID] != nil,
              await relay.canRenew(gateway: identity, fence: expectedFence,
                  appliedControlSequence: appliedControlSequence, userID: userID) else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        guard !closed else { throw V2RoomSubscriptionOwnerError.closed }
        guard activePermissionOperations < 64 else { throw V2RoomSubscriptionOwnerError.overloaded }
        activePermissionOperations += 1
        defer {
            activePermissionOperations -= 1
            resumeCloseIfIdle()
        }
        let started = ContinuousClock.now
        let proof = try await leaseProof(activation, deadline)
        guard proof.activation == activation else { throw V2RoomActivationLeaseError.activationChanged }
        let committedSequence = await relay.committedSequence()
        guard proof.roomControlVersion == appliedRoomControlVersion, proof.roomControlVersion >= requiredControlVersion,
              proof.committedRoomSequence <= UInt64(Int64.max) else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        // Data consumption may progress independently. Revalidate the authority cut after suspension.
        guard await relay.canRenew(gateway: identity, fence: expectedFence,
            appliedControlSequence: appliedControlSequence, userID: userID) else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        guard !closed, token == activation, expectedFence.activation == activation,
              activatedFences[identity] == expectedFence, deliveryBindings[identity] != nil,
              gateways[identity]?.users[userID] != nil,
              proof.roomControlVersion == appliedRoomControlVersion, proof.roomControlVersion >= requiredControlVersion else {
            throw V2RoomSubscriptionOwnerError.catchUpRequired
        }
        guard deadline > .now, !Task.isCancelled else {
            throw V2RoomSubscriptionOwnerError.deadlineExceeded
        }
        let remaining = remainingLease(proof.remainingLeaseMilliseconds, since: started)
        guard remaining > 0 else { throw V2RoomActivationLeaseError.leaseExpired }
        // Authorization renewal never acknowledges or retires message deliveries.
        return .init(fence: expectedFence, appliedControlSequence: appliedControlSequence,
                     committedRoomSequence: max(proof.committedRoomSequence, committedSequence), remainingLeaseMilliseconds: remaining)
    }

    public func unsubscribe(gateway identity: V2GatewayRealtimeIdentity, userID: UserID,
                            memberRevision: UInt64, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws {
        try enter(token: token, deadline: deadline); defer { leave() }
        await prune()
        guard var gateway = gateways[identity], gateway.users[userID] == memberRevision else {
            throw V2RoomSubscriptionOwnerError.stale
        }
        do {
            do { try await control(.unsubscribe(gateway: identity, userID: userID, memberRevision: memberRevision)) }
            catch V2RoomSubscriptionRelayError.stale {
                // A committed member control may already have revoked the
                // grant. The old local attachment still retires safely.
            }
            gateway.users.removeValue(forKey: userID); gateways[identity] = gateway; changed = true
            await prune()
        } catch { await failClosedIfNeeded(error); throw error }
    }

    public func reset(gateway identity: V2GatewayRealtimeIdentity, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionFence {
        try enter(token: token, deadline: deadline); defer { leave() }
        return try await performReset(gateway: identity, userID: nil, expectedFence: nil).fence
    }
    public func resetGrant(gateway identity: V2GatewayRealtimeIdentity, userID: UserID, expectedFence: V2RoomSubscriptionFence, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Grant {
        try enter(token: token, deadline: deadline); defer { leave() }
        return try await performReset(gateway: identity, userID: userID, expectedFence: expectedFence)
    }
    private func performReset(gateway identity: V2GatewayRealtimeIdentity, userID: UserID?, expectedFence: V2RoomSubscriptionFence?) async throws -> Grant {
        // Do not erase retained terminal responsibility by replacing a fence
        // before its actual Gateway receipt reaches this Owner.
        guard !(await relay.controlInvalidationPending(gateway: identity)) else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
        await prune()
        guard let previous = gateways[identity],
              let requester = userID ?? previous.users.keys.sorted().first, previous.users[requester] != nil else {
            throw V2RoomSubscriptionOwnerError.stale
        }
        let current = try requireStatus(await relay.status(for: identity))
        var repeatingReset = false
        if let expectedFence {
            guard expectedFence.activation == activation else { throw V2RoomSubscriptionOwnerError.stale }
            if current.fence != expectedFence {
                guard previous.resetPredecessor == expectedFence, !current.needsBaseline else { throw V2RoomSubscriptionOwnerError.stale }
                repeatingReset = true
            }
        }
        do {
            let started = ContinuousClock.now
            let cut = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs)
            guard cut.roomControlVersion >= requiredControlVersion else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            let progress: DrainReport
            do { progress = try await advance(through: cut.highWatermark) }
            catch V2RoomSubscriptionSourceError.snapshotRequired {
                _ = try await reconcileMissingControl()
                throw V2RoomSubscriptionOwnerError.catchUpRequired
            }
            guard progress.consumedThrough == cut.highWatermark else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            if cut.roomControlVersion > appliedRoomControlVersion {
                if try await relay.reconcileControlCut(cut, requireTerminal: cut.roomControlVersion > appliedRoomControlVersion && cut.membershipRevision == appliedMembershipRevision) { activatedFences.removeAll(); changed = true }
                appliedRoomControlVersion = cut.roomControlVersion
                appliedMembershipRevision = cut.membershipRevision
            }
            guard !(await relay.controlInvalidationPending(gateway: identity)) else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            try await relay.seedAuthorizations(from: cut)
            guard let member = cut.members.first(where: { $0.userID == requester }), member.authorized else { throw V2RoomSubscriptionOwnerError.unauthorized }
            let allowed = Dictionary(uniqueKeysWithValues: cut.members.filter { $0.authorized && previous.users[$0.userID] != nil }.map { ($0.userID, $0.memberRevision) })
            if !repeatingReset {
                var replacement = Gateway(subscriptionID: UUID(), generation: try allocateGeneration(), users: allowed)
                replacement.resetPredecessor = current.fence
                activatedFences.removeValue(forKey: identity)
                try await control(.reset(gateway: identity, subscriptionID: replacement.subscriptionID, generation: replacement.generation))
                gateways[identity] = replacement; changed = true
            }
            let status = try requireStatus(await relay.status(for: identity))
            try checkDeadline()
            let remaining = remainingLease(cut.remainingLeaseMilliseconds, since: started)
            guard remaining > 0 else { throw V2RoomActivationLeaseError.leaseExpired }
            return .init(fence: status.fence, memberRevision: member.memberRevision, baselineSequence: cut.highWatermark, remainingLeaseMilliseconds: remaining)
        } catch { await failClosedIfNeeded(error); throw error }
    }

    /// Second phase: the authenticated Gateway has installed the returned
    /// grant. Recheck DB authority and this user's exact current grant before
    /// exposing the private Relay to its transport admission/ACK pump.
    @discardableResult public func activate(to pump: V2RoomSubscriptionDeliveryPump,
                                           descriptor: V2GatewayRealtimeDescriptor, userID: UserID,
                                           fence: V2RoomSubscriptionFence, token: V2RoomActivationToken,
                                           deadline: ContinuousClock.Instant) async throws -> Bool {
        try enter(token: token, deadline: deadline); defer { leave() }
        try descriptor.validate()
        guard fence.activation == activation, let attached = gateways[descriptor.identity]?.users[userID],
              try requireStatus(await relay.status(for: descriptor.identity)).fence == fence else {
            throw V2RoomSubscriptionOwnerError.stale
        }
        do {
            let cut = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: [userID])
            let progress = try await advance(through: cut.highWatermark)
            guard progress.consumedThrough == cut.highWatermark else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            guard cut.roomControlVersion == appliedRoomControlVersion, cut.roomControlVersion >= requiredControlVersion else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            guard let member = cut.members.first, cut.members.count == 1, member.userID == userID,
                  member.authorized, member.memberRevision == attached else { throw V2RoomSubscriptionOwnerError.unauthorized }
            try await relay.seedAuthorizations(from: cut)
            let status = try requireStatus(await relay.status(for: descriptor.identity))
            guard status.fence == fence, !status.needsBaseline else { throw V2RoomSubscriptionOwnerError.stale }
            try checkDeadline()
            let bound = await pump.bind(.init(roomID: roomID, gateway: descriptor.identity), relay: relay,
                                        descriptor: descriptor, sourceShardID: owner.shardID)
            if bound {
                deliveryBindings[descriptor.identity] = pump
                activatedFences[descriptor.identity] = fence
            }
            return bound
        } catch { await failClosedIfNeeded(error); throw error }
    }

    /// A trusted permission-feed barrier retires old grants immediately, even
    /// while a message read owns the mutation turn. It performs no database read.
    package func observePermissionVersion(_ version: Int64, token: V2RoomActivationToken) async throws {
        guard !closed, token == activation else { throw V2RoomSubscriptionOwnerError.stale }
        guard version >= 0 else { throw V2RoomSubscriptionOwnerError.invalidInput }
        guard version > requiredControlVersion else { return }
        requiredControlVersion = version
        activatedFences.removeAll()
        activePermissionOperations += 1
        defer { activePermissionOperations -= 1; resumeCloseIfIdle() }
        try await relay.invalidateAuthorizations()
        await signalDelivery()
    }

    /// Resolve a changed durable control version at a complete fresh cut.
    /// Terminal invalidation is complete only after actual Gateway application
    /// (pump receipt), never merely starting or retaining a network call.
    package func processControlCut(expectedVersion: Int64, token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Bool {
        try enter(token: token, deadline: deadline); defer { leave() }
        guard expectedVersion >= 0 else { throw V2RoomSubscriptionOwnerError.invalidInput }
        if expectedVersion > appliedRoomControlVersion {
            let cut = try await source.snapshot(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs)
            guard cut.roomControlVersion >= max(expectedVersion, requiredControlVersion) else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
            let invalidated = try await relay.reconcileControlCut(cut, requireTerminal: cut.roomControlVersion > appliedRoomControlVersion && cut.membershipRevision == appliedMembershipRevision)
            if invalidated { activatedFences.removeAll(); changed = true }
            appliedRoomControlVersion = cut.roomControlVersion
            appliedMembershipRevision = cut.membershipRevision
        }
        return !(await relay.controlInvalidationPending())
    }

    /// Reuses the physical host's existing batched head check. Only an already
    /// consumed H is advertised, and only exact activated shared subscriptions
    /// participate. The advisory control cannot extend a lease or install Ready.
    package func refreshHeads(observedHighWatermark: UInt64, token: V2RoomActivationToken,
                              deadline: ContinuousClock.Instant) async throws {
        try enter(token: token, deadline: deadline); defer { leave() }
        let committed = await relay.committedSequence()
        guard observedHighWatermark <= committed else { throw V2RoomSubscriptionOwnerError.catchUpRequired }
        let active = Set(activatedFences.keys)
        changed = try await relay.refreshHeads(highWatermark: committed, gateways: active) || changed
    }

    /// Physical-host coalesced wake; bounded by this owner's gateway limit.
    public func signalDelivery() async {
        guard !closed else { return }
        for (gateway, pump) in deliveryBindings { await pump.signal(.init(roomID: roomID, gateway: gateway)) }
    }

    public func close() async throws {
        // Close admission immediately, then join the actual in-flight database
        // owner before invalidating its delivery responsibility.
        closed = true
        if busy || activePermissionOperations > 0 { await withCheckedContinuation { closeWaiters.append($0) } }
        await relay.invalidate()
        for gateway in gateways.keys { notifyChanged(gateway) }
        for (gateway, pump) in deliveryBindings { await pump.unbindAndJoin(.init(roomID: roomID, gateway: gateway)) }
        deliveryBindings.removeAll(); activatedFences.removeAll()
    }

    private func enter(token: V2RoomActivationToken, deadline: ContinuousClock.Instant) throws {
        guard token == activation else { throw V2RoomSubscriptionOwnerError.stale }
        guard deadline > .now else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
        guard !closed else { throw V2RoomSubscriptionOwnerError.closed }
        guard !busy else { throw V2RoomSubscriptionOwnerError.busy }
        busy = true; activeDeadline = deadline
    }
    private func leave() {
        if changed {
            // At most maximumGateways synchronous notifications per mutation.
            for gateway in gateways.keys { notifyChanged(gateway) }
            changed = false
        }
        busy = false; activeDeadline = nil
        resumeCloseIfIdle()
    }
    private func resumeCloseIfIdle() {
        guard !busy, activePermissionOperations == 0 else { return }
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func control(_ operation: V2RoomSubscriptionInput.Operation) async throws {
        try checkDeadline()
        guard nextInput < UInt64.max else { throw V2RoomSubscriptionOwnerError.overloaded }
        try await relay.offer(.init(ownerEpoch: owner.epoch, inputSequence: nextInput, operation: operation))
        nextInput += 1
    }
    private func requireStatus(_ status: V2RoomSubscriptionRelay.Status?) throws -> V2RoomSubscriptionRelay.Status {
        guard let status else { throw V2RoomSubscriptionOwnerError.stale }; return status
    }
    private func checkDeadline() throws {
        guard !closed else { throw V2RoomSubscriptionOwnerError.closed }
        guard let deadline = activeDeadline, deadline > .now else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
    }
    private func remainingLease(_ value: Int64, since started: ContinuousClock.Instant) -> Int64 {
        let elapsed = started.duration(to: .now).components
        let millis = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        guard millis.isFinite, millis < Double(value) else { return 0 }
        return value - Int64(millis.rounded(.up))
    }
    private func allocateGeneration() throws -> UInt64 {
        guard nextSubscriptionGeneration < UInt64.max else { throw V2RoomSubscriptionOwnerError.overloaded }
        let allocated = nextSubscriptionGeneration; nextSubscriptionGeneration += 1; return allocated
    }
    private func prune() async {
        let empty = Set(gateways.compactMap { $0.value.users.isEmpty ? $0.key : nil })
        let retired = await relay.retireEmptyGateways(empty)
        for gateway in retired {
            gateways.removeValue(forKey: gateway)
            activatedFences.removeValue(forKey: gateway)
            if let pump = deliveryBindings.removeValue(forKey: gateway) {
                await pump.unbindAndJoin(.init(roomID: roomID, gateway: gateway))
            }
        }
        let referenced = Set(gateways.values.flatMap { $0.users.keys })
        let unused = trackedUserIDs.subtracting(referenced)
        let forgotten = await relay.forgetAuthorizations(unused)
        trackedUserIDs.subtract(forgotten)
    }
    private func advance(through target: UInt64?) async throws -> DrainReport {
        var consumed = await relay.committedSequence(), observed = consumed
        if let target, target < consumed { throw V2RoomSubscriptionOwnerError.stale }
        for _ in 0..<maximumDrainPages {
            try checkDeadline()
            if let target, consumed == target { break }
            let page = try await source.read(roomID: roomID, owner: owner, afterRoomSequence: consumed,
                                             trackedUserIDs: trackedUserIDs, limit: pageSize)
            try checkDeadline()
            observed = page.highWatermark
            let records = target.map { cut in page.records.filter { $0.event.roomSequence <= cut } } ?? page.records
            let selected = V2RoomSubscriptionSourcePage(roomID: page.roomID, owner: page.owner,
                afterRoomSequence: page.afterRoomSequence, highWatermark: page.highWatermark, records: records)
            try await relay.ingest(selected)
            if !records.isEmpty { changed = true }
            let next = await relay.committedSequence()
            if next == consumed {
                guard observed == consumed || target == consumed else { throw V2RoomSubscriptionSourceError.snapshotRequired }
                break
            }
            consumed = next
            if consumed == observed { break }
        }
        return .init(consumedThrough: consumed, observedHighWatermark: observed)
    }
    private func failClosedIfNeeded(_ error: any Error) async {
        if error is V2RoomSubscriptionSourceError || error is V2RoomSubscriptionRelayError || error is V2RoomActivationLeaseError {
            closed = true; await relay.invalidate(); changed = true
        }
    }
}
