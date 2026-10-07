import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

/// All control leases use the existing physical loan gates. Observation follows
/// actual settlement, including acquisition and unknown transaction outcomes.
struct GatewayObservedRealtimeLeaseStore: V2RealtimePartitionLeaseStore {
    let underlying: any V2RealtimePartitionLeaseStore
    let metrics: V2ActorRealtimeMetrics

    private func observed<T: Sendable>(_ operation: V2ActorRealtimeOperation,
        body: @Sendable () async throws -> T) async throws -> T {
        let began = ContinuousClock.now
        do {
            let value = try await V2DatabaseLoanObservationContext.$source.withValue(.realtimePartitionControl, operation: body)
            metrics.operation(operation, result: .succeeded, elapsed: began.duration(to: .now))
            return value
        } catch {
            metrics.operation(operation, result: .failed, elapsed: began.duration(to: .now))
            throw error
        }
    }
    func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
               leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try await observed(.partitionClaim) {
            try await underlying.claim(partitionIDs: partitionIDs, identity: identity, token: token, leaseDuration: leaseDuration)
        }
    }
    func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try await observed(.partitionRenew) { try await underlying.renew(leases, leaseDuration: leaseDuration) }
    }
    func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        try await observed(.partitionConfirm) { try await underlying.confirm(leases) }
    }
    func release(_ leases: [V2RealtimePartitionLease]) async throws {
        try await observed(.partitionRelease) { try await underlying.release(leases) }
    }
}
