import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// One process's bounded account/pair owner registry. Database epochs remain
/// authoritative; a common process ID lets an idle scope be evicted and later
/// reconstructed without invalidating its registered holders.
package actor PostgresV2PolicyOwnerDirectory {
    private struct Entry {
        let owner: PostgresV2PolicyOwner
        var uses: Int
        var retainedState: V2PolicyOwnerState?
    }
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let dispatcher: PostgresV2PolicyMutationDispatcher
    private let revoke: PostgresV2PolicyOwner.Revoker
    private let ownerID: UUID
    private nonisolated let ownsScope: @Sendable (String) -> Bool
    private let maximumOwners: Int
    private let maximumRoots: Int
    private let leaseSeconds: Double
    private var owners: [String: Entry] = [:]
    private var idle = V2IndexedFIFO<String, String>()
    private var roots: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private var retainedStates: [String: V2PolicyOwnerState] = [:]
    private var retainedOrder = V2IndexedFIFO<String, String>()
    private var retainedBytes = 0
    private let maximumRetainedStates: Int
    private let maximumRetainedStateBytes: Int
    private let committed: (@Sendable (V2PolicyAuthorizationScope) async throws -> Void)?
    private let memoryMetrics: V2SendOperationBatchMetrics?
    private var pendingScanCursor: V2PolicyJournalCursor?
    private var pendingScanUpper: V2PolicyJournalCursor?
    private var recovering = false
    private let snapshots = V2NodePolicyStateCache()
    private let snapshotPublisher: V2PolicySnapshotPublisher?

    package init(journal: PostgresV2PolicyAuthorizationJournal, dispatcher: PostgresV2PolicyMutationDispatcher,
                 ownerID: UUID = UUID(), maximumOwners: Int = 4_096, maximumRoots: Int = 64,
                 maximumRetainedStates: Int = 0, maximumRetainedStateBytes: Int = 4 * 1_024 * 1_024,
                 memoryMetrics: V2SendOperationBatchMetrics? = nil,
                 committed: (@Sendable (V2PolicyAuthorizationScope) async throws -> Void)? = nil,
                 snapshotPublisher: V2PolicySnapshotPublisher? = nil,
                 leaseSeconds: Double = 30, ownsScope: @escaping @Sendable (String) -> Bool = { _ in true },
                 revoke: @escaping PostgresV2PolicyOwner.Revoker) {
        precondition(maximumOwners > 0 && maximumRoots > 0 && maximumRoots <= 1_024)
        precondition(leaseSeconds.isFinite && leaseSeconds > 0 && leaseSeconds <= 300)
        self.journal = journal; self.dispatcher = dispatcher; self.ownerID = ownerID
        self.maximumOwners = maximumOwners; self.maximumRoots = maximumRoots
        self.leaseSeconds = leaseSeconds; self.revoke = revoke
        self.ownsScope = ownsScope
        precondition(maximumRetainedStates >= 0 && maximumRetainedStateBytes >= 0)
        self.maximumRetainedStates = maximumRetainedStates
        self.maximumRetainedStateBytes = maximumRetainedStateBytes
        self.memoryMetrics = memoryMetrics; self.committed = committed; self.snapshotPublisher = snapshotPublisher
    }

    package func change(_ mutation: V2DurablePolicyMutation) async throws -> V2PolicyMutationResult {
        try await changeExecution(mutation).result
    }

    package func changeExecution(_ mutation: V2DurablePolicyMutation) async throws
        -> (result: V2PolicyMutationResult, replayed: Bool) {
        try mutation.validate()
        let key = mutation.operationKey, fingerprint = try mutation.fingerprint, json = try mutation.json
        let result = try await run {
            try await self.useOwner(scope: mutation.scope) { owner in
                let execution = try await owner.changeExecution(operationKey: key, fingerprint: fingerprint, commandJSON: json)
                if let state = execution.state {
                    let snapshot = try V2PolicyFactsSnapshot(scope: state.owner.scope, version: state.owner.revision, facts: state.facts)
                    try await self.snapshots.install(snapshot)
                    do { try await self.snapshotPublisher?.publish(snapshot) }
                    catch { throw V2RoomCallFailure.outcomeUnknown }
                }
                return (try JSONDecoder().decode(V2PolicyMutationResult.self, from: execution.receipt), execution.replayed)
            }
        }
        if result.1, !journal.roomDrainRequired {
            // An interrupted post-COMMIT push is retried by replaying the
            // current snapshot; versions make duplicate delivery harmless.
            do { try await publishSnapshot(scope: mutation.scope) }
            catch { throw V2RoomCallFailure.outcomeUnknown }
        }
        // COMMIT and authoritative memory publication have already settled.
        // A failed notification cannot be reported as a rolled-back mutation.
        do { try await committed?(mutation.scope) }
        catch { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }

    package func registrationSnapshots(scopes: [V2PolicyAuthorizationScope],
        subscriber: V2PolicySnapshotSubscriberWire? = nil,
        requestedAt: ContinuousClock.Instant? = nil) async throws -> [V2PolicyFactsSnapshot] {
        if let requestedAt { V2SendPathTrace.current?.record("policy_directory_actor_entry_wait", from: requestedAt) }
        guard !closed, !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard scopes.allSatisfy({ ownsScope($0.key) }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let subscriber {
            guard let snapshotPublisher else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            try await snapshotPublisher.subscribe(scopes: scopes, target: subscriber)
        }
        // No bounded mutation root or owner-object quota wraps reads.
        let journal = journal
        return try await snapshots.loadSnapshots(scopes: scopes, requestedAt: .now) { try await journal.readSnapshots(scopes: $0) }
    }
    package func cachedSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot]? {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard scopes.allSatisfy({ ownsScope($0.key) }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        return try await snapshots.cachedSnapshots(scopes: scopes, requestedAt: .now)
    }
    package func publishSnapshot(scope: V2PolicyAuthorizationScope) async throws {
        let snapshot = try await registrationSnapshots(scopes: [scope])[0]
        try await snapshotPublisher?.publish(snapshot)
    }
    package func publishSnapshot(scopeKey: String) async throws {
        let parts = scopeKey.split(separator: ":")
        guard parts.count >= 2, let first = UUID(uuidString: String(parts[1])) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let scope: V2PolicyAuthorizationScope
        switch parts[0] {
        case "account" where parts.count == 2: scope = .account(first)
        case "stranger" where parts.count == 2: scope = .stranger(first)
        case "pair" where parts.count == 3:
            guard let second = UUID(uuidString: String(parts[2])) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
            scope = .pair(first, second)
        default: throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        guard scope.key == scopeKey else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        try await publishSnapshot(scope: scope)
    }

    package func registrationStates(scopes: [V2PolicyAuthorizationScope], minimumRemaining: Duration = .zero) async throws -> [V2PolicyOwnerState] {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard scopes.allSatisfy({ ownsScope($0.key) }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        let ordered = scopes.sorted(by: { $0.key < $1.key })
        // Valid memory facts must not compete with unrelated suspended SQL
        // roots. Misses still use the original bounded, settled work path.
        if let cached = try await cachedStates(ordered), cached.allSatisfy({ $0.deadline > .now + minimumRemaining }) { return cached }
        let width = min(ordered.count, maximumOwners)
        return try await run {
            // Independent scope actors retain their own serialization. Join
            // every child, including failures, before releasing this root.
            try await withThrowingTaskGroup(of: (Int, V2PolicyOwnerState).self) { group in
                func enqueue(_ index: Int) {
                    group.addTask {
                        let state = try await self.useOwner(scope: ordered[index]) { try await $0.registrationState(minimumRemaining: minimumRemaining) }
                        return (index, state)
                    }
                }
                var next = 0
                while next < width { enqueue(next); next += 1 }
                var states = Array<V2PolicyOwnerState?>(repeating: nil, count: ordered.count)
                for try await (index, state) in group {
                    states[index] = state
                    if next < ordered.count { enqueue(next); next += 1 }
                }
                return try states.map {
                    guard let state = $0 else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                    return state
                }
            }
        }
    }

    /// Returns only already-owned valid facts, without creating or renewing
    /// owners. A partial hit is a miss; callers must load the full dependency set.
    package func cachedRegistrationStates(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerState]? {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard scopes.allSatisfy({ ownsScope($0.key) }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        return try await cachedStates(scopes.sorted { $0.key < $1.key })
    }

    private func cachedStates(_ scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerState]? {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        var result: [V2PolicyOwnerState] = []
        for scope in scopes {
            guard let entry = owners[scope.key] else {
                guard let retained = retainedStates[scope.key], retained.deadline > .now else {
                    memoryMetrics?.recordPolicyMemoryEvent(.miss)
                    return nil
                }
                retainedOrder.remove(scope.key); retainedOrder.append(scope.key, key: scope.key)
                memoryMetrics?.recordPolicyMemoryEvent(.retainedHit)
                result.append(retained)
                continue
            }
            idle.remove(scope.key)
            owners[scope.key]!.uses += 1
            let state: V2PolicyOwnerState?
            do { state = try await entry.owner.cachedRegistrationState() }
            catch { finishCachedUse(scope.key); throw error }
            finishCachedUse(scope.key)
            guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
            guard let state else { memoryMetrics?.recordPolicyMemoryEvent(.miss); return nil }
            memoryMetrics?.recordPolicyMemoryEvent(.ownerHit)
            result.append(state)
        }
        return result
    }

    private func finishCachedUse(_ key: String) {
        // Shutdown may clear the directory while an actor hop is suspended.
        guard var entry = owners[key] else { return }
        entry.uses -= 1
        owners[key] = entry
        if entry.uses == 0 { idle.append(key, key: key) }
    }

    package func registrationOwners(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyOwnerLease] {
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        // Reject the whole claim before touching SQL. A foreign scope cannot
        // cause a prefix of local ownership side effects.
        guard scopes.allSatisfy({ ownsScope($0.key) }) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        return try await run {
            var leases: [V2PolicyOwnerLease] = []
            for scope in scopes.sorted(by: { $0.key < $1.key }) {
                leases.append(try await self.useOwner(scope: scope) { try await $0.registrationOwner() })
            }
            return leases
        }
    }

    /// The frozen command supplies the scope on restart. No request-local
    /// closures or process memory are needed to resume the domain effect.
    package nonisolated func acceptsScope(_ key: String) -> Bool { ownsScope(key) }

    package func recoverPending(limit: Int = 128, scanLimit: Int = 512) async throws -> V2PolicyRecoveryReport {
        guard (1...128).contains(limit), (1...4096).contains(scanLimit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard !recovering else { throw V2PolicyAuthorizationLifecycleError.busy }
        recovering = true
        defer { recovering = false }
        return try await run { try await self.performRecovery(limit: limit, scanLimit: scanLimit) }
    }

    private func performRecovery(limit: Int, scanLimit: Int) async throws -> V2PolicyRecoveryReport {
        var upper = pendingScanUpper
        if upper == nil { upper = try await journal.pendingChangeHighWater() }
        guard let upper else { return .init(scanned: 0, attempted: 0, completed: 0, failed: 0, exhausted: true) }
        var cursor = pendingScanCursor, scanned = 0, exhausted = false
        var candidates: [V2PolicyAuthorizationChange] = []
        while scanned < scanLimit, candidates.count < limit {
            let page = try await journal.pendingChangePage(after: cursor, through: upper, limit: min(128, scanLimit - scanned))
            var consumed = 0
            for entry in page.entries {
                consumed += 1; scanned += 1; cursor = entry.cursor
                if ownsScope(entry.change.scopeKey) { candidates.append(entry.change) }
                if candidates.count == limit { break }
            }
            if consumed == page.entries.count, !page.hasMore { exhausted = true; cursor = nil; break }
        }
        pendingScanCursor = cursor
        pendingScanUpper = exhausted ? nil : upper
        let completed = await withTaskGroup(of: Bool.self) { group in
            var next = 0, completed = 0
            func enqueue(_ change: V2PolicyAuthorizationChange) {
                group.addTask { (try? await self.recoverChange(change)) != nil }
            }
            while next < min(8, candidates.count) { enqueue(candidates[next]); next += 1 }
            while let succeeded = await group.next() {
                if succeeded { completed += 1 }
                if next < candidates.count { enqueue(candidates[next]); next += 1 }
            }
            return completed
        }
        return .init(scanned: scanned, attempted: candidates.count, completed: completed,
            failed: candidates.count - completed, exhausted: exhausted)
    }

    private func recoverChange(_ pending: V2PolicyAuthorizationChange) async throws {
        let mutation = try JSONDecoder().decode(V2DurablePolicyMutation.self, from: Data(pending.commandJSON.utf8))
        try mutation.validate()
        guard mutation.scope.key == pending.scopeKey, mutation.operationKey == pending.operationKey,
              try mutation.fingerprint == pending.fingerprint else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        try await useOwner(scope: mutation.scope) { owner in
            try await owner.recover(limit: 1)
            if let state = await owner.retainedRegistrationState(), !self.journal.roomDrainRequired {
                let snapshot = try V2PolicyFactsSnapshot(scope: state.owner.scope, version: state.owner.revision, facts: state.facts)
                try await self.snapshots.install(snapshot)
                try await self.snapshotPublisher?.publish(snapshot)
            }
        }
    }

    package func shutdown() async {
        closed = true
        let work = Array(roots.values)
        for task in work { await task.value }
        let retained = owners.values.map(\.owner)
        for owner in retained { await owner.shutdown() }
        owners.removeAll()
        idle.removeAll()
        retainedStates.removeAll(); retainedOrder.removeAll(); retainedBytes = 0
        await snapshots.shutdown()
    }

    package func pressure() -> (closed: Bool, owners: Int, roots: Int, retainedStates: Int, retainedBytes: Int) {
        (closed, owners.count, roots.count, retainedStates.count, retainedBytes)
    }

    private func run<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard roots.count < maximumRoots else { throw V2PolicyAuthorizationLifecycleError.busy }
        let id = UUID()
        let deadline = V2RoomSQLDeadline.current
        let task = Task.detached {
            let result: Swift.Result<Result, any Error>
            do {
                result = .success(try await V2RoomSQLDeadline.withSelectedDeadline(deadline) { try await operation() })
            } catch { result = .failure(error) }
            await self.finished(id)
            return try result.get()
        }
        roots[id] = Task.detached { _ = await task.result }
        return try await task.value
    }

    private func finished(_ id: UUID) { roots[id] = nil }

    private func useOwner<Result: Sendable>(scope: V2PolicyAuthorizationScope,
        operation: @Sendable (PostgresV2PolicyOwner) async throws -> Result) async throws -> Result {
        guard scope.isValid else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let key = scope.key
        guard ownsScope(key) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if owners[key] == nil {
            var retiringKey: String?
            if owners.count == maximumOwners {
                guard let retired = idle.removeFirst() else {
                    throw V2PolicyAuthorizationLifecycleError.busy
                }
                retiringKey = retired
            }
            // Consume the requested state before retaining the victim. At a
            // full fact budget, the victim must not evict this very request.
            let initialState = removeRetained(key)
            if initialState != nil { memoryMetrics?.recordPolicyMemoryEvent(.ownerRestored) }
            if let retired = retiringKey {
                // Zero uses means every actual owner future settled.
                if let state = owners[retired]?.retainedState { retain(state, key: retired) }
                owners[retired] = nil
                memoryMetrics?.recordPolicyMemoryEvent(.ownerEvicted)
            }
            let dispatcher = dispatcher, journal = journal
            owners[key] = .init(owner: .init(journal: journal, scope: initialState?.owner.scope ?? scope, ownerID: ownerID,
                leaseSeconds: leaseSeconds,
                snapshot: { context, change in
                    try await journal.mutationFacts(scope: scope, context: context, change: change)
                }, initialState: initialState, revoke: revoke,
                apply: { try await dispatcher.apply(context: $0, change: $1) }), uses: 0, retainedState: initialState)
        }
        idle.remove(key)
        owners[key]!.uses += 1
        let owner = owners[key]!.owner
        defer {
            owners[key]!.uses -= 1
            if owners[key]!.uses == 0 { idle.append(key, key: key) }
        }
        do {
            let value = try await operation(owner)
            let retained = await owner.retainedRegistrationState()
            owners[key]!.retainedState = retained
            return value
        } catch {
            let retained = await owner.retainedRegistrationState()
            owners[key]!.retainedState = retained
            throw error
        }
    }

    private func stateBytes(_ state: V2PolicyOwnerState, key: String) -> Int {
        // Fixed struct/key/index allowance plus variable account strings;
        // this is a retained-value budget, not a claim about allocator RSS.
        var bytes = 256 + key.utf8.count
        if case .account(let account) = state.facts {
            bytes += (account.specialKind?.utf8.count ?? 0) + (account.specialStatus?.utf8.count ?? 0)
        }
        return bytes
    }

    private func removeRetained(_ key: String) -> V2PolicyOwnerState? {
        guard let state = retainedStates.removeValue(forKey: key) else { return nil }
        retainedOrder.remove(key); retainedBytes -= stateBytes(state, key: key)
        return state
    }

    private func retain(_ state: V2PolicyOwnerState, key: String) {
        _ = removeRetained(key)
        let bytes = stateBytes(state, key: key)
        guard maximumRetainedStates > 0, bytes <= maximumRetainedStateBytes else { return }
        while retainedStates.count >= maximumRetainedStates || retainedBytes > maximumRetainedStateBytes - bytes {
            guard let oldest = retainedOrder.removeFirst() else { return }
            _ = removeRetained(oldest)
            memoryMetrics?.recordPolicyMemoryEvent(.factsEvicted)
        }
        retainedStates[key] = state; retainedBytes += bytes
        retainedOrder.append(key, key: key)
        memoryMetrics?.recordPolicyMemoryEvent(.factsRetained)
    }
}
