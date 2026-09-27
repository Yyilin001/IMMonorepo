import Foundation
import IMV2Core

public struct V2GroupAvatarActivation: Hashable, Sendable {
    public let roomID: RoomID
    fileprivate let id: UUID
    fileprivate let epoch: UUID
}

public enum V2GroupAvatarPresentationError: Error, Equatable, Sendable {
    case inactive, overloaded, invalidResponse, expired, staleRevision
}

/// Account/device-owned, memory-only authorization. A new visible activation
/// reauthorizes even when another page already has the same image on disk.
public actor V2GroupAvatarPresentationRepository {
    private struct Activation {
        let roomID: RoomID
        var authorized = false
        var observerID: UUID?
        var observer: AsyncStream<Void>.Continuation?
    }
    private struct Access {
        let value: V2GroupAvatarPresentation
        let deadline: ContinuousClock.Instant
        let byteDeadline: ContinuousClock.Instant?
        let cost: Int
    }
    private struct Waiter {
        let activation: V2GroupAvatarActivation
        let continuation: CheckedContinuation<V2GroupAvatarPresentation, Error>
    }
    private struct Demand {
        let id = UUID()
        let order: UInt64
        var waiters: [UUID: Waiter] = [:]
    }
    private struct Flight {
        let demandID: UUID
        let task: Task<Void, Never>
    }
    private struct Cooldown {
        let until: ContinuousClock.Instant
        let error: V2GroupAvatarReadError
    }
    private let actorUserID: UserID
    private let deviceID: DeviceID
    private let reader: any V2GroupAvatarPresentationReading
    private let minimumRevision: @Sendable (RoomID) async throws -> UInt64
    private let now: @Sendable () -> ContinuousClock.Instant
    private var epoch = UUID()
    private var activations: [UUID: Activation] = [:]
    private var access: [RoomID: Access] = [:]
    private var demand: [RoomID: Demand] = [:]
    private var flights: [RoomID: Flight] = [:]
    private var cooldowns: [RoomID: Cooldown] = [:]
    private var order: UInt64 = 0
    private var bytes = 0
    private var closed = false
    private let maximumBytes = 2 * 1_024 * 1_024

    public init(actorUserID: UserID, deviceID: DeviceID, reader: any V2GroupAvatarPresentationReading,
                minimumRevision: @escaping @Sendable (RoomID) async throws -> UInt64,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.reader = reader
        self.minimumRevision = minimumRevision; self.now = now
    }

    public func activate(roomID: RoomID) throws -> V2GroupAvatarActivation {
        guard !closed else { throw V2GroupAvatarPresentationError.inactive }
        guard roomID.uuidValue != nil else { throw V2GroupAvatarPresentationError.invalidResponse }
        guard activations.count < 256 else { throw V2GroupAvatarPresentationError.overloaded }
        let token = V2GroupAvatarActivation(roomID: roomID, id: UUID(), epoch: epoch)
        activations[token.id] = .init(roomID: roomID)
        return token
    }

    public struct Diagnostics: Sendable {
        public let activations: Int
        public let waitingConsumers: Int
        public let pendingRooms: Int
        public let inFlight: Int
        public let cachedRooms: Int
        public let cachedBytes: Int
    }
    public func diagnostics() -> Diagnostics {
        .init(activations: activations.count, waitingConsumers: demand.values.reduce(0, { $0 + $1.waiters.count }),
              pendingRooms: demand.count, inFlight: flights.count, cachedRooms: access.count, cachedBytes: bytes)
    }

    public func deactivate(_ token: V2GroupAvatarActivation) {
        guard token.epoch == epoch else { return }
        activations.removeValue(forKey: token.id)?.observer?.finish()
        for (id, waiter) in demand[token.roomID]?.waiters ?? [:] where waiter.activation == token {
            cancelWaiter(id, roomID: token.roomID)
        }
        if !activations.values.contains(where: { $0.roomID == token.roomID && $0.authorized }) { removeAccess(token.roomID) }
    }

    public func invalidate(roomID: RoomID) {
        removeAccess(roomID); cooldowns.removeValue(forKey: roomID)
        revokeVisibleAccess(roomID)
        complete(roomID, result: .failure(V2GroupAvatarPresentationError.inactive))
        flights[roomID]?.task.cancel()
    }

    public func endAllActivations() {
        for activation in activations.values { activation.observer?.finish() }
        epoch = UUID(); activations.removeAll(); access.removeAll(); bytes = 0; cooldowns.removeAll()
        for room in Array(demand.keys) { complete(room, result: .failure(V2GroupAvatarPresentationError.inactive)) }
        for flight in flights.values { flight.task.cancel() }
        // Keep slots occupied until cancelled I/O actually ends. A transport that
        // ignores cancellation cannot cause unlimited work after page re-entry.
    }

    public func close() async {
        closed = true
        endAllActivations()
        let running = Array(flights.values)
        for flight in running { await flight.task.value }
    }

    /// One bounded observer per visible activation. Subscribe before reading so
    /// a denial or newer response in another page can immediately hide old pixels.
    public func invalidations(for token: V2GroupAvatarActivation) throws -> AsyncStream<Void> {
        try requireActive(token)
        activations[token.id]?.observer?.finish()
        let observerID = UUID(), stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in
            Task { await self?.stopObserving(token, observerID: observerID) }
        }
        activations[token.id]?.observerID = observerID
        activations[token.id]?.observer = stream.continuation
        return stream.stream
    }

    private func stopObserving(_ token: V2GroupAvatarActivation, observerID: UUID) {
        guard token.epoch == epoch, activations[token.id]?.observerID == observerID else { return }
        activations[token.id]?.observer = nil; activations[token.id]?.observerID = nil
    }

    private func revokeVisibleAccess(_ room: RoomID) {
        for id in activations.keys where activations[id]?.roomID == room {
            let wasVisible = activations[id]?.authorized == true
            activations[id]?.authorized = false
            if wasVisible { activations[id]?.observer?.yield(()) }
        }
    }

    public func presentation(for token: V2GroupAvatarActivation) async throws -> V2GroupAvatarPresentation {
        try Task.checkCancellation()
        if let cached = try await validatedAccess(token) { return cached.value }
        try requireActive(token)
        if let cooldown = cooldowns[token.roomID], cooldown.until > now() { throw cooldown.error }
        cooldowns.removeValue(forKey: token.roomID)
        guard demand[token.roomID] != nil || demand.count < 128,
              demand.values.reduce(0, { $0 + $1.waiters.count }) < 512 else { throw V2GroupAvatarPresentationError.overloaded }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if demand[token.roomID] == nil { order &+= 1; demand[token.roomID] = Demand(order: order) }
                demand[token.roomID]?.waiters[id] = .init(activation: token, continuation: continuation)
                launch()
            }
        } onCancel: { Task { await self.cancelWaiter(id, roomID: token.roomID) } }
    }

    public func cachedPresentation(for token: V2GroupAvatarActivation) async throws -> V2GroupAvatarPresentation? {
        try await validatedAccess(token)?.value
    }

    public func authorizationDeadline(for token: V2GroupAvatarActivation) async throws -> ContinuousClock.Instant? {
        try await validatedAccess(token)?.deadline
    }

    public func avatarAccess(for token: V2GroupAvatarActivation) async throws -> V2ResourceAvatarAccess? {
        guard let entry = try await validatedAccess(token), let deadline = entry.byteDeadline, deadline > now() else { return nil }
        return entry.value.avatar
    }

    private func validatedAccess(_ token: V2GroupAvatarActivation) async throws -> Access? {
        try Task.checkCancellation()
        try requireActive(token)
        guard activations[token.id]?.authorized == true, access[token.roomID] != nil else { return nil }
        let revision = try await minimumRevision(token.roomID)
        try Task.checkCancellation()
        try requireActive(token)
        guard activations[token.id]?.authorized == true, let entry = access[token.roomID] else { return nil }
        guard entry.value.state.revision >= revision else { invalidate(roomID: token.roomID); return nil }
        guard entry.deadline > now() else { removeAccess(token.roomID); return nil }
        return entry
    }

    private func requireActive(_ token: V2GroupAvatarActivation) throws {
        guard !closed, token.epoch == epoch, activations[token.id]?.roomID == token.roomID else {
            throw V2GroupAvatarPresentationError.inactive
        }
    }

    private func launch() {
        guard !closed else { return }
        for (room, item) in demand.sorted(by: { $0.value.order < $1.value.order }) where flights[room] == nil {
            guard flights.count < 2 else { break }
            let requestID = item.id, started = now()
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let value = try await reader.readGroupAvatar(roomID: room)
                    try Task.checkCancellation()
                    let revision = try await minimumRevision(room)
                    try Task.checkCancellation()
                    guard value.state.revision >= revision else { throw V2GroupAvatarPresentationError.staleRevision }
                    finish(room, requestID: requestID, started: started, result: .success(value))
                } catch { finish(room, requestID: requestID, started: started, result: .failure(error)) }
            }
            flights[room] = .init(demandID: requestID, task: task)
        }
    }

    private func finish(_ room: RoomID, requestID: UUID, started: ContinuousClock.Instant,
                        result: Result<V2GroupAvatarPresentation, Error>) {
        guard flights[room]?.demandID == requestID else { return }
        flights.removeValue(forKey: room)
        defer { launch() }
        guard demand[room]?.id == requestID else { return }
        do {
            let value = try result.get(), instant = now()
            guard value.actorUserID == actorUserID, value.deviceID == deviceID, value.state.roomID == room else {
                throw V2GroupAvatarPresentationError.invalidResponse
            }
            let elapsed = started.duration(to: instant)
            let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let remaining = Double(value.validUntilUnixMilliseconds - value.serverNowUnixMilliseconds) / 1_000 - elapsedSeconds
            guard elapsedSeconds >= 0, remaining > 0, remaining <= 300 else { throw V2GroupAvatarPresentationError.expired }
            let cost = try JSONEncoder().encode(value).count
            guard cost <= 64 * 1_024 else { throw V2GroupAvatarPresentationError.invalidResponse }
            let byteDeadline = value.avatar.map {
                instant.advanced(by: .seconds(Double($0.plan.expiresAtUnixMilliseconds - value.serverNowUnixMilliseconds) / 1_000 - elapsedSeconds))
            }
            if let prior = access[room]?.value,
               prior.state != value.state || prior.resourceGeneration != value.resourceGeneration ||
                prior.membershipRevision != value.membershipRevision || prior.canManage != value.canManage {
                revokeVisibleAccess(room)
            }
            removeAccess(room)
            while access.count >= 256 || bytes > maximumBytes - cost {
                guard let oldest = access.min(by: { $0.value.deadline < $1.value.deadline }) else { break }
                removeAccess(oldest.key)
            }
            access[room] = .init(value: value, deadline: instant.advanced(by: .seconds(remaining)), byteDeadline: byteDeadline, cost: cost)
            bytes += cost; cooldowns.removeValue(forKey: room)
            for waiter in demand[room]?.waiters.values ?? Dictionary<UUID, Waiter>().values {
                if waiter.activation.epoch == epoch { activations[waiter.activation.id]?.authorized = true }
            }
            complete(room, result: .success(value))
        } catch {
            removeAccess(room)
            if error as? V2GroupAvatarPresentationError == .staleRevision { revokeVisibleAccess(room) }
            // Only a definite denial or explicit server backoff suppresses new
            // reads. Transport failures must never be cached as permission denial.
            if let failure = error as? V2GroupAvatarReadError {
                let delay: TimeInterval?
                switch failure {
                case .forbidden: revokeVisibleAccess(room); delay = 30
                case .throttled(let seconds): delay = seconds.isFinite ? min(60, max(1, seconds)) : 1
                default: delay = nil
                }
                if let delay {
                    if cooldowns.count >= 256 { cooldowns.removeValue(forKey: cooldowns.keys.first!) }
                    cooldowns[room] = .init(until: now().advanced(by: .seconds(delay)), error: failure)
                }
            }
            complete(room, result: .failure(error))
        }
    }

    private func complete(_ room: RoomID, result: Result<V2GroupAvatarPresentation, Error>) {
        guard let item = demand.removeValue(forKey: room) else { return }
        for waiter in item.waiters.values {
            if waiter.activation.epoch == epoch && activations[waiter.activation.id] != nil { waiter.continuation.resume(with: result) }
            else { waiter.continuation.resume(throwing: V2GroupAvatarPresentationError.inactive) }
        }
    }

    private func cancelWaiter(_ id: UUID, roomID: RoomID) {
        guard let waiter = demand[roomID]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if demand[roomID]?.waiters.isEmpty == true {
            let requestID = demand.removeValue(forKey: roomID)?.id
            if flights[roomID]?.demandID == requestID { flights[roomID]?.task.cancel() }
        }
    }

    private func removeAccess(_ room: RoomID) {
        if let entry = access.removeValue(forKey: room) { bytes -= entry.cost }
    }
}
