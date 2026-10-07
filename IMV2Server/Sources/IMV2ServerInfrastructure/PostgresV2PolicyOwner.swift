import Foundation
import FluentKit
import IMV2ServerApplication

/// One logical account/pair owner. SQL epochs are authority; actor isolation
/// protects bounded local roots, not distributed ownership. The runtime holds
/// no database transaction while invoking a room's revocation boundary.
package actor PostgresV2PolicyOwner {
    package typealias Revoker = @Sendable (V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof
    package typealias Mutation = @Sendable (V2PolicyMutationContext, V2PolicyAuthorizationChange) async throws -> Data
    package typealias Snapshot = @Sendable (V2PolicyMutationContext, V2PolicyAuthorizationChange) async throws -> V2PolicyOwnerFacts

    private struct Job: Sendable {
        let id: UUID
        let fingerprint: Data
        let canonicalJSON: String
        let task: Task<V2PolicyMutationExecution, any Error>
    }
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let scope: V2PolicyAuthorizationScope
    private let ownerID: UUID
    private let leaseSeconds: Double
    private let maximumRoots: Int
    private let revocationConcurrency: Int
    private let revoke: Revoker
    private let apply: Mutation
    private let snapshot: Snapshot?
    private var jobs: [String: Job] = [:]
    private var mutationTail: (id: UUID, task: Task<V2PolicyMutationExecution, any Error>)?
    private var claims: [UUID: Task<V2PolicyOwnerLease, any Error>] = [:]
    private var recoveries: [UUID: Task<Void, any Error>] = [:]
    private var closed = false
    private var state: V2PolicyOwnerState?
    private var stateGeneration = UUID()
    private var stateClaim: (id: UUID, generation: UUID, task: Task<V2PolicyOwnerState, any Error>)?

    package init(journal: PostgresV2PolicyAuthorizationJournal, scope: V2PolicyAuthorizationScope,
                 ownerID: UUID = UUID(), leaseSeconds: Double = 30,
                 maximumRoots: Int = 16, revocationConcurrency: Int = 8,
                 snapshot: Snapshot? = nil, initialState: V2PolicyOwnerState? = nil,
                 revoke: @escaping Revoker, apply: @escaping Mutation) {
        precondition(scope.isValid && leaseSeconds.isFinite && leaseSeconds > 0 && leaseSeconds <= 300)
        precondition(maximumRoots > 0 && maximumRoots <= 128 && (1...32).contains(revocationConcurrency))
        self.journal = journal; self.scope = scope; self.ownerID = ownerID
        self.leaseSeconds = leaseSeconds; self.maximumRoots = maximumRoots
        self.revocationConcurrency = revocationConcurrency; self.revoke = revoke; self.apply = apply
        self.snapshot = snapshot
        precondition(initialState == nil || (initialState?.owner.scope == scope && initialState?.owner.ownerID == ownerID))
        self.state = initialState
    }

    /// Cold-load/refresh callers retain their claim until the physical future
    /// settles. A shutdown cannot miss a claim suspended on database ownership.
    package func registrationOwner() async throws -> V2PolicyOwnerLease {
        try Task.checkCancellation()
        try requireCapacity()
        let id = UUID(), journal = journal, scope = scope, ownerID = ownerID, seconds = leaseSeconds
        let deadline = V2RoomSQLDeadline.current
        let task = Task.detached {
            let result: Result<V2PolicyOwnerLease, any Error>
            do { result = .success(try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: seconds)
            }) }
            catch { result = .failure(error) }
            await self.claimFinished(id)
            return try result.get()
        }
        claims[id] = task
        return try await task.value
    }

    package func registrationState(minimumRemaining: Duration = .zero) async throws -> V2PolicyOwnerState {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        if let state, state.deadline > .now + minimumRemaining,
           (jobs.isEmpty && recoveries.isEmpty) || !journal.roomDrainRequired { return state }
        guard jobs.isEmpty, recoveries.isEmpty else { throw V2PolicyAuthorizationLifecycleError.busy }
        if let claim = stateClaim, claim.generation == stateGeneration { return try await claim.task.value }
        try requireCapacity()
        // A superseded load is still an actual SQL root until it settles.
        guard stateClaim == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
        let id = UUID(), generation = stateGeneration, journal = journal, scope = scope, ownerID = ownerID, seconds = leaseSeconds
        let cachedState = state
        let deadline = V2RoomSQLDeadline.current
        let task = Task.detached {
            let result: Result<V2PolicyOwnerState, any Error>
            do { result = .success(try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                try await Self.loadState(journal: journal, scope: scope, ownerID: ownerID,
                    seconds: seconds, cachedState: cachedState)
            }) }
            catch { result = .failure(error) }
            return try await self.stateFinished(id: id, generation: generation, result: result).get()
        }
        stateClaim = (id, generation, task)
        return try await task.value
    }
    /// A cache probe never creates SQL work or joins a suspended state load.
    /// Current-state readers may use the last committed value during a write.
    /// Registered authorization still seals readers before revocation.
    package func cachedRegistrationState() throws -> V2PolicyOwnerState? {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard (jobs.isEmpty && recoveries.isEmpty) || !journal.roomDrainRequired,
              let state, state.deadline > .now else { return nil }
        return state
    }
    /// Export only settled state for object eviction. Expired authority may be
    /// retained as facts, but must pass the journal's fenced renewal to be used.
    package func retainedRegistrationState() -> V2PolicyOwnerState? {
        guard !closed, jobs.isEmpty, recoveries.isEmpty, claims.isEmpty, stateClaim == nil else { return nil }
        return state
    }

    private static func loadState(journal: PostgresV2PolicyAuthorizationJournal, scope: V2PolicyAuthorizationScope,
        ownerID: UUID, seconds: Double, cachedState: V2PolicyOwnerState? = nil) async throws -> V2PolicyOwnerState {
        try await journal.acquireOwnerState(scope: scope, ownerID: ownerID, durationSeconds: seconds,
            cachedState: cachedState)
    }
    private func stateFinished(id: UUID, generation: UUID, result: Result<V2PolicyOwnerState, any Error>)
        -> Result<V2PolicyOwnerState, any Error> {
        guard stateClaim?.id == id else { return result }
        stateClaim = nil
        if generation != stateGeneration, !journal.roomDrainRequired {
            // A mutation may commit while this older load waits for SQL or
            // returns its result. Fence both publication and the result seen
            // by its waiters. The actual load has settled before its root is
            // released; only a live committed value can replace its outcome.
            guard !closed else { return .failure(V2PolicyAuthorizationLifecycleError.closed) }
            guard let state, state.deadline > .now else {
                return .failure(V2PolicyAuthorizationLifecycleError.busy)
            }
            return .success(state)
        }
        // Current-state lookups do not change facts or seal readers. Keep a
        // first completed load even while a receipt/recovery lookup waits;
        // beginMutation/beginRecovery fence any actual effects by generation.
        if generation == stateGeneration, !closed,
           (jobs.isEmpty && recoveries.isEmpty) || !journal.roomDrainRequired,
           case .success(let value) = result { state = value }
        return result
    }
    private func invalidateState() { state = nil; stateGeneration = UUID() }

    package func change(operationKey: String, fingerprint: Data, commandJSON: String) async throws -> Data {
        try await changeExecution(operationKey: operationKey, fingerprint: fingerprint, commandJSON: commandJSON).receipt
    }

    package func changeExecution(operationKey: String, fingerprint: Data, commandJSON: String) async throws -> V2PolicyMutationExecution {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let canonical = try Self.canonical(commandJSON)
        guard fingerprint.count == 32, !operationKey.isEmpty, operationKey.utf8.count <= 512 else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        if let existing = jobs[operationKey] {
            guard existing.fingerprint == fingerprint, existing.canonicalJSON == canonical else {
                throw V2PolicyAuthorizationLifecycleError.identityConflict
            }
            let result = try await existing.task.value
            return .init(receipt: result.receipt, replayed: true)
        }
        guard recoveries.isEmpty else { throw V2PolicyAuthorizationLifecycleError.busy }
        try requireCapacity()
        let predecessor = mutationTail?.task
        let id = UUID(), journal = journal, scope = scope, ownerID = ownerID
        let seconds = leaseSeconds, concurrency = revocationConcurrency, revoke = revoke, apply = apply, snapshot = snapshot
        let task = Task.detached {
            // Actor reentrancy alone does not serialize persistence. Each
            // scope has its own bounded lane; unrelated scopes have no tail
            // dependency. A failed predecessor still settles before the next
            // operation checks the durable journal's pending state.
            if let predecessor { _ = await predecessor.result }
            // Result lookup has no mutation effects. A permanent replay or
            // identity conflict must not discard the committed memory value.
            // A lookup failure also cannot make an already-cached policy
            // uncertain: no mutation transaction has been started here.
            do {
                if let receipt = try await journal.committedResult(scope: scope,
                    operationKey: operationKey, fingerprint: fingerprint, commandJSON: canonical) {
                    await self.jobLookupFinished(operationKey, id: id)
                    return V2PolicyMutationExecution(receipt: receipt, replayed: true)
                }
            } catch {
                await self.jobLookupFinished(operationKey, id: id)
                throw error
            }
            let (generation, replayState) = await self.beginMutation()
            let result: Result<V2PolicyMutationExecution, any Error>
            do {
                result = .success(try await Self.execute(journal: journal, scope: scope, ownerID: ownerID,
                    seconds: seconds, operationKey: operationKey, fingerprint: fingerprint, commandJSON: canonical,
                    concurrency: concurrency, revoke: revoke, snapshot: snapshot,
                    lookupCommittedResult: false, apply: apply))
            } catch { result = .failure(error) }
            var refreshed: V2PolicyOwnerState?
            if case .success(let execution) = result {
                refreshed = execution.state
                // A permanent receipt replay applies no facts. Retain the
                // existing facts, including expired authority. Only this
                // generation may publish them; readers still require a live
                // lease, or a tuple-validated renewal before using the facts.
                if refreshed == nil, execution.replayed, let replayState {
                    refreshed = replayState
                }
            }
            await self.jobFinished(operationKey, id: id, generation: generation, refreshed: refreshed)
            return try result.get()
        }
        jobs[operationKey] = .init(id: id, fingerprint: fingerprint, canonicalJSON: canonical, task: task)
        mutationTail = (id, task)
        // Caller cancellation does not cancel this actual operation or release
        // its root. Durable pending work remains recoverable on every failure.
        return try await task.value
    }

    package func recover(limit: Int = 128) async throws {
        try Task.checkCancellation()
        guard (1...128).contains(limit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard jobs.isEmpty, recoveries.isEmpty else { throw V2PolicyAuthorizationLifecycleError.busy }
        try requireCapacity()
        let currentState = !journal.roomDrainRequired
        if !currentState { invalidateState() }
        let id = UUID(), journal = journal, scope = scope, ownerID = ownerID
        let initialGeneration = stateGeneration
        let seconds = leaseSeconds, concurrency = revocationConcurrency, revoke = revoke, apply = apply, snapshot = snapshot
        let task = Task.detached {
            let pending: [V2PolicyAuthorizationChange]
            do { pending = try await journal.pendingChanges(scope: scope, limit: limit) }
            catch {
                // A failed read has not started any recovery effects. Current
                // committed facts remain valid; legacy recovery stays sealed.
                if currentState { await self.recoveryLookupFinished(id) }
                else { await self.recoveryFinished(id, generation: initialGeneration, refreshed: nil) }
                throw error
            }
            if currentState && pending.isEmpty {
                // A maintenance scan can race with a completed mutation.
                // Do not discard its published state or overwrite a cold load
                // that finished while this no-op lookup was suspended.
                await self.recoveryLookupFinished(id)
                return
            }
            let generation = currentState ? await self.beginRecovery() : initialGeneration
            let result: Result<Void, any Error>
            var refreshed: V2PolicyOwnerState?
            do {
                for pending in pending {
                    let execution = try await Self.execute(journal: journal, scope: scope, ownerID: ownerID,
                        seconds: seconds, operationKey: pending.operationKey, fingerprint: pending.fingerprint,
                        commandJSON: pending.commandJSON, concurrency: concurrency, revoke: revoke, snapshot: snapshot, apply: apply)
                    refreshed = execution.state
                }
                result = .success(())
            } catch { result = .failure(error); refreshed = nil }
            await self.recoveryFinished(id, generation: generation, refreshed: refreshed)
            return try result.get()
        }
        recoveries[id] = task
        try await task.value
    }

    package func shutdown() async {
        closed = true
        invalidateState()
        // Snapshot all retained roots before any suspension. Closed prevents
        // new roots, and task completion removes only its own generation.
        let work = jobs.values.map(\.task), claims = Array(claims.values), recoveries = Array(recoveries.values)
        let stateLoad = stateClaim?.task
        if let stateLoad { _ = await stateLoad.result }
        for task in work { _ = await task.result }
        for task in claims { _ = await task.result }
        for task in recoveries { _ = await task.result }
    }

    package func pressure() -> (closed: Bool, roots: Int) {
        (closed, jobs.count + claims.count + recoveries.count + (stateClaim == nil ? 0 : 1))
    }

    private func requireCapacity() throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard jobs.count + claims.count + recoveries.count + (stateClaim == nil ? 0 : 1) < maximumRoots else {
            throw V2PolicyAuthorizationLifecycleError.busy
        }
    }
    private func claimFinished(_ id: UUID) { claims[id] = nil }
    private func beginMutation() -> (UUID, V2PolicyOwnerState?) {
        let previous = state
        // Reject publication from any older cold load. Current-state writes
        // keep committed facts readable until the actual transaction settles;
        // no uncommitted facts are published. An uncertain failure clears them
        // in jobFinished, and expired authority never becomes a cache hit.
        stateGeneration = UUID()
        if journal.roomDrainRequired { state = nil }
        return (stateGeneration, previous)
    }
    private func beginRecovery() -> UUID {
        // Known pending effects may be uncertain. Seal reads and fence older
        // loads before performing recovery, rather than before its lookup.
        invalidateState()
        return stateGeneration
    }
    private func recoveryLookupFinished(_ id: UUID) { recoveries[id] = nil }
    private func recoveryFinished(_ id: UUID, generation: UUID, refreshed: V2PolicyOwnerState?) {
        recoveries[id] = nil
        if generation == stateGeneration, jobs.isEmpty, recoveries.isEmpty, !closed { state = refreshed }
    }
    private func jobFinished(_ key: String, id: UUID, generation: UUID, refreshed: V2PolicyOwnerState?) {
        jobLookupFinished(key, id: id)
        // Queued mutations cannot yet alter this generation. Publish the
        // settled result before waking their predecessor wait, so a replay
        // retains the immediately preceding committed memory state.
        if generation == stateGeneration, recoveries.isEmpty, !closed { state = refreshed }
    }
    private func jobLookupFinished(_ key: String, id: UUID) {
        if jobs[key]?.id == id { jobs[key] = nil }
        if mutationTail?.id == id { mutationTail = nil }
    }

    private static func canonical(_ json: String) throws -> String {
        guard json.utf8.count <= 16_384,
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func execute(journal: PostgresV2PolicyAuthorizationJournal, scope: V2PolicyAuthorizationScope,
        ownerID: UUID, seconds: Double, operationKey: String, fingerprint: Data, commandJSON: String,
        concurrency: Int, revoke: @escaping Revoker, snapshot: Snapshot? = nil,
        lookupCommittedResult: Bool = true, apply: @escaping Mutation
    ) async throws -> V2PolicyMutationExecution {
        if lookupCommittedResult, let receipt = try await journal.committedResult(scope: scope, operationKey: operationKey,
            fingerprint: fingerprint, commandJSON: commandJSON) { return .init(receipt: receipt, replayed: true) }
        if !journal.roomDrainRequired {
            return try await journal.changeCurrentPolicy(scope: scope, ownerID: ownerID,
                durationSeconds: seconds, operationKey: operationKey, fingerprint: fingerprint,
                commandJSON: commandJSON, snapshot: snapshot, apply: apply)
        }
        let owner = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: seconds)
        let change = try await journal.beginChange(owner: owner, operationKey: operationKey,
            fingerprint: fingerprint, commandJSON: commandJSON)
        if change.committed {
            guard let receipt = change.receipt else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            return .init(receipt: receipt, replayed: true)
        }
        while true {
            let targets = try await journal.targets(operationKey: operationKey)
            if targets.isEmpty { break }
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue(_ holder: V2PolicyAuthorizationHolder) {
                    group.addTask {
                        let proof = try await revoke(holder)
                        guard proof.holder == holder else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        try await journal.acknowledge(operationKey: operationKey, proof: proof)
                    }
                }
                while next < min(concurrency, targets.count) { enqueue(targets[next]); next += 1 }
                while try await group.next() != nil {
                    if next < targets.count { enqueue(targets[next]); next += 1 }
                }
            }
        }
        // Revocation may outlast the owner lease. Renew/reclaim before commit;
        // another owner already holding the scope rejects this stale runtime.
        let renewed = try await journal.acquireOwner(scope: scope, ownerID: ownerID, durationSeconds: seconds)
        return try await journal.commitPolicyExecution(owner: renewed, operationKey: operationKey, snapshot: snapshot, apply: apply)
    }
}
