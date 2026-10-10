import Foundation
import FluentKit
import IMV2ServerApplication

/// One logical account/pair owner. SQL epochs are authority; actor isolation
/// protects bounded local roots, not distributed ownership. The runtime holds
/// each scope's mutations in order and publishes only committed facts.
package actor PostgresV2PolicyOwner {
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
    private let apply: Mutation
    private let snapshot: Snapshot?
    private var jobs: [String: Job] = [:]
    private var mutationTail: (id: UUID, task: Task<V2PolicyMutationExecution, any Error>)?
    private var recoveries: [UUID: Task<Void, any Error>] = [:]
    private var closed = false

    package init(journal: PostgresV2PolicyAuthorizationJournal, scope: V2PolicyAuthorizationScope,
                 ownerID: UUID = UUID(), leaseSeconds: Double = 30,
                 maximumRoots: Int = 16,
                 snapshot: Snapshot? = nil,
                 apply: @escaping Mutation) {
        precondition(scope.isValid && leaseSeconds.isFinite && leaseSeconds > 0 && leaseSeconds <= 300)
        precondition(maximumRoots > 0 && maximumRoots <= 128)
        self.journal = journal; self.scope = scope; self.ownerID = ownerID
        self.leaseSeconds = leaseSeconds; self.maximumRoots = maximumRoots
        self.apply = apply
        self.snapshot = snapshot
    }

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
        let seconds = leaseSeconds, apply = apply, snapshot = snapshot
        let task = Task.detached {
            // Actor reentrancy alone does not serialize persistence. Each
            // scope has its own bounded lane; unrelated scopes have no tail
            // dependency. A failed predecessor still settles before the next
            // operation checks the durable journal's pending state.
            if let predecessor { _ = await predecessor.result }
            // Permanent results are checked before attempting to claim SQL
            // authority; replay remains available after owner takeover.
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
            let result: Result<V2PolicyMutationExecution, any Error>
            do {
                result = .success(try await Self.execute(journal: journal, scope: scope, ownerID: ownerID,
                    seconds: seconds, operationKey: operationKey, fingerprint: fingerprint, commandJSON: canonical,
                    snapshot: snapshot,
                    lookupCommittedResult: false, apply: apply))
            } catch { result = .failure(error) }
            await self.jobLookupFinished(operationKey, id: id)
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
        let id = UUID(), journal = journal, scope = scope, ownerID = ownerID
        let seconds = leaseSeconds, apply = apply, snapshot = snapshot
        let task = Task.detached {
            let pending: [V2PolicyAuthorizationChange]
            do { pending = try await journal.pendingChanges(scope: scope, limit: limit) }
            catch {
                // A failed scan has not started any recovery effects.
                await self.recoveryLookupFinished(id)
                throw error
            }
            if pending.isEmpty {
                // An empty scan starts no mutation work.
                await self.recoveryLookupFinished(id)
                return
            }
            let result: Result<Void, any Error>
            do {
                for pending in pending {
                    _ = try await Self.execute(journal: journal, scope: scope, ownerID: ownerID,
                        seconds: seconds, operationKey: pending.operationKey, fingerprint: pending.fingerprint,
                        commandJSON: pending.commandJSON, snapshot: snapshot, apply: apply)
                }
                result = .success(())
            } catch { result = .failure(error) }
            await self.recoveryLookupFinished(id)
            return try result.get()
        }
        recoveries[id] = task
        try await task.value
    }

    package func shutdown() async {
        closed = true
        // Snapshot all retained roots before any suspension. Closed prevents
        // new roots, and task completion removes only its own generation.
        let work = jobs.values.map(\.task), recoveries = Array(recoveries.values)
        for task in work { _ = await task.result }
        for task in recoveries { _ = await task.result }
    }

    package func pressure() -> (closed: Bool, roots: Int) {
        (closed, jobs.count + recoveries.count)
    }

    private func requireCapacity() throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard jobs.count + recoveries.count < maximumRoots else {
            throw V2PolicyAuthorizationLifecycleError.busy
        }
    }
    private func recoveryLookupFinished(_ id: UUID) { recoveries[id] = nil }
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
        snapshot: Snapshot? = nil,
        lookupCommittedResult: Bool = true, apply: @escaping Mutation
    ) async throws -> V2PolicyMutationExecution {
        if lookupCommittedResult, let receipt = try await journal.committedResult(scope: scope, operationKey: operationKey,
            fingerprint: fingerprint, commandJSON: commandJSON) { return .init(receipt: receipt, replayed: true) }
        return try await journal.changeCurrentPolicy(scope: scope, ownerID: ownerID,
            durationSeconds: seconds, operationKey: operationKey, fingerprint: fingerprint,
            commandJSON: commandJSON, snapshot: snapshot, apply: apply)
    }
}
