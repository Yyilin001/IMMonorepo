import Foundation
import Crypto
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import Synchronization

/// Startup/stop registration is one control commit per logical data shard,
/// independent of active room count. Discovery never replaces an active host.
package final class V2RoomActorPlacementRuntime: V2RoomActorPlacementRouting, Sendable {
    private let logs: [String: any V2ActorPlacementLog]
    private let directories: Mutex<[String: V2ActorPlacementDirectory]>
    private struct RegistrationAttempt: Sendable {
        let previous: V2ActorHostIdentity
        let requestID: UUID
        let originRevision: UInt64
    }
    private struct RegistrationState: Sendable {
        var host: V2ActorHostIdentity?
        var attempts: [String: RegistrationAttempt] = [:]
    }
    // One application owns this runtime. Retain each exact command across lost
    // commit responses; deriving it again from the successor snapshot would
    // turn a safe replay into a second ownership change.
    private let registrations = Mutex(RegistrationState())
    package init(logs: [String: any V2ActorPlacementLog], snapshots: [String: V2ActorPlacementSnapshot]) throws {
        guard !logs.isEmpty, Set(logs.keys) == Set(snapshots.keys) else { throw V2ActorPlacementError.invalidConfiguration }
        self.logs = logs; directories = Mutex(snapshots.mapValues { V2ActorPlacementDirectory(snapshot: $0) })
    }

    package func register(_ host: V2ActorHostIdentity, shards: Set<String>) async throws {
        guard !shards.isEmpty, shards.isSubset(of: Set(logs.keys)) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        try registrations.withLock { state in
            guard state.host == nil || state.host == host else { throw V2ActorPlacementError.invalidConfiguration }
            state.host = host
        }
        for shard in shards.sorted() {
            let log = logs[shard]!
            var current = try await log.load()
            var attempt = try registrations.withLock { state in
                if let existing = state.attempts[shard] { return existing }
                guard let previous = current.registration(for: host.hostID)?.host else {
                    throw V2ActorPlacementError.invalidConfiguration
                }
                let attempt = RegistrationAttempt(previous: previous, requestID: UUID(), originRevision: current.revision)
                state.attempts[shard] = attempt
                return attempt
            }
            while true {
                try Task.checkCancellation()
                let next: V2ActorPlacementSnapshot
                do {
                    next = try await log.append(.registerHost(previous: attempt.previous, successor: host),
                        expected: current, requestID: attempt.requestID, originRevision: attempt.originRevision)
                } catch V2ActorPlacementError.staleRevision { current = try await log.load(); continue }
                catch V2ActorPlacementError.requestExpired {
                    current = try await log.load()
                    // An accepted current registration is pinned and cannot
                    // expire. Renewal is safe only while the exact predecessor
                    // remains retired; an old expired proposal cannot commit.
                    guard current.registration(for: host.hostID) == .init(host: attempt.previous, retired: true) else {
                        throw V2ActorPlacementError.staleOwner
                    }
                    attempt = .init(previous: attempt.previous, requestID: UUID(), originRevision: current.revision)
                    registrations.withLock { $0.attempts[shard] = attempt }
                    continue
                }
                try install(next, shard: shard)
                break
            }
        }
    }

    /// The caller MUST await Host/transport physical drain before this call.
    /// No timer, cancelled task, probe timeout or membership event calls retire.
    package func retireAfterDrain(_ proof: V2RoomHostDrainProof, shards: Set<String>) async throws {
        let host = proof.host
        let requestID = UUID()
        for shard in shards.sorted() {
            guard let log = logs[shard] else { throw V2ActorPlacementError.invalidConfiguration }
            var current = try await log.load()
            var originRevision = current.revision
            while true {
                // Retrying a partial application stop cannot retire a successor
                // and needn't append a second retirement for this incarnation.
                guard let registered = current.registration(for: host.hostID), registered.host == host else {
                    // Failed startup has no authority to retire the predecessor.
                    try install(current, shard: shard)
                    break
                }
                if registered.retired {
                    try install(current, shard: shard)
                    break
                }
                // A failed startup can drain an empty Host with the same
                // configured identity as another running process. A native
                // drain proof alone must not retire that other registration.
                // Recover our exact durable startup request, also covering a
                // lost registration response, before changing ownership.
                guard let attempt = registrations.withLock({ $0.attempts[shard] }),
                      attempt.previous != host else { break }
                let registration = try await log.append(.registerHost(previous: attempt.previous, successor: host),
                    expected: current, requestID: attempt.requestID, originRevision: attempt.originRevision)
                guard registration.registration(for: host.hostID) == .init(host: host, retired: false) else {
                    throw V2ActorPlacementError.staleOwner
                }
                do {
                    let next = try await log.append(.retireHost(host), evidence: .host(proof, previous: attempt.previous, registrationRequestID: attempt.requestID), expected: current, requestID: requestID, originRevision: originRevision)
                    try install(next, shard: shard)
                    break
                } catch V2ActorPlacementError.staleRevision { current = try await log.load() }
                catch V2ActorPlacementError.requestExpired {
                    current = try await log.load(); originRevision = current.revision
                }
                catch V2ActorPlacementError.invalidTransition {
                    let latest = try await log.load()
                    guard latest.registration(for: host.hostID) == .init(host: host, retired: true) else {
                        throw V2ActorPlacementError.invalidTransition
                    }
                    current = latest
                }
            }
        }
    }

    /// Called only by the configured exclusion authority after the deployment
    /// backend and every covered database have completed physical settlement.
    /// Partial multi-shard commits retry with the SAME native proof identity.
    package func retireAfterExclusion(_ proof: V2RoomHostExclusionProof,
                                     deadline: ContinuousClock.Instant) async throws {
        guard !proof.settledShardIDs.isEmpty, proof.settledShardIDs.isSubset(of: Set(logs.keys)) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        for shard in proof.settledShardIDs.sorted() {
            let log = logs[shard]!
            var current = try await log.load()
            var originRevision = current.revision
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
                guard let registered = current.registration(for: proof.host.hostID), registered.host == proof.host else {
                    // Registration replaces an incarnation only after durable
                    // retirement and removal of every old ownership/transfer
                    // reference. Retry must not retire the newer process.
                    if let replacement = current.registration(for: proof.host.hostID), replacement.host != proof.host,
                       current.slots.allSatisfy({ $0.owner.host != proof.host && $0.transfer?.successor != proof.host }) {
                        try install(current, shard: shard)
                        break
                    }
                    throw V2ActorPlacementError.staleOwner
                }
                if registered.retired {
                    // A retired successor cannot accept a pending transfer.
                    // Remove its incoming references even when every Host is
                    // retired, so a newly provisioned incarnation can register.
                    if let partition = current.slots.firstIndex(where: { $0.transfer?.successor == proof.host }),
                       let pending = current.slots[partition].transfer {
                        do {
                            current = try await log.append(.cancelTransfer(partition: partition,
                                expected: current.slots[partition].owner, transferID: pending.id),
                                expected: current, requestID: pending.id)
                            try install(current, shard: shard)
                        } catch V2ActorPlacementError.staleRevision { current = try await log.load() }
                        continue
                    }
                    try install(current, shard: shard)
                    break
                }
                do {
                    let committed = try await log.append(.retireHost(proof.host), evidence: .excludedHost(proof),
                        expected: current, requestID: proof.operationID, originRevision: originRevision)
                    current = committed
                    try install(current, shard: shard)
                } catch V2ActorPlacementError.staleRevision {
                    current = try await log.load()
                } catch V2ActorPlacementError.requestExpired {
                    current = try await log.load(); originRevision = current.revision
                } catch V2ActorPlacementError.invalidTransition {
                    let latest = try await log.load()
                    guard latest.registration(for: proof.host.hostID) == .init(host: proof.host, retired: true) else {
                        throw V2ActorPlacementError.invalidTransition
                    }
                    current = latest
                }
            }
        }
    }

    /// Recovery reuses committed full-Host retirement. It never asks the dead
    /// process for a drain RPC, nor transfers a live, unretired incarnation.
    package func takeOverRetiredHost(_ host: V2ActorHostIdentity, shards: Set<String>,
                                    operationID: UUID, eligibleHosts: [V2ActorHostID: Set<String>],
                                    deadline: ContinuousClock.Instant) async throws {
        guard !shards.isEmpty, shards.isSubset(of: Set(logs.keys)) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        for shard in shards.sorted() {
            let log = logs[shard]!
            var current = try await log.load()
            while let partition = current.slots.firstIndex(where: { $0.owner.host == host }) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
                let slot = current.slots[partition]
                guard slot.retired, current.registration(for: host.hostID) == .init(host: host, retired: true) else {
                    throw V2ActorPlacementError.staleOwner
                }
                let candidates = current.hosts.filter {
                    !$0.retired && $0.host.hostID != host.hostID &&
                        eligibleHosts[$0.host.hostID]?.contains(shard) == true
                }.map(\.host)
                guard !candidates.isEmpty else { throw V2ActorPlacementError.unavailable }
                if let pending = slot.transfer, !candidates.contains(pending.successor) {
                    // A dead successor is not silently replaced in a pending
                    // operation. Cancel it durably before choosing a new one.
                    do {
                        current = try await log.append(.cancelTransfer(partition: partition,
                            expected: slot.owner, transferID: pending.id), expected: current, requestID: pending.id)
                        try install(current, shard: shard)
                    } catch V2ActorPlacementError.staleRevision { current = try await log.load() }
                    continue
                }
                let successor: V2ActorHostIdentity
                if let pending = slot.transfer { successor = pending.successor }
                else {
                    let counts = Dictionary(grouping: current.slots, by: { $0.owner.host }).mapValues(\.count)
                    successor = candidates.min {
                        let left = counts[$0, default: 0], right = counts[$1, default: 0]
                        return left == right ? $0.hostID.rawValue < $1.hostID.rawValue : left < right
                    }!
                }
                let transferID = slot.transfer?.id ?? Self.exclusionTransferID(operationID: operationID,
                    shard: shard, partition: partition, owner: slot.owner, successor: successor)
                let coordinator = V2ActorPlacementCoordinator(log: log, directory: try directory(shard),
                    authorizeSuccessor: { identity in
                        guard ContinuousClock.now < deadline,
                              eligibleHosts[identity.hostID]?.contains(shard) == true,
                              try await log.load().registration(for: identity.hostID) == .init(host: identity, retired: false) else {
                            throw V2ActorPlacementError.staleOwner
                        }
                    }, drain: { _, _ in throw V2ActorAuthenticationError.forbidden })
                do {
                    current = try await coordinator.transfer(partition: partition, expected: slot.owner,
                        successor: successor, transferID: transferID)
                } catch V2ActorPlacementError.staleRevision {
                    current = try await log.load()
                } catch V2ActorPlacementError.staleOwner {
                    current = try await log.load()
                } catch V2ActorPlacementError.invalidTransition {
                    current = try await log.load()
                }
            }
            try install(current, shard: shard)
        }
    }

    private static func exclusionTransferID(operationID: UUID, shard: String, partition: Int,
                                           owner: V2ActorPlacementOwner, successor: V2ActorHostIdentity) -> UUID {
        let value = "IMV2.exclusion-transfer.v1\u{0}\(operationID)\u{0}\(shard)\u{0}\(partition)\u{0}\(owner.epoch)\u{0}\(successor.hostID)\u{0}\(successor.incarnationID)"
        let bytes = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    /// Production handoff uses the real Host, not a second room Registry.
    /// Authenticated transport must bind this callback to slot.owner.host.
    package func drainPlacement<Request: Sendable, Response: Sendable>(
        _ committed: V2ActorPlacementSnapshot, shard: String, partition: Int,
        host: V2RoomActivationHost<Request, Response>, deadline: ContinuousClock.Instant
    ) async throws -> V2ActorPlacementDrainReceipt {
        let directory = try directory(shard)
        guard committed.clusterID == directory.snapshot().clusterID,
              committed.slots.indices.contains(partition),
              let transfer = committed.slots[partition].transfer else {
            throw V2ActorPlacementError.invalidTransition
        }
        // RPC input is a request, never evidence of a committed withdrawal.
        // Verify against the authoritative log before installing anything or
        // touching physical admission. Unrelated partitions may have advanced
        // since the request was sent; the requested slot must still be exact.
        guard let log = logs[shard] else { throw V2ActorPlacementError.invalidConfiguration }
        let verified = try await log.load()
        guard verified.clusterID == committed.clusterID,
              verified.slots.count == committed.slots.count,
              verified.revision >= committed.revision,
              verified.slots[partition] == committed.slots[partition] else {
            throw V2ActorPlacementError.staleOwner
        }
        try install(verified, shard: shard)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        let expected = committed.slots[partition]
        let withdrawal = V2RoomPlacementWithdrawal(host: expected.owner.host,
            clusterID: committed.clusterID, shardID: shard, partition: partition,
            epoch: expected.owner.epoch, transferID: transfer.id,
            isCurrent: { directory.snapshot().slots[partition] == expected },
            contains: { verified.partition(for: $0) == partition },
            admits: { room in
                let current = directory.snapshot()
                let slot = current.slots[current.partition(for: room)]
                return !slot.retired && slot.transfer == nil && slot.owner.host == expected.owner.host
            })
        let proof = try await host.drainPlacement(withdrawal, deadline: deadline)
        guard proof.host == expected.owner.host, proof.clusterID == committed.clusterID,
              proof.shardID == shard, proof.partition == partition,
              proof.epoch == expected.owner.epoch, proof.transferID == transfer.id else {
            throw V2ActorPlacementError.staleOwner
        }
        return .init(clusterID: proof.clusterID, partition: proof.partition,
            owner: expected.owner, transferID: proof.transferID)
    }

    package func refresh() async throws {
        for shard in logs.keys.sorted() {
            let next = try await logs[shard]!.load()
            try install(next, shard: shard)
        }
    }

    /// Operational reads go through the quorum, never the routing cache. Each
    /// shard is linearizable independently; this is not a cross-shard snapshot.
    package func committedInspections(deadline: ContinuousClock.Instant = .now + .seconds(30)) async throws -> [String: V2ActorPlacementInspection] {
        var result: [String: V2ActorPlacementInspection] = [:]
        for shard in logs.keys.sorted() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw V2ActorPlacementError.unavailable }
            guard let log = logs[shard] as? any V2ActorPlacementInspectableLog else {
                throw V2PlacementRaftError.invalidConfiguration
            }
            result[shard] = try await log.inspect(deadline: min(deadline, .now + .seconds(5)))
        }
        return result
    }

    package func grant(roomID: RoomID, owner: V2RoomDataOwner) throws -> V2RoomActorPlacementGrant {
        let snapshot = try directory(owner.shardID).snapshot()
        let slot = snapshot.slots[snapshot.partition(for: roomID)]
        guard !slot.retired, slot.transfer == nil else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return try .init(host: slot.owner.host, epoch: slot.owner.epoch)
    }

    package func admission(for token: V2RoomActivationToken) throws -> @Sendable () -> Bool {
        let directory = try directory(token.owner.shardID), snapshot = directory.snapshot()
        let partition = snapshot.partition(for: token.roomID), expected = snapshot.slots[partition].owner
        guard !snapshot.slots[partition].retired, snapshot.slots[partition].transfer == nil,
              try V2RoomActorPlacementGrant(host: expected.host, epoch: expected.epoch).matches(token) else {
            throw V2RoomCallFailure.notAccepted(.staleActivation)
        }
        return { directory.admits(partition: partition, owner: expected) }
    }

    private func install(_ snapshot: V2ActorPlacementSnapshot, shard: String) throws {
        let local = try directory(shard)
        // A concurrent refresh may already have observed a later committed
        // revision. The directory atomically handles this check and install.
        try local.installCommittedUnlessOlder(snapshot)
    }

    private func directory(_ shard: String) throws -> V2ActorPlacementDirectory {
        guard let directory = directories.withLock({ $0[shard] }) else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return directory
    }

    package static func initialSnapshot(shard: String, peers: [V2RoomDiscoveryPeer], partitionCount: Int = 256) throws -> V2ActorPlacementSnapshot {
        let hosts = peers.filter { $0.accessibleShardIDs.contains(shard) }.map(\.hostID).sorted { $0.rawValue < $1.rawValue }
        guard !hosts.isEmpty, (1...4096).contains(partitionCount), partitionCount >= hosts.count else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        let topology = "IMV2.actor-placement.v1\u{0}" + shard + "\u{0}" + hosts.map(\.rawValue).joined(separator: "\u{0}")
        let hash = Array(SHA256.hash(data: Array(topology.utf8)))
        let clusterID = UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
        let unregistered = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        // The fixed roster supplies affinity only. Reserved slots are retired;
        // fresh process identities must atomically register before admission.
        let slots = (0..<partitionCount).map { partition in
            V2ActorPlacementSlot(owner: .init(host: .init(hostID: hosts[partition % hosts.count], incarnationID: unregistered), epoch: 1), transfer: nil, retired: true)
        }
        return try .init(clusterID: clusterID, revision: 1, slots: slots)
    }
}

