import Foundation
import IMV2ServerContracts
import IMV2ActorContracts

public struct V2RealtimeJournalPublisherSource: Sendable {
    public let id: String
    public let store: any V2RealtimeChangeJournalStore
    public let consumerStore: (any V2RealtimeJournalConsumerStore)?
    public init(id: String, store: any V2RealtimeChangeJournalStore,
                consumerStore: (any V2RealtimeJournalConsumerStore)? = nil) {
        self.id = id; self.store = store; self.consumerStore = consumerStore
    }
}

/// Owns all actual SQL/application calls until they finish. A failed or unknown
/// append outcome leaves the old checkpoint intact, so the next attempt first
/// replays the durable journal. The callback must apply an entire batch before
/// returning, and use the supplied lease to reject stale projection generations.
public struct V2RealtimeJournalPublisherLease: Sendable {
    public let sourceID: String
    public let lease: V2RealtimePartitionLease
    public let deadline: ContinuousClock.Instant
    public init(sourceID: String, lease: V2RealtimePartitionLease, deadline: ContinuousClock.Instant) {
        self.sourceID = sourceID; self.lease = lease; self.deadline = deadline
    }
}

public actor V2RealtimeJournalPublisher {
    public typealias Apply = @Sendable (String, V2RealtimePartitionLease, V2RealtimeJournalBatch) async throws -> V2RealtimeJournalApplyResult
    private struct Key: Hashable, Sendable { let sourceID: String; let partitionID: Int }
    private struct State: Sendable {
        var lease: V2RealtimePartitionLease
        var deadline: ContinuousClock.Instant
        var checkpoint: Int64 = 0
        var needsReplay = true
    }
    private struct Work: Sendable {
        let key: Key
        let state: State
        let store: any V2RealtimeChangeJournalStore
    }
    private struct Completion: Sendable {
        let work: Work
        let checkpoint: Int64?
        let needsReplay: Bool
    }
    private let sources: [V2RealtimeJournalPublisherSource]
    private let apply: Apply
    private let idlePollInterval: Duration
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private var activeWork: [Key: Task<Void, Never>] = [:]
    private var claimRotation: [String: Int] = [:]
    private let completions = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(4))
    private var completionIterator: AsyncStream<Bool>.Iterator?
    private var states: [Key: State] = [:]
    private var claimDiscovery: Set<Key> = []
    private var lastClaimProgress = false
    private var owner: Task<Void, Never>?
    private var isClosed = false
    private var rotation = 0
    private var routingLeases: [String: [Int: V2RealtimePartitionLease]] = [:]
    private var claimTokens: [String: UUID] = [:]
    private var lastRenewal: [String: ContinuousClock.Instant] = [:]
    private var joiners: [CheckedContinuation<Void, Never>] = []

    public init(sources: [V2RealtimeJournalPublisherSource], idlePollInterval: Duration = .seconds(1),
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                apply: @escaping Apply) throws {
        guard !sources.isEmpty, sources.count <= 256,
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty }),
              idlePollInterval >= .milliseconds(100), idlePollInterval <= .seconds(30) else {
            throw V2RealtimeJournalError.invalidInput
        }
        self.sources = sources; self.apply = apply; self.idlePollInterval = idlePollInterval; self.monotonicNow = monotonicNow
    }

    /// Actual source-local claims, not the routing candidates supplied by runtime.
    public func currentSourceLeases() -> [V2RealtimeJournalPublisherLease] {
        guard !isClosed else { return [] }
        return states.compactMap { key, state in
            state.deadline > monotonicNow() ? .init(sourceID: key.sourceID, lease: state.lease, deadline: state.deadline) : nil
        }
    }

    public func start() {
        guard owner == nil, !isClosed else { return }
        owner = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let worked = await self.runOnce()
                let delay = await self.nextPollDelay(didWork: worked)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    private func nextPollDelay(didWork: Bool) -> Duration {
        didWork || lastClaimProgress ? .milliseconds(10) : idlePollInterval
    }

    /// Routing ownership only supplies candidates. Actual publication always
    /// claims a separate lease on each source database before admitting a batch.
    public func setLeases(sourceID: String, leases: [V2RealtimePartitionLease]) throws {
        guard !isClosed, sources.contains(where: { $0.id == sourceID }), leases.count <= 256,
              Set(leases.map(\.partitionID)).count == leases.count,
              leases.allSatisfy({ (0..<256).contains($0.partitionID) && $0.epoch > 0 }),
              Set(leases.map(\.identity)).count <= 1 else { throw V2RealtimeJournalError.invalidInput }
        let previous = routingLeases[sourceID] ?? [:]
        let next = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        routingLeases[sourceID] = next
        claimDiscovery = claimDiscovery.filter { $0.sourceID != sourceID || next[$0.partitionID] != nil }
        for (partitionID, lease) in next {
            if previous[partitionID].map({ !Self.sameGeneration($0, lease) }) ?? true {
                claimDiscovery.insert(.init(sourceID: sourceID, partitionID: partitionID))
            }
        }
        for key in Array(states.keys) where key.sourceID == sourceID {
            guard let old = previous[key.partitionID], let new = next[key.partitionID],
                  Self.sameGeneration(old, new) else { states.removeValue(forKey: key); continue }
        }
        if claimTokens[sourceID] == nil { claimTokens[sourceID] = UUID() }
    }

    /// Cancellation stops admission; joining retains responsibility for every
    /// previously admitted database transaction and projection callback.
    public func close() async {
        isClosed = true
        let running = owner
        running?.cancel()
        await running?.value
        let admitted = Array(activeWork.values)
        for task in admitted { task.cancel() }
        for task in admitted { await task.value }
        if cycleInFlight { await withCheckedContinuation { joiners.append($0) } }
        completions.continuation.finish()
        owner = nil
        states.removeAll(); claimDiscovery.removeAll()
    }

    /// Deterministic admission hook used by tests and explicit wake callers.
    /// Serializes discovery/admission. Up to four actual partition tasks survive
    /// across calls; each call waits for one completion rather than a slow tail.
    private var cycleInFlight = false
    @discardableResult public func runOnce() async -> Bool {
        guard !isClosed, !cycleInFlight else { return false }
        cycleInFlight = true
        lastClaimProgress = false
        defer {
            cycleInFlight = false
            let waiting = joiners; joiners.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        var candidates: [Work] = []
        // One indexed discovery per active database per finite cadence, rather
        // than probing every empty partition's head.
        for source in sources {
            guard let routed = routingLeases[source.id], !routed.isEmpty,
                  let identity = routed.values.first?.identity, let token = claimTokens[source.id] else { continue }
            let pending: Set<Int>
            do {
                var discovered = Set(try await source.store.pendingPartitions(partitionIDs: Array(routed.keys), limit: 256))
                if let consumers = source.consumerStore {
                    discovered.formUnion(try await consumers.pendingConsumerPartitions(partitionIDs: Array(routed.keys), limit: 256))
                }
                pending = discovered
            }
            catch { continue }
            guard !isClosed else { break }
            let existing = states.filter { $0.key.sourceID == source.id && $0.value.deadline > monotonicNow() }
            if lastRenewal[source.id].map({ monotonicNow() - $0 >= .seconds(5) }) ?? true {
                do {
                    let renewalStarted = monotonicNow()
                    let renewed = try await source.store.renew(existing.values.map(\.lease), leaseDuration: 15)
                    let valid = Dictionary(uniqueKeysWithValues: renewed.map { ($0.partitionID, $0) })
                    for (key, stored) in existing {
                        guard let current = states[key], Self.sameGeneration(current.lease, stored.lease) else { continue }
                        var state = current
                        if let lease = valid[key.partitionID], Self.sameGeneration(lease, stored.lease) {
                            state.lease = lease
                            state.deadline = renewalStarted + .seconds(lease.remainingLeaseSeconds)
                            states[key] = state
                        }
                        else {
                            state.deadline = renewalStarted
                            state.needsReplay = true
                            states[key] = state
                        }
                    }
                    lastRenewal[source.id] = renewalStarted
                } catch {
                    for (key, stored) in existing {
                        guard var current = states[key], Self.sameGeneration(current.lease, stored.lease) else { continue }
                        current.deadline = monotonicNow()
                        current.needsReplay = true
                        states[key] = current
                    }
                }
            }
            // Appending can consume the outbox before a projection callback
            // fails or expires. Retain that replay responsibility even when
            // indexed pending discovery no longer reports this partition.
            var claimCandidates = pending
            claimCandidates.formUnion(claimDiscovery.compactMap { $0.sourceID == source.id ? $0.partitionID : nil })
            claimCandidates.formUnion(states.compactMap { key, state in
                key.sourceID == source.id && state.needsReplay ? key.partitionID : nil
            })
            let unowned = claimCandidates.filter {
                guard let state = states[Key(sourceID: source.id, partitionID: $0)] else { return true }
                return state.deadline <= monotonicNow()
            }.sorted()
            if !unowned.isEmpty {
                do {
                    let start = claimRotation[source.id, default: 0] % unowned.count
                    let chosen = (0..<min(4, unowned.count)).map { unowned[(start + $0) % unowned.count] }
                    claimRotation[source.id] = (start + chosen.count) % unowned.count
                    let claimStarted = monotonicNow()
                    let claimed = try await source.store.claim(partitionIDs: chosen,
                        identity: identity, token: token, leaseDuration: 15)
                    for lease in claimed {
                        guard let currentRoute = routingLeases[source.id]?[lease.partitionID],
                              let requestedRoute = routed[lease.partitionID],
                              Self.sameGeneration(currentRoute, requestedRoute),
                              currentRoute.identity == identity,
                              claimStarted + .seconds(lease.remainingLeaseSeconds) > monotonicNow() else { continue }
                        let key = Key(sourceID: source.id, partitionID: lease.partitionID)
                        if claimDiscovery.remove(key) != nil { lastClaimProgress = true }
                        let checkpoint = states[key]?.checkpoint ?? 0
                        states[key] = State(lease: lease, deadline: claimStarted + .seconds(lease.remainingLeaseSeconds),
                                            checkpoint: checkpoint, needsReplay: true)
                    }
                } catch { continue }
            }
            for (key, state) in states where activeWork[key] == nil && state.deadline > monotonicNow() && key.sourceID == source.id && (state.needsReplay || pending.contains(key.partitionID)) {
                candidates.append(Work(key: key, state: state, store: source.store))
            }
        }
        guard !isClosed else { return false }
        candidates.sort { ($0.key.sourceID, $0.key.partitionID) < ($1.key.sourceID, $1.key.partitionID) }
        let count = candidates.count
        let capacity = max(0, 4 - activeWork.count)
        let selected = count == 0 ? [] : (0..<min(capacity, count)).map { candidates[(rotation + $0) % count] }
        if count > 0 { rotation = (rotation + selected.count) % count }
        for work in selected {
            let callback = apply, clock = monotonicNow
            activeWork[work.key] = Task {
                let completion = await Self.perform(work, now: clock, apply: callback)
                self.finish(completion)
            }
        }
        guard !activeWork.isEmpty else { return false }
        var iterator = completionIterator ?? completions.stream.makeAsyncIterator()
        let worked = await iterator.next(isolation: self) ?? false
        completionIterator = iterator
        return worked
    }

    private func finish(_ completion: Completion) {
        activeWork.removeValue(forKey: completion.work.key)
        var advanced = false
        if !isClosed, monotonicNow() < completion.work.state.deadline,
           var current = states[completion.work.key], current.deadline > monotonicNow(),
           Self.sameGeneration(current.lease, completion.work.state.lease) {
            if let checkpoint = completion.checkpoint {
                advanced = checkpoint > current.checkpoint
                current.checkpoint = max(current.checkpoint, checkpoint)
            }
            current.needsReplay = completion.needsReplay
            states[completion.work.key] = current
        }
        if !isClosed, !advanced,
           var current = states[completion.work.key], Self.sameGeneration(current.lease, completion.work.state.lease),
           monotonicNow() >= completion.work.state.deadline {
            // Never advance from the late result, but do keep the journal work
            // discoverable after its outbox row has already been consumed.
            current.needsReplay = true
            states[completion.work.key] = current
        }
        completions.continuation.yield(advanced)
    }

    private static func sameGeneration(_ lhs: V2RealtimePartitionLease, _ rhs: V2RealtimePartitionLease) -> Bool {
        lhs.partitionID == rhs.partitionID && lhs.epoch == rhs.epoch && lhs.token == rhs.token && lhs.identity == rhs.identity
    }

    private static func validateApplied(_ result: V2RealtimeJournalApplyResult, work: Work,
                                        batch: V2RealtimeJournalBatch) throws {
        let expected = batch.requiresSnapshot ? batch.publishedThrough : batch.entries.last?.sequence
        guard batch.partitionID == work.key.partitionID, result.sourceID == work.key.sourceID,
              result.partitionID == work.key.partitionID, result.appliedThrough == expected,
              !batch.requiresSnapshot || result.snapshotInstalled else {
            throw V2RealtimeJournalError.corruptPersistenceState
        }
    }

    private static func perform(_ work: Work, now: @Sendable () -> ContinuousClock.Instant, apply: Apply) async -> Completion {
        var checkpoint = work.state.checkpoint
        func checkLease() throws {
            try Task.checkCancellation()
            guard now() < work.state.deadline else { throw V2RealtimeJournalError.invalidInput }
        }
        do {
            try checkLease()
            let replay = try await work.store.replay(partitionID: work.key.partitionID, after: checkpoint, limit: 128)
            try checkLease()
            if replay.requiresSnapshot || !replay.entries.isEmpty {
                let result = try await apply(work.key.sourceID, work.state.lease, replay)
                try checkLease()
                try validateApplied(result, work: work, batch: replay)
                checkpoint = replay.requiresSnapshot ? replay.publishedThrough : (replay.entries.last?.sequence ?? checkpoint)
            }
            if checkpoint < replay.publishedThrough {
                return Completion(work: work, checkpoint: checkpoint, needsReplay: true)
            }
            try checkLease()
            let appended = try await work.store.publishPending(lease: work.state.lease, limit: 128)
            try checkLease()
            if !appended.entries.isEmpty || appended.requiresSnapshot {
                let result = try await apply(work.key.sourceID, work.state.lease, appended)
                try checkLease()
                try validateApplied(result, work: work, batch: appended)
                checkpoint = appended.requiresSnapshot ? appended.publishedThrough : (appended.entries.last?.sequence ?? checkpoint)
            }
                return Completion(work: work, checkpoint: checkpoint,
                needsReplay: checkpoint < appended.publishedThrough)
        } catch {
            // Do not checkpoint partially applied batches or uncertain commits.
            // Retain a successfully completed earlier replay, if any.
            return Completion(work: work, checkpoint: checkpoint, needsReplay: true)
        }
    }
}
