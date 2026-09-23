import Foundation
import IMV2ActorContracts
import IMV2Core

public enum V2RoomActivationResolution: Equatable, Sendable {
    case ready(V2RoomActivationToken)
    case occupied(V2RoomActivationLease)
}

public struct V2RoomActivationHostSnapshot: Sendable {
    public let accepting: Bool
    public let activeRooms: Int
    public let pendingRooms: Int
    public let activationWaiters: Int
    public let restoringRooms: Int
    public let retiringRooms: Int
}

public struct V2RoomActivationDrainResult: Sendable {
    public let completed: Bool
    public let remainingRooms: Int
}

/// Owns bounded activation, lease renewal and retirement for one process
/// incarnation. Every callback is checked against a local generation and the
/// complete database token before it can mutate a room entry.
public actor V2RoomActivationHost<Request: Decodable & Sendable, Response: Sendable> {
    private let identity: V2ActorHostIdentity
    private let leaseStore: any V2RoomActivationLeaseStore
    private let configuration: V2RoomRuntimeConfiguration
    private let budget: V2RoomCommandBudget
    private let classify: @Sendable (Request) -> V2RoomTurnSchedulingClass
    private let factory: V2RoomActivationFactory<Request, Response>
    private let clock = ContinuousClock()
    private var started = false
    private var accepting = false
    private var entries: [RoomID: Entry] = [:]
    private var activationQueue: [RoomID] = []
    private var runningActivations = 0
    private var pendingRooms = 0
    private var waiterCount = 0
    private var idleTask: Task<Void, Never>?
    private var changeRevision: UInt64 = 0
    private var changeObserver: (id: UUID, continuation: AsyncStream<UInt64>.Continuation)?

    public init(
        identity: V2ActorHostIdentity,
        leaseStore: any V2RoomActivationLeaseStore,
        configuration: V2RoomRuntimeConfiguration,
        budget: V2RoomCommandBudget,
        classify: @escaping @Sendable (Request) -> V2RoomTurnSchedulingClass,
        factory: V2RoomActivationFactory<Request, Response>
    ) {
        self.identity = identity
        self.leaseStore = leaseStore
        self.configuration = configuration
        self.budget = budget
        self.classify = classify
        self.factory = factory
    }

    public func start() {
        guard !started else { return }
        started = true
        accepting = true
        idleTask = Task { [weak self] in await self?.idleLoop() }
    }

    public func snapshot() -> V2RoomActivationHostSnapshot {
        .init(
            accepting: accepting,
            activeRooms: entries.values.filter { $0.phase == .ready && isSafe($0) }.count,
            pendingRooms: pendingRooms,
            activationWaiters: waiterCount,
            restoringRooms: runningActivations,
            retiringRooms: entries.values.filter { $0.phase == .draining || $0.phase == .uncertain }.count
        )
    }

    /// A local receptionist may reconcile strong actor references against this
    /// bounded authoritative set. The complete token prevents stale callbacks
    /// from deleting a replacement activation.
    public func readyTokens() -> [V2RoomActivationToken] {
        entries.values.compactMap { entry in
            entry.phase == .ready && isSafe(entry) ? entry.token : nil
        }
    }

    /// One local observer receives a bounded, coalesced change signal and then
    /// reconciles `readyTokens()`. Slow observers cannot block renewal or SQL.
    public func changes() -> AsyncStream<UInt64> {
        changeObserver?.continuation.finish()
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        changeObserver = (id, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeObserver(id: id) }
        }
        continuation.yield(changeRevision)
        return stream
    }

    private func removeChangeObserver(id: UUID) {
        if changeObserver?.id == id { changeObserver = nil }
    }

    private func signalChange() {
        changeRevision &+= 1
        changeObserver?.continuation.yield(changeRevision)
    }

    public func activate(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        deadline: ContinuousClock.Instant
    ) async throws -> V2RoomActivationResolution {
        guard started, accepting else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
        guard clock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        guard waiterCount < configuration.maximumActivationWaitersPerHost else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        if let entry = entries[roomID] {
            guard entry.owner == owner else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
            switch entry.phase {
            case .ready:
                guard let token = entry.token, isSafe(entry) else {
                    if let token = entry.token { scheduleLeaseLoss(roomID: roomID, generation: entry.generation, token: token) }
                    throw V2RoomCallFailure.notAccepted(.leaseLost)
                }
                return .ready(token)
            case .acquiring, .restoring: break
            case .draining, .uncertain, .stopped:
                throw V2RoomCallFailure.notAccepted(.retired)
            }
        } else {
            guard entries.count < configuration.maximumActiveRooms,
                  pendingRooms < configuration.maximumPendingActivations
            else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            let entry = Entry(roomID: roomID, owner: owner)
            entries[roomID] = entry
            pendingRooms += 1
            activationQueue.append(roomID)
        }
        guard let entry = entries[roomID],
              entry.waiters.count < configuration.maximumActivationWaitersPerRoom,
              waiterCount < configuration.maximumActivationWaitersPerHost
        else { throw V2RoomCallFailure.notAccepted(.overloaded) }
        let waiterID = UUID()
        let generation = entry.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
                    if entry.waiters.isEmpty && !entry.activationJobRunning && entry.phase == .acquiring {
                        activationQueue.removeAll { $0 == roomID }
                        clearPending(entry)
                        entries.removeValue(forKey: roomID)
                    }
                    return
                }
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.removeWaiter(roomID: roomID, generation: generation,
                                             waiterID: waiterID, reason: .deadlineExceeded)
                }
                entry.waiters[waiterID] = Waiter(
                    continuation: continuation, timer: timer, deadline: deadline
                )
                waiterCount += 1
                pumpActivations()
            }
        } onCancel: {
            Task { await self.removeWaiter(roomID: roomID, generation: generation,
                                           waiterID: waiterID, reason: .cancelled) }
        }
    }

    public func invoke(
        token: V2RoomActivationToken,
        encodedRequest: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> Response {
        let entry = try readyEntry(token)
        guard let lane = entry.lane else { throw V2RoomCallFailure.notAccepted(.notReady) }
        entry.inFlightCalls += 1
        do {
            let result = try await lane.submit(encodedRequest: encodedRequest, deadline: deadline)
            entry.inFlightCalls -= 1
            return result
        } catch {
            entry.inFlightCalls -= 1
            throw error
        }
    }

    public func reserve(
        token: V2RoomActivationToken,
        requestID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> V2RoomReservation {
        let entry = try readyEntry(token)
        guard let lane = entry.lane else { throw V2RoomCallFailure.notAccepted(.notReady) }
        entry.inFlightCalls += 1
        defer { entry.inFlightCalls -= 1 }
        do {
            let grant = try await lane.reserve(requestID: requestID, deadline: deadline)
            guard entries[token.roomID] === entry, entry.token == token,
                  (entry.phase == .ready || entry.phase == .draining),
                  isSafe(entry), !Task.isCancelled else {
                _ = await lane.abortReservation(grant)
                throw V2RoomCallFailure.notAccepted(.leaseLost)
            }
            entry.heldReservation = grant
            entry.reservationDispatched = false
            return grant
        } catch {
            throw error
        }
    }

    public func markReservationDispatched(_ grant: V2RoomReservation) async throws {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              entry.phase == .ready || entry.phase == .draining,
              isSafe(entry) else { throw V2RoomCallFailure.notAccepted(.staleActivation) }
        guard entry.heldReservation == grant, !entry.reservationDispatched else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard let lane = entry.lane else { throw V2RoomCallFailure.notAccepted(.notReady) }
        try await lane.markReservationDispatched(grant)
        guard entries[grant.token.roomID] === entry, entry.heldReservation == grant,
              (entry.phase == .ready || entry.phase == .draining), isSafe(entry) else {
            scheduleLeaseLoss(roomID: grant.token.roomID, generation: entry.generation,
                              token: grant.token)
            throw V2RoomCallFailure.notAccepted(.leaseLost)
        }
        entry.reservationDispatched = true
    }

    public func abortReservation(_ grant: V2RoomReservation) async -> Bool {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              entry.heldReservation == grant, !entry.reservationDispatched,
              let lane = entry.lane else { return false }
        let aborted = await lane.abortReservation(grant)
        if aborted, entries[grant.token.roomID] === entry, entry.heldReservation == grant {
            entry.heldReservation = nil
        }
        return aborted
    }

    /// A duplicate completion never invalidates executor state twice. The
    /// barrier stays held until invalidation finishes; only then can the lane
    /// finish and admit the next turn.
    public func finishReservation(
        _ grant: V2RoomReservation,
        completion: V2RoomReservationCompletion
    ) async -> Bool {
        guard let entry = entries[grant.token.roomID], entry.token == grant.token,
              (entry.phase == .ready || entry.phase == .draining),
              entry.heldReservation == grant, entry.reservationDispatched,
              entry.finishingReservation == nil, let lane = entry.lane,
              let executor = entry.executor else { return false }
        entry.finishingReservation = grant
        defer { entry.finishingReservation = nil }
        let snapshot = await lane.snapshot()
        guard snapshot.hasReservation, entries[grant.token.roomID] === entry,
              entry.token == grant.token, isSafe(entry),
              entry.phase == .ready || entry.phase == .draining else {
            if !isSafe(entry) { scheduleLeaseLoss(roomID: grant.token.roomID,
                                                   generation: entry.generation, token: grant.token) }
            return false
        }
        // Caller cancellation cannot abbreviate executor invalidation or turn
        // an unknown SQL outcome into a safe barrier release.
        let invalidation = Task.detached { await executor.invalidateReservation(grant) }
        await invalidation.value
        guard entries[grant.token.roomID] === entry,
              entry.token == grant.token, entry.finishingReservation == grant,
              isSafe(entry), entry.phase == .ready || entry.phase == .draining else {
            if !isSafe(entry) { scheduleLeaseLoss(roomID: grant.token.roomID,
                                                   generation: entry.generation, token: grant.token) }
            return false
        }
        let finished = await lane.finishReservation(grant, completion: completion)
        if finished { entry.heldReservation = nil; entry.reservationDispatched = false }
        return finished
    }

    /// Closes admission before yielding to any lane. Accepted calls and
    /// reservations retain their lease until their transaction finishes.
    public func beginDrain() async {
        guard accepting else { return }
        accepting = false
        idleTask?.cancel()
        for entry in Array(entries.values) { beginRetirement(entry, uncertain: false) }
    }

    public func drain(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await beginDrain()
        while !entries.isEmpty && clock.now < deadline {
            do { try await clock.sleep(for: .milliseconds(10)) }
            catch { break }
        }
        return .init(completed: entries.isEmpty, remainingRooms: entries.count)
    }

    public func stop(deadline: ContinuousClock.Instant) async -> V2RoomActivationDrainResult {
        await drain(deadline: deadline)
    }

    private func readyEntry(_ token: V2RoomActivationToken) throws -> Entry {
        guard accepting, let entry = entries[token.roomID], entry.token == token else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        guard entry.phase == .ready else { throw V2RoomCallFailure.notAccepted(.retired) }
        guard isSafe(entry) else {
            scheduleLeaseLoss(roomID: token.roomID, generation: entry.generation, token: token)
            throw V2RoomCallFailure.notAccepted(.leaseLost)
        }
        return entry
    }

    private func isSafe(_ entry: Entry) -> Bool {
        guard let safetyUntil = entry.safetyUntil else { return false }
        return clock.now < safetyUntil
    }

    private func pumpActivations() {
        while runningActivations < configuration.maximumConcurrentRestores, !activationQueue.isEmpty {
            let roomID = activationQueue.removeFirst()
            guard let entry = entries[roomID], entry.phase == .acquiring else { continue }
            runningActivations += 1
            let generation = entry.generation
            entry.activationJobRunning = true
            Task { [weak self] in await self?.activateEntry(roomID: roomID, generation: generation) }
        }
    }

    private func activateEntry(roomID: RoomID, generation: UUID) async {
        defer { activationFinished(roomID: roomID, generation: generation) }
        guard let entry = entries[roomID], entry.generation == generation,
              entry.phase == .acquiring else { return }
        let startedAt = clock.now
        do {
            let acquisition = try await leaseStore.acquire(
                roomID: roomID, owner: entry.owner, host: identity, duration: configuration.leaseDuration
            )
            switch acquisition {
            case .occupied(let lease):
                if lease.token.roomID == roomID, lease.token.owner == entry.owner {
                    finishPending(entry, result: .success(.occupied(lease)))
                } else {
                    finishPending(entry, result: .failure(V2RoomCallFailure.notAccepted(.unavailable)))
                }
            case .acquired(let lease):
                guard lease.token.roomID == roomID, lease.token.owner == entry.owner,
                      lease.token.host == identity else {
                    // Even a broken store response owns a possibly committed
                    // token. Keep capacity and retry its conditional release.
                    entry.token = lease.token
                    entry.lease = lease
                    beginRetirement(entry, uncertain: true)
                    return
                }
                guard adoptLease(entry, lease: lease, callStartedAt: startedAt) else { return }
                let executor = factory.make(lease.token)
                entry.executor = executor
                entry.restoreInFlight = true
                let restoreDeadline = min(clock.now + configuration.callTimeout.duration,
                                          entry.safetyUntil ?? clock.now)
                entry.restoreTimer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: restoreDeadline) }
                    catch { return }
                    await self?.restoreTimedOut(roomID: roomID, generation: generation,
                                                token: lease.token)
                }
                do {
                    try await executor.restore(restoreDeadline)
                    entry.restoreInFlight = false
                    entry.restoreTimer?.cancel()
                    guard entries[roomID] === entry else { await executor.close(); return }
                    guard entry.phase == .restoring, isSafe(entry), clock.now < restoreDeadline else {
                        beginRetirement(entry, uncertain: true)
                        return
                    }
                    entry.lane = V2RoomTurnLane(
                        token: lease.token, configuration: configuration, budget: budget,
                        classify: classify, execute: executor.execute,
                        onUncertain: { [weak self] token in
                            // Never await retirement from the lane consumer.
                            await self?.scheduleLeaseLoss(roomID: token.roomID,
                                                          generation: generation, token: token)
                        }
                    )
                    entry.phase = .ready
                    clearPending(entry)
                    signalChange()
                    completeWaiters(entry, result: .success(.ready(lease.token)))
                } catch {
                    entry.restoreInFlight = false
                    entry.restoreTimer?.cancel()
                    guard entries[roomID] === entry else { await executor.close(); return }
                    completeWaiters(entry, result: .failure(V2RoomCallFailure.notAccepted(.unavailable)))
                    beginRetirement(entry, uncertain: false)
                }
            }
        } catch {
            guard entries[roomID] === entry else { return }
            if error as? V2RoomActivationLeaseError == .outcomeUnknown {
                // A committed lease may exist but there is no returned token
                // to restore or release. It remains occupied until DB expiry.
                finishPending(entry, result: .failure(V2RoomCallFailure.outcomeUnknown))
                return
            }
            let reason: V2RoomFailureReason = error as? V2RoomActivationLeaseError == .roomNotFound
                ? .notFound : .unavailable
            finishPending(entry, result: .failure(V2RoomCallFailure.notAccepted(reason)))
        }
    }

    private func activationFinished(roomID: RoomID, generation: UUID) {
        if let entry = entries[roomID], entry.generation == generation {
            entry.activationJobRunning = false
        }
        runningActivations -= 1
        pumpActivations()
    }

    private func restoreTimedOut(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token, entry.restoreInFlight, entry.phase == .restoring else { return }
        beginRetirement(entry, uncertain: true)
    }

    private func adoptLease(_ entry: Entry, lease: V2RoomActivationLease,
                            callStartedAt: ContinuousClock.Instant) -> Bool {
        guard entries[entry.roomID] === entry else { return false }
        entry.token = lease.token
        entry.lease = lease
        guard entry.phase == .acquiring,
              let safety = safetyDeadline(lease, callStartedAt: callStartedAt), safety > clock.now else {
            beginRetirement(entry, uncertain: true)
            return false
        }
        entry.safetyUntil = safety
        entry.phase = .restoring
        let roomID = entry.roomID
        let generation = entry.generation
        entry.renewTask = Task { [weak self] in
            await self?.renewLoop(roomID: roomID, generation: generation, token: lease.token)
        }
        setWatchdog(entry, until: safety)
        return true
    }

    /// A DB observation gives a duration, never a local-wall-clock expiry.
    /// Starting at the beginning of the DB call includes network and lock wait
    /// conservatively in the elapsed time.
    private func safetyDeadline(_ lease: V2RoomActivationLease,
                                callStartedAt: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let milliseconds = Int64((lease.expiresAt.timeIntervalSince(lease.databaseObservedAt) * 1_000).rounded(.down))
        guard milliseconds > configuration.renewalSafetyMargin.rawValue else { return nil }
        return callStartedAt + .milliseconds(milliseconds - configuration.renewalSafetyMargin.rawValue)
    }

    private func renewLoop(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) async {
        while true {
            do { try await clock.sleep(for: configuration.renewalInterval.duration) }
            catch { return }
            guard let entry = entries[roomID], entry.generation == generation,
                  entry.token == token,
                  entry.phase == .restoring || entry.phase == .ready || entry.phase == .draining
            else { return }
            let startedAt = clock.now
            do {
                let lease = try await leaseStore.renew(token: token, duration: configuration.leaseDuration)
                guard entries[roomID] === entry, entry.token == token,
                      entry.phase == .restoring || entry.phase == .ready || entry.phase == .draining
                else { return }
                guard isSafe(entry) else {
                    scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                    return
                }
                guard lease.token == token,
                      let safety = safetyDeadline(lease, callStartedAt: startedAt),
                      safety > clock.now else {
                    scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                    return
                }
                entry.lease = lease
                entry.safetyUntil = safety
                setWatchdog(entry, until: safety)
            } catch {
                scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
                return
            }
        }
    }

    private func setWatchdog(_ entry: Entry, until deadline: ContinuousClock.Instant) {
        entry.watchdogTask?.cancel()
        let roomID = entry.roomID
        let generation = entry.generation
        let token = entry.token
        entry.watchdogTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let token else { return }
            await self?.watchdogExpired(roomID: roomID, generation: generation,
                                        token: token, expectedDeadline: deadline)
        }
    }

    private func watchdogExpired(roomID: RoomID, generation: UUID, token: V2RoomActivationToken,
                                 expectedDeadline: ContinuousClock.Instant) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token, entry.safetyUntil == expectedDeadline,
              !isSafe(entry) else { return }
        scheduleLeaseLoss(roomID: roomID, generation: generation, token: token)
    }

    private func scheduleLeaseLoss(roomID: RoomID, generation: UUID, token: V2RoomActivationToken) {
        guard let entry = entries[roomID], entry.generation == generation,
              entry.token == token else { return }
        beginRetirement(entry, uncertain: true)
    }

    private func beginRetirement(_ entry: Entry, uncertain: Bool) {
        guard entries[entry.roomID] === entry, entry.phase != .stopped else { return }
        if entry.phase == .uncertain || (entry.phase == .draining && !uncertain) { return }
        let wasReady = entry.phase == .ready
        if uncertain { entry.phase = .uncertain }
        else if entry.phase != .uncertain { entry.phase = .draining }
        if wasReady { signalChange() }
        completeWaiters(entry, result: .failure(V2RoomCallFailure.notAccepted(
            uncertain ? .leaseLost : .retired
        )))
        if let lane = entry.lane {
            Task {
                if uncertain { await lane.loseLease() }
                else { await lane.beginDrain() }
            }
        }
        guard entry.retireTask == nil else { return }
        let roomID = entry.roomID
        let generation = entry.generation
        entry.retireTask = Task { [weak self] in
            await self?.retireLoop(roomID: roomID, generation: generation)
        }
    }

    private func retireLoop(roomID: RoomID, generation: UUID) async {
        var retryDelayMilliseconds: Int64 = 25
        while true {
            guard let entry = entries[roomID], entry.generation == generation else { return }
            if !entry.activationJobRunning && !entry.restoreInFlight &&
                entry.inFlightCalls == 0 && entry.finishingReservation == nil {
                let laneSnapshot = await entry.lane?.snapshot()
                guard entries[roomID] === entry else { return }
                if laneSnapshot == nil || (laneSnapshot!.executingCount == 0 &&
                                           laneSnapshot!.queuedCount == 0 && !laneSnapshot!.hasReservation) {
                    if await closeAndRelease(entry) { return }
                    retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 5_000)
                }
            }
            do { try await clock.sleep(for: .milliseconds(retryDelayMilliseconds)) }
            catch { return }
        }
    }

    private func closeAndRelease(_ entry: Entry) async -> Bool {
        guard entries[entry.roomID] === entry else { return true }
        if !entry.executorClosed {
            entry.executorClosed = true
            await entry.executor?.close()
        }
        guard entries[entry.roomID] === entry else { return true }
        if let token = entry.token {
            do { _ = try await leaseStore.release(token: token) }
            catch { return false }
        }
        guard entries[entry.roomID] === entry else { return true }
        if let lane = entry.lane {
            guard await lane.completeRetirement() else { return false }
        }
        entry.renewTask?.cancel()
        entry.watchdogTask?.cancel()
        entry.restoreTimer?.cancel()
        clearPending(entry)
        entry.phase = .stopped
        entries.removeValue(forKey: entry.roomID)
        return true
    }

    private func finishPending(_ entry: Entry, result: Result<V2RoomActivationResolution, any Error>) {
        guard entries[entry.roomID] === entry else { return }
        clearPending(entry)
        completeWaiters(entry, result: result)
        entries.removeValue(forKey: entry.roomID)
    }

    private func completeWaiters(_ entry: Entry, result: Result<V2RoomActivationResolution, any Error>) {
        let waiters = entry.waiters
        entry.waiters.removeAll()
        waiterCount -= waiters.count
        for waiter in waiters.values {
            waiter.timer.cancel()
            if waiter.deadline <= clock.now {
                waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
            } else {
                waiter.continuation.resume(with: result)
            }
        }
    }

    private func clearPending(_ entry: Entry) {
        if entry.countedPending {
            entry.countedPending = false
            pendingRooms -= 1
        }
    }

    private func removeWaiter(roomID: RoomID, generation: UUID, waiterID: UUID,
                              reason: V2RoomFailureReason) {
        guard let entry = entries[roomID], entry.generation == generation,
              let waiter = entry.waiters.removeValue(forKey: waiterID) else { return }
        waiterCount -= 1
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: V2RoomCallFailure.notAccepted(reason))
    }

    private func idleLoop() async {
        while accepting {
            do { try await clock.sleep(for: min(configuration.idleTimeout.duration, .seconds(1))) }
            catch { return }
            guard accepting else { return }
            for entry in Array(entries.values) where entry.phase == .ready && entry.inFlightCalls == 0 {
                guard let lane = entry.lane else { continue }
                let snapshot = await lane.snapshot()
                guard entries[entry.roomID] === entry, entry.phase == .ready else { continue }
                if snapshot.isIdle && clock.now - snapshot.lastActivity >= configuration.idleTimeout.duration {
                    beginRetirement(entry, uncertain: false)
                }
            }
        }
    }

    private final class Entry {
        let roomID: RoomID
        let owner: V2RoomDataOwner
        let generation = UUID()
        var phase: V2RoomActivationPhase = .acquiring
        var countedPending = true
        var activationJobRunning = false
        var waiters: [UUID: Waiter] = [:]
        var token: V2RoomActivationToken?
        var lease: V2RoomActivationLease?
        var safetyUntil: ContinuousClock.Instant?
        var lane: V2RoomTurnLane<Request, Response>?
        var executor: V2RoomActivationExecutor<Request, Response>?
        var executorClosed = false
        var restoreInFlight = false
        var inFlightCalls = 0
        var finishingReservation: V2RoomReservation?
        var heldReservation: V2RoomReservation?
        var reservationDispatched = false
        var renewTask: Task<Void, Never>?
        var watchdogTask: Task<Void, Never>?
        var restoreTimer: Task<Void, Never>?
        var retireTask: Task<Void, Never>?

        init(roomID: RoomID, owner: V2RoomDataOwner) {
            self.roomID = roomID
            self.owner = owner
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<V2RoomActivationResolution, any Error>
        let timer: Task<Void, Never>
        let deadline: ContinuousClock.Instant
    }
}
