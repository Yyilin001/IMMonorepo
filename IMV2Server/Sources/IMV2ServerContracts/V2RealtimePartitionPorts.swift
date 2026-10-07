import Foundation
import IMV2ActorContracts

/// A confirmed control lease. Remaining time is sampled after acquiring the
/// sorted partition locks. The installer must deduct the entire request time.
public struct V2RealtimePartitionLease: Equatable, Sendable {
    public let partitionID: Int
    public let identity: V2GatewayRealtimeIdentity
    public let epoch: Int64
    public let token: UUID
    public let remainingLeaseSeconds: TimeInterval
    public init(partitionID: Int, identity: V2GatewayRealtimeIdentity, epoch: Int64,
                token: UUID, remainingLeaseSeconds: TimeInterval) {
        self.partitionID = partitionID; self.identity = identity; self.epoch = epoch
        self.token = token; self.remainingLeaseSeconds = remainingLeaseSeconds
    }
}

/// Fixed-size partition control only; no references, topics or per-event reads.
/// A batch contains at most 256 distinct partition IDs and uses ascending lock
/// order, followed by a fresh database clock. Unknown COMMIT cannot install an
/// extended local lease; the same claim token may be confirmed by retrying claim.
public protocol V2RealtimePartitionLeaseStore: Sendable {
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
               leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease]
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease]
    func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease]
    func release(_ leases: [V2RealtimePartitionLease]) async throws
}

/// A local Ready promise, never a socket/client acknowledgement. Consumers
/// recheck this exact generation after awaiting their own scope work.
public struct V2RealtimeCoverageConfirmation: Sendable {
    public let token: V2RealtimeShardToken
    public let sessionID: UUID
    public let interestGeneration: Int64
    public let highWatermark: UInt64
    public let deadline: ContinuousClock.Instant
    public init(token: V2RealtimeShardToken, sessionID: UUID, interestGeneration: Int64,
                highWatermark: UInt64, deadline: ContinuousClock.Instant) {
        self.token = token; self.sessionID = sessionID
        self.interestGeneration = interestGeneration; self.highWatermark = highWatermark; self.deadline = deadline
    }
}
