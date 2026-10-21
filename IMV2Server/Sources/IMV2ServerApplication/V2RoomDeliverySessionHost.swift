import Foundation
import IMV2Core
import IMV2ActorContracts
import Synchronization
import Logging

/// Lifecycle-bound Host/Gateway generations. Idle sessions have no heartbeat or
/// periodic scan. Only pending authorization owns a cancellable deadline task.
public actor V2RoomDeliverySessionHost {
    public typealias SendPulse = @Sendable (V2RoomDeliverySessionPulse, String, V2GatewayRealtimeDescriptor) async throws -> V2RoomDeliverySessionResult
    private struct Key: Hashable, Sendable { let host: V2ActorHostIdentity; let gateway: V2GatewayRealtimeIdentity }
    private struct Entry: Sendable {
        let session: V2RoomDeliverySession
        let descriptor: V2GatewayRealtimeDescriptor
        let shard: String
        var ready = false
        var invalidated = false
        let control: V2RoomDeliveryControlProgress
    }
    private struct Deadline {
        let session: V2RoomDeliverySession
        let at: ContinuousClock.Instant
        let task: Task<Void, Never>
    }
    private nonisolated let controls = Mutex<[Key: V2RoomDeliveryControlProgress]>([:])
    private nonisolated let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var entries: [Key: Entry] = [:]
    private var deadlines: [Key: Deadline] = [:]
    private var timerTasks: [UUID: Task<Void, Never>] = [:]
    private var nextGeneration: UInt64 = 0
    private var openings: [Key: Task<V2RoomDeliverySession, any Error>] = [:]
    private var send: SendPulse?
    private var hostReady: (@Sendable () async -> Bool)?
    private var controlWorker: Task<Void, Never>?
    private var lifecycleWorker: Task<Void, Never>?
    private var closed = false
    private let now: @Sendable () -> ContinuousClock.Instant
    private let logger = Logger(label: "im.v2.room.delivery.session")
    private let controlAckTimeout: Duration
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, controlAckTimeout: Duration = .seconds(10)) {
        precondition(controlAckTimeout > .zero)
        self.now = now; self.controlAckTimeout = controlAckTimeout
    }
    public nonisolated func observeAuthorization(_ progress: V2RoomSubscriptionRelay.AuthorizationProgress,
                                                 gateway: V2GatewayRealtimeIdentity) {
        let key = Key(host: progress.fence.activation.host, gateway: gateway)
        guard let control = controls.withLock({ $0[key] }) else { return }
        control.observe(progress)
        wakes.continuation.yield(())
    }
    public func configure(send: @escaping SendPulse, hostReady: @escaping @Sendable () async -> Bool,
                          invalidations: AsyncStream<Void> = AsyncStream { $0.finish() }) {
        precondition(self.send == nil && !closed)
        self.send = send; self.hostReady = hostReady
        controlWorker = Task { [weak self, stream = wakes.stream] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.reconcileDeadlines()
            }
        }
        lifecycleWorker = Task { [weak self] in
            for await _ in invalidations {
                guard !Task.isCancelled, let self else { return }
                await self.lifecycleChanged()
            }
        }
    }
    public func retain(activation: V2RoomActivationToken, gateway: V2GatewayRealtimeDescriptor,
                       replacing expected: V2RoomDeliverySession? = nil) async throws -> V2RoomDeliverySession {
        if let expected {
            try expected.validate()
            guard expected.host == activation.host, expected.gateway == gateway.identity else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
        }
        guard !closed, send != nil, let hostReady, await hostReady() else { throw V2RoomCallFailure.notAccepted(.notReady) }
        guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
        let key = Key(host: activation.host, gateway: gateway.identity)
        // Native reachability can fail on only one side. A signed recovery
        // request closes the exact stale local generation without another
        // pulse, heartbeat or database check. Concurrent repairs join open().
        if let expected, let entry = entries[key], entry.session == expected, entry.ready {
            peerUnavailable(host: key.host, gateway: key.gateway)
        }
        if let entry = entries[key] {
            entry.control.retain(activation)
            if entry.ready { return entry.session }
            return try await open(key: key, descriptor: gateway, shard: activation.owner.shardID).value
        }
        guard entries.count < 128 else { throw V2RoomCallFailure.notAccepted(.overloaded) }
        return try await open(key: key, descriptor: gateway, shard: activation.owner.shardID, rooms: [activation]).value
    }
    private func open(key: Key, descriptor: V2GatewayRealtimeDescriptor, shard: String,
                      rooms: Set<V2RoomActivationToken> = []) -> Task<V2RoomDeliverySession, any Error> {
        if let pending = openings[key] { return pending }
        guard !closed, let send, nextGeneration < UInt64.max else {
            return Task { throw V2RoomCallFailure.notAccepted(.overloaded) }
        }
        nextGeneration += 1
        let session = V2RoomDeliverySession(host: key.host, gateway: key.gateway, generation: nextGeneration)
        let control = entries[key]?.control ?? V2RoomDeliveryControlProgress(now: now)
        for room in rooms { control.retain(room) }
        controls.withLock { $0[key] = control }
        entries[key] = Entry(session: session, descriptor: descriptor, shard: shard, control: control)
        let task = Task {
            do {
                guard try await send(.init(session: session, kind: .open, sequence: 1), shard, descriptor) == .accepted else {
                    throw V2RoomCallFailure.notAccepted(.unavailable)
                }
                guard !closed, entries[key]?.session == session, entries[key]?.invalidated == false else { throw V2RoomCallFailure.notAccepted(.retired) }
                control.opened(); entries[key]?.ready = true; openings.removeValue(forKey: key)
                return session
            } catch {
                if entries[key]?.session == session { entries[key]?.ready = false; openings.removeValue(forKey: key) }
                throw error
            }
        }
        openings[key] = task
        return task
    }
    public func release(activation: V2RoomActivationToken, gateway: V2GatewayRealtimeIdentity) async {
        let key = Key(host: activation.host, gateway: gateway)
        guard let entry = entries[key] else { return }
        let exposed = entry.control.release(activation)
        // Removing a room does not revoke the baseline already installed at
        // the Gateway. Fail the old generation before forgetting that authority,
        // even when other rooms keep this Host/Gateway session referenced.
        if exposed { await controlFailed(host: key.host, gateway: key.gateway) }
        wakes.continuation.yield(())
        guard !entry.control.hasRooms else { return }
        if let opening = openings[key] { _ = await opening.result }
        guard let current = entries[key], !current.control.hasRooms else { return }
        entries.removeValue(forKey: key); controls.withLock { $0.removeValue(forKey: key) }
        let deadline = deadlines.removeValue(forKey: key); deadline?.task.cancel(); await deadline?.task.value
        if let send { _ = try? await send(.init(session: current.session, kind: .retire, sequence: 2), current.shard, current.descriptor) }
    }
    /// Native peer loss closes local reuse immediately; there is no reconnect
    /// poll. The next trusted acquisition opens a successor and fresh baseline.
    public func peerUnavailable(host: V2ActorHostIdentity, gateway: V2GatewayRealtimeIdentity) {
        let key = Key(host: host, gateway: gateway)
        entries[key]?.ready = false; entries[key]?.invalidated = true
        deadlines.removeValue(forKey: key)?.task.cancel()
    }
    public func controlFailed(host: V2ActorHostIdentity, gateway: V2GatewayRealtimeIdentity) async {
        let key = Key(host: host, gateway: gateway)
        guard let entry = entries[key], entry.ready else { return }
        peerUnavailable(host: host, gateway: gateway)
        if let send { _ = try? await send(.init(session: entry.session, kind: .retire, sequence: 2), entry.shard, entry.descriptor) }
    }
    /// Keep the production transport boundary and its failure policy together.
    /// A missing authorization receipt cannot prove that a revoke reached the
    /// peer, so it fails the current shared session closed. Room retirement
    /// preserves siblings only when its terminal receipt is acknowledged.
    public nonisolated func guardedSender(_ sendBatch: @escaping V2RoomSubscriptionDeliveryPump.SendBatch) -> V2RoomSubscriptionDeliveryPump.SendBatch {
        { batch, shard, gateway in
            do {
                let result = try await sendBatch(batch, shard, gateway)
                if batch.deliveries.contains(where: { $0.payload.isAuthorizationControl }),
                   result.receipts.contains(where: { receipt in
                       if case .appliedThrough = receipt.result { return false }; return true
                   }) {
                    let rejected = Set(result.receipts.compactMap { receipt -> V2RoomSubscriptionFence? in
                        if case .appliedThrough = receipt.result { return nil }; return receipt.fence
                    })
                    await self.controlDeliveryFailed(batch.deliveries.filter {
                        $0.payload.isAuthorizationControl && rejected.contains($0.fence)
                    }, gateway: gateway.identity)
                }
                return result
            }
            catch {
                let controls = batch.deliveries.filter { $0.payload.isAuthorizationControl }
                if !controls.isEmpty { await self.controlDeliveryFailed(controls, gateway: gateway.identity) }
                throw error
            }
        }
    }

    /// A late transport result is not evidence against a replacement baseline
    /// or session. Only failure of a currently unacknowledged control may close
    /// the shared session; unrelated rooms must not inherit obsolete failures.
    public func controlDeliveryFailed(_ deliveries: [V2RoomSubscriptionDelivery], gateway: V2GatewayRealtimeIdentity) async {
        guard let delivery = deliveries.first(where: { $0.payload.isAuthorizationControl }) else { return }
        let key = Key(host: delivery.fence.activation.host, gateway: gateway)
        guard let entry = entries[key], entry.ready, entry.control.hasPendingControl(in: deliveries) else { return }
        await controlFailed(host: key.host, gateway: gateway)
    }
    private func reconcileDeadlines() {
        guard !closed else { return }
        for (key, entry) in entries where entry.ready {
            guard let at = entry.control.deadline(timeout: controlAckTimeout) else {
                deadlines.removeValue(forKey: key)?.task.cancel(); continue
            }
            if let old = deadlines[key], old.session == entry.session, old.at == at { continue }
            deadlines.removeValue(forKey: key)?.task.cancel()
            let delay = max(.zero, now().duration(to: at))
            let id = UUID()
            let session = entry.session
            let task = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                    await self?.deadlineReached(key: key, session: session, at: at)
                } catch { }
                await self?.timerFinished(id)
            }
            timerTasks[id] = task
            deadlines[key] = .init(session: entry.session, at: at, task: task)
        }
    }
    private func deadlineReached(key: Key, session: V2RoomDeliverySession, at: ContinuousClock.Instant) async {
        guard !closed, let entry = entries[key], entry.ready, entry.session == session,
              deadlines[key]?.at == at else { return }
        deadlines.removeValue(forKey: key)
        // An ACK can arrive before this task gets its Actor turn. Recheck the
        // actual oldest pending control; duplicates never extend its deadline.
        if let actual = entry.control.deadline(timeout: controlAckTimeout), actual <= now() {
            let diagnostic = entry.control.diagnostic
            logger.warning("Room delivery session control deadline reached", metadata: [
                "control_invalidated": .stringConvertible(diagnostic.invalidated),
                "pending_controls": .stringConvertible(diagnostic.pending),
                "oldest_pending_ms": .stringConvertible(diagnostic.oldestPendingMilliseconds)
            ])
            await controlFailed(host: key.host, gateway: key.gateway)
        } else { reconcileDeadlines() }
    }
    private func timerFinished(_ id: UUID) { timerTasks.removeValue(forKey: id) }
    private func lifecycleChanged() async {
        guard !closed else { return }
        await invalidateAll()
    }
    private func invalidateAll() async {
        let current = Array(entries.values)
        for entry in current { peerUnavailable(host: entry.session.host, gateway: entry.session.gateway) }
        guard let send else { return }
        await withTaskGroup(of: Void.self) { group in
            var pending = current.makeIterator()
            func admit(_ entry: Entry) {
                group.addTask { _ = try? await send(.init(session: entry.session, kind: .retire, sequence: 2), entry.shard, entry.descriptor) }
            }
            for _ in 0..<8 { if let entry = pending.next() { admit(entry) } }
            for await _ in group { if let entry = pending.next() { admit(entry) } }
        }
    }
    public func close() async {
        guard !closed else { return }
        closed = true
        await invalidateAll()
        wakes.continuation.finish(); controlWorker?.cancel(); lifecycleWorker?.cancel()
        let timers = Array(timerTasks.values); deadlines.removeAll()
        for timer in timers { timer.cancel() }
        let pending = Array(openings.values); for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        await controlWorker?.value; await lifecycleWorker?.value
        for timer in timers { await timer.value }
        timerTasks.removeAll()
        entries.removeAll(); openings.removeAll(); controls.withLock { $0.removeAll() }
    }
    package func activeControlDeadlines() -> Int { deadlines.count }
}

