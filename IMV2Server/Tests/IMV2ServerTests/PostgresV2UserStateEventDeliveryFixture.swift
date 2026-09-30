import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import Testing
@testable import IMV2ServerInfrastructure

/// Deliver successive stream heads through real target receipts and source ACKs.
/// A large claim limit still returns at most one outstanding event per user.
func deliverUserStateEvents(
    _ outbox: PostgresV2UserStateEventOutbox,
    projector: any V2UserStateEventProjecting,
    now: Date,
    leaseDuration: TimeInterval = 30,
    limit: Int = 1024
) async throws -> [V2UserStateEventLease] {
    var delivered: [V2UserStateEventLease] = []
    for _ in 0..<1024 {
        let leases = try await outbox.claim(now: now, leaseDuration: leaseDuration, limit: limit)
        if leases.isEmpty { return delivered }
        for lease in leases {
            let sequence = try await projector.project(lease.event)
            #expect(try await projector.project(lease.event) == sequence)
            let acknowledged = try await outbox.acknowledge(lease, sequence: sequence, now: now)
            try #require(acknowledged)
            delivered.append(lease)
        }
    }
    Issue.record("User-state fixture exceeded its bounded drain limit")
    throw V2UserStateEventError.corruptPersistenceState
}
