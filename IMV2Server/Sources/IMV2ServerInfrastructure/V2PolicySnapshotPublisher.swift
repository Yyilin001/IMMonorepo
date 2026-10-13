import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Committed full snapshots are retained until application ACK. Heartbeats
/// share one generation per recipient and stop while control work is pending.
package actor V2PolicySnapshotPublisher {
    package struct Target: Hashable, Sendable {
        package let hostID: V2ActorHostID
        package let endpoint: String
        package init(hostID: V2ActorHostID, endpoint: String) throws {
            guard hostID.uuidValue != nil, !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
                throw V2PolicyAuthorizationLifecycleError.invalidTarget
            }
            self.hostID = hostID; self.endpoint = endpoint
        }
    }
    package typealias Send = @Sendable (V2PolicySnapshotUpdateWire, V2PolicySnapshotSubscriberWire) async throws -> Void
    private struct Entry {
        let target: V2PolicySnapshotSubscriberWire
        let session: V2PolicyControlSessionWire
        var scopes: [String: UInt64] = [:]
        var releasedThrough: UInt64 = 0
        var pending: [String: V2PolicyFactsSnapshot] = [:]
        var blockedChanges = 0
        var sequence: UInt64 = 0
        var ready = false
        var retired = false
        var flight: Task<Void, any Error>?
    }
    private let targets: Set<Target>
    private let identity: V2ActorHostIdentity
    private let cache: V2NodePolicyStateCache
    private let send: Send
    private let validateRecipient: @Sendable (V2PolicySnapshotSubscriberWire) async throws -> Void
    private var subscribers: [String: Set<V2ActorHostIdentity>] = [:]
    private var entries: [V2ActorHostIdentity: Entry] = [:]
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var roots: [UUID: Task<Void, any Error>] = [:]
    private var calls = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var changingScopes: [String: Int] = [:]

    package init(targets: [Target], identity: V2ActorHostIdentity, cache: V2NodePolicyStateCache,
                 validateRecipient: @escaping @Sendable (V2PolicySnapshotSubscriberWire) async throws -> Void,
                 send: @escaping Send) {
        self.targets = Set(targets); self.identity = identity; self.cache = cache; self.send = send
        self.validateRecipient = validateRecipient
    }
    package func start(qualified: @escaping @Sendable () async -> Bool) throws {
        guard !closed, !closing, worker == nil else { throw V2PolicyAuthorizationLifecycleError.closed }
        worker = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await pulse(qualified: await qualified())
            }
        }
    }
    package func subscribe(scopes: [V2PolicyAuthorizationScope], target: V2PolicySnapshotSubscriberWire, interestRevision: UInt64 = 1) async throws -> V2PolicyControlSessionWire {
        guard !closed, !closing, interestRevision > 0, !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.canonical)).count == scopes.count,
              targets.contains(try .init(hostID: target.hostID, endpoint: target.endpoint)), target.host != identity else {
            throw V2RoomCallFailure.notAccepted(.forbidden)
        }
        if entries[target.host] == nil {
            try await validateRecipient(target)
            guard !closed, !closing else { throw V2PolicyAuthorizationLifecycleError.closed }
        }
        // A restarted recipient supersedes its old incarnation's registrations.
        // Old tasks stay owned in roots until their actual calls settle.
        for (host, old) in entries where host.hostID == target.hostID && host != target.host {
            old.flight?.cancel(); entries.removeValue(forKey: host)
            for scope in old.scopes.keys {
                subscribers[scope]?.remove(host)
                if subscribers[scope]?.isEmpty == true { subscribers.removeValue(forKey: scope) }
            }
        }
        if entries[target.host] == nil || entries[target.host]?.retired == true { try replaceGeneration(target: target) }
        guard var entry = entries[target.host], entry.target == target else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        guard scopes.allSatisfy({ scope in
            let current = entry.scopes[scope.key]
            return current == interestRevision || (interestRevision > entry.releasedThrough && (current ?? 0) < interestRevision)
        }), entry.scopes.count + scopes.filter({ entry.scopes[$0.key] == nil }).count <= 65_536 else {
            throw V2PolicyAuthorizationLifecycleError.ownerChanged
        }
        for scope in scopes {
            subscribers[scope.key, default: []].insert(target.host)
            if entry.scopes[scope.key] == nil { entry.blockedChanges += changingScopes[scope.key] ?? 0 }
            entry.scopes[scope.key] = interestRevision
        }
        entries[target.host] = entry
        return entry.session
    }
    package func confirmRegistration(_ session: V2PolicyControlSessionWire, scopes: [V2PolicyAuthorizationScope]? = nil, interestRevision: UInt64? = nil) async throws {
        guard !closed, !closing, entries[session.recipient]?.session == session, entries[session.recipient]?.retired == false else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let entry = entries[session.recipient], !entry.pending.isEmpty {
            try await drain(session.recipient).value
        }
        guard !closed, !closing, entries[session.recipient]?.session == session, entries[session.recipient]?.retired == false else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let scopes, let interestRevision {
            guard scopes.allSatisfy({ entries[session.recipient]?.scopes[$0.key] == interestRevision }) else {
                throw V2PolicyAuthorizationLifecycleError.ownerChanged
            }
        }
        entries[session.recipient]?.ready = true
    }
    package func release(_ request: V2PolicyInterestReleaseWire) async throws {
        guard !closed, !closing, request.source == identity,
              targets.contains(try .init(hostID: request.subscriber.hostID, endpoint: request.subscriber.endpoint)) else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        let host = request.subscriber.host
        guard var entry = entries[host] else { return }
        guard entry.target == request.subscriber else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        let selected: [String]
        switch request.payload {
        case .scopes(let items):
            selected = items.compactMap { entry.scopes[$0.scope.key] == $0.revision ? $0.scope.key : nil }
            entry.releasedThrough = max(entry.releasedThrough, items.map(\.revision).max() ?? 0)
        case .reset(let revision, _):
            selected = entry.scopes.compactMap { $0.value <= revision ? $0.key : nil }
            entry.releasedThrough = max(entry.releasedThrough, revision)
        }
        for scope in selected {
            entry.scopes.removeValue(forKey: scope); entry.pending.removeValue(forKey: scope)
            entry.blockedChanges -= changingScopes[scope] ?? 0
            subscribers[scope]?.remove(host)
            if subscribers[scope]?.isEmpty == true { subscribers.removeValue(forKey: scope) }
        }
        entries[host] = entry
        if case .reset(_, let generation) = request.payload, generation == entry.session.generation {
            await retire(host: host, session: entry.session)
        }
        else if entry.scopes.isEmpty { await retire(host: host, session: entry.session) }
    }
    private func replaceGeneration(target: V2PolicySnapshotSubscriberWire) throws {
        guard generation < UInt64.max, entries[target.host] != nil || entries.count < 128 else {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        }
        generation += 1
        let previous = entries[target.host]
        entries[target.host] = Entry(target: target,
            session: try .init(source: identity, recipient: target.host, generation: generation),
            scopes: previous?.scopes ?? [:], releasedThrough: previous?.releasedThrough ?? 0, pending: previous?.pending ?? [:], blockedChanges: previous?.blockedChanges ?? 0)
    }
    package func beginChange(_ scope: V2PolicyAuthorizationScope) throws {
        guard !closed, !closing else { throw V2PolicyAuthorizationLifecycleError.closed }
        changingScopes[scope.key, default: 0] += 1
        for host in subscribers[scope.key] ?? [] { entries[host]?.blockedChanges += 1 }
    }
    package func finishChange(_ scope: V2PolicyAuthorizationScope, succeeded: Bool) async {
        if !succeeded {
            // A transaction may have committed without producing its response.
            // Neither local cache nor peer heartbeats may preserve that old cut.
            await cache.invalidate(scope)
            for host in subscribers[scope.key] ?? [] {
                if let session = entries[host]?.session { await retire(host: host, session: session) }
            }
        }
        if let count = changingScopes[scope.key] {
            if count == 1 { changingScopes.removeValue(forKey: scope.key) }
            else { changingScopes[scope.key] = count - 1 }
            for host in subscribers[scope.key] ?? [] {
                if entries[host] != nil { entries[host]?.blockedChanges -= 1 }
            }
        }
    }
    package func publish(_ snapshot: V2PolicyFactsSnapshot) async throws {
        guard !closed, !closing else { throw V2PolicyAuthorizationLifecycleError.closed }
        var hosts: [V2ActorHostIdentity] = []
        for host in subscribers[snapshot.scope.key] ?? [] {
            guard let old = entries[host] else { continue }
            if old.retired, old.flight == nil { try replaceGeneration(target: old.target) }
            guard var entry = entries[host] else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            guard entry.pending.count < 65_536 || entry.pending[snapshot.scope.key] != nil else {
                await retire(host: host, session: entry.session)
                throw V2RoomCallFailure.notAccepted(.overloaded)
            }
            if let pending = entry.pending[snapshot.scope.key], pending.version == snapshot.version, pending != snapshot {
                await retire(host: host, session: entry.session)
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            if entry.pending[snapshot.scope.key].map({ $0.version <= snapshot.version }) ?? true {
                entry.pending[snapshot.scope.key] = snapshot
            }
            entries[host] = entry; hosts.append(host)
        }
        // Register control responsibility before awaiting the local cache.
        // Even a delayed cache Actor cannot let heartbeats mask this change.
        do { try await cache.install(snapshot, interestedOnly: true) }
        catch {
            for host in hosts { if let session = entries[host]?.session { await retire(host: host, session: session) } }
            throw error
        }
        guard !closed, !closing else { throw V2PolicyAuthorizationLifecycleError.closed }
        let flights = hosts.compactMap { entries[$0] == nil ? nil : drain($0) }
        // Every actual root remains owned even if the mutation caller leaves.
        for flight in flights { try await flight.value }
    }
    private func drain(_ host: V2ActorHostIdentity) -> Task<Void, any Error> {
        if let flight = entries[host]?.flight { return flight }
        let id = UUID(), session = entries[host]!.session
        let task = Task {
            let result: Result<Void, any Error>
            do { try await deliverPending(host: host, session: session); result = .success(()) }
            catch { result = .failure(error) }
            if entries[host]?.session == session { entries[host]?.flight = nil }
            roots.removeValue(forKey: id)
            return try result.get()
        }
        entries[host]?.flight = task; roots[id] = task
        return task
    }
    private func deliverPending(host: V2ActorHostIdentity, session: V2PolicyControlSessionWire) async throws {
        do {
            while !closed, !closing, let entry = entries[host], entry.session == session, !entry.retired,
                  let snapshot = entry.pending.values.first {
                try Task.checkCancellation()
                let sequence = try nextSequence(host: host, session: session)
                try await perform(try .init(endpoint: entry.target.endpoint, session: session, sequence: sequence,
                    payload: .snapshot(snapshot.wire)), target: entry.target)
                guard entries[host]?.session == session else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
                if entries[host]?.pending[snapshot.scope.key]?.version == snapshot.version {
                    entries[host]?.pending.removeValue(forKey: snapshot.scope.key)
                }
            }
            guard !closed, !closing, entries[host]?.session == session, entries[host]?.retired == false else { throw V2PolicyAuthorizationLifecycleError.closed }
            entries[host]?.ready = true
        } catch {
            await retire(host: host, session: session)
            throw error
        }
    }
    private func nextSequence(host: V2ActorHostIdentity, session: V2PolicyControlSessionWire) throws -> UInt64 {
        guard let entry = entries[host], entry.session == session, entry.sequence < UInt64.max else {
            throw V2PolicyAuthorizationLifecycleError.ownerChanged
        }
        entries[host]?.sequence += 1
        return entry.sequence + 1
    }
    private func perform(_ request: V2PolicySnapshotUpdateWire, target: V2PolicySnapshotSubscriberWire) async throws {
        if calls >= 8 { await withCheckedContinuation { callWaiters.append($0) } }
        else { calls += 1 }
        defer {
            if callWaiters.isEmpty { calls -= 1 }
            else { callWaiters.removeFirst().resume() }
        }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        try Task.checkCancellation()
        try await send(request, target)
    }
    private func retire(host: V2ActorHostIdentity, session: V2PolicyControlSessionWire) async {
        guard let entry = entries[host], entry.session == session else { return }
        entries[host]?.ready = false; entries[host]?.retired = true
        if let sequence = try? nextSequence(host: host, session: session),
           let request = try? V2PolicySnapshotUpdateWire(endpoint: entry.target.endpoint, session: session,
               sequence: sequence, payload: .retire) {
            try? await perform(request, target: entry.target)
        }
    }
    private func pulse(qualified: Bool) async {
        guard !closed, !closing else { return }
        let peers = entries.filter { $0.value.ready && $0.value.flight == nil && $0.value.pending.isEmpty && $0.value.blockedChanges == 0 }
        await withTaskGroup(of: Void.self) { group in
            var pending = peers.makeIterator()
            func admit(_ item: (key: V2ActorHostIdentity, value: Entry)) {
                group.addTask { await self.pulse(host: item.key, session: item.value.session, qualified: qualified) }
            }
            for _ in 0..<8 { if let entry = pending.next() { admit(entry) } }
            for await _ in group {
                if !closed, !Task.isCancelled, let entry = pending.next() { admit(entry) }
            }
        }
    }
    private func pulse(host: V2ActorHostIdentity, session: V2PolicyControlSessionWire, qualified: Bool) async {
        guard let entry = entries[host], entry.session == session, entry.ready,
              entry.pending.isEmpty, entry.flight == nil, entry.blockedChanges == 0 else { return }
        guard qualified else { await retire(host: host, session: session); return }
        do {
            let sequence = try nextSequence(host: host, session: session)
            try await perform(try .init(endpoint: entry.target.endpoint, session: session, sequence: sequence,
                payload: .heartbeat), target: entry.target)
        } catch {
            if entries[host]?.session == session { entries[host]?.ready = false; entries[host]?.retired = true }
        }
    }
    package func shutdown() async {
        guard !closed else { return }
        if closing { await withCheckedContinuation { closeWaiters.append($0) }; return }
        closing = true
        worker?.cancel()
        // Stop admission first; actual roots and queued slot owners still join.
        for task in roots.values { task.cancel() }
        for task in Array(roots.values) { _ = await task.result }
        await worker?.value
        await withTaskGroup(of: Void.self) { group in
            var pending = Array(entries.values).makeIterator()
            func admit(_ entry: Entry) {
                group.addTask { await self.retire(host: entry.session.recipient, session: entry.session) }
            }
            for _ in 0..<8 { if let entry = pending.next() { admit(entry) } }
            for await _ in group { if let entry = pending.next() { admit(entry) } }
        }
        closed = true
        entries.removeAll(); subscribers.removeAll(); roots.removeAll()
        changingScopes.removeAll()
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
