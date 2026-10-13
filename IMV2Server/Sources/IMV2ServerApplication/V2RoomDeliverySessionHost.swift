import Foundation
import IMV2Core
import IMV2ActorContracts
import Synchronization

/// One factory-owned registry across every physical database resource. Sessions
/// and their bounded heartbeat worker scale with peers, never with rooms.
public actor V2RoomDeliverySessionHost {
    public typealias SendPulse = @Sendable (V2RoomDeliverySessionPulse, String, V2GatewayRealtimeDescriptor) async throws -> V2RoomDeliverySessionResult
    private struct Key: Hashable, Sendable { let host: V2ActorHostIdentity; let gateway: V2GatewayRealtimeIdentity }
    private struct Entry: Sendable {
        let session: V2RoomDeliverySession
        let descriptor: V2GatewayRealtimeDescriptor
        let shard: String
        var rooms: Set<V2RoomActivationToken>
        var sequence: UInt64 = 1
        var ready = false
        let control: V2RoomDeliveryControlProgress
    }
    private nonisolated let controls = Mutex<[Key: V2RoomDeliveryControlProgress]>([:])
    private var entries: [Key: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private var openings: [Key: Task<V2RoomDeliverySession, any Error>] = [:]
    private var send: SendPulse?
    private var hostReady: (@Sendable () async -> Bool)?
    private var worker: Task<Void, Never>?
    private var closed = false
    private let now: @Sendable () -> ContinuousClock.Instant
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) { self.now = now }
    /// Synchronous bounded enqueue/ACK bookkeeping; no Task is created and
    /// ordinary message delivery never enters this registry.
    public nonisolated func observeAuthorization(_ progress: V2RoomSubscriptionRelay.AuthorizationProgress,
                                                 gateway: V2GatewayRealtimeIdentity) {
        let key = Key(host: progress.fence.activation.host, gateway: gateway)
        let control = controls.withLock { $0[key] }
        control?.observe(progress)
    }
    public func configure(send: @escaping SendPulse, hostReady: @escaping @Sendable () async -> Bool) {
        precondition(self.send == nil && !closed)
        self.send = send; self.hostReady = hostReady
        worker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.pulse()
            }
        }
    }
    public func retain(activation: V2RoomActivationToken, gateway: V2GatewayRealtimeDescriptor) async throws -> V2RoomDeliverySession {
        guard !closed, send != nil, let hostReady, await hostReady() else { throw V2RoomCallFailure.notAccepted(.notReady) }
        guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
        let key = Key(host: activation.host, gateway: gateway.identity)
        if let entry = entries[key] {
            entries[key]?.rooms.insert(activation)
            entry.control.retain(activation)
            if entry.ready { return entry.session }
            return try await open(key: key, descriptor: gateway, shard: activation.owner.shardID).value
        }
        guard entries.count < 128 else { throw V2RoomCallFailure.notAccepted(.overloaded) }
        let task = open(key: key, descriptor: gateway, shard: activation.owner.shardID, rooms: [activation])
        return try await task.value
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
        entries[key] = Entry(session: session, descriptor: descriptor, shard: shard,
            rooms: entries[key]?.rooms ?? rooms, control: control)
        let task = Task {
            do {
                guard try await send(.init(session: session, kind: .open, sequence: 1), shard, descriptor) == .accepted else {
                    throw V2RoomCallFailure.notAccepted(.unavailable)
                }
                guard !closed, entries[key]?.session == session else { throw V2RoomCallFailure.notAccepted(.retired) }
                // Opening a successor closes all old Gateway projections. Only
                // a fresh room baseline may establish control responsibility.
                control.opened()
                entries[key]?.ready = true; openings.removeValue(forKey: key)
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
        guard var entry = entries[key] else { return }
        entry.rooms.remove(activation); entries[key] = entry
        entry.control.release(activation)
        guard entry.rooms.isEmpty else { return }
        if let opening = openings[key] { _ = await opening.result }
        guard let current = entries[key], current.rooms.isEmpty else { return }
        entries.removeValue(forKey: key)
        controls.withLock { $0.removeValue(forKey: key) }
        if let send { _ = try? await send(.init(session: current.session, kind: .retire, sequence: current.sequence + 1), current.shard, current.descriptor) }
    }
    /// Failure of the authorization lane retires its entire session. A heartbeat
    /// cannot keep stale grants alive; opening a successor only schedules reset.
    public func controlFailed(host: V2ActorHostIdentity, gateway: V2GatewayRealtimeIdentity) async {
        let key = Key(host: host, gateway: gateway)
        guard let entry = entries[key], entry.ready else { return }
        entries[key]?.ready = false
        if let send { _ = try? await send(.init(session: entry.session, kind: .retire, sequence: entry.sequence + 1), entry.shard, entry.descriptor) }
    }
    private func pulse() async {
        guard !closed, let send, let hostReady else { return }
        let healthy = await hostReady()
        guard !closed else { return }
        // Keep established peers ahead of reconnect work. Reopening a slow
        // peer must not consume the healthy peers' heartbeat interval.
        var work: [(Key, Entry, Bool)] = []
        for (key, var entry) in entries where entry.ready && !entry.rooms.isEmpty {
            let progress = entry.control.health()
            if healthy, progress == .stalled { continue }
            guard entry.sequence < UInt64.max else { entries[key]?.ready = false; continue }
            entry.sequence += 1; entries[key] = entry
            work.append((key, entry, healthy && progress == .ready))
        }
        await withTaskGroup(of: (Key, V2RoomDeliverySession, Bool).self) { group in
            var pending = work.makeIterator()
            func admit(_ item: (Key, Entry, Bool)) {
                let (key, entry, keepAlive) = item
                group.addTask {
                    let result = try? await send(.init(session: entry.session, kind: keepAlive ? .heartbeat : .retire,
                        sequence: entry.sequence), entry.shard, entry.descriptor)
                    return (key, entry.session, keepAlive && result == .accepted)
                }
            }
            for _ in 0..<8 { if let item = pending.next() { admit(item) } }
            for await (key, session, accepted) in group {
                if entries[key]?.session == session, !accepted { entries[key]?.ready = false }
                if !closed, !Task.isCancelled, let item = pending.next() { admit(item) }
            }
        }
        guard !closed, healthy, !Task.isCancelled else { return }
        let stale = entries.filter { !$0.value.ready && !$0.value.rooms.isEmpty }
        // The transport reserves eight pulse slots. Admit openings lazily so
        // a reconnect wave cannot overload those slots by spawning every peer.
        await withTaskGroup(of: Void.self) { group in
            var pending = stale.makeIterator()
            func admit(_ item: (key: Key, value: Entry)) {
                let opening = open(key: item.key, descriptor: item.value.descriptor, shard: item.value.shard)
                group.addTask { _ = await opening.result }
            }
            for _ in 0..<8 { if let item = pending.next() { admit(item) } }
            for await _ in group {
                if !closed, !Task.isCancelled, let item = pending.next() { admit(item) }
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true; worker?.cancel()
        let pending = Array(openings.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        await worker?.value
        if let send {
            await withTaskGroup(of: Void.self) { group in
                var pending = Array(entries.values).makeIterator()
                func admit(_ entry: Entry) {
                    group.addTask {
                        _ = try? await send(.init(session: entry.session, kind: .retire,
                            sequence: entry.sequence + 1), entry.shard, entry.descriptor)
                    }
                }
                for _ in 0..<8 { if let entry = pending.next() { admit(entry) } }
                for await _ in group { if let entry = pending.next() { admit(entry) } }
            }
        }
        entries.removeAll(); openings.removeAll()
        controls.withLock { $0.removeAll() }
    }
}

/// The oldest pending control determines peer health. Queue entries are
/// appended only for a new pending room; ACK removes by token. Lazy removal
/// is amortized and periodically compacted to keep storage bounded.
private final class V2RoomDeliveryControlProgress: Sendable {
    enum Health { case ready, stalled, expired }
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
    func retain(_ token: V2RoomActivationToken) { state.withLock { $0.rooms.insert(token) } }
    func release(_ token: V2RoomActivationToken) {
        state.withLock { value in
            value.rooms.remove(token); value.pending.removeValue(forKey: token)
            if let old = value.latest.removeValue(forKey: token) { value.ignoredFences.remove(old.fence) }
            value.compact()
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
    func health() -> Health {
        state.withLock { value in
            if value.invalidated { return .expired }
            while value.index < value.queue.count {
                let item = value.queue[value.index]
                guard let pending = value.pending[item.0], pending.id == item.1 else { value.index += 1; continue }
                let age = pending.startedAt.duration(to: now())
                if age >= .seconds(10) { return .expired }
                return age >= .seconds(2) ? .stalled : .ready
            }
            return .ready
        }
    }
}
