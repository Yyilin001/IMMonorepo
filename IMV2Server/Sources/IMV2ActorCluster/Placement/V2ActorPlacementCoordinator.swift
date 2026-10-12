import Foundation
import IMV2ActorContracts

/// A linearizable, durable control log. A successful append means its command
/// has committed. Request ID + command kind + immutable origin version bind
/// retries. Recent results are exact; pinned old proofs return current committed
/// state, and expired unreferenced operations are rejected.
/// Implementations must compare the entire expected snapshot, not membership.
package protocol V2ActorPlacementLog: Sendable {
    func load() async throws -> V2ActorPlacementSnapshot
    func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence, expected: V2ActorPlacementSnapshot,
                requestID: UUID, originRevision: UInt64) async throws -> V2ActorPlacementSnapshot
}

package enum V2ActorPlacementCommandEvidence: Sendable {
    case none
    case partition(V2ActorPlacementDrainReceipt)
    case host(V2RoomHostDrainProof, previous: V2ActorHostIdentity, registrationRequestID: UUID)
    case excludedHost(V2RoomHostExclusionProof)
}
extension V2ActorPlacementLog {
    /// A first submission derives its origin from the initial CAS. Retries
    /// which refresh that CAS must pass the original version explicitly.
    package func append(_ command: V2ActorPlacementCommand, evidence: V2ActorPlacementCommandEvidence,
                        expected: V2ActorPlacementSnapshot, requestID: UUID) async throws -> V2ActorPlacementSnapshot {
        try await append(command, evidence: evidence, expected: expected, requestID: requestID,
            originRevision: expected.revision)
    }
    // Pure/local log callers need no transport proof. A remote implementation
    // rejects uncertified new terminal commands; this is also used for exact
    // replay of already certified successful requests after a lost response.
    package func append(_ command: V2ActorPlacementCommand, expected: V2ActorPlacementSnapshot,
                        requestID: UUID, originRevision: UInt64? = nil) async throws -> V2ActorPlacementSnapshot {
        try await append(command, evidence: .none, expected: expected, requestID: requestID,
            originRevision: originRevision ?? expected.revision)
    }
}

/// Returned by an authenticated old-owner endpoint only after its Host has
/// closed admission, drained accepted work and closed all matching instances.
/// Transport must bind `owner.host` to the authenticated sender. The control
/// plane never accepts a client-supplied receipt or interprets timeout as one.
package struct V2ActorPlacementDrainReceipt: Equatable, Sendable {
    package let clusterID: UUID
    package let partition: Int
    package let owner: V2ActorPlacementOwner
    package let transferID: UUID
    package var certificate: V2ActorSignedPacket? = nil
}

/// Planned transfer publishes ownership only after physical drain. Startup and
/// stop registration use the same durable log's CAS through the runtime.
/// A cancelled or failed migration remains withdrawn and can be resumed using
/// the SAME transfer ID. There is deliberately no timeout-based takeover API.
package actor V2ActorPlacementCoordinator {
    private let log: any V2ActorPlacementLog
    private let directory: V2ActorPlacementDirectory
    private let authorizeSuccessor: @Sendable (V2ActorHostIdentity) async throws -> Void
    private var origins: [UUID: UInt64] = [:]
    private let drain: @Sendable (V2ActorPlacementSnapshot, Int) async throws -> V2ActorPlacementDrainReceipt

    package init(log: any V2ActorPlacementLog, directory: V2ActorPlacementDirectory,
                 authorizeSuccessor: @escaping @Sendable (V2ActorHostIdentity) async throws -> Void,
                 drain: @escaping @Sendable (V2ActorPlacementSnapshot, Int) async throws -> V2ActorPlacementDrainReceipt) {
        self.log = log; self.directory = directory; self.drain = drain
        self.authorizeSuccessor = authorizeSuccessor
    }

    @discardableResult
    package func refresh() async throws -> V2ActorPlacementSnapshot {
        let committed = try await log.load()
        try install(committed)
        return committed
    }

    package func transfer(partition: Int, expected: V2ActorPlacementOwner,
                          successor: V2ActorHostIdentity, transferID: UUID, originRevision suppliedOrigin: UInt64? = nil) async throws -> V2ActorPlacementSnapshot {
        try Task.checkCancellation()
        let current = try await refresh()
        guard current.slots.indices.contains(partition) else { throw V2ActorPlacementError.invalidConfiguration }
        let originRevision = suppliedOrigin ?? origins[transferID] ?? current.revision
        guard originRevision > 0, originRevision <= current.revision,
              origins[transferID] == nil || origins[transferID] == originRevision else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        origins[transferID] = originRevision
        let slot = current.slots[partition]
        let request = V2ActorPlacementTransfer(id: transferID, successor: successor)
        // Retry after a lost terminal commit response is an idempotent success.
        if expected.epoch < UInt64.max,
           slot.owner == .init(host: successor, epoch: expected.epoch + 1), slot.transfer == nil {
            // Only the durable request log can certify which transfer completed.
            // An owner match alone is insufficient: return stale rather than
            // accepting a different transfer which happened to choose this host.
            let replayed = try await log.append(.completeTransfer(partition: partition, expected: expected,
                transferID: transferID), expected: current, requestID: transferID, originRevision: originRevision)
            try install(replayed)
            return replayed
        }
        guard slot.owner == expected else { throw V2ActorPlacementError.staleOwner }
        // The composition boundary checks the fixed trusted host roster, exact
        // process identity and required data-shard access. Discovery is a hint.
        try await authorizeSuccessor(successor)
        try Task.checkCancellation()
        let withdrawn: V2ActorPlacementSnapshot
        if let pending = slot.transfer {
            guard pending == request else { throw V2ActorPlacementError.invalidTransition }
            withdrawn = current
        } else {
            withdrawn = try await log.append(.beginTransfer(partition: partition, expected: expected,
                transfer: request), expected: current, requestID: transferID, originRevision: originRevision)
            try install(withdrawn)
        }
        try Task.checkCancellation()
        let evidence: V2ActorPlacementCommandEvidence
        if withdrawn.slots[partition].retired {
            // Full Host retirement already committed its physical drain proof.
            // A stopped process cannot answer another partition drain RPC.
            evidence = .none
        } else {
            let receipt = try await drain(withdrawn, partition)
            guard receipt.clusterID == withdrawn.clusterID, receipt.partition == partition,
                  receipt.owner == expected, receipt.transferID == transferID else { throw V2ActorPlacementError.staleOwner }
            evidence = .partition(receipt)
        }
        try Task.checkCancellation()
        // Physical drain can be lengthy. Admission checked before withdrawal
        // does not certify that this exact successor is still eligible now.
        // Failure leaves the partition withdrawn; it never selects a fallback.
        try await authorizeSuccessor(successor)
        try Task.checkCancellation()
        // Re-read after the remote drain: an unrelated partition may have
        // committed while we awaited it. Never overwrite another revision.
        let latest = try await refresh()
        guard latest.slots[partition] == withdrawn.slots[partition] else {
            throw V2ActorPlacementError.invalidTransition
        }
        let committed = try await log.append(.completeTransfer(partition: partition,
            expected: expected, transferID: transferID), evidence: evidence, expected: latest, requestID: transferID, originRevision: originRevision)
        try install(committed)
        return committed
    }

    private func install(_ committed: V2ActorPlacementSnapshot) throws {
        try directory.installCommittedUnlessOlder(committed)
    }

}
