import Foundation
import IMV2Core
import IMV2ActorContracts

/// Trusted Directory resolution and signed RoomClient calls, injected without
/// introducing a Gateway -> Cluster implementation dependency.
public struct V2GatewayRoomSubscriptionPorts: Sendable {
    public struct Route: Sendable {
        public let activation: V2RoomActivationToken
        public let authenticatedServiceID: String
        public init(activation: V2RoomActivationToken, authenticatedServiceID: String) {
            self.activation = activation; self.authenticatedServiceID = authenticatedServiceID
        }
    }
    public let gateway: V2GatewayRealtimeDescriptor
    public let resolve: @Sendable (RoomID, ContinuousClock.Instant) async throws -> Route
    public let subscribe: @Sendable (V2RoomSubscriptionSubscribeCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult
    public let reset: @Sendable (V2RoomSubscriptionResetCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult
    public let activate: @Sendable (V2RoomSubscriptionActivateCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult
    public let unsubscribe: @Sendable (V2RoomSubscriptionUnsubscribeCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult
    public init(gateway: V2GatewayRealtimeDescriptor,
        resolve: @escaping @Sendable (RoomID, ContinuousClock.Instant) async throws -> Route,
        subscribe: @escaping @Sendable (V2RoomSubscriptionSubscribeCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult,
        reset: @escaping @Sendable (V2RoomSubscriptionResetCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult,
        activate: @escaping @Sendable (V2RoomSubscriptionActivateCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult,
        unsubscribe: @escaping @Sendable (V2RoomSubscriptionUnsubscribeCommand, V2RoomActivationToken, ContinuousClock.Instant) async throws -> V2RoomSubscriptionResult) {
        self.gateway = gateway; self.resolve = resolve; self.subscribe = subscribe
        self.reset = reset; self.activate = activate; self.unsubscribe = unsubscribe
    }
}

public enum V2GatewayRoomSubscriptionCoordinationError: Error, Sendable {
    case closed, overloaded, superseded, invalidGrant, deadlineExpired
    case refused(V2RoomSubscriptionFailure)
}

/// One reference-counted relation per room/user on this Gateway. The actual
/// local socket nonce remains Registry-owned and is rechecked after acquisition.
/// Last-reference retirement joins an in-flight prepare and compensates it;
/// a replacement relation waits for retirement before issuing another prepare.
public actor V2GatewayRoomSubscriptionCoordinator {
    private struct Key: Hashable, Sendable { let roomID: RoomID; let userID: UserID }
    private struct Receipt: Sendable {
        let grant: V2RoomSubscriptionGrant
        let route: V2GatewayRoomSubscriptionPorts.Route
        let activationFailure: (any Error)?
    }
    private struct Relation: Sendable {
        let id: UUID
        var references: Set<UUID>
        var acquisition: Task<Receipt, any Error>
        var receipt: Receipt?
        var retirement: Task<Void, Never>?
    }
    private let ports: V2GatewayRoomSubscriptionPorts
    private let ingress: V2GatewayRoomSubscriptionIngress
    private let maximumRelations: Int
    private let maximumReferences: Int
    private let maximumConcurrentCalls: Int
    private let maximumForegroundCalls: Int
    private let requestTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onCleanupFailure: @Sendable (RoomID, UserID, any Error) -> Void
    private var relations: [Key: Relation] = [:]
    private var references: [UUID: Key] = [:]
    private var keysByRoom: [RoomID: Set<Key>] = [:]
    private var sharedReceipts: [RoomID: Receipt] = [:]
    private var dueRooms = V2RoomRepairDeadlines()
    private var repairFlights: [UUID: Task<Void, Never>] = [:]
    private var repairingRooms: Set<RoomID> = []
    private var deniedRepresentatives: Set<Key> = []
    private var roomRepresentatives: [RoomID: Key] = [:]
    private var callWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextCallWaiter: UInt64 = 0
    private var firstCallWaiter: UInt64 = 0
    private var shutdownJoiners: [CheckedContinuation<Void, Never>] = []
    private var shutdownFinished = false
    private var routes: [RoomID: V2GatewayRoomSubscriptionPorts.Route] = [:]
    private struct RouteRecovery { var failures: Int; var retryAt: ContinuousClock.Instant }
    private var routeRecovery: [RoomID: RouteRecovery] = [:]
    private var calls = 0
    private var closed = false
    private var maintenance: Task<Void, Never>?
    private var maintenanceStarted = false
    private var wakeGeneration: UInt64 = 0
    private var scheduledWake: ContinuousClock.Instant?

    public init(ports: V2GatewayRoomSubscriptionPorts, ingress: V2GatewayRoomSubscriptionIngress,
        maximumRelations: Int = 4096, maximumReferences: Int = 16_384, maximumConcurrentCalls: Int = 16,
        requestTimeout: Duration = .seconds(5), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        onCleanupFailure: @escaping @Sendable (RoomID, UserID, any Error) -> Void = { _, _, _ in }) throws {
        try ports.gateway.validate()
        precondition(maximumRelations > 0 && maximumReferences > 0 && maximumConcurrentCalls > 0 && requestTimeout > .zero)
        self.ports = ports; self.ingress = ingress; self.maximumRelations = maximumRelations
        self.maximumReferences = maximumReferences; self.maximumConcurrentCalls = maximumConcurrentCalls
        self.maximumForegroundCalls = max(1, maximumConcurrentCalls / 2)
        self.requestTimeout = requestTimeout; self.now = now; self.onCleanupFailure = onCleanupFailure
    }
    public func start() {
        guard !closed, !maintenanceStarted else { return }
        maintenanceStarted = true
        scheduleMaintenance()
    }
    private func setDeadline(_ room: RoomID, at instant: ContinuousClock.Instant) {
        dueRooms.set(room, at: instant)
        scheduleMaintenance()
    }
    private func scheduleMaintenance() {
        guard maintenanceStarted, !closed else { return }
        let target = calls < maximumConcurrentCalls ? dueRooms.firstDeadline : nil
        guard target != scheduledWake else { return }
        maintenance?.cancel()
        wakeGeneration &+= 1
        scheduledWake = target
        guard let target else { maintenance = nil; return }
        let generation = wakeGeneration
        maintenance = Task {
            do { try await Task.sleep(until: target, clock: .continuous) } catch { return }
            guard !closed, generation == wakeGeneration else { return }
            scheduledWake = nil
            _ = await admitRepairs()
            scheduleMaintenance()
        }
    }

    public func acquire(roomID: RoomID, userID: UserID, reference: UUID) async throws -> V2RoomSubscriptionGrant {
        let key = Key(roomID: roomID, userID: userID)
        guard !closed else { throw V2GatewayRoomSubscriptionCoordinationError.closed }
        if let existing = references[reference], existing != key { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
        // Do not overlap an unsubscribe with a successor subscribe for this user.
        while let retirement = relations[key]?.retirement {
            await retirement.value
            guard !closed else { throw V2GatewayRoomSubscriptionCoordinationError.closed }
        }
        guard references[reference] != nil || references.count < maximumReferences else {
            throw V2GatewayRoomSubscriptionCoordinationError.overloaded
        }
        if relations[key] == nil {
            guard relations.count < maximumRelations else {
                throw V2GatewayRoomSubscriptionCoordinationError.overloaded
            }
            let id = UUID()
            let task = Task { try await self.prepareWhenAdmitted(key, relationID: id) }
            relations[key] = Relation(id: id, references: [reference], acquisition: task)
            keysByRoom[roomID, default: []].insert(key)
        } else {
            let wasReferenced = references[reference] != nil
            let observedRelationID = relations[key]!.id
            relations[key]?.references.insert(reference)
            references[reference] = key
            if let previous = relations[key]?.receipt {
                let checkpoint = await ingress.authority.authorizationCheckpoint(fence: previous.grant.fence,
                    serviceID: previous.route.authenticatedServiceID)
                let revision = await ingress.authority.authorizedMemberRevision(roomID: roomID, userID: userID)
                guard !closed, relations[key]?.id == observedRelationID,
                      relations[key]?.retirement == nil, references[reference] == key,
                      relations[key]?.references.contains(reference) == true else {
                    throw V2GatewayRoomSubscriptionCoordinationError.superseded
                }
                if checkpoint != nil, revision != previous.grant.memberRevision {
                // A new device may share a currently authorized user grant;
                // it cannot resurrect a membership revision removed by control.
                guard calls < maximumForegroundCalls else {
                    if !wasReferenced { relations[key]?.references.remove(reference); references.removeValue(forKey: reference) }
                    throw V2GatewayRoomSubscriptionCoordinationError.overloaded
                }
                let id = relations[key]!.id; calls += 1
                relations[key]?.acquisition = Task { try await self.prepare(key, relationID: id) }
                }
            }
        }
        references[reference] = key
        guard !closed, let relation = relations[key], relation.references.contains(reference), relation.retirement == nil else {
            throw V2GatewayRoomSubscriptionCoordinationError.superseded
        }
        do {
            let acquired = try await relation.acquisition.value
            let cached = relations[key]?.receipt
            var receipt: Receipt
            if let cached, cached.grant.fence != acquired.grant.fence,
               (cached.grant.fence.activation.isNewer(than: acquired.grant.fence.activation)
                || (cached.grant.fence.activation == acquired.grant.fence.activation
                    && cached.grant.fence.generation > acquired.grant.fence.generation)) {
                receipt = cached
            } else { receipt = acquired }
            guard !closed, relations[key]?.id == relation.id, references[reference] == key,
                  relations[key]?.references.contains(reference) == true else {
                throw V2GatewayRoomSubscriptionCoordinationError.superseded
            }
            relations[key]?.receipt = receipt
            if receipt.activationFailure == nil { await retainShared(receipt) }
            if let error = receipt.activationFailure { throw error }
            guard ingress.authority.sessionGate(receipt.grant.deliverySession, serviceID: receipt.route.authenticatedServiceID)?.isReady(at: now()) == true else { throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant }
            return receipt.grant
        } catch {
            recordAcquisitionFailure(error)
            await release(reference: reference)
            throw error
        }
    }
    public func release(reference: UUID) async {
        guard let key = references.removeValue(forKey: reference), var relation = relations[key] else { return }
        relation.references.remove(reference); relations[key] = relation
        guard relation.references.isEmpty else { return }
        let task = startRetirement(key, relation: relation)
        await task.value
    }
    private func recordAcquisitionFailure(_ error: any Error) {
        let stage: V2RoomSubscriptionHeadDeliveryMetrics.Stage
        switch error {
        case V2GatewayRoomSubscriptionCoordinationError.deadlineExpired: stage = .acquisitionDeadlineExpired
        case V2GatewayRoomSubscriptionCoordinationError.invalidGrant: stage = .acquisitionInvalidGrant
        case V2GatewayRoomSubscriptionCoordinationError.superseded: stage = .acquisitionSuperseded
        case V2GatewayRoomSubscriptionCoordinationError.refused(let reason):
            switch reason {
            case .unavailable: stage = .acquisitionRemoteUnavailable
            case .overloaded: stage = .acquisitionRemoteOverloaded
            case .stale: stage = .acquisitionRemoteStale
            case .unauthorized: stage = .acquisitionRemoteUnauthorized
            case .invalidRequest: stage = .acquisitionRemoteInvalidRequest
            }
        case let failure as V2RoomCallFailure:
            switch failure {
            case .outcomeUnknown: stage = .acquisitionCallOutcomeUnknown
            case .notAccepted(let reason), .rolledBack(let reason):
                switch reason {
                case .deadlineExceeded: stage = .acquisitionCallDeadlineExceeded
                case .overloaded: stage = .acquisitionCallOverloaded
                case .unavailable: stage = .acquisitionCallUnavailable
                case .invalidRequest: stage = .acquisitionCallInvalidRequest
                case .staleActivation, .notReady, .retired, .authorityLost: stage = .acquisitionCallStale
                default: stage = .acquisitionOtherFailure
                }
            }
        default: stage = .acquisitionOtherFailure
        }
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(stage)
    }
    private func startRetirement(_ key: Key, relation: Relation) -> Task<Void, Never> {
        if let existing = relations[key]?.retirement { return existing }
        let task = Task { await self.retire(key, relation: relation) }
        relations[key]?.retirement = task
        return task
    }
    /// The admitted relation bounds this wait and owns its actual acquisition.
    /// FIFO foreground waiters share a bounded slice of the total call budget.
    /// They cannot consume the slots reserved for failure recovery.
    private func prepareWhenAdmitted(_ key: Key, relationID: UUID) async throws -> Receipt {
        if calls >= maximumConcurrentCalls {
            V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.acquisitionQueued)
        }
        await takeCallSlot()
        guard hasReferences(key, relationID: relationID) else {
            releaseCallSlot(); throw V2GatewayRoomSubscriptionCoordinationError.superseded
        }
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.acquisitionAdmitted)
        return try await prepare(key, relationID: relationID)
    }
    private func prepare(_ key: Key, relationID: UUID, releasesCallSlot: Bool = true) async throws -> Receipt {
        defer { if releasesCallSlot { releaseCallSlot() } }
        let callDeadline = now() + requestTimeout
        if let recovery = routeRecovery[key.roomID], recovery.retryAt > now(), routes[key.roomID] == nil {
            throw V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable)
        }
        if let recovery = routeRecovery[key.roomID], recovery.retryAt <= now() {
            // A failed call proves no rollback. Directory confirms the current
            // activation before a replacement route can issue a fresh subscription.
            routes.removeValue(forKey: key.roomID)
        }
        var route: V2GatewayRoomSubscriptionPorts.Route
        if let existing = routes[key.roomID] { route = existing }
        else {
            do { route = try await ports.resolve(key.roomID, callDeadline) }
            catch { scheduleRouteConfirmation(key.roomID); throw error }
            routes[key.roomID] = route
        }
        guard route.activation.roomID == key.roomID, !route.authenticatedServiceID.isEmpty,
              route.authenticatedServiceID.utf8.count <= 128 else {
            throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
        }
        let command = V2RoomSubscriptionSubscribeCommand(roomID: key.roomID, actorUserID: key.userID,
            gatewayDescriptor: ports.gateway)
        var result: V2RoomSubscriptionResult
        do { result = try await ports.subscribe(command, route.activation, callDeadline) }
        catch V2RoomActorStateError.activationChanged { result = .failure(.stale) }
        catch V2RoomActorStateError.ownerChanged { result = .failure(.stale) }
        catch {
            if Self.provesInvalidActivation(error) { result = .failure(.stale) }
            else { noteRouteFailure(error, roomID: key.roomID, activation: route.activation); throw error }
        }
        if case .failure(.stale) = result {
            // Only explicit activation rejection retries this call immediately.
            // A concurrent prepare may already have installed the newer route.
            if let newer = routes[key.roomID], newer.activation != route.activation {
                route = newer
            } else {
                routes.removeValue(forKey: key.roomID)
                do { route = try await ports.resolve(key.roomID, callDeadline) }
                catch { scheduleRouteConfirmation(key.roomID); throw error }
            }
            guard route.activation.roomID == key.roomID, !route.authenticatedServiceID.isEmpty,
                  route.authenticatedServiceID.utf8.count <= 128 else {
                throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
            }
            routes[key.roomID] = route
            do { result = try await ports.subscribe(command, route.activation, callDeadline) }
            catch { noteRouteFailure(error, roomID: key.roomID, activation: route.activation); throw error }
        }
        var grant: V2RoomSubscriptionGrant
        switch result {
        case .granted(let value): grant = value
        case .failure(let reason): throw V2GatewayRoomSubscriptionCoordinationError.refused(reason)
        default: throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
        }
        var resetValidated = false
        do {
        if await ingress.authority.requiresBaseline(fence: grant.fence) {
            guard hasReferences(key, relationID: relationID) else { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
            let reset = try await ports.reset(.init(roomID: key.roomID, actorUserID: key.userID,
                gatewayDescriptor: ports.gateway, expectedFence: grant.fence), route.activation, callDeadline)
            switch reset {
            case .granted(let replacement):
                guard replacement.fence.activation == grant.fence.activation,
                      replacement.fence.generation > grant.fence.generation,
                      replacement.fence.subscriptionID != grant.fence.subscriptionID else {
                    throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
                }
                grant = replacement
                resetValidated = true
            case .failure(let reason): throw V2GatewayRoomSubscriptionCoordinationError.refused(reason)
            default: throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
            }
        }
        } catch {
            noteRouteFailure(error, roomID: key.roomID, activation: route.activation)
            return Receipt(grant: grant, route: route,
                activationFailure: error)
        }
        try grant.fence.validate()
        guard grant.fence.activation == route.activation, grant.memberRevision <= UInt64(Int64.max),
              grant.userBaselineSequence >= grant.fence.baselineSequence,
              grant.userBaselineSequence <= UInt64(Int64.max),
              grant.deliverySession.host == route.activation.host && grant.deliverySession.gateway == ports.gateway.identity else {
            throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
        }
        try grant.deliverySession.validate()
        var activationFailure: (any Error)?
        do {
            guard hasReferences(key, relationID: relationID) else {
                return Receipt(grant: grant, route: route,
                    activationFailure: V2GatewayRoomSubscriptionCoordinationError.superseded)
            }
            guard await ingress.install(fence: grant.fence, sourceShardID: route.activation.owner.shardID,
                serviceID: route.authenticatedServiceID, session: grant.deliverySession,
                afterAuthoritativeReset: resetValidated) else {
                throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
            }
            guard hasReferences(key, relationID: relationID) else { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
            let activation = try await ports.activate(.init(roomID: key.roomID, actorUserID: key.userID,
                gatewayDescriptor: ports.gateway, fence: grant.fence), route.activation, callDeadline)
            guard case .activated = activation else {
                if case .failure(let reason) = activation { throw V2GatewayRoomSubscriptionCoordinationError.refused(reason) }
                throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
            }

        } catch {
            noteRouteFailure(error, roomID: key.roomID, activation: route.activation)
            activationFailure = error
        }
        if activationFailure == nil { routeRecovery.removeValue(forKey: key.roomID) }
        return Receipt(grant: grant, route: route, activationFailure: activationFailure)
    }
    private static func provesInvalidActivation(_ error: any Error) -> Bool {
        switch error {
        case V2RoomActorStateError.activationChanged, V2RoomActorStateError.ownerChanged: return true
        case V2RoomCallFailure.notAccepted(.staleActivation), V2RoomCallFailure.notAccepted(.retired),
             V2RoomCallFailure.notAccepted(.authorityLost), V2RoomCallFailure.rolledBack(.staleActivation),
             V2RoomCallFailure.rolledBack(.retired), V2RoomCallFailure.rolledBack(.authorityLost): return true
        default: return false
        }
    }
    private func noteRouteFailure(_ error: any Error, roomID: RoomID, activation: V2RoomActivationToken) {
        guard routes[roomID]?.activation == activation else { return }
        if Self.provesInvalidActivation(error) {
            routes.removeValue(forKey: roomID)
            routeRecovery.removeValue(forKey: roomID)
            return
        }
        let uncertain: Bool
        switch error {
        case V2RoomCallFailure.outcomeUnknown, V2RoomCallFailure.notAccepted(.notReady),
             V2RoomCallFailure.notAccepted(.unavailable), V2RoomCallFailure.rolledBack(.notReady),
             V2RoomCallFailure.rolledBack(.unavailable): uncertain = true
        default: uncertain = false
        }
        guard uncertain else { return }
        scheduleRouteConfirmation(roomID)
    }
    private func scheduleRouteConfirmation(_ roomID: RoomID) {
        if let pending = routeRecovery[roomID], pending.retryAt > now() { return }
        let failures = min(6, (routeRecovery[roomID]?.failures ?? 0) + 1)
        routeRecovery[roomID] = .init(failures: failures,
            retryAt: now() + .seconds(min(30, 1 << (failures - 1))))
    }
    private func hasReferences(_ key: Key, relationID: UUID) -> Bool {
        !closed && relations[key]?.id == relationID && relations[key]?.references.isEmpty == false
    }
    private func retire(_ key: Key, relation: Relation) async {
        var acquiredFence = relation.receipt?.grant.fence
        defer {
            if relations[key]?.id == relation.id {
                relations.removeValue(forKey: key); keysByRoom[key.roomID]?.remove(key); deniedRepresentatives.remove(key)
            }
            if keysByRoom[key.roomID]?.isEmpty == true {
                // Last local interest ends socket authority.
                // Exact-fence retirement cannot invalidate a newer installation; keep
                // the fence history to reject delayed controls and old writes.
                if let fence = sharedReceipts[key.roomID]?.grant.fence ?? acquiredFence {
                    _ = await ingress.retire(fence: fence)
                }
                keysByRoom.removeValue(forKey: key.roomID)
                routes.removeValue(forKey: key.roomID); routeRecovery.removeValue(forKey: key.roomID)
                sharedReceipts.removeValue(forKey: key.roomID); dueRooms.remove(key.roomID)
                roomRepresentatives.removeValue(forKey: key.roomID)
            }
        }
        let receipt: Receipt
        do { receipt = try await relation.acquisition.value; acquiredFence = receipt.grant.fence }
        catch { onCleanupFailure(key.roomID, key.userID, error); return }
        await takeCallSlot()
        defer { releaseCallSlot() }
        do {
            let result = try await ports.unsubscribe(.init(roomID: key.roomID, actorUserID: key.userID,
                gatewayDescriptor: ports.gateway, memberRevision: receipt.grant.memberRevision),
                receipt.route.activation, now() + requestTimeout)
            guard case .unsubscribed = result else {
                // Authoritative membership invalidation may already have removed
                // this exact revision. It does not authorize a replacement.
                if case .failure(.stale) = result { return }
                if case .failure(let reason) = result { throw V2GatewayRoomSubscriptionCoordinationError.refused(reason) }
                throw V2GatewayRoomSubscriptionCoordinationError.invalidGrant
            }
        } catch { onCleanupFailure(key.roomID, key.userID, error) }
    }
    /// Signed control retirement schedules the existing bounded maintenance
    /// owner immediately; it never grants authority or starts a per-packet task.
    public func requestBaselineIfRequired(roomID: RoomID) async {
        guard !closed, let receipt = sharedReceipts[roomID],
              await ingress.authority.requiresBaseline(fence: receipt.grant.fence) else { return }
        guard !closed, sharedReceipts[roomID]?.grant.fence == receipt.grant.fence else { return }
        setDeadline(roomID, at: now())
    }


    private func retainShared(_ receipt: Receipt) async {
        let room = receipt.grant.fence.roomID
        if let old = sharedReceipts[room], old.grant.fence.activation.isNewer(than: receipt.grant.fence.activation)
            || (old.grant.fence.activation == receipt.grant.fence.activation && old.grant.fence.generation > receipt.grant.fence.generation) { return }
        sharedReceipts[room] = receipt
        let needsBaseline = await ingress.authority.requiresBaseline(fence: receipt.grant.fence)
        guard !closed, sharedReceipts[room]?.grant.fence == receipt.grant.fence,
              sharedReceipts[room]?.grant.deliverySession == receipt.grant.deliverySession else { return }
        if needsBaseline { setDeadline(room, at: now()) }
    }
    private func representative(_ room: RoomID) async -> Key? {
        func eligible(_ key: Key) -> Bool {
            !deniedRepresentatives.contains(key) && relations[key]?.retirement == nil && relations[key]?.references.isEmpty == false
        }
        if let cached = roomRepresentatives[room], eligible(cached) {
            let live: Bool
            if let receipt = sharedReceipts[room] {
                live = await ingress.authority.authorizationCheckpoint(fence: receipt.grant.fence,
                    serviceID: receipt.route.authenticatedServiceID) != nil
            } else { live = false }
            guard !closed else { return nil }
            if !live, eligible(cached) { return cached }
            let revision = await ingress.authority.authorizedMemberRevision(roomID: room, userID: cached.userID)
            if !closed, revision != nil, eligible(cached) { return cached }
        }
        var fallback: Key?
        for key in keysByRoom[room] ?? [] where eligible(key) {
            if fallback == nil { fallback = key }
            let revision = await ingress.authority.authorizedMemberRevision(roomID: room, userID: key.userID)
            guard !closed else { return nil }
            if revision != nil, eligible(key) { roomRepresentatives[room] = key; return key }
        }
        if let fallback, eligible(fallback), !closed { roomRepresentatives[room] = fallback; return fallback }
        roomRepresentatives.removeValue(forKey: room); return nil
    }
    private func takeCallSlot() async {
        if calls < maximumForegroundCalls { calls += 1; return }
        await withCheckedContinuation {
            callWaiters[nextCallWaiter] = $0; nextCallWaiter += 1
        }
    }
    private func releaseCallSlot() {
        defer { scheduleMaintenance() }
        calls -= 1
        if calls < maximumForegroundCalls, let waiter = callWaiters.removeValue(forKey: firstCallWaiter) {
            calls += 1
            firstCallWaiter += 1; waiter.resume()
            if callWaiters.isEmpty { firstCallWaiter = 0; nextCallWaiter = 0 }
        }
    }
    /// Only failures and explicit control invalidations enqueue recovery.
    public func sessionChanged(host: V2ActorHostIdentity) async {
        guard !closed else { return }
        for (room, receipt) in sharedReceipts where receipt.route.activation.host == host {
            if ingress.authority.sessionGate(receipt.grant.deliverySession, serviceID: receipt.route.authenticatedServiceID)?.isReady(at: now()) != true {
                setDeadline(room, at: now())
            }
        }
    }
    private var admittingRepairs = false
    private func admitRepairs() async -> [Task<Void, Never>] {
        guard !closed, !admittingRepairs else { return [] }
        admittingRepairs = true; defer { admittingRepairs = false }
        var admitted: [Task<Void, Never>] = []
        let cut = now()
        while !closed, calls < maximumConcurrentCalls, let room = dueRooms.popDue(at: cut) {
            guard !repairingRooms.contains(room), let key = await representative(room), let relation = relations[key] else { continue }
            if let pending = routeRecovery[room], pending.retryAt > cut { setDeadline(room, at: pending.retryAt); continue }
            guard calls < maximumConcurrentCalls else { setDeadline(room, at: cut); break }
            calls += 1; repairingRooms.insert(room)
            let flightID = UUID()
            let task = Task { await self.rebuildRoom(key, relationID: relation.id, flightID: flightID) }
            repairFlights[flightID] = task; admitted.append(task)
        }
        return admitted
    }
    private func rebuildRoom(_ key: Key, relationID: UUID, flightID: UUID) async {
        defer {
            releaseCallSlot()
            repairingRooms.remove(key.roomID)
            repairFlights.removeValue(forKey: flightID)
            scheduleMaintenance()
        }
        guard hasReferences(key, relationID: relationID) else { return }
        // A replacement Owner has no inherited user registrations. Every live
        // relation must obtain its own grant; a shared fence is not that proof.
        let members = (keysByRoom[key.roomID] ?? []).compactMap { member -> (Key, UUID)? in
            guard let relation = relations[member], relation.retirement == nil,
                  !relation.references.isEmpty else { return nil }
            return (member, relation.id)
        }
        for (member, id) in members {
            guard hasReferences(member, relationID: id) else { continue }
            let task = Task { try await self.prepare(member, relationID: id, releasesCallSlot: false) }
            relations[member]?.acquisition = task
            do {
                let receipt = try await task.value
                guard hasReferences(member, relationID: id) else { continue }
                relations[member]?.receipt = receipt
                if let failure = receipt.activationFailure { throw failure }
                deniedRepresentatives.remove(member)
                await retainShared(receipt)
            } catch {
                onCleanupFailure(member.roomID, member.userID, error)
                if case V2GatewayRoomSubscriptionCoordinationError.refused(.unauthorized) = error {
                    deniedRepresentatives.insert(member)
                    continue
                }
                // Retry the complete registration after a partial failure.
                scheduleRouteConfirmation(key.roomID)
                if await representative(key.roomID) != nil {
                    setDeadline(key.roomID, at: routeRecovery[key.roomID]?.retryAt ?? now() + .seconds(1))
                }
                return
            }
        }
    }
    public func shutdown() async {
        if closed {
            if !shutdownFinished { await withCheckedContinuation { shutdownJoiners.append($0) } }
            return
        }
        closed = true; maintenance?.cancel(); dueRooms.removeAll()
        for receipt in sharedReceipts.values { _ = await ingress.authority.pause(fence: receipt.grant.fence) }
        references.removeAll()
        let retained = relations
        for (key, var relation) in retained {
            relation.references.removeAll(); relations[key] = relation
            _ = startRetirement(key, relation: relation)
        }
        let retirements = relations.values.compactMap(\.retirement)
        let flights = Array(repairFlights.values)
        for flight in flights { await flight.value }
        for retirement in retirements { await retirement.value }
        await maintenance?.value
        shutdownFinished = true
        let joiners = shutdownJoiners; shutdownJoiners.removeAll()
        for joiner in joiners { joiner.resume() }
    }
    public var relationCount: Int { relations.count }
    public var referenceCount: Int { references.count }
}

/// Exactly one deadline node per active room; no stale tombstones or full sweep.
private struct V2RoomRepairDeadlines {
    private struct Node { let room: RoomID; var at: ContinuousClock.Instant }
    private var nodes: [Node] = []
    private var positions: [RoomID: Int] = [:]
    var firstDeadline: ContinuousClock.Instant? { nodes.first?.at }
    mutating func set(_ room: RoomID, at: ContinuousClock.Instant) {
        if let index = positions[room] {
            let old = nodes[index].at; nodes[index].at = at
            if at < old { up(index) } else { down(index) }
        } else {
            positions[room] = nodes.count; nodes.append(.init(room: room, at: at)); up(nodes.count - 1)
        }
    }
    mutating func popDue(at now: ContinuousClock.Instant) -> RoomID? {
        guard let node = nodes.first, node.at <= now else { return nil }
        remove(node.room); return node.room
    }
    mutating func remove(_ room: RoomID) {
        guard let index = positions[room] else { return }
        swap(index, nodes.count - 1); nodes.removeLast(); positions.removeValue(forKey: room)
        if index < nodes.count {
            if index > 0, nodes[index].at < nodes[(index - 1) / 2].at { up(index) } else { down(index) }
        }
    }
    mutating func removeAll() { nodes.removeAll(); positions.removeAll() }
    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        nodes.swapAt(lhs, rhs); positions[nodes[lhs].room] = lhs; positions[nodes[rhs].room] = rhs
    }
    private mutating func up(_ start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard nodes[index].at < nodes[parent].at else { break }
            swap(index, parent); index = parent
        }
    }
    private mutating func down(_ start: Int) {
        var index = start
        while index * 2 + 1 < nodes.count {
            var child = index * 2 + 1
            if child + 1 < nodes.count, nodes[child + 1].at < nodes[child].at { child += 1 }
            guard nodes[child].at < nodes[index].at else { break }
            swap(index, child); index = child
        }
    }
}
