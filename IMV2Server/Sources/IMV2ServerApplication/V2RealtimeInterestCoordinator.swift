import Foundation
import HashTreeCollections
import IMV2ActorContracts
import IMV2ServerContracts
import Synchronization

/// Gateway-owned desired state. One actual control worker per partition, with
/// transport-owned peer/global control admission. Callers are cancellable waiters only.
public actor V2RealtimeInterestCoordinator {
    public enum Failure: Error { case closed, missingOwner, stale, exhausted, recovering }
    public typealias Heads = @Sendable ([V2RealtimeTopic]) async throws -> [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome]
    public typealias Recovered = @Sendable ([V2RealtimeTopic: UInt64]) async throws -> Set<V2RealtimeTopic>
    private struct Fence: Sendable {
        let token: V2RealtimeShardToken; let sessionID: UUID; let generation: Int64
        let owner: V2RoomDataOwner; let highWatermark: UInt64; let deadline: ContinuousClock.Instant; let ready: Bool
    }
    /// Topic authorization is immutable across a same-session renewal. Only
    /// the acknowledged partition session deadline changes; no scope scan is
    /// needed while holding the read-side mutex.
    private struct FenceState: Sendable {
        private struct SessionDeadline: Sendable {
            let token: V2RealtimeShardToken
            let sessionID: UUID
            let deadline: ContinuousClock.Instant
        }
        private var topics: [V2RealtimeTopicKey: Fence] = [:]
        private var sessions: [Int: SessionDeadline] = [:]
        subscript(key: V2RealtimeTopicKey) -> Fence? {
            get {
                guard let fence = topics[key] else { return nil }
                guard let session = sessions[fence.token.partitionID] else { return fence }
                guard session.token == fence.token, session.sessionID == fence.sessionID else { return nil }
                return Fence(token: fence.token, sessionID: fence.sessionID, generation: fence.generation,
                    owner: fence.owner, highWatermark: fence.highWatermark, deadline: session.deadline, ready: fence.ready)
            }
            set { topics[key] = newValue }
        }
        mutating func renew(token: V2RealtimeShardToken, sessionID: UUID, deadline: ContinuousClock.Instant) {
            sessions[token.partitionID] = .init(token: token, sessionID: sessionID, deadline: deadline)
        }
        mutating func removeValue(forKey key: V2RealtimeTopicKey) { topics.removeValue(forKey: key) }
        mutating func invalidateSession(partitionID: Int) { sessions.removeValue(forKey: partitionID) }
        mutating func removeAll() { topics.removeAll(); sessions.removeAll() }
    }
    private struct Entry: Sendable {
        var topic: V2RealtimeTopic
        var generation: Int64
        var active: Bool
        var ready = false
    }
    private final class Partition {
        var descriptor: V2RealtimeShardDescriptor?
        var descriptorDeadline: ContinuousClock.Instant = .now
        var session: V2RealtimeShardSession
        var revision: Int64 = 0
        var installed: TreeDictionary<V2RealtimeTopicKey, Int64> = [:]
        var sessionDeadline: ContinuousClock.Instant = .now
        var lastHeadCheck: ContinuousClock.Instant = .now
        var snapshot = true
        var pendingRecovery = V2RealtimeKeyQueue<V2RealtimeTopicKey>()
        var dirty = V2RealtimeKeyQueue<V2RealtimeTopicKey>()
        var retryRecovery: Set<V2RealtimeTopicKey> = []
        var recoveryWorker: Task<Void, Never>?
        var renewalWorker: Task<Void, Never>?
        var worker: Task<Void, Never>?
        var pending: V2RealtimeShardControlRequest?
        init(session: V2RealtimeShardSession) { self.session = session }
    }
    private struct Waiter {
        let desired: [V2RealtimeTopicKey: Int64]
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let descriptor: V2GatewayRealtimeDescriptor
    private let transport: any V2RealtimeShardTransport
    private let heads: Heads
    private let recovered: Recovered
    private let coverageReady: @Sendable ([V2RealtimeTopic: V2RealtimeCoverageConfirmation]) async -> Void
    private let coverageLost: @Sendable (Set<V2RealtimeTopic>, ContinuousClock.Instant) async -> Void
    private let metrics: V2ActorRealtimeMetrics?
    private nonisolated let fences = Mutex(FenceState())
    public struct JournalCoverage: Sendable {
        public let token: V2RealtimeShardToken
        public let sessionID: UUID
        public let revision: Int64
        public let interests: TreeDictionary<V2RealtimeTopicKey, Int64>
        public let deadline: ContinuousClock.Instant
    }
    public struct JournalInterestProof: Sendable {
        public let coverage: JournalCoverage
        public let topic: V2RealtimeTopic
        public let generation: Int64
    }
    public enum JournalCoverageChange: Sendable {
        case installed(JournalCoverage)
        case renewed(JournalCoverage)
        case invalidated(partitionID: Int)
    }
    private nonisolated let journalObserver = Mutex<V2CallbackBox<@Sendable (JournalCoverageChange) -> Void>?>(nil)
    private nonisolated let trustedJournalRenewal = Mutex<V2CallbackBox<@Sendable (JournalCoverage) -> Bool>?>(nil)
    public nonisolated func configureJournalCoverageObserver(_ observer: @escaping @Sendable (JournalCoverageChange) -> Void) {
        journalObserver.withLock { $0 = V2CallbackBox(observer) }
    }
    public nonisolated func configureTrustedJournalRenewal(_ current: @escaping @Sendable (JournalCoverage) -> Bool) {
        trustedJournalRenewal.withLock { $0 = V2CallbackBox(current) }
    }
    public nonisolated func activeJournalCoverages() -> [JournalCoverage] {
        journalCoverages.withLock { $0.values.filter { $0.deadline > .now && !$0.interests.isEmpty } }
    }
    public nonisolated func journalInterest(topic: V2RealtimeTopic) -> JournalInterestProof? {
        let key = V2RealtimeTopicKey(topic)
        guard let coverage = journalCoverage(partitionID: key.partitionID()),
              let generation = coverage.interests[key], generation > 0 else { return nil }
        let ownerCurrent = fences.withLock { $0[key].map { $0.owner == topic.owner && $0.generation == generation } ?? false }
        guard ownerCurrent else { return nil }
        return .init(coverage: coverage, topic: topic, generation: generation)
    }
    public nonisolated func confirmsJournalInterest(_ proof: JournalInterestProof) -> Bool {
        guard confirmsJournalCoverage(proof.coverage),
              proof.coverage.interests[V2RealtimeTopicKey(proof.topic)] == proof.generation else { return false }
        return fences.withLock { $0[V2RealtimeTopicKey(proof.topic)].map {
            $0.owner == proof.topic.owner && $0.generation == proof.generation
        } ?? false }
    }
    private nonisolated func withdrawJournalCoverage(_ partitionID: Int) {
        let removed = journalCoverages.withLock { $0.removeValue(forKey: partitionID) != nil }
        if removed { journalObserver.withLock { $0?.callback }?(.invalidated(partitionID: partitionID)) }
    }
    private nonisolated let journalCoverages = Mutex<[Int: JournalCoverage]>([:])
    /// Complete acknowledged partition interests; revision is independent of
    /// each topic's generation. A pending mutation immediately withdraws it.
    public nonisolated func journalCoverage(partitionID: Int) -> JournalCoverage? {
        journalCoverages.withLock { $0[partitionID].flatMap { $0.deadline > .now ? $0 : nil } }
    }
    public nonisolated func confirmsJournalCoverage(_ expected: JournalCoverage) -> Bool {
        journalCoverages.withLock { value in
            guard let current = value[expected.token.partitionID], current.deadline > .now else { return false }
            return current.token == expected.token && current.sessionID == expected.sessionID
                && current.revision == expected.revision && current.interests == expected.interests
        }
    }
    private func retainJournalCoverage(_ id: Int, partition: Partition) {
        guard !closed, !partition.snapshot, partition.revision > 0,
              let token = partition.descriptor?.token, partition.sessionDeadline > .now else {
            withdrawJournalCoverage(id); return
        }
        let coverage = JournalCoverage(token: token, sessionID: partition.session.sessionID,
            revision: partition.revision, interests: partition.installed,
            deadline: min(partition.sessionDeadline, partition.descriptorDeadline))
        let old = journalCoverages.withLock { value in
            let old = value[id]; value[id] = coverage; return old
        }
        let sameGeneration = old.map {
            $0.token == coverage.token && $0.sessionID == coverage.sessionID
                && $0.revision == coverage.revision && $0.interests == coverage.interests
        } ?? false
        journalObserver.withLock { $0?.callback }?(sameGeneration ? .renewed(coverage) : .installed(coverage))
    }
    private static let interestGenerations = Mutex<Int64>(0)
    private let maximumDesiredInterests: Int
    private var entries: [V2RealtimeTopicKey: Entry] = [:]
    private var partitions: [Int: Partition] = [:]
    private var keysByPartition: [Int: Set<V2RealtimeTopicKey>] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var waitersByTopic: [V2RealtimeTopicKey: Set<UUID>] = [:]
    private var waitersByPartition: [Int: Set<UUID>] = [:]
    private var recoveries = 0
    private var recoveryQueue: [Int] = []
    private var recoveryQueued: Set<Int> = []
    private var periodic: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var closed = false
    public init(descriptor: V2GatewayRealtimeDescriptor, transport: any V2RealtimeShardTransport,
                metrics: V2ActorRealtimeMetrics? = nil, maximumDesiredInterests: Int = 100_000,
                readHeads: @escaping Heads, recovered: @escaping Recovered,
                coverageReady: @escaping @Sendable ([V2RealtimeTopic: V2RealtimeCoverageConfirmation]) async -> Void = { _ in },
                coverageLost: @escaping @Sendable (Set<V2RealtimeTopic>, ContinuousClock.Instant) async -> Void) {
        precondition((1...100_000).contains(maximumDesiredInterests))
        self.maximumDesiredInterests = maximumDesiredInterests
        self.descriptor = descriptor; self.transport = transport; self.metrics = metrics
        heads = readHeads; self.recovered = recovered; self.coverageReady = coverageReady; self.coverageLost = coverageLost
    }
    public nonisolated func accepts(_ delivery: V2RealtimeDelivery) -> Bool {
        fences.withLock { state in
            guard let fence = state[.init(delivery.topic)] else { return false }
            return fence.token.partitionID == delivery.partitionID && fence.token.epoch == delivery.partitionEpoch
                && fence.sessionID == delivery.sessionID && fence.generation == delivery.interestGeneration
                && delivery.gatewayIncarnation == descriptor.identity.incarnationID
                && fence.owner == delivery.topic.owner && fence.deadline > .now
        }
    }
    public nonisolated func isReady(_ topic: V2RealtimeTopic) -> Bool {
        fences.withLock { $0[.init(topic)].map { $0.ready && $0.deadline > .now && $0.owner == topic.owner } ?? false }
    }
    /// Pure local coverage check for authenticated scope lifecycle validation.
    /// This does not resolve owners or grant access to the topic's contents.
    public nonisolated func currentReady(kind: V2RealtimeTopicKind, id: String) -> Bool {
        fences.withLock { $0[.init(kind: kind, id: id)].map { $0.ready && $0.deadline > .now } ?? false }
    }
    public nonisolated func confirms(topic: V2RealtimeTopic, confirmation: V2RealtimeCoverageConfirmation) -> Bool {
        fences.withLock { state in
            guard let fence = state[.init(topic)] else { return false }
            return fence.ready && fence.owner == topic.owner && fence.token == confirmation.token
                && fence.sessionID == confirmation.sessionID && fence.generation == confirmation.interestGeneration
                && fence.highWatermark == confirmation.highWatermark && confirmation.deadline > .now
                && fence.deadline > .now
        }
    }
    /// Installed coverage plus the authoritative head whose recovery hint was
    /// scheduled. It does not acknowledge the client's durable cursor.
    public nonisolated func currentConfirmation(kind: V2RealtimeTopicKind, id: String) -> V2RealtimeCoverageConfirmation? {
        fences.withLock { state in
            guard let fence = state[.init(kind: kind, id: id)], fence.ready, fence.deadline > .now else { return nil }
            return .init(token: fence.token, sessionID: fence.sessionID, interestGeneration: fence.generation,
                highWatermark: fence.highWatermark, deadline: fence.deadline)
        }
    }
    public nonisolated func confirmsCurrent(kind: V2RealtimeTopicKind, id: String, confirmation: V2RealtimeCoverageConfirmation) -> Bool {
        fences.withLock { state in
            guard let fence = state[.init(kind: kind, id: id)] else { return false }
            return fence.ready && fence.token == confirmation.token && fence.sessionID == confirmation.sessionID
                && fence.generation == confirmation.interestGeneration && fence.highWatermark == confirmation.highWatermark
                && fence.deadline > .now && confirmation.deadline > .now
        }
    }
    public struct Pressure: Sendable {
        public let desiredInterests: Int
        public let partitions: Int
        public let activationWaiters: Int
        public let recoveryInFlight: Int
        public let recoveryQueued: Int
    }
    public func pressureSnapshot() -> Pressure {
        .init(desiredInterests: entries.count, partitions: partitions.count,
              activationWaiters: waiters.count,
              recoveryInFlight: recoveries, recoveryQueued: recoveryQueued.count)
    }
    public func start() async throws {
        guard !closed else { throw Failure.closed }
        if periodic == nil { periodic = Task { await self.runPeriodic() } }
    }
    public func activate(_ topic: V2RealtimeTopic) async throws { try await activate([topic]) }
    public func activate(_ topics: [V2RealtimeTopic]) async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard waiters.count < 4_096, topics.count <= 128, Set(topics.map { V2RealtimeTopicKey($0) }).count == topics.count,
              topics.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 }),
              entries.count + topics.filter({ entries[.init($0)] == nil }).count <= maximumDesiredInterests else { throw Failure.exhausted }
        if periodic == nil { periodic = Task { await self.runPeriodic() } }
        let replacements = topics.filter { topic in entries[.init(topic)].map { !$0.active || $0.topic.owner != topic.owner } ?? true }
        let firstGeneration = try Self.reserveGenerations(replacements.count)
        var generationOffset: Int64 = 0
        var selected: [V2RealtimeTopicKey: Int64] = [:]
        for topic in topics {
            let key = V2RealtimeTopicKey(topic)
            var entry = entries[key] ?? .init(topic: topic, generation: 0, active: false)
            let changed = !entry.active || entry.topic.owner != topic.owner
            if !entry.active || entry.topic.owner != topic.owner {
                fences.withLock { $0.removeValue(forKey: key) }
                entry.generation = firstGeneration + generationOffset; generationOffset += 1
                if !entry.active { metrics?.interests(delta: 1) }
                entry.active = true; entry.ready = false; entry.topic = topic
            }
            entries[key] = entry; selected[key] = entry.generation
            let partitionID = key.partitionID()
            keysByPartition[partitionID, default: []].insert(key)
            if changed { withdrawJournalCoverage(partitionID) }
            enqueue(partitionID)
            if changed { partitions[partitionID]?.dirty.insert(key) }
        }
        finishWaiters(keys: Set(selected.keys)) // Only affected topic lifecycles can settle.
        if ready(selected) { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = .init(desired: selected, continuation: continuation)
                for key in selected.keys {
                    waitersByTopic[key, default: []].insert(id)
                    waitersByPartition[key.partitionID(), default: []].insert(id)
                }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        try Task.checkCancellation()
    }
    /// Process-local uniqueness persists across removed scopes/coordinators;
    /// overflow fails closed before partially changing any selected scope.
    private static func reserveGenerations(_ count: Int) throws -> Int64 {
        guard count > 0 else { return 0 }
        return try interestGenerations.withLock { value in
            guard Int64(count) <= Int64.max - value else { throw Failure.exhausted }
            let first = value + 1; value += Int64(count); return first
        }
    }
    private func cancelWaiter(_ id: UUID) {
        if let waiter = removeWaiter(id) {
            metrics?.activationSettled(.cancelled)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
    private func removeWaiter(_ id: UUID) -> Waiter? {
        guard let waiter = waiters.removeValue(forKey: id) else { return nil }
        for key in waiter.desired.keys {
            waitersByTopic[key]?.remove(id)
            if waitersByTopic[key]?.isEmpty == true { waitersByTopic.removeValue(forKey: key) }
            let partition = key.partitionID()
            waitersByPartition[partition]?.remove(id)
            if waitersByPartition[partition]?.isEmpty == true { waitersByPartition.removeValue(forKey: partition) }
        }
        return waiter
    }
    private func ready(_ selected: [V2RealtimeTopicKey: Int64]) -> Bool {
        selected.allSatisfy { key, generation in
            guard let entry = entries[key], entry.active, entry.generation == generation, entry.ready else { return false }
            return fences.withLock { $0[key].map { $0.ready && $0.deadline > .now } ?? false }
        }
    }
    private func finishWaiters(partition: Int? = nil, keys: Set<V2RealtimeTopicKey>? = nil, failure: (any Error)? = nil) {
        let candidates: Set<UUID>
        if let keys { candidates = keys.reduce(into: []) { $0.formUnion(waitersByTopic[$1] ?? []) } }
        else if let partition { candidates = waitersByPartition[partition] ?? [] }
        else { candidates = Set(waiters.keys) } // Only shutdown examines every waiter.
        for id in candidates {
            guard let waiter = waiters[id] else { continue }
            let superseded = waiter.desired.contains { key, generation in
                guard let entry = entries[key] else { return true }
                return !entry.active || entry.generation != generation
            }
            if superseded {
                _ = removeWaiter(id); metrics?.activationSettled(.stale)
                waiter.continuation.resume(throwing: Failure.stale)
            } else if ready(waiter.desired) {
                _ = removeWaiter(id); metrics?.activationSettled(.ready)
                waiter.continuation.resume()
            } else if let failure, partition == nil || waiter.desired.keys.contains(where: { $0.partitionID() == partition }) {
                _ = removeWaiter(id)
                let result: V2ActorRealtimeActivationResult
                if let value = failure as? Failure {
                    switch value { case .stale: result = .stale; case .closed: result = .closed; default: result = .failed }
                } else { result = .failed }
                metrics?.activationSettled(result)
                waiter.continuation.resume(throwing: failure)
            }
        }
    }
    public func deactivate(_ topic: V2RealtimeTopic) async { await deactivate(kind: topic.kind, id: topic.id) }
    public func deactivate(kind: V2RealtimeTopicKind, id: String) async {
        let key = V2RealtimeTopicKey(kind: kind, id: id)
        guard !closed, entries[key]?.active == true else { return }
        entries.removeValue(forKey: key)
        let partitionID = key.partitionID()
        withdrawJournalCoverage(partitionID)
        keysByPartition[partitionID]?.remove(key)
        partitions[partitionID]?.pendingRecovery.remove(key)
        partitions[partitionID]?.retryRecovery.remove(key)
        if keysByPartition[partitionID]?.isEmpty == true { keysByPartition.removeValue(forKey: partitionID) }
        metrics?.interests(delta: -1); fences.withLock { $0.removeValue(forKey: key) }
        finishWaiters(keys: [key])
        // installed holds the old generation until the actual remove/upsert
        // control settles; desired indexes retain only current active scopes.
        enqueue(partitionID)
        partitions[partitionID]?.dirty.insert(key)
    }
    private func enqueue(_ id: Int) {
        guard !closed else { return }
        let partition = partitions[id] ?? Partition(session: .init(gateway: descriptor, sessionID: UUID(), sessionGeneration: 1))
        partitions[id] = partition
        if partition.worker == nil { partition.worker = Task {
            try? await Task.sleep(for: .milliseconds(2))
            await self.drive(id, partition: partition)
        } }
    }
    private func request(_ partition: Partition, mutation: V2RealtimeShardMutation) throws -> V2RealtimeShardControlRequest {
        guard let route = partition.descriptor, partition.revision < Int64.max else { throw Failure.stale }
        let base: Int64, next: Int64
        if case .renew = mutation { base = 0; next = 0 } else { base = partition.revision; next = base + 1 }
        return .init(token: route.token, session: partition.session,
            baseRevision: base, nextRevision: next, mutation: mutation,
            payloadFingerprint: try V2RealtimeShardFingerprint.control(token: route.token, session: partition.session,
                baseRevision: base, nextRevision: next, mutation: mutation))
    }
    private func send(_ request: V2RealtimeShardControlRequest, partition: Partition) async throws -> V2RealtimeShardControlReply {
        guard !closed, let route = partition.descriptor else { throw Failure.closed }
        let renewal: Bool
        if case .renew = request.mutation { renewal = true } else { renewal = false }
        if !renewal { partition.pending = request }
        let start = ContinuousClock.now
        // Same mutation/fingerprint on unknown reply. Backpressure is not
        // evidence of a dead endpoint, and retries never refresh this budget.
        let retryUntil = min(partition.descriptorDeadline, start + .seconds(10))
        var attempt = 0
        var response: V2RealtimeShardControlReply?
        while response == nil {
            guard !closed else { throw Failure.closed }
            do {
                let reply = try await transport.control(route, request: request)
                if reply.status == .overloaded { throw V2RealtimePublicationBackpressure.receiverQueue }
                if reply.status == .notInstalled { throw Failure.recovering }
                response = reply
            } catch {
                guard !closed, ContinuousClock.now < retryUntil else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(min(1_000, 100 * attempt)))
            }
        }
        let reply = response!
        guard !closed, partitions[route.token.partitionID] === partition, partition.descriptor?.token == route.token,
              partition.session == request.session else { throw Failure.stale }
        switch reply.status {
        case .applied:
            guard reply.remainingSessionMilliseconds > 0 else { throw Failure.stale }
            let wasAvailable = partition.sessionDeadline > .now
            partition.sessionDeadline = max(partition.sessionDeadline,
                min(partition.descriptorDeadline, start + .milliseconds(reply.remainingSessionMilliseconds)))
            let resumed = fences.withLock { state -> [V2RealtimeTopic: V2RealtimeCoverageConfirmation] in
                state.renew(token: request.token, sessionID: request.session.sessionID, deadline: partition.sessionDeadline)
                // A caller can park while an in-flight renewal crosses the
                // previous local deadline. Publish first, then signal that
                // unavailable -> available edge. Timely renewals remain O(1)
                // and never scan topics or repeat their SQL head barrier.
                guard !wasAvailable, partition.sessionDeadline > .now else { return [:] }
                var ready: [V2RealtimeTopic: V2RealtimeCoverageConfirmation] = [:]
                for key in keysByPartition[request.token.partitionID] ?? [] {
                    guard let entry = entries[key], entry.active, entry.ready,
                          let fence = state[key], fence.ready,
                          fence.token == request.token, fence.sessionID == request.session.sessionID,
                          fence.generation == entry.generation else { continue }
                    ready[entry.topic] = .init(token: fence.token, sessionID: fence.sessionID,
                        interestGeneration: fence.generation, highWatermark: fence.highWatermark,
                        deadline: fence.deadline)
                }
                return ready
            }
            if !renewal { partition.pending = nil }
            if !resumed.isEmpty {
                await coverageReady(resumed)
                guard !closed, partitions[route.token.partitionID] === partition,
                      partition.descriptor?.token == route.token, partition.session == request.session else {
                    throw Failure.stale
                }
            }
            return reply
        case .retiredEpoch, .retiredIncarnation:
            await transport.invalidate(route); throw Failure.stale
        case .notInstalled: throw Failure.recovering
        case .requiresSnapshot: if !renewal { partition.pending = nil }; throw Failure.recovering
        case .overloaded: throw V2RealtimePublicationBackpressure.receiverQueue
        }
    }
    private func desired(_ id: Int) -> [V2RealtimeShardInterest] {
        (keysByPartition[id] ?? []).compactMap { key in
            guard let entry = entries[key], entry.active else { return nil }
            return V2RealtimeShardInterest(key: key, interestGeneration: entry.generation)
        }.sorted { V2RealtimeShardFingerprint.key($0.key) < V2RealtimeShardFingerprint.key($1.key) }
    }
    private func pendingFences(_ id: Int, partition: Partition, keys: Set<V2RealtimeTopicKey>? = nil) {
        withdrawJournalCoverage(id)
        guard let route = partition.descriptor else { return }
        fences.withLock { state in
            for key in keys ?? keysByPartition[id] ?? [] {
                guard let entry = entries[key], entry.active else { continue }
                if let old = state[key], old.token == route.token, old.sessionID == partition.session.sessionID,
                   old.generation == entry.generation, old.owner == entry.topic.owner, old.deadline > .now { continue }
                state[key] = .init(token: route.token, sessionID: partition.session.sessionID,
                    generation: entry.generation, owner: entry.topic.owner, highWatermark: 0,
                    deadline: min(partition.descriptorDeadline, .now + .seconds(30)), ready: false)
            }
        }
    }
    private func queueRecovery(_ id: Int, partition: Partition, keys: Set<V2RealtimeTopicKey>? = nil) {
        guard !closed else { return }
        for key in keys ?? keysByPartition[id] ?? [] {
            guard let entry = entries[key], entry.active, partition.installed[key] == entry.generation else { continue }
            partition.pendingRecovery.insert(key)
        }
        if !partition.pendingRecovery.isEmpty, !recoveryQueued.contains(id) {
            recoveryQueue.append(id); recoveryQueued.insert(id)
        }
        pumpRecovery()
    }
    private func pumpRecovery() {
        guard !closed else { return }
        var inspected = 0
        let bound = recoveryQueue.count
        while recoveries < 4, !recoveryQueue.isEmpty, inspected < bound {
            inspected += 1
            let id = recoveryQueue.removeFirst(); recoveryQueued.remove(id)
            guard let partition = partitions[id] else { continue }
            if partition.recoveryWorker != nil {
                recoveryQueue.append(id); recoveryQueued.insert(id); continue
            }
            guard let route = partition.descriptor, partition.sessionDeadline > .now else { continue }
            var selected: [V2RealtimeTopicKey: Entry] = [:]
            while selected.count < 128, let key = partition.pendingRecovery.popFirst() {
                if let entry = entries[key], entry.active, partition.installed[key] == entry.generation { selected[key] = entry }
            }
            guard !selected.isEmpty else { continue }
            let session = partition.session, deadline = partition.sessionDeadline
            recoveries += 1
            partition.recoveryWorker = Task {
                await self.recover(id, partition: partition, token: route.token, session: session,
                    selected: selected, deadline: deadline)
                await self.recoverySettled(id, partition: partition)
            }
        }
    }
    private func recoverySettled(_ id: Int, partition: Partition) {
        recoveries -= 1
        partition.recoveryWorker = nil
        if !closed, partitions[id] === partition, !partition.pendingRecovery.isEmpty, !recoveryQueued.contains(id) {
            recoveryQueue.append(id); recoveryQueued.insert(id)
        }
        pumpRecovery()
    }
    private func recoveryCurrent(_ id: Int, partition: Partition, token: V2RealtimeShardToken,
        session: V2RealtimeShardSession, deadline: ContinuousClock.Instant) -> Bool {
        !closed && deadline > .now && partitions[id] === partition && partition.descriptor?.token == token
            && partition.session == session && partition.sessionDeadline > .now
    }
    private func recoveryEntryCurrent(_ key: V2RealtimeTopicKey, entry: Entry, partition: Partition) -> Bool {
        entries[key]?.active == true && entries[key]?.generation == entry.generation
            && entries[key]?.topic == entry.topic && partition.installed[key] == entry.generation
    }
    private func retryRecovery(_ id: Int, partition: Partition, token: V2RealtimeShardToken,
        session: V2RealtimeShardSession, selected: [V2RealtimeTopicKey: Entry]) async {
        guard !closed, partitions[id] === partition, partition.descriptor?.token == token,
              partition.session == session else { return }
        var failed: [V2RealtimeTopicKey: Int64] = [:]
        var lost: Set<V2RealtimeTopic> = []
        let cutoff = ContinuousClock.now
        for (key, entry) in selected where recoveryEntryCurrent(key, entry: entry, partition: partition) {
            guard var current = entries[key] else { continue }
            if current.ready { lost.insert(current.topic) }
            current.ready = false; entries[key] = current
            fences.withLock { state in
                guard let prior = state[key], prior.token == token, prior.sessionID == session.sessionID,
                      prior.generation == entry.generation, prior.owner == entry.topic.owner else { return }
                state[key] = .init(token: prior.token, sessionID: prior.sessionID, generation: prior.generation,
                    owner: prior.owner, highWatermark: prior.highWatermark, deadline: prior.deadline, ready: false)
            }
            partition.retryRecovery.insert(key); failed[key] = entry.generation
        }
        // Keep desired interests installed, but don't hold a caller's recovery
        // slot across repeated local head failures. Only its exact failed topics
        // settle; unrelated confirmed topics and sessions remain intact.
        finishWaiters(keys: Set(failed.keys), failure: Failure.recovering)
        if !lost.isEmpty { metrics?.coverageLost(); await coverageLost(lost, cutoff) }
    }
    private func recover(_ id: Int, partition: Partition, token: V2RealtimeShardToken,
        session: V2RealtimeShardSession, selected: [V2RealtimeTopicKey: Entry], deadline: ContinuousClock.Instant) async {
        let topics = selected.values.map(\.topic)
        var successful: Set<V2RealtimeTopicKey> = []
        do {
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            let results = try await heads(topics)
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            guard Set(results.keys) == Set(topics) else { throw Failure.recovering }
            var available: [V2RealtimeTopic: UInt64] = [:]
            for (key, entry) in selected where recoveryEntryCurrent(key, entry: entry, partition: partition) {
                if case .available(let head)? = results[entry.topic] { available[entry.topic] = head }
            }
            // A prior Ready fence must be revoked as soon as this fresh head
            // is unavailable, before another await can expose stale Ready.
            await retryRecovery(id, partition: partition, token: token, session: session,
                selected: selected.filter { recoveryEntryCurrent($0.key, entry: $0.value, partition: partition)
                    && available[$0.value.topic] == nil })
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            let retained = try await recovered(available)
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            guard retained.isSubset(of: Set(available.keys)) else { throw Failure.recovering }
            await retryRecovery(id, partition: partition, token: token, session: session,
                selected: selected.filter { available[$0.value.topic] != nil && !retained.contains($0.value.topic) })
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            var confirmed: [V2RealtimeTopic: V2RealtimeCoverageConfirmation] = [:]
            for (key, entry) in selected where recoveryEntryCurrent(key, entry: entry, partition: partition) {
                guard retained.contains(entry.topic), let highWatermark = available[entry.topic] else {
                    continue
                }
                guard var current = entries[key] else { continue }
                current.ready = true; entries[key] = current
                // The confirmation uses current valid coverage; this attempt's
                // original deadline was independently checked after every await.
                confirmed[entry.topic] = .init(token: token, sessionID: session.sessionID,
                    interestGeneration: entry.generation, highWatermark: highWatermark, deadline: partition.sessionDeadline)
                fences.withLock { $0[key] = .init(token: token, sessionID: session.sessionID,
                    generation: entry.generation, owner: entry.topic.owner, highWatermark: highWatermark,
                    deadline: partition.sessionDeadline, ready: true) }
            }
            await coverageReady(confirmed)
            guard recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) else { throw Failure.recovering }
            successful = Set(confirmed.keys.map(V2RealtimeTopicKey.init))
            partition.lastHeadCheck = .now
        } catch {
            // Retain only exact current failed topics, including when the
            // original attempt deadline elapsed during an actual await.
        }
        await retryRecovery(id, partition: partition, token: token, session: session,
            selected: selected.filter { !successful.contains($0.key) })
        if !recoveryCurrent(id, partition: partition, token: token, session: session, deadline: deadline) {
            // A failure callback may itself have exhausted the original budget.
            await retryRecovery(id, partition: partition, token: token, session: session, selected: selected)
        }
        finishWaiters(keys: Set(selected.keys))
    }

    private func enqueueRenewal(_ id: Int, partition: Partition) {
        guard !closed, partition.renewalWorker == nil, partition.sessionDeadline > .now else { return }
        let session = partition.session
        partition.renewalWorker = Task {
            await self.renewSession(id, partition: partition, session: session)
            await self.renewalSettled(partition)
        }
    }
    private func renewalSettled(_ partition: Partition) { partition.renewalWorker = nil }
    private func renewSession(_ id: Int, partition: Partition, session: V2RealtimeShardSession) async {
        guard !closed, let old = partition.descriptor else { return }
        do {
            let started = ContinuousClock.now
            let route = try await transport.resolve(partitionID: id)
            guard !closed, partitions[id] === partition, partition.session == session,
                  partition.descriptor?.token == old.token else { return }
            guard route.token == old.token else {
                // Subscription worker owns session rotation; the heartbeat cannot
                // install a new token over a still-running old mutation.
                partition.descriptorDeadline = .now; enqueue(id); return
            }
            partition.descriptor = route
            partition.descriptorDeadline = started + .milliseconds(route.remainingLeaseMilliseconds)
            let request = try request(partition, mutation: .renew)
            _ = try await send(request, partition: partition)
            guard !closed, partitions[id] === partition, partition.session == session,
                  partition.descriptor?.token == request.token else { return }
            retainJournalCoverage(id, partition: partition)
        } catch {
            // Keep original deadlines on unknown/temporary failure. The normal
            // expiry/retired-token path will revoke coverage; do not resurrect it.
        }
    }
    private func drive(_ id: Int, partition: Partition) async {
        defer { if partitions[id] === partition { partition.worker = nil } }
        do {
            if partition.descriptor == nil || partition.descriptorDeadline <= .now + .seconds(10) {
                let start = ContinuousClock.now
                let route = try await transport.resolve(partitionID: id)
                try route.validate()
                guard !closed, route.token.partitionID == id else { throw Failure.stale }
                if let old = partition.descriptor, old.token != route.token {
                    await lose(id, partition: partition)
                    try rotate(id, partition: partition, reason: .tokenChange)
                }
                partition.descriptor = route
                partition.descriptorDeadline = start + .milliseconds(route.remainingLeaseMilliseconds)
                guard partition.descriptorDeadline > .now else { throw Failure.stale }
            }
            while !closed {
                if partition.snapshot {
                    let interests = desired(id), digest = try V2RealtimeShardFingerprint.snapshot(interests)
                    let snapshotID = UUID(), total = max(1, (interests.count + 127) / 128)
                    pendingFences(id, partition: partition)
                    for index in 0..<total {
                        let start = min(index * 128, interests.count), end = min(start + 128, interests.count)
                        let next = try request(partition, mutation: .snapshotChunk(snapshotID: snapshotID, index: index,
                            total: total, digest: digest, interests: Array(interests[start..<end])))
                        let reply = try await send(next, partition: partition)
                        if index == total - 1 {
                            guard reply.appliedRevision == next.nextRevision else { throw Failure.recovering }
                            partition.revision = reply.appliedRevision
                        } else { guard reply.appliedRevision == next.baseRevision else { throw Failure.recovering } }
                    }
                    partition.installed = TreeDictionary(uniqueKeysWithValues: interests.map { ($0.key, $0.interestGeneration) })
                    partition.snapshot = false
                    retainJournalCoverage(id, partition: partition)
                    queueRecovery(id, partition: partition)
                }
                var changes: [V2RealtimeShardInterestChange] = []
                // Drain only changed keys. A concurrent change during send inserts a
                // fresh ticket, so it cannot be erased by this batch's completion.
                while changes.count < 128, let key = partition.dirty.popFirst() {
                    if let entry = entries[key], entry.active {
                        if partition.installed[key] != entry.generation {
                            changes.append(.upsert(.init(key: key, interestGeneration: entry.generation)))
                        }
                    } else if let generation = partition.installed[key] {
                        changes.append(.remove(key: key, generation: generation))
                    }
                }
                if !changes.isEmpty {
                    pendingFences(id, partition: partition, keys: Set(changes.compactMap { if case .upsert(let value) = $0 { value.key } else { nil } }))
                    let next = try request(partition, mutation: .delta(changes))
                    let reply = try await send(next, partition: partition)
                    guard reply.appliedRevision == next.nextRevision else { throw Failure.recovering }
                    partition.revision = reply.appliedRevision
                    for change in changes {
                        switch change {
                        case .upsert(let interest): partition.installed[interest.key] = interest.interestGeneration
                        case .remove(let key, _): partition.installed.removeValue(forKey: key)
                        }
                    }
                    retainJournalCoverage(id, partition: partition)
                    let added = Set(changes.compactMap { change -> V2RealtimeTopicKey? in
                        if case .upsert(let interest) = change { return interest.key }; return nil
                    })
                    queueRecovery(id, partition: partition, keys: added); continue
                }
                return
            }
        } catch {
            await lose(id, partition: partition)
            // Unknown replies never cancel actual work or classify remote death.
            // Replacement session generation prevents a delayed old mutation.
            try? rotate(id, partition: partition, reason: .failure)
            if let failure = error as? Failure, case .stale = failure { partition.descriptor = nil }
            finishWaiters(partition: id, failure: error)
        }
    }
    private func rotate(_ id: Int, partition: Partition, reason: V2ActorRealtimeSessionRotationReason) throws {
        withdrawJournalCoverage(id)
        guard partition.session.sessionGeneration < Int64.max else { throw Failure.exhausted }
        let keys = (keysByPartition[id] ?? []).filter { entries[$0]?.active == true }
        let firstGeneration = try Self.reserveGenerations(keys.count)
        for (offset, key) in keys.enumerated() {
            guard var entry = entries[key] else { continue }
            entry.generation = firstGeneration + Int64(offset); entry.ready = false; entries[key] = entry
        }
        partition.session = .init(gateway: descriptor, sessionID: UUID(), sessionGeneration: partition.session.sessionGeneration + 1)
        partition.revision = 0; partition.installed = [:]; partition.snapshot = true; partition.pending = nil
        partition.pendingRecovery.removeAll(); partition.retryRecovery.removeAll(); partition.dirty.removeAll()
        metrics?.sessionRotation(reason)
        // A successor session cannot satisfy a caller waiting on its predecessor.
        finishWaiters(partition: id)
    }
    private func lose(_ id: Int, partition: Partition) async {
        withdrawJournalCoverage(id)
        var lost: Set<V2RealtimeTopic> = []
        for key in keysByPartition[id] ?? [] {
            guard var entry = entries[key], entry.active else { continue }
            if entry.ready { lost.insert(entry.topic) }
            entry.ready = false; entries[key] = entry
        }
        fences.withLock { state in
            state.invalidateSession(partitionID: id)
            for key in keysByPartition[id] ?? [] { state.removeValue(forKey: key) }
        }
        if !lost.isEmpty { metrics?.coverageLost(); await coverageLost(lost, .now) }
    }
    private func runPeriodic() async {
        while !closed, !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await maintainCoverage()
        }
    }
    // A single real maintenance pass. Production retains the original 30s
    // head-check cadence; tests may explicitly demand a fresh barrier without
    // synthesizing time, lease state or successful coverage.
    func maintainCoverage(recheckHeads: Bool = false) async {
        guard !closed else { return }
        for (id, partition) in partitions {
            if partition.worker == nil, partition.sessionDeadline <= .now, partition.revision > 0 {
                let expiredSession = partition.session, expiredToken = partition.descriptor?.token
                await lose(id, partition: partition)
                guard !closed, partitions[id] === partition else { return }
                guard partition.session == expiredSession, partition.descriptor?.token == expiredToken else { continue }
                if partition.sessionDeadline > .now {
                    // An already-started heartbeat may have confirmed live
                    // coverage while loss callbacks settled. Rebuild the local
                    // barriers without rotating that confirmed exact session.
                    queueRecovery(id, partition: partition); enqueue(id); continue
                }
                do { try rotate(id, partition: partition, reason: .expiry) } catch {
                    finishWaiters(partition: id, failure: error); continue
                }
                finishWaiters(partition: id, failure: Failure.stale)
            }
            enqueueRenewal(id, partition: partition)
            if !partition.retryRecovery.isEmpty {
                partition.pendingRecovery.formUnion(partition.retryRecovery); partition.retryRecovery.removeAll()
            }
            let journalCurrent = journalCoverage(partitionID: id).map { coverage in
                trustedJournalRenewal.withLock { $0?.callback }?(coverage) == true
            } ?? false
            if recheckHeads || (!journalCurrent && partition.lastHeadCheck + .seconds(30) <= .now) { queueRecovery(id, partition: partition) }
            else if !partition.pendingRecovery.isEmpty { queueRecovery(id, partition: partition, keys: []) }
            if partition.snapshot || !partition.dirty.isEmpty || partition.descriptorDeadline <= .now + .seconds(10) { enqueue(id) }
        }
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; periodic?.cancel(); fences.withLock { $0.removeAll() }
        let journalPartitions = journalCoverages.withLock { value in
            let ids = Array(value.keys); value.removeAll(); return ids
        }
        for id in journalPartitions { journalObserver.withLock { $0?.callback }?(.invalidated(partitionID: id)) }
        recoveryQueue.removeAll(); recoveryQueued.removeAll()
        finishWaiters(failure: Failure.closed)
        let task = Task { await self.drain() }; shutdownTask = task; await task.value
    }
    private func drain() async {
        await periodic?.value
        for partition in partitions.values {
            await partition.worker?.value
            await partition.renewalWorker?.value
            await partition.recoveryWorker?.value
        }
        for partition in partitions.values {
            guard let route = partition.descriptor, partition.revision < Int64.max else { continue }
            // Resolve a late actual control reply before closing its revision.
            // A partial snapshot may still be closed at its unadvanced base.
            if let pending = partition.pending,
               let settled = try? await transport.control(route, request: pending), settled.status == .applied {
                partition.revision = max(partition.revision, settled.appliedRevision)
            }
            if let close = try? request(partition, mutation: .close) { _ = try? await transport.control(route, request: close) }
        }
        metrics?.interests(delta: -entries.count)
        partitions.removeAll(); entries.removeAll(); keysByPartition.removeAll()
    }
}
