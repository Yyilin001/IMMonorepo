import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway

/// Both remote repairs and local cold refreshes share this bounded owner.
/// A late stronger request waits for another pass, never an older result.
actor GatewayJournalRecoveryCoordinator {
    struct Work: Sendable {
        let batch: V2RealtimeJournalProjectionBatch
        let service: String
        var minimumCut: Int64
        var interestRevision: UInt64
        var controls: V2GatewayJournalRecoveryControls
        var baseline: Proof? = nil // Only the owner supplies a previously installed witness.
        var key: Key { .init(source: batch.source, service: service, fence: batch.fence) }
        mutating func merge(_ other: Work) {
            minimumCut = max(minimumCut, other.minimumCut)
            interestRevision = max(interestRevision, other.interestRevision)
            for (user, version) in other.controls.versions { controls.versions[user] = max(controls.versions[user] ?? 0, version) }
            controls.devices.formUnion(other.controls.devices)
            for (user, rooms) in other.controls.membershipRooms { controls.membershipRooms[user, default: []].formUnion(rooms) }
            for (user, version) in other.controls.membershipVersions { controls.membershipVersions[user] = max(controls.membershipVersions[user] ?? 0, version) }
        }
        var isBounded: Bool {
            controls.versions.count <= 4096 && controls.devices.count <= 4096
                && controls.membershipRooms.values.reduce(0, { $0 + $1.count }) <= 4096
                && controls.membershipVersions.count <= 4096
        }
        var hasControlChanges: Bool {
            !controls.versions.isEmpty || !controls.devices.isEmpty
                || !controls.membershipRooms.isEmpty || !controls.membershipVersions.isEmpty
        }
    }
    struct Key: Hashable, Sendable {
        let source: V2RealtimeJournalSource
        let service: String
        let publisher: UUID
        let sourceEpoch: Int64
        let sourceToken: UUID
        let routingEpoch: Int64
        let routingToken: UUID
        let session: UUID
        let revision: Int64
        let gateway: UUID
        init(source: V2RealtimeJournalSource, service: String, fence: V2RealtimeJournalProjectionFence) {
            self.source = source; self.service = service; publisher = fence.publisherIncarnationID
            sourceEpoch = fence.sourceLeaseEpoch; sourceToken = fence.sourceLeaseToken
            routingEpoch = fence.routingPartitionEpoch; routingToken = fence.routingLeaseToken
            session = fence.sessionID; revision = fence.interestGeneration; gateway = fence.gatewayIncarnationID
        }
    }
    struct Proof: Sendable {
        let cut: Int64
        let interestRevision: UInt64
        let versions: [UserID: UInt64]
        var devices: Set<V2RealtimeJournalDeviceKey> = []
        /// All side effects represented by these requirements already settled.
        let controls: V2GatewayJournalRecoveryControls
        func satisfies(_ work: Work) -> Bool {
            cut >= work.minimumCut && interestRevision >= work.interestRevision
                && work.controls.versions.allSatisfy { versions[$0.key, default: 0] >= $0.value }
                && work.controls.devices.isSubset(of: devices)
                && work.controls.membershipVersions.allSatisfy { controls.membershipVersions[$0.key, default: 0] >= $0.value }
                && work.controls.membershipRooms.allSatisfy { $0.value.isSubset(of: controls.membershipRooms[$0.key] ?? []) }
        }
    }
    enum Reason: String, CaseIterable, Sendable {
        case requested, cacheHit, joined, executed, followup, failed, cancelled
        case firstBaseline, generationChanged, interestsChanged, requirementsAdvanced, bindingUnavailable
        case replayAdvanced, replayFallback, snapshotLoaded
    }
    private static let metrics = Mutex<[Reason: UInt64]>([:])
    nonisolated static func record(_ reason: Reason) { metrics.withLock { $0[reason, default: 0] += 1 } }
    nonisolated static func prometheus() -> String {
        let values = metrics.withLock { $0 }
        var lines = ["# HELP im_v2_gateway_journal_recovery_total Shared local/remote control recovery by fixed reason. Reasons overlap; execution counts are actual passes.",
                     "# TYPE im_v2_gateway_journal_recovery_total counter"]
        for reason in Reason.allCases { lines.append("im_v2_gateway_journal_recovery_total{reason=\"\(reason.rawValue)\"} \(values[reason, default: 0])") }
        return lines.joined(separator: "\n") + "\n"
    }
    private struct Waiter {
        let ticket: UInt64
        let work: Work
        let continuation: CheckedContinuation<Proof, any Error>
    }
    private struct Pending {
        var work: Work
        var waiters: [Waiter]
    }
    private let maximumSources: Int
    private let execute: @Sendable (Work) async throws -> Proof
    private let isCurrent: @Sendable (Work, Proof) -> Bool
    private var pending: [Key: Pending] = [:]
    private var queue: [Key] = []
    private var queueOffset = 0
    private var actual: [Key: Task<Void, Never>] = [:]
    private var completed: [V2RealtimeJournalSource: (Key, Proof)] = [:]
    private var waiting = 0
    private var closed = false
    private var nextWaiter: UInt64 = 0
    struct Snapshot: Sendable {
        let waiting: Int
        let actual: Int
        let queued: Int
        let cached: Int
        let closed: Bool
    }
    func snapshot() -> Snapshot {
        .init(waiting: waiting, actual: actual.count, queued: queue.count - queueOffset,
              cached: completed.count, closed: closed)
    }

    init(maximumSources: Int = 256,
         isCurrent: @escaping @Sendable (Work, Proof) -> Bool,
         execute: @escaping @Sendable (Work) async throws -> Proof) {
        self.maximumSources = maximumSources; self.isCurrent = isCurrent; self.execute = execute
    }
    func run(_ work: Work) async throws -> Proof {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        Self.record(.requested)
        if let (key, proof) = completed[work.batch.source] {
            if key == work.key, proof.interestRevision == work.interestRevision,
               proof.satisfies(work), isCurrent(work, proof) {
                Self.record(.cacheHit); return proof
            }
            if key != work.key { Self.record(.generationChanged) }
            else if proof.interestRevision != work.interestRevision { Self.record(.interestsChanged) }
            else if !proof.satisfies(work) { Self.record(.requirementsAdvanced) }
            else { Self.record(.bindingUnavailable) }
        } else { Self.record(.firstBaseline) }
        guard waiting < 1024, pending[work.key] != nil || pending.count < maximumSources else {
            throw V2RealtimePublicationBackpressure.receiverQueue
        }
        var merged = pending[work.key].flatMap { $0.waiters.isEmpty ? nil : $0.work } ?? work
        merged.merge(work)
        guard merged.isBounded else { throw V2RealtimePublicationBackpressure.receiverQueue }
        nextWaiter &+= 1
        precondition(nextWaiter != 0)
        let ticket = nextWaiter
        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiting += 1
            if var value = pending[work.key] {
                Self.record(.joined)
                value.work = merged; value.waiters.append(.init(ticket: ticket, work: work, continuation: continuation))
                pending[work.key] = value
            } else {
                pending[work.key] = .init(work: merged, waiters: [.init(ticket: ticket, work: work, continuation: continuation)])
                queue.append(work.key)
            }
            admit()
        }
        } onCancel: {
            Task { await self.cancel(work.key, ticket: ticket) }
        }
    }
    private func cancel(_ key: Key, ticket: UInt64) {
        guard var value = pending[key], let index = value.waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        let waiter = value.waiters.remove(at: index)
        waiting -= 1; Self.record(.cancelled)
        waiter.continuation.resume(throwing: CancellationError())
        if let first = value.waiters.first {
            value.work = first.work
            for waiter in value.waiters.dropFirst() { value.work.merge(waiter.work) }
        }
        if value.waiters.isEmpty, actual[key] == nil { pending.removeValue(forKey: key) }
        else { pending[key] = value }
        if value.waiters.isEmpty, actual[key] != nil { actual[key]?.cancel() }
    }
    private func admit() {
        while !closed, actual.count < 4, queueOffset < queue.count {
            let key = queue[queueOffset]; queueOffset += 1
            if queueOffset >= 64 { queue.removeFirst(queueOffset); queueOffset = 0 }
            guard actual[key] == nil, let value = pending[key] else { continue }
            if value.waiters.isEmpty { pending.removeValue(forKey: key); continue }
            var work = value.work
            if let (installedKey, proof) = completed[key.source], installedKey == key,
               proof.interestRevision == work.interestRevision, !work.hasControlChanges {
                work.baseline = proof
            }
            Self.record(.executed)
            actual[key] = Task {
                let result: Result<Proof, any Error>
                do {
                    try Task.checkCancellation()
                    let proof = try await execute(work)
                    try Task.checkCancellation()
                    result = .success(proof)
                }
                catch { result = .failure(error) }
                finished(key, result: result)
            }
        }
    }
    private func finished(_ key: Key, result: Result<Proof, any Error>) {
        actual.removeValue(forKey: key)
        guard var value = pending.removeValue(forKey: key) else { return }
        if case .success(let proof) = result, !closed {
            if completed[key.source] != nil || completed.count < maximumSources { completed[key.source] = (key, proof) }
            var remaining: [Waiter] = []
            for waiter in value.waiters {
                if proof.satisfies(waiter.work) {
                    waiting -= 1; waiter.continuation.resume(returning: proof)
                } else { remaining.append(waiter) }
            }
            if !remaining.isEmpty {
                Self.record(.followup)
                value.waiters = remaining; value.work = remaining[0].work
                for waiter in remaining.dropFirst() { value.work.merge(waiter.work) }
                pending[key] = value; queue.append(key)
            }
        } else {
            Self.record(.failed)
            waiting -= value.waiters.count
            for waiter in value.waiters {
                if closed { waiter.continuation.resume(throwing: CancellationError()) }
                else { waiter.continuation.resume(with: result) }
            }
        }
        admit()
    }
    func close() async {
        closed = true; completed.removeAll()
        for key in queue.dropFirst(queueOffset) {
            if let value = pending.removeValue(forKey: key) {
                waiting -= value.waiters.count
                for waiter in value.waiters { waiter.continuation.resume(throwing: CancellationError()) }
            }
        }
        queue.removeAll(); queueOffset = 0
        let running = Array(actual.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }
}
