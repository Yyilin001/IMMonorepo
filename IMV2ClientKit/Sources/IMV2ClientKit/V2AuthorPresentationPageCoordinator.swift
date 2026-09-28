import Foundation
import IMV2Core

/// One account owns this coordinator. The most recently selected foreground
/// page owns its single optional author stream; other room subscriptions remain
/// intact. The caller owns the profile activation and cancels `run` on leaving
/// the page or entering the background, then deactivates it after this drains.
public actor V2AuthorPresentationPageCoordinator {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Error>
    }
    private let rooms: V2RoomSubscriptionCoordinator
    private let source: any V2AuthorPresentationSource
    private let subscriptions: any V2ClientAuthorPresentationSubscriptionTransport
    private let profiles: V2ProfilePresentationRepository
    private let roomCursor: @Sendable (RoomID) async throws -> UInt64
    private let renewalLead: @Sendable () -> Duration
    private let retryJitter: @Sendable () -> Duration
    private let retryDelay: Duration
    private var retryNotBefore: ContinuousClock.Instant?
    private var requested: UUID?
    private var flight: Flight?
    private var activeBinding: V2ProfileAuthorBinding?
    private var closed = false

    public init(rooms: V2RoomSubscriptionCoordinator, source: any V2AuthorPresentationSource,
                subscriptions: any V2ClientAuthorPresentationSubscriptionTransport,
                profiles: V2ProfilePresentationRepository,
                roomCursor: @escaping @Sendable (RoomID) async throws -> UInt64) {
        self.rooms = rooms; self.source = source; self.subscriptions = subscriptions
        self.profiles = profiles; self.roomCursor = roomCursor
        renewalLead = { .milliseconds(Int64.random(in: 4_000...6_000)) }
        retryJitter = { .milliseconds(Int64.random(in: 100...500)) }
        retryDelay = .seconds(2)
    }

    init(rooms: V2RoomSubscriptionCoordinator, source: any V2AuthorPresentationSource,
         subscriptions: any V2ClientAuthorPresentationSubscriptionTransport,
         profiles: V2ProfilePresentationRepository,
         roomCursor: @escaping @Sendable (RoomID) async throws -> UInt64,
         renewalLead: @escaping @Sendable () -> Duration, retryDelay: Duration) {
        precondition(retryDelay > .zero)
        self.rooms = rooms; self.source = source; self.subscriptions = subscriptions
        self.profiles = profiles; self.roomCursor = roomCursor
        self.renewalLead = renewalLead; self.retryDelay = retryDelay
        retryJitter = { .zero }
    }

    /// The activation must precede nonce creation and belong to this page's
    /// visible author consumers. No authority is copied into durable messages.
    public func run(roomID: RoomID, activation: V2ProfilePageActivation) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ProfilePresentationError.inactive }
        guard roomID.uuidValue != nil else { throw V2ProfilePresentationError.invalidResponse }
        let id = UUID(); requested = id
        while let previous = flight {
            previous.task.cancel()
            _ = await previous.task.result
            try Task.checkCancellation()
            guard !closed, requested == id else { throw CancellationError() }
            if flight?.id == previous.id { flight = nil }
        }
        let task = Task { try await self.runPage(roomID: roomID, activation: activation) }
        flight = .init(id: id, task: task)
        defer {
            if flight?.id == id { flight = nil }
            if requested == id { requested = nil }
        }
        try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            try result.get()
        }, onCancel: { task.cancel() })
    }

    /// Permanently closes admission and waits for the actual subscription,
    /// receiver and room-intent cleanup. Concurrent closes wait on the same task.
    public func close() async {
        closed = true; requested = nil
        await suspend()
    }

    /// Reusable account foreground fence. Revoke cached grants immediately,
    /// then retain the actual task slot until non-cooperative I/O has drained.
    public func suspend() async {
        requested = nil
        let running = flight?.task
        running?.cancel()
        await retireActiveBinding()
        _ = await running?.result
    }

    private func retireActiveBinding() async {
        guard let binding = activeBinding else { return }
        activeBinding = nil
        await profiles.unbindAuthorView(binding)
    }

    public struct Diagnostics: Sendable {
        public let closed: Bool
        public let running: Bool
    }
    public func diagnostics() -> Diagnostics { .init(closed: closed, running: flight != nil) }

    private func runPage(roomID: RoomID, activation: V2ProfilePageActivation) async throws {
        let lease = try await rooms.acquireAuthorPresentationRoom(roomID: roomID)
        var worker: (scope: V2RoomSubscriptionCoordinator.AuthorPresentationScope, task: Task<Void, Never>)?
        for await snapshot in lease.updates {
            if Task.isCancelled { break }
            let eligible: V2RoomSubscriptionCoordinator.AuthorPresentationScope?
            if snapshot.state == .subscribed, let connectionID = snapshot.connectionID,
               let generation = snapshot.authorPresentationGeneration {
                eligible = .init(connectionID: connectionID, generation: generation)
            } else { eligible = nil }
            if worker?.scope == eligible { continue }
            if let previous = worker {
                previous.task.cancel()
                await retireActiveBinding()
                await previous.task.value
                worker = nil
            }
            if Task.isCancelled { break }
            guard let scope = eligible,
                  await rooms.authorPresentationScope(roomID: roomID, consumerID: lease.id) == scope else { continue }
            worker = (scope, Task {
                await V2ConnectionRequestScope.$connectionID.withValue(scope.connectionID) {
                    await self.runConnection(lease: lease, activation: activation, scope: scope)
                }
            })
        }
        worker?.task.cancel()
        await retireActiveBinding()
        await worker?.task.value
        await rooms.release(roomID: roomID, consumerID: lease.id)
        try Task.checkCancellation()
    }

    private func requireCurrent(_ lease: V2RoomSubscriptionLease, scope: V2RoomSubscriptionCoordinator.AuthorPresentationScope) async throws {
        try Task.checkCancellation()
        guard await rooms.authorPresentationScope(roomID: lease.roomID, consumerID: lease.id) == scope else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func runConnection(lease: V2RoomSubscriptionLease, activation: V2ProfilePageActivation,
                               scope: V2RoomSubscriptionCoordinator.AuthorPresentationScope) async {
        var lastBinding: V2ProfileAuthorBinding?
        while !Task.isCancelled {
            do {
                if let retryNotBefore, retryNotBefore > .now { try await ContinuousClock().sleep(until: retryNotBefore) }
                try await requireCurrent(lease, scope: scope)
                let view = try await source.beginAuthorPresentationView(roomID: lease.roomID)
                do {
                    try await requireCurrent(lease, scope: scope)
                    let binding = try await profiles.bindAuthorView(view, activation: activation)
                    lastBinding = binding; activeBinding = binding
                    try await requireCurrent(lease, scope: scope)
                    let cursor = try await roomCursor(lease.roomID)
                    try await requireCurrent(lease, scope: scope)
                    let reply = try await subscriptions.subscribeToGroupEvents(roomID: lease.roomID,
                        afterRoomSequence: cursor, authorPresentationView: view)
                    guard reply.roomID == lease.roomID else { throw V2ProfilePresentationError.invalidResponse }
                    try await requireCurrent(lease, scope: scope)
                    // Reserve time for the next subscription; jitter avoids all
                    // devices renewing on a common 30-second boundary.
                    let lead = min(.seconds(10), max(.milliseconds(1), renewalLead()))
                    let renewAt = view.renewBy - lead
                    guard renewAt > .now else { throw V2ProfilePresentationError.staleResponse }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            while !Task.isCancelled {
                                let delta = try await self.source.nextAuthorPresentationDelta(for: view)
                                try await self.requireCurrent(lease, scope: scope)
                                try await self.profiles.ingest(delta, binding: binding)
                            }
                        }
                        group.addTask { try await ContinuousClock().sleep(until: renewAt) }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                } catch {
                    await finishView(view)
                    throw error
                }
                await finishView(view)
                // Preserve still-live page grants until the replacement binding
                // retags them. Renewal itself does not trigger HTTP or image I/O.
            } catch {
                // A cancelled page's late throttle still belongs to this same
                // account. Page replacement/reconnect cannot reset its cooldown.
                if let domain = error as? V2RealtimeTransportError,
                   case .server(_, let retryable, let seconds, _) = domain, retryable, seconds > 0 {
                    let until = ContinuousClock.now + .seconds(seconds) + retryJitter()
                    retryNotBefore = max(retryNotBefore ?? until, until)
                }
                if let binding = lastBinding {
                    if activeBinding == binding { activeBinding = nil }
                    await profiles.unbindAuthorView(binding); lastBinding = nil
                }
                if Task.isCancelled || error is CancellationError { break }
                if let transport = error as? V2TLSFrameConnectionError,
                   transport == .notConnected || transport == .connectionClosed { break }
                if let domain = error as? V2RealtimeTransportError {
                    if case .server(let code, let retryable, _, _) = domain {
                        if code == "FORBIDDEN" {
                            await rooms.authorSubscriptionWasRejected(roomID: lease.roomID, consumerID: lease.id, scope: scope)
                        }
                        if code == "FORBIDDEN" || !retryable { break }
                    } else if domain == .unexpectedResponse { break }
                }
                if let value = error as? V2ProfilePresentationError,
                   value == .inactive || value == .invalidResponse { break }
                do { try await Task.sleep(for: retryDelay) } catch { break }
            }
        }
        if let binding = lastBinding {
            if activeBinding == binding { activeBinding = nil }
            await profiles.unbindAuthorView(binding)
        }
    }

    private func finishView(_ view: V2AuthorPresentationView) async {
        await source.endAuthorPresentationView(view)
        // This page's actual worker owns and awaits exactly one cleanup. An
        // unstructured task deliberately starts uncancelled, retaining the
        // connection TaskLocal: a cancelled page still stops its original nonce.
        // New pages/close cannot release the worker slot until it returns.
        let cleanup = Task { [subscriptions] in try await subscriptions.stopAuthorPresentation(view) }
        _ = await cleanup.result
    }
}
