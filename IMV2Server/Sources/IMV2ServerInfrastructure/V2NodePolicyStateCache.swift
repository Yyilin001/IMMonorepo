import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Shared versioned facts for every room on this node. Snapshot reads never
/// expire or renew ownership. The older lease APIs below serve only legacy
/// registered authorization; the Gateway uses loadSnapshots/install exclusively.
package actor V2NodePolicyStateCache {
    package typealias Loader = @Sendable ([V2PolicyAuthorizationScope], Bool) async throws -> [V2PolicyOwnerState]
    private struct Entry {
        let state: V2PolicyOwnerState
        var usedAt: ContinuousClock.Instant
    }
    private struct Flight {
        let id: UUID
        let task: Task<[V2PolicyOwnerState], any Error>
    }
    private let maximumEntries: Int
    private let maximumLoads: Int
    private var entries: [String: Entry] = [:]
    private var order = V2IndexedFIFO<String, String>()
    private var flights: [String: Flight] = [:]
    private var invalidated: Set<String> = []
    private var loop: Task<Void, Never>?
    private var closed = false
    package typealias SnapshotLoader = @Sendable ([V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot]
    private struct SnapshotFlight {
        let id: UUID
        let task: Task<[V2PolicyFactsSnapshot], any Error>
    }
    private var snapshots: [String: V2PolicyFactsSnapshot] = [:]
    private var snapshotOrder = V2IndexedFIFO<String, String>()
    private var snapshotFlights: [String: SnapshotFlight] = [:]
    private var pendingSnapshots: [String: V2PolicyFactsSnapshot] = [:]

    package func cachedSnapshots(scopes: [V2PolicyAuthorizationScope], requestedAt: ContinuousClock.Instant? = nil) throws -> [V2PolicyFactsSnapshot]? {
        if let requestedAt { V2SendPathTrace.current?.record("policy_cache_actor_entry_wait", from: requestedAt) }
        try validate(scopes)
        guard scopes.allSatisfy({ snapshots[$0.key] != nil }) else { return nil }
        return scopes.map {
            snapshotOrder.remove($0.key); snapshotOrder.append($0.key, key: $0.key)
            return snapshots[$0.key]!
        }
    }

    /// Updates do not populate unrelated Gateway scopes. A scope currently
    /// loading is interested too: a newer push must win against its old reply.
    package func install(_ snapshot: V2PolicyFactsSnapshot, interestedOnly: Bool = false) throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let key = snapshot.scope.key
        if interestedOnly, snapshots[key] == nil, snapshotFlights[key] == nil { return }
        if let current = pendingSnapshots[key] ?? snapshots[key] {
            if snapshot.version < current.version { return }
            if snapshot.version == current.version {
                guard snapshot == current else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                if snapshots[key] != nil { return }
            }
        }
        if snapshotFlights[key] != nil { pendingSnapshots[key] = snapshot }
        if snapshots[key] == nil, snapshots.count >= maximumEntries,
           let victim = snapshotOrder.removeFirst() { snapshots[victim] = nil }
        snapshots[key] = snapshot
        snapshotOrder.remove(key); snapshotOrder.append(key, key: key)
    }

    /// No logical-read concurrency quota. Only the SQL loader acquires a
    /// database resource allowance; callers for the same scope share its task.
    package func loadSnapshots(scopes: [V2PolicyAuthorizationScope], requestedAt: ContinuousClock.Instant? = nil, loader: @escaping SnapshotLoader)
        async throws -> [V2PolicyFactsSnapshot] {
        if let requestedAt { V2SendPathTrace.current?.record("policy_cache_load_actor_entry_wait", from: requestedAt) }
        try validate(scopes)
        if let cached = try cachedSnapshots(scopes: scopes) { return cached }
        let missing = scopes.filter { snapshots[$0.key] == nil }
        let newScopes = missing.filter { snapshotFlights[$0.key] == nil }
        let trace = V2SendPathTrace.current
        if missing.count > newScopes.count { trace?.mark("policy_shared_flight_join") }
        if !newScopes.isEmpty {
            trace?.mark("policy_new_flight")
            let id = UUID(), deadline = V2RoomSQLDeadline.current
            let registeredAt = ContinuousClock.now
            let task = Task.detached {
                trace?.record("policy_flight_start_wait", from: registeredAt)
                let result: Result<[V2PolicyFactsSnapshot], any Error>
                let startedAt = ContinuousClock.now
                do { result = .success(try await V2SendPathTrace.$current.withValue(trace) {
                    try await V2RoomSQLDeadline.withSelectedDeadline(deadline) { try await loader(newScopes) }
                }) } catch { result = .failure(error) }
                trace?.record("policy_flight_fetch", from: startedAt)
                let installStartedAt = ContinuousClock.now
                let settled = await self.snapshotsFinished(id: id, scopes: newScopes, result: result)
                trace?.record("policy_flight_install", from: installStartedAt)
                return try settled.get()
            }
            for scope in newScopes { snapshotFlights[scope.key] = .init(id: id, task: task) }
        }
        var tasks: [UUID: Task<[V2PolicyFactsSnapshot], any Error>] = [:]
        for scope in missing {
            if let flight = snapshotFlights[scope.key] { tasks[flight.id] = flight.task }
        }
        var loaded: [String: V2PolicyFactsSnapshot] = [:]
        let waitStartedAt = ContinuousClock.now
        for task in tasks.values {
            for state in try await task.value { loaded[state.scope.key] = state }
        }
        trace?.record("policy_flight_wait", from: waitStartedAt)
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        // Results remain available to actual waiters even if a tiny LRU budget
        // evicts one of their scopes while a different task finishes.
        return try scopes.map {
            guard let state = snapshots[$0.key] ?? loaded[$0.key] else { throw V2PolicyAuthorizationLifecycleError.busy }
            return state
        }
    }

    private func snapshotsFinished(id: UUID, scopes: [V2PolicyAuthorizationScope],
        result: Result<[V2PolicyFactsSnapshot], any Error>) -> Result<[V2PolicyFactsSnapshot], any Error> {
        defer { for scope in scopes where snapshotFlights[scope.key]?.id == id { snapshotFlights[scope.key] = nil; pendingSnapshots[scope.key] = nil } }
        guard !closed else { return .failure(V2PolicyAuthorizationLifecycleError.closed) }
        do {
            let states = try result.get()
            guard states.count == scopes.count, Set(states.map { $0.scope.key }) == Set(scopes.map(\.key)) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            // Capture updates before installing/evicting other batch members.
            let resolved = states.map { incoming in
                (pendingSnapshots[incoming.scope.key] ?? snapshots[incoming.scope.key]).map { $0.version > incoming.version ? $0 : incoming } ?? incoming
            }
            for state in resolved { try install(state) }
            return .success(resolved)
        } catch { return .failure(error) }
    }


    package init(maximumEntries: Int = 32_768, maximumLoads: Int = 128) {
        precondition(maximumEntries > 0 && maximumLoads > 0)
        self.maximumEntries = maximumEntries; self.maximumLoads = maximumLoads
    }

    package func cached(scopes: [V2PolicyAuthorizationScope], touch: Bool = true) throws -> [V2PolicyOwnerState]? {
        try validate(scopes)
        let now = ContinuousClock.now
        guard scopes.allSatisfy({ entries[$0.key].map { $0.state.deadline > now } == true }) else { return nil }
        return scopes.map {
            if touch {
                entries[$0.key]!.usedAt = now
                order.remove($0.key); order.append($0.key, key: $0.key)
            }
            return entries[$0.key]!.state
        }
    }

    package func load(scopes: [V2PolicyAuthorizationScope], refresh: Bool = false,
                      loader: @escaping Loader) async throws -> [V2PolicyOwnerState] {
        try validate(scopes)
        if !refresh, let cached = try cached(scopes: scopes) { return cached }
        let now = ContinuousClock.now
        let missing = scopes.filter { refresh || entries[$0.key].map { $0.state.deadline > now } != true }
        let newScopes = missing.filter { flights[$0.key] == nil }
        if !newScopes.isEmpty {
            guard Set(flights.values.map(\.id)).count < maximumLoads else { throw V2PolicyAuthorizationLifecycleError.busy }
            let id = UUID(), deadline = V2RoomSQLDeadline.current
            let task = Task.detached {
                let result: Result<[V2PolicyOwnerState], any Error>
                do { result = .success(try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                    try await loader(newScopes, refresh)
                }) } catch { result = .failure(error) }
                return try await self.finished(id: id, scopes: newScopes, result: result).get()
            }
            for scope in newScopes { flights[scope.key] = .init(id: id, task: task) }
        }
        // Capture actual tasks before suspending. Cancellation of a caller
        // does not abandon the shared load or free its capacity prematurely.
        var tasks: [UUID: Task<[V2PolicyOwnerState], any Error>] = [:]
        for scope in missing {
            if let flight = flights[scope.key] { tasks[flight.id] = flight.task }
        }
        for task in tasks.values { _ = try await task.value }
        try Task.checkCancellation()
        guard let result = try cached(scopes: scopes, touch: !refresh) else { throw V2PolicyAuthorizationLifecycleError.busy }
        return result
    }

    package func invalidate(_ key: String) {
        entries[key] = nil; order.remove(key)
        if flights[key] != nil { invalidated.insert(key) }
    }

    private func finished(id: UUID, scopes: [V2PolicyAuthorizationScope],
        result: Result<[V2PolicyOwnerState], any Error>) -> Result<[V2PolicyOwnerState], any Error> {
        var stale: Set<String> = []
        for scope in scopes where flights[scope.key]?.id == id {
            flights[scope.key] = nil
            if invalidated.remove(scope.key) != nil { stale.insert(scope.key) }
        }
        guard !closed else { return .failure(V2PolicyAuthorizationLifecycleError.closed) }
        guard case .success(let states) = result else { return result }
        guard states.count == scopes.count, Set(states.map { $0.owner.scope.key }) == Set(scopes.map(\.key)),
              states.allSatisfy({ $0.deadline > .now }) else {
            return .failure(V2PolicyAuthorizationLifecycleError.invalidTarget)
        }
        // One changed scope cannot discard independent facts in the same RPC
        // batch. Only callers depending on that scope observe a cache miss.
        let usable = states.filter { !stale.contains($0.owner.scope.key) }
        for state in usable {
            let key = state.owner.scope.key
            let usedAt = entries[key]?.usedAt ?? .now
            if entries[key] == nil, entries.count == maximumEntries, let victim = order.removeFirst() {
                entries[victim] = nil
            }
            entries[key] = .init(state: state, usedAt: usedAt)
            order.remove(key); order.append(key, key: key)
        }
        return .success(usable)
    }

    package func start(loader: @escaping Loader) throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard loop == nil else { return }
        loop = Task.detached {
            while !Task.isCancelled {
                await self.refreshOnce(loader: loader)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// Bound background work separately from message-triggered cold loads.
    /// Recently used entries renew before expiry; idle entries cease renewing.
    package func refreshOnce(loader: @escaping Loader) async {
        guard !closed else { return }
        let now = ContinuousClock.now
        let due = entries.values.filter {
            $0.usedAt > now - .seconds(60) && $0.state.deadline <= now + .seconds(10)
                && flights[$0.state.owner.scope.key] == nil
        }.sorted { $0.state.deadline < $1.state.deadline }.prefix(512).map { $0.state.owner.scope }
        let batches = stride(from: 0, to: due.count, by: 4).map { Array(due[$0..<min($0 + 4, due.count)]) }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(4, batches.count) {
                let scopes = batches[next]; next += 1
                group.addTask { _ = try? await self.load(scopes: scopes, refresh: true, loader: loader) }
            }
            while await group.next() != nil {
                if next < batches.count {
                    let scopes = batches[next]; next += 1
                    group.addTask { _ = try? await self.load(scopes: scopes, refresh: true, loader: loader) }
                }
            }
        }
    }

    package func shutdown() async {
        closed = true; loop?.cancel()
        let snapshotTasks = Array(snapshotFlights.values.map(\.task))
        for task in snapshotTasks { _ = await task.result }
        snapshots.removeAll(); snapshotOrder.removeAll()
        if let loop { await loop.value }
        let tasks = flights.values.map(\.task)
        for task in tasks { _ = await task.result }
        entries.removeAll(); order = .init(); loop = nil
    }

    private func validate(_ scopes: [V2PolicyAuthorizationScope]) throws {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
    }
}
