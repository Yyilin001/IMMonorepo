import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Shared versioned facts for every room on this node. Snapshot reads never
/// expire or renew ownership; committed updates advance their versions.
package actor V2NodePolicyStateCache {
    private typealias Key = V2PolicyAuthorizationScope
    private let maximumEntries: Int
    private let identity: V2ActorHostIdentity?
    private let now: @Sendable () -> ContinuousClock.Instant
    private final class Session {
        let wire: V2PolicyControlSessionWire
        var deadline: ContinuousClock.Instant
        var sequence: UInt64 = 0
        var retired = false
        init(_ wire: V2PolicyControlSessionWire, now: ContinuousClock.Instant) {
            self.wire = wire; deadline = now + .seconds(10)
        }
        func ready(at now: ContinuousClock.Instant) -> Bool {
            if now >= deadline { retired = true }
            return !retired
        }
    }
    private var sessions: [V2ActorHostIdentity: Session] = [:]
    private var currentSources: [V2ActorHostID: V2ActorHostIdentity] = [:]
    private var scopeSources: [Key: V2ActorHostIdentity] = [:]
    private var scopeSessions: [Key: V2PolicyControlSessionWire] = [:]
    private struct InterestRoute: Hashable, Sendable {
        let source: V2ActorHostIdentity
        let endpoint: String
    }
    private struct Interest: Sendable {
        let route: InterestRoute
        let revision: UInt64
    }
    private struct Releases: Sendable {
        var scopes: [Key: UInt64] = [:]
        var resetThrough: UInt64?
        var resetSessionGeneration: UInt64?
    }
    package typealias ReleaseInterests = @Sendable (V2PolicyInterestReleaseWire) async throws -> Void
    private let subscriber: V2PolicySnapshotSubscriberWire?
    private let releaseInterests: ReleaseInterests?
    private let maximumPendingReleases: Int
    private var nextInterestRevision: UInt64 = 0
    private var interests: [Key: Interest] = [:]
    private var releases: [InterestRoute: Releases] = [:]
    private var releaseRouteOrder = V2IndexedFIFO<InterestRoute, InterestRoute>()
    private var pendingReleaseCount = 0
    private let releaseWakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var releaseWorker: Task<Void, Never>?
    private var closed = false
    package typealias SnapshotLoader = @Sendable ([V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot]
    private struct LoadedSnapshot: Sendable {
        let facts: V2PolicyFactsSnapshot
        let session: V2PolicyControlSessionWire?
    }
    private struct SnapshotFlight {
        let id: UUID
        let task: Task<[LoadedSnapshot], any Error>
    }
    private var snapshots: [Key: V2PolicyFactsSnapshot] = [:]
    private var snapshotOrder = V2IndexedFIFO<Key, Key>()
    private var snapshotFlights: [Key: SnapshotFlight] = [:]
    private var pendingSnapshots: [Key: V2PolicyFactsSnapshot] = [:]
    private var invalidatedFlights: Set<UUID> = []

    package func invalidate(_ scope: V2PolicyAuthorizationScope) {
        let key = scope.canonical
        snapshots.removeValue(forKey: key); pendingSnapshots.removeValue(forKey: key)
        snapshotOrder.remove(key)
        if let flight = snapshotFlights[key] {
            invalidatedFlights.insert(flight.id); flight.task.cancel()
        }
        forgetUnusedSource(key)
    }

    package func cachedSnapshots(scopes: [V2PolicyAuthorizationScope], requestedAt: ContinuousClock.Instant? = nil) throws -> [V2PolicyFactsSnapshot]? {
        if let requestedAt { V2SendPathTrace.current?.record("policy_cache_actor_entry_wait", from: requestedAt) }
        try validate(scopes)
        guard scopes.allSatisfy({ snapshots[$0.canonical] != nil && sourceReady($0.canonical) }) else { return nil }
        return scopes.map {
            let key = $0.canonical
            let moved = snapshotOrder.moveToLast(key)
            precondition(moved)
            return snapshots[key]!
        }
    }

    /// Updates do not populate unrelated Gateway scopes. A scope currently
    /// loading is interested too: a newer push must win against its old reply.
    package func install(_ snapshot: V2PolicyFactsSnapshot, interestedOnly: Bool = false) throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let key = snapshot.scope.canonical
        let expectedInterest = interests[key]
        if interestedOnly, snapshots[key] == nil, snapshotFlights[key] == nil { return }
        guard sourceReady(key) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let current = pendingSnapshots[key] ?? snapshots[key] {
            if snapshot.version < current.version { return }
            if snapshot.version == current.version {
                guard snapshot == current else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                if snapshots[key] != nil { return }
            }
        }
        if snapshotFlights[key] != nil { pendingSnapshots[key] = snapshot }
        if snapshots[key] == nil, snapshots.count >= maximumEntries,
           let victim = snapshotOrder.removeFirst() {
            snapshots[victim] = nil
            forgetUnusedSource(victim)
        }
        if let expectedInterest {
            guard interests[key]?.revision == expectedInterest.revision,
                  scopeSources[key] == expectedInterest.route.source, sourceReady(key) else {
                throw V2PolicyAuthorizationLifecycleError.ownerChanged
            }
        }
        snapshots[key] = snapshot
        if !snapshotOrder.moveToLast(key) { snapshotOrder.append(key, key: key) }
    }

    /// The authenticated route establishes the expected source before a first
    /// RPC. A concurrent push can then safely beat that RPC's older reply.
    @discardableResult
    package func prepareRemoteScopes(_ scopes: [V2PolicyAuthorizationScope], source: V2ActorHostIdentity,
                                    endpoint: String = "policy") throws -> UInt64 {
        try validate(scopes)
        guard identity != nil, !endpoint.isEmpty, endpoint.utf8.count <= 512,
              nextInterestRevision < .max else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        nextInterestRevision += 1
        let revision = nextInterestRevision
        if let old = currentSources[source.hostID], old != source {
            sessions[old]?.retired = true
            sessions.removeValue(forKey: old)
            // Native replacement makes old registrations unusable. Do not
            // keep retrying cleanup RPCs against an incarnation that is gone.
            for (route, queued) in releases where route.source == old {
                pendingReleaseCount -= queued.scopes.count
                releases.removeValue(forKey: route); releaseRouteOrder.remove(route)
            }
            for (key, interest) in interests where interest.route.source == old {
                snapshots.removeValue(forKey: key); pendingSnapshots.removeValue(forKey: key)
                snapshotOrder.remove(key); scopeSources.removeValue(forKey: key); scopeSessions.removeValue(forKey: key)
                interests.removeValue(forKey: key)
                if let flight = snapshotFlights[key] { invalidatedFlights.insert(flight.id); flight.task.cancel() }
            }
        }
        currentSources[source.hostID] = source
        for scope in scopes {
            let key = scope.canonical
            if let old = interests.removeValue(forKey: key) { enqueueRelease(key, interest: old) }
            if scopeSources[key] != source {
                snapshots.removeValue(forKey: key); pendingSnapshots.removeValue(forKey: key)
                snapshotOrder.remove(key); scopeSessions.removeValue(forKey: key)
            }
            scopeSources[key] = source
            interests[key] = Interest(route: .init(source: source, endpoint: endpoint), revision: revision)
        }
        return revision
    }
    package func installRemoteBatch(_ batch: V2PolicySnapshotBatchWire, source: V2ActorHostIdentity) throws {
        guard batch.session.source == source,
              batch.snapshots.allSatisfy({
                  let key = $0.scope.policyScope.canonical
                  return scopeSources[key] == source && interests[key]?.revision == batch.interestRevision
              }) else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        // Cancellation is cooperative: an already dispatched read can still
        // return. Its response must not repopulate a cut invalidated by an
        // uncertain mutation, even before snapshotsFinished settles the root.
        guard batch.snapshots.allSatisfy({ wire in
            snapshotFlights[wire.scope.policyScope.canonical].map { !invalidatedFlights.contains($0.id) } ?? true
        }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        let session = try snapshotSession(batch.session)
        do {
            for wire in batch.snapshots {
                let snapshot = try V2PolicyFactsSnapshot(wire: wire)
                scopeSessions[snapshot.scope.canonical] = session.wire
                try install(snapshot)
            }
        } catch { session.retired = true; throw error }
    }
    package func applyControl(_ update: V2PolicySnapshotUpdateWire) throws {
        guard !closed, update.session.recipient == identity else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        switch update.payload {
        case .snapshot(let wire):
            let key = wire.scope.policyScope.canonical
            guard scopeSources[key] == update.session.source || sessions[update.session.source] != nil else {
                return // No cache or initializing reader is interested.
            }
            let session = try snapshotSession(update.session)
            do {
                if scopeSources[key] == update.session.source {
                    scopeSessions[key] = session.wire
                    try install(.init(wire: wire), interestedOnly: true)
                }
                if update.sequence > session.sequence {
                    session.sequence = update.sequence; session.deadline = now() + .seconds(10)
                }
            } catch { session.retired = true; throw error }
        case .heartbeat:
            guard let session = sessions[update.session.source], session.wire == update.session,
                  session.ready(at: now()) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            if update.sequence > session.sequence {
                session.sequence = update.sequence; session.deadline = now() + .seconds(10)
            }
        case .retire:
            guard let session = sessions[update.session.source], session.wire == update.session else {
                throw V2PolicyAuthorizationLifecycleError.ownerChanged
            }
            session.retired = true
        }
    }
    private func snapshotSession(_ wire: V2PolicyControlSessionWire) throws -> Session {
        guard !closed, wire.recipient == identity, currentSources[wire.source.hostID] == wire.source else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        if let old = sessions[wire.source] {
            if old.wire == wire {
                guard old.ready(at: now()) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
                return old
            }
            guard wire.generation > old.wire.generation else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            old.retired = true
        } else if sessions.count >= 128 { throw V2PolicyAuthorizationLifecycleError.busy }
        let session = Session(wire, now: now()); sessions[wire.source] = session
        return session
    }
    private func forgetUnusedSource(_ key: Key) {
        guard snapshots[key] == nil, snapshotFlights[key] == nil else { return }
        scopeSources.removeValue(forKey: key); scopeSessions.removeValue(forKey: key)
        if let interest = interests.removeValue(forKey: key) { enqueueRelease(key, interest: interest) }
    }

    /// Cache eviction relinquishes the remote registration, not just local
    /// facts. The recipient revision protects a reload from delayed release.
    private func enqueueRelease(_ key: Key, interest: Interest) {
        guard !closed, releaseInterests != nil else { return }
        let route = interest.route
        var queued = releases[route] ?? Releases()
        if let cut = queued.resetThrough, interest.revision <= cut { return }
        if queued.scopes[key] == nil, pendingReleaseCount >= maximumPendingReleases {
            // Never drop cleanup responsibility. A bounded reset replaces all
            // old interests for this source and closes their shared authority.
            queued.resetSessionGeneration = sessions[route.source]?.wire.generation
            sessions[route.source]?.retired = true
            pendingReleaseCount -= queued.scopes.count
            queued.scopes.removeAll(); queued.resetThrough = nextInterestRevision
            for (scope, active) in interests where active.route == route {
                snapshots.removeValue(forKey: scope); pendingSnapshots.removeValue(forKey: scope)
                snapshotOrder.remove(scope)
                if let flight = snapshotFlights[scope] {
                    invalidatedFlights.insert(flight.id); flight.task.cancel()
                } else {
                    interests.removeValue(forKey: scope); scopeSources.removeValue(forKey: scope)
                    scopeSessions.removeValue(forKey: scope)
                }
            }
        } else {
            if queued.scopes[key] == nil { pendingReleaseCount += 1 }
            queued.scopes[key] = max(queued.scopes[key] ?? 0, interest.revision)
        }
        releases[route] = queued
        if !releaseRouteOrder.moveToLast(route) { releaseRouteOrder.append(route, key: route) }
        releaseWakes.continuation.yield(())
    }

    package func startInterestReleases() {
        guard !closed, releaseInterests != nil, releaseWorker == nil else { return }
        releaseWorker = Task {
            for await _ in releaseWakes.stream {
                guard !Task.isCancelled, !closed else { return }
                await flushInterestReleases()
                if !closed, !releases.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    releaseWakes.continuation.yield(())
                }
            }
        }
    }
    private func flushInterestReleases() async {
        guard let subscriber, let releaseInterests else { return }
        var candidates: [(InterestRoute, Releases)] = []
        for _ in 0..<min(8, releaseRouteOrder.count) {
            guard let route = releaseRouteOrder.removeFirst(), let queued = releases[route] else { continue }
            releaseRouteOrder.append(route, key: route); candidates.append((route, queued))
        }
        let work = candidates.compactMap { route, queued -> (InterestRoute, V2PolicyInterestReleaseWire)? in
            let payload: V2PolicyInterestReleaseWire.Payload
            if let cut = queued.resetThrough { payload = .reset(throughRevision: cut, sessionGeneration: queued.resetSessionGeneration) }
            else {
                let items = queued.scopes.prefix(64).compactMap { scope, revision in
                    try? V2PolicyInterestReleaseWire.Item(scope: scope.policyWire, revision: revision)
                }
                guard !items.isEmpty else { return nil }
                payload = .scopes(items)
            }
            guard let request = try? V2PolicyInterestReleaseWire(endpoint: route.endpoint, source: route.source,
                subscriber: subscriber, payload: payload) else { return nil }
            return (route, request)
        }
        await withTaskGroup(of: (InterestRoute, V2PolicyInterestReleaseWire, Bool).self) { group in
            for (route, request) in work {
                group.addTask {
                    do { try await releaseInterests(request); return (route, request, true) }
                    catch { return (route, request, false) }
                }
            }
            for await (route, request, accepted) in group {
                guard !closed, var queued = releases[route] else { continue }
                guard accepted else { sessions[route.source]?.retired = true; continue }
                switch request.payload {
                case .reset(let cut, let generation):
                    if queued.resetThrough == cut && queued.resetSessionGeneration == generation {
                        queued.resetThrough = nil; queued.resetSessionGeneration = nil
                    }
                case .scopes(let items):
                    for item in items where queued.scopes[item.scope.policyScope.canonical] == item.revision {
                        queued.scopes.removeValue(forKey: item.scope.policyScope.canonical); pendingReleaseCount -= 1
                    }
                }
                releases[route] = queued.scopes.isEmpty && queued.resetThrough == nil ? nil : queued
                if releases[route] == nil { releaseRouteOrder.remove(route) }
            }
        }
    }
    private func sourceReady(_ key: Key) -> Bool {
        guard let source = scopeSources[key] else { return true } // Local authoritative facts.
        guard let wire = scopeSessions[key], let session = sessions[source], wire == session.wire,
              currentSources[source.hostID] == source else { return false }
        return session.ready(at: now())
    }

    /// No logical-read concurrency quota. Only the SQL loader acquires a
    /// database resource allowance; callers for the same scope share its task.
    package func loadSnapshots(scopes: [V2PolicyAuthorizationScope], requestedAt: ContinuousClock.Instant? = nil, loader: @escaping SnapshotLoader)
        async throws -> [V2PolicyFactsSnapshot] {
        if let requestedAt { V2SendPathTrace.current?.record("policy_cache_load_actor_entry_wait", from: requestedAt) }
        try validate(scopes)
        if let cached = try cachedSnapshots(scopes: scopes) { return cached }
        for scope in scopes where !sourceReady(scope.canonical) {
            snapshots.removeValue(forKey: scope.canonical); pendingSnapshots.removeValue(forKey: scope.canonical)
            snapshotOrder.remove(scope.canonical)
        }
        let missing = scopes.filter { snapshots[$0.canonical] == nil }
        let newScopes = missing.filter { snapshotFlights[$0.canonical] == nil }
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
            for scope in newScopes { snapshotFlights[scope.canonical] = .init(id: id, task: task) }
        }
        var tasks: [UUID: Task<[LoadedSnapshot], any Error>] = [:]
        for scope in missing {
            if let flight = snapshotFlights[scope.canonical] { tasks[flight.id] = flight.task }
        }
        var loaded: [Key: LoadedSnapshot] = [:]
        let waitStartedAt = ContinuousClock.now
        for task in tasks.values {
            for state in try await task.value { loaded[state.facts.scope.canonical] = state }
        }
        trace?.record("policy_flight_wait", from: waitStartedAt)
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        // Results remain available to actual waiters even if a tiny LRU budget
        // evicts one of their scopes while a different task finishes.
        return try scopes.map {
            let key = $0.canonical
            if let state = snapshots[key] {
                guard sourceReady(key) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
                return state
            }
            guard let state = loaded[key] else { throw V2PolicyAuthorizationLifecycleError.busy }
            if let wire = state.session {
                guard let session = sessions[wire.source], session.wire == wire,
                      currentSources[wire.source.hostID] == wire.source, session.ready(at: now()) else {
                    throw V2PolicyAuthorizationLifecycleError.ownerChanged
                }
            }
            return state.facts
        }
    }

    private func snapshotsFinished(id: UUID, scopes: [V2PolicyAuthorizationScope],
        result: Result<[V2PolicyFactsSnapshot], any Error>) -> Result<[LoadedSnapshot], any Error> {
        defer {
            for scope in scopes where snapshotFlights[scope.canonical]?.id == id {
                snapshotFlights[scope.canonical] = nil; pendingSnapshots[scope.canonical] = nil
                forgetUnusedSource(scope.canonical)
            }
            invalidatedFlights.remove(id)
        }
        guard !closed else { return .failure(V2PolicyAuthorizationLifecycleError.closed) }
        guard !invalidatedFlights.contains(id) else { return .failure(V2PolicyAuthorizationLifecycleError.ownerChanged) }
        do {
            let states = try result.get()
            guard states.count == scopes.count, Set(states.map { $0.scope.canonical }) == Set(scopes.map { $0.canonical }) else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            // Capture updates before installing/evicting other batch members.
            let resolved = states.map { incoming in
                (pendingSnapshots[incoming.scope.canonical] ?? snapshots[incoming.scope.canonical]).map { $0.version > incoming.version ? $0 : incoming } ?? incoming
            }
            let tagged = resolved.map { LoadedSnapshot(facts: $0, session: scopeSessions[$0.scope.canonical]) }
            for state in resolved { try install(state) }
            return .success(tagged)
        } catch { return .failure(error) }
    }


    package init(maximumEntries: Int = 32_768, identity: V2ActorHostIdentity? = nil,
                 subscriber: V2PolicySnapshotSubscriberWire? = nil, releaseInterests: ReleaseInterests? = nil,
                 maximumPendingReleases: Int = 65_536,
                 now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        precondition(maximumEntries > 0 && maximumPendingReleases > 0)
        precondition(releaseInterests == nil || (subscriber != nil && subscriber?.host == identity))
        self.maximumEntries = maximumEntries
        self.identity = identity; self.now = now
        self.subscriber = subscriber; self.releaseInterests = releaseInterests
        self.maximumPendingReleases = maximumPendingReleases
    }

    package func shutdown() async {
        closed = true
        for session in sessions.values { session.retired = true }
        let routes = Set(interests.values.map(\.route)).union(releases.keys)
        releaseWakes.continuation.finish(); releaseWorker?.cancel(); await releaseWorker?.value
        let tasks = Array(snapshotFlights.values.map(\.task))
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
        if nextInterestRevision > 0, let subscriber, let releaseInterests {
            let cut = nextInterestRevision
            let work = routes.compactMap { route in
                try? V2PolicyInterestReleaseWire(endpoint: route.endpoint, source: route.source,
                    subscriber: subscriber, payload: .reset(throughRevision: cut,
                        sessionGeneration: sessions[route.source]?.wire.generation))
            }
            await withTaskGroup(of: Void.self) { group in
                var pending = work.makeIterator()
                func admit(_ request: V2PolicyInterestReleaseWire) {
                    group.addTask { try? await releaseInterests(request) }
                }
                for _ in 0..<8 { if let request = pending.next() { admit(request) } }
                for await _ in group { if let request = pending.next() { admit(request) } }
            }
        }
        snapshots.removeAll(); snapshotOrder.removeAll(); pendingSnapshots.removeAll()
        sessions.removeAll(); currentSources.removeAll(); scopeSources.removeAll(); scopeSessions.removeAll()
        interests.removeAll(); releases.removeAll(); releaseRouteOrder.removeAll(); pendingReleaseCount = 0; releaseWorker = nil
        invalidatedFlights.removeAll()
    }

    private func validate(_ scopes: [V2PolicyAuthorizationScope]) throws {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map { $0.canonical }).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
    }
}
