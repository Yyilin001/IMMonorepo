import Foundation
import IMV2Core

/// One account owns one receiver, interest publisher and renewal loop. Pages
/// join that connection view and keep their own presentation grants. Cancelling
/// a page retires its author grants immediately and drains its old socket work;
/// the caller continues to own the profile activation and ordinary HTTP reads.
public actor V2AuthorPresentationPageCoordinator {
    public static let maximumPages = 16
    private typealias Scope = V2RoomSubscriptionCoordinator.AuthorPresentationScope
    private struct Page: Sendable { let activation: V2ProfilePageActivation; let messageRoomID: RoomID? }
    private struct PageTask { let page: Page; let task: Task<Void, Error> }
    private struct Flight { let id: UUID; let task: Task<Void, Never> }
    private struct Worker { let id: UUID; let generation: UUID; let scope: Scope; let task: Task<Void, Never> }
    private let rooms: V2RoomSubscriptionCoordinator
    private let source: any V2AuthorPresentationSource
    private let subscriptions: any V2ClientAuthorPresentationSubscriptionTransport
    private let profiles: V2ProfilePresentationRepository
    private let renewalLead: @Sendable () -> Duration
    private let retryJitter: @Sendable () -> Duration
    private let retryDelay: Duration
    private var retryNotBefore: ContinuousClock.Instant?
    private var pages: [UUID: Page] = [:]
    private var pageTasks: [UUID: PageTask] = [:]
    private var generation = UUID()
    private var connectionScope: Scope?
    private var controller: Flight?
    private var wake: AsyncStream<Void>.Continuation?
    private var worker: Worker?
    private var interestSignal: (id: UUID, continuation: AsyncStream<Void>.Continuation)?
    private var activeBinding: V2ProfileAuthorBinding?
    private var suspending: Flight?
    private var closed = false

    public init(rooms: V2RoomSubscriptionCoordinator, source: any V2AuthorPresentationSource,
                subscriptions: any V2ClientAuthorPresentationSubscriptionTransport,
                profiles: V2ProfilePresentationRepository) {
        self.rooms = rooms; self.source = source; self.subscriptions = subscriptions; self.profiles = profiles
        renewalLead = { .milliseconds(Int64.random(in: 4_000...6_000)) }
        retryJitter = { .milliseconds(Int64.random(in: 100...500)) }; retryDelay = .seconds(2)
    }

    init(rooms: V2RoomSubscriptionCoordinator, source: any V2AuthorPresentationSource,
         subscriptions: any V2ClientAuthorPresentationSubscriptionTransport,
         profiles: V2ProfilePresentationRepository,
         renewalLead: @escaping @Sendable () -> Duration, retryDelay: Duration) {
        precondition(retryDelay > .zero)
        self.rooms = rooms; self.source = source; self.subscriptions = subscriptions; self.profiles = profiles
        self.renewalLead = renewalLead; self.retryDelay = retryDelay; retryJitter = { .zero }
    }

    /// A list supplies nil; a chat also retains its normal room-event intent.
    /// Joining any page creates a fresh nonce after that page's activation.
    public func run(messageRoomID: RoomID?, activation: V2ProfilePageActivation) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ProfilePresentationError.inactive }
        while let draining = suspending {
            await draining.task.value
            if suspending?.id == draining.id { suspending = nil }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard !closed else { throw V2ProfilePresentationError.inactive }
        guard messageRoomID.map({ $0.uuidValue != nil }) ?? true else { throw V2ProfilePresentationError.invalidResponse }
        let messageRooms = Set(pageTasks.values.compactMap { $0.page.messageRoomID }).union(messageRoomID.map { [$0] } ?? [])
        guard pageTasks.count < Self.maximumPages, messageRooms.count <= V2AuthorPresentationStart.maximumMessageRooms,
              !pageTasks.values.contains(where: { $0.page.activation == activation }) else { throw V2ProfilePresentationError.overloaded }
        let id = UUID(), page = Page(activation: activation, messageRoomID: messageRoomID)
        let task = Task { try await self.runPage(id: id, page: page) }
        pageTasks[id] = .init(page: page, task: task)
        defer { pageTasks.removeValue(forKey: id) }
        try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation(); try result.get()
        }, onCancel: { task.cancel() })
    }

    public func close() async {
        closed = true
        await suspend()
        let running = controller
        running?.task.cancel(); wake?.finish()
        await running?.task.value
        if controller?.id == running?.id { controller = nil; wake = nil }
    }

    /// Reusable foreground fence. Hold admission until all actual old I/O and
    /// page cleanup finish; a new foreground run cannot bypass that ownership.
    public func suspend() async {
        if let suspending { await suspending.task.value; return }
        let tasks = pageTasks.values.map(\.task), oldWorker = worker?.task
        for task in tasks { task.cancel() }; oldWorker?.cancel()
        let id = UUID(), task = Task {
            await self.retireActiveBinding()
            for task in tasks { _ = await task.result }
            await oldWorker?.value
        }
        suspending = .init(id: id, task: task)
        await task.value
        if suspending?.id == id { suspending = nil }
    }

    public struct Diagnostics: Sendable { public let closed: Bool; public let running: Bool; public let pages: Int }
    public func diagnostics() -> Diagnostics { .init(closed: closed, running: !pageTasks.isEmpty || worker != nil, pages: pages.count) }

    private func runPage(id: UUID, page: Page) async throws {
        defer { pageTasks.removeValue(forKey: id) }
        var lease: V2RoomSubscriptionLease?
        do {
            try await profiles.expectAuthorDelivery(for: page.activation)
            if let room = page.messageRoomID { lease = try await rooms.acquire(roomID: room, channels: [.roomEvents]) }
            try Task.checkCancellation()
            let changes = try await profiles.visibleAuthorChanges(for: page.activation)
            try Task.checkCancellation()
            guard !closed else { throw V2ProfilePresentationError.inactive }
            pages[id] = page; replacePageSet(); ensureController()
            for await _ in changes {
                if Task.isCancelled { break }
                interestSignal?.continuation.yield(())
            }
            await removePage(id, activation: page.activation)
            if let held = lease {
                lease = nil
                await rooms.release(roomID: held.roomID, consumerID: held.id)
            }
            try Task.checkCancellation()
        } catch {
            await removePage(id, activation: page.activation)
            if let lease { await rooms.release(roomID: lease.roomID, consumerID: lease.id) }
            throw error
        }
    }

    private func removePage(_ id: UUID, activation: V2ProfilePageActivation) async {
        await profiles.endAuthorDelivery(for: activation)
        guard pages.removeValue(forKey: id) != nil else { return }
        let previous = worker?.task
        replacePageSet()
        await profiles.detachAuthorPage(activation)
        if pages.isEmpty { await retireActiveBinding() }
        await previous?.value
        // Covers a bind already enqueued on the repository when cancellation
        // arrived. A replacement view excludes this page and is unaffected.
        await profiles.detachAuthorPage(activation)
    }
    private func replacePageSet() {
        generation = UUID(); worker?.task.cancel(); wake?.yield(())
    }
    private func ensureController() {
        guard controller == nil, !closed else { return }
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = pair.continuation; pair.continuation.yield(())
        let task = Task { await self.runController(wakes: pair.stream) }
        controller = .init(id: id, task: task)
    }
    private func runController(wakes: AsyncStream<Void>) async {
        do {
            let connections = try await rooms.authorConnectionChanges()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await scope in connections {
                        if Task.isCancelled { break }
                        await self.connectionChanged(scope)
                    }
                }
                group.addTask { await self.drive(wakes) }
                _ = await group.next(); group.cancelAll()
            }
        } catch { }
        worker?.task.cancel(); await worker?.task.value
        worker = nil; await retireActiveBinding()
    }
    private func connectionChanged(_ scope: Scope?) async {
        guard connectionScope != scope else { return }
        connectionScope = scope; worker?.task.cancel()
        await retireActiveBinding(); wake?.yield(())
    }
    private func drive(_ wakes: AsyncStream<Void>) async {
        for await _ in wakes {
            if Task.isCancelled { break }
            if let worker, worker.generation == generation, worker.scope == connectionScope { continue }
            if let previous = worker {
                previous.task.cancel(); await previous.task.value
                if worker?.id == previous.id { worker = nil }
            }
            guard !Task.isCancelled, !closed, suspending == nil, !pages.isEmpty, let scope = connectionScope else {
                await retireActiveBinding(); continue
            }
            let snapshot = Array(pages.values), version = generation, id = UUID()
            let task = Task {
                await V2ConnectionRequestScope.$connectionID.withValue(scope.connectionID) {
                    await self.runConnection(pages: snapshot, generation: version, scope: scope)
                }
                self.workerFinished(id)
            }
            worker = .init(id: id, generation: version, scope: scope, task: task)
        }
        worker?.task.cancel(); await worker?.task.value; worker = nil
        await retireActiveBinding()
    }
    private func workerFinished(_ id: UUID) {
        if worker?.id == id { worker = nil }
    }
    private func requireCurrent(_ version: UUID, scope: Scope) async throws {
        try Task.checkCancellation()
        guard !closed, suspending == nil, generation == version, connectionScope == scope,
              await rooms.currentAuthorConnectionScope() == scope else { throw CancellationError() }
        try Task.checkCancellation()
        guard generation == version, connectionScope == scope else { throw CancellationError() }
    }
    private func preservingOtherPages(_ version: UUID, scope: Scope) -> Bool {
        !closed && suspending == nil && !pages.isEmpty && generation != version && connectionScope == scope
    }
    private func retireActiveBinding() async {
        guard let binding = activeBinding else { return }
        activeBinding = nil; await profiles.unbindAuthorView(binding)
    }
    private func retire(_ binding: V2ProfileAuthorBinding) async {
        if activeBinding == binding { activeBinding = nil }
        await profiles.unbindAuthorView(binding)
    }

    private func preservesIssuedGrant(after error: any Error) -> Bool {
        if let transport = error as? V2RealtimeTransportError,
           case .server(let code, let retryable, _, _) = transport {
            return retryable && code != "FORBIDDEN"
        }
        if let transport = error as? V2TLSFrameConnectionError {
            return transport == .requestTimedOut || transport == .tooManyPendingRequests
        }
        if let presentation = error as? V2ProfilePresentationError {
            switch presentation {
            case .overloaded, .throttled, .staleResponse: return true
            default: return false
            }
        }
        return false
    }

    static func renewalDeadline(expires: ContinuousClock.Instant, now: ContinuousClock.Instant,
                                lead: Duration) -> ContinuousClock.Instant {
        let remaining = max(.zero, now.duration(to: expires))
        // Normal 18–20 second Host grants must retain the configured 4–6
        // second jitter. A quarter-lifetime cap collapses most of that range.
        // Short grants still spend at least half their lifetime before renewal.
        return max(now, expires - min(lead, remaining / 2))
    }

    private func runConnection(pages snapshot: [Page], generation version: UUID, scope: Scope) async {
        let activations = Set(snapshot.map(\.activation))
        let messageRooms = Set(snapshot.compactMap(\.messageRoomID)).sorted { $0.rawValue < $1.rawValue }
        var lastBinding: V2ProfileAuthorBinding?
        while !Task.isCancelled {
            do {
                if let retryNotBefore, retryNotBefore > .now { try await ContinuousClock().sleep(until: retryNotBefore) }
                try await requireCurrent(version, scope: scope)
                let view = try await source.beginAuthorPresentationView(messageRoomIDs: messageRooms)
                do {
                    try await requireCurrent(version, scope: scope)
                    let binding = try await profiles.bindAuthorView(view, activations: activations)
                    lastBinding = binding; activeBinding = binding
                    try await requireCurrent(version, scope: scope)
                    try await subscriptions.startAuthorPresentation(view)
                    try await requireCurrent(version, scope: scope)
                    let lead = min(.seconds(10), max(.milliseconds(1), renewalLead()))
                    let renewAt = view.renewBy - lead
                    guard renewAt > .now else { throw V2ProfilePresentationError.staleResponse }
                    let renewal = AuthorViewRenewal(deadline: renewAt)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.publishVisibleKeys(view: view, activations: activations, generation: version, scope: scope) }
                        group.addTask {
                            while !Task.isCancelled {
                                let delta = try await self.source.nextAuthorPresentationDelta(for: view)
                                try await self.requireCurrent(version, scope: scope)
                                if let receipt = try await self.profiles.ingest(delta, binding: binding) {
                                    // Only applied grants may advance renewal. A
                                    // short Host qualification must not leave the
                                    // page waiting until the thirty-second view
                                    // boundary, and unobserved candidates must
                                    // not force repeated account-wide restarts.
                                    let applied = Set(receipt.keys)
                                    let expires = delta.entries.compactMap { entry -> ContinuousClock.Instant? in
                                        guard case .presentation(let value, _, let deadline, _) = entry,
                                              applied.contains(value.lease.key) else { return nil }
                                        return deadline
                                    }.min()
                                    if let expires {
                                        let instant = ContinuousClock.now
                                        await renewal.shorten(to: Self.renewalDeadline(expires: expires, now: instant, lead: lead))
                                    }
                                    try await self.requireCurrent(version, scope: scope)
                                    try await self.subscriptions.acknowledgeAuthorPresentation(receipt)
                                }
                            }
                        }
                        group.addTask { try await renewal.wait() }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                } catch { await finishView(view); throw error }
                await finishView(view)
            } catch {
                if let domain = error as? V2RealtimeTransportError,
                   case .server(_, let retryable, let seconds, _) = domain, retryable, seconds > 0 {
                    let until = ContinuousClock.now + .seconds(seconds) + retryJitter()
                    retryNotBefore = max(retryNotBefore ?? until, until)
                }
                let cancelled = Task.isCancelled || error is CancellationError
                // A transient failure stops this receiver, not the authority
                // already issued to its unchanged pages. The repository keeps
                // the original deadline; no retry or rebind can extend it.
                let preserve = cancelled ? preservingOtherPages(version, scope: scope) : preservesIssuedGrant(after: error)
                if let binding = lastBinding, !preserve {
                    await retire(binding); lastBinding = nil
                }
                if cancelled { break }
                if let transport = error as? V2TLSFrameConnectionError,
                   transport == .notConnected || transport == .connectionClosed { break }
                if let domain = error as? V2RealtimeTransportError {
                    if case .server(let code, let retryable, _, _) = domain {
                        if code == "FORBIDDEN" || !retryable { break }
                    } else if domain == .unexpectedResponse { break }
                }
                if let value = error as? V2ProfilePresentationError,
                   value == .inactive || value == .invalidResponse { break }
                do { try await Task.sleep(for: retryDelay) } catch { break }
            }
        }
        if let binding = lastBinding, !preservingOtherPages(version, scope: scope) { await retire(binding) }
    }
    private func finishView(_ view: V2AuthorPresentationView) async {
        await source.endAuthorPresentationView(view)
        // Cleanup starts uncancelled but inherits the original connection scope.
        // The worker slot remains owned until the actual stop completes.
        let cleanup = Task { [subscriptions] in try await subscriptions.stopAuthorPresentation(view) }
        _ = await cleanup.result
    }
    private func publishVisibleKeys(view: V2AuthorPresentationView, activations: Set<V2ProfilePageActivation>,
                                    generation version: UUID, scope: Scope) async throws {
        let id = UUID(), pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        interestSignal = (id, pair.continuation); pair.continuation.yield(())
        defer { pair.continuation.finish(); if interestSignal?.id == id { interestSignal = nil } }
        var previous: [V2ProfileViewLookupKey]?, sequence: UInt64 = 0
        for await _ in pair.stream {
            try Task.checkCancellation()
            if previous != nil { try await Task.sleep(for: .milliseconds(25)) }
            try await requireCurrent(version, scope: scope)
            let keys = try await profiles.visibleProfileKeys(for: activations)
            guard keys != previous else { continue }
            guard sequence < UInt64(Int64.max) else { throw V2ProfilePresentationError.invalidResponse }
            sequence += 1
            let interests = try V2AuthorPresentationInterests(streamID: view.streamID, viewID: view.viewID, sequence: sequence, keys: keys)
            try await requireCurrent(version, scope: scope)
            try await subscriptions.replaceAuthorPresentationInterests(interests)
            try Task.checkCancellation(); previous = keys
        }
        try Task.checkCancellation()
    }
}

/// One sleeper owned and drained by the view's structured child. Shortening
/// cancels that sleep; it never extends a grant or creates another receiver.
private actor AuthorViewRenewal {
    private var deadline: ContinuousClock.Instant
    private var sleeper: Task<Void, any Error>?
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func shorten(to proposed: ContinuousClock.Instant) {
        guard proposed < deadline else { return }
        deadline = proposed; sleeper?.cancel()
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let target = deadline
                let task = Task { try await ContinuousClock().sleep(until: target) }
                sleeper = task
                let result = await task.result
                sleeper = nil
                try Task.checkCancellation()
                switch result {
                case .success: return
                case .failure(let error):
                    guard error is CancellationError else { throw error }
                    // A newer, earlier deadline cancelled this particular sleep.
                }
            }
        } onCancel: { Task { await self.cancelSleep() } }
    }

    private func cancelSleep() { sleeper?.cancel() }
}
