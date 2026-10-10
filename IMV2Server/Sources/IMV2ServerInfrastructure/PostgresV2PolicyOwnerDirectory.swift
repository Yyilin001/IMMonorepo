import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// One process's bounded account/pair owner registry. Database epochs remain
/// authoritative; a common process ID lets an idle scope be evicted and later
/// reconstructed while versioned facts remain in the separate snapshot cache.
package actor PostgresV2PolicyOwnerDirectory {
    private struct Entry {
        let owner: PostgresV2PolicyOwner
        var uses: Int
    }
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let dispatcher: PostgresV2PolicyMutationDispatcher
    private let ownerID: UUID
    private nonisolated let ownsScope: @Sendable (String) -> Bool
    private let maximumOwners: Int
    private let maximumRoots: Int
    private let leaseSeconds: Double
    private var owners: [String: Entry] = [:]
    private var idle = V2IndexedFIFO<String, String>()
    private var roots: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private let committed: (@Sendable (V2PolicyAuthorizationScope) async throws -> Void)?
    private var pendingScanCursor: V2PolicyJournalCursor?
    private var pendingScanUpper: V2PolicyJournalCursor?
    private var recovering = false
    private let snapshots = V2NodePolicyStateCache()
    private let snapshotPublisher: V2PolicySnapshotPublisher?

    package init(journal: PostgresV2PolicyAuthorizationJournal, dispatcher: PostgresV2PolicyMutationDispatcher,
                 ownerID: UUID = UUID(), maximumOwners: Int = 4_096, maximumRoots: Int = 64,
                 committed: (@Sendable (V2PolicyAuthorizationScope) async throws -> Void)? = nil,
                 snapshotPublisher: V2PolicySnapshotPublisher? = nil,
                 leaseSeconds: Double = 30, ownsScope: @escaping @Sendable (String) -> Bool = { _ in true }) {
        precondition(maximumOwners > 0 && maximumRoots > 0 && maximumRoots <= 1_024)
        precondition(leaseSeconds.isFinite && leaseSeconds > 0 && leaseSeconds <= 300)
        self.journal = journal; self.dispatcher = dispatcher; self.ownerID = ownerID
        self.maximumOwners = maximumOwners; self.maximumRoots = maximumRoots
        self.leaseSeconds = leaseSeconds
        self.ownsScope = ownsScope
        self.committed = committed; self.snapshotPublisher = snapshotPublisher
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
                if let snapshot = execution.state {
                    try await self.snapshots.install(snapshot)
                    do { try await self.snapshotPublisher?.publish(snapshot) }
                    catch { throw V2RoomCallFailure.outcomeUnknown }
                }
                return (try JSONDecoder().decode(V2PolicyMutationResult.self, from: execution.receipt), execution.replayed)
            }
        }
        if result.1 {
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
            try await self.publishSnapshot(scope: mutation.scope)
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
        await snapshots.shutdown()
    }

    package func pressure() -> (closed: Bool, owners: Int, roots: Int) {
        (closed, owners.count, roots.count)
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
            if owners.count == maximumOwners {
                guard let retired = idle.removeFirst() else { throw V2PolicyAuthorizationLifecycleError.busy }
                // Zero uses means every actual owner future has settled.
                owners[retired] = nil
            }
            let dispatcher = dispatcher, journal = journal
            owners[key] = .init(owner: .init(journal: journal, scope: scope, ownerID: ownerID,
                leaseSeconds: leaseSeconds,
                snapshot: { context, change in
                    try await journal.mutationFacts(scope: scope, context: context, change: change)
                },
                apply: { try await dispatcher.apply(context: $0, change: $1) }), uses: 0)
        }
        idle.remove(key)
        owners[key]!.uses += 1
        let owner = owners[key]!.owner
        defer {
            owners[key]!.uses -= 1
            if owners[key]!.uses == 0 { idle.append(key, key: key) }
        }
        return try await operation(owner)
    }
}