extension V2RoomActorPlacementRuntime {
    package func drainageService<Request: Sendable, Response: Sendable>(
        host: V2RoomActivationHost<Request, Response>) -> any V2ActorPlacementDraining {
        V2NativePlacementDrainService { request, deadline in
            guard request.isBounded else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            let snapshot = try V2ActorPlacementProtobuf.decode(request.committedSnapshot)
            let receipt = try await self.drainPlacement(snapshot, shard: request.shardID,
                partition: request.partition, host: host, deadline: deadline)
            return .init(shardID: request.shardID, receipt: receipt)
        }
    }
}

private struct V2NativePlacementDrainService: V2ActorPlacementDraining {
    let drain: @Sendable (V2ActorPlacementDrainWire, ContinuousClock.Instant) async throws -> V2ActorPlacementDrainedWire
    func drainPlacement(_ request: V2ActorPlacementDrainWire,
                        deadline: ContinuousClock.Instant) async throws -> V2ActorPlacementDrainedWire {
        try await drain(request, deadline)
    }
}

extension V2RoomActorPlacementRuntime {
    package func transfer(shard: String, partition: Int, expected: V2ActorPlacementOwner,
                          successor: V2ActorHostIdentity, transferID: UUID, originRevision: UInt64,
                          client: V2RoomClusterClient, deadline: ContinuousClock.Instant,
                          authorizeSuccessor: @escaping @Sendable (V2ActorHostIdentity) async throws -> Void)
        async throws {
        guard let log = logs[shard] else { throw V2ActorPlacementError.invalidConfiguration }
        let coordinator = V2ActorPlacementCoordinator(log: log, directory: try directory(shard),
            authorizeSuccessor: { identity in
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                let current = try await log.load()
                guard current.registration(for: identity.hostID) == .init(host: identity, retired: false) else {
                    throw V2ActorPlacementError.staleOwner
                }
                try await authorizeSuccessor(identity)
            }, drain: { snapshot, partition in
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                let request = V2ActorPlacementDrainWire(shardID: shard, partition: partition,
                    committedSnapshot: try V2ActorPlacementProtobuf.encode(snapshot))
                return try await client.drainPlacement(request, on: snapshot.slots[partition].owner.host,
                    deadline: deadline)
            })
        _ = try await coordinator.transfer(partition: partition, expected: expected,
            successor: successor, transferID: transferID, originRevision: originRevision)
    }
}
