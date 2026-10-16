import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerApplication

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
    /// A shared result is retained before admission; it owns no executable task.
    /// Cancelling a caller removes only that caller's waiter, not another reference's RPC.
    private final class Acquisition: Sendable {
        private struct State: Sendable {
            var result: Result<Receipt, any Error>?
            var waiters: [UUID: CheckedContinuation<Receipt, any Error>] = [:]
            var cancelled: Set<UUID> = []
        }
        private let state = Mutex(State())
        func finish(_ result: Result<Receipt, any Error>) {
            let waiters = state.withLock { value -> [CheckedContinuation<Receipt, any Error>] in
                precondition(value.result == nil)
                value.result = result
                let waiters = Array(value.waiters.values)
                value.waiters.removeAll(); value.cancelled.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume(with: result) }
        }
        func wait(cancellable: Bool = false) async throws -> Receipt {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = state.withLock { value -> Result<Receipt, any Error>? in
                        if cancellable && (value.cancelled.remove(id) != nil || Task.isCancelled) {
                            return .failure(CancellationError())
                        }
                        if let result = value.result { return result }
                        value.waiters[id] = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                guard cancellable else { return }
                let waiter = self.state.withLock { value -> CheckedContinuation<Receipt, any Error>? in
                    guard value.result == nil else { return nil }
                    if let waiter = value.waiters.removeValue(forKey: id) { return waiter }
                    value.cancelled.insert(id)
                    return nil
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
    private struct PendingAcquisition: Sendable {
        let key: Key
        let relationID: UUID
        let id: UUID
        let deadline: ContinuousClock.Instant
        let completion: Acquisition
        let refresh: Bool
    }
    private struct Relation: Sendable {
        let id: UUID
        var references: Set<UUID>
        var acquisition: Acquisition
        var receipt: Receipt?
        var refreshID: UUID?
        var retirement: Task<Void, Never>?
    }
    private let ports: V2GatewayRoomSubscriptionPorts
    private let ingress: V2GatewayRoomSubscriptionIngress
    private let maximumRelations: Int
    private let maximumReferences: Int
    private let maximumConcurrentCalls: Int
    private let maximumForegroundCalls: Int
    private let requestTimeout: Duration
    private let metrics: V2RoomSubscriptionHeadDeliveryMetrics
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onCleanupFailure: @Sendable (RoomID, UserID, any Error) -> Void
    private var relations: [Key: Relation] = [:]
    // A last relation leaves its index before its socket fence has retired.
    // Retain the actual task across that gap, for every user of this room.
    private var roomRetirements: [RoomID: Task<Void, Never>] = [:]
    private var references: [UUID: Key] = [:]
    private var keysByRoom: [RoomID: Set<Key>] = [:]
    private var sharedReceipts: [RoomID: Receipt] = [:]
    private var dueRooms = V2IndexedDeadlines<RoomID>()
    private var cooldownDeadlines = V2IndexedDeadlines<RoomID>()
    private var repairFlights: [UUID: Task<Void, Never>] = [:]
    private var repairingRooms: Set<RoomID> = []
    // At most one follow-up per executing room. Keep it outside the ready heap:
    // a spare maintenance slot must not consume a wake owned by a live flight.
    private var deferredRepairs: [RoomID: ContinuousClock.Instant] = [:]
    private var deniedRepresentatives: Set<Key> = []
    private var roomRepresentatives: [RoomID: Key] = [:]
    private struct CallWaiter: Sendable {
        enum Work: Sendable {
            case slot(CheckedContinuation<Void, any Error>)
            case acquisition(PendingAcquisition)
        }
        let id: UUID
        let deadline: ContinuousClock.Instant
        let allowsClosed: Bool
        let work: Work
        let queued: V2RoomSubscriptionHeadDeliveryMetrics.Measurement?
    }
    private var callWaiters = V2IndexedFIFO<UUID, CallWaiter>()
    private var callDeadlines = V2IndexedDeadlines<UUID>()
    private var pendingAcquisitions: Set<UUID> = []
    private var acquisitionTasks: [UUID: Task<Void, Never>] = [:]
    private var maximumPendingAcquisitions: Int { maximumConcurrentCalls * 32 }
    private var shutdownJoiners: [CheckedContinuation<Void, Never>] = []
    private var shutdownFinished = false
    private var routes: [RoomID: V2GatewayRoomSubscriptionPorts.Route] = [:]
    private struct RouteRecovery { var failures: Int; var retryAt: ContinuousClock.Instant }
    private var routeRecovery: [RoomID: RouteRecovery] = [:]
    private var calls = 0
    private var foregroundCalls = 0
    private var maximumMaintenanceCalls: Int { max(1, maximumConcurrentCalls - maximumForegroundCalls) }
    private var canAdmitForeground: Bool { foregroundCalls < maximumForegroundCalls && calls < maximumConcurrentCalls }
    private var canAdmitMaintenance: Bool { calls - foregroundCalls < maximumMaintenanceCalls && calls < maximumConcurrentCalls }
    private var closed = false
    private var maintenance: Task<Void, Never>?
    private var maintenanceStarted = false
    private var wakeGeneration: UInt64 = 0
    private var scheduledWake: ContinuousClock.Instant?

    public init(ports: V2GatewayRoomSubscriptionPorts, ingress: V2GatewayRoomSubscriptionIngress,
        maximumRelations: Int = 4096, maximumReferences: Int = 16_384, maximumConcurrentCalls: Int = 16,
        requestTimeout: Duration = .seconds(5), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        onCleanupFailure: @escaping @Sendable (RoomID, UserID, any Error) -> Void = { _, _, _ in },
        metrics: V2RoomSubscriptionHeadDeliveryMetrics = .shared) throws {
        try ports.gateway.validate()
        precondition(maximumRelations > 0 && maximumReferences > 0 && maximumConcurrentCalls > 0 && requestTimeout > .zero)
        self.ports = ports; self.ingress = ingress; self.maximumRelations = maximumRelations
        self.maximumReferences = maximumReferences; self.maximumConcurrentCalls = maximumConcurrentCalls
        self.maximumForegroundCalls = max(1, maximumConcurrentCalls / 2)
        self.requestTimeout = requestTimeout; self.now = now; self.onCleanupFailure = onCleanupFailure
        self.metrics = metrics
    }
    public func start() {
        guard !closed, !maintenanceStarted else { return }
        maintenanceStarted = true
        scheduleMaintenance()
    }
    private func setDeadline(_ room: RoomID, at instant: ContinuousClock.Instant) {
        if repairingRooms.contains(room) {
            deferredRepairs[room] = min(deferredRepairs[room] ?? instant, instant)
            return
        }
        dueRooms.set(room, at: instant)
        scheduleMaintenance()
    }
    private func scheduleMaintenance() {
        guard !closed else { return }
        let repair = maintenanceStarted && canAdmitMaintenance ? dueRooms.firstDeadline : nil
        let target = [repair, callDeadlines.firstDeadline, cooldownDeadlines.firstDeadline].compactMap { $0 }.min()
        guard target != scheduledWake else { return }
        maintenance?.cancel()
        wakeGeneration &+= 1
        scheduledWake = target
        guard let target else { maintenance = nil; return }
        let generation = wakeGeneration
        maintenance = Task {
            do { try await Task.sleep(until: target, clock: .continuous) } catch { return }
            guard !closed, generation == wakeGeneration else { return }
            scheduledWake = nil; maintenance = nil
            expireWaitersAndCooldowns()
            admitRepairs()
            scheduleMaintenance()
        }
    }

    public func acquire(roomID: RoomID, userID: UserID, reference: UUID) async throws -> V2RoomSubscriptionGrant {
        let key = Key(roomID: roomID, userID: userID)
        guard !closed else { throw V2GatewayRoomSubscriptionCoordinationError.closed }
        if let existing = references[reference], existing != key { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
        // Join both a same-user unsubscribe and a last-room projection close
        // before a successor can prepare another use of that room's fence.
        while let retirement = roomRetirements[roomID] ?? relations[key]?.retirement {
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
            guard pendingAcquisitions.count < maximumPendingAcquisitions else {
                throw V2GatewayRoomSubscriptionCoordinationError.overloaded
            }
            let id = UUID(), deadline = now() + requestTimeout
            pendingAcquisitions.insert(id)
            let completion = Acquisition()
            relations[key] = Relation(id: id, references: [reference], acquisition: completion)
            keysByRoom[roomID, default: []].insert(key)
            enqueueAcquisition(.init(key: key, relationID: id, id: id, deadline: deadline,
                completion: completion, refresh: false))
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
                let sessionReady = ingress.authority.sessionGate(previous.grant.deliverySession,
                    serviceID: previous.route.authenticatedServiceID)?.isReady() == true
                if relations[key]?.receipt?.grant == previous.grant,
                   !sessionReady || (checkpoint != nil && revision != previous.grant.memberRevision),
                   relations[key]?.refreshID == nil {
                    // An expired shared session cannot be repaired by replaying
                    // a completed acquisition. All callers join one fresh flight.
                    guard pendingAcquisitions.count < maximumPendingAcquisitions else {
                        if !wasReferenced { relations[key]?.references.remove(reference); references.removeValue(forKey: reference) }
                        throw V2GatewayRoomSubscriptionCoordinationError.overloaded
                    }
                    let id = UUID(), deadline = now() + requestTimeout
                    pendingAcquisitions.insert(id)
                    relations[key]?.refreshID = id
                    let completion = Acquisition()
                    relations[key]?.acquisition = completion
                    enqueueAcquisition(.init(key: key, relationID: observedRelationID, id: id,
                        deadline: deadline, completion: completion, refresh: true))
                }
            }
        }
        references[reference] = key
        guard !closed, let relation = relations[key], relation.references.contains(reference), relation.retirement == nil else {
            throw V2GatewayRoomSubscriptionCoordinationError.superseded
        }
        do {
            let acquired = try await relation.acquisition.wait(cancellable: true)
            try Task.checkCancellation()
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
            guard ingress.authority.sessionGate(receipt.grant.deliverySession, serviceID: receipt.route.authenticatedServiceID)?.isReady() == true else { throw invalidGrant(.acquisitionSessionNotReady) }
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
        cancelCallWaiter(relation.refreshID ?? relation.id, error: V2GatewayRoomSubscriptionCoordinationError.superseded)
        let task = startRetirement(key, relation: relation)
        await task.value
    }
    private func invalidGrant(_ stage: V2RoomSubscriptionHeadDeliveryMetrics.Stage) -> V2GatewayRoomSubscriptionCoordinationError {
        V2RoomSubscriptionHeadDeliveryMetrics.shared.record(stage)
        return .invalidGrant
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
                case .roomCapacityExhausted: stage = .acquisitionCallCapacityExhausted
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
    /// Enqueue data in the same FIFO as cleanup calls. Only a granted slot
    /// creates an actual RPC task; queue time is part of the original deadline.
    private func enqueueAcquisition(_ job: PendingAcquisition) {
        expireWaitersAndCooldowns()
        if !canAdmitForeground || !callWaiters.isEmpty {
            V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.acquisitionQueued)
        }
        callWaiters.append(.init(id: job.id, deadline: job.deadline, allowsClosed: false,
            work: .acquisition(job), queued: metrics.begin(.queue, at: now())), key: job.id)
        callDeadlines.set(job.id, at: job.deadline)
        admitForeground()
        scheduleMaintenance()
    }
    private func finishQueuedAcquisition(_ job: PendingAcquisition, error: any Error) {
        pendingAcquisitions.remove(job.id)
        if relations[job.key]?.id == job.relationID, relations[job.key]?.refreshID == job.id {
            relations[job.key]?.refreshID = nil
        }
        job.completion.finish(.failure(error))
    }
    private func executeAcquisition(_ job: PendingAcquisition, foreground: Bool,
        admitted: (slot: V2RoomSubscriptionHeadDeliveryMetrics.Measurement,
                   taskStart: V2RoomSubscriptionHeadDeliveryMetrics.Measurement)? = nil) async {
        if let admitted { metrics.finish(admitted.taskStart, at: now(), outcome: .success) }
        var outcome = V2RoomSubscriptionHeadDeliveryMetrics.Outcome.success
        defer {
            if let admitted { metrics.finish(admitted.slot, at: now(), outcome: outcome) }
            pendingAcquisitions.remove(job.id)
            if foreground {
                acquisitionTasks.removeValue(forKey: job.id)
                releaseCallSlot()
            }
        }
        let result: Result<Receipt, any Error>
        do {
            guard hasReferences(job.key, relationID: job.relationID) else {
                throw V2GatewayRoomSubscriptionCoordinationError.superseded
            }
            let receipt = try await prepare(job.key, relationID: job.relationID, callDeadline: job.deadline,
                kind: foreground ? .foreground : .repair)
            if let failure = receipt.activationFailure { outcome = Self.outcome(failure) }
            if job.refresh, relations[job.key]?.id == job.relationID, relations[job.key]?.refreshID == job.id {
                relations[job.key]?.receipt = receipt
            }
            result = .success(receipt)
        } catch { outcome = Self.outcome(error); result = .failure(error) }
        if relations[job.key]?.id == job.relationID, relations[job.key]?.refreshID == job.id {
            relations[job.key]?.refreshID = nil
        }
        job.completion.finish(result)
    }
    private func prepare(_ key: Key, relationID: UUID, callDeadline: ContinuousClock.Instant,
        kind: V2RoomSubscriptionHeadDeliveryMetrics.Kind) async throws -> Receipt {
        guard callDeadline > now() else { throw V2GatewayRoomSubscriptionCoordinationError.deadlineExpired }
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
            do { route = try await measure(.resolve, kind: kind) { [ports] in
                try await ports.resolve(key.roomID, callDeadline)
            } }
            catch { scheduleRouteConfirmation(key.roomID); throw error }
            routes[key.roomID] = route
        }
        guard route.activation.roomID == key.roomID, !route.authenticatedServiceID.isEmpty,
              route.authenticatedServiceID.utf8.count <= 128 else {
            throw invalidGrant(.acquisitionRouteInvalid)
        }
        let command = V2RoomSubscriptionSubscribeCommand(roomID: key.roomID, actorUserID: key.userID,
            gatewayDescriptor: ports.gateway)
        var result: V2RoomSubscriptionResult
        do { result = try await measureSubscription(.subscribe, kind: kind) { [ports, activation = route.activation] in
            try await ports.subscribe(command, activation, callDeadline)
        } }
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
                do { route = try await measure(.resolve, kind: kind) { [ports] in
                    try await ports.resolve(key.roomID, callDeadline)
                } }
                catch { scheduleRouteConfirmation(key.roomID); throw error }
            }
            guard route.activation.roomID == key.roomID, !route.authenticatedServiceID.isEmpty,
                  route.authenticatedServiceID.utf8.count <= 128 else {
                throw invalidGrant(.acquisitionRouteInvalid)
            }
            routes[key.roomID] = route
            do { result = try await measureSubscription(.subscribe, kind: kind) { [ports, activation = route.activation] in
                try await ports.subscribe(command, activation, callDeadline)
            } }
            catch { noteRouteFailure(error, roomID: key.roomID, activation: route.activation); throw error }
        }
        var grant: V2RoomSubscriptionGrant
        switch result {
        case .granted(let value): grant = value
        case .failure(let reason): throw V2GatewayRoomSubscriptionCoordinationError.refused(reason)
        default: throw invalidGrant(.acquisitionSubscribeReplyInvalid)
        }
        try validateGrant(grant, route: route)
        var resetValidated = false
        do {
        let sessionReady = ingress.authority.sessionGate(grant.deliverySession,
            serviceID: route.authenticatedServiceID)?.isReady() == true
        let needsBaseline = await ingress.authority.requiresBaseline(fence: grant.fence)
        if !sessionReady || needsBaseline {
            guard hasReferences(key, relationID: relationID) else { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
            let reset = try await measureSubscription(.reset, kind: kind) {
                [ports, activation = route.activation, fence = grant.fence, session = grant.deliverySession] in
                try await ports.reset(.init(roomID: key.roomID, actorUserID: key.userID,
                    gatewayDescriptor: ports.gateway, expectedFence: fence,
                    replacingDeliverySession: sessionReady ? nil : session), activation, callDeadline)
            }
            switch reset {
            case .granted(let replacement):
                try validateGrant(replacement, route: route)
                guard replacement.fence.activation == grant.fence.activation,
                      replacement.fence.generation > grant.fence.generation,
                      replacement.fence.subscriptionID != grant.fence.subscriptionID else {
                    throw invalidGrant(.acquisitionResetFenceInvalid)
                }
                guard sessionReady || replacement.deliverySession.generation > grant.deliverySession.generation else {
                    throw invalidGrant(.acquisitionSessionNotReady)
                }
                grant = replacement
                resetValidated = true
            case .failure(let reason): throw V2GatewayRoomSubscriptionCoordinationError.refused(reason)
            default: throw invalidGrant(.acquisitionResetReplyInvalid)
            }
        }
        } catch {
            noteRouteFailure(error, roomID: key.roomID, activation: route.activation)
            return Receipt(grant: grant, route: route,
                activationFailure: error)
        }
        var activationFailure: (any Error)?
        do {
            guard hasReferences(key, relationID: relationID) else {
                return Receipt(grant: grant, route: route,
                    activationFailure: V2GatewayRoomSubscriptionCoordinationError.superseded)
            }
            let installed = await measureInstall(grant: grant, route: route, resetValidated: resetValidated, kind: kind)
            guard installed else {
                throw invalidGrant(.acquisitionInstallRefused)
            }
            guard hasReferences(key, relationID: relationID) else { throw V2GatewayRoomSubscriptionCoordinationError.superseded }
            let activation = try await measureSubscription(.activate, kind: kind) { [ports, activation = route.activation, fence = grant.fence] in
                try await ports.activate(.init(roomID: key.roomID, actorUserID: key.userID,
                    gatewayDescriptor: ports.gateway, fence: fence), activation, callDeadline)
            }
            guard case .activated = activation else {
                if case .failure(let reason) = activation { throw V2GatewayRoomSubscriptionCoordinationError.refused(reason) }
                throw invalidGrant(.acquisitionActivateReplyInvalid)
            }

        } catch {
            noteRouteFailure(error, roomID: key.roomID, activation: route.activation)
            activationFailure = error
        }
        if activationFailure == nil { routeRecovery.removeValue(forKey: key.roomID) }
        return Receipt(grant: grant, route: route, activationFailure: activationFailure)
    }
    private func validateGrant(_ grant: V2RoomSubscriptionGrant, route: V2GatewayRoomSubscriptionPorts.Route) throws {
        try grant.fence.validate()
        guard grant.fence.activation == route.activation, grant.memberRevision <= UInt64(Int64.max),
              grant.userBaselineSequence >= grant.fence.baselineSequence,
              grant.userBaselineSequence <= UInt64(Int64.max),
              grant.deliverySession.host == route.activation.host && grant.deliverySession.gateway == ports.gateway.identity else {
            throw invalidGrant(.acquisitionGrantFenceInvalid)
        }
        try grant.deliverySession.validate()
    }
    // Measures suspension as well as execution, without spawning a task or
    // changing the original deadline, error or compensation semantics.
    private func measure<Value: Sendable>(_ phase: V2RoomSubscriptionHeadDeliveryMetrics.Phase,
        kind: V2RoomSubscriptionHeadDeliveryMetrics.Kind,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        let measurement = metrics.begin(phase, kind: kind, at: now())
        do {
            let value = try await operation()
            metrics.finish(measurement, at: now(), outcome: .success)
            return value
        } catch {
            metrics.finish(measurement, at: now(), outcome: Self.outcome(error))
            throw error
        }
    }
    private func measureSubscription(_ phase: V2RoomSubscriptionHeadDeliveryMetrics.Phase,
        kind: V2RoomSubscriptionHeadDeliveryMetrics.Kind,
        operation: @Sendable () async throws -> V2RoomSubscriptionResult) async throws -> V2RoomSubscriptionResult {
        let measurement = metrics.begin(phase, kind: kind, at: now())
        do {
            let value = try await operation()
            let outcome: V2RoomSubscriptionHeadDeliveryMetrics.Outcome
            if case .failure(let reason) = value {
                outcome = Self.outcome(V2GatewayRoomSubscriptionCoordinationError.refused(reason))
            } else { outcome = .success }
            metrics.finish(measurement, at: now(), outcome: outcome)
            return value
        } catch {
            metrics.finish(measurement, at: now(), outcome: Self.outcome(error))
            throw error
        }
    }
    private func measureInstall(grant: V2RoomSubscriptionGrant, route: V2GatewayRoomSubscriptionPorts.Route,
        resetValidated: Bool, kind: V2RoomSubscriptionHeadDeliveryMetrics.Kind) async -> Bool {
        let measurement = metrics.begin(.install, kind: kind, at: now())
        let installed = await ingress.install(fence: grant.fence, sourceShardID: route.activation.owner.shardID,
            serviceID: route.authenticatedServiceID, session: grant.deliverySession,
            afterAuthoritativeReset: resetValidated)
        metrics.finish(measurement, at: now(), outcome: installed ? .success : .invalid)
        return installed
    }
    private static func outcome(_ error: any Error) -> V2RoomSubscriptionHeadDeliveryMetrics.Outcome {
        switch error {
        case is CancellationError: return .cancelled
        case V2GatewayRoomSubscriptionCoordinationError.deadlineExpired: return .deadline
        case V2GatewayRoomSubscriptionCoordinationError.superseded: return .superseded
        case V2GatewayRoomSubscriptionCoordinationError.invalidGrant: return .invalid
        case V2GatewayRoomSubscriptionCoordinationError.closed: return .unavailable
        case V2GatewayRoomSubscriptionCoordinationError.refused(let reason):
            return reason == .unavailable ? .unavailable : .refused
        case V2RoomCallFailure.outcomeUnknown: return .outcomeUnknown
        case V2RoomCallFailure.notAccepted(let reason), V2RoomCallFailure.rolledBack(let reason):
            switch reason {
            case .deadlineExceeded: return .deadline
            case .unavailable, .notReady: return .unavailable
            default: return .refused
            }
        default: return .other
        }
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
        let at = now() + .seconds(min(30, 1 << (failures - 1)))
        routeRecovery[roomID] = .init(failures: failures, retryAt: at)
        cooldownDeadlines.set(roomID, at: at)
        scheduleMaintenance()
    }
    private func hasReferences(_ key: Key, relationID: UUID) -> Bool {
        !closed && relations[key]?.id == relationID && relations[key]?.references.isEmpty == false
    }
    private func retire(_ key: Key, relation: Relation) async {
        var acquiredFence = relation.receipt?.grant.fence
        defer {
            if relations[key]?.id == relation.id {
                let retirement = relations[key]?.retirement
                precondition(retirement != nil)
                relations.removeValue(forKey: key); keysByRoom[key.roomID]?.remove(key); deniedRepresentatives.remove(key)
                if keysByRoom[key.roomID]?.isEmpty == true {
                    roomRetirements[key.roomID] = retirement
                    defer { roomRetirements.removeValue(forKey: key.roomID) }
                    // A successor may reuse the same Owner fence. It must join
                    // this actual projection retirement before preparing again.
                    if let fence = sharedReceipts[key.roomID]?.grant.fence ?? acquiredFence {
                        _ = await ingress.retire(fence: fence)
                    }
                    if keysByRoom[key.roomID]?.isEmpty != false {
                        keysByRoom.removeValue(forKey: key.roomID)
                        routes.removeValue(forKey: key.roomID)
                        if let recovery = routeRecovery[key.roomID], recovery.retryAt > now() {
                            cooldownDeadlines.set(key.roomID, at: recovery.retryAt)
                        } else {
                            routeRecovery.removeValue(forKey: key.roomID); cooldownDeadlines.remove(key.roomID)
                        }
                        sharedReceipts.removeValue(forKey: key.roomID); dueRooms.remove(key.roomID)
                        deferredRepairs.removeValue(forKey: key.roomID)
                        roomRepresentatives.removeValue(forKey: key.roomID)
                        scheduleMaintenance()
                    }
                }
            }
        }
        let receipt: Receipt
        do { receipt = try await relation.acquisition.wait(); acquiredFence = receipt.grant.fence }
        catch { onCleanupFailure(key.roomID, key.userID, error); return }
        let deadline = now() + requestTimeout
        do {
            try await takeCallSlot(id: UUID(), deadline: deadline, allowsClosed: true)
        } catch { onCleanupFailure(key.roomID, key.userID, error); return }
        defer { releaseCallSlot() }
        do {
            let result = try await ports.unsubscribe(.init(roomID: key.roomID, actorUserID: key.userID,
                gatewayDescriptor: ports.gateway, memberRevision: receipt.grant.memberRevision),
                receipt.route.activation, deadline)
            guard case .unsubscribed = result else {
                // Authoritative membership invalidation may already have removed
                // this exact revision. It does not authorize a replacement.
                if case .failure(.stale) = result { return }
                if case .failure(let reason) = result { throw V2GatewayRoomSubscriptionCoordinationError.refused(reason) }
                throw invalidGrant(.acquisitionUnsubscribeReplyInvalid)
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
        if needsBaseline || ingress.authority.sessionGate(receipt.grant.deliverySession,
            serviceID: receipt.route.authenticatedServiceID)?.isReady() != true {
            setDeadline(room, at: now())
        }
        // A newer invalidation may have arrived while requiresBaseline awaited.
        // A healthy observation cannot erase its queued/deferred repair. The
        // maintenance owner consumes each request and rechecks it before RPC.
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
    private func takeCallSlot(id: UUID, deadline: ContinuousClock.Instant, allowsClosed: Bool = false) async throws {
        try Task.checkCancellation()
        guard !closed || allowsClosed else { throw V2GatewayRoomSubscriptionCoordinationError.closed }
        guard deadline > now() else { throw V2GatewayRoomSubscriptionCoordinationError.deadlineExpired }
        expireWaitersAndCooldowns()
        if canAdmitForeground && callWaiters.isEmpty { calls += 1; foregroundCalls += 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                callWaiters.append(.init(id: id, deadline: deadline, allowsClosed: allowsClosed,
                    work: .slot(continuation), queued: nil), key: id)
                callDeadlines.set(id, at: deadline)
                scheduleMaintenance()
            }
        } onCancel: {
            Task { await self.cancelCallWaiter(id, error: CancellationError()) }
        }
    }
    private func cancelCallWaiter(_ id: UUID, error: any Error) {
        guard let waiter = callWaiters.remove(id) else { return }
        callDeadlines.remove(id)
        reject(waiter, error: error)
        scheduleMaintenance()
    }
    private func reject(_ waiter: CallWaiter, error: any Error) {
        if let queued = waiter.queued { metrics.finish(queued, at: now(), outcome: Self.outcome(error)) }
        switch waiter.work {
        case .slot(let continuation): continuation.resume(throwing: error)
        case .acquisition(let job): finishQueuedAcquisition(job, error: error)
        }
    }
    private func expireWaitersAndCooldowns() {
        let cut = now()
        while let id = callDeadlines.popDue(at: cut) {
            if let waiter = callWaiters.remove(id) { reject(waiter, error: V2GatewayRoomSubscriptionCoordinationError.deadlineExpired) }
        }
        while let room = cooldownDeadlines.popDue(at: cut) {
            if keysByRoom[room]?.isEmpty != false { routeRecovery.removeValue(forKey: room) }
        }
    }
    private func releaseCallSlot(foreground: Bool = true) {
        calls -= 1
        if foreground { foregroundCalls -= 1 }
        precondition(calls >= foregroundCalls && foregroundCalls >= 0)
        expireWaitersAndCooldowns()
        admitForeground()
        scheduleMaintenance()
    }
    private func admitForeground() {
        while canAdmitForeground, let waiter = callWaiters.removeFirst() {
            callDeadlines.remove(waiter.id)
            if closed && !waiter.allowsClosed { reject(waiter, error: V2GatewayRoomSubscriptionCoordinationError.closed); continue }
            if waiter.deadline <= now() { reject(waiter, error: V2GatewayRoomSubscriptionCoordinationError.deadlineExpired); continue }
            if case .acquisition(let job) = waiter.work, !hasReferences(job.key, relationID: job.relationID) {
                reject(waiter, error: V2GatewayRoomSubscriptionCoordinationError.superseded); continue
            }
            calls += 1; foregroundCalls += 1
            switch waiter.work {
            case .slot(let continuation): continuation.resume()
            case .acquisition(let job):
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.acquisitionAdmitted)
                if let queued = waiter.queued { metrics.finish(queued, at: now(), outcome: .success) }
                let admitted = (slot: metrics.begin(.slot, at: now()), taskStart: metrics.begin(.taskStart, at: now()))
                acquisitionTasks[job.id] = Task { await self.executeAcquisition(job, foreground: true, admitted: admitted) }
            }
        }
    }
    /// Only failures and explicit control invalidations enqueue recovery.
    public func sessionChanged(host: V2ActorHostIdentity) async {
        guard !closed else { return }
        for (room, receipt) in sharedReceipts where receipt.route.activation.host == host {
            if ingress.authority.sessionGate(receipt.grant.deliverySession, serviceID: receipt.route.authenticatedServiceID)?.isReady() != true {
                setDeadline(room, at: now())
            }
        }
    }
    /// Ready selection is synchronous. Each room reserves its actual repair
    /// position before any checkpoint/representative read can suspend, so one
    /// room neither spins the deadline timer nor blocks another room's checks.
    private func admitRepairs() {
        guard !closed, maintenanceStarted else { return }
        let cut = now()
        while canAdmitMaintenance, let room = dueRooms.popDue(at: cut) {
            if repairingRooms.contains(room) { setDeadline(room, at: cut); continue }
            guard keysByRoom[room]?.isEmpty == false else { continue }
            if let pending = routeRecovery[room], pending.retryAt > cut {
                setDeadline(room, at: pending.retryAt); continue
            }
            calls += 1; repairingRooms.insert(room)
            let flightID = UUID()
            repairFlights[flightID] = Task { await self.rebuildRoom(room, flightID: flightID) }
        }
    }
    private func rebuildRoom(_ room: RoomID, flightID: UUID) async {
        defer {
            releaseCallSlot(foreground: false)
            repairingRooms.remove(room)
            repairFlights.removeValue(forKey: flightID)
            if let pending = deferredRepairs.removeValue(forKey: room),
               !closed, keysByRoom[room]?.isEmpty == false {
                setDeadline(room, at: pending)
            }
            scheduleMaintenance()
        }
        guard !closed else { return }
        if let receipt = sharedReceipts[room] {
            let checkpoint = await ingress.authority.authorizationCheckpoint(fence: receipt.grant.fence,
                serviceID: receipt.route.authenticatedServiceID)
            guard !closed else { return }
            if checkpoint != nil, sharedReceipts[room]?.grant.fence == receipt.grant.fence,
               sharedReceipts[room]?.grant.deliverySession == receipt.grant.deliverySession,
               ingress.authority.sessionGate(receipt.grant.deliverySession,
                serviceID: receipt.route.authenticatedServiceID)?.isReady() == true {
                // Consume only this selected request. Invalidation during the
                // check owns its coalesced follow-up until this flight settles.
                return
            }
        }
        guard let key = await representative(room), let relation = relations[key],
              hasReferences(key, relationID: relation.id), !closed else { return }
        // A replacement Owner has no inherited user registrations. Every live
        // relation must obtain its own grant; a shared fence is not that proof.
        let members = (keysByRoom[key.roomID] ?? []).compactMap { member -> (Key, UUID)? in
            guard let relation = relations[member], relation.retirement == nil,
                  !relation.references.isEmpty else { return nil }
            return (member, relation.id)
        }
        for (member, id) in members {
            guard hasReferences(member, relationID: id) else { continue }
            if relations[member]?.refreshID != nil {
                // Never hold a repair slot while waiting for a foreground flight
                // that may itself be queued for that slot (notably capacity one).
                setDeadline(key.roomID, at: now() + .milliseconds(100))
                return
            }
            let acquisitionID = UUID(), deadline = now() + requestTimeout
            let completion = Acquisition()
            relations[member]?.refreshID = acquisitionID
            relations[member]?.acquisition = completion
            // The repair already owns its maintenance slot. Run its member
            // acquisition directly and let foreground callers join the result.
            await executeAcquisition(.init(key: member, relationID: id, id: acquisitionID,
                deadline: deadline, completion: completion, refresh: true), foreground: false)
            do {
                let receipt = try await completion.wait()
                guard hasReferences(member, relationID: id) else { continue }
                relations[member]?.receipt = receipt
                if let failure = receipt.activationFailure { throw failure }
                deniedRepresentatives.remove(member)
                await retainShared(receipt)
                // Replayed/coalesced activation ACKs need not deliver another
                // ingress control. Wake current socket projections explicitly.
                await ingress.resignalProgress(roomID: member.roomID)
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
        closed = true; maintenance?.cancel(); dueRooms.removeAll(); deferredRepairs.removeAll()

        for receipt in sharedReceipts.values { _ = await ingress.authority.pause(fence: receipt.grant.fence) }
        references.removeAll()
        var foreground: [UUID] = []
        callWaiters.forEach { if !$0.allowsClosed { foreground.append($0.id) } }
        for id in foreground { cancelCallWaiter(id, error: V2GatewayRoomSubscriptionCoordinationError.closed) }
        let retained = relations
        for (key, var relation) in retained {
            relation.references.removeAll(); relations[key] = relation
            _ = startRetirement(key, relation: relation)
        }
        let retirements = relations.values.compactMap(\.retirement)
        let closingRooms = Array(roomRetirements.values)
        let flights = Array(repairFlights.values)
        let acquisitions = Array(acquisitionTasks.values)
        for acquisition in acquisitions { await acquisition.value }
        for flight in flights { await flight.value }
        for retirement in retirements { await retirement.value }
        for retirement in closingRooms { await retirement.value }
        await maintenance?.value
        shutdownFinished = true
        let joiners = shutdownJoiners; shutdownJoiners.removeAll()
        for joiner in joiners { joiner.resume() }
    }
    public var relationCount: Int { relations.count }
    public var referenceCount: Int { references.count }
    package var queuedCallCount: Int { callWaiters.count }
    package var acquisitionTaskCount: Int { acquisitionTasks.count }
    package var pendingRepairCount: Int { dueRooms.count + deferredRepairs.count }
}
