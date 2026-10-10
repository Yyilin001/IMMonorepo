import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Shared versioned facts for every room on this node. Snapshot reads never
/// expire or renew ownership; committed updates advance their versions.
package actor V2NodePolicyStateCache {
    private let maximumEntries: Int
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


    package init(maximumEntries: Int = 32_768) {
        precondition(maximumEntries > 0)
        self.maximumEntries = maximumEntries
    }

    package func shutdown() async {
        closed = true
        let tasks = Array(snapshotFlights.values.map(\.task))
        for task in tasks { _ = await task.result }
        snapshots.removeAll(); snapshotOrder.removeAll(); pendingSnapshots.removeAll()
    }

    private func validate(_ scopes: [V2PolicyAuthorizationScope]) throws {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
    }
}
