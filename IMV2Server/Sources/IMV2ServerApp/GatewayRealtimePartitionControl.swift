import Foundation
import IMV2ActorContracts
import IMV2ServerContracts

/// One owned worker controls all local partitions. Membership chooses a
/// candidate; only confirmed PostgreSQL leases authorize that candidate.
actor GatewayRealtimePartitionControl {
    struct Installed: Sendable {
        let lease: V2RealtimePartitionLease
        let deadline: ContinuousClock.Instant
        let databaseDeadline: ContinuousClock.Instant
        let qualificationGeneration: UUID
        var token: V2RealtimeShardToken {
            .init(partitionID: lease.partitionID, host: lease.identity,
                  epoch: lease.epoch, leaseToken: lease.token)
        }
    }
    private let identity: V2GatewayRealtimeIdentity
    private let roster: Set<String>
    private let qualification: V2ActorServiceQualification
    private struct LeaseKey: Hashable { let partition: Int; let epoch: Int64; let token: UUID }
    private var owned: [LeaseKey: V2RealtimePartitionLease] = [:]
    private var watchdog: Task<Void, Never>?
    private let store: any V2RealtimePartitionLeaseStore
    private let availableHosts: @Sendable () async -> Set<String>
    private let rotatePartitions: @Sendable () async -> Set<Int>
    private let install: @Sendable ([Installed]) async throws -> Void
    private var installed: [Int: Installed] = [:]
    private var pendingClaim: (ids: [Int], token: UUID)?
    private var worker: Task<Void, Never>?
    private var startup: Task<Void, any Error>?
    private var shutdownTask: Task<Void, any Error>?
    private var closed = false
    private(set) var failedTicks: UInt64 = 0
    private let leaseDuration: TimeInterval = 30
    private let safetyMargin: Duration = .milliseconds(500)

    init(identity: V2GatewayRealtimeIdentity, roster: Set<String>,
         store: any V2RealtimePartitionLeaseStore, qualification: V2ActorServiceQualification,
         availableHosts: @escaping @Sendable () async -> Set<String>,
         rotatePartitions: @escaping @Sendable () async -> Set<Int> = { [] },
         install: @escaping @Sendable ([Installed]) async throws -> Void) throws {
        guard qualification.matches(localNodeID: identity.nodeID, roster: roster),
              roster.contains(identity.nodeID), roster.count <= 64,
              roster.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw V2ActorContractError.invalidConfiguration("realtime partition roster")
        }
        self.identity = identity; self.roster = roster; self.store = store; self.qualification = qualification
        self.availableHosts = availableHosts; self.rotatePartitions = rotatePartitions; self.install = install
    }

    func pressureSnapshot() -> (installed: Int, failedTicks: UInt64) {
        guard !closed, let proof = qualification.snapshot() else { return (0, failedTicks) }
        return (installed.values.filter { $0.qualificationGeneration == proof.generation && $0.deadline > .now }.count, failedTicks)
    }

    func start() async throws {
        guard !closed else { throw V2ActorContractError.invalidConfiguration("closed realtime partition controller") }
        if let startup { try await startup.value; return }
        guard worker == nil else { return }
        if watchdog == nil { watchdog = Task { await self.watchQualification() } }
        let task = Task { try await self.tick() }
        startup = task
        do { try await task.value }
        catch { startup = nil; throw error }
        startup = nil
        guard !closed else { return }
        worker = Task { await self.run() }
    }

    private func run() async {
        while !closed, !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
            guard !closed else { break }
            do { try await tick() }
            catch {
                failedTicks &+= 1
                // Never extend a deadline on a failed or unknown renewal.
                // Remove expired service even if storage remains unavailable.
                await qualificationDidChange()
                try? await releaseRetired()
            }
        }
    }

    private enum Failure: Error { case qualificationLost }
    private func current(_ proof: V2ActorServiceQualification.Snapshot) -> Bool {
        !closed && qualification.snapshot()?.generation == proof.generation
    }
    /// Observer calls this after qualification updates; it owns no SQL. A
    /// single independent watchdog also checks the exact qualification expiry.
    func qualificationDidChange() async {
        guard !closed else { return }
        let proof = qualification.snapshot()
        var next: [Int: Installed] = [:]
        if let proof {
            for (id, value) in installed where value.qualificationGeneration == proof.generation {
                let deadline = min(value.databaseDeadline, proof.validUntil)
                if deadline > .now {
                    next[id] = .init(lease: value.lease, deadline: deadline,
                        databaseDeadline: value.databaseDeadline, qualificationGeneration: proof.generation)
                }
            }
        }
        let changed = next.count != installed.count || next.contains { installed[$0.key]?.deadline != $0.value.deadline }
        installed = next
        if changed { try? await publishCurrent() }
    }
    private func watchQualification() async {
        while !closed && !Task.isCancelled {
            let wake = min(qualification.snapshot()?.validUntil ?? (.now + .seconds(1)), .now + .seconds(1))
            do { try await ContinuousClock().sleep(until: wake) } catch { return }
            await qualificationDidChange()
        }
    }
    private func publishCurrent() async throws {
        let proof = qualification.snapshot()
        let generation = proof?.generation
        let values = installed.values.filter {
            !closed && $0.qualificationGeneration == generation && $0.deadline > .now
        }.sorted { $0.lease.partitionID < $1.lease.partitionID }
        try await install(values)
        // A late installation callback cannot reinstate a retired generation.
        // Production serving also synchronously checks shared qualification.
        if closed || qualification.snapshot()?.generation != generation
            || values.contains(where: { $0.deadline > (qualification.snapshot()?.validUntil ?? .now) }) {
            // Reconcile against the current generation, rather than deleting
            // a successor that an observer may have retained across the await.
            if closed { installed.removeAll(); try await install([]) }
            else { await qualificationDidChange(); try await publishCurrent() }
        }
    }
    private func require(_ proof: V2ActorServiceQualification.Snapshot) async throws {
        guard current(proof) else {
            await qualificationDidChange()
            throw Failure.qualificationLost
        }
    }
    private func retain(_ leases: [V2RealtimePartitionLease]) {
        for lease in leases where lease.identity == identity {
            owned[.init(partition: lease.partitionID, epoch: lease.epoch, token: lease.token)] = lease
        }
    }
    private func releaseRetired() async throws {
        let live = Set(installed.values.map { LeaseKey(partition: $0.lease.partitionID,
            epoch: $0.lease.epoch, token: $0.lease.token) })
        let retiring = owned.filter { !live.contains($0.key) }
        guard !retiring.isEmpty else { return }
        try await store.release(retiring.values.sorted { $0.partitionID < $1.partitionID })
        // Exact tokens only; a late release cannot remove a successor.
        for key in retiring.keys { owned.removeValue(forKey: key) }
    }
    private func tick() async throws {
        guard !closed else { return }
        await qualificationDidChange()
        // Cleanup is allowed without service permission; claim/renew are not.
        try await releaseRetired()
        guard let proof = qualification.snapshot(), !closed else { return }
        let reachable = await availableHosts().intersection(roster).union([identity.nodeID])
        try await require(proof)
        let candidates = reachable.sorted()
        let desired = Set((0..<256).filter { partition in
            candidates.max { left, right in
                let lhs = Self.score(partition: partition, host: left)
                let rhs = Self.score(partition: partition, host: right)
                return lhs == rhs ? left < right : lhs < rhs
            } == identity.nodeID
        })
        let rotating = await rotatePartitions()
        try await require(proof)
        installed = installed.filter { desired.contains($0.key) && !rotating.contains($0.key)
            && $0.value.deadline > .now && $0.value.qualificationGeneration == proof.generation }
        // Retire local service/advertisements before strict token cleanup.
        try await publishCurrent()
        try await require(proof)
        try await releaseRetired()
        try await require(proof)
        if !installed.isEmpty {
            let began = ContinuousClock.now
            let leases = try await store.renew(installed.values.map(\.lease), leaseDuration: leaseDuration)
            retain(leases)
            guard current(proof) else {
                installed.removeAll(); try await install([]); try await releaseRetired()
                throw Failure.qualificationLost
            }
            installed = conservative(leases, began: began, proof: proof)
            try await publishCurrent()
            try await require(proof)
            try await releaseRetired()
        }
        try await require(proof)
        let missing = desired.subtracting(installed.keys).sorted()
        if pendingClaim == nil, !missing.isEmpty { pendingClaim = (missing, UUID()) }
        if let pending = pendingClaim {
            let began = ContinuousClock.now
            let leases = try await store.claim(partitionIDs: pending.ids, identity: identity,
                token: pending.token, leaseDuration: leaseDuration)
            // Unknown replies retain the original pending token. Without an
            // epoch it cannot be safely released/reclaimed while unqualified.
            retain(leases); pendingClaim = nil
            guard current(proof) else {
                installed.removeAll(); try await install([]); try await releaseRetired()
                throw Failure.qualificationLost
            }
            let accepted = conservative(leases, began: began, proof: proof)
            for (id, value) in accepted where desired.contains(id) { installed[id] = value }
            try await releaseRetired()
        }
        try await require(proof)
        try await publishCurrent()
    }
    private func conservative(_ leases: [V2RealtimePartitionLease], began: ContinuousClock.Instant,
        proof: V2ActorServiceQualification.Snapshot) -> [Int: Installed] {
        let now = ContinuousClock.now
        var result: [Int: Installed] = [:]
        guard current(proof), let latest = qualification.snapshot() else { return result }
        for lease in leases {
            let databaseDeadline = began + .seconds(lease.remainingLeaseSeconds) - safetyMargin
            let deadline = min(databaseDeadline, latest.validUntil)
            guard lease.identity == identity, deadline > now else { continue }
            result[lease.partitionID] = .init(lease: lease, deadline: deadline,
                databaseDeadline: databaseDeadline, qualificationGeneration: proof.generation)
        }
        return result
    }

    func shutdown() async throws {
        if let shutdownTask { try await shutdownTask.value; return }
        closed = true
        let task = Task { try await self.drain() }
        shutdownTask = task
        try await task.value
    }

    private func drain() async throws {
        startup?.cancel()
        _ = try? await startup?.value
        startup = nil
        worker?.cancel()
        await worker?.value
        worker = nil
        watchdog?.cancel()
        await watchdog?.value
        watchdog = nil
        installed.removeAll()
        try await install([])
        try await releaseRetired()
        // An unknown claim without its epoch remains fenced by natural TTL;
        // shutdown never calls claim to manufacture ownership for cleanup.
    }

    private static func score(partition: Int, host: String) -> UInt64 {
        // Explicit FNV-1a input; stable across restarts and Swift versions.
        var hash: UInt64 = 14_695_981_039_346_656_037
        let bytes = [UInt8(1), UInt8(partition >> 8), UInt8(partition & 255)] + Array(host.utf8)
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }
}