/// The oldest pending control determines peer health. Queue entries are
/// appended only for a new pending room; ACK removes by token. Lazy removal
/// is amortized and periodically compacted to keep storage bounded.
private final class V2RoomDeliveryControlProgress: Sendable {
    private struct Pending: Sendable {
        let id: UInt64
        let startedAt: ContinuousClock.Instant
    }
    private struct State: Sendable {
        var rooms: Set<V2RoomActivationToken> = []
        var latest: [V2RoomActivationToken: V2RoomSubscriptionRelay.AuthorizationProgress] = [:]
        var ignoredFences: Set<V2RoomSubscriptionFence> = []
        var pending: [V2RoomActivationToken: Pending] = [:]
        var nextPendingID: UInt64 = 0
        var queue: [(V2RoomActivationToken, UInt64)] = []
        var index = 0
        var invalidated = false
        mutating func compact() {
            if queue.count - index > max(1024, pending.count * 2) || index > 1024 {
                queue = queue.dropFirst(index).filter { pending[$0.0]?.id == $0.1 }; index = 0
            }
        }
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant
    init(now: @escaping @Sendable () -> ContinuousClock.Instant) { self.now = now }
    var hasRooms: Bool { state.withLock { !$0.rooms.isEmpty } }
    func retain(_ token: V2RoomActivationToken) { state.withLock { $0.rooms.insert(token) } }
    func release(_ token: V2RoomActivationToken) -> Bool {
        state.withLock { value in
            let previous = value.latest[token]
            let exposed = previous.map {
                $0.transmissionStarted && !$0.isUnreferenced && !value.ignoredFences.contains($0.fence)
            } ?? false
            value.rooms.remove(token); value.pending.removeValue(forKey: token)
            if let old = value.latest.removeValue(forKey: token) { value.ignoredFences.remove(old.fence) }
            value.compact()
            return exposed
        }
    }
    func opened() {
        state.withLock { value in
            value.ignoredFences = Set(value.latest.values.map(\.fence))
            value.pending.removeAll(); value.queue.removeAll(); value.index = 0; value.invalidated = false
        }
    }
    func observe(_ progress: V2RoomSubscriptionRelay.AuthorizationProgress) {
        state.withLock { value in
            let token = progress.fence.activation
            guard value.rooms.contains(token), progress.applied <= progress.issued,
                  !value.ignoredFences.contains(progress.fence) else { return }
            if let old = value.latest[token] {
                guard progress.fence.generation >= old.fence.generation else { return }
                if progress.fence.generation == old.fence.generation {
                    guard progress.fence == old.fence, progress.issued >= old.issued,
                          progress.applied >= old.applied else { return }
                } else { value.ignoredFences.remove(old.fence) }
            }
            value.latest[token] = progress
            // A first grant abandoned before activate has never authorized
            // the Gateway. It cannot make unrelated rooms lose this session.
            // Once any prefix was attempted, enqueue-time revocation deadlines
            // remain mandatory, including across room fence resets.
            guard progress.transmissionStarted else {
                value.pending.removeValue(forKey: token)
                value.compact()
                return
            }
            if progress.invalidated { value.invalidated = true }
            if progress.applied == progress.issued { value.pending.removeValue(forKey: token) }
            else if value.pending[token] == nil {
                guard value.nextPendingID < .max else { value.invalidated = true; return }
                value.nextPendingID += 1
                let pending = Pending(id: value.nextPendingID, startedAt: now())
                value.pending[token] = pending; value.queue.append((token, pending.id))
            }
            value.compact()
        }
    }
    func hasPendingControl(in deliveries: [V2RoomSubscriptionDelivery]) -> Bool {
        state.withLock { value in
            deliveries.contains { delivery in
                guard delivery.payload.isAuthorizationControl,
                      value.rooms.contains(delivery.fence.activation),
                      !value.ignoredFences.contains(delivery.fence),
                      let current = value.latest[delivery.fence.activation], current.fence == delivery.fence,
                      current.transmissionStarted else { return false }
                return current.applied < delivery.authorizationSequence && delivery.authorizationSequence <= current.issued
            }
        }
    }
    var diagnostic: (invalidated: Bool, pending: Int, oldestPendingMilliseconds: Int64) {
        state.withLock { value in
            let oldest = value.pending.values.map(\.startedAt).min()
            let elapsed = oldest.map { $0.duration(to: now()).components }
            let milliseconds = elapsed.map { $0.seconds * 1_000 + $0.attoseconds / 1_000_000_000_000_000 } ?? 0
            return (value.invalidated, value.pending.count, milliseconds)
        }
    }
    func deadline(timeout: Duration) -> ContinuousClock.Instant? {
        state.withLock { value in
            if value.invalidated { return now() }
            while value.index < value.queue.count {
                let item = value.queue[value.index]
                guard let pending = value.pending[item.0], pending.id == item.1 else { value.index += 1; continue }
                return pending.startedAt + timeout
            }
            return nil
        }
    }
}
