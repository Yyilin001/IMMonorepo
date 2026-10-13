import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts

/// Owns the persisted online projection and its SQL lifecycle.
/// Projection expiry never revokes an authenticated socket. Session expiry,
/// heartbeat timeout and explicit revocation belong to the connection owner.
public actor V2ConnectionLeaseController {
    private struct Lease {
        let lifecycle: UInt64
        let identity: V2AuthenticatedConnection
        let policy: V2AuthenticatedConnectionAdmissionPolicy
        var publicationSuppressed: Bool
        var deadline: ContinuousClock.Instant
        var heartbeat: ContinuousClock.Instant
        var coveredHeartbeat: ContinuousClock.Instant
        var renewAt: ContinuousClock.Instant
        var retryAt: ContinuousClock.Instant?
    }
    private let store: any V2LivePresenceLeaseManaging
    private let batcher: V2LivePresenceRenewalBatcher
    private let maximumConnections: Int
    private let onRemoved: @Sendable (UUID, V2AuthenticatedConnection, Bool) async -> Void
    private var retainedConnections: Set<UUID> = []
    private var pendingCleanup: [UUID: V2AuthenticatedConnection] = [:]
    private var cleanupOrder: [UUID] = []
    private var cleanupOffset = 0
    private var cleanupQueued: Set<UUID> = []
    private var cleanupWorker: Task<Void, Never>?
    private var leases: [UUID: Lease] = [:]
    private var admissions: [UUID: UInt64] = [:]
    private var operations: [UUID: Int] = [:]
    private var operationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var renewing: [UUID: UUID] = [:]
    private struct ProjectionRefresh {
        let lifecycle: UInt64
        let ticket: UUID
        let task: Task<Bool, Never>
        var waiters: Int
    }
    private var projectionRefreshes: [UUID: ProjectionRefresh] = [:]
    private var renewalDeadlines = V2ConnectionRenewalDeadlines()
    private var wake: Task<Void, Never>?
    private var wakeDeadline: ContinuousClock.Instant?
    private var activeWakes: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    public init(leases: any V2LivePresenceLeaseManaging,
        configuration: V2LivePresenceRenewalBatcher.Configuration = .init(),
        maximumConnections: Int,
        onRemoved: @escaping @Sendable (UUID, V2AuthenticatedConnection, Bool) async -> Void = { _, _, _ in }) {
        precondition(maximumConnections > 0)
        self.store = leases
        self.maximumConnections = maximumConnections
        self.batcher = .init(leases: leases, configuration: configuration,
            maximumPendingConnections: maximumConnections)
        self.onRemoved = onRemoved
    }

    public func admit(connectionID: UUID,
        identity: V2AuthenticatedConnection, lifecycle: UInt64, publicationSuppressed: Bool,
        policy: V2AuthenticatedConnectionAdmissionPolicy) async throws -> V2LivePresenceLeaseRefresh? {
        guard !closed, leases[connectionID] == nil, admissions[connectionID] == nil,
              operations[connectionID] == nil,
              !retainedConnections.contains(connectionID), retainedConnections.count < maximumConnections else { return nil }
        retainedConnections.insert(connectionID)
        admissions[connectionID] = lifecycle
        begin(connectionID)
        defer { end(connectionID) }
        let started = ContinuousClock.now, date = Date()
        let refresh: V2LivePresenceLeaseRefresh
        do {
            refresh = try await store.admitConnectionRefresh(identity: identity,
                connectionID: connectionID, publicationSuppressed: publicationSuppressed,
                policy: policy, now: date)
        } catch {
            if admissions[connectionID] == lifecycle { admissions.removeValue(forKey: connectionID) }
            // Unknown outcomes may have written a row. Ownership blocks UUID reuse until compensation settles.
            _ = try? await store.removePresence(identity: identity, connectionID: connectionID, now: Date())
            throw error
        }
        guard !closed, admissions[connectionID] == lifecycle,
              let deadline = Self.deadline(refresh, started: started, date: date), deadline > .now else {
            if admissions[connectionID] == lifecycle { admissions.removeValue(forKey: connectionID) }
            _ = try? await store.removePresence(identity: identity, connectionID: connectionID, now: Date())
            return nil
        }
        admissions.removeValue(forKey: connectionID)
        leases[connectionID] = .init(lifecycle: lifecycle, identity: identity, policy: policy, publicationSuppressed: publicationSuppressed,
            deadline: deadline, heartbeat: started, coveredHeartbeat: started,
            renewAt: Self.renewalDate(deadline))
        return refresh
    }

    /// Retire the projection lifecycle; actual SQL ownership remains until settlement.
    public func revoke(connectionID: UUID, lifecycle: UInt64) {
        if admissions[connectionID] == lifecycle { admissions.removeValue(forKey: connectionID) }
        guard let lease = leases[connectionID], lease.lifecycle == lifecycle else { return }
        leases.removeValue(forKey: connectionID)
        updateWake(connectionID)
    }

    public func heartbeat(connectionID: UUID, lifecycle: UInt64) async -> Bool {
        guard !closed, var lease = leases[connectionID], lease.lifecycle == lifecycle else { return false }
        lease.heartbeat = .now
        leases[connectionID] = lease
        updateWake(connectionID)
        return true
    }

    public func refreshProjection(connectionID: UUID, lifecycle: UInt64) async -> Bool {
        guard !closed, let submitted = leases[connectionID], submitted.lifecycle == lifecycle else { return false }
        if let existing = projectionRefreshes[connectionID] {
            guard existing.lifecycle == lifecycle else { return false }
            projectionRefreshes[connectionID]?.waiters += 1
            defer { releaseProjectionWaiter(connectionID, ticket: existing.ticket) }
            return await existing.task.value
        }
        if renewing[connectionID] != nil {
            await drain(connectionID)
            guard let current = leases[connectionID], current.lifecycle == lifecycle else { return false }
            return current.deadline > .now
        }
        guard !Task.isCancelled else { return false }
        let ticket = UUID()
        begin(connectionID)
        // One owned task per admitted connection. Caller cancellation never
        // cancels the shared database waiter or releases actual ownership.
        let task = Task { await self.performProjectionRefresh(connectionID,
            submitted: submitted, ticket: ticket) }
        projectionRefreshes[connectionID] = .init(lifecycle: lifecycle, ticket: ticket, task: task, waiters: 1)
        defer { releaseProjectionWaiter(connectionID, ticket: ticket) }
        return await task.value
    }

    func projectionRefreshWaiterCount(connectionID: UUID) -> Int {
        projectionRefreshes[connectionID]?.waiters ?? 0
    }

    private func releaseProjectionWaiter(_ connectionID: UUID, ticket: UUID) {
        guard projectionRefreshes[connectionID]?.ticket == ticket else { return }
        projectionRefreshes[connectionID]?.waiters -= 1
    }

    private func performProjectionRefresh(_ connectionID: UUID, submitted: Lease, ticket: UUID) async -> Bool {
        defer {
            if projectionRefreshes[connectionID]?.ticket == ticket {
                projectionRefreshes.removeValue(forKey: connectionID)
            }
            updateWake(connectionID)
            end(connectionID)
        }
        let started = ContinuousClock.now, date = Date()
        let result: Result<V2LivePresenceLeaseRefresh, any Error>
        do { result = .success(try await batcher.renew(identity: submitted.identity, connectionID: connectionID, now: date)) }
        catch { result = .failure(error) }
        return await apply(result, connectionID: connectionID, submitted: submitted, started: started, date: date)
    }

    /// Publication policy changes share actual lease-row ownership with
    /// admission, renewal and deletion. A post-await lifecycle check alone
    /// cannot protect a successor row from a late database update.
    public func setPresencePublication(connectionID: UUID, lifecycle: UInt64,
        identity: V2AuthenticatedConnection, suppressed: Bool) async throws -> V2PresencePublicationLeaseObservation? {
        guard !closed, let current = leases[connectionID], current.lifecycle == lifecycle,
              current.identity == identity else { return nil }
        try Task.checkCancellation()
        begin(connectionID)
        defer { end(connectionID) }
        let store = self.store
        let date = Date()
        let actual = Task {
            try await store.setPresencePublication(identity: identity, connectionID: connectionID,
                suppressed: suppressed, now: date)
        }
        let observation = try await actual.value
        guard !closed, let latest = leases[connectionID], latest.lifecycle == lifecycle,
              latest.identity == identity else { return nil }
        leases[connectionID]?.publicationSuppressed = suppressed
        return observation
    }

    /// Revocation never waits for submitted admission/renewal SQL. Cleanup has
    /// its own bounded ownership and holds the ID until its actual completion.
    public func removePresence(identity: V2AuthenticatedConnection, connectionID: UUID) async -> Bool? {
        guard leases[connectionID] == nil, admissions[connectionID] == nil else { return nil }
        if operations[connectionID] != nil || pendingCleanup[connectionID] != nil {
            scheduleCleanup(identity: identity, connectionID: connectionID)
            return nil
        }
        begin(connectionID)
        defer { end(connectionID) }
        return try? await store.removePresence(identity: identity, connectionID: connectionID, now: Date())
    }

    private func scheduleCleanup(identity: V2AuthenticatedConnection, connectionID: UUID) {
        guard pendingCleanup[connectionID] == nil else { return }
        // The original admission reserved this position. Failed duplicate
        // registrations do not create additional cleanup records.
        guard retainedConnections.contains(connectionID) else { return }
        pendingCleanup[connectionID] = identity
        enqueueEligibleCleanup(connectionID)
    }

    private func enqueueEligibleCleanup(_ id: UUID) {
        guard pendingCleanup[id] != nil, operations[id] == nil,
              cleanupQueued.insert(id).inserted else { return }
        cleanupOrder.append(id)
        if cleanupWorker == nil { cleanupWorker = Task { await self.runCleanup() } }
    }

    private func runCleanup() async {
        while cleanupOffset < cleanupOrder.count {
            let id = cleanupOrder[cleanupOffset]; cleanupOffset += 1
            cleanupQueued.remove(id)
            guard let identity = pendingCleanup[id], operations[id] == nil else { continue }
            // Retained ID ownership prevents a successor from being admitted
            // between draining old SQL and this final compensating deletion.
            if leases[id] == nil, admissions[id] == nil {
                begin(id)
                let result = try? await store.removePresence(identity: identity, connectionID: id, now: Date())
                if let result { await onRemoved(id, identity, result) }
                pendingCleanup.removeValue(forKey: id)
                end(id)
            } else {
                pendingCleanup.removeValue(forKey: id)
                releaseRetiredPosition(id)
            }
            if cleanupOffset > 512, cleanupOffset * 2 > cleanupOrder.count {
                cleanupOrder.removeFirst(cleanupOffset); cleanupOffset = 0
            }
        }
        cleanupOrder.removeAll(); cleanupOffset = 0
        cleanupWorker = nil
    }

    public func snapshot(connectionID: UUID) -> (deadline: ContinuousClock.Instant?, renewing: Bool, renewAt: ContinuousClock.Instant?) {
        (leases[connectionID]?.deadline, renewing[connectionID] != nil || projectionRefreshes[connectionID] != nil, leases[connectionID]?.renewAt)
    }

    public func metrics() async -> V2LivePresenceRenewalBatcherSnapshot { await batcher.snapshot() }

    public func finish() async {
        closed = true
        wake?.cancel(); wake = nil; wakeDeadline = nil
        admissions.removeAll()
        leases.removeAll()
        renewalDeadlines.removeAll()
        await batcher.finish()
        while true {
            while let task = activeWakes.values.first { await task.value }
            await cleanupWorker?.value
            if let id = operations.keys.first { await drain(id); continue }
            // A submitted admission can create compensation while a prior
            // drain was suspended. Recheck all owned stages before finishing.
            if cleanupWorker != nil || !activeWakes.isEmpty { continue }
            break
        }
    }

    private static func deadline(_ refresh: V2LivePresenceLeaseRefresh,
        started: ContinuousClock.Instant, date: Date) -> ContinuousClock.Instant? {
        guard case .accepted(let expiry) = refresh.outcome else { return nil }
        let seconds = refresh.remainingLeaseSeconds ?? expiry.timeIntervalSince(date)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return started.advanced(by: .seconds(seconds))
    }

    private static func renewalDate(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        return now.advanced(by: now.duration(to: deadline) * 2 / 3)
    }

    private func nextWake(_ id: UUID, _ lease: Lease) -> ContinuousClock.Instant? {
        guard renewing[id] == nil, projectionRefreshes[id] == nil,
              lease.heartbeat > lease.coveredHeartbeat else { return nil }
        return lease.retryAt ?? lease.renewAt
    }

    private func enqueue(_ id: UUID, lease: Lease) async {
        guard !closed, renewing[id] == nil, leases[id]?.lifecycle == lease.lifecycle else { return }
        let ticket = UUID(), started = ContinuousClock.now, date = Date()
        renewing[id] = ticket
        updateWake(id)
        begin(id)
        let accepted = await batcher.enqueue(identity: lease.identity, connectionID: id, now: date) { result in
            await self.completed(id, ticket: ticket, submitted: lease, started: started, date: date, result: result)
        }
        if !accepted, renewing[id] == ticket {
            renewing.removeValue(forKey: id)
            end(id)
            retry(id, lifecycle: lease.lifecycle)
        }
    }

    private func completed(_ id: UUID, ticket: UUID, submitted: Lease,
        started: ContinuousClock.Instant, date: Date,
        result: Result<V2LivePresenceLeaseRefresh, any Error>) async {
        guard renewing[id] == ticket else { return }
        renewing.removeValue(forKey: id)
        end(id)
        _ = await apply(result, connectionID: id, submitted: submitted, started: started, date: date)
    }

    private func apply(_ result: Result<V2LivePresenceLeaseRefresh, any Error>, connectionID id: UUID,
        submitted: Lease, started: ContinuousClock.Instant, date: Date) async -> Bool {
        guard !closed, let retained = leases[id], retained.lifecycle == submitted.lifecycle else { return false }
        // An expired/missing online row is repaired under the original admission
        // policy. This grants presence only, never a new authenticated identity.
        var observation = result
        if case .success(let refresh) = result, case .rejected = refresh.outcome {
            do {
                observation = .success(try await store.admitConnectionRefresh(identity: retained.identity,
                    connectionID: id, publicationSuppressed: retained.publicationSuppressed,
                    policy: retained.policy, now: date))
            } catch { observation = .failure(error) }
        }
        guard !closed, var current = leases[id], current.lifecycle == submitted.lifecycle else { return false }
        switch observation {
        case .success(let refresh):
            guard let deadline = Self.deadline(refresh, started: started, date: date), deadline > .now else {
                retry(id, lifecycle: submitted.lifecycle); return false
            }
            current.deadline = max(current.deadline, deadline)
            current.coveredHeartbeat = max(current.coveredHeartbeat, submitted.heartbeat)
            current.renewAt = Self.renewalDate(current.deadline)
            current.retryAt = nil
            leases[id] = current
            updateWake(id)
            return true
        case .failure:
            retry(id, lifecycle: submitted.lifecycle)
            return false
        }
    }

    private func retry(_ id: UUID, lifecycle: UInt64) {
        guard !closed, var current = leases[id], current.lifecycle == lifecycle else { return }
        current.retryAt = .now + .seconds(1)
        leases[id] = current
        updateWake(id)
    }

    private func updateWake(_ id: UUID) {
        renewalDeadlines.set(id, deadline: leases[id].flatMap { nextWake(id, $0) })
        scheduleNextWake()
    }

    private func scheduleNextWake() {
        guard let first = renewalDeadlines.first else {
            wake?.cancel(); wake = nil; wakeDeadline = nil
            return
        }
        // Coalesce nearby deadlines, rather than launching a timer per connection.
        schedule(max(first.deadline, .now + .milliseconds(10)))
    }

    private func schedule(_ deadline: ContinuousClock.Instant) {
        guard !closed else { return }
        if let existing = wakeDeadline, existing <= deadline { return }
        wake?.cancel(); wakeDeadline = deadline
        let ticket = UUID()
        let task = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                await self?.processWake(deadline)
            } catch {}
            await self?.wakeCompleted(ticket)
        }
        wake = task
        activeWakes[ticket] = task
    }

    private func wakeCompleted(_ ticket: UUID) { activeWakes.removeValue(forKey: ticket) }

    private func processWake(_ deadline: ContinuousClock.Instant) async {
        guard !closed, wakeDeadline == deadline else { return }
        wake = nil; wakeDeadline = nil
        let observedAt = ContinuousClock.now
        var due: [V2ConnectionRenewalDeadlines.Entry] = []
        while let entry = renewalDeadlines.popDue(at: observedAt) { due.append(entry) }
        for entry in due {
            let id = entry.connectionID
            // Another operation may renew or revoke this connection while enqueue suspends.
            guard !closed, let current = leases[id],
                  let next = nextWake(id, current), next <= observedAt else { continue }
            await enqueue(id, lease: current)
        }
        scheduleNextWake()
    }

    private func begin(_ id: UUID) { operations[id, default: 0] += 1 }
    private func end(_ id: UUID) {
        guard let count = operations[id], count > 0 else { preconditionFailure("lease operation ownership") }
        if count == 1 {
            operations.removeValue(forKey: id)
            let waiters = operationWaiters.removeValue(forKey: id) ?? []
            for waiter in waiters { waiter.resume() }
            enqueueEligibleCleanup(id)
            releaseRetiredPosition(id)
        } else { operations[id] = count - 1 }
    }
    private func releaseRetiredPosition(_ id: UUID) {
        guard leases[id] == nil, admissions[id] == nil, operations[id] == nil,
              pendingCleanup[id] == nil else { return }
        retainedConnections.remove(id)
    }

    private func drain(_ id: UUID) async {
        while operations[id] != nil {
            await withCheckedContinuation { operationWaiters[id, default: []].append($0) }
        }
    }
}
